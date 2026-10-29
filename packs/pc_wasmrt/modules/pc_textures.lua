-- pc_wasmrt:pc_textures — картинки рабочего стола компьютера pc_wasmrt:pc, нарисованные кодом
-- (никаких чужих файлов): обои «зелёный холм и небо», панель задач, кнопка «пуск», заголовок окна,
-- кнопка закрытия, меню «Пуск», курсор-стрелка. Всё рисуется один раз в Bytearray RGBA и отдаётся
-- движку как текстура (Canvas:create_texture). Строка 0 буфера — верх картинки; у <image> с такой
-- текстурой region="0,1,1,0" (текстура canvas в движке перевёрнута).

local M = {}

local floor, min, max, exp, sin, cos, sqrt = math.floor, math.min, math.max, math.exp, math.sin, math.cos, math.sqrt

local function clamp(v) if v < 0 then return 0 elseif v > 255 then return 255 end return floor(v + 0.5) end
local function mix(a, b, t) return a + (b - a) * t end

local made = {}

-- Холст w*h, fill(p, w, h) пишет байты RGBA; текстура name.
local function make(name, w, h, fill)
    if made[name] then return name end
    local data = Bytearray(w * h * 4)
    fill(data.bytes, w, h)
    local canvas = Canvas({ w, h })
    canvas:set_data(data)
    canvas:update()
    canvas:create_texture(name)
    made[name] = canvas  -- держим холст живым вместе с текстурой
    return name
end

local function put(p, w, x, y, r, g, b, a)
    local o = (y * w + x) * 4
    p[o] = clamp(r); p[o + 1] = clamp(g); p[o + 2] = clamp(b); p[o + 3] = clamp(a or 255)
end

-- Вертикальный градиент по опорным точкам { {t, r, g, b}, ... } (t от 0 до 1), ширина 1.
local function vgradient(stops)
    return function(p, w, h)
        for y = 0, h - 1 do
            local t = h > 1 and y / (h - 1) or 0
            local a, b = stops[1], stops[#stops]
            for i = 1, #stops - 1 do
                if t >= stops[i][1] and t <= stops[i + 1][1] then a, b = stops[i], stops[i + 1]; break end
            end
            local k = b[1] > a[1] and (t - a[1]) / (b[1] - a[1]) or 0
            for x = 0, w - 1 do
                put(p, w, x, y, mix(a[2], b[2], k), mix(a[3], b[3], k), mix(a[4], b[4], k))
            end
        end
    end
end

-- Детерминированный шум (одинаковые обои при каждом запуске).
local function hash(x, y)
    local n = sin(x * 12.9898 + y * 78.233) * 43758.5453
    return n - floor(n)
end

-- Обои: небо с облаками и зелёный холм.
function M.wallpaper(w, h)
    return make("pc_wasmrt_pc_wallpaper", w, h, function(p)
        -- линия холма: пологий большой холм слева-по-центру и второй, ниже, справа
        local ridge = {}
        for x = 0, w - 1 do
            local fx = x / w
            local y1 = 0.60 - 0.13 * exp(-((fx - 0.36) / 0.30) ^ 2)
            local y2 = 0.66 - 0.06 * exp(-((fx - 0.88) / 0.22) ^ 2)
            ridge[x] = min(y1, y2) * h + 4 * sin(fx * 9.0)
        end
        -- облака: альфа-маска из гауссовых пятен
        local cloud = {}
        local blobs = {
            { 0.18, 0.16, 0.10, 0.035, 0.85 }, { 0.26, 0.14, 0.07, 0.03, 0.8 }, { 0.12, 0.19, 0.08, 0.025, 0.7 },
            { 0.62, 0.10, 0.12, 0.03, 0.75 }, { 0.70, 0.12, 0.08, 0.035, 0.8 }, { 0.55, 0.13, 0.06, 0.02, 0.6 },
            { 0.86, 0.26, 0.09, 0.025, 0.65 }, { 0.40, 0.30, 0.10, 0.02, 0.45 }, { 0.93, 0.08, 0.06, 0.02, 0.5 },
        }
        for _, bl in ipairs(blobs) do
            local cx, cy, rx, ry, a = bl[1] * w, bl[2] * h, bl[3] * w, bl[4] * h * 1.6, bl[5]
            for y = max(0, floor(cy - 3 * ry)), min(h - 1, floor(cy + 3 * ry)) do
                for x = max(0, floor(cx - 3 * rx)), min(w - 1, floor(cx + 3 * rx)) do
                    local dx, dy = (x - cx) / rx, (y - cy) / ry
                    local v = a * exp(-(dx * dx + dy * dy))
                    local i = y * w + x
                    cloud[i] = min(1, (cloud[i] or 0) + v)
                end
            end
        end
        for y = 0, h - 1 do
            -- небо: насыщенный синий вверху -> светло-голубой у горизонта
            local t = min(1, y / (h * 0.62))
            local sr, sg, sb = mix(22, 150, t ^ 1.3), mix(84, 200, t ^ 1.1), mix(196, 245, t)
            for x = 0, w - 1 do
                local r, g, b
                local top = ridge[x]
                local d = y - top  -- > 0 — ниже линии холма
                if d >= 1 then
                    -- трава: светлее у гребня и слева (солнце слева), темнее к низу
                    local depth = min(1, d / (h - top))
                    local light = 1.0 - 0.35 * (x / w) + 0.25 * exp(-d / 40)
                    local n = (hash(x, y) - 0.5) * 14 + (hash(floor(x / 7), floor(y / 3)) - 0.5) * 10
                    r = (mix(112, 38, depth) + n * 0.5) * light
                    g = (mix(186, 118, depth ^ 0.8) + n) * light
                    b = (mix(56, 22, depth) + n * 0.3) * light
                else
                    local c = cloud[y * w + x] or 0
                    r, g, b = mix(sr, 255, c), mix(sg, 255, c), mix(sb, 255, c)
                    if d > 0 then  -- сглаживание кромки холма
                        local gr, gg, gb = 112, 186, 56
                        r, g, b = mix(r, gr, d), mix(g, gg, d), mix(b, gb, d)
                    end
                end
                put(p, w, x, y, r, g, b)
            end
        end
    end)
end

-- Панель задач XP: светлая кромка сверху, насыщенный синий, темнее к низу.
function M.taskbar(h)
    return make("pc_wasmrt_pc_taskbar", 1, h, vgradient({
        { 0.0, 60, 129, 243 }, { 0.08, 43, 108, 230 }, { 0.15, 36, 94, 220 }, { 0.85, 34, 88, 214 }, { 1.0, 25, 65, 165 },
    }))
end

-- Область часов (трей) — голубее панели.
function M.tray(h)
    return make("pc_wasmrt_pc_tray", 1, h, vgradient({
        { 0.0, 60, 160, 245 }, { 0.12, 22, 142, 232 }, { 0.85, 18, 128, 222 }, { 1.0, 16, 100, 190 },
    }))
end

-- Заголовок окна: синий с бликом.
function M.titlebar(h)
    return make("pc_wasmrt_pc_titlebar", 1, h, vgradient({
        { 0.0, 10, 90, 235 }, { 0.12, 70, 150, 255 }, { 0.30, 20, 100, 240 }, { 0.8, 0, 84, 227 }, { 1.0, 0, 64, 200 },
    }))
end

-- Кнопка «пуск»: зелёная, правый край скруглён.
function M.start_button(w, h)
    return make("pc_wasmrt_pc_start", w, h, function(p)
        local R = h * 0.5
        for y = 0, h - 1 do
            local t = y / (h - 1)
            local r, g, b = mix(92, 45, t), mix(178, 130, t), mix(92, 40, t)
            if t < 0.15 then r, g, b = mix(140, r, t / 0.15), mix(210, g, t / 0.15), mix(140, b, t / 0.15) end
            for x = 0, w - 1 do
                local a = 255
                local cx = w - R
                if x > cx then
                    local dx, dy = x - cx, y - R + 0.5
                    local dist = sqrt(dx * dx + dy * dy)
                    a = clamp((R - dist + 0.5) * 255)
                end
                -- тёмная кромка справа
                local edge = x > w - 3 and 0.8 or 1
                put(p, w, x, y, r * edge, g * edge, b * edge, a)
            end
        end
    end)
end

-- Логотип-флажок на кнопке «пуск» (четыре цветные плашки).
function M.flag(size)
    return make("pc_wasmrt_pc_flag", size, size, function(p, w, h)
        local half = floor(size / 2)
        local colors = { { 240, 80, 30 }, { 120, 190, 40 }, { 40, 130, 240 }, { 250, 200, 20 } }
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local q = (y < half and 0 or 2) + (x < half and 1 or 2)
                local c = colors[q]
                local gap = (x == half or y == half) and 0 or 255
                local wave = floor(1.5 * sin((x / size) * 3.14))
                local yy = y - wave
                if yy < 0 or yy >= h then gap = 0 end
                put(p, w, x, y, c[1], c[2], c[3], gap)
            end
        end
    end)
end

-- Кнопка закрытия окна: красный квадрат со скруглением и белым крестом.
function M.close_button(s)
    return make("pc_wasmrt_pc_close", s, s, function(p, w, h)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local t = y / (h - 1)
                local r, g, b = mix(236, 190, t), mix(120, 50, t), mix(90, 30, t)
                local corner = (x < 2 or x > w - 3) and (y < 2 or y > h - 3)
                local border = x == 0 or y == 0 or x == w - 1 or y == h - 1
                if border then r, g, b = 255, 255, 255 end
                local u, v = x - (w - 1) / 2, y - (h - 1) / 2
                local cross = (math.abs(u - v) < 1.6 or math.abs(u + v) < 1.6) and math.abs(u) < w * 0.27 and math.abs(v) < h * 0.27
                if cross then r, g, b = 255, 255, 255 end
                put(p, w, x, y, r, g, b, corner and 0 or 255)
            end
        end
    end)
end

-- Кнопка «свернуть»: синяя с белой чертой.
function M.min_button(s)
    return make("pc_wasmrt_pc_min", s, s, function(p, w, h)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local t = y / (h - 1)
                local r, g, b = mix(90, 30, t), mix(150, 90, t), mix(255, 230, t)
                local corner = (x < 2 or x > w - 3) and (y < 2 or y > h - 3)
                local border = x == 0 or y == 0 or x == w - 1 or y == h - 1
                if border then r, g, b = 255, 255, 255 end
                if y >= h - 7 and y <= h - 5 and x >= 5 and x <= w * 0.55 then r, g, b = 255, 255, 255 end
                put(p, w, x, y, r, g, b, corner and 0 or 255)
            end
        end
    end)
end

-- Шапка меню «Пуск».
function M.menu_header(h)
    return make("pc_wasmrt_pc_menuhead", 1, h, vgradient({
        { 0.0, 24, 104, 216 }, { 0.2, 60, 140, 240 }, { 0.6, 16, 90, 210 }, { 1.0, 10, 70, 190 },
    }))
end

-- Курсор-стрелка 12x19: белая с чёрной обводкой.
local ARROW = {
    "X...........",
    "XX..........",
    "XWX.........",
    "XWWX........",
    "XWWWX.......",
    "XWWWWX......",
    "XWWWWWX.....",
    "XWWWWWWX....",
    "XWWWWWWWX...",
    "XWWWWWWWWX..",
    "XWWWWWWWWWX.",
    "XWWWWWWXXXXX",
    "XWWWXWWX....",
    "XWWXXWWX....",
    "XWX..XWWX...",
    "XX...XWWX...",
    "X.....XWWX..",
    "......XWWX..",
    ".......XX...",
}
function M.cursor()
    return make("pc_wasmrt_pc_cursor", 12, 19, function(p, w)
        for y, row in ipairs(ARROW) do
            for x = 1, #row do
                local c = row:sub(x, x)
                if c == "X" then put(p, w, x - 1, y - 1, 0, 0, 0, 255)
                elseif c == "W" then put(p, w, x - 1, y - 1, 255, 255, 255, 255)
                else put(p, w, x - 1, y - 1, 0, 0, 0, 0) end
            end
        end
    end)
end

-- PNG из файла -> текстура name (assets.load_texture; ориентация прямая, region не нужен); нет файла — nil.
function M.png(path, name)
    if made[name] then return name end
    local ok, err = pcall(function()
        assets.load_texture(file.read_bytes(path), name)
    end)
    if not ok then debug.log("[pc] texture " .. path .. " failed: " .. tostring(err)) return nil end
    made[name] = true
    return name
end

-- Иконка пака: content/<пак>/icon.png -> текстура pc_wasmrt_icon_<пак>; нет пака — nil.
function M.pack_icon(pack_id)
    return M.png(pack_id .. ":icon.png", "pc_wasmrt_icon_" .. pack_id)
end

-- Обои: textures/gui/wallpaper.png пака (пиксельная надпись wasmrt на холме, 1024x724); если файла
-- нет — обои кодом (wallpaper(), с переворотом region у вызывающего).
function M.wallpaper_png()
    return M.png("pc_wasmrt:textures/gui/wallpaper.png", "pc_wasmrt_pc_wall_png")
end

---------------------------------------------------------------------------------------------------
-- Пиксельные иконки (07.10): ASCII-спрайты -> текстура; палитра — буква -> RGBA. Рисуются кодом,
-- чужих картинок нет. Ярлыки рабочего стола — 32x32 (на экране 48x48), значки проводника — 16x16.
---------------------------------------------------------------------------------------------------
local PAL = {
    ["."] = { 0, 0, 0, 0 },
    K = { 40, 40, 40, 255 }, k = { 90, 90, 90, 255 }, W = { 255, 255, 255, 255 }, w = { 225, 225, 225, 255 },
    Y = { 250, 206, 70, 255 }, y = { 230, 170, 40, 255 }, o = { 200, 130, 20, 255 },
    G = { 140, 140, 150, 255 }, g = { 110, 110, 120, 255 }, h = { 170, 170, 180, 255 },
    B = { 40, 110, 230, 255 }, b = { 20, 70, 170, 255 }, c = { 120, 190, 255, 255 },
    R = { 225, 60, 50, 255 }, E = { 60, 170, 60, 255 }, P = { 160, 70, 200, 255 }, N = { 250, 150, 40, 255 },
    T = { 150, 100, 60, 255 }, t = { 110, 70, 40, 255 },
}
-- Строки спрайта пишутся снизу вверх: текстура canvas в движке перевёрнута, а так <image> показывает
-- её без region (как PNG-иконки паков из assets.load_texture).
local function sprite(name, rows)
    local h, w = #rows, #rows[1]
    for i, row in ipairs(rows) do
        if #row ~= w then error(("sprite %s: row %d has %d chars, expected %d"):format(name, i, #row, w)) end
    end
    return make(name, w, h, function(p)
        for y, row in ipairs(rows) do
            for x = 1, w do
                local c = PAL[row:sub(x, x)] or PAL["."]
                put(p, w, x - 1, h - y, c[1], c[2], c[3], c[4])
            end
        end
    end)
end

local SPRITES = {}
SPRITES.folder = {
    "................................",
    "................................",
    "....ooooooooo...................",
    "...oYYYYYYYYYo..................",
    "..oYYYYYYYYYYYoooooooooooooooo..",
    "..oYYYYYYYYYYYYYYYYYYYYYYYYYYYo.",
    "..oYYYYYYYYYYYYYYYYYYYYYYYYYYYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oYyyyyyyyyyyyyyyyyyyyyyyyyyYo.",
    "..oyyyyyyyyyyyyyyyyyyyyyyyyyyyo.",
    "..oooooooooooooooooooooooooooooo",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
}
SPRITES.paint = {
    "................................",
    "................................",
    "..........KKKKKKKKKK............",
    "........KKwwwwwwwwwwKK..........",
    ".......KwwwwwwwwwwwwwwK.........",
    "......KwwwRRwwwwwwYYwwwK........",
    ".....KwwwRRRRwwwwYYYYwwwK.......",
    ".....KwwwRRRRwwwwYYYYwwwK.......",
    "....KwwwwwRRwwwwwwYYwwwwwK......",
    "....KwwwwwwwwwwwwwwwwwwwwK......",
    "....KwwEEwwwwwwwwwwwwwBBwK......",
    "....KwEEEEwwwwwwwwwwwBBBBK......",
    "....KwEEEEwwwwwwwwwwwBBBBK......",
    "....KwwEEwwwwwwwwwwwwwBBwK......",
    "....KwwwwwwwwwwwwwwwwwwwKK......",
    "....KwwwwwwwwwwwwwwwwwKKK.......",
    ".....KwwPPwwwwwwwwwwwwK.........",
    ".....KwPPPPwwwwwwKKKKK..........",
    ".....KwPPPPwwwwKKK..............",
    "......KwPPwwwwK....KK...........",
    "......KwwwwwwK....KTTK..........",
    ".......KwwwwK....KTTTTK.........",
    "........KKKK....KTTTTK..........",
    "...............KTTTTK...........",
    "..............KTTTTK............",
    ".............KttttK.............",
    "............KttttK..............",
    "...........KRRRRK...............",
    "...........KRRRK................",
    "............KRK.................",
    ".............K..................",
    "................................",
}
SPRITES.trash = {
    "................................",
    "................................",
    "............kkkkkkkk............",
    "...........kGGGGGGGGk...........",
    "......kkkkkkGGGGGGGGkkkkkk......",
    ".....kGGGGGGGGGGGGGGGGGGGGk.....",
    ".....kGGGGGGGGGGGGGGGGGGGGk.....",
    ".....kkkkkkkkkkkkkkkkkkkkkk.....",
    "......kGGGGGGGGGGGGGGGGGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    "......kGGhGGGhGGGGhGGGhGGk......",
    ".......kGGhGGhGGGGhGGhGGk.......",
    ".......kGGhGGhGGGGhGGhGGk.......",
    ".......kGGhGGhGGGGhGGhGGk.......",
    ".......kGGhGGhGGGGhGGhGGk.......",
    ".......kGGhGGhGGGGhGGhGGk.......",
    ".......kGGhGGhGGGGhGGhGGk.......",
    "........kGGhGhGGGGhGhGGk........",
    "........kGGhGhGGGGhGhGGk........",
    "........kGGhGhGGGGhGhGGk........",
    "........kGGGGGGGGGGGGGGk........",
    "........kggggggggggggggk........",
    ".........kkkkkkkkkkkkkk.........",
    "................................",
    "................................",
    "................................",
}
SPRITES.trash_full = {}
for i, row in ipairs(SPRITES.trash) do
    local r = row
    if i == 2 then r = "..........WWWW...wwwW..........." end
    if i == 3 then r = ".........WWwwwWkkkwwwWk........." end
    if i == 4 then r = "......kkkWwwwwWGGGwwwwWkkk......" end
    SPRITES.trash_full[i] = r
end
SPRITES.settings = {
    "................................",
    "..............KKKK..............",
    ".........KK..KGGGGK..KK.........",
    "........KGGK.KGGGGK.KGGK........",
    "........KGGGKKGGGGKKGGGK........",
    ".........KGGGGGGGGGGGGK.........",
    "..........KGGGGGGGGGGK..........",
    ".....KKKKKGGGGhhhhGGGGKKKKK.....",
    "....KGGGGGGGGhhhhhhGGGGGGGGK....",
    "....KGGGGGGGhhKKKKhhGGGGGGGK....",
    "....KGGGGGGGhK....KhGGGGGGGK....",
    ".....KKKKGGGhK....KhGGGKKKK.....",
    "........KGGGhK....KhGGGK........",
    "........KGGGhK....KhGGGK........",
    ".....KKKKGGGhK....KhGGGKKKK.....",
    "....KGGGGGGGhK....KhGGGGGGGK....",
    "....KGGGGGGGhhKKKKhhGGGGGGGK....",
    "....KGGGGGGGGhhhhhhGGGGGGGGK....",
    ".....KKKKKGGGGhhhhGGGGKKKKK.....",
    "..........KGGGGGGGGGGK..........",
    ".........KGGGGGGGGGGGGK.........",
    "........KGGGKKGGGGKKGGGK........",
    "........KGGK.KGGGGK.KGGK........",
    ".........KK..KGGGGK..KK.........",
    "..............KKKK..............",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
}
-- значки проводника 16x16
SPRITES.s_folder = {
    "................", "................", ".ooooo..........", "oYYYYYoooooooooo", "oYYYYYYYYYYYYYYo",
    "oYyyyyyyyyyyyyYo", "oYyyyyyyyyyyyyYo", "oYyyyyyyyyyyyyYo", "oYyyyyyyyyyyyyYo", "oYyyyyyyyyyyyyYo",
    "oYyyyyyyyyyyyyYo", "oYyyyyyyyyyyyyYo", "oyyyyyyyyyyyyyyo", "oooooooooooooooo", "................", "................",
}
SPRITES.s_file = {
    "................", "..kkkkkkkkk.....", "..kWWWWWWWkk....", "..kWWWWWWWkwk...", "..kWWWWWWWkkkk..",
    "..kWWggggWWWWk..", "..kWWWWWWWWWWk..", "..kWWggggggWWk..", "..kWWWWWWWWWWk..", "..kWWggggggWWk..",
    "..kWWWWWWWWWWk..", "..kWWgggggWWWk..", "..kWWWWWWWWWWk..", "..kWWWWWWWWWWk..", "..kkkkkkkkkkkk..", "................",
}
SPRITES.s_image = {
    "................", ".kkkkkkkkkkkkkk.", ".kccccccccccccck", ".kccccccccccccck", ".kccccYYccccccck",
    ".kcccYYYYcccccck", ".kccccYYccccccck", ".kcccccccccccEck", ".kccccccccccEEEk", ".kcccccccccEEEEk",
    ".kccccccEEEEEEEk", ".kcccccEEEEEEEEk", ".kEEEEEEEEEEEEEk", ".kEEEEEEEEEEEEEk", ".kkkkkkkkkkkkkk.", "................",
}
SPRITES.s_video = {
    "................", ".KKKKKKKKKKKKKK.", ".KwKwKwKwKwKwKK.", ".KKKKKKKKKKKKKK.", ".KccccccccccccK.",
    ".KccccBcccccccK.", ".KccccBBccccccK.", ".KccccBBBcccccK.", ".KccccBBBBccccK.", ".KccccBBBcccccK.",
    ".KccccBBccccccK.", ".KccccBcccccccK.", ".KccccccccccccK.", ".KKKKKKKKKKKKKK.", ".KwKwKwKwKwKwKK.", ".KKKKKKKKKKKKKK.",
}
SPRITES.s_up = {
    "................", "................", ".......KK.......", "......KccK......", ".....KccccK.....",
    "....KccccccK....", "...KccccccccK...", "..KKKKccccKKKK..", ".....KccccK.....", ".....KccccK.....",
    ".....KccccK.....", ".....KccccK.....", ".....KKKKKK.....", "................", "................", "................",
}
SPRITES.s_trash = {
    "................", "......kkkk......", "...kkkGGGGkkk...", "..kGGGGGGGGGGk..", "..kkkkkkkkkkkk..",
    "...kGhGGhGGhGk..", "...kGhGGhGGhGk..", "...kGhGGhGGhGk..", "...kGhGGhGGhGk..", "...kGhGGhGGhGk..",
    "...kGhGGhGGhGk..", "....kGGGGGGGk...", "....kggggggggk..", ".....kkkkkkk....", "................", "................",
}
-- бегунок вертикального зума 12x16
SPRITES.thumb = {
    "..bbbbbbbb..", ".bccccccccb.", "bccccccccccb", "bccccccccccb", "bccbbbbbbccb", "bccccccccccb", "bccccccccccb",
    "bccbbbbbbccb", "bccccccccccb", "bccccccccccb", "bccbbbbbbccb", "bccccccccccb", "bccccccccccb", "bccccccccccb",
    ".bccccccccb.", "..bbbbbbbb..",
}
function M.icon(name)
    local rows = SPRITES[name]
    if not rows then return nil end
    return sprite("pc_wasmrt_pc_icon_" .. name, rows)
end

return M
