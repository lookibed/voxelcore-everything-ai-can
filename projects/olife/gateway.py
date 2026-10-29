"""[С 02.10 (волна 2 olife) дескриптор использует tools/olife/gateway_dev.py и sandbox_stub.py; этот файл — только для
теста лаборатории на фейковых процессах (tests/test_olife_session.py).]
Шлюз Olife — ЗАГЛУШКА лаборатории (заменится настоящим sockets_auth, OLIFE_ARCHITECTURE.md §1): TCP-реле
клиент <-> мир, одно соединение с миром на клиента. Считает байты по направлениям и соединениям; по строкам протокола
заглушки (`"tick":N` от мира, `{"t":"ack","tick":N}` от клиента) — задержку такта на шлюзе (ack − state, мс).
Управление — порт F2F (ctlport): hello, metrics, quit. Метрики ещё и в файл --metrics раз в 0.5 с.
  python gateway.py --listen <порт клиентов> --upstream 127.0.0.1:<порт мира> --f2f <порт> --metrics <json>"""
import json
import os
import re
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ctlport  # noqa: E402

TICK_RX = re.compile(rb'"tick":\s*(\d+)')
ACK_RX = re.compile(rb'"t":\s*"ack"')
LOCK = threading.Lock()
M = {"started": time.time(), "conns": {}, "total": {"up": 0, "down": 0, "up_msgs": 0, "down_msgs": 0},
     "rtt_ms": [], "errors": []}


def pump(src, dst, cid, direction, sent_at):
    buf = b""
    while True:
        try:
            data = src.recv(65536)
        except OSError:
            data = b""
        if not data:
            break
        now = time.time()
        try:
            dst.sendall(data)
        except OSError as exc:
            with LOCK:
                M["errors"].append("%s %s: %s" % (cid, direction, exc))
            break
        buf += data
        lines = buf.split(b"\n")
        buf = lines.pop()
        with LOCK:
            c = M["conns"][cid]
            c[direction] += len(data)
            M["total"][direction] += len(data)
            for ln in lines:
                M["total"][direction + "_msgs"] += 1
                c[direction + "_msgs"] += 1
                m = TICK_RX.search(ln)
                if not m:
                    continue
                t = int(m.group(1))
                if direction == "down":
                    sent_at.setdefault(t, now)
                elif ACK_RX.search(ln) and t in sent_at:
                    rtt = (now - sent_at.pop(t)) * 1000.0
                    c["rtt_ms"].append(round(rtt, 3))
                    M["rtt_ms"].append(round(rtt, 3))
                    c["acks"] += 1
            if len(sent_at) > 5000:
                for k in sorted(sent_at)[:1000]:
                    sent_at.pop(k, None)
    for s in (src, dst):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
    with LOCK:
        M["conns"][cid]["closed"] = time.time()


def stats(v):
    if not v:
        return None
    s = sorted(v)
    q = lambda p: s[min(len(s) - 1, int(p * (len(s) - 1) + 0.5))]  # noqa: E731
    return {"n": len(s), "min": s[0], "p50": q(0.5), "p95": q(0.95), "max": s[-1]}


def metrics(args=None):
    with LOCK:
        conns = {k: dict({kk: vv for kk, vv in c.items() if kk != "rtt_ms"}, rtt=stats(c["rtt_ms"]))
                 for k, c in M["conns"].items()}
        return {"uptime_s": round(time.time() - M["started"], 2), "total": dict(M["total"]), "conns": conns,
                "rtt_ms": stats(M["rtt_ms"]), "errors": M["errors"][-20:]}


def main():
    a = ctlport.argmap(sys.argv[1:])
    up_host, up_port = a["upstream"].rsplit(":", 1)
    path = a.get("metrics")
    ctlport.serve(a["f2f"], {"metrics": metrics}, "olife-gateway")
    if path:
        def writer():
            while True:
                time.sleep(0.5)
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(metrics(), f)
                os.replace(tmp, path)
        threading.Thread(target=writer, daemon=True).start()
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", int(a["listen"])))
    srv.listen(64)
    print("[olife_gateway] ready listen=%s upstream=%s" % (a["listen"], a["upstream"]), flush=True)
    n = 0
    while True:
        cl, addr = srv.accept()
        n += 1
        cid = "c%d" % n
        try:
            up = socket.create_connection((up_host, int(up_port)), timeout=5)
            up.settimeout(None)
        except OSError as exc:
            with LOCK:
                M["errors"].append("%s upstream: %s" % (cid, exc))
            cl.close()
            continue
        for s in (cl, up):
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        with LOCK:
            M["conns"][cid] = {"peer": "%s:%d" % addr, "opened": time.time(), "up": 0, "down": 0, "up_msgs": 0,
                               "down_msgs": 0, "acks": 0, "rtt_ms": []}
        print("[olife_gateway] %s from %s:%d" % ((cid,) + addr), flush=True)
        sent_at = {}
        threading.Thread(target=pump, args=(cl, up, cid, "up", sent_at), daemon=True).start()
        threading.Thread(target=pump, args=(up, cl, cid, "down", sent_at), daemon=True).start()


if __name__ == "__main__":
    main()
