-- DOOM: doomgeneric (C) -> wasm -> Lua (Spider). Сессия игры без UI;
-- UI живёт в layouts/pages/doom.xml.lua.

local wasm_host = require "doom:wasm_host"

local band, rshift = bit.band, bit.rshift

local GENERATED_MODULE_PATH = "doom:modules/doom/doom.lua"

-- IWAD-ы ищутся в паке и в пользовательской папке config/doom/wads.
local WAD_DIRS = {
    "doom:wads",
    "config:doom/wads",
}
local DEFAULT_WAD_PATH = "doom:wads/doom1.wad"

-- Коды клавиш DOOM (doomkeys.h)
local KEYS = {
    RIGHTARROW = 0xae,
    LEFTARROW = 0xac,
    UPARROW = 0xad,
    DOWNARROW = 0xaf,
    STRAFE_L = 0xa0,
    STRAFE_R = 0xa1,
    USE = 0xa2,
    FIRE = 0xa3,
    ESCAPE = 27,
    ENTER = 13,
    TAB = 9,
    BACKSPACE = 0x7f,
    RSHIFT = 0x80 + 0x36,
    RALT = 0x80 + 0x38,
    MINUS = 0x2d,
    EQUALS = 0x3d,
}
for index = 1, 10 do
    KEYS["F" .. index] = 0x80 + 0x3a + index
end
KEYS.F11 = 0x80 + 0x57

local wasm_loader = nil

local function basename(path)
    return (path:gsub("\\", "/"):match("([^/:]+)$")) or path
end

-- Список IWAD-ов для select: { value = путь, text = имя }.
local function list_wads()
    local options = {}
    for _, dir in ipairs(WAD_DIRS) do
        if file.isdir(dir) then
            local names = file.list(dir)
            table.sort(names)
            for _, entry in ipairs(names) do
                local name = basename(entry)
                if name:lower():match("%.wad$") then
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

local function read_string(memory, ptr, length)
    local bytes = wasm_host.read_bytes(memory, ptr, length)
    local p = bytes.bytes
    local chars = {}
    for index = 0, length - 1 do
        chars[index + 1] = string.char(p[index])
    end
    return table.concat(chars)
end

-- Сессия DOOM с IWAD-ом по пути wad_path.
local function create_session(wad_path)
    local path = wad_path or DEFAULT_WAD_PATH
    assert(file.isfile(path), "wad file not found: " .. path)

    if not wasm_loader then
        wasm_loader = wasm_host.load_generated(GENERATED_MODULE_PATH)
    end
    wasm_host.flush_jit()
    local wasm = wasm_loader()
    local memory = assert(wasm.memory and wasm.memory[1], "wasm memory is unavailable")
    wasm._initialize()

    local session = {
        path = path,
        name = basename(path),
        wasm = wasm,
        memory = memory,
        width = wasm.dgv_screen_width(),
        height = wasm.dgv_screen_height(),
        started = false,
        exited = false,
        message = nil,
        output = {},
        palette_r = {},
        palette_g = {},
        palette_b = {},
    }
    session.rgba = Bytearray(session.width * session.height * 4)

    -- stdout/stderr DOOM копятся в буфере модуля; забираем их построчно
    function session:drain_output()
        local size = self.wasm.dgv_log_size()
        if size > 0 then
            local text = read_string(self.memory, self.wasm.dgv_log_ptr(), size)
            self.wasm.dgv_log_clear()
            for line in text:gmatch("[^\n]+") do
                table.insert(self.output, line)
            end
        end
    end

    function session:last_output_line()
        return self.output[#self.output]
    end

    -- Любой выход DOOM (меню Quit, I_Error) заканчивается ловушкой wasm:
    -- дальше модуль продолжать нельзя.
    function session:fail(err)
        self.exited = true
        self:drain_output()
        if self.wasm.dgv_exited() ~= 0 then
            self.message = self:last_output_line() or "DOOM exited"
        else
            -- ловушка без штатного exit: показываем и последнюю строку DOOM, и ошибку
            local last = self:last_output_line()
            self.message = last and (last .. " (" .. tostring(err) .. ")") or tostring(err)
        end
        debug.log(("[doom] session ended: %s"):format(self.message))
    end

    function session:start()
        local wad = file.read_bytes(self.path)
        local wad_ptr = self.wasm.dgv_alloc(#wad)
        assert(wad_ptr ~= 0, "not enough memory for the wad")
        wasm_host.write_bytes(self.memory, wad_ptr, wad)

        -- DOOM определяет игру по имени файла (doom1.wad, doom.wad, doom2.wad, ...)
        local name = self.name:lower()
        local name_ptr = self.wasm.dgv_alloc(#name + 1)
        wasm_host.write_bytes(self.memory, name_ptr, { name:byte(1, -1) })
        assert(self.wasm.dgv_set_wad_name(name_ptr, #name) == 1, "bad wad file name: " .. name)

        local ok, err = pcall(self.wasm.dgv_init, wad_ptr, #wad, 0)
        self:drain_output()
        if not ok then
            self:fail(err)
            return false
        end
        self.started = true
        return true
    end

    -- Шаг игры. now_ms — время хоста в миллисекундах от старта сессии.
    function session:tick(now_ms)
        if self.exited then
            return false
        end
        local ok, err = pcall(self.wasm.dgv_tick, now_ms)
        if not ok then
            self:fail(err)
            return false
        end
        self:drain_output()
        return true
    end

    function session:key(pressed, code)
        if not self.exited then
            self.wasm.dgv_key(pressed and 1 or 0, code)
        end
    end

    function session:frame_count()
        return self.wasm.dgv_frame_count()
    end

    -- Текущий кадр в RGBA (Bytearray сессии, переиспользуется между кадрами).
    function session:get_frame()
        local memory, wasm = self.memory, self.wasm
        local pr, pg, pb = self.palette_r, self.palette_g, self.palette_b
        if wasm.dgv_palette_changed() ~= 0 or pr[0] == nil then
            -- 256 записей по 4 байта: b, g, r, a
            local palette = wasm_host.read_bytes(memory, wasm.dgv_palette_ptr(), 1024).bytes
            for index = 0, 255 do
                pb[index] = palette[index * 4]
                pg[index] = palette[index * 4 + 1]
                pr[index] = palette[index * 4 + 2]
            end
        end

        local pixels = self.width * self.height
        local words = wasm_host.words_of(memory)
        local slot = rshift(wasm.dgv_screen_ptr(), 2) + 1
        local out = self.rgba.bytes
        local o = 0
        for _ = 1, pixels / 4 do
            local word = words[slot]
            slot = slot + 1
            for shift = 0, 24, 8 do
                local c = band(rshift(word, shift), 255)
                out[o] = pr[c]
                out[o + 1] = pg[c]
                out[o + 2] = pb[c]
                out[o + 3] = 255
                o = o + 4
            end
        end
        return self.rgba
    end

    return session
end

return {
    DEFAULT_WAD_PATH = DEFAULT_WAD_PATH,
    WAD_DIRS = WAD_DIRS,
    KEYS = KEYS,
    list_wads = list_wads,
    create_session = create_session,
}
