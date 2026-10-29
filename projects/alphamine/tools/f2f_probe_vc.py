"""F2F probe for VoxelCoreF2F.exe (AlphaMine item 5). Stdlib only.

Run with WINDOWS Python (WSL NAT cannot reach Windows 127.0.0.1):
  C:\\Python313\\python.exe tools\\alphamine\\f2f_probe_vc.py [--dir D:\\...] [--shots <repo>\\projects\\alphamine\\external\\shots]

What it does (each case starts its own engine process and kills only that PID):
  normal    : window as created
  covered   : a topmost Tk window is placed over the engine window (also steals focus)
  minimized : the engine window is minimized (ShowWindow SW_MINIMIZE) before stepping
  selftest  : hello.gl/build, `selftest` (invalid UTF-8 in result and error path, 01.10)
  perf_world: engine/tests/f2fperf world: `mode` resets u_timer, `perf` summary/trace, overhead
  isolation (01.10, --f2f-clock / --f2f-window; read-only Win32 queries, no OS input):
    rt_world  : --f2f-clock realtime, f2fworld: frames/time grow without `step`, two shots 1 s apart
                differ, `step` -> error clock-realtime, input{mouse dx} turns the player (state.rot),
                foreground window sampled every 50 ms never belongs to the engine, WS_EX_NOACTIVATE set
    rt_menu   : --f2f-clock realtime on the menu: frames grow, perf summary over 2 s (fps)
    vinput_world : virtual clock, f2fworld: input{mouse dx} + step turns the player
    hidden    : --f2f-window hidden vs normal (virtual): step{40,40} + shot sha equal, no visible window
  layers_menu / layers_world : F2F.md §7 `render` layers (clear colour %, per-layer diffs;
    layers_world uses the project <repo>\\builds\\tests\\f2fworld, world base:demo)
  In each case: hello, mode{seed}, step{ticks:40, frames:40}, shot -> sha256 must be equal.
  Same-process check: shot, minimize, step{ticks:0, frames:1}, shot -> equal.
  Input check: click on a menu button via input{mouse} -> different image.

Also usable as a tiny client:  F2F(port).call("hello")

Engine version / instance (02.10, VoxelCore 0.32 port): --exe <exe> (alias of --engine), --res <res dir>,
--dir <user dir>, --port N, --tests <dir with f2fproj/f2fworld/f2fperf>. Example for 0.32:
  python.exe -X utf8 f2f_probe_vc.py --exe <repo>\\builds\\032\\VoxelCoreF2F-032.exe
    --res <repo>\\engines\\v032\\res --dir <repo>\\builds\\032\\userdir_probe
    --port 25578 --shots <repo>\\builds\\032\\shots --cases normal,minimized,hidden
The `covered` case raises a topmost Tk window with focus_force (takes the user's focus): do not use it
while the user works on the PC.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import hashlib
import json
import os
import socket
import subprocess
import sys
import time

ENGINE = os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")), "builds", "031", "VoxelCoreF2F-031.exe")
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
TESTS = os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")), "builds", "tests")  # --tests: f2fproj, f2fworld, f2fperf


class F2F:
    def __init__(self, port, timeout=60.0):
        self.port = port
        self.sock = None
        self.buf = b""
        self.next_id = 1
        self.timeout = timeout

    def connect(self, wait=60.0, proc=None):
        t0 = time.time()
        while time.time() - t0 < wait:
            if proc is not None and proc.poll() is not None:
                raise RuntimeError("engine exited with code %s" % proc.returncode)
            try:
                self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=1.0)
                self.sock.settimeout(self.timeout)
                return time.time() - t0
            except OSError:
                time.sleep(0.2)
        raise RuntimeError("could not connect to 127.0.0.1:%d" % self.port)

    def call(self, cmd, args=None):
        req = {"id": self.next_id, "cmd": cmd, "args": args or {}}
        self.next_id += 1
        self.sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        resp = json.loads(line.decode("utf-8"))
        if resp.get("id") != req["id"]:
            raise RuntimeError("id mismatch: %r" % resp)
        return resp

    def ok(self, cmd, args=None):
        resp = self.call(cmd, args)
        if not resp.get("ok"):
            raise RuntimeError("%s failed: %r" % (cmd, resp))
        return resp["result"]

    def close(self):
        if self.sock:
            self.sock.close()


# ------------------------------------------------------------------ windows

user32 = ctypes.windll.user32 if os.name == "nt" else None


def find_window(pid, timeout=20.0):
    found = []
    proto = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def cb(hwnd, _):
        p = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True

    t0 = time.time()
    while time.time() - t0 < timeout:
        found.clear()
        user32.EnumWindows(proto(cb), 0)
        if found:
            return found[0]
        time.sleep(0.2)
    return None


def window_rect(hwnd):
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    return r.left, r.top, r.right, r.bottom


def minimize(hwnd):
    # SW_SHOWMINNOACTIVE (7): SW_MINIMIZE (6) activates the next top-level window, i.e. it can move
    # the user's focus (02.10)
    user32.ShowWindow(hwnd, 7)
    time.sleep(0.5)
    return bool(user32.IsIconic(hwnd))


class Cover:
    """Topmost Tk window over the engine window."""

    def __init__(self, hwnd):
        import tkinter as tk
        l, t, r, b = window_rect(hwnd)
        self.root = tk.Tk()
        self.root.overrideredirect(True)
        self.root.geometry("%dx%d+%d+%d" % (r - l + 40, b - t + 40, l - 20, t - 20))
        self.root.configure(bg="#c03030")
        self.root.attributes("-topmost", True)
        self.root.update()
        self.root.focus_force()
        self.root.update()
        time.sleep(0.3)
        self.root.update()

    def pump(self):
        self.root.update()

    def close(self):
        self.root.destroy()


# ------------------------------------------------------------------ probe

def start_engine(port, size, userdir, res, extra=()):
    args = [ENGINE, "--f2f", str(port), "--f2f-size", size, "--dir", userdir]
    if res:
        args += ["--res", res]
    args += list(extra)
    os.makedirs(userdir, exist_ok=True)
    return subprocess.Popen(args, cwd=os.path.dirname(ENGINE),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop_engine(proc, client):
    try:
        client.ok("quit")
    except Exception:
        pass
    client.close()
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()  # only our own PID
        proc.wait()


def run_case(name, opts, shots_dir):
    watch = ForegroundWatch() if name != "covered" else None
    proc = start_engine(opts.port, opts.size, opts.dir, opts.res)
    client = F2F(opts.port)
    report = {"case": name, "pid": proc.pid}
    cover = None
    try:
        report["connect_s"] = round(client.connect(proc=proc), 2)
        report["hello"] = client.ok("hello")
        hwnd = find_window(proc.pid)
        report["hwnd"] = bool(hwnd)
        if name == "covered":
            cover = Cover(hwnd)
            report["foreground_is_engine"] = user32.GetForegroundWindow() == hwnd
        elif name == "minimized":
            report["iconic"] = minimize(hwnd)
        report["mode"] = client.ok("mode", {"fixed": True, "seed": 12345})
        t0 = time.time()
        report["step"] = client.ok("step", {"ticks": 40, "frames": 40})
        report["step_s"] = round(time.time() - t0, 3)
        report["engine_foreground"] = bool(hwnd) and user32.GetForegroundWindow() == hwnd
        if cover:
            cover.pump()
        path = os.path.join(shots_dir, "vc_f2f_menu_%s.png" % name)
        shot = client.ok("shot", {"path": path})
        with open(path, "rb") as f:
            file_sha = hashlib.sha256(f.read()).hexdigest()
        report["shot"] = shot
        report["file_sha256_matches"] = file_sha == shot["sha256"]

        if name == "normal":
            # same process: minimize, re-render the same state, compare
            report["iconic_after"] = minimize(hwnd)
            client.ok("step", {"ticks": 0, "frames": 1})
            again = client.ok("shot", {"path": os.path.join(shots_dir, "vc_f2f_menu_normal_reminimized.png")})
            report["same_process_minimized_sha256"] = again["sha256"]
            report["same_process_equal"] = again["sha256"] == shot["sha256"]
            # SW_SHOWNOACTIVATE (4): SW_RESTORE (9) activates the window = takes the user's focus
            # (seen 02.10: 2 foreground samples in the `normal` case)
            user32.ShowWindow(hwnd, 4)

            # input: move the mouse over a menu button and click it
            x, y = opts.click
            client.ok("input", {"mouse": {"x": x, "y": y}})
            client.ok("step", {"ticks": 1, "frames": 1})
            client.ok("input", {"mouse": {"buttons": [True, False, False]}})
            client.ok("step", {"ticks": 1, "frames": 1})
            client.ok("input", {"mouse": {"buttons": [False, False, False]}})
            client.ok("step", {"ticks": 10, "frames": 10})
            clicked = client.ok("shot", {"path": os.path.join(shots_dir, "vc_f2f_menu_after_click.png")})
            report["after_click"] = clicked
            report["click_changed_image"] = clicked["sha256"] != shot["sha256"]
            # keyboard: ESC goes back to the main menu page
            client.ok("input", {"keys": {"ESCAPE": True}})
            client.ok("step", {"ticks": 1, "frames": 1})
            client.ok("input", {"keys": {"ESCAPE": False}})
            client.ok("step", {"ticks": 10, "frames": 10})
            back = client.ok("shot", {"path": os.path.join(shots_dir, "vc_f2f_menu_after_esc.png")})
            report["after_esc"] = back
            report["unknown"] = client.call("state", {})
    finally:
        if cover:
            cover.close()
        stop_engine(proc, client)
        report["exit_code"] = proc.returncode
        if watch:
            report["foreground_watch"] = watch.stop()
            report["engine_was_foreground"] = proc.pid in report["foreground_watch"]["pids"]
    return report


def run_lua_case(opts):
    """Lua handler: project dir with start.lua that calls f2f.set_handler."""
    proj = os.path.join(TESTS, "f2fproj")
    args = [ENGINE, "--f2f", str(opts.port), "--dir", opts.dir, "--res", opts.res,
            "--project", proj]
    proc = subprocess.Popen(args, cwd=os.path.dirname(ENGINE),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    client = F2F(opts.port)
    rep = {"case": "lua", "pid": proc.pid}
    try:
        client.connect(proc=proc)
        rep["hello_before"] = client.ok("hello")["handler"]
        client.ok("step", {"ticks": 1, "frames": 1})  # start.lua runs in applicationTick
        rep["hello_after"] = client.ok("hello")["handler"]
        rep["state"] = client.call("state", {"radius": 2})
        rep["mode1"] = client.call("mode", {"fixed": True, "seed": 777})
        rep["mode2"] = client.call("mode", {"fixed": True, "seed": 777})
        rep["bad"] = client.call("nosuchcmd", {})
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
    return rep


# ------------------------------------------------------------------ render layers (F2F.md §7)

def _rgb_pixels(path):
    """List of (r,g,b) tuples of a PNG (pngio, stdlib only)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pngio
    with open(path, "rb") as f:
        w, h, rows = pngio.read_rgba(f.read())
    px = []
    for row in rows:
        px.extend(zip(row[0::4], row[1::4], row[2::4]))
    return w, h, px


def pct_equal_color(path, rgb):
    """% of pixels exactly equal to rgb."""
    _w, _h, px = _rgb_pixels(path)
    rgb = tuple(rgb)
    n = sum(1 for p in px if p == rgb)
    return round(100.0 * n / len(px), 4)


def diff_stats(a, b):
    """% of differing pixels and their bbox [x0,y0,x1,y1]."""
    w, _h, pa = _rgb_pixels(a)
    _w, _h2, pb = _rgb_pixels(b)
    diff = 0
    x0 = y0 = 10 ** 9
    x1 = y1 = -1
    for i, (p, q) in enumerate(zip(pa, pb)):
        if p != q:
            diff += 1
            x, y = i % w, i // w
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
    return {"diff_pct": round(100.0 * diff / len(pa), 4),
            "bbox": [x0, y0, x1, y1] if diff else None}


def settle(client, path, same=6, max_frames=600, pause=0.25):
    """step{ticks:0,frames:1} (virtual time frozen) until `same` consecutive frames, `pause` s of REAL
    time apart, have the same sha256 (chunk loading/meshing runs on real-time worker threads and is
    pulled by the frame); then shot to path."""
    last, run, frames = None, 0, 0
    while frames < max_frames:
        client.ok("step", {"ticks": 0, "frames": 1})
        frames += 1
        sha = client.ok("shot", {})["sha256"]
        run = run + 1 if sha == last else 1
        last = sha
        if run >= same:
            break
        time.sleep(pause)
    shot = client.ok("shot", {"path": path})
    shot["settle_frames"] = frames
    shot["stable"] = run >= same
    return shot


def run_layers_menu(opts, shots):
    proc = start_engine(opts.port, opts.size, opts.dir, opts.res)
    client = F2F(opts.port)
    rep = {"case": "layers_menu", "pid": proc.pid}
    try:
        client.connect(proc=proc)
        hello = client.ok("hello")
        rep["layers"] = hello.get("layers")
        rep["render_state"] = hello.get("render")
        client.ok("step", {"ticks": 40, "frames": 40})
        base = os.path.join(shots, "layers_menu_all.png")
        rep["all_on"] = client.ok("shot", {"path": base})["sha256"]

        rep["render_all_false"] = client.ok("render", {"all": False})
        client.ok("step", {"ticks": 0, "frames": 1})
        p = os.path.join(shots, "layers_menu_none_black.png")
        rep["none_black"] = client.ok("shot", {"path": p})["sha256"]
        rep["none_black_pct_clear"] = pct_equal_color(p, (0, 0, 0))

        client.ok("render", {"clear": [40, 80, 120]})
        client.ok("step", {"ticks": 0, "frames": 1})
        p = os.path.join(shots, "layers_menu_none_rgb.png")
        rep["none_rgb"] = client.ok("shot", {"path": p})["sha256"]
        rep["none_rgb_pct_clear"] = pct_equal_color(p, (40, 80, 120))

        client.ok("render", {"layers": {"gui": True}})
        client.ok("step", {"ticks": 0, "frames": 1})
        p = os.path.join(shots, "layers_menu_gui_only.png")
        rep["gui_only"] = client.ok("shot", {"path": p})["sha256"]
        rep["gui_only_pct_clear"] = pct_equal_color(p, (40, 80, 120))
        rep["gui_only_vs_all"] = diff_stats(p, base)

        client.ok("render", {"all": True, "clear": [0, 0, 0]})
        client.ok("step", {"ticks": 0, "frames": 1})
        p = os.path.join(shots, "layers_menu_all_again.png")
        rep["all_again_equal"] = client.ok("shot", {"path": p})["sha256"] == rep["all_on"]
        rep["bad_layer"] = client.call("render", {"layers": {"nosuch": True}})
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
    return rep


def run_layers_world(opts, shots):
    proj = os.path.join(TESTS, "f2fworld")
    args = [ENGINE, "--f2f", str(opts.port), "--f2f-size", opts.size, "--dir", opts.dir,
            "--res", opts.res, "--project", proj]
    os.makedirs(opts.dir, exist_ok=True)
    proc = subprocess.Popen(args, cwd=os.path.dirname(ENGINE),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    client = F2F(opts.port)
    rep = {"case": "layers_world", "pid": proc.pid}
    t0 = time.time()
    try:
        client.connect(proc=proc)
        # start.lua (app coroutine) opens the world; handler "state" appears when ready
        for i in range(2000):
            client.ok("step", {"ticks": 1, "frames": 1})
            r = client.call("state", {})
            if r.get("ok") and r["result"].get("ready"):
                break
        rep["ready_steps"] = i + 1
        # let chunks around the player load (real-time worker threads), then build the scene
        prev = -1
        for i in range(400):
            client.ok("step", {"ticks": 1, "frames": 1})
            chunks = client.ok("state", {})["chunks"]
            if chunks == prev and i > 60:
                break
            prev = chunks
        rep["chunks"] = chunks
        rep["build"] = client.ok("build", {})
        client.ok("step", {"ticks": 2, "frames": 2})
        rep["state"] = client.ok("state", {})

        def cap(name, render_args):
            r = client.ok("render", render_args)
            if r.get("rebuilt"):
                # lighting toggled: every chunk mesh is rebuilt; ChunksRenderer enqueues at most
                # 4 chunks per frame, so give it chunks/4 frames (+margin) before settling
                n = client.ok("state", {})["chunks"] // 4 + 100
                client.ok("step", {"ticks": 0, "frames": n})
            path = os.path.join(shots, "layers_world_%s.png" % name)
            shot = settle(client, path)
            rep["shot_" + name] = {"sha256": shot["sha256"], "settle_frames": shot["settle_frames"],
                                   "stable": shot["stable"]}
            return path

        # whole scene loaded and meshed: 12 identical frames over ~3 s of real time
        if not opts.baseline_only:
            client.ok("render", {"all": True, "clear": [0, 0, 0]})
        rep["warmup"] = settle(client, os.path.join(shots, "layers_world_warmup%s.png" % opts.tag), same=12, pause=0.25)
        if opts.baseline_only:
            # engines without `render` (VoxelCoreF2F-prev.exe): only the settled all-layers frame
            return rep
        s_all = cap("all", {"all": True, "clear": [0, 0, 0]})
        s_ter = cap("terrain_only", {"all": False, "layers": {"terrain": True}})
        rep["terrain_only_pct_clear"] = pct_equal_color(s_ter, (0, 0, 0))
        s_ter_l = cap("terrain_lighting", {"all": False, "layers": {"terrain": True, "lighting": True}})
        rep["terrain_lighting_vs_nolighting"] = diff_stats(s_ter, s_ter_l)
        s_ter_l_off = cap("terrain_nolighting_again", {"all": False, "layers": {"terrain": True}})
        rep["nolighting_repeatable"] = diff_stats(s_ter, s_ter_l_off)
        s_fog = cap("terrain_lighting_fog", {"all": False, "layers": {"terrain": True, "lighting": True, "fog": True}})
        rep["fog_on_vs_off"] = diff_stats(s_ter_l, s_fog)
        s_sky = cap("sky_only", {"all": False, "layers": {"sky": True}})
        rep["sky_only_pct_clear"] = pct_equal_color(s_sky, (0, 0, 0))
        s_water = cap("water_only", {"all": False, "layers": {"water": True, "lighting": True}})
        rep["water_only_pct_clear"] = pct_equal_color(s_water, (0, 0, 0))
        s_all2 = cap("all_again", {"all": True})
        rep["all_again_vs_all"] = diff_stats(s_all, s_all2)
        s_nohud = cap("no_hud", {"all": True, "layers": {"hud": False}})
        rep["hud_off_vs_all"] = diff_stats(s_all2, s_nohud)
        s_nohand = cap("no_hand", {"all": True, "layers": {"hand": False}})
        rep["hand_off_vs_all"] = diff_stats(s_all2, s_nohand)
        s_nosel = cap("no_selection", {"all": True, "layers": {"selection": False}})
        rep["selection_off_vs_all"] = diff_stats(s_all2, s_nosel)
        s_noclouds = cap("no_clouds", {"all": True, "layers": {"clouds": False}})
        rep["clouds_off_vs_all"] = diff_stats(s_all2, s_noclouds)
        s_nogui = cap("no_gui", {"all": True, "layers": {"gui": False}})
        rep["gui_off_vs_all"] = diff_stats(s_all2, s_nogui)
        cap("all_final", {"all": True})
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
        rep["seconds"] = round(time.time() - t0, 1)
    return rep


# ------------------------------------------------------------------ selftest / perf (01.10)

def run_selftest(opts):
    """hello.gl/build, `selftest` (deliberately invalid UTF-8 in the result and in the error
    path): every response must be one strict-UTF-8 JSON line and the engine must stay alive."""
    proc = start_engine(opts.port, opts.size, opts.dir, opts.res)
    client = F2F(opts.port)
    rep = {"case": "selftest", "pid": proc.pid}
    try:
        client.connect(proc=proc)
        hello = client.ok("hello")
        rep["gl"] = hello.get("gl")
        rep["build"] = hello.get("build")
        rep["time_epoch"] = hello.get("time_epoch")
        rep["selftest"] = client.ok("selftest")
        rep["selftest_throw"] = client.call("selftest", {"throw": True})
        rep["alive_after"] = client.ok("hello")["frame"] == hello["frame"]
        st = rep["selftest"]
        acp = st.get("ansi_code_page")
        rep["checks"] = {
            "cp1251_transcoded": st["cp1251"] == "Ошибка" if acp == 1251 else st["cp1251"],
            "mixed": st["mixed"] == ("path/Путь/Ошибка end" if acp == 1251 else st["mixed"]),
            # a run of invalid bytes is transcoded from the ANSI code page if there is one
            "broken": st["broken"] == ("abcв‚" if acp == 1251 else "abc\\xE2\\x82"),
            "control_escaped": st["control"] == "a\\x01b\\x1Fc\td",
            "emoji_kept": st["emoji"] == "\U0001F600",
            "key": list(st["keys"].keys()),
            "throw_ok_false": rep["selftest_throw"].get("ok") is False,
            "throw_error": rep["selftest_throw"].get("error"),
        }
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
    return rep


def wait_world(client, rep, max_ready=2000):
    for i in range(max_ready):
        client.ok("step", {"ticks": 1, "frames": 1})
        r = client.call("state", {})
        if r.get("ok") and r["result"].get("ready"):
            break
    rep["ready_steps"] = i + 1
    prev = -1
    for i in range(400):
        client.ok("step", {"ticks": 1, "frames": 1})
        chunks = client.ok("state", {})["chunks"]
        if chunks == prev and i > 60:
            break
        prev = chunks
    rep["chunks"] = chunks


def check_trace(path):
    """Load a Chrome trace-event JSON and summarise it (quick sanity check)."""
    with open(path, "rb") as f:
        raw = f.read()
    doc = json.loads(raw.decode("utf-8"))
    ev = doc["traceEvents"]
    by_ph, names, tids = {}, {}, {}
    for e in ev:
        by_ph[e["ph"]] = by_ph.get(e["ph"], 0) + 1
        names[e["name"]] = names.get(e["name"], 0) + 1
        tids[e.get("tid")] = tids.get(e.get("tid"), 0) + 1
    frames = sorted((e for e in ev if e["name"] == "frame" and e["ph"] == "X"), key=lambda e: e["ts"])
    # every engine phase of the main thread must lie inside some frame or command
    main_x = [e for e in ev if e["ph"] == "X" and e.get("tid") == 1 and e["name"] != "frame"]
    spans = [(f["ts"], f["ts"] + f["dur"]) for f in frames]
    spans += [(e["ts"], e["ts"] + e["dur"]) for e in ev if e["ph"] == "X" and e.get("tid") == 3]
    spans.sort()

    def inside(e):
        for a, b in spans:
            if a <= e["ts"] and e["ts"] + e["dur"] <= b:
                return True
        return False
    outside = sum(1 for e in main_x if not inside(e))
    lua_x = [e for e in ev if e.get("tid") == 2 and e["ph"] == "X"]
    lua_in_frame = sum(1 for e in lua_x if any(f["ts"] <= e["ts"] and e["ts"] + e["dur"] <= f["ts"] + f["dur"] for f in frames))
    steps = [e for e in ev if e["name"] == "step" and e["ph"] == "i"]
    sample = [e for e in ev if e["ph"] != "M"][:1] + frames[:1] + lua_x[:1] + steps[:1]
    return {"bytes": len(raw), "events": len(ev), "by_ph": by_ph,
            "names": dict(sorted(names.items(), key=lambda kv: -kv[1])[:30]),
            "tids": {str(k): v for k, v in sorted(tids.items(), key=lambda kv: str(kv[0]))},
            "frames": len(frames), "main_phases": len(main_x), "main_phases_outside": outside,
            "lua_x": len(lua_x), "lua_x_inside_frames": lua_in_frame, "step_instants": len(steps),
            "frame_dur_ms_mean": round(sum(f["dur"] for f in frames) / max(1, len(frames)) / 1000, 3),
            "sample": sample}


def run_perf_world(opts, shots):
    """World from engine/tests/f2fperf: `mode` resets u_timer (same shot after a different
    number of frames), perf summary + trace of 200 frames, overhead off/on/trace."""
    proj = os.path.join(TESTS, "f2fperf")
    args = [ENGINE, "--f2f", str(opts.port), "--f2f-size", opts.size, "--dir", opts.dir,
            "--res", opts.res, "--project", proj]
    os.makedirs(opts.dir, exist_ok=True)
    proc = subprocess.Popen(args, cwd=os.path.dirname(ENGINE),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    client = F2F(opts.port, timeout=300.0)
    rep = {"case": "perf_world", "engine": ENGINE, "pid": proc.pid}
    t0 = time.time()
    try:
        client.connect(proc=proc)
        hello = client.ok("hello")
        has_perf = "build" in hello
        rep["build"] = hello.get("build")
        rep["gl"] = hello.get("gl")
        wait_world(client, rep)
        client.ok("build", {})
        client.ok("step", {"ticks": 2, "frames": 2})
        rep["warmup"] = settle(client, os.path.join(shots, "perf_world_warmup%s.png" % opts.tag), same=12)

        # 1. mode resets render-time accumulators: same frame after a different history
        client.ok("mode", {"fixed": True, "seed": 4242})
        client.ok("step", {"ticks": 20, "frames": 20})
        pa = os.path.join(shots, "perf_world_mode_a%s.png" % opts.tag)
        a = client.ok("shot", {"path": pa})
        client.ok("step", {"ticks": 37, "frames": 37})
        client.ok("mode", {"fixed": True, "seed": 4242})
        client.ok("step", {"ticks": 20, "frames": 20})
        pb = os.path.join(shots, "perf_world_mode_b%s.png" % opts.tag)
        b = client.ok("shot", {"path": pb})
        rep["mode_repeat"] = {"a": a["sha256"], "b": b["sha256"], "equal": a["sha256"] == b["sha256"],
                              "diff": diff_stats(pa, pb)}
        # 2. overhead: 200 frames (1 tick each) perf off / on / on+trace, interleaved x7
        #    (engine without perf: only "off", to compare perf-off cost between exes)
        def timed():
            t = time.perf_counter()
            client.ok("step", {"ticks": 200, "frames": 200})
            return round((time.perf_counter() - t) * 1000.0, 1)
        runs = {"off": [], "on": [], "trace": []} if has_perf else {"off": []}
        for _ in range(7):
            if has_perf:
                client.ok("perf", {"stop": True})
            runs["off"].append(timed())
            if has_perf:
                client.ok("perf", {"start": True, "trace": False})
                runs["on"].append(timed())
                client.ok("perf", {"start": True, "trace": True})
                runs["trace"].append(timed())
        med = {k: sorted(v)[len(v) // 2] for k, v in runs.items()}
        rep["overhead_ms_200f"] = runs
        rep["overhead_median_ms"] = med
        if not has_perf:
            rep["note"] = "engine without perf: mode check and perf-off timing only"
            return rep
        client.ok("perf", {"stop": True})
        rep["overhead_pct"] = {"on": round(100.0 * (med["on"] - med["off"]) / med["off"], 2),
                               "trace": round(100.0 * (med["trace"] - med["off"]) / med["off"], 2)}

        # 3. the trace: 200 frames + Lua events (frame work X/C, a B/E pair from the handler)
        client.ok("perf", {"start": True, "trace": True})
        rep["state_trace"] = client.ok("state", {})
        for i in range(10):
            client.ok("step", {"ticks": 20, "frames": 20})
        rep["be"] = client.ok("be", {"name": "pack:handler_be"})
        trace_path = os.path.join(shots, "perf_world_trace%s.json" % opts.tag)
        res = client.ok("perf", {"stop": True, "dump": trace_path})
        rep["dump"] = res["dump"]
        summ = res["summary"]
        rep["summary"] = {k: summ[k] for k in ("frames", "wall_ms", "frame_ms_mean", "events", "dropped")}
        rep["phases"] = {k: v for k, v in summ["phases"].items() if v["count"] or v["items"]}
        rep["trace_check"] = check_trace(trace_path)
        rep["perf_after_stop"] = client.ok("perf", {})["summary"]["enabled"]
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
        rep["seconds"] = round(time.time() - t0, 1)
    return rep


# ------------------------------------------------------------------ isolation (01.10)

def _hwnd_pid(hwnd):
    p = wt.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
    return p.value


def _window_title(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetWindowTextW(hwnd, buf, 256)
    return buf.value


def foreground():
    hwnd = user32.GetForegroundWindow()
    return {"hwnd": int(hwnd or 0), "pid": _hwnd_pid(hwnd) if hwnd else 0,
            "title": _window_title(hwnd) if hwnd else ""}


def process_windows(pid):
    """All top-level windows of pid: [(hwnd, visible, exstyle)] (read-only)."""
    out = []
    proto = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def cb(hwnd, _):
        if _hwnd_pid(hwnd) == pid:
            user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
            ex = user32.GetWindowLongPtrW(hwnd, -20)  # GWL_EXSTYLE
            out.append({"hwnd": int(hwnd), "visible": bool(user32.IsWindowVisible(hwnd)),
                        "title": _window_title(hwnd), "noactivate": bool(ex & 0x08000000),
                        "exstyle": hex(ex & 0xFFFFFFFF)})
        return True
    user32.EnumWindows(proto(cb), 0)
    return out


class ForegroundWatch:
    """Samples GetForegroundWindow every 50 ms in a thread (read-only)."""

    def __init__(self):
        import threading
        self.samples = 0
        self.pids = {}
        self.titles = {}
        self.stop_flag = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop_flag:
            f = foreground()
            self.samples += 1
            self.pids[f["pid"]] = self.pids.get(f["pid"], 0) + 1
            self.titles[f["title"]] = self.titles.get(f["title"], 0) + 1
            time.sleep(0.05)

    def stop(self):
        self.stop_flag = True
        self.thread.join()
        return {"samples": self.samples, "pids": self.pids, "titles": self.titles}


def _start_world(opts, extra):
    proj = os.path.join(TESTS, "f2fworld")
    return start_engine(opts.port, opts.size, opts.dir, opts.res,
                        list(extra) + ["--project", proj])


def run_rt_world(opts, shots):
    rep = {"case": "rt_world", "foreground_before": foreground()}
    watch = ForegroundWatch()
    proc = _start_world(opts, ["--f2f-clock", "realtime"])
    rep["pid"] = proc.pid
    client = F2F(opts.port)
    t0 = time.time()
    try:
        rep["connect_s"] = round(client.connect(proc=proc), 2)
        h = client.ok("hello")
        rep["hello"] = {k: h[k] for k in ("fixed", "flags", "time", "frame", "screen", "handler")}
        # the world opens by itself (start.lua runs in applicationTick on the wall clock)
        ready = None
        for _ in range(600):
            r = client.call("state", {})
            if r.get("ok") and r["result"].get("ready"):
                ready = r["result"]
                break
            time.sleep(0.1)
        rep["ready_after_s"] = round(time.time() - t0, 2)
        rep["windows"] = process_windows(proc.pid)
        time.sleep(3.0)
        h1 = client.ok("hello")
        a = client.ok("shot", {"path": os.path.join(shots, "rt_world_a.png")})
        time.sleep(1.0)
        h2 = client.ok("hello")
        b = client.ok("shot", {"path": os.path.join(shots, "rt_world_b.png")})
        rep["frames"] = [h1["frame"], h2["frame"]]
        rep["time"] = [round(h1["time"], 3), round(h2["time"], 3)]
        rep["fps_1s"] = round((h2["frame"] - h1["frame"]) / (h2["time"] - h1["time"]), 1)
        rep["shots"] = [a["sha256"], b["sha256"]]
        rep["shots_differ"] = a["sha256"] != b["sha256"]
        rep["shot_diff"] = diff_stats(a["path"], b["path"])
        rep["step"] = client.call("step", {"ticks": 1, "frames": 1})
        # synthetic input in realtime: mouse dx turns the camera/player
        rot0 = client.ok("state", {})["rot"]
        client.ok("input", {"mouse": {"dx": 200}})
        time.sleep(0.5)
        rot1 = client.ok("state", {})["rot"]
        rep["input_dx_rot"] = [rot0, rot1]
        rep["input_dx_changed_yaw"] = abs(rot1[0] - rot0[0]) > 1e-3
        # perf over 2 s of the user-session pacing
        client.ok("perf", {"start": True})
        time.sleep(2.0)
        summ = client.ok("perf", {"stop": True})["summary"]
        rep["perf_2s"] = {"frames": summ["frames"], "wall_ms": summ["wall_ms"],
                          "frame_ms_mean": summ["frame_ms_mean"],
                          "present_mean_ms": summ["phases"]["present"]["mean_ms"]}
        rep["windows_end"] = process_windows(proc.pid)
        rep["foreground_after"] = foreground()
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
        rep["foreground_watch"] = watch.stop()
        rep["engine_was_foreground"] = proc.pid in rep["foreground_watch"]["pids"]
    return rep


def run_rt_menu(opts, shots):
    rep = {"case": "rt_menu", "foreground_before": foreground()}
    watch = ForegroundWatch()
    proc = start_engine(opts.port, opts.size, opts.dir, opts.res, ["--f2f-clock", "realtime"])
    rep["pid"] = proc.pid
    client = F2F(opts.port)
    try:
        client.connect(proc=proc)
        h0 = client.ok("hello")
        rep["flags"] = h0["flags"]
        time.sleep(3.0)
        h1 = client.ok("hello")
        a = client.ok("shot", {"path": os.path.join(shots, "rt_menu_a.png")})
        time.sleep(1.0)
        h2 = client.ok("hello")
        b = client.ok("shot", {"path": os.path.join(shots, "rt_menu_b.png")})
        rep["frames"] = [h0["frame"], h1["frame"], h2["frame"]]
        rep["time"] = [round(h0["time"], 3), round(h1["time"], 3), round(h2["time"], 3)]
        rep["shots"] = [a["sha256"], b["sha256"]]
        rep["step"] = client.call("step", {})
        client.ok("perf", {"start": True})
        time.sleep(2.0)
        summ = client.ok("perf", {"stop": True})["summary"]
        rep["perf_2s"] = {"frames": summ["frames"], "wall_ms": summ["wall_ms"],
                          "frame_ms_mean": summ["frame_ms_mean"]}
        rep["windows"] = process_windows(proc.pid)
        rep["foreground_after"] = foreground()
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
        rep["foreground_watch"] = watch.stop()
        rep["engine_was_foreground"] = proc.pid in rep["foreground_watch"]["pids"]
    return rep


def run_vinput_world(opts, shots):
    rep = {"case": "vinput_world"}
    proc = _start_world(opts, [])
    client = F2F(opts.port)
    try:
        client.connect(proc=proc)
        rep["flags"] = client.ok("hello")["flags"]
        wait_world(client, rep)
        rot0 = client.ok("state", {})["rot"]
        client.ok("input", {"mouse": {"dx": 200}})
        client.ok("step", {"ticks": 1, "frames": 1})
        rot1 = client.ok("state", {})["rot"]
        rep["input_dx_rot"] = [rot0, rot1]
        rep["input_dx_changed_yaw"] = abs(rot1[0] - rot0[0]) > 1e-3
    finally:
        stop_engine(proc, client)
        rep["exit_code"] = proc.returncode
    return rep


def run_hidden(opts, shots):
    rep = {"case": "hidden"}
    for win in ("normal", "hidden"):
        r = {}
        watch = ForegroundWatch()
        proc = start_engine(opts.port, opts.size, opts.dir, opts.res, ["--f2f-window", win])
        client = F2F(opts.port)
        try:
            client.connect(proc=proc)
            r["flags"] = client.ok("hello")["flags"]
            client.ok("mode", {"fixed": True, "seed": 12345})
            client.ok("step", {"ticks": 40, "frames": 40})
            shot = client.ok("shot", {"path": os.path.join(shots, "vc_f2f_menu_%s_window.png" % win)})
            r["sha256"] = shot["sha256"]
            r["windows"] = process_windows(proc.pid)
        finally:
            stop_engine(proc, client)
            r["exit_code"] = proc.returncode
            r["foreground_watch"] = watch.stop()
            r["engine_was_foreground"] = proc.pid in r["foreground_watch"]["pids"]
        rep[win] = r
    rep["sha_equal"] = rep["normal"]["sha256"] == rep["hidden"]["sha256"]
    return rep


ISOLATION_CASES = {"rt_world": run_rt_world, "rt_menu": run_rt_menu,
                   "vinput_world": run_vinput_world, "hidden": run_hidden}


def main():
    global ENGINE, TESTS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=25571)
    ap.add_argument("--engine", "--exe", dest="engine", default=ENGINE)
    ap.add_argument("--tests", default=TESTS, help="dir with the test projects f2fproj/f2fworld/f2fperf")
    ap.add_argument("--size", default="854x480")
    ap.add_argument("--dir", default=os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")), "builds", "userdir"),
                    help="user dir (REPO only when the runtime engine is not running)")
    ap.add_argument("--res", default=os.path.join(REPO, "engines", "v031", "res"))
    ap.add_argument("--shots", default=os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")), "projects", "alphamine", "external", "shots"))
    ap.add_argument("--click", default="427,240", help="x,y of a menu button in frame coords")
    ap.add_argument("--cases", default="normal,covered,minimized,normal2,lua")
    ap.add_argument("--baseline-only", action="store_true",
                    help="layers_world: stop after the settled all-layers frame (no `render` calls)")
    ap.add_argument("--tag", default="", help="suffix for the warmup shot name")
    opts = ap.parse_args()
    ENGINE = opts.engine
    TESTS = opts.tests
    opts.click = tuple(int(v) for v in opts.click.split(","))
    os.makedirs(opts.shots, exist_ok=True)

    reports = []
    for case in opts.cases.split(","):
        if case == "lua":
            print(json.dumps(run_lua_case(opts), ensure_ascii=False), flush=True)
            continue
        if case == "selftest":
            print(json.dumps(run_selftest(opts), ensure_ascii=False, indent=1), flush=True)
            continue
        if case == "perf_world":
            print(json.dumps(run_perf_world(opts, opts.shots), ensure_ascii=False, indent=1), flush=True)
            continue
        if case in ISOLATION_CASES:
            print(json.dumps(ISOLATION_CASES[case](opts, opts.shots), ensure_ascii=False, indent=1), flush=True)
            continue
        if case in ("layers_menu", "layers_world"):
            fn = run_layers_menu if case == "layers_menu" else run_layers_world
            print(json.dumps(fn(opts, opts.shots), ensure_ascii=False, indent=1), flush=True)
            continue
        rep = run_case(case, opts, opts.shots)
        reports.append(rep)
        print(json.dumps(rep, ensure_ascii=False), flush=True)
    shas = {r["case"]: r["shot"]["sha256"] for r in reports if "shot" in r}
    print("SHA256:", json.dumps(shas, indent=1))
    print("ALL_EQUAL:", len(set(shas.values())) == 1)
    # the canonical menu shot
    src = os.path.join(opts.shots, "vc_f2f_menu_normal.png")
    if os.path.exists(src):
        with open(src, "rb") as f, open(os.path.join(opts.shots, "vc_f2f_menu.png"), "wb") as g:
            g.write(f.read())


if __name__ == "__main__":
    main()
