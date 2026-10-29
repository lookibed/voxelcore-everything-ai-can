#!/usr/bin/env python3
"""Пропускная способность прохода gpu_worldgen — «чанков на кадр» (13.10, агент gpu_cap).

Сценарий tools/scenarios/gpu_worldgen_throughput.lua: фаза static (новый мир, от первого до последнего чанка при
дальности --ld) и фаза flight (полёт по +x со скоростью --speed блоков/с, --flight-s секунд). Каждая конфигурация —
окно (--param size, F2F-кадр) × потолок прохода (pass) × темп (pace frame | raw), --repeat прогонов чередованием.
Аренда wasmrt engine_rt (часы realtime, v032), `lab sysload` до/после и во время аренды (фазы по маркерам лога),
contended — ПК занят до/после или рядом чужие аренды.

  LAB_OWNER=gpu_cap LAB_ROLE=agent python3 tools/scenarios/gpu_worldgen_throughput.py \\
      --configs 854x480:768x432,1408x902:1408x902,2048x2048:2048x2048 --paces frame,raw --repeat 2 \\
      --ld 32 --speed 160 --flight-s 20 [--fit 1] [--out /tmp/gpu_cap/tp.json]

Итог — JSON (по конфигурации — прогоны: строки static/flight разобраны в числа, GPU % по фазам, run_dir, contended)
и таблица в stdout.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gpu_worldgen_run import lab, host_load, LAB  # noqa: E402
from gpu_worldgen_ab import perf_summary  # noqa: E402

PAT = re.compile(
    r"(static|flight|requeue) (\S+): (\d+) chunks in ([\d.]+) s = ([\d.]+) ch/s; frames (\d+), fps ([\d.]+), frame ms p50 ([\d.]+) "
    r"p95 ([\d.]+) max ([\d.]+); per frame: gpu avg ([\d.]+) p95 (\d+) max (\d+), written avg ([\d.]+) p95 (\d+) max (\d+); "
    r"queue avg (\d+) max (\d+), empty-queue frames (\d+); gpu tiles (\d+)")
KEYS = ("chunks", "s", "chps", "frames", "fps", "p50", "p95", "max_ms", "gpu_avg", "gpu_p95", "gpu_max", "wr_avg", "wr_p95",
        "wr_max", "q_avg", "q_max", "empty", "gpu_tiles")


def log_lines(lease, tail=600):
    r = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", r"gpu_worldgen|\[E\]|ERROR"],
                       capture_output=True, text=True, timeout=60)
    return [ln for ln in r.stdout.splitlines() if "[gpu_worldgen]" in ln or "ERROR" in ln or "[E]" in ln]


def parse(lines):
    out = {}
    for ln in lines:
        m = PAT.search(ln)
        if m:
            g = m.groups()
            d = {"tag": g[1]}
            for k, v in zip(KEYS, g[2:]):
                d[k] = float(v)
            out[g[0]] = d
        for key, pat in (("pass", r"\] pass: (.*)$"), ("pass_info", r"pass info: (.*)$"), ("settings", r"settings: (.*)$"),
                         ("hash", r"area hash \[-3\.\.3\]\^2 = (\w+)"), ("static_tail", r"static \S+: .*(ok=.*)$"),
                         ("flight_tail", r"flight \S+: .*(speed .*)$")):
            m = re.search(pat, ln)
            if m:
                out[key] = m.group(1)
    return out


def sampler(stop, out, phase):
    while not stop.is_set():
        s = lab("sysload", timeout=120)
        smp = s.get("sample") or {}
        g = smp.get("gpu") or []
        out.append({"t": round(time.time(), 1), "phase": phase[0], "busy": s.get("busy"), "reasons": s.get("reasons"),
                    "cpu_total_pct": smp.get("cpu_total_pct"), "cpu_others_pct": smp.get("cpu_others_pct"),
                    "gpu_pct": g[0].get("util_pct") if g else None})


def one(a, win, pas, pace, idx):
    tag = "%s_w%s_p%s_%s%d" % (a.tag, win, pas, pace, idx + 1)
    # проход "cfgWxH" — потолок из config:gpu_worldgen/settings.toml (сценарий пишет файл), "default" — умолчание пака
    pass_opt = ("config_pass=" + pas[3:]) if pas.startswith("cfg") else ("" if pas == "default" else "pass=" + pas)
    opts = "%s;pace=%s;fit=%d;load_distance=%d;speed=%g;flight_s=%g;hold_s=%g;timeout=%d;static=1;requeue=%d%s" % (
        pass_opt, pace, a.fit, a.ld, a.speed, a.flight_s, a.hold, a.scn_timeout, a.requeue,
        (";load_speed=%d" % a.load_speed) if a.load_speed else "")
    params = ["--param", 'packs=["gpu_compute","gpu_worldgen"]', "--param", "script=gpu_worldgen_throughput.lua",
              "--param", r"ready_marker=\[gpu_worldgen\] prestart", "--param", "manifest=" + opts,
              "--param", "ready_timeout=180", "--param", "engine=" + a.engine, "--param", "size=" + win]
    before = host_load()
    res = lab("lease", "wasmrt", "engine_rt", *params, "--ttl", str(int(a.timeout) + 300), "--start", timeout=400)
    lease = (res.get("lease") or {}).get("name") or res.get("name")
    if not lease:
        return {"tag": tag, "error": "lease failed", "res": res, "host_load_before": before}
    out = {"tag": tag, "lease": lease, "window": win, "pass": pas, "pace": pace, "opts": opts, "sysload": []}
    hello = lab("f2f", lease, "hello", "{}")
    hr = hello.get("result") or {}
    out["gl"] = (hr.get("gl") or {}).get("renderer")
    out["hello_size"] = hr.get("size") or hr.get("window")
    out["perf"] = {}
    if a.perf:
        lab("f2f", lease, "perf", json.dumps({"start": True}))
    phase = ["start"]
    stop = threading.Event()
    th = threading.Thread(target=sampler, args=(stop, out["sysload"], phase), daemon=True)
    th.start()
    t0 = time.time()
    finished = False
    try:
        while time.time() - t0 < a.timeout:
            lines = log_lines(lease)
            txt = "\n".join(lines)
            if "] ready" in txt and phase[0] == "start":
                phase[0] = "static"
            if "] area hash" in txt and phase[0] in ("start", "static"):
                if a.perf:
                    out["perf"]["static"] = perf_summary(lab("f2f", lease, "perf", json.dumps({"stop": True})))
                phase[0] = "between"
            if "] requeue start" in txt and phase[0] == "between":
                if a.perf:
                    lab("f2f", lease, "perf", json.dumps({"start": True}))
                phase[0] = "requeue"
            if "] requeue end" in txt and phase[0] == "requeue":
                if a.perf:
                    out["perf"]["requeue"] = perf_summary(lab("f2f", lease, "perf", json.dumps({"stop": True})))
                phase[0] = "between"
            if "] flight start" in txt and phase[0] == "between":
                if a.perf:
                    lab("f2f", lease, "perf", json.dumps({"start": True}))
                phase[0] = "flight"
            if "] flight end" in txt and phase[0] == "flight":
                if a.perf:
                    out["perf"]["flight"] = perf_summary(lab("f2f", lease, "perf", json.dumps({"stop": True})))
                phase[0] = "after"
            if "[gpu_worldgen] done" in txt:
                finished = True
                break
            if any(("[E]" in ln or "ERROR" in ln) and re.search(r"lua|script|gpu_worldgen|uncaught", ln, re.I)
                   for ln in lines):
                break
            time.sleep(0.5)
        lines = log_lines(lease, tail=4000)
        out["lines"] = [ln.split("] ", 2)[-1] if "lua-debug" in ln else ln for ln in lines
                        if re.search(r"static |flight |requeue |pass|settings|area hash|ERROR|\[E\]", ln)
                        and "per frame" not in ln][-60:]
        out["finished"] = finished
    finally:
        stop.set()
        th.join(timeout=150)
        rel = lab("release", lease)
        out["run_dir"] = rel.get("run_dir") or rel.get("run") or rel.get("logs")
    after = host_load()
    out["host_load"] = {"before": before, "after": after}
    # во время аренды «GPU busy» sysload — в основном сам движок аренды (nvidia-smi меряет весь GPU), поэтому
    # contended — по снимкам до/после, чужим арендам и посторонним CPU-процессам во время прогона (не по GPU)
    busy = [s for s in out["sysload"] if any("GPU" not in x for x in (s.get("reasons") or []))]
    out["contended"] = bool(before.get("other_leases") or after.get("other_leases") or before.get("busy")
                            or after.get("busy") or (out["sysload"] and len(busy) >= 0.2 * len(out["sysload"])))
    out["numbers"] = parse(lines)
    for ph in ("static", "requeue", "flight"):
        g = [s["gpu_pct"] for s in out["sysload"] if s["phase"] == ph and s.get("gpu_pct") is not None]
        out["gpu_%s" % ph] = round(sum(g) / len(g), 1) if g else None
        out["gpu_%s_n" % ph] = len(g)
    g = [s["gpu_pct"] for s in out["sysload"] if s["phase"] == "start" and s.get("gpu_pct") is not None]
    out["gpu_idle"] = round(sum(g) / len(g), 1) if g else None
    return out


def table(res):
    rows = ["| окно | проход | тест | темп | ч/кадр GPU ср/p95/max | ч/кадр записано ср/p95/max | ч/с | fps (p95 мс) | очередь ср/max, пустых кадров | GPU % | contended |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    for key, runs in res.items():
        for r in runs:
            n = r.get("numbers") or {}
            for ph in ("static", "requeue", "flight"):
                d = n.get(ph)
                if not d:
                    continue
                rows.append("| %s | %s | %s | %s | %.2f / %d / %d | %.2f / %d / %d | %.0f | %.1f (%.1f) | %d / %d, %d | %s | %s |" % (
                    r["window"], r["pass"], ph, r["pace"], d["gpu_avg"], d["gpu_p95"], d["gpu_max"], d["wr_avg"],
                    d["wr_p95"], d["wr_max"], d["chps"], d["fps"], d["p95"], d["q_avg"], d["q_max"], d["empty"],
                    r.get("gpu_%s" % ph), "да" if r.get("contended") else "нет"))
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--configs", default="854x480:768x432", help="окно:проход через запятую")
    ap.add_argument("--paces", default="frame,raw")
    ap.add_argument("--repeat", type=int, default=2)
    ap.add_argument("--engine", default="v032")
    ap.add_argument("--fit", type=int, default=1)
    ap.add_argument("--requeue", type=int, default=0, help="фаза перезаписи всех загруженных чанков (проход без подачи движка)")
    ap.add_argument("--perf", type=int, default=1, help="F2F perf по фазам static/flight (фазы CPU движка)")
    ap.add_argument("--ld", type=int, default=32)
    ap.add_argument("--load-speed", type=int, default=0)
    ap.add_argument("--speed", type=float, default=160)
    ap.add_argument("--flight-s", type=float, default=20)
    ap.add_argument("--hold", type=float, default=3)
    ap.add_argument("--scn-timeout", type=int, default=300)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--tag", default="tp")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    cfgs = [c.split(":") for c in a.configs.split(",")]
    res = {}
    for i in range(a.repeat):
        for win, pas in cfgs:
            for pace in a.paces.split(","):
                key = "%s|%s|%s" % (win, pas, pace)
                res.setdefault(key, []).append(one(a, win, pas, pace, i))
                if a.out:
                    json.dump(res, open(a.out, "w"), ensure_ascii=False, indent=1)
    print(json.dumps(res, ensure_ascii=False, indent=1))
    print(table(res))
    return 0 if all(r.get("finished") for v in res.values() for r in v) else 1


if __name__ == "__main__":
    sys.exit(main())
