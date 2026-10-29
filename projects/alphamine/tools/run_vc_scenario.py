#!/usr/bin/env python3
"""AlphaMine phase 2: run parity scenarios (tools/scenarios/alpha/*.json) on the VoxelCore side against the
agent's own Java server (port 25566, tools/alphamine/server_v.py) and compare with golden (percent metrics,
agents/F2F.md 7). The same steps/expects as am_scenario / am_layers, but the server is private: am_scenario's
session would restart the server on the scenario's port (25565 = the Java agent's server).

  python3 tools/alphamine/run_vc_scenario.py alpha_spawn layer_terrain_flat [--keep] [--no-server]

One session: fresh server world, VoxelCoreF2F-v.exe (am_client impl=vc), the common prefix (alpha_spawn steps up
to `mode`) once, then the body of every scenario (alpha_spawn body = mode + 4 shots; layer_* = look, mode,
render, 4 shots). Shots -> D:\\Prog\\AlphaMine\\runs\\<stamp>_vc_p2\\<scenario>\\, report.json, *_diff.png,
*_heat.png. All F2F calls go through voxelcore_mcp.call_tool (journaled).

Parameters for a parallel agent (defaults = the values above, so existing callers are unchanged):
  --exe VoxelCoreF2F-p.exe --f2f-port 25572 --dir /mnt/d/Prog/AlphaMine/engine/userdir_p
  --server-port 25567 --server-name p          (own exe copy, F2F port, --dir, Java server + world copy)
  --impl java [--golden]                       the same session on the Java F2F client (golden: write
                                               golden/<scenario>/ instead of runs/)
  --collision engine                           VoxelCore: player collisions by the engine body (phase 3)
Lockstep server (agents/F2F.md 9): a scenario (or its base) with "server": {"f2f": true} (or --lockstep) starts the
server with --f2f <--server-f2f, default server port + 3> and drives every client tick through f2f_server.Lockstep:
client step (rx barrier) -> server step {1, barriers}; `wait` = wait_check + lockstep ticks (no wall clock, `realtime`
is ignored), `mode` also seeds the server, idle keepalive off. Without it: the real-time server as before.
Scenario "client_b" {"user", "f2f_port", "steps"}: a second Java F2F client on the same server, driven through
its steps before the first client connects and left idle (its F2F idle keepalive keeps it connected) — the
other player for layer_entities_player. F2F `input.keys` names that are digit strings are LWJGL key codes
(agents/F2F.md 7.1): for impl=vc they are translated to engine key names ("2" -> "1", "11" -> "0").
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
VC_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(VC_ROOT, "tools", "mcp"))
sys.path.insert(0, os.path.join(VC_ROOT, "tools", "reference"))
import voxelcore_mcp as V  # noqa: E402
import compare as cmp  # noqa: E402

ALPHA = "/mnt/d/Prog/AlphaMine"
SCEN = os.path.join(VC_ROOT, "tools", "scenarios", "alpha")
# session parameters (main() sets them from the command line)
CFG = {"impl": "vc", "port": None, "ls": None}
# commands that advance the game: in lockstep mode they go through f2f_server.Lockstep (client + server ticks)
LS_CMDS = ("step", "wait", "gui", "connect", "mode", "input")
LWJGL_DIGITS = {str(c): str((c - 1) % 10) for c in range(2, 12)}   # KEY_1 = 2 ... KEY_0 = 11


def win(p):
    return "D:\\" + p[len("/mnt/d/"):].replace("/", "\\") if p.startswith("/mnt/d/") else p


def load(name):
    with open(os.path.join(SCEN, name + ".json"), encoding="utf-8") as f:
        scn = json.load(f)
    prefix = []
    if scn.get("base"):
        base = load(scn["base"])
        until = scn.get("base_until", "mode")
        for st in base["_prefix"] + base["_body"]:
            if st.get("cmd") == until:
                break
            prefix.append(st)
    elif name == "alpha_spawn":
        # the shared preparation of the layer scenarios = alpha_spawn up to the first mode
        steps = scn["steps"]
        k = next(i for i, s in enumerate(steps) if s["cmd"] == "mode")
        prefix, scn["steps"] = steps[:k], steps[k:]
    scn["_prefix"] = prefix
    scn["_body"] = list(scn.get("steps", []))
    return scn


def scenario_size(scn):
    """agents/F2F.md 8: frame size of a scenario = its "size" field (else the base scenario's setup.client.size),
    854x480 by default; golden and run must have the same size."""
    if scn.get("size"):
        return scn["size"]
    if scn.get("base"):
        return scenario_size(load(scn["base"]))
    return ((scn.get("setup") or {}).get("client") or {}).get("size") or "854x480"


def lockstep_of(scn):
    """True if the scenario (or its base chain) declares "server": {"f2f": true} (agents/F2F.md 9)."""
    while scn:
        srv = scn.get("server") or (scn.get("setup") or {}).get("server") or {}
        if "f2f" in srv:
            return bool(srv["f2f"])
        scn = load(scn["base"]) if scn.get("base") else None
    return False


def client_call(cmd, args=None, timeout=None):
    """Raw F2F call of the session's client (not journaled; Lockstep issues several per tick)."""
    return V.AM["f2f"](CFG["impl"], cmd, args or {}, port=CFG["port"], timeout=timeout)


def start_lockstep(f2f_port, user=None):
    """Connect to the lockstep server and bind it to the session's client (CFG["ls"])."""
    from f2f_server import F2FServer, Lockstep
    srv = F2FServer(f2f_port)
    ls = Lockstep(srv, client_call, CFG["impl"], user=user or "Player")
    r = ls.sync(keepalive=False)   # idle keepalive off from the start: no packet in a random server tick
    if not r.get("ok"):
        raise SystemExit("lockstep: client sync failed: %s" % r.get("error"))
    CFG["ls"] = ls
    print("lockstep server :%d %s, client user %s" % (f2f_port, json.dumps(srv.hello()), ls.user), flush=True)
    return ls


def f2f(cmd, args=None, timeout=600):
    if cmd == "input" and CFG["impl"] == "vc" and (args or {}).get("keys"):
        args = dict(args, keys={LWJGL_DIGITS.get(k, k): v for k, v in args["keys"].items()})
    if CFG.get("ls") is not None and cmd in LS_CMDS:
        return CFG["ls"].run(cmd, args or {}, timeout=timeout)
    r = V.call_tool("am_f2f", {"impl": CFG["impl"], "cmd": cmd, "args": args or {}, "timeout": timeout,
                               "port": CFG["port"]})
    txt = r["content"][0]["text"]
    if r.get("isError"):
        return {"ok": False, "error": txt}
    try:
        return {"ok": True, "result": json.loads(txt)}
    except ValueError:
        return {"ok": True, "result": txt}


def check_expect(expect, st):
    bad = []
    import re
    if "screen" in expect and not re.fullmatch(expect["screen"], st.get("screen") or ""):
        bad.append("screen %s != %s" % (st.get("screen"), expect["screen"]))
    p = st.get("player") or {}
    if "on_ground" in expect and bool(p.get("onGround")) != bool(expect["on_ground"]):
        bad.append("onGround %s" % p.get("onGround"))
    if "near" in expect:
        x, y, z = expect["near"][:3]
        r = expect["near"][3] if len(expect["near"]) > 3 else 1.0
        d = ((p.get("x", 1e9) - x) ** 2 + (p.get("y", 1e9) - y) ** 2 + (p.get("z", 1e9) - z) ** 2) ** 0.5
        if d > r:
            bad.append("player at %.4f %.4f %.4f, further than %s from %s" % (p.get("x", 0), p.get("y", 0), p.get("z", 0), r, expect["near"][:3]))
    if "health" in expect and p.get("health") != expect["health"]:
        bad.append("health %s != %s" % (p.get("health"), expect["health"]))
    for k in ("yaw", "pitch"):
        if k in expect and abs(p.get(k, 1e9) - expect[k]) > 1e-3:
            bad.append("%s %s != %s" % (k, p.get(k), expect[k]))
    if "entities" in expect:
        n = len((st.get("world") or {}).get("entities") or [])
        if n < int(expect["entities"]):
            bad.append("entities %d < %s" % (n, expect["entities"]))
    return bad


def run_steps(steps, out_dir, rep, first=0):
    for i, step in enumerate(steps, first):
        cmd, args = step["cmd"], dict(step.get("args") or {})
        t0 = time.time()
        e = {"n": i, "cmd": cmd, "args": args}
        if cmd == "shot":
            name = step.get("name") or "%02d" % i
            path = os.path.join(out_dir, name + ".png")
            r = f2f("shot", {"path": win(path)})
            if r["ok"]:
                e["path"] = win(path)
                rep["shots"].append({"name": name, "path": path, "sha256": r["result"].get("sha256")})
        elif cmd == "look":
            st = f2f("state", {"radius": 0})
            p = (st.get("result") or {}).get("player") or {}
            dx = int(round((float(args.get("yaw", p.get("yaw", 0))) - p.get("yaw", 0)) / 0.15))
            dy = int(round((p.get("pitch", 0) - float(args.get("pitch", p.get("pitch", 0)))) / 0.15))
            r = f2f("input", {"mouse": {"dx": dx, "dy": dy}})
            if r["ok"]:
                r["result"] = {"dx": dx, "dy": dy, "from": [p.get("yaw"), p.get("pitch")]}
        elif cmd == "chat_age":
            # harness step (not F2F): step so that the newest chat line matching `match` has updateCounter == age
            # (the server echo arrives on a wall-clock tick; the fade of a line depends on its exact age)
            import re
            st = f2f("state", {"radius": 0})
            lines = (st.get("result") or {}).get("chat") or []
            line = next((c for c in lines if re.search(args.get("match", "."), c.get("text") or "")), None)
            if not line:
                r = {"ok": False, "error": "chat_age: no chat line matches %r: %s" % (args.get("match"), lines)}
            else:
                n = int(args["age"]) - int(line.get("age", 0))
                if n < 0:
                    r = {"ok": False, "error": "chat_age: line already %s ticks old" % line.get("age")}
                else:
                    r = f2f("step", {"ticks": n, "frames": 1}) if n > 0 else {"ok": True, "result": {}}
                    if r["ok"]:
                        r["result"] = dict(r.get("result") or {}, stepped=n, from_age=line.get("age"))
        else:
            r = f2f(cmd, args, timeout=step.get("limit", 600))
        if cmd == "render" and r["ok"] and CFG["impl"] == "vc" and isinstance(r.get("result"), dict) \
                and isinstance(r["result"].get("layers"), dict):
            # the engine does not forward `render` to the pack: pass the layer state to the pack handler (phase 4:
            # EntityPickupFX is drawn by the pack and belongs to the `particles` layer as in Java)
            f2f("layers", {"layers": r["result"]["layers"]})
        if cmd == "render" and r["ok"] and (r.get("result") or {}).get("rebuilt"):
            # VoxelCore F2F build: after a lighting toggle the engine re-meshes at most 4 chunks per frame ->
            # extra frames without ticks (time and alpha ticks do not move) so the shot sees rebuilt chunks
            st = f2f("status").get("result") or {}
            n = int((st.get("engine_chunks") or 1000) / 4) + 10
            sr = f2f("step", {"ticks": 0, "frames": n})
            e["settle_frames"] = n
            if not sr["ok"]:
                r = sr
        e["dur"] = round(time.time() - t0, 2)
        e["ok"] = r["ok"]
        e["result" if r["ok"] else "error"] = r.get("result") if r["ok"] else r.get("error")
        if r["ok"] and step.get("expect"):
            st = f2f("state", {"radius": 4}).get("result") or {}
            bad = check_expect(step["expect"], st)
            if bad:
                e["ok"], e["error"] = False, "expect: " + "; ".join(bad)
                e["state_player"] = st.get("player")
        rep["steps"].append(e)
        short = json.dumps(e.get("result"), ensure_ascii=False)[:150] if e["ok"] else e.get("error")
        print("%2d %-10s %6.2f s %s %s" % (i, cmd, e["dur"], "ok " if e["ok"] else "ERR", short), flush=True)
        if not e["ok"] and not step.get("optional"):
            return False
    return True


def run_client_b(spec, server_port):
    """Second Java F2F client (username spec["user"], F2F port spec["f2f_port"]) on the same server: started with
    ref/start_client.ps1, driven through spec["steps"] (F2F commands + harness look), then left idle."""
    sys.path.insert(0, HERE)
    import f2f_client
    port = int(spec.get("f2f_port", 25580))
    user = spec.get("user", "AlphaMineB")
    log = "client_b_%d" % port
    ps = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    script = win(os.path.join(ALPHA, "ref", "start_client.ps1"))
    out = subprocess.run([ps, "-NoProfile", "-NonInteractive", "-Command",
                          "& '%s' -F2F %d -Size 854x480 -Server 127.0.0.1:%d -Username %s -LogName %s -AssetIndex a1.0.14-local"
                          % (script, port, server_port, user, log)], capture_output=True, text=True, cwd="/mnt/c")
    pid = (out.stdout.strip().splitlines() or [""])[-1].strip()
    if not pid.isdigit():
        raise SystemExit("client B start failed: %s %s" % (out.stdout, out.stderr))
    c = f2f_client.F2F(port, timeout=600.0, connect_timeout=90)
    print("client B pid %s F2F :%d user %s: %s" % (pid, port, user, json.dumps(c.call("hello"))[:200]), flush=True)
    for i, st in enumerate(spec.get("steps", [])):
        cmd, args = st["cmd"], dict(st.get("args") or {})
        t0 = time.time()
        if cmd == "look":
            s = c.call("state", {"radius": 0})
            p = s.get("player") or {}
            dx = int(round((float(args.get("yaw", p.get("yaw", 0))) - p.get("yaw", 0)) / 0.15))
            dy = int(round((p.get("pitch", 0) - float(args.get("pitch", p.get("pitch", 0)))) / 0.15))
            r = c.call("input", {"mouse": {"dx": dx, "dy": dy}})
        else:
            r = c.call(cmd, args, timeout=st.get("limit", 600))
        print("B%2d %-8s %6.2f s %s" % (i, cmd, time.time() - t0, json.dumps(r)[:150]), flush=True)
    s = c.call("state", {"radius": 0})
    print("client B idle at %s" % json.dumps({k: s.get("player", {}).get(k) for k in ("x", "y", "z", "yaw", "pitch", "onGround")}),
          flush=True)
    return {"pid": int(pid), "port": port, "conn": c, "state": s.get("player")}


def stop_client_b(b):
    if not b:
        return
    try:
        b["conn"].call("quit", timeout=10)
    except Exception:
        pass
    b["conn"].close()
    subprocess.run(["/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-NoProfile", "-Command",
                    "Stop-Process -Id %d -Force -ErrorAction SilentlyContinue" % b["pid"]], cwd="/mnt/c")


def compare_shots(rep, name, out_dir, clear):
    rows = []
    for s in rep["shots"]:
        g = os.path.join(ALPHA, "golden", name, s["name"] + ".png")
        if not os.path.exists(g):
            rows.append({"name": s["name"], "error": "no golden " + win(g)})
            continue
        A, B = cmp.load(g), cmp.load(s["path"])
        if A.shape != B.shape:   # F2F.md 8: golden and run of different sizes are not compared
            rows.append({"name": s["name"], "error": "size mismatch: golden %dx%d, run %dx%d" % (
                A.shape[1], A.shape[0], B.shape[1], B.shape[0])})
            continue
        m = cmp.metrics(A, B, 0, clear,
                        os.path.join(out_dir, s["name"] + "_diff.png"), os.path.join(out_dir, s["name"] + "_heat.png"))
        m["name"] = s["name"]
        rows.append(m)
    rep["compare"] = rows
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenarios", nargs="+")
    ap.add_argument("--keep", action="store_true", help="leave server and client running")
    ap.add_argument("--no-server", action="store_true", help="use the running server_v as is")
    ap.add_argument("--size", default=None, help="check only: the frame size comes from the scenario (F2F.md 8)")
    ap.add_argument("--impl", default="vc", choices=["vc", "java"])
    ap.add_argument("--golden", action="store_true", help="impl=java: write golden/<scenario>/")
    ap.add_argument("--exe", default=None, help="VoxelCore exe copy in engine\\ (default VoxelCoreF2F-v.exe)")
    ap.add_argument("--f2f-port", type=int, default=None)
    ap.add_argument("--dir", default=None, help="VoxelCore --dir (WSL path)")
    ap.add_argument("--server-port", type=int, default=25566)
    ap.add_argument("--server-name", default="v")
    ap.add_argument("--collision", default=None, choices=["lua", "engine"])
    ap.add_argument("--tag", default=None, help="runs/<stamp>_<tag>")
    ap.add_argument("--lockstep", action="store_true", help="lockstep server even if the scenario does not declare it")
    ap.add_argument("--server-f2f", type=int, default=None, help="F2F port of the lockstep server (default server port + 3)")
    ap.add_argument("--legacy", action="store_true", help="old path: own exe/ports/server (default: delegate to labd)")
    o = ap.parse_args()
    # этап 2а: по умолчанию прогон отдаётся демону лаборатории (tools/lab, журнал, аренды); старый путь — там, где у
    # лаборатории пока нет нужного (lockstep-сервер, collision, no-server/keep) или по --legacy
    import lab_delegate
    why = ("--legacy" if o.legacy else "lockstep server (F2F.md 9): labd has no server_step hook yet"
           if o.lockstep or any(lockstep_of(load(n)) for n in o.scenarios) else "--collision" if o.collision
           else "--no-server" if o.no_server else "--keep" if o.keep else None)
    if why is None:
        return lab_delegate.delegate(o.scenarios, impl=o.impl, golden="promote" if o.golden else "compare",
                                     runner="run_vc_scenario")
    lab_delegate.note("run_vc_scenario", why)
    CFG["impl"] = o.impl
    CFG["port"] = o.f2f_port
    scns = [(n, load(n)) for n in o.scenarios]
    sizes = sorted({scenario_size(s) for _, s in scns})
    if len(sizes) > 1:
        raise SystemExit("scenarios with different frame sizes in one session: %s (F2F.md 8)" % sizes)
    if o.size and o.size != sizes[0]:
        raise SystemExit("--size %s differs from the scenario size %s (F2F.md 8)" % (o.size, sizes[0]))
    o.size = sizes[0]
    lockstep = o.lockstep or lockstep_of(scns[0][1])
    f2f_srv = o.server_f2f or o.server_port + 3
    prefix = scns[0][1]["_prefix"]
    for n, s in scns:
        if s["_prefix"] != prefix:
            raise SystemExit("%s: other preparation than %s" % (n, scns[0][0]))
    stamp = time.strftime("%Y%m%d_%H%M%S")
    root = os.path.join(ALPHA, "runs", stamp + "_" + (o.tag or ("vc_p2" if o.impl == "vc" else o.impl)))
    os.makedirs(root, exist_ok=True)
    session = {"started": stamp, "scenarios": o.scenarios, "steps": [], "shots": [], "timing": {},
               "server_mode": "lockstep" if lockstep else "realtime"}
    t_all = time.time()
    ok = True
    results = []
    try:
        if not o.no_server:
            t0 = time.time()
            # world of the scenario setup (alpha_spawn: world_b), as am_scenario would copy it
            world = ((scns[0][1].get("setup") or {}).get("server") or {}).get("world") or "world_a"
            if scns[0][1].get("base"):
                world = ((load(scns[0][1]["base"]).get("setup") or {}).get("server") or {}).get("world") or world
            session["world"] = world
            b_spec = scns[0][1].get("client_b") or {}
            out = subprocess.run([sys.executable, os.path.join(HERE, "server_v.py"), "start", "--world", world,
                                  "--port", str(o.server_port), "--name", o.server_name]
                                 + (["--op", b_spec["user"]] if b_spec.get("user") else [])
                                 + (["--f2f", str(f2f_srv)] if lockstep else []),
                                 capture_output=True, text=True)
            print(out.stdout.strip() or out.stderr.strip(), flush=True)
            if out.returncode:
                raise SystemExit("server_v failed")
            session["timing"]["server"] = round(time.time() - t0, 1)
        if scns[0][1].get("client_b"):
            t0 = time.time()
            session["client_b"] = run_client_b(scns[0][1]["client_b"], o.server_port)
            session["timing"]["client_b"] = round(time.time() - t0, 1)
        t0 = time.time()
        cargs = {"action": "start", "impl": o.impl, "server": "127.0.0.1:%d" % o.server_port, "size": o.size}
        if o.f2f_port:
            cargs["f2f_port"] = o.f2f_port
        if o.exe:
            cargs["exe"] = o.exe
        if o.dir:
            cargs["dir"] = o.dir
        r = V.call_tool("am_client", cargs)
        print(r["content"][0]["text"], flush=True)
        if r.get("isError"):
            raise SystemExit("client failed")
        session["timing"]["client"] = round(time.time() - t0, 1)
        if lockstep:
            if scns[0][1].get("client_b"):
                raise SystemExit("lockstep: a second client (client_b) is not supported yet")
            start_lockstep(f2f_srv)
        if o.collision and o.impl == "vc":
            print("collision:", f2f("collision", {"mode": o.collision}), flush=True)
        t0 = time.time()
        ok = run_steps(prefix, root, session)
        session["timing"]["prefix"] = round(time.time() - t0, 1)
        for n, s in scns if ok else []:
            out_dir = os.path.join(ALPHA, "golden", n) if o.golden else os.path.join(root, n)
            os.makedirs(out_dir, exist_ok=True)
            rep = {"scenario": n, "impl": o.impl, "dir": win(out_dir), "steps": [], "shots": []}
            print("--- %s" % n, flush=True)
            t0 = time.time()
            rep["ok"] = run_steps(s["_body"], out_dir, rep, first=len(prefix))
            rep["dur"] = round(time.time() - t0, 1)
            clear = s.get("clear") or [0, 0, 0]
            for st in s["_body"]:
                if st["cmd"] == "render" and (st.get("args") or {}).get("clear"):
                    clear = st["args"]["clear"]
            rows = compare_shots(rep, n, out_dir, clear) if not o.golden else []
            st = f2f("status").get("result")
            rep["status"] = st
            with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as f:
                json.dump(rep, f, ensure_ascii=False, indent=1, default=str)
            results.append((n, rows))
            ok = ok and rep["ok"]
        session["status"] = f2f("status").get("result")
        if CFG.get("ls"):
            session["lockstep"] = CFG["ls"].report()
            session["server_state"] = CFG["ls"].srv.state()
    finally:
        if not o.keep:
            sargs = {"action": "stop", "impl": o.impl}
            if o.f2f_port:
                sargs["f2f_port"] = o.f2f_port
            if o.exe:
                sargs["exe"] = o.exe
            V.call_tool("am_client", sargs)
            stop_client_b(session.pop("client_b", None))
            subprocess.run([sys.executable, os.path.join(HERE, "server_v.py"), "stop", "--name", o.server_name])
        elif session.get("client_b"):
            session["client_b"] = {k: v for k, v in session["client_b"].items() if k != "conn"}
    session["ok"] = ok
    session["dur"] = round(time.time() - t_all, 1)
    with open(os.path.join(root, "session.json"), "w", encoding="utf-8") as f:
        json.dump(session, f, ensure_ascii=False, indent=1, default=str)
    print("=== %s in %.0f s -> %s  timing %s" % ("OK" if ok else "STOPPED", session["dur"], win(root),
                                                 json.dumps(session["timing"])))
    for n, rows in results:
        for m in rows:
            if "error" in m:
                print("%-20s %-9s %s" % (n, m["name"], m["error"]))
            else:
                print("%-20s %-9s identical %6.2f%%  coverage golden %6.2f%% vc %6.2f%%  max|d| %3d  mean|d| %.1f" % (
                    n, m["name"], m["identical_pct"], m["coverage_a_pct"], m["coverage_b_pct"], m["max_delta"],
                    m["mean_delta"]))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
