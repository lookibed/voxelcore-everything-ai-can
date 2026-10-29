-- Network: TCP client of the Alpha SMP protocol 14 (server Alpha 0.1.1, <repo>\projects\alphamine\external\ref\minecraft_server).
-- Frame: [u8 id][payload], big-endian, no length prefix (Packet.java) -> stream parser over a receive buffer.
-- Strings: Java writeUTF (u16 length + modified UTF-8). Doubles/floats: IEEE big-endian.
-- Transport: network.tcp_connect + recv(available()) once per alpha tick (engine receives in its own thread;
-- read everything available at once: recv erases the head of the engine's vector).
-- Login: -> Handshake(2, user) <- Handshake("-") -> Login(1, 14, user, "Password") <- Login(entity 0,"","").
-- Incoming packets are dispatched to M.handler[<name>](...) set by alphamine:game; unknown ids -> disconnect
-- (the stream cannot be resynchronised without lengths).
local M = {
    sock = nil, state = "idle", host = nil, port = nil, error = nil,
    handler = {},
    stats = {bytes_in = 0, bytes_out = 0, packets_in = 0, packets_out = 0, by_id = {}, recv_calls = 0,
             connect_ms = 0, max_buffer = 0, max_poll = 0, polls_capped = 0},
    -- F2F lockstep barrier (agents/F2F.md 9): bytes of the current connection handed to the socket / taken from it
    conn_out = 0, conn_in = 0,
}

local band, rshift = bit.band, bit.rshift
local floor, ldexp = math.floor, math.ldexp
M.perf = require "alphamine:perf"

-- ------------------------------------------------------------------ receive buffer
local buf = nil      -- Bytearray (capacity = #buf)
local rpos, rlen = 0, 0

local function ensure(extra)
    local live = rlen - rpos
    if buf and rlen + extra <= #buf then return end
    local cap = buf and #buf or 65536
    while cap < live + extra do cap = cap * 2 end
    local nb = Bytearray(cap)
    if buf and live > 0 then
        local s, d = buf.bytes, nb.bytes
        for i = 0, live - 1 do d[i] = s[rpos + i] end
    end
    buf, rpos, rlen = nb, 0, live
end

local function push(b)
    local n = #b
    if n == 0 then return end
    if buf and rpos == rlen then rpos, rlen = 0, 0 end
    if buf and rlen + n > #buf and rpos > 0 and (rlen - rpos) + n <= #buf then
        -- compact in place
        local p = buf.bytes
        local live = rlen - rpos
        for i = 0, live - 1 do p[i] = p[rpos + i] end
        rpos, rlen = 0, live
    end
    ensure(n)
    local d, s = buf.bytes, b.bytes
    for i = 0, n - 1 do d[rlen + i] = s[i] end
    rlen = rlen + n
    if rlen - rpos > M.stats.max_buffer then M.stats.max_buffer = rlen - rpos end
end

-- ------------------------------------------------------------------ readers (p = buf.bytes, absolute index)
local function u8(p, i) return p[i] end
local function i8(p, i) local v = p[i]; return v >= 128 and v - 256 or v end
local function u16(p, i) return p[i] * 256 + p[i + 1] end
local function i16(p, i) local v = p[i] * 256 + p[i + 1]; return v >= 32768 and v - 65536 or v end
local function i32(p, i)
    local v = ((p[i] * 256 + p[i + 1]) * 256 + p[i + 2]) * 256 + p[i + 3]
    return v >= 2147483648 and v - 4294967296 or v
end
local function f32(p, i)
    local b0, b1, b2, b3 = p[i], p[i + 1], p[i + 2], p[i + 3]
    local sign = b0 >= 128 and -1 or 1
    local exp = band(b0, 127) * 2 + rshift(b1, 7)
    local mant = (band(b1, 127) * 256 + b2) * 256 + b3
    if exp == 0 then return sign * ldexp(mant, -149) end
    if exp == 255 then return mant == 0 and sign * math.huge or 0 / 0 end
    return sign * ldexp(mant + 8388608, exp - 150)
end
local function f64(p, i)
    local b0, b1 = p[i], p[i + 1]
    local sign = b0 >= 128 and -1 or 1
    local exp = band(b0, 127) * 16 + rshift(b1, 4)
    local hi = band(b1, 15) * 65536 + p[i + 2] * 256 + p[i + 3]            -- 20 bits
    local lo = ((p[i + 4] * 256 + p[i + 5]) * 256 + p[i + 6]) * 256 + p[i + 7]  -- 32 bits
    local mant = hi * 4294967296 + lo                                     -- 52 bits, exact in a double
    if exp == 0 then return sign * ldexp(mant, -1074) end
    if exp == 2047 then return mant == 0 and sign * math.huge or 0 / 0 end
    return sign * ldexp(mant + 4503599627370496, exp - 1075)
end
M.f64, M.f32 = f64, f32

-- UTF at i: returns string, next index; nil when incomplete
local function utf(p, i, limit)
    if i + 2 > limit then return nil end
    local n = u16(p, i)
    if i + 2 + n > limit then return nil end
    local t = {}
    for k = 0, n - 1 do t[k + 1] = string.char(p[i + 2 + k]) end
    return table.concat(t), i + 2 + n
end

-- ------------------------------------------------------------------ writers
local pack = byteutil.pack

local function send(...)
    if not M.sock then return end
    for k = 1, select("#", ...) do
        local part = select(k, ...)
        M.sock:send(part)
        M.stats.bytes_out = M.stats.bytes_out + #part
        M.conn_out = M.conn_out + #part
    end
    M.stats.packets_out = M.stats.packets_out + 1
end

local function utf_parts(s)
    return pack(">H", #s), s
end

function M.send_handshake(user)
    send(pack(">B", 2), utf_parts(user))
end
function M.send_login(user, password, proto)
    local a, b = utf_parts(user)
    local c, d = utf_parts(password)
    send(pack(">Bi", 1, proto), a, b, c, d)
end
function M.send_chat(text)
    send(pack(">B", 3), utf_parts(text))
end
function M.send_keepalive()
    send(pack(">B", 0))
end
-- Packet255KickDisconnect client -> server (WorldClient.sendQuittingDisconnectingPacket: "Quitting")
function M.send_disconnect(reason)
    send(pack(">B", 255), utf_parts(reason or "Quitting"))
end
-- Packet10Flying .. Packet13PlayerLookMove, client -> server: y = bounding box minY (feet), stance = posY (eyes)
function M.send_flying(on_ground)
    send(pack(">BB", 10, on_ground and 1 or 0))
end
function M.send_position(x, y, stance, z, on_ground)
    send(pack(">BddddB", 11, x, y, stance, z, on_ground and 1 or 0))
end
function M.send_look(yaw, pitch, on_ground)
    send(pack(">BffB", 12, yaw, pitch, on_ground and 1 or 0))
end
function M.send_look_move(x, y, stance, z, yaw, pitch, on_ground)
    send(pack(">BddddffB", 13, x, y, stance, z, yaw, pitch, on_ground and 1 or 0))
end
-- phase 3 (player/entities/items): Packet16BlockItemSwitch, Packet18ArmAnimation, Packet21PickupSpawn
function M.send_item_switch(eid, id)
    send(pack(">Bih", 16, eid, id))
end
function M.send_arm_animation(eid, animate)
    send(pack(">Bib", 18, eid, animate))
end
function M.send_pickup_spawn(eid, item, count, x, y, z, rot, pitch, roll)
    send(pack(">Bihbiiibbb", 21, eid, item, count, x, y, z, rot, pitch, roll))
end
-- phase 4 (world interaction, modules/interact.lua): Packet14BlockDig (status u8, x i32, y u8, z i32, face u8),
-- Packet15Place (id i16, x i32, y u8, z i32, direction u8)
local function byte8(v) return v % 256 end
function M.send_block_dig(status, x, y, z, face)
    send(pack(">BBiBiB", 14, byte8(status), x, byte8(y), z, byte8(face)))
end
function M.send_place(id, x, y, z, direction)
    send(pack(">BhiBiB", 15, id, x, byte8(y), z, byte8(direction)))
end

-- ------------------------------------------------------------------ packet parser
-- fixed payload sizes (server -> client); variable ones are parsed below
local FIXED = {[0] = 0, [10] = 1, [11] = 33, [12] = 9, [13] = 41, [16] = 6, [17] = 5, [18] = 5, [21] = 22,
               [22] = 8, [23] = 17, [29] = 4, [30] = 4, [31] = 7, [32] = 6, [33] = 9, [34] = 18, [50] = 9,
               [53] = 11}

local function call(name, ...)
    local h = M.handler[name]
    if h then h(...) end
end

-- parse one packet at rpos; returns true if consumed, false if incomplete
local function parse_one()
    local p = buf.bytes
    local i, limit = rpos, rlen
    if i >= limit then return false end
    local id = p[i]
    i = i + 1
    local need = FIXED[id]
    if need then
        if i + need > limit then return false end
        if id == 0 then
            call("keepalive")
        elseif id == 10 then
            call("flying", 10, nil, nil, nil, nil, nil, nil, p[i] ~= 0)
        elseif id == 11 then
            call("flying", 11, f64(p, i), f64(p, i + 8), f64(p, i + 16), f64(p, i + 24), nil, nil, p[i + 32] ~= 0)
        elseif id == 12 then
            call("flying", 12, nil, nil, nil, nil, f32(p, i), f32(p, i + 4), p[i + 8] ~= 0)
        elseif id == 13 then
            call("flying", 13, f64(p, i), f64(p, i + 8), f64(p, i + 16), f64(p, i + 24), f32(p, i + 32),
                 f32(p, i + 36), p[i + 40] ~= 0)
        elseif id == 17 then
            call("add_to_inventory", i16(p, i), i8(p, i + 2), i16(p, i + 3))
        elseif id == 50 then
            call("pre_chunk", i32(p, i), i32(p, i + 4), p[i + 8] ~= 0)
        elseif id == 53 then
            call("block_change", i32(p, i), p[i + 4], i32(p, i + 5), p[i + 9], p[i + 10])
        elseif id == 29 then
            call("destroy_entity", i32(p, i))
        elseif id == 16 or id == 18 or id == 21 or id == 22 or id == 23 or id >= 30 and id <= 34 then
            call("entity", id)
            -- phase 3: entity packets with their fields (NetClientHandler.handle*), alphamine:entities
            if id == 16 then
                call("item_switch", i32(p, i), i16(p, i + 4))
            elseif id == 18 then
                call("arm_animation", i32(p, i), i8(p, i + 4))
            elseif id == 21 then
                call("pickup_spawn", i32(p, i), i16(p, i + 4), i8(p, i + 6), i32(p, i + 7), i32(p, i + 11),
                     i32(p, i + 15), i8(p, i + 19), i8(p, i + 20), i8(p, i + 21))
            elseif id == 22 then
                call("collect", i32(p, i), i32(p, i + 4))
            elseif id == 23 then
                call("vehicle_spawn", i32(p, i), i8(p, i + 4), i32(p, i + 5), i32(p, i + 9), i32(p, i + 13))
            elseif id == 30 then
                call("entity_move", i32(p, i), 0, 0, 0)
            elseif id == 31 then
                call("entity_move", i32(p, i), i8(p, i + 4), i8(p, i + 5), i8(p, i + 6))
            elseif id == 32 then
                call("entity_move", i32(p, i), 0, 0, 0, i8(p, i + 4), i8(p, i + 5))
            elseif id == 33 then
                call("entity_move", i32(p, i), i8(p, i + 4), i8(p, i + 5), i8(p, i + 6), i8(p, i + 7), i8(p, i + 8))
            elseif id == 34 then
                call("entity_teleport", i32(p, i), i32(p, i + 4), i32(p, i + 8), i32(p, i + 12), i8(p, i + 16),
                     i8(p, i + 17))
            end
        end
        rpos = i + need
        return true, id
    end
    if id == 51 then
        if i + 17 > limit then return false end
        local len = i32(p, i + 13)
        if i + 17 + len > limit then return false end
        local x, y, z = i32(p, i), i16(p, i + 4), i32(p, i + 6)
        local sx, sy, sz = p[i + 10] + 1, p[i + 11] + 1, p[i + 12] + 1
        local zlib = buf:slice(i + 17 + 1, len)  -- slice is 1-based
        rpos = i + 17 + len
        call("map_chunk", x, y, z, sx, sy, sz, zlib)
        return true, id
    elseif id == 52 then
        if i + 10 > limit then return false end
        local n = u16(p, i + 8)
        if i + 10 + n * 4 > limit then return false end
        local cx, cz = i32(p, i), i32(p, i + 4)
        local coords, types, metas = {}, {}, {}
        local c0, t0, m0 = i + 10, i + 10 + n * 2, i + 10 + n * 3
        for k = 0, n - 1 do
            coords[k + 1] = i16(p, c0 + k * 2)
            types[k + 1] = p[t0 + k]
            metas[k + 1] = p[m0 + k]
        end
        rpos = i + 10 + n * 4
        call("multi_block_change", cx, cz, n, coords, types, metas)
        return true, id
    elseif id == 1 then
        if i + 4 > limit then return false end
        local proto = i32(p, i)
        local user, j = utf(p, i + 4, limit)
        if not user then return false end
        local pass, k = utf(p, j, limit)
        if not pass then return false end
        rpos = k
        call("login", proto, user, pass)
        return true, id
    elseif id == 2 or id == 3 or id == 255 then
        local s, j = utf(p, i, limit)
        if not s then return false end
        rpos = j
        call(id == 2 and "handshake" or id == 3 and "chat" or "kick", s)
        return true, id
    elseif id == 20 then
        if i + 4 > limit then return false end
        local name, j = utf(p, i + 4, limit)
        if not name or j + 16 > limit then return false end
        rpos = j + 16
        call("entity", id)
        call("named_entity_spawn", i32(p, i), name, i32(p, j), i32(p, j + 4), i32(p, j + 8), i8(p, j + 12),
             i8(p, j + 13), i16(p, j + 14))
        return true, id
    end
    M.error = ("unknown packet id %d at stream offset %d"):format(id, M.stats.bytes_in - (rlen - rpos))
    error(M.error)
end

-- ------------------------------------------------------------------ connection
function M.connect(host, port, user)
    M.close()
    M.host, M.port, M.user = host, port, user or "Player"
    M.state, M.error = "connecting", nil
    M.conn_out, M.conn_in = 0, 0
    buf, rpos, rlen = nil, 0, 0
    local t0 = os.clock()
    M.sock = network.tcp_connect(host, port, function(s)
        M.stats.connect_ms = (os.clock() - t0) * 1e3
        M.state = "handshake"
        pcall(function() s:set_nodelay(true) end)
        M.send_handshake(M.user)
        call("connected")
    end, function(s, err)
        M.state, M.error = "error", tostring(err)
        call("disconnected", "connect error: " .. tostring(err))
    end)
end

-- read everything available and dispatch complete packets; returns number of packets
function M.poll(max_packets)
    local s = M.sock
    if not s then return 0 end
    if M.state ~= "connecting" and M.state ~= "closed" then
        if not s:is_alive() then
            M.state = "closed"
            call("disconnected", "connection closed")
            return 0
        end
        local n = s:available()
        if n and n > 0 then
            local b = s:recv(n)
            M.stats.recv_calls = M.stats.recv_calls + 1
            if b then
                M.stats.bytes_in = M.stats.bytes_in + #b
                M.conn_in = M.conn_in + #b
                if M.perf then M.perf.count("bytes_in", #b) end
                push(b)
            end
        end
    end
    local count = 0
    while buf and rpos < rlen and (not max_packets or count < max_packets) do
        local ok, id = parse_one()
        if not ok then break end
        count = count + 1
        M.stats.packets_in = M.stats.packets_in + 1
        local k = "p" .. id  -- string keys: a sparse integer table becomes a JSON list
        M.stats.by_id[k] = (M.stats.by_id[k] or 0) + 1
    end
    if buf and rpos == rlen then rpos, rlen = 0, 0 end
    if count > M.stats.max_poll then M.stats.max_poll = count end
    if max_packets and count >= max_packets and buf and rpos < rlen then M.stats.polls_capped = M.stats.polls_capped + 1 end
    return count
end

-- F2F lockstep: bytes received on this connection so far, including what the engine's reader thread holds
function M.rx_avail()
    local s = M.sock
    local n = 0
    if s and M.state ~= "connecting" and M.state ~= "closed" then
        local ok, a = pcall(s.available, s)
        if ok and a then n = a end
    end
    return M.conn_in + n
end

function M.buffered()
    return rlen - rpos
end

function M.close()
    if M.sock then
        pcall(function() M.sock:close() end)
        M.sock = nil
    end
    if M.state ~= "idle" then M.state = "closed" end
end

function M.tick() end
function M.on_world_open() end

return M
