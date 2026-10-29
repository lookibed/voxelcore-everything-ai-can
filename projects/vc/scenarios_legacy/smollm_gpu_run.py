#!/usr/bin/env python3
"""Прогон проб пака smollm_gpu в лаборатории (аренда `wasmrt engine_rt`: тестовая сборка F2F, часы realtime, ввод
изолирован) и вывод строк "[sg] ..." из latest.log. Разведка «LLM на GPU» — agents/research/SMOLLM_GPU.md.

  LAB_OWNER=llm_gpu python3 tools/scenarios/smollm_gpu_run.py v031|v032 [--probe q12|matvec|layer|all] [--size 854x480]
                                                             [--lease NAME] [--keep] [--timeout 300] [--shot NAME]
                                                             [--variant v1|v2] [--noprofile]
--variant (llm): v1 — матвек одним проходом, v2 — IVAL + RED и фреймы SS (по умолчанию); --noprofile — без профиля кадра.

--lease — переиспользовать аренду (сценарий копируется заново, движок перезапускается `lab start --restart`).
Код выхода 0, если в логе есть "[sg] probe done" и нет "[sg] error"/"FAIL".
"""
import json, os, re, shutil, subprocess, sys, time

VC = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # TODO(переезд): был рабочий каталог движка (content, tools, worlds) — теперь корень репозитория
LAB = os.path.join(VC, "tools/lab/lab")
OWNER = os.environ.get("LAB_OWNER", "llm_gpu")


def lab(*args, timeout=300):
    env = dict(os.environ, LAB_OWNER=OWNER)
    out = subprocess.run([LAB, *args], capture_output=True, text=True, env=env, timeout=timeout).stdout
    i = out.find("{")
    try:
        return json.loads(out[i:]) if i >= 0 else {"raw": out}
    except json.JSONDecodeError:
        return {"raw": out}


def win2wsl(p):
    return re.sub(r"^([A-Za-z]):", lambda m: "/mnt/" + m.group(1).lower(), p).replace("\\", "/")


def sg_lines(inst):
    path = os.path.join(inst, "latest.log")
    try:
        data = open(path, "rb").read().decode("utf-8", "replace")
    except OSError:
        return []
    return [l for l in data.splitlines() if "[sg]" in l or "ERROR" in l or "[E]" in l]


def main():
    argv = sys.argv[1:]
    engine = argv[0] if argv and not argv[0].startswith("--") else "v031"
    opt = lambda k, d=None: argv[argv.index(k) + 1] if k in argv else d
    probe = opt("--probe", "q12")
    size = opt("--size")
    timeout = float(opt("--timeout", 300))
    lease = opt("--lease")
    params = ["--param", "script=smollm_gpu_probe.lua", "--param", 'packs=["gpu_compute","smollm_gpu"]',
              "--param", r"ready_marker=\[sg\] ready", "--param", "ready_timeout=60"]
    if engine == "v032":
        params += ["--param", "engine=v032"]
    if size:
        params += ["--param", "size=" + size]
    if not lease:
        r = lab("lease", "wasmrt", "engine_rt", "--ttl", "1800", *params)
        if not r.get("ok"):
            print("lease failed:", r)
            return 2
        lease = r["lease"]["name"]
        inst = win2wsl(r["lease"]["dir"])
        restart = []
    else:
        inst = os.path.join(VC, "artifacts/lab/inst", lease)
        restart = ["--restart"]
    os.makedirs(os.path.join(inst, "export"), exist_ok=True)
    with open(os.path.join(inst, "export/smollm_gpu_probe.txt"), "w") as f:
        f.write(probe)
    with open(os.path.join(inst, "export/smollm_gpu_variant.txt"), "w") as f:
        f.write(opt("--variant", "v2"))
    np_path = os.path.join(inst, "export/smollm_gpu_noprofile.txt")
    if "--noprofile" in argv:
        open(np_path, "w").write("1")
    elif os.path.exists(np_path):
        os.remove(np_path)
    shutil.copy(os.path.join(VC, "tools/scenarios/smollm_gpu_probe.lua"), os.path.join(inst, "smollm_gpu_probe.lua"))
    t0 = time.time()
    r = lab("start", lease, *restart, timeout=240)
    if not r.get("ok"):
        print("start failed:", json.dumps(r)[:2000])
        return 2
    print("lease %s engine %s run %s (start %.1f s)" % (lease, engine, r.get("run"), time.time() - t0), flush=True)
    done = False
    while time.time() - t0 < timeout:
        lines = sg_lines(inst)
        if any("[sg] probe done" in l for l in lines):
            done = True
            break
        time.sleep(2)
    lines = sg_lines(inst)
    for l in lines:
        print(re.sub(r"^\[\w\] \S+ (\S+)\s*\[\s*[\w-]+\]\s*", r"\1 ", l))
    shot = opt("--shot")
    if shot:
        print("shot:", lab("f2f", lease, "shot", json.dumps({"name": shot})))
    print("run_dir:", r.get("run_dir"))
    if "--keep" not in argv:
        lab("release", lease)
        print("released", lease)
    else:
        print("kept", lease)
    bad = any("[sg] error" in l or "FAIL" in l for l in lines)
    return 0 if done and not bad else 1


if __name__ == "__main__":
    sys.exit(main())
