-- gpu_compute:compute — API «compute-шейдера» на стоковом VoxelCore 0.31/0.32 (README пака, agents/research/COMPUTE_API.md).
--
--   программа  = тело content/<пак>/shaders/gpu_<имя>.glsl, собранное tools/gpu_compute_build.py в общий ui.glslf пака
--                gpu_compute; вызывается картинкой UI с цветом-маркером #RRGGBB80 (R — банк, G — код, B = 255, A = 128)
--   буфер      = canvas-текстура RGBA8 (gc.buffer / gc.page: Bytearray -> Canvas:_set_data -> create_texture)
--   параметры  = canvas-текстура слов u32/f32 (gc.params), читаются в шейдере gc_word(i) / gc_wordf(i)
--   проход     = фрейм gui.create_frame(W x H) с картинкой-маркером во весь фрейм (вход — одна текстура, u_texture)
--   чтение     = assets.to_canvas(<id фрейма>) -> Canvas/Bytearray RGBA (данные в RGB, альфа съедена смешиванием)
--   цепочка    = n фреймов, упорядоченных пробой (gpu_compute:order), — зависимые проходы за один кадр
-- Движок рисует все фреймы каждый кадр; рендер прохода — в кадре submit, чтение без ожидания GPU — в следующем.
local codec = require "gpu_compute:codec"
local order = require "gpu_compute:order"
local pages = require "gpu_compute:pages"

local M = { codec = codec, order = order, pages = pages }
local now = time.precise_time or os.clock
local band, rshift, tobit = bit.band, bit.rshift, bit.tobit

local registry
function M.programs()
    if not registry then
        registry = json.parse(file.read("gpu_compute:data/programs.json")).programs
    end
    return registry
end

-- gc.program{ id = "noise" [, glsl = <исходник для сверки>] } -> { id, bank, g0, g1, marker(code) }
-- Программа должна быть собрана в ui.glslf (tools/gpu_compute_build.py); иначе ошибка с подсказкой.
local programs = {}
function M.program(o)
    if type(o) == "string" then o = { id = o } end
    if programs[o.id] then return programs[o.id] end
    local r = M.programs()[o.id]
    if not r then
        error(("gpu_compute: program '%s' is not built into gpu_compute:shaders/ui.glslf — run tools/gpu_compute_build.py and reopen content"):format(o.id))
    end
    local p = { id = o.id, bank = r.bank, g0 = r.g0, g1 = r.g1, pack = r.pack, sha1 = r.sha1 }
    function p.marker(code)
        code = code or p.g0
        if code < p.g0 or code > p.g1 then error(("gpu_compute: code %d out of %s range %d..%d"):format(code, p.id, p.g0, p.g1)) end
        return ("#%02X%02XFF80"):format(p.bank, code)
    end
    function p.color(code) return { p.bank, code or p.g0, 255, 128 } end
    programs[o.id] = p
    return p
end

-- gc.buffer{ id, width, rows | bytes (Bytearray), offset, size } -> { id, canvas, width, rows }
-- Байты кладутся как есть (4 на тексель, строка 0 — начало); id — имя текстуры для <image src> и чтения.
function M.buffer(o)
    local w = o.width or 256
    local size = o.size or (o.bytes and (o.bytes.size or #o.bytes)) or 0
    local rows = o.rows or math.max(1, math.ceil(math.ceil(size / 4) / w))
    local c = Canvas({ w, rows })
    if o.bytes then
        pages.blit(c, w, 0, o.bytes, o.offset or 0, math.min(size, w * rows * 4))
    elseif o.clear ~= false then
        c:clear()
    end
    c:create_texture(o.id)
    return { id = o.id, canvas = c, width = w, rows = rows, update = function(self) self.canvas:update() end }
end

function M.page(o) return pages.build(o) end

-- gc.params{ id, words = 1024, width = 256 } -> объект: :set(i, u32|int), :setf(i, float32), :update()
function M.params(o)
    local w = o.width or 256
    local n = o.words or 1024
    local rows = math.ceil(n / w)
    local c = Canvas({ w, rows })
    c:clear()
    c:create_texture(o.id)
    local prm = { id = o.id, canvas = c, width = w, words = n, dirty = false }
    function prm:set(i, v)
        local row = math.floor(i / w)
        v = tobit(v)
        c:set(i - row * w, row, band(v, 255), band(rshift(v, 8), 255), band(rshift(v, 16), 255), band(rshift(v, 24), 255))
        self.dirty = true
    end
    function prm:setf(i, x) self:set(i, codec.f32_bits(x)) end
    function prm:update() c:update(); self.dirty = false end
    return prm
end

-- gc.limits(): проход не больше окна (Frame::draw ставит фрейм проекцией главного окна), один вход, RGB8 выход
function M.limits()
    local vp = gui.get_viewport()
    return { max_pass_w = vp[1], max_pass_h = vp[2], inputs = 1, out = "rgb8", out_bytes_per_texel = 3,
        max_texture = 32768 }
end

-- gc.pass{ id, program, code, width, height, input = <id текстуры>|buffer|params, images = {...} }
-- Фрейм id (= имя текстуры результата). Без images — одна картинка во весь фрейм; images — свои картинки
-- { src, code, x, y, w, h, region = {p, q} } (несколько вызовов программы в одном проходе, как у smollm_gpu).
local function src_id(s) return type(s) == "table" and s.id or s end
function M.pass(o)
    local prog = type(o.program) == "table" and o.program or M.program(o.program)
    local lim = M.limits()
    local w, h = o.width, o.height
    if w > lim.max_pass_w or h > lim.max_pass_h then
        error(("gpu_compute: pass %s %dx%d is larger than the window %dx%d"):format(o.id, w, h, lim.max_pass_w, lim.max_pass_h))
    end
    local root, doc = gui.create_frame(o.id, o.id, { w, h })
    root:clear()
    local pass = { id = o.id, program = prog, width = w, height = h, root = root, doc = doc, imgs = {}, serial = 0 }
    local imgs = o.images or { { src = o.input, code = o.code, x = 0, y = 0, w = w, h = h } }
    for i, im in ipairs(imgs) do
        local iid = "gc_i" .. i
        local reg = im.region and (' region="%d,%d,%d,%d"'):format(im.region[1], im.region[2], im.region[1], im.region[2]) or ""
        root:add(('<image id="%s" src="%s" pos="%d,%d" size="%d,%d" color="%s"%s/>'):format(
            iid, src_id(im.src), im.x or 0, im.y or 0, im.w or w, im.h or h, prog.marker(im.code), reg))
        pass.imgs[i] = doc[iid]
        if o.visible == false then pass.imgs[i].visible = false end
    end
    pass.visible = o.visible ~= false
    return pass
end

function M.show(pass)
    if pass.visible then return end
    for _, el in ipairs(pass.imgs) do el.visible = true end
    pass.visible = true
end
function M.hide(pass)
    if not pass.visible then return end
    for _, el in ipairs(pass.imgs) do el.visible = false end
    pass.visible = false
end

-- gc.submit(pass [, params, words]) — words: { [i] = u32 } или { [i] = {f = float} } пишутся в params и update();
-- картинки прохода показываются; рендер — в этом кадре. Возвращает serial пакета (слово 0 params, если params дан).
function M.submit(pass, prm, words)
    pass.serial = (pass.serial + 1) % 16777216
    if pass.serial == 0 then pass.serial = 1 end
    if prm then
        prm:set(0, pass.serial)
        if words then
            for i, v in pairs(words) do
                if type(v) == "table" then prm:setf(i, v.f) else prm:set(i, v) end
            end
        end
        prm:update()
    end
    M.show(pass)
    pass.submitted = time.uptime()
    pass.pending = true
    return pass.serial
end

-- gc.read(pass [, { sync = true, canvas = true, serial_texel = t }]) -> Bytearray RGBA (get_data) | Canvas, сведения
-- По умолчанию конвейер: в кадре submit вернёт nil (рендер ещё не был, чтение ждало бы GPU), со следующего кадра —
-- данные. sync = true — читать сейчас (assets.to_canvas ждёт окончания отрисовки GPU; как argmax у smollm_gpu).
-- serial_texel — тексель с эхом serial (u24): если не совпал с последним submit — nil, "stale".
function M.read(pass, o)
    o = o or {}
    local id = type(pass) == "table" and pass.id or pass
    if type(pass) == "table" and not o.sync and pass.submitted == time.uptime() then return nil, "same_frame" end
    local t0 = now()
    local cv = assets.to_canvas(id)
    if not cv then return nil, "no_texture" end
    local t1 = now()
    if o.canvas then return cv, { read_s = t1 - t0 } end
    local data = cv:get_data()
    local t2 = now()
    if o.serial_texel and type(pass) == "table" then
        local s = codec.u24_at(data, o.serial_texel)
        if s ~= pass.serial % 16777216 then return nil, "stale", s end
    end
    if type(pass) == "table" then pass.pending = false end
    return data, { read_s = t1 - t0, get_data_s = t2 - t1 }
end

-- gc.chain{ id = "sg", n = 418, ticks = app.tick-обёртка } -> { ids = { упорядоченные id фреймов }, frames, info }
-- Создаёт n фреймов <id>%03d и раздаёт порядок по пробе (кеш config:gpu_compute_order.json). Клиент потом
-- пересоздаёт фреймы нужного размера через gc.frame(ids[k], w, h) — k-й нарисуется k-м в кадре.
function M.chain(o)
    local ids, frames, info = order.probe(o.id, o.n, { ticks = o.ticks })
    return { ids = ids, frames = frames, info = info }
end

-- gc.frame(id, w, h) — (пере)создать фрейм цепочки нужного размера; -> root, doc
function M.frame(id, w, h)
    local root, doc = gui.create_frame(id, id, { w, h })
    root:clear()
    return root, doc
end

-- gc.idle(list) — скрыть картинки проходов (фреймы движок продолжает очищать каждый кадр, но не считает)
function M.idle(list)
    if list == nil then return end
    if list.imgs then M.hide(list) return end
    for _, p in ipairs(list) do M.hide(p) end
end

-- gc.budget{ ms_per_frame = 6, fps_floor = 50 } -> b:begin() в начале кадра, b:allow(ms_estimate) -> bool, b:spent()
function M.budget(o)
    local b = { ms = o.ms_per_frame or 6, fps_floor = o.fps_floor, t0 = now(), used = 0 }
    function b:begin() self.t0 = now(); self.used = 0 end
    function b:allow(est)
        local el = (now() - self.t0) * 1000
        if self.fps_floor and time.delta() > 1 / self.fps_floor then return el < self.ms * 0.5 end
        return el + (est or 0) <= self.ms
    end
    function b:spent() return (now() - self.t0) * 1000 end
    return b
end

return M
