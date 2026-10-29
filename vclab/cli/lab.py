"""lab — командная строка лаборатории (клиент демона labd; демон поднимается сам, если не запущен).

  lab ps                                             аренды: владелец, вид, порты, pid, состояние, TTL
  lab projects                                       проекты, виды экземпляров, возможности плагинов
  lab lease <project> <kind> [--owner X] [--ttl S] [--name N] [--param k=v ...] [--start]
  lab renew <lease> [--ttl S]
  lab release <lease> [--force] [--keep-dir]        |  lab release --all --force  (= «стоп»: снять всё)
  lab start <lease> [--restart] [--param k=v ...]   |  lab stop <lease>
  lab f2f <lease> <cmd> ['{"json": "args"}'] [--timeout S] [--repeat N]
  lab logs <lease> [--stream latest|stdout|stderr] [--tail N] [--grep RX]
  lab stdin <lease> "<cmd>" [--wait S] [--pattern RX] [--stream S]   строка в stdin (VoxelCore --stdin-cmd) -> новые строки лога
  lab engines [--project P] [--table]                версии движка ([engines.*]): файлы, sha256, ключи F2F, последний hello
  lab runs [--last N] [--project P]                  |  lab run open <project> <scenario> [--lease L ...] | lab run close <id> [--verdict V]
  lab call <feature> ['{"json": "args"}']            возможность плагина (lab call list — все)
  lab journal [--last N] [--lease L] [--inner]
  --- этап 2: сценарии, сравнение, golden (README «Сценарии», «Golden»)
  lab run <project> <scenario> [<scenario>...] --impl vc|java [--golden] [--keep] [--size WxH] [--detach] [--realtime]
  lab run <project> <file.lua|vctest.json> [--window [--clock virtual|realtime]] [--engine v032] [--timeout S]   тест движка 0.32 под --test (вид vctest)
                                                     прогон интерпретатором демона (аренды, каталог прогона, журнал);
                                                     --golden — сравнить с golden после прогона
  lab jobs | lab job <id> [--tail N] | lab cancel <id>   задания интерпретатора (прогоны, regen)
  lab compare <runA|dir> <runB|dir|golden> [--project P] [--tol N] [--out DIR]
  lab golden status <project> [--names a,b]         fresh / stale (причины) / unverified (неизвестное происхождение)
  lab golden import <project> [<name>...] [--overwrite]   манифесты существующих golden + CAS
  lab golden promote <run> --reason R [--scenario S] [--force]
  lab golden regen <scenario> [--project P] [--runs 3] [--reason R] [--strict]
  --- этап 2б: история, ворота, панель, игра (README «История», «Ворота», «lab play», «Ночные ворота»)
  lab history <project> [--scenario X] [--last N] [--kind K] | lab history import [<project>]
  lab gate <project> [--suite all|layers|e2e|u|perf] [--mode latest|run]   (exit 0 pass, 1 fail, 2 no data, 3 warn)
  lab gate accept <project> <run-id> [--frames a,b]  поднять храповик явно (ворота сами не поднимают)
  lab dashboard [--refresh]                          <data>\\index.html + SUMMARY.md
  lab play <project> --user [--param server.world=world_b] [--opt autowalk] [--max-s N]   (игра пользователя)
  lab play <project> --final-check --reason "..."  | lab play <project> stop|status | lab play list
  lab perf <project> <scenario> [--wait-idle 600] [--idle-window 30] [--allow-contended]   замер на простаивающем ПК
  lab sysload [--seconds N]  |  lab schedule install|remove|status|xml  |  lab nightly
  --- этап 5: роли, drain, изолированный демон, аудит (README «Этап 5»)
  lab daemon status | list                           код демона против диска (stale), drain, роль вызывающего; list — изолированные
  lab daemon start [--isolated [--port 25800..25849]]   изолированный демон: свои state/inst/порты, баннер ISOLATED
  lab daemon drain [--timeout S] [--then restart|upgrade|stop] | undrain      (admin)
  lab daemon upgrade [--timeout S] [--wait]          (admin) drain -> рестарт на код с диска, версия в state\\daemon.json
  lab daemon stop|restart [--force] [--reason R]     (admin) отказ при живых/чужих арендах -> drain/upgrade
  lab daemon reload-core [--module gate ...]         (admin) горячая перезагрузка compare/golden/history/dashboard/gate/sysload
  lab audit [--last N] [--table]                     действия уровня демона (<data>\\audit.jsonl)
  --- этап 6: supervisor (vclab/supervise.py, vclab/cli/cli_sup.py)
  lab sup state|incidents|events|accounts|bans|counters|tariffs     ядро supervisor (core.sup)
  --- машина и проекты (новый репозиторий)
  lab doctor [--json]                                machine.toml, корни, движки реестра (сток, F2F, hello.version), Python,
                                                     MSYS2, cargo, место на диске, порт демона: таблица «ок / чего нет / как починить»
  lab <project> <...>                                CLI проекта: projects/<project>/cli.py (run(c, argv, opt)), если он есть
  Общие ключи: --daemon P (LAB_PORT) — какой демон; --as-agent (LAB_ROLE=agent) — роль agent при LAB_OWNER главной сессии.
Из WSL: bin/lab <...> (обёртка запускает python_win из machine.toml; LAB_OWNER передаётся через WSLENV).
Вывод — JSON (--table для ps/runs/journal — таблица)."""
import json
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if REPO not in sys.path:
    sys.path.insert(0, REPO)
from vclab.daemon.client import LabClient  # noqa: E402


def _default_project():
    """Проект без --project: lab.toml [defaults] project (раньше в коде было зашито имя проекта)."""
    from vclab import config
    p = config.default_project()
    if not p:
        raise SystemExit("--project is required (no [defaults] project in lab.toml)")
    return p


_CLI = {}


def project_cli(name):
    """projects/<name>/cli.py проекта (CLI поверх возможностей его плагина) -> модуль с run(c, argv, opt) или None.
    Ищется в каталогах проектов ядра (config.load()["project_dirs"]: projects/ + LAB_PROJECTS)."""
    if name in _CLI:
        return _CLI[name]
    mod = None
    if name and name.replace("_", "").isalnum() and not name.startswith("_"):
        try:
            from vclab import config
            dirs = config.load()["project_dirs"]
        except Exception:
            from vclab import config
            dirs = [config.PROJECTS_DIR]
        for d in dirs:
            p = os.path.join(d, name, "cli.py")
            if os.path.isfile(p):
                import importlib.util
                spec = importlib.util.spec_from_file_location("vclab_project_cli_" + name, p)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                break
    _CLI[name] = mod
    return mod


def opt(argv, name, default=None, many=False, flag=False):
    vals = []
    while name in argv:
        i = argv.index(name)
        if flag:
            argv.pop(i)
            return True
        vals.append(argv[i + 1])
        del argv[i:i + 2]
    if flag:
        return False
    if many:
        return vals
    return vals[-1] if vals else default


def params(argv):
    out = {}
    for kv in opt(argv, "--param", many=True):
        k, _, v = kv.partition("=")
        try:
            out[k] = json.loads(v)
        except ValueError:
            out[k] = v
    return out


def daemon_banner(r):
    """Этап 5: строка о демоне над таблицей ps — ISOLATED / DRAINING видны сразу."""
    d = r.get("daemon") or {}
    if not d:
        return None
    marks = []
    if d.get("isolated"):
        marks.append("ISOLATED daemon :%s (starter %s)" % (d.get("port"), d.get("starter")))
    if d.get("state") and d["state"] != "serving":
        dr = d.get("drain") or {}
        marks.append("%s by %s, then %s, %.0f s%s; waiting for: %s" % (
            d["state"].upper(), dr.get("by"), dr.get("then") or "-", dr.get("elapsed_s") or 0,
            (", left %.0f s" % dr["left_s"]) if dr.get("left_s") is not None else "",
            ", ".join(dr.get("waiting_for") or []) or "nothing"))
    if not marks:
        return "# labd :%s serving, code %s" % (d.get("port"), d.get("code_hash"))
    return "# " + " | ".join(marks) + "  (code %s)" % d.get("code_hash")


def ps_table(r):
    banner = daemon_banner(r)
    rows = ([banner] if banner else []) + ["%-26s %-10s %-10s %-6s %-14s %-9s %-7s %-22s %8s  %s" % (
        "lease", "project", "kind", "engine", "owner", "state", "pid", "ports", "ttl,s", "run")]
    for l in r.get("leases", []):
        p = l.get("proc") or {}
        iso = l.get("isolation") or {}
        mark = (" %s:%s" % (iso.get("role") or "f2f", iso.get("mode") or iso.get("clock") or "")) if iso else ""
        if iso.get("hello_version"):                    # этап 4a: версия из hello сборки (0.31-f2f / 0.32-f2f)
            mark += " %s%s" % (iso["hello_version"], "" if iso.get("verified") else " UNVERIFIED")
        if iso.get("role") == "headless":
            mark = " headless:%s%s" % ("STOCK" if iso.get("stock") else "build",
                                       "" if iso.get("verified") else " UNVERIFIED")
        rows.append("%-26s %-10s %-10s %-6s %-14s %-9s %-7s %-22s %8.0f  %s%s" % (
            l["name"], l["project"], l["kind"], l.get("engine_version") or "-", (l.get("owner") or "")[:14], l["state"],
            p.get("pid") if p.get("alive") else "-", ",".join("%s:%s" % kv for kv in l["ports"].items()),
            l.get("expires_in", 0), l.get("run") or "", mark))
    for f in r.get("foreign") or []:      # сторож: движок/Java вне аренд (не убиваются, только видны)
        rows.append("%-26s %-10s %-10s %-6s %-14s %-9s %-7s %s" % (
            (f.get("name") or "")[:26], "-", "STOCK" if f.get("stock") else ("f2f" if f.get("f2f") else "-"), "?", "?",
            "foreign", f.get("pid"), (f.get("cmdline") or "")[:110]))
    return "\n".join(rows)


def engines_table(r):
    """lab engines --table: движок, версия, каждый файл (f2f/stock/vctest...) — sha256, ключи F2F образа, последний hello."""
    rows = ["default: %s" % r.get("default"),
            "%-6s %-7s %-7s %-12s %-6s %-26s %-28s %s" % ("engine", "version", "file", "sha256", "stock", "f2f keys",
                                                        "hello (last lease)", "path")]
    for eid, e in sorted((r.get("engines") or {}).items()):
        for nm, f in sorted((e.get("files") or {}).items()):
            caps = f.get("f2f") or {}
            keys = ",".join(k.replace("--f2f", "") or "f2f" for k, v in caps.items() if v) or "-"
            h = f.get("hello") or {}
            hs = ("%s %s %s" % (h.get("version"), h.get("build") or "", (h.get("flags") or {}).get("input") or "")
                  ).strip() if h else "-"
            rows.append("%-6s %-7s %-7s %-12s %-6s %-26s %-28s %s" % (
                eid, e.get("version") or "-", nm, (f.get("sha256") or ("MISSING" if not f.get("exists") else "?"))[:12],
                "STOCK" if f.get("stock") else "-", keys if caps.get("--f2f") else "no f2f", hs[:28], f.get("path")))
    return "\n".join(rows)


def follow(c, jid, detach=False, quiet=False):
    """Ждать задание интерпретатора, печатая новые строки прогресса; Ctrl+C — отменить задание."""
    seen = 0
    while True:
        try:
            r = c.get("/scenario/jobs/%s?tail=400" % jid, timeout=30)
        except KeyboardInterrupt:
            c.post("/scenario/jobs/%s/cancel" % jid)
            raise
        if not r.get("ok"):
            print(json.dumps(r, ensure_ascii=False))
            return r
        j = r["job"]
        seq = j.get("seq", 0)
        lines = j.get("progress") or []
        new = seq - seen
        if new > 0 and not quiet:
            for line in lines[-min(new, len(lines)):]:
                print(line, flush=True)
        seen = seq
        if detach or j.get("state") not in ("running",):
            return j
        try:
            time.sleep(1.0)
        except KeyboardInterrupt:
            print("cancelling job %s" % jid, flush=True)
            c.post("/scenario/jobs/%s/cancel" % jid)


def main(argv):
    argv = list(argv[1:])
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    if argv[0] == "doctor":                             # без демона: проверка машины (vclab/cli/doctor.py)
        from vclab.cli import doctor
        return doctor.main(argv[1:])
    table = opt(argv, "--table", flag=True)
    owner = opt(argv, "--owner")
    daemon = opt(argv, "--daemon")                      # этап 5: какой демон (изолированный — 25800–25849)
    role = "agent" if opt(argv, "--as-agent", flag=True) else None
    port = int(daemon) if daemon else None
    c = LabClient(port, owner=owner, role=role)
    cmd = argv.pop(0)
    from vclab.cli import labctl as labctl
    if cmd == "daemon":
        return labctl.main(["labctl"] + argv + (["--table"] if table else []), port=port, owner=owner, role=role)
    if cmd == "audit":
        r = labctl.audit(port, int(opt(argv, "--last", 30)))
        if table:
            print(labctl.audit_table(r))
            return 0
        print(json.dumps(r, ensure_ascii=False, indent=1, default=str))
        return 0
    if not c.alive():
        if c.port != labctl.shared_port():
            # изолированный/тестовый демон сам не поднимается: иначе опечатка в порте создала бы лишний демон
            print(json.dumps({"ok": False, "error": "labd is not running on %d (isolated: lab daemon start --isolated "
                              "--port %d)" % (c.port, c.port)}, ensure_ascii=False))
            return 1
        r = labctl.start()
        if not r.get("ok"):
            print(json.dumps(r, ensure_ascii=False))
            return 1
    if cmd == "ps":
        r = c.get("/leases")
        if table:
            print(ps_table(r))
            return 0
    elif cmd == "projects":
        r = c.get("/projects")
    elif cmd == "lease":
        p = params(argv)
        ttl = opt(argv, "--ttl")
        name = opt(argv, "--name")
        start = opt(argv, "--start", flag=True)
        r = c.post("/leases", {"project": argv[0], "kind": argv[1], "ttl": float(ttl) if ttl else None,
                               "name": name, "params": p, "start": start})
    elif cmd == "renew":
        ttl = opt(argv, "--ttl")
        r = c.post("/leases/%s/renew" % argv[0], {"ttl": float(ttl) if ttl else None})
    elif cmd == "release":
        force = opt(argv, "--force", flag=True)
        keep = opt(argv, "--keep-dir", flag=True)
        if opt(argv, "--all", flag=True):
            if not force:
                print("release --all needs --force (the user's stop: kills every lease, also other agents')")
                return 2
            r = c.post("/stop-all")
        else:
            r = c.post("/leases/%s/release" % argv[0], {"force": force, "keep_dir": keep})
    elif cmd == "start":
        restart = opt(argv, "--restart", flag=True)
        p = params(argv)
        r = c.post("/proc/%s/start" % argv[0], {"restart": restart, "params": p or None})
    elif cmd == "stop":
        r = c.post("/proc/%s/stop" % argv[0], {"force": opt(argv, "--force", flag=True)})
    elif cmd == "status":
        r = c.get("/proc/%s" % argv[0])
    elif cmd == "f2f":
        timeout = float(opt(argv, "--timeout", 60))
        repeat = int(opt(argv, "--repeat", 1))
        args = json.loads(argv[2]) if len(argv) > 2 else {}
        times = []
        for _ in range(repeat):
            t0 = time.perf_counter()
            r = c.post("/f2f/%s" % argv[0], {"cmd": argv[1], "args": args, "timeout": timeout})
            times.append((time.perf_counter() - t0) * 1000)
        if repeat > 1:
            s = sorted(times)
            r = dict(r, http_ms={"n": repeat, "min": round(s[0], 2), "median": round(s[len(s) // 2], 2),
                                 "max": round(s[-1], 2)})
    elif cmd == "logs":
        stream = opt(argv, "--stream")
        tail = int(opt(argv, "--tail", 80))
        grep = opt(argv, "--grep")
        q = "?tail=%d" % tail + ("&stream=%s" % stream if stream else "")
        if grep:
            import urllib.parse
            q += "&grep=" + urllib.parse.quote(grep)
        r = c.get("/proc/%s/logs%s" % (argv[0], q))
        if r.get("ok"):
            print("# %s %s (%s)" % (r["lease"], r["stream"], r["path"]))
            print("\n".join(r["lines"]))
            return 0
    elif cmd == "stdin":
        wait = float(opt(argv, "--wait", 2.0))
        pattern = opt(argv, "--pattern")
        stream = opt(argv, "--stream")
        nopoke = opt(argv, "--no-poke", flag=True)     # диагностика: без события консоли (доказать, что оно нужно)
        r = c.post("/proc/%s/stdin" % argv[0], {"text": argv[1], "wait": wait, "pattern": pattern, "stream": stream,
                                                "poke": False if nopoke else None},
                   timeout=wait + 30)
        if r.get("ok") and not table:
            print("# %s <- %r (%s, %d new lines%s)" % (r["lease"], r["sent"], r["stream"], len(r["lines"]),
                                                      ", poke %s" % r["poke"].get("out") if isinstance(r.get("poke"), dict) else ""))
            print("\n".join(r["lines"]))
            return 0
    elif cmd == "engines":
        project = opt(argv, "--project")
        r = c.get("/engines" + ("?project=%s" % project if project else ""))
        if table and r.get("ok"):
            print(engines_table(r))
            return 0
    elif cmd == "runs":
        last = int(opt(argv, "--last", 20))
        project = opt(argv, "--project")
        r = c.get("/runs?last=%d" % last + ("&project=%s" % project if project else ""))
        if table:
            for e in r.get("runs", []):
                print("%-48s %-7s %-8s %3s shots  %s" % (e["id"], e.get("state"), e.get("verdict") or "",
                                                         e.get("shots", ""), e["dir"]))
            return 0
    elif cmd == "run" and argv and (argv[0] in ("open", "close") or (len(argv) == 1 and argv[0][:8].isdigit())):
        sub = argv.pop(0)
        if sub == "open":
            leases = opt(argv, "--lease", many=True)
            r = c.post("/runs", {"project": argv[0], "scenario": argv[1] if len(argv) > 1 else "adhoc",
                                 "leases": leases})
        elif sub == "close":
            r = c.post("/runs/%s/close" % argv[0], {"verdict": opt(argv, "--verdict")})
        else:
            r = c.get("/runs/%s" % sub)
    elif cmd == "call":
        args = json.loads(argv[1]) if len(argv) > 1 else {}
        r = c.post("/call/%s" % argv[0], {"args": args})
    elif cmd == "journal":
        last = int(opt(argv, "--last", 30))
        lease = opt(argv, "--lease")
        inner = opt(argv, "--inner", flag=True)
        r = c.get("/journal?last=%d" % last + ("&instance=%s" % lease if lease else "") +
                  ("&inner=true" if inner else ""))
        if table:
            for e in r.get("entries", []):
                print("%6d %s %-12s %-22s %8.3f %-14s %s" % (e["idx"], e["t"][11:19], e["tool"],
                                                            (e.get("instance") or "")[:22], e.get("dur", 0),
                                                            ",".join(e.get("flags", [])), e.get("result", "")[:80]))
            return 0
    elif cmd == "run":
        impl = opt(argv, "--impl", "vc")
        golden = opt(argv, "--golden", flag=True)
        keep = opt(argv, "--keep", flag=True)
        detach = opt(argv, "--detach", flag=True)
        size = opt(argv, "--size")
        realtime = opt(argv, "--realtime", flag=True)
        window = opt(argv, "--window", flag=True)
        engine = opt(argv, "--engine")
        vclock = opt(argv, "--clock")             # vctest --window: virtual (умолчание, раннер шагает) | realtime
        vtimeout = opt(argv, "--timeout")
        project, names = argv[0], argv[1:]
        opts = {"golden": golden, "keep": keep}
        if window:
            opts["window"] = True        # vctest: оконный --test (тестовая сборка F2F, часы virtual — раннер шагает)
        if engine:
            opts["engine"] = engine      # vctest: другой движок ([engines.<id>])
        if vclock:
            opts["clock"] = vclock
        if vtimeout:
            opts["timeout"] = float(vtimeout)
        if realtime:
            opts["realtime"] = True      # сервер по часам (дымовой прогон «в реальном времени»), без lockstep
        if size:
            opts["size"] = size
        r = c.post("/scenario/run", {"project": project, "scenarios": names, "impl": impl, "opts": opts})
        if not r.get("ok"):
            print(json.dumps(r, ensure_ascii=False, indent=1))
            return 1
        jid = r["job"]["id"]
        print("job %s -> %s" % (jid, r["job"]["dir"]), flush=True)
        j = follow(c, jid, detach)
        if detach:
            return 0
        rr = c.get("/runs/%s" % jid).get("run") or {}
        sc = rr.get("scenario") or {}
        for res in sc.get("results") or []:
            print("--- %s: %s, %d shots" % (res["scenario"], "ok" if res.get("ok") else "FAILED (%s)" % res.get("error"),
                                           len(res.get("shots") or [])))
            if res.get("kind") == "vctest":
                print("    engine %s (%s), exit %s, %s s, test %s" % (res.get("engine_version"), res.get("mode"),
                                                                     res.get("exit"), res.get("dur"), res.get("test")))
                for st_, lg in (res.get("logs") or {}).items():
                    print("    log %-7s %s (%d lines)%s" % (st_, lg.get("file"), lg.get("lines", 0),
                                                           "; errors: %s" % lg["errors"][:2] if lg.get("errors") else ""))
            for s_ in res.get("shots") or []:
                print("    %-12s %s  file %s" % (s_["name"], s_.get("sha256"), (s_.get("file_sha256") or "")[:16]))
        cm = sc.get("compare")
        if cm:
            print("compare vs golden: %s" % json.dumps(cm.get("summary") or cm.get("error"), ensure_ascii=False))
            for n, b_ in (cm.get("per_scenario") or {}).items():
                print("    %s: %s" % (n, json.dumps(b_, ensure_ascii=False)))
            print("    report: %s" % os.path.join(cm.get("out") or "", "report.md"))
        print("timing %s; verdict %s; run %s" % (json.dumps(sc.get("timing")), j.get("verdict"), rr.get("dir")))
        return 0 if j.get("verdict") == "ok" else 1
    elif cmd == "jobs":
        r = c.get("/scenario/jobs")
        if table:
            for j in r.get("jobs", []):
                print("%-56s %-9s %-10s %s" % (j["id"], j.get("state"), j.get("owner"), (j.get("progress") or [""])[-1]))
            return 0
    elif cmd == "job":
        r = c.get("/scenario/jobs/%s?tail=%d" % (argv[0], int(opt(argv, "--tail", 40))))
    elif cmd == "cancel":
        r = c.post("/scenario/jobs/%s/cancel" % argv[0])
    elif cmd == "compare":
        tol = opt(argv, "--tol")
        r = c.post("/compare", {"a": argv[0], "b": argv[1] if len(argv) > 1 else "golden",
                                "project": opt(argv, "--project"), "out": opt(argv, "--out"),
                                "tol": int(tol) if tol is not None else None}, timeout=1800)
    elif cmd == "golden":
        sub = argv.pop(0)
        if sub == "status":
            names = opt(argv, "--names")
            r = c.get("/golden/%s/status" % argv[0] + ("?names=%s" % names if names else ""), timeout=600)
            if table and r.get("ok"):
                for g in r["goldens"]:
                    print("%-26s %-11s %-5s %-9s %s" % (g["name"], g["state"], g.get("impl") or "", g.get("size") or "",
                                                       "; ".join(g.get("reasons") or [])[:160]))
                    if g.get("unverified"):
                        print("%-26s   unverified: %s" % ("", ", ".join(x.split(" (")[0] for x in g["unverified"])))
                print("counts: %s" % json.dumps(r["counts"]))
                return 0
        elif sub == "import":
            r = c.post("/golden/%s/import" % argv[0], {"names": argv[1:] or None,
                                                       "overwrite": opt(argv, "--overwrite", flag=True)}, timeout=1800)
        elif sub == "promote":
            reason = opt(argv, "--reason")
            r = c.post("/golden/promote", {"run": argv[0], "reason": reason,
                                           "scenarios": opt(argv, "--scenario", many=True) or None,
                                           "force": opt(argv, "--force", flag=True)})
        elif sub == "regen":
            project = opt(argv, "--project") or _default_project()
            r = c.post("/golden/%s/regen" % project, {"scenario": argv[0], "runs": int(opt(argv, "--runs", 3)),
                                                      "reason": opt(argv, "--reason"),
                                                      "strict": opt(argv, "--strict", flag=True),
                                                      "impl": opt(argv, "--impl", "java")})
            if r.get("ok") and not opt(argv, "--detach", flag=True):
                j = follow(c, r["job"]["id"])
                r = c.get("/scenario/jobs/%s?tail=5" % j["id"])
        else:
            print("lab golden status|import|promote|regen")
            return 2
    elif cmd in ("history", "gate", "dashboard", "play", "sysload", "schedule", "nightly", "perf"):   # этап 2б/3а
        from vclab.cli import cli2b
        return cli2b.run(c, cmd, argv, opt, params)
    elif cmd == "sup":                                  # этап 6: supervisor (vclab/cli/cli_sup.py)
        from vclab.cli import cli_sup
        return cli_sup.run(c, cmd, argv, opt)
    elif cmd == "health":
        r = c.get("/health")
    elif project_cli(cmd) is not None:                  # точка расширения: projects/<cmd>/cli.py (lab <проект> ...)
        return project_cli(cmd).run(c, argv, opt)
    else:
        print("unknown command %r\n%s" % (cmd, __doc__))
        return 2
    print(json.dumps(r, ensure_ascii=False, indent=1))
    return 0 if r.get("ok", True) else 1


def _entry():
    """console_script `lab` (pip install -e .): то же, что bin/lab.py."""
    sys.exit(main(sys.argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
