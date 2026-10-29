#!/usr/bin/env python3
"""Диалог с чатом smollm_gpu в аренде лаборатории: несколько вопросов подряд в одной сессии (F2F input в textbox),
как smollm_dialog.py у CPU-пака. Умолчания — карточка модели (0.25 0.85 1.15 120), без истории.
  LAB_OWNER=<имя> python3 tools/scenarios/smollm_gpu_dialog.py v031|v032 [--remember] [--params "t top_p rep max_new"]
                                                               [--midshot] [--dump-logits OUT.f32] -- "вопрос 1" ...
--midshot — кадр F2F `shot` через ~0.5 с после Enter на каждом вопросе (печать по токенам, статус «генерация»).
--dump-logits — логиты первого токена ПОСЛЕДНЕГО ответа (export:smollm_gpu/last_logits.f32) скопировать в OUT
(сверка продолжения диалога с нативным C на том же контексте: run_native -i "<весь текст контекста>" --logits).
Печатает вопрос/ответ, ток/с, контекст, сбросы; кадр ленты в конце; `lab sysload` и чужие аренды до/после (contended).
Аренда освобождается."""
import importlib.util, json, os, sys, time

VC = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("smollm_gpu_check", os.path.join(VC, "tools/scenarios/smollm_gpu_check.py"))
chk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chk)


def main():
    argv = sys.argv[1:]
    engine = argv[0] if argv and not argv[0].startswith("--") else "v031"
    remember = "--remember" in argv
    midshot = "--midshot" in argv
    params = argv[argv.index("--params") + 1] if "--params" in argv else None
    prompts = argv[argv.index("--") + 1:] if "--" in argv else []
    assert prompts, "нет вопросов после --"
    flags = {}
    if remember:
        flags["smollm_gpu_remember.txt"] = "1"
    if params:
        flags["smollm_gpu_params.txt"] = params
    dump = argv[argv.index("--dump-logits") + 1] if "--dump-logits" in argv else None
    if dump:
        flags["smollm_gpu_dump_logits.txt"] = "1"
    before = chk.load_snapshot()
    print("load before:", json.dumps(before, ensure_ascii=False), flush=True)
    lease, inst, run_dir, run = chk.start_lease(engine, flags)
    print("lease %s run %s engine %s remember %s params %s" % (lease, run, engine, remember, params or "pack defaults (0.25 0.85 1.15 120)"),
          flush=True)
    rows = []
    try:
        chk.wait_log(inst, r"\[smollm_gpu\] model ready", 120)
        for i, q in enumerate(prompts):
            if midshot:
                n_done = len(chk.log_lines(inst, r"\[smollm_gpu\] reply done"))
                chk.mouse_click(lease, 300, 454)
                chk.f2f(lease, "input", {"chars": q})
                time.sleep(0.3)
                chk.f2f(lease, "input", {"keys": {"RETURN": True}})
                time.sleep(0.15)
                chk.f2f(lease, "input", {"keys": {"RETURN": False}})
                time.sleep(0.5)
                shot = chk.f2f(lease, "shot", {"name": "dialog_q%d_typing_%s" % (i + 1, engine)}).get("path")
                chk.wait_log(inst, r"\[smollm_gpu\] reply done", 300, count=n_done + 1)
                r = parse_last(inst)
                r["midshot"] = shot
            else:
                r = chk.ask(lease, inst, q, 300)
            rows.append(r)
            print("Q: %s\nA: %s\n   (%d tokens, %.1f tok/s, decode %s tok/s, prefill %d tok %.2f ms/token, ctx %d, resets so far %d, %s%s)"
                  % (q, r["text"], r["gen_tokens"], r["tok_s"], r.get("decode_tok_s"), r["prefill_tokens"],
                     r["prefill_ms_per_token"], r["ctx"], r["resets"], r["mode"], (", mid shot " + r["midshot"]) if r.get("midshot") else ""),
                  flush=True)
        shot = chk.f2f(lease, "shot", {"name": "dialog_%s%s" % (engine, "_remember" if remember else "")}).get("path")
        print("shot:", shot)
        for i, r in enumerate(rows):
            print("turn %d prompt tokens: %s" % (i + 1, " ".join(map(str, r.get("prompt_tokens", [])))))
            print("turn %d reply tokens: %s" % (i + 1, " ".join(map(str, r.get("tokens", [])))))
        if dump:
            import shutil
            shutil.copy(os.path.join(inst, "export/smollm_gpu/last_logits.f32"), dump)
            print("logits of last reply's first token ->", dump)
    finally:
        chk.lab("release", lease)
    after = chk.load_snapshot()
    print("load after:", json.dumps(after, ensure_ascii=False))
    contended = bool(before["busy"] or after["busy"] or before["foreign_leases"] or after["foreign_leases"])
    print("run:", run_dir)
    print("contended:", contended)


def parse_last(inst):
    """числа последнего ответа из лога (как chk.ask, без ввода)"""
    import re
    ll = chk.log_lines
    done = chk.after(ll(inst, r"\[smollm_gpu\] reply done")[-1], "reply done: ")
    m = re.search(r"(\d+) tokens, (\d+) ms, ([\d.]+) tok/s, prefill (\d+) tokens ([\d.]+) ms/token, ctx (\d+), mode (.*?)(, stopped)?, lua heap", done)
    r = {"gen_tokens": int(m.group(1)), "tok_s": float(m.group(3)), "prefill_tokens": int(m.group(4)),
         "prefill_ms_per_token": float(m.group(5)), "ctx": int(m.group(6)), "mode": m.group(7),
         "text": chk.after(ll(inst, r"\[smollm_gpu\] reply: ")[-1], "[smollm_gpu] reply: "),
         "resets": len(ll(inst, r"\[smollm_gpu\] context reset"))}
    tm = ll(inst, r"\[smollm_gpu\] reply timing: ")
    m2 = re.search(r"= ([\d.]+) tok/s", tm[-1]) if tm else None
    r["decode_tok_s"] = float(m2.group(1)) if m2 else None
    r["tokens"] = [int(x) for x in chk.after(ll(inst, r"\[smollm_gpu\] reply tokens: ")[-1], "reply tokens: ").split()]
    r["prompt_tokens"] = [int(x) for x in chk.after(ll(inst, r"\[smollm_gpu\] prompt tokens ")[-1], "): ").split()]
    return r


if __name__ == "__main__":
    main()
