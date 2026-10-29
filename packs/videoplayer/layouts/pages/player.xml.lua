-- UI видеоплеера. Общий для страницы меню (pages/player.xml)
-- и HUD-оверлея в мире (player.xml), см. layouts/player.xml.lua.
--
-- Видео декодируется потоково в фоновой корутине: каждый тик ей даётся квант
-- времени, декод вперёд идёт на READ_AHEAD кадров, длинный кадр прерывается
-- посередине (decoder: checkpoint) и доделывается на следующих тиках, так что
-- окно не замирает. Воспроизведение — с частотой из таймкодов mp4. Звук не поддерживается.

local decoder = require "videoplayer:decoder"
local wasm_host = require "videoplayer:wasm_host"

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
-- квант фонового декода за один тик таймера, секунды
local DECODE_SLICE = 0.008
-- сколько кадров декодировать вперёд от текущего
local READ_AHEAD = 30
-- сколько кадров позади текущего держать в кэше для Prev
local KEEP_BEHIND = 30
-- предел памяти под кэш кадров (RGBA), байты
local CACHE_LIMIT_BYTES = 384 * 1024 * 1024
-- место под панели сверху и снизу при подборе размера экрана
local RESERVED_HEIGHT = 260
local SCREEN_TEXTURE = "videoplayer_screen_" .. random.uuid()

local session = nil
local worker = nil            -- корутина фонового декода
local frames = {}             -- кэш: индекс -> кадр
local cache_bytes = 0
local total_frames = nil      -- известно, когда поток дошёл до конца
local current_index = -1      -- показанный кадр
local wanted_index = 0        -- кадр, который надо показать как только он появится
local is_playing = false
local next_frame_time = 0
local error_text = nil
local selected_video = decoder.DEFAULT_VIDEO_PATH
local screen_size = nil
local decode_time, decoded_count = 0, 0
-- Лок частоты: по умолчанию кадры показываются по таймкодам mp4. Без лока следующий
-- кадр показывается сразу, как только декодирован (предел декодера).
local unlocked = false
local shown_count, shown_time, shown_fps = 0, 0, 0

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

local function frame_total()
    return total_frames or (session and session.sample_count) or 0
end

local function status_text()
    local name = basename(selected_video)
    if error_text then
        return name .. " | error: " .. error_text
    end
    if not session then
        return name .. " | press Open"
    end
    local speed = decoded_count > 0 and string.format(" | decode %.0f ms/frame", decode_time / decoded_count * 1000) or ""
    local fps = is_playing and string.format(" | %.1f fps", shown_fps) or ""
    return string.format("%s | frame %d / %d | %s%s%s", name, math.max(0, current_index) + 1, frame_total(),
        is_playing and "playing" or "paused", fps, speed)
end

local function update_controls()
    local label = el("status_label")
    if label then
        label.text = status_text()
    end
    local open_btn = el("decode_btn")
    if open_btn then
        open_btn.text = session and "Reopen" or "Open"
    end
    local toggle_btn = el("toggle_btn")
    if toggle_btn then
        toggle_btn.text = is_playing and "Pause" or "Play"
        toggle_btn.enabled = session ~= nil
    end
    local prev_btn, next_btn = el("prev_btn"), el("next_btn")
    if prev_btn then
        prev_btn.enabled = session ~= nil
    end
    if next_btn then
        next_btn.enabled = session ~= nil
    end
    local lock_btn = el("lock_btn")
    if lock_btn then
        lock_btn.text = unlocked and "fps lock: OFF" or "fps lock: ON"
    end
    local cache_label = el("cache_label")
    if cache_label then
        cache_label.text = string.format("cache: %d MB", math.floor(cache_bytes / 1048576 + 0.5))
    end
    local bar, outer = el("progress_inner"), el("progress_outer")
    if bar and outer then
        local full = outer.size[1]
        local total = frame_total()
        local width = total > 0 and math.floor((math.max(0, current_index) + 1) / total * full) or 0
        bar.size = { math.max(0, math.min(full, width)), bar.size[2] }
    end
end

-- Экран: скрытый canvas с кадром в родном разрешении, его текстура
-- масштабируется на GPU через <image> под размер окна. region="0,1,1,0" —
-- текстура canvas в image приходит перевёрнутой по вертикали.
--
-- При смене разрешения image не пересоздаётся (меняются его size и src), а canvas
-- создаётся заново с новым id и новой текстурой: destruct + add с тем же id
-- иногда оставлял на экране старый image старого размера.
local screen_canvas = nil
local screen_generation = 0

local function ensure_screen(width, height)
    if screen_size and screen_size[1] == width and screen_size[2] == height
            and screen_canvas and screen_canvas.exists then
        return
    end
    if screen_canvas and screen_canvas.exists then
        screen_canvas:destruct()
    end
    screen_generation = screen_generation + 1
    local canvas_id = "screen_canvas_" .. screen_generation
    local texture = SCREEN_TEXTURE .. "_" .. screen_generation

    local viewport = gui.get_viewport()
    local scale = math.min((viewport[1] - 40) / width, (viewport[2] - RESERVED_HEIGHT) / height)
    if scale >= 1 then
        scale = math.floor(scale)
    end
    local display_width = math.max(1, math.floor(width * scale))
    local display_height = math.max(1, math.floor(height * scale))

    document.root:add(string.format('<canvas id="%s" size="%d,%d" visible="false"/>', canvas_id, width, height))
    screen_canvas = document[canvas_id]
    screen_canvas.data:create_texture(texture)

    local image = el("screen_image")
    if image then
        image.src = texture
        image.size = { display_width, display_height }
        image:reposition()
    else
        document.root:add(string.format(
            '<image id="screen_image" src="%s" size="%d,%d" gravity="center-center" region="0,1,1,0"/>',
            texture, display_width, display_height))
    end
    screen_size = { width, height }
    debug.log(("[videoplayer] screen %dx%d -> %dx%d"):format(width, height, display_width, display_height))
end

local function show_frame(frame)
    ensure_screen(frame.width, frame.height)
    local data = screen_canvas.data
    data:set_data(frame.rgba)
    data:update()
    current_index = frame.frame_index
    shown_count = shown_count + 1
    local now = time.uptime()
    if now - shown_time >= 0.5 then
        shown_fps = shown_count / (now - shown_time)
        shown_count, shown_time = 0, now
    end
    update_controls()
end

local function drop_frame(index)
    cache_bytes = cache_bytes - #frames[index].rgba
    frames[index] = nil
end

-- Держим в кэше только окно [wanted - KEEP_BEHIND, wanted + READ_AHEAD + 1]. Если и оно
-- не влезает в предел (очень большие кадры), первыми уходят кадры позади текущего,
-- чтобы фоновый декод мог дойти до нужного кадра и не встал навсегда.
local function trim_cache()
    local low, high = wanted_index - KEEP_BEHIND, wanted_index + READ_AHEAD + 1
    for index in pairs(frames) do
        if index < low or index > high then
            drop_frame(index)
        end
    end
    for index = low, wanted_index - 1 do
        if cache_bytes <= CACHE_LIMIT_BYTES then
            break
        end
        if frames[index] then
            drop_frame(index)
        end
    end
end

local function store_frame(frame)
    frames[frame.frame_index] = frame
    cache_bytes = cache_bytes + #frame.rgba
    trim_cache()
end

local function clear_cache()
    frames = {}
    cache_bytes = 0
end

-- Фоновый декод: идёт вперёд, пока не опередит wanted_index на READ_AHEAD кадров.
local function worker_body()
    while true do
        if not session.finished and session.next_index <= wanted_index + READ_AHEAD
                and cache_bytes <= CACHE_LIMIT_BYTES then
            local frame = session:next()
            if frame then
                decoded_count = decoded_count + 1
                -- кадры задолго до нужного (перемотка назад) не храним
                if frame.frame_index >= wanted_index - KEEP_BEHIND then
                    store_frame(frame)
                end
            else
                total_frames = session.next_index
                debug.log(("[videoplayer] stream end: %d frames, cache %d MB"):format(
                    total_frames, math.floor(cache_bytes / 1048576 + 0.5)))
            end
            if os.clock() >= session.slice_deadline then
                coroutine.yield("slice")
            end
        else
            coroutine.yield("idle")
        end
    end
end

local function start_worker()
    worker = coroutine.create(worker_body)
    session:set_driver(worker)
end

local function run_worker()
    if not worker then
        return
    end
    session:begin_slice(DECODE_SLICE)
    -- время считается только внутри корутины: кадр может декодироваться несколько тиков
    local started = os.clock()
    local ok, err = coroutine.resume(worker)
    decode_time = decode_time + (os.clock() - started)
    if not ok then
        error_text = tostring(err)
        debug.log("[videoplayer] decode error: " .. error_text)
        worker = nil
        is_playing = false
        update_controls()
    end
end

local function reset_state()
    session = nil
    worker = nil
    clear_cache()
    total_frames = nil
    current_index = -1
    wanted_index = 0
    is_playing = false
    error_text = nil
    decode_time, decoded_count = 0, 0
end

-- Перейти к кадру index: из кэша, иначе ждать фоновый декод; назад за кэш —
-- перезапустить поток и прокрутить вперёд.
local function seek(index)
    local total = frame_total()
    if total > 0 then
        if index < 0 then
            index = total - 1
        elseif total_frames and index >= total_frames then
            index = 0
        end
    end
    wanted_index = index
    if frames[index] then
        show_frame(frames[index])
        return
    end
    if index < session.next_index then
        session:open()
        clear_cache()
        start_worker()
    end
end

local function open_selected()
    local video_select = el("video_select")
    if video_select and video_select.value and video_select.value ~= "" then
        selected_video = video_select.value
    end
    reset_state()
    local ok, err = pcall(function()
        session = decoder.create_session(selected_video)
        session:open()
    end)
    if not ok then
        session = nil
        error_text = tostring(err)
        update_controls()
        return
    end
    start_worker()
    debug.log(("[videoplayer] opened %s: %d samples"):format(selected_video, session.sample_count))
    update_controls()
end

-- тик: фоновый декод, показ нужного кадра, воспроизведение по таймкодам
local function tick()
    if not session then
        return
    end
    trim_cache()
    run_worker()
    if not session then
        return
    end

    local now = time.uptime()
    if is_playing and current_index >= 0 and (unlocked or now >= next_frame_time) then
        local next_index = current_index + 1
        if total_frames and next_index >= total_frames then
            next_index = 0
        end
        wanted_index = next_index
    end

    if wanted_index ~= current_index then
        local frame = frames[wanted_index]
        if frame then
            show_frame(frame)
            -- не копим отставание больше чем на кадр
            next_frame_time = math.max(next_frame_time + session.frame_duration, now)
        elseif total_frames and wanted_index == 0 and session.next_index > 0 and not frames[0] then
            seek(0)
        end
    end
end

-- обработчики из XML/коллбеков -------------------------------------------------

function select_video(path)
    if type(path) == "string" and path ~= "" then
        selected_video = path
    end
    reset_state()
    update_controls()
end

function decode_selected_video()
    open_selected()
end

function step_next()
    if not session then
        return
    end
    is_playing = false
    seek(math.max(0, current_index) + 1)
    update_controls()
end

function step_prev()
    if not session then
        return
    end
    is_playing = false
    seek(current_index - 1)
    update_controls()
end

function toggle_lock()
    unlocked = not unlocked
    next_frame_time = time.uptime()
    update_controls()
end

function toggle_playback()
    if not session then
        return
    end
    is_playing = not is_playing
    next_frame_time = time.uptime()
    update_controls()
end

function leave()
    wasm_host.set_jit_tuned(false)
    reset_state()
    events.emit("videoplayer:leave_to_menu")
end

-- Внешний запуск (сценарии, другие паки): events.emit("videoplayer:open_video", path[, play]).
-- Подписка делается в on_open: скрипт оверлея исполняется при загрузке контента,
-- даже если оверлей не открыт, и не должен реагировать на событие.
local function open_video(path, play)
    local video_select = el("video_select")
    if video_select then
        video_select.value = path
    end
    selected_video = path
    open_selected()
    if play and session then
        is_playing = true
        next_frame_time = time.uptime()
    end
    debug.log("[videoplayer] open_video " .. tostring(path))
end

-- построение UI ------------------------------------------------------------------

local function build_ui()
    document.root:add([[
<panel id="video_panel" gravity="top-center" size="700,118" interval="6" padding="6" color="#00000080">
    <label id="status_label" size="680,20">...</label>
    <panel orientation="horizontal" size="540,36" interval="6">
        <select id="video_select" size="404,32" onselect="select_video(opt)"/>
        <button id="decode_btn" size="130,32" onclick="decode_selected_video()">Open</button>
    </panel>
    <container id="progress_outer" color="#202020FF" size="320,18" margin="0,6,0,0">
        <container id="progress_inner" color="#38D46AFF" size="0,18"/>
    </container>
</panel>
]])
    document.root:add([[
<panel id="controls_panel" gravity="bottom-center" size="770,44" orientation="horizontal" interval="6" padding="6" color="#00000080">
    <button id="prev_btn" size="80,32" onclick="step_prev()">Prev</button>
    <button id="toggle_btn" size="120,32" onclick="toggle_playback()">Play</button>
    <button id="next_btn" size="80,32" onclick="step_next()">Next</button>
    <button id="lock_btn" size="140,32" onclick="toggle_lock()">fps lock: ON</button>
    <label id="cache_label" size="150,32">cache: 0 MB</label>
    <button id="jit_btn" size="150,32" onclick="toggle_jit_tuning()">JIT tuning: ON</button>
</panel>
]])

    local videos = decoder.list_videos()
    document.video_select.options = videos
    local has_default = false
    for _, option in ipairs(videos) do
        if option.value == selected_video then
            has_default = true
        end
    end
    if not has_default and videos[1] then
        selected_video = videos[1].value
    end
    document.video_select.value = selected_video

    document.root:setInterval(TIMER_INTERVAL_MS, tick)
    input.add_callback("key:space", function()
        toggle_playback()
        return true
    end, document.root)
    input.add_callback("key:right", function()
        step_next()
        return true
    end, document.root)
    input.add_callback("key:left", function()
        step_prev()
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
    events.on("videoplayer:open_video", open_video)
    is_built = true
    update_controls()
end

function on_close()
    wasm_host.set_jit_tuned(false)
end
