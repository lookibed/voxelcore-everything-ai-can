-- GuiChat of the Alpha client (E2E fix 01.10) as an engine XML document (layouts/chat.xml).
-- Java (Alpha 1.0.16): Minecraft.runTick key loop -- keyBindChat (T, code 20) in a multiplayer world opens GuiChat;
-- GuiChat.keyTyped: Esc (1) closes; Enter (28) sends message.trim() (Packet3Chat) when not empty and closes;
-- Backspace (14) deletes the last char; any other char is appended when it is in the allowed string (FontRenderer's
-- table with the backquote replaced by a second quote; no '§') and the message is shorter than 100. updateScreen:
-- ++updateCounter every tick while open (the tick that opens it does not count). drawScreen: drawRect(2, h-14, w-2,
-- h-2, 0x80000000) and drawString (= with shadow) "> " + message + ("_" when updateCounter / 6 % 2 == 0) at (4, h-12)
-- colour 0xE0E0E0. No drawDefaultBackground. GuiIngame meanwhile shows up to 20 chat lines at full alpha (hud.lua).
-- Input order like Java: the keyboard events of a tick are handled by GuiScreen.handleInput in runTick after
-- onPlayerUpdate/playerController.onUpdate, so the Chat packet follows the tick's movement packet (M.tick from
-- game.run_tick); the message model lives here, not in the engine's text box.
--
-- Engine side (no Lua text-input API in 0.31): the document holds an invisible <textbox> that keeps the GUI focus
-- while the chat is open. GUI::act feeds it the frame's codepoints (real keyboard, layout-aware, key repeat; F2F
-- `input.chars`) and editing keys (Backspace with repeat, Enter -> consumer). Its text is kept equal to a sentinel:
-- what was appended = typed chars, how much of the sentinel was erased = Backspaces. GUI::act runs before the
-- world update in a frame (Engine::updateFrontend), so the chars of a frame reach the model in the same frame's tick.
-- The document is a permanent HUD element (hud.open_permanent), not an overlay: an overlay counts as an open
-- inventory and the engine then hides its crosshair (Hud::draw), while Java draws the crosshair under GuiChat. Hence:
-- the cursor stays grabbed (GuiChat has no mouse use besides GuiIngame.testMessage, always null in 1.0.16), F2F treats
-- the document as layer `hud` (not `gui`), player keys are blocked by input.lua (text_input), and the engine bindings
-- that would react to typed keys (console `, F5 chunk reload) are switched off while it is open. Window focus loss
-- (normal launch): the engine would put its "pause" page over the chat every frame (no inventory open), so the
-- document is switched to an overlay then (gui.focus_lost_check) -- like Java, the chat stays and the game runs.
local game = require "alphamine:game"
local ui = require "alphamine:ui"
local font = require "alphamine:font"

local M = {open = false, doc = nil, key = nil, message = "", counter = 0, pending = {},
           stats = {opens = 0, sent = 0, typed = 0, rejected = 0, backspaces = 0}}

local LAYOUT = "alphamine:chat"
local SENTINEL = "##########"     -- textbox content between ticks (10 Backspaces per frame at most)
local MAX_LEN = 100
-- engine bindings that react to keys typed into the chat (restored on close)
local TYPING_BINDINGS_OFF = {"devtools.console", "chunks.reload"}

local function log(m) debug.log("[alphamine_chat] " .. m) end

-- GuiChat.keyTyped allowed characters (the decompiled string: FontRenderer's table, '`' -> '\'')
local ALLOWED = {}
do
    local s = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_'abcdefghijklmnopqrstuvwxyz{|}~" ..
        "\u{2302}\u{00c7}\u{00fc}\u{00e9}\u{00e2}\u{00e4}\u{00e0}\u{00e5}\u{00e7}\u{00ea}\u{00eb}\u{00e8}\u{00ef}\u{00ee}" ..
        "\u{00ec}\u{00c4}\u{00c5}\u{00c9}\u{00e6}\u{00c6}\u{00f4}\u{00f6}\u{00f2}\u{00fb}\u{00f9}\u{00ff}\u{00d6}\u{00dc}" ..
        "\u{00f8}\u{00a3}\u{00d8}\u{00d7}\u{0192}\u{00e1}\u{00ed}\u{00f3}\u{00fa}\u{00f1}\u{00d1}\u{00aa}\u{00ba}\u{00bf}" ..
        "\u{00ae}\u{00ac}\u{00bd}\u{00bc}\u{00a1}\u{00ab}\u{00bb}"
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do ALLOWED[ch] = true end
end
M.ALLOWED = ALLOWED

-- UTF-8 string -> list of characters (each a UTF-8 string); Java String length = number of UTF-16 units, the same
-- for every allowed (BMP) character
local function chars(s)
    local out = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
    return out
end
M.chars = chars

local function msg_len(s)
    return #chars(s)
end

-- String.trim: strips chars <= ' ' at both ends
local function jtrim(s)
    return (s:gsub("^[%z\1- ]+", ""):gsub("[%z\1- ]+$", ""))
end

-- ------------------------------------------------------------------ open / close
function M.is_open() return M.open end

local function set_typing_bindings(enabled)
    for _, b in ipairs(TYPING_BINDINGS_OFF) do pcall(input.set_enabled, b, enabled) end
end

local function input_mod()
    return require "alphamine:input"
end

-- Minecraft.displayGuiScreen(new GuiChat()): fresh message, updateCounter 0
function M.open_screen()
    if M.open then return end
    M.open = true
    M.stats.opens = M.stats.opens + 1
    M.message = ""
    M.counter = 0
    M.pending = {}
    M.key = nil
    M.overlay = false
    game.screen = "GuiChat"
    input_mod().text_input = true
    set_typing_bindings(false)
    hud.open_permanent(LAYOUT)
end

local function closed()
    if not M.open then return end
    M.open = false
    M.pending = {}
    input_mod().text_input = false
    input_mod().swallow_held()
    set_typing_bindings(true)
    if game.screen == "GuiChat" then game.screen = "ingame" end
end

-- displayGuiScreen(null)
function M.close()
    if not M.open then return end
    closed()
    if hud.is_open(LAYOUT) then hud.close(LAYOUT) end
end

local function reset_box(refocus)
    local box = M.doc and M.doc.am_input
    if not box then return end
    box.text = SENTINEL
    box.caret = -1
    if refocus ~= false and not box.focused then box.focused = true end
end

function M.attach(doc)
    M.doc = doc
    M.key = nil
    reset_box()
end

function M.detach()
    M.doc = nil
    if M.switching then return end   -- permanent -> overlay (focus loss), the chat stays open
    closed()                         -- closed by the engine (world closing)
end

-- normal launch, window lost focus while the chat is open (gui.focus_lost_check): the same document as an overlay
-- (an open "inventory" keeps the engine from putting its pause page over it every frame)
function M.to_overlay()
    if not M.open or M.overlay then return end
    M.switching = true
    if hud.is_open(LAYOUT) then hud.close(LAYOUT) end
    hud.show_overlay(LAYOUT, false)
    M.switching = false
    M.overlay = true
    log("window lost focus: GuiChat kept as an overlay")
end

-- ------------------------------------------------------------------ input
-- the engine text box -> model events (typed chars, Backspaces); called at the start of the tick and before Enter
function M.sync(refocus)
    local box = M.doc and M.doc.am_input
    if not box then return end
    local t = box.text or ""
    if t ~= SENTINEL then
        local p = 0
        local n = math.min(#t, #SENTINEL)
        while p < n and t:byte(p + 1) == SENTINEL:byte(p + 1) do p = p + 1 end
        for _ = 1, #SENTINEL - p do M.pending[#M.pending + 1] = {"back"} end
        for _, ch in ipairs(chars(t:sub(p + 1))) do M.pending[#M.pending + 1] = {"char", ch} end
    end
    reset_box(refocus)
end

-- layouts/chat.xml.lua: Enter in the text box (it has already defocused itself; reset_box refocuses)
function M.on_submit(_)
    if not M.open then return end
    M.sync(false)   -- inside TextBox::keyPressed (GUI::actFocused): no focus change here
    M.pending[#M.pending + 1] = {"enter"}
end

-- key events from outside the text box: Esc (input callback, gui.install_escape), F2F `gui {key}`
function M.key_event(k)
    if not M.open then return end
    M.pending[#M.pending + 1] = {k}
end

-- GuiChat.keyTyped for one event
local function key_typed(ev)
    local k = ev[1]
    if k == "escape" then
        M.close()
        return false
    elseif k == "enter" then
        local text = jtrim(M.message)
        if #text > 0 then
            game.send_chat(text)
            M.stats.sent = M.stats.sent + 1
            log(("sent %q"):format(text))
        end
        M.close()
        return false
    elseif k == "back" then
        if #M.message > 0 then
            local cs = chars(M.message)
            cs[#cs] = nil
            M.message = table.concat(cs)
            M.stats.backspaces = M.stats.backspaces + 1
        end
    elseif k == "char" then
        if ALLOWED[ev[2]] and msg_len(M.message) < MAX_LEN then
            M.message = M.message .. ev[2]
            M.stats.typed = M.stats.typed + 1
        else
            M.stats.rejected = M.stats.rejected + 1
        end
    end
    return true
end

-- Minecraft.runTick: currentScreen.handleInput() then updateScreen() (game.run_tick, after the movement packet)
function M.tick()
    if not M.open then return end
    M.sync()
    local evs = M.pending
    M.pending = {}
    for _, ev in ipairs(evs) do
        if not key_typed(ev) then return end   -- the screen closed: the remaining events are not its own
    end
    M.counter = M.counter + 1
end

-- F2F `gui {key?, char?, chars?}` while the chat is open (Java F2FAgent.gui: F2FKeyboard.tap / typeChar, then step)
function M.handle(args)
    local res = {}
    if args.chars then
        for _, ch in ipairs(chars(tostring(args.chars))) do M.pending[#M.pending + 1] = {"char", ch} end
    end
    if args.char then
        local ch = chars(tostring(args.char))[1]
        if ch then M.pending[#M.pending + 1] = {"char", ch} end
    end
    if args.key then
        local k = tostring(args.key):upper()
        res.key = k
        if k == "ESCAPE" or k == "1" then M.pending[#M.pending + 1] = {"escape"}
        elseif k == "RETURN" or k == "ENTER" or k == "28" then M.pending[#M.pending + 1] = {"enter"}
        elseif k == "BACK" or k == "BACKSPACE" or k == "14" then M.pending[#M.pending + 1] = {"back"}
        else res.ignored = true end
    end
    res.screen = game.screen
    return res
end

-- ------------------------------------------------------------------ drawing (per frame, hud.lua on_hud_render)
function M.update()
    if not M.doc or not M.open then return end
    local box = M.doc.am_input
    if box and not box.focused then box.focused = true end
    local vw, vh = ui.viewport()
    local w, h, sf = ui.scaled(vw, vh)
    local cursor = math.floor(M.counter / 6) % 2 == 0
    local key = ("%dx%d|%s|%s"):format(vw, vh, tostring(cursor), M.message)
    if key == M.key then return end
    M.key = key
    local buf = {}
    ui.fill(buf, 2, h - 14, w - 2, h - 2, 0x80000000, sf)
    font.draw_shadow(buf, "> " .. M.message .. (cursor and "_" or ""), 4, h - 12, 14737632, sf)
    local root = M.doc.root
    if root then
        local sz = root.size
        if sz[1] ~= vw or sz[2] ~= vh then root.size = {vw, vh} end
    end
    ui.replace(M.doc, "am_screen", buf, vw, vh)
end

-- F2F state / debugging
function M.report()
    return {open = M.open, message = M.message, counter = M.counter, overlay = M.overlay or false, stats = M.stats}
end

return M
