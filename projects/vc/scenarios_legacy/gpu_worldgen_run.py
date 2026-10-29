#!/usr/bin/env python3
"""Прогон пака gpu_worldgen в лаборатории: аренда F2F-движка (wasmrt engine_rt, часы realtime), сценарий
tools/scenarios/gpu_worldgen_world.lua (новый мир на генераторе gpu_worldgen:gpu), кадры F2F shot на маркерах
«view relief» / «view cave», строки замеров из лога, освобождение аренды.

  LAB_OWNER=gpu_gen LAB_ROLE=agent python3 tools/scenarios/gpu_worldgen_run.py [--engine v032|v031]
      [--opts "backend=gpu;radius=3;load_distance=6"] [--size 854x480] [--tag NAME] [--repeat 2] [--expect HASH]

Итог — JSON в stdout: по прогону — аренда, каталог прогона, кадры (путь, sha256), строки [gpu_worldgen]
generation/area hash/gpu_cost/readback/density/parity, загрузка ПК до/после (lab sysload) и чужие аренды;
contended = ПК занят до или после (причины в host_load) или рядом работала чужая аренда движка.
--repeat N — N аренд подряд (новый мир с тем же seed), determinism: хэши области и чанков всех прогонов равны
(и равны --expect, если задан — например, хэш с другой версии движка). Код 0 — все прогоны дошли до done и
детерминизм не нарушен. Ввод ОС не используется; снимки — только F2F shot (кадровый буфер).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

VC_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAB = os.path.join(VC_ROOT, "tools", "lab", "lab")


def lab(*args, timeout=600):
    r = subprocess.run([LAB, *args], capture_output=True, text=True, timeout=timeout)
    out = r.stdout.strip()
    try:
        return json.loads(out[out.index("{"):]) if "{" in out else {"raw": out, "err": r.stderr}
    except ValueError:
        return {"raw": out, "err": r.stderr}


def log_lines(lease, grep=r"gpu_worldgen|\[E\]|ERROR", tail=400):
    r = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", grep], capture_output=True, text=True,
                       timeout=60)
    return [ln for ln in r.stdout.splitlines() if "[gpu_worldgen]" in ln or "ERROR" in ln or "[E]" in ln]


def host_load():
    s = lab("sysload", timeout=120)
    smp = s.get("sample") or {}
    ps = lab("ps", timeout=60)
    others = [(l.get("name"), l.get("owner"), (l.get("params") or {}).get("script"))
              for l in ps.get("leases", []) if l.get("owner") != os.environ.get("LAB_OWNER")]
    return {"busy": s.get("busy"), "reasons": s.get("reasons"), "cpu_total_pct": smp.get("cpu_total_pct"),
            "cpu_others_pct": smp.get("cpu_others_pct"), "gpu": smp.get("gpu"), "user_active": smp.get("user_active"),
            "other_leases": others}


def one_run(a, idx):
    tag = a.tag if a.repeat == 1 else "%s%d" % (a.tag, idx + 1)
    params = ["--param", 'packs=["gpu_compute","gpu_worldgen"]', "--param", "script=" + a.script,
              "--param", r"ready_marker=\[gpu_worldgen\] ready", "--param", "manifest=" + a.opts,
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
    out = {"lease": lease, "engine": a.engine, "opts": a.opts, "tag": tag, "shots": {}, "lines": []}
    shot_done = set()
    t0 = time.time()
    finished = False
    try:
        while time.time() - t0 < a.timeout:
            lines = log_lines(lease)
            for ln in lines:
                m = re.search(r"\[gpu_worldgen\] view (\w+)", ln)
                if m and m.group(1) not in shot_done:
                    name = m.group(1)
                    time.sleep(1.5)  # кадр с новой позицией камеры и догруженными мешами
                    r = lab("f2f", lease, "shot", json.dumps({"name": "%s_%s_%s" % (tag, a.engine, name)}))
                    out["shots"][name] = (r.get("result") or {})
                    shot_done.add(name)
            if any("[gpu_worldgen] done" in ln for ln in lines):
                finished = True
                break
            # ошибки скриптов (а не стартовые [E] движка: audio input, framebuffer постобработки 0x0 на 0.31)
            if any(("[E]" in ln or "ERROR" in ln) and re.search(r"lua|script|gpu_worldgen|uncaught", ln, re.I)
                   for ln in lines):
                break
            time.sleep(1.0)
        lines = log_lines(lease, tail=2000)
        out["lines"] = [ln.split("] ", 2)[-1] if "lua-debug" in ln else ln for ln in lines]
        out["finished"] = finished
    finally:
        rel = lab("release", lease)
        out["run_dir"] = rel.get("run_dir") or rel.get("run") or rel.get("logs")
    after = host_load()
    out["host_load"] = {"before": before, "after": after}
    out["contended"] = bool(before.get("busy") or after.get("busy") or before.get("other_leases")
                            or after.get("other_leases"))
    hashes = {}
    for ln in out["lines"]:
        m = re.search(r"area hash (\S+) = (\w+)", ln)
        if m:
            hashes["area " + m.group(1)] = m.group(2)
        m = re.search(r"\] (chunk hashes) (.*)$", ln) or re.search(r"^(chunk hashes) (.*)$", ln)
        if m:
            hashes["chunks"] = m.group(2).strip()
    out["hashes"] = hashes
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="v032")
    ap.add_argument("--opts", default="radius=3;view_s=6")
    ap.add_argument("--size", default=None)
    ap.add_argument("--timeout", type=float, default=420)
    ap.add_argument("--tag", default="gpu")
    ap.add_argument("--script", default="gpu_worldgen_world.lua")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--expect", default=None, help="ожидаемый area hash (другой прогон/движок)")
    a = ap.parse_args()
    runs = [one_run(a, i) for i in range(a.repeat)]
    area = [next((v for k, v in r.get("hashes", {}).items() if k.startswith("area")), None) for r in runs]
    chunks = [r.get("hashes", {}).get("chunks") for r in runs]
    det = {"area_hashes": area, "chunk_hashes": chunks,
           "same": len(set(area)) == 1 and None not in area and len(set(chunks)) == 1}
    if a.expect:
        det["expect"] = a.expect
        det["same"] = det["same"] and area[0] == a.expect
    out = {"runs": runs, "determinism": det, "contended": any(r.get("contended") for r in runs)}
    print(json.dumps(out, ensure_ascii=False, indent=1))
    ok = all(r.get("finished") for r in runs) and (det["same"] or (a.repeat == 1 and not a.expect))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
