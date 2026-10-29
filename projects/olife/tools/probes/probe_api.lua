-- Проба API 0.32 для olife (headless --test): Bytearray, views, byteutil, player/chunks, entities.
local function p(...) print("[probe]", ...) end
local b = Bytearray({1, 2, 3})
p("ba index1", b[1], "index0", pcall(function() return b[0] end), "len", #b)
local s = Bytearray(8)
p("Bytearray(8) len", #s)
local ok, dv = pcall(DBLview, s)
p("DBLview", ok, tostring(dv))
if ok then dv[1] = 1.5; p("dbl bytes", s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8]) end
local ok2, fv = pcall(FLTview, s)
if ok2 then fv[1] = 1.5; p("flt bytes", s[1], s[2], s[3], s[4]) end
local pk = byteutil.pack(">fd", 1.5, -2.25)
p("pack type", type(pk), tostring(pk), #pk)
p("unpack", byteutil.unpack(">fd", pk))
p("utf8.tostring", utf8.tostring(Bytearray("héllo")), "tobytes", type(utf8.tobytes), type(utf8.tobytes and utf8.tobytes("ab")))
p("copy", type(b.copy), "fill", type(b.fill), "slice", type(b.slice))
local t0 = os.clock()
local big = Bytearray()
for i = 1, 100000 do big:append(i % 256) end
p("append100k", os.clock() - t0)
t0 = os.clock()
local sum = 0
for i = 1, #big do sum = sum + big[i] end
p("read100k", os.clock() - t0, sum)
t0 = os.clock()
local tb = {}
for i = 1, 100000 do tb[i] = i % 256 end
local fromt = Bytearray(tb)
p("table->ba 100k", os.clock() - t0, #fromt)
p("bit", type(bit), bit and bit.band(0xFF00, 0x0F00))
p("crypto", type(crypto), crypto and type(crypto.sha256))
p("math.huge", tostring(1/0), tostring(0/0))
app.reconfig_packs({"base"}, {})
app.new_world("probe", "2026", "core:default")
p("world", world.is_open(), "players", #player.get_all())
local pid = player.create("p1")
p("player.create", pid, player.get_pos(pid))
player.set_pos(pid, 8, 80, 8)
player.set_loading_chunks(pid, true)
for i = 1, 40 do app.tick() end
p("chunks", world.count_chunks())
local d = world.get_chunk_data(0, 0)
p("chunkdata", type(d), d and #d)
p("block at", block.get(8, 60, 8), block.name(math.max(0, block.get(8, 60, 8))))
local d2 = world.get_chunk_data(50, 50)
p("far chunk", type(d2))
if crypto and crypto.sha256 and d then
    local okh, h = pcall(crypto.sha256, d)
    p("sha256", okh, type(h), okh and (type(h) == "string" and #h or tostring(h)))
end
p("entity defs", entities.defs_count())
for i = 0, entities.defs_count() - 1 do p("def", i, entities.def_name(i)) end
p("player entity", player.get_entity(pid))
p("on_world_tick ev", type(events))
p("time", time.uptime(), time.precise_utc_time and time.precise_utc_time())
local srv = network.tcp_open(0, function(s) end)
p("tcp_open port0", srv and srv:get_port())
srv:close()
p("find_free_port", network.find_free_port())
app.close_world(false)
p("done")
