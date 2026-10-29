-- Разведка «LLM на GPU» (пак smollm_gpu, agents/research/SMOLLM_GPU.md): пробы при старте движка, без мира.
--   LAB_OWNER=llm_gpu tools/lab/lab lease wasmrt engine_rt --param script=smollm_gpu_probe.lua \
--       --param 'packs=["smollm_gpu"]' --param 'ready_marker=\[sg\] ready' [--param engine=v032] --start
-- export:smollm_gpu_probe.txt (в --dir экземпляра) выбирает пробы: "q12" (по умолчанию) — чтение пикселей и порядок
-- фреймов; "matvec" — прототип матвека и точная арифметика;
-- "llm" — вся модель на GPU (логиты и токены против эталона, ток/с); "all". Маркеры: [sg] ready, [sg] probe done.
app.config_packs({ "smollm_gpu" })
app.load_content()
app.tick()
debug.log("[sg] ready")
local what = "q12"
if file.isfile("export:smollm_gpu_probe.txt") then
    what = file.read("export:smollm_gpu_probe.txt"):gsub("%s+$", "")
end
local probe = require("smollm_gpu:probe")
local ok, err = pcall(function()
    if what == "q12" or what == "all" then probe.run_q12(app) end
    if what == "matvec" or what == "all" then require("smollm_gpu:matvec").run(app) end
    if what == "llm" or what == "all" then require("smollm_gpu:llm").run(app) end
end)
if not ok then debug.log("[sg] error: " .. tostring(err)) end
debug.log("[sg] probe done")
