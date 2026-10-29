-- olife_client:serverinfo — public play (16.10, olife_friends; agents/research/OLIFE_PUBLIC_PLAY.md): a friend knows only
-- "ip:port" of the gateway. Before the login the client asks the gateway itself: TCP, the FIRST frame is
-- client.InfoRequest (instead of Hello) -> client.ServerInfo{name, gw_id, auth_port, auth_scheme, auth_pub, packs_port,
-- public, whitelist, motd} -> Disconnect 19 "server info sent". The ticket service and the pack server are then the
-- host the client dialed + those ports (the server never needs to know its external address). Nothing secret is sent;
-- auth_pub is checked against the invite fingerprint (#xxxx) or the key remembered for this address (TOFU, menu.json).
-- A gateway without InfoRequest answers Disconnect 3 (or nothing): the login falls back to what it had.
local C = require "olife_proto:client"

local M = {}
M.TIMEOUT = 4          -- s

function M.start(host, port)
    local q = {host = host, port = port, done = false, t0 = time.uptime()}
    q.fr, q.out = C.framer(), Bytearray()
    q.sock = network.tcp_connect(host, port, function(s)
        pcall(s.set_nodelay, s, true)
        C.append_frame(q.out, "InfoRequest", {proto = C.version,
            engine = table.concat({app and app.get_version and app.get_version() or 0}, ".")})
        local ok, err = pcall(s.send, s, q.out)
        q.out:clear()
        if not ok then q.done, q.kind, q.err = true, "send", tostring(err) end
        q.connected = true
    end, function(s, err)
        q.done, q.kind, q.err = true, "connect", tostring(err)
    end)
    return q
end

-- -> true when finished: q.info (ServerInfo) | q.kind = connect | closed | protocol | disconnect (q.code, q.reason)
function M.poll(q)
    if q.done then return true end
    if not q.connected then return false end
    local data = q.sock:recv(65536)
    if data == nil then
        q.done, q.kind = true, q.kind or "closed"
        return true
    end
    if #data > 0 then q.fr:feed(data) end
    while true do
        local name, m = C.read(q.fr)
        if name == nil then break end
        if name == false then
            q.done, q.kind, q.err = true, "protocol", tostring(m)
            break
        end
        if name == "ServerInfo" then
            q.info, q.done = m, true
            break
        elseif name == "Disconnect" then
            q.code, q.reason, q.done, q.kind = m.code, m.reason, true, "disconnect"
            break
        end
    end
    return q.done
end

function M.close(q)
    if q and q.sock then pcall(q.sock.close, q.sock) end
end

-- the same url with the loopback host of a server-side default replaced by the host the client dialed
local LOOP = {["localhost"] = true, ["0.0.0.0"] = true, ["::1"] = true}
local function loopback(h) return h == nil or LOOP[h] or h:match("^127%.") ~= nil end
M.loopback = loopback
function M.fix_url(url, host)
    if type(url) ~= "string" or url == "" or loopback(host) then return url end
    local pre, h, rest = url:match("^(%a+://)([^:/]+)(.*)$")
    if pre and loopback(h) then return pre .. host .. rest end
    return url
end

return M
