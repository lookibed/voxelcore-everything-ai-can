-- olife_client:bench — visual of an Olife scripted entity: the user's original bench model (prototype 0.30.6, pack Olife:
-- models/bench.obj + textures/entities/cmd.png, here olife_bench / entities/olife_bench). The replica never simulates
-- it: position comes from the world's snapshots (olife_client:client); the owner may choose another model/texture
-- (EntityLook -> olife_client:olife.apply_look). Run status is shown by the name tag (only while the Injector is in hand).
if vc.is_client() then
    local rig = entity.skeleton
    for i = 0, 5 do rig:set_texture("$" .. i, "entities/olife_bench") end
end
