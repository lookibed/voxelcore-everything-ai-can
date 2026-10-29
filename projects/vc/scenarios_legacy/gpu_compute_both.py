#!/usr/bin/env python3
"""Оба клиента gpu_compute (gpu_worldgen + smollm_gpu) в одном мире — прогон в лаборатории.

Аренда `wasmrt engine_rt` (F2F, часы realtime, 854x480, ввод ОС изолирован), стартовый сценарий
tools/scenarios/gpu_compute_both.lua (паки base + gpu_compute + gpu_worldgen + smollm_gpu, один общий ui.glslf).
Проверяется:
  * worldgen в мире с LLM: хэш области [-3..3]^2 == b3e5e930 (эталон пака, classic seed 20261011);
  * LLM в мире с worldgen: ответы на промпты 1 и 2 (argmax "0 0.85 1 120") == эталон нативного C
    (tools/scenarios/smollm_reference.json, префикс длины эталона);
  * одновременная работа: ответ 2 идёт, пока генерируется новая область (x = z = 2000) — хэш новой области
    == хэшу прогона без LLM (--far-ref HASH или второй прогон --llm 0), число чанков за время ответа;
  * кадры F2F shot на «view world» и «view far» (кадровый буфер), lab sysload до/после -> contended.

  LAB_OWNER=<имя> python3 tools/scenarios/gpu_compute_both.py v031|v032 [--llm 0] [--far-ref HASH] [--timeout 400]
Код выхода — число провалов. Итог — JSON в stdout.
"""
import argparse, json, os, re, subprocess, sys, time

VC = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAB = os.path.join(VC, "tools", "lab", "lab")
CLASSIC = "b3e5e930"


def lab(*args, timeout=600):
    r = subprocess.run([LAB, *args], capture_output=True, text=True, timeout=timeout)
    out = r.stdout.strip()
    try:
        return json.loads(out[out.index("{"):]) if "{" in out else {"raw": out, "err": r.stderr}
    except ValueError:
        return {"raw": out, "err": r.stderr}


def win2wsl(p):
    return re.sub(r"^([A-Za-z]):", lambda m: "/mnt/" + m.group(1).lower(), p).replace("\\", "/")


def host_load():
    s = lab("sysload", timeout=120)
    ps = lab("ps", timeout=60)
    others = [(l.get("name"), l.get("owner")) for l in ps.get("leases", []) if l.get("owner") != os.environ.get("LAB_OWNER")]
    return {"busy": s.get("busy"), "reasons": s.get("reasons"), "gpu": (s.get("sample") or {}).get("gpu"), "other_leases": others}


def log_lines(inst):
    try:
        data = open(os.path.join(inst, "latest.log"), "rb").read().decode("utf-8", "replace")
    except OSError:
        return []
    return [l.split("] ", 2)[-1] if "lua-debug" in l else l for l in data.splitlines()
            if re.search(r"\[gpu_both\]|\[gpu_worldgen\]|\[smollm_gpu\]|\[sg\]|ERROR|\[E\]", l)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engine", choices=["v031", "v032"])
    ap.add_argument("--llm", type=int, default=1)
    ap.add_argument("--far-ref", default=None)
    ap.add_argument("--timeout", type=float, default=400)
    a = ap.parse_args()
    ref = json.load(open(os.path.join(VC, "tools/scenarios/smollm_reference.json"), encoding="utf-8"))["prompts"]
    prompts = [ref["1"], ref["2"]]
    params = ["--param", "script=gpu_compute_both.lua",
              "--param", 'packs=["gpu_compute","gpu_worldgen","smollm_gpu"]',
              "--param", r"ready_marker=\[gpu_both\] ready", "--param", "ready_timeout=180",
              "--param", "manifest=llm=%d;far=1" % a.llm]
    if a.engine == "v032":
        params += ["--param", "engine=v032"]
    before = host_load()
    r = lab("lease", "wasmrt", "engine_rt", "--ttl", str(int(a.timeout) + 300), *params, timeout=400)
    if not r.get("ok"):
        print(json.dumps({"error": "lease failed", "res": r}, ensure_ascii=False, indent=1))
        return 9
    lease = r["lease"]["name"]
    inst = win2wsl(r["lease"]["dir"])
    os.makedirs(os.path.join(inst, "export"), exist_ok=True)
    for stale in ("smollm_gpu_params.txt", "smollm_gpu_prompt.txt", "smollm_gpu_toktest.txt", "smollm_gpu_dump_logits.txt",
                  "smollm_gpu_remember.txt"):
        fp = os.path.join(inst, "export", stale)
        if os.path.isfile(fp):
            os.remove(fp)
    with open(os.path.join(inst, "export", "gpu_both_prompts.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(p["prompt"] for p in prompts) + "\n")
    out = {"lease": lease, "engine": a.engine, "llm": a.llm, "shots": {}, "fails": []}
    shot, done = set(), False
    try:
        s = lab("start", lease, timeout=300)
        if not s.get("ok"):
            raise RuntimeError("start: %s" % json.dumps(s, ensure_ascii=False)[:1500])
        out["run_dir"] = s.get("run_dir")
        t0 = time.time()
        while time.time() - t0 < a.timeout:
            ls = log_lines(inst)
            for ln in ls:
                m = re.search(r"\[gpu_both\] view (\w+)", ln)
                if m and m.group(1) not in shot:
                    sr = lab("f2f", lease, "shot", json.dumps({"name": "both_%s_%s" % (m.group(1), a.engine)}))
                    out["shots"][m.group(1)] = sr.get("result") or sr
                    shot.add(m.group(1))
            if any("[gpu_both] done" in ln for ln in ls):
                done = True
                break
            time.sleep(1.0)
        ls = log_lines(inst)
    finally:
        rel = lab("release", lease)
        out["run_dir"] = rel.get("run_dir") or out.get("run_dir")
    after = host_load()
    out["done"] = done
    out["lines"] = [l for l in ls if "[gpu_both]" in l or "reply done" in l or "reply tokens" in l or "reply timing" in l
                    or "generation" in l or "pipeline" in l or "order" in l or "ERROR" in l or "[E]" in l or "error" in l]
    txt = "\n".join(ls)
    m = re.search(r"phase1 area hash \[-3\.\.3\]\^2 = (\w+)", txt)
    out["area_hash"] = m and m.group(1)
    if out["area_hash"] != CLASSIC:
        out["fails"].append("area hash %s != %s" % (out["area_hash"], CLASSIC))
    m = re.search(r"phase3 area hash (\S+) = (\w+)", txt)
    out["far_hash"] = m and m.group(2)
    if a.far_ref and out["far_hash"] != a.far_ref:
        out["fails"].append("far hash %s != %s" % (out["far_hash"], a.far_ref))
    for k in ("phase1 worldgen", "phase3 worldgen far", "phase3: chunks generated during reply 2", "phase2: llm pipeline"):
        mm = [l for l in ls if k in l]
        out[k] = mm[-1].split("] ", 1)[-1] if mm else None
    if a.llm:
        toks = [[int(x) for x in l.split("reply tokens: ", 1)[1].split()] for l in ls if "[smollm_gpu] reply tokens: " in l]
        dones = [l.split("reply done: ", 1)[1] for l in ls if "[smollm_gpu] reply done: " in l]
        out["replies"] = []
        for i, p in enumerate(prompts):
            got = toks[i] if i < len(toks) else None
            exp = p["gen"]
            ok = got is not None and got[:len(exp)] == exp
            out["replies"].append({"prompt": p["prompt"], "tokens_match": ok, "n_ref": len(exp),
                                   "done": dones[i] if i < len(dones) else None})
            if not ok:
                out["fails"].append("reply %d tokens %s != reference %s" % (i + 1, got and got[:len(exp)], exp))
    if not done:
        out["fails"].append("no done marker")
    # известные строки движка, не связанные с паками: нет микрофона у аренды; 0.31 пишет «framebuffer is not complete!»
    # при старте и при открытии мира в любом прогоне (и без gpu_compute) — их только показываем
    benign = ("could not open input device", "framebuffer is not complete")
    out["engine_errors"] = [l for l in ls if "[E]" in l and any(b in l for b in benign)]
    bad = [l for l in ls if ("error:" in l or "[E]" in l or "ERROR" in l) and not any(b in l for b in benign)]
    if bad:
        out["fails"].append("errors in log: %s" % bad[:3])
    out["host_load"] = {"before": before, "after": after}
    out["contended"] = bool(before.get("busy") or after.get("busy") or before.get("other_leases") or after.get("other_leases"))
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return len(out["fails"])


if __name__ == "__main__":
    sys.exit(main())
