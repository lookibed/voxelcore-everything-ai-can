"""Negative protocol tests of the Olife gateway and world (contracts client/internal): every bad input must end in a
Disconnect with the right code (or a dropped connection for the world) — never a crash or a hang.

  python negative.py --gateway <port> [--world <port>] [--json out.json]
Used by the lab step olife_negative_proto (tools/lab/projects/olife/plugin.py). Order matters: the legit handshake runs
before the flood test, because a flood bans the source IP for 30 s (127.0.0.1 here)."""
import json
import os
import random
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from olife_proto import client as C, internal as I  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

HELLO = {"proto": C.VERSION, "name": "neg", "token": "olife-test", "engine": "neg"}


def conn(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def read_until(s, want=("Disconnect",), timeout=8.0):
    """-> (msg name, msg, eof) of the first frame in `want`, or (None, None, eof) on EOF/timeout."""
    fr = C.framer()
    end = time.time() + timeout
    s.settimeout(0.2)
    while time.time() < end:
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            return None, None, True
        if not d:
            return None, None, True
        fr.feed(d)
        while True:
            try:
                x = fr.next()
            except ProtoError as exc:
                return "ProtoError", str(exc), False
            if x is None:
                break
            name = C.NAMES[x[0]]
            m = C.decode_body(*x)
            if name in want:
                return name, m, False
    return None, None, False


def eof_after(s, timeout=3.0):
    s.settimeout(0.2)
    end = time.time() + timeout
    while time.time() < end:
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            return True
        if not d:
            return True
    return False


def expect_disconnect(name, port, payload, code, pre=None, timeout=8.0):
    t0 = time.time()
    try:
        s = conn(port)
        if pre:
            s.sendall(pre)
            n, m, _ = read_until(s, ("Welcome",), 5)
            if n != "Welcome":
                s.close()
                return {"name": name, "ok": False, "error": "no Welcome before the test (%s)" % n}
        if payload:
            s.sendall(payload() if callable(payload) else payload)
        n, m, eof = read_until(s, ("Disconnect",), timeout)
        closed = eof or eof_after(s)
        s.close()
    except OSError as exc:
        return {"name": name, "ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}
    got = m["code"] if n == "Disconnect" else None
    return {"name": name, "ok": got == code and closed, "want_code": code, "got_code": got,
            "reason": m["reason"] if n == "Disconnect" else None, "closed": closed,
            "ms": round((time.time() - t0) * 1000, 1)}


def header(magic, ver, mid, n):
    return struct.pack(">HBHI", magic, ver, mid, n)


def legit(port, name="neg_ok"):
    t0 = time.time()
    try:
        s = conn(port)
        s.sendall(C.frame("Hello", dict(HELLO, name=name)))
        n, m, _ = read_until(s, ("Welcome", "Disconnect"), 8)
        ok = n == "Welcome"
        if ok:
            s.sendall(C.frame("Bye", {"reason": "negative suite done"}))
        s.close()
        return {"name": "legit_handshake_" + name, "ok": ok, "got": n, "eid": m and m.get("player_eid"),
                "ms": round((time.time() - t0) * 1000, 1)}
    except OSError as exc:
        return {"name": "legit_handshake_" + name, "ok": False, "error": str(exc)}


def world_direct(port, secret):
    out = []
    for name, data in [("world_bad_magic", b"XXXX" + bytes(5)),
                       ("world_bad_secret", I.frame("GatewayHello", {"proto": 1, "gateway": "evil", "secret": "nope",
                                                                     "client_proto": C.VERSION})),
                       ("world_data_before_hello", I.frame("Data", {"session": 1, "type": 5,
                                                                    "payload": C.body("ChatSend", {"text": "x"})})),
                       ("world_oversized", header(I.MAGIC, I.VERSION, 5, I.MAX_FRAME + 1))]:
        t0 = time.time()
        try:
            s = conn(port)
            s.sendall(data)
            closed = eof_after(s, 4.0)
            s.close()
            out.append({"name": name, "ok": closed, "closed": closed, "ms": round((time.time() - t0) * 1000, 1)})
        except OSError as exc:
            out.append({"name": name, "ok": False, "error": str(exc)})
    return out


def run(gw, world=None, secret="olife-dev-secret"):
    hello = C.frame("Hello", HELLO)
    pin = lambda i: C.frame("PlayerInput", {"seq": i, "pos": {"x": 8.5, "y": 82, "z": 8.5},  # noqa: E731
                                            "rot": {"x": 0, "y": 0, "z": 0}})
    good_chat = C.frame("ChatSend", {"text": "x"})
    rng = random.Random(5)
    res = [
        expect_disconnect("bad_magic", gw, b"XX" + good_chat[2:], 3),
        expect_disconnect("wrong_version", gw, good_chat[:2] + b"\x09" + good_chat[3:], 3),
        expect_disconnect("oversized_header_only", gw, header(C.MAGIC, C.VERSION, 5, 2 ** 20), 3),
        expect_disconnect("oversized_over_max_frame", gw, header(C.MAGIC, C.VERSION, 67, C.MAX_FRAME + 1), 3),
        expect_disconnect("unknown_type", gw, header(C.MAGIC, C.VERSION, 200, 0), 3),
        expect_disconnect("truncated_string", gw, header(C.MAGIC, C.VERSION, 1, 4) + b"\x00\x01\x00\x30", 3),
        expect_disconnect("invalid_utf8", gw, header(C.MAGIC, C.VERSION, 5, 4) + b"\x00\x02\xff\xfe", 3),
        expect_disconnect("trailing_bytes", gw, header(C.MAGIC, C.VERSION, 5, 4) + b"\x00\x01ab", 3),
        expect_disconnect("garbage_4k", gw, bytes(rng.randrange(256) for _ in range(4096)), 3),
        expect_disconnect("no_hello_first", gw, good_chat, 3),
        expect_disconnect("server_message_from_client", gw, C.frame("KeepAlive", {"challenge": 1, "server_ms": 0}), 3),
        expect_disconnect("bad_token", gw, C.frame("Hello", dict(HELLO, token="wrong")), 4),
        expect_disconnect("wrong_client_proto", gw, C.frame("Hello", dict(HELLO, proto=C.VERSION + 1)), 3),
        expect_disconnect("bad_name", gw, C.frame("Hello", dict(HELLO, name="a b")), 4),
        expect_disconnect("banned_account", gw, C.frame("Hello", dict(HELLO, token="olife-banned")), 5),
        expect_disconnect("handshake_timeout", gw, b"", 2, timeout=9.0),
        expect_disconnect("second_hello", gw, hello, 3, pre=hello),
        expect_disconnect("wrong_keepalive_challenge", gw, C.frame("KeepAliveReply", {"challenge": 12345}), 6,
                          pre=C.frame("Hello", dict(HELLO, name="neg_ka"))),
    ]
    if world:
        res += world_direct(world, secret)
    res.append(legit(gw))
    # flood last: 600 inputs in one burst -> Disconnect 7, then the IP is banned for 30 s
    res.append(expect_disconnect("flood_600_msgs", gw, lambda: b"".join(pin(i) for i in range(600)), 7,
                                 pre=C.frame("Hello", dict(HELLO, name="neg_flood"))))
    res.append(expect_disconnect("after_flood_ip_temp_ban", gw, hello, 5))
    return {"tests": len(res), "passed": sum(1 for r in res if r.get("ok")), "results": res}


if __name__ == "__main__":
    a = {sys.argv[i][2:]: sys.argv[i + 1] for i in range(1, len(sys.argv) - 1, 2) if sys.argv[i].startswith("--")}
    rep = run(int(a["gateway"]), int(a["world"]) if a.get("world") else None, a.get("secret", "olife-dev-secret"))
    for r in rep["results"]:
        print("%-32s %s %s" % (r["name"], "ok  " if r.get("ok") else "FAIL", json.dumps({k: v for k, v in r.items()
                                                                                      if k not in ("name", "ok")})))
    print("passed %d/%d" % (rep["passed"], rep["tests"]))
    if a.get("json"):
        with open(a["json"], "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=1)
    sys.exit(0 if rep["passed"] == rep["tests"] else 1)
