#!/usr/bin/env python3
"""Диалог с паком smollm в аренде лаборатории: несколько промптов подряд в одной сессии (F2F input в textbox).
  python3 tools/scenarios/smollm_dialog.py v031|v032 [--remember] [--params "0.25 0.85 1.15 120"] -- "вопрос 1" "вопрос 2" ...
Печатает ответ на каждый вопрос, статистику и пишет кадр ленты. Пути прогона — artifacts\lab\runs\...; аренда освобождается."""
import importlib.util, os, sys, time, re
VC = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("smollm_check", os.path.join(VC, "tools/scenarios/smollm_check.py"))
chk = importlib.util.module_from_spec(spec); spec.loader.exec_module(chk)
lab, f2f, mouse_click, log_lines = chk.lab, chk.f2f, chk.mouse_click, chk.log_lines

def main():
    argv = sys.argv[1:]
    engine = argv[0] if argv and not argv[0].startswith("--") else "v031"
    remember = "--remember" in argv
    params = None
    if "--params" in argv: params = argv[argv.index("--params") + 1]
    prompts = argv[argv.index("--") + 1:] if "--" in argv else []
    assert prompts, "нет промптов после --"
    p = ["--param", "script=smollm_chat.lua", "--param", 'packs=["wasmrt","smollm"]',
         "--param", r"ready_marker=\[smollm_chat\] ready", "--param", "ready_timeout=240"]
    if engine == "v032": p += ["--param", "engine=v032"]
    r = lab("lease", "wasmrt", "engine_rt", "--ttl", "1800", *p)
    assert r.get("ok"), r
    lease = r["lease"]["name"]; inst = re.sub(r"^([A-Za-z]):", lambda m: "/mnt/" + m.group(1).lower(), r["lease"]["dir"]).replace("\\", "/")
    os.makedirs(os.path.join(inst, "export"), exist_ok=True)
    for stale in ("smollm_kprof.txt", "smollm_manifest.txt", "smollm_prompt.txt", "smollm_kernels.txt", "smollm_batch.txt",
                  "smollm_remember.txt", "smollm_params.txt", "smollm_dump_logits.txt"):
        fp = os.path.join(inst, "export", stale)
        if os.path.isfile(fp): os.remove(fp)
    if remember: open(os.path.join(inst, "export/smollm_remember.txt"), "w").write("1")
    if params: open(os.path.join(inst, "export/smollm_params.txt"), "w").write(params)
    r = lab("start", lease); assert r.get("ok"), r
    print("lease", lease, "run", r.get("run"), "remember", remember, "params", params or "pack defaults")
    try:
        chk.wait_log(lease, r"\[smollm_chat\] ready", 240)
        t0 = time.time()
        while time.time() - t0 < 240 and not log_lines(lease, r"smollm: model .* loaded in"): time.sleep(2)
        for q in prompts:
            n_done = len(log_lines(lease, r"\[smollm\] reply done"))
            mouse_click(lease, 300, 454)
            f2f(lease, "input", {"chars": q}); time.sleep(0.3)
            f2f(lease, "input", {"keys": {"RETURN": True}}); time.sleep(0.15)
            f2f(lease, "input", {"keys": {"RETURN": False}})
            t0 = time.time()
            while len(log_lines(lease, r"\[smollm\] reply done")) <= n_done:
                if time.time() - t0 > 240: raise RuntimeError("timeout waiting reply for %r" % q)
                time.sleep(2)
            done = log_lines(lease, r"\[smollm\] reply done")[-1]
            text = log_lines(lease, r"\[smollm\] reply: ")[-1].split("reply: ", 1)[1]
            resets = len(log_lines(lease, r"\[smollm\] context reset"))
            m = re.search(r"reply done: (\d+) tokens, (\d+) ms, ctx (\d+)", done)
            print("Q: %s\nA: %s\n   (%s tokens, %s ms, ctx %s, resets so far %d)" % (q, text, m.group(1), m.group(2), m.group(3), resets))
        f2f(lease, "shot", {"name": "dialog"})
        print("shot:", r.get("run_dir"))
    finally:
        lab("release", lease)
main()
