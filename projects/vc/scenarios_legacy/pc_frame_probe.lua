-- Проба: gui.create_frame в текстуру на экране сущности pc_wasmrt:pc (мир "PC Test").
-- Маркеры: [pc_probe] ...; конец — [pc_probe] ready.
local function log(m) debug.log("[pc_probe] " .. m) end
local WORLD = "PC Test"

app.config_packs({ "base", "wasmrt", "doom", "quake", "eaglercraft", "videoplayer", "pc_wasmrt" })
app.load_content()
app.open_world(WORLD)
app.sleep(2)

local function m2s(m)
    local t = {}
    for i = 1, 16 do t[i] = string.format("%.3f", m[i]) end
    return table.concat(t, " ")
end

local pc
for uid, e in pairs(entities.get_all()) do
    local name = entities.def_name(entities.get_def(uid))
    local ok, pos = pcall(function() return e.transform:get_pos() end)
    log(("entity %s %s pos %s"):format(tostring(uid), name, ok and string.format("%.3f %.3f %.3f", pos[1], pos[2], pos[3]) or tostring(pos)))
    if name == "pc_wasmrt:pc" then
        pc = e
        log("rot " .. m2s(e.transform:get_rot()))
        log("size " .. table.concat(e.transform:get_size(), " "))
        log("bone0 " .. m2s(e.skeleton:get_matrix(0)))
        log("tex $0 = " .. tostring(e.skeleton:get_texture("$0")))
    end
end
local px, py, pz = player.get_pos(0)
log(("player %.3f %.3f %.3f"):format(px, py, pz))
local cam = cameras.get(player.get_camera(0))
log(("camera %s fov %s pos %s front %s"):format(cam:get_name(), tostring(cam:get_fov()),
    table.concat(cam:get_pos(), " "), table.concat(cam:get_front(), " ")))

local W, H = 1024, 724
local root, doc = gui.create_frame("pc_wasmrt:probe", "pc_probe_tex", { W, H })
log("frame created: root " .. tostring(root) .. " doc " .. tostring(doc))
root:add(('<container id="bg" pos="0,0" size="%d,%d" color="#3A6EA5FF"/>'):format(W, H))
root:add('<container id="tl" pos="0,0" size="64,64" color="#FF0000FF"/>')
root:add(('<container id="br" pos="%d,%d" size="64,64" color="#00FF00FF"/>'):format(W - 64, H - 64))
root:add('<label id="lbl" pos="100,100" size="400,32">Hello frame 0,0 is red</label>')
root:add([[<button id="btn" pos="100,200" size="300,60" onclick="events.emit('pc_wasmrt:probe_click')">Click me</button>]])
assets.load_texture(file.read_bytes("doom:icon.png"), "pc_icon_doom")
root:add('<image id="icon" src="pc_icon_doom" pos="500,200" size="128,128"/>')
events.on("pc_wasmrt:probe_click", function() log("button clicked") end)
log("root pos " .. table.concat(root.pos, " ") .. " wpos " .. table.concat(root.wpos, " ") .. " size " .. table.concat(root.size, " "))

if pc then
    pc.skeleton:set_texture("$0", "pc_probe_tex")
    log("set $0 -> pc_probe_tex")
end
app.sleep(0.5)
log("root pos after draw " .. table.concat(root.pos, " ") .. " wpos " .. table.concat(root.wpos, " "))
log("ready")
