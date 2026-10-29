-- Plain-LuaJIT check that chunk_codec.extrle16(raw, zeros) is byte-identical to the element-by-element version
-- (the algorithm only; the engine side is checked by the F2F block hash of alpha_spawn).
--   luajit tools/alphamine/perf/test_extrle16.lua <old chunk_codec.lua> <new chunk_codec.lua>
local ffi = require "ffi"
local mt = {__len = function(self) return self.size end}
function Bytearray(n)
    local o = setmetatable({bytes = ffi.new("uint8_t[?]", n), size = n}, mt)
    return o
end
bit = require "bit"
compression = {encode = function(x) return x end}
local function load(path)
    return dofile(path)
end
local old, new = load(arg[1]), load(arg[2])
local ZEROS = {{32768, 65535}, {98304, 131071}}
math.randomseed(12345)
local function case(kind)
    local raw = Bytearray(262144)
    local p = raw.bytes
    for i = 0, 262143 do p[i] = 0 end
    for x = 0, 15 do for z = 0, 15 do for y = 0, 127 do
        local vi = ((y * 16 + z) * 16 + x) * 2
        local id
        if kind == 1 then id = y < 60 and 1 or (y < 64 and 3 or 0)
        elseif kind == 2 then id = math.random(0, 3) == 0 and math.random(0, 400) or 1
        elseif kind == 3 then id = 0
        else id = (y < 127) and 5 or 0 end
        p[vi] = id % 256; p[vi + 1] = math.floor(id / 256)
        local meta = (kind == 2) and math.random(0, 15) or 0
        p[131072 + vi + 1] = meta
    end end end
    return raw
end
local bad = 0
for kind = 1, 4 do
    local raw = case(kind)
    local a = old.extrle16(raw)
    local sa = ffi.string(a.bytes, a.size)
    local b = new.extrle16(raw, ZEROS)
    local sb = ffi.string(b.bytes, b.size)
    print(("case %d: old %d bytes, new %d bytes, %s"):format(kind, #sa, #sb, sa == sb and "identical" or "DIFFERENT"))
    if sa ~= sb then bad = bad + 1 end
    local t0 = os.clock(); for _ = 1, 20 do old.extrle16(raw) end; local t1 = os.clock()
    for _ = 1, 20 do new.extrle16(raw, ZEROS) end; local t2 = os.clock()
    print(("  old %.3f ms, new %.3f ms per call"):format((t1 - t0) / 20 * 1e3, (t2 - t1) / 20 * 1e3))
end
os.exit(bad == 0 and 0 or 1)
