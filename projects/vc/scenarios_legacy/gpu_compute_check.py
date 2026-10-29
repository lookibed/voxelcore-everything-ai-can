#!/usr/bin/env python3
"""Проверка пака gpu_compute в лаборатории: аренда `wasmrt engine_rt` (F2F, часы realtime, ввод ОС изолирован),
стартовый сценарий tools/scenarios/gpu_compute_check.lua (пример noise, bench, проба порядка, пробы «на лету»),
строки [gpu_compute] из лога, lab sysload до/после (contended), освобождение аренды.

  LAB_OWNER=<имя> python3 tools/scenarios/gpu_compute_check.py v031|v032 [--timeout 300] [--packs gpu_compute,...]
      [--script gpu_compute_check.lua] [--marker done] [--shots name1,name2]

--shots: на строке "[gpu_compute] view <name>" (или "[gpu_both] view <name>") снять F2F shot (кадровый буфер).
Код выхода 0 — дошли до done, нет "error:"/FAIL. Итог — JSON в stdout.
"""
import argparse, json, os, re, subprocess, sys, time

VC = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAB = os.path.join(VC, "tools", "lab", "lab")


def lab(*args, timeout=600):
    r = subprocess.run([LAB, *args], capture_output=True, text=True, timeout=timeout)
    out = r.stdout.strip()
    try:
        return json.loads(out[out.index("{"):]) if "{" in out else {"raw": out, "err": r.stderr}
    except ValueError:
        return {"raw": out, "err": r.stderr}


def host_load():
    s = lab("sysload", timeout=120)
    smp = s.get("sample") or {}
    ps = lab("ps", timeout=60)
    others = [(l.get("name"), l.get("owner")) for l in ps.get("leases", [])
              if l.get("owner") != os.environ.get("LAB_OWNER")]
    return {"busy": s.get("busy"), "reasons": s.get("reasons"), "cpu_total_pct": smp.get("cpu_total_pct"),
            "cpu_others_pct": smp.get("cpu_others_pct"), "gpu": smp.get("gpu"), "other_leases": others}


def lines_of(lease, tag, tail=3000):
    r = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", r"\[%s\]|\[gpu_worldgen\]|\[smollm_gpu|\[sg\]|ERROR|\[E\]" % tag],
                       capture_output=True, text=True, timeout=60)
    return r.stdout.splitlines()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engine", choices=["v031", "v032"])
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--packs", default="gpu_compute")
    ap.add_argument("--script", default="gpu_compute_check.lua")
    ap.add_argument("--tag", default="gpu_compute")
    ap.add_argument("--manifest", default=None)
    a = ap.parse_args()
    packs = json.dumps(a.packs.split(","))
    params = ["--param", "script=" + a.script, "--param", "packs=" + packs,
              "--param", r"ready_marker=\[%s\] ready" % a.tag, "--param", "ready_timeout=180"]
    if a.manifest:
        params += ["--param", "manifest=" + a.manifest]
    if a.engine == "v032":
        params += ["--param", "engine=v032"]
    before = host_load()
    res = lab("lease", "wasmrt", "engine_rt", *params, "--ttl", str(int(a.timeout) + 300), "--start", timeout=400)
    lease = res.get("lease")
    lease = lease.get("name") if isinstance(lease, dict) else (lease or res.get("name"))
    if not lease:
        print(json.dumps({"error": "lease failed", "res": res}, ensure_ascii=False, indent=1))
        return 2
    out = {"lease": lease, "engine": a.engine, "shots": {}}
    done, shot = False, set()
    t0 = time.time()
    try:
        while time.time() - t0 < a.timeout:
            ls = lines_of(lease, a.tag)
            for ln in ls:
                m = re.search(r"\[%s\] view (\w+)" % a.tag, ln)
                if m and m.group(1) not in shot:
                    r = lab("f2f", lease, "shot", json.dumps({"name": "%s_%s" % (m.group(1), a.engine)}))
                    out["shots"][m.group(1)] = r.get("result") or r
                    shot.add(m.group(1))
            if any("[%s] done" % a.tag in ln for ln in ls):
                done = True
                break
            time.sleep(1.0)
        ls = lines_of(lease, a.tag)
        out["lines"] = [ln.split("] ", 2)[-1] if "lua-debug" in ln else ln for ln in ls
                        if "[%s]" % a.tag in ln or "[gpu_worldgen]" in ln or "[sg]" in ln or "[smollm_gpu" in ln
                        or ("ERROR" in ln) or ("[E]" in ln)]
    finally:
        rel = lab("release", lease)
        out["run_dir"] = rel.get("run_dir") or rel.get("run") or rel.get("logs")
    after = host_load()
    out["done"] = done
    out["host_load"] = {"before": before, "after": after}
    out["contended"] = bool(before.get("busy") or after.get("busy") or before.get("other_leases") or after.get("other_leases"))
    bad = [ln for ln in out["lines"] if "error:" in ln or " FAIL" in ln]
    out["ok"] = done and not bad
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
