-- Wave 4c: olife_proto:movement in the 0.32 engine (headless --test, lab vctest): walking speed, gravity/landing,
-- jump height, wall stop + step-up, flight, determinism (two runs and a replay from a copied state = same bits),
-- step cost. Exit code = verdict.
local fails, checks = {}, 0
local function check(c, what) checks = checks + 1; if not c then fails[#fails + 1] = what; print("[move] FAIL " .. what) end end
local function p(...) print("[move]", ...) end
app.reconfig_packs({"base", "olife_proto"}, {})
app.new_world("move4c", "2026", "base:demo")
local Mv = require "olife_proto:movement"
local U = require "olife_proto:util"
local K = Mv.K
local IT = require "olife_proto:items"
-- UX round 1: the test coin is gone from olife_proto (the user: «нахуя монетки»)
local okc, coin = pcall(item.index, "olife_proto:coin")
p("items", item.defs_count(), "coin", okc, coin, "table_hash", IT.table_hash(item.defs_count()))
check(not okc or coin == nil, "olife_proto:coin item is not defined any more")
local pid = player.create("p1")
player.set_pos(pid, 8, 90, 8)
player.set_loading_chunks(pid, true)
for _ = 1, 80 do app.tick() end
local function surface(x, z)
    for y = 200, 1, -1 do
        local id = block.get(x, y, z)
        if id > 0 and block.properties[id].obstacle ~= false then return y + 1 end
    end
end
local sy = surface(8, 8)
p("surface", sy)
-- 1. fall from +5 -> lands on the surface
local s = Mv.new_state(8.5, sy + 5, 8.5)
local n = 0
repeat Mv.step(s, 0, 0, 0); n = n + 1 until s.ground or n > 100
p("fall ticks", n, "y", s.y, "vy", s.vy)
check(s.ground and math.abs(s.y - sy) < 1e-4, "lands on surface y=" .. s.y)
-- 2. walk forward (yaw 0 -> front = -z) for 40 ticks on a flat test floor built here
for x = -4, 40 do for z = -40, 4 do block.set(x, sy - 1, z, block.index("base:stone"), 0); for y = sy, sy + 4 do block.set(x, y, z, 0, 0) end end end
s = Mv.new_state(0.5, sy, 0.5)
Mv.step(s, 0, 0, 0)
local z0 = s.z
for _ = 1, 40 do Mv.step(s, K.FWD, 0, 0) end
local v = (z0 - s.z) / (40 * Mv.DT)
p("walk speed b/s", v, "z", s.z)
check(v > 2.3 and v < 2.8, "walk speed ~2.7 (" .. v .. ")")
-- sprint
local s2 = Mv.new_state(10.5, sy, 0.5)
Mv.step(s2, 0, 0, 0)
local z1 = s2.z
for _ = 1, 40 do Mv.step(s2, K.FWD + K.SPRINT, 0, 0) end
p("sprint speed", (z1 - s2.z) / 2)
-- 3. jump height
s = Mv.new_state(20.5, sy, 0.5); Mv.step(s, 0, 0, 0)
local top = s.y
Mv.step(s, K.JUMP, 0, 0)
for _ = 1, 30 do Mv.step(s, 0, 0, 0); if s.y > top then top = s.y end end
p("jump apex", top - sy)
check(top - sy > 1.2 and top - sy < 1.6, "jump apex ~1.4 (" .. (top - sy) .. ")")
check(s.ground and math.abs(s.y - sy) < 1e-4, "lands after jump")
-- 4. wall: 2-high wall at z = -5 stops, 1-step (0.5 slab? use 1 block -> needs jump) ; half step via step-up test with a 0.5 block
local stone = block.index("base:stone")
for x = 0, 3 do block.set(x, sy, -6, stone, 0); block.set(x, sy + 1, -6, stone, 0) end
s = Mv.new_state(1.5, sy, -2.5); Mv.step(s, 0, 0, 0)
for _ = 1, 60 do Mv.step(s, K.FWD, 0, 0) end
p("wall stop z", s.z, "vz", s.vz)
check(math.abs(s.z - (-5 + Mv.HW)) < 1e-3, "stops at the wall face z=" .. s.z)
-- jump over a 1-block step
for x = 5, 8 do block.set(x, sy, -6, stone, 0) end
s = Mv.new_state(6.5, sy, -2.5); Mv.step(s, 0, 0, 0)
local blocked = false
for _ = 1, 80 do
    local _, inf = Mv.step(s, K.FWD + ((blocked and s.ground) and K.JUMP or 0), 0, 0)
    blocked = inf.collided_h
end
p("over step z", s.z, "y", s.y)
check(s.z < -7, "gets over a 1-block step by jumping")
-- 5. flight up
s = Mv.new_state(20.5, sy + 2, 0.5, true)
for _ = 1, 20 do Mv.step(s, K.JUMP, 0, 0) end
p("flight up 1 s", s.y - (sy + 2))
check(s.y - (sy + 2) > 3, "flight up")
-- 6. determinism: random keys, two runs and a replay from a copy
local function run(seed, nsteps, st)
    local r = seed
    st = st or Mv.new_state(2.5, sy, -1.5)
    local copies = {}
    for i = 1, nsteps do
        r = (r * 1103515245 + 12345) % 2147483648
        local keys = r % 128
        local yaw = (r % 3600) / 10
        Mv.step(st, keys, yaw, 0)
        copies[i] = Mv.copy(st)
    end
    return st, copies
end
local a, ca = run(7, 400)
local b = run(7, 400)
local ha, hb = Mv.hash(a, U.fnv_ints), Mv.hash(b, U.fnv_ints)
p("det hash", ha, hb, "pos", a.x, a.y, a.z)
check(ha == hb, "two runs same hash")
-- replay from step 200 (adopt state at 200 through the wire form: f32 values are already exact)
local mid = Mv.copy(ca[200])
local net = Mv.from_net({x = mid.x, y = mid.y, z = mid.z}, {x = mid.vx, y = mid.vy, z = mid.vz}, Mv.flags(mid))
local r = 7
for i = 1, 200 do r = (r * 1103515245 + 12345) % 2147483648 end
for i = 201, 400 do
    r = (r * 1103515245 + 12345) % 2147483648
    Mv.step(net, r % 128, (r % 3600) / 10, 0)
end
check(Mv.hash(net, U.fnv_ints) == ha, "replay from wire state = same hash")
-- 7. cost
local t0 = time.precise_utc_time()
local st = Mv.new_state(2.5, sy, -1.5)
for i = 1, 2000 do Mv.step(st, K.FWD + (i % 40 == 0 and K.JUMP or 0), (i * 7) % 360, 0) end
p(string.format("step cost %.4f ms", (time.precise_utc_time() - t0) * 1000 / 2000))
app.close_world(false)
print(string.format("[move] checks=%d fails=%d", checks, #fails))
if #fails > 0 then error("movement: " .. #fails .. " failures: " .. fails[1]) end
