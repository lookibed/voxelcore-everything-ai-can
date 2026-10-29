-- blackhole:grenade — брошенная граната: динамическое тело, отскоки (пол — on_grounded, стены — обнуление
-- горизонтальной скорости между кадрами физики), вращение в полёте, фитиль ~2.5 с с миганием и тиком, затем дыра.
local core = require "blackhole:core"
local sfx = require "blackhole:sfx"

local tsf, body, rig = entity.transform, entity.rigidbody, entity.skeleton
local uid = entity:get_uid()
local args = ARGS or {}

local FUSE = args.fuse or 2.5
local FLOOR_K = 0.55     -- доля вертикальной скорости после отскока от пола
local WALL_K = 0.5       -- доля горизонтальной скорости после отскока от стены
local FRICTION = 0.75    -- горизонталь при ударе о пол

bounces = 0
walls = 0
local t = 0
local prev = { 0, 0, 0 }
local spin, spin_axis = 0, vec3.normalize({ 0.6, 0.3, 0.8 })
local blink_t, blink_on = 0, false
local SCALE = 0.32

for i = 0, 5 do rig:set_texture("$" .. i, "blocks:bh_grenade_skin") end
rig:set_matrix(0, mat4.scale({ SCALE, SCALE, SCALE }))
body:set_elasticity(0)
if args.vel then body:set_vel(args.vel); prev = { args.vel[1], args.vel[2], args.vel[3] } end

-- force движка = |v до шага - v после| (вместе с горизонталью, если в том же шаге была стена), поэтому отражаем
-- вертикальную скорость до удара (prev[2] из прошлого кадра физики), а force — только порог и громкость
function on_grounded(force)
    local vy = -prev[2]
    if vy <= 0 then vy = force end
    if vy > 1.6 then
        local v = body:get_vel()
        body:set_vel({ v[1] * FRICTION, vy * FLOOR_K, v[3] * FRICTION })
        bounces = bounces + 1
        core.log(("grenade bounce %d force=%.2f vy_in=%.2f vy_out=%.2f"):format(bounces, force, vy, vy * FLOOR_K))
        sfx.play("bounce", tsf:get_pos(), math.min(1, force / 12), 0.9 + math.random() * 0.2)
    end
end

function on_physics_update(delta)
    local v = body:get_vel()
    local changed = false
    for _, a in ipairs({ 1, 3 }) do
        if math.abs(prev[a]) > 1.0 and math.abs(v[a]) < 0.15 * math.abs(prev[a]) then
            v[a] = -prev[a] * WALL_K
            changed = true
        end
    end
    if changed then
        walls = walls + 1
        body:set_vel(v)
        core.log(("grenade wall bounce %d vel %.2f %.2f %.2f"):format(walls, v[1], v[2], v[3]))
        sfx.play("bounce", tsf:get_pos(), 0.6, 1.2)
    end
    prev = { v[1], v[2], v[3] }
end

function on_render(dt)
    local v = body:get_vel()
    local sp = math.sqrt(v[1] * v[1] + v[3] * v[3]) + math.abs(v[2]) * 0.3
    spin = spin + dt * (60 + sp * 70)
    tsf:set_rot(mat4.rotate(spin_axis, spin))
    -- мигание фитиля: период 0.45 -> 0.07 с
    local left = math.max(0, FUSE - t)
    local period = 0.07 + 0.38 * (left / FUSE)
    blink_t = blink_t + dt
    if blink_t >= period * 0.5 then
        blink_t = 0
        blink_on = not blink_on
        rig:set_color(blink_on and { 1.0, 0.35, 0.9 } or { 1, 1, 1 })
        if blink_on then sfx.play("tick", tsf:get_pos(), 0.5, 1 + (1 - left / FUSE) * 0.6) end
    end
end

function on_update(tps)
    t = t + 1 / (tps or 20)
    if t >= FUSE then
        local p = tsf:get_pos()
        p[2] = p[2] + 0.4
        local hole = entities.spawn("blackhole:hole", p, { blackhole__hole = { mass = 1 } })
        core.log(("grenade %d detonated after %.2f s, %d bounces, %d wall bounces -> hole %d at %.1f %.1f %.1f"):format(
            uid, t, bounces, walls, hole:get_uid(), p[1], p[2], p[3]))
        entity:despawn()
    end
end
