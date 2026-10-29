#!/usr/bin/env python3
"""Host load for the perf suite: tools/lab/labcore/sysload.py (lab stage 2b) run by the Windows Python (psutil,
GetLastInputInfo, nvidia-smi live there). Rule of the user: measurements are valid only on an idle PC; the suite
waits for idle before a run (--wait-idle) and tags the run `contended` when the PC got busy during it.

  wait_idle(timeout_s, own_names)  -> (idle: bool, last check dict)   before the run
  Monitor(own_names).start() ... .stop() -> {contended, busy_share, n, reasons}   during the run
own_names: process names of this suite's own instances (VoxelCore.exe / VoxelCoreF2F-v.exe), plus the Java server
of server_v.py (pid file) -- not counted as foreign engines or foreign CPU.
"""
import json
import os
import subprocess
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))  # корень репозитория (было: рабочий каталог движка)
WIN_PY = "/mnt/c/Python313/python.exe"
PIDF = os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "external")), "run", "server_v.pid")


def win(p):
    return subprocess.check_output(["wslpath", "-w", p], text=True).strip()


CODE = r"""
import sys, json
sys.path.insert(0, %r)
from labcore import sysload
import psutil
names = %r
own = [p.pid for p in psutil.process_iter(['name']) if (p.info['name'] or '').lower() in names] + %r
r = sysload.check(%r, own_pids=own, th=%r)
print(json.dumps({"busy": r["busy"], "reasons": r["reasons"], "cpu_total": r["sample"].get("cpu_total_pct"),
                  "cpu_others": r["sample"].get("cpu_others_pct"), "user_idle_s": r["sample"].get("user_idle_s"),
                  "foreign": [e.get("name") if isinstance(e, dict) else e for e in r["sample"].get("foreign_engines") or []],
                  "own": own}))
"""


def check(own_names=(), seconds=2.0, th=None):
    pids = []
    try:
        pids = [int(open(PIDF).read().strip())]
    except (OSError, ValueError):
        pass
    code = CODE % (win(os.path.join(REPO, "bin")), [n.lower() for n in own_names], pids, seconds, th)
    try:
        out = subprocess.run([WIN_PY, "-X", "utf8", "-c", code], capture_output=True, text=True, timeout=60,
                             cwd="/mnt/c").stdout.strip().splitlines()
        return json.loads(out[-1])
    except Exception as exc:  # no Windows python / psutil: unknown, never silently "idle"
        return {"busy": None, "reasons": ["sysload unavailable: %s" % exc]}


def wait_idle(timeout_s, own_names=(), log=print):
    t0 = time.time()
    while True:
        r = check(own_names)
        if r.get("busy") is False:
            log("host idle (cpu %s %%, others %s %%)" % (r.get("cpu_total"), r.get("cpu_others")))
            return True, r
        if time.time() - t0 >= timeout_s:
            log("host still busy after %.0f s: %s" % (timeout_s, r.get("reasons")))
            return False, r
        log("host busy: %s - waiting" % r.get("reasons"))
        time.sleep(15)


class Monitor:
    def __init__(self, own_names=(), every=20.0):
        self.own_names, self.every = own_names, every
        self.samples = []
        self._stop = threading.Event()
        self._t = None

    def _loop(self):
        while not self._stop.is_set():
            # during the run the GPU is loaded by our own engine: GPU is judged before the run only (as sysload.Sampler)
            self.samples.append(check(self.own_names, th={"gpu_busy_pct": 101.0}))
            self._stop.wait(self.every)

    def start(self):
        self._t = threading.Thread(target=self._loop, daemon=True)
        self._t.start()
        return self

    def stop(self):
        self._stop.set()
        if self._t:
            self._t.join(70)
        known = [s for s in self.samples if s.get("busy") is not None]
        busy = [s for s in known if s["busy"]]
        reasons = []
        for s in busy:
            for r in s.get("reasons") or []:
                if r not in reasons:
                    reasons.append(r)
        share = len(busy) / len(known) if known else None
        return {"contended": (share >= 0.2) if share is not None else None, "busy_share": share,
                "n": len(known), "reasons": reasons[:6]}


if __name__ == "__main__":
    print(json.dumps(check(("voxelcore.exe",)), indent=1))
