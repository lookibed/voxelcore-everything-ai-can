-- Chunks of the Alpha server -> VoxelCore world.
--
-- Store (Lua, per alpha chunk "cx,cz"): Bytearray of 81920 bytes in the layout of Alpha Chunk arrays
-- (the same bytes a full MapChunk inflates to):
--   [0, 32768)      blocks,     index x<<11 | z<<7 | y
--   [32768, 49152)  meta,       nibble (x<<11 | z<<7 | y) >> 1, even index = low nibble
--   [49152, 65536)  blocklight, same nibbles
--   [65536, 81920)  skylight,   same nibbles
-- MapChunk (51) = region x,y,z + sizes, zlib; World.setChunkData/Chunk.setChunkData copy it region-wise
-- (for x: for z: y-run) -> the same loops here. A full chunk (16x128x16 at y 0) is the store as is.
--
-- VoxelCore chunk: 16x256x16, voxel index (y*16+z)*16+x, raw = 65536 u16 id + 65536 u16 state (state high
-- byte = userbits = alpha meta, see modules/blocks.lua), y 0..127 straight, 128..255 air.
-- world.set_chunk_data works only for a chunk the engine has loaded -> dirty set, flushed when present
-- (on_chunk_present) — the same approach as Neutron-Client (voxelcore-0.34_pre roman_donw).
local codec = require "alphamine:chunk_codec"
local blocks = require "alphamine:blocks"
local lightmap = require "alphamine:lightmap"   -- Alpha light for the shaders (phase 3)
local perf = require "alphamine:perf"

local band, rshift, bor, lshift = bit.band, bit.rshift, bit.bor, bit.lshift

local STORE = 81920
local META, BLIGHT, SLIGHT = 32768, 49152, 65536

local M = {
    store = {},    -- ["cx,cz"] = Bytearray(81920)
    present = {},  -- ["cx,cz"] = true while the engine has the chunk
    dirty = {},    -- ["cx,cz"] = {cx, cz}: store changed, engine chunk must be rewritten
    recv = {},     -- ["cx,cz"] = perf.clock() of the first MapChunk since the last engine write (appearance delay)
    lightmap = lightmap,
    stats = {present = 0, removed = 0, map_chunks = 0, map_chunks_full = 0, pre_load = 0, pre_unload = 0,
             applied = 0, block_changes = 0, multi_changes = 0, encode_ms = 0, inflate_ms = 0},
}

local function key(x, z) return x .. "," .. z end
M.key = key

local function zero(b, n)
    local p = b.bytes
    for i = 0, n - 1 do p[i] = 0 end
end

local function new_store()
    local s = Bytearray(STORE)
    zero(s, STORE)
    return s
end

local function mark(cx, cz)
    local k = key(cx, cz)
    if not M.dirty[k] then M.dirty[k] = {cx, cz} end
    lightmap.mark(cx, cz)
end

-- ------------------------------------------------------------------ store -> engine

local raw  -- shared raw buffer; y 128..255 stays zero forever
-- u16 indices of raw that are always zero (y 128..255 of ids and of states): extrle16 counts them at once
local ZEROS = {{32768, 65535}, {98304, 131071}}
local function encode(store)
    if not raw then raw = codec.new_raw() end
    local rp, sp = raw.bytes, store.bytes
    local map = blocks.to_vc
    local unknown = blocks.unknown
    for x = 0, 15 do
        for z = 0, 15 do
            local base = x * 2048 + z * 128
            local col = (z * 16 + x) * 2
            for y = 0, 127 do
                local i = base + y
                local id = sp[i]
                local v = map[id]
                if v == 0 and id ~= 0 then unknown[id] = (unknown[id] or 0) + 1 end
                local vi = col + y * 512
                rp[vi] = band(v, 255)
                rp[vi + 1] = rshift(v, 8)
                local mb = sp[META + rshift(i, 1)]
                -- rp[131072 + vi] (state low byte) stays 0 from new_raw: never written
                rp[131073 + vi] = band(i, 1) == 0 and band(mb, 15) or rshift(mb, 4)
            end
        end
    end
    return codec.encode(raw, perf.opts.zero_rle ~= "off" and ZEROS or nil)
end

local empty_data
local function apply(cx, cz)
    local k = key(cx, cz)
    local s = M.store[k]
    local data
    if s then
        local t0 = perf.clock()
        perf.push("encode")
        data = encode(s)
        perf.pop()
        M.stats.encode_ms = M.stats.encode_ms + (perf.clock() - t0) * 1e3
    else
        if not empty_data then empty_data = codec.encode(codec.new_raw()) end
        data = empty_data
    end
    perf.push("setdata")
    local ok = world.set_chunk_data(cx, cz, data)
    perf.pop()
    if ok then
        M.stats.applied = M.stats.applied + 1
        perf.count("applied")
        local r = M.recv[k]
        if r then
            -- terrain appearance delay: MapChunk receipt -> engine write (the engine lights and meshes it next)
            M.recv[k] = nil
            perf.sample("delay_ms", (perf.clock() - r) * 1e3)
        end
        return true
    end
    return false
end

-- normal launch (budget_ms given), measured by tools/alphamine/perf (agents/ALPHAMINE.md "Производительность"):
-- every world.set_chunk_data costs the engine 8-16 ms in the following world passes (relight + remesh of the chunk
-- and of its neighbours), and every lightmap upload ~12 ms (the whole 14 MB region + mipmaps of the atlas). So the
-- lightmap is uploaded at most once per M.lm_interval s and the engine chunks are written in batches right after
-- the upload that carries their light (a chunk never shows up unlit): neighbours set in the same frame share their
-- remesh (spreading 2 per frame made the engine cost per chunk twice as high). Nearest to the player first, clears
-- of unloaded chunks last, M.max_per_frame / budget_ms cap a batch. F2F (budget_ms nil): everything at once, as
-- before (parity runs need all chunks written before the shot).
M.max_per_frame = 1000
M.lm_interval = 0.5
M.lm_skip = 0         -- 1: no chunk writes in the frame that uploaded the lightmap (spreads the two costs)
M.center = nil        -- {x, z} of the player (block coords), set by alphamine:game before flush

function M.flush(budget_ms)
    if not budget_ms then
        lightmap.flush(M.store)   -- light nibbles of changed stores -> atlas region (independent of the engine chunks)
        for k, c in pairs(M.dirty) do
            if M.present[k] then
                apply(c[1], c[2])
                M.dirty[k] = nil
            end
        end
        return
    end
    local o = perf.opts   -- experiment switches (perf_normal.py --switch)
    local maxn = tonumber(o.max_per_frame) or M.max_per_frame
    budget_ms = tonumber(o.budget_ms) or budget_ms
    local up0 = lightmap.stats.uploads
    lightmap.flush(M.store, tonumber(o.lm_interval) or M.lm_interval)
    -- the budget counts the chunk writes only (the lightmap upload of this frame is not part of it)
    M.batching = true
    local t0 = perf.clock()
    if next(M.bc_queue) then
        perf.push("bc_flush")
        M.flush_block_changes(t0, tonumber(o.bc_age) or M.bc_age, tonumber(o.bc_max) or M.bc_max)
        perf.pop()
    end
    if lightmap.stats.uploads ~= up0 and (tonumber(o.lm_skip) or M.lm_skip) == 1 then return end
    local unsent = lightmap.unsent
    local px, pz = 0, 0
    if M.center then px, pz = M.center[1] / 16 - 0.5, M.center[2] / 16 - 0.5 end
    local n = 0
    while n < maxn do
        local best, bk, bd = nil, nil, math.huge
        for k, c in pairs(M.dirty) do
            if M.present[k] and not unsent[k] then
                local d = (c[1] - px) ^ 2 + (c[2] - pz) ^ 2
                if not M.store[k] then d = d + 1e6 end   -- clears after all data chunks
                if d < bd then best, bk, bd = c, k, d end
            end
        end
        if not best then break end
        apply(best[1], best[2])
        M.dirty[bk] = nil
        n = n + 1
        if (perf.clock() - t0) * 1e3 > budget_ms then break end
    end
end

function M.pending_count()
    local n, np = 0, 0
    for k in pairs(M.dirty) do
        n = n + 1
        if M.present[k] then np = np + 1 end
    end
    return n, np
end

-- ------------------------------------------------------------------ packets

-- PreChunk (50): mode true = client creates an empty chunk, false = unloads it
function M.pre_chunk(cx, cz, load)
    perf.count("pre_chunks")
    perf.push("store")
    local k = key(cx, cz)
    if load then
        M.stats.pre_load = M.stats.pre_load + 1
        if not M.store[k] then
            M.store[k] = new_store()
            if perf.opts.preload_mark == "on" then mark(cx, cz) end   -- the old behaviour (perf comparison)
            -- no mark: an empty store is air, and the engine chunk is air already (void generator, or cleared when
            -- the server unloaded it); the MapChunk that follows marks it. Saves one set_chunk_data per chunk.
        end
    else
        M.stats.pre_unload = M.stats.pre_unload + 1
        M.store[k] = nil
        M.recv[k] = nil
        mark(cx, cz)
    end
    perf.pop()
end

-- Chunk.setChunkData for one chunk: region [x0,x1) x [y0,y1) x [z0,z1) local coords; data offset -> new offset
local function chunk_set_data(s, d, x0, y0, z0, x1, y1, z1, off)
    local sp, dp = s.bytes, d.bytes
    local run = y1 - y0
    for x = x0, x1 - 1 do
        for z = z0, z1 - 1 do
            local i = x * 2048 + z * 128 + y0
            for j = 0, run - 1 do sp[i + j] = dp[off + j] end
            off = off + run
        end
    end
    local half = run / 2
    for _, base in ipairs({META, BLIGHT, SLIGHT}) do
        for x = x0, x1 - 1 do
            for z = z0, z1 - 1 do
                local i = base + rshift(x * 2048 + z * 128 + y0, 1)
                for j = 0, half - 1 do sp[i + j] = dp[off + j] end
                off = off + half
            end
        end
    end
    return off
end

-- MapChunk (51): x, y, z = block coords of the region, sx, sy, sz sizes, zlib = Bytearray of the deflate stream
function M.map_chunk(x, y, z, sx, sy, sz, zlib)
    perf.count("map_chunks")
    perf.push("store")
    local ok, err = pcall(M.map_chunk_body, x, y, z, sx, sy, sz, zlib)
    perf.pop()
    if not ok then error(err, 0) end
end

function M.map_chunk_body(x, y, z, sx, sy, sz, zlib)
    M.stats.map_chunks = M.stats.map_chunks + 1
    local isize = sx * sy * sz * 5 / 2
    local t0 = perf.clock()
    perf.push("inflate")
    local d = codec.inflate_zlib(zlib, isize)
    perf.pop()
    M.stats.inflate_ms = M.stats.inflate_ms + (perf.clock() - t0) * 1e3
    if sx == 16 and sy == 128 and sz == 16 and y == 0 and band(x, 15) == 0 and band(z, 15) == 0 and #d == STORE then
        M.stats.map_chunks_full = M.stats.map_chunks_full + 1
        local cx, cz = rshift(x, 4), rshift(z, 4)
        -- arithmetic shift for negatives
        cx, cz = math.floor(x / 16), math.floor(z / 16)
        M.store[key(cx, cz)] = d
        mark(cx, cz)
        M.recv[key(cx, cz)] = M.recv[key(cx, cz)] or perf.clock()
        return
    end
    -- World.setChunkData: split the region by chunks
    local cx0, cz0 = math.floor(x / 16), math.floor(z / 16)
    local cx1, cz1 = math.floor((x + sx - 1) / 16), math.floor((z + sz - 1) / 16)
    local y0, y1 = y, y + sy
    if y0 < 0 then y0 = 0 end
    if y1 > 128 then y1 = 128 end
    local off = 0
    for cx = cx0, cx1 do
        local lx0, lx1 = x - cx * 16, x + sx - cx * 16
        if lx0 < 0 then lx0 = 0 end
        if lx1 > 16 then lx1 = 16 end
        for cz = cz0, cz1 do
            local lz0, lz1 = z - cz * 16, z + sz - cz * 16
            if lz0 < 0 then lz0 = 0 end
            if lz1 > 16 then lz1 = 16 end
            local k = key(cx, cz)
            local s = M.store[k]
            if not s then
                s = new_store()
                M.store[k] = s
            end
            off = chunk_set_data(s, d, lx0, y0, lz0, lx1, y1, lz1, off)
            mark(cx, cz)
            if not M.recv[k] then M.recv[k] = perf.clock() end
        end
    end
end

local function store_set(x, y, z, id, meta)
    if y < 0 or y > 127 then return false end
    local cx, cz = math.floor(x / 16), math.floor(z / 16)
    local s = M.store[key(cx, cz)]
    if not s then return false end
    local lx, lz = x - cx * 16, z - cz * 16
    local i = lx * 2048 + lz * 128 + y
    local p = s.bytes
    p[i] = id
    local mi = META + rshift(i, 1)
    if band(i, 1) == 0 then
        p[mi] = bor(band(p[mi], 0xF0), band(meta, 15))
    else
        p[mi] = bor(band(p[mi], 0x0F), lshift(band(meta, 15), 4))
    end
    return true, cx, cz
end

-- BlockChange (53) / one entry of MultiBlockChange (52)
function M.block_change(x, y, z, id, meta)
    M.stats.block_changes = M.stats.block_changes + 1
    perf.count("block_changes")
    local ok, cx, cz = store_set(x, y, z, id, meta)
    if not ok then return end
    local k = key(cx, cz)
    if M.present[k] and not M.dirty[k] then
        if M.defer_far(cx, cz) then
            -- normal launch: far block changes (population of new chunks: ~16 per MapChunk) wait for the next batch
            local q = M.bc_queue[k]
            if not q then q = {t = perf.clock()}; M.bc_queue[k] = q end
            q[#q + 1] = {x, y, z}   -- the value is read from the store when applied (always the newest)
            M.stats.bc_deferred = (M.stats.bc_deferred or 0) + 1
            perf.count("bc_deferred")
            return
        end
        block.set(x, y, z, blocks.to_vc[id] or 0, meta * 256)
    else
        mark(cx, cz)
    end
end

-- Deferred block changes (normal launch, M.bc_defer > 0): every block.set makes the engine relight and remesh the
-- chunk (and its neighbours at the border) in the next frame; the server's population of new chunks sends ~16 block
-- changes per MapChunk spread over many ticks, so the same far chunks were remeshed frame after frame (perf_stream,
-- F2F engine profiler: 18 synchronous meshings per written chunk). Changes in chunks at Chebyshev distance >=
-- M.bc_defer from the player's chunk are queued per chunk and applied M.bc_age s after the first one, at most
-- M.bc_max chunks per frame; near chunks (the player's own digging and building) stay immediate.
M.bc_defer = 2     -- Chebyshev chunk distance from which block changes are deferred (0 = off = every change at once,
                   -- `--switch bc_defer=0` for a run); default 2 since the clean lab measurement, agents/ALPHAMINE.md 9.2
M.bc_age = 1.0     -- s: a chunk's queued changes are applied once the first is this old
M.bc_max = 4       -- chunks with queued changes applied per frame at most
M.bc_queue = {}    -- ["cx,cz"] = {t = clock of the first change, {x, y, z}...}
function M.defer_far(cx, cz)
    local d = tonumber(perf.opts.bc_defer) or M.bc_defer
    if not M.batching or d <= 0 or not M.center then return false end
    local pcx, pcz = math.floor(M.center[1] / 16), math.floor(M.center[2] / 16)
    return math.max(math.abs(cx - pcx), math.abs(cz - pcz)) >= d
end

local function flush_block_changes(now, age, maxn)
    -- chunks whose first queued change is at least `age` s old, oldest first, at most `maxn` chunks per frame (each
    -- costs the engine one relight + remesh; spreading them keeps the frame spikes down without remeshing more)
    local ready = {}
    for k, q in pairs(M.bc_queue) do
        if now - q.t >= age then ready[#ready + 1] = k end
    end
    if #ready == 0 then return end
    table.sort(ready, function(a, b) return M.bc_queue[a].t < M.bc_queue[b].t end)
    for i = 1, math.min(#ready, maxn) do
        local k = ready[i]
        local q = M.bc_queue[k]
        M.bc_queue[k] = nil
        if M.present[k] and not M.dirty[k] then
            for j = 1, #q do
                local c = q[j]
                local id, meta = M.get(c[1], c[2], c[3])
                block.set(c[1], c[2], c[3], blocks.to_vc[id] or 0, meta * 256)
            end
            perf.count("bc_applied", #q)
        end
        -- dirty or gone: the store already holds the changes (the rewrite / the next load carries them)
    end
end
M.flush_block_changes = flush_block_changes

-- alpha id, meta from the store (0,0 when there is no chunk / outside 0..127) — for physics and hashes
function M.get(x, y, z)
    if y < 0 or y > 127 then return 0, 0, false end
    local cx, cz = math.floor(x / 16), math.floor(z / 16)
    local s = M.store[key(cx, cz)]
    if not s then return 0, 0, false end
    local i = (x - cx * 16) * 2048 + (z - cz * 16) * 128 + y
    local p = s.bytes
    local mb = p[META + rshift(i, 1)]
    return p[i], band(i, 1) == 0 and band(mb, 15) or rshift(mb, 4), true
end

function M.has_chunk(cx, cz)
    return M.store[key(cx, cz)] ~= nil
end

function M.count()
    local n = 0
    for _ in pairs(M.store) do n = n + 1 end
    return n
end

-- ------------------------------------------------------------------ engine events

function M.on_chunk_present(x, z, loaded)
    local k = key(x, z)
    M.present[k] = true
    M.stats.present = M.stats.present + 1
    -- the void generator gave air; a chunk loaded from disk may hold old data -> always rewrite if we
    -- know it (or clear it when the server never sent it)
    if M.store[k] or loaded then mark(x, z) end
end

function M.on_chunk_remove(x, z)
    M.present[key(x, z)] = nil
    M.stats.removed = M.stats.removed + 1
end

function M.reset()
    M.store, M.dirty, M.recv, M.bc_queue = {}, {}, {}, {}
    lightmap.reset()
    for k in pairs(M.stats) do M.stats[k] = 0 end
end

M.codec = codec
return M
