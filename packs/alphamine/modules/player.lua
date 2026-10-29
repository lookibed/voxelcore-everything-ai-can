-- Player of the Alpha client (EntityPlayerSP / EntityClientPlayerMP), phase 3:
--   * position from the server (Packet10..13 like NetClientHandler.handleFlying: set, zero motion, echo),
--   * EntityPlayerSP.onUpdate every tick (when the chunks around exist, World.updateEntity): living rand
--     (nextInt(1000) — keeps Entity.rand in step with Java for the drop motion), MovementInputFromOptions
--     (W/S/A/D/space; Alpha 1.0.16 has no sneak), jump 0.42F, EntityLiving.moveEntityWithHeading (moveFlying,
--     ground friction 0.546F / slipperiness*0.91F, ladder, water 0.8 / lava 0.5 damping), fall damage,
--   * collisions: `M.collision = "lua"` (default) — Entity.moveEntity in Lua (modules/physics.lua, Java order
--     Y-X-Z, step-up 0.5, bit-exact doubles/floats) or "engine" — the engine player body (hitbox 0.6x1.8 of
--     base:player, dynamic, gravity ~0, no damping, step 0.5) moves by the Alpha motion (velocity = motion *
--     20 per s) and the engine's PhysicsSolver resolves the collisions; the Lua side reads the position back
--     next tick (one tick late; float32 positions, 0.03 skin to walls — see agents/ALPHAMINE.md phase 3),
--   * mouse look: setAngles in float (yaw += dx*0.15, pitch -= dy*0.15, clamp +-90), applied per frame,
--   * sendMotionUpdates (13/11/12/10 by what changed), camera alphamine:view (FOV 70, 0.1 behind the eye).
local J = require "alphamine:jmath"
local P = require "alphamine:physics"
local chunks = require "alphamine:chunks"

local fround, jfloor = J.fround, J.floor
local F = J.F

local F_1_62 = F[1.62]

local M = P.new({width = F[0.6], height = F[1.8], y_offset = F_1_62, step_height = F[0.5]})
M.health = 20
M.has_pos = false
M.old = nil
M.last_move_tick = 0
M.physics = true
M.view_camera = nil
M.collision = "lua"          -- "lua" | "engine"
M.entity_id = 0              -- Java: the local player is the first Entity created (F2F state entity_id 0)
M.rand = J.Random(0)
M.living_sound = 0
M.strafe, M.forward, M.jumping = 0, 0, false
M.in_water, M.in_lava = false, false
M.bb_prev = nil
M.stats = {ticks = 0, engine_ticks = 0, jumps = 0}

-- Entity.setPositionAndRotation (yaw/pitch nil = keep)
function M.set_position(x, y, z, yaw, pitch)
    if yaw then M.yaw = yaw end
    if pitch then M.pitch = pitch end
    M.y_size = 0
    P.set_position(M, x, y, z)
end

-- NetClientHandler.handleFlying: returns values for the echo packet (x, minY, posY, z, yaw, pitch)
function M.on_server_position(x, y, z, yaw, pitch, tick)
    M.mx, M.my, M.mz = 0, 0, 0
    M.set_position(x or M.x, y or M.y, z or M.z, yaw, pitch)
    M.last_move_tick = tick
    local first = not M.has_pos
    M.has_pos = true
    M.engine_sync = true      -- engine body must jump to the new position
    return M.x, M.bb[2], M.y, M.z, M.yaw, M.pitch, first
end

-- World.updateEntity: the player is updated (onUpdate: physics + sendMotionUpdates) only when all chunks
-- within 16 blocks exist (ChunkProviderClient.chunkExists = chunk received via PreChunk)
function M.can_update()
    if not M.has_pos then return false end
    local x, z = jfloor(M.x), jfloor(M.z)
    for cx = math.floor((x - 16) / 16), math.floor((x + 16) / 16) do
        for cz = math.floor((z - 16) / 16), math.floor((z + 16) / 16) do
            if not chunks.has_chunk(cx, cz) then return false end
        end
    end
    return true
end

-- EntityLiving.fall
local function fall(e, dist)
    local d = math.ceil(fround(dist - 3.0))
    if d > 0 then M.health = math.max(0, M.health - d) end
end

-- ------------------------------------------------------------------ engine collision mode
local engine_body = nil
local function engine_entity()
    if engine_body and entities.exists(engine_body.uid) then return engine_body end
    engine_body = nil
    local ok, eid = pcall(player.get_entity, M.PID)
    if not ok or not eid or eid == 0 then return nil end
    local ent = entities.get(eid)
    if not ent then return nil end
    engine_body = {uid = eid, ent = ent}
    return engine_body
end

local function engine_prepare(on)
    local b = engine_entity()
    if not b then return false end
    local ent = b.ent
    -- the engine player's own movement components (WASD, jump, flight) must not act on the body
    pcall(ent.set_enabled, ent, "core:player", false)
    pcall(ent.set_enabled, ent, "core:mob", false)
    local body = ent.rigidbody
    if on then
        player.set_noclip(M.PID, false)
        player.set_flight(M.PID, false)
        body:set_enabled(true)
        body:set_body_type("dynamic")
        body:set_gravity_scale(1e-6)   -- > 0: PhysicsSolver applies stepHeight only with gravity
        body:set_linear_damping(0)
        body:set_vdamping(false)
    else
        player.set_noclip(M.PID, true)
        player.set_flight(M.PID, true)
    end
    return true
end
M.engine_prepare = engine_prepare

function M.set_collision(mode)
    M.collision = (mode == "engine") and "engine" or "lua"
    M.engine_ready = engine_prepare(M.collision == "engine")
    M.engine_sync = true
    return M.collision
end

-- engine mode: move by (dx, dy, dz) over the coming physics frames; returns the position the engine
-- reached for the previous request (applied to the Alpha entity with the Java collision rules)
local function engine_move(dx, dy, dz)
    local b = engine_entity()
    if not b then
        P.move(M, dx, dy, dz, fall)   -- no engine body yet: Lua
        return
    end
    M.stats.engine_ticks = M.stats.engine_ticks + 1
    local tsf, body = b.ent.transform, b.ent.rigidbody
    local half = 0.9
    if M.engine_sync then
        tsf:set_pos({M.x, M.bb[2] + half, M.z})
        body:set_vel({0, 0, 0})
        M.engine_sync = false
        M.engine_want = nil
    elseif M.engine_want then
        -- result of the previous request: collisions per axis (Java: motion component zeroed)
        local p = tsf:get_pos()
        local w = M.engine_want
        local rx, ry, rz = p[1] - w[4], (p[2] - half) - w[5], p[3] - w[6]
        local grounded = body:is_grounded()
        local ox, oy, oz = M.x, M.bb[2], M.z
        local ey = p[2] - half
        M.bb[1], M.bb[4] = p[1] - fround(M.width / 2), p[1] + fround(M.width / 2)
        M.bb[3], M.bb[6] = p[3] - fround(M.width / 2), p[3] + fround(M.width / 2)
        M.bb[2], M.bb[5] = ey, ey + M.height
        M.x, M.z = p[1], p[3]
        M.y = ey + M.y_offset
        local cx = math.abs(rx - w[1]) > 1e-4
        local cy = math.abs(ry - w[2]) > 1e-4
        local cz = math.abs(rz - w[3]) > 1e-4
        M.collided_h, M.collided_v = cx or cz, cy
        M.on_ground = grounded or (cy and w[2] < 0)
        if cx then M.mx = 0 end
        if cy then M.my = 0 end
        if cz then M.mz = 0 end
        if M.on_ground then
            if M.fall > 0 then fall(M, M.fall); M.fall = 0 end
        elseif ry < 0 then
            M.fall = fround(M.fall - ry)
        end
    end
    -- request: this tick's motion over one tick (20 ticks/s)
    M.engine_want = {dx, dy, dz, M.x, M.bb[2], M.z}
    body:set_vel({dx * 20, dy * 20, dz * 20})
end

-- ------------------------------------------------------------------ one tick of EntityPlayerSP.onUpdate
local F091, F098, F002, F004 = F[0.91], F[0.98], F[0.02], F[0.04]
local GROUND_F = fround(fround(fround(F[546.0] * F[0.1]) * F[0.1]) * F[0.1])

local function slipperiness_factor()
    local f = F091
    if M.on_ground then
        f = GROUND_F
        local id = P.block_at(jfloor(M.x), jfloor(M.bb[2]) - 1, jfloor(M.z))
        if id > 0 then f = fround((id == 79 and F[0.98] or F[0.6]) * F091) end
    end
    return f
end

-- Entity.moveFlying
local function move_flying(strafe, forward, speed)
    local d = J.sqrt_float(fround(fround(strafe * strafe) + fround(forward * forward)))
    if d < F[0.01] then return end
    if d < 1 then d = 1 end
    d = fround(speed / d)
    strafe, forward = fround(strafe * d), fround(forward * d)
    local a = fround(fround(M.yaw * J.PI_F) / F[180.0])
    local s, c = J.sin(a), J.cos(a)
    M.mx = M.mx + fround(fround(strafe * c) - fround(forward * s))
    M.mz = M.mz + fround(fround(forward * c) + fround(strafe * s))
end

local function move(dx, dy, dz)
    if M.collision == "engine" then engine_move(dx, dy, dz) else P.move(M, dx, dy, dz, fall) end
end

local function is_on_ladder()
    local x, y, z = jfloor(M.x), jfloor(M.bb[2]), jfloor(M.z)
    return P.block_at(x, y, z) == 65 or P.block_at(x, y + 1, z) == 65
end

-- EntityLiving.moveEntityWithHeading
local function move_with_heading(strafe, forward)
    if M.in_water then
        local y0 = M.y
        move_flying(strafe, forward, F002)
        move(M.mx, M.my, M.mz)
        M.mx, M.my, M.mz = M.mx * F[0.8], M.my * F[0.8], M.mz * F[0.8]
        M.my = M.my - 0.02
        if M.collided_h and P.offset_free(M, M.mx, M.my + F[0.6] - M.y + y0, M.mz) then M.my = F[0.3] end
    elseif M.in_lava then
        local y0 = M.y
        move_flying(strafe, forward, F002)
        move(M.mx, M.my, M.mz)
        M.mx, M.my, M.mz = M.mx * 0.5, M.my * 0.5, M.mz * 0.5
        M.my = M.my - 0.02
        if M.collided_h and P.offset_free(M, M.mx, M.my + F[0.6] - M.y + y0, M.mz) then M.my = F[0.3] end
    else
        local f = slipperiness_factor()
        local k = fround(F[0.16277136] / fround(fround(f * f) * f))
        move_flying(strafe, forward, M.on_ground and fround(F[0.1] * k) or F002)
        f = slipperiness_factor()
        if is_on_ladder() then
            M.fall = 0
            if M.my < -0.15 then M.my = -0.15 end
        end
        move(M.mx, M.my, M.mz)
        if M.collided_h and is_on_ladder() then M.my = 0.2 end
        M.my = M.my - 0.08
        M.my = M.my * F098
        M.mx = M.mx * f
        M.mz = M.mz * f
    end
end

-- strafe/forward/jump from alphamine:input (MovementInputFromOptions.updatePlayerMoveState)
function M.tick_physics(tick, strafe, forward, jump)
    if not M.has_pos or not M.physics then return end
    M.stats.ticks = M.stats.ticks + 1
    local ox, oy, oz = M.x, M.y, M.z
    -- EntityLiving.onEntityUpdate: living sound roll (player has no sound, one nextInt per tick)
    if M.rand:next_int(1000) < M.living_sound then M.living_sound = -80 else M.living_sound = M.living_sound + 1 end
    M.stats.rand_ticks = (M.stats.rand_ticks or 0) + 1
    -- EntityPlayerSP.onLivingUpdate -> EntityPlayer -> EntityLiving.onLivingUpdate
    M.strafe, M.forward, M.jumping = strafe or 0, forward or 0, jump or false
    M.in_water = P.in_water(M)
    M.in_lava = P.in_lava(M)
    if M.in_water then M.fall = 0 end   -- Entity.onEntityUpdate: fallDistance = 0 in water
    if M.jumping then
        if M.in_water or M.in_lava then
            M.my = M.my + F004
        elseif M.on_ground then
            M.my = F[0.42]                  -- EntityLiving.jump
            M.stats.jumps = M.stats.jumps + 1
        end
    end
    M.strafe = fround(M.strafe * F098)
    M.forward = fround(M.forward * F098)
    move_with_heading(M.strafe, M.forward)
    if M.x ~= ox or M.y ~= oy or M.z ~= oz then M.last_move_tick = tick end
end

-- EntityClientPlayerMP.sendMotionUpdates
function M.send_motion(net)
    if not M.has_pos then return end
    local o = M.old
    local minY = M.bb[2]
    if not o then
        o = {M.x, minY, M.y, M.z, M.yaw, M.pitch}
        M.old = o
        net.send_look_move(M.x, minY, M.y, M.z, M.yaw, M.pitch, M.on_ground)
        return
    end
    local moved = minY ~= o[2] or M.y ~= o[3] or M.x ~= o[1] or M.z ~= o[4]
    local looked = M.yaw ~= o[5] or M.pitch ~= o[6]
    if moved and looked then
        net.send_look_move(M.x, minY, M.y, M.z, M.yaw, M.pitch, M.on_ground)
    elseif moved then
        net.send_position(M.x, minY, M.y, M.z, M.on_ground)
    elseif looked then
        net.send_look(M.yaw, M.pitch, M.on_ground)
    else
        net.send_flying(M.on_ground)
    end
    if moved then o[1], o[2], o[3], o[4] = M.x, minY, M.y, M.z end
    if looked then o[5], o[6] = M.yaw, M.pitch end
end

-- Entity.setAngles (float): yaw += dx*0.15, pitch -= dy*0.15, clamp +-90 (dy > 0 = look up)
function M.look(dx, dy, tick)
    if dx == 0 and dy == 0 then return end
    M.yaw = fround(M.yaw + dx * 0.15)
    M.pitch = fround(M.pitch - dy * 0.15)
    if M.pitch < -90 then M.pitch = -90 end
    if M.pitch > 90 then M.pitch = 90 end
    if tick then M.last_move_tick = tick end
end

-- EntityPlayer.dropPlayerItemWithRandomChoice(stack, false) on EntityClientPlayerMP: the item is only sent
-- (Packet21), the server spawns it. Returns the packet fields.
function M.drop(stack, net)
    if not stack then return nil end
    local x, y, z = M.x, M.y - F[0.3] + F[0.12], M.z
    local k = F[0.3]
    local ya = fround(fround(M.yaw / F[180.0]) * J.PI_F)
    local pa = fround(fround(M.pitch / F[180.0]) * J.PI_F)
    local mx = fround(fround(-J.sin(ya) * J.cos(pa)) * k)
    local mz = fround(fround(J.cos(ya) * J.cos(pa)) * k)
    local my = fround(fround(-J.sin(pa) * k) + F[0.1])
    local a = fround(fround(M.rand:next_float() * J.PI_F) * F[2.0])
    local r = fround(F[0.02] * M.rand:next_float())
    mx = mx + math.cos(a) * r
    my = my + fround(fround(M.rand:next_float() - M.rand:next_float()) * F[0.1])
    mz = mz + math.sin(a) * r
    -- Packet21PickupSpawn(EntityItem): floor(pos * 32), (byte)(int)(motion * 128)
    local function b(v)
        local i = J.toint(v * 128.0) % 256
        return i >= 128 and i - 256 or i
    end
    local px, py, pz = jfloor(x * 32.0), jfloor(y * 32.0), jfloor(z * 32.0)
    local pkt = {0, stack.id, stack.count, px, py, pz, b(mx), b(my), b(mz), M.stats.rand_ticks or 0}
    net.send_pickup_spawn(unpack(pkt, 1, 9))
    return pkt
end

-- F2F `mode`: Entity.rand = entitySeed(seed, entityID), view bobbing state reset
function M.mode(seed)
    M.rand:set_seed(J.entity_seed(seed or 0, M.entity_id))
    M.stats.rand_ticks = 0
    M.walked = 0
end

-- ------------------------------------------------------------------ engine player and camera
M.PID = 0
M.FOV = 70

function M.view_init()
    local ok, cam = pcall(cameras.get, "alphamine:view")
    if ok and cam then
        M.view_camera = cam
        player.set_camera(M.PID, cam:get_index())
        cam:set_fov(M.FOV)
    end
    -- the engine player: no own movement (components off), invisible (the pack camera is not the engine's
    -- first-person camera, so the engine would draw the base:player model at the eye)
    local b = engine_entity()
    if b then
        pcall(b.ent.set_enabled, b.ent, "core:player", false)
        pcall(b.ent.set_enabled, b.ent, "core:mob", false)
        pcall(function() b.ent.skeleton:set_visible(false) end)
    end
end

-- Alpha yaw 0 looks at +Z and grows clockwise (90 = -X), pitch > 0 looks down.
-- VoxelCore camera: rotate(Y, yaw) then (X, pitch); yaw 0 looks at -Z, pitch > 0 looks up.
-- => vc_yaw = 180 - alpha_yaw, vc_pitch = -alpha_pitch (checked by running, agents/ALPHAMINE.md phase 2).
function M.update_view()
    if not M.has_pos then return end
    if M.collision == "engine" and not M.engine_ready then
        M.engine_ready = engine_prepare(true)
        M.engine_sync = true
    end
    local b = engine_entity()
    if b and b.ent then pcall(function() b.ent.skeleton:set_visible(false) end) end
    if M.collision ~= "engine" then
        -- engine player: hitbox centre = feet + 0.9 (base:player hitbox 1.8), chunks load around it
        player.set_pos(M.PID, M.x, M.bb[2] + 0.9, M.z)
        player.set_vel(M.PID, 0, 0, 0)
    end
    player.set_rot(M.PID, 180 - M.yaw, -M.pitch, 0)
    local cam = M.view_camera
    local okv, fpv = pcall(require, "alphamine:fpview")
    if cam and okv and fpv and fpv.camera then
        -- U: EntityRenderer.setupCameraTransform — view bobbing, prevPos -> pos by renderPartialTicks, the eye
        -- 0.1 behind (orientCamera); modules/fpview.lua
        local pos, rot = fpv.camera()
        cam:set_pos(pos)
        cam:set_rot(rot)
        cam:set_fov(M.FOV)
    elseif cam then
        -- EntityRenderer.orientCamera (first person): glTranslatef(0, 0, -0.1) before the rotations ->
        -- the eye is 0.1 behind posX/posY/posZ along the view direction
        local ry, rp = math.rad(M.yaw), math.rad(M.pitch)
        local fx, fy, fz = -math.sin(ry) * math.cos(rp), -math.sin(rp), math.cos(ry) * math.cos(rp)
        cam:set_pos({M.x - 0.1 * fx, M.y - 0.1 * fy, M.z - 0.1 * fz})
        local m = mat4.rotate({0, 1, 0}, 180 - M.yaw)
        m = mat4.rotate(m, {1, 0, 0}, -M.pitch)
        cam:set_rot(m)
        cam:set_fov(M.FOV)
    end
end

function M.reset()
    M.has_pos, M.old = false, nil
    M.mx, M.my, M.mz, M.fall, M.health = 0, 0, 0, 0, 20
    M.on_ground = false
end

return M
