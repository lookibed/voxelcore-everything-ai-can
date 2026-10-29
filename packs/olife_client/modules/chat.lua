-- olife_client:chat — UX A2 (03.10, olife_a2): chat on the client.
-- ChatHistory (after Welcome: the last lines of the world, late joiners), ChatLine (players / system / op lines,
-- replies, notices), OpResult (answer to a "/" command), Notice (something happened to this player -> fx event).
-- UI: the overlay olife_client:chat (native 0.32 XML) opens on T (the engine's `hud.chat` binding: its console in
-- chat mode opens first, ours replaces it — same trick as ` for the editor) or Enter; a window of the log with
-- colours per kind/role, ▲/▼ (and PageUp/PageDown) scroll by 5 lines, ↑/↓ in the prompt = sent history, Enter sends,
-- Esc closes. Without the overlay the last lines are shown in the HUD feed (olife_client:chat_feed) and fade out.
local fx = require "olife_client:fx"
local M = {}
local S = {
    lines = {}, total = 0, history_total = 0, history_n = 0, results = {}, notices = {}, sent = {}, sent_i = 0,
    bottom = 0, unread = 0, doc = nil, feed = nil, open = false, n = 0,
    stats = {lines = 0, history = 0, results = 0, notices = 0, sent = 0, commands = 0, legacy = 0, opens = 0},
}
M.S = S
local KEEP = 300                 -- lines kept on the client
local WINDOW = 14                -- lines visible in the overlay
local FEED_N, FEED_TTL = 6, 8.0  -- HUD feed: lines, seconds before fading out

-- colours per kind (0 player, 1 system, 2 op, 3 reply, 4 notice) and role (1 admin, 3 operator)
local COL = {[0] = "#E6EAF0", [1] = "#9FB4D0", [2] = "#FF9CF0", [3] = "#B8F0B8", [4] = "#FFD27A"}
local ROLE_COL = {[1] = "#FFB060", [3] = "#FF7AE0"}
M.COL = COL
local ROLE_TAG = {[1] = "[admin] ", [3] = "[op] "}
local NOTICE_EV = {[1] = "frozen", [2] = "unfrozen", [3] = "killed", [4] = "limits", [5] = "kicked", [6] = "banned",
                   [7] = "restarting", [8] = "throttle", [9] = "frozen", [10] = "unfrozen", [11] = "op", [12] = "killed",
                   [13] = "fraud_warn", [14] = "fraud_throttle"}      -- antifraud 16.10 (world fraud.lua)
M.NOTICE_EV = NOTICE_EV

local function log(fmt, ...) print("[olife_client] chat: " .. string.format(fmt, ...)) end
local function cl() return require "olife_client:client" end

local function fmt_time(ms)        -- local time of the viewer (the world sends unix ms)
    local ok, off = pcall(time.utc_offset)
    local s = math.floor((ms or 0) / 1000) + (ok and tonumber(off) or 0)
    return string.format("%02d:%02d", math.floor(s / 3600) % 24, math.floor(s / 60) % 60)
end

local function text_of(l)
    if l.kind == 1 then return string.format("%s * %s", fmt_time(l.ms), l.text) end
    if l.kind == 3 or l.kind == 4 then return string.format("%s %s", fmt_time(l.ms), l.text) end
    return string.format("%s %s<%s> %s", fmt_time(l.ms), ROLE_TAG[l.role] or "", l.from, l.text)
end
M.text_of = text_of

local function color_of(l)
    if l.kind == 0 and ROLE_COL[l.role] then return ROLE_COL[l.role] end
    return COL[l.kind] or COL[0]
end
M.color_of = color_of

-- "#RRGGBB" -> {r, g, b, a} (the 0.32 GUI takes RGBA arrays only)
local function rgba(hex, a)
    return {tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16), a or 255}
end
M.rgba = rgba

local function add(l, quiet)
    S.n = S.n + 1
    local r = {n = S.n, id = l.id, tick = l.tick, ms = l.ms, kind = l.kind, role = l.role, from_eid = l.from_eid,
               from = l.from, text = l.text, t = time.uptime()}
    S.lines[#S.lines + 1] = r
    if #S.lines > KEEP then table.remove(S.lines, 1); S.bottom = math.max(0, S.bottom - 1) end
    S.stats.lines = S.stats.lines + 1
    local at_bottom = S.bottom == 0 or S.bottom >= #S.lines - 1
    if at_bottom then S.bottom = #S.lines else S.unread = S.unread + 1 end
    if not quiet then
        local me = cl().S.eid
        if l.kind == 0 and l.from_eid ~= me then fx.event("chat", nil, {no_toast = true})
        elseif l.kind == 2 then fx.event("op", l.text, {no_toast = true}) end
    end
    M.refresh()
    return r
end
M.add = add

-- ------------------------------------------------------------------ messages (client.lua dispatch)
local H = {}
function H.ChatLine(m) add(m.line) end

function H.ChatHistory(m)
    S.stats.history = S.stats.history + 1
    S.history_total, S.history_n = m.total, #m.lines
    for _, l in ipairs(m.lines) do add(l, true) end
    log("history: %d lines (world total %d)", #m.lines, m.total)
end

function H.OpResult(m)
    S.stats.results = S.stats.results + 1
    local r = {n = m.n, code = m.code, cmd = m.cmd, text = m.text, t = time.uptime()}
    S.results[#S.results + 1] = r
    if #S.results > 32 then table.remove(S.results, 1) end
    for line in (m.text .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then add({id = 0, tick = 0, ms = time.precise_utc_time() * 1000, kind = 3, role = 2, from_eid = 0, from = "",
                                 text = (m.code ~= 0 and ("[" .. m.code .. "] ") or "") .. line}, true) end
    end
    if m.code == 0 then
        fx.event("op", "/" .. m.cmd .. ": " .. (m.text:match("^[^\n]*") or ""), {code = 0})
    else
        fx.deny("/" .. m.cmd .. ": " .. m.text:match("^[^\n]*"), m.code == 9 and 9 or m.code)
    end
end

function H.Notice(m)
    S.stats.notices = S.stats.notices + 1
    local ev = NOTICE_EV[m.event] or "info"
    local r = {event = m.event, fx = ev, code = m.code, eid = m.eid, by = m.by, text = m.text, t = time.uptime()}
    S.notices[#S.notices + 1] = r
    if #S.notices > 32 then table.remove(S.notices, 1) end
    add({id = 0, tick = 0, ms = time.precise_utc_time() * 1000, kind = 4, role = 2, from_eid = 0, from = "", text = m.text}, true)
    fx.event(ev, m.text, {code = m.code, eid = m.eid})
end

-- wave 2 ChatMessage (an older world): shown as a player line
function H.ChatMessage(m)
    S.stats.legacy = S.stats.legacy + 1
    add({id = 0, tick = 0, ms = time.precise_utc_time() * 1000, kind = 0, role = 0, from_eid = m.from, from = m.name, text = m.text})
end

M.handled = {ChatLine = true, ChatHistory = true, OpResult = true, Notice = true, ChatMessage = true}
function M.on_msg(name, m) local h = H[name]; if h then h(m) end end

-- Disconnect codes -> feedback (gateway codes: 1 shutdown, 5 banned, 9 world unavailable/restarting, 10 kicked)
function M.on_disconnect(code, reason)
    if code == 9 or code == 1 then fx.event("restarting", "Мир перезапускается: " .. tostring(reason))
    elseif code == 10 then fx.event("kicked", "Отключены: " .. tostring(reason))
    elseif code == 5 then fx.event("banned", "Бан: " .. tostring(reason)) end
end

-- ------------------------------------------------------------------ sending
function M.send(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false end
    if #text > 256 then text = text:sub(1, 256) end
    S.sent[#S.sent + 1] = text
    if #S.sent > 50 then table.remove(S.sent, 1) end
    S.sent_i = #S.sent + 1
    S.stats.sent = S.stats.sent + 1
    if text:sub(1, 1) == "/" then S.stats.commands = S.stats.commands + 1 end
    cl().chat(text)
    cl().flush()
    return true
end

-- ------------------------------------------------------------------ UI
local function ui_busy()
    local ok, open = pcall(hud.is_inventory_open)
    return ok and open or false
end

function M.open_ui(why)
    if S.open or not hud or not hud.show_overlay then return false end
    local ol = require "olife_client:olife"
    if ol.S.open then return false end                       -- the editor owns the keyboard
    S.stats.opens = S.stats.opens + 1
    S.open_why = why
    -- two frames later: the engine's own hud.chat runnable (its console in chat mode) runs after a runnable posted
    -- from our callback (seen 03.10: console open, ours replaced) -> replace it after it opened
    time.post_runnable(function() time.post_runnable(function()
        pcall(hud.close, "core:console")
        local ok, err = pcall(hud.show_overlay, "olife_client:chat", false)
        if not ok then log("overlay failed: %s", tostring(err)) end
    end) end)
    return true
end

function M.on_hud_open(pid)
    -- T = the engine's chat binding (its console in chat mode opens first; ours replaces it), Enter too
    pcall(input.add_callback, "hud.chat", function() if not ui_busy() then M.open_ui("t") end end)
    pcall(input.add_callback, "key:enter", function()
        if not S.open and not ui_busy() and not (hud.is_open and hud.is_open("olife_client:editor")) then M.open_ui("enter") end
    end)
    pcall(hud.open_permanent, "olife_client:chat_feed")
end

function M.ui_opened(doc)
    S.doc, S.open = doc, true
    S.unread = 0
    S.bottom = #S.lines
    M.refresh()
    pcall(function() doc.prompt.text = ""; doc.prompt.focused = true end)
end

function M.ui_closed()
    S.doc, S.open = nil, false
    M.refresh()
end

function M.ui_submit(text)
    M.send(text)
    if S.doc then pcall(function() S.doc.prompt.text = ""; S.doc.prompt.focused = true end) end
    S.bottom = #S.lines
end

function M.ui_scroll(d)
    S.bottom = math.max(math.min(WINDOW, #S.lines), math.min(#S.lines, S.bottom + d))
    if S.bottom >= #S.lines then S.unread = 0 end
    M.refresh()
end

function M.ui_history(d)
    if #S.sent == 0 or not S.doc then return end
    S.sent_i = math.max(1, math.min(#S.sent + 1, S.sent_i + d))
    pcall(function() S.doc.prompt.text = S.sent[S.sent_i] or ""; S.doc.prompt.caret = -1 end)
end

function M.ui_close() if hud and hud.close then pcall(hud.close, "olife_client:chat") end end

function M.feed_opened(doc) S.feed = doc; M.refresh() end

-- the overlay window (WINDOW lines ending at S.bottom) and the HUD feed (last FEED_N lines, fading)
function M.refresh()
    local d = S.doc
    if d then
        pcall(function()
            local first = math.max(1, S.bottom - WINDOW + 1)
            for i = 1, WINDOW do
                local l = S.lines[first + i - 1]
                local lab = d["l" .. i]
                if l and first + i - 1 <= S.bottom then
                    lab.text, lab.color = text_of(l), rgba(color_of(l))
                else
                    lab.text = ""
                end
            end
            d.more.text = S.bottom < #S.lines and string.format("v ещё %d (новых %d)", #S.lines - S.bottom, S.unread) or ""
            d.pos.text = string.format("%d / %d", S.bottom, #S.lines)
        end)
    end
    local f = S.feed
    if f then
        pcall(function()
            local now = time.uptime()
            for i = 1, FEED_N do
                local l = not S.open and S.lines[#S.lines - FEED_N + i] or nil
                local lab = f["f" .. i]
                if l and now - l.t < FEED_TTL then
                    local c = color_of(l)
                    local a = now - l.t < FEED_TTL - 1 and 255 or math.floor(255 * (FEED_TTL - (now - l.t)))
                    lab.text = text_of(l)
                    lab.color = rgba(c, math.max(0, math.min(255, a)))
                else
                    lab.text = ""
                end
            end
        end)
    end
end

-- every frame (olife.frame): the feed fades
local last_feed = 0
function M.frame()
    local now = time.uptime()
    if S.feed and now - last_feed > 0.1 then last_feed = now; M.refresh() end
end

-- F2F `chat`: {op=state} lines/results/notices/ui; {op=send, text}; {op=open}; {op=close}; {op=scroll, d}; {op=gui}
function M.f2f(args)
    local op = args.op or "state"
    if op == "send" then return {sent = M.send(args.text)} end
    if op == "open" then return {opened = M.open_ui("f2f")} end
    if op == "close" then M.ui_close(); return {closed = true} end
    if op == "scroll" then M.ui_scroll(args.d or -5); return {bottom = S.bottom} end
    local lines = {}
    local from = math.max(1, #S.lines - (args.last or 60) + 1)
    for i = from, #S.lines do
        local l = S.lines[i]
        lines[#lines + 1] = {id = l.id, kind = l.kind, role = l.role, from = l.from, text = l.text, ms = l.ms,
                             color = color_of(l)}
    end
    local r = {lines = lines, count = #S.lines, history_total = S.history_total, history_n = S.history_n,
               results = S.results, notices = S.notices, stats = S.stats, open = S.open, bottom = S.bottom,
               unread = S.unread, fx = fx.state()}
    if op == "gui" and S.doc then
        local d = S.doc
        local vp = gui.get_viewport()
        local k = 854 / vp[1]
        r.gui = {}
        pcall(function()
            for i = 1, WINDOW do r.gui[i] = {text = d["l" .. i].text, color = d["l" .. i].color} end
            r.visible_lines = 0
            for i = 1, WINDOW do if r.gui[i].text ~= "" then r.visible_lines = r.visible_lines + 1 end end
            r.prompt = d.prompt.text
            r.prompt_focused = d.prompt.focused
            r.more = d.more.text
            local function rect(id)
                local s = d[id].size
                local w = d[id].wpos
                return {x = w[1] * k, y = w[2] * k, w = s[1] * k, h = s[2] * k, cx = (w[1] + s[1] / 2) * k,
                        cy = (w[2] + s[2] / 2) * k}
            end
            r.rects = {up = rect("btn_up"), down = rect("btn_down"), prompt = rect("prompt"), close = rect("btn_close")}
        end)
    end
    if S.feed then
        r.feed = {}
        pcall(function() for i = 1, FEED_N do r.feed[i] = S.feed["f" .. i].text end end)
    end
    return r
end

return M
