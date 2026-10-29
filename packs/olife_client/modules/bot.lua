-- olife_client:bot — load driver for the headless bot: random walk around spawn (4 blocks/s, flying at spawn
-- height + 1), optional block actions (break the top block / place stone on it) and a chat line on join.
-- Deterministic per bot name (seeded), so runs are repeatable up to network timing.
local client = require "olife_client:client"

local M = {}
local rng_state = 1
local function rnd()
    -- LCG (deterministic, independent of math.random)
    rng_state = (rng_state * 1103515245 + 12345) % 2147483648
    return rng_state / 2147483648
end

local cfg = {speed = 4.0, radius = 10, block_every = 0, chat = true,
             drop_every = 0, halt = false, sprint = false}     -- wave 4c: drops (inventory test), halt (stop walking)
local target, ticks, said = nil, 0, false
local stone

function M.configure(name, t)
    for k, v in pairs(t or {}) do cfg[k] = v end
    local h = 7
    for i = 1, #name do h = (h * 31 + name:byte(i)) % 2147483647 end
    rng_state = h
end

function M.set(t)
    for k, v in pairs(t or {}) do cfg[k] = v end
end

local function top_block(x, z)
    for y = 200, 1, -1 do
        local id = block.get(x, y, z)
        if id == -1 then return nil end
        if id > 0 then return y, id end
    end
    return nil
end

-- wave 4c: predicted movement — the bot produces keys and look (olife_proto:movement does the rest, on both sides)
local function drive_predicted(S)
    local pr = client.predict
    if cfg.halt then S.keys = 0; return end
    local dx, dz = target.x - S.pos.x, target.z - S.pos.z
    if dx * dx + dz * dz > 0.25 then
        local K = (require "olife_proto:movement").K
        S.yaw = math.deg(math.atan2(-dx, -dz)) % 360
        S.keys = K.FWD + (cfg.sprint and K.SPRINT or 0) + (pr.P.blocked and K.JUMP or 0)
    else
        S.keys = 0
    end
end

-- wave 4c: block actions through the inventory — place what the selected/first placeable slot holds (select it
-- first if needed); break gives the block's item (server-side)
local function place_or_break(S, x, y, z, want_place)
    local inv = client.inv
    if want_place and inv.I.rev > 0 then
        local slot, _, blk = inv.find_placeable()
        if slot then
            if slot ~= inv.I.selected then inv.select(client.send, slot) end
            client.block_action(1, x, y + 1, z, blk, 0)
            return
        end
    end
    if want_place and inv.I.rev == 0 then
        if not stone then
            local ok, id = pcall(block.index, "base:stone")
            stone = ok and id or 1
        end
        client.block_action(1, x, y + 1, z, stone, 0)
        return
    end
    client.block_action(0, x, y, z, 0, 0)
end

function M.on_tick(S)
    ticks = ticks + 1
    if not S.spawn then return end
    if cfg.chat and not said and ticks > 20 then
        said = true
        client.chat("hello from " .. S.name)
    end
    if not target or ticks % 60 == 0 then
        local a = rnd() * math.pi * 2
        local r = rnd() * cfg.radius
        target = {x = S.spawn.x + math.cos(a) * r, z = S.spawn.z + math.sin(a) * r}
    end
    if client.predict.active() then
        drive_predicted(S)
    else
        local dx, dz = target.x - S.pos.x, target.z - S.pos.z
        local d = math.sqrt(dx * dx + dz * dz)
        local step = cfg.speed / 20
        if d > step and not cfg.halt then
            S.pos.x = S.pos.x + dx / d * step
            S.pos.z = S.pos.z + dz / d * step
            S.rot.y = math.deg(math.atan2(dx, dz)) % 360
        end
        S.pos.y = S.spawn.y + 1
    end
    if cfg.block_every > 0 and ticks % cfg.block_every == 0 then
        local x = math.floor(S.pos.x + (rnd() - 0.5) * 6)
        local z = math.floor(S.pos.z + (rnd() - 0.5) * 6)
        local y = top_block(x, z)
        if y then place_or_break(S, x, y, z, rnd() >= 0.5) end
    end
    if cfg.drop_every > 0 and ticks % cfg.drop_every == 0 and client.inv.I.rev > 0 then
        local slot = client.inv.find_nonempty(math.floor(rnd() * 40))
        if slot then client.inv.drop(client.send, slot, 1) end
    end
end

return M
