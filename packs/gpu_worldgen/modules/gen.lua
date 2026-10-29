-- gpu_worldgen:gen — очередь чанков и конвейер «GPU -> Lua -> world.set_chunk_data».
-- Мир на стоковом генераторе пустоты gpu_worldgen:gpu (весь чанк — воздух); по on_chunk_present чанк встаёт в
-- очередь, раз в кадр (on_hud_render, scripts/hud.lua):
--   1. если пакет на GPU нарисован (эхо serial совпало) — читаем FBO фрейма одним glGetTexImage (gpu.read) и кладём
--      его плитки в список готовых;
--   2. готовые плитки разбираем (gpu.decode_tile), кодируем (codec.encode) и пишем world.set_chunk_data — в пределах
--      бюджета Lua на кадр (budget_ms; меньше — если fps ниже target_fps), остаток — в следующих кадрах;
--   3. когда готовых меньше пакета — отправляем следующий пакет ближайших к игроку чанков (gpu.submit, до max_tiles).
-- Бэкенд "cpu" — тот же путь, но коды блоков считает CPU-референс modules/noise.lua (для сравнения скорости).
-- Чанки, уже записанные в мир, помнятся в world:data/gpu_worldgen/done.txt (сохраняется с миром): сохранённый
-- движком «пустой» чанк, который не успели заполнить до выгрузки, при загрузке встаёт в очередь снова.
local noise = require "gpu_worldgen:noise"
local codec = require "gpu_worldgen:codec"
local gpu = require "gpu_worldgen:gpu"
local presets = require "gpu_worldgen:presets"

local M = {}

local now = time.precise_time or os.clock
M.clock = time.precise_time and "time.precise_time" or "os.clock (1 ms)"

M.cfg = {
    backend = "gpu",      -- "gpu" | "cpu"
    budget_ms = 6,        -- Lua-время на разбор/кодирование/запись за кадр
    target_fps = 50,      -- ниже — бюджет уменьшается (было 30; 50 держит >= 50 fps на пресетах, см. README)
    batch_max = nil,      -- плиток в пакете (nil — сколько влезает во фрейм)
    -- потолок прохода (13.10, gpu_cap): фрейм-вычислитель не больше frame_w x frame_h, окна и 2048 x 2048 (Frame::draw).
    -- Умолчание 768x432 не зависит от окна игрока (раньше nil = окно: при 4K-окне проход в ~12 раз больше, чем при
    -- 854x480, и GPU «взлетал» на генерации). Поднять — config:gpu_worldgen/settings.toml (pass_w, pass_h, fit) или
    -- опции launch.open/сценария (frame_w, frame_h). Числа и выбор умолчания — README «Потолок прохода».
    frame_w = 768, frame_h = 432,
    fit = true,           -- картинка прохода под пакет: считать только плитки пакета (modules/gpu.lua M.fit_batch)
    log_s = 2,            -- период строки stats
    hash = 3,             -- FNV extrle16 чанков (детерминизм): true — всех, число R — только квадрата [-R, R]^2
                          -- (хэши областей сценариев; остальным чанкам не платить ~0.05 мс), false — ни одного
    keep_codes = {},      -- ["x,z"] = true: сохранить коды GPU этих чанков для сверки с CPU (bench)
    place_player = true,  -- поставить игрока на поверхность спавна, когда чанк (0,0) готов
    over = nil,           -- перекрытие параметров шума (noise.DEFAULT)
    hud = true,           -- подсказка пресета в HUD (layouts/gw_hud.xml); сценарии кадров выключают
    rle = true,           -- поток extrle16 считает GPU (цепочка проходов, modules/gpu.lua «RLE на GPU»): Lua только
                          -- копирует байты, gzip и set_chunk_data
    rle_rows = 6,         -- строк кадра потока на плитку (ёмкость rle_rows * W * 3 байт; больше — запасной путь Lua)
    min_per_frame = 24,   -- pace "frame": потолок нижнего предела чанков за кадр. Сам предел — «подача движка»: EMA
                          -- числа чанков, пришедших по on_chunk_present за кадр (движок создаёт ~24 пустых за кадр при
                          -- load-speed 32, 1.3–1.95 мс на чанк), не выше этого значения. Без предела в полёте темп
                          -- опускался до 1 чанка за кадр, принимая падение fps от самого движка на свой счёт, и мир
                          -- впереди оставался пустым (13.10, gpu_worldgen_throughput: 1.0 ч/кадр при очереди 2500);
                          -- жёсткие 24 без привязки к подаче роняли fps новой зоны с 43 до 23 (ld 32)
    pace = "frame",       -- темп записи: "lua" — бюджет Lua-времени budget_ms (урезается при fps (EMA 1/dt) ниже
                          -- target_fps); "frame" — ещё и число чанков за кадр по EMA длительности кадра: ниже target_fps —
                          -- ×0.8, выше — +1 (цена чанка теперь в основном у движка: свет и меши после set_chunk_data);
                          -- "raw" — без темпа: всё, что отдал GPU, пишется в том же кадре (замер пропускной способности
                          -- прохода, tools/scenarios/gpu_worldgen_throughput.lua)
    rle_gzip = "stored",  -- gzip потока RLE: "stored" — без сжатия (stored-блок + CRC32 в Lua при копировании),
                          -- "deflate" — compression.encode движка (меньше байт, дороже: 0.06–0.18 мс/чанк)
    rle_verify = 0,       -- сверить байты потока GPU с Lua-кодером (коды генератора + деревья Lua) на N первых чанках
}

local function log(s) debug.log("[gpu_worldgen] " .. s) end
M.log = log

-- ключи cfg, заданные явно (launch.open / сценарий): файл настроек их не перекрывает
M.cfg_explicit = {}
M.CONFIG = "config:gpu_worldgen/settings.toml"
M.cfg_src = "default"
-- config:gpu_worldgen/settings.toml: pass_w, pass_h (потолок прохода), fit (true/false), pace
local function load_config()
    M.cfg_src = "default"
    if not file.exists(M.CONFIG) then return end
    local txt = file.read(M.CONFIG)
    local t
    if toml and toml.parse then
        local ok, r = pcall(toml.parse, txt)
        if ok then t = r end
    end
    if not t then
        t = {}
        for k, v in txt:gmatch("([%w_]+)%s*=%s*([^\r\n#]+)") do
            v = v:gsub("%s+$", ""):gsub('^"(.*)"$', "%1")
            t[k] = tonumber(v) or (v == "true" and true) or (v == "false" and false) or v
        end
    end
    local map = { pass_w = "frame_w", pass_h = "frame_h", fit = "fit", pace = "pace" }
    local used = {}
    for k, ck in pairs(map) do
        if t[k] ~= nil and not M.cfg_explicit[ck] then
            M.cfg[ck] = t[k]
            used[#used + 1] = k .. "=" .. tostring(t[k])
        end
    end
    if #used > 0 then M.cfg_src = M.CONFIG .. " (" .. table.concat(used, ", ") .. ")" end
end
M.load_config = load_config

-- чанков на кадр (13.10, gpu_cap): fc — текущий кадр (gen — плиток прочитано с GPU, wr — записано set_chunk_data);
-- M.cpf — запись по кадрам для сценариев (M.record_cpf), окно stats — свои массивы
local fc = { gen = 0, wr = 0 }
M.cpf = nil
function M.record_cpf(on) M.cpf = on and { gen = {}, wr = {}, q = {}, dt = {}, t = {} } or nil end
-- сводка массива: среднее, p95, максимум
local function summ(a, from, to)
    from, to = from or 1, to or #a
    local n = to - from + 1
    if n <= 0 then return { n = 0, mean = 0, p95 = 0, max = 0 } end
    local c, sum, mx = {}, 0, 0
    for i = from, to do
        local v = a[i]
        c[#c + 1] = v
        sum = sum + v
        if v > mx then mx = v end
    end
    table.sort(c)
    return { n = n, mean = sum / n, p95 = c[math.max(1, math.ceil(n * 0.95))], max = mx }
end
M.summ = summ
-- размер прохода и плиток за проход (HUD, лог)
M.pass_info = nil

local active = false
M.preset = nil       -- пресет мира (modules/presets.lua)
local pdesc          -- {id, words} для gpu.submit
local deco           -- деревья пресета: fn(cx, cz, ids) или nil
local epoch = 0      -- смена пресета в мире: пакеты/плитки старой эпохи отбрасываются
local present = {}   -- загруженные чанки (для перезаписи при смене пресета)
local spawn_wait = nil  -- пресеты: искать точку спавна, когда готов квадрат [-r, r]^2
local P              -- noise.make(...)
local idmap = {}     -- код -> id блока
local ids = {}       -- переиспользуемый массив id чанка
local queue, queued = {}, 0
local done, ndone = {}, 0
local hashes = {}
M.codes = {}         -- коды GPU для keep_codes
M.engine_hash = {}   -- FNV world.get_chunk_data сразу после set_chunk_data (keep_codes)
local ready = {}     -- готовые плитки: {data, tile, tilesX, x, z}
local ready_head = 1
local rlebuf, rlecap  -- поток extrle16 чанка из кадра E (RLE на GPU) и его ёмкость
M.verify = { n = 0, equal = 0, diff = 0, first = nil, fallback = 0, bytes = 0 }
local inited_gpu = false
local paused = false

local stats
local function reset_stats()
    stats = { t0 = now(), frames = 0, max_dt = 0, chunks = 0, read = 0, copy = 0, decode = 0, encode = 0, set = 0,
        batches = 0, waits = 0, last = nil, tiles = 0, f_gen = {}, f_wr = {} }
end
reset_stats()
M.total = { chunks = 0, decode = 0, encode = 0, set = 0, read = 0, copy = 0, batches = 0, cpu = 0, t_first = nil, t_last = nil }

local function key(x, z) return x .. "," .. z end
M.key = key

function M.is_active() return active end
-- запись длительностей кадров (с) — для фазы генерации в сценарии
M.rec = nil
function M.record(on) M.rec = on and {} or nil end
-- ничего не ждёт обработки: очередь пуста, нет пакета на GPU и готовых плиток
function M.idle() return queued == 0 and gpu.pending == nil and ready[ready_head] == nil end
function M.params() return P end
function M.preset_desc() return pdesc end
function M.done_count() return ndone end
function M.queue_count() return queued end
function M.is_done(x, z) return done[key(x, z)] ~= nil end
function M.hash_of(x, z) return hashes[key(x, z)] end
function M.pause(v) paused = v end
local hold = false
-- не отправлять новые пакеты на GPU (уже отправленный дочитывается) — перед замерами bench
function M.hold(v) hold = v end

local function done_file() return pack.data_file("gpu_worldgen", "done.txt") end

function M.open()
    -- модули переживают закрытие мира: состояние прошлого мира сбросить
    queue, queued, done, ndone, hashes = {}, 0, {}, 0, {}
    M.codes, M.engine_hash = {}, {}
    M.verify = { n = 0, equal = 0, diff = 0, first = nil, fallback = 0, bytes = 0 }
    ready, ready_head = {}, 1
    inited_gpu, paused, hold = false, false, false
    load_config()
    gpu.fit = M.cfg.fit ~= false
    M.pass_info = nil
    gpu.reset()
    reset_stats()
    M.total = { chunks = 0, decode = 0, encode = 0, set = 0, read = 0, copy = 0, batches = 0, cpu = 0, t_first = nil, t_last = nil }
    present = {}
    spawn_wait = nil
    M.preset = presets.by_generator(world.get_generator())
    active = M.preset ~= nil
    if not active then return end
    -- пресет, выбранный в мире (F6 / gpuwg.preset), перекрывает пресет генератора
    local pf = pack.data_file("gpu_worldgen", "preset.txt")
    if file.exists(pf) then
        local name = file.read(pf):match("([%w_]+)")
        if name and presets.get(name) then M.preset = presets.get(name) end
    end
    -- сверка кодов с CPU (keep_codes, bench.parity/density) идёт старым путём: разбор плитки в Lua
    if next(M.cfg.keep_codes) or M.cfg.backend == "cpu" then M.cfg.rle = false end
    P = noise.make(world.get_seed(), M.cfg.over)
    noise.use(P)
    M.apply_preset(M.preset)
    local f = done_file()
    if file.exists(f) then
        for x, z in file.read(f):gmatch("(-?%d+) (-?%d+)") do
            done[key(tonumber(x), tonumber(z))] = true
            ndone = ndone + 1
        end
    end
    if M.preset.id ~= 0 and ndone == 0 and M.cfg.place_player then spawn_wait = { r = 2, cx = 0, cz = 0 } end
    log(("open: seed %s -> %d, preset %s, backend %s, clock %s, done from save %d"):format(tostring(world.get_seed()),
        P.seed, M.preset.name, M.cfg.backend, M.clock, ndone))
end

-- пресет -> idmap, слова параметров, деревья (не трогает очередь)
function M.apply_preset(p)
    M.preset = p
    local m = presets.idmap(p)
    for code = 0, 15 do
        if m[code] > 255 then error("gpu_worldgen: block id > 255 for code " .. code) end
        idmap[code] = m[code]
    end
    pdesc = { id = p.id, words = presets.words(p), deco = p.deco, idmap_rle = presets.idmap_rle(p, idmap) }
    for code = 0, 15 do
        if pdesc.idmap_rle[code] > 255 then error("gpu_worldgen: block id > 255 for rle code " .. code) end
    end
    gpu.invalidate_luts()
    deco = presets.make_deco(p, idmap, P.seed)
    epoch = epoch + 1
end

-- смена пресета в открытом мире: все загруженные чанки — заново в очередь, игрок — на новую точку спавна
function M.set_preset(name)
    if not active then return false, "not a gpu_worldgen world" end
    local p = presets.get(name)
    if not p then return false, "unknown preset " .. tostring(name) end
    M.apply_preset(p)
    local f = pack.data_file("gpu_worldgen", "preset.txt")
    file.mkdirs(f:match("^(.*)/[^/]*$"))
    file.write(f, p.name)
    ready, ready_head = {}, 1
    gpu.pending = nil
    done, ndone, hashes = {}, 0, {}
    queue, queued = {}, 0
    for k, c in pairs(present) do
        queue[k] = { c[1], c[2] }
        queued = queued + 1
    end
    M.total = { chunks = 0, decode = 0, encode = 0, set = 0, read = 0, copy = 0, batches = 0, cpu = 0, t_first = nil, t_last = nil }
    if M.cfg.place_player then
        local px, _, pz = player.get_pos(0)
        player.set_flight(0, true)
        player.set_noclip(0, true)
        spawn_wait = { r = 2, cx = math.floor(px / 16), cz = math.floor(pz / 16) }
    end
    log(("preset -> %s (%s): %d chunks requeued"):format(p.name, p.title, queued))
    return true
end

-- все загруженные чанки — снова в очередь (тот же пресет; замер установившегося потока, сценарий витрины sustain_s)
function M.requeue_all()
    if not active then return 0 end
    local n = 0
    for k, c in pairs(present) do
        if not queue[k] then
            queue[k] = { c[1], c[2] }
            queued = queued + 1
            n = n + 1
        end
    end
    return n
end

function M.save()
    if not active then return end
    local parts = {}
    for k in pairs(done) do parts[#parts + 1] = k:gsub(",", " ") end
    local f = done_file()
    file.mkdirs(f:match("^(.*)/[^/]*$"))
    file.write(f, table.concat(parts, "\n"))
end

local supply_now, supply_ema = 0, 0   -- чанков от движка (on_chunk_present) за текущий кадр и EMA по кадрам
function M.chunk_present(x, z, loaded)
    if not active then return end
    supply_now = supply_now + 1
    local k = key(x, z)
    present[k] = { x, z }
    if done[k] then return end
    if not queue[k] then
        queue[k] = { x, z }
        queued = queued + 1
    end
end

function M.chunk_remove(x, z)
    if not active then return end
    local k = key(x, z)
    present[k] = nil
    if queue[k] then
        queue[k] = nil
        queued = queued - 1
    end
end

-- ближайшие к игроку чанки очереди (не больше n), удаляются из очереди
local function take(n)
    local px, _, pz = player.get_pos(0)
    local pcx, pcz = math.floor((px or 0) / 16), math.floor((pz or 0) / 16)
    local list = {}
    for k, c in pairs(queue) do
        local dx, dz = c[1] - pcx, c[2] - pcz
        list[#list + 1] = { c[1], c[2], dx * dx + dz * dz, k }
    end
    table.sort(list, function(a, b)
        if a[3] ~= b[3] then return a[3] < b[3] end
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end)
    local out = {}
    for i = 1, math.min(n, #list) do
        local c = list[i]
        queue[c[4]] = nil
        queued = queued - 1
        out[i] = { c[1], c[2] }
    end
    return out
end

local function surface_y(wx, wz)
    local water = idmap[5]
    for y = 255, 1, -1 do
        local id = block.get(wx, y, wz)
        if id ~= 0 and id ~= -1 and id ~= water then return y end
    end
    return 0
end
M.surface_y = surface_y

local function write_chunk(x, z, rle)
    local t0 = now()
    local hh = M.cfg.hash
    if type(hh) == "number" then hh = math.abs(x) <= hh and math.abs(z) <= hh end
    local payload, h
    if rle and rle.stored then
        payload = rle.buf
        h = hh and codec.fnv_range(payload, codec.STORED_OFF, rle.n) or nil
    elseif rle then payload, h = codec.encode_rle(rle, hh) else payload, h = codec.encode(ids, hh) end
    local t1 = now()
    local ok = world.set_chunk_data(x, z, payload)
    local t2 = now()
    stats.encode = stats.encode + (t1 - t0)
    stats.set = stats.set + (t2 - t1)
    M.total.encode = M.total.encode + (t1 - t0)
    M.total.set = M.total.set + (t2 - t1)
    if ok then
        local k = key(x, z)
        done[k] = true
        hashes[k] = h
        if M.cfg.keep_codes[k] then
            -- данные чанка, как их кодирует движок, сразу после записи (до случайных тиков блоков: дёрн под нависанием
            -- base:grass_block со временем становится землёй — get_chunk_data через секунды уже другой)
            local d = world.get_chunk_data(x, z)
            M.engine_hash[k] = d and codec.fnv(d)
        end
        ndone = ndone + 1
        fc.wr = fc.wr + 1
        stats.chunks = stats.chunks + 1
        M.total.chunks = M.total.chunks + 1
        M.total.t_first = M.total.t_first or t2
        M.total.t_last = t2
        M.total.bytes = (M.total.bytes or 0) + #payload
        M.total.rle = (M.total.rle or 0) + codec.last_rle
        if x == 0 and z == 0 and M.cfg.place_player and M.preset.id == 0 then
            local y = surface_y(8, 8)
            player.set_pos(0, 8.5, y + 2, 8.5)
            player.set_vel(0, 0, 0, 0)
            log(("spawn: surface y %d at (8, 8)"):format(y))
            if M.on_spawn then M.on_spawn(y) end
        end
    else
        -- чанк выгружен, пока считался: вернётся on_chunk_present и встанет в очередь
        fc.fail = (fc.fail or 0) + 1
        M.total.fail = (M.total.fail or 0) + 1
    end
    return ok
end

-- точка спавна пресета: «витринная» — вершина (mountains), зал пещеры (caves), верх самого высокого острова
-- (islands); взгляд — по направлению, где луч от глаз дольше всего идёт по воздуху
local function free_ray(x, y, z, dx, dy, dz, maxl)
    local l = 0
    while l < maxl do
        local id = block.get(math.floor(x + dx * (l + 1)), math.floor(y + dy * (l + 1)), math.floor(z + dz * (l + 1)))
        if id ~= 0 and id ~= idmap[14] and id ~= idmap[15] and id ~= -1 then break end
        l = l + 1
    end
    return l
end
M.free_ray = free_ray

-- взгляд: направление, где луч упирается в рельеф дальше всего, но не дальше maxl (в кадре горы/острова, а не пустое
-- небо); если таких нет — просто самый длинный луч
local function best_yaw(x, y, z, maxl, pitch, minl)
    local best, by = -1, 0
    local hit, hy = -1, nil
    local cp, sp = math.cos(math.rad(pitch or 0)), math.sin(math.rad(pitch or 0))
    for i = 0, 15 do
        local a = i * math.pi / 8
        local dx, dz = math.sin(a), math.cos(a)
        local l = free_ray(x, y, z, dx * cp, sp, dz * cp, maxl)
        local yaw = math.deg(math.atan2(-dx, -dz))
        if l > best then best, by = l, yaw end
        if l < maxl and l >= (minl or 0) and l > hit then hit, hy = l, yaw end
    end
    if hy then return hy, hit end
    return by, best
end
M.best_yaw = best_yaw

function M.find_spawn(cx, cz, r)
    local p = M.preset
    local x0, z0 = cx * 16 - r * 16 + 4, cz * 16 - r * 16 + 4
    local x1, z1 = cx * 16 + r * 16 + 11, cz * 16 + r * 16 + 11
    local bx, by, bz, score
    local water = idmap[5]
    local leaves, wood = block.index("base:leaves"), block.index("base:wood")
    if p.name == "caves" then
        -- зал: пол (твёрдое) + не меньше 3 блоков воздуха над ним, глубоко под поверхностью; балл — простор по
        -- горизонтали (2 лучших направления) + высота зала
        for x = x0, x1, 3 do
            for z = z0, z1, 3 do
                local s = surface_y(x, z)
                local y = s - 10
                while y > 12 do
                    local id = block.get(x, y, z)
                    if id == 0 and block.get(x, y + 1, z) == 0 and block.get(x, y + 2, z) == 0 then
                        local f = block.get(x, y - 1, z)
                        if f ~= 0 and f ~= water and f ~= idmap[9] and f ~= -1 then
                            local h = 0
                            while h < 24 and block.get(x, y + h, z) == 0 do h = h + 1 end
                            local l1, l2 = 0, 0
                            for i = 0, 7 do
                                local a = i * math.pi / 4
                                local l = free_ray(x + 0.5, y + 1.6, z + 0.5, math.sin(a), 0, math.cos(a), 40)
                                if l > l1 then l1, l2 = l, l1 elseif l > l2 then l2 = l end
                            end
                            local sc = l1 + l2 + h
                            if not score or sc > score then bx, by, bz, score = x, y, z, sc end
                        end
                    end
                    y = y - 1
                end
            end
        end
    end
    if not bx then
        -- самый высокий дёрн (уступ с видом на горы / верх острова); если дёрна нет — самая высокая поверхность
        for pass = 1, 2 do
            for x = x0, x1, 2 do
                for z = z0, z1, 2 do
                    local s = surface_y(x, z)
                    local id = block.get(x, s, z)
                    local okb = pass == 2 or id == idmap[3]
                    if s > 0 and okb and id ~= water and id ~= leaves and id ~= wood and (not score or s > score) then
                        bx, by, bz, score = x, s + 1, z, s
                    end
                end
            end
            if bx then break end
        end
    end
    if not bx then bx, by, bz = cx * 16 + 8, 200, cz * 16 + 8 end
    local pitch = p.name == "caves" and -4 or -8
    -- пещера: вдоль зала (самый длинный луч); снаружи: на рельеф/острова в 40..140 блоках
    local yaw, len
    if p.name == "caves" then
        yaw, len = best_yaw(bx + 0.5, by + 1.6, bz + 0.5, 48, pitch, 1e9)
    else
        yaw, len = best_yaw(bx + 0.5, by + 1.6, bz + 0.5, 140, pitch, 40)
    end
    return bx + 0.5, by, bz + 0.5, yaw, pitch, score, len
end

local function try_spawn()
    local w = spawn_wait
    -- поиск точки (тысячи block.get) — когда очередь пуста, чтобы не добавлять кадр-ступеньку в генерацию
    -- (но не дольше 3 с ожидания)
    w.t0 = w.t0 or now()
    if not M.idle() and now() - w.t0 < 3 then return end
    for x = w.cx - w.r, w.cx + w.r do
        for z = w.cz - w.r, w.cz + w.r do
            if not done[key(x, z)] then return end
        end
    end
    spawn_wait = nil
    local x, y, z, yaw, pitch, score, len = M.find_spawn(w.cx, w.cz, w.r)
    player.set_pos(0, x, y, z)
    player.set_vel(0, 0, 0, 0)
    player.set_rot(0, yaw, pitch, 0)
    player.set_spawnpoint(0, x, y, z)
    player.set_noclip(0, false)
    player.set_flight(0, false)
    log(("spawn %s: pos %.1f %d %.1f yaw %.0f pitch %.0f (score %s, view %d blocks)"):format(M.preset.name, x, y, z,
        yaw, pitch, tostring(score), len))
    if M.on_spawn then M.on_spawn(y) end
end

-- сверка потока GPU с Lua-кодером: коды генератора (кадр 1 цепочки) + деревья Lua -> codec.extrle16
local function rle_verify(r, n, buf)
    local b = r.batch
    gpu.decode_tile_fast(b.f1, r.tile, r.tilesX, idmap, ids)
    if deco then deco(r.x, r.z, ids) end
    local ref = codec.extrle16(ids)
    local V = M.verify
    V.n = V.n + 1
    V.bytes = V.bytes + ref.size
    local same = ref.size == n
    local first
    if same then
        local a = ref.bytes
        local c, o
        if buf.stored then c, o = buf.buf.bytes, codec.STORED_OFF else c, o = rlebuf.bytes, 0 end
        for i = 0, n - 1 do
            if a[i] ~= c[o + i] then same = false; first = i; break end
        end
    end
    if same then V.equal = V.equal + 1 else
        V.diff = V.diff + 1
        if not V.first then
            V.first = ("chunk %d,%d: lua %d B, gpu %d B, first diff at %s"):format(r.x, r.z, ref.size, n, tostring(first))
        end
    end
    if V.n == M.cfg.rle_verify then
        log(("rle verify: %d chunks, equal %d, diff %d, extrle16 bytes %d (lua == gpu byte for byte)%s"):format(V.n,
            V.equal, V.diff, V.bytes, V.first and ("; " .. V.first) or ""))
    end
end

-- после записи: данные чанка, как их снова кодирует движок (world.get_chunk_data: gzip(extrle16) его кодером), —
-- распаковать compression.decode и сравнить с потоком GPU: движок прочёл наш gzip (stored) в те же воксели
local function engine_check(x, z, buf, n)
    local V = M.verify
    local d = world.get_chunk_data(x, z)
    if not d then return end
    local p = d.bytes
    local len = p[2] + p[3] * 256 + p[4] * 65536 + p[5] * 16777216
    local raw = compression.decode(d:slice(7, len))
    local c, o
    if buf.stored then c, o = buf.buf.bytes, codec.STORED_OFF else c, o = rlebuf.bytes, 0 end
    local same = #raw == n
    if same then
        local a = raw.bytes
        for i = 0, n - 1 do
            if a[i] ~= c[o + i] then same = false; break end
        end
    end
    V.engine_n = (V.engine_n or 0) + 1
    if same then V.engine_equal = (V.engine_equal or 0) + 1 end
    if V.engine_n == M.cfg.rle_verify then
        log(("rle engine check: %d chunks, engine re-encoded extrle16 == gpu stream: %d"):format(V.engine_n, V.engine_equal or 0))
    end
end

-- плитка кадра E -> поток (копия RGB текселей, без цикла по вокселям); nil — не влез (запасной путь).
-- rle_gzip "stored": сразу в буфер set_chunk_data (gzip stored-блок), CRC32 таблицей в том же цикле
local stored_t = { stored = true }
local CRC = codec.CRC
local function rle_take(r)
    local n, off, cap = gpu.rle_tile(r.data, r.tile)
    if n <= 0 or n > cap then return nil end
    if M.cfg.rle_gzip == "stored" then
        local buf = codec.stored_begin(n)
        local dst, src = buf.bytes, r.data.bytes
        local o = off * 4
        local k = codec.STORED_OFF
        local crc = -1
        local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
        local full = math.floor(n / 3)
        for _ = 1, full do
            local a, b, c = src[o], src[o + 1], src[o + 2]
            dst[k] = a; dst[k + 1] = b; dst[k + 2] = c
            crc = bxor(CRC[band(bxor(crc, a), 255)], rshift(crc, 8))
            crc = bxor(CRC[band(bxor(crc, b), 255)], rshift(crc, 8))
            crc = bxor(CRC[band(bxor(crc, c), 255)], rshift(crc, 8))
            k = k + 3
            o = o + 4
        end
        for j = 0, n - full * 3 - 1 do
            local a = src[o + j]
            dst[k + j] = a
            crc = bxor(CRC[band(bxor(crc, a), 255)], rshift(crc, 8))
        end
        codec.stored_finish(buf, n, crc)
        stored_t.buf, stored_t.n = buf, n
        return stored_t, n
    end
    if not rlebuf or rlecap < cap then rlebuf = Bytearray(cap + 3); rlecap = cap end
    local dst, src = rlebuf.bytes, r.data.bytes
    local o = off * 4
    local k = 0
    for _ = 1, math.ceil(n / 3) do
        dst[k] = src[o]; dst[k + 1] = src[o + 1]; dst[k + 2] = src[o + 2]
        k = k + 3
        o = o + 4
    end
    rlebuf.size = n
    return rlebuf, n
end

local n_allow = 64   -- pace "frame": чанков за кадр
local function process_ready(budget_s)
    local t_start = now()
    local done_n = 0
    while ready[ready_head] do
        local r = ready[ready_head]
        ready[ready_head] = nil
        ready_head = ready_head + 1
        if r.rle then
            local t0 = now()
            local buf, n = rle_take(r)
            local t1 = now()
            stats.decode = stats.decode + (t1 - t0)
            M.total.decode = M.total.decode + (t1 - t0)
            if buf then
                local chk = M.verify.n < M.cfg.rle_verify and r.batch.f1
                if chk then rle_verify(r, n, buf) end
                local ok = write_chunk(r.x, r.z, buf)
                if chk and ok then engine_check(r.x, r.z, buf, n) end
                -- подписчик (gpu_worldgen_light: высоты столбцов для света в шейдерах мира)
                if ok and M.on_written then
                    gpu.hm_n = #r.batch.chunks
                    M.on_written(r.x, r.z, r.data, r.tile)
                end
            else
                -- поток не влез в кадр E: коды с деревьями (кадр 3 цепочки) -> Lua-кодер
                M.verify.fallback = M.verify.fallback + 1
                if r.batch.f3 then
                    gpu.decode_tile_fast(r.batch.f3, r.tile, r.tilesX, r.batch.idmap_rle, ids)
                    if write_chunk(r.x, r.z) and M.on_written then
                        gpu.hm_n = #r.batch.chunks
                        M.on_written(r.x, r.z, r.data, r.tile)
                    end
                else
                    queue[key(r.x, r.z)] = { r.x, r.z }
                    queued = queued + 1
                end
            end
            done_n = done_n + 1
            if now() - t_start >= budget_s or done_n >= n_allow then break end
            goto continue
        end
        local t0 = now()
        local k = key(r.x, r.z)
        local keep = M.cfg.keep_codes[k] and {} or nil
        gpu.decode_tile(r.data, r.tile, r.tilesX, idmap, ids, keep)
        if keep then M.codes[k] = keep end
        if deco then deco(r.x, r.z, ids) end
        local t1 = now()
        stats.decode = stats.decode + (t1 - t0)
        M.total.decode = M.total.decode + (t1 - t0)
        write_chunk(r.x, r.z)
        done_n = done_n + 1
        if now() - t_start >= budget_s or done_n >= n_allow then break end
        ::continue::
    end
end

local function ready_count()
    local n = 0
    local i = ready_head
    while ready[i] do n = n + 1; i = i + 1 end
    return n
end

local function gpu_frame(budget_s)
    if not inited_gpu then
        if M.cfg.rle then
            -- цепочка RLE: проба порядка фреймов идёт несколько кадров (из кеша — 3)
            if not gpu.rle_step(M.cfg.frame_w, M.cfg.frame_h, M.cfg.rle_rows) then return end
            local L = gpu.rle
            inited_gpu = true
            local vp = gui.get_viewport()
            M.pass_info = { w = L.W, h = math.max(L.H, L.EH), tiles = L.nt, cap_w = M.cfg.frame_w, cap_h = M.cfg.frame_h,
                win_w = vp[1], win_h = vp[2], fit = gpu.fit, src = M.cfg_src }
            log(("gpu rle chain %s: frames %dx%d (stream %dx%d, %d B per tile), %d chunk tiles per pass, order %s"):format(
                table.concat(L.ids, ","), L.W, L.H, L.W, L.EH, L.KR * L.W * 3, L.nt,
                L.info and (L.info.cached and "cached" or "probed") or "-"))
            log(("pass: %dx%d (tiles %dx%d = %d per pass), ceiling %sx%s, window %dx%d, fit %s, config %s"):format(
                L.W, M.pass_info.h, L.tilesX, L.tilesY, L.nt, tostring(M.cfg.frame_w), tostring(M.cfg.frame_h),
                vp[1], vp[2], tostring(gpu.fit), M.cfg_src))
        else
            local w, h, tiles = gpu.init(M.cfg.frame_w, M.cfg.frame_h)
            inited_gpu = true
            local vp = gui.get_viewport()
            M.pass_info = { w = w, h = h, tiles = tiles, cap_w = M.cfg.frame_w, cap_h = M.cfg.frame_h,
                win_w = vp[1], win_h = vp[2], fit = gpu.fit, src = M.cfg_src }
            log(("gpu frame %dx%d, %d chunk tiles per pass (tile %dx%d)"):format(w, h, tiles, gpu.TW, gpu.TH))
            log(("pass: %dx%d (%d tiles per pass), ceiling %sx%s, window %dx%d, fit %s, config %s"):format(w, h, tiles,
                tostring(M.cfg.frame_w), tostring(M.cfg.frame_h), vp[1], vp[2], tostring(gpu.fit), M.cfg_src))
        end
    end
    if gpu.pending and gpu.pending.mode == 0 then
        local data, pend, t_read, t_copy = gpu.read()
        if data then
            stats.read = stats.read + t_read
            stats.copy = stats.copy + t_copy
            stats.batches = stats.batches + 1
            stats.tiles = stats.tiles + #pend.chunks
            fc.gen = fc.gen + #pend.chunks
            M.total.read = M.total.read + t_read
            M.total.copy = M.total.copy + t_copy
            M.total.batches = M.total.batches + 1
            if pend.rle then
                -- запасной путь (поток не влез) и сверка читают кадры 3/1 цепочки сейчас: в следующем кадре их уже нет
                local over = false
                for i = 1, #pend.chunks do
                    local n, _, cap = gpu.rle_tile(data, i - 1)
                    if n <= 0 or n > cap then over = true end
                end
                if over then pend.f3 = gpu.rle_frame_data(3) end
                if M.verify.n < M.cfg.rle_verify then pend.f1 = gpu.rle_frame_data(1) end
                pend.idmap_rle = pdesc.idmap_rle
                gpu.rle_hide()
            end
            for i, c in ipairs(pend.chunks) do
                if pend.epoch == epoch then
                    ready[ready_head + ready_count()] = { data = data, tile = i - 1, tilesX = pend.tilesX, x = c[1], z = c[2],
                        rle = pend.rle, batch = pend }
                end
            end
        else
            stats.waits = stats.waits + 1
        end
    end
    process_ready(budget_s)
    -- следующий пакет — сразу, как GPU свободен и в разборе меньше одного пакета (GPU считает, пока Lua пишет чанки)
    if not hold and not gpu.pending and queued > 0 and ready_count() < gpu.max_tiles then
        local n = math.min(M.cfg.batch_max or gpu.max_tiles, gpu.max_tiles)
        local list = take(n)
        if #list > 0 then
            gpu.submit(list, P, 0, pdesc)
            gpu.pending.epoch = epoch
        end
    end
end

local cpu_codes = {}
local function cpu_frame(budget_s)
    local t_start = now()
    while queued > 0 do
        local list = take(1)
        local c = list[1]
        local t0 = now()
        noise.chunk_codes(c[1], c[2], cpu_codes)
        for i = 0, 65535 do ids[i] = idmap[cpu_codes[i]] end
        local t1 = now()
        stats.decode = stats.decode + (t1 - t0)
        M.total.cpu = M.total.cpu + (t1 - t0)
        M.total.decode = M.total.decode + (t1 - t0)
        write_chunk(c[1], c[2])
        if now() - t_start >= budget_s then break end
    end
end

local budget_s
local last_t, fps_ema, dt_ema
local rec_t
function M.frame()
    local t = now()
    -- длительности кадров пишутся и в чужом мире (сценарий меряет стоковый генератор тем же способом)
    if M.rec and rec_t then M.rec[#M.rec + 1] = t - rec_t end
    rec_t = t
    if not active or paused then
        last_t = nil
        return
    end
    if last_t then
        local dt = t - last_t
        stats.frames = stats.frames + 1
        if dt > stats.max_dt then stats.max_dt = dt end
        fps_ema = fps_ema and (fps_ema * 0.9 + (1 / dt) * 0.1) or 1 / dt
        dt_ema = dt_ema and (dt_ema * 0.8 + dt * 0.2) or dt
    end
    last_t = t
    budget_s = budget_s or M.cfg.budget_ms / 1000
    if M.cfg.pace == "raw" then
        budget_s = 1e9
        n_allow = 1e9
    elseif M.cfg.pace == "frame" then
        if n_allow > 64 then n_allow = 64 end
        budget_s = M.cfg.budget_ms / 1000
        supply_ema = supply_ema * 0.8 + supply_now * 0.2
        supply_now = 0
        local floor = math.min(M.cfg.min_per_frame or 1, math.ceil(supply_ema))
        if dt_ema and 1 / dt_ema < M.cfg.target_fps then
            n_allow = math.max(1, floor, math.floor(n_allow * 0.8))
        else
            n_allow = math.min(64, n_allow + 1)
        end
    elseif fps_ema and fps_ema < M.cfg.target_fps then
        budget_s = math.max(0.0005, budget_s * 0.8)
    else
        budget_s = math.min(M.cfg.budget_ms / 1000, budget_s + 0.00025)
    end
    fc.gen, fc.wr, fc.fail = 0, 0, 0
    if M.cfg.backend == "cpu" then cpu_frame(budget_s) else gpu_frame(budget_s) end
    stats.f_gen[#stats.f_gen + 1] = fc.gen
    stats.f_wr[#stats.f_wr + 1] = fc.wr
    M.last_frame = fc
    local R = M.cpf
    if R then
        local i = #R.gen + 1
        R.gen[i], R.wr[i], R.q[i], R.t[i] = fc.gen, fc.wr, queued, t
    end
    if spawn_wait then try_spawn() end
    local el = t - stats.t0
    if el >= M.cfg.log_s then
        local n = stats.chunks
        local per = function(v) return n > 0 and v / n * 1000 or 0 end
        log(("stats %s: %d chunks in %.2f s = %.1f ch/s, fps %.1f (worst frame %.1f ms), Lua ms/chunk: read %.3f copy %.3f decode %.3f encode %.3f set %.3f, batches %d, waits %d, queue %d, ready %d, done %d, mem %.1f MB")
            :format(M.cfg.backend, n, el, n / el, stats.frames / el, stats.max_dt * 1000, per(stats.read), per(stats.copy),
                per(stats.decode), per(stats.encode), per(stats.set), stats.batches, stats.waits, queued, ready_count(), ndone,
                collectgarbage("count") / 1024))
        local g, w = summ(stats.f_gen), summ(stats.f_wr)
        M.last_cpf = { gen = g, wr = w, tiles_per_pass = stats.batches > 0 and stats.tiles / stats.batches or 0 }
        log(("per frame %s: gpu tiles avg %.2f p95 %d max %d, written avg %.2f p95 %d max %d, tiles per pass %.1f (pass %s, %s tiles), pace %s")
            :format(M.cfg.backend, g.mean, g.p95, g.max, w.mean, w.p95, w.max, M.last_cpf.tiles_per_pass,
                M.pass_info and (M.pass_info.w .. "x" .. M.pass_info.h) or "-", M.pass_info and M.pass_info.tiles or "-",
                M.cfg.pace))
        reset_stats()
        stats.t0 = t
    end
end

-- комбинированный хэш чанков квадрата [x0..x1]x[z0..z1] (nil, если какой-то не готов)
function M.area_hash(x0, z0, x1, z1)
    local h = 0
    for x = x0, x1 do
        for z = z0, z1 do
            local v = hashes[key(x, z)]
            if not v then return nil end
            h = bit.tobit(bit.bxor(h, v) * 31 + x * 7 + z)
        end
    end
    return h
end

return M
