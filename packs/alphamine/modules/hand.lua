-- First-person hand and held item of the Alpha client (phase 3): ItemRenderer.renderItemInFirstPerson through the
-- engine's named skeleton `hand` (skeletons/hand.json via config/defaults.toml "hand-skeleton", bones `arm` and
-- `item`, models/am_hand/*.vcm from tools/alphamine/gen_ui_assets.py), drawn by WorldRenderer in the F2F `hand` layer.
--
-- Engine facts this relies on (WorldRenderer::renderFrame, HandsRenderer, ModelBatch, entity.glsl*):
--  * the hand is drawn only while player.currentCamera == fpCamera (core:first-person), with a copy of that camera
--    at the origin, FOV 0.9 rad, far 10; the bone matrix is in world orientation, so matrix = R_cam * S(k, k, 1) * E
--    where E is Java's hand modelview (eye space) and k = tan(0.45) / tan(35 deg) turns the engine's 0.9 rad
--    projection into Java's gluPerspective(70) for x/y (z only orders the hand's own faces);
--  * `shading off` meshes get light 1 and no face factor: the pixel is texel * skeleton tint, so Java's lighting
--    (RenderHelper standard item lighting in the Rx(pitch) Ry(yaw) frame x world brightness, GL_MODULATE) is baked
--    into small canvas textures per light class ($f $b $x $u $d for flat items, $0..$5 for blocks and the arm).
--  * pose and textures must be set BEFORE WorldRenderer::renderFrame of the same frame: hud.hand_controller /
--    on_hud_render run after it (the matrix would lag one frame behind the camera). The only pack Lua that runs
--    between CameraControl::update and renderFrame is stdcomp.render (LevelScreen::draw -> on_entities_render), so
--    `stdcomp.render` is wrapped: after the components (alphamine:am_frame -> game.frame: mouse look + view camera)
--    pre_render copies the pack view camera (alphamine:view, modules/player.lua) into core:first-person, which is
--    made the current camera, and poses/lights the hand.
local game = require "alphamine:game"
local pl = require "alphamine:player"
local T = require "alphamine:ui_tables"

local M = {installed = false, canvases = {}, variant = nil, light_key = nil,
           equipped = 0, prev_equipped = 0, item = nil, last_tick = nil, stats = {updates = 0}}

local sin, cos, rad, sqrt, floor = math.sin, math.cos, math.rad, math.sqrt, math.floor
local K = math.tan(0.45) / math.tan(math.rad(35))

local function log(m) debug.log("[alphamine_hand] " .. m) end

-- ------------------------------------------------------------------ 4x4 (column-major, GL order: M = M * op)
local function idt() return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1} end
local function mul(a, b)
    local r = {}
    for c = 0, 3 do
        for rw = 1, 4 do
            r[c * 4 + rw] = a[rw] * b[c * 4 + 1] + a[4 + rw] * b[c * 4 + 2] + a[8 + rw] * b[c * 4 + 3] + a[12 + rw] * b[c * 4 + 4]
        end
    end
    return r
end
local function translate(m, x, y, z)
    return mul(m, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1})
end
local function scale(m, x, y, z)
    return mul(m, {x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1})
end
-- glRotatef(deg, x, y, z) with a unit axis
local function rotate(m, deg, x, y, z)
    local a = rad(deg)
    local c, s = cos(a), sin(a)
    local t = 1 - c
    return mul(m, {
        x * x * t + c, y * x * t + z * s, x * z * t - y * s, 0,
        x * y * t - z * s, y * y * t + c, y * z * t + x * s, 0,
        x * z * t + y * s, y * z * t - x * s, z * z * t + c, 0,
        0, 0, 0, 1})
end
local function xform3(m, v)
    return {m[1] * v[1] + m[5] * v[2] + m[9] * v[3], m[2] * v[1] + m[6] * v[2] + m[10] * v[3],
            m[3] * v[1] + m[7] * v[2] + m[11] * v[3]}
end
local function normalize(v)
    local l = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if l < 1e-12 then return {0, 0, 0} end
    return {v[1] / l, v[2] / l, v[3] / l}
end

-- EntityLiving.getSwingProgress (modules/fpview.lua keeps swingProgress / prev per tick)
local J = require "alphamine:jmath"
local fpv = require "alphamine:fpview"
local fround, F, PI_F, jsin, jsqrt = J.fround, J.F, J.PI_F, J.sin, J.sqrt_float
local function swing_progress(partial)
    return fpv.swing_progress(partial)
end

-- ------------------------------------------------------------------ Java matrices
-- the swing terms of renderItemInFirstPerson in float (MathHelper.sin table, sqrt_float)
local function swing_terms(sw)
    local v7 = jsin(fround(sw * PI_F))
    local v8 = jsin(fround(jsqrt(sw) * PI_F))
    local v9 = jsin(fround(fround(jsqrt(sw) * PI_F) * F[2.0]))
    local w7 = jsin(fround(fround(sw * sw) * PI_F))
    return v7, v8, v9, w7
end

-- ItemRenderer.renderItemInFirstPerson, item branch, up to renderItem (the item/block geometry follows)
local function item_base(eq, sw)
    local v7, v8, v9, w7 = swing_terms(sw)
    local m = idt()
    m = translate(m, fround(-v8 * F[0.4]), fround(v9 * F[0.2]), fround(-v7 * F[0.2]))
    m = translate(m, fround(F[0.7] * F[0.8]), fround(fround(F[-0.65] * F[0.8]) - fround(fround(1.0 - eq) * F[0.6])),
        fround(F[-0.9] * F[0.8]))
    m = rotate(m, 45, 0, 1, 0)
    m = rotate(m, fround(-w7 * F[20.0]), 0, 1, 0)
    m = rotate(m, fround(-v8 * F[20.0]), 0, 0, 1)
    m = rotate(m, fround(-v8 * F[80.0]), 1, 0, 0)
    m = scale(m, 0.4, 0.4, 0.4)
    return m
end

-- ItemRenderer.renderItem, flat branch: object space of models/am_hand/item.vcm
local function flat_item(m)
    m = translate(m, 0, -0.3, 0)
    m = scale(m, 1.5, 1.5, 1.5)
    m = rotate(m, 50, 0, 1, 0)
    m = rotate(m, 335, 0, 0, 1)
    m = translate(m, -(15 / 16), -(1 / 16), 0)
    return m
end

-- empty hand: renderItemInFirstPerson else-branch + RenderPlayer.drawFirstPersonHand (bipedRightArm at
-- rotation point (-5, 2, 0)/16, rotateAngleZ = cos(0)*0.05 + 0.05 = 0.1 rad at ticks 0; the model is in 1/16 units)
local function arm_matrix(eq, sw)
    local v7, v8, v9, w7 = swing_terms(sw)
    local m = idt()
    m = translate(m, fround(-v8 * F[0.3]), fround(v9 * F[0.4]), fround(-v7 * F[0.4]))
    m = translate(m, fround(F[0.8] * F[0.8]), fround(fround(-(F[12.0] / 16.0) * F[0.8]) - fround(fround(1.0 - eq) * F[0.6])),
        fround(F[-0.9] * F[0.8]))
    m = rotate(m, 45, 0, 1, 0)
    m = rotate(m, fround(v8 * F[70.0]), 0, 1, 0)
    m = rotate(m, fround(-w7 * F[20.0]), 0, 0, 1)
    m = translate(m, -1, 3.6, 3.5)
    m = rotate(m, 120, 0, 0, 1)
    m = rotate(m, 200, 1, 0, 0)
    m = rotate(m, -135, 0, 1, 0)
    m = translate(m, 5.6, 0, 0)
    m = translate(m, -5 / 16, 2 / 16, 0)
    m = rotate(m, 0.1 * 180 / math.pi, 0, 0, 1)
    return m
end

-- ------------------------------------------------------------------ canvases
local sources = {}
local function source(name)
    local s = sources[name]
    if s == nil then
        local ok, c = pcall(function()
            return Canvas.decode(file.read_bytes("alphamine:textures/gui/" .. name .. ".png"), "png")
        end)
        if ok and c then
            s = {w = c.width, h = c.height, data = c:get_data()}
        else
            log("cannot read " .. name .. ": " .. tostring(c))
            s = false
        end
        sources[name] = s
    end
    return s or nil
end

-- 16x16 texels at png (x0, y0) of an atlas -> bottom-up rows (data row j = png row y0 + 15 - j)
local function tile_pixels(src, x0, y0)
    local out = {}
    local b = src.data
    for j = 0, 15 do
        local drow = src.h - 1 - (y0 + 15 - j)
        for i = 0, 15 do
            local p = (drow * src.w + x0 + i) * 4
            local o = (j * 16 + i) * 4
            out[o + 1], out[o + 2], out[o + 3], out[o + 4] = b[p + 1], b[p + 2], b[p + 3], b[p + 4]
        end
    end
    return out
end

local function canvas_for(key)
    local c = M.canvases[key]
    if not c then
        c = Canvas({16, 16})
        c:create_texture("am_hand_" .. key)
        M.canvases[key] = c
    end
    return c
end

-- texels x factor (GL_MODULATE of the clamped lit colour), alpha kept
local function upload(key, px, f)
    local c = canvas_for(key)
    local out = {}
    for i = 1, 1024, 4 do
        out[i] = floor(px[i] * f + 0.5)
        out[i + 1] = floor(px[i + 1] * f + 0.5)
        out[i + 2] = floor(px[i + 2] * f + 0.5)
        out[i + 3] = px[i + 3]
    end
    c:set_data(out)
    c:update()
end

-- ------------------------------------------------------------------ light
local L0 = normalize({0.20000000298023224, 1.0, -0.699999988079071})
local L1 = normalize({-0.20000000298023224, 1.0, 0.699999988079071})

-- RenderHelper.enableStandardItemLighting under glRotatef(pitch, X) glRotatef(yaw, Y)
local function eye_lights(yaw, pitch)
    local m = rotate(rotate(idt(), pitch, 1, 0, 0), yaw, 0, 1, 0)
    return normalize(xform3(m, L0)), normalize(xform3(m, L1))
end

local function light_factor(m, n, l0, l1, b)
    -- GL_RESCALE_NORMAL: the normal is scaled back by the uniform scale of the modelview, not renormalised (the
    -- Tessellator byte normals decoded (2b + 1) / 255 are not unit length: -127 -> -0.99216)
    local e = xform3(m, n)
    local s = sqrt(m[1] * m[1] + m[2] * m[2] + m[3] * m[3])
    e = {e[1] / s, e[2] / s, e[3] / s}
    local d0 = e[1] * l0[1] + e[2] * l0[2] + e[3] * l0[3]
    local d1 = e[1] * l1[1] + e[2] * l1[2] + e[3] * l1[3]
    local c = 0.4 * b + 0.6 * b * math.max(0, d0) + 0.6 * b * math.max(0, d1)
    if c > 1 then c = 1 end
    return c
end

-- World.getBrightness(floor(posX), floor(posY), floor(posZ)) (posY = eyes)
local function brightness()
    local ok, phys = pcall(require, "alphamine:physics")
    if ok and phys and phys.brightness and pl.has_pos then
        local ok2, b = pcall(phys.brightness, floor(pl.x), floor(pl.y), floor(pl.z))
        if ok2 and b then return b end
    end
    return 1.0
end

-- ------------------------------------------------------------------ per tick: ItemRenderer.updateEquippedItem
local function current_stack()
    local ok, inv = pcall(require, "alphamine:inventory")
    if ok and inv and inv.current_item then
        local ok2, st = pcall(inv.current_item)
        if ok2 then return st end
    end
    return game.inventory[game.selected_slot or 0]
end

local function same_stack(a, b)
    if a == nil or b == nil then return a == b end
    return a == b
end

local function tick_equipped()
    M.prev_equipped = M.equipped
    local st = current_stack()
    local target = same_stack(st, M.item) and 1.0 or 0.0
    local d = fround(target - M.equipped)
    if d < -F[0.4] then d = -F[0.4] end
    if d > F[0.4] then d = F[0.4] end
    M.equipped = fround(M.equipped + d)
    if M.equipped < F[0.1] then M.item = st end
end

function M.mode_reset()
    -- F2F mode: the item has been in hand for a long time
    M.item = current_stack()
    M.equipped, M.prev_equipped = 1.0, 1.0
    M.last_tick = game.tick
end

-- ------------------------------------------------------------------ per frame
local function camera_sync()
    local fp = M.fp
    local vc = pl.view_camera
    if not fp or not vc then return end
    fp:set_pos(vc:get_pos())
    fp:set_rot(vc:get_rot())
    fp:set_fov(vc:get_fov())
end

local function partial_tick()
    if not game.t0 or not game.ticks_done then return 0 end
    local p = (time.uptime() - game.t0) / 0.05 - game.ticks_done
    if p < 0 then p = 0 end
    if p > 1 then p = 1 end
    return p
end

function M.pre_render()
    if not M.skel then return end
    if M.fp and player.get_camera(pl.PID or 0) ~= M.fp:get_index() then
        player.set_camera(pl.PID or 0, M.fp:get_index())
    end
    camera_sync()
    if M.last_tick == nil or M.mode_base ~= game.tick_base then
        M.mode_base = game.tick_base
        M.mode_reset()
    end
    local ia = game.interact   -- interact.lua (P): clickMouse(1) -> ItemRenderer.resetEquippedProgress in that tick
    while M.last_tick < game.tick do
        M.last_tick = M.last_tick + 1
        if ia and ia.equip_reset_tick == M.last_tick then M.equipped = 0 end
        tick_equipped()
    end
    local sk = M.skel
    local partial = partial_tick()
    local eq = fround(M.prev_equipped + fround(fround(M.equipped - M.prev_equipped) * partial))
    local sw = swing_progress(partial)
    local st = M.item
    local base, model, kind, normals, keys
    if st and st.id and st.id > 0 then
        local ic = T.icons[st.id]
        local blk = T.hand_blocks[st.id]
        base = item_base(eq, sw)
        if blk then
            kind, model = "block", blk.model
            base = translate(base, 0, 0, 0)  -- renderBlockOnInventory: cube around the origin (model has -0.5)
            normals, keys = T.hand.block_normals, {"0", "1", "2", "3", "4", "5"}
        elseif ic then
            kind, model = "flat", T.hand.item.model
            base = flat_item(base)
            normals, keys = T.hand.item.normals, {"f", "b", "x", "u", "d"}
        end
    end
    if not kind then
        kind, model = "arm", T.hand.arm.model
        base = arm_matrix(eq, sw)
        normals, keys = T.hand.arm.normals, {"0", "1", "2", "3", "4", "5"}
    end
    -- lighting per class
    local l0, l1 = eye_lights(pl.yaw or 0, pl.pitch or 0)
    local b = brightness()
    local fac = {}
    for i, k in ipairs(keys) do
        local n = normals[k] or normals[i]
        fac[i] = light_factor(base, n, l0, l1, b)
    end
    local variant = kind .. ":" .. (st and st.id or 0)
    local lkey = variant .. "|" .. table.concat(fac, ",")
    if lkey ~= M.light_key then
        M.light_key = lkey
        M.stats.updates = M.stats.updates + 1
        M.last_light = {variant = variant, yaw = pl.yaw, pitch = pl.pitch, brightness = b, factors = fac}
        -- trace of the first light classes: F2F runs and dev runs with export:alphamine_debug.txt only
        if M.stats.updates <= 12 and (game.f2f or game.debug_log) then
            log(("light %s yaw %.2f pitch %.2f b %.4f: %s"):format(variant, pl.yaw or 0, pl.pitch or 0, b,
                table.concat(fac, ", ")))
        end
        for i, k in ipairs(keys) do
            local px
            if kind == "flat" then
                local ic = T.icons[st.id]
                local src = source(ic.atlas == "gui/am_items" and "am_items" or "am_terrain")
                if src then px = tile_pixels(src, ic.index % 16 * 16, floor(ic.index / 16) * 16) end
            elseif kind == "block" then
                local tile = T.hand_blocks[st.id].tiles[i]
                local src = source("am_terrain")
                if src then px = tile_pixels(src, tile % 16 * 16, floor(tile / 16) * 16) end
            else
                local src = source("am_char")
                if src then px = tile_pixels(src, 40, 16) end
            end
            if px then upload(k, px, fac[i]) end
            sk:set_texture("$" .. k, "am_hand_" .. k)
        end
    end
    if M.variant ~= variant then
        M.variant = variant
        local bone_item, bone_arm = sk:index("item"), sk:index("arm")
        if kind == "arm" then
            sk:set_visible(bone_item, false)
            sk:set_visible(bone_arm, true)
        else
            sk:set_model(bone_item, model)
            sk:set_visible(bone_item, true)
            sk:set_visible(bone_arm, false)
        end
    end
    -- bone matrix: camera rotation (world orientation of the hud camera) * FOV fix * Java eye-space matrix
    local cam = M.fp
    local r = cam and cam:get_rot() or idt()
    local m = mul(r, scale(idt(), K, K, 1))
    -- EntityRenderer.renderHand: glLoadIdentity, hurtCameraEffect, setupViewBobbing, then renderItemInFirstPerson
    -- (the bob rotation does not change the lighting: lights and normals turn together)
    local bob = fpv.bob_matrix(partial)
    if bob then m = mul(m, bob) end
    m = mul(m, base)
    local bone = kind == "arm" and sk:index("arm") or sk:index("item")
    sk:set_matrix(bone, m)
end

function M.init()
    if M.installed then return end
    M.installed = true
    local ok, sk = pcall(gfx.skeletons.get, "hand")
    if not ok or not sk then
        log("no hand skeleton: " .. tostring(sk))
        return
    end
    M.skel = sk
    sk:set_color({1, 1, 1})
    local okc, fp = pcall(cameras.get, "core:first-person")
    if okc and fp then
        M.fp = fp
        player.set_camera(pl.PID or 0, fp:get_index())
    end
    hud.hand_controller = function() end   -- pose is set in pre_render (before the world pass)
    local orig = stdcomp.render
    stdcomp.render = function(delta)
        -- after the entity components: alphamine:am_frame (game.frame) applies the mouse look and moves the pack
        -- view camera in its on_render, the hand and the first-person camera follow it in the same frame
        orig(delta)
        local perf = require("alphamine:perf")
        perf.push("hand")
        local okp, err = pcall(M.pre_render)
        perf.pop()
        if not okp and not M.err_logged then
            M.err_logged = true
            log("pre_render error: " .. tostring(err))
        end
        perf.push("particles")
        local oki, erri = pcall(require("alphamine:inventory_gui").frame)
        if not oki and not M.inv_err_logged then
            M.inv_err_logged = true
            log("inventory frame error: " .. tostring(erri))
        end
        local okf, errf = pcall(require("alphamine:particles").frame)
        perf.pop()
        if not okf and not M.fx_err_logged then
            M.fx_err_logged = true
            log("particles error: " .. tostring(errf))
        end
        perf.world_begin()   -- the engine's world pass follows (until on_hud_render)
    end
    log(("installed: skeleton hand (arm %s, item %s), camera core:first-person %s"):format(
        tostring(sk:index("arm")), tostring(sk:index("item")), tostring(M.fp ~= nil)))
end

return M
