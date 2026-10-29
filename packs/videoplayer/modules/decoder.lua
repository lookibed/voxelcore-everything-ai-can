-- Декодер MP4 (H.264 baseline): minimp4 + h264bsd (C) -> wasm -> Lua (Spider).
-- Модуль отдаёт кадры в RGBA; UI живёт в layouts/pages/player.xml.lua.
--
-- Декод потоковый: mp4 и декодер открываются один раз, next() отдаёт следующий
-- кадр. Если next() вызывается из корутины, назначенной сессии (set_driver), то
-- декод и перевод в RGBA сами уступают управление, когда исчерпан квант времени
-- (begin_slice), и длинный кадр растягивается на несколько кадров движка.

local wasm_host = require "videoplayer:wasm_host"

local GENERATED_MODULE_PATH = "videoplayer:modules/h264mp4/h264mp4.lua"

-- Видео ищутся в паке и в пользовательской папке config/videoplayer/videos.
local VIDEO_DIRS = {
    "videoplayer:videos",
    "config:videoplayer/videos",
}
local DEFAULT_VIDEO_PATH = "videoplayer:videos/sample.mp4"

-- Как часто wasm-декодер зовёт host.checkpoint: раз в столько макроблоков (16x16).
local CHECKPOINT_MACROBLOCKS = 64
-- Как часто перевод в RGBA проверяет квант времени: раз в столько строк.
local RGBA_ROWS_PER_CHECK = 16

local wasm_loader = nil

local function basename(path)
    return (path:gsub("\\", "/"):match("([^/:]+)$")) or path
end

-- Список видео для select: { value = путь, text = имя }.
local function list_videos()
    local options = {}
    for _, dir in ipairs(VIDEO_DIRS) do
        if file.isdir(dir) then
            local names = file.list(dir)
            table.sort(names)
            for _, entry in ipairs(names) do
                local name = basename(entry)
                if name:lower():match("%.mp4$") then
                    local text = name
                    if dir:sub(1, 7) == "config:" then
                        text = name .. "  [config]"
                    end
                    table.insert(options, { value = dir .. "/" .. name, text = text })
                end
            end
        end
    end
    return options
end

-- Таблицы коэффициентов BT.601 (full range). Порядок операций тот же, что был
-- в исходном адаптере, поэтому результат совпадает с ним побайтно.
local R_CR, G_CB, G_CR, B_CB = {}, {}, {}, {}
for value = 0, 255 do
    local c = value - 128
    R_CR[value] = 1.402 * c
    G_CB[value] = 0.344136 * c
    G_CR[value] = 0.714136 * c
    B_CB[value] = 1.772 * c
end

local floor = math.floor

local function clamp_byte(value)
    if value < 0 then
        return 0
    end
    if value > 255 then
        return 255
    end
    return value
end

-- YUV 4:2:0 (три плоскости Bytearray) -> RGBA Bytearray. checkpoint вызывается
-- между строками, чтобы длинный перевод можно было прервать.
local function yuv420_to_rgba(width, height, y_plane, u_plane, v_plane, checkpoint)
    local rgba = Bytearray(width * height * 4)
    local out = rgba.bytes
    local yp, up, vp = y_plane.bytes, u_plane.bytes, v_plane.bytes
    local uv_width = floor(width / 2)
    local o = 0

    for y = 0, height - 1 do
        local y_row = y * width
        local uv_row = floor(y / 2) * uv_width
        for x = 0, width - 1 do
            local c = yp[y_row + x]
            local uv_index = uv_row + floor(x / 2)
            local cb = up[uv_index]
            local cr = vp[uv_index]
            out[o] = clamp_byte(floor(c + R_CR[cr] + 0.5))
            out[o + 1] = clamp_byte(floor(c - G_CB[cb] - G_CR[cr] + 0.5))
            out[o + 2] = clamp_byte(floor(c + B_CB[cb] + 0.5))
            out[o + 3] = 255
            o = o + 4
        end
        if checkpoint and y % RGBA_ROWS_PER_CHECK == 0 then
            checkpoint()
        end
    end
    return rgba
end

-- Сессия декодера для одного mp4.
--   open()                 — загрузить файл и открыть поток (кадры с начала);
--   next()                 — следующий кадр { frame_index, width, height, rgba } или nil в конце;
--   set_driver(co)         — корутина, из которой зовётся next() и которой можно уступать;
--   begin_slice(seconds)   — начать квант времени для этой корутины;
--   decode_frame(i)        — совместимость: кадр i (перезапуск потока и прокрутка вперёд).
local function create_session(mp4_path)
    local path = mp4_path or DEFAULT_VIDEO_PATH
    assert(file.isfile(path), "video file not found: " .. path)
    local mp4_bytes = file.read_bytes(path)

    local session = {
        path = path,
        name = basename(path),
        sample_count = 0,
        frame_duration = 1 / 30,
        next_index = 0,
        finished = false,
        driver = nil,
        slice_deadline = math.huge,
        yields = 0,
    }

    -- Уступаем только своей корутине и только когда квант исчерпан.
    local function checkpoint()
        local current = coroutine.running()
        if current ~= nil and current == session.driver and os.clock() >= session.slice_deadline then
            session.yields = session.yields + 1
            coroutine.yield("checkpoint")
        end
    end

    if not wasm_loader then
        wasm_loader = wasm_host.load_generated(GENERATED_MODULE_PATH)
    end
    wasm_host.flush_jit()
    local wasm = wasm_loader({ host = { checkpoint = checkpoint } })
    local memory = assert(wasm.memory and wasm.memory[1], "wasm memory is unavailable")
    session.wasm, session.memory = wasm, memory

    function session:set_driver(co)
        self.driver = co
    end

    function session:begin_slice(seconds)
        self.slice_deadline = os.clock() + seconds
    end

    function session:open()
        -- куча wasm-модуля не освобождает память: сбрасываем её и заново кладём файл
        assert(self.wasm.h264mp4_host_reset() == 1, "decoder reset failed")
        local ptr = self.wasm.h264mp4_host_alloc(#mp4_bytes)
        assert(ptr ~= 0, "decoder input allocation failed")
        wasm_host.write_bytes(self.memory, ptr, mp4_bytes)
        assert(self.wasm.h264mp4_stream_open(ptr, #mp4_bytes) == 1, "not an H.264 baseline mp4: " .. self.name)
        self.wasm.h264mp4_host_set_checkpoint_interval(CHECKPOINT_MACROBLOCKS)
        self.sample_count = self.wasm.h264mp4_stream_sample_count()
        self.next_index = 0
        self.finished = false
        return true
    end

    function session:next()
        if self.finished then
            return nil
        end
        if self.wasm.h264mp4_stream_next() ~= 1 then
            self.finished = true
            return nil
        end

        local width = self.wasm.h264mp4_host_get_width()
        local height = self.wasm.h264mp4_host_get_height()
        assert(width > 0 and height > 0, "decoder returned invalid frame size")
        local duration_us = self.wasm.h264mp4_stream_frame_duration_us()
        if duration_us > 0 then
            self.frame_duration = duration_us / 1e6
        end

        local y_plane = wasm_host.read_bytes(self.memory, self.wasm.h264mp4_host_get_y_ptr(), self.wasm.h264mp4_host_get_y_size())
        local u_plane = wasm_host.read_bytes(self.memory, self.wasm.h264mp4_host_get_u_ptr(), self.wasm.h264mp4_host_get_u_size())
        local v_plane = wasm_host.read_bytes(self.memory, self.wasm.h264mp4_host_get_v_ptr(), self.wasm.h264mp4_host_get_v_size())

        local frame = {
            frame_index = self.next_index,
            width = width,
            height = height,
            rgba = yuv420_to_rgba(width, height, y_plane, u_plane, v_plane, checkpoint),
        }
        self.next_index = self.next_index + 1
        return frame
    end

    -- Совместимость со старым API: кадр frame_index или nil, если его нет.
    function session:decode_frame(frame_index)
        frame_index = frame_index or 0
        assert(frame_index >= 0, "frame_index must be non-negative")
        if frame_index < self.next_index or self.sample_count == 0 then
            self:open()
        end
        local frame
        repeat
            frame = self:next()
        until not frame or frame.frame_index >= frame_index
        return frame
    end

    return session
end

return {
    DEFAULT_VIDEO_PATH = DEFAULT_VIDEO_PATH,
    VIDEO_DIRS = VIDEO_DIRS,
    list_videos = list_videos,
    create_session = create_session,
}
