#!/usr/bin/env python3
"""End-to-end check of wave 4b features against a running gateway build + the fake world (no engine, no lab):
tickets in Hello.token (olife_ticket.py mints them) and pack hot reload (PacksChanged after Welcome and on a manifest
change, the packs HTTP server). Works for both gateways (same flags):

  python3 tools/ticket_packs_check.py [--gw "target/release/olife-gateway"] [--vc <VoxelCore dir>] [--rounds 5]
  python3 tools/ticket_packs_check.py --gw "python3 <VC>/tools/olife/gateway_dev.py"

Everything temporary (master key, key file, manifest, pack root, logs) goes to a fresh temp dir ($TMPDIR), never the repo.
Prints one line per case and a JSON summary; exit 0 = all ok."""
import hashlib
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
a = {sys.argv[i][2:]: sys.argv[i + 1] for i in range(1, len(sys.argv) - 1) if sys.argv[i].startswith("--")}
VC = a.get("vc", "/mnt/d/Prog/VoxelCore/voxelcore-0.31.0_pre_gemini")
OL = os.path.join(VC, "tools", "olife")
sys.path.insert(0, OL)
import olife_ticket as T  # noqa: E402
from olife_proto import client as C  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

GW = shlex.split(a.get("gw", os.path.join(os.path.dirname(HERE), "target", "release", "olife-gateway")))
ROUNDS = int(a.get("rounds", 5))
SECRET = "check-secret"
GW_ID = "olife-gw-check"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_port(p, t=10.0):
    end = time.time() + t
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", p), timeout=0.5).close()
            return True
        except OSError:
            time.sleep(0.05)
    return False


class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.fr = C.framer()
        self.q = []

    def hello(self, token, name="chk"):
        self.s.sendall(C.frame("Hello", {"proto": C.VERSION, "name": name, "token": token, "engine": "check"}))

    def next(self, want, timeout=8.0):
        """-> (name, msg, t_received) of the first frame in want (KeepAlive answered); (None, None, t) on EOF/timeout"""
        end = time.time() + timeout
        while time.time() < end:
            while self.q:
                n, m, t = self.q.pop(0)
                if n in want:
                    return n, m, t
            self.s.settimeout(max(0.01, min(0.2, end - time.time())))
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return None, None, time.time()
            if not d:
                return None, None, time.time()
            t = time.time()
            self.fr.feed(d)
            while True:
                try:
                    x = self.fr.next()
                except ProtoError as e:
                    return "ProtoError", str(e), t
                if x is None:
                    break
                n = C.NAMES[x[0]]
                m = C.decode_body(*x)
                if n == "KeepAlive":
                    self.s.sendall(C.frame("KeepAliveReply", {"challenge": m["challenge"]}))
                self.q.append((n, m, t))
        return None, None, time.time()

    def close(self):
        try:
            self.s.sendall(C.frame("Bye", {"reason": "check done"}))
        except OSError:
            pass
        self.s.close()


def ctl(port, cmd, args=None):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall((json.dumps({"id": 1, "cmd": cmd, "args": args or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        d = s.recv(1 << 20)
        if not d:
            break
        buf += d
    s.close()
    r = json.loads(buf)
    return r.get("result")


def http(port, path):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=5) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def write_manifest(path, root, version):
    packs = {}
    for pk in sorted(os.listdir(root)):
        files = []
        for dp, _, fns in os.walk(os.path.join(root, pk)):
            for fn in sorted(fns):
                fp = os.path.join(dp, fn)
                rel = os.path.relpath(fp, os.path.join(root, pk)).replace(os.sep, "/")
                with open(fp, "rb") as f:
                    data = f.read()
                files.append({"path": rel, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                              "side": "server" if rel.startswith("server/") else ("both" if rel.endswith(".json") else "client")})
        packs[pk] = {"side": "both", "files": files}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"version": version, "root": root, "packs": packs}, f, indent=1)
    os.replace(tmp, path)
    return sum(1 for p in packs.values() for e in p["files"] if e["side"] in ("client", "both"))


def main():
    tmp = tempfile.mkdtemp(prefix="olife_w4b_check_")
    master = os.urandom(32)
    key = T.gateway_key(master, GW_ID)
    kf = os.path.join(tmp, "gw_key.json")
    with open(kf, "w") as f:
        json.dump({"key": key.hex(), "gateway": GW_ID}, f)
    bans = os.path.join(tmp, "bans.json")
    with open(bans, "w") as f:
        json.dump({"accounts": ["banned"], "ips": []}, f)
    root = os.path.join(tmp, "packs")
    for rel, data in [("base/scripts/a.lua", b"print('a')\n"), ("base/pack.json", b"{}"),
                      ("base/server/s.lua", b"-- server only\n"), ("extra/tex/b.png", os.urandom(3000))]:
        os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
        with open(os.path.join(root, rel), "wb") as f:
            f.write(data)
    man = os.path.join(tmp, "manifest.json")
    nfiles = write_manifest(man, root, "m1")

    wp, gp, cp, hp = free_port(), free_port(), free_port(), free_port()
    procs = []
    res = []

    def case(name, ok, **kw):
        res.append(dict(name=name, ok=bool(ok), **kw))
        print("%-34s %s %s" % (name, "ok  " if ok else "FAIL", json.dumps(kw, default=str)), flush=True)

    try:
        procs.append(subprocess.Popen([sys.executable, os.path.join(OL, "world_fake.py"), "--port", str(wp), "--secret",
                                       SECRET], stdout=open(os.path.join(tmp, "world.log"), "w"), stderr=subprocess.STDOUT))
        assert wait_port(wp), "fake world did not start"
        gwlog = open(os.path.join(tmp, "gw.log"), "w")
        procs.append(subprocess.Popen(GW + ["--listen", str(gp), "--upstream", "127.0.0.1:%d" % wp, "--secret", SECRET,
                                            "--name", "gwchk", "--tokens", os.path.join(OL, "gateway_tokens.json"),
                                            "--bans", bans, "--f2f", str(cp), "--ticket-key", kf,
                                            "--packs-manifest", man, "--packs-http", str(hp)],
                                      stdout=gwlog, stderr=subprocess.STDOUT))
        assert wait_port(gp) and wait_port(cp) and wait_port(hp), "gateway did not start (see %s)" % gwlog.name
        end = time.time() + 10
        while time.time() < end and (ctl(cp, "metrics").get("world") or {}).get("state") != "ready":
            time.sleep(0.1)
        now = time.time()

        def tick(acct="chk", **kw):
            return T.mint(key, GW_ID, acct, **kw)[0]

        def one(name, token, want_code, want_reason=None, acct_name="chk"):
            c = Client(gp)
            c.hello(token, acct_name)
            n, m, _ = c.next(("Welcome", "Disconnect"))
            c.s.close()
            got = 0 if n == "Welcome" else (m["code"] if n == "Disconnect" else n)
            reason = m.get("reason") if n == "Disconnect" else None
            case(name, got == want_code and (want_reason is None or reason == want_reason), want=want_code, got=got,
                 reason=reason)

        # ---- tickets
        good = tick(ttl=30)
        c = Client(gp)
        c.hello(good, "chk_good")
        n, m, tw = c.next(("Welcome", "Disconnect"))
        case("ticket_good_welcome", n == "Welcome", got=n, eid=m and m.get("player_eid"))
        n2, pm, tp = c.next(("PacksChanged", "Disconnect"), 3.0)
        case("packs_changed_after_welcome", n2 == "PacksChanged" and pm["version"] == "m1" and pm["files"] == nfiles
             and pm["url"] == "http://127.0.0.1:%d" % hp, got=pm, after_welcome_ms=round((tp - tw) * 1000, 2))
        one("ticket_replayed", good, 15, T.REASONS["replayed"], "chk_r")
        one("ticket_expired", tick(ttl=5, now=now - 60), 14, T.REASONS["expired"])
        one("ticket_too_long_lifetime", tick(ttl=60, now=now + 30), 14, T.REASONS["expired"])
        other = T.mint(T.gateway_key(master, "other-gw"), "other-gw", "chk")[0]
        one("ticket_wrong_gateway", other, 17, T.REASONS["wrong_gateway"])
        forged = T.mint(T.gateway_key(os.urandom(32), GW_ID), GW_ID, "chk")[0]
        one("ticket_bad_signature", forged, 16, T.REASONS["bad_signature"])
        one("ticket_malformed", "T1.not-base64!", 4, T.REASONS["malformed"])
        one("ticket_banned_account", tick("banned"), 5, "banned")
        one("static_token_mode_both", "olife-test", 0, acct_name="chk_static")
        one("static_bad_token_mode_both", "wrong", 4, "bad token")
        mt = ctl(cp, "metrics")
        tk = mt.get("tickets") or {}
        case("metrics_tickets", tk.get("ok") == 2 and tk.get("replayed") == 1 and tk.get("expired") == 2
             and tk.get("wrong_gateway") == 1 and tk.get("bad_signature") == 1 and tk.get("malformed") == 1
             and tk.get("mode") == "both" and tk.get("gw_id") == GW_ID, tickets=tk)

        # ---- packs HTTP
        st, body = http(hp, "/manifest.json")
        with open(man, "rb") as f:
            case("http_manifest_raw", st == 200 and body == f.read(), status=st, bytes=len(body))
        st, body = http(hp, "/files/base/scripts/a.lua")
        case("http_client_file", st == 200 and body == b"print('a')\n", status=st)
        st, _ = http(hp, "/files/base/server/s.lua")
        case("http_server_file_hidden", st == 404, status=st)
        st, _ = http(hp, "/files/base/../../gw_key.json")
        case("http_traversal_404", st == 404, status=st)
        st, body = http(hp, "/files/extra/tex/b.png")
        case("http_binary_file", st == 200 and len(body) == 3000, status=st)
        with open(os.path.join(root, "base", "scripts", "a.lua"), "ab") as f:
            f.write(b"-- changed after the manifest\n")
        st, _ = http(hp, "/files/base/scripts/a.lua")
        case("http_changed_409", st == 409, status=st)

        # ---- hot reload: manifest change -> PacksChanged to the session in play
        lat = []
        for i in range(ROUNDS):
            time.sleep(0.37 * (i % 3))         # spread the change over the 1 s watcher period
            nf = write_manifest(man, root, "m%d" % (i + 2))
            t0 = time.time()
            n, pm, tp = c.next(("PacksChanged", "Disconnect"), 4.0)
            ok = n == "PacksChanged" and pm["version"] == "m%d" % (i + 2) and pm["files"] == nf
            lat.append(round((tp - t0) * 1000, 1) if ok else None)
            if not ok:
                case("packs_changed_round_%d" % i, False, got=n, msg=pm)
        good_lat = [x for x in lat if x is not None]
        case("packs_changed_on_change", len(good_lat) == ROUNDS, rounds=ROUNDS, ms=lat,
             max_ms=max(good_lat) if good_lat else None)
        st, body = http(hp, "/files/base/scripts/a.lua")
        case("http_file_after_new_manifest", st == 200, status=st)
        pk = ctl(cp, "metrics").get("packs") or {}
        case("metrics_packs", pk.get("version") == ROUNDS + 1 and pk.get("manifest_version") == "m%d" % (ROUNDS + 1)
             and pk.get("files") == nfiles and pk.get("served", 0) >= 3 and pk.get("notified", 0) >= ROUNDS + 1, packs=pk)
        c.close()
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                p.kill()
    # tickets-only mode: a static token is refused with its own reason; a ticket still works
    if "skip-tickets-mode" not in a:
        procs = []
        try:
            procs.append(subprocess.Popen([sys.executable, os.path.join(OL, "world_fake.py"), "--port", str(wp),
                                           "--secret", SECRET], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT))
            assert wait_port(wp)
            procs.append(subprocess.Popen(GW + ["--listen", str(gp), "--upstream", "127.0.0.1:%d" % wp, "--secret", SECRET,
                                                "--name", "gwchk2", "--ticket-key", kf, "--auth-mode", "tickets",
                                                "--bans", bans], stdout=open(os.path.join(tmp, "gw2.log"), "w"),
                                          stderr=subprocess.STDOUT))
            assert wait_port(gp)
            time.sleep(0.5)
            for name, tok, want, reason in [("mode_tickets_static_refused", "olife-test", 4,
                                             "static tokens disabled (use a ticket)"),
                                            ("mode_tickets_ticket_ok", T.mint(key, GW_ID, "chk")[0], 0, None)]:
                cl = Client(gp)
                cl.hello(tok, "chk_t")
                n, m, _ = cl.next(("Welcome", "Disconnect"))
                got = 0 if n == "Welcome" else (m["code"] if n == "Disconnect" else n)
                rs = m.get("reason") if n == "Disconnect" else None
                case(name, got == want and (reason is None or rs == reason), want=want, got=got, reason=rs)
                cl.close()
        finally:
            for p in procs:
                p.terminate()
                p.wait(5)
    ok = all(r["ok"] for r in res)
    print(json.dumps({"passed": sum(r["ok"] for r in res), "tests": len(res), "tmp": tmp}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
