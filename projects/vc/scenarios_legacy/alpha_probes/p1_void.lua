-- Проба 1: генератор alphamine:void даёт чанки из одного воздуха. Плюс дамп API.
-- vc_start(script="user:tools/scenarios/alpha_probes/p1_void.lua", wait_for="\\[alpha_p1\\] done")
local C = setfenv(load(file.read("user:tools/scenarios/alpha_probes/common.lua")), getfenv(1))()
local T = "alpha_p1"
local pid = C.open_probe_world(T)
local t0 = time.uptime()
app.sleep_until(function() return world.count_chunks() >= 9 end, 1e9, 20)
app.sleep(1)
C.log(T, ("chunks loaded %d after %.2f s"):format(world.count_chunks(), time.uptime() - t0))
local px, py, pz = player.get_pos(pid)
C.log(T, ("player at %.2f %.2f %.2f flight=%s noclip=%s"):format(px, py, pz,
    tostring(player.is_flight(pid)), tostring(player.is_noclip(pid))))
-- полный обход чанков -1..1 по x,z: всё ли воздух (id 0), есть ли незагруженные (-1)
for cz = -1, 1 do
    for cx = -1, 1 do
        local nonair, unloaded = 0, 0
        for y = 0, 255 do
            for z = 0, 15 do
                for x = 0, 15 do
                    local id = block.get(cx * 16 + x, y, cz * 16 + z)
                    if id == -1 then unloaded = unloaded + 1 elseif id ~= 0 then nonair = nonair + 1 end
                end
            end
        end
        C.log(T, ("chunk %d,%d: nonair=%d unloaded=%d"):format(cx, cz, nonair, unloaded))
    end
end
for _, p in ipairs({{0, 0, 0}, {5, 10, 5}, {-7, 1, 3}, {15, 255, 15}, {8, 64, 8}}) do
    C.log(T, ("block.get(%d,%d,%d) = %s name=%s"):format(p[1], p[2], p[3],
        tostring(block.get(p[1], p[2], p[3])), tostring(block.name(block.get(p[1], p[2], p[3])))))
end
C.log(T, "block: " .. C.keys(block))
C.log(T, "world: " .. C.keys(world))
C.log(T, "network: " .. C.keys(network))
C.log(T, "compression: " .. C.keys(compression))
C.log(T, "cameras: " .. C.keys(cameras))
C.log(T, "player: " .. C.keys(player))
C.log(T, "gfx: " .. C.keys(gfx))
C.log(T, "time: " .. C.keys(time))
C.log(T, "ffi global: " .. tostring(ffi ~= nil) .. " os.clock: " .. tostring(os and os.clock ~= nil))
for _, n in ipairs({"camera.fov", "camera.fov-effects", "camera.shaking", "camera.inertia",
        "graphics.soft-lighting", "graphics.backlight", "graphics.gamma", "graphics.fog-curve",
        "graphics.advanced-render", "graphics.clouds-quality", "chunks.load-distance", "display.framerate"}) do
    local ok, v = pcall(app.get_setting, n)
    C.log(T, "setting " .. n .. " = " .. tostring(v) .. (ok and "" or " (ERR)"))
end
C.log(T, "done")
