#!/usr/bin/env python3
"""Private Java Alpha server for the VoxelCore side (AlphaMine phase 2): port 25566, own world copy.

Does not touch other java processes (the Java-side agent runs its server on 25565 via am_server): the PID of
the server started here is kept in D:\\Prog\\AlphaMine\\run\\server_v.pid and only that PID is stopped.

  python3 tools/alphamine/server_v.py start [--world world_a] [--port 25566]   # fresh copy of golden/<world>
  python3 tools/alphamine/server_v.py stop
  python3 tools/alphamine/server_v.py status
  --f2f 25593: lockstep test mode (agents/F2F.md 9, F2FServer): the server does not tick by itself, the harness steps
  it over 127.0.0.1:25593 (tools/alphamine/f2f_server.py); without --f2f the original real-time server.
  --name p --port 25567: a second private server (run\\server_p, run\\world_p, server_p.pid, logs\\server_p.*) for a
  parallel agent; the default name "v" keeps the paths above.

Layout: D:\\Prog\\AlphaMine\\run\\world_v (copy of golden\\world_a), run\\server_v (server.properties with
server-port and level-name=../world_v, ops.txt), logs\\server_v.log/.err (cp866). Start: ref\\start_server.ps1 (WMI,
detached). Ready when the log says "Done!" (~3-15 s).
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

ALPHA = "/mnt/d/Prog/AlphaMine"
RUN = os.path.join(ALPHA, "run")
SDIR = os.path.join(RUN, "server_v")
WORLD = os.path.join(RUN, "world_v")
PIDF = os.path.join(RUN, "server_v.pid")
LOG = os.path.join(ALPHA, "logs", "server_v.err")
PS = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"


def win(p):
    return subprocess.check_output(["wslpath", "-w", p], text=True).strip()


def ps(script, timeout=120):
    r = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True,
                       timeout=timeout, cwd="/mnt/c")
    return r.stdout.decode("utf-8", "replace").strip()


def set_name(name):
    """Paths of the private server `name` (default "v": run\\server_v, run\\world_v, server_v.pid, server_v.log)."""
    global SDIR, WORLD, PIDF, LOG, NAME
    NAME = name
    SDIR = os.path.join(RUN, "server_" + name)
    WORLD = os.path.join(RUN, "world_" + name)
    PIDF = os.path.join(RUN, "server_%s.pid" % name)
    LOG = os.path.join(ALPHA, "logs", "server_%s.err" % name)


NAME = "v"


def read_log():
    try:
        return open(LOG, "rb").read().decode("cp866", "replace")
    except OSError:
        return ""


def my_pid():
    try:
        pid = int(open(PIDF).read().strip())
    except (OSError, ValueError):
        return None
    out = ps("$p = Get-CimInstance Win32_Process -Filter \"ProcessId=%d\"; if ($p -and $p.Name -eq 'java.exe') "
             "{ $p.CommandLine }" % pid)
    return pid if "MinecraftServer" in out else None


def stop():
    pid = my_pid()
    if pid:
        ps("Stop-Process -Id %d -Force -ErrorAction SilentlyContinue" % pid)
        for _ in range(40):
            if not my_pid():
                break
            time.sleep(0.25)
    if os.path.exists(PIDF):
        os.remove(PIDF)
    return pid


def start(world, port, timeout=90, ops=(), f2f=0):
    old = stop()
    t0 = time.time()
    src = os.path.join(ALPHA, "golden", world)
    code = ps("$d = '%s'; for ($i = 0; $i -lt 20 -and (Test-Path $d); $i++) { Remove-Item -Recurse -Force $d "
              "-ErrorAction SilentlyContinue; if (Test-Path $d) { Start-Sleep -Milliseconds 250 } }; "
              "robocopy '%s' $d /E /NFL /NDL /NJH /NJS /NP /MT:16 /XF session.lock | Out-Null; $LASTEXITCODE"
              % (win(WORLD) if os.path.exists(WORLD) else win(RUN) + "\\world_" + NAME, win(src)))
    if not code.strip().isdigit() or int(code.strip()) >= 8:
        raise SystemExit("world copy failed: robocopy %s" % code)
    os.makedirs(SDIR, exist_ok=True)
    game = os.path.join(ALPHA, "ref", "minecraft_server", "game")
    with open(os.path.join(game, "server.properties"), encoding="latin-1") as f:
        props = [l for l in f.read().splitlines()
                 if not l.startswith(("server-port=", "level-name="))]
    props += ["server-port=%d" % port, "level-name=../world_" + NAME]
    with open(os.path.join(SDIR, "server.properties"), "w", encoding="latin-1") as f:
        f.write("\n".join(props) + "\n")
    shutil.copy(os.path.join(game, "ops.txt"), os.path.join(SDIR, "ops.txt"))
    if ops:  # extra operators of this private server (e.g. the second Java client of layer_entities_player)
        with open(os.path.join(SDIR, "ops.txt"), "a", encoding="latin-1") as f:
            f.write("".join(o.lower() + "\n" for o in ops))
    out = ps("& '%s' -Dir '%s' -LogName server_%s%s" % (win(os.path.join(ALPHA, "ref", "start_server.ps1")), win(SDIR), NAME,
                                                         " -F2F %d" % f2f if f2f else ""))
    pid = out.splitlines()[-1].strip() if out else ""
    if not pid.isdigit():
        raise SystemExit("start_server.ps1: %s" % out)
    with open(PIDF, "w") as f:
        f.write(pid)
    deadline = time.time() + timeout
    while time.time() < deadline:
        log = read_log()
        if "Done!" in log:
            print("server_" + NAME + " started in %.1f s: pid %s, port %d, world %s (fresh copy of golden/%s)%s%s"
                  % (time.time() - t0, pid, port, win(WORLD), world, ", stopped old pid %s" % old if old else "",
                     ", F2F lockstep on 127.0.0.1:%d" % f2f if f2f else ""))
            return int(pid)
        if "FAILED TO BIND" in log or "Exception" in log and not my_pid():
            raise SystemExit("server failed:\n" + log[-2000:])
        time.sleep(0.3)
    raise SystemExit("no Done! in %d s:\n%s" % (timeout, read_log()[-2000:]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["start", "stop", "status"])
    ap.add_argument("--world", default="world_a")
    ap.add_argument("--port", type=int, default=25566)
    ap.add_argument("--name", default="v", help="private server name: run\\server_<name>, world_<name>, pid, log")
    ap.add_argument("--op", action="append", default=[], help="extra operator name (ops.txt of this server)")
    ap.add_argument("--f2f", type=int, default=0, help="lockstep test mode: F2F command port (agents/F2F.md 9)")
    o = ap.parse_args()
    set_name(o.name)
    if o.action == "start":
        start(o.world, o.port, ops=o.op, f2f=o.f2f)
    elif o.action == "stop":
        pid = stop()
        print("server_v stopped (pid %s)" % pid if pid else "server_v was not running")
    else:
        pid = my_pid()
        print("server_v running: pid %s" % pid if pid else "server_v not running")
        print("\n".join(read_log().splitlines()[-5:]))


if __name__ == "__main__":
    sys.exit(main())
