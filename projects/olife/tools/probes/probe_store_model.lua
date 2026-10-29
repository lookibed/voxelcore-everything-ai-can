-- Проба 0.32 (окно), UX A4: модель VCM из байтов под длинным именем olife_assets:<sha> -> set_model -> get_model
local function p(...) print("[probe]", ...) end
local function has(list, id) for _, v in ipairs(list) do if v == id then return true end end return false end
local want = {}
for _, id in ipairs({"base", "olife_proto", "olife_client"}) do if not has(app.get_content(), id) then want[#want + 1] = id end end
app.reconfig_packs(want, {})
app.new_world("store_probe_m", "1", "core:default")
app.sleep(0.3)
local ent = entities.spawn("olife_client:bench", {0.5, 100, 0.5})
local rig = ent.skeleton
local idx = rig:index("rody")
p("initial", rig:get_model(idx))
local vcm = '@box from (-0.45,-0.5,-0.45) to (0.45,-0.1,0.45) texture "$0"\n@box from (-0.2,-0.1,-0.2) to (0.2,0.5,0.2) texture "$1"\n'
local name = "olife_assets:693cfdb4ee688dc2c8b140bc32eafb08984fa8f7a7581445ffbcad2e19621353"
p("parse long", pcall(assets.parse_model, "vcm", vcm, name))
p("set long", pcall(rig.set_model, rig, idx, name), rig:get_model(idx))
rig:set_model(idx, "olife_bench")
p("back", rig:get_model(idx))
p("parse short", pcall(assets.parse_model, "vcm", vcm, "olife_assets:m1"))
p("set short", pcall(rig.set_model, rig, idx, "olife_assets:m1"), rig:get_model(idx))
local b = Bytearray(vcm)
p("parse from Bytearray", pcall(assets.parse_model, "vcm", b, "olife_assets:m2"))
p("set m2", pcall(rig.set_model, rig, idx, "olife_assets:m2"), rig:get_model(idx))
p("parse no prefix", pcall(assets.parse_model, "vcm", vcm, "m3x"))
p("set m3x", pcall(rig.set_model, rig, idx, "m3x"), rig:get_model(idx))
p("set unknown", pcall(rig.set_model, rig, idx, "nope:nope"), rig:get_model(idx))
app.sleep(0.2)
p("after sleep", rig:get_model(idx))
app.close_world(false)
p("done")
