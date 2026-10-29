-- Client-side relighting after a block change (phase 4, agent P): the Alpha client recomputes sky and block
-- light itself when a block changes (World.setBlockAndMetadata -> Chunk.relightBlock + World.updateLight ->
-- MetadataChunkBlock.updateLight); the server's BlockChange carries no light. Without this a dug hole stays black
-- (the shaders read the light of the neighbour cell from the chunk store, modules/lightmap.lua).
-- Same rule as MetadataChunkBlock.updateLight, run as a work list until nothing changes:
--   opacity = Block.lightOpacity (0 -> 1); source = 15 if the cell sees the sky (y >= height map of the column:
--   the first cell from the top with lightOpacity != 0, + 1) for sky light, Block.lightValue for block light;
--   level = (opacity >= 15 and source == 0) ? 0 : max(source, max(6 neighbours) - opacity).
-- Neighbours above y 127 have sky 15, below 0 have 0 (EnumSkyBlock default values); missing chunks read 0.
-- Changed chunks are marked for modules/lightmap.lua (uploaded with the next chunks.flush).
local chunks = require "alphamine:chunks"
local lightmap = require "alphamine:lightmap"
local T = require "alphamine:interact_table"

local band, rshift, bor, lshift = bit.band, bit.rshift, bit.bor, bit.lshift
local floor = math.floor
local META, BLIGHT, SLIGHT = 32768, 49152, 65536

local M = {enabled = true, stats = {changes = 0, cells = 0, updates = 0, max_queue = 0, ms = 0}}

local OPACITY, EMIT = {}, {}
for i = 0, 255 do OPACITY[i], EMIT[i] = 0, 0 end
for id, b in pairs(T.blocks) do
    OPACITY[id] = b.light_opacity or 0
    EMIT[id] = b.light_value or 0
end

local function store_of(x, z)
    local cx, cz = floor(x / 16), floor(z / 16)
    return chunks.store[cx .. "," .. cz], cx, cz
end

local function idx(x, y, z)
    return band(x, 15) * 2048 + band(z, 15) * 128 + y
end

local function get_light(base, x, y, z)
    if y > 127 then return base == SLIGHT and 15 or 0 end
    if y < 0 then return 0 end
    local s = store_of(x, z)
    if not s then return 0 end
    local i = idx(x, y, z)
    local b = s.bytes[base + rshift(i, 1)]
    return band(i, 1) == 0 and band(b, 15) or rshift(b, 4)
end

local touched = {}
local function set_light(base, x, y, z, v)
    local s, cx, cz = store_of(x, z)
    if not s then return end
    local i = idx(x, y, z)
    local p = s.bytes
    local o = base + rshift(i, 1)
    if band(i, 1) == 0 then p[o] = bor(band(p[o], 0xF0), v) else p[o] = bor(band(p[o], 0x0F), lshift(v, 4)) end
    touched[cx .. "," .. cz] = {cx, cz}
end

local function block_id(x, y, z)
    if y < 0 or y > 127 then return 0 end
    local s = store_of(x, z)
    if not s then return 0 end
    return s.bytes[idx(x, y, z)]
end

-- height map of a column (Chunk.heightMap: first cell from the top that blocks light, + 1)
local function height(x, z)
    local s = store_of(x, z)
    if not s then return 0 end
    local p = s.bytes
    local b = band(x, 15) * 2048 + band(z, 15) * 128
    for y = 127, 0, -1 do
        if OPACITY[p[b + y]] ~= 0 then return y + 1 end
    end
    return 0
end

local DIRS = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

local function compute(base, x, y, z, hcache)
    local id = block_id(x, y, z)
    local op = OPACITY[id]
    if op == 0 then op = 1 end
    local src
    if base == SLIGHT then
        local k = x .. "," .. z
        local h = hcache[k]
        if not h then h = height(x, z); hcache[k] = h end
        src = y >= h and 15 or 0
    else
        src = EMIT[id]
    end
    if op >= 15 and src == 0 then return 0 end
    local m = 0
    for d = 1, 6 do
        local v = get_light(base, x + DIRS[d][1], y + DIRS[d][2], z + DIRS[d][3])
        if v > m then m = v end
    end
    m = m - op
    if m < 0 then m = 0 end
    if src > m then m = src end
    return m
end

local function run(base, seeds, hcache)
    local q, head = {}, 1
    local inq = {}
    for _, c in ipairs(seeds) do
        local k = c[1] .. "," .. c[2] .. "," .. c[3]
        if not inq[k] then inq[k] = true; q[#q + 1] = c end
    end
    local n = 0
    while head <= #q and n < 200000 do
        local c = q[head]
        q[head] = nil
        head = head + 1
        local x, y, z = c[1], c[2], c[3]
        inq[x .. "," .. y .. "," .. z] = nil
        n = n + 1
        if y >= 0 and y <= 127 and store_of(x, z) then
            local v = compute(base, x, y, z, hcache)
            if v ~= get_light(base, x, y, z) then
                set_light(base, x, y, z, v)
                M.stats.updates = M.stats.updates + 1
                for d = 1, 6 do
                    local nx, ny, nz = x + DIRS[d][1], y + DIRS[d][2], z + DIRS[d][3]
                    local k = nx .. "," .. ny .. "," .. nz
                    if not inq[k] then inq[k] = true; q[#q + 1] = {nx, ny, nz} end
                end
            end
        end
        if #q - head > M.stats.max_queue then M.stats.max_queue = #q - head end
    end
    M.stats.cells = M.stats.cells + n
end

-- a block at x, y, z changed from old_id to new_id (the store already holds the new block)
function M.block_changed(x, y, z, old_id, new_id)
    if not M.enabled or y < 0 or y > 127 then return end
    local s, cx, cz = store_of(x, z)
    if not s then return end
    local t0 = os.clock()
    M.stats.changes = M.stats.changes + 1
    touched = {}
    touched[cx .. "," .. cz] = {cx, cz}   -- fluid/solid codes of the lightmap change with the block too
    local hcache = {}
    -- sky: the changed cell, its neighbours and the column span between the old and the new height
    local h_new = height(x, z)
    local h_old = h_new
    if OPACITY[old_id or 0] ~= OPACITY[new_id or 0] then
        if OPACITY[new_id or 0] ~= 0 then
            -- a light-blocking block was added: before, the height was at most y
            h_old = math.min(h_new, y)
        else
            h_old = math.max(h_new, y + 1)
        end
    end
    local seeds = {{x, y, z}}
    for d = 1, 6 do seeds[#seeds + 1] = {x + DIRS[d][1], y + DIRS[d][2], z + DIRS[d][3]} end
    for yy = math.max(0, math.min(h_old, h_new) - 1), math.min(127, math.max(h_old, h_new)) do
        seeds[#seeds + 1] = {x, yy, z}
    end
    run(SLIGHT, seeds, hcache)
    run(BLIGHT, {{x, y, z}, {x + 1, y, z}, {x - 1, y, z}, {x, y + 1, z}, {x, y - 1, z}, {x, y, z + 1}, {x, y, z - 1}},
        hcache)
    for _, c in pairs(touched) do lightmap.mark(c[1], c[2]) end
    M.stats.ms = M.stats.ms + (os.clock() - t0) * 1e3
end

return M
