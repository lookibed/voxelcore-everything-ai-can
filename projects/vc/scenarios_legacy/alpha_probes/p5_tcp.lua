-- Проба 5: network.tcp_connect из VoxelCore (Windows) к серверу в WSL (tools/alphamine/tcp_echo_server.py,
-- порт 25580, 8 МБ). Какие адреса работают (WSL в режиме NAT) и скорость приёма recv(available()) раз в кадр.
-- Адреса — export:alpha_tcp_addrs.txt (через пробел), по умолчанию "127.0.0.1 localhost".
-- Маркеры: [alpha_p5] addr ..., done.
local T = "alpha_p5"
local function log(m) debug.log("[" .. T .. "] " .. m) end
local PORT, SIZE = 25580, 8 * 1024 * 1024
local addrs = {"127.0.0.1", "localhost"}
if file.isfile("export:alpha_tcp_addrs.txt") then
    addrs = {}
    for a in file.read("export:alpha_tcp_addrs.txt"):gmatch("%S+") do addrs[#addrs + 1] = a end
end
log("tcp_open exists: " .. tostring(network.tcp_open ~= nil) .. ", tcp_connect: " .. tostring(network.tcp_connect ~= nil))
for _, addr in ipairs(addrs) do
    local state, err = "wait", nil
    local t0 = os.clock()
    local sock = network.tcp_connect(addr, PORT, function(s) state = "ok" end,
        function(s, e) state = "err"; err = e end)
    pcall(app.sleep_until, function() return state ~= "wait" end, 1e9, 5)
    local tconn = os.clock() - t0
    if state ~= "ok" then
        log(("addr %s: connect %s (%s) after %.2f s"):format(addr, state, tostring(err), tconn))
    else
        sock:set_nodelay(true)
        local got, ticks, maxchunk, bad = 0, 0, 0, 0
        local trecv = 0
        local t1 = os.clock()
        while got < SIZE and ticks < 20000 and sock:is_alive() do
            local n = sock:available()
            if n > 0 then
                local a = os.clock()
                local b = sock:recv(n)
                trecv = trecv + (os.clock() - a)
                local p = b.bytes
                -- проверка содержимого по выборке (каждый 4099-й байт)
                for k = 0, #b - 1, 4099 do
                    local i = got + k
                    if p[k] ~= bit.band(i * 7 + math.floor(i / 4096), 255) then bad = bad + 1 end
                end
                got = got + #b
                if #b > maxchunk then maxchunk = #b end
            end
            app.tick()
            ticks = ticks + 1
        end
        local dt = os.clock() - t1
        log(("addr %s: connect %.2f s; received %d B in %.2f s (%.1f MB/s), %d frames, max chunk %d B, time in recv %.1f ms, bad samples %d"):format(
            addr, tconn, got, dt, got / dt / 1048576, ticks, maxchunk, trecv * 1e3, bad))
        -- эхо: 64 КБ туда и обратно
        local payload = {}
        for i = 1, 65536 do payload[i] = i % 251 end
        local t2 = os.clock()
        sock:send(payload)
        local back = 0
        pcall(app.sleep_until, function()
            local n = sock:available()
            if n > 0 then back = back + #sock:recv(n) end
            return back >= 65536
        end, 1e9, 5)
        log(("addr %s: echo 64 KB round trip %.1f ms (got %d)"):format(addr, (os.clock() - t2) * 1e3, back))
        sock:close()
    end
end
log("done")
