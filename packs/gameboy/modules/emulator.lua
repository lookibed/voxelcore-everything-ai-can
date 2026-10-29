-- Эмулятор Game Boy / Game Boy Color: binjgb (C) -> wasm -> Lua (Spider).
-- Модуль отвечает за сессию эмулятора; UI живёт в layouts/pages/emulator.xml.lua.

local wasm_host = require "gameboy:wasm_host"

local band, rshift = bit.band, bit.rshift

local GENERATED_MODULE_PATH = "gameboy:modules/binjgb/binjgb.lua"

-- ROM-ы ищутся в паке и в пользовательской папке config/gameboy/roms.
local ROM_DIRS = {
    "gameboy:roms",
    "config:gameboy/roms",
}
local ROM_EXTENSIONS = { gb = true, gbc = true }
local DEFAULT_ROM_PATH = "gameboy:roms/cgb-acid2.gbc"

local BUTTON_BITS = {
    A = 1,
    B = 2,
    SELECT = 4,
    START = 8,
    RIGHT = 16,
    LEFT = 32,
    UP = 64,
    DOWN = 128,
}

-- Встроенные в wasm сценарии нажатий для первых кадров (см. module.c).
local PRESET_IDS = {
    none = 0,
    acid2 = 1,
    ["tetris-start"] = 2,
    ["tetris-start-then-a"] = 3,
}

local PRESET_OPTIONS = {
    { value = "auto", text = "auto" },
    { value = "none", text = "none" },
    { value = "acid2", text = "acid2" },
    { value = "tetris-start", text = "tetris-start" },
    { value = "tetris-start-then-a", text = "tetris-start-then-a" },
}

local wasm_loader = nil
local stream_counter = 0

-- 5 бит канала -> 8 бит
local EXPAND5 = {}
for value = 0, 31 do
    EXPAND5[value] = value * 8 + math.floor(value / 4)
end

local function basename(path)
    return (path:gsub("\\", "/"):match("([^/:]+)$")) or path
end

local function stem(path)
    return (basename(path):gsub("%.[^.]+$", ""))
end

local function select_default_preset(path)
    local name = stem(path):lower()
    if name == "cgb-acid2" then
        return "acid2"
    end
    if name:match("^tetris") then
        return "tetris-start"
    end
    return "none"
end

-- Список ROM-ов для select: { value = путь, text = имя }.
local function list_roms()
    local options = {}
    for _, dir in ipairs(ROM_DIRS) do
        if file.isdir(dir) then
            local names = file.list(dir)
            table.sort(names)
            for _, entry in ipairs(names) do
                local name = basename(entry)
                local ext = name:match("%.([^.]+)$")
                if ext and ROM_EXTENSIONS[ext:lower()] then
                    local path = dir .. "/" .. name
                    local text = name
                    if dir:sub(1, 7) == "config:" then
                        text = name .. "  [config]"
                    end
                    table.insert(options, { value = path, text = text })
                end
            end
        end
    end
    return options
end

-- Упакованный RGB555 (2 байта на пиксель) -> RGBA в заранее выделенный Bytearray.
local function convert_rgb555(memory, ptr, pixel_count, out)
    local p = out.bytes
    local o = 0
    if ptr % 4 == 0 and pixel_count % 2 == 0 then
        local words = wasm_host.words_of(memory)
        local slot = rshift(ptr, 2) + 1
        for _ = 1, pixel_count / 2 do
            local word = words[slot]
            slot = slot + 1
            for half = 0, 1 do
                local pixel = half == 0 and band(word, 0xFFFF) or band(rshift(word, 16), 0xFFFF)
                p[o] = EXPAND5[band(rshift(pixel, 10), 31)]
                p[o + 1] = EXPAND5[band(rshift(pixel, 5), 31)]
                p[o + 2] = EXPAND5[band(pixel, 31)]
                p[o + 3] = 255
                o = o + 4
            end
        end
    else
        for index = 0, pixel_count - 1 do
            local pixel = memory[ptr + index * 2 + 1] + memory[ptr + index * 2 + 2] * 256
            p[o] = EXPAND5[band(rshift(pixel, 10), 31)]
            p[o + 1] = EXPAND5[band(rshift(pixel, 5), 31)]
            p[o + 2] = EXPAND5[band(pixel, 31)]
            p[o + 3] = 255
            o = o + 4
        end
    end
    return out
end

-- Калибровка JIT, см. session:calibrate.
-- Замер кадров 31..70 от старта ROM предсказывает итоговую скорость (проверено на Tetris,
-- Kirby, Super Mario Land, cgb-acid2); режимы отличаются минимум в 1.25 раза. Раньше мерить
-- нельзя: в движке кадры до ~30 после сброса трасс ещё заняты компиляцией.
local CALIBRATE_WARM = 30
local CALIBRATE_MEASURE = 40
local CALIBRATE_SAME = 1.10
local CALIBRATE_SPLIT = 1.20
local CALIBRATE_CONFIRM = 5
local CALIBRATE_MAX_ROLLS = 12
-- Бросок с перезагрузкой модуля (новые адреса прототипов) в движке заметно не лучше
-- (Tetris: 6 из 8 быстрых против 5 из 8), но дороже, поэтому выключен.
local CALIBRATE_RELOAD = false
-- Потолок процессорного времени калибровки: после него принимается текущий бросок.
local CALIBRATE_MAX_CPU = 5.0

-- reload: загрузить модуль заново (новые прототипы по новым адресам) — для калибровки JIT.
local function create_runtime(reload)
    if reload or not wasm_loader then
        wasm_loader = wasm_host.load_generated(GENERATED_MODULE_PATH)
    end
    wasm_host.flush_jit()
    local wasm = wasm_loader()
    local memory = assert(wasm.memory and wasm.memory[1], "wasm memory is unavailable")
    return wasm, memory
end

-- Создаёт сессию эмулятора для ROM-а. options: preset_name, buttons_mask, script_entries, audio_enabled.
local function create_session(rom_path, options)
    options = options or {}
    local path = rom_path or DEFAULT_ROM_PATH
    local preset_name = options.preset_name
    if not preset_name or preset_name == "" or preset_name == "auto" then
        preset_name = select_default_preset(path)
    end
    assert(PRESET_IDS[preset_name], "unknown preset: " .. tostring(preset_name))
    assert(file.isfile(path), "rom file not found: " .. path)

    local rom_bytes = file.read_bytes(path)
    local wasm, memory = create_runtime()

    local session = {
        path = path,
        name = basename(path),
        wasm = wasm,
        memory = memory,
        preset_name = preset_name,
        buttons_mask = options.buttons_mask or 0,
        script_entries = options.script_entries or {},
        frame_index = -1,
        started = false,
        width = 0,
        height = 0,
        rgba = nil,
        audio_enabled = options.audio_enabled == true,
        audio_stream = nil,
        audio_speaker = 0,
        audio_active = false,
    }

    function session:teardown_audio()
        if self.audio_speaker ~= 0 and audio and audio.stop then
            audio.stop(self.audio_speaker)
        end
        self.audio_stream = nil
        self.audio_speaker = 0
        self.audio_active = false
    end

    function session:setup_audio()
        if not self.audio_enabled or not (audio and audio.PCMStream and audio.play_stream_2d) then
            return false
        end
        local sample_rate = self.wasm.binjgb_host_get_audio_sample_rate()
        assert(sample_rate > 0, "emulator returned invalid audio sample rate")

        stream_counter = stream_counter + 1
        local alias = ("gameboy-audio-%s-%d"):format(stem(self.path), stream_counter)
        self.audio_stream = audio.PCMStream(sample_rate, 2, 16)
        self.audio_stream:share(alias)
        self.audio_speaker = audio.play_stream_2d(alias, 1.0, 1.0, "ui", true)
        self.audio_active = self.audio_speaker ~= 0
        return self.audio_active
    end

    function session:set_audio_enabled(state)
        self.audio_enabled = state == true
        if not self.audio_enabled then
            self:teardown_audio()
            self.wasm.binjgb_host_clear_audio_buffer()
            return false
        end
        if self.started and not self.audio_active then
            return self:setup_audio()
        end
        return self.audio_active
    end

    function session:pump_audio()
        if not self.audio_active or not self.audio_stream then
            return 0
        end
        local ptr = self.wasm.binjgb_host_get_audio_buffer_ptr()
        local size = self.wasm.binjgb_host_get_audio_buffer_size()
        if ptr == 0 or size <= 0 then
            return 0
        end
        self.audio_stream:feed(wasm_host.read_bytes(self.memory, ptr, size))
        self.wasm.binjgb_host_clear_audio_buffer()
        return size
    end

    function session:set_buttons(mask)
        self.buttons_mask = mask or 0
        assert(self.wasm.binjgb_host_set_live_buttons(self.buttons_mask) == 1, "emulator live buttons set failed")
    end

    -- Текущий кадр. frame.rgba — Bytearray сессии, переиспользуется между кадрами.
    function session:get_frame()
        assert(self.started, "session is not started")
        local ptr = self.wasm.binjgb_host_get_framebuffer_ptr()
        convert_rgb555(self.memory, ptr, self.width * self.height, self.rgba)
        self.frame_index = self.wasm.binjgb_host_get_frame_index()
        return {
            frame_index = self.frame_index,
            width = self.width,
            height = self.height,
            rgba = self.rgba,
        }
    end

    function session:start()
        self:teardown_audio()
        self.started = false
        assert(self.wasm.binjgb_host_reset() == 1, "emulator host reset failed")

        local ptr = self.wasm.binjgb_host_alloc(#rom_bytes)
        assert(ptr ~= 0, "emulator rom allocation failed")
        wasm_host.write_bytes(self.memory, ptr, rom_bytes)
        assert(self.wasm.binjgb_host_load_rom(ptr, #rom_bytes) == 1, "emulator failed to load rom")
        assert(self.wasm.binjgb_host_set_input_preset(PRESET_IDS[self.preset_name]) == 1, "emulator preset set failed")

        assert(self.wasm.binjgb_host_clear_button_script() == 1, "button script clear failed")
        for _, entry in ipairs(self.script_entries) do
            assert(self.wasm.binjgb_host_add_button_script(entry.start_frame, entry.end_frame, entry.mask) == 1,
                "button script add failed")
        end
        self:set_buttons(self.buttons_mask)
        assert(self.wasm.binjgb_host_start() == 1, "emulator start failed")

        self.width = self.wasm.binjgb_host_get_width()
        self.height = self.wasm.binjgb_host_get_height()
        assert(self.width > 0 and self.height > 0, "emulator returned invalid frame size")
        assert(self.wasm.binjgb_host_get_framebuffer_size() == self.width * self.height * 2,
            "unexpected framebuffer format")
        self.rgba = Bytearray(self.width * self.height * 4)

        self:setup_audio()
        self.started = true
        return self:get_frame()
    end

    -- Калибровка JIT (см. wasm_host.reroll_jit). binjgb в LuaJIT случайно попадает в один из
    -- режимов, различающихся по скорости в 1.3-2.5 раза, и режим определяется в первые ~30
    -- кадров. Бросок: ROM с начала, CALIBRATE_WARM кадров, затем замер CALIBRATE_MEASURE
    -- кадров (одни и те же загрузочные кадры, поэтому броски сравнимы). Перебрасываем, пока
    -- текущий бросок не окажется в быстром режиме: не медленнее лучшего более чем на
    -- CALIBRATE_SAME и либо уже был явно медленный бросок, либо CALIBRATE_CONFIRM бросков
    -- подряд одинаковы. Вызывать повторно с квантом времени, пока не вернёт true; после
    -- этого ROM стартует заново. Результат в self.calibration.
    function session:calibrate(budget)
        local c = self.calibration
        if not c then
            c = { roll = 1, frame = 0, time = 0, best = math.huge, split = false, same = 0, fps = {}, done = false,
                audio = self.audio_enabled, cpu = 0 }
            self.calibration = c
            self.audio_enabled = false  -- броски без звука, каждый сброс ROM иначе пересоздаёт поток
            self:start()
        end
        if c.done then
            return true
        end
        local slice_start = os.clock()
        local deadline = slice_start + budget
        local step = self.wasm.binjgb_host_step_frame
        while os.clock() < deadline do
            local t0 = os.clock()
            assert(step() == 1, "emulator step frame failed")
            c.frame = c.frame + 1
            if c.frame > CALIBRATE_WARM then
                c.time = c.time + (os.clock() - t0)
            end
            if c.frame >= CALIBRATE_WARM + CALIBRATE_MEASURE then
                local t = c.time / CALIBRATE_MEASURE
                c.fps[#c.fps + 1] = math.floor(1 / t + 0.5)
                if t >= c.best * CALIBRATE_SPLIT or (c.best < math.huge and t * CALIBRATE_SPLIT <= c.best) then
                    c.split = true
                end
                if t <= c.best * CALIBRATE_SAME then
                    c.same = c.same + 1
                else
                    c.same = 0
                end
                if t < c.best then
                    c.best = t
                end
                local fast_now = t <= c.best * CALIBRATE_SAME
                local cpu_spent = c.cpu + (os.clock() - slice_start)
                if (fast_now and (c.split or c.same >= CALIBRATE_CONFIRM)) or c.roll >= CALIBRATE_MAX_ROLLS
                        or cpu_spent >= CALIBRATE_MAX_CPU then
                    c.done = true
                    c.cpu = c.cpu + (os.clock() - slice_start)
                    self.audio_enabled = c.audio
                    self:start()
                    return true
                end
                c.roll = c.roll + 1
                c.frame, c.time = 0, 0
                if CALIBRATE_RELOAD then
                    -- новые прототипы лягут по новым адресам: LuaJIT делит 64 счётчика
                    -- горячести по адресу байткода, и в одном процессе без перезагрузки
                    -- броски залипают в одном режиме
                    self.wasm, self.memory = create_runtime(true)
                else
                    wasm_host.reroll_jit(wasm_loader)
                end
                self:start()
                step = self.wasm.binjgb_host_step_frame
            end
        end
        c.cpu = c.cpu + (os.clock() - slice_start)
        return false
    end

    function session:step_frame()
        assert(self.started, "session is not started")
        self:set_buttons(self.buttons_mask)
        assert(self.wasm.binjgb_host_step_frame() == 1, "emulator step frame failed")
        self:pump_audio()
        return self:get_frame()
    end

    return session
end

return {
    DEFAULT_ROM_PATH = DEFAULT_ROM_PATH,
    ROM_DIRS = ROM_DIRS,
    BUTTON_BITS = BUTTON_BITS,
    PRESET_IDS = PRESET_IDS,
    PRESET_OPTIONS = PRESET_OPTIONS,
    select_default_preset = select_default_preset,
    list_roms = list_roms,
    create_session = create_session,
}
