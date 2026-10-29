-- Wave 5p (OLIFE_WORLD_PERF.md §3): cost of suspected trace-killers in the engine's own LuaJIT (headless 0.32),
-- JIT on vs off, and the snapdelta stand of wave 4c with trace-cache flushes as in the live world
-- (stock maxtrace=1000: 17-18 flushes per 25 s under olife_sandbox_load, 2 per 15 s under olife_load).
app.reconfig_packs({"base", "olife_proto", "olife_world"}, {})
app.new_world("w5p_bench", "1", "core:default")
local U = require "olife_proto:util"
local W = require "olife_proto:wire"
local C = require "olife_proto:client"
local clock = time.precise_time
local function bench(name, f, n)
    f(math.max(1, math.floor(n / 10)))                    -- warm-up (hot counters, traces)
    local t0 = clock()
    f(n)
    return (clock() - t0) * 1e9 / n                         -- ns per iteration
end
local sink = 0
local cases = {
    {"bytearray_append_u8", function(n) local b = Bytearray() for i = 1, n do b:append(i % 256) end sink = sink + #b end, 2e5},
    {"bytearray_index_read", function(n) local b = Bytearray(4096) local s = 0 for i = 1, n do s = s + b[(i % 4096) + 1] end sink = sink + s end, 1e6},
    {"w_u32_writer", function(n) local b = Bytearray() for i = 1, n do W.w_u32(b, i * 7) end sink = sink + #b end, 1e5},
    {"fnv_ints_varargs_7", function(n) local s = 0 for i = 1, n do s = s + U.fnv_ints(i, 2, 3, 4, 5, 6, 7) end sink = sink + s end, 1e5},
    {"entity_term", function(n) local p, r = {x = 1.5, y = 80, z = -3.25}, {x = 0, y = 90, z = 0} local s = 0
        for i = 1, n do p.x = i * 0.01 s = s + U.entity_term(i, p, r) end sink = sink + s end, 1e5},
    {"f32_bits", function(n) local s = 0 for i = 1, n do s = s + W.f32_bits(i * 0.37 - 1000) end sink = sink + s end, 1e6},
    {"closure_per_iter_FNEW", function(n) local s = 0 for i = 1, n do local f = function() return i end s = s + f() end sink = sink + s end, 1e6},
    {"table_sort_closure_100", function(n) for i = 1, n do local t = {} for k = 1, 100 do t[k] = (k * 7919) % 101 end
        table.sort(t, function(a, b) return a < b end) sink = sink + t[1] end end, 2e3},
    {"tostring_number", function(n) local s = 0 for i = 1, n do s = s + #tostring(i * 0.1) end sink = sink + s end, 2e5},
    {"concat_dotdot_5", function(n) local s = 0 for i = 1, n do local x = '{"eid":' .. i .. ',"k":' .. (i % 3) .. '}' s = s + #x end sink = sink + s end, 2e5},
    {"pcall_lua_fn", function(n) local s = 0 local g = function(x) return x + 1 end for i = 1, n do local ok, v = pcall(g, i) s = s + v end sink = sink + s end, 1e6},
    {"select_varargs", function(n) local function f(...) local s = 0 for i = 1, select("#", ...) do s = s + select(i, ...) end return s end
        local s = 0 for i = 1, n do s = s + f(i, 2, 3) end sink = sink + s end, 1e6},
    {"block_get_C_api", function(n) local s = 0 for i = 1, n do s = s + block.get(i % 16, 60, 0) end sink = sink + s end, 2e5},
    {"json_tostring_small", function(n) local s = 0 for i = 1, n do s = s + #json.tostring({type = "rejected", op = "set_pos", reason = "dup"}) end sink = sink + s end, 2e4},
    {"C_body_TickSync", function(n) local s = 0 for i = 1, n do s = s + #C.body("TickSync", {tick = i, server_ms = 1e12 + i, view_hash = i, entities = 5, chunks = 49}) end sink = sink + s end, 2e4},
}
local res = {}
for _, mode in ipairs({"on", "off"}) do
    if mode == "on" then jit.on() else jit.off() end
    jit.flush()
    for _, c in ipairs(cases) do
        res[c[1]] = res[c[1]] or {}
        res[c[1]][mode] = bench(c[1], c[2], c[3])
    end
end
jit.on(); jit.flush()
for _, c in ipairs(cases) do
    local r = res[c[1]]
    print(string.format("[w5p_bench] %-24s jit on %9.1f ns  off %9.1f ns  x%.1f", c[1], r.on, r.off, r.off / r.on))
end
-- snapdelta stand of wave 4c (6 sessions x 11 entities) with and without trace flushes
local GW = {out = Bytearray(), closed = false}
local D = require "olife_world:snapdelta"
local S = {tick = 0, ents = {}, sessions = {}, stats = {snap_bytes = 0}}
D.init({S = S, cfg = {snap = "delta"}})
for i = 1, 11 do
    S.ents[i] = {eid = i, kind = 2, def = "olife:mob", name = "m" .. i, owner = 0, pos = {x = i, y = 80, z = 0},
                 rot = {x = 0, y = 0, z = 0}, ck = 0}
end
local sess = {}
for k = 1, 6 do
    sess[k] = {eid = k, sid = k, gw = GW, pos = {x = 8, y = 80, z = 8}, chunks = {[0] = true}, ent_hash = 0, nview = 0, bytes = 0}
    D.check_mode(sess[k])
end
local function run(n, flush_every)
    local t0 = clock()
    for t = 1, n do
        S.tick = S.tick + 1
        for i, e in pairs(S.ents) do
            local a = S.tick * 0.03 + i
            e.pos.x, e.pos.z = 8 + math.cos(a) * 5, 8 + math.sin(a) * 5
            e.rot.y = (a * 57.3) % 360
        end
        for k = 1, 6 do D.replicate_session(sess[k]) end
        GW.out:clear()
        if flush_every and t % flush_every == 0 then jit.flush() end
    end
    return (clock() - t0) * 1000 / n
end
run(300)
local a = run(1000)
local b = run(1000, 28)        -- one flush per ~1.4 s of a 20 Hz world (olife_sandbox_load, stock maxtrace)
local c = run(1000, 5)
jit.off(); jit.flush()
local d = run(1000)
jit.on(); jit.flush()
print(string.format("[w5p_bench] snapdelta 6x11 ms/tick: steady %.3f | flush every 28 ticks %.3f | every 5 %.3f | jit off %.3f",
    a, b, c, d))
print("[w5p_bench] sink " .. tostring(sink % 1000))
app.close_world(false)
