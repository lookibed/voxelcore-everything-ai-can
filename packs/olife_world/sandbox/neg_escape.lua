-- negative: escape attempts (os/io/debug/require/load/dofile/loadfile/getfenv/setfenv/newproxy/string.dump/module/
-- package, bytecode via loadstring, patching the shared stdlib and the string metatable, os.execute, io.open of a
-- canary file). Reports once via say: "ESCAPE_BLOCKED checks=N" or "ESCAPE_LEAK <names>"; then orbits normally.
local leaks, checks = {}, 0
local function absent(name, v)
    checks = checks + 1
    if v ~= nil then leaks[#leaks + 1] = name end
end
absent("os", os) absent("io", io) absent("debug", debug) absent("require", require) absent("load", load)
absent("dofile", dofile) absent("loadfile", loadfile) absent("getfenv", getfenv) absent("setfenv", setfenv)
absent("newproxy", newproxy) absent("string.dump", string.dump) absent("module", module) absent("package", package)
local function fails(name, f)
    checks = checks + 1
    if pcall(f) then leaks[#leaks + 1] = name end
end
fails("bytecode", function() assert(loadstring("\27Lua\81\0")) end)
fails("stdlib_patch", function() string.rep = function() return "" end end)
fails("rawset_stdlib", function() rawset(string, "rep", nil) end)
fails("string_mt", function() getmetatable("").__index = {} end)
fails("os.execute", function() os.execute("echo x > olife_canary.txt") end)
fails("io.open", function() io.open("olife_canary.txt", "w"):write("x") end)
fails("loadstring_env", function() local f = loadstring("return os.execute") assert(f() ~= nil) end)
local t, home, said = 0, nil, false
function on_tick(dt)
    if not said then
        said = true
        self:say(#leaks == 0 and ("ESCAPE_BLOCKED checks=" .. checks) or ("ESCAPE_LEAK " .. table.concat(leaks, ",")))
    end
    t = t + dt
    local p = self.pos
    if home == nil then home = {p[1] - 2, p[2], p[3]} end
    self:move_to({home[1] + math.cos(t) * 2, home[2], home[3] + math.sin(t) * 2})
end
