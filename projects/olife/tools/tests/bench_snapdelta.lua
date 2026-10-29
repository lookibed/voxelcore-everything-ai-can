-- Wave 4c: cost of olife_world:snapdelta.replicate_session (headless 0.32, lab vctest): 6 sessions x 10 moving
-- entities, with the real codec (EntityDelta encoded into a Bytearray) and without encoding.
app.reconfig_packs({"base", "olife_proto", "olife_world"}, {})
app.new_world("bench4c", "1", "core:default")
local GW = {out = Bytearray(), closed = false}
local D = require "olife_world:snapdelta"
local S = {tick = 0, ents = {}, sessions = {}, stats = {snap_bytes = 0}}
local cfg = {snap = "delta"}
D.init({S = S, cfg = cfg})
for i = 1, 11 do
    S.ents[i] = {eid = i, kind = 2, def = "olife:mob", name = "m" .. i, owner = 0, pos = {x = i, y = 80, z = 0},
                 rot = {x = 0, y = 0, z = 0}, ck = 0}
end
local sess = {}
for k = 1, 6 do
    sess[k] = {eid = k, sid = k, gw = GW, pos = {x = 8, y = 80, z = 8}, chunks = {[0] = true}, ent_hash = 0, nview = 0,
               bytes = 0}
    D.check_mode(sess[k])
end
local function run(n)
    local t0 = time.precise_utc_time()
    for t = 1, n do
        S.tick = S.tick + 1
        for i, e in pairs(S.ents) do
            local a = S.tick * 0.03 + i
            e.pos.x, e.pos.z = 8 + math.cos(a) * 5, 8 + math.sin(a) * 5
            e.rot.y = (a * 57.3) % 360
        end
        for k = 1, 6 do D.replicate_session(sess[k]) end
        GW.out:clear()
    end
    return (time.precise_utc_time() - t0) * 1000 / n
end
run(200)
GW.closed = false
local a = run(1000)
GW.closed = true
local b = run(1000)
print(string.format("[bench4c] replicate 6 sessions x 11 entities: %.3f ms/tick with encoding, %.3f ms/tick without",
    a, b))
-- the live world has a big Lua heap: every allocation pays incremental GC work over it
local keep = {}
for i = 1, 300000 do keep[i] = {i, tostring(i)} end
GW.closed = false
local c = run(1000)
print(string.format("[bench4c] same with a %.0f MB Lua heap: %.3f ms/tick (gc count %.0f KB)", collectgarbage("count") / 1024,
    c, collectgarbage("count")))
keep = nil
app.close_world(false)
