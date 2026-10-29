-- olife_proto:movement — deterministic player movement shared by the world (headless) and the client (prediction).
-- Hand-written (NOT generated). Wave 4c (02.10).
--
-- Model = the engine's own player physics of VoxelCore 0.32, re-expressed as a fixed-step integrator:
--   res/scripts/components/player.lua + mob.lua: front/right from the camera yaw, mob.go adds dir*speed*dt to the
--     velocity (movement_speed 27, run x1.5, crouch x0.35, flight x2), jump adds jump_force 8 when grounded,
--     flight up/down: vy = vy*0.2 + 27*(1/4)*0.8;
--   src/physics/PhysicsSolver.cpp: gravity 22.6 (Level.cpp), gravity off in flight (mob.set_flight -> gravity_scale 0),
--     linear damping 10 on x/z after the step (air_damping = ground_damping = 10), vertical damping in flight,
--     step height 0.5 when grounded, elasticity 0, hitbox 0.6 x 1.8 x 0.6.
-- Why not the engine solver itself: it is stepped by the frame delta (substeps = delta*1000 in [8, 200]) — a 60 fps
-- client and a 20 tps server integrate differently — and Lua cannot step it on demand, which reconciliation needs
-- (replaying the unacknowledged inputs within one frame). So both sides run THIS function with dt = 0.05 per input.
-- Collisions are swept per axis (Y, then X, Z; step-up) against block hitboxes (block.get_hitbox by rotation;
-- `obstacle: false` blocks — grass, water, torches — are ignored; unloaded chunks are solid), as in
-- content/alphamine/modules/physics.lua. After every step position and velocity are rounded to f32: the server sends
-- f32 on the wire, so the client can adopt the server state bit-exactly and its replay gives the same numbers.
-- State: {x, y, z (feet, centre of the hitbox bottom), vx, vy, vz, ground (bool), flight (bool)}.
local W = require "olife_proto:wire"

local M = {}
local fround = W.fround
local floor, sqrt, sin, cos, rad, abs = math.floor, math.sqrt, math.sin, math.cos, math.rad, math.abs

M.DT = 0.05
M.GRAVITY = 22.6
M.SPEED = 27.0            -- mob.lua movement_speed
M.DAMPING = 10.0          -- air_damping = ground_damping
M.JUMP = 8.0              -- base:player jump_force
M.RUN, M.CROUCH, M.FLIGHT = 1.5, 0.35, 2.0
M.STEP = 0.5              -- Hitbox.stepHeight
M.HW, M.H = 0.3, 1.8      -- half width, height
M.EPS = 1e-7

-- keys bitmask of MoveInput.keys
local K = {FWD = 1, BACK = 2, LEFT = 4, RIGHT = 8, JUMP = 16, SPRINT = 32, CROUCH = 64}
M.K = K
M.KEYS_MASK = 127

function M.new_state(x, y, z, flight)
    return {x = fround(x), y = fround(y), z = fround(z), vx = 0, vy = 0, vz = 0, ground = false, flight = flight and true or false}
end

function M.copy(s, d)
    d = d or {}
    d.x, d.y, d.z, d.vx, d.vy, d.vz, d.ground, d.flight = s.x, s.y, s.z, s.vx, s.vy, s.vz, s.ground, s.flight
    return d
end

function M.flags(s)
    return (s.ground and 1 or 0) + (s.flight and 2 or 0)
end

function M.from_net(pos, vel, flags, d)
    d = d or {}
    d.x, d.y, d.z = pos.x, pos.y, pos.z
    d.vx, d.vy, d.vz = vel.x, vel.y, vel.z
    d.ground = flags % 2 == 1
    d.flight = math.floor(flags / 2) % 2 == 1
    return d
end

-- ------------------------------------------------------------------ collision boxes
local hb_cache = {}       -- id*16 + rotation -> {x0, y0, z0, x1, y1, z1} | false
local function block_box(id, rot)
    local k = id * 16 + rot
    local b = hb_cache[k]
    if b == nil then
        local pr = block.properties[id]
        if id == 0 or (pr and pr.obstacle == false) then
            b = false
        else
            local ok, hb = pcall(block.get_hitbox, id, rot)
            if ok and type(hb) == "table" and hb[1] and hb[2] then
                local p, s = hb[1], hb[2]
                b = {p[1], p[2], p[3], p[1] + s[1], p[2] + s[2], p[3] + s[3]}
            else
                b = {0, 0, 0, 1, 1, 1}
            end
        end
        hb_cache[k] = b
    end
    return b
end
M.block_box = block_box

local FULL = {0, 0, 0, 1, 1, 1}
local boxes, nboxes = {}, 0
-- boxes of obstacle blocks touching [x0,x1]x[y0,y1]x[z0,z1] (world coordinates) -> shared list
local function collect(x0, y0, z0, x1, y1, z1)
    nboxes = 0
    local get, get_rot = block.get, block.get_rotation
    for bx = floor(x0), floor(x1) do
        for bz = floor(z0), floor(z1) do
            for by = floor(y0) - 1, floor(y1) do
                local id = get(bx, by, bz)
                local b
                if id == -1 then
                    b = FULL
                elseif id ~= 0 then
                    b = block_box(id, id > 0 and get_rot(bx, by, bz) or 0)
                end
                if b then
                    nboxes = nboxes + 1
                    local t = boxes[nboxes]
                    if not t then t = {}; boxes[nboxes] = t end
                    t[1], t[2], t[3] = bx + b[1], by + b[2], bz + b[3]
                    t[4], t[5], t[6] = bx + b[4], by + b[5], bz + b[6]
                end
            end
        end
    end
    return boxes, nboxes
end

-- clip a movement d along axis a (1 x, 2 y, 3 z) of the box bb against the collected boxes
local function clip(bb, a, d)
    if d == 0 then return 0 end
    local o1, o2 = (a == 1) and 2 or 1, (a == 3) and 2 or 3
    for i = 1, nboxes do
        local c = boxes[i]
        if bb[o1 + 3] > c[o1] + M.EPS and bb[o1] < c[o1 + 3] - M.EPS and bb[o2 + 3] > c[o2] + M.EPS and bb[o2] < c[o2 + 3] - M.EPS then
            if d > 0 and bb[a + 3] <= c[a] + M.EPS then
                local v = c[a] - bb[a + 3]
                if v < d then d = v end
            elseif d < 0 and bb[a] >= c[a + 3] - M.EPS then
                local v = c[a + 3] - bb[a]
                if v > d then d = v end
            end
        end
    end
    if abs(d) < M.EPS then d = 0 end
    return d
end

local function shift(bb, a, d)
    bb[a] = bb[a] + d
    bb[a + 3] = bb[a + 3] + d
end

-- move the box by (dx, dy, dz) with collisions: Y first, then X, Z (the order of Entity.moveEntity) -> moved dx, dy, dz
local function sweep(bb, dx, dy, dz)
    local x0, x1 = bb[1] + math.min(dx, 0), bb[4] + math.max(dx, 0)
    local y0, y1 = bb[2] + math.min(dy, 0), bb[5] + math.max(dy, 0)
    local z0, z1 = bb[3] + math.min(dz, 0), bb[6] + math.max(dz, 0)
    collect(x0, y0, z0, x1, y1 + M.STEP, z1)
    local my = clip(bb, 2, dy); shift(bb, 2, my)
    local mx = clip(bb, 1, dx); shift(bb, 1, mx)
    local mz = clip(bb, 3, dz); shift(bb, 3, mz)
    return mx, my, mz
end

-- ------------------------------------------------------------------ one input = one fixed step
-- s: state (mutated), keys: bitmask, yaw/pitch: degrees (yaw = player rot x: front = (-sin yaw, -cos yaw) on XZ)
-- returns s, info {collided_h, collided_v}
local bb, bb2 = {0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0}
local info = {collided_h = false, collided_v = false}
function M.step(s, keys, yaw, pitch)
    local dt = M.DT
    local band = bit.band
    keys = band(keys or 0, M.KEYS_MASK)
    local fwd = (band(keys, K.FWD) ~= 0 and 1 or 0) - (band(keys, K.BACK) ~= 0 and 1 or 0)
    local side = (band(keys, K.RIGHT) ~= 0 and 1 or 0) - (band(keys, K.LEFT) ~= 0 and 1 or 0)
    local jump, sprint, crouch = band(keys, K.JUMP) ~= 0, band(keys, K.SPRINT) ~= 0, band(keys, K.CROUCH) ~= 0
    local vx, vy, vz = s.vx, s.vy, s.vz
    -- mob.go: horizontal acceleration along the camera
    if fwd ~= 0 or side ~= 0 then
        local a = rad(yaw or 0)
        local fx, fz = -sin(a), -cos(a)      -- front (y zeroed, unit)
        local rx, rz = cos(a), -sin(a)       -- right
        local dx, dz = fx * fwd + rx * side, fz * fwd + rz * side
        local l = sqrt(dx * dx + dz * dz)
        if l > 0 then
            local speed = M.SPEED
            if s.flight then speed = speed * M.FLIGHT end
            if sprint then speed = speed * M.RUN elseif crouch then speed = speed * M.CROUCH end
            vx = vx + dx / l * speed * dt
            vz = vz + dz / l * speed * dt
        end
    end
    if s.flight then
        if jump then vy = vy * 0.2 + M.SPEED * 0.25 * 0.8
        elseif crouch then vy = vy * 0.2 - M.SPEED * 0.25 * 0.8 end
    elseif s.ground and jump then
        vy = vy + M.JUMP
    end
    -- integrate (constant acceleration over the step) and collide
    local g = s.flight and 0 or M.GRAVITY
    local vy1 = vy - g * dt
    local dx, dy, dz = vx * dt, (vy + vy1) * 0.5 * dt, vz * dt
    vy = vy1
    local hw, h = M.HW, M.H
    bb[1], bb[2], bb[3], bb[4], bb[5], bb[6] = s.x - hw, s.y, s.z - hw, s.x + hw, s.y + h, s.z + hw
    local mx, my, mz = sweep(bb, dx, dy, dz)
    local hit_y = my ~= dy
    local ground = dy < 0 and hit_y
    -- step-up (grounded, not flying, blocked horizontally): retry from STEP higher, keep it if it went further
    if s.ground and not s.flight and (mx ~= dx or mz ~= dz) then
        bb2[1], bb2[2], bb2[3], bb2[4], bb2[5], bb2[6] = s.x - hw, s.y, s.z - hw, s.x + hw, s.y + h, s.z + hw
        collect(bb2[1] + math.min(dx, 0), bb2[2], bb2[3] + math.min(dz, 0), bb2[4] + math.max(dx, 0),
                bb2[5] + M.STEP, bb2[6] + math.max(dz, 0))
        local up = clip(bb2, 2, M.STEP); shift(bb2, 2, up)
        local sx = clip(bb2, 1, dx); shift(bb2, 1, sx)
        local sz = clip(bb2, 3, dz); shift(bb2, 3, sz)
        local want = -up + math.min(dy, 0)
        collect(bb2[1], bb2[2] + want, bb2[3], bb2[4], bb2[5], bb2[6])
        local down = clip(bb2, 2, want); shift(bb2, 2, down)
        if sx * sx + sz * sz > mx * mx + mz * mz + M.EPS then
            for i = 1, 6 do bb[i] = bb2[i] end
            mx, mz = sx, sz
            hit_y = down ~= want
            ground = hit_y
        end
    end
    info.collided_h = (mx ~= dx) or (mz ~= dz)
    info.collided_v = hit_y
    if mx ~= dx then vx = 0 end
    if mz ~= dz then vz = 0 end
    if hit_y then vy = 0 end
    -- PhysicsSolver::step damping (after the substeps)
    local damp = dt * M.DAMPING
    vx = vx - vx * damp
    vz = vz - vz * damp
    if s.flight then vy = vy / (1 + damp) end
    s.x, s.y, s.z = fround((bb[1] + bb[4]) * 0.5), fround(bb[2]), fround((bb[3] + bb[6]) * 0.5)
    s.vx, s.vy, s.vz = fround(vx), fround(vy), fround(vz)
    if abs(s.vx) < 1e-6 then s.vx = 0 end
    if abs(s.vz) < 1e-6 then s.vz = 0 end
    if s.flight and abs(s.vy) < 1e-6 then s.vy = 0 end
    s.ground = ground
    return s, info
end

-- the box of a state overlaps a block cell (placing a block into a player is refused)
function M.overlaps_cell(s, x, y, z)
    local hw = M.HW
    return s.x + hw > x and s.x - hw < x + 1 and s.y + M.H > y and s.y < y + 1 and s.z + hw > z and s.z - hw < z + 1
end

-- yaw (degrees, player rot x) that makes `front` point from (x, z) to (tx, tz)
function M.yaw_to(x, z, tx, tz)
    return math.deg(math.atan2(-(tx - x), -(tz - z))) % 360
end

-- state hash (f32 bits of position and velocity + flags), the same on both sides
local f32_bits = W.f32_bits
function M.hash(s, fnv_ints)
    return fnv_ints(f32_bits(s.x), f32_bits(s.y), f32_bits(s.z), f32_bits(s.vx), f32_bits(s.vy), f32_bits(s.vz), M.flags(s))
end

return M
