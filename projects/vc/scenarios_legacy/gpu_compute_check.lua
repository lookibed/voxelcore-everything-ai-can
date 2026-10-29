-- Проверка пака gpu_compute при старте движка (без мира): пример examples/noise (проход 256x256, чтение конвейером,
-- сверка с Lua), bench (мс на проход, чтение 256²/1024², проходов за кадр), проба порядка фреймов (gc.chain) и пробы
-- «можно ли подключать программы на лету» (Lua API шейдеров, запись в каталог пака).
--   lab lease wasmrt engine_rt --param script=gpu_compute_check.lua --param 'packs=["gpu_compute"]' \
--       --param 'ready_marker=\[gpu_compute\] ready' [--param engine=v032] --start      (tools/scenarios/gpu_compute_check.py)
-- Маркеры: [gpu_compute] ready | ... | [gpu_compute] done | [gpu_compute] error: ...
app.config_packs({ "gpu_compute" })
app.load_content()
app.tick()
local function log(s) debug.log("[gpu_compute] " .. s) end
log("ready")
local function ticks(n) for _ = 1, n or 1 do app.tick() end end
local ok, err = pcall(function()
    local gc = require "gpu_compute:compute"
    local vp = gui.get_viewport()
    local lim = gc.limits()
    log(("viewport %dx%d, limits: max pass %dx%d, inputs %d, out %s"):format(vp[1], vp[2], lim.max_pass_w, lim.max_pass_h, lim.inputs, lim.out))
    local progs = {}
    for k, p in pairs(gc.programs()) do progs[#progs + 1] = ("%s=#%02X%02X..%02X(%s)"):format(k, p.bank, p.g0, p.g1, p.pack) end
    table.sort(progs)
    log("programs in ui.glslf: " .. table.concat(progs, " "))
    -- (а) подключение на лету: есть ли в Lua загрузка/перезагрузка шейдера и можно ли писать в каталог пака
    local shader_api = {}
    for _, lib in ipairs({ "assets", "gfx", "gui", "app", "core" }) do
        local t = _G[lib]
        if type(t) == "table" then
            for k in pairs(t) do if tostring(k):lower():find("shader") then shader_api[#shader_api + 1] = lib .. "." .. k end end
        end
    end
    log("lua shader api: " .. (#shader_api > 0 and table.concat(shader_api, ", ") or "none"))
    local w1 = file.is_writeable and file.is_writeable("gpu_compute:shaders/ui.glslf")
    local w2 = pcall(file.write, "gpu_compute:shaders/gc_probe.txt", "x")
    log(("pack dir writeable: is_writeable=%s, write=%s"):format(tostring(w1), tostring(w2)))
    -- пример
    local noise = require "gpu_compute:examples/noise"
    local okn, sum = noise.run(ticks)
    log("example noise " .. (okn and "PASS" or "FAIL") .. " checksum " .. tostring(sum))
    -- цепочка: порядок 64 фреймов (проба + проверка INC), повторный вызов — из кеша
    local ch = gc.chain{ id = "gcchk", n = 64, ticks = ticks }
    log(("chain 64: cached %s, %.2f s"):format(tostring(ch.info.cached), ch.info.seconds))
    local ch2 = gc.chain{ id = "gcchk", n = 64, ticks = ticks }
    log(("chain 64 again: cached %s, %.2f s"):format(tostring(ch2.info.cached), ch2.info.seconds))
    local res = noise.bench(ticks)
    log(("bench summary: empty %.3f ms; frame with 1/8/32/128/256 passes %.2f/%.2f/%.2f/%.2f/%.2f ms; pass 256x256 %.4f ms, fit in 16.7 ms: %d; read 256 %.3f ms, 1024 %.3f ms; sync after 256 passes %.3f ms")
        :format(res.empty_ms, res.k1, res.k8, res.k32, res.k128, res.k256, res.per_pass, res.fit_16ms,
            res.read256, res.read1024, res.sync_after))
end)
if not ok then log("error: " .. tostring(err)) end
log("done")
