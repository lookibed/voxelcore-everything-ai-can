-- blackhole:core — общее состояние пака: настройки, реестр дыр и обломков, формулы масса -> радиусы, статистика.
-- Подключается компонентами (hole, grenade, ejecta), world.lua, hud.lua и сценариями (`require "blackhole:core"`).
local M = {}

M.INSTANCE = math.random(1, 2 ^ 30)
M.CONFIG = "config:blackhole/settings.toml"

-- настройки по умолчанию (config:blackhole/settings.toml перекрывает, файл создаётся при первом входе в мир)
M.DEFAULTS = {
    power = 1.0,            -- множитель силы притяжения и темпа поедания блоков
    max_debris = 160,       -- обломков-сущностей одновременно (все дыры вместе)
    budget_ms = 3.0,        -- бюджет мс на такт логики поедания блоков (делится между дырами)
    max_holes_shader = 8,   -- сколько ближайших дыр видит пост-эффект (1..8)
    sound = true,           -- процедурный звук
    volume = 1.0,           -- общая громкость звуков пака
    lifetime = 90,          -- секунд жизни дыры массы ~1 (дальше растёт с массой, см. M.lifetime)
    lifetime_mass_scale = 500, -- L(m) = lifetime * (1 + ln(1 + m / lifetime_mass_scale))
    max_mass = 50000,       -- масса коллапса (0 — без предела)
    max_radius = 32,        -- потолок радиуса всасывания, блоков (сверхмассивные)
    max_rate = 1500,        -- потолок темпа поедания, блоков/с
    erase_path = "auto",    -- стирание блоков: auto | set | fragment
    fast_debris = 12,       -- обломков-визуала на кольцо при стирании фрагментом
    hole_gravity = 0.15,    -- G притяжения дыра <-> дыра: a = 2 G m / d^2 (потолок 30), в радиусе 2 R(m) притягивающей
    damping = 0.6,          -- затухание скорости дыры массы ~0, 1/с
    damping_mass = 100,     -- c(m) = damping / (1 + m / damping_mass)
    eject_fraction = 0.35,  -- доля съеденных блоков, выбрасываемых при коллапсе
    max_eject = 96,         -- потолок выброшенных блоков
    particles = true,       -- искры gfx.particles
    pull_players = true,    -- тянуть игрока
    stats_log = true,       -- строка статистики в лог раз в 5 с
}
local ORDER = { "settings_version", "power", "max_debris", "budget_ms", "max_holes_shader", "sound", "volume",
    "lifetime", "lifetime_mass_scale", "max_mass", "max_radius", "max_rate", "erase_path", "fast_debris", "hole_gravity",
    "damping", "damping_mass", "eject_fraction", "max_eject", "particles", "pull_players", "stats_log" }
M.DEFAULTS.settings_version = 2
-- умолчания первой версии файла: значения, совпадающие с ними, при обновлении файла заменяются новыми умолчаниями
local DEFAULTS_V1 = { max_mass = 2500 }

M.cfg = {}
for k, v in pairs(M.DEFAULTS) do M.cfg[k] = v end

M.time_scale = 1    -- множитель времени дыр (0 — заморозка; для кадров сценария на середине слияния)
M.holes = {}        -- uid -> state дыры (scripts/components/hole.lua)
M.debris = {}       -- uid обломка -> uid дыры-владельца
M.ndebris = 0
M.flashes = {}      -- вспышки коллапса для пост-эффекта: {pos, t0, dur, power}
M.ejecta = {}       -- uid схлопнувшейся дыры -> {n, landed, placed, t0}
M.collapse_zones = {} -- {pos, r, t0, sand}: воронки недавних коллапсов (scripts/world.lua, падающий песок)
M.stats = { logic_s = 0, sfx = 0, frames = 0, frame_s = 0, blocks = 0, absorbed = 0, merges = 0, collapses = 0,
    shader_n = 0, slot_active = false, t_last = 0, logic_last = 0, frames_last = 0, frame_s_last = 0, blocks_last = 0 }

local now = time.precise_time or time.uptime
M.now = now

function M.log(s)
    debug.log("[blackhole] " .. s)
end

-- ---------------------------------------------------------------- настройки
local function parse_toml(txt)
    if toml and toml.parse then
        local ok, r = pcall(toml.parse, txt)
        if ok and type(r) == "table" then return r end
    end
    local r = {}
    for k, v in txt:gmatch("([%w_]+)%s*=%s*([^\r\n#]+)") do
        v = v:gsub("%s+$", "")
        if v == "true" then r[k] = true
        elseif v == "false" then r[k] = false
        else r[k] = tonumber(v) or v:gsub('^"(.*)"$', "%1") end
    end
    return r
end

local function write_settings(f)
    local lines = { "# blackhole: настройки пака (читаются при входе в мир), описание — README пака" }
    for _, k in ipairs(ORDER) do
        local v = M.cfg[k]
        lines[#lines + 1] = ("%s = %s"):format(k, type(v) == "string" and ('"' .. v .. '"') or tostring(v))
    end
    pcall(file.mkdirs, "config:blackhole")
    pcall(file.write, f, table.concat(lines, "\n") .. "\n")
end

function M.load_settings()
    local f = M.CONFIG
    local how = "defaults (written " .. f .. ")"
    for k, v in pairs(M.DEFAULTS) do M.cfg[k] = v end
    if file.exists(f) then
        local ok, t = pcall(function() return parse_toml(file.read(f)) end)
        if ok and t then
            local old = (tonumber(t.settings_version) or 1) < M.DEFAULTS.settings_version
            for k, v in pairs(t) do
                if M.DEFAULTS[k] ~= nil and type(v) == type(M.DEFAULTS[k]) and k ~= "settings_version" then
                    if not (old and DEFAULTS_V1[k] ~= nil and v == DEFAULTS_V1[k]) then M.cfg[k] = v end
                end
            end
            how = "from " .. f
            if old then
                write_settings(f)
                how = how .. " (upgraded to v" .. M.DEFAULTS.settings_version .. ")"
            end
        end
    else
        write_settings(f)
    end
    local c = M.cfg
    c.max_holes_shader = math.max(1, math.min(8, math.floor(c.max_holes_shader)))
    c.max_debris = math.max(0, math.floor(c.max_debris))
    c.max_radius = math.max(2, math.min(64, c.max_radius))
    local parts = {}
    for _, k in ipairs(ORDER) do parts[#parts + 1] = k .. "=" .. tostring(c[k]) end
    M.log(("settings %s: %s"):format(how, table.concat(parts, " ")))
end

-- ---------------------------------------------------------------- формулы
-- радиус всасывания блоков: R = 2 + 8 * cbrt((m - 1) / 1500), потолок max_radius (32). Кубический корень: съеденный
-- объём ~ R^3 ~ масса, т.е. радиус воронки растёт так, как растёт шар из съеденного (10 при m = 1500, 18 при 12000,
-- 32 при ~ 79000)
function M.suck_radius(m)
    return math.min(M.cfg.max_radius, 2 + 8 * (math.max(0, m - 1) / 1500) ^ (1 / 3))
end
-- время самосхлопывания: чем массивнее, тем дольше живёт (90 с при m ~ 1, 215 с при 1500, 345 с при 8000)
function M.lifetime(m)
    return M.cfg.lifetime * (1 + math.log(1 + math.max(0, m) / M.cfg.lifetime_mass_scale))
end
-- затухание скорости дыры, 1/с: падает с массой
function M.damping(m)
    return M.cfg.damping / (1 + m / M.cfg.damping_mass)
end
-- радиус горизонта (чёрная сфера и тень в пост-эффекте), блоков
function M.horizon(m)
    return 0.6 + 0.17 * M.suck_radius(m)
end
-- радиус, в котором тянутся сущности и игрок
function M.pull_radius(m)
    return M.suck_radius(m) * 1.8 + 4
end
-- темп поедания, блоков в секунду
function M.eat_rate(m)
    return math.min(M.cfg.max_rate, 14 + 0.1 * m) * M.cfg.power
end
-- сила притяжения (ускорение, блоков/с^2) на расстоянии d: ~ M / d^2, с потолком
function M.accel(m, d, k, cap)
    return math.min(cap, M.cfg.power * k * (1 + m / 150) / math.max(d, 0.7) ^ 2)
end
-- векторное произведение (vec3.cross в 0.32 нет)
function M.cross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
-- 0..1: нормированная масса (для звука и силы эффекта)
function M.mnorm(m)
    return math.min(1, math.sqrt(math.max(0, m - 1) / 1500))
end
-- 0..1 по радиусу (для сверхмассивных: 1 при max_radius)
function M.rnorm(m)
    return (M.suck_radius(m) - 2) / math.max(1, M.cfg.max_radius - 2)
end

-- ---------------------------------------------------------------- кольца (оболочки) шара по расстоянию
-- Оболочка k — клетки с floor(|d|) == k, внутри отсортированы по расстоянию (при равенстве — сначала нижние: воронка).
-- Строятся лениво (O(k^2) на оболочку), кешируются. Дыра идёт по оболочкам изнутри наружу.
M.shells = {}
function M.shell(k)
    local sh = M.shells[k]
    if sh then return sh end
    local t0 = now()
    local list = {}
    local lo2, hi2 = k * k, (k + 1) * (k + 1)
    for dx = -k - 1, k + 1 do
        for dy = -k - 1, k + 1 do
            local r2 = dx * dx + dy * dy
            if r2 < hi2 then
                for dz = -k - 1, k + 1 do
                    local d2 = r2 + dz * dz
                    if d2 >= lo2 and d2 < hi2 then list[#list + 1] = { dx, dy, dz, d2 + dy * 0.01 } end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a[4] < b[4] end)
    local X, Y, Z, D = {}, {}, {}, {}
    for i, e in ipairs(list) do X[i], Y[i], Z[i], D[i] = e[1], e[2], e[3], math.sqrt(math.max(0, e[4])) end
    sh = { k = k, n = #list, X = X, Y = Y, Z = Z, D = D, ms = (now() - t0) * 1000 }
    M.shells[k] = sh
    return sh
end

-- фрагмент-«стёрка» оболочки k: blackhole:void в клетках оболочки, воздух (= пропуск при place) в остальных.
-- VoxelFragment:place (src/world/generator/VoxelFragment.cpp) ставит только ненулевые id, поэтому стирать воздухом
-- нельзя — ставится свой невидимый проходимый заменяемый блок blackhole:void (блок «как воздух»).
M.fragments = {}
function M.shell_fragment(k)
    local fr = M.fragments[k]
    if fr then return fr end
    local t0 = now()
    local S = 2 * k + 3
    local sh = M.shell(k)
    local mark = {}
    for i = 1, sh.n do
        mark[((sh.Y[i] + k + 1) * S + (sh.Z[i] + k + 1)) * S + (sh.X[i] + k + 1) + 1] = true
    end
    local vox = {}
    local n = S * S * S
    for i = 1, n do
        local j = i * 2
        vox[j - 1] = mark[i] and 1 or 0
        vox[j] = 0
    end
    local bytes = bjson.tobytes({ version = 1, size = { S, S, S }, voxels = vox,
        ["block-names"] = { "core:air", "blackhole:void" } })
    local frag = generation.load_fragment(bytes)
    fr = { frag = frag, k = k, size = S, cells = sh.n, ms = (now() - t0) * 1000, bytes = #bytes }
    M.fragments[k] = fr
    M.log(("fragment shell %d built: %d cells in %d^3, %d bytes bjson, %.1f ms"):format(k, sh.n, S, fr.bytes, fr.ms))
    return fr
end

-- замер стирания одного кольца k вокруг c двумя путями (без обломков): path "set" — block.get + block.set(0) по
-- съедобным клеткам; "fragment" — block.get-скан (счёт и список несъедобных) + place фрагмента-стёрки + возврат
-- несъедобных. Сборка фрагмента (разово на радиус) — отдельно, в build_ms.
-- -> ms всего, блоков, build_ms, scan_ms (block.get + отбор), write_ms (block.set / place + возврат)
function M.bench_ring(c, k, path)
    local cx, cy, cz = math.floor(c[1]), math.floor(c[2]), math.floor(c[3])
    local sh = M.shell(k)
    local build_ms = 0
    if path == "fragment" then
        local had = M.fragments[k]
        local fr = M.shell_fragment(k)
        build_ms = had and 0 or fr.ms
    end
    local t0 = now()
    local n = 0
    local cells = {}
    local restore = {}
    for i = 1, sh.n do
        local x, y, z = cx + sh.X[i], cy + sh.Y[i], cz + sh.Z[i]
        local id = block.get(x, y, z)
        if id > 0 then
            if M.edible(id) then
                n = n + 1
                if path == "set" then cells[#cells + 1] = { x, y, z } end
            elseif path ~= "set" and id ~= M.void_id then
                restore[#restore + 1] = { x, y, z, id, block.get_states(x, y, z) }
            end
        end
    end
    local t1 = now()
    if path == "set" then
        for i = 1, #cells do
            local p = cells[i]
            block.set(p[1], p[2], p[3], 0, 0)
        end
    else
        M.fragments[k].frag:place({ cx - k - 1, cy - k - 1, cz - k - 1 }, 0)
        for _, r in ipairs(restore) do block.set(r[1], r[2], r[3], r[4], r[5]) end
    end
    local t2 = now()
    return (t2 - t0) * 1000, n, build_ms, (t1 - t0) * 1000, (t2 - t1) * 1000
end

-- ---------------------------------------------------------------- блоки
local edible_cache = {}
function M.edible(id)
    if id <= 0 then return false end
    local v = edible_cache[id]
    if v ~= nil then return v end
    local name = block.name(id)
    v = true
    if name == "core:air" or name == "core:obstacle" or name == "base:bazalt" or name == "blackhole:void"
        or name:find("water") then v = false end
    if v and block.has_tag and block.has_tag(id, "core:liquid") then v = false end
    if v and block.is_extended and block.is_extended(id) then v = false end
    if v and block.properties then
        local p = block.properties[id]
        if p and (p.breakable == false or p["base:durability"] and p["base:durability"] >= 1e8) then v = false end
    end
    edible_cache[id] = v
    return v
end

-- одеть сущность со скелетом-кубом (модель "block") в текстуры блока, с осями его поворота (как base:falling_block)
function M.dress(ent, id, states)
    local rig = ent.skeleton
    local tex = block.get_textures(id)
    for i = 1, 6 do
        local t = tex[i] or tex[#tex]
        if t then rig:set_texture("$" .. (i - 1), "blocks:" .. t) end
    end
    local rot = block.decompose_state(states or 0)[1]
    local ax = { block.get_X(id, rot) }
    local ay = { block.get_Y(id, rot) }
    local az = { block.get_Z(id, rot) }
    rig:set_matrix(0, {
        ax[1], ax[2], ax[3], 0,
        ay[1], ay[2], ay[3], 0,
        az[1], az[2], az[3], 0,
        0, 0, 0, 1
    })
end

-- ---------------------------------------------------------------- обломки
function M.add_debris(uid, owner)
    if M.debris[uid] == nil then M.ndebris = M.ndebris + 1 end
    M.debris[uid] = owner
end
function M.drop_debris(uid)
    if M.debris[uid] ~= nil then
        M.debris[uid] = nil
        M.ndebris = M.ndebris - 1
    end
end
function M.debris_free()
    return M.cfg.max_debris - M.ndebris
end

-- ---------------------------------------------------------------- выброс при коллапсе
function M.ejecta_start(src, n)
    M.ejecta[src] = { n = n, landed = 0, placed = 0, t0 = time.uptime() }
end
function M.ejecta_sound(src)
    local e = M.ejecta[src]
    if not e then return false end
    e.sounds = (e.sounds or 0) + 1
    return e.sounds <= 24
end
function M.ejecta_landed(src, placed)
    local e = M.ejecta[src]
    if not e then return end
    e.landed = e.landed + 1
    if placed then e.placed = e.placed + 1 end
    if e.landed >= e.n then
        M.log(("collapse %d returned blocks: placed %d of %d ejected (dropped %d) in %.1f s, speakers now %d"):format(src,
            e.placed, e.n, e.n - e.placed, time.uptime() - e.t0, audio.count_speakers and audio.count_speakers() or -1))
        M.ejecta[src] = nil
    end
end

-- ---------------------------------------------------------------- вспышки
function M.flash(pos, power, dur)
    M.flashes[#M.flashes + 1] = { pos = { pos[1], pos[2], pos[3] }, t0 = time.uptime(), dur = dur or 0.9, power = power or 1 }
end

-- ---------------------------------------------------------------- статистика (кадр — из hud.lua)
function M.frame(dt)
    local s = M.stats
    s.frames = s.frames + 1
    s.frame_s = s.frame_s + dt
    local t = time.uptime()
    if s.t_last == 0 then s.t_last = t end
    if M.cfg.stats_log and t - s.t_last >= 5 then
        local nf = s.frames - s.frames_last
        local fs = s.frame_s - s.frame_s_last
        local nh = 0
        for _ in pairs(M.holes) do nh = nh + 1 end
        local spk = (audio and audio.count_speakers) and audio.count_speakers() or -1
        M.log(("stats holes %d debris %d shader %d active %s speakers %d sfx %d: %.1f fps, logic %.3f ms/frame, blocks %.1f/s"):format(
            nh, M.ndebris, s.shader_n, tostring(s.slot_active), spk, s.sfx or 0, fs > 0 and nf / fs or 0,
            nf > 0 and (s.logic_s - s.logic_last) * 1000 / nf or 0, (s.blocks - s.blocks_last) / (t - s.t_last)))
        s.t_last, s.frames_last, s.frame_s_last, s.logic_last, s.blocks_last = t, s.frames, s.frame_s, s.logic_s, s.blocks
    end
end

-- новый мир: модуль живёт дольше мира (package.loaded), реестры прошлого мира не должны попасть в пост-эффект
function M.reset()
    M.holes, M.debris, M.flashes, M.ejecta, M.collapse_zones = {}, {}, {}, {}, {}
    M.ndebris = 0
    for k in pairs(M.stats) do M.stats[k] = (type(M.stats[k]) == "boolean") and false or 0 end
    M.fx_last = nil
end

function M.count_holes()
    local n = 0
    for _ in pairs(M.holes) do n = n + 1 end
    return n
end

return M
