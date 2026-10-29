-- F2F Lua handler test project (probe: F2F client, cases lua)
print("[f2f-test] active=" .. tostring(f2f.is_active()))
local ok = f2f.set_handler(function(cmd, args)
    if cmd == "state" then
        return {uptime = time.uptime(), delta = time.delta(), echo = args}
    elseif cmd == "mode" then
        return {r = math.random(1000000)}
    end
    error("unknown-command: " .. tostring(cmd))
end)
print("[f2f-test] set_handler=" .. tostring(ok))
