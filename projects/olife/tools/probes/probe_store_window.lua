-- Проба 0.32 в окне (F2F, vctest --window), UX A4: что из скачанных активов применяется на лету без переоткрытия мира.
--   текстура: PNG -> Canvas.decode -> canvas:create_texture(name) -> rig:set_texture("$i", name), to_canvas() назад;
--             assets.load_texture(bytes, name[, format]);
--   модель:   assets.parse_model("vcm", text, name) -> rig:set_model(i, name), rig:get_model(i);
--   звук:     audio.play_stream("world:...ogg", x, y, z, vol, pitch[, channel, loop]) / play_sound(name, ...).
local function p(...) print("[probe]", ...) end
local function has(list, id) for _, v in ipairs(list) do if v == id then return true end end return false end
p("sources", json.tostring(app.get_content_sources()))
p("available", pcall(function() return json.tostring(pack.get_available()) end))
local want = {}
for _, id in ipairs({"base", "olife_proto", "olife_client"}) do if not has(app.get_content(), id) then want[#want + 1] = id end end
local all = app.get_content()
for _, id in ipairs(want) do all[#all + 1] = id end
app.reconfig_packs(want, {})
p("content", table.concat(app.get_content(), ","))
app.new_world("store_probe_w", "1", "core:default")
app.sleep(0.5)
-- 1) texture from PNG bytes
local c = Canvas({8, 8})
for y = 0, 7 do for x = 0, 7 do c:set(x, y, ((x + y) % 2 == 0) and 0xff0000ff or 0xff00ff00) end end
local png = c:encode("png")
file.mkdirs("world:content/olife_assets")
file.write_bytes("world:content/olife_assets/tex1.png", png)
local d = Canvas.decode(file.read_bytes("world:content/olife_assets/tex1.png"), "png")
p("decoded", d.width, d.height, string.format("%08x", d:at(0, 0)))
local okct, ect = pcall(function() return d:create_texture("olife_assets/tex1") end)
p("create_texture", okct, ect)
local okb, back = pcall(assets.to_canvas, "olife_assets/tex1")
p("to_canvas", okb, okb and back and (back.width .. "x" .. back.height .. " " .. string.format("%08x", back:at(0, 0))) or back)
local oklt, elt = pcall(assets.load_texture, png, "olife_assets/tex2")
p("load_texture(bytes,name)", oklt, elt)
local oklt3, elt3 = pcall(assets.load_texture, png, "olife_assets/tex3", "png")
p("load_texture(bytes,name,png)", oklt3, elt3)
local okb2, back2 = pcall(assets.to_canvas, "olife_assets/tex2")
p("to_canvas tex2", okb2, okb2 and back2 and (back2.width .. "x" .. back2.height) or back2)
p("request_texture", pcall(assets.request_texture, "olife_assets/tex4"))
-- 2) entity rig: set_texture / set_model
local ent = entities.spawn("olife_client:bench", {0.5, 100, 0.5})
p("spawned", ent ~= nil, ent and ent:get_uid())
local rig = ent and ent.skeleton
p("rig", rig ~= nil)
if rig then
    local idx = rig:index("rody")
    p("rody idx", idx, "model", rig:get_model(idx))
    p("set_texture runtime", pcall(rig.set_texture, rig, "$0", "olife_assets/tex1"), rig:get_texture("$0"))
    local vcm = "@box from (-0.25,0,-0.25) to (0.25,0.5,0.25) texture \"$0\"\n"
    local okm, em = pcall(assets.parse_model, "vcm", vcm, "olife_assets:m1")
    p("parse_model vcm", okm, em)
    local oks, es = pcall(rig.set_model, rig, idx, "olife_assets:m1")
    p("set_model runtime", oks, es, "get_model", rig:get_model(idx))
    local okm2, em2 = pcall(assets.parse_model, "vcm", "@box from (0,0,0) to (1,1,1)\n@garbage ((((", "olife_assets:bad")
    p("parse_model bad", okm2, em2)
    local okx, ex = pcall(assets.parse_model, "xml", "<model/>", "olife_assets:m2")
    p("parse_model xml", okx, ex)
    app.sleep(0.2)
    -- re-parse the same name (hot replace)
    p("parse_model again", pcall(assets.parse_model, "vcm", "@box from (0,0,0) to (0.2,0.2,0.2)\n", "olife_assets:m1"))
    p("get_model after", rig:get_model(idx))
end
-- 3) sound from a file in world:
local ogg = file.read_bytes("olife_client:sounds/olife/ok.ogg")
file.write_bytes("world:content/olife_assets/s1.ogg", ogg)
p("play_stream world:", pcall(audio.play_stream, "world:content/olife_assets/s1.ogg", 0.5, 100, 0.5, 1.0, 1.0, "regular", false))
p("play_stream_2d world:", pcall(audio.play_stream_2d, "world:content/olife_assets/s1.ogg", 1.0, 1.0, "regular", false))
p("play_sound name", pcall(audio.play_sound, "olife/ok", 0.5, 100, 0.5, 1.0, 1.0, "regular"))
p("play_sound world path", pcall(audio.play_sound, "world:content/olife_assets/s1.ogg", 0.5, 100, 0.5, 1.0, 1.0, "regular"))
p("play_stream bad", pcall(audio.play_stream, "world:content/olife_assets/nope.ogg", 0.5, 100, 0.5, 1.0, 1.0, "regular", false))
app.sleep(0.3)
p("count_streams", audio.count_streams())
-- wav
p("PCMStream", type(audio.PCMStream))
app.close_world(false)
p("done")
