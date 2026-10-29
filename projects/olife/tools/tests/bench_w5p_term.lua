-- Wave 5p: entity hash term — fnv_ints(...) with varargs/select vs an unrolled variant (same value), JIT on.
app.reconfig_packs({"base", "olife_proto", "olife_world"}, {})
app.new_world("w5p_term", "1", "core:default")
local U = require "olife_proto:util"
local W = require "olife_proto:wire"
local bxor, f32_bits = bit.bxor, W.f32_bits
local function step(h, byte)
    h = bxor(h, byte) % 4294967296
    local lo = h % 65536
    local hi = (h - lo) / 65536
    return (lo * 16777619 + ((hi * 16777619) % 65536) * 65536) % 4294967296
end
local function u32(h, v)
    v = v % 4294967296
    h = step(h, (v - v % 16777216) / 16777216)
    h = step(h, ((v - v % 65536) / 65536) % 256)
    h = step(h, ((v - v % 256) / 256) % 256)
    return step(h, v % 256)
end
local function term2(eid, p, r)
    local h = u32(2166136261, eid)
    h = u32(h, f32_bits(p.x)); h = u32(h, f32_bits(p.y)); h = u32(h, f32_bits(p.z))
    h = u32(h, f32_bits(r.x)); h = u32(h, f32_bits(r.y))
    return u32(h, f32_bits(r.z))
end
local ents = {}
math.randomseed(9)
for i = 1, 505 do ents[i] = {eid = i, pos = {x = math.random() * 80 - 40, y = 80 + math.random() * 9, z = math.random() * 80 - 40},
    rot = {x = 0, y = math.random() * 360, z = 0}} end
local bad = 0
for _, e in ipairs(ents) do if U.entity_term(e.eid, e.pos, e.rot) ~= term2(e.eid, e.pos, e.rot) then bad = bad + 1 end end
local function run(f, ticks)
    local t0 = time.precise_time()
    local s = 0
    for t = 1, ticks do
        for _, e in ipairs(ents) do e.pos.x = e.pos.x + 0.013; e.rot.y = (e.rot.y + 1.7) % 360; s = s + f(e.eid, e.pos, e.rot) end
    end
    return (time.precise_time() - t0) * 1000 / ticks, s
end
run(U.entity_term, 50); run(term2, 50)
local a = run(U.entity_term, 300)
local b = run(term2, 300)
print(string.format("[w5p_term] 505 entities per tick: fnv_ints varargs %.3f ms, unrolled %.3f ms; mismatches %d", a, b, bad))
app.close_world(false)
