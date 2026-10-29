-- Lua environment dump for build comparison, VoxelCore 0.32 (adapted from engine/tests/env_dump.lua):
-- every global, every global table one level deep (keys:type), package.loaded, jit, float results,
-- bit, sort, math.random after randomseed(42). No addresses are printed.
local out = {}
local function p(s) out[#out+1] = s end
p("jit.version=" .. tostring(jit and jit.version) .. " arch=" .. tostring(jit and jit.arch) .. " os=" .. tostring(jit and jit.os))
if jit and jit.status then
    local st = {jit.status()}
    for i = 1, #st do st[i] = tostring(st[i]) end
    p("jit.status=" .. table.concat(st, ","))
end
p("_VERSION=" .. tostring(_VERSION))
local names = {}
for k, v in pairs(_G) do names[#names+1] = tostring(k) .. ":" .. type(v) end
table.sort(names)
p("globals(" .. #names .. ")=" .. table.concat(names, " "))
local libs = {}
for k, v in pairs(_G) do if type(v) == "table" and k ~= "_G" then libs[#libs+1] = tostring(k) end end
table.sort(libs)
for _, lib in ipairs(libs) do
    local t = rawget(_G, lib)
    local ks = {}
    for k, v in pairs(t) do ks[#ks+1] = tostring(k) .. ":" .. type(v) end
    table.sort(ks)
    p(lib .. "(" .. #ks .. ")=" .. table.concat(ks, " "))
end
if package and package.loaded then
    local ks = {}
    for k in pairs(package.loaded) do ks[#ks+1] = tostring(k) end
    table.sort(ks)
    p("package.loaded(" .. #ks .. ")=" .. table.concat(ks, " "))
end
p(string.format("num %.17g %.17g %.17g %s", math.sin(1e6), math.exp(0.5), 2^0.5, tostring(1/3)))
p("bit " .. tostring(bit and bit.tohex(bit.bxor(0x12345678, 0x0f0f0f0f))))
p("sort " .. (function() local t = {5,3,9,1,7,2}; table.sort(t, function(a,b) return a>b end); return table.concat(t, ",") end)())
math.randomseed(42); p("rand " .. math.random(1000000) .. " " .. math.random())
p("version " .. tostring(vc and vc.get_version and table.concat({vc.get_version()}, ".") or "?"))
for _, l in ipairs(out) do print("[env] " .. l) end
