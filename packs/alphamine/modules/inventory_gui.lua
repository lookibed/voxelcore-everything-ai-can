-- GuiInventory of the Alpha client (phase 3, agent U) as an engine XML document (layouts/inventory.xml,
-- hud.show_overlay -> F2F layer `gui`; the engine releases the cursor and blocks the player while it is open).
-- Java: GuiInventory + GuiContainer + SlotInventory/SlotArmor/SlotCrafting.
--   drawScreen: drawDefaultBackground, gui/inventory.png 176x166 at ((w-176)/2, (h-166)/2), the player model
--   (modules/inv_preview.lua), every slot in order: item (RenderItem 3D icon / flat icon) + count/damage, empty armour
--   slot -> items.png icon 15 + type*16, the slot under the cursor -> 0x80FFFFFF over 16x16; the stack held by the
--   cursor at (mouse - 8); "Crafting" at (86, 16) 0x404040 without shadow (foreground layer, drawn last).
--   keyTyped: Esc or the inventory key closes; onGuiClosed drops the held stack.
-- The model -- slots in GuiInventory order, the cursor stack, the 2x2 grid with its CraftingManager result and
-- GuiContainer.mouseClicked (left/right, no shift-click in Alpha 1.0.16, drop outside the window) -- is
-- alphamine:inventory (agent P): one source of truth for the screen, F2F state and the engine mirror. This module
-- opens/closes the document, draws the model and routes clicks and keys (F2F `gui`, runtime mouse/keys).
local game = require "alphamine:game"
local ui = require "alphamine:ui"
local font = require "alphamine:font"
local inv = require "alphamine:inventory"

local M = {open = false, doc = nil, key = nil, poll = {}, stats = {clicks = 0, opens = 0}}

local LAYOUT = "alphamine:inventory"
local XS, YS = 176, 166

local function log(m) debug.log("[alphamine_inv] " .. m) end

-- ------------------------------------------------------------------ geometry
local function geometry()
    local vw, vh = ui.viewport()
    local w, h, sf = ui.scaled(vw, vh)
    return vw, vh, w, h, sf, math.floor((w - XS) / 2), math.floor((h - YS) / 2)
end

local function over(s, mx, my, left, top)   -- SlotInventory.getIsMouseOverSlot
    local x, y = mx - left, my - top
    return x >= s.x - 1 and x < s.x + 16 + 1 and y >= s.y - 1 and y < s.y + 16 + 1
end

local function mouse_gui()
    local vw, vh, w, h = geometry()
    local ok, pos = pcall(input.get_mouse_pos)
    local px, py = -1, -1
    if ok and type(pos) == "table" then px, py = pos[1], pos[2] end
    return require("alphamine:gui").to_gui(px, py, vw, vh, w, h)
end

-- GuiContainer.mouseClicked at GUI (mx, my): slot number (inventory.lua order), "drop" or nil
function M.mouse_clicked(mx, my, button)
    if button ~= 0 and button ~= 1 then return nil end
    M.stats.clicks = M.stats.clicks + 1
    local _, _, w, h = geometry()
    return inv.click_at(mx, my, button, w, h)
end

-- ------------------------------------------------------------------ open / close
function M.is_open() return M.open end

function M.open_screen()
    if M.open then return end
    M.open = true
    M.stats.opens = M.stats.opens + 1
    M.key = nil
    inv.open_screen()                     -- GuiInventory: result of the grid (this.a(craftingInventory))
    require("alphamine:inv_preview").reset()
    game.screen = "GuiInventory"
    M.poll = {}
    for _, k in ipairs({"mouse:left", "mouse:right", "key:i", "key:e"}) do
        local ok, v = pcall(input.is_pressed, k)
        M.poll[k] = ok and v or false
    end
    hud.show_overlay(LAYOUT, false)
end

local function closed()
    if not M.open then return end
    M.open = false
    inv.close_screen()                    -- GuiContainer.onGuiClosed: the cursor stack is dropped (Packet21)
    if game.screen == "GuiInventory" then game.screen = "ingame" end
end

function M.close()
    if not M.open then return end
    closed()
    if hud.is_open(LAYOUT) then hud.close(LAYOUT) end
end

function M.attach(doc)
    M.doc = doc
    M.key = nil
end

function M.detach()
    M.doc = nil
    closed()   -- closed by the engine (Esc with an open overlay)
end

-- F2F `gui {click:[x,y], button?, key?}` while the inventory is open (frame pixels)
function M.handle(args)
    local res = {}
    if args.key then
        local k = tostring(args.key):upper()
        res.key = k
        if k == "ESCAPE" or k == "1" or k == "I" or k == "23" or k == "E" then M.close() else res.ignored = true end
    end
    if args.click and M.open then
        local vw, vh, w, h = geometry()
        local mx, my = require("alphamine:gui").to_gui(args.click[1], args.click[2], vw, vh, w, h)
        res.gui = {mx, my}
        res.slot = M.mouse_clicked(mx, my, tonumber(args.button) or 0)
    end
    res.screen = game.screen
    return res
end

-- per frame before the world pass (hand.lua's stdcomp.render hook): runtime clicks and keys of the open screen
-- (rising edges; F2F `input` buttons/keys go the same way, F2F `gui` calls M.handle)
function M.frame()
    if not M.open then return end
    local function edge(k)
        local ok, v = pcall(input.is_pressed, k)
        v = ok and v or false
        local e = v and not M.poll[k]
        M.poll[k] = v
        return e
    end
    local l, r = edge("mouse:left"), edge("mouse:right")
    local ki, ke = edge("key:i"), edge("key:e")
    if l or r then
        local mx, my = mouse_gui()
        if l then M.mouse_clicked(mx, my, 0) end
        if r then M.mouse_clicked(mx, my, 1) end
    end
    if ki or ke then M.close() end
end

-- ------------------------------------------------------------------ drawing
local function stack_key(st)
    return st and ("%d:%d:%d"):format(st.id, st.count, st.meta or 0) or "-"
end

function M.update()
    if not M.doc or not M.open then return end
    local vw, vh, w, h, sf, left, top = geometry()
    local mx, my = mouse_gui()
    local sl = inv.gui_slots()
    local parts = {vw, vh, mx, my, stack_key(inv.cursor), stack_key(inv.craft_result)}
    for _, s in ipairs(sl) do parts[#parts + 1] = stack_key(s.stack) end
    local pv = require "alphamine:inv_preview"
    parts[#parts + 1] = pv.key(mx, my, left, top)
    local key = table.concat(parts, "|")
    if key == M.key then
        pv.end_frame(mx, my)   -- GuiInventory.drawScreen: xSize_lo / ySize_lo = this frame's mouse
        return
    end
    M.key = key
    local hudm = require "alphamine:hud"
    local buf = {}
    -- drawDefaultBackground (world present)
    ui.background(buf, vw, vh)
    -- drawGuiContainerBackgroundLayer: inventory.png + the player
    ui.rect(buf, "gui/am_inventory", 256, 256, left, top, 0, 0, XS, YS, sf)
    local okx, err = pcall(pv.xml, buf, left, top, mx, my, sf, vw, vh)
    if not okx and not M.preview_err then
        M.preview_err = true
        log("preview error: " .. tostring(err))
    end
    for _, s in ipairs(sl) do
        local st = s.stack
        local x, y = left + s.x, top + s.y
        if not st and s.bg then
            local idx = s.bg
            ui.rect(buf, "gui/am_items", 256, 256, x, y, idx % 16 * 16, math.floor(idx / 16) * 16, 16, 16, sf)
        elseif st then
            hudm.item_xml(buf, st, x, y, sf)
        end
        if over(s, mx, my, left, top) then
            ui.fill(buf, x, y, x + 16, y + 16, 0x80FFFFFF, sf)
        end
    end
    if inv.cursor then
        hudm.item_xml(buf, inv.cursor, mx - 8, my - 8, sf)
    end
    font.draw(buf, "Crafting", left + 86, top + 16, 0x404040, sf)
    local root = M.doc.root
    if root then
        local sz = root.size
        if sz[1] ~= vw or sz[2] ~= vh then root.size = {vw, vh} end
    end
    ui.replace(M.doc, "am_screen", buf, vw, vh)
    pv.end_frame(mx, my)
end

-- F2F state (inventory.lua: open, armor, craft, cursor, result)
function M.report()
    return inv.report_screen()
end

return M
