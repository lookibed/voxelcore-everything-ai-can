#!/usr/bin/env python3
"""Half-Life (пак halflife: Xash3D FWGS + hlsdk-portable, wasm -> Lua, wasmrt) в лаборатории.

Аренда `wasmrt engine_rt` (тестовая сборка F2F, часы realtime, 854x480, ввод ОС изолирован), стартовый сценарий
tools/scenarios/wasmrt_page.lua с манифестом пака (по умолчанию halflife:wasm.json; карта hldemo1 из Uplink).
Шаги: старт -> загрузка карты (`[wasmrt] mouse grabbed`: игра, курсор захвачен) -> мир (после вступительного затемнения ~25 с) ->
N строк fps (`[wasmrt] <манифест>: X fps`, раз в 5 с) -> кадр F2F `shot` -> (необязательно) ход вперёд клавишей W
через F2F `input` и ещё кадр -> освобождение аренды.

  python3 tools/scenarios/halflife_check.py [--manifest halflife:wasm.json] [--fps-lines 4] [--walk 3]
                                            [--button] [--keep] [--lease NAME] [--timeout 400]
  --button — кнопка «Рендер» (F2F клик): 854x480 -> 640x360 -> 480x270 -> 854x480, fps и кадр на каждом

Вывод: таблица шагов, числа (секунды до карты, fps по строкам лога, медиана), пути кадров; код выхода — число провалов.
ПК должен быть свободен для замеров: `lab sysload` пишется в отчёт (busy -> замер помечается contended).
"""
import json, os, re, statistics, subprocess, sys, time

VC = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # TODO(переезд): был рабочий каталог движка (content, tools, worlds) — теперь корень репозитория
LAB = os.path.join(VC, "tools/lab/lab")
OWNER = os.environ.get("LAB_OWNER", "halflife_check")
FAILS, ROWS = [], []


def lab(*args, timeout=400):
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


def log_lines(lease, pattern, tail=4000):
    env = dict(os.environ, LAB_OWNER=OWNER)
    out = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", pattern], capture_output=True, text=True,
                         env=env, timeout=60).stdout
    return [l for l in out.splitlines() if not l.startswith("#") and re.search(pattern, l)]


def wait_log(lease, pattern, timeout, count=1, period=2.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        lines = log_lines(lease, pattern)
        if len(lines) >= count:
            return lines, time.time() - t0
        if log_lines(lease, r"\[wasmrt\] crash|halflife: longjmp"):
            raise RuntimeError("program stopped: %s" % log_lines(lease, r"\[wasmrt\] crash|longjmp|Xash Error")[-2:])
        time.sleep(period)
    raise RuntimeError("timeout %ss waiting for /%s/ (have %d)" % (timeout, pattern, len(log_lines(lease, pattern))))


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


def main():
    argv = sys.argv[1:]
    opt = lambda k, d=None: argv[argv.index(k) + 1] if k in argv else d
    manifest = opt("--manifest", "halflife:wasm.json")
    n_fps = int(opt("--fps-lines", 4))
    walk = float(opt("--walk", 0))
    timeout = float(opt("--timeout", 400))
    keep = "--keep" in argv
    lease = opt("--lease")
    mname = manifest.split(":", 1)[1]
    fps_re = re.escape(mname) + r": ([0-9.]+) fps"
    numbers = {"manifest": manifest}

    load = lab("sysload")
    numbers["sysload_before"] = {"busy": load.get("busy"), "reasons": load.get("reasons")}

    def do_lease():
        nonlocal lease
        if lease:
            return "reuse %s" % lease
        ready = r"halflife: resolution" if "--button" in argv else fps_re
        r = lab("lease", "wasmrt", "engine_rt", "--ttl", "1800", "--param", "manifest=" + manifest,
                "--param", 'packs=["wasmrt","halflife"]', "--param", "ready_marker=" + ready,
                "--param", "ready_timeout=300")
        if not r.get("ok"):
            raise RuntimeError(str(r)[:400])
        lease = r["lease"]["name"]
        # каталог экземпляра переживает аренды: выбор кнопки «Рендер» прошлых прогонов убрать (иначе он
        # перекрывает разрешение манифеста)
        inst = re.sub(r"^([A-Za-z]):", lambda m: "/mnt/" + m.group(1).lower(), r["lease"]["dir"]).replace("\\", "/")
        stale = os.path.join(inst, "config/halflife/resolution.txt")
        if os.path.isfile(stale):
            os.remove(stale)
        r = lab("start", lease)
        if not r.get("ok"):
            raise RuntimeError(str(r)[:400])
        numbers["run_dir"] = r.get("run_dir")
        return lease

    step("lease+start", do_lease)
    if FAILS:
        sys.exit(1)
    t_start = time.time()

    if "--button" in argv:
        def do_button_start():
            # кнопка «Рендер: WxH» (pos 8,52 size 200x32 на странице 854x480) пока карта грузится и курсор свободен
            # (в игре курсор захвачен; Esc -> консоль Xash его отпускает — через F2F не проверено, см. README)
            for b in (False, True, False):
                f2f(lease, "input", {"mouse": {"x": 108, "y": 68, "buttons": [b, False, False]}})
                time.sleep(0.15)
            lines, _ = wait_log(lease, r"render size 640x360", 120)
            return lines[-1].split("out: ")[-1][-50:]

        step("button -> 640x360", do_button_start)

    def do_map():
        lines, dt = wait_log(lease, r"\[wasmrt\] mouse grabbed", timeout)  # игра идёт: key_game + ca_active
        numbers["map_s"] = round(time.time() - t_start, 1)
        return "in game after %.1f s" % numbers["map_s"]

    step("map hldemo1 loaded", do_map)

    def do_world():
        # вступительное затемнение и титры Uplink ~25 с: ждать, пока fps-строк станет на 6 больше
        have = len(log_lines(lease, fps_re))
        wait_log(lease, fps_re, timeout, count=have + 6, period=3.0)
        r = f2f(lease, "shot", {"name": "world"})
        numbers["shot_world"] = r.get("path")
        return r.get("path")

    step("world frame (shot)", do_world)

    def do_fps():
        have = len(log_lines(lease, fps_re))
        lines, _ = wait_log(lease, fps_re, timeout, count=have + n_fps, period=3.0)
        vals = [float(re.search(fps_re, l).group(1)) for l in lines[-n_fps:]]
        numbers["fps"] = vals
        numbers["fps_median"] = statistics.median(vals)
        return "fps %s median %.1f" % (vals, numbers["fps_median"])

    step("fps (log, 5 s each)", do_fps)

    if walk > 0:
        def do_walk():
            f2f(lease, "input", {"keys": {"W": True}})
            time.sleep(walk)
            f2f(lease, "input", {"keys": {"W": False}})
            time.sleep(0.5)
            r = f2f(lease, "shot", {"name": "walked"})
            numbers["shot_walked"] = r.get("path")
            return r.get("path")

        step("walk forward (F2F W)", do_walk)

    load = lab("sysload")
    numbers["sysload_after"] = {"busy": load.get("busy"), "reasons": load.get("reasons")}
    if not keep:
        lab("release", lease)
    print(json.dumps(numbers, ensure_ascii=False, indent=1))
    print("contended" if (numbers["sysload_before"]["busy"] or numbers["sysload_after"]["busy"]) else "free")
    sys.exit(len(FAILS))


if __name__ == "__main__":
    main()
