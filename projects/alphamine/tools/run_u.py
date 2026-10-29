#!/usr/bin/env python3
"""AlphaMine phase 3 (HUD / hand / particles / GUI): private launcher of agent U.

Mirrors run_vc_scenario.py + server_v.py + alpha_vc.am_client with its own values so that nothing is shared with
the other agents (their engine copies, F2F ports, servers, user dirs):
  engine   D:\\Prog\\AlphaMine\\engine\\VoxelCoreF2F-u.exe (copy of VoxelCoreF2F.exe, refreshed when the original is newer)
  F2F      127.0.0.1:25573 (through tools/alphamine/f2f_relay.ps1 from WSL)
  --dir    D:\\Prog\\AlphaMine\\engine\\userdir_u (settings of run\\vc_f2f, junction content\\alphamine -> pack)
  server   Java Alpha server on :25568, run\\server_u + run\\world_u (fresh copy of golden\\<world>), PID run\\server_u.pid
Only processes started here (PIDs in files) are ever stopped.

  python3 tools/alphamine/run_u.py layer_hud layer_gui [--keep] [--prefix full|quick] [--attach]
  python3 tools/alphamine/run_u.py --stop

--prefix quick: connect + world + a few ticks (enough for HUD/GUI, not for the golden hand light / particles).
--keep: leave engine + server running; --attach: reuse them (skip server/engine start and the prefix).
Shots -> D:\\Prog\\AlphaMine\\runs\\<stamp>_vc_u\\<scenario>\\ + report.json, *_diff.png, *_heat.png.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
VC_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(VC_ROOT, "tools", "reference"))
from f2f_client import F2F  # noqa: E402
import compare as cmp  # noqa: E402

ALPHA = "/mnt/d/Prog/AlphaMine"
ENGINE_DIR = os.path.join(ALPHA, "engine")
ENGINE_SRC = os.path.join(ENGINE_DIR, "VoxelCoreF2F.exe")
ENGINE_COPY = os.path.join(ENGINE_DIR, "VoxelCoreF2F-u.exe")
USER_DIR = os.path.join(ENGINE_DIR, "userdir_u")
ENGINE_PIDF = os.path.join(ENGINE_DIR, "userdir_u.pid")
F2F_PORT = 25573
RUN = os.path.join(ALPHA, "run")
SDIR = os.path.join(RUN, "server_u")
WORLD = os.path.join(RUN, "world_u")
SERVER_PIDF = os.path.join(RUN, "server_u.pid")
SERVER_PORT = 25568
SERVER_LOG = os.path.join(ALPHA, "logs", "server_u.err")
SCEN = os.path.join(VC_ROOT, "tools", "scenarios", "alpha")
PS = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
LWJGL_DIGITS = {str(c): str((c - 1) % 10) for c in range(2, 12)}   # KEY_1 = 2 ... KEY_0 = 11 (as run_vc_scenario.py)


def win(p):
    if p.startswith("/mnt/") and len(p) > 6:
        return p[5].upper() + ":\\" + p[7:].replace("/", "\\")
    return p


def ps(script, timeout=120):
    r = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True,
                       timeout=timeout, cwd="/mnt/c")
    return r.stdout.decode("utf-8", "replace").strip()


def pid_alive(pid, name_re, cmd_re=None):
    out = ps("$p = Get-CimInstance Win32_Process -Filter \"ProcessId=%d\"; if ($p) { $p.Name + '|' + $p.CommandLine }"
             % pid)
    if not out or "|" not in out:
        return False
    name, cmdline = out.split("|", 1)
    return bool(re.search(name_re, name, re.I)) and (cmd_re is None or re.search(cmd_re, cmdline, re.I))


def read_pid(path):
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------------------------- server :25568
def server_stop():
    pid = read_pid(SERVER_PIDF)
    if pid and pid_alive(pid, r"java", r"MinecraftServer.*|alphamine\.dir=.*server_u"):
        ps("Stop-Process -Id %d -Force -ErrorAction SilentlyContinue" % pid)
        for _ in range(40):
            if not pid_alive(pid, r"java"):
                break
            time.sleep(0.25)
    if os.path.exists(SERVER_PIDF):
        os.remove(SERVER_PIDF)
    return pid


def server_start(world, timeout=90):
    old = server_stop()
    t0 = time.time()
    src = os.path.join(ALPHA, "golden", world)
    code = ps("$d = '%s'; for ($i = 0; $i -lt 20 -and (Test-Path $d); $i++) { Remove-Item -Recurse -Force $d "
              "-ErrorAction SilentlyContinue; if (Test-Path $d) { Start-Sleep -Milliseconds 250 } }; "
              "robocopy '%s' $d /E /NFL /NDL /NJH /NJS /NP /MT:16 /XF session.lock | Out-Null; $LASTEXITCODE"
              % (win(WORLD), win(src)))
    if not code.strip().isdigit() or int(code.strip()) >= 8:
        raise SystemExit("world copy failed: robocopy %s" % code)
    os.makedirs(SDIR, exist_ok=True)
    game = os.path.join(ALPHA, "ref", "minecraft_server", "game")
    with open(os.path.join(game, "server.properties"), encoding="latin-1") as f:
        props = [l for l in f.read().splitlines() if not l.startswith(("server-port=", "level-name="))]
    props += ["server-port=%d" % SERVER_PORT, "level-name=../world_u"]
    with open(os.path.join(SDIR, "server.properties"), "w", encoding="latin-1") as f:
        f.write("\n".join(props) + "\n")
    shutil.copy(os.path.join(game, "ops.txt"), os.path.join(SDIR, "ops.txt"))
    try:
        os.remove(SERVER_LOG)
    except OSError:
        pass
    out = ps("& '%s' -Dir '%s' -LogName server_u" % (win(os.path.join(ALPHA, "ref", "start_server.ps1")), win(SDIR)))
    pid = out.splitlines()[-1].strip() if out else ""
    if not pid.isdigit():
        raise SystemExit("start_server.ps1: %s" % out)
    with open(SERVER_PIDF, "w") as f:
        f.write(pid)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            log = open(SERVER_LOG, "rb").read().decode("cp866", "replace")
        except OSError:
            log = ""
        if "Done!" in log:
            print("server_u started in %.1f s: pid %s, port %d, world %s (copy of golden/%s)%s" % (
                time.time() - t0, pid, SERVER_PORT, win(WORLD), world, ", stopped old %s" % old if old else ""),
                flush=True)
            return int(pid)
        if "FAILED TO BIND" in log:
            raise SystemExit("server failed:\n" + log[-2000:])
        time.sleep(0.3)
    raise SystemExit("server_u: no Done! in %d s" % timeout)


# ---------------------------------------------------------------------------------------------- engine
def engine_pid():
    pid = read_pid(ENGINE_PIDF)
    if pid and pid_alive(pid, r"VoxelCoreF2F-u"):
        return pid
    return None


def refresh_copy():
    src = os.stat(ENGINE_SRC)
    if os.path.exists(ENGINE_COPY):
        dst = os.stat(ENGINE_COPY)
        if dst.st_size == src.st_size and dst.st_mtime >= src.st_mtime - 2:   # copy2 on /mnt/d drops sub-second mtime
            return "copy up to date"
    shutil.copy2(ENGINE_SRC, ENGINE_COPY)
    return "copy refreshed from VoxelCoreF2F.exe"


def prepare_dir(server):
    os.makedirs(os.path.join(USER_DIR, "content"), exist_ok=True)
    shutil.copy(os.path.join(RUN, "vc_f2f", "settings.toml"), os.path.join(USER_DIR, "settings.toml"))
    link = os.path.join(USER_DIR, "content", "alphamine")
    if not os.path.exists(os.path.join(link, "package.json")):
        if os.path.lexists(link):
            ps("cmd /c rmdir '%s'" % win(link))
        pack = os.path.join(VC_ROOT, "content", "alphamine")
        ps("cmd /c mklink /J '%s' '%s' | Out-Null" % (win(link), win(pack)))
        if not os.path.exists(os.path.join(link, "package.json")):
            raise SystemExit("junction %s -> %s failed" % (link, pack))
    shutil.copy(os.path.join(VC_ROOT, "tools", "scenarios", "alphamine_f2f.lua"),
                os.path.join(USER_DIR, "alphamine_f2f.lua"))
    with open(os.path.join(USER_DIR, "autorun_app_script.txt"), "w", encoding="utf-8") as f:
        f.write("user:alphamine_f2f.lua")
    with open(os.path.join(USER_DIR, "alphamine_f2f.json"), "w", encoding="utf-8") as f:
        json.dump({"server": server, "user": "Player", "load_distance": 16}, f)


class Client:
    """F2F connection with an idle keepalive thread (the server drops a silent client after 60 s)."""

    def __init__(self, port, connect_timeout=60):
        self.c = F2F(port, connect_timeout=connect_timeout, timeout=600)
        self.lock = threading.RLock()
        self.last = time.time()
        self.alive = True
        threading.Thread(target=self._ka, daemon=True).start()

    def _ka(self):
        while self.alive:
            time.sleep(1.0)
            if time.time() - self.last >= 1.0 and self.lock.acquire(blocking=False):
                try:
                    self.c.raw("keepalive", {}, 5)
                except Exception:
                    pass
                finally:
                    self.lock.release()

    def raw(self, cmd, args=None, timeout=None):
        with self.lock:
            self.last = time.time()
            try:
                return self.c.raw(cmd, args or {}, timeout)
            finally:
                self.last = time.time()

    def close(self):
        self.alive = False
        with self.lock:
            self.c.close()


def engine_stop(client=None):
    pid = engine_pid()
    if pid and client:
        try:
            client.raw("quit", {}, timeout=5)
        except Exception:
            pass
        for _ in range(30):
            if not pid_alive(pid, r"VoxelCoreF2F-u"):
                break
            time.sleep(0.25)
    if pid and pid_alive(pid, r"VoxelCoreF2F-u"):
        ps("Stop-Process -Id %d -Force -ErrorAction SilentlyContinue" % pid)
    if os.path.exists(ENGINE_PIDF):
        os.remove(ENGINE_PIDF)
    return pid


def engine_start(server="127.0.0.1:%d" % SERVER_PORT, size="854x480"):
    engine_stop()
    t0 = time.time()
    note = refresh_copy()
    prepare_dir(server)
    argv = ["--f2f", str(F2F_PORT), "--f2f-size", size, "--res", win(os.path.join(VC_ROOT, "res")), "--dir", win(USER_DIR)]
    out = ps("(Start-Process -FilePath '%s' -WorkingDirectory '%s' -ArgumentList %s -PassThru).Id" % (
        win(ENGINE_COPY), win(ENGINE_DIR), ",".join("'%s'" % a for a in argv)), timeout=60)
    pid = int(out.split()[-1])
    with open(ENGINE_PIDF, "w") as f:
        f.write(str(pid))
    c = Client(F2F_PORT)
    hello = c.raw("hello")["result"]
    frames = 0
    while not hello.get("handler"):
        if frames > 2000:
            raise SystemExit("pack handler did not register:\n" + log_tail(20))
        c.raw("step", {"ticks": 1, "frames": 1})
        frames += 1
        hello = c.raw("hello")["result"]
    print("engine_u pid %d, F2F :%d, %s, world+handler in %d frames, %.1f s" % (pid, F2F_PORT, note, frames,
                                                                               time.time() - t0), flush=True)
    return c


def log_tail(n=15, pattern=None):
    try:
        with open(os.path.join(USER_DIR, "latest.log"), encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return ""
    if pattern:
        lines = [l for l in lines if pattern in l]
    return "\n".join(lines[-n:])


# ---------------------------------------------------------------------------------------------- scenarios
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


QUICK_PREFIX = [
    {"cmd": "connect"},
    {"cmd": "wait", "args": {"world": True, "max_frames": 1200}, "expect": {"screen": "ingame"}},
    {"cmd": "wait", "args": {"chunks": 9, "max_frames": 1200}},
    {"cmd": "step", "args": {"ticks": 20, "frames": 1}},
]


def wait(c, args):
    cond = {k: v for k, v in args.items() if k not in ("max_frames", "settle", "realtime", "partial")}
    max_frames = int(args.get("max_frames", 2000))
    realtime = args.get("realtime", True)
    t0 = time.time()
    used = 0
    rep = c.raw("wait_check", dict(cond, begin=True))
    if not rep.get("ok"):
        return rep
    nxt = time.time()
    while not rep["result"].get("done"):
        r = rep["result"]
        if r.get("fatal"):
            return {"ok": False, "error": "%s after %d frames: %s" % (r["fatal"], used, r.get("describe"))}
        if used >= max_frames:
            return {"ok": False, "error": "timeout after %d frames: %s; %s" % (used, r.get("describe"), r.get("why"))}
        if realtime:
            nxt += 0.05
            d = nxt - time.time()
            if d > 0:
                time.sleep(d)
            elif d < -1.0:
                nxt = time.time()
        s = c.raw("step", {"ticks": 1, "frames": 1, "partial": args.get("partial", 0)})
        if not s.get("ok"):
            return s
        used += 1
        rep = c.raw("wait_check", cond)
        if not rep.get("ok"):
            return rep
    if int(args.get("settle", 0)) > 0:
        c.raw("step", {"ticks": int(args["settle"]), "frames": 1})
    r = rep["result"]
    return {"ok": True, "result": {"tick": r.get("tick"), "frames": used, "screen": r.get("screen"),
                                   "map_chunks": r.get("map_chunks"), "wall_s": round(time.time() - t0, 2)}}


def gui(c, args):
    """Java F2FAgent `gui`: queue the click/key, then step ticks/frames (default 1/1). The pack handler applies
    the event (it runs between frames), the step runs the tick + frame that Java would run."""
    r = c.raw("gui", args)
    if not r.get("ok"):
        return r
    s = c.raw("step", {"ticks": int(args.get("ticks", 1)), "frames": int(args.get("frames", 1))})
    if not s.get("ok"):
        return s
    st = c.raw("state", {"radius": 0}).get("result") or {}
    res = dict(s["result"])
    res["screen"] = st.get("screen")
    res["handled"] = r["result"]
    return {"ok": True, "result": res}


def check_expect(expect, st):
    bad = []
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
            bad.append("player at %.4f %.4f %.4f, further than %s from %s" % (
                p.get("x", 0), p.get("y", 0), p.get("z", 0), r, expect["near"][:3]))
    if "health" in expect and p.get("health") != expect["health"]:
        bad.append("health %s != %s" % (p.get("health"), expect["health"]))
    for k in ("yaw", "pitch"):
        if k in expect and abs(p.get(k, 1e9) - expect[k]) > 1e-3:
            bad.append("%s %s != %s" % (k, p.get(k), expect[k]))
    return bad


def run_steps(c, steps, out_dir, rep, first=0):
    for i, step in enumerate(steps, first):
        cmd, args = step["cmd"], dict(step.get("args") or {})
        t0 = time.time()
        e = {"n": i, "cmd": cmd, "args": args}
        if cmd == "shot":
            name = step.get("name") or "%02d" % i
            path = os.path.join(out_dir, name + ".png")
            r = c.raw("shot", {"path": win(path)})
            if r.get("ok"):
                rep["shots"].append({"name": name, "path": path, "sha256": r["result"].get("sha256")})
        elif cmd == "look":
            st = c.raw("state", {"radius": 0}).get("result") or {}
            p = st.get("player") or {}
            dx = int(round((float(args.get("yaw", p.get("yaw", 0))) - p.get("yaw", 0)) / 0.15))
            dy = int(round((p.get("pitch", 0) - float(args.get("pitch", p.get("pitch", 0)))) / 0.15))
            r = c.raw("input", {"mouse": {"dx": dx, "dy": dy}})
            if r.get("ok"):
                r["result"] = {"dx": dx, "dy": dy}
        elif cmd == "wait":
            r = wait(c, args)
        elif cmd == "gui":
            r = gui(c, args)
        else:
            if cmd == "input" and args.get("keys"):
                # F2F.md 7.1: digit-string keys are LWJGL codes on Java ("3" = KEY_2); engine names here
                args = dict(args, keys={LWJGL_DIGITS.get(k, k): v for k, v in args["keys"].items()})
            r = c.raw(cmd, args, timeout=step.get("limit", 600))
        if cmd == "render" and r.get("ok") and (r.get("result") or {}).get("rebuilt"):
            st = c.raw("status").get("result") or {}
            n = int((st.get("engine_chunks") or 1000) / 4) + 10
            r2 = c.raw("step", {"ticks": 0, "frames": n})
            e["settle_frames"] = n
            if not r2.get("ok"):
                r = r2
        e["dur"] = round(time.time() - t0, 2)
        e["ok"] = bool(r.get("ok"))
        if e["ok"]:
            e["result"] = r.get("result")
        else:
            e["error"] = r.get("error")
        if e["ok"] and step.get("expect"):
            st = c.raw("state", {"radius": 4}).get("result") or {}
            bad = check_expect(step["expect"], st)
            if bad:
                e["ok"], e["error"] = False, "expect: " + "; ".join(bad)
        rep["steps"].append(e)
        short = json.dumps(e.get("result"), ensure_ascii=False)[:150] if e["ok"] else e.get("error")
        print("%2d %-10s %6.2f s %s %s" % (i, cmd, e["dur"], "ok " if e["ok"] else "ERR", short), flush=True)
        if not e["ok"] and not step.get("optional"):
            return False
    return True


def compare_shots(rep, name, out_dir, clear):
    rows = []
    for s in rep["shots"]:
        g = os.path.join(ALPHA, "golden", name, s["name"] + ".png")
        if not os.path.exists(g):
            rows.append({"name": s["name"], "error": "no golden " + win(g)})
            continue
        A, B = cmp.load(g), cmp.load(s["path"])
        if A.shape != B.shape:
            rows.append({"name": s["name"], "error": "size mismatch: golden %dx%d, run %dx%d (F2F.md 8: not compared)" % (
                A.shape[1], A.shape[0], B.shape[1], B.shape[0])})
            continue
        m = cmp.metrics(A, B, 0, clear,
                        os.path.join(out_dir, s["name"] + "_diff.png"), os.path.join(out_dir, s["name"] + "_heat.png"))
        m["name"] = s["name"]
        # mean colour of the covered pixels (layers with engine-side randomness: particles)
        import numpy as np
        cl = np.array(list(clear)[:3], dtype=np.int16)
        for key, img in (("mean_rgb_a", A), ("mean_rgb_b", B)):
            cov = (img != cl).any(axis=2)
            m[key] = [round(float(v), 1) for v in img[cov].mean(axis=0)] if cov.any() else None
        rows.append(m)
    rep["compare"] = rows
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenarios", nargs="*")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--attach", action="store_true")
    ap.add_argument("--stop", action="store_true")
    ap.add_argument("--prefix", choices=["full", "quick"], default="full")
    ap.add_argument("--size", default=None, help="only as a check: the size comes from the scenarios (F2F.md 8)")
    ap.add_argument("--tag", default="")
    ap.add_argument("--legacy", action="store_true", help="old path: own engine/server (default: delegate to labd)")
    o = ap.parse_args()
    # этап 2а: прогон — демону лаборатории; старый путь — --legacy, --stop/--attach/--keep, --prefix quick
    import lab_delegate
    why = ("--legacy" if o.legacy else "--stop" if o.stop else "--attach" if o.attach else "--keep" if o.keep
           else "--prefix quick" if o.prefix == "quick" else None)
    if why is None and o.scenarios:
        return lab_delegate.delegate(o.scenarios, impl="vc", golden="compare", runner="run_u")
    lab_delegate.note("run_u", why or "no scenarios")
    if o.stop:
        c = None
        if engine_pid():
            try:
                c = Client(F2F_PORT, connect_timeout=3)
            except Exception:
                c = None
        print("engine_u stopped: %s, server_u stopped: %s" % (engine_stop(c), server_stop()))
        return 0
    scns = [(n, load(n)) for n in o.scenarios]
    sizes = sorted({scenario_size(s) for _, s in scns}) or ["854x480"]
    if len(sizes) > 1:
        raise SystemExit("scenarios with different frame sizes in one session: %s (F2F.md 8)" % sizes)
    if o.size and o.size != sizes[0]:
        raise SystemExit("--size %s differs from the scenario size %s (F2F.md 8)" % (o.size, sizes[0]))
    o.size = sizes[0]
    prefix = QUICK_PREFIX if o.prefix == "quick" else scns[0][1]["_prefix"]
    stamp = time.strftime("%Y%m%d_%H%M%S")
    root = os.path.join(ALPHA, "runs", stamp + "_vc_u" + ("_" + o.tag if o.tag else ""))
    os.makedirs(root, exist_ok=True)
    session = {"started": stamp, "scenarios": o.scenarios, "prefix": o.prefix, "steps": [], "shots": [], "timing": {}}
    t_all = time.time()
    ok = True
    results = []
    c = None
    try:
        if o.attach:
            c = Client(F2F_PORT, connect_timeout=5)
        else:
            t0 = time.time()
            base = scns[0][1]
            world = "world_b"
            if base.get("base"):
                world = ((load(base["base"]).get("setup") or {}).get("server") or {}).get("world") or world
            server_start(world)
            session["timing"]["server"] = round(time.time() - t0, 1)
            t0 = time.time()
            c = engine_start(size=o.size)
            session["timing"]["client"] = round(time.time() - t0, 1)
            t0 = time.time()
            ok = run_steps(c, prefix, root, session)
            session["timing"]["prefix"] = round(time.time() - t0, 1)
        for n, s in scns if ok else []:
            out_dir = os.path.join(root, n)
            os.makedirs(out_dir, exist_ok=True)
            rep = {"scenario": n, "impl": "vc", "dir": win(out_dir), "steps": [], "shots": []}
            print("--- %s" % n, flush=True)
            t0 = time.time()
            rep["ok"] = run_steps(c, s["_body"], out_dir, rep, first=len(prefix))
            rep["dur"] = round(time.time() - t0, 1)
            clear = s.get("clear") or [0, 0, 0]
            for st in s["_body"]:
                if st["cmd"] == "render" and (st.get("args") or {}).get("clear"):
                    clear = st["args"]["clear"]
            rows = compare_shots(rep, n, out_dir, clear)
            with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as f:
                json.dump(rep, f, ensure_ascii=False, indent=1, default=str)
            results.append((n, rows))
            ok = ok and rep["ok"]
            # the next scenario starts from the full frame
            c.raw("render", {"all": True})
    finally:
        if not o.keep:
            print("engine_u stopped: %s, server_u stopped: %s" % (engine_stop(c), server_stop()), flush=True)
        if c:
            c.close()
    session["ok"] = ok
    session["dur"] = round(time.time() - t_all, 1)
    with open(os.path.join(root, "session.json"), "w", encoding="utf-8") as f:
        json.dump(session, f, ensure_ascii=False, indent=1, default=str)
    print("=== %s in %.0f s -> %s  timing %s" % ("OK" if ok else "STOPPED", session["dur"], win(root),
                                                 json.dumps(session["timing"])))
    for n, rows in results:
        for m in rows:
            if "error" in m:
                print("%-18s %-11s %s" % (n, m["name"], m["error"]))
            else:
                print("%-18s %-11s identical %6.2f%%  coverage golden %6.2f%% vc %6.2f%%  max|d| %3d  mean|d| %.2f  mean rgb %s / %s" % (
                    n, m["name"], m["identical_pct"], m["coverage_a_pct"], m["coverage_b_pct"], m["max_delta"],
                    m["mean_delta"], m.get("mean_rgb_a"), m.get("mean_rgb_b")))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
