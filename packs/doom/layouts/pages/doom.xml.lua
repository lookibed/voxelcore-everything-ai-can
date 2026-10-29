-- UI DOOM: выбор IWAD, экран, клавиатура. Логика игры — modules/engine.lua.

local engine = require "doom:engine"
local wasm_host = require "doom:wasm_host"

-- JIT: настройка LuaJIT под код Spider (-loop и большой кеш трасс), см. wasm_host.set_jit_tuned.
-- По умолчанию включено; действует, пока открыта страница.
local jit_tuned = true

local function update_jit_button()
    local button = document.jit_btn
    if button and button.exists then
        button.text = jit_tuned and "JIT tuning: ON" or "JIT tuning: OFF"
    end
end

function toggle_jit_tuning()
    jit_tuned = not jit_tuned
    wasm_host.set_jit_tuned(jit_tuned)
    update_jit_button()
end

local TIMER_INTERVAL_MS = 4
-- игровые тики DOOM идут 35 раз в секунду
local TIC_MS = 1000 / 35
-- место под панели сверху и снизу при подборе размера экрана
local RESERVED_HEIGHT = 110
-- DOOM рисовал 320x200 для экрана 4:3, то есть пиксели на 20% выше ширины
local PIXEL_ASPECT = 1.2
local SCREEN_TEXTURE = "doom_screen_" .. random.uuid()

local K = engine.KEYS
-- клавиша VoxelCore -> код клавиши DOOM
local BINDINGS = {
    { "key:up", K.UPARROW }, { "key:w", K.UPARROW },
    { "key:down", K.DOWNARROW }, { "key:s", K.DOWNARROW },
    { "key:left", K.LEFTARROW },
    { "key:right", K.RIGHTARROW },
    { "key:a", K.STRAFE_L },
    { "key:d", K.STRAFE_R },
    { "key:left-ctrl", K.FIRE }, { "key:right-ctrl", K.FIRE },
    { "key:space", K.USE }, { "key:e", K.USE },
    { "key:left-shift", K.RSHIFT }, { "key:right-shift", K.RSHIFT },
    { "key:left-alt", K.RALT }, { "key:right-alt", K.RALT },
    { "key:escape", K.ESCAPE },
    { "key:enter", K.ENTER },
    { "key:tab", K.TAB },
    { "key:backspace", K.BACKSPACE },
    -- размер экрана DOOM: Page Down / Page Up (key:minus/key:equal оставлены на случай,
    -- если движок знает эти имена; в таблице клавиш VoxelCore их не видно)
    { "key:page-down", K.MINUS }, { "key:minus", K.MINUS },
    { "key:page-up", K.EQUALS }, { "key:equal", K.EQUALS },
}
for index = 1, 11 do
    table.insert(BINDINGS, { "key:f" .. index, K["F" .. index] })
end
-- цифры (оружие) и буквы (y/n в меню, чит-коды) — их ASCII-коды
for digit = 0, 9 do
    table.insert(BINDINGS, { "key:" .. digit, string.byte(tostring(digit)) })
end
for code = string.byte("a"), string.byte("z") do
    table.insert(BINDINGS, { "key:" .. string.char(code), code })
end

local session = nil
local selected_wad = engine.DEFAULT_WAD_PATH
local key_state = {}
local session_clock = 0
local tic_debt = 0
local status_text = "select a WAD and press Start"
local fps_value = 0
local fps_time = 0
local fps_frames = 0
local screen_size = nil
-- true: тики идут без ограничения 35/с. У doomgeneric один кадр = один игровой тик,
-- интерполяции нет, поэтому без лока игра ускоряется, а fps показывает предел машины.
local unlocked = true

local function basename(path)
    return (tostring(path):gsub("\\", "/"):match("([^/:]+)$")) or tostring(path)
end

local function el(id)
    local element = document[id]
    if element and element.exists then
        return element
    end
    return nil
end

local function set_status(text)
    status_text = text
    local label = el("status_label")
    if label then
        label.text = text
    end
end

local function update_labels()
    local start_btn = el("start_btn")
    if start_btn then
        start_btn.text = (session and not session.exited) and "Restart" or "Start"
    end
    local lock_btn = el("lock_btn")
    if lock_btn then
        lock_btn.text = unlocked and "35 fps lock: OFF" or "35 fps lock: ON"
    end
    local fps_label = el("fps_label")
    if fps_label then
        fps_label.text = string.format("fps %.1f", fps_value)
    end
    set_status(status_text)
end

-- Экран: скрытый canvas 320x200, текстура растягивается на GPU через <image>
-- с исправлением пропорций пикселя. region="0,1,1,0" — текстура canvas
-- в image приходит перевёрнутой по вертикали.
local function ensure_screen(width, height)
    if screen_size and screen_size[1] == width and screen_size[2] == height and el("screen_canvas") then
        return
    end
    if el("screen_canvas") then
        document.screen_canvas:destruct()
    end
    if el("screen_image") then
        document.screen_image:destruct()
    end

    local viewport = gui.get_viewport()
    local display_height = height * PIXEL_ASPECT
    local scale = math.min((viewport[1] - 20) / width, (viewport[2] - RESERVED_HEIGHT) / display_height)
    scale = math.max(1, scale)

    document.root:add(string.format('<canvas id="screen_canvas" size="%d,%d" visible="false"/>', width, height))
    document.screen_canvas.data:create_texture(SCREEN_TEXTURE)
    document.root:add(string.format(
        '<image id="screen_image" src="%s" size="%d,%d" gravity="center-center" region="0,1,1,0"/>',
        SCREEN_TEXTURE, math.floor(width * scale), math.floor(display_height * scale)))
    screen_size = { width, height }
end

local function present()
    ensure_screen(session.width, session.height)
    local data = document.screen_canvas.data
    data:set_data(session:get_frame())
    data:update()
end

local function release_all_keys()
    if session then
        for code, pressed in pairs(key_state) do
            if pressed then
                session:key(false, code)
            end
        end
    end
    key_state = {}
end

-- Опрос клавиатуры: DOOM ждёт события нажатия и отпускания.
local function poll_keys()
    local wanted = {}
    for _, binding in ipairs(BINDINGS) do
        if input.is_pressed(binding[1]) then
            wanted[binding[2]] = true
        end
    end
    for code in pairs(wanted) do
        if not key_state[code] then
            session:key(true, code)
        end
    end
    for code, pressed in pairs(key_state) do
        if pressed and not wanted[code] then
            session:key(false, code)
        end
    end
    key_state = wanted
end

local function stop_session()
    release_all_keys()
    session = nil
    fps_value = 0
end

local function start_session()
    stop_session()
    local ok, result = pcall(engine.create_session, selected_wad)
    if not ok then
        set_status("error: " .. tostring(result))
        update_labels()
        return false
    end
    session = result
    set_status("loading " .. basename(selected_wad) .. "...")
    local started_ok, started = pcall(session.start, session)
    if not started_ok or not started then
        set_status("error: " .. tostring(started_ok and session.message or started))
        session = nil
        update_labels()
        return false
    end
    session_clock = time.uptime()
    tic_debt = 0
    fps_time = time.uptime()
    fps_frames = session:frame_count()
    set_status("playing " .. basename(selected_wad))
    update_labels()
    debug.log("[doom] started " .. selected_wad)
    return true
end

local function count_fps()
    local now = time.uptime()
    if now - fps_time >= 0.5 then
        local frames = session:frame_count()
        fps_value = (frames - fps_frames) / (now - fps_time)
        fps_frames = frames
        fps_time = now
        update_labels()
    end
end

-- Таймер тикает часто; кадр DOOM считается, когда наступил следующий игровой тик.
-- Если рендер не успевает, DOOM сам догоняет пропущенные тики логики.
local last_tick_time = 0
local function tick()
    if not session or session.exited then
        return
    end
    local now = time.uptime()
    tic_debt = math.min(tic_debt + (now - last_tick_time) * 1000, TIC_MS * 4)
    last_tick_time = now
    poll_keys()
    if unlocked then
        tic_debt = 0
    elseif tic_debt < TIC_MS then
        return
    else
        tic_debt = tic_debt % TIC_MS
    end
    if not session:tick(math.floor((now - session_clock) * 1000)) then
        set_status(("DOOM stopped: %s"):format(tostring(session.message)))
        release_all_keys()
        update_labels()
        return
    end
    present()
    count_fps()
end

-- обработчики из XML ---------------------------------------------------------------

function select_wad(path)
    if type(path) == "string" and path ~= "" then
        selected_wad = path
    end
    set_status("selected " .. basename(selected_wad))
end

function start_selected_wad()
    start_session()
end

function toggle_lock()
    unlocked = not unlocked
    debug.log("[doom] fps lock " .. (unlocked and "off" or "on"))
    update_labels()
end

function leave()
    wasm_host.set_jit_tuned(false)
    stop_session()
    events.emit("doom:leave_to_menu")
end

-- Внешний запуск (сценарии, другие паки): events.emit("doom:open_wad", path)
local function open_wad(path)
    local wad_select = el("wad_select")
    if wad_select then
        wad_select.value = path
    end
    selected_wad = path
    start_session()
end

-- построение UI ------------------------------------------------------------------

local function build_ui()
    document.root:add([[
<panel id="top_panel" gravity="top-center" size="980,44" orientation="horizontal" interval="6" padding="6" color="#00000080">
    <select id="wad_select" size="380,32" onselect="select_wad(opt)"/>
    <button id="start_btn" size="120,32" onclick="start_selected_wad()">Start</button>
    <button id="lock_btn" size="190,32" onclick="toggle_lock()">35 fps lock: ON</button>
    <label id="fps_label" size="100,32">fps 0.0</label>
    <button id="jit_btn" size="150,32" onclick="toggle_jit_tuning()">JIT tuning: ON</button>
</panel>
]])
    document.root:add([[
<panel id="bottom_panel" gravity="bottom-center" size="900,54" interval="2" padding="4" color="#00000080">
    <label id="status_label" size="890,20">...</label>
    <label size="890,20">WASD/arrows move, Ctrl fire, Space use, Shift run, Alt strafe, 1-7 weapons, Esc menu, Tab map, PgUp/PgDn size</label>
</panel>
]])

    local wads = engine.list_wads()
    document.wad_select.options = wads
    local has_default = false
    for _, option in ipairs(wads) do
        if option.value == selected_wad then
            has_default = true
        end
    end
    if not has_default and wads[1] then
        selected_wad = wads[1].value
    end
    document.wad_select.value = selected_wad

    last_tick_time = time.uptime()
    document.root:setInterval(TIMER_INTERVAL_MS, tick)
    -- Escape нужен самому DOOM (его меню): не отдаём его движку
    input.add_callback("key:escape", function()
        return true
    end, document.root)
end

local is_built = false

function on_open()
    wasm_host.set_jit_tuned(jit_tuned)
    update_jit_button()
    if is_built then
        return
    end
    build_ui()
    events.on("doom:open_wad", open_wad)
    is_built = true
    update_labels()
end

function on_close()
    wasm_host.set_jit_tuned(false)
end
