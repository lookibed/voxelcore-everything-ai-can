-- smollm_gpu:llm — вся модель Ru-Small-Instruct (12 слоёв, Q8_0) на GPU стокового VoxelCore: фреймы GUI в текстуру
-- (gui.create_frame) как страницы памяти, вычисления — режимы ui.glslf, чтение в Lua — assets.to_canvas (glGetTexImage).
-- Разведка, вопрос 5 (agents/research/SMOLLM_GPU.md).
--
-- Устройство:
--   * статические страницы весов (data/gpu/weights.bin, prep_model.py) -> 117 canvas-текстур RGBA 768 x rows (RGB данные);
--     без PNG: file.read_bytes -> Canvas:_set_data(адрес + смещение) (memcpy) -> create_texture;
--   * 264 фрейма-роли; фреймы рисуются движком каждый кадр в порядке std::unordered_map (не по имени) — порядок
--     узнаётся пробой (frame R копирует «часы», остальные — фрейм R) и кешируется в export:smollm_gpu_order.txt;
--     роли раздаются фреймам в порядке отрисовки, поэтому весь проход токена (12 слоёв + логиты + argmax) — ОДИН кадр;
--   * KV-кэш живёт в паре фреймов KA/KB (VA/VB) на слой: KA = копия KB прошлого кадра + новая строка pos, KB = копия KA;
--   * токен и позиция — canvas sgw_tok (int8-строка эмбеддинга, масштабы, cos/sin RoPE для pos), Lua пишет его перед
--     кадром; параметры pos — region картинок (без пересборки документа). Результат — фрейм AM2: индекс argmax.
-- 12.10 (агент gpu_api): примитивы — через API пака gpu_compute: программа smollm_gpu (shaders/gpu_smollm.glsl, маркеры
-- #FF<режим>FF80) собрана в общий ui.glslf пака gpu_compute (свой ui.glslf — ui.glslf.api.bak); страницы весов — gc.buffer,
-- 418 фреймов-ролей — gc.chain (проба порядка и кеш config:gpu_compute_order.json), чтение — gc.read{sync}.
local probe = require("smollm_gpu:probe")
local gc = require("gpu_compute:compute")
local PROG = gc.program("smollm_gpu")
local M = {}

local function log(s) debug.log("[sg] " .. s) end
local now = time.precise_time or os.clock
local function rgb24(v) return v % 16777216 end
local PW = 768

-- ---------------------------------------------------------------- данные
local function ptr_of(ba)
    local s = tostring(ba.bytes)
    local hex = s:match("0x(%x+)")
    if not hex then error("no pointer in " .. s) end
    -- tonumber(hex, 16) в LuaJIT насыщается на 2^32-1 (адрес 0x0209... -> 4294967295 -> падение в memcpy): разбор вручную
    local n = 0
    for i = 1, #hex do n = n * 16 + tonumber(hex:sub(i, i), 16) end
    return n
end

function M.load()
    local t0 = now()
    local index = json.parse(file.read("smollm_gpu:data/gpu/index.json"))
    local t1 = now()
    local ba = file.read_bytes("smollm_gpu:data/gpu/weights.bin")
    local t2 = now()
    local canvases, bytes, tset, ttex = {}, 0, 0, 0
    for name, e in pairs(index.pages) do
        local off, rows = e[1], e[2]
        local a = now()
        -- буфер gpu_compute: Canvas PW x rows <- memcpy(_set_data) из Bytearray со смещения off -> create_texture
        local buf = gc.buffer{ id = "sgw_" .. name, width = PW, rows = rows, bytes = ba, offset = off, size = PW * rows * 4 }
        ttex = ttex + (now() - a)
        canvases[name] = buf.canvas
        bytes = bytes + PW * rows * 4
    end
    local t3 = now()
    M.weights_ba = nil
    ba = nil
    M.tok = file.read_bytes("smollm_gpu:data/gpu/tok.bin")
    M.rope = file.read_bytes("smollm_gpu:data/gpu/rope.bin")
    local t4 = now()
    M.canvases = canvases
    local tok = Canvas({ PW, 2 })
    for x = 0, PW - 1 do tok:set(x, 0, 0, 0, 0, 255); tok:set(x, 1, 0, 0, 0, 255) end
    tok:create_texture("sgw_tok")
    M.tok_canvas = tok
    collectgarbage("collect")
    log(("load: index %.1f ms, read_bytes weights.bin (%.1f MB) %.1f ms, %d canvases: _set_data %.1f ms + create_texture %.1f ms (total %.1f ms), tok/rope %.1f ms, lua heap %.1f MB")
        :format((t1 - t0) * 1000, bytes / 1e6, (t2 - t1) * 1000, #(function() local l = {} for k in pairs(canvases) do l[#l + 1] = k end return l end)(),
            tset * 1000, ttex * 1000, (t3 - t2) * 1000, (t4 - t3) * 1000, collectgarbage("count") / 1024))
end

-- ---------------------------------------------------------------- роли (страницы) и картинки
local MODE = { COPYR = 5, MV_ROPE = 12, MV_RES = 13, MV_SILU = 14, MV = 15, IVAL = 16, EMBED = 30, NORMQ = 31, QUANT = 32,
    SCORES = 33, SM_E = 34, SM_N = 35, AV = 36, KVPUT = 37, ARGMAX1 = 38, ARGMAX2 = 39,
    RED_ROPE = 40, RED_RES = 41, RED_SILU = 42, RED = 43, SS = 44, NORMQ2 = 45 }
M.MODE = MODE

local function I(src, mode, r0, h, P, Q, dyn) return { src = src, mode = mode, r0 = r0, h = h, P = P or 0, Q = Q or 0, dyn = dyn } end
local function mvP(rows, G) return rows + G * 4096 end
local function mvQ(row_base, orow) return row_base + orow * 32768 end
local function nqP(xrow, wrow) return xrow + wrow * 512 end
local function nqQ(orow, G) return orow + G * 512 end

local function ceil_div(a, b) return math.floor((a + b - 1) / b) end
-- раскладка страницы матвека (как prep_model.py и mv_x0row в ui.glslf)
local function lay(rows, n)
    local G, RT = n / 64, ceil_div(n, 3)
    local wsr0, wsr = ceil_div(rows * RT, PW), ceil_div(rows * G * 2, PW)
    return { G = G, RT = RT, wsr0 = wsr0, wsr = wsr, x0row = wsr0 + wsr, ivr = ceil_div(rows * G, PW) }
end
M.lay = lay

-- вариант 2: матвек в два прохода (IVAL -> фрейм IV, RED в фрейме выхода), сумма квадратов нормы — фрейм SS
function M.build_roles_v2(nlayers)
    nlayers = nlayers or 12
    local roles = {}
    local function role(name, H, imgs) roles[#roles + 1] = { name = name, H = H, imgs = imgs } end
    -- фрейм IV страницы page (rows, n, hpage — высота страницы)
    local function iv(page, rows, n, hpage)
        local L = lay(rows, n)
        local ex = L.ivr + L.wsr
        role(page .. "_IV", ex + (hpage - L.x0row), {
            I(page, MODE.IVAL, 0, L.ivr, mvP(rows, L.G), 0),
            I(page, MODE.COPYR, L.ivr, L.wsr, L.wsr0, L.ivr),
            I(page, MODE.COPYR, ex, hpage - L.x0row, L.x0row, ex) })
    end
    local function ss(name, src)
        role(name, 5, { I(src, MODE.COPYR, 0, 4, 0, 0), I(src, MODE.SS, 4, 1, 0, 4) })
    end
    role("E", 4, { I("@tok", MODE.EMBED, 0, 2), I("@rms", MODE.COPYR, 2, 2, 0, 2) })
    local prevR = "E"
    local lq, lo, lf, l2 = lay(1280, 768), lay(768, 768), lay(1024, 768), lay(384, 2048)
    for l = 0, nlayers - 1 do
        local L = "L" .. l .. "_"
        ss(L .. "SA", prevR)
        role(L .. "N1", lq.x0row + 2, { I("@qkv" .. l, MODE.COPYR, 0, lq.x0row, 0, 0),
            I(L .. "SA", MODE.NORMQ2, lq.x0row, 1, nqP(0, 2), nqQ(lq.x0row, 12)),
            I("@tok", MODE.COPYR, lq.x0row + 1, 1, 1, lq.x0row + 1) })
        iv(L .. "N1", 1280, 768, lq.x0row + 2)
        role(L .. "QKV", 4, { I(L .. "N1_IV", MODE.RED_ROPE, 0, 4, mvP(1280, 12), mvQ(0, 0)) })
        role(L .. "KA", 344, { I(L .. "KB", MODE.COPYR, 0, 342, 0, 0), I(L .. "QKV", MODE.KVPUT, 0, 1, 0, 1536, "kv"),
            I(L .. "QKV", MODE.COPYR, 342, 2, 0, 342) })
        role(L .. "SC", 16, { I(L .. "KA", MODE.SCORES, 0, 16, 0, 0, "pos") })
        role(L .. "SM", 16, { I(L .. "SC", MODE.SM_E, 0, 16, 0, 0, "pos") })
        role(L .. "SN", 16, { I(L .. "SM", MODE.SM_N, 0, 16, 0, 0, "pos") })
        role(L .. "VA", 358, { I(L .. "VB", MODE.COPYR, 0, 342, 0, 0), I(L .. "QKV", MODE.KVPUT, 0, 1, 0, 2048, "kv"),
            I(L .. "SN", MODE.COPYR, 342, 16, 0, 342) })
        role(L .. "AV", 2, { I(L .. "VA", MODE.AV, 0, 2, 0, 0, "pos") })
        role(L .. "WO", lo.x0row + 3, { I("@wo" .. l, MODE.COPYR, 0, lo.x0row, 0, 0),
            I(L .. "AV", MODE.QUANT, lo.x0row, 1, nqP(0, 0), nqQ(lo.x0row, 12)),
            I(prevR, MODE.COPYR, lo.x0row + 1, 2, 0, lo.x0row + 1) })
        iv(L .. "WO", 768, 768, lo.x0row + 3)
        role(L .. "R1", 4, { I(L .. "WO_IV", MODE.RED_RES, 0, 2, mvP(768, 12), mvQ(0, 0)),
            I("@rms", MODE.COPYR, 2, 2, 2 * (12 + l), 2) })
        ss(L .. "SF", L .. "R1")
        role(L .. "NQ", 1, { I(L .. "SF", MODE.NORMQ2, 0, 1, nqP(0, 2), nqQ(0, 12)) })
        for k = 0, 3 do
            role(L .. "FP" .. k, lf.x0row + 1, { I("@ffn" .. l .. "_" .. k, MODE.COPYR, 0, lf.x0row, 0, 0),
                I(L .. "NQ", MODE.COPYR, lf.x0row, 1, 0, lf.x0row) })
            iv(L .. "FP" .. k, 1024, 768, lf.x0row + 1)
        end
        local himgs = {}
        for k = 0, 3 do
            local r0, r1 = math.floor(1024 * k / PW), math.floor((1024 * k + 1023) / PW)
            himgs[#himgs + 1] = I(L .. "FP" .. k .. "_IV", MODE.RED_SILU, r0, r1 - r0 + 1, mvP(1024, 12), mvQ(512 * k, 0))
        end
        role(L .. "H", 6, himgs)
        for k = 0, 1 do
            role(L .. "W2" .. k, l2.x0row + 3, { I("@w2" .. l .. "_" .. k, MODE.COPYR, 0, l2.x0row, 0, 0),
                I(L .. "H", MODE.QUANT, l2.x0row, 1, nqP(0, 0), nqQ(l2.x0row, 32)),
                I(L .. "R1", MODE.COPYR, l2.x0row + 1, 2, 0, l2.x0row + 1) })
            iv(L .. "W2" .. k, 384, 2048, l2.x0row + 3)
        end
        local next_rms = l < 11 and (l + 1) or 24
        role(L .. "R2", 4, { I(L .. "W20_IV", MODE.RED_RES, 0, 1, mvP(384, 32), mvQ(0, 0)),
            I(L .. "W21_IV", MODE.RED_RES, 1, 1, mvP(384, 32), mvQ(384, 0)), I("@rms", MODE.COPYR, 2, 2, 2 * next_rms, 2) })
        role(L .. "KB", 342, { I(L .. "KA", MODE.COPYR, 0, 342, 0, 0) })
        role(L .. "VB", 342, { I(L .. "VA", MODE.COPYR, 0, 342, 0, 0) })
        prevR = L .. "R2"
    end
    ss("SL", prevR)
    role("NQL", 1, { I("SL", MODE.NORMQ2, 0, 1, nqP(0, 2), nqQ(0, 12)) })
    local lg = {}
    for k = 0, 19 do
        local rows = k < 19 and 1280 or 256
        local Lc = lay(rows, 768)
        role("LP" .. k, Lc.x0row + 1, { I("@cls" .. k, MODE.COPYR, 0, Lc.x0row, 0, 0), I("NQL", MODE.COPYR, Lc.x0row, 1, 0, Lc.x0row) })
        iv("LP" .. k, rows, 768, Lc.x0row + 1)
        local t0, t1 = 2560 * k, 2560 * k + 2 * rows - 1
        local r0, r1 = math.floor(t0 / PW), math.floor(t1 / PW)
        lg[#lg + 1] = I("LP" .. k .. "_IV", MODE.RED, r0, r1 - r0 + 1, mvP(rows, 12), mvQ(1280 * k, 0))
    end
    role("LG", 64, lg)
    role("AM1", 1, { I("LG", MODE.ARGMAX1, 0, 1, 0, 0) })
    role("AM2", 1, { I("AM1", MODE.ARGMAX2, 0, 1, 0, 0) })
    M.roles = roles
    return roles
end

function M.build_roles(nlayers)
    nlayers = nlayers or 12
    local roles = {}
    local function role(name, H, imgs) roles[#roles + 1] = { name = name, H = H, imgs = imgs } end
    role("E", 4, { I("@tok", MODE.EMBED, 0, 2), I("@rms", MODE.COPYR, 2, 2, 0, 2) })
    local prevR = "E"
    for l = 0, nlayers - 1 do
        local L = "L" .. l .. "_"
        role(L .. "N1", 469, { I("@qkv" .. l, MODE.COPYR, 0, 467, 0, 0),
            I(prevR, MODE.NORMQ, 467, 1, nqP(0, 2), nqQ(467, 12)),
            I("@tok", MODE.COPYR, 468, 1, 1, 468) })
        role(L .. "QKV", 4, { I(L .. "N1", MODE.MV_ROPE, 0, 4, mvP(1280, 12), mvQ(0, 0)) })
        role(L .. "KA", 344, { I(L .. "KB", MODE.COPYR, 0, 342, 0, 0), I(L .. "QKV", MODE.KVPUT, 0, 1, 0, 1536, "kv"),
            I(L .. "QKV", MODE.COPYR, 342, 2, 0, 342) })
        role(L .. "SC", 16, { I(L .. "KA", MODE.SCORES, 0, 16, 0, 0, "pos") })
        role(L .. "SM", 16, { I(L .. "SC", MODE.SM_E, 0, 16, 0, 0, "pos") })
        role(L .. "SN", 16, { I(L .. "SM", MODE.SM_N, 0, 16, 0, 0, "pos") })
        role(L .. "VA", 358, { I(L .. "VB", MODE.COPYR, 0, 342, 0, 0), I(L .. "QKV", MODE.KVPUT, 0, 1, 0, 2048, "kv"),
            I(L .. "SN", MODE.COPYR, 342, 16, 0, 342) })
        role(L .. "AV", 2, { I(L .. "VA", MODE.AV, 0, 2, 0, 0, "pos") })
        role(L .. "WO", 283, { I("@wo" .. l, MODE.COPYR, 0, 280, 0, 0), I(L .. "AV", MODE.QUANT, 280, 1, nqP(0, 0), nqQ(280, 12)),
            I(prevR, MODE.COPYR, 281, 2, 0, 281) })
        role(L .. "R1", 4, { I(L .. "WO", MODE.MV_RES, 0, 2, mvP(768, 12), mvQ(0, 0)), I("@rms", MODE.COPYR, 2, 2, 2 * (12 + l), 2) })
        -- xq/xs нормы FFN считаются один раз (фрейм NQ), страницы FP копируют строку
        role(L .. "NQ", 1, { I(L .. "R1", MODE.NORMQ, 0, 1, nqP(0, 2), nqQ(0, 12)) })
        for k = 0, 3 do
            role(L .. "FP" .. k, 375, { I("@ffn" .. l .. "_" .. k, MODE.COPYR, 0, 374, 0, 0),
                I(L .. "NQ", MODE.COPYR, 374, 1, 0, 374) })
        end
        local himgs = {}
        for k = 0, 3 do
            local r0, r1 = math.floor(1024 * k / PW), math.floor((1024 * k + 1023) / PW)
            himgs[#himgs + 1] = I(L .. "FP" .. k, MODE.MV_SILU, r0, r1 - r0 + 1, mvP(1024, 12), mvQ(512 * k, 0))
        end
        role(L .. "H", 6, himgs)
        for k = 0, 1 do
            role(L .. "W2" .. k, 377, { I("@w2" .. l .. "_" .. k, MODE.COPYR, 0, 374, 0, 0),
                I(L .. "H", MODE.QUANT, 374, 1, nqP(0, 0), nqQ(374, 32)), I(L .. "R1", MODE.COPYR, 375, 2, 0, 375) })
        end
        local next_rms = l < 11 and (l + 1) or 24
        role(L .. "R2", 4, { I(L .. "W20", MODE.MV_RES, 0, 1, mvP(384, 32), mvQ(0, 0)),
            I(L .. "W21", MODE.MV_RES, 1, 1, mvP(384, 32), mvQ(384, 0)), I("@rms", MODE.COPYR, 2, 2, 2 * next_rms, 2) })
        role(L .. "KB", 342, { I(L .. "KA", MODE.COPYR, 0, 342, 0, 0) })
        role(L .. "VB", 342, { I(L .. "VA", MODE.COPYR, 0, 342, 0, 0) })
        prevR = L .. "R2"
    end
    local lg = {}
    role("NQL", 1, { I(prevR, MODE.NORMQ, 0, 1, nqP(0, 2), nqQ(0, 12)) })
    for k = 0, 19 do
        local rows = k < 19 and 1280 or 256
        local x0 = k < 19 and 467 or 94
        role("LP" .. k, x0 + 1, { I("@cls" .. k, MODE.COPYR, 0, x0, 0, 0), I("NQL", MODE.COPYR, x0, 1, 0, x0) })
        local t0, t1 = 2560 * k, 2560 * k + 2 * rows - 1
        local r0, r1 = math.floor(t0 / PW), math.floor(t1 / PW)
        lg[#lg + 1] = I("LP" .. k, MODE.MV, r0, r1 - r0 + 1, mvP(rows, 12), mvQ(1280 * k, 0))
    end
    role("LG", 64, lg)
    role("AM1", 1, { I("LG", MODE.ARGMAX1, 0, 1, 0, 0) })
    role("AM2", 1, { I("AM1", MODE.ARGMAX2, 0, 1, 0, 0) })
    M.roles = roles
    return roles
end

-- ---------------------------------------------------------------- фреймы и порядок отрисовки
local frames = {}  -- fid -> {root, doc}

local function create(fid, w, h)
    local root, doc = gc.frame(fid, w, h)
    frames[fid] = { root = root, doc = doc, w = w, h = h }
    return frames[fid]
end

-- порядок отрисовки n фреймов sgf000.. — gc.chain (gpu_compute:order: проба 2 кадра на фрейм, проверка цепочкой INC,
-- кеш config:gpu_compute_order.json; прежний кеш export:smollm_gpu_order.txt не используется)
function M.setup_frames(n)
    local ch = gc.chain{ id = "sgf", n = n, ticks = probe.ticks }
    log(("order: %d frames, %s, %.1f s"):format(n, ch.info.cached and "cached" or "probed", ch.info.seconds))
    M.order = ch.ids
    return ch.ids
end

local function region(p, q) return ("%d,%d,%d,%d"):format(p, q, p, q) end

function M.assign(roles, order)
    local t0 = now()
    local fid_of = {}
    for k, r in ipairs(roles) do fid_of[r.name] = order[k] end
    M.fid_of = fid_of
    M.dyn = {}
    M.imgs = {}
    local nimg = 0
    for k, r in ipairs(roles) do
        local fid = order[k]
        local f = create(fid, PW, r.H)
        r.fid = fid
        for j, im in ipairs(r.imgs) do
            local src = im.src:sub(1, 1) == "@" and ("sgw_" .. im.src:sub(2)) or fid_of[im.src]
            if not src then error("role " .. r.name .. ": unknown source " .. im.src) end
            local id = "i" .. j
            f.root:add(('<image id="%s" src="%s" pos="0,%d" size="%d,%d" color="%s" region="%s"/>'):format(
                id, src, r.H - im.r0 - im.h, PW, im.h, PROG.marker(im.mode), region(im.P, im.Q)))
            nimg = nimg + 1
            M.imgs[#M.imgs + 1] = { el = f.doc[id], mode = im.mode, src = im.src, role = r.name }
            if im.dyn then M.dyn[#M.dyn + 1] = { el = f.doc[id], kind = im.dyn, Q = im.Q, H = r.H } end
        end
    end
    log(("assign: %d roles, %d images, %.1f ms"):format(#roles, nimg, (now() - t0) * 1000))
end

-- ---------------------------------------------------------------- токен
function M.set_token(token, pos)
    local c, tb, rb = M.tok_canvas, M.tok, M.rope
    local q0 = token * 768
    for t = 0, 255 do
        local b = q0 + 3 * t
        c:set(t, 0, tb[b + 1], tb[b + 2], tb[b + 3], 255)
    end
    local s0 = 24576 * 768 + token * 48
    for g = 0, 11 do
        local b = s0 + 4 * g
        c:set(256 + 2 * g, 0, tb[b + 1], tb[b + 2], tb[b + 3], 255)
        c:set(257 + 2 * g, 0, tb[b + 4], 0, 0, 255)
    end
    for j = 0, 31 do
        local bc, bs = pos * 128 + 4 * j, 512 * 128 + pos * 128 + 4 * j
        c:set(2 * j, 1, rb[bc + 1], rb[bc + 2], rb[bc + 3], 255)
        c:set(2 * j + 1, 1, rb[bc + 4], 0, 0, 255)
        c:set(64 + 2 * j, 1, rb[bs + 1], rb[bs + 2], rb[bs + 3], 255)
        c:set(65 + 2 * j, 1, rb[bs + 4], 0, 0, 255)
    end
    c:update()
    for _, d in ipairs(M.dyn) do
        if d.kind == "pos" then
            d.el.region = { pos, d.Q, pos, d.Q }
        else
            local r0, r1 = math.floor(pos * 512 / PW), math.floor((pos * 512 + 511) / PW)
            d.el.region = { pos, d.Q, pos, d.Q }
            d.el.pos = { 0, d.H - r1 - 1 }
            d.el.size = { PW, r1 - r0 + 1 }
        end
    end
end

function M.argmax()
    local c = gc.read(M.fid_of.AM2, { sync = true, canvas = true })
    local bits = rgb24(c:at(1, 0)) + (rgb24(c:at(2, 0)) % 256) * 16777216
    return rgb24(c:at(0, 0)), bits
end

function M.logits_bits()
    local c = gc.read(M.fid_of.LG, { sync = true, canvas = true })
    local out = {}
    for j = 0, 24575 do
        local t = 2 * j
        out[j] = rgb24(c:at(t % PW, math.floor(t / PW))) + (rgb24(c:at((t + 1) % PW, math.floor((t + 1) / PW))) % 256) * 16777216
    end
    return out
end

-- вектор float из фрейма роли (отладка): n значений с тексела 2*j строки row0
function M.vec_bits(role, row0, n)
    local c = assets.to_canvas(M.fid_of[role])
    local out = {}
    for j = 0, n - 1 do
        local t = row0 * PW + 2 * j
        out[j] = rgb24(c:at(t % PW, math.floor(t / PW))) + (rgb24(c:at((t + 1) % PW, math.floor((t + 1) / PW))) % 256) * 16777216
    end
    return out
end

-- ---------------------------------------------------------------- профиль: какая часть кадра GPU на что уходит
local function category(im)
    local m = im.mode
    if m == MODE.COPYR then
        if im.src:sub(1, 1) == "@" then return (im.src == "@tok" or im.src == "@rms") and "copy_vec" or "copy_weights" end
        if im.src:match("_K[AB]$") or im.src:match("_V[AB]$") then return "copy_kv" end
        return "copy_vec"
    end
    local kind = im.role:gsub("^L%d+_", ""):gsub("%d+$", "")
    if (m >= 12 and m <= 16) or (m >= 40 and m <= 43) then return (m == 16 and "iv_" or "mv_") .. kind:gsub("_IV$", "") end
    if m == MODE.SS or m == MODE.NORMQ2 then return "nq_" .. kind end
    if m == MODE.NORMQ or m == MODE.QUANT then return "nq_" .. kind end
    if m >= 33 and m <= 36 then return "attention" end
    if m == MODE.KVPUT then return "kvput" end
    return "other"
end

local function frame_ms(n)
    probe.ticks(3)
    local u0 = time.uptime()
    probe.ticks(n)
    return (time.uptime() - u0) * 1000 / n
end

function M.profile(n)
    n = n or 60
    local cats, order = {}, {}
    for _, im in ipairs(M.imgs) do
        local c = category(im)
        if not cats[c] then cats[c] = {}; order[#order + 1] = c end
        table.insert(cats[c], im.el)
    end
    local all = frame_ms(n)
    log(("profile: all on %.2f ms/frame"):format(all))
    for _, c in ipairs(order) do
        for _, el in ipairs(cats[c]) do el.visible = false end
        local ms = frame_ms(n)
        for _, el in ipairs(cats[c]) do el.visible = true end
        log(("profile: without %-12s (%3d images) %.2f ms/frame -> %.2f ms"):format(c, #cats[c], ms, all - ms))
    end
    for _, im in ipairs(M.imgs) do im.el.visible = false end
    log(("profile: all images hidden (frames still cleared) %.2f ms/frame"):format(frame_ms(n)))
    for _, im in ipairs(M.imgs) do im.el.visible = true end
end

-- ---------------------------------------------------------------- проверки и замеры
local function u32_le(ba, i)
    local b = i * 4
    return ba[b + 1] + ba[b + 2] * 256 + ba[b + 3] * 65536 + ba[b + 4] * 16777216
end
local f32 = require("smollm_gpu:matvec").f32

local function cmp_logits(label, bits, path)
    local ex = file.read_bytes(path)
    local same, maxd, emax, eidx = 0, 0, -math.huge, 0
    for j = 0, 24575 do
        local e = u32_le(ex, j)
        if bits[j] == e then same = same + 1 else
            local d = math.abs(f32(bits[j]) - f32(e))
            if d > maxd then maxd = d end
        end
        local v = f32(e)
        if v > emax then emax, eidx = v, j end
    end
    log(("%s: logits %d/24576 bit-exact vs native C, max |d| %.4g; reference argmax %d"):format(label, same, maxd, eidx))
    return same, eidx
end

function M.run(app)
    probe.app = app or probe.app
    local vp = gui.get_viewport()
    log(("llm start: viewport %sx%s"):format(tostring(vp[1]), tostring(vp[2])))
    M.load()
    local variant = "v2"
    if file.isfile("export:smollm_gpu_variant.txt") then variant = file.read("export:smollm_gpu_variant.txt"):gsub("%s+$", "") end
    local roles = variant == "v1" and M.build_roles(12) or M.build_roles_v2(12)
    log(("variant %s: %d roles"):format(variant, #roles))
    local order = M.setup_frames(#roles)
    M.assign(roles, order)

    -- A: один токен (4 = <|юзер|>) в позиции 0
    M.set_token(4, 0)
    probe.ticks(3)
    local idx = M.argmax()
    local same = cmp_logits("token 4 pos 0", M.logits_bits(), "smollm_gpu:data/proto/logits_pos0.f32")
    log(("token 4 pos 0: GPU argmax %d (native C: 206)"):format(idx))

    -- B: промпты эталона: prefill по токену за кадр, затем генерация argmax до <|я_закончил|> (7)
    local refs = json.parse(file.read("smollm_gpu:data/proto/ref_prompts.json"))
    for _, key in ipairs({ "1", "2" }) do
        local ref = refs[key]
        local toks = ref.prompt_tokens
        local t0, u0 = now(), time.uptime()
        for pos = 0, #toks - 1 do
            M.set_token(toks[pos + 1], pos)
            probe.ticks(1)
        end
        local t1, u1 = now(), time.uptime()
        local first = M.argmax()
        local bits = M.logits_bits()
        local t2 = now()
        cmp_logits("prompt " .. key .. " first reply token", bits, ref.logits)
        local gen, pos = { first }, #toks
        local tg0, ug0 = now(), time.uptime()
        while #gen < #ref.gen and gen[#gen] ~= 7 and pos < 511 do
            M.set_token(gen[#gen], pos)
            probe.ticks(1)
            gen[#gen + 1] = M.argmax()
            pos = pos + 1
        end
        local tg1, ug1 = now(), time.uptime()
        local okn = 0
        for i = 1, #gen do if gen[i] == ref.gen[i] then okn = okn + 1 else break end end
        log(("prompt %s: prefill %d tokens in %.1f ms (%.2f ms/token, uptime %.1f ms), logits readback %.1f ms"):format(
            key, #toks, (t1 - t0) * 1000, (t1 - t0) * 1000 / #toks, (u1 - u0) * 1000, (t2 - t1) * 1000))
        log(("prompt %s: generated %d tokens in %.1f ms = %.1f tok/s (uptime %.1f ms), first %d tokens == reference (of %d)"):format(
            key, #gen - 1, (tg1 - tg0) * 1000, (#gen - 1) / math.max(tg1 - tg0, 1e-9), (ug1 - ug0) * 1000, okn, #ref.gen))
        log(("prompt %s: gpu tokens %s"):format(key, table.concat(gen, " ")))
    end

    -- C: время кадра со всей моделью (каждый кадр пересчитывает токен целиком)
    probe.ticks(5)
    local u0 = time.uptime()
    probe.ticks(120)
    log(("frame with full model pipeline: %.3f ms/frame over 120 frames"):format((time.uptime() - u0) * 1000 / 120))
    M.set_token(206, 40)
    if not file.isfile("export:smollm_gpu_noprofile.txt") then M.profile(60) end
    -- простой: картинки скрыты, чтобы движок не считал модель каждый кадр (GPU общий)
    for _, im in ipairs(M.imgs) do im.el.visible = false end
    log("llm " .. (same == 24576 and "PASS" or "CHECK"))
end

-- ---------------------------------------------------------------- демо для страницы (пункт «Сценарии» -> smollm_gpu)
-- Токены -> текст: data/tokenizer.bin (копия smollm:data/tokenizer.bin; "RSTK", u32 версия, u32 словарь,
-- u32 merges, u32 max_len, затем словарь: u16 длина + байты). Промпты — уже токенизированные эталонные
-- (data/proto/ref_prompts.json): BPE-кодировщика в этом паке нет, свободный ввод — в плане доводки (SMOLLM_GPU.md).
function M.load_vocab()
    if M.vocab then return M.vocab end
    local b = file.read_bytes("smollm_gpu:data/tokenizer.bin")
    local function u16(o) return b[o + 1] + b[o + 2] * 256 end
    local function u32(o) return u16(o) + u16(o + 2) * 65536 end
    local n, o, v = u32(8), 20, {}
    for i = 0, n - 1 do
        local l = u16(o)
        local t = {}
        for k = 1, l do t[k] = string.char(b[o + 2 + k]) end
        v[i] = table.concat(t)
        o = o + 2 + l
    end
    M.vocab = v
    return v
end

function M.decode(toks)
    local v, out = M.load_vocab(), {}
    for _, t in ipairs(toks) do if t ~= 7 then out[#out + 1] = v[t] or ("<" .. t .. ">") end end
    return table.concat(out)
end

-- ---------------------------------------------------------------- конвейер для чата и демо (12.10, llm_gpu_chat)
-- Загрузка весов + роли + порядок фреймов + сборка — один раз на экземпляр (пока живы фреймы). say(text) — прогресс.
function M.ensure_pipeline(app, say)
    probe.app = app or probe.app
    if M.ready then M.wake(); return 0 end
    say = say or function() end
    local t0 = now()
    say("загрузка весов (138 МБ -> 117 текстур)...")
    M.load()
    M.load_vocab()
    local roles = M.build_roles_v2(12)
    local cached = file.isfile("config:gpu_compute_order.json") and file.read("config:gpu_compute_order.json"):find('"sgf/' .. #roles .. '"', 1, true) ~= nil
    say(("веса загружены за %.1f с; %s порядка отрисовки %d фреймов%s..."):format(now() - t0,
        cached and "проверка" or "поиск", #roles, cached and "" or " (~13 с, один раз на экземпляр)"))
    M.setup_frames(#roles)
    M.assign(roles, M.order)
    M.ready = true
    M.awake = true
    local dt = now() - t0
    say(("конвейер готов за %.1f с"):format(dt))
    log(("pipeline ready in %.2f s"):format(dt))
    return dt
end

-- Простой: картинки скрыты, движок не пересчитывает модель каждый кадр. keep_kv — оставить копирование KV-кэша
-- (KA <- KB, KB <- KA, VA <- VB, VB <- VA): скрытый фрейм очищается каждый кадр, без копий кэш пропал бы, а
-- «помнить диалог» продолжает с текущей позиции. KVPUT скрыт (иначе он писал бы нули из очищенного QKV в строку pos).
local function keeps_kv(im)
    return im.mode == MODE.COPYR and (im.src:match("_K[AB]$") or im.src:match("_V[AB]$")) and true or false
end
function M.idle(keep_kv)
    if not M.imgs then return end
    for _, im in ipairs(M.imgs) do im.el.visible = keep_kv and keeps_kv(im) or false end
    M.awake = false
end
function M.wake()
    if not M.imgs or M.awake then return end
    for _, im in ipairs(M.imgs) do im.el.visible = true end
    M.awake = true
end

-- Логиты целиком для семплирования: фрейм LG (768 x 64, float = 2 текселя: RGB — биты 0..23, R следующего — 24..31)
-- одним get_data (Bytearray RGBA, строка 0 = верх, как canvas:at) -> массив float (индекс 0..24575) и, если want_bits,
-- массив битов (для дампа и сверки с C). Быстрее logits_bits(): 1 вызов вместо 49152 canvas:at.
local POW2 = {}
for e = 0, 255 do POW2[e] = 2 ^ (e - 150) end   -- (2^23 + m) * 2^(e-150) = (1 + m/2^23) * 2^(e-127)
function M.logits_f32(out, bits_out)
    local ba = gc.read(M.fid_of.LG, { sync = true })
    -- Bytearray 0.31/0.32 — FFI (cdata): .bytes — указатель uint8 (индекс 0-based, без __index на каждый байт)
    local p, o = ba, 1
    if type(ba) == "cdata" and ba.bytes ~= nil then p, o = ba.bytes, 0 end
    out = out or {}
    for j = 0, 24575 do
        local b = 8 * j + o
        local lo = p[b] + p[b + 1] * 256 + p[b + 2] * 65536
        local hi = p[b + 4]
        local e = (hi % 128) * 2 + (lo >= 8388608 and 1 or 0)
        local m = lo % 8388608
        local v
        if e == 0 then v = m * 2 ^ -149
        elseif e == 255 then v = m == 0 and math.huge or 0 / 0
        else v = (8388608 + m) * POW2[e] end
        out[j] = hi >= 128 and -v or v
        if bits_out then bits_out[j] = lo + hi * 16777216 end
    end
    return out
end

-- биты логитов -> Bytearray float32 LE (дамп export:...f32 для cmp с эталоном C)
function M.bits_to_bytes(bits)
    local ba = Bytearray(24576 * 4)
    for j = 0, 24575 do
        local v = bits[j]
        ba[4 * j + 1] = v % 256
        ba[4 * j + 2] = math.floor(v / 256) % 256
        ba[4 * j + 3] = math.floor(v / 65536) % 256
        ba[4 * j + 4] = math.floor(v / 16777216) % 256
    end
    return ba
end

-- say(text) — строка на страницу; stop() — true, если пользователь ушёл со страницы.
-- Три эталонных промпта (уже токенами, data/proto/ref_prompts.json) с позиции 0: argmax на GPU, сверка с эталоном C.
function M.demo_prompts(say, stop)
    M.wake()
    local refs = json.parse(file.read("smollm_gpu:data/proto/ref_prompts.json"))
    for _, key in ipairs({ "1", "2", "4" }) do
        if stop() then break end
        local ref = refs[key]
        local toks = ref.prompt_tokens
        local p0 = now()
        for pos = 0, #toks - 1 do
            M.set_token(toks[pos + 1], pos)
            probe.ticks(1)
        end
        local p1 = now()
        local first = M.argmax()  -- argmax() возвращает (индекс, биты): в {} попали бы оба
        local gen, pos = { first }, #toks
        local g0 = now()
        while gen[#gen] ~= 7 and pos < 511 and #gen < 64 and not stop() do
            M.set_token(gen[#gen], pos)
            probe.ticks(1)
            gen[#gen + 1] = M.argmax()
            pos = pos + 1
        end
        local g1 = now()
        local okn = 0
        for i = 1, math.min(#gen, #ref.gen) do if gen[i] == ref.gen[i] then okn = okn + 1 else break end end
        local q = M.decode(toks):gsub("<|[^|]*|>", ""):gsub("^%s+", ""):gsub("%s+$", "")
        say("> " .. q)
        say((M.decode(gen):gsub("%s+$", ""):gsub("\226\128\148", "-")))  -- в шрифте движка нет «—»
        say(("   prefill %d ток. %.1f мс/ток; ответ %d ток. %.1f ток/с; совпадает с эталоном C: %d/%d"):format(
            #toks, (p1 - p0) * 1000 / #toks, #gen - 1, (#gen - 1) / math.max(g1 - g0, 1e-9), okn, #ref.gen))
        log(("demo prompt %s: %d/%d tokens == reference, %.1f tok/s"):format(key, okn, #ref.gen, (#gen - 1) / math.max(g1 - g0, 1e-9)))
    end
    M.idle(false)
end

-- Демо целиком (tools/scenarios/smollm_gpu_demo.lua и кнопка «Демо» чата): конвейер + три промпта.
function M.demo(app, say, stop)
    M.ensure_pipeline(app, say)
    M.demo_prompts(say, stop)
    say("готово (конвейер остановлен)")
end

return M
