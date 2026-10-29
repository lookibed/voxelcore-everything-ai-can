-- Компьютер pc_wasmrt:pc с «Windows XP» (content/pc_wasmrt/modules/pc_os.lua) в мире.
-- Мир — export:pc_world.txt (по умолчанию "PC Test": копия "New World 1" пользователя, где игрок
-- стоит перед компьютером; в packs.list добавлены wasmrt, doom, quake, eaglercraft, videoplayer).
-- Полдень и остановленное время (иначе экран в темноте). export:pc_enter.txt = "1" — сразу сесть
-- за компьютер (как ПКМ по нему). export:pc_launch.txt = id программы (doom | quake | eaglercraft | video |
-- shader) — после входа запустить её ярлыком (pc:launch, как двойной клик; 06.10, порт на 0.32.1).
-- Если компьютера в мире нет (07.10: в fineltest старые minecraft2:pc пропали при переименовании пака) —
-- сценарий ставит его сам в 3 блоках перед игроком, развёрнутым к нему (как scripts/app/pc_wasmrt.lua):
-- [pc_world] spawned pc <uid> at x y z.
-- Маркеры: [pc_world] pc <uid> ..., [pc_world] launch <id>, [pc_world] ready.
local function log(m) debug.log("[pc_world] " .. m) end
local WORLD = "PC Test"
if file.isfile("export:pc_world.txt") then WORLD = file.read("export:pc_world.txt"):gsub("%s+$", "") end

-- паки — из packs.list мира (как при открытии мира из меню)
local packs = {}
for line in file.read("user:worlds/" .. WORLD .. "/packs.list"):gmatch("[^\r\n]+") do
    if not line:match("^%s*#") and line:match("%S") then packs[#packs + 1] = line:match("^%s*(.-)%s*$") end
end
log("packs " .. table.concat(packs, " "))
app.config_packs(packs)
app.load_content()
app.open_world(WORLD)
world.set_day_time(0.5)
world.set_day_time_speed(0)
app.sleep(1.5)

local pc_os = require("pc_wasmrt:pc_os")
local found
for uid, e in pairs(entities.get_all()) do
    if entities.def_name(entities.get_def(uid)) == "pc_wasmrt:pc" then
        local pos = e.transform:get_pos()
        log(("pc %d at %.2f %.2f %.2f, module instance %s"):format(uid, pos[1], pos[2], pos[3], tostring(pc_os.get(uid) ~= nil)))
        found = found or uid
    end
end
if not found then
    log("no pc in world")
    local ok, err = pcall(function()
        local x, y, z = player.get_pos(0)
        local dir = player.get_dir(0)
        local len = math.sqrt(dir[1] * dir[1] + dir[3] * dir[3])
        if len < 1e-3 then dir, len = {0, 0, -1}, 1 end
        local dx, dz = dir[1] / len, dir[3] / len
        local pos = {x + dx * 3, y + 1, z + dz * 3}
        local ent = entities.spawn("pc_wasmrt:pc", pos)
        found = ent:get_uid()
        -- развернуть экраном к игроку: из четырёх поворотов берём тот, где нормаль экрана (pc:screen())
        -- смотрит на игрока (формула из scripts/app/pc_wasmrt.lua давала ПК спиной — проверено кадром)
        local pc = pc_os.get(found)
        local to_player = {-dx, 0, -dz}
        local best, best_dot = 0, -2
        for _, deg in ipairs({0, 90, 180, 270}) do
            ent.transform:set_rot(mat4.rotate({0, 1, 0}, deg))
            if pc then
                local a, eu, ev = pc:screen()
                local n = {eu[2] * ev[3] - eu[3] * ev[2], eu[3] * ev[1] - eu[1] * ev[3], eu[1] * ev[2] - eu[2] * ev[1]}
                local l = math.sqrt(n[1] * n[1] + n[2] * n[2] + n[3] * n[3])
                local d = (n[1] * to_player[1] + n[3] * to_player[3]) / (l > 0 and l or 1)
                if d > best_dot then best, best_dot = deg, d end
            end
        end
        ent.transform:set_rot(mat4.rotate({0, 1, 0}, best))
        log(("spawned pc %d at %.2f %.2f %.2f, rot %d (screen normal . to_player = %.2f)"):format(
            found, pos[1], pos[2], pos[3], best, best_dot))
    end)
    if not ok then log("spawn failed: " .. tostring(err)) end
    app.sleep(0.5)
    if found then log("spawned pc module instance " .. tostring(pc_os.get(found) ~= nil)) end
end
local enter = file.isfile("export:pc_enter.txt") and file.read("export:pc_enter.txt"):match("1")
if found and enter and pc_os.get(found) then
    -- не из корутины сценария: gui.set_active_frame(id, locator) запоминает функцию вместе с
    -- lua_State вызова, и locator, созданный в корутине, потом портит её ("cannot resume dead
    -- coroutine" каждый кадр) — вход через post_runnable (главное состояние)
    time.post_runnable(function()
        pc_os.get(found):enter(0)
        log("entered pc " .. found)
    end)
end
local launch = file.isfile("export:pc_launch.txt") and file.read("export:pc_launch.txt"):match("%S+")
if found and launch and pc_os.get(found) then
    app.sleep(0.5)
    time.post_runnable(function()
        log("launch " .. launch)
        pc_os.get(found):launch(launch)
    end)
end
app.sleep(0.5)
log("ready")
