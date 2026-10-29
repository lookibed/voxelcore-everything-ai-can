-- Проба 0.32 headless, UX A4 (хранилище): Canvas/PNG, sha256, base64, Bytearray<->string, file.write_bytes в world:,
-- список функций assets/audio/Canvas — что доступно миру (сервер) без окна.
local function p(...) print("[probe]", ...) end
local function keys(t)
    local l = {}
    if type(t) ~= "table" then return tostring(t) end
    for k in pairs(t) do l[#l + 1] = tostring(k) end
    table.sort(l)
    return table.concat(l, ",")
end
p("assets", keys(assets))
p("audio", keys(audio))
p("Canvas", type(Canvas), keys(Canvas), keys(getmetatable(Canvas) or {}))
p("base64", keys(base64))
p("crypto", keys(crypto))
p("utf8", keys(utf8))
p("Bytearray", type(Bytearray), keys(getmetatable(Bytearray) or {}))
local c = Canvas({4, 2})
local mt = getmetatable(c)
p("canvas mt", keys(mt), mt and keys(mt.__index) or "")
p("w h", c.width, c.height)
local b = Bytearray(32)
for i = 1, 32 do b[i] = (i * 37) % 256 end
local ok, e = pcall(function() c:set_data(b) end)
p("set_data", ok, e)
p("at(0,0)", string.format("%08x", c:at(0, 0)), "at(1,0)", string.format("%08x", c:at(1, 0)), "at(0,1)", string.format("%08x", c:at(0, 1)))
local okp, png = pcall(function() return c:encode("png") end)
p("encode png", okp, type(png), png and #png)
local okd, d = pcall(function() return Canvas.decode(png, "png") end)
p("Canvas.decode", okd, okd and (type(d) .. " " .. tostring(d.width) .. "x" .. tostring(d.height)) or d)
if okd and type(d) == "userdata" or type(d) == "table" then
    local same = true
    for y = 0, 1 do for x = 0, 3 do if d:at(x, y) ~= c:at(x, y) then same = false end end end
    p("decode roundtrip same", same)
    local okg, gd = pcall(function() return d:get_data() end)
    p("get_data", okg, okg and type(gd), okg and gd and #gd)
end
local s = utf8.tostring(png)
p("utf8.tostring len", #s, "png len", #png, "sig", s:sub(2, 4))
local h = crypto.sha256(s)
p("sha256 type/len", type(h), #h)
local okh2, h2 = pcall(crypto.sha256, png)
p("sha256(Bytearray)", okh2, okh2 and #h2 or h2)
local e64 = base64.encode(png)
p("b64 len", #e64, type(e64))
local d64 = base64.decode(e64)
p("b64 decode type", type(d64), #d64)
local okmk = pcall(file.mkdirs, "world:olife_store/cas/ab")
p("mkdirs world (no world)", okmk)
app.reconfig_packs({"base"}, {})
app.new_world("store_probe", "1", "core:default")
p("mkdirs world", pcall(file.mkdirs, "world:olife_store/cas/ab"))
p("write_bytes", pcall(file.write_bytes, "world:olife_store/cas/ab/x.png", png))
p("exists/len", file.exists("world:olife_store/cas/ab/x.png"), #file.read_bytes("world:olife_store/cas/ab/x.png"))
p("resolve", pcall(file.resolve, "world:olife_store/cas/ab/x.png"))
p("list", json.tostring(file.list("world:olife_store/cas/ab")))
p("remove", pcall(file.remove, "world:olife_store/cas/ab/x.png"), file.exists("world:olife_store/cas/ab/x.png"))
-- 256x256 encode timing
local big = Canvas({256, 256})
local bb = Bytearray(256 * 256 * 4)
for i = 1, #bb do bb[i] = (i * 7) % 251 end
local t0 = os.clock()
big:set_data(bb)
local bp = big:encode("png")
local t1 = os.clock()
local bs = utf8.tostring(bp)
local hh = crypto.sha256(bs)
local t2 = os.clock()
p(string.format("256x256 set+encode %.2f ms, png %d B, tostring+sha %.2f ms", (t1 - t0) * 1000, #bp, (t2 - t1) * 1000))
local t3 = os.clock()
local bb2 = Bytearray(256 * 256 * 4)
for i = 1, #bb2 do bb2[i] = 0 end
p(string.format("Bytearray fill loop %.2f ms", (os.clock() - t3) * 1000))
p("Bytearray from string", pcall(function() local x = Bytearray(bs); return #x end))
app.close_world(false)
p("done")
