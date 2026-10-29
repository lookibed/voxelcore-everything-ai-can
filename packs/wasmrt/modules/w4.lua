-- wasmrt: хост фэнтези-консоли WASM-4 (https://wasm4.org) — запуск публичных картриджей
-- без пересборки. Порт эталонного нативного рантайма (github.com/aduros/wasm4,
-- runtimes/native/src: runtime.c, framebuffer.c, apu.c; лицензия ISC) на Lua.
--
-- Картридж импортирует память (env.memory, 64 КБ) и функции env.*; экспортирует
-- start (один раз) и update (60 раз в секунду). Экран 160x160, 2 бита на пиксель,
-- палитра из 4 цветов. Вывод — через бэкенд canvas пака wasmrt.
--
-- Манифест: { "platform": "wasm4", "module": "<путь Lua-модуля картриджа>" }.
-- Клавиши: стрелки — крестовина, X / Space — кнопка X, Z / C — кнопка Z; мышь — над экраном.
-- Сохранения (diskw) — в export:wasm4/<имя картриджа>.disk.

local host = require "wasmrt:host"
local gfx_canvas = require "wasmrt:gfx_canvas"
local FONT = require "wasmrt:w4font"

local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
local floor, abs, min, max = math.floor, math.abs, math.min, math.max

local M = {}

local WIDTH, HEIGHT = 160, 160
local ADDR_PALETTE = 0x04
local ADDR_DRAW_COLORS = 0x14
local ADDR_GAMEPADS = 0x16
local ADDR_MOUSE_X = 0x1a
local ADDR_MOUSE_Y = 0x1c
local ADDR_MOUSE_BUTTONS = 0x1e
local ADDR_SYSTEM_FLAGS = 0x1f
local ADDR_FRAMEBUFFER = 0xa0
local FRAMEBUFFER_SIZE = WIDTH * HEIGHT / 4
local SYSTEM_PRESERVE_FRAMEBUFFER = 1
local FRAME_TIME = 1 / 60

local SAMPLE_RATE = 44100
local SAMPLES_PER_FRAME = SAMPLE_RATE / 60   -- 735
local MAX_VOLUME = 0x1333
local MAX_VOLUME_TRIANGLE = 0x2000
local RELEASE_TIME_TRIANGLE = SAMPLE_RATE / 1000

local function log(message)
    debug.log("[wasm4] " .. message)
end

-- i32 из Spider может прийти беззнаковым: координаты и размеры в C — int.
local function s32(v)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
end

local function u32(v)
    if v < 0 then return v + 0x100000000 end
    return v
end

-- APU (apu.c) ----------------------------------------------------------------------

local function new_apu()
    local channels = {}
    for i = 0, 3 do
        channels[i] = {
            freq1 = 0, freq2 = 0, startTime = 0, attackTime = 0, decayTime = 0, sustainTime = 0,
            releaseTime = 0, endTick = -1, sustainVolume = 0, peakVolume = 0, phase = 0, pan = 0,
            dutyCycle = 0.125, seed = 1, lastRandom = 0,
        }
    end
    local apu = { time = 0, ticks = 0 }

    local function ramp(v1, v2, t1, t2)
        if apu.time >= t2 then return v2 end
        local t = (apu.time - t1) / (t2 - t1)
        return v1 + t * (v2 - v1)
    end

    local function current_freq(ch)
        if ch.freq2 > 0 then return ramp(ch.freq1, ch.freq2, ch.startTime, ch.releaseTime) end
        return ch.freq1
    end

    local function current_volume(ch)
        local t = apu.time
        if t >= ch.sustainTime and (ch.releaseTime - ch.sustainTime) > RELEASE_TIME_TRIANGLE then
            return floor(ramp(ch.sustainVolume, 0, ch.sustainTime, ch.releaseTime))
        elseif t >= ch.decayTime then
            return ch.sustainVolume
        elseif t >= ch.attackTime then
            return floor(ramp(ch.peakVolume, ch.sustainVolume, ch.attackTime, ch.decayTime))
        end
        return floor(ramp(0, ch.peakVolume, ch.startTime, ch.attackTime))
    end

    local function polyblep(phase, inc)
        if phase < inc then
            local t = phase / inc
            return t + t - t * t
        elseif phase > 1 - inc then
            local t = (phase - (1 - inc)) / inc
            return 1 - (t + t - t * t)
        end
        return 1
    end

    local function midi_freq(note, bend)
        return 2 ^ ((note - 69 + bend / 256) / 12) * 440
    end

    function apu.tone(frequency, duration, volume, flags)
        frequency, duration, volume, flags = u32(frequency), u32(duration), u32(volume), u32(flags)
        local freq1 = band(frequency, 0xffff)
        local freq2 = band(rshift(frequency, 16), 0xffff)
        local sustain = band(duration, 0xff)
        local release = band(rshift(duration, 8), 0xff)
        local decay = band(rshift(duration, 16), 0xff)
        local attack = band(rshift(duration, 24), 0xff)
        local sustainVolume = min(band(volume, 0xff), 100)
        local peakVolume = min(band(rshift(volume, 8), 0xff), 100)
        local idx = band(flags, 3)
        local mode = band(rshift(flags, 2), 3)
        local pan = band(rshift(flags, 4), 3)
        local noteMode = band(flags, 0x40) ~= 0
        local ch = channels[idx]

        if apu.time > ch.releaseTime and apu.ticks ~= ch.endTick then
            ch.phase = (idx == 2) and 0.25 or 0
        end
        if noteMode then
            ch.freq1 = midi_freq(band(freq1, 0xff), rshift(freq1, 8))
            ch.freq2 = (freq2 == 0) and 0 or midi_freq(band(freq2, 0xff), rshift(freq2, 8))
        else
            ch.freq1, ch.freq2 = freq1, freq2
        end
        ch.startTime = apu.time
        ch.attackTime = ch.startTime + floor(SAMPLE_RATE * attack / 60)
        ch.decayTime = ch.attackTime + floor(SAMPLE_RATE * decay / 60)
        ch.sustainTime = ch.decayTime + floor(SAMPLE_RATE * sustain / 60)
        ch.releaseTime = ch.sustainTime + floor(SAMPLE_RATE * release / 60)
        ch.endTick = apu.ticks + attack + decay + sustain + release
        local maxVolume = (idx == 2) and MAX_VOLUME_TRIANGLE or MAX_VOLUME
        ch.sustainVolume = floor(maxVolume * sustainVolume / 100)
        ch.peakVolume = peakVolume ~= 0 and floor(maxVolume * peakVolume / 100) or maxVolume
        ch.pan = pan
        if idx == 0 or idx == 1 then
            ch.dutyCycle = (mode == 0 and 0.125) or (mode == 2 and 0.5) or 0.25
        elseif idx == 2 and release == 0 then
            ch.releaseTime = ch.releaseTime + RELEASE_TIME_TRIANGLE
        end
    end

    function apu.tick()
        apu.ticks = apu.ticks + 1
    end

    local function clamp16(v)
        if v > 32767 then return 32767 elseif v < -32768 then return -32768 end
        return v
    end

    -- frames стерео-кадров int16 в out[0..], возвращает true, если был звук.
    function apu.write(out, frames)
        local any = false
        local o = 0
        for _ = 1, frames do
            local left, right = 0, 0
            local t = apu.time
            for idx = 0, 3 do
                local ch = channels[idx]
                if t < ch.releaseTime or apu.ticks == ch.endTick then
                    any = true
                    local freq = current_freq(ch)
                    local volume = current_volume(ch)
                    local sample
                    if idx == 3 then
                        ch.phase = ch.phase + freq * freq / (1000000 / 44100 * SAMPLE_RATE)
                        while ch.phase > 0 do
                            ch.phase = ch.phase - 1
                            local s = ch.seed
                            s = bxor(s, rshift(s, 7))
                            s = band(bxor(s, lshift(s, 9)), 0xffff)
                            s = bxor(s, rshift(s, 13))
                            ch.seed = s
                            ch.lastRandom = 2 * band(s, 1) - 1
                        end
                        sample = volume * ch.lastRandom
                    else
                        local inc = freq / SAMPLE_RATE
                        ch.phase = ch.phase + inc
                        if ch.phase >= 1 then ch.phase = ch.phase - 1 end
                        if idx == 2 then
                            sample = volume * (2 * abs(2 * ch.phase - 1) - 1)
                        else
                            local duty = ch.dutyCycle
                            local dp, di, mul
                            if ch.phase < duty then
                                dp, di, mul = ch.phase / duty, inc / duty, volume
                            else
                                dp, di, mul = (ch.phase - duty) / (1 - duty), inc / (1 - duty), -volume
                            end
                            sample = mul * polyblep(dp, di)
                        end
                    end
                    sample = floor(sample)
                    if ch.pan ~= 1 then right = right + sample end
                    if ch.pan ~= 2 then left = left + sample end
                end
            end
            left, right = clamp16(left), clamp16(right)
            if left < 0 then left = left + 65536 end
            if right < 0 then right = right + 65536 end
            out[o] = band(left, 255); out[o + 1] = rshift(left, 8)
            out[o + 2] = band(right, 255); out[o + 3] = rshift(right, 8)
            o = o + 4
            apu.time = t + 1
        end
        return any
    end

    return apu
end

-- Запуск ---------------------------------------------------------------------------

function M.start(m, document)
    local app = { manifest = m, status = "running", frames = 0 }
    local cart_name = (m.module:match("([^/:]+)%.lua$")) or "cart"

    host.set_jit_tuned(m.jit ~= "default")
    local loader, api = host.load(m.module)
    assert(api and api.new_memory, "module has no host API: rebuild it with a current Spider")
    local memory = api.new_memory(65536, 65536)

    local read_u8, write_u8 = api.read_u8, api.write_u8
    local read_i32, write_i32 = api.read_i32, api.write_i32

    -- Начальное состояние памяти (w4_runtimeInit): палитра, DRAW_COLORS, мышь вне экрана.
    local DEFAULT_PALETTE = { 0xe0f8cf, 0x86c06c, 0x306850, 0x071821 }
    for i = 1, 4 do write_i32(memory, ADDR_PALETTE + (i - 1) * 4, DEFAULT_PALETTE[i]) end
    write_u8(memory, ADDR_DRAW_COLORS, 0x03)
    write_u8(memory, ADDR_DRAW_COLORS + 1, 0x12)
    api.write_u16(memory, ADDR_MOUSE_X, 0x7fff)
    api.write_u16(memory, ADDR_MOUSE_Y, 0x7fff)

    -- Кадровый буфер (framebuffer.c) -------------------------------------------------

    local function draw_point(color, x, y)
        local idx = ADDR_FRAMEBUFFER + rshift(WIDTH * y + x, 2)
        local shift = lshift(band(x, 3), 1)
        local mask = lshift(3, shift)
        write_u8(memory, idx, bor(lshift(color, shift), band(read_u8(memory, idx), bxor(mask, 255))))
    end

    local function draw_point_unclipped(color, x, y)
        if x >= 0 and x < WIDTH and y >= 0 and y < HEIGHT then draw_point(color, x, y) end
    end

    local function draw_hline(color, startX, y, endX)
        local fillEnd = endX - band(endX, 3)
        local fillStart = min(band(startX + 3, bxor(3, -1)), fillEnd)
        if fillEnd - fillStart > 3 then
            for xx = startX, fillStart - 1 do draw_point(color, xx, y) end
            local from = ADDR_FRAMEBUFFER + rshift(WIDTH * y + fillStart, 2)
            local to = ADDR_FRAMEBUFFER + rshift(WIDTH * y + fillEnd, 2)
            api.fill(memory, from, color * 0x55, to - from)
            startX = fillEnd
        end
        for xx = startX, endX - 1 do draw_point(color, xx, y) end
    end

    local function draw_hline_unclipped(color, startX, y, endX)
        if y >= 0 and y < HEIGHT then
            if startX < 0 then startX = 0 end
            if endX > WIDTH then endX = WIDTH end
            if startX < endX then draw_hline(color, startX, y, endX) end
        end
    end

    local function draw_colors() return read_u8(memory, ADDR_DRAW_COLORS), read_u8(memory, ADDR_DRAW_COLORS + 1) end

    local function blit(sprite_at, dstX, dstY, width, height, srcX, srcY, stride, bpp2, flipX, flipY, rotate)
        local dc0, dc1 = draw_colors()
        local colors = bor(dc0, lshift(dc1, 8))
        local clipXMin, clipYMin, clipXMax, clipYMax
        if rotate then
            flipX = not flipX
            clipXMin = max(0, dstY) - dstY
            clipYMin = max(0, dstX) - dstX
            clipXMax = min(width, HEIGHT - dstY)
            clipYMax = min(height, WIDTH - dstX)
        else
            clipXMin = max(0, dstX) - dstX
            clipYMin = max(0, dstY) - dstY
            clipXMax = min(width, WIDTH - dstX)
            clipYMax = min(height, HEIGHT - dstY)
        end
        for y = clipYMin, clipYMax - 1 do
            for x = clipXMin, clipXMax - 1 do
                local tx = dstX + (rotate and y or x)
                local ty = dstY + (rotate and x or y)
                local sx = srcX + (flipX and (width - x - 1) or x)
                local sy = srcY + (flipY and (height - y - 1) or y)
                local bitIndex = sy * stride + sx
                local colorIdx
                if bpp2 then
                    local byte = sprite_at(rshift(bitIndex, 2))
                    colorIdx = band(rshift(byte, 6 - lshift(band(bitIndex, 3), 1)), 3)
                else
                    local byte = sprite_at(rshift(bitIndex, 3))
                    colorIdx = band(rshift(byte, 7 - band(bitIndex, 7)), 1)
                end
                local dc = band(rshift(colors, lshift(colorIdx, 2)), 0x0f)
                if dc ~= 0 then draw_point(band(dc - 1, 3), tx, ty) end
            end
        end
    end

    local function memory_sprite(ptr)
        return function(i) return read_u8(memory, ptr + i) end
    end
    local function font_sprite(i) return FONT:byte(i + 1) or 0 end

    local function text_bytes(get, count, x, y)
        local currentX = x
        for k = 0, count - 1 do
            local c = get(k)
            if c == 0 then break end
            if c == 10 then
                y = y + 8
                currentX = x
            elseif c >= 32 and c <= 255 then
                blit(font_sprite, currentX, y, 8, 8, 0, lshift(c - 32, 3), 8, false, false, false, false)
                currentX = currentX + 8
            else
                currentX = currentX + 8
            end
        end
    end

    local function oval(x, y, width, height)
        local dc01 = read_u8(memory, ADDR_DRAW_COLORS)
        local dc0 = band(dc01, 0xf)
        local dc1 = band(rshift(dc01, 4), 0xf)
        if dc1 == 0xf then return end
        local strokeColor = band(dc1 - 1, 3)
        local fillColor = band(dc0 - 1, 3)
        local a = width - 1
        local b = height - 1
        local b1 = b % 2
        local north = y + floor(height / 2)
        local west = x
        local east = x + width - 1
        local south = north - b1
        local a2 = a * a
        local b2 = b * b
        local dx = 4 * (1 - a) * b2
        local dy = 4 * (b1 + 1) * a2
        local err = dx + dy + b1 * a2
        a = 8 * a2
        b1 = 8 * b2
        repeat
            draw_point_unclipped(strokeColor, east, north)
            draw_point_unclipped(strokeColor, west, north)
            draw_point_unclipped(strokeColor, west, south)
            draw_point_unclipped(strokeColor, east, south)
            local start = west + 1
            local len = east - start
            if dc0 ~= 0 and len > 0 then
                draw_hline_unclipped(fillColor, start, north, east)
                draw_hline_unclipped(fillColor, start, south, east)
            end
            local err2 = 2 * err
            if err2 <= dy then
                north = north + 1
                south = south - 1
                dy = dy + a
                err = err + dy
            end
            if err2 >= dx or err2 > dy then
                west = west + 1
                east = east - 1
                dx = dx + b1
                err = err + dx
            end
        until not (west <= east)
        while north - south < height do
            draw_point_unclipped(strokeColor, west - 1, north)
            draw_point_unclipped(strokeColor, east + 1, north)
            north = north + 1
            draw_point_unclipped(strokeColor, west - 1, south)
            draw_point_unclipped(strokeColor, east + 1, south)
            south = south - 1
        end
    end

    local function rect(x, y, width, height)
        local startX, startY = max(0, x), max(0, y)
        local endXU, endYU = x + width, y + height
        local endX = max(0, min(endXU, WIDTH))
        local endY = max(0, min(endYU, HEIGHT))
        local dc01 = read_u8(memory, ADDR_DRAW_COLORS)
        local dc0 = band(dc01, 0xf)
        local dc1 = band(rshift(dc01, 4), 0xf)
        if dc0 ~= 0 then
            local fill = band(dc0 - 1, 3)
            for yy = startY, endY - 1 do draw_hline(fill, startX, yy, endX) end
        end
        if dc1 ~= 0 then
            local stroke = band(dc1 - 1, 3)
            if x >= 0 and x < WIDTH then
                for yy = startY, endY - 1 do draw_point(stroke, x, yy) end
            end
            if endXU > 0 and endXU <= WIDTH then
                for yy = startY, endY - 1 do draw_point(stroke, endXU - 1, yy) end
            end
            if y >= 0 and y < HEIGHT then draw_hline(stroke, startX, y, endX) end
            if endYU > 0 and endYU <= HEIGHT then draw_hline(stroke, startX, endYU - 1, endX) end
        end
    end

    local function line(x1, y1, x2, y2)
        local dc0 = band(read_u8(memory, ADDR_DRAW_COLORS), 0xf)
        if dc0 == 0 then return end
        local stroke = band(dc0 - 1, 3)
        if y1 > y2 then x1, x2, y1, y2 = x2, x1, y2, y1 end
        local dx, sx = abs(x2 - x1), x1 < x2 and 1 or -1
        local dy = y2 - y1
        local v = dx > dy and dx or -dy
        local err = v >= 0 and floor(v / 2) or -floor(-v / 2)
        while true do
            draw_point_unclipped(stroke, x1, y1)
            if x1 == x2 and y1 == y2 then break end
            local e2 = err
            if e2 > -dx then err = err - dy; x1 = x1 + sx end
            if e2 < dy then err = err + dx; y1 = y1 + 1 end
        end
    end

    -- Диск и трассировка -----------------------------------------------------------

    local disk_path = "export:wasm4/" .. cart_name .. ".disk"
    local disk = ""
    pcall(function()
        if file.isfile(disk_path) then disk = Bytearray_as_string(file.read_bytes(disk_path)) end
    end)

    local function trace(text) log(cart_name .. ": " .. text) end

    local function tracef(fmt_ptr, arg_ptr)
        local fmt = api.read_cstring(memory, fmt_ptr, 1024)
        local out, i = {}, 1
        while i <= #fmt do
            local c = fmt:sub(i, i)
            if c == "%" then
                i = i + 1
                local sym = fmt:sub(i, i)
                if sym == "" then break
                elseif sym == "%" then out[#out + 1] = "%"
                elseif sym == "c" then out[#out + 1] = string.char(band(read_i32(memory, arg_ptr), 255)); arg_ptr = arg_ptr + 4
                elseif sym == "d" then out[#out + 1] = tostring(s32(u32(read_i32(memory, arg_ptr)))); arg_ptr = arg_ptr + 4
                elseif sym == "x" then out[#out + 1] = ("%x"):format(u32(read_i32(memory, arg_ptr))); arg_ptr = arg_ptr + 4
                elseif sym == "s" then out[#out + 1] = api.read_cstring(memory, u32(read_i32(memory, arg_ptr)), 1024); arg_ptr = arg_ptr + 4
                elseif sym == "f" then out[#out + 1] = ("%g"):format(api.read_f64(memory, arg_ptr)); arg_ptr = arg_ptr + 8
                else out[#out + 1] = "%" .. sym end
            else
                out[#out + 1] = c
            end
            i = i + 1
        end
        trace(table.concat(out))
    end

    local apu = new_apu()

    local env = {
        memory = memory,
        blit = function(ptr, x, y, w, h, flags)
            flags = u32(flags)
            w, h = s32(w), s32(h)
            blit(memory_sprite(ptr), s32(x), s32(y), w, h, 0, 0, w,
                band(flags, 1) ~= 0, band(flags, 2) ~= 0, band(flags, 4) ~= 0, band(flags, 8) ~= 0)
        end,
        blitSub = function(ptr, x, y, w, h, srcX, srcY, stride, flags)
            flags = u32(flags)
            blit(memory_sprite(ptr), s32(x), s32(y), s32(w), s32(h), s32(srcX), s32(srcY), s32(stride),
                band(flags, 1) ~= 0, band(flags, 2) ~= 0, band(flags, 4) ~= 0, band(flags, 8) ~= 0)
        end,
        line = function(x1, y1, x2, y2) line(s32(x1), s32(y1), s32(x2), s32(y2)) end,
        hline = function(x, y, len)
            local dc0 = band(read_u8(memory, ADDR_DRAW_COLORS), 0xf)
            if dc0 == 0 then return end
            x, y = s32(x), s32(y)
            draw_hline_unclipped(band(dc0 - 1, 3), x, y, x + s32(len))
        end,
        vline = function(x, y, len)
            x, y, len = s32(x), s32(y), s32(len)
            if y + len <= 0 or x < 0 or x >= WIDTH then return end
            local dc0 = band(read_u8(memory, ADDR_DRAW_COLORS), 0xf)
            if dc0 == 0 then return end
            for yy = max(0, y), min(HEIGHT, y + len) - 1 do draw_point(band(dc0 - 1, 3), x, yy) end
        end,
        oval = function(x, y, w, h) oval(s32(x), s32(y), s32(w), s32(h)) end,
        rect = function(x, y, w, h) rect(s32(x), s32(y), s32(w), s32(h)) end,
        text = function(ptr, x, y)
            text_bytes(function(k) return read_u8(memory, ptr + k) end, 65536, s32(x), s32(y))
        end,
        textUtf8 = function(ptr, len, x, y)
            text_bytes(function(k) return read_u8(memory, ptr + k) end, s32(len), s32(x), s32(y))
        end,
        textUtf16 = function(ptr, len, x, y)
            text_bytes(function(k) return api.read_u16(memory, ptr + k * 2) end, floor(s32(len) / 2), s32(x), s32(y))
        end,
        tone = function(frequency, duration, volume, flags) apu.tone(frequency, duration, volume, flags) end,
        diskr = function(ptr, size)
            size = min(s32(size), #disk)
            if size > 0 then api.write_string(memory, ptr, disk:sub(1, size)) end
            return size
        end,
        diskw = function(ptr, size)
            size = min(s32(size), 1024)
            disk = size > 0 and api.read_string(memory, ptr, size) or ""
            pcall(function()
                if not file.isdir("export:wasm4") then file.mkdirs("export:wasm4") end
                local data = Bytearray(#disk)
                for i = 1, #disk do data[i] = disk:byte(i) end
                file.write_bytes(disk_path, data)
            end)
            return size
        end,
        trace = function(ptr) trace(api.read_cstring(memory, ptr, 4096)) end,
        traceUtf8 = function(ptr, len) trace(api.read_string(memory, ptr, s32(len))) end,
        traceUtf16 = function(ptr, len)
            local chars = {}
            for k = 0, floor(s32(len) / 2) - 1 do
                local c = api.read_u16(memory, ptr + k * 2)
                chars[#chars + 1] = c < 128 and string.char(c) or "?"
            end
            trace(table.concat(chars))
        end,
        tracef = function(fmt, args) tracef(fmt, args) end,
    }

    local exports = host.instantiate(loader, { env = env })
    -- Как в эталоне (web runtime.ts, native wasm_*.c): сразу после создания вызываются
    -- WASI-инициализаторы _start и _initialize (конструкторы C/C++/Rust), потом start().
    if exports._start then exports._start() end
    if exports._initialize then exports._initialize() end

    -- Экран и звук -----------------------------------------------------------------

    local gfx = gfx_canvas.new(document, WIDTH, HEIGHT)
    gfx:activate()
    app.gfx = gfx

    local sound, pcm = nil, nil
    if document and m.audio ~= false and audio and audio.PCMStream and audio.play_stream_2d then
        local stream = audio.PCMStream(SAMPLE_RATE, 2, 16)
        local alias = ("wasm4-%s-%d"):format(cart_name, floor(time.uptime() * 1000))
        stream:share(alias)
        local speaker = audio.play_stream_2d(alias, 1.0, 1.0, "ui", true)
        if speaker and speaker ~= 0 then
            sound = { stream = stream, speaker = speaker }
            pcm = Bytearray(SAMPLES_PER_FRAME * 4)
        end
    end

    local fb_bytes = {}
    local function composite()
        local palette = {}
        for i = 0, 3 do
            local c = u32(read_i32(memory, ADDR_PALETTE + i * 4))
            palette[i] = { band(rshift(c, 16), 255), band(rshift(c, 8), 255), band(c, 255) }
        end
        api.copy_out(memory, ADDR_FRAMEBUFFER, FRAMEBUFFER_SIZE, fb_bytes, 0)
        local p = gfx:bytes()
        local o = 0
        for i = 0, FRAMEBUFFER_SIZE - 1 do
            local byte = fb_bytes[i]
            for k = 0, 3 do
                local c = palette[band(rshift(byte, k * 2), 3)]
                p[o] = c[1]; p[o + 1] = c[2]; p[o + 2] = c[3]; p[o + 3] = 255
                o = o + 4
            end
        end
        gfx:upload()
    end

    local GAMEPAD_KEYS = {
        { 1, { "key:x", "key:space", "key:v" } },
        { 2, { "key:z", "key:c", "key:n" } },
        { 16, { "key:left" } }, { 32, { "key:right" } },
        { 64, { "key:up" } }, { 128, { "key:down" } },
    }

    local function poll_input()
        local pad = 0
        for _, entry in ipairs(GAMEPAD_KEYS) do
            for _, name in ipairs(entry[2]) do
                if input.is_pressed(name) then pad = bor(pad, entry[1]); break end
            end
        end
        write_u8(memory, ADDR_GAMEPADS, pad)
        local pos = input.get_mouse_pos()
        local x, y = gfx:to_virtual(pos[1], pos[2])
        if x then
            api.write_u16(memory, ADDR_MOUSE_X, band(x, 0xffff))
            api.write_u16(memory, ADDR_MOUSE_Y, band(y, 0xffff))
        end
        local buttons = (input.is_pressed("mouse:left") and 1 or 0) + (input.is_pressed("mouse:right") and 2 or 0)
            + (input.is_pressed("mouse:middle") and 4 or 0)
        write_u8(memory, ADDR_MOUSE_BUTTONS, buttons)
    end

    local first_frame = true
    local function run_frame()
        poll_input()
        if first_frame then
            first_frame = false
            if exports.start then exports.start() end
        elseif band(read_u8(memory, ADDR_SYSTEM_FLAGS), SYSTEM_PRESERVE_FRAMEBUFFER) == 0 then
            api.fill(memory, ADDR_FRAMEBUFFER, 0, FRAMEBUFFER_SIZE)
        end
        if exports.update then exports.update() end
        apu.tick()
        if sound then
            apu.write(pcm.bytes, SAMPLES_PER_FRAME)
            sound.stream:feed(pcm)
        end
        app.frames = app.frames + 1
    end

    local acc, last = 0, time.uptime()
    local fps_frames, fps_clock = 0, os.clock()
    log(("%s started (%s)"):format(cart_name, m.module))

    function app:tick()
        if self.status ~= "running" then return end
        local now = time.uptime()
        acc = min(acc + (now - last), FRAME_TIME * 3)
        last = now
        local ran = false
        local ok, err = pcall(function()
            while acc >= FRAME_TIME do
                acc = acc - FRAME_TIME
                run_frame()
                ran = true
            end
        end)
        if not ok then
            self.status = "error"
            self.message = tostring(err)
            log(("%s: error %s"):format(cart_name, self.message))
            return
        end
        if ran then
            composite()
            if m.log_fps then
                fps_frames = fps_frames + 1
                local c = os.clock()
                if c - fps_clock >= 5 then
                    log(("%s: %.1f frames/s shown, %d updates"):format(cart_name, fps_frames / (c - fps_clock), self.frames))
                    fps_frames, fps_clock = 0, c
                end
            end
        end
    end

    -- Для тестов без UI: n кадров подряд без экрана и звука.
    function app:run_frames(n)
        for _ = 1, n do run_frame() end
        composite()
    end

    function app:stop()
        if self.status == "running" then self.status = "stopped" end
        if sound and audio.stop then audio.stop(sound.speaker) end
        gfx:deactivate()
        host.set_jit_tuned(false)
    end

    function app:set_debug() end
    app.exports = exports
    app.memory, app.api = memory, api

    -- Сколько пикселей каждого из 4 цветов в кадровом буфере (для тестов).
    function app:color_histogram()
        local counts = { [0] = 0, 0, 0, 0 }
        api.copy_out(memory, ADDR_FRAMEBUFFER, FRAMEBUFFER_SIZE, fb_bytes, 0)
        for i = 0, FRAMEBUFFER_SIZE - 1 do
            local byte = fb_bytes[i]
            for k = 0, 3 do
                local c = band(rshift(byte, k * 2), 3)
                counts[c] = counts[c] + 1
            end
        end
        return counts
    end
    return app
end

return M
