"""Фейковые службы этапа 6 (supervisor, без движка): `python fake_sup.py <режим> --k v ...`.
  world — как мир olife для supervisor: TCP-порт --port (LISTEN), stdin-команды (status, sandbox_reconnect, save,
          journal_dump, hang — перестать отвечать, olife.stop), export\\sup_state_{a,b}.json раз в 0.2 с (кольцо кадров,
          игроки, песочница, действия по аккаунтам), строка [olife_world] ready; --die-after S — exit 3 через S с
  ctl   — как шлюз/песочница: порт управления --f2f (протокол F2F лаборатории: hello, stats, metrics, world_status;
          каждый вызов — строка в ctl_calls.jsonl), --listen — TCP-порт в LISTEN, строка [fake_ctl] ready"""
import json
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "projects", "olife"))


def args():
    a, i, out = sys.argv[2:], 0, {}
    while i < len(a):
        if a[i].startswith("--") and i + 1 < len(a) and not a[i + 1].startswith("--"):
            out[a[i][2:]] = a[i + 1]
            i += 2
        else:
            out[a[i][2:]] = ""
            i += 1
    return out


def world(a):
    os.makedirs("export", exist_ok=True)
    srv = socket.socket()
    srv.bind(("127.0.0.1", int(a["port"])))
    srv.listen(4)
    st = {"tick": 0, "hang": False, "stop": False, "writes": 0, "sandbox": "connected"}

    def handler(cmd):
        if st["hang"]:
            return None
        if cmd == "status":
            return "[stdin-cmd] [olife_world] status tick=%d sessions=1 entities=4 sandbox=%s/jsonl(sent=1) scripted=2" % (
                st["tick"], st["sandbox"])
        if cmd == "sandbox_reconnect":
            st["sandbox"] = "connected"
            return "[stdin-cmd] [olife_world] sandbox_reconnect queued (state down)"
        if cmd == "save":
            return "[stdin-cmd] [olife_world] save requested at tick %d" % st["tick"]
        if cmd == "hang":
            st["hang"] = True
            return "[stdin-cmd] [olife_world] hanging"
        if cmd == "olife.stop":
            st["stop"] = True
            return "[stdin-cmd] [olife_world] stopping"
        return "[stdin-cmd] unknown %s" % cmd

    def reader():
        for line in sys.stdin:
            line = line.strip()
            if line:
                r = handler(line)
                if r:
                    print(r, flush=True)
    threading.Thread(target=reader, daemon=True).start()
    print("[olife_world] ready port=%s" % a["port"], flush=True)
    t0 = time.time()
    while not st["stop"]:
        time.sleep(0.05)
        st["tick"] += 1
        if st["tick"] % 4 == 0:
            st["writes"] += 1
            frames = [[st["tick"] - 3 + i % 3, 1, 1 + i % 2, 5, 3 if i % 5 else 4, 40 + i, time.time() * 1000]
                      for i in range(min(256, st["tick"]))]
            d = {"v": 1, "tick": st["tick"], "ms": time.time() * 1000, "seq": st["writes"], "entities": 4,
                 "scripted": 2, "entities_by_owner": {"1": 2}, "sessions": 1, "journal_total": st["tick"],
                 "players": [{"eid": 6, "name": "bot1", "account": "bot1", "session": 1, "pos": [1, 2, 3],
                              "inputs": st["tick"], "actions": st["tick"] // 10}],
                 "acct_actions": {"bot1": st["tick"] // 10}, "journal": frames,
                 "sandbox": {"state": st["sandbox"], "results": st["tick"], "last_result_tick": st["tick"] - 1,
                             "last_result": {"tick": st["tick"] - 1, "entities": 2, "actions": 4},
                             "owners": {"1": {"fuel": st["tick"] * 100, "actions": st["tick"], "rejected": 0}}},
                 "tick_ms": {"avg": 1.0, "p95": 1.5, "max": 2.0}}
            p = os.path.join("export", "sup_state_%s.json" % ("a" if st["writes"] % 2 == 0 else "b"))
            with open(p, "w", encoding="utf-8") as f:
                json.dump(d, f)
        if a.get("die-after") and time.time() - t0 > float(a["die-after"]):
            print("[olife_world] dying on purpose", flush=True)
            os._exit(3)
    print("[olife_world] finished", flush=True)


def ctl(a):
    import ctlport
    if a.get("listen"):
        srv = socket.socket()
        srv.bind(("127.0.0.1", int(a["listen"])))
        srv.listen(4)
    calls = open("ctl_calls.jsonl", "a", encoding="utf-8")
    st = {"t0": time.time()}

    def rec(name):
        def fn(args):
            calls.write(json.dumps({"t": time.time(), "cmd": name, "args": args}) + "\n")
            calls.flush()
            if name == "stats":
                return {"ticks": int((time.time() - st["t0"]) * 20), "uptime_s": time.time() - st["t0"]}
            if name == "metrics":
                n = int((time.time() - st["t0"]) * 1000)
                return {"auth": "supervisor", "connections": 1, "auth_ok": 1, "total": {"down": n, "up": n // 10},
                        "sessions": {"1": {"account": "bot1", "up": n // 10, "down": n, "up_msgs": n // 100,
                                           "down_msgs": n // 50}}}
            return {"ok": True, "args": args}
        return fn
    ctlport.serve(a["f2f"], {k: rec(k) for k in ("stats", "metrics", "world_status")}, "fake-ctl")
    print("[fake_ctl] ready", flush=True)
    while True:
        time.sleep(1)


if __name__ == "__main__":
    {"world": world, "ctl": ctl}[sys.argv[1]](args())
