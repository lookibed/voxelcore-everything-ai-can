-- Particles of the Alpha client (phase 3) through gfx.particles.emit (F2F layer `particles`).
-- EffectRenderer.addBlockHitEffects -> EntityDiggingFX: one particle per tick while the left button digs a block
-- (Minecraft.sendClickBlockToController). The Java particle is simulated in Lua from its creation tick up to the
-- current tick (EntityFX.onUpdate: gravity 0.04 * blockParticleGravity, drag 0.98, ground friction 0.7) and handed
-- to the engine at its rendered position (prevPos at partial 0) with its current velocity and remaining lifetime;
-- the engine then moves it (acceleration -16 = 0.04 per tick^2, no drag) and draws it as a billboard with a quarter
-- of the block texture chosen by the pack from particleTextureJitterX/Y (sub_texture; the engine's random_sub_uv was
-- seeded by a heap address and made runs differ, lab stage 3b).
-- Colour 0.6 x brightness: textures/particles/am_p<tile>.png are the terrain tiles x 0.6 and the engine multiplies
-- by its light (lighting = true). Size 0.2 * particleScale, particleScale = (r * 0.5 + 0.5) * 2 / 2 * 0.6.
-- Random numbers are the pack's (java.util.Random seeded at F2F mode), not Java's streams: positions differ from
-- the golden frames by construction -- the layer test compares coverage and mean colour, not pixels.
-- Also: smoke / flame / bubble / splash presets (EntitySmokeFX, EntityFlameFX, EntityBubbleFX, EntitySplashFX) for
-- world effects (M.spawn(kind, x, y, z, vx, vy, vz)); the random display updates that emit them are not wired yet.
local game = require "alphamine:game"
local pl = require "alphamine:player"
local T = require "alphamine:ui_tables"
local JRandom = require "alphamine:jrandom"
local J = require "alphamine:jmath"
local fround, F = J.fround, J.F

local M = {last_tick = nil, rand = JRandom.new(0), mrand = JRandom.new(1), stats = {hit = 0, emitted = 0},
           dig = nil}

local floor, sqrt, max = math.floor, math.sqrt, math.max

local function log(m) debug.log("[alphamine_fx] " .. m) end

-- F2F mode: fixed seeds
function M.mode_reset(seed)
    M.rand:set_seed(seed or 0)
    M.mrand:set_seed((seed or 0) + 7919)
    M.last_tick = game.tick
end

local function solid(x, y, z)
    local id = block.get(floor(x), floor(y), floor(z))
    return id ~= nil and id > 0
end

-- EntityFX constructor (motion from Math.random, texture jitter / scale / max age from Entity.rand)
-- Math.random() of EntityFX is F2FRandom.random = the one stream texfx.lua also draws from (TextureFX): taking
-- the numbers from texfx.random keeps the water/lava animation in step with Java while particles are created
local function mrandom()
    local ok, tf = pcall(require, "alphamine:texfx")
    if ok and tf and tf.random then return tf.random() end
    return M.mrand:next_float()
end
local function new_fx(x, y, z, vx, vy, vz, fx)
    local p = {x = x, y = y, z = z, px = x, py = y, pz = z, birth = game.tick}
    p.mx = vx + fround(fround(mrandom() * 2.0 - 1.0) * F[0.4])
    p.my = vy + fround(fround(mrandom() * 2.0 - 1.0) * F[0.4])
    p.mz = vz + fround(fround(mrandom() * 2.0 - 1.0) * F[0.4])
    local spd = fround(fround(mrandom() + mrandom() + 1.0) * F[0.15])
    local len = sqrt(p.mx * p.mx + p.my * p.my + p.mz * p.mz)
    if len < 1e-9 then len = 1 end
    p.mx = p.mx / len * spd * 0.4
    p.my = p.my / len * spd * 0.4 + 0.1
    p.mz = p.mz / len * spd * 0.4
    local er = M.rand
    p.jx = er:next_float() * 3.0                -- particleTextureJitterX/Y = rand.nextFloat() * 3: the pack picks
    p.jy = er:next_float() * 3.0                -- the quarter-tile window (sub_texture), not the engine
    p.scale = (er:next_float() * 0.5 + 0.5) * 2.0
    p.max_age = floor(4.0 / (er:next_float() * 0.9 + 0.1))
    p.age = 0
    p.gravity = fx.gravity or 1.0
    p.tex = fx.tex
    p.half = 0.1   -- setSize(0.2, 0.2)
    return p
end

-- EntityFX.onUpdate with a simple collision against full blocks (moveEntity of a 0.2 box)
local function update_fx(p)
    p.px, p.py, p.pz = p.x, p.y, p.z
    if p.age >= p.max_age then
        p.age = p.age + 1
        p.dead = true
        return
    end
    p.age = p.age + 1
    p.my = p.my - 0.04 * p.gravity
    local ny = p.y + p.my
    p.on_ground = false
    if p.my < 0 and solid(p.x, ny - p.half, p.z) then
        ny = floor(ny - p.half) + 1 + p.half
        p.my = 0
        p.on_ground = true
    elseif p.my > 0 and solid(p.x, ny + p.half, p.z) then
        ny = floor(ny + p.half) - p.half
        p.my = 0
    end
    local nx, nz = p.x + p.mx, p.z + p.mz
    if solid(nx, ny, p.z) then nx = p.x; p.mx = 0 end
    if solid(nx, ny, nz) then nz = p.z; p.mz = 0 end
    p.x, p.y, p.z = nx, ny, nz
    p.mx, p.my, p.mz = p.mx * 0.98, p.my * 0.98, p.mz * 0.98
    if p.on_ground then
        p.mx, p.mz = p.mx * 0.7, p.mz * 0.7
    end
end

local pending = {}   -- particles created since the last frame (simulated until handed to the engine)

-- multiplyVelocity(0.2) + multipleParticleScaleBy(0.6)
local function hit_fx(bx, by, bz, side, id)
    local fx = T.block_fx[id]
    if not fx then return end
    local b = fx.bounds
    local e = 0.1
    local r = M.rand
    local x = bx + r:next_float() * (b[4] - b[1] - e * 2) + e + b[1]
    local y = by + r:next_float() * (b[5] - b[2] - e * 2) + e + b[2]
    local z = bz + r:next_float() * (b[6] - b[3] - e * 2) + e + b[3]
    if side == 0 then y = by + b[2] - e end
    if side == 1 then y = by + b[5] + e end
    if side == 2 then z = bz + b[3] - e end
    if side == 3 then z = bz + b[6] + e end
    if side == 4 then x = bx + b[1] - e end
    if side == 5 then x = bx + b[4] + e end
    local p = new_fx(x, y, z, 0, 0, 0, fx)
    p.scale = p.scale / 2.0          -- EntityDiggingFX: particleScale /= 2
    p.mx = p.mx * 0.2
    p.my = (p.my - 0.1) * 0.2 + 0.1
    p.mz = p.mz * 0.2
    p.half = 0.1 * 0.6
    p.scale = p.scale * 0.6
    pending[#pending + 1] = p
    M.stats.hit = M.stats.hit + 1
end
-- EffectRenderer.addBlockDestroyEffects: 4x4x4 EntityDiggingFX (interact.lua P calls it before the block goes)
function M.block_destroy(bx, by, bz)
    local id = game.block_id and game.block_id(bx, by, bz)
    if not id then
        local ok, chunks = pcall(require, "alphamine:chunks")
        id = ok and chunks.get(bx, by, bz) or 0
    end
    local fx = id and id > 0 and T.block_fx[id]
    if not fx then return end
    for i = 0, 3 do
        for j = 0, 3 do
            for k = 0, 3 do
                local x, y, z = bx + (i + 0.5) / 4, by + (j + 0.5) / 4, bz + (k + 0.5) / 4
                local p = new_fx(x, y, z, x - bx - 0.5, y - by - 0.5, z - bz - 0.5, fx)
                p.scale = p.scale / 2.0          -- EntityDiggingFX: particleScale /= 2
                pending[#pending + 1] = p
            end
        end
    end
    M.stats.destroy = (M.stats.destroy or 0) + 1
end

-- Minecraft.sendClickBlockToController -> addBlockHitEffects, called by interact.lua (P) in its tick
function M.block_hit_tick(x, y, z, side)
    M.tick_hooked = true
    M.block_hit(x, y, z, side)
end

M.block_hit = function(x, y, z, side)
    local id = game.block_id and game.block_id(x, y, z)
    if not id then
        local ok, chunks = pcall(require, "alphamine:chunks")
        id = ok and chunks.get(x, y, z) or 0
    end
    if id and id > 0 then hit_fx(x, y, z, side, id) end
end

-- Minecraft.getMouseOver (blocks only): eye (posX, posY, posZ), Entity.getLook, reach 4 (PlayerControllerMP)
local function mouse_over()
    if not pl.has_pos then return nil end
    local yr, pr = math.rad(pl.yaw or 0), math.rad(pl.pitch or 0)
    local f1, f2 = math.cos(-yr - math.pi), math.sin(-yr - math.pi)
    local f3, f4 = -math.cos(-pr), math.sin(-pr)
    local dir = {f2 * f3, f4, f1 * f3}
    local ok, hit = pcall(block.raycast, {pl.x, pl.y, pl.z}, dir, 4.0)
    if not ok or not hit then return nil end
    local ip, n = hit.iendpoint, hit.normal
    local side
    if n[2] < -0.5 then side = 0 elseif n[2] > 0.5 then side = 1
    elseif n[3] < -0.5 then side = 2 elseif n[3] > 0.5 then side = 3
    elseif n[1] < -0.5 then side = 4 else side = 5 end
    return ip[1], ip[2], ip[3], side
end

M.mouse_over = mouse_over

local function digging()
    if game.screen ~= "ingame" then return false end
    local ok, inp = pcall(require, "alphamine:input")
    if ok and inp and inp.focused and not inp.focused() then return false end
    local okp, v = pcall(input.is_pressed, "mouse:left")
    return okp and v or false
end

-- Deterministic sub-UV (lab stage 3b): the engine's random_sub_uv draws the window offset from the emitter's
-- PseudoRandom, seeded with the emitter's heap address (Emitter.cpp: random.setSeed(this)) -> another quarter of the
-- texture in every run (VoxelCore vs VoxelCore frames differed while digging). Here the window comes from the
-- particle's own jitter (EntityFX: u = (tile + jitterX / 4) / 16, 4 texels wide): a 4x4 crop of the 16x16 particle
-- texture at texel offset floor(jitter * 4) (0..11), made once per (texture, offset) as a Canvas texture, and the
-- emitter gets random_sub_uv = 1 (no engine random for the UV).
local sub_src, sub_made = {}, {}
local function sub_texture(tex, jx, jy)
    local ox, oy = floor((jx or 0) * 4), floor((jy or 0) * 4)
    if ox > 12 then ox = 12 end
    if oy > 12 then oy = 12 end
    local name = "am_psub_" .. tex:gsub("^.*:", "") .. "_" .. ox .. "_" .. oy
    if sub_made[name] then return name end
    local src = sub_src[tex]
    if src == nil then
        local ok, c = pcall(function()
            return Canvas.decode(file.read_bytes("alphamine:textures/particles/" .. tex:gsub("^.*:", "") .. ".png"),
                                 "png")
        end)
        src = (ok and c) and {w = c.width, h = c.height, data = c:get_data()} or false
        if not src then log("sub_texture: cannot read " .. tex .. ": " .. tostring(c)) end
        sub_src[tex] = src
    end
    if not src then return nil end
    local out, b = {}, src.data
    for j = 0, 3 do
        for i = 0, 3 do
            local sp = ((oy + j) * src.w + ox + i) * 4
            local o = (j * 4 + i) * 4
            out[o + 1], out[o + 2], out[o + 3], out[o + 4] = b[sp + 1], b[sp + 2], b[sp + 3], b[sp + 4]
        end
    end
    local c = Canvas({4, 4})
    c:set_data(out)
    c:create_texture(name)
    c:update()
    sub_made[name] = c
    M.stats.sub_textures = (M.stats.sub_textures or 0) + 1
    return name
end
M.sub_texture = sub_texture

-- engine emitter for one simulated particle
local function hand_over(p)
    local size = 0.2 * p.scale
    local left = (p.max_age - p.age + 1) * 0.05
    if left <= 0 then return end
    local probe = M.probe
    local sub = probe ~= "engine_sub" and sub_texture(p.tex, p.jx, p.jy) or nil
    gfx.particles.emit({p.px, p.py, p.pz}, 1, {
        texture = sub or p.tex,
        lighting = not (probe == "nolight" or probe == "none"),
        collision = true,
        max_distance = 64,
        spawn_interval = 0,
        lifetime = left,
        lifetime_spread = 0,
        velocity = {p.mx * 20, p.my * 20, p.mz * 20},
        acceleration = {0, -16 * p.gravity, 0},
        explosion = {0, 0, 0},
        size = {size, size, size},
        size_spread = 0,
        random_sub_uv = (sub or probe == "nosub" or probe == "none") and 1 or 0.25,
    })
    M.stats.emitted = M.stats.emitted + 1
end

-- per rendered frame, before the world pass (hand.lua's stdcomp.render hook)
function M.frame()
    if M.last_tick == nil or M.mode_base ~= game.tick_base then
        M.mode_base = game.tick_base
        M.mode_reset(game.mode_seed or 0)   -- same stream after every F2F mode (tick_base depends on the network)
    end
    -- without interact.lua (P) the frame decides about digging itself (older builds)
    local dig = not game.interact and digging()
    while M.last_tick < game.tick do
        M.last_tick = M.last_tick + 1
        -- runTick: sendClickBlockToController -> addBlockHitEffects, then EffectRenderer.updateEffects
        if dig then
            local x, y, z, side = mouse_over()
            if x then M.block_hit(x, y, z, side) end
        end
        for _, p in ipairs(pending) do
            if (p.birth or 0) <= M.last_tick then update_fx(p) end
        end
    end
    if #pending > 0 then
        for _, p in ipairs(pending) do
            if not p.dead then hand_over(p) end
        end
        pending = {}
    end
end

-- world effects (EntitySmokeFX, EntityFlameFX, EntityBubbleFX, EntitySplashFX), particles.png atlas indices
local KINDS = {
    smoke = {tex = "particles:am_fx_smoke", life = 0.4, size = 0.1, vel_mul = 0.1, gravity = -0.004},
    flame = {tex = "particles:am_fx_flame", life = 0.4, size = 0.1, vel_mul = 0.01, gravity = 0},
    bubble = {tex = "particles:am_fx_bubble", life = 0.4, size = 0.04, vel_mul = 0.2, gravity = -0.002},
    splash = {tex = "particles:am_fx_splash", life = 0.4, size = 0.1, vel_mul = 1.0, gravity = 0.06},
}
function M.spawn(kind, x, y, z, vx, vy, vz)
    local k = KINDS[kind]
    if not k then return end
    gfx.particles.emit({x, y, z}, 1, {
        texture = k.tex, lighting = true, collision = true, spawn_interval = 0,
        lifetime = k.life, lifetime_spread = 0.5,
        velocity = {(vx or 0) * 20 * k.vel_mul, (vy or 0) * 20 * k.vel_mul, (vz or 0) * 20 * k.vel_mul},
        acceleration = {0, -k.gravity * 400, 0}, explosion = {0.2, 0.2, 0.2},
        size = {k.size, k.size, k.size}, size_spread = 0.3,
    })
end

return M
