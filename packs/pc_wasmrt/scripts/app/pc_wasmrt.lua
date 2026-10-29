-- Сценарий меню "Сценарии": мир "pc_wasmrt" с паком pc_wasmrt (компьютер-сущность с
-- рабочим столом «Windows XP» на экране, см. README.md пака; ярлык «Minecraft (shader)» —
-- ShaderToy "Minecraft" в шейдере сущностей по данным из canvas).
-- Мир создаётся, если его нет; в новом мире перед игроком ставится компьютер и в
-- инвентарь кладётся "pc_egg". ПКМ по компьютеру — камера в компьютер (WASD/мышь/F/Space/Shift),
-- ещё раз ПКМ — обратно. Маркер в логе: [pc_wasmrt] ready.
local WORLD = "pc_wasmrt"

app.config_packs({"base", "pc_wasmrt"})
app.load_content()

local created = false
if file.isfile("user:worlds/"..WORLD.."/world.json") then
    debug.log("[pc_wasmrt] opening world")
    app.open_world(WORLD)
else
    debug.log("[pc_wasmrt] creating world")
    app.new_world(WORLD, "2", "base:demo")
    created = true
end
app.sleep(2)

local pid = 0
if created then
    local ok, err = pcall(function()
        local invid = player.get_inventory(pid)
        inventory.add(invid, item.index("pc_wasmrt:pc_egg"), 1)
        local x, y, z = player.get_pos(pid)
        local dir = player.get_dir(pid)
        local len = math.sqrt(dir[1] * dir[1] + dir[3] * dir[3])
        if len < 1e-3 then dir, len = {0, 0, -1}, 1 end
        local dx, dz = dir[1] / len, dir[3] / len
        local pos = {x + dx * 3, y + 1, z + dz * 3}
        local ent = entities.spawn("pc_wasmrt:pc", pos)
        -- развернуть к игроку (как rotate() в goblin_startcode.lua: угол от оси X)
        local angle = math.deg(math.atan2(-dz, -dx))
        ent.transform:set_rot(mat4.rotate({0, 1, 0}, -angle - 90))
        debug.log("[pc_wasmrt] spawned pc at "..
            string.format("%.1f %.1f %.1f", pos[1], pos[2], pos[3]))
    end)
    if not ok then
        debug.error("[pc_wasmrt] setup failed: "..tostring(err))
    end
end
app.sleep(1)
debug.log("[pc_wasmrt] ready")
