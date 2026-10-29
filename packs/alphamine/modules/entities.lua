-- Entities of the Alpha client (phase 3): NetClientHandler entity packets -> client entities with the Java
-- per-tick logic -> native VoxelCore entities (entities/*.json, skeletons/*.json, models/am_*.vcm generated
-- from the Java model classes by tools/alphamine/gen_models.py), posed every frame like the Java renderers.
--
-- Kinds (Java class in F2F state):
--   player  EntityOtherPlayerMP  Packet20; interpolation over 3 ticks (setPositionAndRotation(...,3)),
--           EntityLiving body yaw (renderYawOffset), limb swing, arm idle sway by ticksExisted, swing (Packet18),
--           held item (Packet16 / Packet20.currentItem), name tag (gfx.text3d), RenderPlayer/ModelBiped pose
--   item    EntityItem           Packet21; client physics (EntityItem.onUpdate: gravity 0.04, friction,
--           bounce, pushOutOfBlocks) + server corrections (setPosition), RenderItem: bob / spin by age and
--           hoverStart, block items as cubes (x0.25 / x0.5), others as camera-facing sprites, stack copies
--   cart    EntityMinecart (type 0 / 1 chest / 2 furnace) Packet23 type 10..12; interpolation over 3 ticks
--   boat    EntityBoat           Packet23 type 1; server corrections + buoyancy/move part of onUpdate
-- Positions from packets are fixed point /32 (serverPos += byte deltas for 30/31/33).
-- Light: Alpha brightness at the entity (physics.entity_brightness) as the skeleton tint; the pack entity
-- shader (shaders/entity.glsl*) applies RenderHelper's two lights.
local J = require "alphamine:jmath"
local P = require "alphamine:physics"
local mat = require "alphamine:mat"
local T = require "alphamine:models_table"

local fround, jfloor = J.fround, J.floor
local F = J.F

local M = {
    list = {},      -- [server id] = entity
    order = {},     -- spawn order (World entity list order)
    effects = {},   -- EntityPickupFX objects (phase 4)
    seed = 0,       -- F2F mode seed (entity rand)
    stats = {spawned = 0, destroyed = 0, engine_spawns = 0, engine_errors = 0, packets = 0},
    name_tags = true,
    shadows = false,
}

local KIND_CLASS = {player = "EntityOtherPlayerMP", item = "EntityItem", cart = "EntityMinecart", boat = "EntityBoat"}
local ENGINE_DEF = {player = "alphamine:am_player", item = "alphamine:am_item", cart = "alphamine:am_cart",
                    boat = "alphamine:am_boat"}

local function log(m) debug.log("[alphamine] entities: " .. m) end

-- ------------------------------------------------------------------ creation
local function base(id, kind, x, y, z)
    local e = P.new({id = id, kind = kind, ticks = 0, age = 0, dead = false, uid = nil,
                     last_x = x, last_y = y, last_z = z, prev_yaw = 0, prev_pitch = 0,
                     sx = 0, sy = 0, sz = 0})
    e.rand = J.Random(J.entity_seed(M.seed, id))
    return e
end

local function add(e)
    M.list[e.id] = e
    M.order[#M.order + 1] = e
    M.stats.spawned = M.stats.spawned + 1
end

-- Packet20NamedEntitySpawn -> EntityOtherPlayerMP (EntityPlayer: width 0.6, height 1.8, yOffset 0 for MP others)
function M.named_spawn(id, name, x, y, z, rot, pitch, item)
    local e = base(id, "player", x / 32.0, y / 32.0, z / 32.0)
    e.name = name
    e.width, e.height, e.y_offset = F[0.6], F[1.8], 0
    e.no_clip = true
    e.sx, e.sy, e.sz = x, y, z
    e.held = item or 0
    -- EntityLiving fields
    e.body_yaw, e.prev_body_yaw = 0, 0
    e.limb_yaw, e.prev_limb_yaw, e.limb_swing = 0, 0, 0
    e.swing_int, e.swinging, e.swing, e.prev_swing = 0, false, 0, 0
    e.incr = 0
    e.living_sound = 0
    local yaw = fround(fround(rot * 360) / F[256.0])
    local pit = fround(fround(pitch * 360) / F[256.0])
    -- setPositionAndRotation (5 args): prev = pos, rotation set
    P.set_position(e, x / 32.0, y / 32.0, z / 32.0)
    e.yaw, e.pitch = yaw, pit
    e.last_x, e.last_y, e.last_z = e.x, e.y, e.z
    e.prev_x, e.prev_y, e.prev_z = e.x, e.y, e.z
    e.prev_yaw, e.prev_pitch = yaw, pit
    add(e)
end

-- Packet21PickupSpawn -> EntityItem (0.25 x 0.25, yOffset = height / 2)
function M.pickup_spawn(id, item_id, count, x, y, z, rot, pitch, roll)
    local e = base(id, "item", x / 32.0, y / 32.0, z / 32.0)
    e.item, e.count = item_id, count
    e.width, e.height = F[0.25], F[0.25]
    e.y_offset = fround(e.height / 2.0)
    -- EntityItem field init hoverStart, then the constructor: rotationYaw, motionX, motionZ -- four numbers of the
    -- shared Math.random stream (F2FRandom.random, texfx.random); the motion is overwritten from the packet below
    local tf = package.loaded["alphamine:modules/texfx.lua"]
    local rnd = tf and tf.random or math.random
    e.hover = fround(rnd() * math.pi * 2.0)
    rnd(); rnd(); rnd()
    e.age = 0
    e.sx, e.sy, e.sz = x, y, z
    P.set_position(e, x / 32.0, y / 32.0, z / 32.0)
    e.mx, e.my, e.mz = rot / 128.0, pitch / 128.0, roll / 128.0
    e.last_x, e.last_y, e.last_z = e.x, e.y, e.z
    add(e)
end

-- Packet23VehicleSpawn: 10/11/12 minecart (type 0/1/2), 1 boat
function M.vehicle_spawn(id, vtype, x, y, z)
    local kind = (vtype >= 10 and vtype <= 12) and "cart" or (vtype == 1 and "boat" or nil)
    if not kind then return end
    local e = base(id, kind, x / 32.0, y / 32.0, z / 32.0)
    if kind == "cart" then
        e.cart_type = vtype - 10
        e.width, e.height = F[0.98], F[0.7]
    else
        e.width, e.height = F[1.5], F[0.6]
    end
    e.y_offset = fround(e.height / 2.0)
    e.sx, e.sy, e.sz = x, y, z
    P.set_position(e, x / 32.0, y / 32.0, z / 32.0)
    e.yaw, e.pitch = 0, 0
    e.incr = 0
    e.last_x, e.last_y, e.last_z = e.x, e.y, e.z
    add(e)
end

-- setPositionAndRotation(x, y, z, yaw, pitch, 3): players/carts interpolate, others jump
local function set_target(e, x, y, z, yaw, pitch)
    if e.kind == "player" then
        e.y_offset = 0
        e.tx, e.ty, e.tz, e.tyaw, e.tpitch, e.incr = x, y, z, yaw, pitch, 3
    elseif e.kind == "cart" then
        e.tx, e.ty, e.tz, e.tyaw, e.tpitch, e.incr = x, y, z, yaw, pitch, 3
    else
        P.set_position(e, x, y, z)
        e.yaw, e.pitch = yaw, pitch
    end
end

local function byte_angle(b) return fround(fround(b * 360) / F[256.0]) end

-- Packet30/31/32/33 (NetClientHandler.handleEntity)
function M.move(id, dx, dy, dz, yaw, pitch)
    local e = M.list[id]
    M.stats.packets = M.stats.packets + 1
    if not e then return end
    e.sx, e.sy, e.sz = e.sx + dx, e.sy + dy, e.sz + dz
    local ry = yaw and byte_angle(yaw) or e.yaw
    local rp = pitch and byte_angle(pitch) or e.pitch
    set_target(e, e.sx / 32.0, e.sy / 32.0, e.sz / 32.0, ry, rp)
end

-- Packet34EntityTeleport
function M.teleport(id, x, y, z, yaw, pitch)
    local e = M.list[id]
    M.stats.packets = M.stats.packets + 1
    if not e then return end
    e.sx, e.sy, e.sz = x, y, z
    set_target(e, x / 32.0, y / 32.0, z / 32.0, byte_angle(yaw), byte_angle(pitch))
end

function M.destroy(id)
    local e = M.list[id]
    if e then
        e.dead = true
        M.stats.destroyed = M.stats.destroyed + 1
    end
end

-- Packet22Collect (NetClientHandler.handleCollect): the server picked the item up (its EntityItem.onCollideWithPlayer:
-- delayBeforeCanPickup 0, room in the inventory -> Packet17 AddToInventory to the collector, Packet22 to everyone
-- tracking the item, Packet29 later). The client plays random.pop (0.2, ((r - r) * 0.7 + 1) * 2 from the
-- NetClientHandler Random), adds EntityPickupFX(item, collector or the local player, yOffs -0.5) and removes the item
-- from the world at once (the later DestroyEntity finds nothing). The effect lives 3 ticks (EffectRenderer after
-- WorldClient.tick: age 1 already in the tick of the packet, dead at 3 -> drawn over two ticks) and renders the
-- frozen item at item + (collector - item) * ((age + partial) / 3)^2, the collector interpolated by lastTickPos,
-- lit by the world brightness at that point. EntityFX's constructor draws 5 numbers of the shared Math.random
-- stream (F2FRandom.random: motion and speed) -> texfx.random().
function M.collect(item_id, collector_id)
    local e = M.list[item_id]
    if not e or e.kind ~= "item" then return false end
    local ia = package.loaded["alphamine:modules/interact.lua"]
    if ia and ia.play_sound then
        local r = ia.snd_rand
        local pitch = fround(fround(fround(fround(r:next_float() - r:next_float()) * F[0.7]) + F[1.0]) * F[2.0])
        ia.play_sound("random.pop", e.x, e.y - e.y_offset, e.z, F[0.2], pitch)
    end
    local tf = package.loaded["alphamine:modules/texfx.lua"]
    if tf and tf.random then for _ = 1, 5 do tf.random() end end
    local col = M.list[collector_id]
    -- the effect is a separate object (EffectRenderer layer 3 = F2F layer `particles`): its own engine entity with
    -- the frozen item fields; the item itself is setEntityDead but stays in loadedEntityList (and is drawn at its
    -- own place by the entity pass) until the next World.updateEntities purges it
    local fx = base(e.id, "item", e.x, e.y, e.z)
    for _, k in ipairs({"item", "count", "width", "height", "y_offset", "hover", "age", "sx", "sy", "sz"}) do
        fx[k] = e[k]
    end
    P.set_position(fx, e.x, e.y, e.z)
    fx.last_x, fx.last_y, fx.last_z = e.x, e.y, e.z
    fx.fx = {age = 0, max = 3, y_offs = -0.5, collector = (col and not col.dead) and col or nil}
    M.effects[#M.effects + 1] = fx
    e.dead, e.dead_listed = true, true
    M.list[item_id] = nil       -- WorldClient.removeEntityFromWorld
    M.stats.collected = (M.stats.collected or 0) + 1
    return true
end

-- EffectRenderer.updateEffects for the pickup effects (after WorldClient.tick): dead at age 3, gone at once
function M.update_effects()
    local keep = {}
    for _, fx in ipairs(M.effects) do
        fx.fx.age = fx.fx.age + 1
        if fx.fx.age >= fx.fx.max then
            M.despawn_engine(fx)
        else
            keep[#keep + 1] = fx
        end
    end
    M.effects = keep
end

-- the F2F `render` layer state (modules/f2f.lua records it): the pickup effect is a particle in Java
local function layer_on(name)
    local f = package.loaded["alphamine:modules/f2f.lua"]
    local l = f and f.layers
    if not l or l[name] == nil then return true end
    return l[name]
end

-- Packet16 (other player's held item), Packet18 (swing)
function M.item_switch(id, item)
    local e = M.list[id]
    if e and e.kind == "player" then e.held = item end
end
function M.arm_animation(id, anim)
    local e = M.list[id]
    if e and e.kind == "player" and anim == 1 then
        e.swing_int, e.swinging = -1, true   -- EntityPlayer.swingItem
    end
end

-- ------------------------------------------------------------------ per tick (World.updateEntities order)
local F004, F098, F02, F01 = F[0.04], F[0.98], F[0.2], F[0.1]
local OPAQUE
local function opaque(id)
    if not OPAQUE then
        OPAQUE = {}
        for bid, b in pairs(require("alphamine:blocks_table")) do OPAQUE[bid] = b.opaque end
    end
    return OPAQUE[id] or false
end

-- EntityItem.pushOutOfBlocks
local function push_out(e, x, y, z)
    local ix, iy, iz = jfloor(x), jfloor(y), jfloor(z)
    local fx, fy, fz = x - ix, y - iy, z - iz
    if not opaque(P.block_at(ix, iy, iz)) then return end
    local free = {
        not opaque(P.block_at(ix - 1, iy, iz)), not opaque(P.block_at(ix + 1, iy, iz)),
        not opaque(P.block_at(ix, iy - 1, iz)), not opaque(P.block_at(ix, iy + 1, iz)),
        not opaque(P.block_at(ix, iy, iz - 1)), not opaque(P.block_at(ix, iy, iz + 1)),
    }
    local dist = {fx, 1 - fx, fy, 1 - fy, fz, 1 - fz}
    local best, bd = -1, 9999.0
    for k = 1, 6 do
        if free[k] and dist[k] < bd then bd, best = dist[k], k - 1 end
    end
    local v = fround(fround(e.rand:next_float() * F02) + F01)
    if best == 0 then e.mx = -v elseif best == 1 then e.mx = v
    elseif best == 2 then e.my = -v elseif best == 3 then e.my = v
    elseif best == 4 then e.mz = -v elseif best == 5 then e.mz = v end
end

local function item_tick(e)
    -- Entity.onEntityUpdate
    e.ticks = e.ticks + 1
    e.prev_x, e.prev_y, e.prev_z = e.x, e.y, e.z
    -- EntityItem.onUpdate
    e.prev_x, e.prev_y, e.prev_z = e.x, e.y, e.z
    e.my = e.my - F004
    if P.LAVA[(P.block_at(jfloor(e.x), jfloor(e.y), jfloor(e.z)))] then
        e.my = F02
        e.mx = fround(fround(e.rand:next_float() - e.rand:next_float()) * F02)
        e.mz = fround(fround(e.rand:next_float() - e.rand:next_float()) * F02)
        e.rand:next_float()
    end
    push_out(e, e.x, e.y, e.z)
    P.move(e, e.mx, e.my, e.mz)
    local fr = F098
    if e.on_ground then
        fr = fround(fround(F[0.1] * F[0.1]) * F[58.8])
        local id = P.block_at(jfloor(e.x), jfloor(e.bb[2]) - 1, jfloor(e.z))
        if id > 0 then fr = fround((id == 79 and F[0.98] or F[0.6]) * F098) end
    end
    e.mx = e.mx * fr
    e.my = e.my * F098
    e.mz = e.mz * fr
    if e.on_ground then e.my = e.my * -0.5 end
    e.age = e.age + 1
    if e.age >= 6000 then e.dead = true end
end

local function wrap180(v)
    while v < -180 do v = v + 360 end
    while v >= 180 do v = v - 360 end
    return v
end

local function player_tick(e)
    -- EntityLiving.onEntityUpdate (prevSwingProgress; Entity: ticksExisted, prev pos/rot; living sound rand)
    e.prev_swing = e.swing
    e.ticks = e.ticks + 1
    e.prev_x, e.prev_y, e.prev_z = e.x, e.y, e.z
    if e.rand:next_int(1000) < e.living_sound then e.living_sound = -80 else e.living_sound = e.living_sound + 1 end
    e.prev_body_yaw = e.body_yaw
    e.prev_yaw, e.prev_pitch = e.yaw, e.pitch
    -- EntityOtherPlayerMP.onLivingUpdate: EntityPlayer.updateEntityActionState (swing) + interpolation
    if e.swinging then
        e.swing_int = e.swing_int + 1
        if e.swing_int == 8 then e.swing_int, e.swinging = 0, false end
    else
        e.swing_int = 0
    end
    e.swing = fround(e.swing_int / F[8.0])
    if e.incr > 0 then
        local n = e.incr
        local nx = e.x + (e.tx - e.x) / n
        local ny = e.y + (e.ty - e.y) / n
        local nz = e.z + (e.tz - e.z) / n
        local dy = e.tyaw - e.yaw
        while dy < -180 do dy = dy + 360 end
        while dy >= 180 do dy = dy - 360 end
        e.yaw = fround(e.yaw + dy / n)
        e.pitch = fround(e.pitch + (e.tpitch - e.pitch) / n)
        e.incr = n - 1
        P.set_position(e, nx, ny, nz)
    end
    -- EntityLiving.onUpdate: body yaw (renderYawOffset)
    local ddx, ddz = e.x - e.prev_x, e.z - e.prev_z
    local dist = J.sqrt_double(ddx * ddx + ddz * ddz)
    local target = e.body_yaw
    if dist > F[0.05] then
        target = fround(fround(fround(math.atan2(ddz, ddx)) * F[180.0]) / J.PI_F) - F[90.0]
        target = fround(target)
    end
    if e.swing > 0 then target = e.yaw end
    local d9 = fround(target - e.body_yaw)
    while d9 < -180 do d9 = fround(d9 + 360) end
    while d9 >= 180 do d9 = fround(d9 - 360) end
    e.body_yaw = fround(e.body_yaw + fround(d9 * F[0.3]))
    local d10 = fround(e.yaw - e.body_yaw)
    while d10 < -180 do d10 = fround(d10 + 360) end
    while d10 >= 180 do d10 = fround(d10 - 360) end
    if d10 < -75 then d10 = -75 end
    if d10 >= 75 then d10 = 75 end
    e.body_yaw = fround(e.yaw - d10)
    if d10 * d10 > 2500 then e.body_yaw = fround(e.body_yaw + fround(d10 * F[0.2])) end
    while e.yaw - e.prev_yaw < -180 do e.prev_yaw = e.prev_yaw - 360 end
    while e.yaw - e.prev_yaw >= 180 do e.prev_yaw = e.prev_yaw + 360 end
    while e.body_yaw - e.prev_body_yaw < -180 do e.prev_body_yaw = e.prev_body_yaw - 360 end
    while e.body_yaw - e.prev_body_yaw >= 180 do e.prev_body_yaw = e.prev_body_yaw + 360 end
    -- EntityOtherPlayerMP.onUpdate: limbs
    e.prev_limb_yaw = e.limb_yaw
    local l = fround(dist * F[4.0])
    if l > 1 then l = 1 end
    e.limb_yaw = fround(e.limb_yaw + fround(fround(l - e.limb_yaw) * F[0.4]))
    e.limb_swing = fround(e.limb_swing + e.limb_yaw)
end

local function cart_tick(e)
    e.ticks = e.ticks + 1
    if e.incr > 0 then
        local n = e.incr
        local nx = e.x + (e.tx - e.x) / n
        local ny = e.y + (e.ty - e.y) / n
        local nz = e.z + (e.tz - e.z) / n
        local dy = e.tyaw - e.yaw
        while dy < -180 do dy = dy + 360 end
        while dy >= 180 do dy = dy - 360 end
        e.yaw = fround(e.yaw + dy / n)
        e.pitch = fround(e.pitch + (e.tpitch - e.pitch) / n)
        e.incr = n - 1
        P.set_position(e, nx, ny, nz)
    end
end

local function boat_tick(e)
    e.ticks = e.ticks + 1
    e.prev_x, e.prev_y, e.prev_z = e.x, e.y, e.z
    local bb = e.bb
    local frac = 0
    for k = 0, 4 do
        local y0 = bb[2] + (bb[5] - bb[2]) * k / 5.0 - 0.125
        local y1 = bb[2] + (bb[5] - bb[2]) * (k + 1) / 5.0 - 0.125
        local wet = false
        for x = jfloor(bb[1]), jfloor(bb[4] + 1.0) - 1 do
            for y = jfloor(y0), jfloor(y1 + 1.0) - 1 do
                for z = jfloor(bb[3]), jfloor(bb[6] + 1.0) - 1 do
                    if P.WATER[(P.block_at(x, y, z))] then wet = true end
                end
            end
        end
        if wet then frac = frac + 1.0 / 5 end
    end
    e.my = e.my + F004 * (frac * 2.0 - 1.0)
    e.mx = math.max(-0.4, math.min(0.4, e.mx))
    e.mz = math.max(-0.4, math.min(0.4, e.mz))
    if e.on_ground then e.mx, e.my, e.mz = e.mx * 0.5, e.my * 0.5, e.mz * 0.5 end
    P.move(e, e.mx, e.my, e.mz)
    e.mx, e.my, e.mz = e.mx * 0.99, e.my * 0.95, e.mz * 0.99
end

-- World.updateEntities for the non-player entities (the local player is updated first by alphamine:player)
function M.tick(chunk_ok)
    local keep = {}
    for _, e in ipairs(M.order) do
        if not e.dead and chunk_ok(e.x, e.z) then
            e.last_x, e.last_y, e.last_z = e.x, e.y, e.z
            e.prev_yaw, e.prev_pitch = e.yaw, e.pitch
            if e.kind == "item" then item_tick(e)
            elseif e.kind == "player" then player_tick(e)
            elseif e.kind == "cart" then cart_tick(e)
            elseif e.kind == "boat" then boat_tick(e) end
        end
        if e.dead then
            M.list[e.id] = nil
            M.despawn_engine(e)
        else
            keep[#keep + 1] = e
        end
    end
    M.order = keep
end

-- boats and carts are solid for other entities (World.getCollidingBoundingBoxes)
P.entity_boxes = function(self, bb, out, n)
    for _, e in ipairs(M.order) do
        if e ~= self and not e.dead and (e.kind == "boat" or e.kind == "cart") then
            local b = e.bb
            n = P.push_box(out, n, bb, b[1], b[2], b[3], b[4], b[5], b[6])
        end
    end
    return n
end

-- F2F `mode`: EntityItem age / hoverStart = 0, ticksExisted = 0, entity rand = entitySeed(seed, id)
function M.mode(seed)
    M.seed = seed or 0
    for _, e in ipairs(M.order) do
        e.rand:set_seed(J.entity_seed(M.seed, e.id))
        e.ticks = 0   -- Java F2FAgent.mode: ticksExisted = 0 (arm sway of other players)
        if e.kind == "item" then e.age, e.hover = 0, 0 end
    end
end

-- ------------------------------------------------------------------ engine side
local bones_cache = {}
local function bone_indices(ent, names)
    local skel = ent.skeleton
    local r = {}
    for _, n in ipairs(names) do r[n] = skel:index(n) end
    return r
end

local PLAYER_BONES = {"head", "headwear", "body", "rarm", "larm", "rleg", "lleg", "item"}
local ITEM_BONES = {"m0", "m1", "m2", "m3"}
local CART_BONES = {"p0", "p1", "p2", "p3", "p4", "p5", "content"}
local BOAT_BONES = {"p0", "p1", "p2", "p3", "p4"}
local BONES = {player = PLAYER_BONES, item = ITEM_BONES, cart = CART_BONES, boat = BOAT_BONES}

function M.spawn_engine(e)
    local ok, ent = pcall(entities.spawn, ENGINE_DEF[e.kind], {e.x, e.y, e.z})
    if not ok or not ent then
        M.stats.engine_errors = M.stats.engine_errors + 1
        if M.stats.engine_errors < 5 then log("spawn " .. e.kind .. " failed: " .. tostring(ent)) end
        return nil
    end
    M.stats.engine_spawns = M.stats.engine_spawns + 1
    e.uid = ent:get_uid()
    e.ent = ent
    e.bones = bone_indices(ent, BONES[e.kind])
    pcall(function() ent.rigidbody:set_enabled(false) end)
    e.models_set = nil
    return ent
end

function M.despawn_engine(e)
    -- hide first: the engine removes despawned entities in its own world update (every other 50 ms frame in F2F),
    -- the skeleton would be drawn once more
    if e.uid and entities.exists(e.uid) then
        pcall(function() e.ent.skeleton:set_visible(false) end)
        pcall(function() e.ent:despawn() end)
    end
    e.uid, e.ent = nil, nil
    if e.tag_uid and entities.exists(e.tag_uid) then pcall(function() e.tag_ent:despawn() end) end
    e.tag_ent, e.tag_uid = nil, nil
end

-- ModelBiped.setRotationAngles -> {head = {rx, ry, rz}, ...}
local PI = J.PI_F
local function biped_angles(e, swing_l, limb, ticks, head_yaw, pitch, swing, held)
    local A = {}
    local r2d = fround(F[180.0] / PI)
    local hy, hx = fround(head_yaw / r2d), fround(pitch / r2d)
    A.head = {hx, hy, 0}
    A.headwear = {hx, hy, 0}
    local ra_x = fround(fround(fround(J.cos(fround(fround(swing_l * F[0.6662]) + PI)) * F[2.0]) * limb) * F[0.5])
    local la_x = fround(fround(fround(J.cos(fround(swing_l * F[0.6662])) * F[2.0]) * limb) * F[0.5])
    local rl_x = fround(fround(J.cos(fround(swing_l * F[0.6662])) * F[1.4]) * limb)
    local ll_x = fround(fround(J.cos(fround(fround(swing_l * F[0.6662]) + PI)) * F[1.4]) * limb)
    local ra_y, la_y, ra_z, la_z, body_y = 0, 0, 0, 0, 0
    if held then ra_x = fround(fround(ra_x * F[0.5]) - fround(PI * F[0.1])) end
    local rpx, rpz, lpx, lpz = -5, 0, 5, 0
    if swing > -9990 then
        body_y = fround(J.sin(fround(fround(J.sqrt_float(swing) * PI) * F[2.0])) * F[0.2])
        rpz = fround(J.sin(body_y) * F[5.0])
        rpx = fround(-J.cos(body_y) * F[5.0])
        lpz = fround(-J.sin(body_y) * F[5.0])
        lpx = fround(J.cos(body_y) * F[5.0])
        ra_y = fround(ra_y + body_y)
        la_y = fround(la_y + body_y)
        la_x = fround(la_x + body_y)
        local s = fround(1.0 - swing)
        s = fround(s * s)
        s = fround(s * s)
        s = fround(1.0 - s)
        local v8 = J.sin(fround(s * PI))
        local v9 = fround(fround(J.sin(fround(swing * PI)) * -fround(hx - F[0.7])) * F[0.75])
        ra_x = fround(ra_x - (v8 * 1.2 + v9))
        ra_y = fround(ra_y + fround(body_y * F[2.0]))
        ra_z = fround(J.sin(fround(swing * PI)) * F[-0.4])
    end
    ra_z = fround(ra_z + fround(fround(J.cos(fround(ticks * F[0.09])) * F[0.05]) + F[0.05]))
    la_z = fround(la_z - fround(fround(J.cos(fround(ticks * F[0.09])) * F[0.05]) + F[0.05]))
    ra_x = fround(ra_x + fround(J.sin(fround(ticks * F[0.067])) * F[0.05]))
    la_x = fround(la_x - fround(J.sin(fround(ticks * F[0.067])) * F[0.05]))
    A.body = {0, body_y, 0}
    A.rarm = {ra_x, ra_y, ra_z, rpx, 2, rpz}
    A.larm = {la_x, la_y, la_z, lpx, 2, lpz}
    A.rleg = {rl_x, 0, 0}
    A.lleg = {ll_x, 0, 0}
    return A
end

M.biped_angles = biped_angles   -- U: GuiInventory player preview (modules/inv_preview.lua)

local function part_matrix(root, part, ang)
    local p = part.point
    local px, py, pz = p[1], p[2], p[3]
    if ang and ang[4] then px, py, pz = ang[4], ang[5], ang[6] end
    local m = mat.translate(root, px / 16.0, py / 16.0, pz / 16.0)
    local rx, ry, rz = part.rot[1], part.rot[2], part.rot[3]
    if ang then rx, ry, rz = ang[1], ang[2], ang[3] end
    local r2d = 180.0 / math.pi
    if rz ~= 0 then m = mat.rotate(m, rz * r2d, 0, 0, 1) end
    if ry ~= 0 then m = mat.rotate(m, ry * r2d, 0, 1, 0) end
    if rx ~= 0 then m = mat.rotate(m, rx * r2d, 1, 0, 0) end
    return m
end

local PLAYER_PARTS = {}
for _, p in ipairs(T.parts.am_player) do
    PLAYER_PARTS[p.model:gsub("^am_player_", "")] = p
end

local function lerp(a, b, t) return a + (b - a) * t end

local function set_models(e)
    if e.models_set == e.model_key then return end
    local skel = e.ent.skeleton
    if e.kind == "item" then
        local it = T.items[e.item]
        for k = 0, 3 do
            local idx = e.bones["m" .. k]
            if idx then skel:set_model(idx, it and it.model or "") end
        end
    elseif e.kind == "player" then
        local idx = e.bones.item
        local it = e.held and e.held > 0 and T.items[e.held]
        if idx then skel:set_model(idx, it and it.model or "") end
    elseif e.kind == "cart" then
        local idx = e.bones.content
        local m = e.cart_type == 1 and "am_bi_54" or (e.cart_type == 2 and "am_bi_61" or "")
        if idx then skel:set_model(idx, m) end
    end
    e.models_set = e.model_key
end

-- pose one entity for the frame (partial = Timer.renderPartialTicks, cam = camera pos/yaw/pitch)
-- EntityPickupFX.renderParticle: position and brightness of the flying item
local function pickup_pos(e, partial)
    local fx = e.fx
    local t = fround(fround(fx.age + partial) / fround(fx.max))
    t = fround(t * t)
    local cx, cy, cz
    local c = fx.collector
    if c then
        cx, cy, cz = lerp(c.last_x, c.x, partial), lerp(c.last_y, c.y, partial) + fx.y_offs, lerp(c.last_z, c.z, partial)
    else
        local pl = package.loaded["alphamine:modules/player.lua"]
        local fpv = package.loaded["alphamine:modules/fpview.lua"]
        local px, py, pz = pl.x, pl.y, pl.z
        if fpv and fpv.prev_x then
            px, py, pz = lerp(fpv.prev_x, px, partial), lerp(fpv.prev_y, py, partial), lerp(fpv.prev_z, pz, partial)
        end
        cx, cy, cz = px, py + fx.y_offs, pz
    end
    local x = e.x + (cx - e.x) * t
    local y = e.y + (cy - e.y) * t
    local z = e.z + (cz - e.z) * t
    local bright = P.brightness(jfloor(x), jfloor(y + fround(F[0.2] / 2.0) / 2.0), jfloor(z))
    return x, y, z, bright
end

local function pose(e, partial, cam)
    local x = lerp(e.last_x, e.x, partial)
    local y = lerp(e.last_y, e.y, partial)
    local z = lerp(e.last_z, e.z, partial)
    local ent = e.ent
    local skel = ent.skeleton
    local b = e.bones
    local cy = 0.0 -- transform origin offset (frustum box centre)
    local bright
    if e.fx then
        -- renderEntityWithPosYaw at the effect position; RenderItem bobs by the frozen age + partial
        x, y, z, bright = pickup_pos(e, partial)
    else
        bright = P.entity_brightness(e)
    end
    skel:set_color({bright, bright, bright})
    if e.kind == "player" then
        cy = 0.9
        e.model_key = "p" .. tostring(e.held)
        set_models(e)
        ent.transform:set_pos({x, y + cy, z})
        local body = lerp(e.prev_body_yaw, e.body_yaw, partial)
        local yaw = lerp(e.prev_yaw, e.yaw, partial)
        local pit = lerp(e.prev_pitch, e.pitch, partial)
        local root = mat.translate(mat.idt(), 0, -cy - e.y_offset, 0)
        root = mat.rotate(root, 180 - body, 0, 1, 0)
        root = mat.scale(root, -1, -1, 1)
        root = mat.scale(root, 0.9375, 0.9375, 0.9375)
        root = mat.translate(root, 0, -24 / 16.0 - 0.0078125, 0)
        local limb = lerp(e.prev_limb_yaw, e.limb_yaw, partial)
        if limb > 1 then limb = 1 end
        local swing_l = e.limb_swing - e.limb_yaw * (1 - partial)
        local swing = lerp(e.prev_swing, e.swing, partial)
        local held = e.held and e.held > 0
        local A = biped_angles(e, swing_l, limb, e.ticks + partial, yaw - body, pit, swing, held)
        local arm
        for name, part in pairs(PLAYER_PARTS) do
            local m = part_matrix(root, part, A[name])
            if name == "rarm" then arm = m end
            if b[name] then skel:set_matrix(b[name], m) end
        end
        if b.item and held and arm then
            -- RenderPlayer.renderSpecials
            local m = mat.translate(arm, -1 / 16.0, 7 / 16.0, 1 / 16.0)
            local it = T.items[e.held]
            if it and it.kind == "block" then
                m = mat.translate(m, 0, 3 / 16.0, -5 / 16.0)
                m = mat.rotate(m, 20, 1, 0, 0)
                m = mat.rotate(m, 45, 0, 1, 0)
                m = mat.scale(m, 0.375, -0.375, 0.375)
            else
                m = mat.translate(m, 0.25, 3 / 16.0, -3 / 16.0)
                m = mat.scale(m, 0.375, 0.375, 0.375)
                m = mat.rotate(m, 60, 0, 0, 1)
                m = mat.rotate(m, -90, 1, 0, 0)
                m = mat.rotate(m, 20, 0, 0, 1)
            end
            skel:set_matrix(b.item, m)
        end
        M.name_tag(e, x, y, z, cam)
    elseif e.kind == "item" then
        cy = 0.25
        e.model_key = "i" .. tostring(e.item)
        set_models(e)
        ent.transform:set_pos({x, y + cy, z})
        local it = T.items[e.item]
        local age = fround(e.age + partial)
        local bob = fround(fround(J.sin(fround(fround(age / F[10.0]) + e.hover)) * F[0.1]) + F[0.1])
        local spin = fround(fround(fround(age / F[20.0]) + e.hover) * fround(F[180.0] / PI))
        local copies = 1
        if e.count > 1 then copies = 2 end
        if e.count > 5 then copies = 3 end
        if e.count > 20 then copies = 4 end
        local rnd = J.Random(187)
        local root = mat.translate(mat.idt(), 0, -cy + bob, 0)
        for k = 0, 3 do
            local idx = b["m" .. k]
            if idx then
                if k >= copies or not it then
                    skel:set_matrix(idx, mat.scale(mat.idt(), 0, 0, 0))
                elseif it.kind == "block" then
                    local s = it.scale or 0.25
                    local m = mat.rotate(root, spin, 0, 1, 0)
                    m = mat.scale(m, s, s, s)
                    if k > 0 then
                        m = mat.translate(m, fround(fround(fround(rnd:next_float() * 2.0) - 1.0) * F[0.2]) / s,
                            fround(fround(fround(rnd:next_float() * 2.0) - 1.0) * F[0.2]) / s,
                            fround(fround(fround(rnd:next_float() * 2.0) - 1.0) * F[0.2]) / s)
                    end
                    skel:set_matrix(idx, m)
                else
                    local m = mat.scale(root, 0.5, 0.5, 0.5)
                    if k > 0 then
                        m = mat.translate(m, fround(fround(fround(rnd:next_float() * 2.0) - 1.0) * F[0.3]),
                            fround(fround(fround(rnd:next_float() * 2.0) - 1.0) * F[0.3]),
                            fround(fround(fround(rnd:next_float() * 2.0) - 1.0) * F[0.3]))
                    end
                    m = mat.rotate(m, 180 - cam.view_y, 0, 1, 0)
                    skel:set_matrix(idx, m)
                end
            end
        end
    elseif e.kind == "cart" or e.kind == "boat" then
        cy = 0.5
        e.model_key = e.kind .. tostring(e.cart_type)
        set_models(e)
        ent.transform:set_pos({x, y + cy, z})
        local yaw = lerp(e.prev_yaw, e.yaw, partial)
        local pit = lerp(e.prev_pitch, e.pitch, partial)
        local root = mat.translate(mat.idt(), 0, -cy, 0)
        root = mat.rotate(root, 180 - yaw, 0, 1, 0)
        if e.kind == "cart" then
            root = mat.rotate(root, -pit, 0, 0, 1)
            if b.content and e.cart_type and e.cart_type > 0 then
                local m = mat.scale(root, 0.75, 0.75, 0.75)
                m = mat.translate(m, 0, 5 / 16.0, 0)
                m = mat.rotate(m, 90, 0, 1, 0)
                skel:set_matrix(b.content, m)
            end
        end
        root = mat.scale(root, -1, -1, 1)
        local parts = e.kind == "cart" and T.parts.am_cart or T.parts.am_boat
        for i, part in ipairs(parts) do
            local idx = b["p" .. (i - 1)]
            if idx then
                local ang = nil
                if e.kind == "cart" and i == 6 then
                    -- ModelMinecart.render: sideModels[5].rotationPointY = 4 - (-0.1)
                    ang = {part.rot[1], part.rot[2], part.rot[3], part.point[1], 4.1, part.point[3]}
                end
                skel:set_matrix(idx, part_matrix(root, part, ang))
            end
        end
    end
end

-- RenderPlayer name tag with the Alpha font: entity alphamine:am_tag, one bone per glyph (models am_font.c<code>
-- generated from default.png with FontRenderer's widths), white, unlit (tint 1, shading off), depth-tested pass
-- only (the first pass through walls at alpha 0x20 and the 25% black box are not drawn).
local WIDTHS = T.font_widths
local function tag_pose(e, x, y, z, cam)
    if not M.name_tags then return end
    local name = e.name or ""
    if not e.tag_ent or not entities.exists(e.tag_uid) then
        local ok, ent = pcall(entities.spawn, "alphamine:am_tag", {x, y + 2.3, z})
        if not ok or not ent then return end
        e.tag_ent, e.tag_uid = ent, ent:get_uid()
        pcall(function() ent.rigidbody:set_enabled(false) end)
        e.tag_text = nil
    end
    local ent = e.tag_ent
    local skel = ent.skeleton
    if e.tag_text ~= name then
        for k = 0, 15 do
            local idx = skel:index("g" .. k)
            local c = name:byte(k + 1)
            if idx then skel:set_model(idx, c and c >= 32 and ("am_font.c" .. c) or "") end
        end
        e.tag_text = name
    end
    skel:set_color({1, 1, 1})
    ent.transform:set_pos({x, y + 2.3, z})
    -- getDistanceToEntity (float), var14 = (1/60 * 1.6F) * sqrt(d) / 2
    local dx, dy, dz = fround(x - cam.x), fround(y - cam.y), fround(z - cam.z)
    local d = J.sqrt_float(fround(fround(fround(dx * dx) + fround(dy * dy)) + fround(dz * dz)))
    local s = fround(fround(fround(1.0 / 60.0) * F[1.6]) * (math.sqrt(d) / 2.0))
    local root = mat.rotate(mat.idt(), -cam.view_y, 0, 1, 0)
    root = mat.rotate(root, cam.view_x, 1, 0, 0)
    root = mat.scale(root, -s, -s, s)
    local w = 0
    for k = 1, #name do w = w + (WIDTHS[name:byte(k)] or 0) end
    local x0 = -math.floor(w / 2)   -- Java: -getStringWidth / 2 (int division toward zero)
    local pos = x0
    for k = 0, 15 do
        local idx = skel:index("g" .. k)
        local c = name:byte(k + 1)
        if idx then
            if c then
                skel:set_matrix(idx, mat.translate(root, pos, 0, 0))
                pos = pos + (WIDTHS[c] or 0)
            else
                skel:set_matrix(idx, mat.scale(mat.idt(), 0, 0, 0))
            end
        end
    end
end
function M.name_tag(e, x, y, z, cam)
    local ok, err = pcall(tag_pose, e, x, y, z, cam)
    if not ok and M.stats.engine_errors < 5 then
        M.stats.engine_errors = M.stats.engine_errors + 1
        log("name tag: " .. tostring(err))
    end
end

-- per rendered frame (before the world is drawn): spawn/pose engine entities
local function frame_one(e, partial, cam)
    if not e.uid or not entities.exists(e.uid) then M.spawn_engine(e) end
    if e.ent then
        local ok, err = pcall(pose, e, partial, cam)
        if not ok then
            M.stats.engine_errors = M.stats.engine_errors + 1
            if M.stats.engine_errors < 5 then log("pose " .. e.kind .. ": " .. tostring(err)) end
        end
    end
end

function M.frame(partial, cam)
    for _, e in ipairs(M.order) do
        -- dead_listed: collected this tick, still in loadedEntityList -> drawn where it lies (RenderGlobal)
        if not e.dead or e.dead_listed then frame_one(e, partial, cam) end
    end
    -- EntityPickupFX (EffectRenderer, F2F layer `particles`)
    local show = layer_on("particles")
    for _, fx in ipairs(M.effects) do
        if show then frame_one(fx, partial, cam) elseif fx.uid then M.despawn_engine(fx) end
    end
end

-- F2F state: [{id, type, x, y, z}] (World entity list order; the local player is added by the caller)
function M.report()
    local out = {}
    for _, e in ipairs(M.order) do
        if not e.dead or e.dead_listed then
            local r = {id = e.id, type = KIND_CLASS[e.kind], x = e.x, y = e.y, z = e.z}
            if e.kind == "item" then r.item, r.count, r.age = e.item, e.count, e.age end
            if e.kind == "player" then r.name, r.yaw, r.pitch, r.held = e.name, e.yaw, e.pitch, e.held end
            out[#out + 1] = r
        end
    end
    return out
end

function M.reset()
    for _, e in ipairs(M.order) do M.despawn_engine(e) end
    for _, e in ipairs(M.effects) do M.despawn_engine(e) end
    M.list, M.order, M.effects = {}, {}, {}
end

return M
