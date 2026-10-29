"""Olife sandbox STUB service — stands in for <olife-src>/sandboxd (Rust + wasmtime, Linux) on the Windows dev box.

  python sandbox_stub.py --listen <port> [--f2f <control port>] [--dir <instance dir>]

Speaks the world<->sandbox bridge in BOTH transports on one port (detected by the first byte):
  * JSON lines exactly like sandboxd today: {"type":"hello"|"set_limits"|"load"|"unload"|"tick"|"meters"|"quit",...}
    -> {"type":"hello"|"ok"|"load_result"|"tick_result"|"meters"|"error",...}
  * the binary contract "sandbox" (tools/olife/protocol/sandbox.yaml, magic "OS").
It does NOT run user code: every loaded entity gets the built-in deterministic "orbit" behaviour (set_pos on a circle
around its first position, set_rot, a print every 100 ticks) — enough to exercise the world's bridge, validation
and replication. Control port (lab F2F protocol): hello, stats, exec (always denied — the harness of the negative
scenario; the real sandbox replaces this), quit."""
import json
import math
import os
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "lab", "projects", "olife"))
from olife_proto import sandbox as SB  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

LOCK = threading.Lock()
ST = {"started": time.time(), "connections": 0, "ticks": 0, "loads": 0, "actions": 0, "exec": 0, "denied": 0,
      "proto": {}, "errors": [], "last_tick": None, "wall_us": []}
SCRIPTS = {}            # eid -> {"owner", "home", "t", "n"}
REQ_LOG = None          # <dir>/requests.jsonl: first 200 jsonl requests of each connection


def tick(inp):
    t0 = time.perf_counter()
    out = []
    for e in inp.get("entities") or []:
        eid, owner = int(e["eid"]), int(e.get("owner", 0))
        s = SCRIPTS.get(eid)
        if s is None:
            out.append({"eid": eid, "owner": owner, "status": "unknown", "error": "not loaded", "actions": [],
                        "meter": meter(0, 0)})
            continue
        pos = e.get("pos") or [0, 0, 0]
        r = 2 + eid % 3
        if s["home"] is None:
            # the circle passes through the current position (no teleport on the first tick)
            s["home"] = [pos[0] - r, pos[1], pos[2]]
        s["t"] += float(inp.get("dt") or 0.05)
        s["n"] += 1
        hx, hy, hz = s["home"]
        acts = [{"op": "set_pos", "pos": [hx + math.cos(s["t"]) * r, hy, hz + math.sin(s["t"]) * r]},
                {"op": "set_rot", "rot": [0, (s["t"] * 45) % 360, 0]}]
        if s["n"] % 100 == 0:
            acts.append({"op": "print", "text": "alive %d %d" % (eid, s["n"])})
        out.append({"eid": eid, "owner": owner, "status": "ok", "actions": acts, "meter": meter(1200, len(acts))})
    us = (time.perf_counter() - t0) * 1e6
    with LOCK:
        ST["ticks"] += 1
        ST["actions"] += sum(len(x["actions"]) for x in out)
        ST["last_tick"] = inp.get("tick")
        ST["wall_us"].append(us)
        del ST["wall_us"][:-1000]
    return {"tick": inp.get("tick", 0), "entities": out, "owners": [], "wall_us": round(us)}


def meter(fuel, calls):
    return {"fuel": fuel, "api_calls": calls, "api_credits": calls, "credits": calls, "alloc_bytes": 0,
            "actions_dropped": 0}


def handle_json(req):
    ty = req.get("type")
    if ty == "hello":
        return {"type": "hello", "proto": 1, "runtime": "stub"}
    if ty == "set_limits":
        return {"type": "ok"}
    if ty == "load":
        SCRIPTS[int(req["eid"])] = {"owner": int(req.get("owner", 0)), "home": None, "t": 0.0, "n": 0}
        with LOCK:
            ST["loads"] += 1
        return {"type": "load_result", "owner": req.get("owner"), "eid": req.get("eid"), "ok": True}
    if ty == "unload":
        SCRIPTS.pop(int(req.get("eid", -1)), None)
        return {"type": "ok"}
    if ty == "tick":
        return dict(tick(req), type="tick_result")
    if ty == "meters":
        return {"type": "meters", "owners": []}
    if ty == "quit":
        return {"type": "ok"}
    return {"type": "error", "message": "unknown request %r" % ty}


BIN_KIND = {"set_pos": "SetPos", "set_rot": "SetRot", "set_vel": "SetVel", "block.set": "BlockSet", "spawn": "Spawn",
            "say": "Say", "print": "Print", "oprint": "OPrint"}


def to_bin_action(a):
    k = BIN_KIND[a["op"]]
    o = {"kind": k}
    for f in ("pos", "rot", "vel"):
        if f in a and k != "BlockSet":
            o[f] = {"x": a[f][0], "y": a[f][1], "z": a[f][2]}
    if k == "BlockSet":
        o.update(x=int(a["pos"][0]), y=int(a["pos"][1]), z=int(a["pos"][2]), id=str(a["id"]))
    if "text" in a:
        o["text"] = a["text"][:1024]
    if "def" in a:
        o["def"] = a["def"]
    return o


def handle_bin(name, m):
    if name == "Hello":
        return [("Hello", {"proto": SB.VERSION, "runtime": "stub"})]
    if name == "Load":
        r = handle_json({"type": "load", "owner": m["owner"], "eid": m["eid"], "src": m["src"]})
        return [("LoadResult", {"owner": m["owner"], "eid": m["eid"], "ok": True, "error": None})]
    if name == "Unload":
        SCRIPTS.pop(m["eid"], None)
        return []
    if name == "TickInput":
        inp = {"tick": m["tick"], "dt": m["dt"], "entities": [
            {"eid": e["eid"], "owner": e["owner"], "pos": [e["pos"]["x"], e["pos"]["y"], e["pos"]["z"]]}
            for e in m["entities"]]}
        r = tick(inp)
        ents = [{"eid": x["eid"], "owner": x["owner"], "status": x["status"][:16], "error": x.get("error"),
                 "actions": [to_bin_action(a) for a in x["actions"]], "queries_json": [], "meter": x["meter"]}
                for x in r["entities"]]
        return [("TickResult", {"tick": r["tick"], "entities": ents, "wall_us": r["wall_us"]})]
    return [("Error", {"message": "unexpected %s" % name})]


def serve_conn(conn):
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    first = conn.recv(1, socket.MSG_PEEK)
    if not first:
        return
    proto = "jsonl" if first[:1] == b"{" else "bin"
    with LOCK:
        ST["connections"] += 1
        ST["proto"][proto] = ST["proto"].get(proto, 0) + 1
    print("[olife_sandbox] connection (%s)" % proto, flush=True)
    if proto == "jsonl":
        f = conn.makefile("rb")
        logged = 0
        for line in f:
            line = line.strip()
            if not line:
                continue
            if REQ_LOG and logged < 200:          # the world's requests verbatim (replay into the real sandboxd)
                logged += 1
                with open(REQ_LOG, "ab") as lf:
                    lf.write(line + b"\n")
            try:
                resp = handle_json(json.loads(line))
            except (ValueError, KeyError, TypeError) as exc:
                resp = {"type": "error", "message": "bad request: %s" % exc}
            conn.sendall((json.dumps(resp) + "\n").encode())
        return
    fr = SB.framer()
    while True:
        data = conn.recv(262144)
        if not data:
            return
        fr.feed(data)
        while True:
            try:
                x = fr.next()
            except ProtoError as exc:
                with LOCK:
                    ST["errors"].append(str(exc))
                return
            if x is None:
                break
            mid, body = x
            try:
                m = SB.decode_body(mid, body)
                out = handle_bin(SB.NAMES[mid], m)
            except ProtoError as exc:
                out = [("Error", {"message": str(exc)[:1000]})]
            conn.sendall(b"".join(SB.frame(n, v) for n, v in out))


def stats(args=None):
    with LOCK:
        w = sorted(ST["wall_us"])
        d = {k: v for k, v in ST.items() if k != "wall_us"}
        d["wall_us_p50"] = w[len(w) // 2] if w else None
        d["scripts"] = len(SCRIPTS)
        d["uptime_s"] = round(time.time() - ST["started"], 2)
        return d


def do_exec(args):
    with LOCK:
        ST["exec"] += 1
        ST["denied"] += 1
    return {"denied": True, "reason": "stub: no runtime (code is never executed)", "effects": [], "fuel_used": 0,
            "code_len": len(str(args.get("code") or ""))}


def main():
    import ctlport
    global REQ_LOG
    a = ctlport.argmap(sys.argv[1:])
    if a.get("dir"):
        REQ_LOG = os.path.join(a["dir"], "requests.jsonl")
    if a.get("f2f"):
        ctlport.serve(a["f2f"], {"exec": do_exec, "stats": stats}, "olife-sandbox")
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", int(a.get("listen", 0))))
    srv.listen(8)
    print("[olife_sandbox] ready listen=%s (stub: built-in orbit behaviour, jsonl+bin)" % srv.getsockname()[1],
          flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=lambda: (serve_conn(c), c.close()), daemon=True).start()


if __name__ == "__main__":
    main()
