-- smollm_gpu:probe — пробы 1–2 разведки «LLM на GPU» (agents/research/SMOLLM_GPU.md).
-- Запуск из app-скрипта (корутина: app.tick() = один кадр движка с рендером всех фреймов GUI).
--   1. Чтение пикселей в Lua: assets.to_canvas(<текстура фрейма>) (glGetTexImage), canvas:at / get_data,
--      на 0.32 ещё gui.screenshot(frame_id). Стоимость 1x1, 256x256, 1024x1024, проверка ориентации и байтов.
--   2. Проходы за кадр: порядок отрисовки фреймов (GUI::frames — unordered_map) и цепочка зависимых проходов
--      (выход фрейма A — вход фрейма B) внутри одного кадра движка.
-- Лог: строки "[sg] ..." в latest.log.
local M = {}

local function log(s) debug.log("[sg] " .. s) end

local now = time.precise_time or os.clock
M.clock_name = time.precise_time and "time.precise_time" or "os.clock"

local function bench(label, fn, min_s)
    min_s = min_s or 0.1
    fn()  -- прогрев
    local n, t0 = 0, now()
    repeat
        fn()
        n = n + 1
    until (now() - t0 >= min_s and n >= 3) or n >= 100000
    local dt = (now() - t0) / n
    log(("bench %-34s %9.4f ms  (n=%d, %s)"):format(label, dt * 1000, n, M.clock_name))
    return dt * 1000
end
M.bench = bench

local frames = {}
-- кадр GUI в текстуру: id фрейма = имя текстуры (без ':' — так assets.to_canvas ищет текстуру, а не атлас)
local function frame(id, w, h, xml)
    if not frames[id] then
        local root, doc = gui.create_frame(id, id, { w, h })
        frames[id] = { root = root, doc = doc, w = w, h = h }
    end
    local f = frames[id]
    f.root:clear()
    if xml then f.root:add(xml) end
    return f
end
M.frame = frame

local function img(src, w, h, mode, x, y)
    return ('<image src="%s" pos="%d,%d" size="%d,%d" color="#FF%02XFF80"/>'):format(src, x or 0, y or 0, w, h, mode)
end
M.img = img

local function rgb24(v) return v % 16777216 end

local function ticks(n) for _ = 1, n or 1 do M.app.tick() end end
M.ticks = ticks

-- ---------------------------------------------------------------- проба 1: чтение пикселей
function M.probe_read()
    -- узор 256x256: (x, y, x xor y, 255) — проверка, что байты и строки доходят как есть
    local pat = Canvas({ 256, 256 })
    for y = 0, 255 do
        for x = 0, 255 do
            pat:set(x, y, x, y, bit.bxor(x, y), 255)
        end
    end
    pat:create_texture("sg_pat")
    M.pat = pat
    frame("sg_r1", 1, 1, img("sg_pat", 1, 1, 1))
    frame("sg_r256", 256, 256, img("sg_pat", 256, 256, 1))
    frame("sg_r1024", 1024, 1024, img("sg_pat", 1024, 1024, 1))
    ticks(3)

    -- ориентация/байты: что лежит в строке y текстуры фрейма
    local c = assets.to_canvas("sg_r256")
    if not c then
        log("read: assets.to_canvas(sg_r256) = nil")
        return
    end
    local bad, first_bad = 0, nil
    local flipped_bad = 0
    for y = 0, 255 do
        for x = 0, 255, 17 do
            local v = c:at(x, y)
            local want = x + y * 256 + bit.bxor(x, y) * 65536 + 255 * 16777216
            local want_f = x + (255 - y) * 256 + bit.bxor(x, 255 - y) * 65536 + 255 * 16777216
            if v ~= want then
                bad = bad + 1
                first_bad = first_bad or ("(%d,%d)=%08x want %08x"):format(x, y, v or -1, want)
            end
            if v ~= want_f then flipped_bad = flipped_bad + 1 end
        end
    end
    log(("read: frame 256x256 copy of canvas: %d/%d samples differ (direct), %d differ (flipped) %s; canvas %dx%d")
        :format(bad, 256 * 16, flipped_bad, first_bad or "", c.width, c.height))
    local c1 = assets.to_canvas("sg_r1")
    log(("read: frame 1x1 -> %08x"):format(c1:at(0, 0)))

    -- стоимость
    local res = {}
    res.to_canvas_1 = bench("to_canvas 1x1", function() assets.to_canvas("sg_r1") end)
    res.to_canvas_256 = bench("to_canvas 256x256", function() assets.to_canvas("sg_r256") end)
    res.to_canvas_1024 = bench("to_canvas 1024x1024", function() assets.to_canvas("sg_r1024") end, 0.3)
    local c256 = assets.to_canvas("sg_r256")
    local c1024 = assets.to_canvas("sg_r1024")
    res.at_1 = bench("canvas:at x1", function() return c1:at(0, 0) end)
    res.at_256 = bench("canvas:at 256x256 loop", function()
        local s = 0
        for y = 0, 255 do for x = 0, 255 do s = s + c256:at(x, y) end end
        return s
    end)
    res.get_data_256 = bench("canvas:get_data 256x256", function() return c256:get_data() end)
    res.get_data_1024 = bench("canvas:get_data 1024x1024", function() return c1024:get_data() end, 0.3)
    local ba = c256:get_data()
    res.ba_loop_256 = bench("Bytearray index loop 256x256x4", function()
        local s = 0
        for i = 1, #ba do s = s + ba[i] end
        return s
    end)
    if gui.screenshot then
        res.screenshot_256 = bench("gui.screenshot(frame) 256x256", function() return gui.screenshot("sg_r256") end)
        res.screenshot_1024 = bench("gui.screenshot(frame) 1024x1024", function() return gui.screenshot("sg_r1024") end, 0.3)
        local s = gui.screenshot("sg_r256")
        log(("read: gui.screenshot(sg_r256) %s, at(5,7)=%08x (to_canvas %08x)"):format(
            tostring(s), s and s:at(5, 7) or -1, c256:at(5, 7)))
    else
        log("read: gui.screenshot absent (0.31)")
    end
    log("read: Bytearray_as_ptr " .. tostring(Bytearray_as_ptr ~= nil))
    M.read_res = res
    return res
end

-- ---------------------------------------------------------------- проба 2: порядок фреймов и цепочки
-- N фреймов 1x1; в раунде R фрейм R копирует canvas-часы, остальные копируют фрейм R. Два кадра с часами c1, c2:
-- фреймы, нарисованные после R, показывают c2, до R — c1. Так восстанавливается порядок отрисовки.
function M.probe_order(n)
    n = n or 24
    local ids = {}
    for i = 1, n do
        ids[i] = ("sg_o%02d"):format(i)
        frame(ids[i], 1, 1, img("sg_clock", 1, 1, 1))
    end
    ticks(2)
    local set_clock = M.set_clock
    local after = {}  -- after[a][b] = true: b рисуется после a
    local cval = 100
    for r = 1, n do
        for i = 1, n do
            frame(ids[i], 1, 1, img(i == r and "sg_clock" or ids[r], 1, 1, 1))
        end
        cval = cval + 2
        set_clock(cval - 1)
        ticks(1)
        set_clock(cval)
        ticks(1)
        after[r] = {}
        for i = 1, n do
            if i ~= r then
                local v = rgb24(assets.to_canvas(ids[i]):at(0, 0))
                if v == cval then after[r][i] = true
                elseif v ~= cval - 1 then log(("order: round %d frame %s unexpected %d (c=%d)"):format(r, ids[i], v, cval)) end
            end
        end
    end
    -- позиция = число фреймов, нарисованных раньше
    local pos, order = {}, {}
    for i = 1, n do
        local before = 0
        for r = 1, n do if r ~= i and after[r][i] then before = before + 1 end end
        pos[i] = before
        order[#order + 1] = i
    end
    table.sort(order, function(a, b) return pos[a] < pos[b] end)
    local consistent = true
    for k = 1, n do if pos[order[k]] ~= k - 1 then consistent = false end end
    local names = {}
    for k = 1, n do names[k] = ids[order[k]] end
    log(("order: %d frames, consistent total order %s: %s"):format(n, tostring(consistent), table.concat(names, " ")))
    M.order_ids = names
    return names, consistent
end

-- Цепочка INC по списку ids: ids[1] читает часы, ids[k] — ids[k-1]; значение = часы + k, если все проходы — в одном
-- кадре движка. lag = сколько кадров отстаёт конец цепочки.
function M.probe_chain(ids, label)
    local k = #ids
    for i = 1, k do
        frame(ids[i], 1, 1, img(i == 1 and "sg_clock" or ids[i - 1], 1, 1, 2))
    end
    ticks(k + 2)
    local lags = {}
    -- часы растут на 1000 каждый кадр: отставание видно в тысячах
    local base = 5000000
    for f = 1, k + 3 do
        local v = base + f * 1000
        M.set_clock(v)
        ticks(1)
    end
    local cur = base + (k + 3) * 1000
    local out = {}
    for i = 1, k do
        local v = rgb24(assets.to_canvas(ids[i]):at(0, 0))
        local lag = math.floor((cur - (v - i)) / 1000 + 0.5)
        lags[i] = lag
        out[#out + 1] = tostring(lag)
    end
    log(("chain %s: %d INC passes, end value %d (clock %d + %d), lag per pass: %s"):format(
        label, k, rgb24(assets.to_canvas(ids[k]):at(0, 0)), cur, k, table.concat(out, ",")))
    return lags
end

function M.set_clock(v)
    local c = M.clock_canvas
    c:set(0, 0, v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, 255)
    c:update()
end

function M.run_q12(app)
    M.app = app or M.app
    local vp = gui.get_viewport()
    log(("probe start: viewport %sx%s, clock %s"):format(tostring(vp[1]), tostring(vp[2]), M.clock_name))
    local ok, err = pcall(M.probe_read)
    if not ok then log("probe_read error: " .. tostring(err)) end
    local clock = Canvas({ 1, 1 })
    clock:set(0, 0, 0, 0, 0, 255)
    clock:create_texture("sg_clock")
    M.clock_canvas = clock
    local ok2, ids, consistent = pcall(M.probe_order, 24)
    if not ok2 then log("probe_order error: " .. tostring(ids)) return end
    local fwd = {}
    for i = 1, #ids do fwd[i] = ids[i] end
    local rev = {}
    for i = 1, #ids do rev[i] = ids[#ids + 1 - i] end
    local ok3, e3 = pcall(M.probe_chain, fwd, "draw-order")
    if not ok3 then log("chain error: " .. tostring(e3)) end
    local ok4, e4 = pcall(M.probe_chain, rev, "reverse-order")
    if not ok4 then log("chain error: " .. tostring(e4)) end
end

return M
