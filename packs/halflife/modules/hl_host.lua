-- Расширение wasmrt для Half-Life (манифест: "extension": "halflife:hl_host"): внутреннее разрешение рендера.
--   vc.hl_resolution() -> 0 — как в манифесте (-width/-height), иначе w * 65536 + h — выбранное кнопкой.
-- Программа (src/vc_platform.c в Spider, Platform_RunEvents) спрашивает каждый кадр и при смене ставит cvar
-- width/height и host.renderinfo_changed -> VID_SetMode -> ref_soft пересоздаёт буфер; кадр показывается
-- вписанным в страницу. Выбор хранится в config:halflife/resolution.txt ("854x480" / "640x360" / "480x270");
-- без файла — разрешение манифеста. Кнопка «Рендер: WxH» на странице (или в оверлее) шлёт событие
-- halflife:cycle_resolution; по умолчанию выход — родные 854x480, меньшие — только явным выбором.
local CONFIG_DIR = "config:halflife"
local CONFIG_FILE = CONFIG_DIR .. "/resolution.txt"
local SIZES = { { 854, 480 }, { 640, 360 }, { 480, 270 } }

local state = { size = nil, button = nil, log = nil, default = nil }

local function parse(text)
    local w, h = tostring(text or ""):match("^%s*(%d+)x(%d+)")
    w, h = tonumber(w), tonumber(h)
    if not w then return nil end
    for _, s in ipairs(SIZES) do
        if s[1] == w and s[2] == h then return s end
    end
    return nil
end

local function load_size()
    local ok, text = pcall(function()
        if file.isfile(CONFIG_FILE) then return file.read(CONFIG_FILE) end
    end)
    return ok and parse(text) or nil
end

local function save_size(s)
    local ok, err = pcall(function()
        if not file.isdir(CONFIG_DIR) then file.mkdirs(CONFIG_DIR) end
        file.write(CONFIG_FILE, ("%dx%d\n"):format(s[1], s[2]))
    end)
    if not ok and state.log then state.log("halflife: resolution save failed: " .. tostring(err)) end
end

local function label()
    local s = state.size or state.default or SIZES[1]
    return ("Рендер: %dx%d"):format(s[1], s[2])
end

local function update_button()
    local button = state.button
    if button then pcall(function() button.text = label() end) end
end

local M = {}

function M.get_size() return state.size or load_size() end
function M.set_size(w, h)
    local s = parse(("%dx%d"):format(w, h))
    assert(s, "size must be one of 854x480, 640x360, 480x270")
    state.size = s
    save_size(s)
    update_button()
    debug.log(("[halflife] resolution %dx%d"):format(s[1], s[2]))
end
function M.cycle()
    local cur = state.size or state.default or SIZES[1]
    local idx = 1
    for i, s in ipairs(SIZES) do
        if s[1] == cur[1] and s[2] == cur[2] then idx = i end
    end
    local nxt = SIZES[idx % #SIZES + 1]
    M.set_size(nxt[1], nxt[2])
end

events.reset("halflife:cycle_resolution", function() M.cycle() end)

setmetatable(M, { __call = function(_, ctx)
    state.log = ctx.log
    state.button = nil
    state.default = parse(("%dx%d"):format(ctx.manifest.width or 854, ctx.manifest.height or 480)) or SIZES[1]
    state.size = load_size()
    local doc = ctx.document
    local parent = ctx.parent or (doc and doc.root)
    if doc and ctx.manifest.resolution_button ~= false then
        local ok, err = pcall(function()
            parent:add(('<button id="halflife_res_btn" pos="8, 52" size="200, 32" ' ..
                'onclick="events.emit(\'halflife:cycle_resolution\')">%s</button>'):format(label()))
            state.button = doc["halflife_res_btn"]
        end)
        if not ok then ctx.log("halflife: resolution button failed: " .. tostring(err)) end
    end
    ctx.log(("halflife: resolution %s (%s)"):format(state.size and ("%dx%d"):format(state.size[1], state.size[2])
        or "manifest", CONFIG_FILE))
    -- ядра спанов ref_soft (modules/hl_kernels.lua): импорт vc.hl_spans(mode, pspan, params) из r_scan.c
    local kernels = require("halflife:hl_kernels")
    local memory = ctx.memory
    local spans = kernels.spans
    -- "jit_stat": true в манифесте — раз в 5 с строка `[halflife] jit: ...` (трассы, сбросы, отказы LuaJIT)
    local tick
    if ctx.manifest.jit_stat and jit and jit.attach then
        local st = { start = 0, flush = 0, abort = 0 }
        pcall(jit.attach, function(what) st[what] = (st[what] or 0) + 1 end, "trace")
        local last = os.clock()
        tick = function()
            local now = os.clock()
            if now - last >= 5 then
                last = now
                ctx.log(("halflife: jit traces started %d, flushes %d, aborts %d"):format(st.start, st.flush, st.abort))
            end
        end
    end
    return {
        __tick = tick,
        hl_spans = function(mode, pspan, prm)
            return spans(memory()[1], mode, pspan, prm)
        end,
        hl_resolution = function()
            local s = state.size
            if not s then return 0 end
            return s[1] * 65536 + s[2]
        end,
    }
end })

return M
