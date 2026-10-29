#!/usr/bin/env python3
"""Общая тонкая обёртка перф-скриптов над `tools/lab/lab perf alphamine <сценарий>` (этап 3а).

Замер идёт в демоне лаборатории: ожидание простоя ПК (lab.toml [perf]), аренды server + rt (тестовая сборка
VoxelCoreF2F.exe, часы realtime, ввод изолирован), снимки загрузки во время прогона, метка contended, история.
Стоковый VoxelCore.exe и свои процессы вне аренд скрипты больше не запускают. Код выхода — как у `lab perf`:
0 чистый замер, 3 contended, 4 отказ (ПК не простаивал), 1 сбой, 2 ошибка вызова."""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VC_ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
LAB = os.path.join(VC_ROOT, "tools", "lab", "lab")


def win(p):
    return subprocess.check_output(["wslpath", "-w", p], text=True).strip()


def common_args(ap, walk=1200):
    ap.add_argument("--tag", default="run")
    ap.add_argument("--walk", type=int, default=walk)
    ap.add_argument("--stand", type=int, default=100)
    ap.add_argument("--settle", type=int, default=300)
    ap.add_argument("--yaw", type=float, default=180)
    ap.add_argument("--turn", type=float, default=30)
    ap.add_argument("--world", default="world_b")
    ap.add_argument("--timeout", type=float, default=None, help="s to wait for [alphamine_perf] finished")
    ap.add_argument("--line", default=None, help="ax,az: autowalk follows the line through this anchor")
    ap.add_argument("--autowalk", action="append", default=[], help="extra autowalk key=value")
    ap.add_argument("--switch", action="append", default=[], help="pack switch k=v (perf.opts)")
    ap.add_argument("--pack", default=None, help="variant pack dir (WSL path), e.g. run/alphamine_lp")
    ap.add_argument("--size", default=None, help="frame WxH (F2F window)")
    ap.add_argument("--wait-idle", type=float, default=600, help="s to wait for an idle PC (lab.toml [perf])")
    ap.add_argument("--idle-window", type=float, default=None, help="s of continuous idle before the run")
    ap.add_argument("--allow-contended", action="store_true", help="run even if the PC never got idle (tagged "
                    "contended, ignored by gates)")
    for legacy in ("--userdir", "--dir", "--port", "--frames", "--end", "--no-server", "--keep"):
        ap.add_argument(legacy, default=None, nargs="?", const=True, help="removed in lab stage 3a (ignored)")


def run(scenario, o):
    for legacy in ("userdir", "dir", "port", "frames", "end", "no_server", "keep"):
        if getattr(o, legacy, None) not in (None, False):
            print("note: --%s is not supported any more (lab perf: leases only, realtime test build) - ignored" %
                  legacy.replace("_", "-"), flush=True)
    a = {"tag": o.tag, "walk": o.walk, "stand": o.stand, "settle": o.settle, "yaw": o.yaw, "turn": o.turn,
         "world": o.world, "switch": o.switch, "autowalk": o.autowalk}
    if o.line:
        a["line"] = o.line
    if o.pack:
        a["pack"] = win(o.pack) if o.pack.startswith("/") else o.pack
    if o.size:
        a["size"] = o.size
    a["timeout"] = o.timeout or (120 + (o.stand + o.walk + o.settle + 441) / 20.0 * 1.5)
    argv = [LAB, "perf", "alphamine", scenario, "--wait-idle", str(o.wait_idle)]
    if o.idle_window:
        argv += ["--idle-window", str(o.idle_window)]
    if o.allow_contended:
        argv.append("--allow-contended")
    for k, v in a.items():
        argv += ["--param", "%s=%s" % (k, json.dumps(v))]
    print("$ lab perf alphamine %s ..." % scenario, flush=True)
    return subprocess.call(argv)
