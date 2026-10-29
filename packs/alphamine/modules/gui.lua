-- GUI screens of the Alpha client (phase 3) as engine XML documents shown with hud.show_overlay (F2F layer `gui`):
-- GuiIngameMenu ("Game menu": Back to game / Disconnect (multiplayer; "Save and quit to title" in single player) /
-- Options...), drawDefaultBackground over the world (gradient 0xC0101010 -> 0xD0101010, textures/gui/am_menu_bg.png),
-- GuiButton from gui/gui.png (state 1 normal, 2 hover: texture rows 46 + state*20), labels with the Alpha font.
-- Hover is computed like GuiScreen.drawScreen(mouseX, mouseY): from the cursor position of the frame, not from the
-- engine's hover state. Clicks and keys come from the F2F `gui` command (gui.handle) or the engine document.
local game = require "alphamine:game"
local ui = require "alphamine:ui"
local font = require "alphamine:font"

local M = {screen = nil, doc = nil, key = nil, opened_tick = 0}

local LAYOUT = "alphamine:ingame_menu"

local function log(m) debug.log("[alphamine_gui] " .. m) end

-- ------------------------------------------------------------------ GuiIngameMenu
local function menu_buttons(w, h)
    local quit = game.multiplayer == false and "Save and quit to title" or "Disconnect"
    return {
        {id = 1, x = math.floor(w / 2) - 100, y = math.floor(h / 4) + 48, w = 200, h = 20, text = quit, enabled = true},
        {id = 4, x = math.floor(w / 2) - 100, y = math.floor(h / 4) + 24, w = 200, h = 20, text = "Back to game", enabled = true},
        {id = 0, x = math.floor(w / 2) - 100, y = math.floor(h / 4) + 96, w = 200, h = 20, text = "Options...", enabled = true},
    }
end

-- GuiConnectFailed: one button "Back to title screen" at (w/2 - 100, h/4 + 120 + 12)
local function failed_buttons(w, h)
    return {
        {id = 100, x = math.floor(w / 2) - 100, y = math.floor(h / 4) + 132, w = 200, h = 20,
         text = "Back to title screen", enabled = true},
    }
end

local function screen_buttons(w, h)
    if M.screen == "GuiConnectFailed" then return failed_buttons(w, h) end
    return menu_buttons(w, h)
end

-- frame pixels (top-left origin) -> GUI units like GuiScreen.handleMouseInput
local function to_gui(px, py, vw, vh, w, h)
    local gx = math.floor(px * w / vw)
    local ly = vh - 1 - py                         -- LWJGL y (bottom-up)
    local gy = h - math.floor(ly * h / vh) - 1
    return gx, gy
end
M.to_gui = to_gui

local function inside(b, mx, my)
    return mx >= b.x and my >= b.y and mx < b.x + b.w and my < b.y + b.h
end

-- GuiButton.drawButton
local function button_xml(buf, b, mx, my, sf)
    local over = inside(b, mx, my)
    local state = not b.enabled and 0 or (over and 2 or 1)
    local half = math.floor(b.w / 2)
    ui.rect(buf, "gui/am_gui", 256, 256, b.x, b.y, 0, 46 + state * 20, half, b.h, sf)
    ui.rect(buf, "gui/am_gui", 256, 256, b.x + half, b.y, 200 - half, 46 + state * 20, half, b.h, sf)
    local color = not b.enabled and -6250336 or (over and 16777120 or 14737632)
    font.draw_centered(buf, b.text, b.x + half, b.y + math.floor((b.h - 8) / 2), color, sf)
end

local function mouse()
    local ok, pos = pcall(input.get_mouse_pos)
    if ok and type(pos) == "table" then return pos[1], pos[2] end
    return -1, -1
end

function M.attach(doc)
    M.doc = doc
    M.key = nil
    M.saving_key = nil
end

function M.detach()
    M.doc = nil
    if M.screen == "GuiConnectFailed" then
        -- the engine closed the overlay (world closing); nothing to restore
        M.screen = nil
    elseif M.screen == "GuiIngameMenu" then
        -- closed by the engine (Esc with an open overlay closes the inventory)
        M.screen = nil
        if game.screen == "GuiIngameMenu" then game.screen = "ingame" end
    end
end

function M.is_open()
    return M.screen ~= nil
end

function M.open_menu()
    if M.screen then return end
    M.screen = "GuiIngameMenu"
    M.opened_tick = game.tick
    M.key = nil
    game.screen = "GuiIngameMenu"
    hud.show_overlay(LAYOUT, false)
end

function M.close()
    if not M.screen then return end
    M.screen = nil
    if game.screen == "GuiIngameMenu" then game.screen = "ingame" end
    if hud.is_open(LAYOUT) then hud.close(LAYOUT) end
end

-- GuiConnectFailed(message, description): kick (Packet255) or lost connection; stays until its button
function M.show_failed(title, reason)
    M.failed = {title = tostring(title or ""), reason = tostring(reason or "")}
    M.key = nil
    if M.screen == "GuiConnectFailed" then return end
    if M.screen then M.close() end
    M.screen = "GuiConnectFailed"
    M.opened_tick = game.tick
    log(("GuiConnectFailed: %s / %s"):format(M.failed.title, M.failed.reason))
    if not hud.is_open(LAYOUT) then hud.show_overlay(LAYOUT, false) end
end

local function action(b)
    if b.id == 4 then
        M.close()
    elseif b.id == 1 or b.id == 100 then
        -- GuiIngameMenu "Disconnect" / GuiConnectFailed "Back to title screen" -> GuiMainMenu (engine main menu)
        M.close()
        if game.leave_to_menu then game.leave_to_menu(b.text) else game.close() end
        game.screen = "GuiMainMenu"
    elseif b.id == 0 then
        log("GuiOptions is not implemented")
    end
end

-- F2F `gui {click:[x,y], button?, key?}` (frame pixels, like Java F2FAgent.gui); the harness steps afterwards
function M.handle(args)
    -- GuiInventory (modules/inventory_gui.lua): its own keys and clicks while open; the inventory key opens it
    local invgui = require "alphamine:inventory_gui"
    if invgui.is_open() then return invgui.handle(args) end
    local chat = require "alphamine:chat_gui"          -- GuiChat: chars / Enter / Backspace / Esc (E2E 01.10)
    if chat.is_open() then return chat.handle(args) end
    if args.key and game.screen == "ingame" and not M.screen then
        local k = tostring(args.key):upper()
        if k == "I" or k == "23" or k == "E" then
            invgui.open_screen()
            return {key = k, screen = game.screen}
        end
        if k == "T" or k == "20" then
            chat.open_screen()
            return {key = k, screen = game.screen}
        end
    end
    local vw, vh = ui.viewport()
    local w, h = ui.scaled(vw, vh)
    local res = {}
    if args.key then
        local k = tostring(args.key):upper()
        if k == "ESCAPE" or k == "1" then
            -- GuiConnectFailed.keyTyped does nothing
            if M.screen == "GuiConnectFailed" then
            elseif M.screen then M.close() elseif game.screen == "ingame" then M.open_menu() end
            res.key = "ESCAPE"
        else
            res.key = k
            res.ignored = true
        end
    end
    if args.click then
        local mx, my = to_gui(args.click[1], args.click[2], vw, vh, w, h)
        res.gui = {mx, my}
        if M.screen and (args.button or 0) == 0 then
            for _, b in ipairs(screen_buttons(w, h)) do
                if b.enabled and inside(b, mx, my) then
                    res.button = b.text
                    action(b)
                    break
                end
            end
        end
    end
    res.screen = game.screen
    return res
end

-- real mouse (not F2F): a click on the menu document (layouts/ingame_menu.xml onclick) -> the button under the cursor
function M.on_click()
    local px, py = mouse()
    local vw, vh = ui.viewport()
    return M.handle({click = {px, py}, button = 0})
end

-- Esc in the world (runtime): the pack's GuiIngameMenu instead of the engine pause page; handlers run from the
-- last added to the first, returning true stops the chain (stdlib.lua adds the engine's in on_hud_open of core)
function M.install_escape()
    if M.escape_installed then return end
    M.escape_installed = true
    input.add_callback("key:escape", function()
        local invgui = require "alphamine:inventory_gui"   -- GuiInventory: Esc closes it (U)
        if invgui.is_open() then
            invgui.close()
            return true
        end
        local chat = require "alphamine:chat_gui"          -- GuiChat: Esc in its tick (keyTyped code 1)
        if chat.is_open() then
            chat.key_event("escape")
            return true
        end
        if M.screen == "GuiConnectFailed" then return true end
        if M.screen then
            M.close()
            return true
        end
        if game.screen == "ingame" and not hud.is_inventory_open() and not hud.is_paused() then
            local ok, page = pcall(function() return gui.root.menu and gui.root.menu.page end)
            if ok and page and page ~= "" then return false end
            M.open_menu()
            return true
        end
        return false
    end)
end

-- state.buttons for F2F (centre in frame pixels, like Java)
function M.buttons()
    if not M.screen then return {} end
    local vw, vh = ui.viewport()
    local w, h, sf = ui.scaled(vw, vh)
    local out = {}
    for _, b in ipairs(screen_buttons(w, h)) do
        out[#out + 1] = {id = b.id, text = b.text, x = (b.x + b.w / 2) * sf, y = (b.y + b.h / 2) * sf,
                         w = b.w * sf, h = b.h * sf, enabled = b.enabled, visible = true}
    end
    return out
end

-- per frame (hud script on_hud_render): rebuild the document when the hover, size or "Saving level.." changes
function M.update(partial)
    if not M.doc or not M.screen then return end
    if M.screen == "GuiConnectFailed" then return M.update_failed() end
    local vw, vh = ui.viewport()
    local w, h, sf = ui.scaled(vw, vh)
    local px, py = mouse()
    local mx, my = to_gui(px, py, vw, vh, w, h)
    local buttons = menu_buttons(w, h)
    local hover = {}
    for _, b in ipairs(buttons) do hover[#hover + 1] = inside(b, mx, my) and "1" or "0" end
    -- GuiIngameMenu.updateCounter: ticks since opened (updateScreen runs in the tick that opened it)
    local counter = game.tick - M.opened_tick
    local saving = counter < 20
    local pulse = 0
    if saving then
        local v = ((counter % 10) + (partial or 0)) / 10.0
        v = math.sin(v * math.pi * 2.0) * 0.2 + 0.8
        pulse = math.floor(255.0 * v)
    end
    -- "Saving level.." changes its colour every frame for 20 ticks: its own container (am_saving, drawn after the
    -- screen; it overlaps nothing), so the pulse does not rebuild the whole menu (was ~16 ms per frame, perf suite)
    local skey = ("%dx%d|%d"):format(vw, vh, saving and pulse or -1)
    if skey ~= M.saving_key and M.doc.am_saving then
        M.saving_key = skey
        local sb = {}
        if saving then
            font.draw_shadow(sb, "Saving level..", 8, h - 16, pulse * 65536 + pulse * 256 + pulse, sf)
        end
        ui.replace(M.doc, "am_saving", sb, vw, vh)
    end
    local key = ("%dx%d|%s|%s"):format(vw, vh, table.concat(hover), M.doc.am_saving and "-" or tostring(pulse))
    if key == M.key then return end
    M.key = key
    local buf = {}
    -- drawDefaultBackground (world present): the gradient column stretched over the screen
    ui.background(buf, vw, vh)
    if saving and not M.doc.am_saving then
        font.draw_shadow(buf, "Saving level..", 8, h - 16, pulse * 65536 + pulse * 256 + pulse, sf)
    end
    font.draw_centered(buf, "Game menu", math.floor(w / 2), 40, 16777215, sf)
    for _, b in ipairs(buttons) do button_xml(buf, b, mx, my, sf) end
    local root = M.doc.root
    if root then
        local sz = root.size
        if sz[1] ~= vw or sz[2] ~= vh then root.size = {vw, vh} end
    end
    ui.replace(M.doc, "am_screen", buf, vw, vh)
end

-- normal launch, engine pause disabled (hud.lua): on focus loss Hud::processInput still opens the engine page
-- "pause" (without pausing). In game it is replaced by GuiIngameMenu like EntityRenderer.updateCameraAndRender
-- (displayInGameMenu when the window is inactive); our overlay counts as an open inventory, so the engine does not
-- open its page again. Called per frame by alphamine:game (normal launch only).
function M.focus_lost_check()
    local ok, page = pcall(function() return menu and menu.page end)
    if not ok or page ~= "pause" then return false end
    if hud.is_paused() then return false end            -- a real engine pause (allowed pause) is left alone
    local chat = require "alphamine:chat_gui"
    if chat.is_open() then
        -- Java: displayInGameMenu does nothing under GuiChat; the chat document becomes an overlay so the engine
        -- stops opening its pause page (chat_gui.lua header)
        pcall(function() menu:reset() end)
        pcall(gui.set_active_frame, "")
        chat.to_overlay()
        return true
    end
    if game.screen ~= "ingame" or M.screen then return false end
    pcall(function() menu:reset() end)
    pcall(gui.set_active_frame, "")
    M.open_menu()
    M.focus_menus = (M.focus_menus or 0) + 1
    if M.focus_menus <= 5 then log("engine pause page -> GuiIngameMenu (window lost focus), world keeps running") end
    return true
end

-- GuiConnectFailed.drawScreen: drawDefaultBackground, message at h/2 - 50, description at h/2 - 10, the button
function M.update_failed()
    local vw, vh = ui.viewport()
    local w, h, sf = ui.scaled(vw, vh)
    local px, py = mouse()
    local mx, my = to_gui(px, py, vw, vh, w, h)
    local buttons = failed_buttons(w, h)
    local hover = {}
    for _, b in ipairs(buttons) do hover[#hover + 1] = inside(b, mx, my) and "1" or "0" end
    local f = M.failed or {title = "", reason = ""}
    local key = ("failed|%dx%d|%s|%s|%s"):format(vw, vh, table.concat(hover), f.title, f.reason)
    if key == M.key then return end
    M.key = key
    local buf = {}
    ui.background(buf, vw, vh)
    font.draw_centered(buf, f.title, math.floor(w / 2), math.floor(h / 2) - 50, 16777215, sf)
    font.draw_centered(buf, f.reason, math.floor(w / 2), math.floor(h / 2) - 10, 16777215, sf)
    for _, b in ipairs(buttons) do button_xml(buf, b, mx, my, sf) end
    local root = M.doc.root
    if root then
        local sz = root.size
        if sz[1] ~= vw or sz[2] ~= vh then root.size = {vw, vh} end
    end
    ui.replace(M.doc, "am_screen", buf, vw, vh)
    if M.doc.am_saving then ui.replace(M.doc, "am_saving", {}, vw, vh) end
    M.saving_key = nil
end

return M
