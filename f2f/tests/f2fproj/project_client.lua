local menubg

-- Сценарий, который запускается сразу при старте движка.
-- nil — обычный запуск в главное меню.
local AUTORUN_APP_SCRIPT = nil
-- Если файл есть, его содержимое заменяет AUTORUN_APP_SCRIPT ("none" — без автозапуска).
-- Его пишет MCP-обёртка (tools/mcp) при vc_start(script=...).
local AUTORUN_OVERRIDE_FILE = "user:autorun_app_script.txt"
local autorun_done = false

local function resolve_autorun_script()
    if file.isfile(AUTORUN_OVERRIDE_FILE) then
        local value = file.read(AUTORUN_OVERRIDE_FILE):gsub("^%s+", ""):gsub("%s+$", "")
        if value == "" or value == "none" then
            return nil
        end
        return value
    end
    return AUTORUN_APP_SCRIPT
end

function on_menu_clear()
    if menubg then
        menubg:destruct()
        menubg = nil
    end
end

local function setup_backround()
    local controller = {}
    function controller.resize_menu_bg()
        local w, h = unpack(gui.get_viewport())
        if menubg then
            menubg.region = {0, math.floor(h / 48), math.floor(w / 48), 0}
            menubg.pos = {0, 0}
        end
        return w, h
    end
    local bgid = random.uuid()
    gui.root.root:add(string.format(
        "<image id='%s' src='gui/menubg' size-func='DATA.resize_menu_bg' "..
        "z-index='-1' interactive='true'/>", bgid), controller)
    menubg = gui.root[bgid]
    controller.resize_menu_bg()
end

function on_menu_setup()
    setup_backround()
    menu.page = "main"
    menu.visible = true
    -- app.open_world("gameboy")

    -- тот же путь, что и кнопка на странице меню "scripts"
    if not autorun_done then
        autorun_done = true
        local script = resolve_autorun_script()
        if script then
            __vc_start_app_script(script, script)
        end
    end
end
