-- Проба: доступен ли в VoxelCore таймерный профилировщик LuaJIT (jit.profile) и jit.util.
-- Запуск: VoxelCore.exe --headless --script tools/scenarios/jit_profile_probe.lua
local function log(s) local m = "[jit_probe] " .. tostring(s); print(m); if debug and debug.log then debug.log(m) end end
log("jit = " .. tostring(jit) .. " version " .. tostring(jit and jit.version))
log("jit.profile = " .. tostring(jit and jit.profile))
log("jit.util = " .. tostring(jit and jit.util))
log("package = " .. tostring(package) .. " preload = " .. tostring(package and package.preload))
if package and package.preload then
    local keys = {}
    for k in pairs(package.preload) do keys[#keys+1] = tostring(k) end
    log("preload keys: " .. table.concat(keys, ", "))
    local l2 = {}
    if package.loaded then for k in pairs(package.loaded) do l2[#l2+1] = tostring(k) end end
    log("loaded keys: " .. table.concat(l2, ", "))
end
local ok, prof = pcall(function() return package.preload["jit.profile"]() end)
log("require jit.profile: " .. tostring(ok) .. " " .. tostring(prof))
local ok2, jutil = pcall(function() return package.preload["jit.util"]() end)
log("require jit.util: " .. tostring(ok2) .. " " .. tostring(jutil))
local P = (ok and prof) or (jit and jit.profile)
if P and P.start then
    local counts, n = {}, 0
    P.start("li1", function(th, samples, vmstate)
        n = n + samples
        local key = P.dumpstack(th, "l", 1) .. vmstate
        counts[key] = (counts[key] or 0) + samples
    end)
    local t0 = os.clock()
    local acc = 0
    while os.clock() - t0 < 0.5 do
        for i = 1, 100000 do acc = acc + math.sin(i) end
    end
    P.stop()
    log("samples in 0.5 s: " .. n)
    for k, v in pairs(counts) do log(("  %d %s"):format(v, k)) end
else
    log("профилировщик недоступен")
end
log("done")
