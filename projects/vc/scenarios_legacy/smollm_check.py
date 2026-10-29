#!/usr/bin/env python3
"""Проверка чата smollm в лаборатории: аренда `wasmrt engine_rt` (тестовая сборка F2F, часы realtime, 854x480,
ввод ОС изолирован) со стартовым сценарием tools/scenarios/smollm_chat.lua, промпт вводится F2F `input`
(клик в поле, chars, Enter), ответ ждём по latest.log, первые N токенов сверяются с эталоном нативного runq
(tools/scenarios/smollm_reference.json, Spider tests/manual/real-world-smollm/reference), логиты первого токена —
побайтно с reference/logits_<i>.f32 (если каталог Spider доступен), кадр ленты — F2F `shot` в каталог прогона.

  python3 tools/scenarios/smollm_check.py v031|v032 [--prompt N|"текст"] [--n 8] [--manifest smollm:wasm.json]
                                          [--keep] [--lease NAME] [--timeout 600] [--kprof]
  --kprof — профиль по ядрам forward (export:smollm_kprof.txt): numbers.kprof_prefill / kprof_generation
  --kernels c|lua, --batch N — переопределить ядра и батч prefill манифеста (export:smollm_kernels.txt / smollm_batch.txt)

Выход: таблица шагов, пути прогона и кадра, числа (загрузка, prefill мс/токен, ток/с, heap Lua); код выхода — число провалов.
"""
import json, os, re, subprocess, sys, time

VC = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # TODO(переезд): был рабочий каталог движка (content, tools, worlds) — теперь корень репозитория
LAB = os.path.join(VC, "tools/lab/lab")
SPIDER_REF = os.environ.get("SPIDER_ROOT", "Spider") + "/tests/manual/real-world-smollm"
OWNER = os.environ.get("LAB_OWNER", "smollm_check")
FAILS, ROWS = [], []


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
    f2f(lease, "input", {"mouse": {"x": x, "y": y, "buttons": [False, False, False]}})
    time.sleep(pause)
    f2f(lease, "input", {"mouse": {"x": x, "y": y, "buttons": [True, False, False]}})
    time.sleep(pause)
    f2f(lease, "input", {"mouse": {"x": x, "y": y, "buttons": [False, False, False]}})
    time.sleep(pause)


def log_lines(lease, pattern, tail=2000):
    env = dict(os.environ, LAB_OWNER=OWNER)
    out = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", pattern], capture_output=True, text=True,
                         env=env, timeout=60).stdout
    # CLI печатает заголовок "# ..." и служебные строки; оставляем только строки лога, подходящие под шаблон
    return [l for l in out.splitlines() if not l.startswith("#") and re.search(pattern, l)]


def wait_log(lease, pattern, timeout, count=1, period=2.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        lines = log_lines(lease, pattern)
        if len(lines) >= count:
            return lines, time.time() - t0
        time.sleep(period)
    raise RuntimeError("timeout %ss waiting for /%s/ (have %d)" % (timeout, pattern, len(log_lines(lease, pattern))))


def step(name, fn):
    t0 = time.time()
    try:
        info = fn() or ""
        ROWS.append((name, "ok", round(time.time() - t0, 1), info))
        print("ok   %-28s %6.1fs  %s" % (name, time.time() - t0, info), flush=True)
    except Exception as e:
        FAILS.append(name)
        ROWS.append((name, "FAIL", round(time.time() - t0, 1), str(e)))
        print("FAIL %-28s %6.1fs  %s" % (name, time.time() - t0, e), flush=True)


def main():
    argv = sys.argv[1:]
    engine = argv[0] if argv and not argv[0].startswith("--") else "v031"
    opt = lambda k, d=None: argv[argv.index(k) + 1] if k in argv else d
    keep = "--keep" in argv
    kprof = "--kprof" in argv   # профиль по ядрам forward ([smollm] kprof {...} в лог, см. llm_host.lua)
    kernels = opt("--kernels")  # c | lua — ядра (export:smollm_kernels.txt), по умолчанию из манифеста
    batch = opt("--batch")      # токенов в батче prefill (export:smollm_batch.txt), по умолчанию из манифеста
    n_check = int(opt("--n", 8))
    manifest = opt("--manifest", "smollm:wasm.json")
    timeout = float(opt("--timeout", 600))
    ref = json.load(open(os.path.join(VC, "tools/scenarios/smollm_reference.json"), encoding="utf-8"))
    prompt_arg = opt("--prompt", "1")
    if prompt_arg in ref["prompts"]:
        entry = ref["prompts"][prompt_arg]
        prompt, expect, logits_ref = entry["prompt"], entry["gen"], entry["logits"]
    else:
        prompt, expect, logits_ref = prompt_arg, None, None
    lease = opt("--lease")
    params = ["--param", "script=smollm_chat.lua", "--param", 'packs=["wasmrt","smollm"]',
              "--param", r"ready_marker=\[smollm_chat\] ready", "--param", "ready_timeout=240"]
    if engine == "v032":
        params += ["--param", "engine=v032"]
    numbers = {}

    def do_lease():
        nonlocal lease
        if lease:
            return "reuse %s" % lease
        r = lab("lease", "wasmrt", "engine_rt", "--ttl", "1800", *params)
        if not r.get("ok"):
            raise RuntimeError(r)
        lease = r["lease"]["name"]
        inst = re.sub(r"^([A-Za-z]):", lambda m: "/mnt/" + m.group(1).lower(), r["lease"]["dir"]).replace("\\", "/")
        os.makedirs(os.path.join(inst, "export"), exist_ok=True)
        with open(os.path.join(inst, "export/smollm_dump_logits.txt"), "w") as f:
            f.write("1")
        # каталог экземпляра переживает аренды: флаги прошлых прогонов убрать
        for stale in ("smollm_kprof.txt", "smollm_manifest.txt", "smollm_prompt.txt", "smollm_kernels.txt",
                      "smollm_batch.txt", "smollm_remember.txt"):
            if os.path.isfile(os.path.join(inst, "export", stale)):
                os.remove(os.path.join(inst, "export", stale))
        with open(os.path.join(inst, "export/smollm_params.txt"), "w") as f:   # паритет: argmax, без штрафа
            f.write("0 0.85 1 120")
        if kprof:
            with open(os.path.join(inst, "export/smollm_kprof.txt"), "w") as f:
                f.write("1")
        if kernels:
            with open(os.path.join(inst, "export/smollm_kernels.txt"), "w") as f:
                f.write(kernels)
        if batch:
            with open(os.path.join(inst, "export/smollm_batch.txt"), "w") as f:
                f.write(batch)
        if manifest != "smollm:wasm.json":
            with open(os.path.join(inst, "export/smollm_manifest.txt"), "w") as f:
                f.write(manifest)
        numbers["inst"] = inst
        r = lab("start", lease)
        if not r.get("ok"):
            raise RuntimeError(r)
        numbers["run_dir"] = r.get("run_dir")
        return "%s port %s run %s" % (lease, r.get("ports"), r.get("run"))

    step("lease+start", do_lease)
    if FAILS:
        sys.exit(1)

    def do_load():
        lines, dt = wait_log(lease, r"smollm: model .* loaded in", 240)
        m = re.search(r"loaded in (\d+) ms", lines[-1])
        numbers["load_ms"] = int(m.group(1)) if m else None
        lines2, _ = wait_log(lease, r"\[smollm_chat\] ready", 60)
        return "weights loaded in %s ms" % numbers["load_ms"]

    step("model loaded", do_load)

    def do_type():
        # поле ввода: pos (8, H-44), size (W-134, 36) при 854x480 -> клик в (300, 454); Enter — consumer textbox
        mouse_click(lease, 300, 454)
        f2f(lease, "input", {"chars": prompt})
        time.sleep(0.3)
        f2f(lease, "shot", {"name": "typed"})
        f2f(lease, "input", {"keys": {"RETURN": True}})
        time.sleep(0.15)
        f2f(lease, "input", {"keys": {"RETURN": False}})
        lines, dt = wait_log(lease, r"\[smollm\] prompt: ", 20)
        got = lines[-1].split("[smollm] prompt: ", 1)[1].strip()
        if got != prompt:
            raise RuntimeError("prompt in log %r != typed %r" % (got, prompt))
        return "typed %r" % prompt

    step("type prompt (F2F input)", do_type)

    def do_reply():
        lines, dt = wait_log(lease, r"\[smollm\] reply done", timeout, period=3.0)
        done = lines[-1]
        toks = log_lines(lease, r"\[smollm\] reply tokens: ")[-1].split("reply tokens: ", 1)[1].split()
        numbers["tokens"] = [int(x) for x in toks]
        m = re.search(r"reply done: (\d+) tokens, (\d+) ms, ctx (\d+)(?:, lua heap ([\d.]+) MB)?", done)
        numbers["gen_tokens"], numbers["gen_ms"], numbers["ctx"] = int(m.group(1)), int(m.group(2)), int(m.group(3))
        numbers["lua_heap_mb"] = float(m.group(4)) if m.group(4) else None
        pf = log_lines(lease, r"smollm: prefill")[-1]
        m2 = re.search(r"prefill (\d+) tokens in (\d+) ms", pf)
        numbers["prefill_tokens"], numbers["prefill_ms"] = int(m2.group(1)), int(m2.group(2))
        text = log_lines(lease, r"\[smollm\] reply: ")[-1].split("reply: ", 1)[1]
        numbers["text"] = text
        for l in log_lines(lease, r"\[smollm\] kprof "):
            try:
                kp = json.loads(l.split("[smollm] kprof ", 1)[1])
                numbers["kprof_" + kp["phase"]] = kp
            except (ValueError, KeyError):
                pass
        return "%d tokens, %.2f tok/s, prefill %.0f ms/token, ctx %d, heap %s MB: %s" % (
            numbers["gen_tokens"], numbers["gen_tokens"] * 1000.0 / max(1, numbers["gen_ms"]),
            numbers["prefill_ms"] / max(1, numbers["prefill_tokens"]), numbers["ctx"], numbers["lua_heap_mb"], text[:60])

    step("reply", do_reply)

    def do_parity():
        if expect is None:
            return "no reference for this prompt (tokens: %s)" % numbers.get("tokens")
        got = numbers.get("tokens") or []
        n = min(n_check, len(expect))
        if got[:n] != expect[:n]:
            raise RuntimeError("first %d tokens differ: engine %s, reference %s" % (n, got[:n], expect[:n]))
        extra = ""
        if logits_ref and os.path.isfile(os.path.join(SPIDER_REF, logits_ref)) and numbers.get("inst"):
            eng = os.path.join(numbers["inst"], "export/smollm/last_logits.f32")
            if os.path.isfile(eng):
                same = open(eng, "rb").read() == open(os.path.join(SPIDER_REF, logits_ref), "rb").read()
                extra = ", logits %s" % ("bit-exact" if same else "DIFFER")
                if not same:
                    raise RuntimeError("logits differ from %s" % logits_ref)
        return "first %d tokens == reference%s" % (n, extra)

    step("parity vs native", do_parity)

    def do_shot():
        r = f2f(lease, "shot", {"name": "chat_reply"})
        numbers["shot"] = r.get("path")
        return r.get("path")

    step("shot", do_shot)

    if not keep:
        lab("release", lease)
    print("--")
    print("run: %s" % numbers.get("run_dir"))
    print("numbers: %s" % json.dumps({k: v for k, v in numbers.items() if k not in ("tokens",)}, ensure_ascii=False))
    print("failed: %d %s" % (len(FAILS), FAILS))
    sys.exit(len(FAILS))


if __name__ == "__main__":
    main()
