-- Alpha InventoryPlayer (phase 3) + mirror into the engine inventory of the VoxelCore player.
--   main[0..35] = {id, count, meta}, current (0..8, hotbar) — the authoritative Alpha state;
--   packets: 17 AddToInventory -> add (addItemStackToInventory), 16 BlockItemSwitch sent by
--   PlayerControllerMP.syncCurrentPlayItem each tick when the held item id changes;
--   keys 1..9 -> current, Q -> drop one (dropPlayerItemWithRandomChoice, Packet21 from the client).
-- Engine mirror: Alpha slot 0..8 -> engine slot 0..8 (hotbar), 9..35 -> engine 10..36 (engine slot 9 = the
-- 10th hotbar cell Alpha does not have, kept empty); items: blocks -> generated `alphamine:<block>.item`,
-- other items -> `alphamine:item_<item>` (content/alphamine/items/*.json, tools/alphamine/gen_pack_items.py).
-- The mirror is only a view: engine-side edits (engine inventory UI) are overwritten on the next change.
local items = require "alphamine:items_table"

local M = {
    main = {},
    current = 0,
    synced_item = 0,     -- PlayerControllerMP.currentPlayerItem
    dirty = true,
    engine_slot = -1,
    vc_index = {},       -- alpha item id -> engine item index (0 = unknown)
    stats = {adds = 0, drops = 0, switches = 0, mirror_writes = 0, unknown_items = {}},
}

local function max_stack(id)
    local t = items[id]
    return t and t.max_stack or 64
end

local function vc_item(id)
    local v = M.vc_index[id]
    if v then return v end
    v = 0
    local t = items[id]
    if t then
        local names = id < 256 and {"alphamine:" .. t.name .. ".item", "alphamine:" .. t.name}
                      or {"alphamine:item_" .. t.name}
        for _, n in ipairs(names) do
            local ok, idx = pcall(item.index, n)
            if ok and idx and idx > 0 then v = idx; break end
        end
    end
    if v == 0 then M.stats.unknown_items[tostring(id)] = true end
    M.vc_index[id] = v
    return v
end
M.vc_item = vc_item

function M.reset()
    M.main, M.current, M.synced_item, M.dirty = {}, 0, 0, true
end

-- InventoryPlayer.storeItemStack / getFirstEmptyStack / storePartialItemStack
local function store_item_stack(id)
    for s = 0, 35 do
        local st = M.main[s]
        if st and st.id == id and st.count < max_stack(id) and st.count < 64 then return s end
    end
    return -1
end
local function first_empty()
    for s = 0, 35 do if not M.main[s] then return s end end
    return -1
end
local function store_partial(id, count)
    local s = store_item_stack(id)
    if s < 0 then s = first_empty() end
    if s < 0 then return count end
    local st = M.main[s]
    if not st then st = {id = id, count = 0, meta = 0}; M.main[s] = st end
    local n = count
    if n > max_stack(id) - st.count then n = max_stack(id) - st.count end
    if n > 64 - st.count then n = 64 - st.count end
    if n == 0 then return count end
    st.count = st.count + n
    st.anim = 5          -- ItemStack.animationsToGo (GuiIngame: hotbar item "pop")
    return count - n
end

-- addItemStackToInventory
function M.add(id, count, meta)
    M.stats.adds = M.stats.adds + 1
    M.dirty = true
    if meta == 0 then
        count = store_partial(id, count)
        if count == 0 then return true end
    end
    local s = first_empty()
    if s >= 0 then
        M.main[s] = {id = id, count = count, meta = meta, anim = 5}
        return true
    end
    return false
end

-- InventoryPlayer.decrementAnimations (EntityPlayer.onLivingUpdate, once per tick)
function M.decrement_animations()
    for s = 0, 35 do
        local st = M.main[s]
        if st and st.anim and st.anim > 0 then st.anim = st.anim - 1 end
    end
end

-- decrStackSize(slot, n) -> {id, count, meta} or nil
function M.decr(slot, n)
    local st = M.main[slot]
    if not st then return nil end
    M.dirty = true
    if st.count <= n then
        M.main[slot] = nil
        return st
    end
    st.count = st.count - n
    return {id = st.id, count = n, meta = st.meta}
end

function M.current_item()
    return M.main[M.current]
end

function M.set_current(slot)
    if slot ~= M.current then
        M.current = slot
        M.dirty = true
    end
end

-- PlayerControllerMP.onUpdate -> syncCurrentPlayItem: Packet16(0, id) when the held item id changed
function M.sync_current(net)
    local st = M.main[M.current]
    local id = st and st.id or 0
    if id ~= M.synced_item then
        M.synced_item = id
        M.stats.switches = M.stats.switches + 1
        net.send_item_switch(0, id)
    end
end

-- engine mirror (after the ticks of a frame)
function M.mirror(pid)
    if not M.dirty then return end
    local ok, invid, eslot = pcall(player.get_inventory, pid)
    if not ok or not invid then return end
    local size = inventory.size(invid)
    local function eng(s) return s < 9 and s or s + 1 end
    for s = 0, 35 do
        local e = eng(s)
        if e < size then
            local st = M.main[s]
            if st then
                local v = vc_item(st.id)
                inventory.set(invid, e, v, v ~= 0 and st.count or 0)
            else
                inventory.set(invid, e, 0, 0)
            end
        end
    end
    if size > 9 then inventory.set(invid, 9, 0, 0) end
    if eslot ~= M.current then player.set_selected_slot(pid, M.current) end
    M.engine_slot = M.current
    M.stats.mirror_writes = M.stats.mirror_writes + 1
    M.dirty = false
end

-- the engine may change its selected slot itself (mouse wheel, Hud::updateHotbarControl): follow it
function M.follow_engine(pid, hold)
    local ok, _, eslot = pcall(player.get_inventory, pid)
    if hold then
        -- a pack screen is open (GuiChat, GuiInventory): Java ignores digit keys there; put the engine slot back
        if ok and eslot and eslot ~= M.current then
            pcall(player.set_selected_slot, pid, M.current)
            M.engine_slot = M.current
        end
        return
    end
    if ok and eslot and eslot ~= M.engine_slot then
        local s = eslot
        if s > 8 then s = M.current == 0 and 8 or 0 end   -- the 10th engine cell: wrap like Alpha
        M.engine_slot = eslot
        M.set_current(s)
    end
end

-- F2F state: [{slot, id, count, meta}] like Java F2FAgent
function M.report()
    local out = {}
    for s = 0, 35 do
        local st = M.main[s]
        if st then out[#out + 1] = {slot = s, id = st.id, count = st.count, meta = st.meta} end
    end
    return out
end

-- ================================================================== phase 4: the inventory screen (GuiInventory)
-- Alpha 1.0.16 SMP has no window/slot packets: the client alone owns its inventory (InventoryPlayer: 36 main +
-- 4 armour, craftingInventory ItemStack[4] that stays in the player between openings), crafting is client-side
-- (CraftingManager.findMatchingRecipe over a 3x3 id grid, the 2x2 grid in its top-left corner), the server only
-- learns the held item (Packet16) and what is thrown (Packet21). GuiContainer.mouseClicked has no shift-click in
-- this version. Layout (GuiInventory, 176x166 at ((w-176)/2, (h-166)/2) in GUI units), slot order = Java
-- inventorySlots order (getSlotAtPosition takes the first hit):
--   1 result (144,36) | 2..5 craft grid c + r*2 at (88 + c*18, 26 + r*18) | 6..9 armour inv 39-k at (8, 8 + k*18)
--   (armorType k: 0 helmet .. 3 boots; background icon 15 + k*16 of gui/items.png) | 10..36 main 9..35 at
--   (8 + c*18, 84 + r*18) | 37..45 hotbar 0..8 at (8 + c*18, 142). A slot is hit on [x-1, x+17) x [y-1, y+17).
-- API for the screen document (agent U): M.gui_slots(), M.cursor, M.craft_result, M.click(n, button),
-- M.click_at(gx, gy, button, w, h), M.open_screen(), M.close_screen(), M.screen_open, hooks M.on_open/on_close.
local IT = require "alphamine:interact_table"

M.armor = {}          -- [0..3] (InventoryPlayer.armorInventory; slot 36 + i)
M.craft = {}          -- [0..3] (InventoryPlayer.craftingInventory)
M.craft_result = nil  -- InventoryCraftResult slot 0
M.cursor = nil        -- GuiContainer.l (the stack held by the mouse)
M.screen_open = false
M.on_open, M.on_close = nil, nil

local function max_stack_of(id)
    local t = IT.items[id]
    return t and t.max_stack or 64
end
local function new_stack(id, count, meta) return {id = id, count = count, meta = meta or 0} end
-- ItemStack.splitStack
local function split(st, n)
    st.count = st.count - n
    return new_stack(st.id, n, st.meta)
end

-- CraftingManager.findMatchingRecipe (CraftingRecipe.matches: both mirrorings at every offset)
local function check(r, grid, ox, oy, mirror)
    for x = 0, 2 do
        for y = 0, 2 do
            local a, b = x - ox, y - oy
            local want = -1
            if a >= 0 and b >= 0 and a < r.w and b < r.h then
                if mirror then want = r.map[(r.w - a - 1) + b * r.w + 1] else want = r.map[a + b * r.w + 1] end
            end
            if grid[x + y * 3] ~= want then return false end
        end
    end
    return true
end
function M.find_recipe(grid)
    for _, r in ipairs(IT.recipes) do
        for ox = 0, 3 - r.w do
            for oy = 0, 3 - r.h do
                if check(r, grid, ox, oy, true) or check(r, grid, ox, oy, false) then
                    return new_stack(r.id, r.count, 0)
                end
            end
        end
    end
    return nil
end

-- GuiInventory.a(craftingInventory): result from the 2x2 grid
function M.update_craft()
    local grid = {}
    for x = 0, 2 do
        for y = 0, 2 do
            local id = -1
            if x < 2 and y < 2 then
                local st = M.craft[x + y * 2]
                if st then id = st.id end
            end
            grid[x + y * 3] = id
        end
    end
    M.craft_result = M.find_recipe(grid)
end

-- IInventory views: get / set / decr (decrStackSize) per inventory kind
local INV = {}
INV.main = {
    get = function(i) if i >= 36 then return M.armor[i - 36] end return M.main[i] end,
    set = function(i, st) if i >= 36 then M.armor[i - 36] = st else M.main[i] = st end; M.dirty = true end,
    decr = function(i, n)
        local arr, k = M.main, i
        if i >= 36 then arr, k = M.armor, i - 36 end
        local st = arr[k]
        if not st then return nil end
        M.dirty = true
        if st.count <= n then arr[k] = nil; return st end
        local r = split(st, n)
        if st.count == 0 then arr[k] = nil end
        return r
    end,
}
INV.craft = {
    get = function(i) return M.craft[i] end,
    set = function(i, st) M.craft[i] = st; M.update_craft() end,
    decr = function(i, n)
        local st = M.craft[i]
        if not st then return nil end
        local r
        if st.count <= n then M.craft[i] = nil; r = st
        else r = split(st, n); if st.count == 0 then M.craft[i] = nil end end
        M.update_craft()
        return r
    end,
}
INV.result = {
    get = function() return M.craft_result end,
    set = function(_, st) M.craft_result = st end,
    decr = function() local st = M.craft_result; M.craft_result = nil; return st end,
}

local SLOTS
local function build_slots()
    SLOTS = {}
    local function add(t) SLOTS[#SLOTS + 1] = t; t.n = #SLOTS end
    add({kind = "result", inv = "result", slot = 0, x = 144, y = 36})
    for r = 0, 1 do for c = 0, 1 do add({kind = "craft", inv = "craft", slot = c + r * 2, x = 88 + c * 18, y = 26 + r * 18}) end end
    for k = 0, 3 do add({kind = "armor", inv = "main", slot = 39 - k, x = 8, y = 8 + k * 18, armor_type = k, bg = 15 + k * 16}) end
    for r = 0, 2 do for c = 0, 8 do add({kind = "main", inv = "main", slot = c + (r + 1) * 9, x = 8 + c * 18, y = 84 + r * 18}) end end
    for c = 0, 8 do add({kind = "hotbar", inv = "main", slot = c, x = 8 + c * 18, y = 142}) end
end
build_slots()
M.SLOTS = SLOTS

-- InventoryPlayer-style indices for the screen document (agent U, inventory_gui.lua): 0..35 main, 36..39 armour
-- (armorInventory[i - 36]), 40..43 the 2x2 crafting grid (craftingInventory[i - 40])
function M.get_slot(i)
    if i >= 40 then return M.craft[i - 40] end
    if i >= 36 then return M.armor[i - 36] end
    return M.main[i]
end
function M.set_slot(i, st)
    if i >= 40 then M.craft[i - 40] = st; M.update_craft()
    elseif i >= 36 then M.armor[i - 36] = st
    else M.main[i] = st end
    M.dirty = true
end
function M.decr_slot(i, n)   -- IInventory.decrStackSize
    if i >= 40 then return INV.craft.decr(i - 40, n) end
    return INV.main.decr(i, n)
end

-- the screen's slots with their stacks: {n, kind, slot, x, y (GUI units inside the 176x166 panel), stack, bg}
function M.gui_slots()
    local out = {}
    for i, s in ipairs(SLOTS) do
        out[i] = {n = s.n, kind = s.kind, slot = s.slot, x = s.x, y = s.y, stack = INV[s.inv].get(s.slot),
                  bg = s.bg, armor_type = s.armor_type}
    end
    return out
end

local function valid(s, st)
    if s.kind == "result" then return false end
    if s.kind == "armor" then
        local it = IT.items[st.id]
        return it ~= nil and it.cls == "ItemArmor" and it.armor_type == s.armor_type
    end
    return true
end

local function put(s, st) INV[s.inv].set(s.slot, st) end
local function pickup_done(s)
    if s.kind == "result" then
        -- SlotCrafting.onPickupFromSlot: one of each ingredient
        for i = 0, 3 do if M.craft[i] then INV.craft.decr(i, 1) end end
    end
end

-- GuiContainer.mouseClicked on slot n (1-based, SLOTS order), button 0 left / 1 right
function M.click(n, button)
    if button ~= 0 and button ~= 1 then return end
    local s = SLOTS[n]
    if not s then return end
    local I = INV[s.inv]
    local st = I.get(s.slot)
    local cur = M.cursor
    local LIMIT = 64
    M.stats.clicks = (M.stats.clicks or 0) + 1
    if not st and not cur then return end
    if st and not cur then
        local k = button == 0 and st.count or math.floor((st.count + 1) / 2)
        M.cursor = I.decr(s.slot, k)
        if st.count == 0 then put(s, nil) end
        pickup_done(s)
    elseif not st and cur and valid(s, cur) then
        local k = button == 0 and cur.count or 1
        if k > LIMIT then k = LIMIT end
        put(s, split(cur, k))
        if cur.count == 0 then M.cursor = nil end
    elseif st and cur then
        if valid(s, cur) then
            if st.id ~= cur.id then
                if cur.count <= LIMIT then
                    put(s, cur)
                    M.cursor = st
                end
            else
                local k = button == 0 and cur.count or 1
                if k > LIMIT - st.count then k = LIMIT - st.count end
                if k > max_stack_of(cur.id) - st.count then k = max_stack_of(cur.id) - st.count end
                split(cur, k)
                if cur.count == 0 then M.cursor = nil end
                st.count = st.count + k
                if s.inv == "craft" then M.update_craft() end
            end
        elseif st.id == cur.id and max_stack_of(cur.id) > 1 then
            local k = st.count
            if k > 0 and k + cur.count <= max_stack_of(cur.id) then
                cur.count = cur.count + k
                split(st, k)
                if st.count == 0 then put(s, nil) end
                pickup_done(s)
            end
        end
    end
    M.dirty = true
end

-- EntityPlayer.dropPlayerItem from the screen (player.lua drop = Packet21)
local function drop(stack)
    local pl = package.loaded["alphamine:modules/player.lua"]
    local net = package.loaded["alphamine:modules/net.lua"]
    if stack and pl and net then pl.drop(stack, net); M.stats.drops = M.stats.drops + 1 end
end

-- mouseClicked at GUI coordinates (gx, gy) of a w x h scaled screen
function M.click_at(gx, gy, button, w, h)
    local ox, oy = math.floor((w - 176) / 2), math.floor((h - 166) / 2)
    local mx, my = gx - ox, gy - oy
    for _, s in ipairs(SLOTS) do
        if mx >= s.x - 1 and mx < s.x + 17 and my >= s.y - 1 and my < s.y + 17 then
            M.click(s.n, button)
            return s.n
        end
    end
    if M.cursor and (button == 0 or button == 1) then
        -- outside the panel (Java checks the height against xSize = 176)
        if gx < ox or gy < oy or gx >= ox + 176 or gy >= oy + 176 then
            if button == 0 then
                drop(M.cursor)
                M.cursor = nil
            else
                drop(split(M.cursor, 1))
                if M.cursor.count == 0 then M.cursor = nil end
            end
            M.dirty = true
            return "drop"
        end
    end
    return nil
end

-- the slot under GUI coordinates (hover highlight)
function M.slot_at(gx, gy, w, h)
    local ox, oy = math.floor((w - 176) / 2), math.floor((h - 166) / 2)
    local mx, my = gx - ox, gy - oy
    for _, s in ipairs(SLOTS) do
        if mx >= s.x - 1 and mx < s.x + 17 and my >= s.y - 1 and my < s.y + 17 then return s.n end
    end
    return nil
end

-- displayGuiScreen(new GuiInventory(...)) / displayGuiScreen(null) (GuiContainer.onGuiClosed drops the cursor)
function M.open_screen()
    if M.screen_open then return end
    M.screen_open = true
    M.update_craft()
    local g = package.loaded["alphamine:modules/game.lua"]
    if g then g.screen = "GuiInventory" end
    M.stats.opened = (M.stats.opened or 0) + 1
    if M.on_open then pcall(M.on_open) end
end
function M.close_screen()
    if not M.screen_open then return end
    M.screen_open = false
    if M.cursor then drop(M.cursor); M.cursor = nil end
    local g = package.loaded["alphamine:modules/game.lua"]
    if g and g.screen == "GuiInventory" then g.screen = "ingame" end
    M.dirty = true
    if M.on_close then pcall(M.on_close) end
end

-- F2F / state: armour, grid, cursor, result like the Java objects
function M.report_screen()
    local function rs(st) return st and {id = st.id, count = st.count, meta = st.meta} or nil end
    local r = {open = M.screen_open, armor = {}, craft = {}, cursor = rs(M.cursor), result = rs(M.craft_result)}
    for i = 0, 3 do
        if M.armor[i] then r.armor[#r.armor + 1] = {slot = 36 + i, id = M.armor[i].id, count = M.armor[i].count} end
        if M.craft[i] then r.craft[#r.craft + 1] = {slot = i, id = M.craft[i].id, count = M.craft[i].count} end
    end
    return r
end

return M
