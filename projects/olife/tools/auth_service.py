"""Olife auth service (wave 4b): exchanges a long-lived account token for a short-lived one-time ticket
(tools/olife/olife_ticket.py) that the client puts into client.Hello.token. A separate process by design (dev: one
lab lease, kind `auth`); the supervisor stays the source of accounts and bans (GET <auth-url>/auth?token_sha=...).

  python auth_service.py --listen <port> [--f2f <ctl port>] --master <key file> [--tls 1] [--cert c.pem --key k.pem]
         [--seal-key x25519.key] [--auth-url http://127.0.0.1:<lab>/sup] [--tokens gateway_tokens.json]
         [--bans gateway_bans.json] [--gateways gw1,gw2] [--ttl 30] [--require-sealed 0] [--dir <state dir>]
         [--public 1]   (olife_friends 16.10: the HTTPS port binds 0.0.0.0 — friends over LAN/Internet; the control
                         port stays 127.0.0.1. The dev cert stays self-signed: trust = the seal to the pinned key)

HTTP(S) API (TLS 1.2+ with --tls 1; a self-signed cert is generated into --dir when --cert is not given):
  GET  /health                 {ok, tls, gateways, sealed_pub}
  GET  /pubkey                 {x25519: b64url}  (pinned in the client pack; never trust it from this endpoint in prod)
  POST /ticket  plain   {"token": "...", "gateway": "<gw id>"}  |  {"name": "<nick>", "gateway": "<gw id>"} (UX B)
                sealed  {"v": 1, "epk": b64url(32), "ct": b64url(ChaCha20-Poly1305(k_req, 0^12, aad, json))}
       -> {"ok": true, "ticket": "T1....", "exp": <unix s>, "ttl": s, "account": ...}
        | {"ok": false, "code": "auth"|"banned"|"unknown_gateway"|"bad_request"|"sealed_required"|"rate"|
                             "whitelist"|"nick_reserved"|"bad_name"|
                             antifraud 16.10: "ip_banned"|"rate_ip"|"rate_net"|"sessions_ip"|"multi_account"|
                             "nick_in_use"|"nick_similar", "reason", "until"?}
       Antifraud (16.10, olife_antifraud; agents/research/OLIFE_ANTIFRAUD.md): the supervisor decides by the client IP —
       token logins ask POST <daemon>/call/olife.ip_check {ip, gateway} (IP/CIDR ban, ticket rates per IP and /24,
       sessions per IP), nick logins get the same plus the nick rules inside olife.auth_name. Daemon down -> the bans
       file (addresses and CIDR) only.
       UX B (16.10, olife_menu): login by NICK without a token (the client's main menu: ip:port + nick). The supervisor
       decides (plugin olife: POST <daemon>/call/olife.auth_name {name, ip, gateway}): the nick's syntax, an account
       that has a token cannot be taken by a nick (nick_reserved), bans (banned), the server's whitelist — scope = the
       gateway id of the ticket (whitelist). A token, when given, wins (the nick is ignored). Without a supervisor
       (--auth-url empty) a nick login is refused (code auth).
       sealed request -> sealed reply {"v": 1, "ct": ...} (k_resp). Keys: shared = X25519(esk, spk);
       okm = HKDF-SHA256(salt="olife-auth-v1", ikm=shared, info=epk||spk, 64); k_req = okm[:32], k_resp = okm[32:];
       aad "olife-auth-req-v1" / "olife-auth-resp-v1". Why: VoxelCore 0.32 network.* uses curl+schannel without a CA
       option, so a self-signed (or any non-public) cert only works with verify_ssl=false — the seal to a key pinned in
       the pack makes an active MITM useless even then (agents/research/OLIFE_GATEWAY_SECURITY.md §7).
Control port (lab F2F protocol): hello, metrics, mint {account, gateway, ttl, age_s} (lab negative tests only: issue a
ticket as if `age_s` seconds ago), quit.
Failed token checks per IP: 20/min -> HTTP 429 for 30 s."""
import base64
import collections
import hashlib
import http.server
import json
import os
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "lab", "projects", "olife"))
import olife_ticket as T  # noqa: E402

AAD_REQ, AAD_RESP = b"olife-auth-req-v1", b"olife-auth-resp-v1"
FAIL_RATE, FAIL_WINDOW, FAIL_BAN = 20, 60.0, 30.0


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def ip_in_list(ip, nets):
    """antifraud: address in a list of addresses / CIDR -> the matching entry | None"""
    import ipaddress
    try:
        a = ipaddress.ip_address(str(ip).split("%")[0])
        if a.version == 6 and a.ipv4_mapped:
            a = a.ipv4_mapped
    except ValueError:
        return None
    for n in nets:
        try:
            net = ipaddress.ip_network(str(n), strict=False)
        except ValueError:
            continue
        if net.version == a.version and a in net:
            return str(n)
    return None


# ---------------------------------------------------------------------------------------------- keys / cert
def load_or_make_master(path):
    if os.path.exists(path):
        k, _ = T.load_key_file(path)
        return k
    k = os.urandom(32)
    with open(path, "w", encoding="utf-8") as f:
        f.write(k.hex())
    return k


def load_or_make_x25519(path):
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization as S
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            sk = X25519PrivateKey.from_private_bytes(bytes.fromhex(f.read().strip()))
    else:
        sk = X25519PrivateKey.generate()
        if path:
            with open(path, "w", encoding="utf-8") as f:
                f.write(sk.private_bytes(S.Encoding.Raw, S.PrivateFormat.Raw, S.NoEncryption()).hex())
    pk = sk.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw)
    return sk, pk


def make_self_signed(cert_path, key_path, names=("localhost",), ips=("127.0.0.1",), days=30):
    """dev only: ECDSA P-256 self-signed cert with SAN (localhost, 127.0.0.1)"""
    import datetime
    import ipaddress
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization as S
    from cryptography.hazmat.primitives.asymmetric import ec
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "olife-auth-dev")])
    now = datetime.datetime.now(datetime.timezone.utc)
    san = [x509.DNSName(n) for n in names] + [x509.IPAddress(ipaddress.ip_address(i)) for i in ips]
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(days=days))
            .add_extension(x509.SubjectAlternativeName(san), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256()))
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(S.Encoding.PEM, S.PrivateFormat.PKCS8, S.NoEncryption()))
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(S.Encoding.PEM))
    return hashlib.sha256(cert.public_bytes(S.Encoding.DER)).hexdigest()


def seal_keys(shared, epk, spk):
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    okm = HKDF(algorithm=hashes.SHA256(), length=64, salt=b"olife-auth-v1", info=epk + spk).derive(shared)
    return okm[:32], okm[32:]


# ---------------------------------------------------------------------------------------------- service
class Auth:
    def __init__(self, a):
        self.a = a
        self.dir = a.get("dir") or os.getcwd()
        os.makedirs(self.dir, exist_ok=True)
        self.master = load_or_make_master(a.get("master") or os.path.join(self.dir, "auth_master.key"))
        self.sk, self.pk = load_or_make_x25519(a.get("seal-key") or os.path.join(self.dir, "auth_seal_x25519.key"))
        self.ttl = int(a.get("ttl", 30))
        self.gateways = set(x for x in (a.get("gateways") or "").split(",") if x)
        self.auth_url = (a.get("auth-url") or "").rstrip("/")
        self.tokens = self._json(a.get("tokens") or os.path.join(HERE, "gateway_tokens.json")).get("tokens", {})
        self.bans_path = a.get("bans") or os.path.join(HERE, "gateway_bans.json")
        self.require_sealed = a.get("require-sealed", "0") not in ("0", "", "false")
        self.lock = threading.Lock()
        self.fails = collections.defaultdict(collections.deque)    # ip -> fail times
        self.blocked = {}
        self.m = collections.Counter()
        self.lat = collections.deque(maxlen=2000)
        self.events = collections.deque(maxlen=50)
        self.tls = False
        self.cert_sha = None

    @staticmethod
    def _json(p):
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def event(self, kind, **kw):
        self.events.append(dict(kw, t=round(time.time(), 3), kind=kind))

    def check_token(self, token, ip, gateway):
        """-> (account, None) | (None, (code, reason)). Supervisor DB first; daemon down -> static files."""
        if self.auth_url:
            try:
                q = urllib.parse.urlencode({"token_sha": hashlib.sha256(token.encode("utf-8")).hexdigest(),
                                            "ip": ip, "gateway": "auth:" + gateway})
                with urllib.request.urlopen("%s/auth?%s" % (self.auth_url, q), timeout=2.0) as r:
                    d = json.loads(r.read().decode("utf-8"))
                if d.get("ok"):
                    return d["account"], None
                return None, (d.get("code") or "auth", d.get("reason") or "bad token")
            except Exception as exc:
                self.m["sup_fallback"] += 1
                self.event("auth_fallback", error="%s: %s" % (type(exc).__name__, exc))
        acct = self.tokens.get(token)
        if acct is None:
            return None, ("auth", "bad token")
        bans = self._json(self.bans_path)
        if acct in (bans.get("accounts") or []) or ip_in_list(ip, bans.get("ips") or []):
            return None, ("banned", "banned")
        return acct, None

    def check_name(self, name, ip, gateway):
        """UX B: nick login -> (account, None) | (None, (code, reason)); the supervisor DB of the lab decides."""
        if not self.auth_url:
            return None, ("auth", "login by nick needs the supervisor (auth service without --auth-url)")
        base = self.auth_url[:-4] if self.auth_url.endswith("/sup") else self.auth_url
        body = json.dumps({"args": {"name": name, "ip": ip, "gateway": gateway}, "owner": "olife-auth"}).encode()
        try:
            req = urllib.request.Request(base + "/call/olife.auth_name", data=body, method="POST",
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3.0) as r:
                d = json.loads(r.read().decode("utf-8"))
        except Exception as exc:
            self.m["name_check_error"] += 1
            self.event("name_check_error", error="%s: %s" % (type(exc).__name__, exc))
            return None, ("auth", "supervisor unavailable for the nick check")
        res = d.get("result") if isinstance(d, dict) else None
        if not d.get("ok") or not isinstance(res, dict):
            return None, ("auth", "nick check failed: %s" % str(d.get("error") or d.get("message"))[:120])
        if res.get("ok"):
            return res["account"], None
        return None, (res.get("code") or "auth", res.get("reason") or "refused", res.get("until"))

    def _post(self, feature, args, timeout=3.0):
        base = self.auth_url[:-4] if self.auth_url.endswith("/sup") else self.auth_url
        body = json.dumps({"args": args, "owner": "olife-auth"}).encode()
        req = urllib.request.Request(base + "/call/" + feature, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    def check_ip(self, ip, gateway):
        """antifraud: -> None | (code, reason, until). Supervisor (olife.ip_check); daemon down -> the bans file"""
        if self.auth_url:
            try:
                d = self._post("olife.ip_check", {"ip": ip, "gateway": gateway})
                res = d.get("result") if isinstance(d, dict) else None
                if d.get("ok") and isinstance(res, dict):
                    if res.get("ok"):
                        return None
                    self.m["ip_" + str(res.get("code"))] += 1
                    return res.get("code") or "ip_banned", res.get("reason") or "refused", res.get("until")
            except Exception as exc:
                self.m["ip_check_error"] += 1
                self.event("ip_check_error", error="%s: %s" % (type(exc).__name__, exc))
        net = ip_in_list(ip, (self._json(self.bans_path).get("ips") or []))
        if net:
            return "ip_banned", "banned by IP %s (bans file)" % net, None
        return None

    def rate_blocked(self, ip):
        with self.lock:
            return self.blocked.get(ip, 0) > time.time()

    def note_fail(self, ip):
        t = time.time()
        with self.lock:
            q = self.fails[ip]
            q.append(t)
            while q and q[0] < t - FAIL_WINDOW:
                q.popleft()
            if len(q) >= FAIL_RATE:
                self.blocked[ip] = t + FAIL_BAN
                q.clear()
                self.event("ip_blocked", ip=ip)

    def issue(self, req, ip):
        token, gateway, name = req.get("token"), req.get("gateway"), req.get("name")
        by_name = not token and isinstance(name, str) and name != ""
        if not isinstance(gateway, str) or not gateway or (not by_name and (not isinstance(token, str) or not token)):
            return {"ok": False, "code": "bad_request", "reason": "token (or name) and gateway required"}
        if self.gateways and gateway not in self.gateways:
            return {"ok": False, "code": "unknown_gateway", "reason": "unknown gateway"}
        if not by_name:                       # antifraud: nick logins get the IP check inside olife.auth_name
            ipr = self.check_ip(ip, gateway)
            if ipr:
                self.event("refused", code=ipr[0], gateway=gateway, ip=ip)
                rep = {"ok": False, "code": ipr[0], "reason": ipr[1]}
                if ipr[2]:
                    rep["until"] = ipr[2]
                return rep
        if by_name:
            acct, err = self.check_name(name, ip, gateway)
            self.m["by_name_" + ("ok" if not err else err[0])] += 1
        else:
            acct, err = self.check_token(token, ip, gateway)
        if err:
            if not by_name or err[0] in ("auth", "bad_name"):   # tokens as before; nicks: only guessing counts
                self.note_fail(ip)
            self.event("refused", code=err[0], name=name if by_name else None, gateway=gateway, ip=ip)
            rep = {"ok": False, "code": err[0], "reason": err[1]}
            if len(err) > 2 and err[2]:
                rep["until"] = err[2]
            return rep
        try:
            ticket, exp = T.mint(T.gateway_key(self.master, gateway), gateway, acct, ttl=self.ttl)
        except ValueError as exc:
            return {"ok": False, "code": "bad_request", "reason": str(exc)}
        self.event("ticket", account=acct, gateway=gateway, ip=ip, exp=exp)
        return {"ok": True, "ticket": ticket, "exp": exp, "ttl": self.ttl, "account": acct}

    def handle_ticket(self, body, ip):
        """-> (http status, reply dict)"""
        t0 = time.perf_counter()
        if self.rate_blocked(ip):
            self.m["rate"] += 1
            return 429, {"ok": False, "code": "rate", "reason": "too many failed attempts"}
        try:
            req = json.loads(body.decode("utf-8"))
            if not isinstance(req, dict):
                raise ValueError("object expected")
        except (ValueError, UnicodeDecodeError) as exc:
            self.m["bad_request"] += 1
            return 400, {"ok": False, "code": "bad_request", "reason": "bad json: %s" % exc}
        sealed = "epk" in req
        if sealed:
            from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
            from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
            try:
                epk = unb64u(req["epk"])
                shared = self.sk.exchange(X25519PublicKey.from_public_bytes(epk))
                k_req, k_resp = seal_keys(shared, epk, self.pk)
                inner = json.loads(ChaCha20Poly1305(k_req).decrypt(bytes(12), unb64u(req["ct"]), AAD_REQ))
            except Exception as exc:
                self.m["seal_bad"] += 1
                self.note_fail(ip)
                return 400, {"ok": False, "code": "bad_request", "reason": "seal: %s" % type(exc).__name__}
            rep = self.issue(inner, ip)
            self.m["sealed_" + ("ok" if rep.get("ok") else rep.get("code", "err"))] += 1
            self.lat.append((time.perf_counter() - t0) * 1000)
            ct = ChaCha20Poly1305(k_resp).encrypt(bytes(12), json.dumps(rep).encode("utf-8"), AAD_RESP)
            return 200, {"v": 1, "ct": b64u(ct)}
        if self.require_sealed:
            self.m["sealed_required"] += 1
            return 400, {"ok": False, "code": "sealed_required", "reason": "send the token sealed to the pinned key"}
        rep = self.issue(req, ip)
        self.m["plain_" + ("ok" if rep.get("ok") else rep.get("code", "err"))] += 1
        self.lat.append((time.perf_counter() - t0) * 1000)
        return 200, rep

    def metrics(self, args=None):
        lat = sorted(self.lat)
        q = (lambda p: round(lat[min(len(lat) - 1, int(p * (len(lat) - 1) + 0.5))], 3)) if lat else (lambda p: None)
        return {"counts": dict(self.m), "issue_ms": {"n": len(lat), "p50": q(0.5), "p95": q(0.95),
                                                     "max": lat[-1] if lat else None},
                "tls": self.tls, "cert_sha256": self.cert_sha, "ttl": self.ttl, "gateways": sorted(self.gateways),
                "sealed_pub": b64u(self.pk), "require_sealed": self.require_sealed,
                "auth": "supervisor" if self.auth_url else "files", "events": list(self.events)[-20:]}

    def ctl_mint(self, args):
        """lab negative tests: a ticket as if issued age_s seconds ago (expired ones), for any gateway id"""
        gw = args["gateway"]
        t, exp = T.mint(T.gateway_key(self.master, gw), gw, args.get("account", "dev"),
                        ttl=int(args.get("ttl", self.ttl)), now=time.time() - float(args.get("age_s", 0)))
        self.m["ctl_mint"] += 1
        return {"ticket": t, "exp": exp}


def serve(auth, port, tls, cert, key, host="127.0.0.1"):
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def reply(self, code, obj):
            data = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            p = self.path.split("?", 1)[0]
            if p == "/health":
                return self.reply(200, {"ok": True, "tls": auth.tls, "gateways": sorted(auth.gateways),
                                        "sealed_pub": b64u(auth.pk)})
            if p == "/pubkey":
                return self.reply(200, {"x25519": b64u(auth.pk)})
            self.reply(404, {"ok": False, "code": "not_found"})

        def do_POST(self):
            if self.path.split("?", 1)[0] != "/ticket":
                return self.reply(404, {"ok": False, "code": "not_found"})
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > 8192:
                return self.reply(400, {"ok": False, "code": "bad_request", "reason": "body size"})
            code, rep = auth.handle_ticket(self.rfile.read(n), self.client_address[0])
            self.reply(code, rep)

    srv = http.server.ThreadingHTTPServer((host, int(port)), H)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# ---------------------------------------------------------------------------------------------- client (tests, bots)
def client_ticket(url, token, gateway, sealed_pub=None, verify=False, timeout=5.0):
    """POST <url>/ticket (plain, or sealed to sealed_pub b64url) -> reply dict (+ "_ms"). verify=False: dev cert."""
    body = {"token": token, "gateway": gateway}
    keys = None
    if sealed_pub:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
        from cryptography.hazmat.primitives import serialization as S
        spk = unb64u(sealed_pub)
        esk = X25519PrivateKey.generate()
        epk = esk.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw)
        k_req, k_resp = seal_keys(esk.exchange(X25519PublicKey.from_public_bytes(spk)), epk, spk)
        body = {"v": 1, "epk": b64u(epk),
                "ct": b64u(ChaCha20Poly1305(k_req).encrypt(bytes(12), json.dumps(body).encode(), AAD_REQ))}
        keys = k_resp
    ctx = None
    if url.startswith("https:"):
        ctx = ssl.create_default_context()
        if not verify:
            ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    req = urllib.request.Request(url.rstrip("/") + "/ticket", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            rep = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        rep = json.loads(e.read().decode() or "{}")
        rep.setdefault("http", e.code)
    if keys and "ct" in rep:
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
        rep = json.loads(ChaCha20Poly1305(keys).decrypt(bytes(12), unb64u(rep["ct"]), AAD_RESP))
        rep["_sealed"] = True
    rep["_ms"] = round((time.perf_counter() - t0) * 1000, 2)
    return rep


def main():
    import ctlport
    a = ctlport.argmap(sys.argv[1:])
    auth = Auth(a)
    tls = a.get("tls", "1") not in ("0", "false", "")
    cert, key = a.get("cert"), a.get("key")
    if tls:
        if not cert:
            cert, key = os.path.join(auth.dir, "auth_cert.pem"), os.path.join(auth.dir, "auth_key.pem")
            if not (os.path.exists(cert) and os.path.exists(key)):
                make_self_signed(cert, key)
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization as S
        with open(cert, "rb") as f:
            auth.cert_sha = hashlib.sha256(x509.load_pem_x509_certificate(f.read()).public_bytes(S.Encoding.DER)
                                           ).hexdigest()
    auth.tls = tls
    if a.get("f2f"):
        ctlport.serve(a["f2f"], {"metrics": auth.metrics, "mint": auth.ctl_mint}, "olife-auth")
    host = "0.0.0.0" if str(a.get("public") or "") not in ("", "0", "false") else "127.0.0.1"
    serve(auth, a["listen"], tls, cert, key, host)
    print("[olife_auth] ready host=%s listen=%s tls=%s sealed_pub=%s cert_sha256=%s auth=%s ttl=%d" % (
        host, a["listen"], int(tls), b64u(auth.pk), (auth.cert_sha or "-")[:16], "supervisor" if auth.auth_url else "files",
        auth.ttl), flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
