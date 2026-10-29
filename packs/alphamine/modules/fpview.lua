-- First-person view state of the local player (phase 3, agent U): what EntityRenderer/ItemRenderer read from
-- EntityPlayerSP besides position and look, kept per Alpha tick exactly like Java, and the camera built from it.
--   * swing: EntityPlayer.swingItem (swingProgressInt = -1, isSwinging) on a left click (Minecraft.clickMouse(0)),
--     updateEntityActionState per tick (8 ticks, swingProgress = int / 8F), prevSwingProgress (EntityLiving.
--     onEntityUpdate); Packet18ArmAnimation(entity, 1) (EntityClientPlayerMP.swingItem);
--   * clicks: Minecraft.runTick — mouse press events -> clickMouse(button) (+ mouseTicksRan), held buttons repeat
--     every ticksPerSecond / 4 = 5 ticks, leftClickCounter (10 after a left click into the air, -1 per tick,
--     blocks clickMouse(0)); what a click does to blocks/entities is the gameplay agent's (`M.on_click` hook);
--   * view bobbing (GameSettings.viewBobbing, default on): distanceWalkedModified (physics.lua: e.walked, in
--     Entity.moveEntity) + prev, cameraYaw / cameraPitch (EntityPlayer.onLivingUpdate: += (target - v) * 0.4F /
--     0.8F) + prev; EntityRenderer.setupViewBobbing for the camera (setupCameraTransform) and the hand (renderHand);
--   * interpolation: prevPosX/Y/Z (Entity.onEntityUpdate, setPositionAndRotation) -> orientCamera with
--     renderPartialTicks (F2F shots at partial 0 show prevPos, one tick behind while walking).
-- Order in a tick (game.run_tick): mouse_tick (runTick input loop) ... pre_tick -> action_tick -> player physics
-- (P, player.tick_physics) -> post_tick (world.updateEntities -> EntityPlayerSP.onUpdate).
local J = require "alphamine:jmath"
local pl = require "alphamine:player"

local fround, F = J.fround, J.F
local PI_F = J.PI_F

local M = {
    bobbing = true,                         -- GameSettings.viewBobbing (F2F mode options.viewBobbing)
    swing_int = 0, swinging = false, swing = 0, prev_swing = 0,
    camera_yaw = 0, prev_camera_yaw = 0, camera_pitch = 0, prev_camera_pitch = 0,
    prev_walked = 0,
    limb_yaw = 0, prev_limb_yaw = 0, limb_swing = 0, ticks = 0,   -- EntityLiving limbYaw/limbSwing, ticksExisted
    prev_x = nil, prev_y = nil, prev_z = nil,
    left_click_counter = 0, mouse_ticks_ran = -100000,
    on_click = nil,                         -- gameplay hook: fn(button, hit) after the swing (hit = mouse_over)
    stats = {swings = 0, clicks = 0, blocked_clicks = 0},
}

-- lazy: game.lua requires this module (package.loaded keys are "alphamine:modules/<name>.lua", not "alphamine:<name>")
local function game()
    local ok, g = pcall(require, "alphamine:game")
    return ok and g or nil
end

-- ------------------------------------------------------------------ tick
-- EntityPlayer.swingItem + EntityClientPlayerMP.swingItem (Packet18)
function M.swing_item(net)
    M.swing_int = -1
    M.swinging = true
    M.stats.swings = M.stats.swings + 1
    if net and net.send_arm_animation then pcall(net.send_arm_animation, pl.entity_id or 0, 1) end
end

-- Minecraft.getMouseOver (blocks within reach 4; particles.lua)
local function mouse_over()
    local ok, fx = pcall(require, "alphamine:particles")
    if ok and fx and fx.mouse_over then
        local x, y, z, side = fx.mouse_over()
        if x then return {x = x, y = y, z = z, side = side} end
    end
    return nil
end
M.mouse_over = mouse_over

-- Minecraft.clickMouse
function M.click_mouse(button, net)
    if button == 0 and M.left_click_counter > 0 then
        M.stats.blocked_clicks = M.stats.blocked_clicks + 1
        return
    end
    M.stats.clicks = M.stats.clicks + 1
    if button == 0 then M.swing_item(net) end
    local hit = mouse_over()
    if not hit and button == 0 then M.left_click_counter = 10 end   -- not creative (PlayerControllerMP)
    if M.on_click then pcall(M.on_click, button, hit) end
end

-- Minecraft.runTick input part: edges = rising edges since the last tick (alphamine:input: attack = left,
-- use = right), state = current states; screen_open = currentScreen != null (mouseTicksRan = ticksRan + 10000)
function M.mouse_tick(tick, edges, state, screen_open, net)
    if screen_open then
        M.mouse_ticks_ran = tick + 10000
        if M.left_click_counter > 0 then M.left_click_counter = M.left_click_counter - 1 end
        return
    end
    if edges.attack then M.click_mouse(0, net); M.mouse_ticks_ran = tick end
    if edges.use then M.click_mouse(1, net); M.mouse_ticks_ran = tick end
    if M.left_click_counter > 0 then M.left_click_counter = M.left_click_counter - 1 end
    if state.attack and tick - M.mouse_ticks_ran >= 5 then
        M.click_mouse(0, net)
        M.mouse_ticks_ran = tick
    end
    if state.use and tick - M.mouse_ticks_ran >= 5 then
        M.click_mouse(1, net)
        M.mouse_ticks_ran = tick
    end
end

-- Entity.onEntityUpdate / EntityLiving.onEntityUpdate / EntityPlayer.onLivingUpdate: the prev values
function M.pre_tick()
    M.prev_x, M.prev_y, M.prev_z = pl.x, pl.y, pl.z
    M.ticks = M.ticks + 1
    M.prev_walked = pl.walked or 0
    M.prev_swing = M.swing
    M.prev_camera_pitch = M.camera_pitch
    M.prev_camera_yaw = M.camera_yaw
end

-- EntityPlayer.updateEntityActionState (from EntityLiving.onLivingUpdate while health > 0)
function M.action_tick()
    if (pl.health or 20) <= 0 then return end
    if M.swinging then
        M.swing_int = M.swing_int + 1
        if M.swing_int == 8 then
            M.swing_int = 0
            M.swinging = false
        end
    else
        M.swing_int = 0
    end
    M.swing = fround(M.swing_int / F[8.0])
end

-- EntityPlayer.onLivingUpdate after super.onLivingUpdate (motion and onGround after the move)
function M.post_tick()
    local mx, my, mz = pl.mx or 0, pl.my or 0, pl.mz or 0
    local v1 = J.sqrt_double(mx * mx + mz * mz)
    local v2 = fround(fround(math.atan(-my * F[0.2])) * F[15.0])
    if v1 > F[0.1] then v1 = F[0.1] end
    local dead = (pl.health or 20) <= 0
    if not pl.on_ground or dead then v1 = 0 end
    if pl.on_ground or dead then v2 = 0 end
    -- EntityLiving.moveEntityWithHeading tail: limbYaw / limbSwing (GuiInventory player preview)
    local dx, dz = pl.x - (M.prev_x or pl.x), pl.z - (M.prev_z or pl.z)
    local v7 = fround(J.sqrt_double(dx * dx + dz * dz) * F[4.0])
    if v7 > 1 then v7 = 1 end
    M.prev_limb_yaw = M.limb_yaw
    M.limb_yaw = fround(M.limb_yaw + fround(fround(v7 - M.limb_yaw) * F[0.4]))
    M.limb_swing = fround(M.limb_swing + M.limb_yaw)
    M.camera_yaw = fround(M.camera_yaw + fround(fround(v1 - M.camera_yaw) * F[0.4]))
    M.camera_pitch = fround(M.camera_pitch + fround(fround(v2 - M.camera_pitch) * F[0.8]))
end

-- Entity.setPositionAndRotation (NetClientHandler.handleFlying): prevPos = pos
function M.teleport()
    M.prev_x, M.prev_y, M.prev_z = pl.x, pl.y, pl.z
end

-- F2F mode (F2FAgent.mode): distanceWalked, cameraYaw/Pitch and their prev = 0; options.viewBobbing
function M.mode(args)
    M.prev_walked = 0
    pl.walked = 0
    M.ticks = 0
    M.camera_yaw, M.prev_camera_yaw, M.camera_pitch, M.prev_camera_pitch = 0, 0, 0, 0
    local o = args and args.options
    if type(o) == "table" and o.viewBobbing ~= nil then M.bobbing = o.viewBobbing and true or false end
    return {viewBobbing = M.bobbing}
end

-- ------------------------------------------------------------------ frame
function M.partial()
    local g = game()
    if g and g.partial then return g.partial() end
    return 0
end

-- EntityLiving.getSwingProgress
function M.swing_progress(p)
    local d = fround(M.swing - M.prev_swing)
    if d < 0 then d = d + 1 end
    return fround(M.prev_swing + fround(d * p))
end

-- 4x4 column-major (GL order: M = M * op)
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
local function rotate(m, deg, x, y, z)
    local a = math.rad(deg)
    local c, s = math.cos(a), math.sin(a)
    local t = 1 - c
    return mul(m, {
        x * x * t + c, y * x * t + z * s, x * z * t - y * s, 0,
        x * y * t - z * s, y * y * t + c, y * z * t + x * s, 0,
        x * z * t + y * s, y * z * t - x * s, z * z * t + c, 0,
        0, 0, 0, 1})
end
local function translate(m, x, y, z) return mul(m, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1}) end
M.mat = {idt = idt, mul = mul, rotate = rotate, translate = translate}

-- EntityRenderer.setupViewBobbing(partial): {tx, ty, rz, rx1, rx2} or nil (off / no bob)
function M.bob_params(p)
    if not M.bobbing then return nil end
    local walked = pl.walked or 0
    local d = fround(walked - M.prev_walked)
    local v4 = fround(walked + fround(d * p))
    local v5 = fround(M.prev_camera_yaw + fround(fround(M.camera_yaw - M.prev_camera_yaw) * p))
    local v6 = fround(M.prev_camera_pitch + fround(fround(M.camera_pitch - M.prev_camera_pitch) * p))
    if v5 == 0 and v6 == 0 then return nil end
    local a = fround(v4 * PI_F)
    local s, c = J.sin(a), J.cos(a)
    local tx = fround(fround(s * v5) * F[0.5])
    local ty = -math.abs(fround(c * v5))
    local rz = fround(fround(s * v5) * F[3.0])
    local rx1 = fround(math.abs(fround(J.cos(fround(a + F[0.2])) * v5)) * F[5.0])
    return {tx, ty, rz, rx1, v6}
end

-- the bob as an eye-space matrix (glTranslatef, glRotatef Z, X, X)
function M.bob_matrix(p)
    local b = M.bob_params(p)
    if not b then return nil end
    local m = translate(idt(), b[1], b[2], 0)
    m = rotate(m, b[3], 0, 0, 1)
    m = rotate(m, b[4], 1, 0, 0)
    m = rotate(m, b[5], 1, 0, 0)
    return m
end

-- camera of the pack (alphamine:view), EntityRenderer.setupCameraTransform + orientCamera (first person):
-- world -> eye = Bob * T(0, 0, -0.1) * Rx(pitch) * Ry(yaw + 180) * T(-eye). VoxelCore camera: rotation R
-- (camera -> world) and position; R = Ry(180 - yaw) Rx(-pitch) * Bob_rot^T, pos = eye + R0 (0, 0, 0.1) - R Bob_t
-- (R0 = the rotation without bob). Returns pos {x, y, z}, rot (16 numbers).
function M.camera(p)
    p = p or M.partial()
    local x, y, z = pl.x, pl.y, pl.z
    if M.prev_x then
        x = M.prev_x + (x - M.prev_x) * p
        y = M.prev_y + (y - M.prev_y) * p
        z = M.prev_z + (z - M.prev_z) * p
    end
    local r0 = rotate(rotate(idt(), 180 - pl.yaw, 0, 1, 0), -pl.pitch, 1, 0, 0)
    -- T(0, 0, -0.1) in eye space: eye + R0 * (0, 0, 0.1)
    x, y, z = x + r0[9] * 0.1, y + r0[10] * 0.1, z + r0[11] * 0.1
    local b = M.bob_params(p)
    if not b then return {x, y, z}, r0 end
    -- Bob = T(t) * Rb, Rb = Rz(rz) Rx(rx1) Rx(rx2); Rb^T = Rx(-rx2) Rx(-rx1) Rz(-rz)
    local r = rotate(r0, -b[5], 1, 0, 0)
    r = rotate(r, -b[4], 1, 0, 0)
    r = rotate(r, -b[3], 0, 0, 1)
    -- camera position: eye - R * t (t = bob translation in eye space)
    local tx, ty = b[1], b[2]
    x = x - (r[1] * tx + r[5] * ty)
    y = y - (r[2] * tx + r[6] * ty)
    z = z - (r[3] * tx + r[7] * ty)
    return {x, y, z}, r
end

return M
