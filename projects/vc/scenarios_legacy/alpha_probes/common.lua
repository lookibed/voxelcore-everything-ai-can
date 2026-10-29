-- Общее для проб AlphaMine: мир "AlphaProbe" на генераторе alphamine:void (пересоздаётся).
-- Подключение из сценария: setfenv(load(file.read(".../common.lua")), getfenv(1))()
-- (load без setfenv даёт глобальное окружение, где нет app).
local C = {}
function C.log(tag, m) debug.log("[" .. tag .. "] " .. m) end
function C.open_probe_world(tag, name)
    name = name or "AlphaProbe"
    app.config_packs({"base", "alphamine"})
    app.load_content()
    if world.exists(name) then
        app.delete_world(name)
        C.log(tag, "deleted old world " .. name)
    end
    app.new_world(name, "1", "alphamine:void")
    world.set_day_time(0.5)
    world.set_day_time_speed(0)
    local pid = 0
    player.set_flight(pid, true)
    player.set_noclip(pid, true)
    player.set_pos(pid, 8, 100, 8)
    player.set_vel(pid, 0, 0, 0)
    C.log(tag, "world " .. name .. " generator " .. tostring(world.get_generator()))
    return pid
end
function C.keys(t)
    local r = {}
    for k in pairs(t or {}) do r[#r + 1] = tostring(k) end
    table.sort(r)
    return table.concat(r, " ")
end
return C
