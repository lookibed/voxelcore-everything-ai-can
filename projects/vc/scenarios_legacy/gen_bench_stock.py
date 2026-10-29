#!/usr/bin/env python3
"""Стоковый генератор мира против gpu_worldgen (13.10, агент gen_bench): одна процедура и одни метрики для обоих.

Варианты (чередуются A/B в одном прогоне драйвера):
  stock:<генератор>  — tools/scenarios/gen_bench_stock.lua, паки только base (base:demo, base:flat_grass, core:default)
  gpu_classic        — tools/scenarios/gpu_worldgen_showcase.lua, preset=classic, rle=1, light=1 (паки gpu_compute,
                       gpu_worldgen, gpu_worldgen_light) — та же процедура, что gpu_worldgen_ab.py --rle 1 --light 1
Аренда F2F-движка (wasmrt engine_rt, часы realtime, 854×480, --param engine=v032), пауза до открытия мира (маркер
«prestart»), F2F perf (с trace) на фазе генерации от открытия мира и на фазе потока (sustain_s), `lab sysload` до/после
и во время потока, F2F shot на маркерах «view <имя>». Из trace (счётчик «chunks per frame») — время от первого
созданного чанка до последнего освещённого/последнего меша (зона готова к показу) — одинаково для обоих путей.

  LAB_OWNER=gen_bench LAB_ROLE=agent python3 tools/scenarios/gen_bench_stock.py \
      --variants stock:base:demo,gpu_classic --repeat 2 [--sustain 10] [--views 1] [--out /tmp/gen_bench/res.json]

Итог — JSON (по варианту — прогоны: числа фаз, perf-фазы, trace-итоги, sysload, кадры, run_dir, contended).
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
from gpu_worldgen_ab import perf_summary, sustain_numbers, sysload_sampler  # noqa: E402
from gpu_worldgen_showcase import numbers  # noqa: E402

TAGS = r"\[gen_bench\]|\[gpu_worldgen\]"


def log_lines(lease, tail=400):
    r = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", TAGS + r"|\[E\]|ERROR"],
                       capture_output=True, text=True, timeout=60)
    return [ln for ln in r.stdout.splitlines()
            if "[gen_bench]" in ln or "[gpu_worldgen]" in ln or "ERROR" in ln or "[E]" in ln]


def win2wsl(p):
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", p or "")
    return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/")) if m else p


def trace_stats(path):
    """Счётчики «chunks per frame» trace: первый кадр с созданным чанком, последний со светом/мешем."""
    try:
        ev = json.load(open(path)).get("traceEvents", [])
    except Exception as e:  # noqa: BLE001
        return {"error": str(e), "path": path}
    cnt = sorted((e for e in ev if e.get("name") == "chunks per frame"), key=lambda e: e["ts"])
    if not cnt:
        return {"error": "no counters", "path": path}
    t0 = cnt[0]["ts"]
    out = {"frames": len(cnt), "path": path}
    tot = {"chunks_load": 0, "light_chunk": 0, "mesh_upload": 0, "mesh_worker": 0}
    first = {}
    last = {}
    for e in cnt:
        a = e.get("args", {})
        for k in tot:
            v = a.get(k, 0)
            if v:
                tot[k] += v
                first.setdefault(k, e["ts"])
                last[k] = e["ts"]
    out["items"] = tot
    out["span_s"] = round((cnt[-1]["ts"] - t0) / 1e6, 3)
    base = first.get("chunks_load", t0)
    for k in tot:
        if k in last:
            out["first_%s_s" % k] = round((first[k] - base) / 1e6, 3)
            out["last_%s_s" % k] = round((last[k] - base) / 1e6, 3)
            # моменты, когда набрано 50 / 95 % элементов окна (поздние одиночные перестройки мешей не тянут «готовность»)
            acc, marks = 0, {}
            for e in cnt:
                acc += e.get("args", {}).get(k, 0)
                for q in (0.5, 0.95):
                    if q not in marks and acc >= q * tot[k]:
                        marks[q] = round((e["ts"] - base) / 1e6, 3)
            out["t50_%s_s" % k] = marks.get(0.5)
            out["t95_%s_s" % k] = marks.get(0.95)
    return out


def one(a, variant, idx):
    tag = "%s_%s%d" % (a.tag, variant.replace(":", "_"), idx + 1)
    if variant.startswith("stock:"):
        gen = variant[len("stock:"):]
        packs = []
        script = "gen_bench_stock.lua"
        marker = r"\[gen_bench\]"
        opts = "generator=%s;seed=%s;load_distance=8;hold_s=%g;sustain_s=%g;views=%d;view_s=%g;dwell_s=%g" % (
            gen, a.seed, a.hold, a.sustain, a.views, a.view_s, a.dwell)
        done_pat, gen_pat = "[gen_bench] done", "[gen_bench] generation "
    elif variant == "gpu_classic":
        packs = ["gpu_compute", "gpu_worldgen", "gpu_worldgen_light"]
        script = "gpu_worldgen_showcase.lua"
        marker = r"\[gpu_worldgen\]"
        opts = "preset=classic;views=%d;view_s=%g;hold_s=%g;sustain_s=%g;rle=1;light=1" % (
            a.views, a.view_s, a.hold, a.sustain)
        done_pat, gen_pat = "[gpu_worldgen] done", "[gpu_worldgen] generation "
    else:
        raise SystemExit("unknown variant " + variant)
    params = ["--param", "packs=" + json.dumps(packs), "--param", "script=" + script,
              "--param", "ready_marker=" + marker + " prestart", "--param", "manifest=" + opts, "--param", "ready_timeout=180",
              "--param", "engine=" + a.engine, "--param", "size=" + a.size]
    before = host_load()
    res = lab("lease", "wasmrt", "engine_rt", *params, "--ttl", str(int(a.timeout) + 300), "--start", timeout=400)
    lease = (res.get("lease") or {}).get("name") or res.get("name")
    if not lease:
        return {"variant": variant, "error": "lease failed", "res": res, "host_load_before": before}
    ldir = ((res.get("lease") or {}).get("dir")) or res.get("dir")
    out = {"variant": variant, "lease": lease, "dir": ldir, "opts": opts, "tag": tag, "shots": {}, "perf": {},
           "trace": {}, "sysload": [], "t_start": time.strftime("%H:%M:%S")}
    hello = lab("f2f", lease, "hello", "{}")
    out["gl"] = ((hello.get("result") or {}).get("gl") or {}).get("renderer")
    out["perf_start"] = lab("f2f", lease, "perf", json.dumps({"start": True, "trace": True})).get("ok")
    t0 = time.time()
    finished = False
    phase = "gen"
    stop = threading.Event()
    th = None
    shot_done = set()

    def perf_stop(name):
        r = lab("f2f", lease, "perf", json.dumps({"stop": True}))
        out["perf"][name] = perf_summary(r)
        d = lab("f2f", lease, "perf", json.dumps({"dump": "perf_%s.json" % name}))
        out["trace"][name] = {"dump": d.get("result") or d}

    try:
        while time.time() - t0 < a.timeout:
            lines = log_lines(lease)
            if phase == "gen" and any(gen_pat in ln for ln in lines):
                perf_stop("gen")
                phase = "after_gen"
            if phase == "after_gen" and any("] sustain start" in ln for ln in lines):
                lab("f2f", lease, "perf", json.dumps({"start": True, "trace": True}))
                th = threading.Thread(target=sysload_sampler, args=(stop, out["sysload"]), daemon=True)
                th.start()
                phase = "sustain"
            if phase == "sustain" and any("] sustain end" in ln for ln in lines):
                perf_stop("sustain")
                stop.set()
                phase = "views"
            for ln in lines:
                m = re.search(r"\] view (\w+)", ln)
                if m and m.group(1) not in shot_done:
                    name = m.group(1)
                    time.sleep(2.0)
                    r = lab("f2f", lease, "shot", json.dumps({"name": "%s_%s" % (tag, name)}))
                    out["shots"][name] = (r.get("result") or {})
                    shot_done.add(name)
            if any(done_pat in ln for ln in lines):
                finished = True
                break
            if any(("[E]" in ln or "ERROR" in ln) and re.search(r"lua|script|gpu_worldgen|gen_bench|uncaught", ln, re.I)
                   for ln in lines):
                break
            time.sleep(0.5)
        lines = log_lines(lease, tail=3000)
        out["lines"] = [ln.split("] ", 2)[-1] if "lua-debug" in ln else ln for ln in lines]
        out["finished"] = finished
        # trace-файлы читаем до освобождения аренды (каталог может уйти в runs)
        for name, t in out["trace"].items():
            dres = t.get("dump") or {}
            p = dres.get("path") or dres.get("file") or (os.path.join(win2wsl(ldir), "perf_%s.json" % name) if ldir else None)
            t["stats"] = trace_stats(win2wsl(p)) if p else {"error": "no path", "dump": dres}
            if p and a.keep_traces:
                os.makedirs(a.keep_traces, exist_ok=True)
                try:
                    import shutil
                    dst = os.path.join(a.keep_traces, "%s_%s.json" % (tag, name))
                    shutil.copyfile(win2wsl(p), dst)
                    t["stats"]["copy"] = dst
                except OSError as e:
                    t["stats"]["copy_error"] = str(e)
            t.pop("dump", None) if "error" not in t["stats"] else None
    finally:
        stop.set()
        if th:
            th.join(timeout=150)
        rel = lab("release", lease)
        out["run_dir"] = rel.get("run_dir") or rel.get("run") or rel.get("logs")
    after = host_load()
    out["host_load"] = {"before": before, "after": after}
    out["contended"] = bool(before.get("busy") or after.get("busy") or before.get("other_leases")
                            or after.get("other_leases"))
    out["numbers"] = numbers(out["lines"])
    out["sustain"] = sustain_numbers(out["lines"])
    for ln in out["lines"]:
        for key, pat in (("zone", r"zone: (\d+) chunks"), ("settings", r"settings: (.*)$"),
                         ("after_open", r"chunks at open (\d+), after open (\d+), after-open rate ([\d.]+)"),
                         ("gpu_ms_chunk", r"gpu_cost: .* -> ([\-\d.]+) ms/chunk")):
            m = re.search(pat, ln)
            if m:
                out[key] = m.groups() if len(m.groups()) > 1 else m.group(1)
    out["hops"] = [ln for ln in out["lines"] if "] hop " in ln or ln.startswith("hop ")]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variants", default="stock:base:demo,gpu_classic")
    ap.add_argument("--repeat", type=int, default=2)
    ap.add_argument("--engine", default="v032")
    ap.add_argument("--size", default="854x480")
    ap.add_argument("--seed", default="20261011")
    ap.add_argument("--sustain", type=float, default=10)
    ap.add_argument("--hold", type=float, default=3)
    ap.add_argument("--views", type=int, default=1)
    ap.add_argument("--view-s", type=float, default=3)
    ap.add_argument("--dwell", type=float, default=0.2, help="сток, поток: пауза после зоны до прыжка (с)")
    ap.add_argument("--timeout", type=float, default=420)
    ap.add_argument("--tag", default="gb")
    ap.add_argument("--out", default=None)
    ap.add_argument("--keep-traces", default=None, help="куда скопировать trace-файлы perf до освобождения аренды")
    a = ap.parse_args()
    res = {v: [] for v in a.variants.split(",")}
    for i in range(a.repeat):          # A/B чередованием: A1 B1 A2 B2
        for v in res:
            res[v].append(one(a, v, i))
            if a.out:
                json.dump(res, open(a.out, "w"), ensure_ascii=False, indent=1)
    print(json.dumps(res, ensure_ascii=False, indent=1))
    return 0 if all(r.get("finished") for v in res.values() for r in v) else 1


if __name__ == "__main__":
    sys.exit(main())
