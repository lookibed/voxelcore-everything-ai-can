"""Load generator for the Olife gateway (throughput and soak; lab kind olife.gw_load, step olife_gw_load / olife_soak).
N protocol bots (no engine): Hello -> Welcome, answer every KeepAlive, send PlayerInput at a fixed rate (default 55/s,
under the gateway limit of 60/s) and every K-th message a ChatSend of `chat_len` bytes (world fan-out via Multicast),
read everything. Measures per bot and in total: frames/bytes up and down, TickSync delay (receive - world server_ms,
same machine clock), keepalive challenges, Disconnect codes. Nothing should be dropped while within the limits.

  python gw_load.py --gateway <port> [--bots 20] [--rate 55] [--seconds 30] [--chat-every 0] [--chat-len 200]
         [--token olife-bot] [--prefix load] [--out gw_load.json] [--ramp 0.02] [--progress 10]
Stdlib only (Windows Python of the lab daemon or WSL). Two threads per bot (reader, writer)."""
import json
import os
import socket
import sys
import struct
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from olife_proto import client as C  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

SERVER_MS = struct.Struct(">d")


def stats(v):
    if not v:
        return None
    s = sorted(v)
    q = lambda p: s[min(len(s) - 1, int(p * (len(s) - 1) + 0.5))]  # noqa: E731
    return {"n": len(s), "min": round(s[0], 3), "p50": round(q(0.5), 3), "p95": round(q(0.95), 3),
            "p99": round(q(0.99), 3), "max": round(s[-1], 3), "mean": round(sum(s) / len(s), 3)}


class Bot:
    def __init__(self, a, i):
        self.a, self.i = a, i
        self.name = "%s%d" % (a["prefix"], i)
        self.sent = self.sent_bytes = self.recv = self.recv_bytes = 0
        self.by_type = {}
        self.sync_ms = []
        self.ka = 0
        self.code = None
        self.reason = None
        self.error = None
        self.welcome_ms = None
        self.done = threading.Event()
        self.lock = threading.Lock()
        self.s = None

    def tx(self, data):
        with self.lock:
            self.s.sendall(data)
        self.sent += 1
        self.sent_bytes += len(data)

    def run(self, t_end):
        a = self.a
        t0 = time.time()
        try:
            self.s = socket.create_connection((a["host"], int(a["gateway"])), timeout=10)
            self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.tx(C.frame("Hello", {"proto": C.VERSION, "name": self.name, "token": a["token"], "engine": "gw_load"}))
        except OSError as exc:
            self.error = "connect: %s" % exc
            self.done.set()
            return
        rd = threading.Thread(target=self.reader, daemon=True)
        rd.start()
        # wait for Welcome
        while self.welcome_ms is None and not self.done.is_set() and time.time() - t0 < 10:
            time.sleep(0.01)
        if self.welcome_ms is None:
            self.error = self.error or "no Welcome"
            self.close()
            return
        rate = float(a["rate"])
        chat_every = int(a["chat_every"])
        chat = C.frame("ChatSend", {"text": "x" * int(a["chat_len"])})
        # pre-encoded PlayerInput; only seq (body offset 0) changes -> the client spends its CPU on sockets, not codecs
        pin = bytearray(C.frame("PlayerInput", {"seq": 0, "pos": {"x": 8.5, "y": 82.0, "z": 8.5},
                                                "rot": {"x": 0.0, "y": 0.0, "z": 0.0}}))
        seq = 0
        nxt = time.time()
        try:
            while time.time() < t_end and not self.done.is_set():
                seq += 1
                if chat_every and seq % chat_every == 0:
                    fr = chat
                else:
                    pin[9:13] = seq.to_bytes(4, "big")
                    fr = bytes(pin)
                self.tx(fr)
                nxt += 1.0 / rate
                d = nxt - time.time()
                if d > 0:
                    time.sleep(d)
                elif d < -1.0:
                    nxt = time.time()          # fell behind (client CPU): do not burst to catch up
        except OSError as exc:
            if not self.done.is_set():
                self.error = "send: %s" % exc
        if not self.done.is_set():
            try:
                self.tx(C.frame("Bye", {"reason": "gw_load done"}))
            except OSError:
                pass
        rd.join(3.0)
        self.close()

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        self.done.set()

    def reader(self):
        fr = C.framer()
        t0 = time.time()
        try:
            while True:
                d = self.s.recv(262144)
                if not d:
                    break
                self.recv_bytes += len(d)
                fr.feed(d)
                while True:
                    x = fr.next()
                    if x is None:
                        break
                    mid, body = x
                    self.recv += 1
                    n = C.NAMES[mid]
                    self.by_type[n] = self.by_type.get(n, 0) + 1
                    if n == "TickSync":
                        self.sync_ms.append(time.time() * 1000.0 - SERVER_MS.unpack_from(body, 4)[0])  # TickSync.server_ms
                    elif n == "KeepAlive":
                        m = C.decode_body(mid, body)
                        self.ka += 1
                        self.tx(C.frame("KeepAliveReply", {"challenge": m["challenge"]}))
                    elif n == "Welcome":
                        self.welcome_ms = (time.time() - t0) * 1000.0
                    elif n == "Disconnect":
                        m = C.decode_body(mid, body)
                        self.code, self.reason = m["code"], m["reason"]
        except (OSError, ProtoError) as exc:
            if not self.done.is_set() and self.code is None:
                self.error = "recv: %s" % exc
        self.done.set()

    def report(self):
        return {"name": self.name, "sent": self.sent, "sent_bytes": self.sent_bytes, "recv": self.recv,
                "recv_bytes": self.recv_bytes, "by_type": self.by_type, "keepalives": self.ka,
                "disconnect": self.code, "reason": self.reason, "error": self.error,
                "welcome_ms": round(self.welcome_ms, 2) if self.welcome_ms is not None else None,
                "sync_ms": stats(self.sync_ms)}


def run(a):
    a = dict({"host": "127.0.0.1", "bots": 20, "rate": 55, "seconds": 30, "chat_every": 0, "chat_len": 200,
              "token": "olife-bot", "prefix": "load", "ramp": 0.02, "progress": 0}, **a)
    bots = [Bot(a, i + 1) for i in range(int(a["bots"]))]
    t_start = time.time()
    t_end = t_start + float(a["seconds"]) + int(a["bots"]) * float(a["ramp"])
    ths = []
    for b in bots:
        t = threading.Thread(target=b.run, args=(t_end,), daemon=True)
        t.start()
        ths.append(t)
        time.sleep(float(a["ramp"]))
    prog = float(a["progress"] or 0)
    last = time.time()
    while any(t.is_alive() for t in ths):
        time.sleep(0.2)
        if prog and time.time() - last >= prog:
            last = time.time()
            print("[gw_load] t=%.0f sent=%d recv=%d alive=%d" % (time.time() - t_start, sum(b.sent for b in bots),
                                                                  sum(b.recv for b in bots),
                                                                  sum(1 for b in bots if not b.done.is_set())),
                  flush=True)
        if time.time() > t_end + 15:
            break
    dur = time.time() - t_start
    reps = [b.report() for b in bots]
    allsync = [x for b in bots for x in b.sync_ms]
    codes = {}
    for r in reps:
        if r["disconnect"] is not None:
            k = "bye" if r["disconnect"] == 3 and (r["reason"] or "").startswith("bye:") else str(r["disconnect"])
            codes[k] = codes.get(k, 0) + 1
    tot = {k: sum(r[k] for r in reps) for k in ("sent", "sent_bytes", "recv", "recv_bytes", "keepalives")}
    out = {"args": a, "duration_s": round(dur, 2), "bots": len(bots), "total": tot,
           "sent_per_s": round(tot["sent"] / max(dur, 1e-9), 1), "recv_per_s": round(tot["recv"] / max(dur, 1e-9), 1),
           "sent_bytes_per_s": round(tot["sent_bytes"] / max(dur, 1e-9)),
           "recv_bytes_per_s": round(tot["recv_bytes"] / max(dur, 1e-9)),
           "planned_msgs": round(len(bots) * float(a["rate"]) * float(a["seconds"])),
           "disconnect_codes": codes, "errors": [r["error"] for r in reps if r["error"]][:20],
           "welcome_ms": stats([r["welcome_ms"] for r in reps if r["welcome_ms"] is not None]),
           "sync_ms": stats(allsync), "per_bot": reps}
    return out


def main():
    argv = sys.argv[1:]
    a = {argv[i][2:].replace("-", "_"): argv[i + 1] for i in range(0, len(argv) - 1) if argv[i].startswith("--")}
    out = a.pop("out", None)
    print("[gw_load] start %s" % json.dumps(a), flush=True)
    r = run(a)
    s = {k: v for k, v in r.items() if k != "per_bot"}
    print("[gw_load] done %s" % json.dumps(s), flush=True)
    if out:
        with open(out, "w", encoding="utf-8") as f:
            json.dump(r, f, indent=1)
    # Bye is the normal end (the gateway answers Disconnect 3 "bye: ..."); anything else is a failure
    bad = {c: n for c, n in r["disconnect_codes"].items() if c != "bye"}
    return 1 if (bad or r["errors"]) else 0


if __name__ == "__main__":
    sys.exit(main())
