-- Alpha entity physics in Lua, bit-exact with the Java client (phase 3):
--   Entity.setPosition / moveEntity (Y, X, Z order, step-up by stepHeight, ySize, fallDistance, onGround),
--   World.getCollidingBoundingBoxes (block boxes by id+meta from the chunk store, then entity boxes),
--   AxisAlignedBB.calculate{X,Y,Z}Offset, handleWaterMovement / handleLavaMovement (detection; the flow
--   push of BlockFluid.velocityToAddToEntity is not done), isOffsetPositionInLiquid, block brightness.
-- An entity is a table: {x, y, z, mx, my, mz, yaw, pitch, bb = {minX,minY,minZ,maxX,maxY,maxZ},
--   width, height, y_offset, y_size, step_height, on_ground, fall, collided_h, collided_v, surface, no_clip}
-- Floats are Java floats (jmath.fround) wherever Java keeps a float.
local J = require "alphamine:jmath"
local chunks = require "alphamine:chunks"
local blocks = require "alphamine:blocks"

local fround, jfloor = J.fround, J.floor
local floor = math.floor
local band, rshift = bit.band, bit.rshift

local M = {
    -- extra collision boxes of entities (boats, minecarts): fn(entity, bb) -> list of boxes; set by entities
    entity_boxes = nil,
    stats = {moves = 0, boxes = 0},
}

local WATER = {[8] = true, [9] = true}
local LAVA = {[10] = true, [11] = true}
M.WATER, M.LAVA = WATER, LAVA

-- ------------------------------------------------------------------ blocks
local function block_at(x, y, z)
    local id, meta = chunks.get(x, y, z)
    return id, meta
end
M.block_at = block_at

local STAIRS = {[53] = true, [67] = true}
local DOORS = {[64] = true, [71] = true}
local F3_16 = fround(3.0 / 16.0)
local F2_16 = fround(2.0 / 16.0)
local F1_16 = fround(1.0 / 16.0)

-- Block.getCollidingBoundingBoxes: appends boxes that intersect bb (strict) to out, returns new count
local function push_box(out, n, bb, x0, y0, z0, x1, y1, z1)
    if x1 > bb[1] and x0 < bb[4] and y1 > bb[2] and y0 < bb[5] and z1 > bb[3] and z0 < bb[6] then
        n = n + 1
        local t = out[n]
        if not t then t = {}; out[n] = t end
        t[1], t[2], t[3], t[4], t[5], t[6] = x0, y0, z0, x1, y1, z1
    end
    return n
end

local function block_boxes(out, n, bb, id, meta, x, y, z)
    if STAIRS[id] then
        if meta == 0 then
            n = push_box(out, n, bb, x, y, z, x + 0.5, y + 0.5, z + 1)
            n = push_box(out, n, bb, x + 0.5, y, z, x + 1, y + 1, z + 1)
        elseif meta == 1 then
            n = push_box(out, n, bb, x, y, z, x + 0.5, y + 1, z + 1)
            n = push_box(out, n, bb, x + 0.5, y, z, x + 1, y + 0.5, z + 1)
        elseif meta == 2 then
            n = push_box(out, n, bb, x, y, z, x + 1, y + 0.5, z + 0.5)
            n = push_box(out, n, bb, x, y, z + 0.5, x + 1, y + 1, z + 1)
        elseif meta == 3 then
            n = push_box(out, n, bb, x, y, z, x + 1, y + 1, z + 0.5)
            n = push_box(out, n, bb, x, y, z + 0.5, x + 1, y + 0.5, z + 1)
        end
        return n
    end
    if DOORS[id] then
        -- BlockDoor.getState: (meta & 4) == 0 ? meta - 1 & 3 : meta & 3
        local st = band(meta, 4) == 0 and band(meta - 1, 3) or band(meta, 3)
        if st == 0 then return push_box(out, n, bb, x, y, z, x + 1, y + 1, z + F3_16) end
        if st == 1 then return push_box(out, n, bb, x + (1 - F3_16), y, z, x + 1, y + 1, z + 1) end
        if st == 2 then return push_box(out, n, bb, x, y, z + (1 - F3_16), x + 1, y + 1, z + 1) end
        return push_box(out, n, bb, x, y, z, x + F3_16, y + 1, z + 1)
    end
    if id == 65 then -- ladder: bounds by meta, other metas keep the last bounds set (start: full block)
        if meta == 2 then return push_box(out, n, bb, x, y, z + (1 - F2_16), x + 1, y + 1, z + 1) end
        if meta == 3 then return push_box(out, n, bb, x, y, z, x + 1, y + 1, z + F2_16) end
        if meta == 4 then return push_box(out, n, bb, x + (1 - F2_16), y, z, x + 1, y + 1, z + 1) end
        if meta == 5 then return push_box(out, n, bb, x, y, z, x + F2_16, y + 1, z + 1) end
    end
    if id == 81 then -- cactus: (float)x + 1/16 ...
        return push_box(out, n, bb, fround(x + F1_16), y, fround(z + F1_16), fround((x + 1) - F1_16),
                        fround((y + 1) - F1_16), fround((z + 1) - F1_16))
    end
    local b = blocks.box[id]
    if not b then return n end
    return push_box(out, n, bb, x + b[1], y + b[2], z + b[3], x + b[4], y + b[5], z + b[6])
end

-- World.getCollidingBoundingBoxes(entity, bb) -> boxes (shared table), count
local tmp = {}
local function colliding(e, bb)
    local n = 0
    local x0, x1 = jfloor(bb[1]), jfloor(bb[4] + 1.0)
    local y0, y1 = jfloor(bb[2]), jfloor(bb[5] + 1.0)
    local z0, z1 = jfloor(bb[3]), jfloor(bb[6] + 1.0)
    for x = x0, x1 - 1 do
        for z = z0, z1 - 1 do
            if chunks.has_chunk(floor(x / 16), floor(z / 16)) then  -- blockExists(x, 64, z)
                for y = y0 - 1, y1 - 1 do
                    local id, meta = block_at(x, y, z)
                    if id ~= 0 then n = block_boxes(tmp, n, bb, id, meta, x, y, z) end
                end
            end
        end
    end
    if M.entity_boxes then n = M.entity_boxes(e, bb, tmp, n) end
    M.stats.boxes = M.stats.boxes + n
    return tmp, n
end
M.colliding = colliding
M.push_box = push_box

-- ------------------------------------------------------------------ AxisAlignedBB
local function y_offset(c, bb, d)
    if bb[4] > c[1] and bb[1] < c[4] and bb[6] > c[3] and bb[3] < c[6] then
        if d > 0 and bb[5] <= c[2] then
            local v = c[2] - bb[5]
            if v < d then d = v end
        end
        if d < 0 and bb[2] >= c[5] then
            local v = c[5] - bb[2]
            if v > d then d = v end
        end
    end
    return d
end
local function x_offset(c, bb, d)
    if bb[5] > c[2] and bb[2] < c[5] and bb[6] > c[3] and bb[3] < c[6] then
        if d > 0 and bb[4] <= c[1] then
            local v = c[1] - bb[4]
            if v < d then d = v end
        end
        if d < 0 and bb[1] >= c[4] then
            local v = c[4] - bb[1]
            if v > d then d = v end
        end
    end
    return d
end
local function z_offset(c, bb, d)
    if bb[4] > c[1] and bb[1] < c[4] and bb[5] > c[2] and bb[2] < c[5] then
        if d > 0 and bb[6] <= c[3] then
            local v = c[3] - bb[6]
            if v < d then d = v end
        end
        if d < 0 and bb[3] >= c[6] then
            local v = c[6] - bb[3]
            if v > d then d = v end
        end
    end
    return d
end

local function add_coord(bb, dx, dy, dz, out)
    local x0, y0, z0, x1, y1, z1 = bb[1], bb[2], bb[3], bb[4], bb[5], bb[6]
    if dx < 0 then x0 = x0 + dx elseif dx > 0 then x1 = x1 + dx end
    if dy < 0 then y0 = y0 + dy elseif dy > 0 then y1 = y1 + dy end
    if dz < 0 then z0 = z0 + dz elseif dz > 0 then z1 = z1 + dz end
    out[1], out[2], out[3], out[4], out[5], out[6] = x0, y0, z0, x1, y1, z1
    return out
end
local function offset(bb, dx, dy, dz)
    bb[1], bb[2], bb[3] = bb[1] + dx, bb[2] + dy, bb[3] + dz
    bb[4], bb[5], bb[6] = bb[4] + dx, bb[5] + dy, bb[6] + dz
end
local function copy(src, dst)
    dst = dst or {}
    for i = 1, 6 do dst[i] = src[i] end
    return dst
end
M.offset, M.copy, M.add_coord = offset, copy, add_coord

-- ------------------------------------------------------------------ Entity
function M.new(t)
    local e = {x = 0, y = 0, z = 0, mx = 0, my = 0, mz = 0, yaw = 0, pitch = 0,
               bb = {0, 0, 0, 0, 0, 0}, width = fround(0.6), height = fround(1.8), y_offset = 0, y_size = 0,
               step_height = 0, on_ground = false, fall = 0, collided_h = false, collided_v = false,
               surface = true, no_clip = false, walked = 0}
    for k, v in pairs(t or {}) do e[k] = v end
    return e
end

-- Entity.setPosition
function M.set_position(e, x, y, z)
    e.x, e.y, e.z = x, y, z
    local w = fround(e.width / 2.0)
    local bb = e.bb
    bb[1], bb[2], bb[3] = x - w, y - e.y_offset + e.y_size, z - w
    bb[4], bb[5], bb[6] = x + w, y - e.y_offset + e.y_size + e.height, z + w
end

local q = {0, 0, 0, 0, 0, 0}
local saved, stepped = {0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0}
-- Entity.moveEntity(dx, dy, dz); fall_cb(e, dist) = Entity.fall
function M.move(e, dx, dy, dz, fall_cb)
    M.stats.moves = M.stats.moves + 1
    local bb = e.bb
    if e.no_clip then
        offset(bb, dx, dy, dz)
        e.x = (bb[1] + bb[4]) / 2.0
        e.y = bb[2] + e.y_offset - e.y_size
        e.z = (bb[3] + bb[6]) / 2.0
        return
    end
    local ox, oz = e.x, e.z
    local wx, wy, wz = dx, dy, dz
    copy(bb, saved)
    local boxes, n = colliding(e, add_coord(bb, dx, dy, dz, q))
    for i = 1, n do dy = y_offset(boxes[i], bb, dy) end
    offset(bb, 0, dy, 0)
    if not e.surface and wy ~= dy then dx, dy, dz = 0, 0, 0 end
    local ground = e.on_ground or (wy ~= dy and wy < 0)
    for i = 1, n do dx = x_offset(boxes[i], bb, dx) end
    offset(bb, dx, 0, 0)
    if not e.surface and wx ~= dx then dx, dy, dz = 0, 0, 0 end
    for i = 1, n do dz = z_offset(boxes[i], bb, dz) end
    offset(bb, 0, 0, dz)
    if not e.surface and wz ~= dz then dx, dy, dz = 0, 0, 0 end

    if e.step_height > 0 and ground and e.y_size < 0.05 and (wx ~= dx or wz ~= dz) then
        local sx, sy, sz = dx, dy, dz
        dx, dy, dz = wx, e.step_height, wz
        copy(bb, stepped)
        copy(saved, bb)
        boxes, n = colliding(e, add_coord(bb, wx, dy, wz, q))
        for i = 1, n do dy = y_offset(boxes[i], bb, dy) end
        offset(bb, 0, dy, 0)
        if not e.surface and wy ~= dy then dx, dy, dz = 0, 0, 0 end
        for i = 1, n do dx = x_offset(boxes[i], bb, dx) end
        offset(bb, dx, 0, 0)
        if not e.surface and wx ~= dx then dx, dy, dz = 0, 0, 0 end
        for i = 1, n do dz = z_offset(boxes[i], bb, dz) end
        offset(bb, 0, 0, dz)
        if not e.surface and wz ~= dz then dx, dy, dz = 0, 0, 0 end
        if sx * sx + sz * sz >= dx * dx + dz * dz then
            dx, dy, dz = sx, sy, sz
            copy(stepped, bb)
        else
            e.y_size = fround(e.y_size + 0.5)
        end
    end

    e.x = (bb[1] + bb[4]) / 2.0
    e.y = bb[2] + e.y_offset - e.y_size
    e.z = (bb[3] + bb[6]) / 2.0
    e.collided_h = wx ~= dx or wz ~= dz
    e.collided_v = wy ~= dy
    e.on_ground = wy ~= dy and wy < 0
    if e.on_ground then
        if e.fall > 0 then
            if fall_cb then fall_cb(e, e.fall) end
            e.fall = 0
        end
    elseif dy < 0 then
        e.fall = fround(e.fall - dy)
    end
    if wx ~= dx then e.mx = 0 end
    if wy ~= dy then e.my = 0 end
    if wz ~= dz then e.mz = 0 end
    local ddx, ddz = e.x - ox, e.z - oz
    e.walked = fround(e.walked + J.sqrt_double(ddx * ddx + ddz * ddz) * 0.6)
    e.y_size = fround(e.y_size * fround(0.4))
end

-- World.handleMaterialAcceleration / isMaterialInBB over bb.expand(0, -0.4F, 0)
local F04 = fround(0.4)
local function fluid_height(meta)
    if meta >= 8 then meta = 0 end
    return fround((meta + 1) / 9.0)
end
function M.in_water(e)
    local bb = e.bb
    local x0, x1 = jfloor(bb[1]), jfloor(bb[4] + 1.0)
    local y0, y1 = jfloor(bb[2] + F04), jfloor(bb[5] - F04 + 1.0)
    local z0, z1 = jfloor(bb[3]), jfloor(bb[6] + 1.0)
    local found = false
    for x = x0, x1 - 1 do
        for y = y0, y1 - 1 do
            for z = z0, z1 - 1 do
                local id, meta = block_at(x, y, z)
                if WATER[id] then
                    local h = fround((y + 1) - fluid_height(meta))
                    if y1 >= h then found = true end
                end
            end
        end
    end
    return found
end
function M.in_lava(e)
    local bb = e.bb
    local x0, x1 = jfloor(bb[1]), jfloor(bb[4] + 1.0)
    local y0, y1 = jfloor(bb[2] + F04), jfloor(bb[5] - F04 + 1.0)
    local z0, z1 = jfloor(bb[3]), jfloor(bb[6] + 1.0)
    for x = x0, x1 - 1 do
        for y = y0, y1 - 1 do
            for z = z0, z1 - 1 do
                if LAVA[(block_at(x, y, z))] then return true end
            end
        end
    end
    return false
end

-- Entity.isOffsetPositionInLiquid
function M.offset_free(e, dx, dy, dz)
    local bb = copy(e.bb, {})
    offset(bb, dx, dy, dz)
    local _, n = colliding(e, bb)
    if n > 0 then return false end
    local x0, x1 = jfloor(bb[1]), jfloor(bb[4] + 1.0)
    local y0, y1 = jfloor(bb[2]), jfloor(bb[5] + 1.0)
    local z0, z1 = jfloor(bb[3]), jfloor(bb[6] + 1.0)
    for x = x0, x1 - 1 do
        for y = y0, y1 - 1 do
            for z = z0, z1 - 1 do
                local id = block_at(x, y, z)
                if WATER[id] or LAVA[id] then return false end
            end
        end
    end
    return true
end

-- ------------------------------------------------------------------ light (World.getBrightness)
-- Alpha lightBrightnessTable: (1 - f) / (3f + 1) * 0.95 + 0.05, f = 1 - l / 15 (float)
local BRIGHT = {}
for l = 0, 15 do
    local f = fround(1.0 - fround(l / 15.0))
    BRIGHT[l] = fround(fround(fround(fround(1.0 - f) / fround(fround(f * 3.0) + 1.0)) * fround(0.95)) + fround(0.05))
end
M.BRIGHT = BRIGHT
local META, BLIGHT, SLIGHT = 32768, 49152, 65536
-- (sky, block) light nibbles from the chunk store; no chunk -> sky 15 above? Java: getBlockLightValue of a
-- missing chunk is 15 (ChunkProviderClient returns an empty chunk: skylight 15 only above... use 15)
function M.light_at(x, y, z)
    if y < 0 then return 0, 0 end
    if y > 127 then return 15, 0 end
    local cx, cz = floor(x / 16), floor(z / 16)
    local s = chunks.store[chunks.key(cx, cz)]
    if not s then return 15, 0 end
    local i = (x - cx * 16) * 2048 + (z - cz * 16) * 128 + y
    local p = s.bytes
    local h = rshift(i, 1)
    local odd = band(i, 1) ~= 0
    local sb, bb = p[SLIGHT + h], p[BLIGHT + h]
    if odd then return rshift(sb, 4), rshift(bb, 4) end
    return band(sb, 15), band(bb, 15)
end
-- World.getBlockLightValue (skylightSubtracted = 0 in multiplayer at time 0), with the Alpha rule for
-- slabs/farmland (use the max of neighbours) left out: entities stand in air blocks
function M.light_value(x, y, z, subtracted)
    local sky, blk = M.light_at(x, y, z)
    sky = sky - (subtracted or 0)
    return sky > blk and sky or blk
end
function M.brightness(x, y, z)
    return BRIGHT[M.light_value(x, y, z)]
end
-- Entity.getBrightness: floor(posX), floor(posY - yOffset + (maxY - minY) * 0.66), floor(posZ)
function M.entity_brightness(e)
    local h = (e.bb[5] - e.bb[2]) * 0.66
    return M.brightness(jfloor(e.x), jfloor(e.y - e.y_offset + h), jfloor(e.z))
end

return M
