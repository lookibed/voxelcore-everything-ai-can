-- blackhole:collapser_thrown — схлопыватель: летит динамическим телом; попадание в горизонт любой дыры (расстояние до
-- центра < горизонт + 0.6) немедленно запускает её коллапс (то же проверяет и сама дыра в своём такте). 15 с — исчезает.
local core = require "blackhole:core"
local tsf, body, rig = entity.transform, entity.rigidbody, entity.skeleton
local uid = entity:get_uid()
local args = ARGS or {}
for i = 0, 5 do rig:set_texture("$" .. i, "blocks:bh_collapser_skin") end
rig:set_matrix(0, mat4.scale({ 0.3, 0.3, 0.3 }))
body:set_elasticity(0.3)
if args.vel then body:set_vel(args.vel) end
local t, spin = 0, 0
local done = false

local function check()
    if done then return end
    local p = tsf:get_pos()
    for huid, s in pairs(core.holes) do
        if s.phase == "feed" or s.phase == "birth" or s.phase == "merging" then
            local d = vec3.length(vec3.sub(s.center, p))
            local rh = core.horizon(s.mass)
            if d < math.max(s.rh_vis or 0, rh) + 0.6 then
                done = true
                core.log(("collapser %d hit hole %d at distance %.2f (horizon %.2f, mass %.0f)"):format(uid, huid, d, rh, s.mass))
                s.start_collapse("collapser")
                entity:despawn()
                return
            end
        end
    end
end

function on_physics_update(delta) check() end

function on_update(tps)
    t = t + 1 / (tps or 20)
    if t > 15 and not done then done = true; entity:despawn() end
end

function on_render(dt)
    spin = spin + dt * 500
    tsf:set_rot(mat4.rotate({ 0.3, 1, 0.2 }, spin))
    local k = 0.75 + 0.25 * math.sin(t * 20)
    rig:set_color({ k, k, 1 })
end
