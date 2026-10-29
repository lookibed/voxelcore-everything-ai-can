-- Замер памяти Spider на Doom без вывода на экран (как doom_timedemo.lua): -timedemo demo1 через dgv_*
-- модуля doom.lua (doomgeneric + src/dg_voxelcore.c), память в таблице слов (export:membench/doom_tbl.lua)
-- против Bytearray (export:membench/doom_ba.lua). Модули: Spider Hosts/VoxelCore/pipeline/membench.sh
-- translate doomlib && membench.sh install doomlib. Метка [membench_doom], конец — "[membench_doom] done".
--
-- Порядок вариантов — export:membench/doom_run.txt (по умолчанию "tbl ba tbl ba"). Перед каждым прогоном
-- jit.flush и снятие чёрного списка; JIT — как wasmrt ("jit": "tuned"), в конце — значения по умолчанию.
-- Кадры/с по отрезкам SEGMENT тиков; сумма экрана в конце должна совпасть у обоих вариантов.

app.config_packs({ "doom" })
app.load_content()

local MAX_TICKS, SEGMENT = 1400, 200
local variants = { "tbl", "ba", "tbl", "ba" }
if file.isfile("export:membench/doom_run.txt") then
    variants = {}
    for v in file.read("export:membench/doom_run.txt"):gmatch("%S+") do variants[#variants + 1] = v end
end

local function log(m) debug.log("[membench_doom] " .. m) end

local env = setmetatable({ require = function(name)
    if name == "bit" then return bit end
    error("module not found: " .. tostring(name))
end }, { __index = _G })

local chunks = {}
local function loader_of(variant)
    local path = "export:membench/doom_" .. variant .. ".lua"
    if not chunks[variant] then
        local chunk = assert(loadstring(file.read(path), "=" .. path))
        setfenv(chunk, env)
        chunks[variant] = { chunk = chunk, loader = chunk() }
    end
    return chunks[variant]
end

local wad = file.read_bytes("doom:wads/doom1.wad")
local wad_string = Bytearray_as_string(wad)

local function run(variant)
    local m = loader_of(variant)
    jit.flush()
    jit.on(m.chunk, true)
    local t0 = os.clock()
    local e = m.loader({})
    e._initialize()
    local p = e.dgv_alloc(#wad_string)
    e.__host.write_string(e.memory, p, wad_string)
    local ok, err = pcall(e.dgv_init, p, #wad_string, 1)
    local init = os.clock() - t0
    if not ok then error("init: " .. tostring(err)) end

    local start = os.clock()
    local ticks, seg_t, seg_f, segments = 0, os.clock(), 0, {}
    while ok and ticks < MAX_TICKS do
        ok, err = pcall(e.dgv_tick, math.floor((os.clock() - start) * 1000))
        if ok then ticks = ticks + 1 end
        if ticks % SEGMENT == 0 then
            local f = e.dgv_frame_count()
            segments[#segments + 1] = ("%.0f"):format((f - seg_f) / (os.clock() - seg_t))
            seg_t, seg_f = os.clock(), f
        end
    end
    local dt = os.clock() - start
    local ptr, size = e.dgv_screen_ptr(), e.dgv_screen_width() * e.dgv_screen_height()
    local sum, read_u8, memory = 0, e.__host.read_u8, e.memory
    for i = 0, size - 1 do sum = (sum * 31 + read_u8(memory, ptr + i)) % 2147483647 end
    return ("init %.2fs, frames=%d %.2fs -> %.1f frames/s | per %d ticks: %s | stop=%s | screen sum %d"):format(
        init, e.dgv_frame_count(), dt, e.dgv_frame_count() / dt, SEGMENT, table.concat(segments, " "),
        tostring(err), sum)
end

jit.opt.start("-loop", "maxtrace=8000", "maxmcode=65536", "hotexit=200")
log("start: variants " .. table.concat(variants, " "))
for _, variant in ipairs(variants) do
    local ok, result = pcall(run, variant)
    log(("%s: %s"):format(variant, ok and result or ("FAIL " .. tostring(result))))
    collectgarbage("collect")
end
jit.opt.start("+loop", "maxtrace=1000", "maxmcode=2048", "hotexit=10")
log("done")
