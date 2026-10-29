-- Проба 4: шейдеры мира из пака. Перед запуском shaders/ из tools/scenarios/alpha_probes/shaders
-- копируются в content/alphamine/shaders (после пробы — удаляются). graphics.soft-lighting=false и
-- graphics.backlight=false на время пробы (в конце возвращаются). Сцена — узор пробы 2 + лампа.
-- Маркеры: [alpha_p4] shot, done. Разбор скриншота — p4_analyze.py.
local C = setfenv(load(file.read("user:tools/scenarios/alpha_probes/common.lua")), getfenv(1))()
local T = "alpha_p4"
local old_soft = app.get_setting("graphics.soft-lighting")
local old_back = app.get_setting("graphics.backlight")
app.set_setting("graphics.soft-lighting", false)
app.set_setting("graphics.backlight", false)
local pid = C.open_probe_world(T)
local codec = require("alphamine:chunk_codec")
local STONE, DIRT, GRASS = block.index("base:stone"), block.index("base:dirt"), block.index("base:grass_block")
local PLANKS, LAMP = block.index("base:planks"), block.index("base:lamp")
player.set_spawnpoint(pid, 8, 100, 8)
player.set_pos(pid, 8, 100, 8)
pcall(app.sleep_until, function() return block.get(16, 0, 16) ~= -1 and block.get(-16, 0, -16) ~= -1 end, 1e9, 20)
local raw = codec.new_raw()
for cz = -1, 1 do for cx = -1, 1 do
    local p = raw.bytes
    for i = 0, codec.RAW_LEN - 1 do p[i] = 0 end
    for z = 0, 15 do for x = 0, 15 do
        codec.fill_column(raw, x, z, 0, 62, STONE)
        codec.fill_column(raw, x, z, 63, 63, GRASS)
    end end
    if cx == 0 and cz == 0 then
        -- крыша 7×16 на y=66 (низко, чтобы свет под ней заметно падал), лампа на траве
        for z = 0, 15 do for x = 0, 6 do codec.set_id(raw, x, 66, z, PLANKS) end end
        codec.set_id(raw, 11, 64, 12, LAMP)
    end
    world.set_chunk_data(cx, cz, codec.encode(raw))
end end
app.sleep(1)
C.log(T, ("soft-lighting=%s backlight=%s lamp=%d"):format(tostring(app.get_setting("graphics.soft-lighting")),
    tostring(app.get_setting("graphics.backlight")), LAMP))
player.set_pos(pid, 14, 67.5, 8)
player.set_rot(pid, 90, -25, 0)
app.sleep(1.5)
C.log(T, "shot")
app.sleep(4)
app.set_setting("graphics.soft-lighting", old_soft)
app.set_setting("graphics.backlight", old_back)
C.log(T, "done")
