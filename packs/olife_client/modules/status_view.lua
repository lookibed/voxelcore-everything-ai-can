-- olife_client:status_view — UX B (16.10, olife_menu): draws olife_client:status into a document with the status
-- layout's ids (menu page layouts/pages/olife_status.xml, HUD element layouts/olife_status.xml). Only draws: buttons
-- of the page put a request into the menu model (olife_client:menu) which the application script handles.
-- Module instances change under us (app.reopen_world / close_world reload the pack's modules; a layout script may hold
-- an older instance than hud.lua): the registry of documents lives in the bound state table of olife_client:status
-- (the app script's table), and every call takes the CURRENT status module — one view state for all instances.
-- (16.10 coordinator: an empty status panel stayed over the game after a login with a pack reopen.)
local function STm() return require "olife_client:status" end

local M = {}
local function docs()
    local S = STm().S
    S._views = S._views or {}
    return S._views
end
M.docs = docs
M.HOLD_DONE = 1.0              -- s the HUD keeps the filled phase lines after «В игре», then hides

local BAR_W = 520
M.BAR_W = BAR_W
local COL = {wait = {120, 130, 150, 255}, run = {255, 214, 110, 255}, ok = {140, 235, 150, 255},
             skip = {150, 160, 175, 255}, fail = {255, 120, 110, 255}}
M.COL = COL

function M.attach(name, doc, kind)
    -- hidden until drawn from the state: a panel without phase lines must never show (HUD root defaults)
    -- (the HUD forces the ROOT of a permanent element visible every frame: Hud::updateElementsPosition -> show/hide the
    -- panel inside it)
    if kind == "hud" then pcall(function() doc.st_panel.visible = false end) end
    local d = {doc = doc, kind = kind, seq = -1}
    docs()[name] = d
    local ok, err = pcall(M.render_one, d)
    if not ok then debug.log("[olife_status] view " .. name .. ": " .. tostring(err)) end
end

function M.detach(name) docs()[name] = nil end

local function set(doc, id, k, v)
    pcall(function() doc[id][k] = v end)
end

-- split a long text into label lines of at most n characters (labels do not wrap); UTF-8 aware, at spaces if possible
local function split_lines(s, n, count)
    local out, chars = {}, {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    local i = 1
    while i <= #chars and #out < count do
        local j = math.min(#chars, i + n - 1)
        if j < #chars and #out < count - 1 then
            for k = j, i + math.floor(n * 0.6), -1 do
                if chars[k] == " " then j = k; break end
            end
        end
        out[#out + 1] = table.concat(chars, "", i, j)
        i = j + 1
    end
    for k = #out + 1, count do out[k] = "" end
    return out
end
M.split_lines = split_lines

function M.render_one(d)
    local ST = STm()
    local S = ST.S
    local doc = d.doc
    if d.seq == S.seq and not d.force then return end
    d.seq, d.force = S.seq, nil
    local game = d.kind == "hud"
    if game then
        local now = ST.now()
        local hold = S.done and S.done_t and now - S.done_t < M.HOLD_DONE
        local vis = S.banner ~= nil or (S.mode ~= "game" and S.mode ~= "idle" and not S.done) or S.error ~= nil
                    or hold or false
        if hold then d.force = true end            -- redraw once more when the hold ends
        d.vis, d.hold = vis, hold
        set(doc, "st_panel", "visible", vis)   -- not `root`: the HUD sets the root of a permanent element visible
        if not vis then return end
    end
    set(doc, "st_title", "text", ST.title())
    local t = S.target
    set(doc, "st_target", "text", t and string.format("ник %s, шлюз %s:%s, попытка %d", tostring(t.nick),
        tostring(t.host), tostring(t.port), S.attempt or 0) or "")
    for i, p in ipairs(ST.PHASES) do
        local x = S.phases[p.id] or {state = "wait"}
        set(doc, "st_ph" .. i, "text", ST.line(p.id))
        set(doc, "st_ph" .. i, "color", COL[x.state] or COL.wait)
    end
    local f = ST.fraction()
    set(doc, "st_bar", "size", {math.max(1, math.floor(BAR_W * f)), 12})
    set(doc, "st_prog", "text", ST.progress_text())
    set(doc, "st_file", "text", ST.current_text())
    local e = ST.error_text()
    local el = split_lines(e, 68, 3)
    set(doc, "st_err1", "text", el[1])
    set(doc, "st_err2", "text", el[2])
    set(doc, "st_err3", "text", el[3])
    set(doc, "st_errbox", "visible", e ~= "")
    local busy = not S.done and S.error == nil and S.mode == "login"
    set(doc, "st_retry", "enabled", S.error ~= nil)
    set(doc, "st_retry", "visible", S.error ~= nil and not game)
    set(doc, "st_back", "visible", not game)        -- in the game the mouse drives the camera: no buttons
    set(doc, "st_back", "text", busy and "Отмена" or "Назад")
    local bn = S.banner
    set(doc, "st_banner", "text", (bn and not game) and bn.text or "")     -- in the HUD the banner is the title
end

function M.render_all()
    STm().tick()
    local ds = docs()
    for name, d in pairs(ds) do
        local ok = pcall(M.render_one, d)
        if not ok then ds[name] = nil end           -- the document went away with the content
    end
end

-- rectangles (frame pixels, 854-wide test frame) of the status page buttons and lines, for F2F clicks and checks
local function rect(doc, id, k)
    local ok, r = pcall(function()
        local el = doc[id]
        local p, s = el.wpos, el.size
        return {x = p[1] * k, y = p[2] * k, w = s[1] * k, h = s[2] * k, cx = (p[1] + s[1] / 2) * k,
                cy = (p[2] + s[2] / 2) * k, visible = el.visible, enabled = el.enabled}
    end)
    return ok and r or nil
end
M.rect = rect

function M.f2f(name)
    local ST = STm()
    local d = docs()[name]
    if not d then return nil end
    local vp = gui.get_viewport()
    local k = 854 / vp[1]
    local S = ST.S
    local r = {kind = d.kind, rects = {}, texts = {}, seq = d.seq, state_seq = S.seq, vis = d.vis, hold = d.hold,
               done = S.done, since_done = S.done_t and (ST.now() - S.done_t) or nil}
    for _, id in ipairs({"root", "st_panel", "st_retry", "st_back", "st_errbox", "st_bar", "st_bar_bg"}) do
        r.rects[id] = rect(d.doc, id, k)
    end
    for _, id in ipairs({"st_title", "st_target", "st_prog", "st_file", "st_err1", "st_err2", "st_err3", "st_banner",
                         "st_back"}) do
        pcall(function() r.texts[id] = d.doc[id].text end)
    end
    r.lines = {}
    for i = 1, #ST.PHASES do pcall(function() r.lines[i] = d.doc["st_ph" .. i].text end) end
    pcall(function()
        if d.kind == "hud" then r.visible = d.doc.st_panel.visible else r.visible = d.doc.root.visible end
    end)
    return r
end

return M
