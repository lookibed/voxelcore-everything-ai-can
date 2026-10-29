-- F2F render-layer test world (probe: F2F client, cases layers).
-- Opens/creates world "f2f_render" (base:demo, seed 42), freezes day time, puts the player
-- in flight at (8,130,8) and builds a small structure in front of the camera (-Z):
-- stone/planks/grass wall + floor (AO, face shading), glass and water (translucent pass),
-- a lamp (block light). Handler: state -> {ready, chunks, pos, rot}.
local WORLD = "f2f_render"
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
local inv = player.get_inventory(pid)
inventory.set(inv, 0, item.index("base:planks.item"), 10)
player.set_selected_slot(pid, 0)

local ready = false
local function build()
    local stone = block.index("base:stone")
    local planks = block.index("base:planks")
    local grass = block.index("base:grass_block")
    local glass = block.index("base:glass")
    local water = block.index("base:water")
    local lamp = block.index("base:lamp")
    for x = 4, 13 do
        for z = 1, 6 do
            block.set(x, 126, z, stone, 0)       -- floor
        end
        for y = 127, 131 do
            block.set(x, y, 1, (x + y) % 2 == 0 and planks or grass, 0)  -- back wall
        end
    end
    block.set(7, 127, 4, glass, 0)
    block.set(8, 127, 4, water, 0)
    block.set(9, 127, 4, water, 0)
    block.set(10, 127, 3, lamp, 0)
    block.set(8, 128, 5, stone, 0)   -- target block (selection outline)
end

f2f.set_handler(function(cmd, args)
    if cmd == "state" then
        local x, y, z = player.get_pos(pid)
        local yaw, pitch = player.get_rot(pid)
        return {ready = ready, chunks = world.count_chunks(), pos = {x, y, z}, rot = {yaw, pitch},
                block = block.name(block.get(8, 126, 3))}
    elseif cmd == "build" then
        build()
        player.set_pos(pid, 8.5, 130, 8.5)
        player.set_rot(pid, 0, -35, 0)
        return {built = true, block = block.name(block.get(8, 126, 3))}
    end
    error("unknown-command: " .. tostring(cmd))
end)
ready = true
print("[f2f-world] ready")
