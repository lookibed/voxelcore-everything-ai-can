"""Команды CLI этапа 2б (история, ворота, панель, lab play, загрузка ПК, ночные ворота). Вызывается из lab.py.

  lab history <project> [--scenario X] [--last N] [--kind layers|e2e|perf|play|lab] [--json]
  lab history import [<project>]                    импорт каталогов прогонов ([history].import + runs_dir)
  lab history ingest <project> <dir>                один каталог прогона
  lab gate <project> [--suite all|layers|e2e|u|perf] [--mode latest|run] [--no-refresh] [--json]
                                                    код выхода: 0 pass, 1 fail, 2 нет данных/ошибка, 3 warn
  lab gate accept <project> <run-id> [--frames a,b] [--note T]   поднять храповик явно (ворота сами не поднимают)
  lab dashboard [--refresh]                         artifacts\\lab\\index.html, dashboard\\<project>.html, SUMMARY.md
  lab play <project> [start] --user [--param kind.k=v ...] [--opt autowalk] [--public] [--max-s N]
                                                   --public = --opt public (опция проекта [play.options.public])
                                                    игра пользователя на стоковом VoxelCore.exe: только из его
                                                    терминала (интерактивный CLI; LAB_OWNER агента — отказ)
  lab play <project> [start] --final-check --reason "..."   разовая финальная проверка главной сессией (claude/user)
  lab play <project> stop | status                  |  lab play list
  lab play <project> --user --wait                 держать терминал до конца сеанса, затем путь отчёта (play.bat)
  lab play <project> --dry-run [--keep]            всё, кроме стокового движка: сценарий <project>_play_dry (агентам можно)
  lab perf <project> <scenario> [--wait-idle 600] [--idle-window 30] [--allow-contended] [--param k=v ...]
                                                    замер на простаивающем ПК (этап 3а, vclab/quality/perf.py)
  lab sysload [--seconds N] [--idle]                загрузка ПК сейчас (busy + причины; --idle — простой для lab perf)
  lab schedule install|remove|status|xml            ночные ворота в Планировщике (ставит пользователь)
  lab nightly [--project P ...] [--suite all] [--mode run|latest] [--ignore-busy]
                                                    то, что запускает задача: проверка простоя, ворота, панель
"""
import json
import os
import subprocess
import sys
import time

COMMANDS = ("history", "gate", "dashboard", "play", "sysload", "schedule", "nightly", "perf")
TASK = "VoxelCoreLab\\NightlyGate"
HERE = os.path.dirname(os.path.abspath(__file__))                     # vclab\cli (schedule\nightly_gate.xml)


def _data_dir():
    """Каталог данных общего демона (lab.toml [daemon].data; раньше VC_ROOT\\artifacts\\lab)."""
    from vclab import config
    return config.load()["daemon"]["data"]


def _default_projects():
    """Проекты ночных ворот без --project: lab.toml [defaults] nightly_projects, иначе [defaults] project."""
    from vclab import config
    d = config.load().get("defaults") or {}
    return list(d.get("nightly_projects") or ([d["project"]] if d.get("project") else []))


def _call(c, feature, args, timeout=600.0):
    r = c.post("/call/%s" % feature, {"args": args}, timeout=timeout)
    if not r.get("ok"):
        return r, None
    return r, r.get("result")


def _print(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=1, default=str))


def run(c, cmd, argv, opt, params):
    """-> код выхода."""
    js = opt(argv, "--json", flag=True)
    if cmd == "history":
        if argv and argv[0] == "import":
            r, res = _call(c, "core.history_import", {"project": argv[1] if len(argv) > 1 else None})
            _print(res if res is not None else r)
            return 0 if res is not None else 1
        if argv and argv[0] == "ingest":
            r, res = _call(c, "core.history_ingest", {"project": argv[1], "dir": argv[2]})
            _print(res if res is not None else r)
            return 0 if res is not None else 1
        if not argv:
            print(__doc__)
            return 2
        a = {"project": argv[0], "scenario": opt(argv, "--scenario"), "last": int(opt(argv, "--last", 20)),
             "kind": opt(argv, "--kind"), "engine": opt(argv, "--engine"), "table": True, "counts": True}
        r, res = _call(c, "core.history", a)
        if res is None:
            _print(r)
            return 1
        if js:
            _print(res)
        else:
            print("# %s (%s)" % (a["project"], res["db"]))
            print(res["table"])
            print("\nвсего по видам: " + ", ".join("%s/%s@%s %d" % (x["kind"], x["impl"], x.get("engine_version"), x["n"])
                                                   for x in res.get("counts") or []))
        return 0
    if cmd == "gate":
        if argv and argv[0] == "accept":
            frames = opt(argv, "--frames")
            r, res = _call(c, "core.gate_accept", {"project": argv[1], "run": argv[2], "note": opt(argv, "--note"),
                                                   "frames": frames.split(",") if frames else None})
            _print(res if res is not None else r)
            return 0 if res is not None else 1
        if not argv:
            print(__doc__)
            return 2
        a = {"project": argv[0], "suite": opt(argv, "--suite", "all"), "mode": opt(argv, "--mode", "latest"),
             "refresh": not opt(argv, "--no-refresh", flag=True)}
        r, res = _call(c, "core.gate", a, timeout=6 * 3600)
        if res is None:
            _print(r)
            return 2
        if js:
            _print(res)
        else:
            s = res["summary"]
            print("gate %s %s: %s (exit %d)" % (a["project"], a["suite"], res["verdict"], res["exit_code"]))
            print("frames %d ok %d regressions %d (state %d) improved %d stale %d new %d; perf %s" % (
                s["frames"], s["ok"], s["regressions"], s["state_regressions"], s["improved"], s["stale"], s["new"],
                s["perf"] or "-"))
            for x in res["regressions"][:20]:
                print("  REGRESS %-24s %-10s %.3f -> %.3f (eps %.3f, %s %s)" % (
                    x["scenario"], x["frame"], x["was"], x["now"], x["eps"], x["base_src"], x["base_run"]))
            for p in res.get("perf") or []:
                if p["verdict"] not in ("ok", "new"):
                    print("  PERF %s/%s %s: %s (best %s)" % (p["scenario"], p["family"], p["verdict"], p["now"],
                                                            p["best"]))
            print("report: %s\ndashboard: %s" % (res["report_md"], res.get("dashboard")))
        return int(res["exit_code"])
    if cmd == "dashboard":
        r, res = _call(c, "core.dashboard", {"refresh": opt(argv, "--refresh", flag=True)})
        _print(res if res is not None else r)
        return 0 if res is not None else 1
    if cmd == "play":
        if argv and argv[0] == "list":
            r, res = _call(c, "core.play", {"action": "list"})
            _print(res if res is not None else r)
            return 0
        if not argv:
            print(__doc__)
            return 2
        project = argv.pop(0)
        action = argv.pop(0) if argv and not argv[0].startswith("--") else "start"
        a = {"project": project, "action": action}
        if action == "start" and opt(argv, "--dry-run", flag=True):
            # всё, кроме стокового движка: сценарий <project>_play_dry (тот же стек + клиент F2F с тем же
            # стартовым скриптом); агентам можно — стоковый рантайм не запускается
            import __main__
            extra = ["--keep"] if opt(argv, "--keep", flag=True) else []
            return __main__.main(["lab", "run", project, "%s_play_dry" % project] + extra)
        if action == "start":
            user = opt(argv, "--user", flag=True)
            final = opt(argv, "--final-check", flag=True)
            reason = opt(argv, "--reason")
            if user == final:
                print("lab play start needs exactly one of --user (the user's own game, interactive terminal) or "
                      "--final-check --reason \"...\" (one-off check by the main session)")
                return 2
            if user:
                env_owner = os.environ.get("LAB_OWNER")
                if env_owner and env_owner != "user":
                    print("refused: lab play --user is the user's command; LAB_OWNER=%s is an agent owner" % env_owner)
                    return 2
                interactive = sys.stdin.isatty() or os.environ.get("LAB_TTY") == "1"
                if not interactive:
                    print("refused: lab play --user needs an interactive terminal (stdin/stdout of a TTY)")
                    return 2
                c.owner = "user"
                a.update(user=True, interactive=True)
            else:
                a.update(final_check=True, reason=reason)
            p = params(argv)
            wait = opt(argv, "--wait", flag=True)
            opts = opt(argv, "--opt", many=True) or []
            if opt(argv, "--public", flag=True) and "public" not in opts:
                opts = list(opts) + ["public"]          # = --opt public ([play.options.public] проекта)
            a.update(params=p, opts=opts, max_s=float(opt(argv, "--max-s", 0)) or None)
        else:
            wait = False
        r, res = _call(c, "core.play", a, timeout=900)
        _print(res if res is not None else r)
        if res is None or not wait:
            return 0 if res is not None else 1
        # --wait: держать терминал до конца сеанса (выход окна игры), потом — где отчёт (play.bat пользователя)
        import time as _t
        sid = res.get("id")
        print("session %s is running; close the game window to finish (Ctrl+C here does not stop the game)" % sid,
              flush=True)
        while True:
            _t.sleep(3)
            r2, st = _call(c, "core.play", {"action": "status", "project": project, "session": sid})
            if st is None:
                print("status error: %s" % r2)
                return 1
            if st.get("state") in ("done", "failed"):
                print("session %s: %s, verdict %s" % (sid, st.get("state"), st.get("verdict")))
                if st.get("report"):
                    print("report: %s" % st["report"])
                if st.get("run_dir"):
                    print("run dir: %s" % st["run_dir"])
                if st.get("error"):
                    print("error: %s" % st["error"])
                return 0 if st.get("state") == "done" else 1
    if cmd == "perf":
        return perf(c, argv, opt, params)
    if cmd == "sysload":
        if opt(argv, "--idle", flag=True):         # определение «простоя» lab perf (этап 3а)
            r, res = _call(c, "core.idle", {"seconds": float(opt(argv, "--seconds", 1))})
            _print(res if res is not None else r)
            return 0 if res and res.get("idle") else 1
        r, res = _call(c, "core.sysload", {"seconds": float(opt(argv, "--seconds", 2))})
        _print(res if res is not None else r)
        return 0 if res is not None else 1
    if cmd == "schedule":
        return schedule(argv[0] if argv else "status", argv[1:])
    if cmd == "nightly":
        return nightly(c, argv, opt)
    return None


# ------------------------------------------------------------------------------------------------ lab perf
def perf(c, argv, opt, params):
    """lab perf <project> <scenario> [--wait-idle S] [--idle-window S] [--allow-contended] [--tag T] [--param k=v]
    [--detach]. Код выхода: 0 чистый замер, 3 contended, 4 отказ (ПК не простаивал), 1 сбой, 2 ошибка вызова."""
    if len(argv) >= 1 and argv[0] == "list":
        r, res = _call(c, "core.perf", {"action": "list"})
        _print(res if res is not None else r)
        return 0
    wait_idle = opt(argv, "--wait-idle")
    window = opt(argv, "--idle-window")
    allow = opt(argv, "--allow-contended", flag=True)
    detach = opt(argv, "--detach", flag=True)
    tag = opt(argv, "--tag")
    a = params(argv)
    if tag:
        a["tag"] = tag
    if len(argv) < 2:
        print(__doc__)
        return 2
    r, job = _call(c, "core.perf", {"project": argv[0], "scenario": argv[1], "args": a,
                                    "wait_idle_s": float(wait_idle) if wait_idle else None,
                                    "idle_window_s": float(window) if window else None, "allow_contended": allow})
    if job is None:
        _print(r)
        return 2
    print("job %s" % job["id"], flush=True)
    if detach:
        return 0
    seen = 0
    while True:
        try:
            rr = c.get("/scenario/jobs/%s?tail=400" % job["id"], timeout=30)
        except KeyboardInterrupt:
            c.post("/scenario/jobs/%s/cancel" % job["id"])
            raise
        j = rr.get("job") or {}
        seq = j.get("seq", 0)
        lines = j.get("progress") or []
        if seq > seen:
            for line in lines[-min(seq - seen, len(lines)):]:
                print(line, flush=True)
            seen = seq
        if j.get("state") != "running":
            break
        try:
            time.sleep(1.0)
        except KeyboardInterrupt:
            print("cancelling job %s" % job["id"], flush=True)
            c.post("/scenario/jobs/%s/cancel" % job["id"])
    res = j.get("result") or {}
    _print({k: res.get(k) for k in ("ok", "verdict", "contended", "dir", "refused", "reasons", "error")} if res
           else {"state": j.get("state"), "error": j.get("error")})
    if res.get("refused"):
        return 4
    if not res.get("ok"):
        return 1
    return 3 if res.get("contended") else 0


# ------------------------------------------------------------------------------------------------ Планировщик
def task_xml(user=None, start="03:00", python=None, projects=None):
    from vclab import config
    tmpl = open(os.path.join(HERE, "schedule", "nightly_gate.xml"), encoding="utf-8").read()
    user = user or "%s\\%s" % (os.environ.get("USERDOMAIN", ""), os.environ.get("USERNAME", ""))
    python = python or os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    day = time.strftime("%Y-%m-%d", time.localtime(time.time() + 86400))
    return (tmpl.replace("{USER}", user).replace("{PYTHONW}", python)
            .replace("{LAB_PY}", os.path.join(config.BIN_DIR, "lab.py")).replace("{WORKDIR}", config.REPO_ROOT)
            .replace("{PROJECTS}", " ".join("--project %s" % p for p in (projects or _default_projects())))
            .replace("{START}", "%sT%s:00" % (day, start)))


def schedule(action, argv):
    """install/remove/status/xml. Ставит задачу только пользователь (агент — status/xml)."""
    schtasks = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "schtasks.exe")
    out_dir = os.path.join(_data_dir(), "schedule")
    if action == "xml":
        print(task_xml())
        return 0
    if action == "install":
        os.makedirs(out_dir, exist_ok=True)
        p = os.path.join(out_dir, "nightly_gate.xml")
        start = argv[argv.index("--at") + 1] if "--at" in argv else "03:00"
        with open(p, "w", encoding="utf-16") as f:
            f.write(task_xml(start=start))
        r = subprocess.run([schtasks, "/Create", "/TN", TASK, "/XML", p, "/F"], capture_output=True)
        print(_dec(r.stdout) + _dec(r.stderr))
        return r.returncode
    if action == "remove":
        r = subprocess.run([schtasks, "/Delete", "/TN", TASK, "/F"], capture_output=True)
        print(_dec(r.stdout) + _dec(r.stderr))
        return r.returncode
    r = subprocess.run([schtasks, "/Query", "/TN", TASK, "/V", "/FO", "LIST"], capture_output=True)
    txt = _dec(r.stdout) + _dec(r.stderr)
    print(txt.strip() or "not installed")
    return 0 if r.returncode == 0 else 1


def _dec(b):
    for enc in ("utf-8", "cp866", "cp1251"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            continue
    return b.decode("utf-8", "replace")


def nightly(c, argv, opt):
    """Задача Планировщика: ПК простаивает? -> ворота по проектам (mode run: прогон набора интерпретатором, стоп при
    возвращении пользователя) -> история, панель. Журнал — <data>\\nightly\\<дата>.json."""
    projects = opt(argv, "--project", many=True) or _default_projects()
    suite = opt(argv, "--suite", "all")
    mode = opt(argv, "--mode", "run")
    ignore = opt(argv, "--ignore-busy", flag=True)
    log = {"started": time.strftime("%Y-%m-%d %H:%M:%S"), "projects": projects, "suite": suite, "mode": mode,
           "gates": {}}
    r, load = _call(c, "core.sysload", {"seconds": 5})
    log["load"] = load
    if load and load.get("busy") and not ignore:
        log["skipped"] = "PC busy: " + "; ".join(load.get("reasons") or [])
    else:
        for p in projects:
            r, res = _call(c, "core.gate", {"project": p, "suite": suite, "mode": mode, "stop_on_user": True},
                           timeout=6 * 3600)
            log["gates"][p] = {k: res.get(k) for k in ("verdict", "exit_code", "summary", "report_md")} if res else r
    _, dash = _call(c, "core.dashboard", {})
    log["dashboard"] = (dash or {}).get("index")
    log["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    data = os.path.join(_data_dir(), "nightly")
    os.makedirs(data, exist_ok=True)
    with open(os.path.join(data, time.strftime("%Y%m%d_%H%M%S") + ".json"), "w", encoding="utf-8") as f:
        json.dump(log, f, ensure_ascii=False, indent=1, default=str)
    _print(log)
    codes = [g.get("exit_code", 2) for g in log["gates"].values() if isinstance(g, dict)]
    return max(codes) if codes else (0 if log.get("skipped") else 2)


def params(argv):
    out = {}
    while "--param" in argv:
        i = argv.index("--param")
        k, _, v = argv[i + 1].partition("=")
        try:
            out[k] = json.loads(v)
        except ValueError:
            out[k] = v
        del argv[i:i + 2]
    return out
