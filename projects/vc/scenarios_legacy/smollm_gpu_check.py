#!/usr/bin/env python3
"""Проверка чата smollm_gpu (Ru-Small-Instruct на GPU) в лаборатории: аренда `wasmrt engine_rt` (тестовая сборка F2F,
часы realtime, 854x480, ввод ОС изолирован) со стартовым сценарием tools/scenarios/smollm_gpu_chat.lua; вопрос вводится
F2F `input` (клик в поле, chars, Enter), ответ ждём по latest.log ("[smollm_gpu] reply done").

Проверяется:
  * BPE на Lua в движке: фразы tok_check.py (26) -> export:smollm_gpu_toktest_out.txt == C-кодер run_native --tok-test
    (Spider real-world-smollm, 0 расхождений с HF tokenizers), decode == вход;
  * паритет при "0 0.85 1 120" (argmax, без штрафа — по умолчанию): токены ответа == эталон нативного C
    (tools/scenarios/smollm_reference.json), токены промпта == data/proto/ref_prompts.json, логиты первого токена ответа
    (чтение LG get_data -> export:smollm_gpu/last_logits.f32) побайтно == reference/logits_<N>.f32;
  * кадр ленты — F2F `shot` в каталог прогона; `lab sysload` и чужие аренды до/после -> пометка contended.

  LAB_OWNER=<имя> python3 tools/scenarios/smollm_gpu_check.py v031|v032 [--prompt N|"текст"] [--params "t top_p rep max"]
                                                              [--remember] [--keep] [--lease NAME] [--timeout 300]
                                                              [--tok-extra FILE] [--ui]
--tok-extra — ещё фразы для BPE (по строке, \\n/\\t экранированы); --ui — после паритета кнопки страницы через F2F:
«Стоп» во время ответа, «Демо» (три эталонных промпта, «Назад» -> чат), вопрос после демо (паритет, контекст сброшен),
«Очистить», «Назад» -> главное меню; кадры каждого шага.
Код выхода — число провалов."""
import json, os, re, subprocess, sys, time

VC = "/mnt/d/Prog/VoxelCore/voxelcore-0.31.0_pre_gemini"
LAB = os.path.join(VC, "tools/lab/lab")
SPIDER_REF = "/root/Spider/tests/manual/real-world-smollm"
OWNER = os.environ.get("LAB_OWNER", "smollm_gpu_check")
FAILS, ROWS = [], []
FLAGS = ("smollm_gpu_params.txt", "smollm_gpu_remember.txt", "smollm_gpu_prompt.txt", "smollm_gpu_dump_logits.txt",
         "smollm_gpu_toktest.txt", "smollm_gpu_toktest_out.txt", "smollm_gpu/last_logits.f32")


def lab(*args, timeout=300):
    env = dict(os.environ, LAB_OWNER=OWNER)
    out = subprocess.run([LAB, *args], capture_output=True, text=True, env=env, timeout=timeout).stdout
    i = out.find("{")
    if i < 0:
        return {"raw": out}
    try:
        return json.loads(out[i:])
    except json.JSONDecodeError:
        return {"raw": out}


def f2f(lease, cmd, args=None):
    r = lab("f2f", lease, cmd, json.dumps(args or {}, ensure_ascii=False))
    if not r.get("ok", False):
        raise RuntimeError("f2f %s %s -> %s" % (cmd, args, r))
    return r.get("result", r)


def mouse_click(lease, x, y, pause=0.12):
    for down in (False, True, False):
        f2f(lease, "input", {"mouse": {"x": x, "y": y, "buttons": [down, False, False]}})
        time.sleep(pause)


def win2wsl(p):
    return p.replace("D:\\", "/mnt/d/").replace("\\", "/")


def log_lines(inst, pattern):
    try:
        data = open(os.path.join(inst, "latest.log"), "rb").read().decode("utf-8", "replace")
    except OSError:
        return []
    return [l for l in data.splitlines() if re.search(pattern, l)]


def after(line, marker):
    return line.split(marker, 1)[1].rstrip("\r")


def wait_log(inst, pattern, timeout, count=1, period=0.5):
    t0 = time.time()
    while time.time() - t0 < timeout:
        lines = log_lines(inst, pattern)
        if len(lines) >= count:
            return lines, time.time() - t0
        if log_lines(inst, r"\[smollm_gpu\] error"):
            raise RuntimeError("engine: %s" % log_lines(inst, r"\[smollm_gpu\] error")[-1])
        time.sleep(period)
    raise RuntimeError("timeout %ss waiting for /%s/ (have %d)" % (timeout, pattern, len(log_lines(inst, pattern))))


def load_snapshot():
    """lab sysload + чужие аренды: (busy, reasons, foreign leases)."""
    s = lab("sysload", timeout=90)
    ps = lab("ps", timeout=60)
    foreign = ["%s(%s)" % (l.get("name"), l.get("owner")) for l in ps.get("leases", []) if l.get("owner") != OWNER]
    return {"busy": s.get("busy"), "reasons": s.get("reasons", []),
            "gpu": (s.get("sample") or {}).get("gpu"), "cpu_others": (s.get("sample") or {}).get("cpu_others_pct"),
            "foreign_leases": foreign}


def step(name, fn):
    t0 = time.time()
    try:
        info = fn() or ""
        ROWS.append((name, "ok", round(time.time() - t0, 1), info))
        print("ok   %-26s %6.1fs  %s" % (name, time.time() - t0, info), flush=True)
    except Exception as e:
        FAILS.append(name)
        ROWS.append((name, "FAIL", round(time.time() - t0, 1), str(e)))
        print("FAIL %-26s %6.1fs  %s" % (name, time.time() - t0, e), flush=True)


def tok_phrases():
    import ast
    tree = ast.parse(open(os.path.join(SPIDER_REF, "tok_check.py"), encoding="utf-8").read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "PHRASES":
            return ast.literal_eval(node.value)
    return []


def start_lease(engine, flags, lease=None, ttl=1800):
    """Аренда + флаги export: (dict имя -> текст) + старт. Возвращает (lease, inst, run_dir)."""
    params = ["--param", "script=smollm_gpu_chat.lua", "--param", 'packs=["gpu_compute","smollm_gpu"]',
              "--param", r"ready_marker=\[smollm_gpu_chat\] ready", "--param", "ready_timeout=120"]
    if engine == "v032":
        params += ["--param", "engine=v032"]
    restart = []
    if lease:
        inst = os.path.join(VC, "artifacts/lab/inst", lease)
        restart = ["--restart"]
    else:
        r = lab("lease", "wasmrt", "engine_rt", "--ttl", str(ttl), *params)
        if not r.get("ok"):
            raise RuntimeError(r)
        lease = r["lease"]["name"]
        inst = win2wsl(r["lease"]["dir"])
    os.makedirs(os.path.join(inst, "export/smollm_gpu"), exist_ok=True)
    for stale in FLAGS:   # каталог экземпляра переживает аренды: флаги прошлых прогонов убрать
        fp = os.path.join(inst, "export", stale)
        if os.path.isfile(fp):
            os.remove(fp)
    for name, text in flags.items():
        with open(os.path.join(inst, "export", name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    r = lab("start", lease, *restart, timeout=240)
    if not r.get("ok"):
        lab("release", lease)
        raise RuntimeError("start: %s" % json.dumps(r, ensure_ascii=False)[:1500])
    return lease, inst, r.get("run_dir"), r.get("run")


def ask(lease, inst, q, timeout):
    """Ввести вопрос F2F input, дождаться ответа; вернуть dict чисел из лога."""
    n_done = len(log_lines(inst, r"\[smollm_gpu\] reply done"))
    n_prompt = len(log_lines(inst, r"\[smollm_gpu\] prompt: "))
    mouse_click(lease, 300, 454)        # поле ввода: pos (8, H-44), size (W-134, 36) при 854x480
    f2f(lease, "input", {"chars": q})
    time.sleep(0.3)
    f2f(lease, "input", {"keys": {"RETURN": True}})
    time.sleep(0.15)
    f2f(lease, "input", {"keys": {"RETURN": False}})
    wait_log(inst, r"\[smollm_gpu\] prompt: ", 20, count=n_prompt + 1)
    got = after(log_lines(inst, r"\[smollm_gpu\] prompt: ")[-1], "[smollm_gpu] prompt: ")
    if got != q:
        raise RuntimeError("prompt in log %r != typed %r" % (got, q))
    wait_log(inst, r"\[smollm_gpu\] reply done", timeout, count=n_done + 1)
    done = after(log_lines(inst, r"\[smollm_gpu\] reply done")[-1], "reply done: ")
    m = re.search(r"(\d+) tokens, (\d+) ms, ([\d.]+) tok/s, prefill (\d+) tokens ([\d.]+) ms/token, ctx (\d+), mode (.*?)(, stopped)?, lua heap ([\d.]+) MB", done)
    res = {"gen_tokens": int(m.group(1)), "gen_ms": int(m.group(2)), "tok_s": float(m.group(3)),
           "prefill_tokens": int(m.group(4)), "prefill_ms_per_token": float(m.group(5)), "ctx": int(m.group(6)),
           "mode": m.group(7), "stopped": bool(m.group(8)), "lua_heap_mb": float(m.group(9))}
    res["tokens"] = [int(x) for x in after(log_lines(inst, r"\[smollm_gpu\] reply tokens: ")[-1], "reply tokens: ").split()]
    res["prompt_tokens"] = [int(x) for x in after(log_lines(inst, r"\[smollm_gpu\] prompt tokens ")[-1], "): ").split()]
    res["text"] = after(log_lines(inst, r"\[smollm_gpu\] reply: ")[-1], "[smollm_gpu] reply: ")
    res["resets"] = len(log_lines(inst, r"\[smollm_gpu\] context reset"))
    tm = log_lines(inst, r"\[smollm_gpu\] reply timing: ")
    m2 = re.search(r"decode (\d+) frames in ([\d.]+) ms = ([\d.]+) tok/s, first token ([\d.]+) ms", tm[-1]) if tm else None
    if m2:
        res["decode_frames"], res["decode_ms"] = int(m2.group(1)), float(m2.group(2))
        res["decode_tok_s"], res["first_token_ms"] = float(m2.group(3)), float(m2.group(4))
    return res


def click_wait(lease, inst, xy, pattern, timeout=30, count=None):
    n = len(log_lines(inst, pattern)) if count is None else count - 1
    mouse_click(lease, *xy)
    wait_log(inst, pattern, timeout, count=n + 1)


# кнопки тулбара при 854x480 (panel padding 6, interval 6): Назад 6..106, Стоп 368..448, Очистить 454..564, Демо 746..826
BTN = {"back": (56, 22), "stop": (408, 22), "reset": (509, 22), "demo": (786, 22)}


def ui_steps(lease, inst, engine, ref, timeout):
    def do_stop():
        n_done = len(log_lines(inst, r"\[smollm_gpu\] reply done"))
        mouse_click(lease, 300, 454)
        f2f(lease, "input", {"chars": ref["prompts"]["3"]["prompt"]})
        f2f(lease, "input", {"keys": {"RETURN": True}})
        time.sleep(0.15)
        f2f(lease, "input", {"keys": {"RETURN": False}})
        wait_log(inst, r"\[smollm_gpu\] prefill ", 20, count=len(log_lines(inst, r"\[smollm_gpu\] prefill ")) + 1)
        time.sleep(0.2)
        mouse_click(lease, *BTN["stop"])
        wait_log(inst, r"\[smollm_gpu\] reply done", timeout, count=n_done + 1)
        done = log_lines(inst, r"\[smollm_gpu\] reply done")[-1]
        f2f(lease, "shot", {"name": "ui_stop_%s" % engine})
        if "stopped" not in done or not log_lines(inst, r"\[smollm_gpu\] stop requested"):
            raise RuntimeError("not stopped: %s" % done)
        return after(done, "reply done: ")

    step("ui: Стоп", do_stop)

    def do_demo():
        click_wait(lease, inst, BTN["demo"], r"\[smollm_gpu\] demo done", 120)
        demo = [after(l, "[sg] ") for l in log_lines(inst, r"\[sg\] demo prompt ")[-3:]]
        shot = f2f(lease, "shot", {"name": "ui_demo_%s" % engine}).get("path")
        click_wait(lease, inst, BTN["back"], r"\[smollm_gpu\] page open", 20)
        time.sleep(0.3)
        f2f(lease, "shot", {"name": "ui_demo_back_%s" % engine})
        bad = [d for d in demo if not re.search(r": (\d+)/\1 tokens == reference", d)]
        if len(demo) != 3 or bad:
            raise RuntimeError("demo: %s" % demo)
        return "; ".join(demo) + "; shot " + str(shot)

    step("ui: Демо -> Назад", do_demo)

    def do_after_demo():
        r = ask(lease, inst, ref["prompts"]["1"]["prompt"], timeout)
        exp = ref["prompts"]["1"]["gen"]
        if r["tokens"][:len(exp)] != exp or not log_lines(inst, r"context reset \(after demo\)"):
            raise RuntimeError("after demo: tokens %s ctx %d" % (r["tokens"], r["ctx"]))
        return "context reset after demo, prompt 1 tokens %d/%d == reference, ctx %d" % (len(exp), len(exp), r["ctx"])

    step("ui: вопрос после демо", do_after_demo)

    def do_reset():
        click_wait(lease, inst, BTN["reset"], r"\[smollm_gpu\] reset requested", 10)
        wait_log(inst, r"context reset \(command\)", 10, count=1)
        time.sleep(0.3)
        return f2f(lease, "shot", {"name": "ui_reset_%s" % engine}).get("path")

    step("ui: Очистить", do_reset)

    def do_back():
        click_wait(lease, inst, BTN["back"], r"\[smollm_gpu\] chat loop done", 10)
        time.sleep(0.5)
        return f2f(lease, "shot", {"name": "ui_back_menu_%s" % engine}).get("path")

    step("ui: Назад -> меню", do_back)


def main():
    argv = sys.argv[1:]
    engine = argv[0] if argv and not argv[0].startswith("--") else "v031"
    opt = lambda k, d=None: argv[argv.index(k) + 1] if k in argv else d
    keep = "--keep" in argv
    timeout = float(opt("--timeout", 300))
    params = opt("--params", "0 0.85 1 120")
    ref = json.load(open(os.path.join(VC, "tools/scenarios/smollm_reference.json"), encoding="utf-8"))
    rp = json.load(open(os.path.join(VC, "content/smollm_gpu/data/proto/ref_prompts.json"), encoding="utf-8"))
    prompt_arg = opt("--prompt", "1")
    key = prompt_arg if prompt_arg in ref["prompts"] else None
    prompt = ref["prompts"][key]["prompt"] if key else prompt_arg
    parity = key is not None and params.split()[0] in ("0", "0.0") and float(params.split()[2]) <= 1
    phrases = tok_phrases()
    if opt("--tok-extra"):
        phrases += [l.rstrip("\n").replace("\\n", "\n").replace("\\t", "\t")
                    for l in open(opt("--tok-extra"), encoding="utf-8") if l.strip()]
    flags = {"smollm_gpu_params.txt": params, "smollm_gpu_dump_logits.txt": "1",
             "smollm_gpu_toktest.txt": "\n".join(p.replace("\n", "\\n").replace("\t", "\\t") for p in phrases) + "\n"}
    if "--remember" in argv:
        flags["smollm_gpu_remember.txt"] = "1"
    numbers = {"engine": engine, "params": params, "prompt": prompt}
    st = {}

    numbers["load_before"] = load_snapshot()
    print("load before:", json.dumps(numbers["load_before"], ensure_ascii=False), flush=True)

    def do_lease():
        st["lease"], st["inst"], numbers["run_dir"], numbers["run"] = start_lease(engine, flags, opt("--lease"))
        return "%s run %s" % (st["lease"], numbers["run"])

    step("lease+start", do_lease)
    if FAILS:
        sys.exit(1)
    lease, inst = st["lease"], st["inst"]

    def do_ready():
        lines, dt = wait_log(inst, r"\[smollm_gpu\] model ready", 120)
        pl = log_lines(inst, r"\[sg\] pipeline ready in")
        ld = log_lines(inst, r"\[sg\] load: ")
        tk = log_lines(inst, r"\[smollm_gpu\] tokenizer: ")
        numbers["pipeline_s"] = float(re.search(r"in ([\d.]+) s", pl[-1]).group(1)) if pl else None
        numbers["order"] = after(log_lines(inst, r"\[sg\] order: ")[-1], "[sg] order: ") if log_lines(inst, r"\[sg\] order: ") else None
        numbers["tokenizer"] = after(tk[-1], "tokenizer: ") if tk else None
        return "pipeline %.2f s (%s); %s" % (numbers["pipeline_s"] or -1, numbers["order"], numbers["tokenizer"])

    step("model ready", do_ready)

    def do_toktest():
        out = os.path.join(inst, "export/smollm_gpu_toktest_out.txt")
        eng = [l for l in open(out, encoding="utf-8").read().split("\n") if l != ""]
        stdin = "\n".join(p.replace("\n", "\\n").replace("\t", "\\t") for p in phrases) + "\n"
        c = subprocess.run([os.path.join(SPIDER_REF, "generated/run_native"), "-z", os.path.join(SPIDER_REF, "generated/tokenizer.bin"),
                            "--tok-test"], input=stdin.encode(), stdout=subprocess.PIPE, check=True).stdout.decode().split("\n")
        c = [l for l in c if l != ""]
        rts = sum(1 for l in eng if l == "ROUNDTRIP-MISMATCH")
        eng_ids = [l for l in eng if l != "ROUNDTRIP-MISMATCH"]
        c_ids = [l for l in c if l != "ROUNDTRIP-MISMATCH"]
        bad = sum(1 for a, b in zip(eng_ids, c_ids) if a != b) + abs(len(eng_ids) - len(c_ids))
        numbers["toktest"] = {"phrases": len(phrases), "mismatches": bad, "roundtrip_mismatches": rts,
                              "tokens": sum(len(l.split()) for l in c_ids)}
        tl = log_lines(inst, r"\[smollm_gpu\] toktest: ")
        if bad or rts:
            raise RuntimeError(numbers["toktest"])
        return "%d phrases, %d tokens == C, decode == input; %s" % (len(phrases), numbers["toktest"]["tokens"],
                                                                     after(tl[-1], "toktest: ") if tl else "")

    step("BPE in engine == C", do_toktest)

    def do_ask():
        f2f(lease, "shot", {"name": "chat_ready_%s" % engine})
        r = ask(lease, inst, prompt, timeout)
        numbers.update(r)
        return "%d tokens, %.1f tok/s (decode %s tok/s, first %s ms), prefill %d tok %.2f ms/token, ctx %d, %s: %s" % (
            r["gen_tokens"], r["tok_s"], r.get("decode_tok_s"), r.get("first_token_ms"), r["prefill_tokens"],
            r["prefill_ms_per_token"], r["ctx"], r["mode"], r["text"][:70])

    step("ask (F2F input)", do_ask)

    def do_parity():
        if key is None:
            return "no reference for free prompt"
        info = []
        if key in rp and numbers.get("prompt_tokens") != rp[key]["prompt_tokens"]:
            raise RuntimeError("prompt tokens %s != ref %s" % (numbers.get("prompt_tokens"), rp[key]["prompt_tokens"]))
        info.append("prompt tokens %d == ref" % len(numbers.get("prompt_tokens") or []))
        eng = os.path.join(inst, "export/smollm_gpu/last_logits.f32")
        lref = os.path.join(SPIDER_REF, ref["prompts"][key]["logits"])
        if os.path.isfile(eng) and os.path.isfile(lref):
            a, b = open(eng, "rb").read(), open(lref, "rb").read()
            same = sum(1 for j in range(0, len(b), 4) if a[j:j + 4] == b[j:j + 4]) if len(a) == len(b) else 0
            numbers["logits_bit_exact"] = "%d/%d" % (same, len(b) // 4)
            info.append("logits %s bit-exact" % numbers["logits_bit_exact"])
            if same != len(b) // 4:   # логиты первого токена не зависят от семплирования
                raise RuntimeError("logits differ: %s" % numbers["logits_bit_exact"])
        if parity:
            exp = ref["prompts"][key]["gen"]
            got = numbers.get("tokens") or []
            n = len(exp)
            if got[:n] != exp:
                raise RuntimeError("tokens differ: engine %s, reference %s" % (got[:n], exp))
            info.append("tokens %d/%d == reference" % (n, n))
        else:
            info.append("sampling mode: tokens not compared")
        return ", ".join(info)

    step("parity vs native C", do_parity)

    def do_shot():
        r = f2f(lease, "shot", {"name": "chat_reply_%s" % engine})
        numbers["shot"] = r.get("path")
        return r.get("path")

    step("shot", do_shot)
    if "--ui" in argv:
        ui_steps(lease, inst, engine, ref, timeout)
    if not keep:
        lab("release", lease)
    numbers["load_after"] = load_snapshot()
    lb, la = numbers["load_before"], numbers["load_after"]
    numbers["contended"] = bool(lb["busy"] or la["busy"] or lb["foreign_leases"] or la["foreign_leases"])
    print("load after:", json.dumps(la, ensure_ascii=False))
    print("--")
    print("run: %s" % numbers.get("run_dir"))
    print("numbers: %s" % json.dumps({k: v for k, v in numbers.items() if k not in ("tokens", "prompt_tokens", "load_before",
                                                                                      "load_after")}, ensure_ascii=False))
    print("contended: %s" % numbers["contended"])
    print("failed: %d %s" % (len(FAILS), FAILS))
    sys.exit(len(FAILS))


if __name__ == "__main__":
    main()
