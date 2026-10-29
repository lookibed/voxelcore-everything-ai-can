-- blackhole:api — запасной способ без игрока (сценарии, консоль, другие паки):
--   local blackhole = require "blackhole:api"
--   blackhole.spawn({x, y, z}, mass, vel)       -> uid дыры (vel — начальная скорость, необязательно)
--   blackhole.throw({x, y, z}, {vx, vy, vz})    -> uid гранаты
--   blackhole.state(uid)                         -> таблица состояния дыры (mass, phase, eaten_blocks, ...) или nil
local M = {}

function M.spawn(pos, mass, vel, axis)
    local e = entities.spawn("blackhole:hole", { pos[1], pos[2], pos[3] },
        { blackhole__hole = { mass = mass or 1, vel = vel, axis = axis } })
    return e:get_uid()
end

function M.throw(pos, vel, fuse, kind)
    kind = kind or "grenade_thrown"
    local e = entities.spawn("blackhole:" .. kind, { pos[1], pos[2], pos[3] },
        { ["blackhole__" .. kind] = { vel = vel, fuse = fuse } })
    return e:get_uid()
end

function M.state(uid)
    local e = entities.get(uid)
    if not e then return nil end
    local c = e:get_component("blackhole:hole")
    return c and c.state or nil
end

-- все дыры мира: uid -> state (по сущностям, а не по реестру модуля)
function M.all()
    local t = {}
    local idx = entities.def_index("blackhole:hole")
    for uid, e in pairs(entities.get_all()) do
        if e:def_index() == idx then
            local c = e:get_component("blackhole:hole")
            if c and c.state then t[uid] = c.state end
        end
    end
    return t
end

return M
