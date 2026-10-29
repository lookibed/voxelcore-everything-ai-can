-- UI эмулятора Game Boy. Общий для страницы меню (pages/emulator.xml)
-- и HUD-оверлея в мире (emulator.xml), см. layouts/emulator.xml.lua.

local emulator = require "gameboy:emulator"
local wasm_host = require "gameboy:wasm_host"

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

local FRAME_INTERVAL_MS = 4
-- частота кадров настоящего Game Boy (4194304 / 70224)
local GB_FRAME_TIME = 70224 / 4194304
local MAX_SCALE = 4
-- место под панели сверху и снизу при подборе масштаба экрана
local RESERVED_HEIGHT = 260
local SCREEN_TEXTURE = "gameboy_screen_" .. random.uuid()

local KEY_BINDINGS = {
    { "key:z", "A" },
    { "key:x", "B" },
    { "key:backspace", "SELECT" },
    { "key:right-shift", "SELECT" },
    { "key:enter", "START" },
    { "key:right", "RIGHT" },
    { "key:left", "LEFT" },
    { "key:up", "UP" },
    { "key:down", "DOWN" },
}

local session = nil
local current_frame = nil
local is_running = false
local is_paused = false
local audio_enabled = false
local selected_rom = emulator.DEFAULT_ROM_PATH
local selected_preset = "auto"
local active_preset = "auto"
local buttons_mask = 0
local status_message = "select a ROM and press Start"
local fps_value = 0
local fps_last_time = 0
local fps_counter = 0
local screen_size = nil
local frame_clock = 0
local frame_debt = 0
-- Лок частоты: по умолчанию кадры идут с частотой настоящего Game Boy (59.7/с).
-- Без лока за тик движка эмулируется столько кадров, сколько влезает в
-- UNLOCKED_BUDGET, и счётчик fps показывает предел машины (игра ускоряется).
local unlocked = false
local UNLOCKED_BUDGET = 0.010
-- Калибровка JIT при старте ROM (emulator: session:calibrate), квант на тик таймера.
local calibrating = false
local calibrate_started = 0
local CALIBRATE_BUDGET = 0.010

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
    status_message = text
    local label = el("status_label")
    if label then
        label.text = text
    end
end

local function sync_from_ui()
    local rom_select = el("rom_select")
    if rom_select and rom_select.value and rom_select.value ~= "" then
        selected_rom = rom_select.value
    end
    local preset_select = el("preset_select")
    if preset_select and preset_select.value and preset_select.value ~= "" then
        selected_preset = preset_select.value
    end
end

local function update_controls()
    local start_btn = el("start_btn")
    if start_btn then
        start_btn.text = is_running and "Restart" or "Start"
    end
    local toggle_btn = el("toggle_btn")
    if toggle_btn then
        toggle_btn.text = is_paused and "Play" or "Pause"
        toggle_btn.enabled = is_running
    end
    local step_btn = el("step_btn")
    if step_btn then
        step_btn.enabled = is_running and is_paused
    end
    local audio_btn = el("audio_btn")
    if audio_btn then
        audio_btn.text = audio_enabled and "Audio On" or "Audio Off"
    end
    local lock_btn = el("lock_btn")
    if lock_btn then
        lock_btn.text = unlocked and "59.7 fps lock: OFF" or "59.7 fps lock: ON"
    end
    local fps_label = el("fps_label")
    if fps_label then
        fps_label.text = string.format("fps %.1f", fps_value)
    end
    local frame_label = el("frame_label")
    if frame_label then
        if current_frame then
            frame_label.text = string.format("frame %d | buttons %d", current_frame.frame_index, buttons_mask)
        else
            frame_label.text = "not started"
        end
    end
    set_status(status_message)
end

-- Экран: скрытый canvas с кадром в родном разрешении, его текстура
-- растягивается на GPU через <image>. region="0,1,1,0" — текстура canvas
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
    local scale = math.floor(math.min((viewport[1] - 40) / width, (viewport[2] - RESERVED_HEIGHT) / height))
    scale = math.max(1, math.min(MAX_SCALE, scale))

    document.root:add(string.format('<canvas id="screen_canvas" size="%d,%d" visible="false"/>', width, height))
    document.screen_canvas.data:create_texture(SCREEN_TEXTURE)
    document.root:add(string.format(
        '<image id="screen_image" src="%s" size="%d,%d" gravity="center-center" region="0,1,1,0"/>',
        SCREEN_TEXTURE, width * scale, height * scale))
    screen_size = { width, height }
end

local function render_frame(frame)
    ensure_screen(frame.width, frame.height)
    local data = document.screen_canvas.data
    data:set_data(frame.rgba)
    data:update()
    current_frame = frame
end

local function compose_buttons_mask()
    local mask = 0
    local seen = {}
    for _, binding in ipairs(KEY_BINDINGS) do
        local button = binding[2]
        if not seen[button] and input.is_pressed(binding[1]) then
            mask = mask + emulator.BUTTON_BITS[button]
            seen[button] = true
        end
    end
    return mask
end

local function reset_fps()
    fps_value = 0
    fps_last_time = time.uptime()
    fps_counter = 0
end

local function count_fps()
    local now = time.uptime()
    fps_counter = fps_counter + 1
    if now - fps_last_time >= 0.5 then
        fps_value = fps_counter / (now - fps_last_time)
        fps_counter = 0
        fps_last_time = now
    end
end

local function stop_session()
    if session then
        session:teardown_audio()
    end
    session = nil
    current_frame = nil
    is_running = false
    is_paused = false
    buttons_mask = 0
    reset_fps()
end

local function start_session()
    sync_from_ui()
    stop_session()

    active_preset = selected_preset
    if active_preset == "auto" or active_preset == "" then
        active_preset = emulator.select_default_preset(selected_rom)
    end

    local ok, result = pcall(emulator.create_session, selected_rom, {
        preset_name = active_preset,
        audio_enabled = audio_enabled,
    })
    if not ok then
        set_status("error: " .. tostring(result))
        update_controls()
        return false
    end

    local new_session = result
    local frame_ok, frame = pcall(new_session.start, new_session)
    if not frame_ok then
        set_status("error: " .. tostring(frame))
        update_controls()
        return false
    end

    session = new_session
    is_running = true
    calibrating = true
    calibrate_started = time.uptime()
    render_frame(frame)
    set_status(string.format("JIT calibration %s...", basename(selected_rom)))
    update_controls()
    return true
end

local function step()
    buttons_mask = compose_buttons_mask()
    session:set_buttons(buttons_mask)
    local ok, frame = pcall(session.step_frame, session)
    if not ok then
        set_status("error: " .. tostring(frame))
        is_running = false
        is_paused = true
        update_controls()
        return false
    end
    render_frame(frame)
    count_fps()
    return true
end

-- Таймер тикает чаще кадра; кадр эмулируется, когда накопилось GB_FRAME_TIME,
-- чтобы игра не шла быстрее оригинала. Отставание не догоняется больше чем на кадр.
local function tick()
    if not is_running or is_paused or not session then
        frame_clock = time.uptime()
        frame_debt = 0
        return
    end
    local now = time.uptime()
    if calibrating then
        frame_clock = now
        frame_debt = 0
        local ok, done = pcall(session.calibrate, session, CALIBRATE_BUDGET)
        if not ok then
            calibrating = false
            set_status("error: " .. tostring(done))
            is_running = false
            update_controls()
            return
        end
        local c = session.calibration
        if not done then
            set_status(string.format("JIT calibration %s: roll %d (%s fps)", basename(selected_rom), c.roll,
                #c.fps > 0 and table.concat(c.fps, " ") or "..."))
            return
        end
        calibrating = false
        debug.log(("[gameboy] jit calibration %s: rolls=%d fps={%s} cpu %.2fs wall %.2fs"):format(
            basename(selected_rom), c.roll, table.concat(c.fps, " "), c.cpu, time.uptime() - calibrate_started))
        reset_fps()
        render_frame(session:get_frame())
        set_status(string.format("running %s | preset %s | jit rolls %d", basename(selected_rom), active_preset, c.roll))
        update_controls()
        return
    end
    if unlocked then
        frame_clock = now
        frame_debt = 0
        local deadline = os.clock() + UNLOCKED_BUDGET
        repeat
            if not step() then
                return
            end
        until os.clock() >= deadline
        update_controls()
        return
    end
    frame_debt = math.min(frame_debt + (now - frame_clock), GB_FRAME_TIME * 2)
    frame_clock = now
    if frame_debt < GB_FRAME_TIME then
        return
    end
    frame_debt = frame_debt - GB_FRAME_TIME
    if step() then
        update_controls()
    end
end

-- обработчики из XML/коллбеков -------------------------------------------------

function select_rom(path)
    if type(path) == "string" and path ~= "" then
        selected_rom = path
    end
    set_status("selected " .. basename(selected_rom))
    update_controls()
end

function select_preset(preset)
    if type(preset) == "string" and preset ~= "" then
        selected_preset = preset
    end
    set_status("preset " .. selected_preset)
    update_controls()
end

function start_selected_rom()
    start_session()
end

function toggle_lock()
    unlocked = not unlocked
    debug.log("[gameboy] fps lock " .. (unlocked and "off" or "on"))
    update_controls()
end

function toggle_playback()
    if not is_running then
        return
    end
    is_paused = not is_paused
    set_status(is_paused and "paused" or ("running " .. basename(selected_rom)))
    update_controls()
end

function step_once()
    if not is_running or not is_paused or not session then
        return
    end
    if step() then
        set_status(string.format("paused | frame %d", current_frame.frame_index))
        update_controls()
    end
end

function toggle_audio()
    audio_enabled = not audio_enabled
    if session then
        local ok, result = pcall(session.set_audio_enabled, session, audio_enabled)
        if not ok then
            audio_enabled = false
            set_status("audio error: " .. tostring(result))
        end
    end
    update_controls()
end

function leave()
    wasm_host.set_jit_tuned(false)
    stop_session()
    events.emit("gameboy:leave_to_menu")
end


-- Внешний запуск ROM-а (сценарии, другие паки): events.emit("gameboy:open_rom", path[, preset]).
-- Подписка делается в on_open: скрипт оверлея исполняется при загрузке контента,
-- даже если оверлей не открыт, и не должен реагировать на событие.
local function open_rom(path, preset)
    local rom_select = el("rom_select")
    if rom_select then
        rom_select.value = path
    end
    selected_rom = path
    if preset then
        selected_preset = preset
        local preset_select = el("preset_select")
        if preset_select then
            preset_select.value = preset
        end
    end
    local ok = start_session()
    debug.log(("[gameboy] open_rom %s ok=%s"):format(tostring(path), tostring(ok)))
end

-- построение UI ------------------------------------------------------------------

local function build_ui()
    document.root:add([[
<panel id="rom_panel" gravity="top-center" size="660,118" interval="6" padding="6" color="#00000080">
    <label id="status_label" size="640,20">...</label>
    <panel orientation="horizontal" size="640,36" interval="6">
        <select id="rom_select" size="504,32" onselect="select_rom(opt)"/>
        <button id="start_btn" size="130,32" onclick="start_selected_rom()">Start</button>
    </panel>
    <panel orientation="horizontal" size="640,36" interval="6">
        <select id="preset_select" size="220,32" onselect="select_preset(opt)"/>
        <label size="414,32">Z=A X=B Enter=Start Backspace=Select Arrows=DPad</label>
    </panel>
</panel>
]])
    document.root:add([[
<panel id="controls_panel" gravity="bottom-center" size="1010,44" orientation="horizontal" interval="6" padding="6" color="#00000080">
    <button id="toggle_btn" size="110,32" onclick="toggle_playback()">Pause</button>
    <button id="step_btn" size="110,32" onclick="step_once()">Step</button>
    <button id="audio_btn" size="120,32" onclick="toggle_audio()">Audio Off</button>
    <button id="lock_btn" size="180,32" onclick="toggle_lock()">59.7 fps lock: ON</button>
    <label id="fps_label" size="90,32">fps 0.0</label>
    <label id="frame_label" size="190,32">not started</label>
    <button id="jit_btn" size="150,32" onclick="toggle_jit_tuning()">JIT tuning: ON</button>
</panel>
]])

    local roms = emulator.list_roms()
    document.rom_select.options = roms
    local has_default = false
    for _, option in ipairs(roms) do
        if option.value == selected_rom then
            has_default = true
        end
    end
    if not has_default and roms[1] then
        selected_rom = roms[1].value
    end
    document.rom_select.value = selected_rom
    document.preset_select.options = emulator.PRESET_OPTIONS
    document.preset_select.value = selected_preset

    document.root:setInterval(FRAME_INTERVAL_MS, tick)
    input.add_callback("key:space", function()
        toggle_playback()
        return true
    end, document.root)
    input.add_callback("key:period", function()
        step_once()
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
    events.on("gameboy:open_rom", open_rom)
    is_built = true
    update_controls()
end

function on_close()
    wasm_host.set_jit_tuned(false)
end
