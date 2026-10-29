"""Olife auth tickets (wave 4b, agents/research/OLIFE_GATEWAY_SECURITY.md §6.1): short-lived, one-time, signed
tickets that replace the static account token in client.Hello.token (str<128>, schema unchanged).

Text form:  "T1." + base64url(bin) without padding  (<= 127 chars)
bin (big-endian):
  ver   u8      = 1
  exp   u32     unix seconds; the auth service issues exp = now + ttl, ttl <= 60
  nonce 12 B    CSPRNG (one-time: the gateway remembers used nonces until exp)
  gw    u32     first 4 bytes of SHA-256(gateway id): audience
  alen  u8      1..55
  acct  alen B  account name (UTF-8)
  tag   16 B    HMAC-SHA256(K_gw, b"olife-ticket-v1" + bin[:-16])[:16]
K_gw = HMAC-SHA256(master, b"olife-gw-key-v1|" + gateway id): each gateway holds only its own key (a stolen gateway key
mints tickets for that gateway only); the auth service holds the master key. Ed25519 does not fit: a 64-byte signature
is 86 base64 chars, leaving ~10 bytes for account + nonce + expiry in 128 chars.

Verification order and results (gateway, offline — no call to anything):
  malformed -> "malformed"  (Disconnect 4)    gw mismatch -> "wrong_gateway" (17)
  bad tag   -> "bad_signature" (16)           now > exp + skew or exp > now + ttl_max + skew -> "expired" (14)
  nonce already used -> "replayed" (15)       ok -> account
Stdlib only (hmac, hashlib, base64) — used by gateway_dev.py, auth_service.py, tests; Rust twin in
<olife-src>/gateway/src/ticket.rs is checked against protocol/vectors/tickets.json."""
import base64
import collections
import hashlib
import hmac
import os
import struct
import time

PREFIX = "T1."
VERSION = 1
TTL_MAX = 60
SKEW = 2
ACCOUNT_MAX = 55
TAG_LEN = 16
NONCE_LEN = 12
CODES = {"malformed": 4, "expired": 14, "replayed": 15, "bad_signature": 16, "wrong_gateway": 17}
REASONS = {"malformed": "bad ticket", "expired": "ticket expired", "replayed": "ticket replayed",
           "bad_signature": "bad ticket signature", "wrong_gateway": "ticket for another gateway"}


def gw_hash(gateway_id):
    return struct.unpack(">I", hashlib.sha256(gateway_id.encode("utf-8")).digest()[:4])[0]


def gateway_key(master, gateway_id):
    """master: bytes (32) -> K_gw (32 bytes)"""
    return hmac.new(master, b"olife-gw-key-v1|" + gateway_id.encode("utf-8"), hashlib.sha256).digest()


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def mint(key_gw, gateway_id, account, ttl=30, now=None, nonce=None):
    """-> (ticket text, exp). key_gw — the gateway's key (gateway_key(master, id))."""
    a = account.encode("utf-8")
    if not 1 <= len(a) <= ACCOUNT_MAX:
        raise ValueError("account name must be 1..%d bytes for a ticket" % ACCOUNT_MAX)
    if not 1 <= ttl <= TTL_MAX:
        raise ValueError("ttl 1..%d s" % TTL_MAX)
    exp = int(now if now is not None else time.time()) + int(ttl)
    nonce = nonce if nonce is not None else os.urandom(NONCE_LEN)
    body = struct.pack(">BI", VERSION, exp) + nonce + struct.pack(">IB", gw_hash(gateway_id), len(a)) + a
    tag = hmac.new(key_gw, b"olife-ticket-v1" + body, hashlib.sha256).digest()[:TAG_LEN]
    t = PREFIX + b64u(body + tag)
    assert len(t) <= 127
    return t, exp


def parse(text):
    """-> dict(ver, exp, nonce, gw, account, body, tag) or None (malformed)"""
    if not isinstance(text, str) or not text.startswith(PREFIX) or len(text) > 127:
        return None
    try:
        b = unb64u(text[len(PREFIX):])
    except (ValueError, TypeError):
        return None
    if len(b) < 22 + 1 + TAG_LEN:
        return None
    ver, exp = struct.unpack(">BI", b[:5])
    nonce = b[5:17]
    gw, alen = struct.unpack(">IB", b[17:22])
    if ver != VERSION or not 1 <= alen <= ACCOUNT_MAX or len(b) != 22 + alen + TAG_LEN:
        return None
    try:
        acct = b[22:22 + alen].decode("utf-8")
    except UnicodeDecodeError:
        return None
    return {"ver": ver, "exp": exp, "nonce": nonce, "gw": gw, "account": acct, "body": b[:22 + alen],
            "tag": b[22 + alen:]}


class NonceCache:
    """Used nonces until their exp (+skew). Bounded: full -> verify fails closed ("replayed" would lie, so "busy")."""

    def __init__(self, cap=1_000_000):
        self.cap = cap
        self.seen = {}
        self.order = collections.deque()

    def prune(self, now):
        while self.order and self.order[0][0] + SKEW < now:
            exp, n = self.order.popleft()
            if self.seen.get(n) == exp:
                del self.seen[n]

    def use(self, nonce, exp, now):
        """True — first use (remembered); False — replay; None — cache full"""
        self.prune(now)
        if nonce in self.seen:
            return False
        if len(self.seen) >= self.cap:
            return None
        self.seen[nonce] = exp
        self.order.append((exp, nonce))
        return True

    def __len__(self):
        return len(self.seen)


class Verifier:
    def __init__(self, key_gw, gateway_id, cache=None, ttl_max=TTL_MAX, skew=SKEW):
        self.key, self.gw_id, self.gw = key_gw, gateway_id, gw_hash(gateway_id)
        self.cache = cache if cache is not None else NonceCache()
        self.ttl_max, self.skew = ttl_max, skew
        self.counts = collections.Counter()

    def verify(self, text, now=None):
        """-> ("ok", account) | (result, None); result in CODES (+ "busy")"""
        now = time.time() if now is None else now
        p = parse(text)
        r = None
        if p is None:
            r = "malformed"
        elif p["gw"] != self.gw:
            r = "wrong_gateway"
        elif not hmac.compare_digest(hmac.new(self.key, b"olife-ticket-v1" + p["body"], hashlib.sha256)
                                     .digest()[:TAG_LEN], p["tag"]):
            r = "bad_signature"
        elif now > p["exp"] + self.skew or p["exp"] > now + self.ttl_max + self.skew:
            r = "expired"
        else:
            u = self.cache.use(p["nonce"], p["exp"], now)
            r = "ok" if u else ("replayed" if u is False else "busy")
        self.counts[r] += 1
        return (r, p["account"]) if r == "ok" else (r, None)


def load_key_file(path):
    """key file: 64 hex chars (optionally JSON {"key": hex, "gateway": id}) -> (key bytes, gateway id | None)"""
    import json
    with open(path, encoding="utf-8") as f:
        s = f.read().strip()
    if s.startswith("{"):
        d = json.loads(s)
        return bytes.fromhex(d["key"]), d.get("gateway")
    return bytes.fromhex(s), None


def write_vectors(path):
    """protocol/vectors/tickets.json: fixed master/gateway/now -> tickets + expected verify results (Rust twin)."""
    import json
    master = bytes(range(32))
    gid = "olife-gateway-test"
    k = gateway_key(master, gid)
    now = 1_790_000_000
    good, exp = mint(k, gid, "bot1", ttl=30, now=now, nonce=bytes(range(100, 112)))
    other, _ = mint(gateway_key(master, "other-gw"), "other-gw", "bot1", ttl=30, now=now, nonce=bytes(12))
    forged = good[:-2] + ("A" if good[-2] != "A" else "B") + good[-1]
    cases = [
        {"name": "good", "ticket": good, "now": now + 1, "want": "ok", "account": "bot1"},
        {"name": "replayed", "ticket": good, "now": now + 2, "want": "replayed", "after": "good"},
        {"name": "expired", "ticket": mint(k, gid, "bot2", ttl=5, now=now - 60, nonce=bytes([7] * 12))[0],
         "now": now, "want": "expired"},
        {"name": "wrong_gateway", "ticket": other, "now": now + 1, "want": "wrong_gateway"},
        {"name": "bad_signature", "ticket": forged, "now": now + 1, "want": "bad_signature"},
        {"name": "malformed", "ticket": "T1.not-base64!", "now": now, "want": "malformed"},
        {"name": "static_token", "ticket": "olife-dev", "now": now, "want": "malformed"},
        {"name": "long_account", "ticket": mint(k, gid, "a" * 55, ttl=60, now=now, nonce=bytes([9] * 12))[0],
         "now": now + 59, "want": "ok", "account": "a" * 55},
        {"name": "too_long_lifetime", "ticket": None, "now": now, "want": "expired"},
    ]
    # exp = now + 120 cannot be minted by mint() (ttl <= 60): build it by hand with a valid tag
    a = b"bot3"
    body = struct.pack(">BI", 1, now + 120) + bytes([5] * 12) + struct.pack(">IB", gw_hash(gid), len(a)) + a
    cases[-1]["ticket"] = PREFIX + b64u(body + hmac.new(k, b"olife-ticket-v1" + body, hashlib.sha256).digest()[:16])
    v = Verifier(k, gid)
    for c in cases:
        r, acct = v.verify(c["ticket"], now=c["now"])
        assert r == c["want"] and (acct == c.get("account")), (c, r, acct)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"master_hex": master.hex(), "gateway": gid, "gateway_key_hex": k.hex(),
                   "gw_hash": gw_hash(gid), "ttl_max": TTL_MAX, "skew": SKEW,
                   "note": "verify cases in order with ONE verifier (replayed follows good)", "cases": cases},
                  f, indent=1)
    return cases


def selftest():
    m = os.urandom(32)
    k = gateway_key(m, "gw-a")
    t, exp = mint(k, "gw-a", "dev", ttl=60)
    assert len(t) <= 127, len(t)
    v = Verifier(k, "gw-a")
    assert v.verify(t) == ("ok", "dev")
    assert v.verify(t)[0] == "replayed"
    t2, _ = mint(k, "gw-a", "x" * 55, ttl=60)
    assert len(t2) <= 127 and v.verify(t2) == ("ok", "x" * 55), len(t2)
    assert v.verify(mint(k, "gw-a", "dev", ttl=1, now=time.time() - 10)[0])[0] == "expired"
    assert Verifier(gateway_key(m, "gw-b"), "gw-b").verify(mint(k, "gw-a", "dev")[0])[0] == "wrong_gateway"
    assert Verifier(gateway_key(m, "gw-b"), "gw-a").verify(mint(k, "gw-a", "dev")[0])[0] == "bad_signature"
    c = NonceCache(cap=2)
    assert c.use(b"a", 10, 0) and c.use(b"b", 10, 0) and c.use(b"c", 10, 0) is None
    assert c.use(b"c", 20, 13) is True and len(c) == 1           # a, b pruned after exp + skew
    return len(t2)


if __name__ == "__main__":
    import sys
    n = selftest()
    if len(sys.argv) > 1 and sys.argv[1] == "--vectors":
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "protocol", "vectors", "tickets.json")
        print("vectors:", len(write_vectors(p)), "->", p)
    print("olife_ticket selftest ok (max ticket %d chars)" % n)
