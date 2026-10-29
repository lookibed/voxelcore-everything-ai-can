-- Бенчмарк пака doom: -timedemo demo1 без вывода на экран, кадры/с по отрезкам. Метка: [doom_timedemo].
-- Демо доходит до конца примерно за 5000 тиков; хватит и первых MAX_TICKS.
local MAX_TICKS = 1400
local SEGMENT = 200

app.config_packs({"doom"})
app.load_content()
local function log(m) debug.log("[doom_timedemo] " .. m) end

local wasm_host = require "doom:wasm_host"
local t0 = os.clock()
local e = wasm_host.load_generated("doom:modules/doom/doom.lua")()
local mem = e.memory[1]
log(("instantiate %.2fs"):format(os.clock() - t0))

e._initialize()
local wad = file.read_bytes("doom:wads/doom1.wad")
local p = e.dgv_alloc(#wad)
wasm_host.write_bytes(mem, p, wad)
t0 = os.clock()
local ok, err = pcall(e.dgv_init, p, #wad, 1)
log(("init %s %.2fs"):format(ok and "ok" or tostring(err), os.clock() - t0))

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
log(("frames=%d %.2fs -> %.1f frames/s | per %d ticks: %s | stop=%s"):format(
    e.dgv_frame_count(), dt, e.dgv_frame_count() / dt, SEGMENT, table.concat(segments, " "), tostring(err)))
log("done")
