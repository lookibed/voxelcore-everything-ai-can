-- Wave 5p: cost of the world's chunk re-hash pass (server.lua rehash: world.get_chunk_data + FNV-1a in Lua) split
-- into the engine call and the hash, and crc32 (engine builtin) of the same bytes for comparison.
app.reconfig_packs({"base", "olife_proto", "olife_world"}, {})
app.new_world("w5p_rehash", "2026", "base:demo")
local W = require "olife_proto:wire"
local pid = player.create("probe")
player.set_pos(pid, 8, 100, 8)
pcall(player.set_loading_chunks, pid, true)
app.sleep_until(function() return block.get(8, 10, 8) ~= -1 end, 2000, 30)
local clock = time.precise_time
local ds, n = {}, 0
local t0 = clock()
for cx = -2, 2 do for cz = -2, 2 do
    local d = world.get_chunk_data(cx, cz)
    if d then n = n + 1; ds[n] = d end
end end
local t_get = (clock() - t0) * 1000 / math.max(n, 1)
local bytes = 0
for i = 1, n do bytes = bytes + #ds[i] end
local function each(f, reps)
    for i = 1, n do f(ds[i]) end                     -- warm-up
    local t = clock()
    for _ = 1, reps do for i = 1, n do f(ds[i]) end end
    return (clock() - t) * 1000 / (reps * n)
end
local t_fnv = each(function(d) return W.fnv1a(d) end, 20)
local t_crc = each(function(d) return crc32(d) end, 20)
print(string.format("[w5p_rehash] %d chunks, %.0f bytes avg: get_chunk_data %.3f ms, fnv1a (Lua) %.3f ms, crc32 (engine) %.3f ms per chunk",
    n, bytes / math.max(n, 1), t_get, t_fnv, t_crc))
app.close_world(false)
