-- Dump of the Lua environment for build comparison (addresses stripped by the caller)
local out = {}
local function p(s) out[#out+1] = s end
p("jit.version=" .. tostring(jit and jit.version) .. " arch=" .. tostring(jit and jit.arch) .. " os=" .. tostring(jit and jit.os))
if jit and jit.status then p("jit.status=" .. table.concat({tostring(select(1, jit.status()))}, ",")) end
local names = {}
for k, v in pairs(_G) do names[#names+1] = tostring(k) .. ":" .. type(v) end
table.sort(names)
p("globals(" .. #names .. ")=" .. table.concat(names, " "))
for _, lib in ipairs({"jit", "bit", "string", "table", "math", "os", "debug", "coroutine", "file", "app", "time", "utf8", "json", "f2f"}) do
    local t = rawget(_G, lib)
    if type(t) == "table" then
        local ks = {}
        for k, v in pairs(t) do ks[#ks+1] = tostring(k) .. ":" .. type(v) end
        table.sort(ks)
        p(lib .. "(" .. #ks .. ")=" .. table.concat(ks, " "))
    else
        p(lib .. "=" .. type(t))
    end
end
p(string.format("num %.17g %.17g %.17g %s", math.sin(1e6), math.exp(0.5), 2^0.5, tostring(1/3)))
p("bit " .. tostring(bit and bit.tohex(bit.bxor(0x12345678, 0x0f0f0f0f))))
p("sort " .. (function() local t = {5,3,9,1,7,2}; table.sort(t, function(a,b) return a>b end); return table.concat(t, ",") end)())
math.randomseed(42); p("rand " .. math.random(1000000) .. " " .. math.random())
for _, l in ipairs(out) do print("[env] " .. l) end
