-- Проверка сохранения: мир gpu_worldgen создаётся, ждём простоя конвейера, мир закрывается с сохранением и
-- открывается снова — заполненные чанки не должны вставать в очередь (done.txt мира), блоки — те же.
-- Маркеры: [gpu_worldgen] ready ... reopen: ... | done
app.config_packs({ "base", "gpu_worldgen" })
app.load_content()
local launch = require "gpu_worldgen:launch"
local gen = require "gpu_worldgen:gen"
local function log(s) debug.log("[gpu_worldgen] " .. s) end
launch.open(app, { world = "gpuwg_reopen", fresh = true, load_distance = 4 })
app.sleep_until(function() return gen.done_count() > 0 and gen.idle() end, 1e9, 120)
app.sleep(1)
local n1, b1 = gen.done_count(), block.get(8, 40, 8)
local h1 = gen.hash_of(0, 0)
log(("reopen: before close done %d, block(8,40,8) %d"):format(n1, b1))
app.close_world(true)
app.sleep(1)
launch.open(app, { world = "gpuwg_reopen", load_distance = 4 })
app.sleep(3)
-- после close_world/open_world контент перезагружен: мир работает с новым экземпляром модуля, ссылка выше устарела
local gen2 = require "gpu_worldgen:gen"
log(("reopen: module instance %s, new instance: done %d, queue %d, written %d"):format(gen2 == gen and "same" or "new",
    gen2.done_count(), gen2.queue_count(), gen2.total.chunks))
gen = gen2
log(("reopen: after open done %d (from save), queue %d, written this session %d, block(8,40,8) %d (was %d)")
    :format(gen.done_count(), gen.queue_count(), gen.total.chunks, block.get(8, 40, 8), b1))
log("done")
