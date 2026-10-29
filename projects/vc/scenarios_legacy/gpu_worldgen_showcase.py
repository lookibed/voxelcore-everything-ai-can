#!/usr/bin/env python3
"""Витрина пресетов gpu_worldgen в лаборатории: для каждого пресета — аренда F2F-движка (wasmrt engine_rt, часы
realtime), сценарий tools/scenarios/gpu_worldgen_showcase.lua (новый мир на пресете -> генерация -> замеры -> хэш
области -> gpu_cost -> витринные точки), кадры F2F shot на маркерах «view <имя>», итоговые числа.

  LAB_OWNER=gpu_show LAB_ROLE=agent python3 tools/scenarios/gpu_worldgen_showcase.py \
      [--presets mountains,caves,islands] [--engine v032|v031] [--size 1408x902] [--opts "view_s=6"] [--repeat 2]
      [--views 0]   # только замеры (кадров нет), например --size 854x480 --views 0 --repeat 2

Кадры — только F2F shot (кадровый буфер), ввод ОС не используется. Размер кадра витрины — 1408x902 (явно, по заданию
пользователя 12.10), замеры сравниваются с README пака при 854x480 (--size 854x480).
Итог — JSON в stdout: по пресету — прогоны (аренда, каталог, кадры, строки), числа (ч/с, fps, мс/чанк, gpu_cost),
хэши области и same (все прогоны пресета равны), contended. Код 0 — все прогоны дошли до done, хэши совпали.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gpu_worldgen_run import one_run  # noqa: E402


def numbers(lines):
    out = {}
    for ln in lines:
        m = re.search(r"generation \w+: ok=(\w+), (\d+) chunks .*? in ([\d.]+) s from world open \(([\d.]+) s first\.\.last "
                      r"chunk\) = ([\d.]+) ch/s; frames (\d+), avg fps ([\d.]+), frame ms p50 ([\d.]+) p95 ([\d.]+) max ([\d.]+), "
                      r">33 ms: (\d+); Lua ms/chunk: read ([\d.]+) copy ([\d.]+) decode ([\d.]+) encode ([\d.]+) set ([\d.]+) "
                      r"total ([\d.]+)", ln)
        if m:
            g = m.groups()
            out.update(ok=g[0] == "true", chunks=int(g[1]), open_s=float(g[2]), span_s=float(g[3]), chps=float(g[4]),
                       frames=int(g[5]), fps=float(g[6]), p50=float(g[7]), p95=float(g[8]), max_ms=float(g[9]),
                       slow=int(g[10]), lua_read=float(g[11]), lua_copy=float(g[12]), lua_decode=float(g[13]),
                       lua_encode=float(g[14]), lua_set=float(g[15]), lua_total=float(g[16]))
        m = re.search(r"window \w+: first ([\d.]+) s after world open: (\d+) frames, avg fps ([\d.]+), frame ms p50 ([\d.]+) "
                      r"p95 ([\d.]+) p99 ([\d.]+) max ([\d.]+)", ln)
        if m:
            out["window"] = {"s": float(m.group(1)), "fps": float(m.group(3)), "p95": float(m.group(5)),
                             "p99": float(m.group(6)), "max": float(m.group(7))}
        m = re.search(r"gpu_cost: .* -> ([\-\d.]+) ms/chunk", ln)
        if m:
            out["gpu_ms_chunk"] = float(m.group(1))
        m = re.search(r"payload: set_chunk_data avg (\d+) B", ln)
        if m:
            out["payload_b"] = int(m.group(1))
        m = re.search(r"\] (spawn \w+: .*)$", ln) or re.search(r"^(spawn \w+: .*)$", ln)
        if m:
            out["spawn"] = m.group(1)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--presets", default="mountains,caves,islands")
    ap.add_argument("--engine", default="v032")
    ap.add_argument("--size", default="1408x902")
    ap.add_argument("--opts", default="view_s=6")
    ap.add_argument("--views", type=int, default=1)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--timeout", type=float, default=420)
    ap.add_argument("--tag", default="show")
    a = ap.parse_args()
    res = {}
    all_ok = True
    for preset in a.presets.split(","):
        runs = []
        for i in range(a.repeat):
            ns = argparse.Namespace(
                tag="%s_%s%s" % (a.tag, preset, "" if a.repeat == 1 else str(i + 1)), repeat=1, engine=a.engine,
                opts="preset=%s;views=%d;%s" % (preset, a.views, a.opts), script="gpu_worldgen_showcase.lua",
                size=a.size, timeout=a.timeout, expect=None)
            r = one_run(ns, 0)
            r["numbers"] = numbers(r.get("lines", []))
            runs.append(r)
        area = [next((v for k, v in r.get("hashes", {}).items() if k.startswith("area")), None) for r in runs]
        chunks = [r.get("hashes", {}).get("chunks") for r in runs]
        same = len(set(area)) == 1 and None not in area and len(set(chunks)) == 1
        ok = all(r.get("finished") for r in runs) and (same or a.repeat == 1)
        all_ok = all_ok and ok
        res[preset] = {"runs": runs, "area_hashes": area, "chunk_hashes": chunks, "same": same,
                       "contended": any(r.get("contended") for r in runs)}
    print(json.dumps(res, ensure_ascii=False, indent=1))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
