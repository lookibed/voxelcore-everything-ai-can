#!/usr/bin/env python3
"""AlphaMine final end-to-end test (agents/F2F.md 8): a pre-recorded tick timeline on the Java reference or on
VoxelCore, keyframe shots and `state` dumps as a series.

  python3 tools/alphamine/e2e/e2e_run.py e2e_walk1 --impl java --golden        # golden/e2e_walk1/
  python3 tools/alphamine/e2e/e2e_run.py e2e_walk1 --impl java --tag e2e_java2  # runs/<stamp>_e2e_java2/e2e_walk1/
  python3 tools/alphamine/e2e/e2e_run.py e2e_walk1 --impl vc --compare          # + e2e_compare.py against golden

Scenario tools/scenarios/alpha/e2e_<name>.json:
  "size"        frame size (854x480 standard, F2F.md 8)
  "setup"       {"world": "world_b",            server world = fresh copy of golden/<world> (--world overrides)
                 "base": "alpha_spawn",         F2F steps of that scenario up to its first `mode` (connect, waits, /tp)
                 "steps": [...],                extra F2F/harness steps before mode (run_vc_scenario.py format)
                 "tp": [x, y, z],               optional /tp + wait near/chunks/on_ground (only into the loaded radius)
                 "look": {"yaw", "pitch"},      harness look + step{1,1} before mode
                 "mode": {"seed", "clear_chat", "options"},  F2F mode (tick 0 = right after it)
                 "render": {...}}               optional F2F render (layers); default everything on
  "ticks"       timeline length; "pace_ms" wall pacing per tick (50 = the server's clock; 0 = as fast as possible)
  "timeline"    [{"tick": N, "input": {keys, mouse{dx,dy,buttons,wheel,x,y}, chars}}, {"tick": N, "chat": "..."},
                 {"tick": N, "gui": {click|key|chars...}}, "comment": "..."] - applied before the step N -> N+1
  "keyframes"   [N, ...] + "keyframes_every": K  -> shot after the step that reaches tick N (kf_NNNN.png)
  "state_every" K -> `state {radius: state_radius}` after every K-th tick (and at every keyframe) -> states.jsonl
  "regions"     named rects [x0, y0, x1, y1) for the per-region breakdown of e2e_compare.py (first match wins)

Lockstep server (agents/F2F.md 9): "server": {"f2f": true} in the scenario (or --lockstep) starts the server with
--f2f (--server-f2f, default server port + 3), the setup runs through f2f_server.Lockstep (wait = wait_check + lockstep
ticks) and every timeline tick is: client step {1,1, rx_bytes} -> server step {1, barriers}. No wall pacing: pace_ms and
the schedule shift do not apply; the series is repeatable byte for byte (DETERMINISM.md 1.2). Without it: real time.

--compare: java run -> e2e_compare.py golden vs run, its compare.json is kept as golden/<name>/reference_noise.json
(what the reference itself does not repeat); vc run -> the same compare with --baseline reference_noise.json.

Execution per tick N = 0..ticks-1: wait for the wall slot t0 + N*pace, apply the entries of tick N, then
`step {ticks:1, frames:1}` (a `gui` entry is itself that step: Java F2FAgent.gui and alpha_vc.gui do step{1,1});
shot at keyframes, state every K ticks. No `wait` inside the timeline: waiting for chunks/network is setup only.
The step is virtual on both sides (no realtime inside); the harness paces wall time so the real-time server sees
the same timeline from both clients. Packets still arrive at slightly different ticks: every state dump keeps
world.world_packets / last_world_packet_tick for that.

Isolation defaults (agent E, 01.10): VoxelCoreF2F-e.exe, F2F :25575, --dir engine/userdir_e, Java client F2F :25582,
server_v.py --name e --port 25570.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
AM_DIR = os.path.dirname(HERE)
sys.path.insert(0, AM_DIR)
import run_vc_scenario as R  # noqa: E402  (voxelcore_mcp, am_* tools, alpha_spawn prefix, look/expect steps)

V = R.V
ALPHA = R.ALPHA
SCEN = R.SCEN
win = R.win

DEFAULT_REGIONS = {
    # 854x480, GUI scale 2 (ScaledResolution: 854/3 < 320): hotbar 364x44 at (245, 436), hearts above it
    "hotbar": [245, 400, 609, 480],
    "crosshair": [411, 224, 443, 256],
    # chat lines (GuiIngame: bottom line at height-48 GUI, 10 lines up) and the GuiChat input line
    "chat": [0, 190, 660, 480],
    # first-person hand / held item
    "hand": [500, 240, 854, 480],
}


def load_e2e(name):
    path = os.path.join(SCEN, name + ".json")
    with open(path, encoding="utf-8") as f:
        scn = json.load(f)
    scn.setdefault("name", name)
    ticks = int(scn["ticks"])
    by_tick = {}
    for e in scn.get("timeline", []):
        t = int(e["tick"])
        if not 0 <= t < ticks:
            raise SystemExit("%s: timeline tick %d outside 0..%d" % (name, t, ticks - 1))
        if not any(k in e for k in ("input", "chat", "gui")):
            raise SystemExit("%s: timeline entry at %d has no input/chat/gui" % (name, t))
        g = e.get("gui")
        if g and (int(g.get("ticks", 1)) != 1 or int(g.get("frames", 1)) != 1):
            raise SystemExit("%s: gui entry at %d must step exactly 1 tick + 1 frame" % (name, t))
        by_tick.setdefault(t, []).append(e)
    kf = set(int(k) for k in scn.get("keyframes", []))
    every = int(scn.get("keyframes_every", 0))
    if every:
        kf |= set(range(every, ticks + 1, every))
    bad = [k for k in kf if not 1 <= k <= ticks]
    if bad:
        raise SystemExit("%s: keyframes outside 1..%d: %s" % (name, ticks, bad))
    scn["_by_tick"] = by_tick
    scn["_keyframes"] = sorted(kf)
    return scn


def setup_steps(scn):
    s = scn.get("setup") or {}
    steps = []
    if s.get("base"):   # the base scenario's steps up to its first `mode` (alpha_spawn, dev_base, ...)
        b = R.load(s["base"])
        for st in b["_prefix"] + b["_body"]:
            if st.get("cmd") == "mode":
                break
            steps.append(st)
    steps += list(s.get("steps") or [])
    if s.get("tp"):
        x, y, z = s["tp"]
        steps += [
            {"cmd": "chat", "args": {"text": "/tp %s %s %s" % (x, y, z)}},
            {"cmd": "wait", "args": {"near": [x, y + 1.62, z, 3], "max_frames": 600}},
            {"cmd": "wait", "args": {"new_chunks": 1, "net_idle": 60, "max_frames": 6000}},
            {"cmd": "wait", "args": {"on_ground": True, "still": 40, "max_frames": 1200},
             "expect": {"on_ground": True, "screen": "ingame", "health": 20}},
        ]
    if s.get("look"):
        steps += [{"cmd": "look", "args": s["look"]}, {"cmd": "step", "args": {"ticks": 1, "frames": 1}}]
    mode = {"fixed": True, "seed": 20260930, "clear_chat": True}
    mode.update(s.get("mode") or {})
    steps.append({"cmd": "mode", "args": mode})
    if s.get("render"):
        steps.append({"cmd": "render", "args": s["render"]})
    return steps


def raw(cmd, args=None, timeout=120):
    """Direct F2F call (not journaled: ~2000 calls per run would flood the MCP journal)."""
    impl, port = R.CFG["impl"], R.CFG["port"]
    if cmd == "input" and impl == "vc" and (args or {}).get("keys"):
        args = dict(args, keys={R.LWJGL_DIGITS.get(k, k): v for k, v in args["keys"].items()})
    return V.AM["f2f"](impl, cmd, args or {}, port=port, timeout=timeout)


def run_timeline(scn, out_dir, log):
    ticks = int(scn["ticks"])
    ls = R.CFG.get("ls")
    pace = 0.0 if ls is not None else float(scn.get("pace_ms", 50)) / 1000.0
    K = int(scn.get("state_every", 5))
    radius = int(scn.get("state_radius", 8))
    kfs = set(scn["_keyframes"])
    states = open(os.path.join(out_dir, "states.jsonl"), "w", encoding="utf-8")
    shots, events, lags, errors, mism = [], [], [], [], []
    t0 = time.time()
    shift = 0.0
    done = 0   # ticks whose step completed
    ok = True
    try:
        for t in range(ticks):
            # never faster than the pace: a stall (GC, slow shot) shifts the rest of the schedule instead of
            # being caught up with a burst of ticks the real-time server would see compressed
            if pace > 0:   # lockstep: no wall clock at all
                target = t0 + t * pace + shift
                d = target - time.time()
                if d > 0:
                    time.sleep(d)
                elif d < 0:
                    shift -= d
            lags.append(round(shift * 1000, 1))
            stepped = None
            for e in scn["_by_tick"].get(t, []):
                if "input" in e:
                    r = raw("input", e["input"])
                    events.append({"tick": t, "cmd": "input", "args": e["input"], "ok": r.get("ok"),
                                   "result": r.get("result") if r.get("ok") else r.get("error")})
                if "chat" in e:
                    r = raw("chat", {"text": e["chat"]})
                    events.append({"tick": t, "cmd": "chat", "args": e["chat"], "ok": r.get("ok"),
                                   "result": r.get("result") if r.get("ok") else r.get("error")})
                if "gui" in e:
                    g = dict(e["gui"], ticks=1, frames=1)
                    # lockstep: Lockstep.run("gui") = event + client tick + server tick; else vc: alpha_vc.gui (event +
                    # step{1,1}); java: F2FAgent.gui steps itself
                    r = R.f2f("gui", g)
                    events.append({"tick": t, "cmd": "gui", "args": e["gui"], "ok": r.get("ok"),
                                   "result": r.get("result") if r.get("ok") else r.get("error")})
                    if r.get("ok"):
                        stepped = r
                for ev in events[-3:]:
                    if ev["tick"] == t and not ev["ok"] and ev not in errors:
                        errors.append(ev)
                        print("tick %d: %s failed: %s" % (t, ev["cmd"], ev["result"]), flush=True)
            if stepped is None:
                stepped = ls.tick(frames=1) if ls is not None else raw("step", {"ticks": 1, "frames": 1})
            if not stepped.get("ok"):
                errors.append({"tick": t, "cmd": "step", "error": stepped.get("error")})
                print("tick %d: step failed: %s" % (t, stepped.get("error")), flush=True)
                ok = False
                break
            n = t + 1
            done = n
            got = (stepped.get("result") or {}).get("tick")
            if got is not None and int(got) != n:
                mism.append([n, got])   # informational: the reply counter of the implementation
            if n in kfs:
                path = os.path.join(out_dir, "kf_%04d.png" % n)
                r = raw("shot", {"path": win(path)})
                if r.get("ok"):
                    shots.append({"tick": n, "file": os.path.basename(path), "sha256": r["result"].get("sha256")})
                else:
                    errors.append({"tick": n, "cmd": "shot", "error": r.get("error")})
            if n % K == 0 or n in kfs:
                r = raw("state", {"radius": radius})
                rec = {"tick": n, "kf": n in kfs, "wall_s": round(time.time() - t0, 3), "lag_ms": lags[-1]}
                if ls is not None:
                    rec["server_tick"] = (ls.srv.last or {}).get("tick")
                    rec["net"] = {"tx": ls.tx, "rx": ls.rx}
                if r.get("ok"):
                    rec["state"] = r["result"]
                else:
                    rec["error"] = r.get("error")
                    errors.append({"tick": n, "cmd": "state", "error": r.get("error")})
                states.write(json.dumps(rec, ensure_ascii=False) + "\n")
                states.flush()
            if n % 50 == 0:
                print("tick %4d  wall %6.1f s  shift %6.0f ms  shots %d  errors %d" % (
                    n, time.time() - t0, lags[-1], len(shots), len(errors)), flush=True)
    except Exception as exc:   # the client died (connection closed): keep the series up to here
        errors.append({"tick": t, "cmd": "exception", "error": "%s: %s" % (type(exc).__name__, exc)})
        print("tick %d: %s: %s" % (t, type(exc).__name__, exc), flush=True)
        ok = False
    finally:
        states.close()
    if ls is not None:
        log["lockstep"] = ls.report()
    log["timeline"] = {"ok": ok, "ticks": ticks, "last_tick": done, "pace_ms": pace * 1000, "wall_s": round(time.time() - t0, 1),
                       "schedule_shift_ms": lags[-1] if lags else None,
                       "late_ticks": sum(1 for a, b in zip([0.0] + lags, lags) if b > a)}
    log["tick_mismatch"] = {"count": len(mism), "first": mism[:5]}
    log["lags_ms"] = lags
    log["shots"] = shots
    log["events"] = events
    log["errors"] = errors
    return ok and not [e for e in errors if e["cmd"] in ("step", "shot", "state")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", help="scenario tools/scenarios/alpha/<name>.json (e2e_*)")
    ap.add_argument("--impl", default="vc", choices=["vc", "java"])
    ap.add_argument("--golden", action="store_true", help="impl=java: write golden/<name>/")
    ap.add_argument("--world", default=None, help="server world (golden/<world>) instead of setup.world")
    ap.add_argument("--tag", default=None)
    ap.add_argument("--pace-ms", type=float, default=None, help="override the scenario pace_ms")
    ap.add_argument("--keep", action="store_true", help="leave server and client running")
    ap.add_argument("--exe", default="VoxelCoreF2F-e.exe")
    ap.add_argument("--vc-port", type=int, default=25575)
    ap.add_argument("--java-port", type=int, default=25582)
    ap.add_argument("--dir", default="/mnt/d/Prog/AlphaMine/engine/userdir_e")
    ap.add_argument("--server-port", type=int, default=25570)
    ap.add_argument("--server-name", default="e")
    ap.add_argument("--compare", action="store_true", help="after the run: e2e_compare.py golden/<name> <run>")
    ap.add_argument("--lockstep", action="store_true", help="lockstep server even if the scenario does not declare it")
    ap.add_argument("--server-f2f", type=int, default=None, help="F2F port of the lockstep server (default server port + 3)")
    ap.add_argument("--golden-dir", default=None, help="compare against this golden directory (default golden/<name>)")
    ap.add_argument("--legacy", action="store_true", help="old path: own exe/ports/server (default: delegate to labd)")
    o = ap.parse_args()
    # этап 2а: прогон — демону лаборатории (lab run; --golden -> lab golden promote; --compare -> сравнение серий с
    # golden); старый путь — --legacy, lockstep (server.f2f / --lockstep), --keep, --world, --pace-ms, --golden-dir
    import lab_delegate
    _scn = json.load(open(os.path.join(SCEN, o.name + ".json"), encoding="utf-8"))
    why = ("--legacy" if o.legacy else "lockstep server (F2F.md 9): labd has no server_step hook yet"
           if o.lockstep or (_scn.get("server") or {}).get("f2f") or ((_scn.get("setup") or {}).get("server") or {}).get("f2f")
           else "--keep" if o.keep else "--world" if o.world else "--pace-ms" if o.pace_ms is not None
           else "--golden-dir" if o.golden_dir else None)
    if why is None:
        if o.golden and o.impl != "java":
            raise SystemExit("--golden is the Java reference only")
        return lab_delegate.delegate([o.name], impl=o.impl, golden="promote" if o.golden else (
            "compare" if o.compare else None), runner="e2e_run")
    lab_delegate.note("e2e_run", why)
    if o.golden and o.impl != "java":
        raise SystemExit("--golden is the Java reference only")
    scn = load_e2e(o.name)
    if o.pace_ms is not None:
        scn["pace_ms"] = o.pace_ms
    size = scn.get("size") or "854x480"
    world = o.world or (scn.get("setup") or {}).get("world") or "world_b"
    if not os.path.isdir(os.path.join(ALPHA, "golden", world)):
        raise SystemExit("no world %s" % win(os.path.join(ALPHA, "golden", world)))
    R.CFG["impl"] = o.impl
    R.CFG["port"] = o.vc_port if o.impl == "vc" else o.java_port
    lockstep = o.lockstep or bool(((scn.get("server") or {}).get("f2f")) or ((scn.get("setup") or {}).get("server") or {}).get("f2f"))
    f2f_srv = o.server_f2f or o.server_port + 3
    stamp = time.strftime("%Y%m%d_%H%M%S")
    if o.golden:
        out_dir = os.path.join(ALPHA, "golden", o.name)
        if os.path.isdir(out_dir):
            for fn in os.listdir(out_dir):   # only the files this harness writes
                if fn.startswith("kf_") or fn in ("states.jsonl", "run.json", "reference_noise.json"):
                    os.remove(os.path.join(out_dir, fn))
    else:
        out_dir = os.path.join(ALPHA, "runs", "%s_%s" % (stamp, o.tag or "e2e_" + o.impl), o.name)
    os.makedirs(out_dir, exist_ok=True)
    log = {"scenario": o.name, "impl": o.impl, "golden": o.golden, "started": stamp, "size": size, "world": world,
           "ports": {"f2f": R.CFG["port"], "server": o.server_port}, "exe": o.exe if o.impl == "vc" else None,
           "keyframes": scn["_keyframes"], "state_every": scn.get("state_every", 5), "ticks": scn["ticks"],
           "pace_ms": 0 if lockstep else scn.get("pace_ms", 50), "timing": {}, "steps": [], "shots": [],
           "server_mode": "lockstep" if lockstep else "realtime"}
    with open(os.path.join(out_dir, "scenario.json"), "w", encoding="utf-8") as f:
        json.dump({k: v for k, v in scn.items() if not k.startswith("_")}, f, ensure_ascii=False, indent=1)
    t_all = time.time()
    ok = False
    try:
        t0 = time.time()
        out = subprocess.run([sys.executable, os.path.join(AM_DIR, "server_v.py"), "start", "--world", world,
                              "--port", str(o.server_port), "--name", o.server_name]
                             + (["--f2f", str(f2f_srv)] if lockstep else []), capture_output=True, text=True)
        print(out.stdout.strip() or out.stderr.strip(), flush=True)
        if out.returncode:
            raise SystemExit("server_v failed")
        log["timing"]["server"] = round(time.time() - t0, 1)
        t0 = time.time()
        cargs = {"action": "start", "impl": o.impl, "server": "127.0.0.1:%d" % o.server_port, "size": size,
                 "f2f_port": R.CFG["port"]}
        if o.impl == "vc":
            cargs.update(exe=o.exe, dir=o.dir)
        r = V.call_tool("am_client", cargs)
        print(r["content"][0]["text"], flush=True)
        if r.get("isError"):
            raise SystemExit("client failed")
        log["timing"]["client"] = round(time.time() - t0, 1)
        if lockstep:
            R.start_lockstep(f2f_srv)
        t0 = time.time()
        setup = setup_steps(scn)
        ok = R.run_steps(setup, out_dir, log)
        log["timing"]["setup"] = round(time.time() - t0, 1)
        if ok:
            st = raw("state", {"radius": int(scn.get("state_radius", 8))})
            log["state0"] = st.get("result")
            if R.CFG.get("ls"):
                log["server_state0"] = R.CFG["ls"].srv.state()
                log["lockstep_setup"] = R.CFG["ls"].report()
            print("--- timeline %d ticks, %s, %d keyframes, state every %s" % (
                scn["ticks"], "lockstep" if lockstep else "pace %s ms" % scn.get("pace_ms", 50), len(scn["_keyframes"]),
                scn.get("state_every", 5)), flush=True)
            t0 = time.time()
            ok = run_timeline(scn, out_dir, log)
            log["timing"]["timeline"] = round(time.time() - t0, 1)
            if R.CFG.get("ls"):
                log["server_state"] = R.CFG["ls"].srv.state()
        log["status"] = R.f2f("status").get("result") if o.impl == "vc" else None
    finally:
        if not o.keep:
            sargs = {"action": "stop", "impl": o.impl, "f2f_port": R.CFG["port"]}
            if o.impl == "vc":
                sargs["exe"] = o.exe
            V.call_tool("am_client", sargs)
            subprocess.run([sys.executable, os.path.join(AM_DIR, "server_v.py"), "stop", "--name", o.server_name])
        log["ok"] = ok
        log["dur"] = round(time.time() - t_all, 1)
        with open(os.path.join(out_dir, "run.json"), "w", encoding="utf-8") as f:
            json.dump(log, f, ensure_ascii=False, indent=1, default=str)
    tl = log.get("timeline") or {}
    print("=== %s %s in %.0f s -> %s  timing %s  timeline %s" % (
        o.name, "OK" if ok else "STOPPED", log["dur"], win(out_dir), json.dumps(log["timing"]), json.dumps(tl)))
    for e in log.get("errors", [])[:20]:
        print("  error:", json.dumps(e, ensure_ascii=False)[:300])
    if o.compare and not o.golden:
        gdir = o.golden_dir or os.path.join(ALPHA, "golden", o.name)
        noise = os.path.join(gdir, "reference_noise.json")   # compare.json of the last Java-vs-Java pair
        extra = ["--baseline", noise] if o.impl == "vc" and os.path.exists(noise) else []
        subprocess.run([sys.executable, os.path.join(HERE, "e2e_compare.py"), gdir, out_dir] + extra)
        cj = os.path.join(out_dir, "vs_golden", "compare.json")
        if o.impl == "java" and os.path.exists(cj):
            shutil.copy(cj, noise)
            print("reference noise (Java vs Java) -> %s" % win(noise))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
