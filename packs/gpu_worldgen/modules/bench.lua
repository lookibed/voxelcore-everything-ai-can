-- gpu_worldgen:bench — замеры и сверки (вызывать из корутины app-скрипта: tick = app.tick, один кадр движка).
--   readback(tick)        — цена чтения текстуры фрейма 256x256 и 1024x1024: assets.to_canvas, get_data,
--                           gui.screenshot(frame) (0.32) и gui.screenshot() окна (0.32)
--   density(tick, x, z)   — плотность GPU (mode 1) против noise.density: max |d|, расхождения знака
--   parity(list)          — коды блоков GPU (gen.codes, keep_codes) против CPU-референса: число несовпадений,
--                           мс CPU на чанк
local noise = require "gpu_worldgen:noise"
local gpu = require "gpu_worldgen:gpu"
local gen = require "gpu_worldgen:gen"

local M = {}
local now = time.precise_time or os.clock
local log = gen.log

local function timeit(n, fn)
    fn()
    local t0 = now()
    for _ = 1, n do fn() end
    return (now() - t0) / n * 1000
end

function M.readback(tick)
    local out = {}
    for _, sz in ipairs({ 256, 1024 }) do
        local id = "gpuwg_rb" .. sz
        local root = gui.create_frame(id, id, { sz, sz })
        root:add(('<image src="%s" pos="0,0" size="%d,%d"/>'):format(gpu.PARAMS, sz, sz))
        tick(); tick()
        local n = sz == 256 and 50 or 10
        local cv
        local t_to = timeit(n, function() cv = assets.to_canvas(id) end)
        local t_get = timeit(n, function() return cv:get_data() end)
        local t_at = timeit(n, function()
            local s = 0
            for i = 0, sz * 4 - 1 do s = s + cv:at(i % sz, math.floor(i / sz)) end
            return s
        end) / (sz * 4)
        local line = ("readback %dx%d (%.2f MB): assets.to_canvas %.3f ms, canvas:get_data %.3f ms, canvas:at %.4f us/px")
            :format(sz, sz, sz * sz * 4 / 1048576, t_to, t_get, t_at * 1000)
        if gui.screenshot then
            local t_sf = timeit(n, function() return gui.screenshot(id) end)
            line = line .. (", gui.screenshot(frame) %.3f ms"):format(t_sf)
        end
        log(line)
        out[sz] = { to_canvas = t_to, get_data = t_get }
        root:clear()
    end
    if gui.screenshot then
        local vp = gui.get_viewport()
        local t_sw = timeit(10, function() return gui.screenshot() end)
        log(("readback window %dx%d RGB: gui.screenshot() %.3f ms"):format(vp[1], vp[2], t_sw))
    else
        log("readback: gui.screenshot нет (0.31) — только assets.to_canvas")
    end
    return out
end

-- цена GPU-прохода: средняя длительность кадра без пакета и с пакетом из n плиток каждый кадр (+ чтение FBO)
function M.gpu_cost(tick, frames, n)
    local P = gen.params()
    n = math.min(n or gpu.max_tiles, gpu.max_tiles)
    local list = {}
    for i = 0, n - 1 do list[#list + 1] = { i % 8 - 4, math.floor(i / 8) - 4 } end
    local function run(k)
        -- без пакета проход скрыт, как в генерации между пакетами (иначе картинки с прошлого прогона рисуются впустую)
        if k == 0 then gpu.rle_hide() end
        tick()
        local t0 = now()
        local worst = 0
        local tp = t0
        for _ = 1, frames do
            if k > 0 then
                gpu.read()
                gpu.pending = nil
                gpu.submit(list, P, 0, gen.preset_desc())
            end
            tick()
            local t = now()
            if t - tp > worst then worst = t - tp end
            tp = t
        end
        local data = k > 0 and gpu.read()
        gpu.pending = nil
        return (now() - t0) / frames * 1000, worst * 1000, data ~= nil
    end
    local base, bw = run(0)
    local load, lw, got = run(n)
    local base2 = run(0)
    local b = (base + base2) / 2
    log(("gpu_cost: frame %.3f ms idle (%.3f / %.3f), %.3f ms with %d chunk tiles + readback %dx%d each frame (worst %.1f ms, last read ok %s) -> %.4f ms/chunk GPU+readback"):format(
        b, base, base2, load, n, gpu.W, gpu.H, lw, tostring(got), (load - b) / n))
    return (load - b) / n
end

-- GPU-плотность одного чанка против CPU. Генерация должна стоять (gen.pause), gpu.pending пуст.
function M.density(tick, x, z)
    local P = gen.params()
    noise.use(P)
    gpu.submit({ { x, z } }, P, 1)
    local data
    for _ = 1, 30 do
        tick()
        data = gpu.read()
        if data then break end
    end
    if not data then
        log("density: GPU did not answer in 30 frames")
        return nil
    end
    local dens = gpu.decode_density(data, 0, math.floor(gpu.W / gpu.DW), {})
    local maxd, sumd, sign, near, n = 0, 0, 0, 0, 0
    local t0 = now()
    for y = 0, 255 do
        for zz = 0, 15 do
            for xx = 0, 15 do
                local c = noise.density(x * 16 + xx, y, z * 16 + zz)
                local g = dens[(y * 16 + zz) * 16 + xx]
                local d = math.abs(c - g)
                if d > maxd then maxd = d end
                sumd = sumd + d
                n = n + 1
                if (c > 0) ~= (g > 0) then sign = sign + 1 end
                if math.abs(c) < 1e-4 then near = near + 1 end
            end
        end
    end
    local t_cpu = now() - t0
    log(("density chunk %d,%d: %d voxels, max |GPU-CPU| %.3g, mean %.3g (quantum 2^-20 = %.3g), sign mismatches %d, |d|<1e-4 %d; CPU density %.2f ms/chunk")
        :format(x, z, n, maxd, sumd / n, 2 ^ -20, sign, near, t_cpu * 1000))
    return { max = maxd, mean = sumd / n, sign = sign, near = near }
end

-- коды GPU (gen.codes) против CPU-референса
function M.parity(list)
    local P = gen.params()
    noise.use(P)
    local total, diff, t = 0, 0, 0
    local byc = {}
    local codes = {}
    for _, c in ipairs(list) do
        local k = gen.key(c[1], c[2])
        local g = gen.codes[k]
        if g then
            local t0 = now()
            noise.chunk_codes(c[1], c[2], codes)
            t = t + (now() - t0)
            local d = 0
            for i = 0, 65535 do
                if codes[i] ~= g[i] then
                    d = d + 1
                    local kk = codes[i] .. "->" .. g[i]
                    byc[kk] = (byc[kk] or 0) + 1
                end
            end
            total = total + 65536
            diff = diff + d
            log(("parity chunk %s: %d / 65536 voxels differ (CPU %.1f ms)"):format(k, d, (now() - t0) * 1000))
        else
            log("parity chunk " .. k .. ": no GPU codes kept")
        end
    end
    local parts = {}
    for kk, v in pairs(byc) do parts[#parts + 1] = kk .. ":" .. v end
    table.sort(parts)
    local n = #list
    log(("parity total: %d / %d voxels differ (%.5f %%), cpu->gpu codes {%s}, CPU reference %.1f ms/chunk")
        :format(diff, total, total > 0 and diff / total * 100 or 0, table.concat(parts, " "), n > 0 and t / n * 1000 or 0))
    return diff, total
end

return M
