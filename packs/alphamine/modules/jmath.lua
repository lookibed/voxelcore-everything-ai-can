-- Java arithmetic for bit-exact parity with the Alpha client (phase 3):
--   fround(x)            (float) cast: round a double to the nearest float32 (ties to even), like Java/JVM
--   sin/cos(f)           MathHelper.sin/cos: 65536-entry float table, index (int)(f*10430.378F) & 65535
--   floor(x)             MathHelper.floor_double
--   Random(seed64)       java.util.Random (48-bit LCG): next_int(n), next_float(), next_double(), set_seed
--   mix(seed, tag, n)    F2FRandom.mix (splitmix-like, 64-bit wrapping) -> 64-bit value as 4 x 16-bit limbs
--   entity_seed(seed,id) F2FRandom.entitySeed = mix(seed, "Entity", id)
-- 64-bit values are {a, b, c, d}: 16-bit limbs, a = most significant (pure Lua, no ffi/int64 cdata).
local band, bxor = bit.band, bit.bxor
local floor, ldexp, frexp = math.floor, math.ldexp, math.frexp

local M = {}

local HUGE = math.huge
local FLT_MAX = 3.4028234663852886e38
-- (float)x: round to 24 significant bits (subnormals: quantum 2^-149), ties to even
local function fround(x)
    if x == 0 or x ~= x or x == HUGE or x == -HUGE then return x end
    local _, e = frexp(x)                  -- x = m * 2^e, 0.5 <= |m| < 1
    local q = e - 24
    if q < -149 then q = -149 end
    local s = ldexp(x, -q)                 -- exact scaling
    local f = floor(s)
    local d = s - f
    if d > 0.5 or (d == 0.5 and f % 2 ~= 0) then f = f + 1 end
    local r = ldexp(f, q)
    if r > FLT_MAX then return HUGE elseif r < -FLT_MAX then return -HUGE end
    return r
end
M.fround = fround

-- float literals as Java stores them
M.F = setmetatable({}, {__index = function(t, k) local v = fround(k); rawset(t, k, v); return v end})

-- (int) cast of a float/double (truncation toward zero, saturating like Java)
local function toint(x)
    if x ~= x then return 0 end
    if x >= 2147483647 then return 2147483647 end
    if x <= -2147483648 then return -2147483648 end
    return x >= 0 and floor(x) or -floor(-x)
end
M.toint = toint

function M.floor(x)                        -- MathHelper.floor_double
    local i = toint(x)
    return x < i and i - 1 or i
end

-- MathHelper tables
local SIN = {}
for i = 0, 65535 do SIN[i] = fround(math.sin(i * math.pi * 2.0 / 65536.0)) end
local K = fround(10430.378)
function M.sin(f)
    return SIN[band(toint(fround(f * K)), 65535)]
end
function M.cos(f)
    return SIN[band(toint(fround(fround(f * K) + 16384.0)), 65535)]
end
function M.sqrt_float(f) return fround(math.sqrt(f)) end
function M.sqrt_double(d) return fround(math.sqrt(d)) end
M.PI_F = fround(math.pi)                   -- (float)Math.PI

-- ------------------------------------------------------------------ 64-bit limbs
local T16 = 65536
local function u64(v)                      -- from a Lua integer in [-2^53, 2^53]
    local neg = v < 0
    if neg then v = -v end
    local d = v % T16; v = (v - d) / T16
    local c = v % T16; v = (v - c) / T16
    local b = v % T16; v = (v - b) / T16
    local a = v % T16
    local r = {a, b, c, d}
    if neg then                             -- two's complement
        r = {65535 - a, 65535 - b, 65535 - c, 65535 - d}
        local carry = 1
        for k = 4, 1, -1 do
            local s = r[k] + carry
            r[k] = s % T16
            carry = s >= T16 and 1 or 0
        end
    end
    return r
end
M.u64 = u64
local function hex64(h) -- "9E3779B97F4A7C15" -> limbs
    return {tonumber(h:sub(1, 4), 16), tonumber(h:sub(5, 8), 16), tonumber(h:sub(9, 12), 16), tonumber(h:sub(13, 16), 16)}
end
local function add64(x, y)
    local r, carry = {}, 0
    for k = 4, 1, -1 do
        local s = x[k] + y[k] + carry
        r[k] = s % T16
        carry = s >= T16 and 1 or 0
    end
    return r
end
local function mul64(x, y)                 -- mod 2^64
    local r = {0, 0, 0, 0}
    -- limb index from the least significant: x4 = x[4] ...
    local acc = {0, 0, 0, 0}
    for i = 0, 3 do
        for j = 0, 3 - i do
            acc[i + j + 1] = acc[i + j + 1] + x[4 - i] * y[4 - j]
        end
    end
    local carry = 0
    for k = 1, 4 do
        local s = acc[k] + carry
        local lo = s % T16
        carry = (s - lo) / T16
        r[5 - k] = lo
    end
    return r
end
local function xor64(x, y)
    return {bxor(x[1], y[1]), bxor(x[2], y[2]), bxor(x[3], y[3]), bxor(x[4], y[4])}
end
local function shr64(x, n)                 -- logical, 0 < n < 64
    local hi = x[1] * T16 + x[2]
    local lo = x[3] * T16 + x[4]
    local nhi, nlo
    if n >= 32 then
        nhi, nlo = 0, floor(hi / 2 ^ (n - 32))
    else
        local p = 2 ^ n
        nlo = floor(lo / p) + (hi % p) * 2 ^ (32 - n)
        nhi = floor(hi / p)
    end
    return {floor(nhi / T16), nhi % T16, floor(nlo / T16), nlo % T16}
end
M.add64, M.mul64, M.xor64, M.shr64 = add64, mul64, xor64, shr64

-- String.hashCode (int)
function M.hash_code(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end
    return h >= 2147483648 and h - 4294967296 or h
end

local C1, C2, C3 = hex64("9E3779B97F4A7C15"), hex64("C2B2AE3D27D4EB4F"), hex64("165667B19E3779F9")
local C4, C5 = hex64("BF58476D1CE4E5B9"), hex64("94D049BB133111EB")
-- F2FRandom.mix(long s, String tag, int n)
function M.mix(seed, tag, n)
    local s = type(seed) == "table" and seed or u64(seed)
    local z = add64(add64(mul64(s, C1), mul64(u64(M.hash_code(tag)), C2)), mul64(u64(n), C3))
    z = mul64(xor64(z, shr64(z, 30)), C4)
    z = mul64(xor64(z, shr64(z, 27)), C5)
    return xor64(z, shr64(z, 31))
end
function M.entity_seed(seed, id) return M.mix(seed, "Entity", id) end

-- ------------------------------------------------------------------ java.util.Random
local T24 = 16777216
local MHI, MLO = 0x5DE, 0xECE66D           -- 0x5DEECE66D = MHI * 2^24 + MLO
local Random = {}
Random.__index = Random

function Random:set_seed(seed)             -- seed: Lua integer or 64-bit limbs
    local s = type(seed) == "table" and seed or u64(seed)
    -- low 48 bits ^ 0x5DEECE66D
    local b, c, d = bxor(s[2], 0x0005), bxor(s[3], 0xDEEC), bxor(s[4], 0xE66D)
    self.hi = b * 256 + floor(c / 256)                -- bits 24..47
    self.lo = (c % 256) * T16 + d                     -- bits 0..23
    self.have_gaussian = false
end

function Random:next(bits)
    local lo, hi = self.lo, self.hi
    local t = lo * MLO + 0xB
    local nlo = t % T24
    local carry = (t - nlo) / T24
    local mid = hi * MLO + lo * MHI + carry
    local nhi = mid % T24
    self.lo, self.hi = nlo, nhi
    -- (int)(seed >>> (48 - bits))
    local v = floor((nhi * T24 + nlo) / 2 ^ (48 - bits))
    if bits == 32 and v >= 2147483648 then v = v - 4294967296 end
    return v
end

function Random:next_float()
    return self:next(24) / T24
end

function Random:next_double()
    return (self:next(26) * 134217728 + self:next(27)) / 9007199254740992
end

function Random:next_int(n)
    if not n then return self:next(32) end
    if n % 2 == 0 and band(n, -n) == n then        -- power of two
        return floor(n * self:next(31) / 2147483648)
    end
    while true do
        local bits = self:next(31)
        local val = bits % n
        -- Java: bits - val + (n-1) < 0 with int overflow
        if bits - val + (n - 1) < 2147483648 then return val end
    end
end

function M.Random(seed)
    local r = setmetatable({}, Random)
    r:set_seed(seed or 0)
    return r
end

return M
