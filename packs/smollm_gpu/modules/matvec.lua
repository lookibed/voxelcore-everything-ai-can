-- smollm_gpu:matvec — прототип матвека Q8 на GPU (вопрос 4 разведки, agents/research/SMOLLM_GPU.md).
-- Страницы линейной памяти (data/proto/*.rgba, 768x480 RGBA, 3 байта данных на тексель, A=255) собраны
-- prep_proto.py (Spider tests/manual/real-world-smollm-gpu) из model_q8.bin и нативного дампа слоя 0 (dump.c):
--   w1 (768 -> 2048, 2 страницы по 1024 строки), w2 (2048 -> 768, 2 страницы по 384 строки).
-- Выход — фрейм GUI: картинка страницы с маркером MATVEC (ui.glslf, режимы 10/11), параметры — region="P,Q,P,Q".
-- Проверка: биты float32 выхода против data/proto/*_expect.f32 (нативный C, MATMUL=1); время прохода — по кадрам движка.
local probe = require("smollm_gpu:probe")
local M = {}

local function log(s) debug.log("[sg] " .. s) end
local now = time.precise_time or os.clock

local function rgb24(v) return v % 16777216 end

local function f32(bits)
    local s = bits >= 2147483648 and -1 or 1
    local e = math.floor(bits / 8388608) % 256
    local m = bits % 8388608
    if e == 0 then return s * m * 2 ^ -149 end
    if e == 255 then return m == 0 and s * math.huge or 0 / 0 end
    return s * (1 + m / 8388608) * 2 ^ (e - 127)
end
M.f32 = f32

local function u32_le(ba, i)  -- i: 0-based индекс слова
    local b = i * 4
    return ba[b + 1] + ba[b + 2] * 256 + ba[b + 3] * 65536 + ba[b + 4] * 16777216
end
M.u32_le = u32_le

local function load_page(path, name, w, h)
    local t0 = now()
    local ba = file.read_bytes(path)
    local t1 = now()
    local c = Canvas({ w, h })
    c:set_data(ba)
    local t2 = now()
    c:create_texture(name)
    local t3 = now()
    return c, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000
end
M.load_page = load_page

local function region(p, q) return ("%d,%d,%d,%d"):format(p, q, p, q) end

local function mv_img(tex, mode, x, y, w, h, p, q)
    return ('<image src="%s" pos="%d,%d" size="%d,%d" color="#FF%02XFF80" region="%s"/>'):format(
        tex, x, y, w, h, mode, region(p, q))
end
M.mv_img = mv_img

-- выход матвека: список float из фрейма шириной ow, n значений
local function read_vec(tex, ow, n)
    local c = assets.to_canvas(tex)
    local bits = {}
    for j = 0, n - 1 do
        local t = j * 2
        local lo = rgb24(c:at(t % ow, math.floor(t / ow)))
        local hi = rgb24(c:at((t + 1) % ow, math.floor((t + 1) / ow))) % 256
        bits[j] = lo + hi * 16777216
    end
    return bits
end
M.read_vec = read_vec

local function compare(label, bits, expect_path, n)
    local ex = file.read_bytes(expect_path)
    local same, maxd, maxrel, first = 0, 0, 0, nil
    for j = 0, n - 1 do
        local e = u32_le(ex, j)
        if bits[j] == e then
            same = same + 1
        else
            local a, b = f32(bits[j]), f32(e)
            local d = math.abs(a - b)
            if d > maxd then maxd = d end
            local rel = d / math.max(math.abs(b), 1e-30)
            if rel > maxrel then maxrel = rel end
            first = first or ("j=%d gpu %.9g (%08x) C %.9g (%08x)"):format(j, a, bits[j], b, e)
        end
    end
    log(("matvec %s: %d/%d outputs bit-exact vs native C, max |d| %.3g, max rel %.3g %s"):format(
        label, same, n, maxd, maxrel, first or ""))
    return same == n
end

-- кадров в секунду / мс на кадр за n тиков (time.uptime — начало кадра)
local function frame_ms(n)
    probe.ticks(2)
    local t0 = time.uptime()
    local c0 = now()
    probe.ticks(n)
    return (time.uptime() - t0) * 1000 / n, (now() - c0) * 1000 / n
end

-- точная арифметика шейдера (fp64) против C: 4096 значений на операцию
function M.run_math()
    local frame, ticks = probe.frame, probe.ticks
    local _, tr = load_page("smollm_gpu:data/proto/math_in.rgba", "sg_mt_in", 768, 22)
    local n, ops = 4096, { 20, 21, 22, 23, 24, 25, 26, 27 }
    local names = { [20] = "a/b fp64", [21] = "sqrtf fp64", [22] = "fm_expf fp64", [23] = "1/sqrtf fp64",
        [24] = "SiLU fp64", [25] = "a/b float GLSL", [26] = "sqrt float GLSL", [27] = "exp float GLSL" }
    local refop = { [20] = 0, [21] = 1, [22] = 2, [23] = 3, [24] = 4, [25] = 0, [26] = 1, [27] = 2 }
    local H = 16 * #ops
    local parts = {}
    for k, op in ipairs(ops) do
        parts[#parts + 1] = mv_img("sg_mt_in", op, 0, H - 16 * k, 512, 16, 16 * (k - 1) * 512, 8 * 65536)
    end
    frame("sg_mt", 512, H, "<container size='512," .. H .. "'>" .. table.concat(parts) .. "</container>")
    ticks(3)
    local c = assets.to_canvas("sg_mt")
    local ex = file.read_bytes("smollm_gpu:data/proto/math_expect.f32")
    local all_exact = true
    for k, op in ipairs(ops) do
        local same, maxulp, first = 0, 0, nil
        for i = 0, n - 1 do
            local t = 16 * (k - 1) * 512 + i * 2
            local lo = rgb24(c:at(t % 512, math.floor(t / 512)))
            local hi = rgb24(c:at((t + 1) % 512, math.floor((t + 1) / 512))) % 256
            local g = lo + hi * 16777216
            local e = u32_le(ex, refop[op] * n + i)
            if g == e then same = same + 1 else
                local d = math.abs(g - e)
                if d > maxulp then maxulp = d end
                first = first or ("i=%d gpu %.9g C %.9g"):format(i, f32(g), f32(e))
            end
        end
        if op <= 24 and same ~= n then all_exact = false end
        log(("math %-16s %4d/%d bit-exact vs C, max diff %d ulp %s"):format(names[op], same, n, maxulp, first or ""))
    end
    frame("sg_mt", 4, 4, nil)
    return all_exact
end

function M.run(app)
    probe.app = app or probe.app
    local frame, ticks = probe.frame, probe.ticks
    local okm, em = pcall(M.run_math)
    if not okm then log("math error: " .. tostring(em)) end
    local vp = gui.get_viewport()
    log(("matvec start: viewport %sx%s"):format(tostring(vp[1]), tostring(vp[2])))

    -- загрузка страниц
    local pages = {}
    for _, nm in ipairs({ "w1_p0", "w1_p1", "w2_p0", "w2_p1" }) do
        local c, tr, ts, tt = load_page("smollm_gpu:data/proto/" .. nm .. ".rgba", "sg_" .. nm, 768, 480)
        pages[nm] = c
        log(("load %s: read_bytes %.1f ms, set_data %.1f ms, create_texture %.1f ms (1.47 MB)"):format(nm, tr, ts, tt))
    end
    M.pages = pages

    -- параметры через region: проба (текстура должна существовать — иначе UV пересчитаются в регион запасной)
    frame("sg_echo", 2, 1, mv_img("sg_w1_p0", 3, 0, 0, 2, 1, 12345, 678901))
    ticks(2)
    local ce = assets.to_canvas("sg_echo")
    log(("echo: region P=12345 Q=678901 -> shader saw P=%d Q=%d"):format(rgb24(ce:at(0, 0)), rgb24(ce:at(1, 0))))

    -- w1: 2048 выходов, фрейм 512x8; страница 0 -> строки FBO 0..3 (локальные y 4..7), страница 1 -> 4..7 (y 0..3)
    local P1, P2 = 1024 + 12 * 4096, 384 + 32 * 4096
    local function w1_xml(mode)
        return "<container size='512,8'>" ..
            mv_img("sg_w1_p0", mode, 0, 4, 512, 4, P1, 0 + 8 * 65536) ..
            mv_img("sg_w1_p1", mode, 0, 0, 512, 4, P1, 1024 + 8 * 65536) .. "</container>"
    end
    local function w2_xml(mode)
        return "<container size='256,6'>" ..
            mv_img("sg_w2_p0", mode, 0, 3, 256, 3, P2, 0 + 4 * 65536) ..
            mv_img("sg_w2_p1", mode, 0, 0, 256, 3, P2, 384 + 4 * 65536) .. "</container>"
    end
    frame("sg_mv1", 512, 8, w1_xml(10))
    frame("sg_mv1b", 512, 8, w1_xml(11))
    frame("sg_mv2", 256, 6, w2_xml(10))
    frame("sg_mv2b", 256, 6, w2_xml(11))
    ticks(3)
    local ok = true
    ok = compare("w1 768->2048 (mode 10, fma allowed)", read_vec("sg_mv1", 512, 2048), "smollm_gpu:data/proto/w1_expect.f32", 2048) and ok
    ok = compare("w1 768->2048 (mode 11, product materialized)", read_vec("sg_mv1b", 512, 2048), "smollm_gpu:data/proto/w1_expect.f32", 2048) and ok
    ok = compare("w2 2048->768 (mode 10)", read_vec("sg_mv2", 256, 768), "smollm_gpu:data/proto/w2_expect.f32", 768) and ok
    ok = compare("w2 2048->768 (mode 11)", read_vec("sg_mv2b", 256, 768), "smollm_gpu:data/proto/w2_expect.f32", 768) and ok

    -- время: K копий полного матвека в одном фрейме (перерисовка поверх, каждый фрагмент считается заново)
    frame("sg_mv1", 512, 8, nil)
    frame("sg_mv1b", 512, 8, nil)
    frame("sg_mv2", 256, 6, nil)
    frame("sg_mv2b", 256, 6, nil)
    local base_ms, base_cpu = frame_ms(120)
    log(("bench frame: idle %.3f ms/frame (cpu clock %.3f)"):format(base_ms, base_cpu))
    for _, spec in ipairs({ { "w1", 512, 8, w1_xml }, { "w2", 256, 6, w2_xml } }) do
        local name, fw, fh, xml = spec[1], spec[2], spec[3], spec[4]
        for _, k in ipairs({ 1, 8, 32, 128 }) do
            local parts = {}
            for _ = 1, k do parts[#parts + 1] = xml(11) end
            frame("sg_mvbench", fw, fh, "<container size='" .. fw .. "," .. fh .. "'>" .. table.concat(parts) .. "</container>")
            local ms = frame_ms(k >= 128 and 30 or 60)
            log(("bench %s x%d per frame: %.3f ms/frame -> %.4f ms per matvec over idle"):format(
                name, k, ms, (ms - base_ms) / k))
            -- чтение результата сразу после тяжёлого кадра: ожидание GPU (синхронизация) + glGetTexImage
            local t0 = now()
            assets.to_canvas("sg_mvbench")
            log(("bench %s x%d: to_canvas right after frame %.3f ms"):format(name, k, (now() - t0) * 1000))
        end
    end
    frame("sg_mvbench", 4, 4, nil)
    log("matvec " .. (ok and "PASS" or "FAIL"))
end

return M
