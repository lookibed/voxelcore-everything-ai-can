-- Растеризация треугольников на GPU для программ, которые рисуют как OpenGL (TeaVM-порты,
-- эмуляция GL на стороне wasm): программа присылает треугольники в экранных координатах и
-- текстуры, хост кладёт всё в одну текстуру canvas, а фрагментный шейдер UI пака wasmrt
-- (ui.glslf, режим по цвету-маркеру #FF01FF80) для каждого пикселя проходит треугольники
-- своего тайла по порядку: текстура, цвет вершин, альфа-тест, глубина, смешивание.
--
-- Раскладка текстуры (ширина W = 2048, слово = тексель RGBA8 = u32 little-endian; строка 0
-- текстуры в шейдере — внизу экрана, но шейдер адресует тексели texelFetch по номеру строки):
--   строки 0 .. ATLAS_H-1 — атлас текстур программы (упаковка по свободным прямоугольникам);
--   строка ATLAS_H — заголовок:
--     [0] число треугольников, [1] размер экрана (w | h << 16), [2] цвет очистки RGBA,
--     [3] значение очистки глубины (0..65535),
--     [4] биннинг: log2 стороны тайла (биты 0-7; 0 — биннинга нет, полный перебор) |
--         тайлов по x << 8 (12 бит) | тайлов по y << 20 (12 бит),
--     [5] режим отладки (tris_verify: 1 — сверка биннинга, 2 — коэффициент тумана серым), [6] строка треугольников | строка таблицы тайлов << 16,
--     [7] первая строка индексов | строка наборов тумана << 16,
--     [8 + 2k], [9 + 2k] — прямоугольник слота текстуры k (x | y << 16, w | h << 16);
--   строки TRI_ROW0 .. — треугольники по TRI_TEXELS текселей (формат — VcGL.java):
--     на вершину [x, y в 1/16 пикселя], [u, v: (uv + 8) * 4096], [RGBA], [1/w float]; затем
--     [слот текстуры | флаги << 16 | порог альфы << 24],
--     [смешивание (биты 0-7) | функция глубины << 8 | запись глубины << 12 | цвет не пишется << 13],
--     [z0 | z1 << 16], [z2]; смешивание: 0 нет, 1 alpha, 2 add, 3 mul, 4 invert, 5 mul2,
--     6 darken, 7 glint (формулы — ui.glslf); флаг 128 CLEAR_DEPTH — очистка глубины значением z0;
--     флаг 8 FOG — туман по набору номер (слово 13 >> 14) & 255 (биты 14-21);
--     флаг 16 LINEAR — билинейная выборка текстуры, флаг 32 CLAMP — координаты зажимаются к краю
--     (иначе ближайший тексель и повтор; выборка — внутри прямоугольника слота атласа);
--     флаг 64 SNAPSHOT — не треугольник, а снимок экрана в текстуру (glCopyTexSubImage2D):
--     [0] id текстуры, [1] x | y << 16 (левый верхний угол, пиксели, y вниз), [2] w | h << 16,
--     [3] смещение в текстуре x | y << 16. Записи до снимка в пределах прямоугольника рисуются
--     на CPU (modules/gfx_snap.lua, те же формулы, что ui.glslf), результат — в слот текстуры;
--     в списки тайлов снимок не попадает, шейдер его пропускает;
--   строка TILE_ROW — таблица тайлов: слово t = начало списка тайла t (номер элемента),
--     слово ntiles = общее число элементов; список тайла t — элементы [start[t], start[t+1]);
--     тайл t = ty * tiles_x + tx, tx = floor(x / (16 * сторона)) по координатам в 1/16 пикселя
--     (экран программы, y вниз — так же, как у вершин);
--   строки IDX_ROW0 .. — элементы списков: номера треугольников u16, по два на тексель
--     (элемент 2n — младшие 16 бит слова n, 2n+1 — старшие);
--   строки FOG_ROW .. FOG_ROW + 1 — наборы тумана (fog, импорт eag_fog перед кадром): набор k —
--     FOG_TEXELS слов с тексела k * FOG_TEXELS: [0] цвет тумана RGBA8, [1] режим (1 — линейный,
--     иначе exp), [2] начало, [3] конец - начало, [4] плотность, [5..7] Ax Bx Cx, [8..10] Ay By Cy,
--     [11..13] Az Cz Dz, [14] Ex, [15] Ey (слова 1-15 — float). Позиция в пространстве камеры
--     пикселя (px, py в пикселях экрана программы, y вниз; wc = 1 / интерполированное 1/w;
--     d — глубина окна 0..1): ze = wc*Az + Cz + d*Dz, xe = wc*(px*Ax + Bx) + Cx + d*Ex,
--     ye = wc*(py*Ay + By) + Cy + d*Ey; dist = sqrt(xe² + ye² + ze² + 1), дальше — как core.glsl
--     Eaglercraft (формула в ui.glslf). Наборы, не присланные в этом кадре, не используются.
-- Биннинг (CPU, frame): треугольник попадает во все тайлы своего ограничивающего прямоугольника
-- (он же — первая проверка шейдера, поэтому для любого пикселя отброшенные треугольники всё
-- равно ничего бы не нарисовали); записи CLEAR_DEPTH — во все тайлы; в каждом списке исходный
-- порядок. Итог по каждому пикселю — ровно как у полного перебора. Если элементов больше
-- MAX_ENTRIES, заголовок [4] = 0 и шейдер перебирает все треугольники.
local host = require "wasmrt:host"
local gfx_snap = require "wasmrt:gfx_snap"

local M = {}

local W = 2048
local ATLAS_H = 2048
local TRI_TEXELS = 16
local TRI_ROWS = 256
local IDX_ROWS = 128
local TRI_ROW0 = ATLAS_H + 1
local TILE_ROW = TRI_ROW0 + TRI_ROWS
local IDX_ROW0 = TILE_ROW + 1
local FOG_ROW = IDX_ROW0 + IDX_ROWS
local FOG_TEXELS = 16
local MAX_FOG = 256
local FOG_ROWS = math.ceil(MAX_FOG * FOG_TEXELS / W)
local H = FOG_ROW + FOG_ROWS
local MAX_TRIS = math.floor(W * TRI_ROWS / TRI_TEXELS)
local MAX_ENTRIES = W * IDX_ROWS * 2
local SLOT0 = 8
local MAX_SLOTS = math.floor((W - SLOT0) / 2)
assert(MAX_TRIS <= 65536)

-- opts (поля манифеста): tris_tile — сторона тайла в пикселях (32 по умолчанию, 0 — без
-- биннинга, полный перебор), tris_verify — отладка: шейдер считает пиксель обоими способами
-- и красит расхождения пурпурным.
function M.new(document, width, height, opts)
    opts = opts or {}
    local tile_size = opts.tris_tile or 32
    -- tris_verify: 1 (или true) — сверка биннинга с полным перебором, 2 — вывод коэффициента тумана
    local verify = tonumber(opts.tris_verify) or (opts.tris_verify and 1) or 0
    -- tris_probe = {x, y}: пиксель-зонд для режима 3 (биты 8-19 и 20-31 слова [5])
    local probe = opts.tris_probe
    if probe then verify = verify + probe[1] * 256 + probe[2] * 1048576 end
    local self = { width = width, height = height, max_tris = MAX_TRIS }
    local fb = Bytearray(W * H * 4)
    local p = fb.bytes
    local canvas, image
    local slots, next_slot = {}, 0  -- id текстуры программы -> { slot, x, y, w, h }
    local shelf_x, shelf_y, shelf_h = 0, 0, 0
    local floor, min, max = math.floor, math.min, math.max
    local band, bor, rshift, lshift, arshift = bit.band, bit.bor, bit.rshift, bit.lshift, bit.arshift

    local function write_u32(texel, value)
        local o = texel * 4
        p[o] = band(value, 255)
        p[o + 1] = band(rshift(value, 8), 255)
        p[o + 2] = band(rshift(value, 16), 255)
        p[o + 3] = band(rshift(value, 24), 255)
    end

    local header = ATLAS_H * W

    local function place_image()
        if not image then return end
        local parent = opts.host and opts.host.parent
        local viewport = parent and parent.size or gui.get_viewport()
        local margin = parent and 0 or 20
        local scale = min((viewport[1] - margin) / self.width, (viewport[2] - margin) / self.height)
        if scale >= 1 then scale = floor(scale) end
        image.size = { max(1, floor(self.width * scale)), max(1, floor(self.height * scale)) }
        image:reposition()
    end

    function self:activate()
        if not document or (canvas and canvas.exists) then return end
        document.root:add(('<canvas id="wasmrt_tris_canvas" size="%d,%d" visible="false"/>'):format(W, H))
        canvas = document["wasmrt_tris_canvas"]
        canvas.data:create_texture("wasmrt_tris")
        local parent = opts.host and opts.host.parent or document.root
        parent:add('<image id="wasmrt_tris_image" src="wasmrt_tris" size="1,1" gravity="center-center" region="0,0,1,1" color="#FF01FF80"/>')
        image = document["wasmrt_tris_image"]
        place_image()
    end
    function self:deactivate()
        if image and image.exists then image:destruct() end
        if canvas and canvas.exists then canvas:destruct() end
    end
    function self:set_debug() end
    function self:relayout() place_image() end

    function self:to_virtual(mx, my)
        if not (image and image.exists) then return nil end
        local pos, size = image.wpos, image.size
        if size[1] <= 0 or size[2] <= 0 then return nil end
        local vx = (mx - pos[1]) / size[1] * self.width
        local vy = (my - pos[2]) / size[2] * self.height
        return floor(vx), floor(vy), vx >= 0 and vy >= 0 and vx < self.width and vy < self.height
    end

    -- Место в атласе: список свободных прямоугольников, лучший по площади, остаток
    -- режется на два (guillotine). Освобождённое место возвращается в список.
    local free = { { 0, 0, W, ATLAS_H } }
    local function place(w, h)
        local best, best_area
        for i, r in ipairs(free) do
            if r[3] >= w and r[4] >= h then
                local area = r[3] * r[4]
                if not best or area < best_area then best, best_area = i, area end
            end
        end
        if not best then return nil end
        local r = table.remove(free, best)
        local x, y = r[1], r[2]
        -- разрез по большей стороне остатка
        if r[3] - w > r[4] - h then
            if r[3] > w then free[#free + 1] = { x + w, y, r[3] - w, r[4] } end
            if r[4] > h then free[#free + 1] = { x, y + h, w, r[4] - h } end
        else
            if r[4] > h then free[#free + 1] = { x, y + h, r[3], r[4] - h } end
            if r[3] > w then free[#free + 1] = { x + w, y, r[3] - w, h } end
        end
        return x, y
    end

    function self:texture_delete(id)
        local s = slots[id]
        if not s then return end
        if s.w > 0 then free[#free + 1] = { s.x, s.y, s.w, s.h } end
        s.x, s.y, s.w, s.h, s.tw, s.th = 0, 0, 0, 0, -1, -1
        if s.slot == 0xFFFF then return end
        write_u32(header + SLOT0 + 2 * s.slot, 0)
        write_u32(header + SLOT0 + 1 + 2 * s.slot, 0)
    end

    function self:texture(api, memory, id, w, h, ptr)
        if ptr and self.snap then self.snap:invalidate(id) end  -- новая загрузка: готового снимка нет
        local s = slots[id]
        if s and (s.tw ~= w or s.th ~= h) then self:texture_delete(id) end
        if not s or s.tw ~= w or s.th ~= h then
            -- Высокие полосы (кадры анимаций Minecraft) программа сама копирует в атлас
            -- через texture_sub; на GPU они не нужны.
            local x, y
            if h < 8 * w then x, y = place(w, h) end
            local pw, ph = w, h
            if not x then
                if h < 8 * w then
                    debug.log(("[wasmrt] gfx_tris: texture %d (%dx%d) does not fit the atlas"):format(id, w, h))
                end
                x, y, pw, ph = 0, 0, 0, 0
            end
            if not s then
                s = { slot = next_slot }
                if next_slot >= MAX_SLOTS then
                    debug.log(("[wasmrt] gfx_tris: texture %d: no free header slot"):format(id))
                    s.slot = 0xFFFF
                else
                    next_slot = next_slot + 1
                end
                slots[id] = s
            end
            s.x, s.y, s.w, s.h, s.tw, s.th = x, y, pw, ph, w, h
            if s.slot == 0xFFFF then return end
            write_u32(header + SLOT0 + 2 * s.slot, x + y * 65536)
            write_u32(header + SLOT0 + 1 + 2 * s.slot, pw + ph * 65536)
        end
        if s.w == 0 or not ptr then return end
        for row = 0, h - 1 do
            api.copy_out(memory, ptr + row * w * 4, w * 4, p, ((s.y + row) * W + s.x) * 4)
        end
    end

    function self:texture_sub(api, memory, id, x, y, w, h, ptr)
        local s = slots[id]
        if not s or s.w == 0 or x + w > s.w or y + h > s.h then return end
        for row = 0, h - 1 do
            api.copy_out(memory, ptr + row * w * 4, w * 4, p, ((s.y + y + row) * W + s.x + x) * 4)
        end
    end

    -- Наборы тумана кадра: count записей по FOG_TEXELS слов с адреса ptr — в строки FOG_ROW.
    -- float32 из 4 байт буфера (для диагностики наборов тумана в строке fps)
    local function f32_at(o)
        local b0, b1, b2, b3 = p[o], p[o + 1], p[o + 2], p[o + 3]
        local sign = b3 >= 128 and -1 or 1
        local exp = band(b3, 127) * 2 + rshift(b2, 7)
        local mant = band(b2, 127) * 65536 + b1 * 256 + b0
        if exp == 0 then return sign * mant * 2 ^ -149 end
        if exp == 255 then return mant == 0 and sign * math.huge or 0 / 0 end
        return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
    end

    function self:fog(api, memory, ptr, count)
        if count > MAX_FOG then count = MAX_FOG end
        self.fog_sets = count
        if count > 0 then
            local o = FOG_ROW * W * 4
            api.copy_out(memory, ptr, count * FOG_TEXELS * 4, p, o)
            self.fog_info = ("color %02x%02x%02x/%02x mode %g start %g len %g dens %g"):format(
                p[o], p[o + 1], p[o + 2], p[o + 3], f32_at(o + 4), f32_at(o + 8), f32_at(o + 12), f32_at(o + 16))
            if not self.fog_dumped then
                self.fog_dumped = true
                local words = {}
                for k = 0, FOG_TEXELS - 1 do
                    local b = o + k * 4
                    words[#words + 1] = ("%02x%02x%02x%02x"):format(p[b + 3], p[b + 2], p[b + 1], p[b])
                end
                debug.log("[wasmrt] gfx_tris fog set0 words: " .. table.concat(words, " "))
            end
        end
    end

    -- Тайловый биннинг (см. описание формата в начале файла). Массивы заводятся один раз.
    local tile_shift, tiles_x, tiles_y, ntiles = 0, 0, 0, 0
    if tile_size > 0 then
        tile_shift = 0
        while bit.lshift(1, tile_shift) < tile_size do tile_shift = tile_shift + 1 end
        -- таблица тайлов — одна строка: при большом экране тайлы укрупняются
        while true do
            local ts = bit.lshift(1, tile_shift)
            tiles_x = floor((width + ts - 1) / ts)
            tiles_y = floor((height + ts - 1) / ts)
            ntiles = tiles_x * tiles_y
            if ntiles + 1 <= W then break end
            tile_shift = tile_shift + 1
        end
    end
    local tri_shift = tile_shift + 4  -- координаты вершин в 1/16 пикселя
    local tile_count, tile_pos = {}, {}
    for t = 0, ntiles do tile_count[t], tile_pos[t] = 0, 0 end
    local tri_x0, tri_x1, tri_y0, tri_y1 = {}, {}, {}, {}
    for i = 0, MAX_TRIS - 1 do tri_x0[i], tri_x1[i], tri_y0[i], tri_y1[i] = 0, 0, 0, 0 end
    local tile_row = TILE_ROW * W
    local idx_byte = IDX_ROW0 * W * 4
    local bin_word = tiles_x > 0 and (tile_shift + tiles_x * 256 + tiles_y * 1048576) or 0
    self.tile_size = tiles_x > 0 and bit.lshift(1, tile_shift) or 0
    local warned_clip, warned_bins = false, false
    -- снимки экрана в текстуру: CPU-растеризация (id текстуры программы -> слот атласа)
    local snap = gfx_snap.new(p, W, header, TRI_ROW0 * W, TRI_TEXELS, SLOT0, function(id)
        local s = slots[id]
        return s and s.w > 0 and s.slot ~= 0xFFFF and s.slot or nil
    end)
    self.snap = snap
    -- Бюджет CPU-снимков на кадр (manifest snapshot_budget_ms, по умолчанию 25; 0 — всё в том же
    -- кадре). С бюджетом цепочка снимков кадра считается за несколько кадров в промежуточные слоты
    -- (id -id), а видимая текстура обновляется целиком по готовности.
    local budget_ms = opts.snapshot_budget_ms or 25
    snap.budget = budget_ms > 0 and budget_ms / 1000 or nil
    snap.staging_of = function(id, w, h)
        self:texture(nil, nil, -id, w, h, nil)
        local s = slots[-id]
        return s and s.w > 0 and s.slot ~= 0xFFFF and s.slot or nil
    end
    self.canvas_bytes, self.canvas_size = p, W * H * 4  -- для проверки (run_luajit HOSTSIM)
    self.slots = slots

    -- Кадр: count треугольников по TRI_TEXELS int с адреса ptr. В поле текстуры приходит id
    -- текстуры программы, здесь он заменяется номером слота; заодно строятся списки тайлов.
    function self:frame(api, memory, ptr, count, clear, clear_depth)
        local clock = os.clock
        local t0 = clock()
        if count > MAX_TRIS then
            if not warned_clip then
                debug.log(("[wasmrt] gfx_tris: %d triangles, only %d fit (TRI_ROWS)"):format(count, MAX_TRIS))
                warned_clip = true
            end
            self.clipped = (self.clipped or 0) + (count - MAX_TRIS)
            count = MAX_TRIS
        end
        self.last_count = count
        local base = TRI_ROW0 * W
        api.copy_out(memory, ptr, count * TRI_TEXELS * 4, p, base * 4)
        local t1 = clock()
        -- проход 1: слоты текстур, прямоугольники тайлов, счёт по тайлам
        local clears, fog_tris, last_snap = 0, 0, -1
        for t = 0, ntiles - 1 do tile_count[t] = 0 end
        local txm, tym = tiles_x - 1, tiles_y - 1
        for i = 0, count - 1 do
            local ob = (base + i * TRI_TEXELS) * 4
            local o = ob + 48
            local id = p[o] + p[o + 1] * 256
            if id ~= 0 then
                local s = slots[id]
                local slot = s and s.slot or 0xFFFF
                p[o], p[o + 1] = band(slot, 255), rshift(slot, 8)
            end
            if band(p[o + 2], 8) ~= 0 then
                fog_tris = fog_tris + 1
                if not self.fog_tri_dumped then
                    self.fog_tri_dumped = true
                    local words = {}
                    for k = 0, TRI_TEXELS - 1 do
                        local b = ob + k * 4
                        words[#words + 1] = ("%02x%02x%02x%02x"):format(p[b + 3], p[b + 2], p[b + 1], p[b])
                    end
                    debug.log("[wasmrt] gfx_tris first fog tri words: " .. table.concat(words, " "))
                end
            end
            if band(p[o + 2], 64) ~= 0 and band(p[o + 2], 128) == 0 then
                -- снимок экрана: не треугольник, в тайлы не идёт
                last_snap = i
                tri_x0[i] = -1
            elseif ntiles > 0 then
                if band(p[o + 2], 128) ~= 0 then
                    clears = clears + 1
                    tri_x0[i] = -2
                else
                    -- x, y вершин: знаковые 16 бит; arshift даёт floor для отрицательных
                    local ax = bor(p[ob], lshift(p[ob + 1], 8)); ax = arshift(lshift(ax, 16), 16)
                    local ay = bor(p[ob + 2], lshift(p[ob + 3], 8)); ay = arshift(lshift(ay, 16), 16)
                    local bx = bor(p[ob + 16], lshift(p[ob + 17], 8)); bx = arshift(lshift(bx, 16), 16)
                    local by = bor(p[ob + 18], lshift(p[ob + 19], 8)); by = arshift(lshift(by, 16), 16)
                    local cx = bor(p[ob + 32], lshift(p[ob + 33], 8)); cx = arshift(lshift(cx, 16), 16)
                    local cy = bor(p[ob + 34], lshift(p[ob + 35], 8)); cy = arshift(lshift(cy, 16), 16)
                    local x0 = arshift(min(ax, bx, cx), tri_shift)
                    local x1 = arshift(max(ax, bx, cx), tri_shift)
                    local y0 = arshift(min(ay, by, cy), tri_shift)
                    local y1 = arshift(max(ay, by, cy), tri_shift)
                    if x1 < 0 or y1 < 0 or x0 > txm or y0 > tym then
                        tri_x0[i] = -1
                    else
                        if x0 < 0 then x0 = 0 end
                        if y0 < 0 then y0 = 0 end
                        if x1 > txm then x1 = txm end
                        if y1 > tym then y1 = tym end
                        tri_x0[i], tri_x1[i], tri_y0[i], tri_y1[i] = x0, x1, y0, y1
                        for ty = y0, y1 do
                            local row = ty * tiles_x
                            for t = row + x0, row + x1 do tile_count[t] = tile_count[t] + 1 end
                        end
                    end
                end
            end
        end
        self.fog_tris = fog_tris
        if last_snap >= 0 or snap:busy() then
            local ts = clock()
            snap:run(count, last_snap, clear, clear_depth)
            self.snap_time = (self.snap_time or 0) + (clock() - ts)
            self.snap_frames = (self.snap_frames or 0) + 1
        end
        local t2 = clock()
        -- таблица тайлов (начала списков) и проход 2: индексы в исходном порядке
        local total = 0
        local binned = ntiles > 0
        if binned then
            for t = 0, ntiles - 1 do
                tile_pos[t] = total
                write_u32(tile_row + t, total)
                total = total + tile_count[t] + clears
            end
            write_u32(tile_row + ntiles, total)
            if total > MAX_ENTRIES then
                binned = false
                if not warned_bins then
                    debug.log(("[wasmrt] gfx_tris: %d tile entries > %d, full loop"):format(total, MAX_ENTRIES))
                    warned_bins = true
                end
                self.bin_overflows = (self.bin_overflows or 0) + 1
            end
        end
        if binned then
            for i = 0, count - 1 do
                local x0 = tri_x0[i]
                if x0 >= 0 then
                    local lo, hi = band(i, 255), rshift(i, 8)
                    local x1 = tri_x1[i]
                    for ty = tri_y0[i], tri_y1[i] do
                        local row = ty * tiles_x
                        for t = row + x0, row + x1 do
                            local e = tile_pos[t]
                            tile_pos[t] = e + 1
                            local o = idx_byte + e * 2
                            p[o], p[o + 1] = lo, hi
                        end
                    end
                elseif x0 == -2 then
                    local lo, hi = band(i, 255), rshift(i, 8)
                    for t = 0, ntiles - 1 do
                        local e = tile_pos[t]
                        tile_pos[t] = e + 1
                        local o = idx_byte + e * 2
                        p[o], p[o + 1] = lo, hi
                    end
                end
            end
            self.last_entries = total
            if total > (self.max_entries or 0) then self.max_entries = total end
        end
        write_u32(header, count)
        write_u32(header + 1, self.width + self.height * 65536)
        write_u32(header + 2, clear)
        write_u32(header + 3, clear_depth or 65535)
        write_u32(header + 4, binned and bin_word or 0)
        write_u32(header + 5, verify)
        write_u32(header + 6, TRI_ROW0 + TILE_ROW * 65536)
        write_u32(header + 7, IDX_ROW0 + FOG_ROW * 65536)
        local t3 = clock()
        local t4 = t3
        if canvas and canvas.exists then
            canvas.data:set_data(fb)
            t4 = clock()
            canvas.data:update()
        end
        local t5 = clock()
        local st = self.stage_time
        if not st then st = { 0, 0, 0, 0, 0 }; self.stage_time = st end
        st[1], st[2], st[3] = st[1] + (t1 - t0), st[2] + (t2 - t1), st[3] + (t3 - t2)
        st[4], st[5] = st[4] + (t4 - t3), st[5] + (t5 - t4)
        self.host_time = (self.host_time or 0) + (t5 - t0)
        self.host_frames = (self.host_frames or 0) + 1
    end

    -- Для строки fps в app.lua: среднее по этапам кадра (мс) с прошлого отчёта; обнуляет счётчики.
    function self:stage_report()
        local st, n = self.stage_time, self.host_frames or 0
        if not st or n == 0 then return "" end
        local k = 1000 / n
        local text = (" [copy %.1f, pass1 %.1f, bins %.1f, set_data %.1f, update %.1f; tile %d, entries %d max %d%s%s]"):format(
            st[1] * k, st[2] * k, st[3] * k, st[4] * k, st[5] * k, self.tile_size, self.last_entries or 0, self.max_entries or 0,
            self.clipped and (", clipped %d"):format(self.clipped) or "",
            self.bin_overflows and (", overflows %d"):format(self.bin_overflows) or "")
        text = text .. (" fog sets %d tris %d%s"):format(self.fog_sets or 0, self.fog_tris or 0,
            self.fog_info and (" (" .. self.fog_info .. ")") or "")
        if self.snap_frames then
            local ss = self.snap.stats
            text = text .. (" snapshot %.1f ms/frame (%d frames; last: %d tris, %d px, %d copies)"):format(
                self.snap_time / self.snap_frames * 1000, self.snap_frames, ss.tris, ss.pixels, ss.snapshots)
            self.snap_time, self.snap_frames = 0, nil
        end
        st[1], st[2], st[3], st[4], st[5] = 0, 0, 0, 0, 0
        self.clipped, self.bin_overflows = nil, nil
        return text
    end

    return self
end

return M
