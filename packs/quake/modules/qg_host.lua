-- Расширение wasmrt для Quake (манифест: "extension": "quake:qg_host"): схема управления.
--   vc.qg_controls() -> 1 — современная (WASD + мышь с захватом курсора), 0 — классическая
--                        (default.cfg: стрелки, взгляд с зажатой правой кнопкой);
--   vc.qg_wheel()    -> шаги колеса мыши с прошлого вызова (>0 — вверх; 0, если хост не видит колесо).
-- Программа спрашивает режим каждый кадр и при смене добавляет bind'ы в буфер команд Quake
-- (src/qg_wasmrt.c в Spider), так что переключение действует на уже запущенную игру.
-- Выбор хранится в config:quake/controls.txt ("modern" / "classic"); без файла — поле манифеста
-- "controls" или "modern". Кнопка «Управление: …» добавляется в документ программы (страница меню
-- wasmrt_app или HUD-оверлей) и шлёт событие quake:toggle_controls.
local CONFIG_DIR = "config:quake"
local CONFIG_FILE = CONFIG_DIR .. "/controls.txt"
local LABELS = { modern = "Управление: WASD+мышь", classic = "Управление: стандарт" }

local state = { mode = nil, button = nil, log = nil }

local function load_mode(default)
    local ok, text = pcall(function()
        if file.isfile(CONFIG_FILE) then return file.read(CONFIG_FILE) end
    end)
    local mode = ok and text and text:match("^%s*(%a+)") or nil
    if mode ~= "modern" and mode ~= "classic" then mode = default end
    return mode
end

local function save_mode(mode)
    local ok, err = pcall(function()
        if not file.isdir(CONFIG_DIR) then file.mkdirs(CONFIG_DIR) end
        file.write(CONFIG_FILE, mode .. "\n")
    end)
    if not ok and state.log then state.log("quake: controls save failed: " .. tostring(err)) end
end

local function update_button()
    local button = state.button
    if button then pcall(function() button.text = LABELS[state.mode] end) end
end

local M = {}

-- Для скриптов и сценариев: текущая схема и смена без кнопки.
function M.get_mode() return state.mode or load_mode("modern") end
function M.set_mode(mode)
    assert(mode == "modern" or mode == "classic", "mode must be 'modern' or 'classic'")
    state.mode = mode
    save_mode(mode)
    update_button()
    debug.log("[quake] controls " .. mode)
end
function M.toggle()
    M.set_mode(M.get_mode() == "modern" and "classic" or "modern")
end

-- Один обработчик на событие (events.reset): кнопка документа любого экземпляра.
events.reset("quake:toggle_controls", function() M.toggle() end)

setmetatable(M, { __call = function(_, ctx)
    state.log = ctx.log
    state.mode = load_mode(ctx.manifest.controls or "modern")
    state.button = nil
    local doc = ctx.document
    -- контейнер для кнопки и панели колеса: корень страницы/оверлея или окно программы на
    -- рабочем столе компьютера pc_wasmrt:pc (ctx.parent, см. wasmrt:app embed)
    local parent = ctx.parent or (doc and doc.root)
    if doc and ctx.manifest.controls_button ~= false then
        local ok, err = pcall(function()
            parent:add(('<button id="quake_controls_btn" pos="8, 52" size="200, 32" ' ..
                'onclick="events.emit(\'quake:toggle_controls\')">%s</button>'):format(LABELS[state.mode]))
            state.button = doc["quake_controls_btn"]
        end)
        if not ok then ctx.log("quake: controls button failed: " .. tostring(err)) end
    end
    -- Колесо: у Lua движка нет API колеса (input: только кнопки и курсор), но прокручиваемая
    -- панель (panel scrollable + max-length) получает прокрутку от GUI: +1/-1 на щелчок при
    -- scroll-step="1" (проверено в движке). Прозрачная панель на всю страницу под кнопками с
    -- очень длинным содержимым; каждый тик читаем scroll, копим сдвиг и возвращаем в середину.
    local WHEEL_BASE = -1000  -- середина диапазона (-100000 движок уже не прокручивал — проверено)
    local wheel_el, wheel_acc = nil, 0
    if doc and ctx.manifest.controls_wheel ~= false then
        local ok, err = pcall(function()
            parent:add('<panel id="quake_wheel" pos="0, 92" size="8192, 8192" max-length="8192" ' ..
                'scrollable="true" scroll-step="1" color="#00000000">' ..
                '<container size="16, 16384" interactive="false" color="#00000000"/></panel>')
            wheel_el = doc["quake_wheel"]
            wheel_el.scroll = WHEEL_BASE
        end)
        if not ok then
            wheel_el = nil
            ctx.log("quake: wheel panel failed: " .. tostring(err))
        end
    end
    local function wheel_tick()
        if not wheel_el then return end
        local ok, v = pcall(function() return wheel_el.scroll end)
        v = ok and tonumber(v) or nil
        if v and v ~= WHEEL_BASE then
            wheel_acc = wheel_acc + (v - WHEEL_BASE)
            pcall(function() wheel_el.scroll = WHEEL_BASE end)
        end
    end
    ctx.log("quake: controls " .. state.mode .. " (" .. CONFIG_FILE .. ")")
    return {
        __tick = wheel_tick,
        qg_controls = function() return state.mode == "modern" and 1 or 0 end,
        qg_wheel = function()
            local steps = wheel_acc
            if steps ~= 0 then ctx.log(("quake: wheel %+d"):format(steps)) end
            wheel_acc = 0
            return steps
        end,
    }
end })

return M
