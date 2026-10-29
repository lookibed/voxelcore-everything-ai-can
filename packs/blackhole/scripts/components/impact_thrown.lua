-- blackhole:impact_thrown — ударная граната: без отскоков, при первом касании пола (on_grounded), стены (горизонтальная
-- скорость упала >85 % за кадр физики) или сущности (ближе 0.7, кроме бросившего игрока первые 0.3 с) — дыра.
local core = require "blackhole:core"
local tsf, body, rig = entity.transform, entity.rigidbody, entity.skeleton
local uid = entity:get_uid()
local args = ARGS or {}
for i = 0, 5 do rig:set_texture("$" .. i, "blocks:bh_impact_skin") end
rig:set_matrix(0, mat4.scale({ 0.3, 0.3, 0.3 }))
body:set_elasticity(0)
if args.vel then body:set_vel(args.vel) end
local prev = args.vel and { args.vel[1], args.vel[2], args.vel[3] } or { 0, 0, 0 }
local t, spin = 0, 0
local done = false
local peid
pcall(function() peid = player.get_entity(args.thrower or 0) end)

local function detonate(how)
    if done then return end
    done = true
    local p = tsf:get_pos()
    -- чуть назад по полёту, чтобы центр не оказался в стене
    local sp = vec3.length(prev)
    if sp > 0.1 then p = vec3.sub(p, vec3.mul(prev, 0.25 / sp)) end
    local hole = entities.spawn("blackhole:hole", p, { blackhole__hole = { mass = 1 } })
    core.log(("impact grenade %d detonated by %s after %.2f s -> hole %d at %.1f %.1f %.1f"):format(uid, how, t,
        hole:get_uid(), p[1], p[2], p[3]))
    entity:despawn()
end

function on_grounded(force) detonate("floor") end

function on_physics_update(delta)
    if done then return end
    local v = body:get_vel()
    for _, a in ipairs({ 1, 3 }) do
        if math.abs(prev[a]) > 1.0 and math.abs(v[a]) < 0.15 * math.abs(prev[a]) then detonate("wall"); return end
    end
    prev = { v[1], v[2], v[3] }
    local p = tsf:get_pos()
    local ok, ids = pcall(entities.get_all_in_radius, p, 0.7)
    if ok and ids then
        for _, oid in pairs(ids) do
            if oid ~= uid and not (oid == peid and t < 0.3) then
                local e = entities.get(oid)
                local name = e and e:def_name() or "?"
                if name ~= "blackhole:debris" and name ~= "blackhole:hole" then
                    detonate("entity " .. name .. " #" .. oid)
                    return
                end
            end
        end
    end
end

function on_update(tps)
    t = t + 1 / (tps or 20)
    if t > 20 then detonate("timeout") end
end

function on_render(dt)
    spin = spin + dt * 360
    tsf:set_rot(mat4.rotate({ 0.6, 0.3, 0.8 }, spin))
end
