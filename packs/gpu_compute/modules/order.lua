-- gpu_compute:order — порядок отрисовки фреймов GUI (= порядок проходов в кадре).
-- Движок рисует все фреймы gui.create_frame каждый кадр в порядке обхода своей хеш-таблицы (не по имени и не по
-- созданию; стабилен между кадрами и запусками, одинаков на 0.31/0.32 — SMOLLM_GPU.md). Фрейм, читающий текстуру
-- фрейма, нарисованного раньше в этом кадре, видит новую версию, иначе — прошлого кадра. Цепочке зависимых проходов
-- нужен этот порядок: проба (раунд R: фрейм R копирует «часы», остальные — фрейм R; после R видят новое значение) за
-- 2 кадра на фрейм, проверка цепочкой INC (конец = часы + N за один кадр), кеш config:gpu_compute_order.json.
-- Служебная программа core (shaders/gpu_core.glsl): #FD01FF80 COPY, #FD02FF80 INC.
local M = {}
local now = time.precise_time or os.clock
local CACHE = "config:gpu_compute_order.json"
local COPY, INC = "#FD01FF80", "#FD02FF80"
local function rgb24(v) return v % 16777216 end
local function log(s) debug.log("[gpu_compute] " .. s) end

local clock
local function set_clock(v)
    clock:set(0, 0, v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, 255)
    clock:update()
end
local function px(fid) return rgb24(assets.to_canvas(fid):at(0, 0)) end

local function load_cache()
    if not file.isfile(CACHE) then return {} end
    local ok, t = pcall(json.parse, file.read(CACHE))
    return ok and type(t) == "table" and t or {}
end

-- frames: { [fid] = {root=, doc=} } уже созданные 1x1 фреймы с картинкой id="gc_o"; ids — список fid
local function verify(frames, ids, ticks)
    for i, fid in ipairs(ids) do
        local d = frames[fid].doc.gc_o
        d.src = i == 1 and "gc_clock" or ids[i - 1]
        d.color = { 253, 2, 255, 128 }
    end
    ticks(2)
    set_clock(4000000)
    ticks(1)
    local v = px(ids[#ids])
    return v == 4000000 + #ids, v
end

-- Создать n фреймов prefix%03d (1x1) и узнать их порядок. opts.ticks(n) — ждать n кадров (app.tick в сценарии/странице).
-- Возвращает упорядоченный список id, таблицу фреймов {root, doc} и сведения {cached, seconds, verify}.
function M.probe(prefix, n, opts)
    opts = opts or {}
    local ticks = opts.ticks or error("gpu_compute order.probe: opts.ticks(n) required (app.tick)")
    local t0 = now()
    if not clock then
        clock = Canvas({ 1, 1 })
        clock:set(0, 0, 0, 0, 0, 255)
        clock:create_texture("gc_clock")
    end
    local frames, ids = {}, {}
    for i = 1, n do
        ids[i] = ("%s%03d"):format(prefix, i - 1)
        local root, doc = gui.create_frame(ids[i], ids[i], { 1, 1 })
        root:clear()
        root:add('<image id="gc_o" src="gc_clock" pos="0,0" size="1,1" color="' .. COPY .. '"/>')
        frames[ids[i]] = { root = root, doc = doc }
    end
    ticks(2)
    local key = prefix .. "/" .. n
    local cache = load_cache()
    local order, info = nil, { cached = false }
    local list = cache[key]
    if type(list) == "table" and #list == n then
        local ok, v = verify(frames, list, ticks)
        log(("order %s: cached %d ids, verify %s (end %d)"):format(key, n, tostring(ok), v))
        if ok then order = list; info.cached = true end
    end
    if not order then
        for i = 1, n do frames[ids[i]].doc.gc_o.color = { 253, 1, 255, 128 } end
        local before = {}
        for i = 1, n do before[i] = 0 end
        local c = 100
        for r = 1, n do
            for i = 1, n do frames[ids[i]].doc.gc_o.src = (i == r) and "gc_clock" or ids[r] end
            c = c + 2
            set_clock(c - 1)
            ticks(1)
            set_clock(c)
            ticks(1)
            for i = 1, n do
                if i ~= r and px(ids[i]) == c then before[i] = before[i] + 1 end
            end
        end
        local idx = {}
        for i = 1, n do idx[i] = i end
        table.sort(idx, function(a, b) return before[a] < before[b] end)
        order = {}
        local consistent = true
        for k = 1, n do
            order[k] = ids[idx[k]]
            if before[idx[k]] ~= k - 1 then consistent = false end
        end
        local ok, v = verify(frames, order, ticks)
        log(("order %s: discovered %d frames in %.1f s, consistent %s, verify chain %s (end %d)"):format(
            key, n, now() - t0, tostring(consistent), tostring(ok), v))
        if not ok then error("gpu_compute: frame order verification failed (" .. key .. ")") end
        cache = load_cache()
        cache[key] = order
        pcall(file.write, CACHE, json.tostring(cache))
    end
    info.seconds = now() - t0
    for _, fid in ipairs(order) do frames[fid].root:clear() end
    return order, frames, info
end

-- проверка уже назначенного порядка без изменения фреймов невозможна (проба переписывает картинки), поэтому
-- после появления новых фреймов (rehash таблицы движка) клиент вызывает probe заново: из кеша это 3 кадра.
return M
