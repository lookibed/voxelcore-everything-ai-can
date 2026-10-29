-- Замер (headless 0.32 --test), волна 4b: TickInput/TickResult песочницы на 500 сущностей — JSON-строки против
-- бинарного контракта olife_proto:sandbox (байты, кодирование, разбор) в Lua мира.
-- Запуск: lab run olife D:\...\tools\olife\tests\bench_sandbox_bin.lua
app.reconfig_packs({"base", "olife_proto", "olife_world"}, {})
if not app.is_content_loaded() then app.load_content() end
local MT = require "olife_world:sbmeter"
local SB = require "olife_proto:sandbox"
local now = function() return time.precise_utc_time() * 1000 end
local N, REP = 500, 20
local spawn = {x = 8.5, y = 70, z = 8.5}
local slots = MT.slots(spawn)
local ents = {}
for i = 1, N do
    local p = slots[i]
    ents[i] = {eid = i, kind = 3, owner = math.floor((i - 1) / 10) + 1,
               pos = {x = p.x + math.sin(i) * 1.37, y = p.y, z = p.z + math.cos(i) * 2.11},
               rot = {x = 0, y = (i * 37) % 360 + 0.123456789, z = 0}, vel = {x = 0, y = 0, z = 0}}
end
local view_of = MT.view_index(ents)
local views, nview = {}, 0
for i = 1, N do views[i] = view_of(ents[i]); nview = nview + #views[i] end

local function timeit(fn)
    local best, sum, out = 1e9, 0, nil
    for k = 1, REP + 3 do
        local t0 = now()
        out = fn()
        local dt = now() - t0
        if k > 3 then sum = sum + dt; if dt < best then best = dt end end
    end
    return sum / REP, best, out
end
local function line(name, avg, best, bytes)
    print(string.format("[bench_sandbox_bin] %-46s avg %7.2f ms  best %7.2f ms  %8d B", name, avg, best, bytes or 0))
end

-- TickInput, JSON line (bridge today: MT.encode_tick)
local jl = {}
for i = 1, N do
    local e = ents[i]
    jl[i] = {eid = e.eid, owner = e.owner, pos = {e.pos.x, e.pos.y, e.pos.z}, rot = {e.rot.x, e.rot.y, e.rot.z},
             vel = {e.vel.x, e.vel.y, e.vel.z}, view = #views[i] > 0 and views[i] or nil}
end
local a, b, s = timeit(function() return MT.encode_tick(1, 1, 0.05, jl) end)
line("TickInput JSON (MT.encode_tick)", a, b, #s)

-- TickInput, binary, views as json.tostring (bridge wave 2..4b-before)
local function bin_list(view_str)
    local l = {}
    for i = 1, N do
        local e = ents[i]
        l[i] = {eid = e.eid, owner = e.owner, pos = {x = e.pos.x, y = e.pos.y, z = e.pos.z},
                rot = {x = e.rot.x, y = e.rot.y, z = e.rot.z}, vel = {x = e.vel.x, y = e.vel.y, z = e.vel.z},
                events_json = {}, view_json = #views[i] > 0 and view_str(views[i]) or nil}
    end
    return l
end
local a1, b1, ba = timeit(function()
    return SB.body("TickInput", {tick = 1, seed = 1, dt = 0.05, entities = bin_list(json.tostring)})
end)
line("TickInput BIN (views json.tostring)", a1, b1, #ba)
local a2, b2, ba2 = timeit(function()
    return SB.body("TickInput", {tick = 1, seed = 1, dt = 0.05, entities = bin_list(MT.encode_view)})
end)
line("TickInput BIN (views MT.encode_view)", a2, b2, #ba2)
local pre = bin_list(MT.encode_view)
local a3, b3, ba3 = timeit(function() return SB.body("TickInput", {tick = 1, seed = 1, dt = 0.05, entities = pre}) end)
line("  of it: codec only (lists prebuilt)", a3, b3, #ba3)
local noview = {}
for i = 1, N do local x = {}; for k, v in pairs(pre[i]) do x[k] = v end; x.view_json = nil; noview[i] = x end
local a4, b4, ba4 = timeit(function() return SB.body("TickInput", {tick = 1, seed = 1, dt = 0.05, entities = noview}) end)
line("  codec, no views (9 f64 + ids per entity)", a4, b4, #ba4)
local a5, b5 = timeit(function() return SB.decode_body(SB.ids.TickInput, ba3, 1, #ba3) end)
line("TickInput BIN decode (service side, Lua)", a5, b5, #ba3)

-- TickResult: 500 x (set_pos + set_rot) + meter; JSON (sandboxd today) vs binary
local res_j, res_b = {}, {}
for i = 1, N do
    local m = {fuel = 120000, api_calls = 2, api_credits = 2, credits = 14, alloc_bytes = 2000, actions_dropped = 0}
    res_j[i] = {eid = i, owner = 1, status = "ok", actions = {{op = "set_pos", pos = {1.2345678901, 70, 3.14159265}},
                {op = "set_rot", rot = {0, 123.456789, 0}}}, meter = m}
    res_b[i] = {eid = i, owner = 1, status = "ok", actions = {{kind = "SetPos", pos = {x = 1.2345678901, y = 70, z = 3.14159265}},
                {kind = "SetRot", rot = {x = 0, y = 123.456789, z = 0}}}, queries_json = {}, meter = m}
end
local jtext = json.tostring({type = "tick_result", tick = 1, entities = res_j, owners = {}, wall_us = 4000})
local a6, b6 = timeit(function() return json.parse(jtext) end)
line("TickResult JSON json.parse", a6, b6, #jtext)
local a7, b7, rb = timeit(function() return SB.body("TickResult", {tick = 1, entities = res_b, wall_us = 4000}) end)
line("TickResult BIN encode (service side, Lua)", a7, b7, #rb)
local a8, b8 = timeit(function() return SB.decode_body(SB.ids.TickResult, rb, 1, #rb) end)
line("TickResult BIN decode", a8, b8, #rb)
print(string.format("[bench_sandbox_bin] entities %d, view items %d, repeats %d", N, nview, REP))
