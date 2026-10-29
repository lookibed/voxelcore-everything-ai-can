-- Wave 5p: sbmeter.view_json_index(all, tick)(e) must give byte-identical text to encode_view(view_index(all)(e))
-- (binary TickInput view_json), plus the cost of both on 505 entities (headless 0.32: lab run olife <this file>).
app.reconfig_packs({"base", "olife_proto", "olife_world"}, {})
app.new_world("w5p_view", "1", "core:default")
local MT = require "olife_world:sbmeter"
local ents = {}
math.randomseed(5)
local function add(eid, x, y, z, kind)
    ents[eid] = {eid = eid, kind = kind, pos = {x = x, y = y, z = z}}
end
local eid = 0
for i = 1, 505 do                                   -- grid of slots like spawn_scripted + jitter, 3 layers, clusters
    eid = eid + 1
    local s = (i % 7 == 0) and 0.37 or 4
    add(eid, ((i % 19) - 9) * s + math.random() * 1.3, 80 + (i % 3) * 4 + math.random(), (math.floor(i / 19) - 13) * s
        + math.random() * 1.3, (i % 11 == 0) and 2 or 3)
end
add(9001, 1e6 + 0.123456789012345, 80, -1e-7, 3)    -- far away, long number text
local bad, nonempty, n = 0, 0, 0
for tick = 1, 3 do
    for _, e in pairs(ents) do e.pos.x = e.pos.x + 0.01 end
    local va, vb = MT.view_index(ents), MT.view_json_index(ents, tick)
    for _, e in pairs(ents) do
        local v = va(e)
        local a = #v > 0 and MT.encode_view(v) or nil
        local b = vb(e)
        n = n + 1
        if a ~= b then
            bad = bad + 1
            if bad <= 3 then print("[view_json_test] MISMATCH eid=" .. e.eid .. "\n  " .. tostring(a) .. "\n  " .. tostring(b)) end
        elseif a then nonempty = nonempty + 1 end
    end
end
print(string.format("[view_json_test] compared %d views (%d non-empty): %d mismatches", n, nonempty, bad))
local function bench(f, k)
    collectgarbage("collect")
    local kb0 = collectgarbage("count")
    collectgarbage("stop")
    local t0 = time.precise_time()
    for t = 1, k do f(t) end
    local dt = (time.precise_time() - t0) * 1000 / k
    local kb = (collectgarbage("count") - kb0) / k
    collectgarbage("restart")
    return dt, kb
end
local old_ms, old_kb = bench(function()
    local va = MT.view_index(ents)
    for _, e in pairs(ents) do local v = va(e); if #v > 0 then MT.encode_view(v) end end
end, 200)
local new_ms, new_kb = bench(function(t)
    local vb = MT.view_json_index(ents, 1000 + t)
    for _, e in pairs(ents) do vb(e) end
end, 200)
print(string.format("[view_json_test] 506 entities: view_index+encode_view %.3f ms %.0f KB/tick; view_json_index %.3f ms %.0f KB/tick",
    old_ms, old_kb, new_ms, new_kb))
if bad > 0 then error("view_json_index differs from encode_view(view_index)") end
app.close_world(false)
