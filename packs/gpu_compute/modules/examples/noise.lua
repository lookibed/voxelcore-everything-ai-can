-- gpu_compute:examples/noise — пример-клиент API: 3D-шум (value-noise fbm, shaders/gpu_noise.glsl) в текстуру
-- 256x256 и чтение в Lua; сверка нескольких пикселей с тем же шумом на Lua; bench: мс на проход, чтение 256²/1024²,
-- проходов за кадр. Запуск — tools/scenarios/gpu_compute_check.lua (лаборатория: gpu_compute_check.py v031|v032).
local gc = require "gpu_compute:compute"
local M = {}
local now = time.precise_time or os.clock
local function log(s) debug.log("[gpu_compute] " .. s) end

-- ---- тот же шум на Lua (uint32 как в GLSL): умножение по 16-битным половинам
local band, bxor, rshift, tobit = bit.band, bit.bxor, bit.rshift, bit.tobit
local function u32(x) x = x % 4294967296; return x end
local function mul32(a, b)
    a, b = u32(a), u32(b)
    local al, ah = a % 65536, math.floor(a / 65536)
    local lo = al * b                       -- < 2^48: точно в double
    local hi = (ah * (b % 65536)) % 65536   -- старшие 16 бит произведения ah*b по модулю 2^16
    return (lo + hi * 65536) % 4294967296
end
local function ush(x, n) return math.floor(u32(x) / 2 ^ n) end
local function xr(a, b) return u32(bxor(tobit(a), tobit(b))) end
local function hash(x, y, z, seed)
    local h = (mul32(x, 374761393) + mul32(y, 668265263) + mul32(z, 2147483647) + mul32(seed, 144665)) % 4294967296
    h = mul32(xr(h, ush(h, 13)), 1274126177)
    return xr(h, ush(h, 16))
end
local function val(x, y, z, s) return (hash(x, y, z, s) % 65536) / 65535 end
local function mix(a, b, t) return a * (1 - t) + b * t end
local function noise(x, y, z, s)
    local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
    local tx, ty, tz = x - fx, y - fy, z - fz
    local ux, uy, uz = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty), tz * tz * (3 - 2 * tz)
    local a = mix(val(fx, fy, fz, s), val(fx + 1, fy, fz, s), ux)
    local b = mix(val(fx, fy + 1, fz, s), val(fx + 1, fy + 1, fz, s), ux)
    local c = mix(val(fx, fy, fz + 1, s), val(fx + 1, fy, fz + 1, s), ux)
    local d = mix(val(fx, fy + 1, fz + 1, s), val(fx + 1, fy + 1, fz + 1, s), ux)
    return mix(mix(a, b, uy), mix(c, d, uy), uz)
end
local function fbm(x, y, z, oct, seed)
    local s, a, n = 0, 0.5, 0
    for o = 0, oct - 1 do
        s = s + noise(x, y, z, seed + o) * a
        n = n + a; a = a * 0.5
        x, y, z = x * 2, y * 2, z * 2
    end
    return s / n
end
M.fbm = fbm

local W, H = 256, 256
local P = { oct = 5, scale = 1 / 32, z = 0.5, seed = 20261012 }

function M.setup()
    M.prog = gc.program{ id = "noise" }
    M.prm = gc.params{ id = "gcn_params", words = 256 }
    M.pass = gc.pass{ id = "gcn_out", program = M.prog, width = W, height = H, input = M.prm, visible = false }
    return M.pass
end

local function words(t)
    -- значения float32 точно (масштаб 1/32, z 0.5 — представимы), чтобы Lua-шум считался с теми же входами
    return { [1] = P.oct, [2] = { f = P.scale }, [3] = { f = P.z }, [4] = P.seed, [5] = { f = t or 0 }, [6] = W, [7] = H }
end

-- один проход + чтение конвейером (кадр N submit, кадр N+1 read) и сверка с Lua
function M.run(ticks)
    M.setup()
    local serial = gc.submit(M.pass, M.prm, words(0))
    local d0, why = gc.read(M.pass, { serial_texel = W * H - 1 })
    log(("noise: submit serial %d, read in the same frame -> %s (%s)"):format(serial, tostring(d0), tostring(why)))
    ticks(1)
    local data, info = gc.read(M.pass, { serial_texel = W * H - 1 })
    if not data then
        ticks(1)
        data, info = gc.read(M.pass, { serial_texel = W * H - 1 })
    end
    if not data then error("noise: no data after 2 frames: " .. tostring(info)) end
    gc.idle(M.pass)
    -- сверка: строка y get_data = gl_FragCoord.y (строка 0 — низ фрейма), пиксель (x, y) -> fbm(x*s, y*s, z + 0.33c)
    local p, o = gc.codec.raw(data)
    local maxd, n, hist = 0, 0, 0
    for k = 0, 63 do
        local x, y = (k * 37) % W, (k * 101 + 7) % (H - 1)
        local b = (y * W + x) * 4 + o
        local gpu = { p[b], p[b + 1], p[b + 2] }
        for c = 0, 2 do
            local v = fbm(x * P.scale, y * P.scale, P.z + 0.33 * c, P.oct, P.seed)
            local q = math.floor(v * 255 + 0.5)
            local d = math.abs(q - gpu[c + 1])
            if d > maxd then maxd = d end
            if d > 1 then hist = hist + 1 end
            n = n + 1
        end
    end
    local sum = 0
    for i = 0, W * H * 4 - 1, 4 do sum = (sum * 31 + p[i + o] + p[i + o + 1] * 7 + p[i + o + 2] * 13) % 4294967291 end
    log(("noise: 256x256 read ok (read %.3f ms, get_data %.3f ms), %d samples vs Lua fbm: max |d| %d level(s), >1: %d; checksum %d")
        :format(info.read_s * 1000, info.get_data_s * 1000, n, maxd, hist, sum))
    return maxd <= 1, sum
end

-- ---- bench: время кадра с k проходами 256² (картинки показаны) против без них; чтение 256² и 1024²
local function frame_ms(ticks, n)
    ticks(3)
    local u0 = time.uptime()
    ticks(n)
    return (time.uptime() - u0) * 1000 / n
end

function M.bench(ticks)
    local res = {}
    local passes = {}
    local NP = 256
    for i = 1, NP do
        local prm = gc.params{ id = "gcnb_p" .. i, words = 256 }
        local ps = gc.pass{ id = "gcnb_" .. i, program = "noise", width = W, height = H, input = prm, visible = false }
        gc.submit(ps, prm, words(i))
        gc.hide(ps)
        passes[i] = ps
    end
    local base = frame_ms(ticks, 120)
    res.empty_ms = base
    log(("bench: empty frame (%d hidden passes) %.3f ms"):format(NP, base))
    -- кадр движка в аренде упирается в ~6.9 мс (пустой кадр): малые k не видны, цена прохода — по большим k
    for _, k in ipairs({ 1, 8, 32, 128, 256 }) do
        for i = 1, k do gc.show(passes[i]) end
        local ms = frame_ms(ticks, 120)
        for i = 1, k do gc.hide(passes[i]) end
        res["k" .. k] = ms
        log(("bench: %3d passes 256x256 (5-octave fbm x3) per frame: frame %.3f ms -> %.4f ms/pass"):format(k, ms, (ms - base) / k))
    end
    res.per_pass = (res.k256 - base) / 256
    res.fit_16ms = res.per_pass > 0 and math.floor((16.7 - base) / res.per_pass) or -1
    log(("bench: pass cost %.4f ms (k=256), passes that fit a 60 fps frame (16.7 ms) over the empty frame: %d"):format(res.per_pass, res.fit_16ms))
    -- чтение: проход 256² (конвейер — в следующем кадре, без ожидания GPU) и текстура 1024² (canvas)
    gc.show(passes[1])
    local tr, tg, n = 0, 0, 30
    for i = 1, n do
        ticks(1)
        local _, info = gc.read(passes[1].id)
        tr, tg = tr + info.read_s, tg + info.get_data_s
    end
    gc.hide(passes[1])
    res.read256 = tr * 1000 / n
    log(("bench: read 256x256 pass (next frame): to_canvas %.3f ms, get_data %.3f ms (avg of %d)"):format(tr * 1000 / n, tg * 1000 / n, n))
    local big = gc.buffer{ id = "gcnb_big", width = 1024, rows = 1024 }
    ticks(2)
    tr, tg = 0, 0
    for i = 1, 10 do
        ticks(1)
        local _, info = gc.read("gcnb_big")
        tr, tg = tr + info.read_s, tg + info.get_data_s
    end
    res.read1024 = tr * 100
    log(("bench: read 1024x1024 texture: to_canvas %.3f ms, get_data %.3f ms (avg of 10)"):format(tr * 100, tg * 100))
    -- синхронное чтение сразу после кадра с 32 проходами (ждёт GPU)
    for i = 1, NP do gc.show(passes[i]) end
    ticks(2)
    local t0 = now()
    gc.read(passes[NP], { sync = true, canvas = true })
    res.sync_after = (now() - t0) * 1000
    for i = 1, NP do gc.hide(passes[i]) end
    log(("bench: sync read right after a frame with %d passes: %.3f ms (GPU wait)"):format(NP, res.sync_after))
    return res
end

return M
