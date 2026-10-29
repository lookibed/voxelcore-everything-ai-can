#!/usr/bin/env python3
"""Проверка пункта меню gpu_worldgen (страница пресетов, F6 в мире, возврат на страницу) в лаборатории, только F2F:
аренда wasmrt engine_rt v032 со сценарием gpu_worldgen_play.lua (зеркало scripts/app/gpu_worldgen.lua с autoclose),
клик F2F input по кнопке «Горы и арки» (координаты кнопок страница пишет в лог), F6 -> caves, закрытие мира ->
снова страница -> клик «Парящие острова». Кадры — F2F shot в shots\ прогона, итог — JSON в stdout.

  LAB_OWNER=gpu_show LAB_ROLE=agent python3 tools/scenarios/gpu_worldgen_menu_test.py [1408x902]
"""
import json, re, subprocess, sys, time, os
LAB = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools", "lab", "lab")
def lab(*a, timeout=400):
    r = subprocess.run([LAB, *a], capture_output=True, text=True, timeout=timeout)
    out = r.stdout.strip()
    try: return json.loads(out[out.index("{"):])
    except Exception: return {"raw": out, "err": r.stderr}
def logs(lease, n=600):
    r = subprocess.run([LAB, "logs", lease, "--tail", str(n), "--grep", r"gpu_worldgen|\[E\]"], capture_output=True, text=True, timeout=60)
    return r.stdout.splitlines()
def wait(lease, pat, t=120, after=0):
    t0 = time.time()
    while time.time() - t0 < t:
        ls = logs(lease)
        hits = [l for l in ls if re.search(pat, l)]
        if len(hits) > after: return hits[after]
        time.sleep(1)
    raise SystemExit("timeout waiting " + pat)
size = sys.argv[1] if len(sys.argv) > 1 else "1408x902"
res = lab("lease", "wasmrt", "engine_rt", "--param", "engine=v032", "--param", 'packs=["gpu_compute","gpu_worldgen"]', "--param", "script=gpu_worldgen_play.lua",
          "--param", r"ready_marker=\[gpu_worldgen\] page open", "--param", "manifest=autoclose=25;rounds=2", "--param", "ready_timeout=120",
          "--param", "size=" + size, "--ttl", "900", "--start")
lease = (res.get("lease") or {}).get("name") or res.get("name")
print("lease", lease, flush=True)
out = {"lease": lease, "shots": {}}
W = int(size.split("x")[0])
def click(btn, k):
    line = wait(lease, r"page open: viewport", after=k)
    m = re.search(r"viewport (\d+),(\d+) ", line); sc = W / int(m.group(1))
    m = re.search(btn + r"=(\d+),(\d+),(\d+),(\d+)", line)
    x, y, w, h = map(int, m.groups())
    cx, cy = int((x + w / 2) * sc), int((y + h / 2) * sc)
    print("click", btn, cx, cy, "scale", sc, flush=True)
    lab("f2f", lease, "input", json.dumps({"mouse": {"x": cx, "y": cy, "buttons": [False, False, False]}}))
    time.sleep(0.3)
    lab("f2f", lease, "input", json.dumps({"mouse": {"x": cx, "y": cy, "buttons": [True, False, False]}}))
    time.sleep(0.3)
    lab("f2f", lease, "input", json.dumps({"mouse": {"x": cx, "y": cy, "buttons": [False, False, False]}}))
def shot(name):
    r = lab("f2f", lease, "shot", json.dumps({"name": "menu_" + name}))
    out["shots"][name] = (r.get("result") or r).get("path")
    print("shot", name, out["shots"][name], flush=True)
try:
    time.sleep(1.5); shot("page")
    click("btn_mountains", 0)
    print(wait(lease, r"spawn mountains"), flush=True)
    time.sleep(3); shot("mountains_spawn")
    lab("f2f", lease, "input", json.dumps({"keys": {"F6": True}})); time.sleep(0.3)
    lab("f2f", lease, "input", json.dumps({"keys": {"F6": False}}))
    print(wait(lease, r"preset -> caves", t=30), flush=True)
    print(wait(lease, r"spawn caves", t=60), flush=True)
    time.sleep(3); shot("f6_caves")
    print(wait(lease, r"back to page", t=120), flush=True)
    time.sleep(2); shot("page_again")
    click("btn_islands", 1)
    print(wait(lease, r"spawn islands"), flush=True)
    time.sleep(3); shot("islands_spawn")
    print(wait(lease, r"round 2", t=120), flush=True)
finally:
    ls = logs(lease, 3000)
    out["lines"] = [l for l in ls if "stats gpu" not in l]
    rel = lab("release", lease)
    out["run_dir"] = rel.get("run_dir")
    out["ok"] = all(out["shots"].get(k) for k in ("page", "mountains_spawn", "f6_caves", "page_again", "islands_spawn"))
    print(json.dumps(out, ensure_ascii=False, indent=1))
