-- World interaction of the Alpha client (phase 4, agent P): what the Java client does between the mouse and the
-- server when a block is dug or placed. Java classes and where they live here:
--   Minecraft.getMouseOver (EntityRenderer): M.mouse_over_at(partial) — EntityLiving.rayTrace(4.0 = PlayerControllerMP
--     .getBlockReachDistance) = World.rayTraceBlocks_do (DDA, 20 steps, the start cell is never tested) +
--     Block.collisionRayTrace with the block bounds (Block.minX..maxZ as doubles, setBlockBoundsBasedOnState for
--     doors/buttons/levers/rails/plates/wall signs, BlockTorch.collisionRayTrace), fluids and fire not hit
--     (canCollideCheck); then entities (players, carts, boats: bb.expand(0.1).calculateIntercept up to
--     min(hit distance, 3)). Per tick with partial 1 (runTick) -> M.mouse_over / game.mouse_over; per frame with
--     the frame's partial (renderWorld) -> M.frame_over (selection box and cracks are drawn on it).
--   Minecraft.clickMouse after the swing (the click loop, swing and leftClickCounter are agent U's fpview.lua,
--     which calls M.on_click(button)): left -> World.extinguishFire + PlayerControllerMP.clickBlock (Packet14
--     status 0, onBlockClicked, instant break when blockStrength >= 1); right -> blockActivated (doors, levers,
--     buttons locally; workbench/chest/furnace: their GUI is not done -> nothing), else onPlayerRightClick =
--     Packet15Place(held id, x, y, z, side) + ItemStack.useItem (ItemBlock.onItemUse placement prediction,
--     ItemSeeds/ItemReed/ItemRedstone/ItemHoe), then useItemRightClick (ItemFood/ItemSoup).
--   Minecraft.sendClickBlockToController -> M.click_block_tick (every tick after the click loop): held left on a
--     block -> PlayerControllerMP.sendBlockRemoving (Packet16 sync, Packet14 status 1, blockHitDelay 5,
--     curBlockDamageMP += Block.blockStrength(player), step sound every 4th hit, >= 1 -> sendBlockRemoved:
--     Packet14 status 3, local removal, tool damage), otherwise resetBlockRemoving (Packet14 status 2 once).
--   PlayerControllerMP.onUpdate (prev damage) -> M.tick_begin; setPartialTime -> M.frame (game.dig for the cracks:
--     RenderGlobal.drawBlockBreaking draws tile 240 + (int)(damagePartialTime * 10) on the block under the cursor).
--   WorldClient: every client-side block change keeps the old block for 80 ticks (WorldBlockPositionType) and puts
--     it back unless the server confirms by BlockChange / MultiBlockChange / MapChunk over it (M.set_block,
--     M.world_tick, M.invalidate).
-- Packet14 statuses in Alpha 1.0.16 (PlayerControllerMP / NetServerHandler.handleBlockDig): 0 = clickBlock, 1 = every
-- tick while digging, 2 = resetBlockRemoving (coordinates 0), 3 = sendBlockRemoved (the client broke it; the server
-- only answers with a BlockChange: its own ItemInWorldManager counts the damage from the status 1 packets).
-- The server's /gamemode 1 (patched NetServerHandler.isCreative) breaks on status 0; the Java client does not know
-- the mode, so neither do we: the block disappears by the server's BlockChange while the cracks still grow.
local J = require "alphamine:jmath"
local chunks = require "alphamine:chunks"
local T = require "alphamine:interact_table"
local pl = require "alphamine:player"
local inv = require "alphamine:inventory"
local relight = require "alphamine:relight"

local fround, jfloor, F = J.fround, J.floor, J.F
local floor = math.floor

local M = {
    reach = 4.0,              -- PlayerControllerMP.getBlockReachDistance
    mouse_over = nil,         -- tick: {type="block", x, y, z, side, hx, hy, hz} | {type="entity", id} | nil
    frame_over = nil,         -- frame (partial)
    -- PlayerControllerMP
    cur_x = -1, cur_y = -1, cur_z = -1,
    cur_damage = 0, prev_damage = 0, step_counter = 0, hit_delay = 0, hitting = false,
    damage_partial = 0,       -- setPartialTime -> RenderGlobal.damagePartialTime
    -- WorldClient
    pending = {},             -- {x, y, z, id, meta, countdown}
    sounds = {},              -- last sounds (F2F state): {tick, name, x, y, z, volume, pitch}
    equip_reset_tick = nil,   -- ItemRenderer.resetEquippedProgress (clickMouse right, stack size changed)
    stats = {clicks = {0, 0}, dig_packets = {0, 0, 0, 0}, places = 0, breaks = 0, rollbacks = 0, confirmed = 0,
             activated = 0, eaten = 0, local_sets = 0},
}

local function game() return package.loaded["alphamine:modules/game.lua"] end
local function net() return package.loaded["alphamine:modules/net.lua"] end
local function log(m) debug.log("[alphamine] interact: " .. m) end

-- ------------------------------------------------------------------ blocks
local function block_at(x, y, z)
    local id, meta = chunks.get(x, y, z)
    return id, meta
end
M.block_at = block_at

local function info(id) return T.blocks[id] end

local LIQUID = {[8] = true, [9] = true, [10] = true, [11] = true}
local function material(id)
    local b = T.blocks[id]
    return b and b.material or "air"
end
local SOLID_MAT = {}   -- Material.isSolid
for id, b in pairs(T.blocks) do
    local m = b.material
    SOLID_MAT[m] = not (m == "air" or m == "water" or m == "lava" or m == "plants" or m == "circuits" or m == "fire"
        or m == "snow")
end
-- World.isBlockNormalCube: Block.opaqueCubeLookup
local function normal_cube(x, y, z)
    local id = block_at(x, y, z)
    local b = T.blocks[id]
    return b ~= nil and b.opaque == true
end

-- Block bounds for the ray trace (the last setBlockBounds of the Block object; state-dependent ones here).
-- Java keeps them as (double) of float expressions.
local f = fround
local F1_16, F2_16, F3_16 = f(1 / 16), f(2 / 16), f(3 / 16)
local function bounds(id, meta)
    local b = T.blocks[id]
    if not b then return 0, 0, 0, 1, 1, 1 end
    local c = b.cls
    if c == "BlockTorch" then
        -- BlockTorch.collisionRayTrace
        local m, w = meta % 8, F[0.15]
        if m == 1 then return 0, F[0.2], f(0.5 - w), f(w * 2), F[0.8], f(0.5 + w)
        elseif m == 2 then return f(1 - f(w * 2)), F[0.2], f(0.5 - w), 1, F[0.8], f(0.5 + w)
        elseif m == 3 then return f(0.5 - w), F[0.2], 0, f(0.5 + w), F[0.8], f(w * 2)
        elseif m == 4 then return f(0.5 - w), F[0.2], f(1 - f(w * 2)), f(0.5 + w), F[0.8], 1 end
        w = F[0.1]
        return f(0.5 - w), 0, f(0.5 - w), f(0.5 + w), F[0.6], f(0.5 + w)
    elseif c == "BlockDoor" then
        local st = (meta % 8 >= 4) and (meta % 4) or ((meta - 1) % 4)
        if st == 0 then return 0, 0, 0, 1, 1, F3_16
        elseif st == 1 then return f(1 - F3_16), 0, 0, 1, 1, 1
        elseif st == 2 then return 0, 0, f(1 - F3_16), 1, 1, 1
        else return 0, 0, 0, F3_16, 1, 1 end
    elseif c == "BlockButton" then
        local m, pressed = meta % 8, meta >= 8
        local y0, y1, h, d = f(6 / 16), f(10 / 16), F3_16, pressed and F1_16 or F2_16
        if m == 1 then return 0, y0, f(0.5 - h), d, y1, f(0.5 + h)
        elseif m == 2 then return f(1 - d), y0, f(0.5 - h), 1, y1, f(0.5 + h)
        elseif m == 3 then return f(0.5 - h), y0, 0, f(0.5 + h), y1, d
        elseif m == 4 then return f(0.5 - h), y0, f(1 - d), f(0.5 + h), y1, 1 end
    elseif c == "BlockLever" then
        local m, w = meta % 8, F3_16
        if m == 1 then return 0, F[0.2], f(0.5 - w), f(w * 2), F[0.8], f(0.5 + w)
        elseif m == 2 then return f(1 - f(w * 2)), F[0.2], f(0.5 - w), 1, F[0.8], f(0.5 + w)
        elseif m == 3 then return f(0.5 - w), F[0.2], 0, f(0.5 + w), F[0.8], f(w * 2)
        elseif m == 4 then return f(0.5 - w), F[0.2], f(1 - f(w * 2)), f(0.5 + w), F[0.8], 1 end
        return 0.25, 0, 0.25, 0.75, F[0.6], 0.75
    elseif c == "BlockMinecartTrack" then
        if meta >= 2 and meta <= 5 then return 0, 0, 0, 1, f(10 / 16), 1 end
        return 0, 0, 0, 1, F2_16, 1
    elseif c == "BlockPressurePlate" then
        if meta == 1 then return F1_16, 0, F1_16, f(1 - F1_16), 0.03125, f(1 - F1_16) end
        return F1_16, 0, F1_16, f(1 - F1_16), F1_16, f(1 - F1_16)
    elseif c == "BlockSign" and id == 68 then
        local y0, y1, d = f(9 / 32), f(25 / 32), F2_16
        if meta == 2 then return 0, y0, f(1 - d), 1, y1, 1
        elseif meta == 3 then return 0, y0, 0, 1, y1, d
        elseif meta == 4 then return f(1 - d), y0, 0, 1, y1, 1
        elseif meta == 5 then return 0, y0, 0, d, y1, 1 end
        return 0, 0, 0, 1, 1, 1
    end
    local bb = b.bounds
    return bb[1], bb[2], bb[3], bb[4], bb[5], bb[6]
end
M.bounds = bounds

-- ------------------------------------------------------------------ ray trace (Vec3D / Block / World)
local EPS7 = F[1.0E-7]
-- Vec3D.getIntermediateWith{X,Y,Z}Value: a + (b - a) * t at the plane, nil outside [0, 1]
local function inter(ax, ay, az, bx, by, bz, axis, v)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local d, a = dx, ax
    if axis == 2 then d, a = dy, ay elseif axis == 3 then d, a = dz, az end
    if d * d < EPS7 then return nil end
    local t = (v - a) / d
    if t >= 0.0 and t <= 1.0 then return ax + dx * t, ay + dy * t, az + dz * t end
    return nil
end
local function dist(ax, ay, az, bx, by, bz)   -- Vec3D.distanceTo: (double)MathHelper.sqrt_double
    local dx, dy, dz = bx - ax, by - ay, bz - az
    return J.sqrt_double(dx * dx + dy * dy + dz * dz)
end

-- Block.collisionRayTrace: nearest of the 6 plane hits inside the box, side of that plane (ties: first wins)
local function collision_ray_trace(id, meta, bx, by, bz, sx, sy, sz, ex, ey, ez)
    local x0, y0, z0, x1, y1, z1 = bounds(id, meta)
    local ax, ay, az = sx + (-bx), sy + (-by), sz + (-bz)
    local qx, qy, qz = ex + (-bx), ey + (-by), ez + (-bz)
    local best, bd, hx, hy, hz
    local planes = {{1, x0, 4}, {1, x1, 5}, {2, y0, 0}, {2, y1, 1}, {3, z0, 2}, {3, z1, 3}}
    for k = 1, 6 do
        local p = planes[k]
        local px, py, pz = inter(ax, ay, az, qx, qy, qz, p[1], p[2])
        if px then
            local ok
            if p[1] == 1 then ok = py >= y0 and py <= y1 and pz >= z0 and pz <= z1
            elseif p[1] == 2 then ok = px >= x0 and px <= x1 and pz >= z0 and pz <= z1
            else ok = px >= x0 and px <= x1 and py >= y0 and py <= y1 end
            if ok then
                local d = dist(ax, ay, az, px, py, pz)
                if not best or d < bd then best, bd, hx, hy, hz = p[3], d, px, py, pz end
            end
        end
    end
    if not best then return nil end
    return {type = "block", x = bx, y = by, z = bz, side = best, hx = hx + bx, hy = hy + by, hz = hz + bz}
end

-- World.rayTraceBlocks_do(start, end, false)
local function ray_trace(sx, sy, sz, ex, ey, ez)
    if sx ~= sx or sy ~= sy or sz ~= sz or ex ~= ex or ey ~= ey or ez ~= ez then return nil end
    local x1, y1, z1 = jfloor(ex), jfloor(ey), jfloor(ez)
    local x0, y0, z0 = jfloor(sx), jfloor(sy), jfloor(sz)
    local n = 20
    while n >= 0 do
        n = n - 1
        if sx ~= sx or sy ~= sy or sz ~= sz then return nil end
        if x0 == x1 and y0 == y1 and z0 == z1 then return nil end
        local nx, ny, nz = 999.0, 999.0, 999.0
        if x1 > x0 then nx = x0 + 1.0 end
        if x1 < x0 then nx = x0 + 0.0 end
        if y1 > y0 then ny = y0 + 1.0 end
        if y1 < y0 then ny = y0 + 0.0 end
        if z1 > z0 then nz = z0 + 1.0 end
        if z1 < z0 then nz = z0 + 0.0 end
        local tx, ty, tz = 999.0, 999.0, 999.0
        local dx, dy, dz = ex - sx, ey - sy, ez - sz
        if nx ~= 999.0 then tx = (nx - sx) / dx end
        if ny ~= 999.0 then ty = (ny - sy) / dy end
        if nz ~= 999.0 then tz = (nz - sz) / dz end
        local side
        if tx < ty and tx < tz then
            side = x1 > x0 and 4 or 5
            sx = nx
            sy = sy + dy * tx
            sz = sz + dz * tx
        elseif ty < tz then
            side = y1 > y0 and 0 or 1
            sx = sx + dx * ty
            sy = ny
            sz = sz + dz * ty
        else
            side = z1 > z0 and 2 or 3
            sx = sx + dx * tz
            sy = sy + dy * tz
            sz = nz
        end
        x0 = jfloor(sx)
        if side == 5 then x0 = x0 - 1 end
        y0 = jfloor(sy)
        if side == 1 then y0 = y0 - 1 end
        z0 = jfloor(sz)
        if side == 3 then z0 = z0 - 1 end
        local id, meta = block_at(x0, y0, z0)
        -- canCollideCheck(meta, false): fluids no (BlockFluid: flag && meta == 0), fire not collidable
        if id > 0 and not LIQUID[id] and id ~= 51 and T.blocks[id] then
            local hit = collision_ray_trace(id, meta, x0, y0, z0, sx, sy, sz, ex, ey, ez)
            if hit then return hit end
        end
    end
    return nil
end
M.ray_trace = ray_trace

-- EntityLiving.getLook (float math, MathHelper tables)
local D2R = fround(J.PI_F / F[180.0])
local function look(yaw, pitch)
    local a = fround(fround(-yaw * D2R) - J.PI_F)
    local f1, f2 = J.cos(a), J.sin(a)
    local p = fround(-pitch * D2R)
    local f3, f4 = -J.cos(p), J.sin(p)
    return fround(f2 * f3), f4, fround(f1 * f3)
end
M.look = look

-- AxisAlignedBB.calculateIntercept (squared distances, ties: first wins); returns hit distance source point
local function aabb_intercept(b, sx, sy, sz, ex, ey, ez)
    local best, bd, hx, hy, hz
    local planes = {{1, b[1]}, {1, b[4]}, {2, b[2]}, {2, b[5]}, {3, b[3]}, {3, b[6]}}
    for k = 1, 6 do
        local p = planes[k]
        local px, py, pz = inter(sx, sy, sz, ex, ey, ez, p[1], p[2])
        if px then
            local ok
            if p[1] == 1 then ok = py >= b[2] and py <= b[5] and pz >= b[3] and pz <= b[6]
            elseif p[1] == 2 then ok = px >= b[1] and px <= b[4] and pz >= b[3] and pz <= b[6]
            else ok = px >= b[1] and px <= b[4] and py >= b[2] and py <= b[5] end
            if ok then
                local dx, dy, dz = px - sx, py - sy, pz - sz
                local d = dx * dx + dy * dy + dz * dz
                if not best or d < bd then best, bd, hx, hy, hz = k, d, px, py, pz end
            end
        end
    end
    if not best then return nil end
    return hx, hy, hz
end

-- Minecraft.getMouseOver(partial) for the local player: eye = posX/posY/posZ (prev at partial < 1), look by
-- rotation (prevRotation at partial < 1)
function M.mouse_over_at(partial)
    if not pl.has_pos then return nil end
    local ex, ey, ez = pl.x, pl.y, pl.z
    local yaw, pitch = pl.yaw, pl.pitch
    local lx, ly, lz
    if partial ~= 1.0 then
        local fpv = package.loaded["alphamine:modules/fpview.lua"]
        if fpv and fpv.prev_x then
            ex = fpv.prev_x + (ex - fpv.prev_x) * partial
            ey = fpv.prev_y + (ey - fpv.prev_y) * partial
            ez = fpv.prev_z + (ez - fpv.prev_z) * partial
        end
        -- prevRotationYaw/Pitch of the local player follow setAngles (both move together), so the
        -- interpolated look equals the current one
    end
    lx, ly, lz = look(yaw, pitch)
    local r = M.reach
    local hit = ray_trace(ex, ey, ez, ex + lx * r, ey + ly * r, ez + lz * r)
    local d = r
    if hit then d = dist(ex, ey, ez, hit.hx, hit.hy, hit.hz) end
    if d > 3.0 then d = 3.0 end
    -- entities (EntityLiving / minecart / boat canBeCollidedWith): bb.expand(0.1).calculateIntercept
    local ents = package.loaded["alphamine:modules/entities.lua"]
    if ents then
        local tx, ty, tz = ex + lx * d, ey + ly * d, ez + lz * d
        local pb = pl.bb
        local ax0, ax1 = math.min(pb[1], pb[1] + lx * d), math.max(pb[4], pb[4] + lx * d)
        local ay0, ay1 = math.min(pb[2], pb[2] + ly * d), math.max(pb[5], pb[5] + ly * d)
        local az0, az1 = math.min(pb[3], pb[3] + lz * d), math.max(pb[6], pb[6] + lz * d)
        local best, bestd = nil, 0.0
        for _, e in ipairs(ents.order) do
            if not e.dead and not e.fx and (e.kind == "player" or e.kind == "cart" or e.kind == "boat") and e.bb then
                local b = e.bb
                if b[4] > ax0 and b[1] < ax1 and b[5] > ay0 and b[2] < ay1 and b[6] > az0 and b[3] < az1 then
                    local g = F[0.1]
                    local hx, hy, hz = aabb_intercept({b[1] - g, b[2] - g, b[3] - g, b[4] + g, b[5] + g, b[6] + g},
                        ex, ey, ez, tx, ty, tz)
                    if hx then
                        local dd = dist(ex, ey, ez, hx, hy, hz)
                        if dd < bestd or bestd == 0.0 then best, bestd = e, dd end
                    end
                end
            end
        end
        if best then return {type = "entity", id = best.id, kind = best.kind} end
    end
    return hit
end

-- ------------------------------------------------------------------ sounds (SoundManager.playSound)
M.snd_rand = J.Random(J.mix(0, "NetClientHandler", 0))
function M.play_sound(name, x, y, z, volume, pitch)
    local g = game()
    local s = M.sounds
    s[#s + 1] = {tick = g and g.rel_tick and g.rel_tick() or 0, name = name, x = x, y = y, z = z,
                 volume = volume, pitch = pitch}
    if #s > 24 then table.remove(s, 1) end
    if volume <= 0 then return end
    local vc = "am/" .. name:gsub("%.", "/"):gsub(" ", "_")
    if audio and audio.play_sound then
        pcall(audio.play_sound, vc, x, y, z, math.min(volume, 1.0), pitch, "regular")
    end
end
local function step_sound(id) local b = T.blocks[id]; return b and b.step end

-- ------------------------------------------------------------------ WorldClient
-- World.setBlockAndMetadata (via WorldClient: the old block waits 80 ticks for the server)
function M.set_block(x, y, z, id, meta, no_rollback)
    meta = meta or 0
    if y < 0 or y > 127 then return false end
    local oid, ometa, ok = chunks.get(x, y, z)
    if not ok then return false end
    if oid == id and ometa == meta then return false end   -- Chunk.setBlockIDWithMetadata: nothing changes
    chunks.block_change(x, y, z, id, meta)
    chunks.stats.block_changes = chunks.stats.block_changes - 1   -- not a server change
    M.stats.local_sets = M.stats.local_sets + 1
    if not no_rollback then M.pending[#M.pending + 1] = {x, y, z, oid, ometa, 80} end
    relight.block_changed(x, y, z, oid, id)
    return true
end

-- WorldClient.invalidateBlockReceiveRegion (BlockChange, MultiBlockChange, MapChunk)
function M.invalidate(x0, y0, z0, x1, y1, z1)
    local p = M.pending
    if #p == 0 then return end
    local keep = {}
    for _, e in ipairs(p) do
        if e[1] >= x0 and e[2] >= y0 and e[3] >= z0 and e[1] <= x1 and e[2] <= y1 and e[3] <= z1 then
            M.stats.confirmed = M.stats.confirmed + 1
        else
            keep[#keep + 1] = e
        end
    end
    M.pending = keep
end

-- NetClientHandler.handleBlockChange / handleMultiBlockChange: before the store is written
function M.on_server_block(x, y, z)
    M.invalidate(x, y, z, x, y, z)
end
-- after the store is written: the client relights (World.setBlockAndMetadata -> lighting)
function M.after_server_block(x, y, z, old_id, new_id)
    if old_id ~= new_id then relight.block_changed(x, y, z, old_id, new_id) end
end

-- WorldClient.tick after processReadPackets: countdown, then the old block comes back
function M.world_tick()
    local p = M.pending
    if #p == 0 then return end
    local keep = {}
    for _, e in ipairs(p) do
        e[6] = e[6] - 1
        if e[6] == 0 then
            M.stats.rollbacks = M.stats.rollbacks + 1
            local cur = chunks.get(e[1], e[2], e[3])
            chunks.block_change(e[1], e[2], e[3], e[4], e[5])
            chunks.stats.block_changes = chunks.stats.block_changes - 1
            relight.block_changed(e[1], e[2], e[3], cur, e[4])
        else
            keep[#keep + 1] = e
        end
    end
    M.pending = keep
end

-- ------------------------------------------------------------------ player strength (EntityPlayer / InventoryPlayer)
local HARVEST_MAT = {rock = true, iron = true, craftedSnow = true, snow = true}
local function can_harvest(id)
    local b = T.blocks[id]
    if not b or not HARVEST_MAT[b.material] then return true end
    local st = inv.current_item()
    if not st then return false end
    local it = T.items[st.id]
    return it ~= nil and it.harvest ~= nil and it.harvest[id] == true
end
M.can_harvest = can_harvest

-- Entity.isInsideOfMaterial(water) at posY + getEyeHeight (1.8 * 0.85F)
local EYE = fround(F[1.8] * F[0.85])
local function in_water_eyes()
    local y = pl.y + EYE
    local bx, by, bz = jfloor(pl.x), jfloor(y), jfloor(pl.z)
    local id, meta = block_at(bx, by, bz)
    if id == 8 or id == 9 then
        local m = meta >= 8 and 0 or meta
        local h = fround(fround(fround(m + 1) / F[9.0]) - fround(F[1.0] / F[9.0]))
        return y < fround((by + 1) - h)
    end
    return false
end

local function str_vs_block(id)
    local s = F[1.0]
    local st = inv.current_item()
    if st then
        local it = T.items[st.id]
        local v = it and it.str and it.str[id]
        s = fround(s * (v and F[v] or F[1.0]))
    end
    if in_water_eyes() then s = fround(s / F[5.0]) end
    if not pl.on_ground then s = fround(s / F[5.0]) end
    return s
end

-- Block.blockStrength(player)
function M.block_strength(id)
    local b = T.blocks[id]
    if not b then return 0 end
    local h = F[b.hardness]
    if h < 0 then return 0 end
    if not can_harvest(id) then return fround(fround(F[1.0] / h) / F[100.0]) end
    return fround(fround(str_vs_block(id) / h) / F[30.0])
end

-- ItemStack.damageItem / onDestroyBlock / hitEntity; destroyCurrentEquippedItem
local function damage_current(n)
    local st = inv.current_item()
    if not st then return end
    local it = T.items[st.id]
    st.meta = (st.meta or 0) + n
    if st.meta > (it and it.max_damage or 32) then
        st.count = st.count - 1
        if st.count < 0 then st.count = 0 end
        st.meta = 0
    end
    inv.dirty = true
    if st.count == 0 then inv.main[inv.current] = nil end
end
local function on_destroy_block()
    local st = inv.current_item()
    if not st then return end
    local it = T.items[st.id]
    local c = it and it.cls
    if c == "ItemPickaxe" or c == "ItemSpade" or c == "ItemAxe" then damage_current(1)
    elseif c == "ItemSword" then damage_current(2) end
end

-- ------------------------------------------------------------------ PlayerControllerMP
local function send_dig(status, x, y, z, face)
    M.stats.dig_packets[status + 1] = M.stats.dig_packets[status + 1] + 1
    local n = net()
    if n and n.send_block_dig then n.send_block_dig(status, x, y, z, face) end
end

-- neighbours that cannot stay without the removed block (onNeighborBlockChange -> setBlockWithNotify(0))
local NEEDS_BELOW = {[6] = true, [37] = true, [38] = true, [39] = true, [40] = true, [59] = true, [78] = true,
                     [55] = true, [66] = true, [70] = true, [72] = true, [83] = true, [81] = true}
local function notify_removed(x, y, z)
    local id = block_at(x, y + 1, z)
    if NEEDS_BELOW[id] then M.set_block(x, y + 1, z, 0, 0) end
end

-- PlayerController.sendBlockRemoved (the client part: effects, removal, sound)
local function remove_block_local(x, y, z)
    local fx = package.loaded["alphamine:modules/particles.lua"]
    if fx and fx.block_destroy then pcall(fx.block_destroy, x, y, z) end   -- addBlockDestroyEffects (U)
    local id = block_at(x, y, z)
    local ok = M.set_block(x, y, z, 0, 0)
    if ok and T.blocks[id] then
        local s = step_sound(id)
        M.play_sound(s.brk, x + 0.5, y + 0.5, z + 0.5, fround(fround(F[s.volume] + F[1.0]) / F[2.0]),
            fround(F[s.pitch] * F[0.8]))
        notify_removed(x, y, z)
    end
    return ok
end

-- PlayerControllerMP.sendBlockRemoved
local function send_block_removed(x, y, z, side)
    send_dig(3, x, y, z, side)
    local ok = remove_block_local(x, y, z)
    on_destroy_block()
    M.stats.breaks = M.stats.breaks + 1
    return ok
end

-- Block.onBlockClicked / blockActivated of the blocks that react on the client
local function activate(x, y, z, id, meta, from_click)
    local b = T.blocks[id]
    if not b then return false end
    local c = b.cls
    if c == "BlockDoor" then
        if id == 71 then return true end                  -- iron door: material iron -> nothing
        if meta >= 8 then                                 -- upper half: the lower one toggles
            if block_at(x, y - 1, z) == id then activate(x, y - 1, z, id, select(2, block_at(x, y - 1, z))) end
            return true
        end
        if block_at(x, y + 1, z) == id then M.set_block(x, y + 1, z, id, bit.bxor(meta, 4) + 8) end
        M.set_block(x, y, z, id, bit.bxor(meta, 4))
        local tf = package.loaded["alphamine:modules/texfx.lua"]
        local r = tf and tf.random and tf.random() or math.random()   -- F2FRandom.random(): the Math.random stream
        M.play_sound(r < 0.5 and "random.door_open" or "random.door_close", x + 0.5, y + 0.5, z + 0.5, 1.0, 1.0)
        return true
    elseif c == "BlockLever" or c == "BlockButton" then
        local m7, on = meta % 8, meta >= 8
        if c == "BlockButton" and on then return true end
        M.set_block(x, y, z, id, m7 + (on and 0 or 8))
        M.play_sound("random.click", x + 0.5, y + 0.5, z + 0.5, 0.3, on and 0.5 or 0.6)
        return true
    elseif c == "BlockRedstoneOre" then
        if id == 73 then M.set_block(x, y, z, 74, meta) end   -- glow
        return false
    elseif not from_click and (c == "BlockWorkbench" or c == "BlockFurnace" or c == "BlockChest") then
        -- displayWorkbenchGUI / displayGUIFurnace / displayGUIChest: those screens are not done
        log(c .. " GUI is not implemented")
        return true
    elseif c == "BlockJukeBox" and not from_click then
        if meta > 0 then M.set_block(x, y, z, id, 0); return true end
        return false
    end
    return false
end

-- PlayerControllerMP.clickBlock
function M.click_block(x, y, z, side)
    M.hitting = true
    send_dig(0, x, y, z, side)
    local id, meta = block_at(x, y, z)
    if id > 0 and M.cur_damage == 0 then activate(x, y, z, id, meta, true) end
    if id > 0 and M.block_strength(id) >= 1.0 then send_block_removed(x, y, z, side) end
end

-- PlayerControllerMP.resetBlockRemoving
function M.reset_block_removing()
    if M.hitting then
        M.hitting = false
        send_dig(2, 0, 0, 0, 0)
        M.cur_damage = 0
        M.hit_delay = 0
    end
end

-- PlayerControllerMP.sendBlockRemoving (every tick while the left button digs a block)
function M.send_block_removing(x, y, z, side)
    M.hitting = true
    inv.sync_current(net())
    send_dig(1, x, y, z, side)
    if M.hit_delay > 0 then
        M.hit_delay = M.hit_delay - 1
        return
    end
    if x == M.cur_x and y == M.cur_y and z == M.cur_z then
        local id = block_at(x, y, z)
        if id == 0 then return end
        M.cur_damage = fround(M.cur_damage + M.block_strength(id))
        if M.step_counter % 4.0 == 0.0 and T.blocks[id] then
            local s = step_sound(id)
            M.play_sound(s.name, x + 0.5, y + 0.5, z + 0.5, fround(fround(F[s.volume] + F[1.0]) / F[8.0]),
                fround(F[s.pitch] * F[0.5]))
        end
        M.step_counter = fround(M.step_counter + 1)
        if M.cur_damage >= 1.0 then
            send_block_removed(x, y, z, side)
            M.cur_damage, M.prev_damage, M.step_counter = 0, 0, 0
            M.hit_delay = 5
        end
    else
        M.cur_damage, M.prev_damage, M.step_counter = 0, 0, 0
        M.cur_x, M.cur_y, M.cur_z = x, y, z
    end
end

-- ------------------------------------------------------------------ placement (ItemBlock.onItemUse and friends)
local PLANT_SOIL = {[2] = true, [3] = true, [60] = true}
local function can_place_block_at(bid, x, y, z)
    local id = block_at(x, y, z)
    local here_ok = id == 0 or LIQUID[id]
    local b = T.blocks[bid]
    local c = b and b.cls or ""
    if bid == 6 or bid == 37 or bid == 38 then return here_ok and PLANT_SOIL[block_at(x, y - 1, z)] == true end
    if bid == 39 or bid == 40 then return here_ok and normal_cube(x, y - 1, z) end
    if bid == 59 then return here_ok and block_at(x, y - 1, z) == 60 end
    if c == "BlockTorch" or c == "BlockLever" then
        return normal_cube(x - 1, y, z) or normal_cube(x + 1, y, z) or normal_cube(x, y, z - 1)
            or normal_cube(x, y, z + 1) or normal_cube(x, y - 1, z)
    end
    if c == "BlockLadder" or c == "BlockButton" then
        return normal_cube(x - 1, y, z) or normal_cube(x + 1, y, z) or normal_cube(x, y, z - 1)
            or normal_cube(x, y, z + 1)
    end
    if bid == 55 or bid == 66 or bid == 70 or bid == 72 then return normal_cube(x, y - 1, z) end
    if bid == 78 then return SOLID_MAT[material(block_at(x, y - 1, z))] == true end
    if bid == 83 then
        local below = block_at(x, y - 1, z)
        if below == 83 then return true end
        if below ~= 2 and below ~= 3 then return false end
        local function wat(ax, az) local w = block_at(ax, y - 1, az); return w == 8 or w == 9 end
        return wat(x - 1, z) or wat(x + 1, z) or wat(x, z - 1) or wat(x, z + 1)
    end
    if bid == 81 then
        if not here_ok then return false end
        for _, d in ipairs({{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) do
            if SOLID_MAT[material(block_at(x + d[1], y, z + d[2]))] then return false end
        end
        local below = block_at(x, y - 1, z)
        return below == 81 or below == 12
    end
    return here_ok
end

-- World.checkIfAABBIsClear for the collision box of the new block (players, carts, boats)
local function box_clear(bid, x, y, z)
    local b = T.blocks[bid]
    local bt = require("alphamine:blocks_table")[bid]
    if not bt or not bt.box then return true end
    local bb = bt.box
    local x0, y0, z0, x1, y1, z1 = x + bb[1], y + bb[2], z + bb[3], x + bb[4], y + bb[5], z + bb[6]
    local function hits(e)
        local o = e.bb
        return o and o[4] > x0 and o[1] < x1 and o[5] > y0 and o[2] < y1 and o[6] > z0 and o[3] < z1
    end
    if pl.has_pos and hits(pl) then return false end
    local ents = package.loaded["alphamine:modules/entities.lua"]
    if ents then
        for _, e in ipairs(ents.order) do
            if not e.dead and not e.fx and (e.kind == "player" or e.kind == "cart" or e.kind == "boat") and hits(e) then
                return false
            end
        end
    end
    return true
end

-- World.canBlockBePlacedAt(id, x, y, z, false)
local function can_block_be_placed_at(bid, x, y, z)
    if not box_clear(bid, x, y, z) then return false end
    local id = block_at(x, y, z)
    if LIQUID[id] or id == 51 or id == 78 then return true end
    return bid > 0 and id == 0 and can_place_block_at(bid, x, y, z)
end

-- Block.onBlockPlaced (metadata by the clicked side)
local function placed_meta(bid, x, y, z, side)
    local b = T.blocks[bid]
    local c = b and b.cls or ""
    if c == "BlockTorch" then
        local m = 0
        if side == 1 and normal_cube(x, y - 1, z) then m = 5 end
        if side == 2 and normal_cube(x, y, z + 1) then m = 4 end
        if side == 3 and normal_cube(x, y, z - 1) then m = 3 end
        if side == 4 and normal_cube(x + 1, y, z) then m = 2 end
        if side == 5 and normal_cube(x - 1, y, z) then m = 1 end
        return m
    elseif c == "BlockLadder" then
        local m = 0
        if (m == 0 or side == 2) and normal_cube(x, y, z + 1) then m = 2 end
        if (m == 0 or side == 3) and normal_cube(x, y, z - 1) then m = 3 end
        if (m == 0 or side == 4) and normal_cube(x + 1, y, z) then m = 4 end
        if (m == 0 or side == 5) and normal_cube(x - 1, y, z) then m = 5 end
        return m
    elseif c == "BlockButton" or c == "BlockLever" then
        local m = 0
        if c == "BlockLever" and side == 1 and normal_cube(x, y - 1, z) then m = 5 end   -- Java: 5 + World.l.nextInt(2)
        if side == 2 and normal_cube(x, y, z + 1) then m = 4 end
        if side == 3 and normal_cube(x, y, z - 1) then m = 3 end
        if side == 4 and normal_cube(x + 1, y, z) then m = 2 end
        if side == 5 and normal_cube(x - 1, y, z) then m = 1 end
        return m
    end
    return 0
end

local function side_offset(x, y, z, side)
    if side == 0 then y = y - 1 elseif side == 1 then y = y + 1
    elseif side == 2 then z = z - 1 elseif side == 3 then z = z + 1
    elseif side == 4 then x = x - 1 elseif side == 5 then x = x + 1 end
    return x, y, z
end

-- ItemBlock.onItemUse / ItemReed.onItemUse (spawnID)
local function place_block(st, bid, x, y, z, side)
    if block_at(x, y, z) == 78 then side = 0 else x, y, z = side_offset(x, y, z, side) end
    if st.count == 0 then return false end
    if can_block_be_placed_at(bid, x, y, z) then
        if M.set_block(x, y, z, bid, 0) then
            local m = placed_meta(bid, x, y, z, side)
            if m ~= 0 then M.set_block(x, y, z, bid, m, true) end
            local s = step_sound(bid)
            if s then
                M.play_sound(s.name, x + 0.5, y + 0.5, z + 0.5, fround(fround(F[s.volume] + F[1.0]) / F[2.0]),
                    fround(F[s.pitch] * F[0.8]))
            end
            st.count = st.count - 1
            M.stats.places = M.stats.places + 1
        end
    end
    return true
end

-- ItemStack.useItem -> Item.onItemUse
local function use_item(st, x, y, z, side)
    local it = T.items[st.id]
    if st.id < 256 then return place_block(st, st.id, x, y, z, side) end
    local c = it and it.cls or ""
    if c == "ItemReed" then return place_block(st, it.places or 83, x, y, z, side)
    elseif c == "ItemSeeds" then
        if side ~= 1 then return false end
        if block_at(x, y, z) == 60 then
            M.set_block(x, y + 1, z, it.places or 59, 0)
            st.count = st.count - 1
            return true
        end
        return false
    elseif c == "ItemRedstone" then
        x, y, z = side_offset(x, y, z, side)
        if block_at(x, y, z) ~= 0 then return false end
        if normal_cube(x, y - 1, z) then
            st.count = st.count - 1
            M.set_block(x, y, z, 55, 0)
        end
        return true
    elseif c == "ItemHoe" then
        local id = block_at(x, y, z)
        local above = block_at(x, y + 1, z)
        if (SOLID_MAT[material(above)] or id ~= 2) and id ~= 3 then return false end
        local s = step_sound(60)
        M.play_sound(s.name, x + 0.5, y + 0.5, z + 0.5, fround(fround(F[s.volume] + F[1.0]) / F[2.0]),
            fround(F[s.pitch] * F[0.8]))
        M.set_block(x, y, z, 60, 0)
        damage_current(1)   -- the client-side seed drop (World.l.nextInt(8)) is not modelled
        return true
    end
    return false   -- Item.onItemUse: doors, signs, buckets, minecarts... only the packet goes to the server
end

-- ------------------------------------------------------------------ Minecraft.clickMouse (after the swing, U)
function M.on_click(button)
    M.stats.clicks[button + 1] = (M.stats.clicks[button + 1] or 0) + 1
    local hit = M.mouse_over
    local n = net()
    if hit and hit.type == "entity" then
        if button == 0 then
            -- EntityPlayer.attackEntity: client-side only in protocol 14 (no packet); the held tool wears
            local st = inv.current_item()
            local it = st and T.items[st.id]
            if it and (it.cls == "ItemPickaxe" or it.cls == "ItemSpade" or it.cls == "ItemAxe") then damage_current(2)
            elseif it and it.cls == "ItemSword" then damage_current(1) end
        end
    elseif hit and hit.type == "block" then
        local x, y, z, side = hit.x, hit.y, hit.z, hit.side
        local id, meta = block_at(x, y, z)
        if button == 0 then
            -- World.extinguishFire
            local fx, fy, fz = side_offset(x, y, z, side)
            if block_at(fx, fy, fz) == 51 then
                M.play_sound("random.fizz", fx + 0.5, fy + 0.5, fz + 0.5, 0.5, 2.6)
                M.set_block(fx, fy, fz, 0, 0)
            end
            if id ~= 7 then M.click_block(x, y, z, side) end   -- bedrock: unusedMiningCooldown is never >= 100
        else
            local st = inv.current_item()
            if id > 0 and activate(x, y, z, id, meta, false) then
                M.stats.activated = M.stats.activated + 1
                return
            end
            if not st then return end
            local before = st.count
            -- PlayerControllerMP.onPlayerRightClick: sync, Packet15Place, ItemStack.useItem
            inv.sync_current(n)
            if n and n.send_place then n.send_place(st.id, x, y, z, side) end
            if use_item(st, x, y, z, side) then
                local fpv = package.loaded["alphamine:modules/fpview.lua"]
                if fpv and fpv.swing_item then fpv.swing_item(n) end
            end
            if st.count == 0 then
                if inv.main[inv.current] == st then inv.main[inv.current] = nil end
            elseif st.count ~= before then
                local g = game()
                M.equip_reset_tick = g and g.tick or 0   -- ItemRenderer.resetEquippedProgress
            end
            inv.dirty = true
        end
    end
    if button == 1 then
        -- ItemStack.useItemRightClick (food; the others return the same stack)
        local st = inv.current_item()
        if st then
            local it = T.items[st.id]
            if it and it.heal and (it.cls == "ItemFood" or it.cls == "ItemSoup") then
                st.count = st.count - 1
                if pl.health > 0 then pl.health = math.min(20, pl.health + it.heal) end
                M.stats.eaten = M.stats.eaten + 1
                if it.cls == "ItemSoup" then
                    inv.main[inv.current] = {id = 281, count = 1, meta = 0}
                elseif st.count == 0 then
                    inv.main[inv.current] = nil
                end
                inv.dirty = true
            end
        end
    end
end

-- ------------------------------------------------------------------ hooks into game / net / U's modules
-- Installed once from the first tick (after game.lua defined its packet handlers):
--   BlockChange / MultiBlockChange / MapChunk: WorldClient.invalidateBlockReceiveRegion before the store is
--   written, client relight after; Collect: EntityPickupFX instead of an instant removal; fpview.on_click (U's
--   click loop calls it after the swing); particles.mouse_over (U's fpview asks it whether a click hit something:
--   leftClickCounter) = this Alpha ray trace; game.block_id for particles.
function M.install(g)
    if M.installed then return end
    M.installed = true
    local n = net()
    local H = n and n.handler
    local ents = package.loaded["alphamine:modules/entities.lua"]
    if H then
        local bc, mbc, mc = H.block_change, H.multi_block_change, H.map_chunk
        H.block_change = function(x, y, z, id, meta)
            M.on_server_block(x, y, z)
            local old = chunks.get(x, y, z)
            bc(x, y, z, id, meta)
            M.after_server_block(x, y, z, old, id)
        end
        H.multi_block_change = function(cx, cz, cnt, coords, types, metas)
            local olds = {}
            for k = 1, cnt do
                local c = coords[k]
                local x, z, y = cx * 16 + bit.band(bit.rshift(c, 12), 15), cz * 16 + bit.band(bit.rshift(c, 8), 15),
                    bit.band(c, 255)
                M.on_server_block(x, y, z)
                olds[k] = {x, y, z, (chunks.get(x, y, z))}
            end
            mbc(cx, cz, cnt, coords, types, metas)
            for k = 1, cnt do
                local o = olds[k]
                M.after_server_block(o[1], o[2], o[3], o[4], types[k])
            end
        end
        H.map_chunk = function(x, y, z, sx, sy, sz, zlib)
            M.invalidate(x, y, z, x + sx - 1, y + sy - 1, z + sz - 1)
            mc(x, y, z, sx, sy, sz, zlib)
        end
        if ents and ents.collect then
            H.collect = function(item_eid, collector) ents.collect(item_eid, collector) end
        end
    end
    local fpv = package.loaded["alphamine:modules/fpview.lua"]
    if fpv then fpv.on_click = function(button) M.on_click(button) end end
    local ok, fx = pcall(require, "alphamine:particles")
    if ok and type(fx) == "table" then
        fx.mouse_over = function()
            local h = M.mouse_over
            if h and h.type == "block" then return h.x, h.y, h.z, h.side end
            return nil
        end
    end
    g.block_id = function(x, y, z) return (chunks.get(x, y, z)) end
    g.interact = M
end

-- keyBindInventory (Minecraft.runTick with no screen -> GuiInventory; GuiContainer.keyTyped: Esc or the same key
-- closes). Java F2F does not read options.txt -> the default key 23 (I); the user's options.txt binds 18 (E) ->
-- E in normal runs. Sampled here directly (the input focus is off while a screen document is open).
M.inv_key_state = {}
local function key_edge(name, code)
    local ok, v = pcall(input.is_pressed, code)
    v = ok and v or false
    local e = v and not M.inv_key_state[name]
    M.inv_key_state[name] = v
    return e
end
local function inventory_keys(g)
    local key = g.f2f and "key:i" or "key:e"
    local open_edge = key_edge("inv", key)
    local esc_edge = key_edge("esc", "key:escape")
    if g.screen == "ingame" and open_edge then
        M.reset_block_removing()
        inv.open_screen()
    elseif g.screen == "GuiInventory" and (open_edge or esc_edge) then
        inv.close_screen()
    end
end

-- ------------------------------------------------------------------ per tick hooks (game.run_tick)
-- start of runTick: getMouseOver(1.0); PlayerControllerMP.onUpdate: prevBlockDamageMP = curBlockDamageMP
function M.tick_begin(g)
    if g and not M.installed then M.install(g) end
    M.mouse_over = M.mouse_over_at(1.0)
    M.prev_damage = M.cur_damage
    -- the inventory key is handled by game.run_tick -> inventory_gui.lua (U); inventory_keys stays unused
end

-- after the click loop: Minecraft.sendClickBlockToController(0, currentScreen == null && left held && focus)
function M.click_block_tick(left_held, ingame)
    inv.decrement_animations()   -- (EntityPlayer.onLivingUpdate, just before the player physics)
    local fpv = package.loaded["alphamine:modules/fpview.lua"]
    if fpv and (fpv.left_click_counter or 0) > 0 then return end
    local hit = M.mouse_over
    if ingame and left_held and hit and hit.type == "block" then
        M.send_block_removing(hit.x, hit.y, hit.z, hit.side)
        local fx = package.loaded["alphamine:modules/particles.lua"]
        if fx and fx.block_hit_tick then pcall(fx.block_hit_tick, hit.x, hit.y, hit.z, hit.side) end
    else
        M.reset_block_removing()
    end
end

-- per frame before the world is drawn: getMouseOver(partial) + setPartialTime -> game.dig
function M.frame(partial)
    M.frame_over = M.mouse_over_at(partial)
    if M.cur_damage <= 0 then
        M.damage_partial = 0
    else
        M.damage_partial = fround(M.prev_damage + fround(fround(M.cur_damage - M.prev_damage) * partial))
    end
    local g = game()
    if not g then return end
    local o = M.frame_over
    g.mouse_over = M.mouse_over and M.mouse_over.type == "block" and M.mouse_over or nil
    g.frame_over = o
    if o and o.type == "block" and M.damage_partial > 0 then
        local stage = J.toint(fround(M.damage_partial * F[10.0]))
        g.dig = {x = o.x, y = o.y, z = o.z, stage = stage, damage = M.damage_partial}
    else
        g.dig = nil
    end
end

-- F2F mode: PlayerControllerMP fields keep their values in Java (only Minecraft.f2fReset clears ticksRan,
-- mouseTicksRan, leftClickCounter — fpview.lua); the sound stream is reseeded
function M.mode(seed)
    M.snd_rand = J.Random(J.mix(seed or 0, "NetClientHandler", 0))
    M.sounds = {}
end

-- F2F state
function M.report()
    local o = M.frame_over or M.mouse_over   -- Java: objectMouseOver of the last frame
    local r = {cur = {M.cur_x, M.cur_y, M.cur_z}, damage = M.cur_damage, prev_damage = M.prev_damage,
               hit_delay = M.hit_delay, hitting = M.hitting, step_counter = M.step_counter,
               pending = #M.pending, stats = M.stats, damage_partial = M.damage_partial}
    local g = game()
    if g and g.dig then r.cracks = {x = g.dig.x, y = g.dig.y, z = g.dig.z, stage = g.dig.stage} end
    if o and o.type == "block" then
        r.mouse_over = {type = "block", x = o.x, y = o.y, z = o.z, side = o.side}
    elseif o then
        r.mouse_over = {type = "entity", id = o.id}
    end
    local sounds = {}
    for i, s in ipairs(M.sounds) do sounds[i] = s end
    r.sounds = sounds
    return r
end

function M.reset()
    M.pending = {}
    M.cur_x, M.cur_y, M.cur_z, M.cur_damage, M.prev_damage, M.hit_delay, M.hitting = -1, -1, -1, 0, 0, 0, false
end

return M
