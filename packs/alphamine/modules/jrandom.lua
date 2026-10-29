-- java.util.Random (48-bit LCG) in doubles: seed kept as two 24-bit halves so every product stays exact.
-- Used where the Alpha client seeds a Random per frame (GuiIngame heart jitter: setSeed(updateCounter * 312871)).
local bxor = bit.bxor
local TWO24 = 16777216
local MH, ML = 1502, 15525485          -- 0x5DEECE66D = 1502 * 2^24 + 15525485
local M = {}
M.__index = M

function M.new(seed)
    local r = setmetatable({hi = 0, lo = 0}, M)
    r:set_seed(seed or 0)
    return r
end

-- (int) a * b with Java int overflow, result as a signed 32-bit number
function M.imul(a, b)
    local lo = (a % 65536) * b
    local hi = math.floor(a / 65536) % 65536 * b % 65536
    local v = (hi * 65536 + lo) % 4294967296
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

-- setSeed(long s): (s ^ 0x5DEECE66D) & (2^48 - 1); s may be negative (two's complement)
function M:set_seed(s)
    local s48 = s % 281474976710656
    local lo, hi = s48 % TWO24, math.floor(s48 / TWO24)
    self.lo = bxor(lo, ML) % TWO24
    self.hi = bxor(hi, MH) % TWO24
end

function M:next(bits)
    local lo, hi = self.lo, self.hi
    local p = lo * ML + 11                            -- < 2^48
    local mid = (hi * ML + lo * MH) % TWO24 + math.floor(p / TWO24)
    self.lo = p % TWO24
    self.hi = mid % TWO24
    -- seed >>> (48 - bits) as a signed int of `bits` bits
    local seed = self.hi * TWO24 + self.lo
    local v = math.floor(seed / 2 ^ (48 - bits))
    if bits == 32 and v >= 2147483648 then v = v - 4294967296 end
    return v
end

function M:next_int(n)
    if n > 0 and bit.band(n, -n) == n then
        return math.floor(n * self:next(31) / 2147483648)
    end
    local b, v
    repeat
        b = self:next(31)
        v = b % n
    until b - v + (n - 1) < 2147483648
    return v
end

function M:next_float()
    return self:next(24) / TWO24
end

return M
