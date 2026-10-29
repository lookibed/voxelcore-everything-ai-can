-- olife_proto:util — hand-written helpers shared by olife_world and olife_client (NOT generated):
-- state hashes (the same definition on the world and on the replica), JSONL writer, ring buffer, clock.
local W = require "olife_proto:wire"
local bxor = bit.bxor
local f32_bits, fround = W.f32_bits, W.fround

local M = {}

function M.now_ms()
    return time.precise_utc_time() * 1000
end

-- FNV-1a over 32-bit integers (4 bytes each, big-endian) — exact in doubles
-- (wave 5p: `% 2^32` instead of `if h < 0 then h = h + 2^32 end` — the same value, but no data-dependent branch:
-- the branch, taken for ~half of the bytes, grew side traces without end under JIT — OLIFE_WORLD_PERF.md)
local function fnv_step(h, byte)
    h = bxor(h, byte) % 4294967296
    local lo = h % 65536
    local hi = (h - lo) / 65536
    return (lo * 16777619 + ((hi * 16777619) % 65536) * 65536) % 4294967296
end
function M.fnv_ints(...)
    local h = 2166136261
    for i = 1, select("#", ...) do
        local v = select(i, ...) % 4294967296
        h = fnv_step(h, (v - v % 16777216) / 16777216)
        h = fnv_step(h, ((v - v % 65536) / 65536) % 256)
        h = fnv_step(h, ((v - v % 256) / 256) % 256)
        h = fnv_step(h, v % 256)
    end
    return h
end
local fnv_ints = M.fnv_ints

-- hash term of a replicated entity: positions/rotations as the f32 the wire carries
function M.entity_term(eid, p, r)
    return fnv_ints(eid, f32_bits(p.x), f32_bits(p.y), f32_bits(p.z), f32_bits(r.x), f32_bits(r.y), f32_bits(r.z))
end
-- hash term of an applied block change
function M.block_term(x, y, z, id, states)
    return fnv_ints(x, y, z, id, states)
end
-- order-independent combination
function M.add32(a, b)
    return (a + b) % 4294967296
end
M.fround = fround

function M.vec_round(p)
    return {x = fround(p.x), y = fround(p.y), z = fround(p.z)}
end

-- JSONL file writer with periodic flush (io_stream, text mode)
local Jsonl = {}
Jsonl.__index = Jsonl
function M.jsonl(path)
    local ok, s = pcall(file.open, path, "w")
    if not ok then
        print("[olife] cannot open " .. path .. ": " .. tostring(s))
        s = nil
    end
    return setmetatable({stream = s, n = 0, pending = 0}, Jsonl)
end
function Jsonl:write(t)
    if not self.stream then return end
    self.stream:write_line(json.tostring(t))
    self.n = self.n + 1
    self.pending = self.pending + 1
end
function Jsonl:flush(force)
    if self.stream and (force or self.pending >= 10) then
        self.stream:flush()
        self.pending = 0
    end
end
function Jsonl:close()
    if self.stream then
        self.stream:flush()
        self.stream:close()
        self.stream = nil
    end
end

-- fixed ring of the last N items
local Ring = {}
Ring.__index = Ring
function M.ring(n)
    return setmetatable({n = n, i = 0, items = {}, total = 0}, Ring)
end
function Ring:push(x)
    self.i = self.i % self.n + 1
    self.items[self.i] = x
    self.total = self.total + 1
end
function Ring:last(k)
    local out = {}
    local cnt = math.min(k or self.n, self.n, self.total)
    local j = self.i
    for _ = 1, cnt do
        out[#out + 1] = self.items[j]
        j = j - 1
        if j < 1 then j = self.n end
    end
    return out
end

-- chunk key
function M.ckey(cx, cz)
    return cx * 65536 + cz
end

return M
