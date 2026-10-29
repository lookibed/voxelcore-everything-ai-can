#!/usr/bin/env python3
"""Protocol-level test driver for olife-sandboxd (plays the world side over JSON lines).

  tests/driver.py [all|smoke|negative|load|determinism|query] [--runtime wasm|luau] [--bin PATH]
                  [--ticks N] [--threads N] [--tcp HOST:PORT]

Spawns the service (stdin/stdout) unless --tcp is given, sends TickInput, checks TickResult.
Exit code 0 = all checks passed.
"""
import argparse, json, os, queue, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# source tree (WSL) or the deployed Windows layout (D:\Prog\Olife\sandboxd: driver.py next to olife-sandboxd.exe)
DEFAULT_BIN = next((p for p in (os.path.join(ROOT, "target", "release", "olife-sandboxd"),
                                os.path.join(HERE, "olife-sandboxd.exe"), os.path.join(ROOT, "olife-sandboxd.exe"))
                    if os.path.isfile(p)), os.path.join(ROOT, "target", "release", "olife-sandboxd"))

_WL = os.path.join(ROOT, "src", "workload.rs")
TYPICAL = (open(_WL).read().split('pub const TYPICAL: &str = r#"')[1].split('"#;')[0] if os.path.isfile(_WL)
           else open(os.path.join(HERE, "workload_typical.lua")).read())
COUNTER = "local n = 0\nfunction on_tick(dt) n = n + 1; print(n) end"


class Svc:
    def __init__(self, args):
        self.args = args
        if args.tcp:
            host, port = args.tcp.rsplit(":", 1)
            self.sock = socket.create_connection((host, int(port)))
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.r = self.sock.makefile("r")
            self.w = self.sock.makefile("w")
            self.p = None
        else:
            self.p = subprocess.Popen([args.bin, "--runtime", args.runtime, "--threads", str(args.threads)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
            self.r, self.w = self.p.stdout, self.p.stdin

    def call(self, msg, timeout=None):
        self.w.write(json.dumps(msg) + "\n")
        self.w.flush()
        timeout = timeout or self.args.timeout
        q = queue.Queue()
        threading.Thread(target=lambda: q.put(self.r.readline()), daemon=True).start()
        try:
            line = q.get(timeout=timeout)
        except queue.Empty:
            if self.p:
                self.p.kill()
            raise TimeoutError(f"no reply in {timeout}s: service hung, killed")
        if not line:
            raise RuntimeError("service closed the stream")
        return json.loads(line)

    def load(self, owner, eid, src):
        r = self.call({"type": "load", "owner": owner, "eid": eid, "src": src})
        return r.get("ok"), r.get("error")

    def tick(self, t, ents, dt=0.05):
        return self.call({"type": "tick", "tick": t, "seed": t, "dt": dt, "entities": ents})

    def close(self):
        try:
            self.call({"type": "quit"})
        except Exception:
            pass
        if self.p:
            try:
                self.p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.p.kill()


def ent(owner, eid, **kw):
    e = {"owner": owner, "eid": eid}
    e.update(kw)
    return e


def by_eid(res, eid):
    for e in res["entities"]:
        if e["eid"] == eid:
            return e
    raise KeyError(eid)


def prints(e):
    return [a.get("text") for a in e.get("actions", []) if a.get("op") == "print"]


FAILS = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what, flush=True)
    if not cond:
        FAILS.append(what)


def t_smoke(args):
    print("[smoke]")
    s = Svc(args)
    h = s.call({"type": "hello", "proto": 1})
    check(h["type"] == "hello", f"hello -> runtime {h.get('runtime')}")
    check(s.load(1, 1, COUNTER)[0], "load counter")
    ok, err = s.load(1, 2, "syntax error here")
    check(not ok and "e2:1" in (err or ""), f"syntax error reported: {err}")
    r = s.tick(1, [ent(1, 1, pos=[1, 2, 3])])
    check(prints(by_eid(r, 1)) == ["1"], "first tick prints 1")
    s.close()


def t_query(args):
    print("[query] async raycast: yield -> answer next tick")
    s = Svc(args)
    s.load(1, 1, """function on_tick()
        local hit = world.raycast(self.pos, {0, -1, 0}, 16)
        print("hit", hit.dist)
    end""")
    r = s.tick(1, [ent(1, 1, pos=[0, 10, 0])])
    e = by_eid(r, 1)
    check(e["status"] == "wait" and e["queries"][0]["op"] == "raycast", "tick 1: wait + raycast query")
    qid = e["queries"][0]["qid"]
    r = s.tick(2, [ent(1, 1, pos=[0, 10, 0], answers={str(qid): {"dist": 4}})])
    check(prints(by_eid(r, 1)) == ["hit\t4"], "tick 2: answer delivered")
    s.close()


NEGATIVE = [
    # name, owner limits, source, expected statuses (any of), ticks, expect_other_ok
    ("while true do end", {}, "while true do end", {"throttled"}, 3),
    ("pcall-wrapped infinite loop", {}, "while true do pcall(function() while true do end end) end", {"killed", "throttled"}, 2),
    ("string.rep('x', 2^30)", {}, 'local s = string.rep("x", 2^30)', {"error"}, 1),
    ("table growth to heap limit", {"lua_heap_max": 8 << 20, "mem_max": 16 << 20, "entity_budget": 50000000, "tick_cap": 100000000},
     "local t = {} local i = 0 while true do i = i + 1; t[i] = {i} end", {"error"}, 40),
    ("deep recursion (no pcall)", {"entity_budget": 100000000, "tick_cap": 400000000},
     "local function f() return f() + 1 end f()", {"error"}, 3),
    ("C-level recursion via __index", {}, "local t = setmetatable({}, {__index = function(t, k) return t[k] end}) local _ = t.x", {"error"}, 1),
    ("pattern backtracking in C (owner freeze -> kill)", {"hard_cap_ticks": 4},
     'function on_tick() string.find(string.rep("a", 40), ".-.-.-.-.-.-.-.-.-.-.-.-b") end', {"killed", "throttled"}, 8),
    ("escape: os/io/debug/getfenv/require/load", {},
     'assert(os == nil and io == nil and debug == nil and getfenv == nil and require == nil and load == nil and dofile == nil)\nprint("sealed")', {"ok"}, 1),
    ("escape: bytecode via loadstring", {}, 'local f, e = loadstring("\\27Lua\\81\\0") assert(f == nil) print(e)', {"ok", "error"}, 1),
    ("escape: modify shared stdlib", {}, "string.rep = nil", {"error"}, 1),
    ("action spam (100 prints/tick)", {}, "function on_tick() for i = 1, 100 do print(i) end end", {"ok"}, 1),
]


def t_negative(args):
    print(f"[negative] runtime={args.runtime}")
    rows = []
    for i, (name, lim, src, expect, ticks) in enumerate(NEGATIVE):
        s = Svc(args)
        owner, other_owner = 10 + i, 1000 + i
        if lim:
            l = dict(lim)
            s.call({"type": "set_limits", "owner": owner, "limits": l})
        s.load(owner, 2, COUNTER)               # same owner, well-behaved
        s.load(other_owner, 3, COUNTER)         # other owner
        s.tick(1, [ent(owner, 2), ent(other_owner, 3)])   # checkpoint after loads
        ok, err = s.load(owner, 1, src)
        last, other_ok, statuses, fuel = None, True, [], 0
        hung = False
        for t in range(2, 2 + ticks):
            try:
                r = s.tick(t, [ent(owner, 1), ent(owner, 2), ent(other_owner, 3)])
            except TimeoutError as ex:
                statuses.append("HUNG")
                hung, other_ok = True, False
                last = {"status": "HUNG", "error": str(ex), "meter": {"fuel": 0}}
                break
            e = by_eid(r, 1)
            statuses.append(e["status"])
            fuel = max(fuel, e["meter"]["fuel"])
            other_ok &= prints(by_eid(r, 3)) == [str(t)]
            last = e
            if e["status"] in ("error", "killed", "ok") and e["status"] in expect:
                break
        if args.runtime == "luau" and "loadstring" in src:
            expect = expect | {"error"}
        got = last["status"] if last else "load-failed"
        passed = (got in expect or any(st in expect for st in statuses)) and other_ok
        extra = (last or {}).get("error") or ""
        if hung:
            passed = False
        if name.startswith("action spam") and not hung:
            passed &= len(last.get("actions", [])) == 64 and last["meter"]["actions_dropped"] == 36
            extra = f"accepted {len(last.get('actions', []))}, dropped {last['meter']['actions_dropped']}"
        rows.append((name, "/".join(sorted(expect)), " ".join(dict.fromkeys(statuses)), fuel, other_ok, passed, extra[:70]))
        check(passed, f"{name}: {got}")
        if not hung:
            s.close()
    print("\n| scenario | expected | statuses seen | max fuel/tick | other owner ok | pass | note |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        print("| %s | %s | %s | %d | %s | %s | %s |" % (r[0], r[1], r[2], r[3], "yes" if r[4] else "NO", "PASS" if r[5] else "FAIL", r[6].replace("|", "/")))


def t_load(args):
    owners, per = 50, 10
    print(f"[load] {owners} owners x {per} entities, {args.ticks} ticks over the JSON protocol (threads={args.threads})")
    s = Svc(args)
    for o in range(1, owners + 1):
        for k in range(per):
            ok, err = s.load(o, o * 1000 + k, TYPICAL)
            assert ok, err
    svc_ms, e2e_ms = [], []
    for t in range(1, args.ticks + 21):
        ents = []
        for o in range(1, owners + 1):
            for k in range(per):
                eid = o * 1000 + k
                view = [{"id": eid + j + 1, "pos": [(eid + j + 1) % 100, 64, (eid + j + 1) // 100], "type": "box"} for j in range(5)]
                e = ent(o, eid, pos=[eid % 100, 64, eid // 100], view=view)
                if t % 10 == eid % 10:
                    e["events"] = [{"type": "touched", "by": 1}]
                ents.append(e)
        t0 = time.perf_counter()
        r = s.tick(t, ents)
        dt = (time.perf_counter() - t0) * 1e3
        if t > 20:
            svc_ms.append(r["wall_us"] / 1e3)
            e2e_ms.append(dt)
    s.close()
    svc_ms.sort(); e2e_ms.sort()
    p = lambda a, q: a[int((len(a) - 1) * q)]
    print(f"  service tick: mean {sum(svc_ms)/len(svc_ms):.2f} ms  p50 {p(svc_ms,.5):.2f}  p99 {p(svc_ms,.99):.2f}")
    print(f"  end-to-end (JSON encode + pipe + decode in Python): mean {sum(e2e_ms)/len(e2e_ms):.2f} ms  p99 {p(e2e_ms,.99):.2f}")
    check(p(svc_ms, .5) < 20.0, "service p50 < 20 ms per tick (gate)")


def det_once(args):
    s = Svc(args)
    src = """math.randomseed(self.id)
    function on_tick(dt)
        local t = {}
        for i = 1, 20 do t[{}] = math.random(1000); t["k" .. math.random(50)] = i end
        local acc = 0
        for k, v in pairs(t) do acc = (acc * 31 + v) % 1000003 end
        print(acc)
    end"""
    for o in (1, 2):
        for k in range(3):
            s.load(o, o * 10 + k, src)
    out = []
    for t in range(1, 21):
        r = s.tick(t, [ent(o, o * 10 + k) for o in (1, 2) for k in range(3)])
        r.pop("wall_us", None)
        for m in r["owners"]:
            m.pop("wall_us", None)
        out.append(json.dumps(r, sort_keys=True))
    hashes = []
    if args.runtime == "wasm":
        for o in (1, 2):
            hashes.append(s.call({"type": "snapshot", "owner": o})["hash"])
    s.close()
    return out, hashes


def t_determinism(args):
    print("[determinism] two separate processes, same inputs")
    a, ha = det_once(args)
    b, hb = det_once(args)
    check(a == b, "TickResult stream identical (statuses, actions, fuel meters)")
    if args.runtime == "wasm":
        check(ha == hb, f"owner memory hashes identical: {ha[0][:16]}.. {ha[1][:16]}..")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", nargs="?", default="all")
    ap.add_argument("--runtime", default="wasm")
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--ticks", type=int, default=100)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--tcp", default=None)
    ap.add_argument("--timeout", type=float, default=30.0, help="seconds per request before the service is declared hung")
    args = ap.parse_args()
    tests = {"smoke": t_smoke, "query": t_query, "negative": t_negative, "determinism": t_determinism, "load": t_load}
    for name, fn in tests.items():
        if args.what in ("all", name):
            fn(args)
    print("\nRESULT:", "PASS" if not FAILS else f"FAIL ({len(FAILS)}): " + "; ".join(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
