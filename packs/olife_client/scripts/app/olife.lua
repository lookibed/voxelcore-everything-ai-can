-- Пункт меню «Сценарии» -> olife (VoxelCore 0.32): клиент Olife. UX B (16.10, olife_menu): главное меню клиента
-- (layouts/pages/olife_menu.xml: 3D-сценка <modelviewer>, ip:port шлюза, ник, «Войти», последние серверы) -> экран
-- статуса входа (layouts/pages/olife_status.xml: билет -> шлюз -> Welcome -> манифест -> файлы -> sha256 -> мир ->
-- чанки, ошибки с кодом и причиной, «Повторить»/«Назад») -> игра (HUD-статус: паки на лету, перезапуск мира) -> по
-- выходу из мира — снова меню (или экран статуса с ошибкой разрыва).
-- export:olife_server.txt (пишет лаборатория: `lab play olife`, `lab olife play-up`) — только автозаполнение полей.
-- Аргумент проекта --autologin 1 (сухой прогон лаборатории) — сразу «Войти» с автозаполнением.
-- Грабли 0.32 (LESSONS «Olife — меню клиента»): в меню контента нет, пока его не загрузить (app.load_content) —
-- модули и страницы пака находятся только после этого; закрытие мира сбрасывает контент до "base" и выгружает
-- модули пака, поэтому состояние меню и статуса хранит этот скрипт (таблицы STATE) и после перезагрузки контента
-- отдаёт их модулям заново. Непойманная ошибка app-скрипта = abort процесса (0xC0000409) — всё под xpcall.
-- Длинного тире нет в шрифте движка: в строках интерфейса — дефис.
local STATE = {status = {}, menu = {}}

local function log(fmt, ...)
    local s = "[olife_play] " .. string.format(fmt, ...)
    if debug and debug.log then debug.log(s) else print(s) end
end

local function arg(name, default)
    local ok, v = pcall(function() return vc and vc.get_project_arg and vc.get_project_arg(name) end)
    if not ok or v == nil or v == "" then return default end
    return v
end

-- packs of the client + content loaded in the menu; "base" only if missing ("pack duplication [base]")
local function boot()
    local loaded = {}
    for _, id in ipairs(app.get_content()) do loaded[id] = true end
    local add = {}
    for _, id in ipairs({"base", "olife_client"}) do
        if not loaded[id] then add[#add + 1] = id end
    end
    if #add > 0 then app.reconfig_packs(add, {}) end
    if not app.is_content_loaded() then app.load_content() end
    local ST = require "olife_client:status"
    local MN = require "olife_client:menu"
    ST.bind(STATE.status)
    MN.bind(STATE.menu)
    return ST, MN
end

local function show(page)
    local MN = require "olife_client:menu"
    MN.S.app_phase = page
    -- the game left the null frame active (the camera holds the cursor): a world closed by this script keeps it, and
    -- the GUI then ignores the mouse (Engine::renderFrame locks the cursor while no frame is active) -> the menu frame
    pcall(gui.set_active_frame, gui.main_frame_id or "core:main")
    menu.page = page
end

local function main()
    local ST, MN = boot()
    MN.load()
    local autologin = arg("autologin", "0") == "1"
    local screen = "olife_menu"
    show(screen)
    log("menu ready (autofill %s, autologin %s)", MN.S.autofill and MN.S.autofill.gateway or "none", tostring(autologin))
    if autologin then
        local t, kind, why = MN.target(MN.S.fields.addr, MN.S.fields.nick)
        if t then MN.request("login", t) else log("autologin: %s %s", tostring(kind), tostring(why)) end
    end
    local last_target
    while true do
        app.tick()
        local V = require "olife_client:status_view"
        V.render_all()
        if screen == "olife_menu" then MN.scene() else MN.flash_tick() end
        local r = MN.pop()
        if r then
            if r.what == "quit" then
                log("menu: quit")
                break
            elseif r.what == "back" then
                screen = "olife_menu"
                MN.S.hint = nil
                show(screen)
            elseif r.what == "login" or (r.what == "retry" and last_target) then
                last_target = r.what == "login" and r.arg or last_target
                MN.S.logins = (MN.S.logins or 0) + 1
                screen = "olife_status"
                show(screen)
                local L = require "olife_client:login"
                local okl, res = xpcall(L.run, debug.traceback, last_target, {app = app})
                if not okl then
                    log("login crashed: %s", tostring(res))
                    ST.fail(nil, "internal", "lua", tostring(res):sub(1, 300))
                    res = "error"
                end
                MN.S.results = MN.S.results or {}
                table.insert(MN.S.results, {attempt = ST.S.attempt, result = res, error = ST.S.error})
                if res == "play" then
                    local P = require "olife_client:play"
                    local okp, pres = xpcall(P.run_world, debug.traceback, {app = app, target = last_target})
                    if not okp then
                        log("game loop crashed: %s", tostring(pres))
                        pcall(function() if world.is_open() then app.close_world(false) end end)
                        pres = "error"
                    end
                    table.insert(MN.S.results, {attempt = ST.S.attempt, result = "game:" .. tostring(pres),
                                                error = ST.S.error})
                    if pres == "stop" then break end
                    -- the world closed: the content is "base" again and the pack's modules were unloaded
                    ST, MN = boot()
                    if pres == "error" then
                        screen = "olife_status"
                    else
                        screen = "olife_menu"
                        ST.S.mode, ST.S.banner = "idle", nil
                    end
                    show(screen)
                else
                    -- back: the menu; error: stay on the status screen. A world opened half way is closed; the content
                    -- may have been reset by it (or by a failed reopen) -> boot again (idempotent) and show the page
                    -- again (its on_open also puts the F2F handler of the menu back)
                    local cl = require "olife_client:client"
                    if res == "back" then pcall(cl.bye, "login cancelled") end
                    if world.is_open() then pcall(app.close_world, false) end
                    ST, MN = boot()
                    screen = res == "back" and "olife_menu" or "olife_status"
                    show(screen)
                end
            end
        end
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    log("FAILED: %s", tostring(err))
    pcall(function() if world.is_open() then app.close_world(false) end end)
end
-- back to the engine's main menu (our pages would stay with nobody handling their buttons)
pcall(function() menu:reset(); menu.page = "main" end)
if not ok and gui and gui.alert then pcall(gui.alert, "Olife: ошибка клиента - " .. tostring(err):sub(1, 200)) end
log("client script finished")
