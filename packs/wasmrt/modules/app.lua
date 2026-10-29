-- wasmrt: запуск wasm-программы (Spider) по манифесту проекта.
--
-- Манифест (JSON, например "pong:wasm.json"):
--   module    — путь сгенерированного Lua-модуля ("pong:modules/pong/pong.lua")
--   graphics  — "canvas" (везде, растеризация на Lua и кадровый буфер) или
--               "posteffect" (только в мире, команды в шейдере)
--   width, height — виртуальный экран (по умолчанию 320x200)
--   args, env — argv и окружение WASI
--   files     — каталог пака, видимый программе как "/" (только чтение), например "pong:data"
--   slice_ms  — квант времени программы за тик для модели main (по умолчанию 12)
--   frame_pacing — модель main: "present" (по умолчанию: каждый vc_gfx_present — конец тика)
--               или "slice" (present отдаёт управление, только когда исчерпан квант:
--               несколько кадров программы за тик движка, на экране — последний; для бенчмарков)
--   log_fps   — раз в 5 с писать в лог частоту кадров программы (vc_gfx_present / vc_gfx_submit)
--   palette   — для vc_gfx_present_indexed с графикой canvas: "cpu" (по умолчанию, перевод в
--               RGBA на Lua) или "gpu" (индексы и палитра в текстуре, цвет — шейдер UI пака)
--   capture_escape — пока программа работает, Esc не закрывает страницу (по умолчанию true)
--   tris_tile, tris_verify — для графики "tris": сторона тайла биннинга (32; 0 — полный перебор)
--               и отладочная сверка с полным перебором (см. modules/gfx_tris.lua)
--   jit       — "tuned" (по умолчанию) или "default"
--   jit_opt   — доп. параметры jit.opt.start поверх "tuned" (например ["+loop"]: smollm — матвек с LICM)
--   platform  — "wasm4": картридж фэнтези-консоли WASM-4 (см. modules/w4.lua), остальные
--               поля кроме module/jit/log_fps не нужны
--
-- Модели программы (по экспортам):
--   vc_frame(dt_ms)  — вызывается каждый тик движка (плюс vc_init() / _initialize один раз);
--   _start           — обычный main в корутине: vc_frame_end() / vc_gfx_present() отдают
--                      управление до следующего тика; длинные вычисления уступают сами,
--                      если модуль собран с `spider-cli --yield-every N`.

local host = require "wasmrt:host"
local WASI = require "wasmrt:wasi"
local gfx_post = require "wasmrt:gfx_post"
local gfx_canvas = require "wasmrt:gfx_canvas"

local M = {}

local TIMER_INTERVAL_MS = 4

local function log(message)
    debug.log("[wasmrt] " .. message)
end

function M.load_manifest(path)
    local m = json.parse(file.read(path))
    m.path = path
    m.width = m.width or 320
    m.height = m.height or 200
    m.graphics = m.graphics or "canvas"
    m.args = m.args or { "wasm" }
    m.env = m.env or {}
    m.slice_ms = m.slice_ms or 12
    assert(m.module, "manifest has no 'module': " .. path)
    assert(m.graphics == "canvas" or m.graphics == "posteffect" or m.graphics == "tris",
        "graphics must be 'canvas', 'posteffect' or 'tris'")
    return m
end

-- Построчный вывод в лог движка (stdout/stderr программы).
local function line_writer(prefix)
    local pending = ""
    return function(text)
        pending = pending .. text
        while true do
            local nl = pending:find("\n", 1, true)
            if not nl then break end
            log(prefix .. pending:sub(1, nl - 1))
            pending = pending:sub(nl + 1)
        end
    end
end

-- Запускает программу и привязывает её вывод к документу UI (для canvas).
-- embed (необязательно) — встраивание программы не на страницу/оверлей во весь экран, а, например,
-- в окно рабочего стола компьютера pc_wasmrt:pc (документ фрейма gui.create_frame в текстуре):
--   parent        — контейнер (Element) для картинки программы, она вписывается в его размер;
--   mouse_pos()   — позиция курсора {x, y} в координатах документа (как wpos элементов) вместо
--                   input.get_mouse_pos() (курсор, спроецированный на экран в мире);
--   release_grab() — вернуть активный фрейм после захвата курсора (vc_mouse_grab(0)) вместо
--                   gui.set_active_frame(прежний id): так фрейм получает обратно свой cursorLocator;
--   input_enabled() — false: клавиши и кнопки мыши программе не видны (игрок отошёл от компьютера).
function M.start(manifest, document, embed)
    local m = type(manifest) == "string" and M.load_manifest(manifest) or manifest
    if m.platform == "wasm4" then
        return require("wasmrt:w4").start(m, document)
    end
    embed = embed or {}
    local app = { manifest = m, status = "running", message = nil, frames = 0, embed = embed }
    local function input_enabled() return not embed.input_enabled or embed.input_enabled() end
    local function mouse_pos() return embed.mouse_pos and embed.mouse_pos() or input.get_mouse_pos() end
    local function is_pressed(code) return input_enabled() and input.is_pressed(code) end

    host.set_jit_tuned(m.jit ~= "default", m.jit_opt)

    local gfx
    if m.graphics == "posteffect" then
        gfx = gfx_post.new(m.width, m.height)
    elseif m.graphics == "tris" then
        gfx = require("wasmrt:gfx_tris").new(document, m.width, m.height,
            setmetatable({ host = embed }, { __index = m }))
    else
        gfx = gfx_canvas.new(document, m.width, m.height, m.palette, embed)
    end
    gfx:activate()
    app.gfx = gfx

    local exports, api, memory
    local mode, co, deadline = nil, nil, 0
    local key_names = {}
    local sound = nil  -- { stream, speaker, channels }

    local file_cache = {}
    local wasi = WASI.create({
        args = m.args, env = m.env,
        stdout = line_writer("out: "), stderr = line_writer("err: "),
        read_file = function(path)
            if not m.files then return nil end
            local full = m.files .. "/" .. path
            local hit = file_cache[full]
            if hit then return hit end
            if not file.isfile(full) then return nil end
            local data = Bytearray_as_string(file.read_bytes(full))
            -- кэш содержимого (12.10, Half-Life: Xash открывает pak0.pak 79 МБ заново на каждый файл внутри)
            if m.cache_files then file_cache[full] = data end
            return data
        end,
        -- каталоги файлов программы (fd_readdir / stat каталога; 12.10, Half-Life: Xash ищет pak/wad списком)
        list_dir = function(path)
            if not m.files then return nil end
            local full = path == "" and m.files or (m.files .. "/" .. path)
            if not file.isdir(full) then return nil end
            local out = {}
            for _, entry in ipairs(file.list(full)) do
                local name = entry:match("([^/:]+)$") or entry
                out[#out + 1] = { name, file.isdir(full .. "/" .. name) }
            end
            return out
        end,
        clock = function() return time.utc_time() end,
        monotonic = function() return time.uptime() end,
        random = function() return math.random(0, 255) end,
        log = log,
    })

    local function frame_boundary()
        if mode == "main" and coroutine.running() == co then
            coroutine.yield("frame")
        end
    end

    local fps_frames, fps_time = 0, time.uptime()
    local function count_frame()
        app.frames_drawn = (app.frames_drawn or 0) + 1
        if not m.log_fps then return end
        fps_frames = fps_frames + 1
        local now = os.clock()
        if not app.fps_clock then app.fps_clock = now end
        if now - app.fps_clock >= 5 then
            local present = ""
            if app.present_count and app.present_count > 0 then
                present = (", present %.2f ms/frame"):format(app.present_time / app.present_count * 1000)
                app.present_time, app.present_count = 0, 0
            end
            if gfx.host_frames and gfx.host_frames > 0 then
                present = present .. (", %d tris, host %.1f ms/frame"):format(gfx.last_count or 0,
                    gfx.host_time / gfx.host_frames * 1000)
                if gfx.stage_report then present = present .. gfx:stage_report() end
                gfx.host_time, gfx.host_frames = 0, 0
            end
            local ticks = app.frames - (app.fps_ticks or 0)
            app.fps_ticks = app.frames
            present = present .. (", engine %.1f ticks/s, %.1f ms/tick outside"):format(ticks / (now - app.fps_clock),
                ticks > 0 and (app.engine_gap or 0) / ticks * 1000 or 0)
            app.engine_gap = 0
            log(("%s: %.1f fps%s"):format(m.path, fps_frames / (now - app.fps_clock), present))
            fps_frames, app.fps_clock = 0, now
        end
    end

    -- Захват мыши (vc_mouse_grab / vc_mouse_delta): gui.set_active_frame("") — null-фрейм, курсор
    -- захвачен движком (doc/ru/scripting/builtins/libgui.md); отпускание — прежний активный фрейм.
    -- Дельты input.get_mouse_delta() (пиксели окна за кадр движка) копятся в тиках между опросами
    -- программы; один кадр движка считается один раз (time.uptime() не изменился — тот же кадр).
    local grab = { on = false, saved = nil, dx = 0, dy = 0, last_t = nil }
    app.grab = grab
    local function grab_tick()
        if not grab.on then return end
        local t = time.uptime()
        if t == grab.last_t then return end
        grab.last_t = t
        local ok, d = pcall(input.get_mouse_delta)
        if ok and d then
            grab.dx = grab.dx + (d[1] or 0)
            grab.dy = grab.dy + (d[2] or 0)
        end
    end
    app.grab_tick = grab_tick
    local function apply_grab(on)
        if on == grab.on then return grab.on end
        if on then
            local ok, frame = pcall(gui.get_active_frame)
            grab.saved = ok and frame or nil
            local ok2, err = pcall(gui.set_active_frame, "")
            if not ok2 then
                log("mouse grab failed: " .. tostring(err))
                return false
            end
            grab.on, grab.dx, grab.dy, grab.last_t = true, 0, 0, time.uptime()
            pcall(input.get_mouse_delta)
            log(("mouse grabbed (previous active frame %q)"):format(tostring(grab.saved)))
        else
            grab.on = false
            -- gui.get_active_frame() отдаёт id корневого элемента документа ("root"), а
            -- set_active_frame ждёт id фрейма ("core:main" = gui.main_frame_id): set("root")
            -- оставлял null-фрейм, и курсор не отпускался (проверено пробой в движке).
            local target = grab.saved
            if type(target) ~= "string" or not target:find(":", 1, true) then target = gui.main_frame_id end
            if embed.release_grab then target = "embed" end
            local ok, err = pcall(embed.release_grab or gui.set_active_frame, target)
            if not ok then log("mouse release failed: " .. tostring(err)) end
            local ok2, now = pcall(gui.get_active_frame)
            if ok2 and now == nil and target ~= gui.main_frame_id and not embed.release_grab then
                pcall(gui.set_active_frame, gui.main_frame_id)
                ok2, now = pcall(gui.get_active_frame)
            end
            log(("mouse released (frame %s, active %q)"):format(tostring(target), tostring(now)))
        end
        return grab.on
    end
    -- Программа просит захват (wanted); при встраивании (embed.input_enabled) он действует, только
    -- пока ввод программе открыт: игрок отошёл от компьютера — курсор отпускается, вернулся —
    -- захватывается снова (sync_grab на каждом тике), а программа всё это время считает, что
    -- курсор у неё (иначе Quake не просит захват повторно до смены состояния).
    local function set_grab(on)
        grab.wanted = on
        if on and not input_enabled() then return true end
        return apply_grab(on)
    end
    local function sync_grab()
        local want = grab.wanted and input_enabled() or false
        if want ~= grab.on then apply_grab(want) end
    end
    app.set_grab = set_grab

    local vc = {
        -- захват курсора: 1 — захватить (курсор скрыт, дельты через vc_mouse_delta), 0 — отпустить;
        -- возвращает 1, если курсор захвачен
        mouse_grab = function(on) return set_grab(on ~= 0) and 1 or 0 end,
        -- out[0], out[1] — сдвиг мыши в пикселях окна с прошлого вызова (y вниз); 1 — захвачен
        mouse_delta = function(out_ptr)
            local dx, dy = math.floor(grab.dx), math.floor(grab.dy)
            grab.dx, grab.dy = grab.dx - dx, grab.dy - dy
            api.write_i32(memory, out_ptr, dx)
            api.write_i32(memory, out_ptr + 4, dy)
            return grab.on and 1 or 0
        end,
        gfx_submit = function(ptr, count)
            gfx:submit(api, memory, ptr, count)
            count_frame()
        end,
        gfx_present = function(ptr, w, h)
            count_frame()
            if m.frame_pacing == "slice" and os.clock() < deadline then
                return  -- кадр не показываем: квант ещё не исчерпан
            end
            gfx:present(api, memory, ptr, w, h)
            frame_boundary()
        end,
        frame_end = frame_boundary,
        gfx_texture = function(id, ptr, w, h) gfx:texture(api, memory, id, ptr, w, h) end,
        gfx_present_indexed = function(ptr, w, h, pal_ptr)
            count_frame()
            if m.frame_pacing == "slice" and os.clock() < deadline then
                return
            end
            local t0 = os.clock()
            gfx:present_indexed(api, memory, ptr, w, h, pal_ptr)
            app.present_time = (app.present_time or 0) + (os.clock() - t0)
            app.present_count = (app.present_count or 0) + 1
            frame_boundary()
        end,
        -- 16-битный кадр ref_soft Xash3D (12.10, пак halflife): цвет на GPU, только canvas
        gfx_present_rgb16 = function(ptr, w, h)
            count_frame()
            if m.frame_pacing == "slice" and os.clock() < deadline then
                return
            end
            local t0 = os.clock()
            if gfx.present_rgb16 then
                gfx:present_rgb16(api, memory, ptr, w, h)
            elseif not app.rgb16_warned then
                app.rgb16_warned = true
                log("gfx_present_rgb16: graphics " .. tostring(m.graphics) .. " has no rgb16 mode (canvas only)")
            end
            app.present_time = (app.present_time or 0) + (os.clock() - t0)
            app.present_count = (app.present_count or 0) + 1
            frame_boundary()
        end,
        mouse = function(out_ptr)
            local pos = mouse_pos()
            local x, y, inside = gfx:to_virtual(pos[1], pos[2])
            local buttons = (is_pressed("mouse:left") and 1 or 0)
                + (is_pressed("mouse:right") and 2 or 0)
                + (is_pressed("mouse:middle") and 4 or 0)
            api.write_i32(memory, out_ptr, x or -1)
            api.write_i32(memory, out_ptr + 4, y or -1)
            api.write_i32(memory, out_ptr + 8, buttons)
            return inside and 1 or 0
        end,
        audio_open = function(rate, channels)
            if sound then return 1 end
            if not (audio and audio.PCMStream and audio.play_stream_2d) then return 0 end
            local stream = audio.PCMStream(rate, channels, 16)
            local alias = ("wasmrt-audio-%d"):format(math.floor(time.uptime() * 1000))
            stream:share(alias)
            local speaker = audio.play_stream_2d(alias, 1.0, 1.0, "ui", true)
            if not speaker or speaker == 0 then return 0 end
            sound = { stream = stream, speaker = speaker, channels = channels }
            log(("audio: %d Hz x%d, speaker %s"):format(rate, channels, tostring(speaker)))
            return 1
        end,
        audio_write = function(ptr, frames)
            if not sound or frames <= 0 then return end
            local size = frames * sound.channels * 2
            local data = Bytearray(size)
            api.copy_out(memory, ptr, size, data.bytes, 0)
            sound.stream:feed(data)
        end,
        key_down = function(name_ptr)
            local name = key_names[name_ptr]
            if not name then
                name = "key:" .. api.read_cstring(memory, name_ptr, 64)
                key_names[name_ptr] = name
            end
            return is_pressed(name) and 1 or 0
        end,
        time_ms = function() return math.floor(time.uptime() * 1000) % 2147483648 end,
        log = function(ptr) log("log: " .. api.read_cstring(memory, ptr)) end,
    }

    local imports = { wasi_snapshot_preview1 = wasi.imports, vc = vc }
    -- Программы TeaVM (Java -> wasm): математика и время хоста.
    imports.teavmMath = setmetatable({}, { __index = function(_, k) return math[k] end })
    -- teavm.nanoTime отдаёт МИЛЛИСЕКУНДЫ (double): TSystem.nanoTime() в wasm-варианте умножает
    -- результат импорта на 1e6 (проверено javap по teavm-classlib 0.10.2). Раньше здесь были
    -- наносекунды, и таймер Minecraft выдавал ~40 тиков/с вместо 20.
    imports.teavm = { nanoTime = function() return time.uptime() * 1000 end }
    -- Расширение пака: модуль с function(ctx) -> { имя = функция } для модуля vc.
    if m.extension then
        local ctx = {
            manifest = m, gfx = gfx, log = log, frame_boundary = frame_boundary, count_frame = count_frame,
            document = document, grab = grab, set_grab = set_grab,
            -- встраивание (embed): контейнер для своих элементов, курсор и ввод
            parent = embed.parent or (document and document.root), mouse_pos = mouse_pos,
            is_pressed = is_pressed, input_enabled = input_enabled,
            api = function() return api end, memory = function() return memory end,
            -- для долгих импортов расширения (ядра smollm): уступить кадр, если квант slice_ms исчерпан
            slice_yield = function()
                if mode == "main" and coroutine.running() == co and os.clock() >= deadline then
                    coroutine.yield("slice")
                end
            end,
        }
        for name, fn in pairs(require(m.extension)(ctx)) do
            -- __tick: вызывается на каждом тике движка (опрос ввода между кадрами программы)
            if name == "__tick" then app.extension_tick = fn else vc[name] = fn end
        end
    end

    local loader = host.load(m.module)
    exports = host.instantiate(loader, imports)
    wasi:bind(exports)
    api, memory = exports.__host, exports.memory

    local function finish(ok, err)
        set_grab(false)  -- программа завершилась или упала: курсор отпустить
        local code = WASI.exit_code(err)
        if ok or code then
            app.status = "exited"
            app.message = "exit " .. tostring(code or 0)
        else
            app.status = "error"
            app.message = tostring(err)
            -- стек упавшей корутины одной строкой: номера строк модуля (имена — по --[[fn:]])
            if co then
                local module_file = m.module:match("([^/:]+)$")
                local lines = {}
                for file, line in debug.traceback(co):gmatch("([^%s:]+):(%d+):") do
                    if file:find(module_file, 1, true) then lines[#lines + 1] = line end
                end
                log(("crash %s"):format(table.concat(lines, "<")))
            end
        end
        log(("%s: %s"):format(m.path, app.message))
    end

    if exports.vc_frame then
        mode = "frame"
        local ok, err = pcall(function()
            if exports._initialize then exports._initialize() end
            if exports.vc_init then exports.vc_init() end
        end)
        if not ok then finish(false, err) end
    elseif exports._start then
        mode = "main"
        co = coroutine.create(exports._start)
        if api.has_yield_points then
            -- Профилировщик (манифест "profile": true): стек Lua в точках уступки, раз в 5 с
            -- в лог топ стеков "[wasmrt] profile" (строки модуля; имена — по меткам --[[fn:]]).
            -- Сэмпл взвешен временем: стеку в точке уступки приписывается время, прошедшее
            -- с предыдущего сэмпла (код без циклов, рантайм-хелперы и импорты хоста между
            -- уступками попадают в стек следующей уступки). Время вне корутины (кадр движка
            -- между квантами) не считается: app:tick сбрасывает часы перед resume.
            local samples, sample_count, sample_ms, profile_clock = {}, 0, 0, os.clock()
            local module_file = m.module:match("([^/:]+)$")
            local next_sample, last_sample = 0, os.clock()
            local function sample()
                local now = os.clock()
                if now < next_sample then return end
                next_sample = now + 0.005  -- не чаще раза в 5 мс: traceback дорогой
                local elapsed = (now - last_sample) * 1000
                last_sample = now
                local tb = debug.traceback("", 2)
                local lines = {}
                for file, line in tb:gmatch("([^%s:]+):(%d+):") do
                    if file:find(module_file, 1, true) then
                        lines[#lines + 1] = line
                        if #lines >= 10 then break end
                    end
                end
                if #lines > 0 then
                    local key = table.concat(lines, "<")
                    local rec = samples[key]
                    if not rec then rec = { 0, 0 }; samples[key] = rec end
                    rec[1], rec[2] = rec[1] + 1, rec[2] + elapsed
                    sample_count, sample_ms = sample_count + 1, sample_ms + elapsed
                end
                if os.clock() - profile_clock >= 5 then
                    local list = {}
                    for key, rec in pairs(samples) do list[#list + 1] = { key, rec[1], rec[2] } end
                    table.sort(list, function(a, b) return a[3] > b[3] end)
                    log(("profile %d samples %d ms"):format(sample_count, sample_ms))
                    for i = 1, math.min(20, #list) do
                        log(("profile %d %s"):format(list[i][3] + 0.5, list[i][1]))
                    end
                    samples, sample_count, sample_ms, profile_clock = {}, 0, 0, os.clock()
                end
            end
            app.profile_resumed = function() last_sample = os.clock() end
            api.set_yield_hook(function()
                if m.profile then sample() end
                if os.clock() >= deadline and coroutine.running() == co then
                    coroutine.yield("slice")
                    if m.profile then last_sample = os.clock() end
                end
            end, m.profile and 2000 or 20000)
        end
    else
        finish(false, "module exports neither vc_frame nor _start")
    end
    log(("%s started: mode %s, graphics %s %dx%d, yield points %s"):format(
        m.path, tostring(mode), m.graphics, m.width, m.height, tostring(api.has_yield_points)))

    local last = time.uptime()
    function app:tick()
        if self.status ~= "running" then return end
        local tick_start = os.clock()
        if self.tick_end then
            -- время движка между тиками (кадр движка: отрисовка, GPU, прочие скрипты)
            self.engine_gap = (self.engine_gap or 0) + (tick_start - self.tick_end)
        end
        if embed.input_enabled then sync_grab() end
        grab_tick()
        if self.extension_tick then self.extension_tick() end
        local now = time.uptime()
        local dt_ms = math.floor((now - last) * 1000 + 0.5)
        last = now
        if mode == "frame" then
            local ok, err = pcall(exports.vc_frame, dt_ms)
            if not ok then return finish(false, err) end
        else
            deadline = os.clock() + m.slice_ms / 1000
            if self.profile_resumed then self.profile_resumed() end
            local ok, err = coroutine.resume(co)
            if coroutine.status(co) == "dead" then return finish(ok, err) end
        end
        self.frames = self.frames + 1
        self.tick_end = os.clock()
    end

    function app:stop()
        if self.status == "running" then self.status = "stopped" end
        set_grab(false)
        if sound and audio and audio.stop then
            audio.stop(sound.speaker)
            sound = nil
        end
        gfx:deactivate()
        host.set_jit_tuned(false)
    end

    function app:set_debug(mode_, x, y) gfx:set_debug(mode_, x, y) end

    app.exports = exports
    app.wasi = wasi
    return app
end

-- Для документов: проект кладёт манифест в pending и открывает оверлей/страницу wasmrt.
local pending = nil
function M.set_pending(manifest) pending = manifest end

-- Сообщение вместо программы (например, «сервер не запущен»): строки текста на странице wasmrt_app
-- под кнопкой Back; программа не запускается. Сбрасывается при показе.
local notice = nil
function M.set_notice(lines) notice = type(lines) == "string" and { lines } or lines end

local function xml_escape(text)
    return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
M.xml_escape = xml_escape

-- Показывает строки текста в документе (панель слева сверху, под кнопками страницы).
function M.show_notice(document, lines, id)
    local parts = {}
    for i, line in ipairs(lines) do
        parts[#parts + 1] = ('<label id="%s_%d" size="900, 24">%s</label>'):format(id or "wasmrt_notice", i, xml_escape(line))
    end
    document.root:add(('<panel id="%s" pos="8, 56" size="920, %d" padding="8" interval="4" color="#40000080">%s</panel>')
        :format(id or "wasmrt_notice", #lines * 28 + 16, table.concat(parts)))
end

-- Вызывается из on_open документа wasmrt: запускает pending и крутит тики таймером документа.
function M.attach(document)
    if not pending then
        if notice then
            local ok, err = pcall(M.show_notice, document, notice)
            if not ok then log("notice failed: " .. tostring(err)) end
            for _, line in ipairs(notice) do log("notice: " .. line) end
            notice = nil
        end
        return nil
    end
    local manifest = pending
    pending = nil
    local ok, app = pcall(M.start, manifest, document)
    if not ok then
        log("start failed: " .. tostring(app))
        return nil
    end
    -- Esc на страницах меню движок обрабатывает как «назад» (res/scripts/stdlib.lua: menu:back()), и
    -- программа закрывалась посреди игры. Пока программа работает, Esc остаётся ей (пауза Minecraft,
    -- меню Doom/Quake); обработчик с владельцем document.root возвращает true и не пускает предыдущие
    -- (doc/ru/scripting/builtins/libinput.md). Выход со страницы — кнопкой «Back to Main Menu».
    if app.manifest.capture_escape ~= false and input and input.add_callback then
        input.add_callback("key:escape", function() return app.status == "running" end, document.root)
    end
    document.root:setInterval(TIMER_INTERVAL_MS, function() app:tick() end)
    M.current = app
    events.emit("wasmrt:started", app.manifest.path)
    return app
end

-- В мире: HUD-оверлей wasmrt:screen с программой проекта.
function M.show_overlay(manifest)
    M.set_pending(manifest)
    hud.show_overlay("wasmrt:screen", false)
end

return M
