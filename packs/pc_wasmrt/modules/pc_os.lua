-- pc_wasmrt:pc_os — «Windows XP» на экране компьютера pc_wasmrt:pc.
--
-- Экран — штатный фрейм движка: gui.create_frame(id, текстура, {W, H}) рендерит XML-документ в
-- текстуру, её получает скелет сущности ($0 — материал экрана в models/pc.obj). Курсор: пока игрок
-- за компьютером, фрейм активен (gui.set_active_frame(id, locator)), движок сам отпускает курсор
-- ОС, а locator проецирует его лучом камеры на плоскость экрана и отдаёт координаты во фрейме —
-- наведение, клики, двойные клики и колесо GUI делает сам.
--
-- Программы: wasmrt:app.start(манифест, документ фрейма, embed) — картинка программы идёт в окно
-- рабочего стола (embed.parent), курсор — проекция, клавиши и мышь видны программе, только пока
-- игрок за этим компьютером. Видео — videoplayer:decoder на canvas в окне. «Minecraft (shader)» —
-- прежний режим пака: ShaderToy в шейдере сущностей по данным canvas (scripts/components/pc.lua).
-- Встроенные программы (07.10): Проводник (config:, export:, user:screenshots; .png — просмотр, .mp4 —
-- видео), Paint (canvas, кисть/ластик/цвета, PNG в export:pc_wasmrt/), Корзина (ярлыки и файлы),
-- Настройки (камера к ПК и лок мыши при входе — по умолчанию выключены).
--
-- Управление (07.10): ПКМ по компьютеру — сесть: курсор появляется на экране, камера ОСТАЁТСЯ на месте
-- (не прыгает к ПК), игрок стоит. Кнопки и подсказки — НЕ в экране, а в XML-оверлее движка вокруг него
-- (layouts/pc_overlay.xml, приём dagger_pc: hud.show_overlay при входе, hud.close при выходе; режим оверлея
-- заодно прячет хотбар и прицел движка): «встать», «залочить/отпустить мышь» (камера к экрану + курсор
-- заперт в экране; то же — Right Ctrl), «приблизить/отдалить» (зум 0 ↔ 1), стикеры с текущим режимом камеры
-- и мыши и клавишами. Пока игрок не за ПК, стикер «ПКМ — сесть за компьютер» показывает layouts/pc_hint.xml
-- (hud.open_permanent), когда взгляд на компьютере. Мышь: пока активен фрейм экрана, главный GUI её не видит
-- (GUI::act) — tick переключает активный фрейм: курсор над кнопками оверлея или мимо экрана → core:main,
-- над экраном → фрейм экрана (курсор ОС при любом активном фрейме отпущен). Ярлыки перетаскиваются мышью
-- (позиции — config:pc_wasmrt/desktop.json), ярлык на Корзину — в корзину. Встать: Esc на столе,
-- удержание Esc 1 с, кнопка «встать» оверлея, «пуск» → Выключение.

local tex = require "pc_wasmrt:pc_textures"

local M = {}

M.W, M.H = 1024, 724          -- разрешение экрана (соотношение сторон экрана модели 1.414)
local W, H = M.W, M.H
local TASKBAR_H = 30
local TITLE_H = 26
local BORDER = 3
local WIN_X, WIN_Y = 22, 16
local VIDEO_SLICE = 0.012     -- квант декодера видео за кадр движка, с
local EMISSIVE_MARKER = "#123456FF"  -- пиксель (0,0) экрана: shaders/entity.glslf светит экраном сам
local ICON_W, ICON_H = 150, 92       -- ячейка ярлыка
local OVERLAY_ID = "pc_wasmrt:pc_overlay"   -- layouts/pc_overlay.xml: кнопки и стикеры вокруг экрана (пока игрок за ПК)
M.OVERLAY_ID = OVERLAY_ID
local CONFIG_DIR, CONFIG_PATH = "config:pc_wasmrt", "config:pc_wasmrt/desktop.json"
local TRASH_DIR, TRASH_INDEX = "config:pc_wasmrt/trash", "config:pc_wasmrt/trash/index.json"
local PAINT_DIR = "export:pc_wasmrt"
local PAINT_W, PAINT_H = 800, 560
-- версия движка для меню «пуск»: vc.get_version() есть с 0.32 (res/scripts/stdmin.lua; возвращает два числа,
-- major и minor — libapp.cpp l_get_version), в 0.31 его нет
local ENGINE_VERSION = (function()
    local ok, major, minor = pcall(function() return vc.get_version() end)
    if not ok or major == nil then return "0.31" end
    return tostring(major) .. "." .. tostring(minor or 0)
end)()

-- Геометрия экрана в модели pc.obj (объект Plane, материал $0): угол uv(0,0), конец оси u (uv 1,0),
-- конец оси v (uv 0,1); смещение узла скелета skeletons/pc.json.
local SCREEN_A = { 0.180874, 0.215477, -0.914803 }
local SCREEN_U = { 0.180874, 0.215477, 0.536349 }
local SCREEN_V = { 0.176635, 1.241388, -0.914803 }
local MODEL_OFFSET = { 0, -0.7, 0 }

local function log(msg) debug.log("[pc] " .. msg) end

-- Программы рабочего стола. pack — пак, который должен быть включён в мире (иконка — его icon.png);
-- builtin — встроенная программа пака (иконка — pc_textures.icon).
local PROGRAMS = {
    { id = "doom", title = "Doom", pack = "doom", manifest = "doom:wasm.json" },
    { id = "quake", title = "Quake", pack = "quake", manifest = "quake:wasm.json" },
    { id = "eaglercraft", title = "Minecraft 1.5 (Eaglercraft)", short = "Eaglercraft", pack = "eaglercraft",
      manifest = "eaglercraft:wasm.json", server = { "127.0.0.1", 25599 } },
    { id = "video", title = "Проигрыватель видео", short = "Видео", pack = "videoplayer" },
    { id = "shader", title = "Minecraft (shader)", pack = "pc_wasmrt" },
    { id = "explorer", title = "Проводник", builtin = "folder" },
    { id = "paint", title = "Paint", builtin = "paint" },
    { id = "trash", title = "Корзина", builtin = "trash", fixed = true },
    { id = "settings", title = "Настройки", builtin = "settings", menu_only = true },
}
local BY_ID = {}
for _, p in ipairs(PROGRAMS) do BY_ID[p.id] = p end
M.PROGRAMS = PROGRAMS

-- Положение ярлыков по умолчанию: программы паков — столбец слева, встроенные — второй столбец,
-- корзина — справа внизу.
local DEFAULT_ICON_POS = {
    doom = { 18, 14 }, quake = { 18, 114 }, eaglercraft = { 18, 214 }, video = { 18, 314 }, shader = { 18, 414 },
    explorer = { 178, 14 }, paint = { 178, 114 }, trash = { W - 200, 586 },
}

local pcs = {}          -- uid -> экземпляр
local active = nil      -- экземпляр, за которым сидит игрок
local running = nil     -- { pc, prog, app | video | app_local } — одна программа на все компьютеры
local wasmrt = nil

local function vsub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function vadd(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function vmul(a, k) return { a[1] * k, a[2] * k, a[3] * k } end
local function vmix(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function norm(a) local l = math.sqrt(dot(a, a)); return l > 0 and vmul(a, 1 / l) or a end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

local function esc(text)
    return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
local function basename(path) return (path:gsub("\\", "/"):match("([^/:]+)$")) or path end
local function ext_of(name) return (name:lower():match("%.([%w]+)$")) or "" end

-- onclick в документе фрейма: событие пака с номером компьютера.
local function action(uid, name, arg)
    return ("events.emit('pc_wasmrt:pc_ui', %d, '%s', '%s')"):format(uid, name, (arg or ""):gsub("'", ""))
end

---------------------------------------------------------------------------------------------------
-- Настройки рабочего стола: config:pc_wasmrt/desktop.json
---------------------------------------------------------------------------------------------------
local config = { icons = {}, trash = {}, options = { attach_camera = false, mouse_lock = false, zoom = 1.0 } }
M.config = config

local function load_config()
    local ok, data = pcall(function()
        if not file.isfile(CONFIG_PATH) then return nil end
        return json.parse(file.read(CONFIG_PATH))
    end)
    if ok and type(data) == "table" then
        config.icons = type(data.icons) == "table" and data.icons or {}
        config.trash = type(data.trash) == "table" and data.trash or {}
        if type(data.options) == "table" then
            for k, v in pairs(data.options) do config.options[k] = v end
        end
        local n = 0
        for _ in pairs(config.icons) do n = n + 1 end
        log(("config loaded: %d icon positions, %d in trash, attach=%s lock=%s zoom=%.2f"):format(
            n, #config.trash, tostring(config.options.attach_camera), tostring(config.options.mouse_lock),
            tonumber(config.options.zoom) or 1))
    elseif not ok then
        log("config read failed: " .. tostring(data))
    end
end

local function save_config()
    local ok, err = pcall(function()
        file.mkdirs(CONFIG_DIR)
        file.write(CONFIG_PATH, json.tostring(config, true))
    end)
    if not ok then log("config save failed: " .. tostring(err)) else log("config saved " .. CONFIG_PATH) end
end
M.save_config = save_config
load_config()

local function in_trash(id)
    for _, t in ipairs(config.trash) do if t == id then return true end end
    return false
end

-- Корзина файлов: config:pc_wasmrt/trash/<имя>, индекс index.json = { {name, from}, ... }
local function trash_index()
    local ok, data = pcall(function()
        if not file.isfile(TRASH_INDEX) then return {} end
        return json.parse(file.read(TRASH_INDEX))
    end)
    if ok and type(data) == "table" then return data end
    return {}
end
local function save_trash_index(list)
    file.mkdirs(TRASH_DIR)
    file.write(TRASH_INDEX, json.tostring(list, true))
end

---------------------------------------------------------------------------------------------------
-- Экземпляр компьютера
---------------------------------------------------------------------------------------------------
local PC = {}
PC.__index = PC

function M.get(uid) return pcs[uid] end
function M.active() return active end
function M.running() return running end

-- entity — сущность pc_wasmrt:pc (таблица компонента), hooks — { on_shader(pc, on) }
function M.new(entity, hooks)
    local uid = entity:get_uid()
    local old = pcs[uid]
    if old then old:destroy() end
    local self = setmetatable({ uid = uid, entity = entity, hooks = hooks or {}, cursor = nil,
        frame_id = "pc_wasmrt:pc_" .. uid, texture = "pc_wasmrt_pc_screen_" .. uid, selected = nil,
        zoom = 0, mouse_lock = false, icon_pos = {} }, PC)
    local root, doc = gui.create_frame(self.frame_id, self.texture, { W, H })
    self.root, self.doc = root, doc
    self:build()
    pcs[uid] = self
    entity.skeleton:set_texture("$0", self.texture)
    log(("screen %s -> %s %dx%d"):format(self.frame_id, self.texture, W, H))
    return self
end

function PC:el(id) return self.doc[id] end

local function prog_icon(prog)
    if prog.builtin then return tex.icon(prog.builtin) end
    return tex.pack_icon(prog.pack)
end

function PC:icon_default_pos(id)
    local p = DEFAULT_ICON_POS[id] or { 338, 14 }
    return { p[1], p[2] }
end

function PC:build()
    local root, uid = self.root, self.uid
    local bar, tray, start, flag = tex.taskbar(TASKBAR_H), tex.tray(TASKBAR_H), tex.start_button(104, TASKBAR_H), tex.flag(18)
    local title, close, minb, head, cur = tex.titlebar(TITLE_H), tex.close_button(21), tex.min_button(21), tex.menu_header(54), tex.cursor()

    -- обои: textures/gui/wallpaper.png (пиксельная надпись wasmrt на холме); нет файла — обои кодом
    local wall_png = tex.wallpaper_png()
    root:add(('<image id="wall" src="%s" pos="0,0" size="%d,%d" %s interactive="true" onclick="%s"/>')
        :format(wall_png or tex.wallpaper(W, H), W, H, wall_png and "" or 'region="0,1,1,0"', action(uid, "desktop")))
    -- ярлыки
    for _, prog in ipairs(PROGRAMS) do
        if not prog.menu_only then
            local icon = prog_icon(prog)
            local label = esc(prog.short or prog.title)
            local installed = prog.builtin ~= nil or (pack.is_installed(prog.pack) and icon ~= nil)
            local saved = config.icons[prog.id]
            local pos = (type(saved) == "table" and tonumber(saved[1]) and tonumber(saved[2]))
                and { clamp(math.floor(saved[1]), 0, W - ICON_W), clamp(math.floor(saved[2]), 0, H - TASKBAR_H - ICON_H) }
                or self:icon_default_pos(prog.id)
            self.icon_pos[prog.id] = pos
            local visible = not in_trash(prog.id)
            -- ячейка 150x92: картинка 48x48, подпись с тенью; выделение — синяя плашка поверх картинки
            -- и под подписью (как у XP)
            root:add(('<container id="icon_%s" pos="%d,%d" size="%d,%d" color="#00000000" hover-color="#FFFFFF1C" ' ..
                'visible="%s" onclick="%s" ondoubleclick="%s">' ..
                '<image id="iconimg_%s" src="%s" pos="51,4" size="48,48" interactive="false" color="%s"/>' ..
                '<container id="iconsel_%s" pos="51,4" size="48,48" color="#00000000" interactive="false"/>' ..
                '<container id="iconlblbg_%s" pos="2,57" size="146,22" color="#00000000" interactive="false"/>' ..
                '<label pos="1,60" size="150,20" text-align="center" color="#000000C0" interactive="false">%s</label>' ..
                '<label id="iconlbl_%s" pos="0,59" size="150,20" text-align="center" color="#FFFFFFFF" interactive="false">%s</label>' ..
                '</container>')
                :format(prog.id, pos[1], pos[2], ICON_W, ICON_H, visible and "true" or "false",
                    action(uid, "select", prog.id), action(uid, "launch", prog.id),
                    prog.id, icon or "gui/error", installed and "#FFFFFFFF" or "#FFFFFF60", prog.id, prog.id, label, prog.id, label))
        end
    end
    -- окно программы (скрыто): рамка, заголовок, кнопки, клиентская область
    -- края экрана модели закрывает скос рамки монитора: окно с отступом
    local ww, wh = W - 2 * WIN_X, H - TASKBAR_H - WIN_Y - 8  -- клиент 974 px: Doom 320x200 помещается x3 (как в README)
    self.win_rect = { WIN_X, WIN_Y, ww, wh }
    self.client_rect = { WIN_X + BORDER, WIN_Y + TITLE_H, ww - 2 * BORDER, wh - TITLE_H - BORDER }
    root:add(('<container id="win" pos="%d,%d" size="%d,%d" color="#0831D9FF" visible="false">' ..
        '<image src="%s" pos="0,0" size="%d,%d" interactive="false"/>' ..
        '<label id="win_title" pos="30,5" size="%d,18" color="#FFFFFFFF" interactive="false">-</label>' ..
        '<image id="win_icon" src="gui/error" pos="6,4" size="18,18" interactive="false"/>' ..
        '<image id="win_min" src="%s" pos="%d,3" size="21,21" interactive="true" onclick="%s"/>' ..
        '<image id="win_close" src="%s" pos="%d,3" size="21,21" interactive="true" onclick="%s"/>' ..
        '<container id="win_client" pos="%d,%d" size="%d,%d" color="#000000FF"/>' ..
        '</container>')
        :format(WIN_X, WIN_Y, ww, wh, title, ww, TITLE_H, ww - 120, minb, ww - 50, action(uid, "minimize"),
            close, ww - 26, action(uid, "close"),
            BORDER, TITLE_H, ww - 2 * BORDER, wh - TITLE_H - BORDER))
    -- панель задач
    root:add(('<image id="taskbar" src="%s" pos="0,%d" size="%d,%d" interactive="true" onclick="%s"/>')
        :format(bar, H - TASKBAR_H, W, TASKBAR_H, action(uid, "desktop")))
    root:add(('<image id="start" src="%s" pos="0,%d" size="104,%d" region="0,1,1,0" interactive="true" onclick="%s"/>')
        :format(start, H - TASKBAR_H, TASKBAR_H, action(uid, "start")))
    root:add(('<image src="%s" pos="10,%d" size="18,18" region="0,1,1,0" interactive="false"/>')
        :format(flag, H - TASKBAR_H + 6))
    root:add(('<label pos="36,%d" size="60,20" color="#FFFFFFFF" interactive="false">пуск</label>')
        :format(H - TASKBAR_H + 7))
    root:add(('<container id="task" pos="112,%d" size="170,24" color="#3C81F3FF" hover-color="#5A9BFFFF" visible="false" onclick="%s">' ..
        '<image id="task_icon" src="gui/error" pos="5,3" size="18,18" interactive="false"/>' ..
        '<label id="task_title" pos="28,3" size="140,18" color="#FFFFFFFF" interactive="false">-</label></container>')
        :format(H - TASKBAR_H + 3, action(uid, "task")))
    root:add(('<image src="%s" pos="%d,%d" size="130,%d" interactive="false"/>'):format(tray, W - 130, H - TASKBAR_H, TASKBAR_H))
    -- кнопки «встать», «залочить мышь», «приблизить» и ползунок зума (до 07.10 — на панели задач и у правого
    -- края экрана) теперь в XML-оверлее движка вокруг экрана (layouts/pc_overlay.xml), в экране их нет
    root:add(('<label id="clock" pos="%d,%d" size="80,20" text-align="center" color="#FFFFFFFF" interactive="false">12:00</label>')
        :format(W - 122, H - TASKBAR_H + 7))
    -- меню «пуск» (скрыто)
    local menu_items = {}
    for _, prog in ipairs(PROGRAMS) do if prog.id ~= "trash" then menu_items[#menu_items + 1] = prog end end
    local mh = 54 + #menu_items * 44 + 16 + 44
    local items = {}
    for i, prog in ipairs(menu_items) do
        local icon = prog_icon(prog) or "gui/error"
        items[#items + 1] = ('<container pos="4,%d" size="312,40" color="#00000000" hover-color="#316AC5FF" onclick="%s">' ..
            '<image src="%s" pos="4,4" size="32,32" interactive="false"/>' ..
            '<label pos="44,11" size="264,18" color="#000000FF" interactive="false">%s</label></container>')
            :format(54 + 6 + (i - 1) * 44, action(uid, "launch", prog.id), icon, esc(prog.title))
    end
    root:add(('<container id="startmenu" pos="0,%d" size="480,%d" color="#0831D9FF" visible="false">' ..
        '<image src="%s" pos="0,0" size="480,54" interactive="false"/>' ..
        '<container pos="8,8" size="38,38" color="#FFFFFFFF" interactive="false"><image src="%s" pos="3,3" size="32,32" interactive="false"/></container>' ..
        '<label pos="56,18" size="300,20" color="#FFFFFFFF" interactive="false">Игрок</label>' ..
        '<container pos="2,54" size="318,%d" color="#FFFFFFFF" interactive="false"/>' ..
        '<container pos="320,54" size="158,%d" color="#D3E5FAFF" interactive="false">' ..
        '<label pos="10,12" size="140,18" color="#1E3287FF" interactive="false">Мой компьютер</label>' ..
        '<label pos="10,38" size="140,18" color="#1E3287FF" interactive="false">VoxelCore %s</label>' ..
        '<label pos="10,64" size="140,18" color="#1E3287FF" interactive="false">wasmrt</label></container>' ..
        '%s' ..
        '<container pos="2,%d" size="476,42" color="#3C81F3FF" interactive="false"/>' ..
        '<container pos="332,%d" size="140,32" color="#E0522CFF" hover-color="#FF7040FF" onclick="%s">' ..
        '<label pos="10,7" size="120,18" color="#FFFFFFFF" interactive="false">Выключение</label></container>' ..
        '</container>')
        :format(H - TASKBAR_H - mh, mh, head, tex.pack_icon("pc_wasmrt") or "gui/error", mh - 54 - 44, mh - 54 - 44,
            esc(ENGINE_VERSION), table.concat(items), mh - 44, mh - 38, action(uid, "shutdown")))
    -- маркер «экран светится» для шейдера сущностей и курсор поверх всего
    root:add(('<container pos="0,0" size="1,1" color="%s" interactive="false" z-index="1000"/>'):format(EMISSIVE_MARKER))
    root:add(('<image id="cursor" src="%s" pos="-40,-40" size="12,19" region="0,1,1,0" interactive="false" z-index="1001"/>'):format(cur))
    self:update_clock(true)
    self:update_trash_icon()
    self:ui_changed()
end

function PC:destroy()
    if running and running.pc == self then M.close_program() end
    if active == self then self:leave() end
    pcall(function() self.root:clear() end)
    pcs[self.uid] = nil
end

---------------------------------------------------------------------------------------------------
-- Геометрия экрана и проекция курсора
---------------------------------------------------------------------------------------------------
function PC:screen()
    local tsf = self.entity.transform
    local pos, rot, size = tsf:get_pos(), tsf:get_rot(), tsf:get_size()
    local function world(p)
        local q = mat4.mul(rot, { (p[1] + MODEL_OFFSET[1]) * size[1], (p[2] + MODEL_OFFSET[2]) * size[2],
            (p[3] + MODEL_OFFSET[3]) * size[3] })
        return { pos[1] + q[1], pos[2] + q[2], pos[3] + q[3] }
    end
    local a = world(SCREEN_A)
    return a, vsub(world(SCREEN_U), a), vsub(world(SCREEN_V), a)
end

-- Позиция курсора ОС во фрейме (пиксели, y вниз) или nil, если луч мимо экрана. При «локе мыши»
-- курсор не выходит за край экрана: точка прижимается к краю. Третий результат — true, если луч
-- действительно попал в экран (не прижат): по нему tick переключает активный фрейм (см. route_mouse).
function PC:project()
    local cam = cameras.get(player.get_camera(self.pid or 0))
    if not cam then return nil end
    local mp, vp = input.get_mouse_pos(), gui.get_viewport()
    local nx, ny = 2 * mp[1] / vp[1] - 1, 1 - 2 * mp[2] / vp[2]
    local t = math.tan(math.rad(cam:get_fov()) / 2)
    local o, f, r, u = cam:get_pos(), cam:get_front(), cam:get_right(), cam:get_up()
    local d = vadd(f, vadd(vmul(r, nx * t * vp[1] / vp[2]), vmul(u, ny * t)))
    local a, eu, ev = self:screen()
    local n = cross(eu, ev)
    local den = dot(d, n)
    if math.abs(den) < 1e-9 then return nil end
    local k = dot(vsub(a, o), n) / den
    if k <= 0 then
        if self.mouse_lock and self.cursor then return self.cursor[1], self.cursor[2] end
        return nil
    end
    local rel = vsub(vadd(o, vmul(d, k)), a)
    local su, sv = dot(rel, eu) / dot(eu, eu), dot(rel, ev) / dot(ev, ev)
    local inside = true
    if su < 0 or su > 1 or sv < 0 or sv > 1 then
        if not self.mouse_lock then return nil end
        su, sv = clamp(su, 0, 1), clamp(sv, 0, 1)
        inside = false
    end
    return su * W, (1 - sv) * H, inside
end

-- Точка фрейма (пиксели) -> координаты окна движка (для тестов: куда слать F2F input).
function PC:to_window(fx, fy)
    local cam = cameras.get(player.get_camera(self.pid or 0))
    if not cam then return nil end
    local a, eu, ev = self:screen()
    local p = vadd(a, vadd(vmul(eu, fx / W), vmul(ev, 1 - fy / H)))
    local vp = gui.get_viewport()
    local t = math.tan(math.rad(cam:get_fov()) / 2)
    local rel = vsub(p, cam:get_pos())
    local z = dot(rel, cam:get_front())
    if z <= 1e-6 then return nil end
    local x = dot(rel, cam:get_right()) / (z * t * vp[1] / vp[2])
    local y = dot(rel, cam:get_up()) / (z * t)
    return (x + 1) / 2 * vp[1], (1 - y) / 2 * vp[2]
end

-- Поза камеры «экран во весь кадр»: экран занимает ~95% кадра над хотбаром HUD (снизу HUD_RESERVE
-- пикселей окна): камера сдвинута вниз вдоль экрана, взгляд параллелен нормали экрана.
local HUD_RESERVE = 76
function PC:screen_pose()
    local cam = cameras.get("pc_wasmrt:sleeping")
    local a, eu, ev = self:screen()
    local center = vadd(a, vadd(vmul(eu, 0.5), vmul(ev, 0.5)))
    local n = norm(cross(eu, ev))
    local vp = gui.get_viewport()
    local t = math.tan(math.rad(cam:get_fov()) / 2)
    local hw, hh = math.sqrt(dot(eu, eu)) / 2, math.sqrt(dot(ev, ev)) / 2
    local usable = (vp[2] - HUD_RESERVE) / vp[2]
    local dist = math.max(hh / (t * usable), hw / (t * vp[1] / vp[2])) / 0.95
    local shift = vmul(norm(ev), -(HUD_RESERVE / vp[2]) * t * dist)
    local pos = vadd(vadd(center, vmul(n, dist)), shift)
    return pos, vmul(n, -1)
end

-- Камера по зуму: 0 — камера игрока как была (не прыгает к ПК); 1 — экран во весь кадр; между —
-- интерполяция положения и направления взгляда.
function PC:apply_camera()
    if not self.pid then return end
    if self.zoom <= 0.001 then
        player.set_camera(self.pid, self.prev_camera or cameras.index("core:first-person"))
        return
    end
    local cam = cameras.get("pc_wasmrt:sleeping")
    local p1, d1 = self:screen_pose()
    local b = self.base_pose
    local pos, dir = p1, d1
    if b then
        pos = vmix(b.pos, p1, self.zoom)
        dir = norm(vmix(b.front, d1, self.zoom))
    end
    cam:set_pos(pos)
    cam:look_at(vadd(pos, dir))
    player.set_camera(self.pid, cameras.index("pc_wasmrt:sleeping"))
end

function PC:set_zoom(z, save)
    self.zoom = clamp(z, 0, 1)
    self:apply_camera()
    self:ui_changed()
    if save and self.zoom > 0.001 then config.options.zoom = self.zoom end
end

-- Состояние камеры/мыши изменилось: обновить тексты оверлея (layouts/pc_overlay.xml.lua) сразу, не ждать его опроса.
function PC:ui_changed()
    local ov = M.overlay
    if ov and ov.refresh then pcall(ov.refresh) end
end

-- Зум «камера у экрана»: из настроек (ползунка больше нет, значение остаётся в desktop.json), по умолчанию 1.
local function attach_zoom()
    local z = tonumber(config.options.zoom) or 0
    return z > 0.05 and z or 1
end

-- Кнопка «приблизить/отдалить» оверлея: зум 0 (камера игрока как была) <-> зум у экрана; лок мыши не трогает.
function PC:toggle_zoom()
    self:set_zoom(self.zoom > 0.5 and 0 or attach_zoom())
    log(("zoom toggle -> %.2f"):format(self.zoom))
end

-- «Залочиться»: камера к экрану (зум из настроек, по умолчанию 1) и курсор заперт в экране; «отпустить» —
-- камера игрока как была, курсор свободный.
function PC:set_locked(on)
    self.locked = on
    self.mouse_lock = on
    if on then self:set_zoom(attach_zoom()) else self:set_zoom(0) end
    log(("lock %s (zoom %.2f, mouse_lock %s)"):format(tostring(on), self.zoom, tostring(self.mouse_lock)))
end

-- Функция-поставщик курсора для gui.set_active_frame. Каждый раз НОВОЕ замыкание: движок хранит
-- функцию в таблице лямбд под именем из её адреса и удаляет запись, когда прежний поставщик
-- уничтожается. Та же функция второй раз -> запись удалялась вместе со старым поставщиком, новый
-- возвращал nil, и движок падал ("uncaught exception: invalid value returned from locator").
-- Ошибка внутри тоже не должна ронять движок: pcall и точка вне фрейма.
function PC:locator()
    return function()
        local ok, x, y = pcall(self.project, self)
        if not ok then
            if not self.locator_error then
                self.locator_error = true
                log("cursor projection failed: " .. tostring(x))
            end
            x = nil
        end
        self.cursor = x and { x, y } or nil
        if not x then return { -100000, -100000 } end
        return { x, y }
    end
end

function PC:activate_frame()
    gui.set_active_frame(self.frame_id, self:locator())
end

-- Пока активен фрейм экрана, главный GUI (core:main, в нём XML-оверлей) мыши не видит (GUI::act отдаёт её
-- только активному фрейму), а курсор ОС отпущен при любом активном фрейме. Поэтому каждый кадр: мышь над
-- кнопкой оверлея или луч мимо экрана (без лока) — активен core:main, иначе — фрейм экрана с locator'ом.
-- При локе мыши проекция прижата к краю экрана, но кнопки оверлея (полоса под экраном) остаются досягаемы.
function PC:route_mouse()
    local ok, x, y = pcall(self.project, self)
    if not ok then x = nil end
    local want_main = M.mouse_over_overlay() or x == nil
    if want_main ~= (self.frame_main == true) then
        self.frame_main = want_main
        if want_main then gui.set_active_frame("core:main") else self:activate_frame() end
    end
    if self.frame_main then self.cursor = x and { x, y } or nil end
end

-- Позиция курсора для wasmrt (координаты документа, как wpos элементов: фрейм сдвинут по y).
function PC:doc_cursor()
    local c = self.cursor
    if not c then return { -100000, -100000 } end
    local p = self.root.pos
    return { c[1] + p[1], c[2] + p[2] }
end

---------------------------------------------------------------------------------------------------
-- Сесть за компьютер / встать
---------------------------------------------------------------------------------------------------
local saved_bindings = nil

local function lock_bindings(on)
    if on then
        if saved_bindings then return end
        saved_bindings = {}
        for _, name in ipairs(input.get_bindings()) do
            saved_bindings[#saved_bindings + 1] = name
            pcall(input.set_enabled, name, false)
        end
    elseif saved_bindings then
        for _, name in ipairs(saved_bindings) do pcall(input.set_enabled, name, true) end
        saved_bindings = nil
        -- привязки, которые держат правила мира (res/scripts/stdlib.lua)
        local rule_binds = {
            ["allow-flight"] = "player.flight", ["allow-noclip"] = "player.noclip", ["allow-attack"] = "player.attack",
            ["allow-destroy"] = "player.destroy", ["allow-cheat-movement"] = "movement.cheat",
            ["allow-fast-interaction"] = "player.fast_interaction",
        }
        for rule, bind in pairs(rule_binds) do
            local ok, value = pcall(rules.get, rule)
            if ok and value == false then pcall(input.set_enabled, bind, false) end
        end
    end
end

function PC:enter(pid)
    if active and active ~= self then active:leave() end
    self.pid = pid or 0
    self.lock_pos = { player.get_pos(self.pid) }
    self.lock_rot = { player.get_rot(self.pid) }
    self.prev_camera = player.get_camera(self.pid)
    -- поза камеры игрока на момент входа: начало интерполяции зума (камера не прыгает к ПК)
    local base = cameras.get(self.prev_camera)
    self.base_pose = base and { pos = base:get_pos(), front = base:get_front() } or nil
    active = self
    lock_bindings(true)
    local opts = config.options
    self.locked = opts.attach_camera == true or opts.mouse_lock == true
    self.mouse_lock = opts.mouse_lock == true
    self.zoom = opts.attach_camera == true and attach_zoom() or 0
    self:apply_camera()
    -- оверлей движка вокруг экрана (приём dagger_pc): кнопки и стикеры; режим оверлея прячет хотбар и прицел
    -- (Hud::update/draw: inventoryOpen) и делает активным фрейм core:main — наш фрейм активируем после него
    M.open_overlay(self)
    self.frame_main = false
    if self.shader_on then
        gui.set_active_frame("")
    else
        self:activate_frame()
    end
    self:ui_changed()
    log(("enter pc %d (attach=%s mouse_lock=%s zoom=%.2f)"):format(self.uid, tostring(opts.attach_camera == true),
        tostring(self.mouse_lock), self.zoom))
end

function PC:leave()
    if active ~= self then return end
    active = nil
    if self.shader_on then self:set_shader(false) end
    self:show_startmenu(false)
    gui.set_active_frame("")
    M.close_overlay()  -- hud.close(оверлея) -> Hud::closeInventory: хотбар и прицел возвращаются
    self.frame_main = false
    lock_bindings(false)
    player.set_camera(self.pid, self.prev_camera or cameras.index("core:first-person"))
    self.cursor = nil
    self.drag = nil
    self:el("cursor").pos = { -40, -40 }
    M.leave_t = time.uptime()  -- ещё зажатый Esc не должен открыть паузу движка (см. on_escape)
    log("leave pc " .. self.uid)
end

function PC:is_active() return active == self end

---------------------------------------------------------------------------------------------------
-- Рабочий стол
---------------------------------------------------------------------------------------------------
function PC:show_startmenu(on)
    local menu = self:el("startmenu")
    if on == nil then on = not menu.visible end
    menu.visible = on
end

function PC:select(id)
    for _, prog in ipairs(PROGRAMS) do
        if not prog.menu_only then
            local sel = prog.id == id
            self:el("iconsel_" .. prog.id).color = sel and { 11, 97, 255, 110 } or { 0, 0, 0, 0 }
            self:el("iconlblbg_" .. prog.id).color = sel and { 11, 97, 255, 255 } or { 0, 0, 0, 0 }
        end
    end
    self.selected = id
end

function PC:update_clock(force)
    local now = time.uptime()
    if not force and self.clock_t and now - self.clock_t < 1 then return end
    self.clock_t = now
    local ok, t = pcall(world.get_day_time)
    if not ok or not t then return end
    local minutes = math.floor(t * 24 * 60 + 0.5) % (24 * 60)
    self:el("clock").text = ("%d:%02d"):format(math.floor(minutes / 60), minutes % 60)
end

function PC:update_trash_icon()
    local full = #config.trash > 0 or #trash_index() > 0
    local img = self:el("iconimg_trash")
    if img then img.src = tex.icon(full and "trash_full" or "trash") end
end

-- Ярлык под точкой фрейма (видимый, не под открытым окном).
function PC:icon_at(x, y)
    if self:el("startmenu").visible then return nil end
    local wr = self.win_rect
    if self:el("win").visible and x >= wr[1] and x < wr[1] + wr[3] and y >= wr[2] and y < wr[2] + wr[4] then return nil end
    if y >= H - TASKBAR_H then return nil end
    for _, prog in ipairs(PROGRAMS) do
        if not prog.menu_only and not in_trash(prog.id) then
            local p = self.icon_pos[prog.id]
            if p and x >= p[1] and x < p[1] + ICON_W and y >= p[2] and y < p[2] + ICON_H then return prog.id end
        end
    end
    return nil
end

function PC:set_icon_pos(id, x, y)
    x = clamp(math.floor(x), 0, W - ICON_W - 18)
    y = clamp(math.floor(y), 0, H - TASKBAR_H - ICON_H)
    self.icon_pos[id] = { x, y }
    self:el("icon_" .. id).pos = { x, y }
end

-- Ярлык в корзину / из корзины.
function PC:trash_icon(id, on)
    local prog = BY_ID[id]
    if not prog or prog.fixed then return end
    local list = {}
    for _, t in ipairs(config.trash) do if t ~= id then list[#list + 1] = t end end
    if on then list[#list + 1] = id end
    config.trash = list
    self:el("icon_" .. id).visible = not on
    if on then self:select(nil) end
    save_config()
    for _, pc in pairs(pcs) do
        pc:update_trash_icon()
        if pc ~= self then pc:el("icon_" .. id).visible = not on end
    end
    log(("icon %s %s trash"):format(id, on and "->" or "<-"))
end

-- Перетаскивание ярлыков и ползунок зума: по проекции курсора и состоянию левой кнопки (клик GUI
-- приходит по нажатию, отпускание элементы фрейма не видят).
function PC:drag_tick()
    local pressed = input.is_pressed("mouse:left")
    local c = self.cursor
    local was = self.mouse_was
    self.mouse_was = pressed
    if pressed and not was and c then
        -- нажатие: ярлык (ползунок зума из экрана убран — зум переключает кнопка оверлея)
        local id = self:icon_at(c[1], c[2])
        if id then
            local p = self.icon_pos[id]
            self.drag = { id = id, ox = c[1] - p[1], oy = c[2] - p[2], sx = c[1], sy = c[2], moved = false }
        end
    elseif pressed and c then
        if self.drag then
            local d = self.drag
            if not d.moved and (math.abs(c[1] - d.sx) > 6 or math.abs(c[2] - d.sy) > 6) then d.moved = true end
            if d.moved then self:set_icon_pos(d.id, c[1] - d.ox, c[2] - d.oy) end
        end
    elseif not pressed and was then
        local d = self.drag
        self.drag = nil
        if d and d.moved then
            local p = self.icon_pos[d.id]
            local tp = self.icon_pos.trash
            local cx, cy = c and c[1] or (p[1] + d.ox), c and c[2] or (p[2] + d.oy)
            if d.id ~= "trash" and tp and cx >= tp[1] and cx < tp[1] + ICON_W and cy >= tp[2] and cy < tp[2] + ICON_H then
                self:set_icon_pos(d.id, d.sx - d.ox, d.sy - d.oy)  -- вернуть на место и спрятать
                self:trash_icon(d.id, true)
            else
                config.icons[d.id] = { p[1], p[2] }
                save_config()
                log(("icon %s moved to %d,%d"):format(d.id, p[1], p[2]))
            end
        end
    end
end

-- Окно программы: заголовок, иконка, клиентская область заново (программа кладёт туда картинку).
function PC:open_window(prog)
    local win = self:el("win")
    win.visible = true
    self:el("win_title").text = prog.title
    local icon = prog_icon(prog) or "gui/error"
    self:el("win_icon").src = icon
    self:el("task_icon").src = icon
    self:el("task_title").text = prog.short or prog.title
    self:el("task").visible = true
    local client = self:el("win_client")
    client:clear()
    client.color = { 0, 0, 0, 255 }
    self.minimized = false
    return client
end

function PC:close_window()
    self:el("win").visible = false
    self:el("task").visible = false
    pcall(function() self:el("win_client"):clear() end)
end

function PC:set_minimized(on)
    self.minimized = on
    self:el("win").visible = not on
end

-- Текст в окне (сообщение вместо программы).
function PC:message(prog, lines)
    local client = self:open_window(prog)
    local parts = {}
    for i, line in ipairs(lines) do
        parts[#parts + 1] = ('<label pos="16,%d" size="%d,20" color="#FFFFFFFF">%s</label>'):format(16 + (i - 1) * 26, W - 40, esc(line))
    end
    for _, part in ipairs(parts) do client:add(part) end  -- add() берёт один корневой элемент
    running = { pc = self, prog = prog, message = true }
end

---------------------------------------------------------------------------------------------------
-- Программы
---------------------------------------------------------------------------------------------------
function M.close_program()
    local r = running
    if not r then return end
    running = nil
    r.pc.action_t = time.uptime()
    if r.app then pcall(function() r.app:stop() end) end
    if r.video then r.video.stop() end
    if r.app_local and r.app_local.stop then pcall(r.app_local.stop) end
    if r.shader then r.pc:set_shader(false) end
    r.pc:close_window()
    if active == r.pc and not r.pc.shader_on then r.pc:activate_frame() end
    log("closed " .. r.prog.id .. (r.app and (" (" .. tostring(r.app.status) .. ", frames " .. tostring(r.app.frames) .. ")") or ""))
end

local function input_for(pc)
    return function() return active == pc and not pc.minimized end
end

function PC:start_wasm(prog, manifest)
    wasmrt = wasmrt or require("wasmrt:app")
    local client = self:open_window(prog)
    local ok, app = pcall(wasmrt.start, manifest, self.doc, {
        parent = client,
        mouse_pos = function() return self:doc_cursor() end,
        release_grab = function()
            if active == self then self:activate_frame() end
        end,
        input_enabled = input_for(self),
    })
    if not ok then
        log("start failed: " .. tostring(app))
        self:message(prog, { "Не удалось запустить " .. prog.title .. ":", tostring(app) })
        return
    end
    running = { pc = self, prog = prog, app = app }
    log(("started %s on pc %d (%s)"):format(prog.id, self.uid, type(manifest) == "table" and manifest.path or manifest))
end

-- Проверка порта сервера Eaglercraft (как scripts/app/eaglercraft.lua пака): асинхронно, до 3 с.
function PC:start_eaglercraft(prog)
    local host, port = prog.server[1], prog.server[2]
    local client = self:open_window(prog)
    client:add(('<label pos="16,16" size="600,20" color="#FFFFFFFF">Подключение к серверу %s:%d...</label>'):format(host, port))
    running = { pc = self, prog = prog, message = true }
    local done = false
    local t0 = time.uptime()
    local function finish(result)
        if done then return end
        done = true
        if not (running and running.prog == prog and running.pc == self) then return end
        if result == "ok" then
            log(("eaglercraft server ok %s:%d"):format(host, port))
            local m = wasmrt.load_manifest(prog.manifest)
            m.profile = false
            running = nil
            self:start_wasm(prog, m)
        else
            log(("eaglercraft server down %s:%d (%s)"):format(host, port, result))
            self:message(prog, {
                ("Сервер Eaglercraft не запущен: %s:%d не отвечает (%s)."):format(host, port, result),
                "Одиночной игре нужен внешний Node-сервер (оригинальный classes_server.js).",
                "Запустите его в WSL:",
                "  node <Spider>/tests/manual/real-world-eaglercraft/native_server/launcher.js",
                "и откройте ярлык снова.",
            })
        end
    end
    wasmrt = wasmrt or require("wasmrt:app")
    local ok, err = pcall(network.tcp_connect, host, port, function(sock)
        pcall(sock.close, sock)
        time.post_runnable(function() finish("ok") end)
    end, function(_, e)
        time.post_runnable(function() finish("fail: " .. tostring(e)) end)
    end)
    if not ok then finish("fail: " .. tostring(err)) end
    self.eag_wait = function()
        if not done and time.uptime() - t0 > 3 then finish("fail: timeout 3 s") end
    end
end

function PC:start_video(prog)
    local ok, decoder = pcall(require, "videoplayer:decoder")
    if not ok then
        self:message(prog, { "Пак videoplayer не включён в мире.", tostring(decoder) })
        return
    end
    local client = self:open_window(prog)
    local videos = decoder.list_videos()
    if #videos == 0 then
        self:message(prog, { "Нет видео: положите .mp4 в config/videoplayer/videos/." })
        return
    end
    local rows = {}
    for i, v in ipairs(videos) do
        rows[#rows + 1] = ('<container pos="16,%d" size="420,28" color="#FFFFFF20" hover-color="#316AC5FF" onclick="%s">' ..
            '<label pos="8,5" size="400,18" color="#FFFFFFFF" interactive="false">%s</label></container>')
            :format(16 + (i - 1) * 32, action(self.uid, "video", tostring(i)), esc(v.text))
    end
    for _, row in ipairs(rows) do client:add(row) end  -- add() берёт один корневой элемент
    running = { pc = self, prog = prog, message = true, videos = videos }
    if #videos == 1 then self:play_video(1) end
end

function PC:play_video(index)
    local r = running
    if not (r and r.pc == self and r.videos) then
        log(("play_video %s ignored: running %s"):format(tostring(index), tostring(r and r.prog.id)))
        return
    end
    local entry = r.videos[index]
    if not entry then return end
    self:play_video_entry(entry)
end

-- Видео в окне: entry = { value = путь, text = имя }. Вызывается из плеера (список) и из проводника
-- (двойной клик по .mp4); running уже указывает на этот компьютер.
function PC:play_video_entry(entry, back)
    local r = running
    local decoder = require("videoplayer:decoder")
    local client = self:el("win_client")
    client:clear()
    local ok, session = pcall(function()
        local s = decoder.create_session(entry.value)
        s:open()
        return s
    end)
    if not ok then
        self:message(r.prog, { "Не удалось открыть " .. entry.text .. ":", tostring(session) })
        return
    end
    -- настройки JIT для оттранслированного кода (как кнопка «JIT tuning» плеера: в 3.5–5 раз быстрее)
    pcall(function() require("wasmrt:host").set_jit_tuned(true) end)
    local v = { session = session, queue = {}, shown = 0, playing = true, frames = 0, fps_t = time.uptime(), fps_n = 0 }
    local worker = coroutine.create(function()
        while true do
            if #v.queue < 8 then
                local frame = session:next()
                if not frame then
                    session:open()  -- по кругу
                else
                    v.queue[#v.queue + 1] = frame
                end
            else
                coroutine.yield("full")
            end
            if os.clock() >= session.slice_deadline then coroutine.yield("slice") end
        end
    end)
    session:set_driver(worker)
    local canvas_id, texture, image = "pc_video_canvas", "pc_wasmrt_pc_video_" .. self.uid, nil
    local cw, ch = 0, 0
    client:add(('<label id="pc_video_status" pos="8,4" size="700,18" color="#C0C0C0FF" z-index="5">%s</label>'):format(esc(entry.text)))
    if back then
        client:add(('<container pos="%d,2" size="90,22" color="#2E6BD6FF" hover-color="#4A86F0FF" z-index="6" onclick="%s">' ..
            '<label pos="0,3" size="90,16" text-align="center" color="#FFFFFFFF" interactive="false">назад</label></container>')
            :format(self.client_rect[3] - 100, action(self.uid, "app", "back")))
    end
    local status = self:el("pc_video_status")
    local function show(frame)
        if frame.width ~= cw or frame.height ~= ch then
            cw, ch = frame.width, frame.height
            local old = self:el(canvas_id)
            if old and old.exists then old:destruct() end
            if image and image.exists then image:destruct() end
            self.root:add(('<canvas id="%s" size="%d,%d" visible="false"/>'):format(canvas_id, cw, ch))
            self:el(canvas_id).data:create_texture(texture)
            local cs = client.size
            local scale = math.min(cs[1] / cw, (cs[2] - 26) / ch)
            if scale >= 1 then scale = math.floor(scale) end
            client:add(('<image id="pc_video_image" src="%s" size="%d,%d" gravity="center-center" region="0,1,1,0"/>')
                :format(texture, math.floor(cw * scale), math.floor(ch * scale)))
            image = self:el("pc_video_image")
            log(("video %s %dx%d, x%.2f"):format(entry.text, cw, ch, scale))
        end
        local canvas = self:el(canvas_id)
        canvas.data:set_data(frame.rgba)
        canvas.data:update()
    end
    local t0 = time.uptime()
    local space_was = false
    function v.tick()
        -- пробел: пауза (только за компьютером)
        local space = active == self and not self.minimized and input.is_pressed("key:space")
        if space and not space_was then
            v.playing = not v.playing
            t0 = time.uptime() - v.shown * session.frame_duration
            log(("video %s at frame %d"):format(v.playing and "resume" or "pause", v.shown))
            if status and status.exists and not v.playing then status.text = status.text .. "   пауза" end
        end
        space_was = space
        if not v.playing then return end
        session:begin_slice(VIDEO_SLICE)
        local ok2, err = coroutine.resume(worker)
        if not ok2 then
            log("video decode error: " .. tostring(err))
            v.playing = false
            return
        end
        local now = time.uptime()
        local due = t0 + v.shown * session.frame_duration
        if #v.queue > 0 and now >= due then
            if now - due > 0.5 then t0 = now - v.shown * session.frame_duration end  -- отстали: без рывка
            local frame = table.remove(v.queue, 1)
            show(frame)
            v.shown = v.shown + 1
            v.fps_n = v.fps_n + 1
            if now - v.fps_t >= 5 then
                local fps = v.fps_n / (now - v.fps_t)
                log(("video %s: %.1f fps, frame %d/%d"):format(entry.text, fps, frame.frame_index + 1, session.sample_count))
                v.fps_t, v.fps_n = now, 0
            end
            if status and status.exists then
                status.text = ("%s   кадр %d/%d   %s"):format(entry.text, frame.frame_index + 1, session.sample_count,
                    v.playing and "" or "пауза")
            end
        end
    end
    function v.stop()
        v.playing = false
        pcall(function() require("wasmrt:host").set_jit_tuned(false) end)
        pcall(function() if image and image.exists then image:destruct() end end)
        pcall(function() local c = self:el(canvas_id); if c and c.exists then c:destruct() end end)
    end
    running.video = v
    running.videos = nil
    log("video opened " .. entry.value .. ": " .. session.sample_count .. " samples")
end

-- Режим «Minecraft (shader)»: текстура экрана — canvas ShaderToy (hooks.on_shader из pc.lua).
function PC:set_shader(on)
    if self.shader_on == on then return end
    self.shader_on = on
    if self.hooks.on_shader then self.hooks.on_shader(self, on) end
    if on then
        gui.set_active_frame("")
    else
        self.entity.skeleton:set_texture("$0", self.texture)
        if active == self then self:activate_frame() end
    end
end

---------------------------------------------------------------------------------------------------
-- Встроенные программы: Проводник, Paint, Корзина, Настройки. Общее окно; running.app_local =
-- { tick(dt), stop(), event(cmd, arg) }; кнопки документа — action(uid, "app", "cmd:arg").
---------------------------------------------------------------------------------------------------
local function btn(uid, x, y, w, text, cmd, color)
    return ('<container pos="%d,%d" size="%d,22" color="%s" hover-color="#4A86F0FF" onclick="%s">' ..
        '<label pos="0,3" size="%d,16" text-align="center" color="#FFFFFFFF" interactive="false">%s</label></container>')
        :format(x, y, w, color or "#2E6BD6FF", action(uid, "app", cmd), w, esc(text))
end

local PLACES = {
    { id = "config", title = "config:", root = "config:" },
    { id = "export", title = "export:", root = "export:" },
    { id = "screenshots", title = "screenshots", root = "user:screenshots" },
}
local FS_ROWS = 19

local function list_dir(path)
    local ok, names = pcall(file.list, path)
    if not ok or type(names) ~= "table" then return nil, tostring(names) end
    local dirs, files = {}, {}
    for _, p in ipairs(names) do
        local name = basename(p)
        local isdir = false
        pcall(function() isdir = file.isdir(p) end)
        local size = 0
        if not isdir then pcall(function() size = file.length(p) end) end
        local e = { path = p, name = name, dir = isdir, size = size }
        if isdir then dirs[#dirs + 1] = e else files[#files + 1] = e end
    end
    table.sort(dirs, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    for _, f in ipairs(files) do dirs[#dirs + 1] = f end
    return dirs
end

local function fmt_size(n)
    if n >= 1048576 then return ("%.1f МБ"):format(n / 1048576) end
    if n >= 1024 then return ("%.1f КБ"):format(n / 1024) end
    return tostring(n) .. " Б"
end

-- Проводник: place — индекс PLACES, path — текущий каталог ("config:dir/sub").
function PC:start_explorer(prog, place, path)
    if running and running.pc == self and running.video then running.video.stop(); running.video = nil end
    local client = self:open_window(prog)
    local st = self.fs or { place = 1, page = 1 }
    self.fs = st
    st.place = place or st.place
    local pl = PLACES[st.place]
    st.path = path or st.path or pl.root
    if st.path:sub(1, #pl.root) ~= pl.root then st.path = pl.root end
    local uid, cr = self.uid, self.client_rect
    local cw, chh = cr[3], cr[4]
    -- боковая панель с местами
    client:add(('<container pos="0,0" size="160,%d" color="#EEF2FAFF" interactive="false"/>'):format(chh))
    client:add(('<label pos="10,8" size="140,16" color="#1E3287FF" interactive="false">Места</label>'))
    for i, p in ipairs(PLACES) do
        client:add(('<container pos="6,%d" size="148,26" color="%s" hover-color="#9CC2FFFF" onclick="%s">' ..
            '<image src="%s" pos="4,5" size="16,16" interactive="false"/>' ..
            '<label pos="26,5" size="120,16" color="#000000FF" interactive="false">%s</label></container>')
            :format(30 + (i - 1) * 30, i == st.place and "#B9D3FFFF" or "#00000000", action(uid, "app", "place:" .. i),
                tex.icon("s_folder"), esc(p.title)))
    end
    -- адресная строка и «вверх»
    client:add(('<container pos="160,0" size="%d,%d" color="#FFFFFFFF" interactive="false"/>'):format(cw - 160, chh))
    client:add(('<container pos="166,4" size="26,22" color="#DDE6F5FF" hover-color="#9CC2FFFF" onclick="%s">' ..
        '<image src="%s" pos="5,3" size="16,16" interactive="false"/></container>')
        :format(action(uid, "app", "up"), tex.icon("s_up")))
    client:add(('<label id="fs_path" pos="200,7" size="%d,16" color="#000000FF" interactive="false">%s</label>')
        :format(cw - 420, esc(st.path)))
    client:add(btn(uid, cw - 212, 4, 100, "обновить", "refresh", "#5A7FB8FF"))
    client:add(btn(uid, cw - 106, 4, 100, "в корзину", "trash_sel", "#B04030FF"))
    client:add(('<label id="fs_status" pos="166,%d" size="%d,16" color="#404040FF" interactive="false"></label>')
        :format(chh - 22, cw - 180))
    local entries, err = list_dir(st.path)
    if not entries then
        if not file.isdir(st.path) then err = "каталога нет: " .. st.path end
        client:add(('<label pos="200,40" size="%d,18" color="#A00000FF" interactive="false">%s</label>'):format(cw - 220, esc(err)))
        st.entries = {}
        log(("explorer %s: %s"):format(st.path, err))
    else
        st.entries = entries
        local pages = math.max(1, math.ceil(#entries / FS_ROWS))
        st.page = clamp(st.page or 1, 1, pages)
        local first = (st.page - 1) * FS_ROWS
        for i = 1, FS_ROWS do
            local e = entries[first + i]
            if not e then break end
            local idx = first + i
            local icon = e.dir and "s_folder" or ({ png = "s_image", mp4 = "s_video" })[ext_of(e.name)] or "s_file"
            client:add(('<container id="fs_row_%d" pos="166,%d" size="%d,24" color="%s" hover-color="#CFE0FFFF" onclick="%s" ondoubleclick="%s">' ..
                '<image src="%s" pos="4,4" size="16,16" interactive="false"/>' ..
                '<label pos="28,4" size="%d,16" color="#000000FF" interactive="false">%s</label>' ..
                '<label pos="%d,4" size="110,16" text-align="right" color="#606060FF" interactive="false">%s</label></container>')
                :format(idx, 32 + (i - 1) * 26, cw - 176, st.selected == idx and "#B9D3FFFF" or "#00000000",
                    action(uid, "app", "sel:" .. idx), action(uid, "app", "open:" .. idx),
                    tex.icon(icon), cw - 330, esc(e.name), cw - 300, e.dir and "папка" or fmt_size(e.size)))
        end
        if pages > 1 then
            client:add(btn(uid, cw - 230, chh - 26, 60, "<", "page:-1", "#5A7FB8FF"))
            client:add(('<label pos="%d,%d" size="60,16" text-align="center" color="#000000FF" interactive="false">%d/%d</label>')
                :format(cw - 166, chh - 22, st.page, pages))
            client:add(btn(uid, cw - 100, chh - 26, 60, ">", "page:1", "#5A7FB8FF"))
        end
        log(("explorer %s: %d entries (page %d/%d)"):format(st.path, #entries, st.page, pages))
    end
    local pc = self
    running = { pc = self, prog = prog, app_local = {
        event = function(cmd, arg) pc:explorer_event(cmd, arg) end,
    } }
end

function PC:fs_status(text)
    local l = self:el("fs_status")
    if l and l.exists then l.text = text end
    log("explorer: " .. text)
end

-- Файл -> корзина (config:pc_wasmrt/trash/): копия + удаление; запись в индексе хранит исходный путь.
function PC:trash_file(path)
    local name = basename(path)
    local ok, err = pcall(function()
        file.mkdirs(TRASH_DIR)
        local idx = trash_index()
        local stored = name
        local n = 1
        while file.exists(TRASH_DIR .. "/" .. stored) do n = n + 1; stored = n .. "_" .. name end
        file.write_bytes(TRASH_DIR .. "/" .. stored, file.read_bytes(path))
        file.remove(path)
        idx[#idx + 1] = { name = stored, from = path }
        save_trash_index(idx)
    end)
    if ok then
        log(("file %s -> trash"):format(path))
        for _, pc in pairs(pcs) do pc:update_trash_icon() end
        return true
    end
    log(("trash %s failed: %s"):format(path, tostring(err)))
    return false, tostring(err)
end

function PC:explorer_event(cmd, arg)
    local st = self.fs
    local prog = BY_ID.explorer
    if cmd == "place" then
        local i = tonumber(arg) or 1
        st.place, st.path, st.page, st.selected = i, PLACES[i].root, 1, nil
        self:start_explorer(prog)
    elseif cmd == "up" then
        local pl = PLACES[st.place]
        if st.path ~= pl.root then
            st.path = st.path:match("^(.*)/[^/]+$") or pl.root
            if st.path == "" or st.path:sub(-1) == ":" then st.path = pl.root end
        end
        st.page, st.selected = 1, nil
        self:start_explorer(prog)
    elseif cmd == "refresh" then
        self:start_explorer(prog)
    elseif cmd == "page" then
        st.page = (st.page or 1) + (tonumber(arg) or 0)
        self:start_explorer(prog)
    elseif cmd == "sel" then
        local idx = tonumber(arg)
        if time.uptime() - (self.action_t or 0) > 0.4 then
            st.selected = idx
            for i = 1, #st.entries do
                local row = self:el("fs_row_" .. i)
                if row and row.exists then row.color = i == idx and { 185, 211, 255, 255 } or { 0, 0, 0, 0 } end
            end
        end
    elseif cmd == "open" then
        local e = st.entries[tonumber(arg) or 0]
        if not e then return end
        self.action_t = time.uptime()
        if e.dir then
            st.path, st.page, st.selected = e.path, 1, nil
            self:start_explorer(prog)
        else
            self:open_file(e.path)
        end
    elseif cmd == "trash_sel" then
        local e = st.entries[st.selected or 0]
        if not e then self:fs_status("выберите файл") return end
        if e.dir then self:fs_status("папки в корзину не переносятся") return end
        local ok, err = self:trash_file(e.path)
        if ok then st.selected = nil; self:start_explorer(prog); self:fs_status(e.name .. " - в корзине")
        else self:fs_status("не удалось: " .. err) end
    elseif cmd == "back" then
        -- из просмотра/видео назад в список (видео остановить)
        if running and running.video then running.video.stop(); running.video = nil end
        self:start_explorer(prog)
    end
end

-- Открыть файл двойным кликом: .png — просмотр в окне, .mp4 — видео в окне (videoplayer:decoder).
function PC:open_file(path)
    local ext = ext_of(path)
    if ext == "png" then
        self:view_image(path)
    elseif ext == "mp4" then
        local ok, err = pcall(require, "videoplayer:decoder")
        if not ok then self:fs_status("пак videoplayer не включён: " .. tostring(err)) return end
        log("explorer open video " .. path)
        self:play_video_entry({ value = path, text = basename(path) }, true)
    else
        self:fs_status("нечем открыть " .. basename(path))
    end
end

function PC:view_image(path)
    local client = self:el("win_client")
    local cr = self.client_rect
    local ok, canvas = pcall(function() return Canvas.decode(file.read_bytes(path), "png") end)
    if not ok or not canvas then
        self:fs_status("не удалось открыть " .. basename(path) .. ": " .. tostring(canvas))
        return
    end
    client:clear()
    local texname = "pc_wasmrt_pc_view_" .. self.uid
    canvas:create_texture(texname)
    self.view_canvas = canvas  -- холст живёт вместе с текстурой
    local iw, ih = canvas.width, canvas.height
    local scale = math.min((cr[3] - 16) / iw, (cr[4] - 40) / ih)
    if scale >= 1 then scale = math.floor(scale) end
    local dw, dh = math.floor(iw * scale), math.floor(ih * scale)
    client:add(('<label pos="8,6" size="%d,16" color="#000000FF" interactive="false">%s   %dx%d</label>')
        :format(cr[3] - 120, esc(basename(path)), iw, ih))
    client:add(btn(self.uid, cr[3] - 100, 3, 90, "назад", "back"))
    -- текстура из Canvas.decode + create_texture не перевёрнута (в отличие от data элемента <canvas>): без region
    client:add(('<image src="%s" pos="%d,%d" size="%d,%d" interactive="false"/>')
        :format(texname, math.floor((cr[3] - dw) / 2), 30 + math.floor((cr[4] - 30 - dh) / 2), dw, dh))
    client.color = { 230, 230, 230, 255 }
    log(("explorer view %s %dx%d x%.2f"):format(path, iw, ih, scale))
    self.fs_viewing = path
end

-- Paint: холст PAINT_W x PAINT_H (скрытый <canvas> -> текстура -> <image>), кисть по проекции курсора.
local PAINT_COLORS = {
    { 0, 0, 0 }, { 128, 128, 128 }, { 255, 255, 255 }, { 200, 30, 30 }, { 255, 140, 0 }, { 250, 220, 40 },
    { 40, 170, 60 }, { 0, 200, 200 }, { 30, 90, 230 }, { 130, 50, 200 }, { 240, 110, 180 }, { 120, 70, 30 },
}
local PAINT_SIZES = { 2, 6, 12 }

function PC:start_paint(prog)
    local client = self:open_window(prog)
    local uid, cr = self.uid, self.client_rect
    local canvas_id, texname = "pc_paint_canvas", "pc_wasmrt_pc_paint_" .. self.uid
    local old = self:el(canvas_id)
    if old and old.exists then old:destruct() end
    self.root:add(('<canvas id="%s" size="%d,%d" visible="false"/>'):format(canvas_id, PAINT_W, PAINT_H))
    local cv = self:el(canvas_id)
    local data = cv.data
    data:clear(255, 255, 255, 255)
    data:update()
    data:create_texture(texname)
    local p = { data = data, color = { 0, 0, 0 }, size = 6, color_i = 1, size_i = 2, eraser = false, last = nil,
        dirty = false, strokes = 0, x0 = cr[1] + 8, y0 = cr[2] + 44, saved = nil }
    self.paint = p
    client.color = { 200, 208, 220, 255 }
    -- панель: цвета, размеры, ластик, очистить, сохранить
    for i, c in ipairs(PAINT_COLORS) do
        client:add(('<container id="paint_c%d" pos="%d,8" size="24,24" color="#%02X%02X%02XFF" hover-color="#%02X%02X%02XFF" onclick="%s"/>')
            :format(i, 8 + (i - 1) * 28, c[1], c[2], c[3], c[1], c[2], c[3], action(uid, "app", "color:" .. i)))
    end
    for i, s in ipairs(PAINT_SIZES) do
        client:add(('<container id="paint_s%d" pos="%d,8" size="28,24" color="#FFFFFFFF" hover-color="#CFE0FFFF" onclick="%s">' ..
            '<container pos="%d,%d" size="%d,%d" color="#000000FF" interactive="false"/></container>')
            :format(i, 360 + (i - 1) * 32, action(uid, "app", "size:" .. i), 14 - math.floor(s / 2), 12 - math.floor(s / 2), s, s))
    end
    client:add(btn(uid, 470, 9, 80, "ластик", "eraser", "#5A7FB8FF"))
    client:add(btn(uid, 556, 9, 90, "очистить", "clear", "#5A7FB8FF"))
    client:add(btn(uid, 652, 9, 110, "сохранить", "save", "#2E8B3EFF"))
    client:add(('<label id="paint_status" pos="770,12" size="%d,16" color="#202020FF" interactive="false">кисть 6, чёрный</label>')
        :format(cr[3] - 780))
    client:add(('<image id="paint_img" src="%s" pos="8,44" size="%d,%d" region="0,1,1,0" interactive="false"/>')
        :format(texname, PAINT_W, PAINT_H))
    client:add(('<container id="paint_sel" pos="6,6" size="28,28" color="#00000000" interactive="false"/>'))
    self:paint_select_ui()
    local pc = self
    running = { pc = self, prog = prog, app_local = {
        tick = function(dt) pc:paint_tick(dt) end,
        stop = function()
            pc.paint = nil
            pcall(function() local c = pc:el(canvas_id); if c and c.exists then c:destruct() end end)
        end,
        event = function(cmd, arg) pc:paint_event(cmd, arg) end,
    } }
    log("paint opened " .. PAINT_W .. "x" .. PAINT_H)
end

function PC:paint_select_ui()
    local p = self.paint
    if not p then return end
    local sel = self:el("paint_sel")
    if sel and sel.exists then
        if p.eraser then sel.pos = { 468, 7 } else sel.pos = { 6 + (p.color_i - 1) * 28, 6 } end
        sel.color = { 255, 60, 60, 255 }
    end
    for i = 1, #PAINT_SIZES do
        local b = self:el("paint_s" .. i)
        if b and b.exists then b.color = i == p.size_i and { 185, 211, 255, 255 } or { 255, 255, 255, 255 } end
    end
    local st = self:el("paint_status")
    if st and st.exists then
        st.text = (p.eraser and "ластик " or "кисть ") .. p.size .. (p.saved and ("  " .. basename(p.saved)) or "")
    end
end

function PC:paint_event(cmd, arg)
    local p = self.paint
    if not p then return end
    if cmd == "color" then
        p.color_i = tonumber(arg) or 1
        p.color = PAINT_COLORS[p.color_i] or { 0, 0, 0 }
        p.eraser = false
    elseif cmd == "size" then
        p.size_i = tonumber(arg) or 2
        p.size = PAINT_SIZES[p.size_i] or 6
    elseif cmd == "eraser" then
        p.eraser = not p.eraser
    elseif cmd == "clear" then
        p.data:clear(255, 255, 255, 255)
        p.data:update()
        p.strokes = 0
        log("paint cleared")
    elseif cmd == "save" then
        local ok, err = pcall(function()
            file.mkdirs(PAINT_DIR)
            local n = 1
            while file.exists(("%s/paint_%d.png"):format(PAINT_DIR, n)) do n = n + 1 end
            local path = ("%s/paint_%d.png"):format(PAINT_DIR, n)
            local bytes = p.data:encode("png")
            file.write_bytes(path, bytes)
            p.saved = path
            M.last_saved = path
            log(("paint saved %s (%d bytes, %d strokes)"):format(path, file.length(path), p.strokes))
        end)
        if not ok then log("paint save failed: " .. tostring(err)); p.saved = "ошибка: " .. tostring(err) end
    end
    self:paint_select_ui()
end

local function stamp(data, x, y, s, c)
    local x0, y0 = clamp(math.floor(x - s / 2), 0, PAINT_W - s), clamp(math.floor(y - s / 2), 0, PAINT_H - s)
    data:rect(x0, y0, s, s, c[1], c[2], c[3], 255)
end

function PC:paint_tick(dt)
    local p = self.paint
    if not p or self.minimized or active ~= self then return end
    local c = self.cursor
    local pressed = input.is_pressed("mouse:left")
    if pressed and c then
        local x, y = c[1] - p.x0, c[2] - p.y0
        local inside = x >= 0 and y >= 0 and x < PAINT_W and y < PAINT_H
        if inside or p.last then
            x, y = clamp(x, 0, PAINT_W - 1), clamp(y, 0, PAINT_H - 1)
            local col = p.eraser and { 255, 255, 255 } or p.color
            if p.last then
                local lx, ly = p.last[1], p.last[2]
                local n = math.max(1, math.ceil(math.max(math.abs(x - lx), math.abs(y - ly)) / math.max(1, p.size / 3)))
                for i = 1, n do stamp(p.data, lx + (x - lx) * i / n, ly + (y - ly) * i / n, p.size, col) end
            else
                stamp(p.data, x, y, p.size, col)
                p.strokes = p.strokes + 1
            end
            p.last = { x, y }
            p.dirty = true
        end
    else
        p.last = nil
    end
    if p.dirty then p.data:update(); p.dirty = false end
end

-- Корзина: ярлыки и файлы, восстановление, очистка.
function PC:start_trash(prog)
    local client = self:open_window(prog)
    local uid, cr = self.uid, self.client_rect
    client.color = { 255, 255, 255, 255 }
    local y = 10
    client:add(('<label pos="12,%d" size="400,18" color="#1E3287FF" interactive="false">Ярлыки</label>'):format(y))
    y = y + 24
    if #config.trash == 0 then
        client:add(('<label pos="24,%d" size="400,16" color="#606060FF" interactive="false">нет</label>'):format(y))
        y = y + 24
    end
    for i, id in ipairs(config.trash) do
        local prog2 = BY_ID[id]
        client:add(('<container pos="12,%d" size="%d,26" color="#F4F6FAFF" interactive="false">' ..
            '<image src="%s" pos="4,5" size="16,16" interactive="false"/>' ..
            '<label pos="28,5" size="300,16" color="#000000FF" interactive="false">%s</label></container>')
            :format(y, cr[3] - 160, (prog2 and prog_icon(prog2)) or "gui/error", esc(prog2 and prog2.title or id)))
        client:add(btn(uid, cr[3] - 140, y + 2, 130, "восстановить", "restore_icon:" .. i, "#2E8B3EFF"))
        y = y + 30
    end
    y = y + 10
    client:add(('<label pos="12,%d" size="400,18" color="#1E3287FF" interactive="false">Файлы (%s)</label>'):format(y, TRASH_DIR))
    y = y + 24
    local idx = trash_index()
    if #idx == 0 then
        client:add(('<label pos="24,%d" size="400,16" color="#606060FF" interactive="false">нет</label>'):format(y))
        y = y + 24
    end
    for i, e in ipairs(idx) do
        if y > cr[4] - 60 then break end
        client:add(('<container pos="12,%d" size="%d,26" color="#F4F6FAFF" interactive="false">' ..
            '<image src="%s" pos="4,5" size="16,16" interactive="false"/>' ..
            '<label pos="28,5" size="%d,16" color="#000000FF" interactive="false">%s</label></container>')
            :format(y, cr[3] - 160, tex.icon("s_file"), cr[3] - 200, esc(e.name .. "   <-  " .. (e.from or "?"))))
        client:add(btn(uid, cr[3] - 140, y + 2, 130, "восстановить", "restore_file:" .. i, "#2E8B3EFF"))
        y = y + 30
    end
    client:add(btn(uid, 12, cr[4] - 34, 180, "очистить корзину", "empty", "#B04030FF"))
    client:add(('<label id="trash_status" pos="200,%d" size="%d,16" color="#404040FF" interactive="false"></label>')
        :format(cr[4] - 30, cr[3] - 220))
    local pc = self
    running = { pc = self, prog = prog, app_local = { event = function(cmd, arg) pc:trash_event(cmd, arg) end } }
    log(("trash opened: %d icons, %d files"):format(#config.trash, #idx))
end

function PC:trash_event(cmd, arg)
    local prog = BY_ID.trash
    if cmd == "restore_icon" then
        local id = config.trash[tonumber(arg) or 0]
        if id then self:trash_icon(id, false) end
        self:start_trash(prog)
    elseif cmd == "restore_file" then
        local idx = trash_index()
        local e = idx[tonumber(arg) or 0]
        if e then
            local ok, err = pcall(function()
                local src = TRASH_DIR .. "/" .. e.name
                local dst = e.from
                local dir = dst:match("^(.*)/[^/]+$")
                if dir and dir:sub(-1) ~= ":" then file.mkdirs(dir) end
                file.write_bytes(dst, file.read_bytes(src))
                file.remove(src)
                table.remove(idx, tonumber(arg))
                save_trash_index(idx)
            end)
            log(("restore %s -> %s: %s"):format(e.name, e.from, ok and "ok" or tostring(err)))
        end
        for _, pc in pairs(pcs) do pc:update_trash_icon() end
        self:start_trash(prog)
    elseif cmd == "empty" then
        local idx = trash_index()
        local removed = 0
        for _, e in ipairs(idx) do
            if pcall(file.remove, TRASH_DIR .. "/" .. e.name) then removed = removed + 1 end
        end
        pcall(save_trash_index, {})
        config.trash = {}
        save_config()
        for _, pc in pairs(pcs) do pc:update_trash_icon() end
        log(("trash emptied: %d files removed, icons cleared"):format(removed))
        self:start_trash(prog)
        local st = self:el("trash_status")
        if st and st.exists then st.text = "корзина очищена" end
    end
end

-- Настройки: камера к ПК при входе, лок мыши при входе (по умолчанию выключены), сброс ярлыков.
function PC:start_settings(prog)
    local client = self:open_window(prog)
    local uid = self.uid
    client.color = { 255, 255, 255, 255 }
    local function row(y, key, text)
        local on = config.options[key] == true
        client:add(('<container id="opt_%s" pos="12,%d" size="520,28" color="#F4F6FAFF" hover-color="#CFE0FFFF" onclick="%s">' ..
            '<container pos="6,5" size="18,18" color="#FFFFFFFF" interactive="false"><container pos="3,3" size="12,12" color="%s" interactive="false"/></container>' ..
            '<label pos="34,6" size="480,16" color="#000000FF" interactive="false">%s</label></container>')
            :format(key, y, action(uid, "app", "toggle:" .. key), on and "#1E5AD0FF" or "#FFFFFFFF", esc(text)))
    end
    client:add('<label pos="12,10" size="500,18" color="#1E3287FF" interactive="false">Камера и мышь при входе за компьютер (ПКМ)</label>')
    row(36, "attach_camera", "притягивать камеру к экрану (иначе камера остаётся на месте)")
    row(68, "mouse_lock", "запирать курсор в экране (иначе курсор свободно уходит с экрана)")
    client:add(('<label pos="12,104" size="700,16" color="#404040FF" interactive="false">Кнопки под экраном: «залочить мышь» включает оба режима, «приблизить» - зум (%.2f).</label>')
        :format(tonumber(config.options.zoom) or 1))
    client:add(btn(uid, 12, 140, 220, "сбросить позиции ярлыков", "reset_icons", "#5A7FB8FF"))
    client:add(('<label pos="12,180" size="700,16" color="#404040FF" interactive="false">Файл: %s</label>'):format(CONFIG_PATH))
    local pc = self
    running = { pc = self, prog = prog, app_local = { event = function(cmd, arg) pc:settings_event(cmd, arg) end } }
end

function PC:settings_event(cmd, arg)
    if cmd == "toggle" then
        config.options[arg] = not (config.options[arg] == true)
        save_config()
        log(("option %s = %s"):format(arg, tostring(config.options[arg])))
        self:start_settings(BY_ID.settings)
    elseif cmd == "reset_icons" then
        config.icons = {}
        for _, pc in pairs(pcs) do
            for _, prog in ipairs(PROGRAMS) do
                if not prog.menu_only then local d = pc:icon_default_pos(prog.id); pc:set_icon_pos(prog.id, d[1], d[2]) end
            end
        end
        save_config()
        log("icon positions reset")
    end
end

function PC:launch(id)
    local prog = BY_ID[id]
    if not prog then return end
    self:show_startmenu(false)
    self:select(nil)
    if running then
        if running.pc == self and running.prog == prog and not running.message and not prog.builtin then
            self:set_minimized(false)
            return
        end
        M.close_program()
    end
    if not prog.builtin and not pack.is_installed(prog.pack) then
        self:message(prog, { ("Пак %s не включён в этом мире."):format(prog.pack),
            "Включите его в настройках мира (packs.list) и откройте ярлык снова." })
        return
    end
    log("launch " .. id .. " on pc " .. self.uid)
    self.action_t = time.uptime()
    if id == "video" then
        self:start_video(prog)
    elseif id == "shader" then
        running = { pc = self, prog = prog, shader = true }
        self:set_shader(true)
    elseif id == "explorer" then
        self:start_explorer(prog)
    elseif id == "paint" then
        self:start_paint(prog)
    elseif id == "trash" then
        self:start_trash(prog)
    elseif id == "settings" then
        self:start_settings(prog)
    elseif prog.server then
        self:start_eaglercraft(prog)
    else
        self:start_wasm(prog, prog.manifest)
    end
end

---------------------------------------------------------------------------------------------------
-- Кадр
---------------------------------------------------------------------------------------------------
function PC:tick(dt)
    self:update_clock()
    if self.eag_wait then self.eag_wait() end
    local r = running
    if r and r.pc == self then
        if r.app then
            r.app:tick()
            if r.app.status ~= "running" and not r.reported then
                r.reported = true
                log(("%s: %s %s"):format(r.prog.id, tostring(r.app.status), tostring(r.app.message)))
                -- программа завершилась или упала: сообщение в её окне (стек — в логе, [wasmrt] crash)
                pcall(function() r.app:stop() end)
                self:message(r.prog, { r.prog.title .. ": " .. (r.app.status == "error" and "ошибка" or "программа завершилась"),
                    tostring(r.app.message):sub(1, 110) })
            end
        elseif r.video then
            r.video.tick()
        end
        if r.app_local and r.app_local.tick then r.app_local.tick(dt) end
    end
    if active ~= self then return end
    player.set_pos(self.pid, unpack(self.lock_pos))
    player.set_rot(self.pid, unpack(self.lock_rot))
    -- курсор-стрелка на экране (курсор ОС в мире рисуется поверх, на снимках окна его нет)
    local grabbed = r and r.app and r.app.grab and r.app.grab.on
    if not grabbed and not self.shader_on then
        self:route_mouse()
        -- Right Ctrl (как host key у dagger_pc): залочить/отпустить мышь без кнопки
        local rc = input.is_pressed("key:right-ctrl")
        if rc and not self.rctrl_was then self:set_locked(not self.locked) end
        self.rctrl_was = rc
    end
    local c = self.cursor
    local el = self:el("cursor")
    if c and not grabbed and not self.shader_on then el.pos = { math.floor(c[1]), math.floor(c[2]) }
    else el.pos = { -40, -40 } end
    if not grabbed and not self.shader_on and not self.frame_main then self:drag_tick() end
    -- удержание Esc 1 с: встать из-за компьютера в любом состоянии — программа продолжает идти
    -- на экране, на неё можно посмотреть со стороны (свернуть — кнопкой «_» в окне)
    if input.is_pressed("key:escape") then
        self.esc_t = (self.esc_t or 0) + dt
        if self.esc_t >= 1.0 then
            self.esc_t = -1000
            if r and r.pc == self and r.app and r.app.set_grab then r.app.set_grab(false) end
            log("esc held: leave pc " .. self.uid)
            self:leave()
            return
        end
    else
        self.esc_t = 0
    end
end

-- Кнопки документа фрейма.
events.reset("pc_wasmrt:pc_ui", function(uid, name, arg)
    local pc = pcs[uid]
    log(("ui %s %s %s"):format(tostring(uid), tostring(name), tostring(arg)))
    if not pc then return end
    if name == "launch" then pc:launch(arg)
    elseif name == "select" then
        -- щелчок, пришедший вместе с запуском/закрытием (второй щелчок двойного), не выделяет ярлык
        if time.uptime() - (pc.action_t or 0) > 0.4 then pc:show_startmenu(false); pc:select(arg) end
    elseif name == "desktop" then pc:show_startmenu(false); pc:select(nil)
    elseif name == "start" then pc:show_startmenu()
    elseif name == "close" then M.close_program()
    elseif name == "minimize" then pc:set_minimized(true)
    elseif name == "task" then
        if running and running.pc == pc then pc:set_minimized(not pc.minimized) end
    elseif name == "video" then pc:play_video(tonumber(arg))
    elseif name == "lock" then pc:set_locked(not pc.locked)
    elseif name == "zoom" then pc:toggle_zoom()
    elseif name == "app" then
        local cmd, a = arg:match("^([%w_]+):?(.*)$")
        if running and running.pc == pc and running.app_local and running.app_local.event then
            running.app_local.event(cmd, a)
        end
    elseif name == "shutdown" then pc:show_startmenu(false); pc:leave()
    end
end)

-- Esc (scripts/hud.lua, обработчик после движкового: вызывается раньше него).
function M.on_escape()
    local pc = active
    if not pc then
        -- полторы секунды после выхода из-за компьютера Esc «съедается»: он ещё зажат после удержания
        return time.uptime() - (M.leave_t or -10) < 1.5
    end
    local r = running
    if pc.shader_on then
        M.close_program()
        return true
    end
    if r and r.pc == pc and not pc.minimized and not r.message and not r.app_local then
        return true  -- Esc у программы (она опрашивает клавишу сама)
    end
    if r and r.pc == pc and (r.message or r.app_local) and not pc.minimized then
        M.close_program()
        return true
    end
    if pc:el("startmenu").visible then
        pc:show_startmenu(false)
        return true
    end
    pc:leave()
    return true
end

function M.shutdown()
    M.close_program()
    if active then active:leave() end
end

---------------------------------------------------------------------------------------------------
-- XML-оверлей вокруг экрана (layouts/pc_overlay.xml + .xml.lua) и стикер «ПКМ — сесть» (layouts/pc_hint.xml).
-- Приём dagger_pc: окно компьютера — hud.show_overlay(layout, false, args), закрытие — hud.close(layout);
-- стикер-подсказка у кромки монитора. Здесь оверлей не содержит экрана (он — фрейм в текстуре на модели),
-- а только кнопки и стикеры в нижней полосе окна (под экраном при зуме 1, HUD_RESERVE).
---------------------------------------------------------------------------------------------------
M.overlay = nil        -- { refresh = fn, rects = { standup = {x,y,w,h}, lock = ..., zoom = ... }, texts = {...} }
M.hint_shown = false   -- стикер «ПКМ — сесть за компьютер» сейчас показан (pc_hint.xml.lua)

function M.open_overlay(pc)
    if type(hud) ~= "table" or type(hud.show_overlay) ~= "function" then return false end
    local ok, err = pcall(hud.show_overlay, OVERLAY_ID, false, { pc.uid })
    if not ok then log("overlay open failed: " .. tostring(err)) end
    return ok
end

function M.overlay_is_open()
    if type(hud) ~= "table" then return false end
    local ok, open = pcall(hud.is_open, OVERLAY_ID)
    return ok and open == true
end

function M.close_overlay()
    if M.overlay_closing or not M.overlay_is_open() then return end
    local ok, err = pcall(hud.close, OVERLAY_ID)
    if not ok then log("overlay close failed: " .. tostring(err)) end
end

-- Из on_open оверлея: документ привязан (refresh/rects/texts заполняет скрипт layout'а).
function M.overlay_attach(ov)
    M.overlay = ov
    log("overlay attached")
end

-- Из on_close оверлея. Если его закрыл не PC:leave (F1, другой оверлей, hud.close_inventory) — игрок
-- встаёт из-за компьютера, чтобы состояние не разъехалось (курсор, привязки, камера).
function M.overlay_detach()
    M.overlay = nil
    log("overlay detached" .. (active and " (closed from outside: leave)" or ""))
    if active then
        M.overlay_closing = true   -- hud.close изнутри on_close не нужен (элемент уже снимается)
        local ok, err = pcall(function() active:leave() end)
        M.overlay_closing = false
        if not ok then log("leave after overlay close failed: " .. tostring(err)) end
    end
end

-- Кнопки оверлея: onclick="ov_action('standup'|'lock'|'zoom')".
function M.overlay_action(name)
    local pc = active
    if not pc then return end
    log("overlay action " .. tostring(name))
    if name == "standup" then pc:leave()
    elseif name == "lock" then pc:set_locked(not pc.locked)
    elseif name == "zoom" then pc:toggle_zoom()
    end
end

-- Тексты стикеров и кнопок по текущему состоянию (короткие, с режимом).
function M.overlay_texts()
    local pc = active
    local near = pc ~= nil and pc.zoom > 0.5
    local locked = pc ~= nil and pc.mouse_lock
    return {
        cam = near and "камера: у экрана (поз/рот лок)" or "камера: на месте (поз/рот лок)",
        mouse = locked and "мышь: заперта в экране" or "мышь: свободная",
        keys = "Esc - встать · Right Ctrl - лок мыши",
        hold = "в программе: Esc удержать 1 с",
        lock_btn = locked and "отпустить мышь" or "залочить мышь",
        zoom_btn = near and "отдалить" or "приблизить",
        standup_btn = "встать",
    }
end

function M.overlay_state()
    local ov = M.overlay
    if not ov then return nil end
    return { rects = ov.rects, texts = ov.texts, viewport = ov.viewport }
end

-- Мышь над кнопкой оверлея (координаты окна)? Тогда активным должен быть core:main, чтобы клик дошёл.
function M.mouse_over_overlay()
    local ov = M.overlay
    if not ov or not ov.rects then return false end
    local mp = input.get_mouse_pos()
    for _, r in pairs(ov.rects) do
        if mp[1] >= r.x and mp[1] < r.x + r.w and mp[2] >= r.y and mp[2] < r.y + r.h then return true end
    end
    return false
end

-- Стикер «ПКМ — сесть за компьютер» нужен, когда игрок не за ПК и смотрит на компьютер.
function M.hint_wanted()
    if active then return false end
    local pid = 0
    if type(hud) == "table" and type(hud.get_player) == "function" then
        local ok, p = pcall(hud.get_player)
        if ok and p then pid = p end
    end
    local ok, uid = pcall(player.get_selected_entity, pid)
    return ok and uid ~= nil and pcs[uid] ~= nil
end

---------------------------------------------------------------------------------------------------
-- Обработчик F2F для тестов лаборатории (тестовая сборка движка; в стоковом движке f2f нет).
-- Команда "pc": {op="state"} — состояние; {op="map", x, y} — точка фрейма -> координаты окна;
-- {op="launch", id}, {op="enter"}, {op="leave"}, {op="lock", on}, {op="zoom", value}, {op="open", path}.
-- Регистрируется из главного состояния Lua (scripts/world.lua on_world_open).
---------------------------------------------------------------------------------------------------
function M.f2f_handle(args)
    args = args or {}
    local op = args.op or "state"
    local pc = active
    if not pc then
        local uid = tonumber(args.uid)
        if uid then pc = pcs[uid] else for _, p in pairs(pcs) do pc = pc or p end end
    end
    if op == "state" then
        local icons = {}
        for id, p in pairs(pc and pc.icon_pos or {}) do icons[id] = { x = p[1], y = p[2], visible = not in_trash(id) } end
        local r = running
        return {
            uid = pc and pc.uid, active = pc ~= nil and active == pc, zoom = pc and pc.zoom, locked = pc and pc.locked,
            mouse_lock = pc and pc.mouse_lock, cursor = pc and pc.cursor, icons = icons, trash = config.trash,
            trash_files = #trash_index(), running = r and r.prog.id, window = pc and pc:el("win").visible,
            win_title = pc and pc:el("win_title").text, startmenu = pc and pc:el("startmenu").visible,
            options = config.options, last_saved = M.last_saved, fs_path = pc and pc.fs and pc.fs.path,
            fs_entries = pc and pc.fs and pc.fs.entries and #pc.fs.entries, fs_viewing = pc and pc.fs_viewing,
            paint_strokes = pc and pc.paint and pc.paint.strokes, camera = pc and pc.pid and player.get_camera(pc.pid),
            win_rect = pc and pc.win_rect, client_rect = pc and pc.client_rect,
            -- оверлей (layouts/pc_overlay.xml): открыт ли, прямоугольники кнопок в окне, тексты стикеров; режим
            -- инвентаря движка (= хотбар и прицел спрятаны); какой фрейм активен; стикер «ПКМ — сесть»
            overlay_open = M.overlay_is_open(), inventory_open = hud.is_inventory_open(),
            overlay = M.overlay_state(), frame = pc and (pc.frame_main and "main" or "pc"),
            hint_visible = M.hint_shown == true, hint_wanted = M.hint_wanted(),
        }
    elseif op == "map" then
        if not pc then return { error = "no pc" } end
        local x, y = pc:to_window(tonumber(args.x) or 0, tonumber(args.y) or 0)
        return { x = x, y = y }
    elseif op == "launch" then
        if pc then pc:launch(tostring(args.id)) end
        return { running = running and running.prog.id }
    elseif op == "enter" then
        if pc then pc:enter(0) end
        return { active = active ~= nil }
    elseif op == "leave" then
        if pc then pc:leave() end
        return { active = active ~= nil }
    elseif op == "lock" then
        if pc then pc:set_locked(args.on ~= false) end
        return { locked = pc and pc.locked, zoom = pc and pc.zoom }
    elseif op == "zoom" then
        if pc then pc:set_zoom(tonumber(args.value) or 1, true) end
        return { zoom = pc and pc.zoom }
    elseif op == "zoom_toggle" then
        if pc then pc:toggle_zoom() end
        return { zoom = pc and pc.zoom }
    elseif op == "open" then
        if pc and running and running.pc == pc and pc.fs then pc:open_file(tostring(args.path)) end
        return { viewing = pc and pc.fs_viewing }
    elseif op == "close" then
        M.close_program()
        return { running = running and running.prog.id }
    end
    return { error = "unknown op " .. tostring(op) }
end

function M.register_f2f()
    if M.f2f_registered then return true end
    if type(f2f) ~= "table" or type(f2f.set_handler) ~= "function" then return false end
    local ok, res = pcall(f2f.set_handler, function(cmd, args)
        if cmd == "pc" then return M.f2f_handle(args) end
        error("unknown-command: " .. tostring(cmd))
    end)
    M.f2f_registered = ok and res ~= false
    log("f2f handler " .. (M.f2f_registered and "registered" or ("not registered: " .. tostring(res))))
    return M.f2f_registered
end

return M
