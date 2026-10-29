-- Wave 5p (olife_w5p): what the LuaJIT of stock 0.32 headless exposes (jit table, status, attach, clocks).
local function keys(t)
    local l = {}
    for k, v in pairs(t or {}) do l[#l + 1] = tostring(k) .. ":" .. type(v) end
    table.sort(l)
    return table.concat(l, " ")
end
print("[probe_jit] version=" .. tostring(jit and jit.version) .. " os=" .. tostring(jit and jit.os) .. " arch=" .. tostring(jit and jit.arch))
print("[probe_jit] jit: " .. keys(jit))
print("[probe_jit] jit.opt: " .. keys(jit and jit.opt))
print("[probe_jit] status: " .. table.concat({tostring(jit.status())}, " ") .. " | " .. table.concat({select(2, jit.status())}, " "))
print("[probe_jit] package: " .. type(package) .. " preload=" .. type(package and package.preload) .. " debug: " .. keys(debug))
print("[probe_jit] time: " .. keys(time))
-- trace events
local ev = {start = 0, stop = 0, abort = 0, flush = 0}
local aborts = {}
if jit.attach then
    jit.attach(function(what, tr, func, pc, otr, oex)
        ev[what] = (ev[what] or 0) + 1
        if what == "abort" then
            local i = debug.getinfo(func, "S")
            aborts[#aborts + 1] = string.format("tr=%s %s:%s pc=%s err=%s info=%s", tostring(tr), i and i.short_src or "?",
                i and i.linedefined or "?", tostring(pc), tostring(otr), tostring(oex))
        end
    end, "trace")
end
local function loop_plain(n) local s = 0 for i = 1, n do s = s + i % 7 end return s end
local function loop_c(n) local s = 0 for i = 1, n do s = s + #tostring(i) end return s end
local function loop_pcall(n) local s = 0 for i = 1, n do local ok, v = pcall(math.floor, i * 0.5) s = s + v end return s end
local function loop_ba(n) local b = Bytearray() for i = 1, n do b:append(i % 256) end return #b end
local function bench(name, f, n)
    local t0 = time.precise_time()
    f(n)
    local dt = (time.precise_time() - t0) * 1000
    print(string.format("[probe_jit] %-10s n=%d %.3f ms", name, n, dt))
end
for _, mode in ipairs({"on", "off", "on"}) do
    if mode == "on" then jit.on() else jit.off() end
    jit.flush()
    print("[probe_jit] mode " .. mode .. " status=" .. tostring(jit.status()))
    bench("plain", loop_plain, 1e6)
    bench("tostring", loop_c, 2e5)
    bench("pcall", loop_pcall, 2e5)
    bench("bytearray", loop_ba, 2e5)
end
-- clock resolution
local function res(f)
    local a = f(); local b = a
    while b == a do b = f() end
    local mn = math.huge
    for _ = 1, 50 do
        local x = f(); local y = f()
        while y == x do y = f() end
        if y - x < mn then mn = y - x end
    end
    return mn
end
print(string.format("[probe_jit] res precise_time=%.3g s precise_utc_time=%.3g s os.clock=%.3g s", res(time.precise_time),
    res(time.precise_utc_time), res(os.clock)))
local t0 = time.precise_time()
for _ = 1, 1e5 do time.precise_time() end
print(string.format("[probe_jit] precise_time call %.1f ns", (time.precise_time() - t0) * 1e9 / 1e5))
t0 = time.precise_time()
for _ = 1, 1e5 do time.precise_utc_time() end
print(string.format("[probe_jit] precise_utc_time call %.1f ns", (time.precise_time() - t0) * 1e9 / 1e5))
print(string.format("[probe_jit] trace events start=%d stop=%d abort=%d flush=%d", ev.start, ev.stop, ev.abort, ev.flush))
for i = 1, math.min(#aborts, 12) do print("[probe_jit] abort " .. aborts[i]) end
print(string.format("[probe_jit] gc %.0f KB pause/stepmul default?", collectgarbage("count")))
