-- olife_world:net — the world's side of the internal protocol (gateway <-> world, OLIFE_ARCHITECTURE §1/§4).
-- One TCP listener on localhost (network.tcp_open); each gateway is ONE connection multiplexing its sessions
-- (internal.Data{session, type, payload}). Incoming: at most `max_frames` frames per tick over all gateways
-- (the rest waits in the framer); every frame goes to a ring journal (tick, gateway, session, type, size) BEFORE
-- decoding, so the last 256 frames are known after a crash. Outgoing: frames are appended to a per-gateway
-- Bytearray during the tick and sent with one socket:send in flush() (phase "send").
local I = require "olife_proto:internal"
local C = require "olife_proto:client"
local U = require "olife_proto:util"
local PF = require "olife_world:prof"   -- wave 5p profiler

local M = {}
M.gateways = {}          -- id -> gw
M.journal = U.ring(256)
M.stats = {frames_in = 0, bytes_in = 0, bytes_out = 0, frames_out = 0, dropped_gateways = 0, bad_frames = 0,
           deferred = 0}
local server_sock
local next_gw = 0
local cfg
local handlers           -- {hello(gw, m), attach(gw, m), detach(gw, m), data(gw, session, type, payload), lost(gw, why)}

function M.open(config, h)
    cfg, handlers = config, h
    server_sock = network.tcp_open(cfg.port, function(sock)
        local addr, port = sock:get_address()
        -- olife_friends (16.10): network.tcp_open of 0.32 has no host argument — the listener is on ALL interfaces.
        -- Gateways run on this machine: a peer that is not loopback is closed at once (the internal contract trusts
        -- the gateway: Attach{account, perms}); M.stats.refused counts them (agents/research/OLIFE_PUBLIC_PLAY.md)
        if not tostring(addr or ""):match("^127%.") and tostring(addr) ~= "::1" then
            M.stats.refused = (M.stats.refused or 0) + 1
            print(string.format("[olife_world] refused non-loopback gateway connection from %s:%s", tostring(addr),
                tostring(port)))
            pcall(sock.close, sock)
            return
        end
        next_gw = next_gw + 1
        local ok_nd = pcall(sock.set_nodelay, sock, true)
        local gw = {id = next_gw, sock = sock, fr = I.framer(), out = Bytearray(), hello = false, addr = addr,
                    port = port, frames = 0, bytes_in = 0, bytes_out = 0, sessions = {}, nodelay = ok_nd}
        M.gateways[gw.id] = gw
        print(string.format("[olife_world] gateway #%d connected from %s:%s", gw.id, tostring(addr), tostring(port)))
    end)
    return server_sock
end

function M.close_gateway(gw, why)
    if gw.closed then return end
    gw.closed = true
    M.stats.dropped_gateways = M.stats.dropped_gateways + 1
    print(string.format("[olife_world] gateway #%d dropped: %s", gw.id, why))
    pcall(function()
        if #gw.out > 0 then gw.sock:send(gw.out) end
        gw.sock:close()
    end)
    M.gateways[gw.id] = nil
    handlers.lost(gw, why)
end

-- session id of a Data/Attach/Detach frame without decoding (journal before parsing)
local function peek_session(fr, id, s, e)
    if (id == 3 or id == 4 or id == 5) and e - s >= 3 then
        local b = fr.buf
        return ((b[s] * 256 + b[s + 1]) * 256 + b[s + 2]) * 256 + b[s + 3]
    end
    return nil
end

-- phase "incoming": read sockets, decode at most max_frames frames; returns frames handled
function M.poll(tick, max_frames)
    local handled = 0
    local pt = PF.on and PF.now()
    for _, gw in pairs(M.gateways) do
        if not gw.closed then
            local data = gw.sock:recv(1048576)
            if data == nil then
                M.close_gateway(gw, "socket closed")
            else
                if #data > 0 then
                    gw.fr:feed(data)
                    gw.bytes_in = gw.bytes_in + #data
                    M.stats.bytes_in = M.stats.bytes_in + #data
                end
            end
        end
    end
    if pt then PF.add("in_recv", PF.now() - pt) end
    for _, gw in pairs(M.gateways) do
        while not gw.closed do
            if handled >= max_frames then
                M.stats.deferred = M.stats.deferred + 1
                return handled
            end
            local id, s, e = gw.fr:next()
            if id == nil then break end
            if id == false then
                M.stats.bad_frames = M.stats.bad_frames + 1
                M.journal:push({tick = tick, gw = gw.id, type = -1, size = 0, err = s})
                M.close_gateway(gw, "bad frame: " .. tostring(s))
                break
            end
            handled = handled + 1
            if pt then PF.inc("frames") end
            gw.frames = gw.frames + 1
            M.stats.frames_in = M.stats.frames_in + 1
            local rec = {tick = tick, gw = gw.id, session = peek_session(gw.fr, id, s, e), type = id, size = e - s + 1,
                         ms = U.now_ms()}
            if id == 5 and e - s >= 5 then          -- Data: client-contract message type right after the session
                rec.ctype = gw.fr.buf[s + 4] * 256 + gw.fr.buf[s + 5]
            end
            M.journal:push(rec)
            local ok, m = pcall(I.decode_body, id, gw.fr.buf, s, e)
            if not ok then
                rec.err = tostring(m)
                M.stats.bad_frames = M.stats.bad_frames + 1
                M.close_gateway(gw, "bad body: " .. tostring(m))
                break
            end
            if not gw.hello then
                if id ~= I.ids.GatewayHello then
                    M.close_gateway(gw, "first frame is not GatewayHello")
                    break
                end
                if m.proto ~= I.version or m.client_proto ~= C.version then
                    M.close_gateway(gw, "protocol mismatch " .. m.proto .. "/" .. m.client_proto)
                    break
                end
                if cfg.secret ~= "" and m.secret ~= cfg.secret then
                    M.close_gateway(gw, "bad secret")
                    break
                end
                gw.hello = true
                gw.name = m.gateway
                handlers.hello(gw, m)
            elseif id == I.ids.Attach then
                handlers.attach(gw, m)
            elseif id == I.ids.Detach then
                handlers.detach(gw, m)
            elseif id == I.ids.Data then
                handlers.data(gw, m.session, m.type, m.payload)
            elseif id == I.ids.Ping then
                M.send(gw, "Pong", {seq = m.seq, ms = m.ms})
            elseif id == I.ids.Pong then
                gw.rtt_ms = U.now_ms() - m.ms
            else
                M.close_gateway(gw, "unexpected " .. tostring(I.names[id]))
                break
            end
        end
    end
    return handled
end

function M.send(gw, name, msg)
    if gw.closed then return end
    I.append_frame(gw.out, name, msg)
    M.stats.frames_out = M.stats.frames_out + 1
end

-- one client-contract message to one session of a gateway
function M.send_client(gw, session, name, msg)
    if gw.closed then return 0 end
    local body = C.body(name, msg)
    I.append_frame(gw.out, "Data", {session = session, type = C.ids[name], payload = body})
    M.stats.frames_out = M.stats.frames_out + 1
    return #body
end

-- the same client message to many sessions: one Multicast frame per gateway
function M.multicast(by_gw, name, msg)
    local body
    for gid, list in pairs(by_gw) do
        local gw = M.gateways[gid]
        if gw and not gw.closed and #list > 0 then
            body = body or C.body(name, msg)
            I.append_frame(gw.out, "Multicast", {sessions = list, type = C.ids[name], payload = body})
            M.stats.frames_out = M.stats.frames_out + 1
        end
    end
    return body and #body or 0
end

-- phase "send"
function M.flush()
    for _, gw in pairs(M.gateways) do
        if not gw.closed and #gw.out > 0 then
            local n = #gw.out
            local ok, err = pcall(gw.sock.send, gw.sock, gw.out)
            if not ok then
                M.close_gateway(gw, "send failed: " .. tostring(err))
            else
                gw.bytes_out = gw.bytes_out + n
                M.stats.bytes_out = M.stats.bytes_out + n
                gw.out:clear()
            end
        end
    end
end

function M.count()
    local n = 0
    for _ in pairs(M.gateways) do n = n + 1 end
    return n
end

function M.shutdown()
    for _, gw in pairs(M.gateways) do
        pcall(function() gw.sock:close() end)
    end
    if server_sock then pcall(function() server_sock:close() end) end
end

return M
