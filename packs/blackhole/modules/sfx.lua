-- blackhole:sfx — процедурный звук: WAV (16 бит, моно, 22050 Гц) синтезируется в Lua, пишется в
-- config:blackhole/sfx/<имя>_v<N>.wav один раз (кеш по имени и версии синтеза), из файла делается звук-ассет
-- (audio.PCMStream:create_sound) и играется audio.play_sound с 3D-позицией (почему не play_stream — у M.load).
-- Моно обязательно: стерео OpenAL играет без учёта позиции (doc/en/audio.md).
local core = require "blackhole:core"

local M = {}
M.DIR = "config:blackhole/sfx"
M.RATE = 22050
M.VERSION = 1           -- номер синтеза: при правке формул меняется имя файла -> пересинтез
M.made = {}             -- имя -> путь
M.synth_ms = {}         -- имя -> мс синтеза (0 — взят из кеша)

local PI2 = math.pi * 2
local sin, exp, floor, min, max, abs = math.sin, math.exp, math.floor, math.min, math.max, math.abs

-- детерминированный шум (LCG), чтобы файлы были одинаковыми между запусками
local seed = 12345
local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 1073741824 - 1
end

-- запись массива float [-1..1] в WAV
local function write_wav(path, s, n)
    local ba = Bytearray(44 + n * 2)
    local function put(off, v, bytes)
        for i = 0, bytes - 1 do
            ba[off + i + 1] = floor(v / 256 ^ i) % 256
        end
    end
    local function tag(off, str)
        for i = 1, 4 do ba[off + i] = str:byte(i) end
    end
    tag(0, "RIFF"); put(4, 36 + n * 2, 4); tag(8, "WAVE"); tag(12, "fmt ")
    put(16, 16, 4); put(20, 1, 2); put(22, 1, 2); put(24, M.RATE, 4); put(28, M.RATE * 2, 4)
    put(32, 2, 2); put(34, 16, 2); tag(36, "data"); put(40, n * 2, 4)
    -- нормировка по пику
    local peak = 1e-6
    for i = 1, n do
        local a = abs(s[i]); if a > peak then peak = a end
    end
    local k = 0.85 * 32767 / peak
    local v = I16view(ba)
    for i = 1, n do
        local x = floor(s[i] * k + 0.5)
        if x > 32767 then x = 32767 elseif x < -32768 then x = -32768 end
        v[22 + i] = x
    end
    return file.write_bytes(path, ba)
end

-- однополюсный фильтр нижних частот
local function lowpass(s, n, a)
    local y = 0
    for i = 1, n do
        y = y + a * (s[i] - y)
        s[i] = y
    end
end

local SYN = {}

-- гул дыры: петля 4 с, все частоты — целое число периодов за 4 с (шов без щелчка), шум склеен кроссфейдом
SYN.hum = function()
    local R = M.RATE
    local n = R * 4
    local F = floor(R * 0.25)
    local nz = {}
    for i = 1, n + F do nz[i] = rnd() end
    lowpass(nz, n + F, 0.02)
    lowpass(nz, n + F, 0.05)
    local s = {}
    for i = 1, n do
        local t = (i - 1) / R
        local am = 0.65 + 0.35 * sin(PI2 * 0.5 * t) * sin(PI2 * 0.25 * t + 1.0)
        local v = 0.55 * sin(PI2 * 41.25 * t)
            + 0.35 * sin(PI2 * 55 * t + 0.3 * sin(PI2 * 0.75 * t))
            + 0.22 * sin(PI2 * 82.5 * t)
            + 0.10 * sin(PI2 * 123.75 * t + 1.7)
            + 0.30 * sin(PI2 * 27.5 * t)
        local z = nz[i]
        if i <= F then
            local w = (i - 1) / F
            z = nz[i] * w + nz[n + i] * (1 - w)
        end
        s[i] = v * am + z * 9.0
    end
    return s, n
end

-- «глоток»: падающий тон + полосовой шум, короткий
SYN.gulp = function()
    local R = M.RATE
    local n = floor(R * 0.30)
    local s, ph, lp, lp2 = {}, 0, 0, 0
    for i = 1, n do
        local t = (i - 1) / R
        local f = 70 + 420 * exp(-t * 11)
        ph = ph + PI2 * f / R
        local env = min(1, t / 0.006) * exp(-t * 13)
        local z = rnd()
        lp = lp + 0.25 * (z - lp)
        lp2 = lp2 + 0.25 * (lp - lp2)
        s[i] = (0.8 * sin(ph) + 0.6 * sin(ph * 0.5) + 2.2 * (lp - lp2)) * env
    end
    return s, n
end

-- тик фитиля: высокий щелчок
SYN.tick = function()
    local R = M.RATE
    local n = floor(R * 0.07)
    local s = {}
    for i = 1, n do
        local t = (i - 1) / R
        s[i] = (sin(PI2 * 2300 * t) * 0.8 + sin(PI2 * 3450 * t) * 0.3 + rnd() * 0.25) * exp(-t * 85)
    end
    return s, n
end

-- удар гранаты о землю: глухой стук
SYN.bounce = function()
    local R = M.RATE
    local n = floor(R * 0.14)
    local s, ph, lp = {}, 0, 0
    for i = 1, n do
        local t = (i - 1) / R
        ph = ph + PI2 * (55 + 120 * exp(-t * 40)) / R
        lp = lp + 0.15 * (rnd() - lp)
        s[i] = (sin(ph) + lp * 1.5) * exp(-t * 32)
    end
    return s, n
end

-- слияние: два тона сходятся в один, шумовой «вдох», удар
SYN.merge = function()
    local R = M.RATE
    local n = floor(R * 1.9)
    local s, p1, p2, p3, lp = {}, 0, 0, 0, 0
    for i = 1, n do
        local t = (i - 1) / R
        local u = min(1, t / 1.3)
        local f1 = 95 - 35 * u
        local f2 = 42 + 18 * u
        p1 = p1 + PI2 * f1 / R
        p2 = p2 + PI2 * f2 / R
        local swell = (t < 1.3) and (t / 1.3) ^ 2 or exp(-(t - 1.3) * 4)
        lp = lp + 0.04 * (rnd() - lp)
        local boom = 0
        if t >= 1.3 then
            local tb = t - 1.3
            p3 = p3 + PI2 * (32 + 40 * exp(-tb * 12)) / R
            boom = sin(p3) * exp(-tb * 5) * 1.3
        end
        s[i] = (0.5 * sin(p1) + 0.5 * sin(p2)) * swell + lp * 6 * swell + boom
    end
    return s, n
end

-- коллапс: всасывающий подъём 0.4 с, удар суб-баса 55 -> 22 Гц, шумовой взрыв и длинный рокочущий хвост
SYN.collapse = function()
    local R = M.RATE
    local n = floor(R * 3.6)
    local s, p, lp, lp2 = {}, 0, 0, 0
    for i = 1, n do
        local t = (i - 1) / R
        local v
        local z = rnd()
        if t < 0.4 then
            local u = t / 0.4
            p = p + PI2 * (60 + 300 * u * u) / R
            lp = lp + (0.02 + 0.3 * u) * (z - lp)
            v = (0.4 * sin(p) + lp * 2) * u * u
        else
            local tb = t - 0.4
            p = p + PI2 * (22 + 33 * exp(-tb * 3)) / R
            local a = 0.02 + 0.25 * exp(-tb * 6)
            lp = lp + a * (z - lp)
            lp2 = lp2 + 0.01 * (z - lp2)
            v = 1.4 * sin(p) * exp(-tb * 1.4) + lp * 3.0 * exp(-tb * 2.2) + lp2 * 14 * exp(-tb * 0.9)
            if tb < 0.02 then v = v + z * (1 - tb / 0.02) end
        end
        s[i] = v
    end
    return s, n
end

function M.path(name)
    return ("%s/%s_v%d.wav"):format(M.DIR, name, M.VERSION)
end

-- синтез по имени (если файла нет) -> путь
function M.ensure(name)
    if M.made[name] then return M.made[name] end
    local path = M.path(name)
    if not file.exists(path) then
        local t0 = core.now()
        pcall(file.mkdirs, M.DIR)
        seed = 12345 + #name * 7919
        local s, n = SYN[name]()
        local ok, err = pcall(write_wav, path, s, n)
        M.synth_ms[name] = (core.now() - t0) * 1000
        if not ok then
            core.log("sfx " .. name .. " write failed: " .. tostring(err))
            return nil
        end
        core.log(("sfx %s synthesized: %d samples %.2f s, %.1f ms -> %s"):format(name, n, n / M.RATE, M.synth_ms[name], path))
    else
        M.synth_ms[name] = 0
    end
    M.made[name] = path
    return path
end

function M.prepare_all()
    for _, name in ipairs({ "hum", "gulp", "tick", "bounce", "merge", "collapse" }) do M.load(name) end
end

-- WAV из кеша -> звук-ассет (audio.PCMStream -> create_sound). Почему не audio.play_stream(путь): в 0.32.1 динамик
-- потока с stopOnEnd = false не удаляется ни по концу трека, ни после audio.stop (audio::update, src/audio/audio.cpp) —
-- каждый play_stream навсегда занимает источник OpenAL, после 255 звук пропадает («limit is 255»). Динамики звуков-ассетов
-- (audio.play_sound) удаляются по окончании.
M.sounds = {}
function M.load(name)
    local v = M.sounds[name]
    if v ~= nil then return v end
    local path = M.ensure(name)
    local alias = ("bh_%s_v%d"):format(name, M.VERSION)
    local ok, err = pcall(function()
        local bytes = file.read_bytes(path)
        local pcm = bytes:slice(45)      -- данные после 44-байтового заголовка WAV
        local st = audio.PCMStream(M.RATE, 1, 16)
        st:feed(pcm)
        st:create_sound(alias)
    end)
    if not ok then
        core.log("sfx " .. name .. " load failed: " .. tostring(err))
        alias = false
    end
    M.sounds[name] = alias
    return alias
end

-- проиграть с позицией -> speaker id (0 — звук выключен/ошибка)
function M.play(name, pos, volume, pitch, loop)
    if not core.cfg.sound then return 0 end
    local alias = M.load(name)
    if not alias then return 0 end
    local ok, id = pcall(audio.play_sound, alias, pos[1], pos[2], pos[3],
        min(1, (volume or 1) * core.cfg.volume), pitch or 1, "regular", loop == true)
    if not ok then
        core.log("sfx play " .. name .. " failed: " .. tostring(id))
        return 0
    end
    core.stats.sfx = (core.stats.sfx or 0) + 1
    return id or 0
end

-- ограничение частоты «глотков» (не больше ~10 в секунду на всё)
local last_gulp = 0
function M.gulp(pos, mass)
    local t = time.uptime()
    if t - last_gulp < 0.1 then return 0 end
    last_gulp = t
    local p = (1.25 - 0.5 * core.mnorm(mass)) * (0.85 + math.random() * 0.3)
    return M.play("gulp", pos, 0.55, p)
end

return M
