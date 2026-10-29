-- Импорты платформы vc для Eaglercraft (src/vc/.../VcHost.java в Spider,
-- tests/manual/real-world-eaglercraft): клавиши по кодам LWJGL, мышь, текстуры и кадры
-- треугольников для wasmrt:gfx_tris.

-- Код LWJGL -> имена клавиши движка (первое, которое знает input.keycode; имена движка
-- 0.31 не документированы полностью — для знаков и цифрового блока перебираются варианты).
local KEYS = {
    [1] = "escape", [14] = "backspace", [15] = "tab", [28] = "enter", [57] = "space",
    [29] = "left-ctrl", [157] = "right-ctrl", [42] = "left-shift", [54] = "right-shift",
    [56] = "left-alt", [184] = "right-alt", [219] = "left-super", [220] = "right-super",
    [58] = "caps-lock", [69] = { "num-lock", "numlock" }, [70] = { "scroll-lock", "scrolllock" },
    [183] = { "print-screen", "printscreen" }, [197] = "pause", [221] = "menu",
    [200] = "up", [208] = "down", [203] = "left", [205] = "right",
    [199] = "home", [207] = "end", [201] = "page-up", [209] = "page-down",
    [210] = "insert", [211] = "delete",
    [12] = { "minus", "-" }, [13] = { "equal", "=" }, [26] = { "left-bracket", "bracketleft", "[" },
    [27] = { "right-bracket", "bracketright", "]" }, [39] = { "semicolon", ";" }, [40] = { "apostrophe", "'" },
    [41] = { "grave-accent", "`" }, [43] = { "backslash", "\\" }, [51] = { "comma", "," },
    [52] = { "period", "." }, [53] = { "slash", "/" },
    [87] = "f11", [88] = "f12",
    -- цифровой блок
    [55] = { "kp-multiply", "keypad-multiply", "numpad-multiply" }, [74] = { "kp-subtract", "keypad-subtract", "numpad-subtract" },
    [78] = { "kp-add", "keypad-add", "numpad-add" }, [83] = { "kp-decimal", "keypad-decimal", "numpad-decimal" },
    [181] = { "kp-divide", "keypad-divide", "numpad-divide" }, [156] = { "kp-enter", "keypad-enter", "numpad-enter" },
}
local ROW1, ROW2, ROW3, ROW4 = "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"
for i = 1, #ROW1 do KEYS[1 + i] = ROW1:sub(i, i) end
for i = 1, #ROW2 do KEYS[15 + i] = ROW2:sub(i, i) end
for i = 1, #ROW3 do KEYS[29 + i] = ROW3:sub(i, i) end
for i = 1, #ROW4 do KEYS[43 + i] = ROW4:sub(i, i) end
for i = 1, 10 do KEYS[58 + i] = "f" .. i end
-- цифры цифрового блока: 71..73 = 7..9, 75..77 = 4..6, 79..81 = 1..3, 82 = 0
for code, d in pairs({ [71] = 7, [72] = 8, [73] = 9, [75] = 4, [76] = 5, [77] = 6, [79] = 1, [80] = 2, [81] = 3, [82] = 0 }) do
    KEYS[code] = { "kp-" .. d, "keypad-" .. d, "numpad-" .. d, "kp" .. d }
end

return function(ctx)
    local gfx = ctx.gfx
    local bindings, broken = {}, {}
    -- Код LWJGL -> "key:<имя>" для input.is_pressed: первое имя, которое знает input.keycode.
    local key_count = 0
    do
        local missing = {}
        for code, names in pairs(KEYS) do
            if type(names) == "string" then names = { names } end
            local found
            for _, n in ipairs(names) do
                local ok, kc = pcall(input.keycode, n)
                if ok and kc and kc ~= -1 then found = n; break end
            end
            if not found and not input.keycode then found = names[1] end  -- нет keycode: как раньше
            if found then
                bindings[code] = "key:" .. found
                key_count = key_count + 1
            else
                missing[#missing + 1] = code
            end
        end
        table.sort(missing)
        ctx.log(("eaglercraft: %d keys, not supported by the engine (LWJGL codes): %s"):format(key_count,
            table.concat(missing, " ")))
    end
    -- Нажатия между кадрами программы: клавиша, нажатая и отпущенная между двумя опросами,
    -- всё равно видна программе нажатой один кадр.
    local key_latch = {}
    -- Ввод через ctx (wasmrt:app): при встраивании (компьютер pc_wasmrt:pc) клавиши и курсор
    -- программе видны, только пока игрок за компьютером; курсор — проекция на экран в мире.
    local is_pressed = ctx.is_pressed or input.is_pressed
    local mouse_pos = ctx.mouse_pos or input.get_mouse_pos
    local input_enabled = ctx.input_enabled or function() return true end
    local function latch_keys()
        for code, binding in pairs(bindings) do
            if not broken[code] then
                local ok, pressed = pcall(is_pressed, binding)
                if not ok then broken[code] = true elseif pressed then key_latch[code] = true end
            end
        end
    end
    -- Набранный текст (символы с учётом раскладки и Shift, автоповтор ОС): скрытое текстовое
    -- поле страницы в фокусе; каждый тик текст забирается и поле очищается. manifest.text_input =
    -- false — выключить (тогда символы по таблице в программе).
    local text_box, text_pending, text_ok = nil, "", ctx.manifest.text_input ~= false and ctx.document ~= nil
    local function pump_text()
        if not text_ok then return end
        if not input_enabled() then
            -- игрок отошёл: поле не держит фокус (иначе оно забирало бы клавиатуру у мира)
            if text_box and text_box.exists and text_box.focused then pcall(function() text_box.focused = false end) end
            return
        end
        local ok, err = pcall(function()
            if not (text_box and text_box.exists) then
                ctx.document.root:add('<textbox id="wasmrt_eag_text" pos="-4000,-4000" size="200,24" multiline="false"></textbox>')
                text_box = ctx.document["wasmrt_eag_text"]
            end
            local t = text_box.text
            if t and t ~= "" then
                text_pending = text_pending .. t
                text_box.text = ""
            end
            if not text_box.focused then text_box.focused = true end
        end)
        if not ok then
            text_ok = false
            ctx.log("eaglercraft: text input disabled: " .. tostring(err))
        end
    end
    local wheel = 0
    local latched = 0  -- кнопки, нажатые с прошлого опроса программой (быстрый клик)
    local function buttons_raw()
        return (is_pressed("mouse:left") and 1 or 0)
            + (is_pressed("mouse:right") and 2 or 0)
            + (is_pressed("mouse:middle") and 4 or 0)
    end
    -- Кнопка, нажатая вне картинки программы (и не при захвате курсора), не видна программе до
    -- отпускания: в браузере mousedown слушает только canvas. Иначе клик по окну движка (фокус,
    -- другие элементы страницы) нажимал кнопки Minecraft под курсором.
    local prev_raw, ignored = 0, 0
    local function buttons_now()
        local raw = buttons_raw()
        local newly = bit.band(raw, bit.bnot(prev_raw))
        prev_raw = raw
        if newly ~= 0 and not (ctx.grab and ctx.grab.on) then
            local pos = mouse_pos()
            local _, _, inside = gfx:to_virtual(pos[1], pos[2])
            if not inside then ignored = bit.bor(ignored, newly) end
        end
        ignored = bit.band(ignored, raw)
        return bit.band(raw, bit.bnot(ignored))
    end
    if events and events.on then
        pcall(events.on, "core:scroll", function(dy) wheel = wheel + dy end)
    end
    -- Автоматизация: строки из export:eagler_cmd.txt (см. VcDebug.java) -> очередь команд.
    local CMD_FILE = "export:eagler_cmd.txt"
    local commands, next_check = {}, 0
    local function check_commands()
        local now = time.uptime()
        if now < next_check then return end
        next_check = now + 0.05
        if not file.isfile(CMD_FILE) then return end
        local text = file.read(CMD_FILE)
        if not pcall(file.remove, CMD_FILE) then file.write(CMD_FILE, "") end
        for line in text:gmatch("[^\r\n]+") do
            if line:match("%S") and not line:match("^%s*#") then commands[#commands + 1] = line end
        end
    end

    -- Хранилище SimpleStorage (как localStorage браузера): ключ -> файл
    -- export:eaglercraft/storage/<ключ> (байты вне [A-Za-z0-9_-] — %XX). Значения кэшируются.
    local STORAGE_DIR = "export:eaglercraft/storage"
    local storage_cache = {}   -- ключ -> строка байт или false (нет значения)
    local function storage_file(key)
        return STORAGE_DIR .. "/" .. key:gsub("[^%w_%-]", function(c) return ("%%%02X"):format(c:byte()) end)
    end
    local function storage_read(key)
        local v = storage_cache[key]
        if v == nil then
            v = false
            local path = storage_file(key)
            local ok, data = pcall(function()
                if file.isfile(path) then return Bytearray_as_string(file.read_bytes(path)) end
            end)
            if ok and data then v = data end
            if not ok then ctx.log("eaglercraft: storage read " .. key .. ": " .. tostring(data)) end
            storage_cache[key] = v
        end
        return v
    end
    local function storage_write(key, data)
        local path = storage_file(key)
        local ok, err = pcall(function()
            if data == nil then
                if file.isfile(path) then file.remove(path) end
            else
                if not file.isdir(STORAGE_DIR) then file.mkdirs(STORAGE_DIR) end
                local bytes = Bytearray(#data)
                for i = 1, #data do bytes[i] = data:byte(i) end
                file.write_bytes(path, bytes)
            end
        end)
        if not ok then
            ctx.log("eaglercraft: storage write " .. key .. ": " .. tostring(err))
            storage_cache[key] = nil
            return false
        end
        storage_cache[key] = data or false
        return true
    end
    local function storage_keys()
        local keys = {}
        pcall(function()
            if not file.isdir(STORAGE_DIR) then return end
            for _, entry in ipairs(file.list(STORAGE_DIR)) do
                local name = entry:match("([^/:]+)$") or entry
                keys[#keys + 1] = name:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
            end
        end)
        table.sort(keys)
        return table.concat(keys, "\n")
    end
    local function put_bytes(value, ptr, cap)
        if #value <= cap and #value > 0 then ctx.api().write_string(ctx.memory(), ptr, value) end
        return #value
    end

    -- Встроенный сервер: оригинальный classes_server.js в Node (Spider,
    -- tests/manual/real-world-eaglercraft/native_server/launcher.js) по TCP. Кадр: u16 длина
    -- канала, канал, u32 длина данных, данные (little-endian); первый кадр — START + имя базы.
    local SERVER_HOST = ctx.manifest.server_host or "127.0.0.1"
    local SERVER_PORT = ctx.manifest.server_port or 25599
    local sock, connecting = nil, false
    local server_notice_shown = false
    local outgoing = {}          -- кадры до подключения
    local inbuf = ""             -- принятые байты
    local incoming = {}          -- { channel, data } от сервера
    local in_head, in_tail = 1, 0 -- очередь incoming[in_head .. in_tail]

    local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
    local function u32(n)
        return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
    end
    local function frame(ch, data) return u16(#ch) .. ch .. u32(#data) .. data end
    local function send_raw(s)
        if sock and sock:is_connected() then sock:send(s) else outgoing[#outgoing + 1] = s end
    end
    local inpos = 1              -- начало неразобранных байт в inbuf
    local stats = { bytes = 0, frames = 0 }
    local function pump_server()
        if not sock then return end
        if #outgoing > 0 and sock:is_connected() then
            for _, s in ipairs(outgoing) do sock:send(s) end
            outgoing = {}
        end
        local ok, n = pcall(sock.available, sock)
        if not (ok and n and n > 0) then return end
        local data = sock:recv(n)
        if not data then return end
        data = type(data) == "string" and data or Bytearray_as_string(data)
        stats.bytes = stats.bytes + #data
        inbuf = (inpos > 1 and inbuf:sub(inpos) or inbuf) .. data
        inpos = 1
        local len = #inbuf
        while len - inpos + 1 >= 2 do
            local cl = inbuf:byte(inpos) + inbuf:byte(inpos + 1) * 256
            if len - inpos + 1 < 6 + cl then break end
            local b1, b2, b3, b4 = inbuf:byte(inpos + 2 + cl, inpos + 5 + cl)
            local dl = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            if len - inpos + 1 < 6 + cl + dl then break end
            in_tail = in_tail + 1
            incoming[in_tail] = { inbuf:sub(inpos + 2, inpos + 1 + cl), inbuf:sub(inpos + 6 + cl, inpos + 5 + cl + dl) }
            inpos = inpos + 6 + cl + dl
            stats.frames = stats.frames + 1
        end
    end

    return {
        __tick = function()
            latched = bit.bor(latched, buttons_now())
            latch_keys()
            pump_text()
            check_commands()
            pump_server()
            if ctx.manifest.trace_server and sock then
                local now = time.uptime()
                if now >= (stats.next_log or 0) then
                    stats.next_log = now + 2
                    local ok, avail = pcall(sock.available, sock)
                    ctx.log(("eaglercraft: bridge bytes %d frames %d queue %d..%d buffered %d available %s connected %s"):format(
                        stats.bytes, stats.frames, in_head, in_tail, #inbuf - inpos + 1, tostring(ok and avail or avail),
                        tostring(sock:is_connected())))
                end
            end
        end,
        eag_srv_start = function(ptr, len)
            local db = ctx.api().read_string(ctx.memory(), ptr, len)
            if sock then pcall(sock.close, sock) end
            sock, outgoing, inbuf, incoming, inpos, in_head, in_tail = nil, {}, "", {}, 1, 1, 0
            outgoing[1] = frame("START", db)
            ctx.log(("eaglercraft: server %s:%d (db %s)"):format(SERVER_HOST, SERVER_PORT, db))
            network.tcp_connect(SERVER_HOST, SERVER_PORT, function(s)
                sock = s
                pcall(s.set_nodelay, s, true)
                ctx.log("eaglercraft: server connected")
            end, function(_, err)
                ctx.log("eaglercraft: server connection failed: " .. tostring(err))
                -- без сервера мир так и висит на Connecting: сказать об этом на странице
                if ctx.document and not server_notice_shown then
                    server_notice_shown = true
                    pcall(require("wasmrt:app").show_notice, ctx.document, {
                        ("Сервер Eaglercraft не отвечает: %s:%d (%s)."):format(SERVER_HOST, SERVER_PORT, tostring(err)),
                        "Запустите в WSL: node /root/Spider/tests/manual/real-world-eaglercraft/native_server/launcher.js",
                    }, "eag_server_notice")
                end
            end)
        end,
        eag_srv_stop = function()
            if sock then pcall(sock.close, sock) end
            sock = nil
        end,
        eag_srv_send = function(ch_ptr, ch_len, ptr, len)
            local api, memory = ctx.api(), ctx.memory()
            local ch = api.read_string(memory, ch_ptr, ch_len)
            if ctx.manifest.trace_server then
                ctx.log(("eaglercraft: c->s %s %d (connected %s)"):format(ch, len, tostring(sock and sock:is_connected())))
            end
            send_raw(frame(ch, api.read_string(memory, ptr, len)))
        end,
        eag_srv_peek = function(out)
            local m = incoming[in_head]
            if not m then return 0 end
            ctx.api().write_i32(ctx.memory(), out, #m[1])
            ctx.api().write_i32(ctx.memory(), out + 4, #m[2])
            return 1
        end,
        eag_srv_pop = function(ch_ptr, ptr)
            local m = incoming[in_head]
            if not m then return end
            incoming[in_head] = nil
            in_head = in_head + 1
            ctx.api().write_string(ctx.memory(), ch_ptr, m[1])
            ctx.api().write_string(ctx.memory(), ptr, m[2])
        end,
        eag_command = function(ptr, capacity)
            local line = table.remove(commands, 1)
            if not line then return -1 end
            line = line:sub(1, capacity)
            ctx.api().write_string(ctx.memory(), ptr, line)
            return #line
        end,
        eag_key = function(code)
            local binding = bindings[code]
            if not binding or broken[code] then return 0 end
            local ok, pressed = pcall(is_pressed, binding)
            if not ok then broken[code] = true; return 0 end
            local latched_key = key_latch[code]
            key_latch[code] = nil
            return (pressed or latched_key) and 1 or 0
        end,
        -- Текст, набранный с прошлого вызова (UTF-8): длина; -1 — ввода текста нет. Если текст
        -- длиннее capacity, отдаётся начало (остальное — в следующий раз, по границе символа).
        eag_text = function(ptr, capacity)
            if not text_ok then return -1 end
            if text_pending == "" then return 0 end
            local n = #text_pending
            if n > capacity then
                n = capacity
                while n > 0 and bit.band(text_pending:byte(n + 1) or 0, 0xC0) == 0x80 do n = n - 1 end
            end
            local chunk = text_pending:sub(1, n)
            text_pending = text_pending:sub(n + 1)
            ctx.api().write_string(ctx.memory(), ptr, chunk)
            return n
        end,
        eag_mouse = function(ptr)
            local api, memory = ctx.api(), ctx.memory()
            local pos = mouse_pos()
            local x, y, inside = gfx:to_virtual(pos[1], pos[2])
            local buttons = bit.bor(buttons_now(), latched)
            latched = 0
            api.write_i32(memory, ptr, x or 0)
            api.write_i32(memory, ptr + 4, y or 0)
            api.write_i32(memory, ptr + 8, buttons)
            api.write_i32(memory, ptr + 12, wheel)
            wheel = 0
            return inside and 1 or 0
        end,
        eag_texture = function(id, w, h, ptr)
            gfx:texture(ctx.api(), ctx.memory(), id, w, h, ptr)
        end,
        eag_texture_delete = function(id) gfx:texture_delete(id) end,
        eag_texture_sub = function(id, x, y, w, h, ptr)
            gfx:texture_sub(ctx.api(), ctx.memory(), id, x, y, w, h, ptr)
        end,
        -- наборы тумана кадра (VcGL.fogRecord), приходят перед eag_frame
        eag_fog = function(ptr, count)
            gfx:fog(ctx.api(), ctx.memory(), ptr, count)
        end,
        eag_frame = function(ptr, count, clear, clear_depth)
            gfx:frame(ctx.api(), ctx.memory(), ptr, count, clear, clear_depth)
            ctx.count_frame()
        end,
        eag_storage_get = function(kptr, klen, ptr, cap)
            local key = ctx.api().read_string(ctx.memory(), kptr, klen)
            local v = storage_read(key)
            if not v then return -1 end
            return put_bytes(v, ptr, cap)
        end,
        eag_storage_set = function(kptr, klen, ptr, len)
            local api, memory = ctx.api(), ctx.memory()
            local key = api.read_string(memory, kptr, klen)
            local data = nil
            if len >= 0 then data = len > 0 and api.read_string(memory, ptr, len) or "" end
            return storage_write(key, data) and 1 or 0
        end,
        eag_storage_list = function(ptr, cap)
            return put_bytes(storage_keys(), ptr, cap)
        end,
        eag_log = function(ptr, len)
            ctx.log("eaglercraft: " .. ctx.api().read_string(ctx.memory(), ptr, len))
        end,
    }
end
