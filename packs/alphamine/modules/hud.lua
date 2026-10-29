-- HUD of the Alpha client (phase 3): GuiIngame.renderGameOverlay as an engine XML document (layouts/hud.xml,
-- hud.open_permanent -> F2F layer `hud`). Hotbar and selection from gui/gui.png, hearts/armour/air from
-- gui/icons.png (jitter: java.util.Random.setSeed(updateCounter * 312871)), hotbar items (3D blocks prerendered
-- by tools/alphamine/gen_ui_assets.py, flat icons from items.png/terrain.png), stack sizes and damage bars,
-- "Minecraft Alpha v1.0.16" and chat lines with the Alpha font (modules/font.lua).
-- The crosshair is the engine's own (Hud::draw, BlendMode::inversion = ONE_MINUS_DST_COLOR, ONE_MINUS_SRC_ALPHA)
-- with textures/gui/crosshair.png replaced by the Alpha icon: XML elements have no blend modes, and with the
-- binary alpha of icons.png (RGB 0 under alpha 0) that blend equals Java's ONE_MINUS_DST_COLOR, ONE_MINUS_SRC_COLOR.
-- Not done: vignette (fancy graphics, GL_ZERO/ONE_MINUS_SRC_COLOR multiply -- no multiply blend in XML), the
-- pickup "pop" animation of hotbar items (animationsToGo), record "Now playing", F3 lines 2-4.
local game = require "alphamine:game"
local pl = require "alphamine:player"
local ui = require "alphamine:ui"
local font = require "alphamine:font"
local T = require "alphamine:ui_tables"
local JRandom = require "alphamine:jrandom"

local M = {doc = nil, keys = {}, show_debug = false, rand = JRandom.new(0)}

local GUI_TEX, ICONS_TEX = "gui/am_gui", "gui/am_icons"
local VERSION = "Minecraft Alpha v1.0.16"

local function log(m) debug.log("[alphamine_hud] " .. m) end

local function selected_slot()
    local ok, inv = pcall(require, "alphamine:inventory")
    if ok and inv and inv.current then return inv.current end
    return game.selected_slot or game.slot or 0
end

-- the document script (layouts/hud.xml.lua) hands its document over
function M.attach(doc)
    M.doc = doc
    M.keys = {}
end

-- the engine's hotbar (Hud::hotbarView, id "hud.hotbar" in the root document) is re-shown by Hud::update every
-- frame: move it into a hidden container of our document so it is never drawn
local function hide_engine_hotbar()
    local ok, hb = pcall(function() return gui.root["hud.hotbar"] end)
    if ok and hb and hb.exists and M.doc and M.doc.am_trash then
        local ok2, err = pcall(function() hb:moveInto(M.doc.am_trash) end)
        if not ok2 then log("cannot hide the engine hotbar: " .. tostring(err)) end
        return ok2
    end
    return false
end

function M.on_hud_open(playerid)
    hud.open_permanent("alphamine:hud")
    M.hotbar_hidden = hide_engine_hotbar()
    require("alphamine:hand").init()
    require("alphamine:gui").install_escape()
    -- normal launch: the engine must not pause the world when the window loses focus (Alpha SMP never pauses:
    -- Minecraft.isGamePaused = !isMultiplayerWorld() && ...; a paused engine stops on_world_tick -> no Alpha ticks, no
    -- packets, the server drops the client after 60 s). hud.set_allow_pause(false) keeps the world running; the
    -- engine still shows its "pause" page on focus loss, alphamine:gui.focus_lost replaces it by GuiIngameMenu
    -- (EntityRenderer.updateCameraAndRender: !Display.isActive() -> displayInGameMenu). F2F: unchanged.
    local f2f_on = require("alphamine:f2f").active()
    if not f2f_on and hud.set_allow_pause then
        hud.set_allow_pause(false)
        M.pause_disabled = true
    end
    log("open, engine hotbar hidden: " .. tostring(M.hotbar_hidden) .. ", engine pause " ..
        (M.pause_disabled and "disabled" or "kept"))
end

-- ------------------------------------------------------------------ parts
local function build_hotbar(w, h, sf)
    local b = {}
    ui.rect(b, GUI_TEX, 256, 256, math.floor(w / 2) - 91, h - 22, 0, 0, 182, 22, sf)
    ui.rect(b, GUI_TEX, 256, 256, math.floor(w / 2) - 91 - 1 + selected_slot() * 20, h - 22 - 1, 0, 22, 24, 22, sf)
    return b
end

local function hearts_state()
    local health = pl.health or 20
    local prev = pl.prev_health or health
    local life = pl.hearts_life or 0
    local flash = math.floor(life / 3) % 2 == 1 and life >= 10
    local armor = game.armor_value or 0
    local air = pl.air
    local in_water = pl.in_water and air ~= nil
    return health, prev, flash, armor, in_water and air or nil
end

local function build_hearts(w, h, sf, health, prev, flash, armor, air, counter)
    local b = {}
    M.rand:set_seed(JRandom.imul(counter, 312871))
    for i = 0, 9 do
        local y = h - 32
        if armor > 0 then
            local ax = math.floor(w / 2) + 91 - i * 8 - 9
            if i * 2 + 1 < armor then ui.rect(b, ICONS_TEX, 256, 256, ax, y, 34, 9, 9, 9, sf) end
            if i * 2 + 1 == armor then ui.rect(b, ICONS_TEX, 256, 256, ax, y, 25, 9, 9, 9, sf) end
            if i * 2 + 1 > armor then ui.rect(b, ICONS_TEX, 256, 256, ax, y, 16, 9, 9, 9, sf) end
        end
        local x = math.floor(w / 2) - 91 + i * 8
        if health <= 4 then y = y + M.rand:next_int(2) end
        ui.rect(b, ICONS_TEX, 256, 256, x, y, 16 + (flash and 9 or 0), 0, 9, 9, sf)
        if flash then
            if i * 2 + 1 < prev then ui.rect(b, ICONS_TEX, 256, 256, x, y, 70, 0, 9, 9, sf) end
            if i * 2 + 1 == prev then ui.rect(b, ICONS_TEX, 256, 256, x, y, 79, 0, 9, 9, sf) end
        end
        if i * 2 + 1 < health then ui.rect(b, ICONS_TEX, 256, 256, x, y, 52, 0, 9, 9, sf) end
        if i * 2 + 1 == health then ui.rect(b, ICONS_TEX, 256, 256, x, y, 61, 0, 9, 9, sf) end
    end
    if air then
        local full = math.ceil((air - 2) * 10 / 300)
        local pop = math.ceil(air * 10 / 300) - full
        for i = 0, full + pop - 1 do
            ui.rect(b, ICONS_TEX, 256, 256, math.floor(w / 2) - 91 + i * 8, h - 32 - 9, i < full and 16 or 25, 18, 9, 9, sf)
        end
    end
    return b
end

-- RenderItem.renderItemIntoGUI + renderItemOverlayIntoGUI at GUI (x, y); pop = GuiIngame.renderInventorySlot's
-- animationsToGo - partial (> 0: the icon is scaled by 1/k, (k+1)/2 about (x+8, y+12), k = 1 + pop/5)
function M.item_xml(b, stack, x, y, sf, pop)
    local ic = T.icons[stack.id]
    if not ic then return end
    local kx, ky = ui.kxy(sf)
    local cx, cy, sx, sy = x + 8, y + 12, 1, 1
    if pop and pop > 0 then
        local k = 1 + pop / 5
        sx, sy = 1 / k, (k + 1) / 2
    end
    local function gx(v) return (cx + (v - cx) * sx) * kx end
    local function gy(v) return (cy + (v - cy) * sy) * ky end
    local drawn = false
    local integer = kx == math.floor(kx) and ky == math.floor(ky) and ic.scales and ic.scales[sf]
    if ic.scales and not (integer and (not pop or pop <= 0)) then
        -- fractional GUI unit or the pickup pop: rasterised for this exact position (inv_preview.lua)
        local okp, pv = pcall(require, "alphamine:inv_preview")
        if okp and pv.icon_xml and pv.icon_xml(b, stack.id, x, y, kx, ky, pop) then drawn = true end
    end
    if drawn then
        -- drawn above
    elseif ic.scales then
        local s = ic.scales[sf] or ic.scales[2]
        local at = T.icon_atlas[sf] or T.icon_atlas[2]
        local base = ic.scales[sf] and sf or 2
        -- prerendered at the integer scale `base` (pixel offset/size from the slot origin); a fractional GUI scale
        -- (1390x855: 3.00216 x 3) or the pickup pop stretches it
        local x0, y0 = x + s[1] / base, y + s[2] / base
        local x1, y1 = x0 + s[3] / base, y0 + s[4] / base
        ui.quad(b, at[1], gx(x0), gy(y0), gx(x1), gy(y1), s[5] / at[2], s[6] / at[3], (s[5] + s[3]) / at[2],
            (s[6] + s[4]) / at[3])
    else
        local idx = ic.index
        local u, v = idx % 16 * 16, math.floor(idx / 16) * 16
        ui.quad(b, ic.atlas, gx(x), gy(y), gx(x + 16), gy(y + 16), u / 256, v / 256, (u + 16) / 256, (v + 16) / 256)
    end
    if stack.count and stack.count > 1 then
        local s = tostring(stack.count)
        font.draw_shadow(b, s, x + 19 - 2 - font.width(s), y + 6 + 3, 0xFFFFFF, sf)
    end
    local dmg = stack.meta or 0
    local maxd = ic.max_damage or 0
    if dmg > 0 and maxd > 0 then
        local len = 13 - math.floor(dmg * 13 / maxd)
        local c = 255 - math.floor(dmg * 255 / maxd)
        local c9 = (255 - c) * 65536 + c * 256
        local c10 = math.floor((255 - c) / 4) * 65536 + 16128
        ui.fill(b, x + 2, y + 13, x + 2 + 13, y + 13 + 2, 0xFF000000, sf)
        ui.fill(b, x + 2, y + 13, x + 2 + 12, y + 13 + 1, 0xFF000000 + c10, sf)
        ui.fill(b, x + 2, y + 13, x + 2 + len, y + 13 + 1, 0xFF000000 + c9, sf)
    end
end

-- ItemStack.animationsToGo (inventory.lua: `anim`, set 5 on pickup, -1 per tick) - renderPartialTicks
local function pop_of(st)
    if not st or not st.anim or st.anim <= 0 then return 0 end
    local p = st.anim - (game.partial and game.partial() or 0)
    return p > 0 and p or 0
end

local function build_items(w, h, sf)
    local b = {}
    for i = 0, 8 do
        local st = game.inventory[i]
        if st and st.id and st.id > 0 then
            M.item_xml(b, st, math.floor(w / 2) - 90 + i * 20 + 2, h - 16 - 3, sf, pop_of(st))
        end
    end
    return b
end

local function items_key()
    local parts = {}
    for i = 0, 8 do
        local st = game.inventory[i]
        parts[#parts + 1] = st and ("%d:%d:%d:%g"):format(st.id or 0, st.count or 0, st.meta or 0, pop_of(st)) or "-"
    end
    return table.concat(parts, ",")
end

local function build_text(w, h, sf)
    local b = {}
    if M.show_debug then
        local dbg = game.f2f and "0 fps, 0 chunk updates" or (M.debug_fps or "0 fps, 0 chunk updates")
        font.draw_shadow(b, VERSION .. " (" .. dbg .. ")", 2, 2, 0xFFFFFF, sf)
    else
        font.draw_shadow(b, VERSION, 2, 2, 0xFFFFFF, sf)
    end
    return b
end

-- chat: newest first at h-48 upwards, 200 ticks visible, fade in the last 20
local function chat_lines(open)
    local out = {}
    local limit = open and 20 or 10
    for i, c in ipairs(game.chat) do
        if i > limit then break end
        if c.age < 200 or open then
            local t = 1.0 - c.age / 200.0
            t = t * 10.0
            if t < 0 then t = 0 end
            if t > 1 then t = 1 end
            t = t * t
            local a = math.floor(255.0 * t)
            if open then a = 255 end
            if a > 0 then out[#out + 1] = {i - 1, c.text, a} end
        end
    end
    return out
end

local function build_chat(w, h, sf, lines)
    local b = {}
    local base = h - 48
    for _, l in ipairs(lines) do
        local y = -l[1] * 9
        ui.fill(b, 2, base + y - 1, 2 + 320, base + y + 8, math.floor(l[3] / 2) * 16777216, sf)
        font.draw_shadow(b, l[2], 2, base + y, 0xFFFFFF + l[3] * 16777216, sf)
    end
    return b
end

-- GuiIngame.renderVignette (fancy graphics): prevVignetteBrightness += (clamp(1 - brightness) - prev) * 0.01 per
-- rendered frame; drawn as a black image whose alpha = vignette luminance x prev (same result as the Java
-- GL_ZERO / GL_ONE_MINUS_SRC_COLOR multiply)
M.vignette = 1.0
local function vignette_target()
    local b = 1.0
    local ok, phys = pcall(require, "alphamine:physics")
    if ok and phys and phys.brightness and pl.has_pos then
        local ok2, v = pcall(phys.brightness, math.floor(pl.x), math.floor(pl.bb[2] + 1.8 * 0.66), math.floor(pl.z))
        if ok2 and v then b = v end
    end
    local t = 1.0 - b
    if t < 0 then t = 0 end
    if t > 1 then t = 1 end
    return t
end
-- F2F `mode` (as Java F2FAgent.mode, E2E 01.10): the smoothing starts at its fixed point, not at whatever the
-- frames of the network waits before mode left (Java vs Java differed by 1 in the vignette otherwise)
function M.vignette_reset()
    M.vignette = vignette_target()
    M.vignette_a = nil
end
local function update_vignette(vw, vh)
    local el = M.doc.am_vignette
    if not el then return end
    local t = vignette_target()
    M.vignette = M.vignette + (t - M.vignette) * 0.01
    local a = math.floor(M.vignette * 255 + 0.5)
    if a ~= M.vignette_a then
        M.vignette_a = a
        el.color = {0, 0, 0, a}
    end
    local sz = el.size
    if sz[1] ~= vw or sz[2] ~= vh then el.size = {vw, vh} end
end

-- The crosshair is the engine's texture gui/crosshair (64x64, centred by Hud::draw at ((vw-64)/2, (vh-64)/2) with
-- integer division); GuiIngame draws icons.png (0, 0, 16, 16) at GUI (w/2 - 7, h/2 - 7) with the GUI ortho stretched
-- over the frame. For frame sizes other than 854x480 (the generated texture) the texels are redrawn here: every frame
-- pixel whose centre the Java quad covers gets the icon texel Java samples (NEAREST), offset into the texture.
local CROSS = 64
local function update_crosshair(vw, vh, w, h, sf)
    local key = vw .. "x" .. vh
    if M.cross_key == key then return end
    M.cross_key = key
    local ok, c = pcall(assets.to_canvas, "gui/crosshair")
    if not ok or not c then
        log("crosshair: no canvas (" .. tostring(c) .. ")")
        return
    end
    local okd, src = pcall(function()
        local ic = Canvas.decode(file.read_bytes("alphamine:textures/gui/am_icons.png"), "png")
        return {w = ic.width, h = ic.height, data = ic:get_data()}
    end)
    if not okd then
        log("crosshair: " .. tostring(src))
        return
    end
    local kx, ky = ui.kxy(sf)
    local x0, y0 = math.floor((vw - CROSS) / 2), math.floor((vh - CROSS) / 2)
    local ax, ay = (math.floor(w / 2) - 7) * kx, (math.floor(h / 2) - 7) * ky
    local data = {}
    for i = 1, CROSS * CROSS * 4 do data[i] = 0 end
    for ty = 0, CROSS - 1 do
        local py = y0 + ty
        local gy = (py + 0.5 - ay) / ky
        if gy >= 0 and gy < 16 then
            local tv = math.floor(gy)
            for tx = 0, CROSS - 1 do
                local px = x0 + tx
                local gx = (px + 0.5 - ax) / kx
                if gx >= 0 and gx < 16 then
                    local tu = math.floor(gx)
                    local sp = ((src.h - 1 - tv) * src.w + tu) * 4        -- decoded canvas rows are bottom-up
                    local dp = ((CROSS - 1 - ty) * CROSS + tx) * 4
                    if src.data[sp + 4] > 25 then
                        data[dp + 1], data[dp + 2], data[dp + 3], data[dp + 4] =
                            src.data[sp + 1], src.data[sp + 2], src.data[sp + 3], src.data[sp + 4]
                    end
                end
            end
        end
    end
    c:set_data(data)
    c:update()
    log(("crosshair for %dx%d: icon at (%.2f, %.2f), texture at (%d, %d)"):format(vw, vh, ax, ay, x0, y0))
end

-- ------------------------------------------------------------------ per frame
M.rebuilds = {}   -- [id] = XML rebuilds (perf diagnostics, logged with the status line of dev runs)
local function part(id, key, builder, vw, vh)
    if M.keys[id] == key then return end
    M.keys[id] = key
    M.rebuilds[id] = (M.rebuilds[id] or 0) + 1
    ui.replace(M.doc, id, builder(), vw, vh)
end

-- like part(), for content whose layout stays and only colours change (the chat fade: alpha per tick for the
-- last 20 ticks of a line): the elements get ids at the structural build; when only `key` changes (not `skey`)
-- the new colours are set in place (element.color) instead of rebuilding the XML (~20 ms per rebuild, measured by
-- the perf suite: the fade of one chat line cost ~1 s at ~20 fps). Pixels are the same: the same colours.
M.fade = {}
local function hex_rgba(h)
    local r, g, b = tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
    local a = #h >= 8 and tonumber(h:sub(7, 8), 16) or 255
    return {r, g, b, a}
end
local function part_fade(id, skey, key, builder, vw, vh)
    if M.keys[id] == key then return end
    local b = builder()
    local f = M.fade[id]
    if f and f.skey == skey and f.n == #b and M.keys[id] ~= nil then
        local ok = true
        local cols = {}
        for i, s in ipairs(b) do cols[i] = s:match('color="#(%x+)"') or false end
        for i = 1, #b do
            if cols[i] ~= f.cols[i] then
                local el = cols[i] and M.doc[id .. "_e" .. i]
                if not el then ok = false break end
                el.color = hex_rgba(cols[i])
            end
        end
        if ok then
            f.cols = cols
            M.keys[id] = key
            return
        end
    end
    local cols = {}
    for i, s in ipairs(b) do
        cols[i] = s:match('color="#(%x+)"') or false
        b[i] = s:gsub("^<(%w+) ", '<%1 id="' .. id .. "_e" .. i .. '" ', 1)
    end
    M.fade[id] = {skey = skey, n = #b, cols = cols}
    M.keys[id] = key
    M.rebuilds[id] = (M.rebuilds[id] or 0) + 1
    ui.replace(M.doc, id, b, vw, vh)
end

function M.update()
    local doc = M.doc
    if not doc then return end
    if not M.hotbar_hidden then M.hotbar_hidden = hide_engine_hotbar() end
    local vw, vh = ui.viewport()
    local w, h, sf = ui.scaled(vw, vh)
    local geo = ("%dx%d"):format(vw, vh)
    if doc.root then
        local sz = doc.root.size
        if sz[1] ~= vw or sz[2] ~= vh then doc.root.size = {vw, vh} end
    end
    update_vignette(vw, vh)
    if vw ~= 854 or vh ~= 480 or M.cross_key then update_crosshair(vw, vh, w, h, sf) end
    part("am_hotbar", geo .. "|" .. selected_slot(), function() return build_hotbar(w, h, sf) end, vw, vh)
    local health, prev, flash, armor, air = hearts_state()
    local counter = health <= 4 and game.rel_tick() or 0
    part("am_hearts", ("%s|%d|%d|%s|%d|%s|%d"):format(geo, health, prev, tostring(flash), armor, tostring(air), counter),
        function() return build_hearts(w, h, sf, health, prev, flash, armor, air, counter) end, vw, vh)
    part("am_items", geo .. "|" .. items_key(), function() return build_items(w, h, sf) end, vw, vh)
    part("am_text", geo .. "|" .. tostring(M.show_debug) .. "|" .. tostring(M.debug_fps), function()
        return build_text(w, h, sf) end, vw, vh)
    local lines = chat_lines(game.screen == "GuiChat")
    local ck = {geo}
    for _, l in ipairs(lines) do ck[#ck + 1] = l[1] .. ":" .. l[3] .. ":" .. l[2] end
    local sk = {geo}
    for _, l in ipairs(lines) do sk[#sk + 1] = l[1] .. ":" .. l[2] end
    part_fade("am_chat", table.concat(sk, "|"), table.concat(ck, "|"), function() return build_chat(w, h, sf, lines) end,
        vw, vh)
end

function M.on_hud_render()
    game.stats.frames = game.stats.frames + 1
    local perf = require("alphamine:perf")
    perf.world_end()
    local ok, err = pcall(function()
        perf.push("hud")
        M.update()
        perf.pop()
        perf.push("gui")
        require("alphamine:gui").update(0)
        require("alphamine:inventory_gui").update()
        require("alphamine:chat_gui").update()
        perf.pop()
    end)
    if not ok and not M.err_logged then
        M.err_logged = true
        log("update error: " .. tostring(err))
    end
end

return M
