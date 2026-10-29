#!/usr/bin/env python3
"""Проверка пака blackhole в лаборатории: аренда F2F-движка 0.32 (wasmrt engine_rt, часы realtime, 854x480, ввод ОС
изолирован), сценарий tools/scenarios/blackhole_check.lua (новый мир base + blackhole на base:demo), реакции на маркеры
лога, освобождение аренды.

  LAB_OWNER=blackhole LAB_ROLE=agent python3 tools/scenarios/blackhole_check.py [--opts "perf_s=8;hold=2.5"]
      [--engine v032] [--size 854x480] [--tag bh] [--timeout 600] [--no-audio]

Маркеры сценария (строки «[blackhole] ...»):
  view <имя>   -> F2F shot (кадровый буфер) <tag>_<имя>
  input rmb    -> F2F input: нажать и отпустить ПКМ (бросок гранаты предметом, on_use)
  perf start / perf end <tag> -> lab sysload (busy до/после замера)
  done         -> конец
Итог — JSON в stdout: аренда, каталог прогона, кадры (путь, sha256 RGB от F2F и sha256 файла PNG), все строки
[blackhole], ошибки ([E]/Lua), загрузка ПК до/после замеров, contended. Код 0 — дошли до done без ошибок скриптов.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
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


GREP = r"\[blackhole\]|\[E\]|ERROR|rror|traceback"


def log_lines(lease, tail=600):
    r = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", GREP], capture_output=True, text=True,
                       timeout=60)
    return [ln for ln in r.stdout.splitlines() if ln.strip() and not ln.startswith("#")]


def host_load():
    s = lab("sysload", timeout=120)
    smp = s.get("sample") or {}
    ps = lab("ps", timeout=60)
    others = [(l.get("name"), l.get("owner"), (l.get("params") or {}).get("script"))
              for l in ps.get("leases", []) if l.get("owner") != os.environ.get("LAB_OWNER")]
    return {"busy": s.get("busy"), "reasons": s.get("reasons"), "cpu_total_pct": smp.get("cpu_total_pct"),
            "cpu_others_pct": smp.get("cpu_others_pct"), "gpu": smp.get("gpu"), "user_idle_s": smp.get("user_idle_s"),
            "other_leases": others}


def win_to_wsl(p):
    if not p:
        return p
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", p)
    if m:
        return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/"))
    return p


def is_script_error(ln):
    if "[blackhole]" in ln and "error" not in ln.lower():
        return False
    if "al-audio" in ln:          # ошибки OpenAL — не скрипт, но в отчёт (audio_errors)
        return False
    return ("[E]" in ln or "ERROR" in ln or "rror" in ln) and bool(
        re.search(r"lua|script|blackhole|uncaught|attempt|traceback|nil value", ln, re.I))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="v032")
    ap.add_argument("--opts", default="perf_s=8;hold=2.5")
    ap.add_argument("--size", default=None)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--tag", default="bh")
    ap.add_argument("--script", default="blackhole_check.lua")
    ap.add_argument("--no-audio", action="store_true")
    a = ap.parse_args()

    params = ["--param", "engine=" + a.engine, "--param", 'packs=["blackhole"]', "--param", "script=" + a.script,
              "--param", r"ready_marker=\[blackhole\] ready", "--param", "manifest=" + a.opts,
              "--param", "ready_timeout=240"]
    if not a.no_audio:
        params += ["--param", 'audio="true"']
    if a.size:
        params += ["--param", "size=" + a.size]
    before = host_load()
    res = lab("lease", "wasmrt", "engine_rt", *params, "--ttl", str(int(a.timeout) + 300), "--start", timeout=400)
    lease = res.get("lease")
    if isinstance(lease, dict):
        lease = lease.get("name")
    lease = lease or res.get("name")
    if lease and res.get("ok") is False:
        rel = lab("release", lease)
        print(json.dumps({"error": "lease start failed", "res": res, "run_dir": rel.get("run_dir")}, ensure_ascii=False,
                         indent=1))
        return 2
    if not lease:
        print(json.dumps({"error": "lease failed", "res": res, "host_load_before": before}, ensure_ascii=False, indent=1))
        return 2
    out = {"lease": lease, "engine": a.engine, "opts": a.opts, "tag": a.tag, "shots": {}, "perf_load": {},
           "inputs": [], "host_load_before": before}
    seen = set()
    threads = []
    finished = False
    errors = []
    t0 = time.time()
    try:
        while time.time() - t0 < a.timeout:
            lines = log_lines(lease)
            for ln in lines:
                if ln in seen:
                    continue
                seen.add(ln)
                if is_script_error(ln):
                    errors.append(ln)
                m = re.search(r"\[blackhole\] view (\w+): cam", ln)
                if m:
                    name = m.group(1)
                    time.sleep(0.3)  # кадр с новой позицией камеры
                    tshot = time.time()
                    r = lab("f2f", lease, "shot", json.dumps({"name": "%s_%s_%s" % (a.tag, a.engine, name)}))
                    out["shots"][name] = (r.get("result") or r)
                    out["shots"][name]["shot_s"] = round(time.time() - tshot, 2)
                    # квитанция сценарию: кадр снят, можно двигать камеру дальше
                    ack = os.path.join(VC_ROOT, "artifacts", "lab", "inst", lease, "export", "bh_ack_" + name)
                    try:
                        os.makedirs(os.path.dirname(ack), exist_ok=True)
                        open(ack, "w").write("1")
                    except OSError as ex:
                        out.setdefault("ack_errors", []).append(str(ex))
                if "[blackhole] input rmb" in ln:
                    r1 = lab("f2f", lease, "input", json.dumps({"mouse": {"buttons": [False, True, False]}}))
                    time.sleep(0.25)
                    r2 = lab("f2f", lease, "input", json.dumps({"mouse": {"buttons": [False, False, False]}}))
                    out["inputs"].append({"press": r1.get("result", r1), "release": r2.get("result", r2)})
                m = re.search(r"\[blackhole\] perf (start|end) (\w+)", ln)
                if m:
                    # в отдельном потоке: sysload занимает секунды и не должен задерживать кадры следующих маркеров
                    key = "%s_%s" % (m.group(2), m.group(1))
                    th = threading.Thread(target=lambda k=key: out["perf_load"].__setitem__(k, host_load()))
                    th.start()
                    threads.append(th)
                if "[blackhole] done" in ln:
                    finished = True
            if finished:
                break
            if errors and len(errors) > 20:
                break
            time.sleep(0.3)
        for th in threads:
            th.join(timeout=60)
        lines = log_lines(lease, tail=4000)
        out["lines"] = [ln.split("] ", 2)[-1] if "lua-debug" in ln else ln for ln in lines if "[blackhole]" in ln]
        out["errors"] = [ln for ln in lines if is_script_error(ln)]
        out["e_lines"] = [ln for ln in lines if "[E]" in ln][:40]
        out["finished"] = finished
    finally:
        rel = lab("release", lease)
        out["run_dir"] = rel.get("run_dir") or rel.get("run") or rel.get("logs")
        out["release"] = {k: rel.get(k) for k in ("ok", "state", "run_dir") if k in rel}
    after = host_load()
    out["host_load_after"] = after
    perf_busy = any(v.get("busy") or v.get("other_leases") for v in out["perf_load"].values())
    out["contended"] = bool(before.get("busy") or after.get("busy") or before.get("other_leases")
                            or after.get("other_leases") or perf_busy)
    # sha256 файлов PNG (F2F даёт sha256 RGB-байт кадра)
    for name, r in out["shots"].items():
        p = win_to_wsl(r.get("path")) if isinstance(r, dict) else None
        if p and not os.path.exists(p) and out.get("run_dir"):
            cand = os.path.join(win_to_wsl(out["run_dir"]), "shots", os.path.basename(p))
            p = cand if os.path.exists(cand) else p
        if p and os.path.exists(p):
            r["png_path"] = p
            r["png_sha256"] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    # сверка кадра с данными шейдера: в центре каждой дыры из строки «view <имя> ... shader N: (x y rR kK fF)» должен
    # быть горизонт (почти чёрный пиксель), на расстоянии ~1.45 r — яркое фотонное кольцо
    try:
        from PIL import Image
        for ln in out.get("lines", []):
            m = re.search(r"view (\w+): .*shader (\d+): (.*)$", ln)
            if not m or m.group(1) not in out["shots"] or not out["shots"][m.group(1)].get("png_path"):
                continue
            im = Image.open(out["shots"][m.group(1)]["png_path"]).convert("RGB")
            W, H = im.size
            res = []
            for x, y, r, k, f in re.findall(r"\(([-\d.]+) ([-\d.]+) r([-\d.]+) k([-\d.]+) f([-\d.]+)\)", m.group(3)):
                x, y, r, k, f = map(float, (x, y, r, k, f))
                px, py = int(x * W), int((1 - y) * H)
                if not (0 <= px < W and 0 <= py < H) or f > 0:
                    continue
                c = im.getpixel((px, py))
                ring = max(sum(im.getpixel((min(W - 1, max(0, int(px + dx * 1.45 * r * H))),
                                            min(H - 1, max(0, int(py + dy * 1.45 * r * H)))))) / 3
                           for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                res.append({"px": [px, py], "center_rgb": c, "dark": sum(c) < 40, "ring_max_luma": round(ring, 1)})
            out["shots"][m.group(1)]["shader_check"] = res
    except Exception as ex:  # noqa
        out["shader_check_error"] = str(ex)
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0 if finished and not out["errors"] else 1


if __name__ == "__main__":
    sys.exit(main())
