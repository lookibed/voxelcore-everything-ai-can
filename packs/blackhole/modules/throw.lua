-- blackhole:throw — бросок сущности-снаряда по взгляду камеры игрока (предметы grenade, collapser, impact_grenade).
-- on_use в 0.32 повторяется, пока ПКМ зажата, — пауза между бросками (по предмету).
local core = require "blackhole:core"
local M = {}
local last = {}

function M.throw(pid, entity_name, args_key, item_tag, speed)
    local t = time.uptime()
    if t - (last[item_tag] or -1) < 0.45 then return nil end
    last[item_tag] = t
    local cam = cameras.get(player.get_camera(pid))
    local pos = cam and cam:get_pos()
    local dir = cam and cam:get_front() or player.get_dir(pid)
    if not pos then
        local x, y, z = player.get_pos(pid)
        pos = { x, y + 1.6, z }
    end
    local vx, vy, vz = player.get_vel(pid)
    local p = vec3.add(pos, vec3.mul(dir, 0.7))
    local v = vec3.add(vec3.mul(dir, speed or 15), { vx * 0.5, vy * 0.5 + 2, vz * 0.5 })
    local e = entities.spawn(entity_name, p, { [args_key] = { vel = v, thrower = pid } })
    core.log(("%s thrown by player %d: uid %d pos %.1f %.1f %.1f vel %.1f %.1f %.1f"):format(item_tag, pid, e:get_uid(),
        p[1], p[2], p[3], v[1], v[2], v[3]))
    if not player.is_infinite_items(pid) then
        local invid, slot = player.get_inventory(pid)
        local itemid, count = inventory.get(invid, slot)
        if count and count > 0 then inventory.set(invid, slot, itemid, count - 1) end
    end
    return e
end

return M
