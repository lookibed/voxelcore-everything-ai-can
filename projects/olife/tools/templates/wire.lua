-- olife_proto:wire — runtime of the generated Olife codecs (VoxelCore 0.32 Lua/LuaJIT, Bytearray).
-- Big-endian, strict: every read is bounds-checked, every write type/range-checked; errors are raised as
-- "olife_proto: <path>: <what>" (level 0) and caught by the frame reader (M.read) — a bad frame never crashes
-- the caller, it returns false + reason and the connection is dropped (no resync heuristics).
local M = {}
local floor, huge = math.floor, math.huge
local type, tostring, error = type, tostring, error

local frexp, ldexp = math.frexp, math.ldexp
-- Floats are converted arithmetically (frexp/ldexp), not through FLTview/DBLview over a scratch Bytearray:
-- LuaJIT's type-based alias analysis lets a compiled trace read a stale float after byte stores into the same
-- memory (seen in the engine: wrong rot.z after ~100 decodes). Rounding = IEEE round-half-even, like struct.pack.
local function f32_bits(v)
    local s = 0
    if v < 0 or (v == 0 and 1 / v < 0) then s = 2147483648; v = -v end
    if v == 0 then return s end
    local m, e = frexp(v)            -- v = m * 2^e, 0.5 <= m < 1
    local E = e + 126                -- biased exponent of a normal f32
    local mf
    if E >= 1 then
        mf = (m * 2 - 1) * 8388608   -- 23-bit fraction, exact in a double
    else
        mf = ldexp(v, 149)           -- subnormal: units of 2^-149
        E = 0
    end
    local r = mf - mf % 1
    local frac = mf - r
    if frac > 0.5 or (frac == 0.5 and r % 2 == 1) then r = r + 1 end
    return s + E * 8388608 + r       -- a carry of r into the exponent is the correct rounding
end
local function bits_f32(u)
    local s = 1
    if u >= 2147483648 then s = -1; u = u - 2147483648 end
    local E = (u - u % 8388608) / 8388608
    local M = u % 8388608
    if E == 255 then return 0 / 0 end
    if E == 0 then return s * ldexp(M, -149) end
    return s * ldexp(M + 8388608, E - 150)
end
-- f64 -> hi, lo (two u32)
local function f64_bits(v)
    local s = 0
    if v < 0 or (v == 0 and 1 / v < 0) then s = 2147483648; v = -v end
    if v == 0 then return s, 0 end
    local m, e = frexp(v)
    local E = e + 1022
    local M
    if E >= 1 then
        M = (m * 2 - 1) * 4503599627370496   -- 2^52, exact
    else
        M = ldexp(v, 1074)
        E = 0
    end
    local lo = M % 4294967296
    local hi = (M - lo) / 4294967296
    return s + E * 1048576 + hi, lo
end
local function bits_f64(hi, lo)
    local s = 1
    if hi >= 2147483648 then s = -1; hi = hi - 2147483648 end
    local E = (hi - hi % 1048576) / 1048576
    local M = (hi % 1048576) * 4294967296 + lo
    if E == 2047 then return 0 / 0 end
    if E == 0 then return s * ldexp(M, -1074) end
    return s * ldexp(M + 4503599627370496, E - 1075)
end
M.f32_bits, M.bits_f32, M.f64_bits, M.bits_f64 = f32_bits, bits_f32, f64_bits, bits_f64

local function fail(path, what)
    error("olife_proto: " .. path .. ": " .. what, 0)
end
M.fail = fail

local F32_MAX = 3.4028234663852886e38

-- ------------------------------------------------------------------ checks (encode side)
function M.c_int(v, lo, hi, path)
    if type(v) ~= "number" or v ~= v or v % 1 ~= 0 or v < lo or v > hi then
        fail(path, "expected integer in [" .. lo .. "," .. hi .. "], got " .. tostring(v))
    end
end
function M.c_f32(v, path)
    if type(v) ~= "number" or v ~= v or v > F32_MAX or v < -F32_MAX then
        fail(path, "expected finite f32, got " .. tostring(v))
    end
end
function M.c_f64(v, path)
    if type(v) ~= "number" or v ~= v or v == huge or v == -huge then
        fail(path, "expected finite f64, got " .. tostring(v))
    end
end
function M.c_bool(v, path)
    if type(v) ~= "boolean" then fail(path, "expected boolean, got " .. type(v)) end
end
function M.c_table(v, path)
    if type(v) ~= "table" then fail(path, "expected table, got " .. type(v)) end
end
function M.c_count(n, max, path)
    if n > max then fail(path, "too many elements: " .. n .. " > " .. max) end
end

-- ------------------------------------------------------------------ writers (append to a Bytearray)
local function w_u8(b, v) b:append(v) end
local function w_u16(b, v) b:append(floor(v / 256)); b:append(v % 256) end
local function w_u32(b, v)
    b:append(floor(v / 16777216)); b:append(floor(v / 65536) % 256); b:append(floor(v / 256) % 256); b:append(v % 256)
end
M.w_u8, M.w_u16, M.w_u32 = w_u8, w_u16, w_u32
function M.w_i8(b, v) if v < 0 then v = v + 256 end; b:append(v) end
function M.w_i16(b, v) if v < 0 then v = v + 65536 end; w_u16(b, v) end
function M.w_i32(b, v) if v < 0 then v = v + 4294967296 end; w_u32(b, v) end
function M.w_bool(b, v) b:append(v and 1 or 0) end
function M.w_f32(b, v) w_u32(b, f32_bits(v)) end
function M.w_f64(b, v)
    local hi, lo = f64_bits(v)
    w_u32(b, hi); w_u32(b, lo)
end
-- string: u16 length (bytes) + raw bytes
function M.w_str(b, v, max, path)
    if type(v) ~= "string" then fail(path, "expected string, got " .. type(v)) end
    local n = #v
    if n > max then fail(path, "string too long: " .. n .. " > " .. max) end
    w_u16(b, n)
    if n > 0 then b:append(Bytearray(v)) end
end
-- bytes: u32 length + raw bytes (Bytearray or Lua string)
function M.w_bytes(b, v, max, path)
    local t = type(v)
    if t == "string" then v = Bytearray(v)
    elseif t ~= "cdata" and t ~= "userdata" and t ~= "table" then fail(path, "expected Bytearray, got " .. t) end
    if t == "table" then v = Bytearray(v) end
    local n = #v
    if n > max then fail(path, "bytes too long: " .. n .. " > " .. max) end
    w_u32(b, n)
    if n > 0 then b:append(v) end
end

-- ------------------------------------------------------------------ readers: r = {b = Bytearray, p = pos, e = last}
local function r_u8(r, path)
    local p = r.p
    if p > r.e then fail(path, "truncated") end
    r.p = p + 1
    return r.b[p]
end
local function r_u16(r, path)
    local p = r.p
    if p + 1 > r.e then fail(path, "truncated") end
    local b = r.b
    r.p = p + 2
    return b[p] * 256 + b[p + 1]
end
local function r_u32(r, path)
    local p = r.p
    if p + 3 > r.e then fail(path, "truncated") end
    local b = r.b
    r.p = p + 4
    return ((b[p] * 256 + b[p + 1]) * 256 + b[p + 2]) * 256 + b[p + 3]
end
M.r_u8, M.r_u16, M.r_u32 = r_u8, r_u16, r_u32
function M.r_i8(r, path) local v = r_u8(r, path); if v >= 128 then v = v - 256 end; return v end
function M.r_i16(r, path) local v = r_u16(r, path); if v >= 32768 then v = v - 65536 end; return v end
function M.r_i32(r, path) local v = r_u32(r, path); if v >= 2147483648 then v = v - 4294967296 end; return v end
function M.r_bool(r, path)
    local v = r_u8(r, path)
    if v > 1 then fail(path, "bad bool " .. v) end
    return v == 1
end
function M.r_f32(r, path)
    local v = bits_f32(r_u32(r, path))
    if v ~= v then fail(path, "non-finite f32") end
    return v
end
function M.r_f64(r, path)
    local hi = r_u32(r, path)
    local v = bits_f64(hi, r_u32(r, path))
    if v ~= v then fail(path, "non-finite f64") end
    return v
end
function M.r_str(r, max, path)
    local n = r_u16(r, path)
    if n > max then fail(path, "string too long: " .. n .. " > " .. max) end
    if n == 0 then return "" end
    local p = r.p
    if p + n - 1 > r.e then fail(path, "truncated") end
    r.p = p + n
    return utf8.tostring(r.b:slice(p, n))
end
function M.r_bytes(r, max, path)
    local n = r_u32(r, path)
    if n > max then fail(path, "bytes too long: " .. n .. " > " .. max) end
    if n == 0 then return Bytearray() end
    local p = r.p
    if p + n - 1 > r.e then fail(path, "truncated") end
    r.p = p + n
    return r.b:slice(p, n)
end
function M.r_count(r, max, path)
    local n = r_u16(r, path)
    if n > max then fail(path, "too many elements: " .. n .. " > " .. max) end
    return n
end

-- f32 rounding of a Lua number (what a peer decodes after an f32 round trip)
function M.fround(v)
    return bits_f32(f32_bits(v))
end

-- FNV-1a 32 over a Bytearray (or a range of it)
local bxor = bit.bxor
function M.fnv1a(b, s, e)
    s = s or 1
    e = e or #b
    local h = 2166136261
    for i = s, e do
        h = bxor(h, b[i])
        -- h * 16777619 mod 2^32 without overflowing the double mantissa
        local lo = h % 65536
        local hi = (h - lo) / 65536
        h = (lo * 16777619 + ((hi * 16777619) % 65536) * 65536) % 4294967296
    end
    if h < 0 then h = h + 4294967296 end
    return h
end

-- ------------------------------------------------------------------ frames
M.HEADER = 9
-- append a frame (header + body encoded by enc(b, msg)) to b; returns body length
function M.append_frame(b, magic, version, id, enc, msg)
    local start = #b
    w_u16(b, magic); w_u8(b, version); w_u16(b, id); w_u32(b, 0)
    local ok, err = pcall(enc, b, msg)
    if not ok then
        b:remove(start + 1, #b - start)   -- leave the buffer as it was
        error(err, 0)
    end
    local n = #b - start - 9
    b[start + 6] = floor(n / 16777216); b[start + 7] = floor(n / 65536) % 256
    b[start + 8] = floor(n / 256) % 256; b[start + 9] = n % 256
    return n
end

-- stream reader of one connection: feed(data), next() -> id, s, e | nil (need more) | false, reason
local Framer = {}
Framer.__index = Framer
function M.framer(magic, version, max, known)
    return setmetatable({buf = Bytearray(), off = 1, magic = magic, version = version, max = max, known = known,
                         frames = 0, bytes = 0}, Framer)
end
function Framer:feed(data)
    if data ~= nil and #data > 0 then
        self.buf:append(data)
        self.bytes = self.bytes + #data
    end
end
function Framer:compact()
    local off, n = self.off, #self.buf
    if off > n then
        if n > 0 then self.buf:clear() end
        self.off = 1
    elseif off > 65536 then
        self.buf:remove(1, off - 1)
        self.off = 1
    end
end
function Framer:next()
    local b, off = self.buf, self.off
    local avail = #b - off + 1
    if avail < 9 then self:compact(); return nil end
    local magic = b[off] * 256 + b[off + 1]
    if magic ~= self.magic then return false, string.format("bad magic 0x%04X", magic) end
    local ver = b[off + 2]
    if ver ~= self.version then return false, "wrong version " .. ver .. " (want " .. self.version .. ")" end
    local id = b[off + 3] * 256 + b[off + 4]
    local n = ((b[off + 5] * 256 + b[off + 6]) * 256 + b[off + 7]) * 256 + b[off + 8]
    if n > self.max then return false, "frame too large " .. n .. " > " .. self.max end
    if self.known and not self.known[id] then return false, "unknown type " .. id end
    if avail < 9 + n then return nil end
    self.off = off + 9 + n
    self.frames = self.frames + 1
    return id, off + 9, off + 8 + n
end
M.Framer = Framer

return M
