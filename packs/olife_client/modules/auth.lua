-- olife_client:auth — wave 4b: the account token never goes into the game socket. Before every connection the client
-- exchanges it at the auth service (HTTPS, network.request) for a short one-time ticket (tools/olife/olife_ticket.py)
-- and sends the ticket in Hello.token.
-- Transport security: VoxelCore 0.32 network.* = curl + schannel with no CA option — a self-signed / private cert works
-- only with verify_ssl = false (checked in the engine: verify on -> status 0 "SSL peer certificate ... was not OK").
-- So the request is SEALED to the auth service's x25519 key pinned in the client config (`pub`): ephemeral x25519 ->
-- HKDF-SHA256 -> ChaCha20-Poly1305 both ways (crypto lib of 0.32). An active MITM can neither read the token nor the
-- ticket. With a public CA cert in prod set verify = true as well (both layers).
local A = {}

local AAD_REQ, AAD_RESP = "olife-auth-req-v1", "olife-auth-resp-v1"
local NONCE = string.rep("\0", 12)

local function b64u(s) return (base64.encode(s):gsub("+", "-"):gsub("/", "_"):gsub("=", "")) end
local function unb64u(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    local ba = base64.decode(s .. string.rep("=", (4 - #s % 4) % 4))     -- Bytearray
    local t = {}
    for i = 1, #ba do t[i] = string.char(ba[i]) end
    return table.concat(t)
end
A.b64u, A.unb64u = b64u, unb64u

A.stats = {requests = 0, ok = 0, failed = 0, last_ms = nil, last_error = nil, sealed = nil, verify = nil}

-- cfg: {url = "https://127.0.0.1:P", token, name (nick, UX B), gateway (audience id), pub = b64url x25519 | nil,
--       verify = bool}
-- UX B (16.10, olife_menu): `name` — the nick typed in the menu. With a token the service takes the token's account
-- (the nick must be that account or empty); without a token — the nick itself (the server's whitelist decides).
-- cb(ticket | nil, err, reply); reply of a refusal carries the structured reason: reply.code (service code: auth,
-- banned, whitelist, nick_reserved, bad_name, unknown_gateway, rate, sealed_required, bad_request), reply.reason,
-- reply.http (HTTP status, 0 = no answer), reply.kind (network | http | seal | refused)
function A.fetch(cfg, cb)
    local body, k_resp
    local tok = cfg.token
    if tok == "" then tok = nil end
    local plain = json.tostring({token = tok, name = (cfg.name ~= "" and cfg.name) or nil, gateway = cfg.gateway})
    if cfg.pub and cfg.pub ~= "" then
        local spk = unb64u(cfg.pub)
        local esk, epk = crypto.x25519_keypair()
        local prk = crypto.hkdf_extract("SHA256", "olife-auth-v1", crypto.x25519(esk, spk))
        local okm = crypto.hkdf_expand("SHA256", prk, epk .. spk, 64)
        k_resp = okm:sub(33, 64)
        body = json.tostring({v = 1, epk = b64u(epk),
                              ct = b64u(crypto.chacha20_poly1305_encrypt(okm:sub(1, 32), NONCE, AAD_REQ, plain))})
    else
        body = plain
    end
    A.stats.requests = A.stats.requests + 1
    A.stats.sealed, A.stats.verify = k_resp ~= nil, cfg.verify == true
    local t0 = time.uptime()
    local function fail(err, rep, kind, status)
        A.stats.failed = A.stats.failed + 1
        A.stats.last_error = err
        rep = type(rep) == "table" and rep or {}
        rep.kind, rep.http = kind or rep.kind or "refused", status or rep.http
        A.stats.last_fail = {kind = rep.kind, http = rep.http, code = rep.code, reason = rep.reason}
        cb(nil, err, rep)
    end
    network.request(cfg.url .. "/ticket", {
        method = "POST", body = body, timeout_ms = 5000, verify_ssl = cfg.verify == true,
        headers = {"Content-Type: application/json"},
        on_response = function(r)
            A.stats.last_ms = (time.uptime() - t0) * 1000
            if not r or (r.status or 0) == 0 then
                return fail("network: " .. tostring(r and r.body), {reason = tostring(r and r.body)}, "network", 0)
            end
            local ok, rep = pcall(json.parse, r.body or "")
            if not ok or type(rep) ~= "table" then
                return fail("http " .. tostring(r.status) .. ": bad json", {reason = tostring(r.body):sub(1, 120)},
                    "http", r.status)
            end
            if k_resp and rep.ct then
                local pt, err = crypto.chacha20_poly1305_decrypt(k_resp, NONCE, AAD_RESP, unb64u(rep.ct))
                if not pt then return fail("seal: " .. tostring(err), {reason = tostring(err)}, "seal", r.status) end
                rep = json.parse(pt)
            elseif k_resp then
                return fail("http " .. tostring(r.status) .. ": " .. tostring(rep.code) .. " " .. tostring(rep.reason), rep,
                    "http", r.status)
            end
            if rep.ok and type(rep.ticket) == "string" then
                A.stats.ok = A.stats.ok + 1
                return cb(rep.ticket, nil, rep)
            end
            return fail(tostring(rep.code) .. ": " .. tostring(rep.reason), rep, "refused", r.status)
        end})
end

return A
