-- Проба 0.32 (headless --test), волна 4b: HTTPS к самоподписанному сертификату (verify_ssl true/false), crypto
-- (x25519, hkdf, chacha20-poly1305, hmac, random) и запечатанный запрос билета к tools/olife/auth_service.py.
-- Вход: user:probe_https.json {url, pub, token, gateway}. Итог: строки "[probe]" и user:export/probe_https.json.
local function p(...) print("[probe]", ...) end
local cfg = json.parse(file.read("user:probe_https.json"))
local out = {}

local function wait(pred, ms)            -- app.sleep ticks the engine loop (network events) for real time
    for _ = 1, math.ceil(ms / 20) do
        if pred() then return true end
        app.sleep(0.02)
    end
    return pred()
end

-- crypto
local f = crypto.features()
out.features = f
p("features", json.tostring(f))
local esk, epk = crypto.x25519_keypair()
p("x25519 sk", #esk, "pk", #epk, type(esk))
out.x25519 = {sk = #esk, pk = #epk}
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
p("hmac", hex(crypto.hmac("SHA256", "key", "data")))   -- 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0
out.hmac_ok = hex(crypto.hmac("SHA256", "key", "data")) ==
    "5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0"

-- base64url
local function b64u(s) return (base64.encode(s):gsub("+", "-"):gsub("/", "_"):gsub("=", "")) end
local function unb64u(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    s = s .. string.rep("=", (4 - #s % 4) % 4)
    local ba = base64.decode(s)          -- Bytearray
    local t = {}
    for i = 1, #ba do t[i] = string.char(ba[i]) end
    return table.concat(t)
end
p("base64", type(base64.decode("AAEC")), unb64u("AAEC") == "\0\1\2", base64.encode("\0\1\2"),
  pcall(base64.encode_urlsafe, "\251\255"))

-- 1) verify_ssl = true (default) against the self-signed cert
local r1
network.request(cfg.url .. "/health", {method = "GET", timeout_ms = 5000, on_response = function(r) r1 = r end})
wait(function() return r1 ~= nil end, 8000)
p("verify_ssl=true", r1 and r1.status, r1 and tostring(r1.body):sub(1, 80))
out.verify_true = r1 and {status = r1.status, body = tostring(r1.body):sub(1, 200)} or "no response"

-- 2) verify_ssl = false
local r2
network.request(cfg.url .. "/health", {method = "GET", timeout_ms = 5000, verify_ssl = false,
                                       on_response = function(r) r2 = r end})
wait(function() return r2 ~= nil end, 8000)
p("verify_ssl=false", r2 and r2.status, r2 and tostring(r2.body):sub(1, 120))
out.verify_false = r2 and {status = r2.status, body = tostring(r2.body):sub(1, 200)} or "no response"

-- 3) network.get (simplified, verify on): onfailure code
local g1, g1e
network.get(cfg.url .. "/health", function(s) g1 = s end, function(code, msg) g1e = {code, msg} end)
wait(function() return g1 ~= nil or g1e ~= nil end, 8000)
p("network.get", g1 and "ok" or "fail", g1e and json.tostring(g1e))
out.get_verify = g1 and "ok" or (g1e and {code = g1e[1], msg = tostring(g1e[2])} or "no response")

-- 4) sealed ticket request
local spk = unb64u(cfg.pub)
local shared = crypto.x25519(esk, spk)
local prk = crypto.hkdf_extract("SHA256", "olife-auth-v1", shared)
local okm = crypto.hkdf_expand("SHA256", prk, epk .. spk, 64)
local k_req, k_resp = okm:sub(1, 32), okm:sub(33, 64)
local nonce = string.rep("\0", 12)
local t0 = os.clock()
local ct = crypto.chacha20_poly1305_encrypt(k_req, nonce, "olife-auth-req-v1",
    json.tostring({token = cfg.token, gateway = cfg.gateway}))
local body = json.tostring({v = 1, epk = b64u(epk), ct = b64u(ct)})
local seal_ms = (os.clock() - t0) * 1000
local r3
network.request(cfg.url .. "/ticket", {method = "POST", body = body, timeout_ms = 5000, verify_ssl = false,
    headers = {"Content-Type: application/json"}, on_response = function(r) r3 = r end})
wait(function() return r3 ~= nil end, 8000)
local rt0 = os.clock()
local rep
if r3 and r3.status == 200 then
    local outer = json.parse(r3.body)
    local pt, err = crypto.chacha20_poly1305_decrypt(k_resp, nonce, "olife-auth-resp-v1", unb64u(outer.ct))
    rep = pt and json.parse(pt) or {err = err}
end
p("sealed ticket", r3 and r3.status, rep and json.tostring(rep), "seal_ms", seal_ms,
  "open_ms", (os.clock() - rt0) * 1000)
out.sealed = {status = r3 and r3.status, reply = rep, seal_ms = seal_ms}
-- tamper: flip a byte of ct -> server must refuse (400)
local bad = ct:sub(1, 5) .. string.char((ct:byte(6) + 1) % 256) .. ct:sub(7)
local r4
network.request(cfg.url .. "/ticket", {method = "POST", verify_ssl = false, timeout_ms = 5000,
    body = json.tostring({v = 1, epk = b64u(epk), ct = b64u(bad)}), headers = {"Content-Type: application/json"},
    on_response = function(r) r4 = r end})
wait(function() return r4 ~= nil end, 8000)
p("tampered", r4 and r4.status, r4 and r4.body)
out.tampered = r4 and {status = r4.status, body = r4.body}
file.write("user:export/probe_https.json", json.tostring(out, true))
p("done")
