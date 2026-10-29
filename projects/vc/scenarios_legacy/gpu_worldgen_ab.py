#!/usr/bin/env python3
"""A/B-замеры gpu_worldgen (12.10, gpu_pack2): RLE на GPU и свет в шейдерах пака против прежнего пути.

Аренда F2F-движка (wasmrt engine_rt, часы realtime), сценарий tools/scenarios/gpu_worldgen_showcase.lua с паузой до
открытия мира (маркер «prestart»: драйвер успевает включить F2F perf), фазы:
  1) генерация зоны загрузки от открытия мира — Lua (чанков/с, fps, мс/чанк), F2F perf (light_chunk, mesh_worker, ...);
  2) sustain_s секунд установившегося потока (все загруженные чанки снова в очередь, как только она пуста) — те же числа
     + загрузка ПК/GPU (`lab sysload`) во время фазы;
  3) витринные точки (--views 1) — кадры F2F shot.

  LAB_OWNER=gpu_pack2 LAB_ROLE=agent python3 tools/scenarios/gpu_worldgen_ab.py --presets classic,mountains \\
      [--rle 0|1] [--light 0|1] [--sustain 10] [--views 0] [--size 854x480] [--repeat 1] [--tag ab] [--opts "k=v;..."]

Итог — JSON в stdout (по пресету — прогоны: числа фаз, perf-фазы движка, хэши, sysload, кадры).
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
from gpu_worldgen_run import lab, host_load  # noqa: E402


def log_lines(lease, tail=400):
    r = subprocess.run([os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                                     "tools", "lab", "lab"), "logs", lease, "--tail", str(tail), "--grep",
                        r"gpu_worldgen|\[E\]|ERROR"], capture_output=True, text=True, timeout=60)
    return [ln for ln in r.stdout.splitlines() if "[gpu_worldgen" in ln or "ERROR" in ln or "[E]" in ln]
from gpu_worldgen_showcase import numbers  # noqa: E402

PHASES = ("frame", "lua", "light_chunk", "light_block", "mesh_worker", "mesh_upload", "mesh_sync", "chunks_load",
          "render", "render_world", "gui", "hud", "world_update")


def perf_summary(res):
    r = res.get("result") or res
    ph = (r.get("summary") or {}).get("phases") or r.get("phases") or {}
    out = {}
    for k in PHASES:
        v = ph.get(k)
        if v:
            out[k] = {"count": v.get("count"), "items": v.get("items"), "sum_ms": round(v.get("sum_ms", 0), 2),
                      "mean_ms": round(v.get("mean_ms", 0), 4), "p99_ms": v.get("p99_ms"), "frames": v.get("frames")}
            if v.get("items"):
                out[k]["ms_per_item"] = round(v.get("sum_ms", 0) / v["items"], 4)
    return out


def sustain_numbers(lines):
    for ln in lines:
        m = re.search(r"sustain end \w+: (\d+) chunks in ([\d.]+) s = ([\d.]+) ch/s; frames (\d+), avg fps ([\d.]+), "
                      r"frame ms p50 ([\d.]+) p95 ([\d.]+) max ([\d.]+); Lua ms/chunk: read ([\d.]+) copy ([\d.]+) "
                      r"decode ([\d.]+) encode ([\d.]+) set ([\d.]+) total ([\d.]+)", ln)
        if m:
            g = [float(x) for x in m.groups()]
            return dict(chunks=int(g[0]), s=g[1], chps=g[2], frames=int(g[3]), fps=g[4], p50=g[5], p95=g[6],
                        max_ms=g[7], lua_read=g[8], lua_copy=g[9], lua_decode=g[10], lua_encode=g[11], lua_set=g[12],
                        lua_total=g[13])
    return None


def sysload_sampler(stop, out):
    while not stop.is_set():
        s = lab("sysload", timeout=120)
        smp = s.get("sample") or {}
        out.append({"t": round(time.time(), 1), "busy": s.get("busy"), "reasons": s.get("reasons"),
                    "cpu_total_pct": smp.get("cpu_total_pct"), "cpu_others_pct": smp.get("cpu_others_pct"),
                    "gpu": smp.get("gpu")})


def one(a, preset, idx):
    tag = "%s_%s%s" % (a.tag, preset, "" if a.repeat == 1 else str(idx + 1))
    opts = "preset=%s;views=%d;hold_s=%g;sustain_s=%g;rle=%d;light=%d;%s" % (
        preset, a.views, a.hold, a.sustain, a.rle, a.light, a.opts)
    packs = ["gpu_compute", "gpu_worldgen"] + (["gpu_worldgen_light"] if a.light else []) + \
        ([a.extra_pack] if a.extra_pack else [])
    if a.extra_pack:
        opts += ";extra_pack=" + a.extra_pack
    params = ["--param", "packs=" + json.dumps(packs), "--param", "script=gpu_worldgen_showcase.lua",
              "--param", r"ready_marker=\[gpu_worldgen\] prestart", "--param", "manifest=" + opts,
              "--param", "ready_timeout=180"]
    if a.engine != "v031":
        params += ["--param", "engine=" + a.engine]
    if a.size:
        params += ["--param", "size=" + a.size]
    before = host_load()
    res = lab("lease", "wasmrt", "engine_rt", *params, "--ttl", str(int(a.timeout) + 300), "--start", timeout=400)
    lease = (res.get("lease") or {}).get("name") or res.get("name")
    if not lease:
        return {"error": "lease failed", "res": res, "host_load_before": before}
    out = {"lease": lease, "engine": a.engine, "opts": opts, "tag": tag, "shots": {}, "perf": {}, "sysload": []}
    hello = lab("f2f", lease, "hello", "{}")
    out["gl"] = ((hello.get("result") or {}).get("gl") or {}).get("renderer")
    lab("f2f", lease, "perf", json.dumps({"start": True}))
    t0 = time.time()
    finished = False
    phase = "gen"
    stop = threading.Event()
    th = None
    shot_done = set()
    try:
        while time.time() - t0 < a.timeout:
            lines = log_lines(lease)
            if phase == "gen" and any("] generation " in ln for ln in lines):
                out["perf"]["gen"] = perf_summary(lab("f2f", lease, "perf", json.dumps({"stop": True})))
                phase = "after_gen"
            if phase == "after_gen" and any("] sustain start" in ln for ln in lines):
                lab("f2f", lease, "perf", json.dumps({"start": True}))
                th = threading.Thread(target=sysload_sampler, args=(stop, out["sysload"]), daemon=True)
                th.start()
                phase = "sustain"
            if phase == "sustain" and any("] sustain end" in ln for ln in lines):
                out["perf"]["sustain"] = perf_summary(lab("f2f", lease, "perf", json.dumps({"stop": True})))
                stop.set()
                phase = "views"
            for ln in lines:
                m = re.search(r"\[gpu_worldgen\] view (\w+)", ln)
                if m and m.group(1) not in shot_done:
                    name = m.group(1)
                    time.sleep(2.0)
                    r = lab("f2f", lease, "shot", json.dumps({"name": "%s_%s_%s" % (tag, a.engine, name)}))
                    out["shots"][name] = (r.get("result") or {})
                    shot_done.add(name)
            if any("[gpu_worldgen] done" in ln for ln in lines):
                finished = True
                break
            if any(("[E]" in ln or "ERROR" in ln) and re.search(r"lua|script|gpu_worldgen|uncaught", ln, re.I)
                   for ln in lines):
                break
            time.sleep(0.5)
        lines = log_lines(lease, tail=3000)
        out["lines"] = [ln.split("] ", 2)[-1] if "lua-debug" in ln else ln for ln in lines]
        out["finished"] = finished
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
    hashes = {}
    for ln in out["lines"]:
        m = re.search(r"area hash (\S+) = (\w+)", ln)
        if m:
            hashes["area"] = m.group(2)
        m = re.search(r"chunk hashes (.*)$", ln)
        if m:
            hashes["chunks"] = m.group(1).strip()
        m = re.search(r"rle verify: (.*)$", ln)
        if m:
            out["rle_verify"] = m.group(1)
    out["hashes"] = hashes
    gpus = [s["gpu"] for s in out["sysload"] if s.get("gpu") is not None]
    out["sustain_gpu"] = gpus
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--presets", default="classic,mountains,caves,islands")
    ap.add_argument("--engine", default="v032")
    ap.add_argument("--size", default="854x480")
    ap.add_argument("--opts", default="")
    ap.add_argument("--views", type=int, default=0)
    ap.add_argument("--rle", type=int, default=0)
    ap.add_argument("--light", type=int, default=0)
    ap.add_argument("--sustain", type=float, default=10)
    ap.add_argument("--hold", type=float, default=3)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--timeout", type=float, default=420)
    ap.add_argument("--tag", default="ab")
    ap.add_argument("--extra-pack", default=None, help="ещё пак мира (отладка)")
    ap.add_argument("--out", default=None, help="куда записать JSON (кроме stdout)")
    a = ap.parse_args()
    res = {}
    for preset in a.presets.split(","):
        res[preset] = [one(a, preset, i) for i in range(a.repeat)]
        if a.out:
            json.dump(res, open(a.out, "w"), ensure_ascii=False, indent=1)
    print(json.dumps(res, ensure_ascii=False, indent=1))
    return 0 if all(r.get("finished") for v in res.values() for r in v) else 1


if __name__ == "__main__":
    sys.exit(main())
