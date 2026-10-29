-- Lua-кодеки Olife против векторов Python (headless 0.32 --test): декодирование кадров Python, повторное
-- кодирование побайтно, кодирование из значений, строгие ошибки (усечение, хвост), побайтовая подача, замер.
-- Запуск: lab run olife D:\...\tools\olife\tests\codec_vectors.lua (вид vctest копирует векторы в export/vectors).
app.reconfig_packs({"base", "olife_proto"}, {})
if not app.is_content_loaded() then app.load_content() end
local W = require "olife_proto:wire"
local codecs = {client = require "olife_proto:client", internal = require "olife_proto:internal",
                sandbox = require "olife_proto:sandbox"}

local function hex2ba(h)
    local b = Bytearray()
    for i = 1, #h, 2 do b:append(tonumber(h:sub(i, i + 1), 16)) end
    return b
end
local function ba2hex(b, s, e)
    local t = {}
    for i = s or 1, e or #b do t[#t + 1] = string.format("%02x", b[i]) end
    return table.concat(t)
end
local function from_json(v)
    if type(v) == "table" then
        if v["$bytes"] ~= nil then return hex2ba(v["$bytes"]) end
        local o = {}
        for k, x in pairs(v) do o[k] = from_json(x) end
        return o
    end
    return v
end
local function same(a, b, path)
    local ta, tb = type(a), type(b)
    if ta == "cdata" or tb == "cdata" then
        if ta ~= tb or #a ~= #b then return false, path .. ": bytes len" end
        for i = 1, #a do if a[i] ~= b[i] then return false, path .. ": byte " .. i end end
        return true
    end
    if ta ~= tb then return false, path .. ": type " .. ta .. " vs " .. tb end
    if ta == "table" then
        for k, x in pairs(a) do
            local ok, e = same(x, b[k], path .. "." .. tostring(k))
            if not ok then return false, e end
        end
        for k in pairs(b) do if a[k] == nil then return false, path .. "." .. tostring(k) .. " missing" end end
        return true
    end
    if a ~= b then return false, path .. ": " .. tostring(a) .. " ~= " .. tostring(b) end
    return true
end

local fails, checks = {}, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then fails[#fails + 1] = what; print("[codec] FAIL " .. what) end
end

for cname, C in pairs(codecs) do
    local doc = json.parse(file.read("user:export/vectors/" .. cname .. ".json"))
    local n = 0
    for _, v in ipairs(doc.vectors) do
        local frame = hex2ba(v.frame)
        local tag = cname .. "." .. v.name .. "/" .. v.mode
        -- decode the Python frame
        local fr = C.framer()
        fr:feed(frame)
        local name, msg, id = C.read(fr)
        check(name == v.name, tag .. " read: " .. tostring(name) .. " " .. tostring(msg))
        if name then
            local ok, err = same(msg, from_json(v.value), tag)
            check(ok, tag .. " value " .. tostring(err))
            local b = Bytearray()
            C.append_frame(b, id, msg)
            check(ba2hex(b) == v.frame, tag .. " re-encode")
        end
        -- encode from the JSON value
        local b2 = Bytearray()
        local ok2, e2 = pcall(C.append_frame, b2, v.name, from_json(v.value))
        check(ok2 and ba2hex(b2) == v.frame, tag .. " encode " .. tostring(e2))
        -- strict: truncated body and trailing byte must fail
        local blen = #frame - 9
        if blen > 0 then
            local okt = pcall(C.decode_body, v.id, frame, 10, #frame - 1)
            check(not okt, tag .. " truncated accepted")
        end
        local ext = frame:slice(1, #frame)
        ext:append(0)
        local okx = pcall(C.decode_body, v.id, ext, 10, #ext)
        check(not okx, tag .. " trailing accepted")
        n = n + 1
    end
    print(string.format("[codec] %s: %d vectors", cname, n))
end

-- framing errors and byte-by-byte delivery
local C = codecs.client
local good = Bytearray()
C.append_frame(good, "ChatSend", {text = "жx"})
local function bad(mut, needle)
    local f = good:slice(1, #good)
    mut(f)
    local fr = C.framer()
    fr:feed(f)
    local r, why = C.read(fr)
    check(r == false and tostring(why):find(needle, 1, true) ~= nil, "framer " .. needle .. " got " .. tostring(why))
end
bad(function(f) f[1] = 0x58 end, "bad magic")
bad(function(f) f[3] = 9 end, "wrong version")
bad(function(f) f[4] = 1; f[5] = 0 end, "unknown type")
bad(function(f) f[6] = 0; f[7] = 0x10; f[8] = 0; f[9] = 1 end, "frame too large")
bad(function(f) f[9] = f[9] - 1 end, "truncated")            -- length shorter than the body -> decode error
local fr = C.framer()
local got = 0
local stream = Bytearray()
for _ = 1, 3 do stream:append(good) end
for i = 1, #stream do
    fr:feed(stream:slice(i, 1))
    while true do
        local name, msg = C.read(fr)
        if not name then break end
        if msg.text == "жx" then got = got + 1 end
    end
end
check(got == 3, "byte-by-byte frames " .. got)
-- encode checks
check(not pcall(C.append_frame, Bytearray(), "Hello", {proto = 70000, name = "a", token = "t", engine = "e"}), "u16 range")
check(not pcall(C.append_frame, Bytearray(), "PlayerInput", {seq = 1, pos = {x = 0/0, y = 0, z = 0}, rot = {x = 0, y = 0, z = 0}}), "NaN")
check(not pcall(C.append_frame, Bytearray(), "ChatSend", {text = string.rep("x", 257)}), "str max")
local b = Bytearray()
pcall(C.append_frame, b, "ChatSend", {text = string.rep("x", 257)})
check(#b == 0, "failed append leaves buffer unchanged (" .. #b .. ")")
check(W.fnv1a(Bytearray("a")) == 0xE40C292C, "fnv1a " .. W.fnv1a(Bytearray("a")))
check(W.fnv1a(Bytearray("")) == 2166136261, "fnv1a empty")

-- float conversion edge cases (bit patterns checked against Python struct)
check(W.f32_bits(1.5) == 0x3FC00000, "f32 1.5")
check(W.f32_bits(-0.0) == 0x80000000, "f32 -0")
check(W.f32_bits(1e-45) == 1, "f32 min subnormal " .. W.f32_bits(1e-45))
check(W.f32_bits(3.4028234663852886e38) == 0x7F7FFFFF, "f32 max")
check(W.f32_bits(0.1) == 0x3DCCCCCD, "f32 0.1 rounding " .. string.format("%08X", W.f32_bits(0.1)))
check(W.f32_bits(16777217) == 0x4B800000, "f32 half-even 2^24+1")
check(W.f32_bits(16777219) == 0x4B800002, "f32 half-even 2^24+3")
local hi, lo = W.f64_bits(1.5)
check(hi == 0x3FF80000 and lo == 0, "f64 1.5")
hi, lo = W.f64_bits(5e-324)
check(hi == 0 and lo == 1, "f64 min subnormal")
hi, lo = W.f64_bits(-123456.789)
check(W.bits_f64(hi, lo) == -123456.789, "f64 roundtrip")
local bad_rt = 0
for i = 1, 20000 do
    local x = (math.random() - 0.5) * 10 ^ math.random(-40, 40)
    local h2, l2 = W.f64_bits(x)
    if W.bits_f64(h2, l2) ~= x then bad_rt = bad_rt + 1 end
    local f = W.fround(x)
    if math.abs(x) < 3e38 and (W.fround(f) ~= f or math.abs(f - x) > math.abs(x) * 6e-8 + 1.5e-45) then bad_rt = bad_rt + 1 end
end
check(bad_rt == 0, "random float roundtrips bad=" .. bad_rt)

-- micro benchmark: EntitySnapshot with 100 updates
local snap = {tick = 1, spawns = {}, despawns = {}, updates = {}}
for i = 1, 100 do snap.updates[i] = {eid = i, pos = {x = i, y = 64.5, z = -i}, rot = {x = 0, y = i, z = 0}} end
local t0 = time.precise_utc_time()
local total = 0
for _ = 1, 200 do
    local bb = Bytearray()
    C.append_frame(bb, "EntitySnapshot", snap)
    total = total + #bb
end
local t1 = time.precise_utc_time()
local bb = Bytearray()
C.append_frame(bb, "EntitySnapshot", snap)
for _ = 1, 200 do
    local f2 = C.framer()
    f2:feed(bb)
    C.read(f2)
end
local t2 = time.precise_utc_time()
print(string.format("[codec] bench EntitySnapshot(100 updates, %d B): encode %.3f ms, decode %.3f ms",
    #bb, (t1 - t0) * 1000 / 200, (t2 - t1) * 1000 / 200))
print(string.format("[codec] checks=%d fails=%d", checks, #fails))
if #fails > 0 then error("codec vectors: " .. #fails .. " failures, first: " .. fails[1]) end
