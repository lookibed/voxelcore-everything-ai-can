-- F2F perf/trace test world (probe: F2F client, cases perf_world).
-- Same scene as ../f2fworld (base:demo, seed 42, frozen day, player in flight at (8,130,8),
-- small structure with glass/water/lamp), world "f2f_perf". After setup the app coroutine
-- keeps running one iteration per frame: while F2F `perf` tracing is on it does a fixed
-- amount of Lua work and reports it with f2f.trace_event (X + C events on the "lua" track),
-- so Lua and engine phases can be checked to align in one trace.
-- Handler: state -> {ready, chunks, pos, rot, lua_frames}; build; be {name} -> B/E pair.
local WORLD = "f2f_perf"
app.config_packs({"base"})
app.load_content()
if file.isfile("user:worlds/" .. WORLD .. "/world.json") then
    app.open_world(WORLD)
else
    app.new_world(WORLD, "42", "base:demo")
end
world.set_day_time(0.5)
world.set_day_time_speed(0)
local pid = 0
player.set_flight(pid, true)
player.set_noclip(pid, true)
player.set_pos(pid, 8.5, 130, 8.5)
player.set_vel(pid, 0, 0, 0)
player.set_rot(pid, 0, -15, 0)

local function build()
    local stone = block.index("base:stone")
    local planks = block.index("base:planks")
    local grass = block.index("base:grass_block")
    local glass = block.index("base:glass")
    local water = block.index("base:water")
    local lamp = block.index("base:lamp")
    for x = 4, 13 do
        for z = 1, 6 do
            block.set(x, 126, z, stone, 0)
        end
        for y = 127, 131 do
            block.set(x, y, 1, (x + y) % 2 == 0 and planks or grass, 0)
        end
    end
    block.set(7, 127, 4, glass, 0)
    block.set(8, 127, 4, water, 0)
    block.set(9, 127, 4, water, 0)
    block.set(10, 127, 3, lamp, 0)
    block.set(8, 128, 5, stone, 0)
end

-- older F2F builds (VoxelCoreF2F-prev2.exe) have no trace API
local trace_active = f2f.trace_active or function() return false end
local ready = false
local lua_frames = 0
f2f.set_handler(function(cmd, args)
    if cmd == "state" then
        local x, y, z = player.get_pos(pid)
        local yaw, pitch = player.get_rot(pid)
        return {ready = ready, chunks = world.count_chunks(), pos = {x, y, z}, rot = {yaw, pitch},
                lua_frames = lua_frames, trace_active = trace_active()}
    elseif cmd == "build" then
        build()
        player.set_pos(pid, 8.5, 130, 8.5)
        player.set_rot(pid, 0, -35, 0)
        return {built = true}
    elseif cmd == "mode" then
        return {lua_frames = lua_frames}
    elseif cmd == "be" then
        local name = args.name or "pack:handler"
        local b = f2f.trace_event(name, "B", {from = "handler"})
        local s = 0
        for i = 1, 100000 do s = s + i % 7 end
        local e = f2f.trace_event(name, "E")
        return {b = b, e = e, s = s}
    end
    error("unknown-command: " .. tostring(cmd))
end)
ready = true
print("[f2f-perf] ready")

while true do
    if trace_active() then
        local t0 = f2f.now_us()
        local s = 0
        for i = 1, 20000 do s = s + (i * 31) % 17 end
        lua_frames = lua_frames + 1
        f2f.trace_event("pack:frame_work", "X", {frame = lua_frames, s = s}, t0)
        f2f.trace_event("pack:counter", "C", {lua_frames = lua_frames})
    end
    app.tick()
end
