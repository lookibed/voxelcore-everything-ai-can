"""Возможности и хуки сценариев проекта olife (lab call olife.<имя>, lab run olife <сценарий>).
Волна 2 (02.10): настоящие паки content/olife_world + olife_client (+ olife_proto), шлюз tools/olife/gateway_dev.py,
песочница tools/olife/sandbox_stub.py; согласованность — hash вида каждой сессии (views[eid] мира против реплики бота);
шаги olife_blocks (бот против мира по изменённым позициям) и olife_negative_proto (tools/olife/negative.py).

  olife.session  {clients=1, client_kind="bot"|"client", sandbox=true, gateway=true, ticks=0, world_mode="--script",
                  ttl} — аренды мир + шлюз + песочница + N клиентов, одна сессия (параметр аренд session=<id>);
                  мир — headless стоковый 0.32, бот — headless стоковый 0.32, клиент — тестовая сборка F2F 0.32.
  olife.release  {session} — освободить аренды сессии (клиенты, песочница, шлюз, мир — в этом порядке).
  olife.status   {session} — `status` миру через stdin (--stdin-cmd), метрики шлюза, статистика песочницы.
  olife.consistency {session} — сравнение состояний по тактам: мир против каждого клиента (hash реплики), задержка
                  такта (t_recv клиента − ts мира, мс), пропуски, байты и задержка ack на шлюзе.
  olife.sandbox_probe {session|lease, attempts?} — негативные попытки выхода из песочницы (обвязка; песочница —
                  заглушка, всё отклоняет).
Сценарии (scenarios/*.json): шаговые; setup.session — как аргументы olife.session; шаги olife_run, olife_stdin,
olife_consistency, olife_sandbox, olife_metrics. Итог — report.scenario.finish {olife: true, metrics}.
"""
import json
import os
import time

PLUGIN_VERSION = 4

ORDER = ("world", "gateway", "sandbox")          # роли сессии; старт: песочница -> мир -> шлюз -> клиенты

DEFAULT_ATTEMPTS = [
    # из разбора прототипа 0.30.6 (OLIFE_ASSESSMENT.md §2): обход окружения через компонент, файлы, ОС, отладка,
    # бесконечный цикл, бомба памяти, подмена общих библиотек
    {"name": "component_env_escape", "code": "local e = entity:get_component('x'); e.file.write('{canary}', 'x')"},
    {"name": "os_execute", "code": "os.execute('cmd /c echo x > {canary}')"},
    {"name": "io_open", "code": "local f = io.open('{canary}', 'w'); f:write('x'); f:close()"},
    {"name": "debug_registry", "code": "debug.getregistry()._G.file.write('{canary}', 'x')"},
    {"name": "infinite_loop", "code": "while true do end"},
    {"name": "memory_bomb", "code": "local t = {} for i = 1, 1e9 do t[i] = string.rep('x', 1e6) end"},
    {"name": "shared_lib_patch", "code": "string.rep = function() return '' end; math.floor = nil"},
    {"name": "load_bytecode", "code": "load(string.dump(function() end))()"},
]


# ---------------------------------------------------------------------------------------------- сессия
def _sid():
    return "s%s%03d" % (time.strftime("%H%M%S"), int(time.time() * 1000) % 1000)


def build_session(mk, info, args, log=None):
    """mk(kind, role, params) -> имя запущенной аренды; info(name) -> lease dict. -> {session, leases, timing}."""
    sid = args.get("session") or _sid()
    out = {"session": sid, "leases": {}, "timing": {}, "client_kind": args.get("client_kind", "bot")}
    log = log or (lambda s: None)

    def start(kind, role, params):
        t0 = time.time()
        name = mk(kind, role, dict(params, session=sid))
        out["leases"][role] = name
        out["timing"][role] = round(time.time() - t0, 2)
        log("olife session %s: %s %s ready in %.2f s" % (sid, role, name, out["timing"][role]))
        return name

    sb_port = 0
    if args.get("sandbox", True):
        # волна 3a: вид "sandbox" — настоящий olife-sandboxd; "sandbox_stub" — заглушка (бинарный контракт)
        sb = start(args.get("sandbox_kind", "sandbox"), "sandbox", dict(args.get("sandbox_params") or {}))  # + UX A3
        sb_port = info(sb)["ports"]["sb"]
    wp = {"ticks": int(args.get("ticks", 0)), "mode": args.get("world_mode", "--script"), "sandbox": sb_port}
    for k in ("view", "mobs", "scripted", "sandbox_proto", "secret"):
        if k in args:
            wp[k] = args[k]
    if args.get("world_opts"):                  # волна 4c: сетевой код мира (snap=..., inv=...)
        wp["opts"] = args["world_opts"]
    if sb_port and args.get("sandbox_kind", "sandbox") == "sandbox":   # UX A2: /limits -> set_limits (порт f2f)
        wp["opts"] = _a2().world_opts(wp.get("opts"), info(sb)["ports"].get("f2f"))
    if args.get("auth_ticket"):                 # UX B: /whitelist in the chat -> daemon (scope = gateway id of tickets)
        _o = getattr(info, "__self__", None)
        _lab = getattr(_o, "lab", _o)
        if _lab is not None and hasattr(_lab, "cfg"):
            wp["opts"] = _menu().world_opts(_lab, wp.get("opts"), "gw-" + sid)
    # волна 3c: world_kind "world_fake" (tools/olife/world_fake.py, без движка) — замеры шлюза; gateway_kind "gateway_rs"
    wk = args.get("world_kind", "world")
    world = start(wk, "world", wp if wk == "world" else {k: v for k, v in wp.items() if k == "secret"})
    game = info(world)["ports"]["game"]
    gport = None
    # волна 4b (olife_w4b.py): сервис билетов (auth_ticket) и копия паков с манифестом (packs_reload) — до шлюза
    x4b = _w4b().session_extra(info, args, sid, start, log) if args.get("auth_ticket") or args.get("packs_reload") \
        else {}
    if x4b:
        out["w4b"] = x4b["info"]
    if args.get("gateway", True):
        gwp = dict(args.get("gateway_params") or {}, upstream=game, **(x4b.get("gateway") or {}))
        if wk == "world":                       # UX A4: the world's store CAS over the gateway HTTP (GET /assets/<sha>)
            gwp.setdefault("assets_dir", assets_dir_of(info(world)))
            # clients learn the HTTP base from PacksChanged.url: a manifest of the live packs (per session, so the
            # clients — whose packs are junctions to the same content — find nothing to reload); opt-in: setup
            # "assets_http": true (other scenarios keep the gateway without PacksChanged, as before)
            if not gwp.get("packs_manifest") and args.get("assets_http"):
                gwp["packs_manifest"] = session_manifest(sid)
        gw = start(args.get("gateway_kind", "gateway"), "gateway", gwp)
        gport = info(gw)["ports"]["gw"]
    n = int(args.get("clients", 1))
    kind = out["client_kind"]
    target = gport or game
    for i in range(1, n + 1):
        cp = {"gateway": target, "name": "%s%d" % (kind, i), "ticks": int(args.get("client_ticks", 0))}
        for k in ("blocks", "walk", "token", "reconnect"):      # reconnect: UX A3 (world restart in the session)
            if k in args:
                cp[k] = args[k]
        if args.get("bot_opts"):                # волна 4c: move=predict, drops=N, radius=R (строка или список по клиентам)
            bo = args["bot_opts"]
            cp["opts"] = bo[min(i, len(bo)) - 1] if isinstance(bo, list) else bo
        if args.get("tokens") and i <= len(args["tokens"]):     # волна 4a: свой аккаунт каждому клиенту
            cp["token"] = args["tokens"][i - 1]
        cp.update(x4b.get("client") or {})                        # волна 4b: --auth/--gw-id/--auth-pub
        start(kind, "client%d" % i, cp)
    out["gateway_port"], out["game_port"] = gport, game
    return out


def session_manifest(sid):
    """UX A4: manifest of the live client packs for one session (artifacts\\lab\\olife\\manifests\\<sid>.json)"""
    from labcore import config, supervise
    out = os.path.join(config.VC_ROOT, "artifacts", "lab", "olife", "manifests", "%s.json" % sid)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    supervise.pack_manifest(os.path.join(config.VC_ROOT, "content"), CLIENT_PACKS, out)
    return out


def assets_dir_of(world_info, world_name="olife"):
    """UX A4: the CAS of the world's store (content/olife_world/modules/store.lua: world:olife_store/cas)"""
    return os.path.join(world_info["dir"], "worlds", world_name, "olife_store", "cas")


def session_leases(lab, sid, owner=None):
    with lab.lock:
        ls = [l for l in lab.leases.values() if l.params.get("session") == sid and (owner is None or
                                                                                    l.owner == owner)]
    roles = {}
    for l in ls:
        k = {"sandbox_stub": "sandbox", "gateway_rs": "gateway", "world_fake": "world", "gateway_rs_public": "gateway",
             "auth_public": "auth"}.get(l.kind, l.kind)
        roles[k if k in ORDER else "client:" + l.name] = l.name
    return roles


def f_session(ctx, args):
    args = dict(args)
    args.setdefault("session", _sid())
    ttl = args.get("ttl")

    def mk(kind, role, params):
        r = ctx.lease(kind, params=params, ttl=ttl)
        name = r["lease"]["name"]
        try:
            ctx.start(name)
        except Exception:
            ctx.release(name)
            raise
        return name
    try:
        return build_session(mk, ctx.info, args)
    except Exception:
        # не оставлять половину сессии: всё, что успели поднять, — освободить
        f_release(ctx, {"session": args["session"]})
        raise


def f_release(ctx, args):
    roles = session_leases(ctx.lab, args["session"], ctx.owner)
    order = [r for r in roles if r.startswith("client:")] + [r for r in ("sandbox", "gateway", "world") if r in roles]
    out = {}
    for r in order:
        try:
            rel = ctx.release(roles[r])
            out[roles[r]] = {"ok": True, "exit": rel.get("exit"), "forced_kill": rel.get("forced_kill"),
                             "run_dir": rel.get("run_dir")}
        except Exception as exc:
            out[roles[r]] = {"ok": False, "error": str(exc)}
    return {"session": args["session"], "released": out}


# ---------------------------------------------------------------------------------------------- состояния
def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return rows


def stats(v):
    if not v:
        return None
    s = sorted(v)
    q = lambda p: s[min(len(s) - 1, int(p * (len(s) - 1) + 0.5))]  # noqa: E731
    return {"n": len(s), "min": round(s[0], 3), "p50": round(q(0.5), 3), "p95": round(q(0.95), 3),
            "max": round(s[-1], 3), "mean": round(sum(s) / len(s), 3)}


def compare_states(world_rows, clients):
    """world_rows: [{tick, ts, hash}]; clients: {имя: [{tick, t_recv, ts, hash, server_hash}]} -> отчёт.
    Расхождение — hash реплики клиента != hash мира в том же такте (или такт клиента, которого у мира нет).
    Задержка такта — t_recv − ts мира (мс, одни часы машины). Пропуски — такты между первым и последним принятым."""
    w = {int(r["tick"]): r for r in world_rows if r.get("tick") is not None}
    w_last = max(w) if w else 0
    out = {"world_ticks": len(w), "world_last_tick": w_last, "clients": {}, "divergences": [], "compared": 0}
    all_lat = []
    for name, rows in sorted(clients.items()):
        got = {}
        for r in rows:
            if r.get("tick") is not None:
                got[int(r["tick"])] = r
        ticks = sorted(t for t in got if t <= w_last)       # мир сбрасывает файл раз в 10 тактов: хвост ещё не записан
        lat, div = [], []
        for t in ticks:
            r, wr = got[t], w.get(t)
            if wr is None:
                div.append({"client": name, "tick": t, "why": "tick absent on world"})
                continue
            # волна 2: мир пишет hash вида каждой сессии views[eid игрока]; реплика — свой hash (сущности + блоки)
            views = wr.get("views")
            if isinstance(views, dict) and r.get("eid") is not None:
                want = views.get(str(r["eid"]))
                if want is None:
                    div.append({"client": name, "tick": t, "why": "session absent on world", "eid": r["eid"]})
                elif r.get("hash") != want:
                    div.append({"client": name, "tick": t, "why": "replica hash", "client_hash": r.get("hash"),
                                "world_hash": want})
            elif r.get("hash") != wr.get("hash"):
                div.append({"client": name, "tick": t, "why": "replica hash", "client_hash": r.get("hash"),
                            "world_hash": wr.get("hash")})
            if r.get("t_recv") is not None and wr.get("ts") is not None:
                lat.append(float(r["t_recv"]) - float(wr["ts"]))
        missing = (ticks[-1] - ticks[0] + 1 - len(ticks)) if ticks else 0
        out["clients"][name] = {"received": len(got), "compared": len(ticks), "first": ticks[0] if ticks else None,
                                "last": ticks[-1] if ticks else None, "missing": missing, "divergences": len(div),
                                "latency_ms": stats(lat)}
        out["divergences"] += div
        out["compared"] += len(ticks)
        all_lat += lat
    out["latency_ms"] = stats(all_lat)
    out["divergence_count"] = len(out["divergences"])
    out["divergences"] = out["divergences"][:50]
    return out


def collect(lab, roles):
    """Файлы состояний сессии: export\\world_states.jsonl мира, export\\client_states.jsonl клиентов."""
    world = roles.get("world")
    wdir = lab.lease_info(world)["dir"]
    clients = {}
    for r, name in roles.items():
        if r.startswith("client"):
            ex = os.path.join(lab.lease_info(name)["dir"], "export")
            clients[name] = read_jsonl(os.path.join(ex, "client_states.jsonl"))
            i = 1                                 # волна 4b: части после reopen_world (перезагрузка паков)
            while os.path.exists(os.path.join(ex, "client_states_r%d.jsonl" % i)):
                clients[name] += read_jsonl(os.path.join(ex, "client_states_r%d.jsonl" % i))
                i += 1
    return read_jsonl(os.path.join(wdir, "export", "world_states.jsonl")), clients


def _client_roles(roles):
    return {r: n for r, n in roles.items() if r.startswith("client")}


def consistency(lab, roles, gateway_metrics=None):
    w, cl = collect(lab, roles)
    rep = compare_states(w, cl)
    if gateway_metrics:
        rep["gateway"] = {"total": gateway_metrics.get("total"), "rtt_ms": gateway_metrics.get("rtt_ms"),
                          "conns": len(gateway_metrics.get("conns") or {}), "errors": gateway_metrics.get("errors"),
                          "world_to_gateway_ms": gateway_metrics.get("world_to_gateway_ms"),
                          "rejects": gateway_metrics.get("rejects")}
    return rep


def f_consistency(ctx, args):
    roles = session_leases(ctx.lab, args["session"], ctx.owner)
    gm = ctx.call(roles["gateway"], "metrics") if "gateway" in roles else None
    return consistency(ctx.lab, roles, gm)


def f_status(ctx, args):
    roles = session_leases(ctx.lab, args["session"], ctx.owner)
    out = {"leases": roles}
    if "world" in roles:
        r = ctx.lab.stdin(roles["world"], "status", owner=ctx.owner, wait=3.0, pattern=r"status tick=")
        out["world"] = [x for x in r["lines"] if "olife_world" in x or "stdin-cmd" in x][-5:]
    if "gateway" in roles:
        out["gateway"] = ctx.call(roles["gateway"], "metrics")
    if "sandbox" in roles:
        out["sandbox"] = ctx.call(roles["sandbox"], "stats")
    return out


# ---------------------------------------------------------------------------------------------- негативные
def sandbox_probe(lab, call, lease, attempts=None, budget_ms=500.0):
    """Попытки выхода из песочницы: каждая — exec с кодом, ссылающимся на файл-канарейку в каталоге экземпляра.
    Проходит, если: ответ — отказ или без эффектов; канарейки нет; ответ в бюджете; песочница жива после всех."""
    d = lab.lease_info(lease)["dir"]
    res = []
    for i, a in enumerate(attempts or DEFAULT_ATTEMPTS):
        canary = os.path.join(d, "canary_%02d_%s" % (i, a["name"]))
        code = a["code"].replace("{canary}", canary.replace("\\", "/"))
        t0 = time.time()
        err = None
        try:
            r = call(lease, "exec", {"owner": "probe", "code": code, "fuel": int(a.get("fuel", 100000))})
        except Exception as exc:
            r, err = None, "%s: %s" % (type(exc).__name__, exc)
        ms = (time.time() - t0) * 1000.0
        denied = bool(r and (r.get("denied") or not r.get("effects")))
        leaked = os.path.exists(canary)
        ok = err is None and denied and not leaked and ms <= float(a.get("budget_ms", budget_ms))
        res.append({"name": a["name"], "ok": ok, "denied": denied, "canary_created": leaked, "ms": round(ms, 2),
                    "error": err, "reply": r})
    alive = None
    try:
        alive = bool(call(lease, "hello", {}))
    except Exception as exc:
        alive = False
        res.append({"name": "alive_after", "ok": False, "error": str(exc)})
    return {"attempts": len(res), "passed": sum(1 for x in res if x["ok"]), "alive_after": alive, "results": res,
            "note": "sandbox is a placeholder (no runtime): this proves the harness, not the sandbox"}


def f_sandbox_probe(ctx, args):
    lease = args.get("lease") or session_leases(ctx.lab, args["session"], ctx.owner)["sandbox"]
    return sandbox_probe(ctx.lab, ctx.call, lease, args.get("attempts"), float(args.get("budget_ms", 500)))


# ---------------------------------------------------------------------------------------------- сценарии
def sc_info(scn):
    return {"session": (scn.setup or {}).get("session") or {}}


def sc_start(sx):
    args = dict((sx.scn.setup or {}).get("session") or {})
    if args.get("public_play"):                 # olife_friends: публичный стек (сухой) + клиенты-друзья шагами
        return _pub().sc_start(sx, args)
    if args.get("play"):                        # путь игрока (olife_play.py): сухой прогон lab play olife --dry-run
        return _play().sc_start(sx, args)
    if args.get("supervise"):                   # этап 6: сессия под supervisor (olife_restart)
        def create(kind, role, params):
            return sx.lease(kind, role=role, params=params, start=False)
        s = build_supervised(sx.lab, sx.owner, args, create, log=sx.log)
        sx.data["session"] = s
        sx.data["group"] = s["group"]
        sx.data["metrics"] = {}
        sx.client = s["leases"]["world"]
        return

    def mk(kind, role, params):
        return sx.lease(kind, role=role, params=params)
    if sx.impl == "rs":                         # волна 3c: lab run olife <сценарий> --impl rs -> Rust-шлюз
        args.setdefault("gateway_kind", "gateway_rs")
    s = build_session(mk, sx.lab.lease_info, args, log=sx.log)
    sx.data["session"] = s
    sx.data["metrics"] = {}
    sx.client = s["leases"]["world"]


def _roles(sx):
    return dict(sx.data["session"]["leases"])


def st_run(sx, args, step):
    """Подождать seconds, проверяя, что все процессы сессии живы (смерть — ошибка шага с кодом выхода)."""
    end = time.time() + float(args.get("seconds", 5))
    while time.time() < end:
        for role, name in _roles(sx).items():
            p = sx.lab.leases[name].proc
            if p is not None and not p.alive() and not (role.startswith("client") and args.get("clients_may_exit")):
                return {"ok": False, "error": "%s %s died: %s" % (role, name, p.info().get("exit")), "fatal": "dead"}
        if sx.cancelled:
            return {"ok": False, "error": "cancelled"}
        time.sleep(0.25)
    return {"ok": True, "result": {"seconds": args.get("seconds", 5)}}


def st_stdin(sx, args, step):
    lease = _roles(sx)[args.get("role", "world")]
    r = sx.lab.stdin(lease, args["cmd"], owner=sx.owner, wait=float(args.get("wait", 3)), pattern=args.get("pattern"))
    ok = r["matched"] is not False
    return {"ok": ok, "result": {"lines": r["lines"][-6:], "matched": r["matched"], "poke": r.get("poke")},
            "error": None if ok else "no /%s/ after %s" % (args.get("pattern"), args["cmd"])}


def st_consistency(sx, args, step):
    roles = _roles(sx)
    gm = sx.call("metrics", lease=roles["gateway"]) if "gateway" in roles else None
    rep = consistency(sx.lab, roles, gm)
    with open(os.path.join(sx.out_dir(), "olife_consistency.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    sx.data["metrics"]["consistency"] = {
        "world_ticks": rep["world_ticks"], "compared": rep["compared"], "divergences": rep["divergence_count"],
        "latency_ms": rep["latency_ms"], "missing": sum(c["missing"] for c in rep["clients"].values()),
        "bytes_down": ((rep.get("gateway") or {}).get("total") or {}).get("down"),
        "bytes_up": ((rep.get("gateway") or {}).get("total") or {}).get("up"),
        "gateway_rtt_ms": (rep.get("gateway") or {}).get("rtt_ms"),
        "world_to_gateway_ms": (rep.get("gateway") or {}).get("world_to_gateway_ms")}
    bad = []
    if rep["divergence_count"] > int(args.get("max_divergences", 0)):
        bad.append("divergences %d > %d" % (rep["divergence_count"], int(args.get("max_divergences", 0))))
    for name, c in rep["clients"].items():
        if c["compared"] < int(args.get("min_ticks", 1)):
            bad.append("%s compared %d ticks < %d" % (name, c["compared"], int(args.get("min_ticks", 1))))
    if not rep["clients"] and int(args.get("min_clients", 1)):
        bad.append("no clients")
    summary = dict(sx.data["metrics"]["consistency"], clients={n: {k: c[k] for k in ("compared", "divergences",
                                                                                       "missing")}
                                                               for n, c in rep["clients"].items()})
    return {"ok": not bad, "result": summary, "error": "; ".join(bad) or None}


def st_sandbox(sx, args, step):
    lease = _roles(sx)["sandbox"]
    rep = sandbox_probe(sx.lab, lambda l, c, a: sx.call(c, a, lease=l), lease, args.get("attempts"),
                        float(args.get("budget_ms", 500)))
    with open(os.path.join(sx.out_dir(), "olife_negative.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    sx.data["metrics"]["negative"] = {"attempts": rep["attempts"], "passed": rep["passed"],
                                      "alive_after": rep["alive_after"]}
    ok = rep["passed"] == rep["attempts"] and rep["alive_after"]
    return {"ok": ok, "result": sx.data["metrics"]["negative"],
            "error": None if ok else "failed: %s" % [x["name"] for x in rep["results"] if not x["ok"]]}


def st_metrics(sx, args, step):
    roles = _roles(sx)
    out = {}
    if "gateway" in roles:
        out["gateway"] = sx.call("metrics", lease=roles["gateway"])
    if "sandbox" in roles:
        out["sandbox"] = sx.call("stats", lease=roles["sandbox"])
    sx.data["metrics"]["gateway_total"] = (out.get("gateway") or {}).get("total")
    return {"ok": True, "result": {"gateway_total": (out.get("gateway") or {}).get("total"),
                                   "gateway_rtt_ms": (out.get("gateway") or {}).get("rtt_ms"),
                                   "sandbox": out.get("sandbox")}}


def _kv(line):
    """'... key=val key2=val2 ...' -> dict (числа — числами)"""
    out = {}
    for tok in line.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                out[k] = float(v) if "." in v else int(v)
            except ValueError:
                out[k] = v
    return out


def _status(sx, role, marker):
    lease = _roles(sx)[role]
    r = sx.lab.stdin(lease, "status", owner=sx.owner, wait=3.0, pattern=marker.replace(" ", r"\s"))
    lines = [x for x in r["lines"] if marker in x]
    return _kv(lines[-1]) if lines else {}


def st_world_status(sx, args, step):
    """status мира (stdin) и каждого бота -> метрики (такты, байты, фазы, отказы, self_div реплик)."""
    w = _status(sx, "world", "status tick=")
    bots = {}
    for role, name in _roles(sx).items():
        if role.startswith("client") and sx.lab.leases[name].kind == "bot":
            bots[name] = _status(sx, role, "status name=")
    sx.data["metrics"]["world_status"] = w
    sx.data["metrics"]["bots"] = {n: {k: b.get(k) for k in ("syncs", "self_div", "chunks_rx", "verified",
                                                           "verify_diff", "blocks", "ok", "mismatch", "rejects",
                                                           "corrections", "bytes_in", "bytes_out", "state")}
                                  for n, b in bots.items()}
    bad = [n for n, b in bots.items() if b.get("self_div") or b.get("verify_diff") or b.get("mismatch")
           or b.get("state") != "play"]
    ok = bool(w) and (not args.get("strict", True) or not bad)
    return {"ok": ok, "result": {"world": {k: w.get(k) for k in ("tick", "tps", "sessions", "entities", "bytes_in",
                                                                 "bytes_out", "chunks_sent", "blocks_ok", "kicks",
                                                                 "bad_frames", "sandbox")},
                                 "bots": sx.data["metrics"]["bots"]},
            "error": None if ok else "world status missing or bots not clean: %s" % bad}


def st_quiet(sx, args, step):
    """боты прекращают действия с блоками (olife.quiet), пауза — чтобы последние BlockUpdate дошли"""
    for role, name in _roles(sx).items():
        if role.startswith("client") and sx.lab.leases[name].kind == "bot":
            sx.lab.stdin(name, "olife.quiet", owner=sx.owner, wait=1.0, pattern=r"quiet")
    time.sleep(float(args.get("seconds", 1.5)))
    return {"ok": True, "result": {"quiet": True}}


def st_blocks(sx, args, step):
    """olife_blocks: мир пишет все изменённые позиции и что там сейчас (olife.dump_blocks), лаборатория копирует файл
    каждому боту, бот сравнивает со своим миром (olife.check_blocks). Ок: расхождений 0, проверено >= min_blocks."""
    import shutil
    roles = _roles(sx)
    r = sx.lab.stdin(roles["world"], "olife.dump_blocks", owner=sx.owner, wait=3.0, pattern=r"dump_blocks n=")
    wdir = sx.lab.lease_info(roles["world"])["dir"]
    src = os.path.join(wdir, "export", "blocks_world.json")
    time.sleep(0.3)
    try:
        with open(src, encoding="utf-8") as f:
            world_dump = json.load(f)
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": "no world dump: %s" % exc}
    rep = {"world_blocks": len(world_dump.get("blocks") or []), "world_tick": world_dump.get("tick"), "bots": {}}
    for role, name in roles.items():
        if not role.startswith("client") or sx.lab.leases[name].kind != "bot":
            continue
        d = sx.lab.lease_info(name)["dir"]
        shutil.copyfile(src, os.path.join(d, "export", "blocks_check.json"))
        sx.lab.stdin(name, "olife.check_blocks", owner=sx.owner, wait=3.0, pattern=r"check_blocks")
        time.sleep(0.2)
        try:
            with open(os.path.join(d, "export", "blocks_bot.json"), encoding="utf-8") as f:
                rep["bots"][name] = json.load(f)
        except (OSError, ValueError) as exc:
            rep["bots"][name] = {"error": str(exc)}
    with open(os.path.join(sx.out_dir(), "olife_blocks.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    summary = {"world_blocks": rep["world_blocks"], "bots": {n: {k: b.get(k) for k in ("checked", "match", "mismatch",
                                                                                     "unloaded", "error")}
                                                          for n, b in rep["bots"].items()}}
    sx.data["metrics"]["blocks"] = summary
    bad = []
    if rep["world_blocks"] < int(args.get("min_blocks", 1)):
        bad.append("world changed only %d blocks < %d" % (rep["world_blocks"], int(args.get("min_blocks", 1))))
    for n, b in rep["bots"].items():
        if b.get("error") or b.get("mismatch") or b.get("unloaded") or b.get("checked") != rep["world_blocks"]:
            bad.append("%s: %s" % (n, {k: b.get(k) for k in ("checked", "mismatch", "unloaded", "error")}))
    if not rep["bots"]:
        bad.append("no bots")
    return {"ok": not bad, "result": summary, "error": "; ".join(bad) or None}


def st_negative_proto(sx, args, step):
    """негативные тесты протокола (tools/olife/negative.py) против шлюза и мира; затем мир и шлюз живы"""
    import importlib
    import sys
    tools = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "olife"))
    if tools not in sys.path:
        sys.path.insert(0, tools)
    neg = importlib.import_module("negative")
    roles = _roles(sx)
    gw_port = sx.lab.lease_info(roles["gateway"])["ports"]["gw"]
    w_port = sx.lab.lease_info(roles["world"])["ports"]["game"]
    rep = neg.run(gw_port, w_port if args.get("world", True) else None)
    alive = {}
    r = sx.lab.stdin(roles["world"], "status", owner=sx.owner, wait=3.0, pattern=r"status tick=")
    alive["world"] = bool(r["matched"])
    try:
        alive["gateway"] = bool(sx.call("metrics", lease=roles["gateway"]))
    except Exception as exc:
        alive["gateway"] = False
        alive["gateway_error"] = str(exc)
    for role, name in roles.items():
        p = sx.lab.leases[name].proc
        alive[role + "_proc"] = p is not None and p.alive()
    rep["alive_after"] = alive
    with open(os.path.join(sx.out_dir(), "olife_negative_proto.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    sx.data["metrics"]["negative_proto"] = {"tests": rep["tests"], "passed": rep["passed"],
                                            "table": [{k: x.get(k) for k in ("name", "ok", "want_code", "got_code",
                                                                              "ms")} for x in rep["results"]],
                                            "alive_after": alive}
    ok = rep["passed"] == rep["tests"] and all(v for k, v in alive.items() if not k.endswith("_error"))
    return {"ok": ok, "result": {"tests": rep["tests"], "passed": rep["passed"], "alive_after": alive},
            "error": None if ok else "failed: %s" % [x["name"] for x in rep["results"] if not x.get("ok")]}


def sc_stop(sx):
    """Освобождение сессии сценария в порядке клиенты -> песочница -> шлюз -> мир (каждый — своим мягким стопом), чтобы
    клиенты останавливались командой, а не обрывом соединения; ядро потом освобождает то, что осталось (мир)."""
    if sx.data.get("public"):                   # olife_friends: клиенты -> коляска -> тестовые записи
        return _pub().sc_stop(sx)
    if sx.data.get("play"):                     # путь игрока: клиент -> коляска (olife.play_down) -> отчёт игры
        return _play().sc_stop(sx)
    try:
        _w4b().on_stop(sx)                      # волна 4b: убрать тарифы limits.*, поставленные сценарием
    except Exception as exc:
        sx.data.setdefault("metrics", {})["w4b_stop_error"] = str(exc)
    if sx.opts.get("keep"):
        return
    roles = dict(sx.leases)
    order = sorted(r for r in roles if r.startswith("client")) + [r for r in ("sandbox", "gateway") if r in roles]
    if sx.data.get("group"):                    # supervisor: снять наблюдение, стоп в обратном порядке старта
        try:
            g = sx.lab.sup.get(sx.data["group"])
            sx.data.setdefault("metrics", {}).setdefault("supervisor", {})["timeline"] = list(g.timeline)
            sx.lab.sup.down(sx.data["group"], sx.owner, release=False)
        except Exception as exc:
            sx.data.setdefault("metrics", {}).setdefault("supervisor", {})["down_error"] = str(exc)
        order = sorted(r for r in roles if r.startswith("client")) + [r for r in ("gateway", "sandbox") if r in roles]
    res = {}
    for r in order:
        try:
            rel = sx.lab.release(roles[r], owner=sx.owner, reason="scenario-end")
            res[roles[r]] = {"exit": rel.get("exit"), "forced_kill": rel.get("forced_kill"),
                             "stop": [st.get("step") for st in rel.get("steps") or []]}
        except Exception as exc:
            res[roles[r]] = {"error": str(exc)}
        sx.leases.pop(r, None)
    sx.data.setdefault("metrics", {})["release"] = res


def sc_finish(sx):
    fd = sx.data.get("fraud")
    if fd and not fd.get("cleaned"):            # antifraud: test bans/accounts never outlive a failed scenario
        try:
            _fraud().reset_test(sx.lab, fd["ips"], fd["accounts"], fd["keys"])
            fd["cleaned"] = "finish"
        except Exception as exc:                # noqa: BLE001
            fd["cleaned"] = "finish failed: %s" % exc
    s = sx.data.get("session") or {}
    return {"olife": True, "session": s.get("session"), "leases": s.get("leases"), "start_s": s.get("timing"),
            "group": s.get("group"), "metrics": sx.data.get("metrics")}


# ============================================================================================== этап 6: supervisor
# Ядро — labcore/supervise.py (lab.sup): службы поверх аренд, health, перезапуск с бэкоффом, инциденты, БД, панель.
# Здесь — только Olife: состав и порядок служб (мир -> песочница -> шлюз; стоп обратный), проверки здоровья, зависимости
# (песочница перезапущена -> миру `sandbox_reconnect`; мир упал -> шлюз закрывает сессии с причиной «world restarting»,
# боты с --reconnect возвращаются), снимок перед смертью (export\sup_state_{a,b}.json мира: кольцо 256 входящих кадров,
# последний TickResult), учёт по аккаунтам (шлюз: байты/пакеты; мир: действия, сущности; песочница: топливо) и тарифы.
SUP_PREFIX = "olife-"
INTERNAL_NAMES = {1: "GatewayHello", 2: "WorldHello", 3: "Attach", 4: "Detach", 5: "Data", 6: "Multicast", 7: "Ping",
                  8: "Pong", -1: "bad-frame"}
CLIENT_NAMES = {1: "Hello", 2: "KeepAliveReply", 3: "PlayerInput", 4: "BlockAction", 5: "ChatSend", 6: "Bye"}
WORLD_HEALTH = [{"stdin": "status", "pattern": r"status tick=", "timeout": 3}, {"port": "game"}]
SANDBOX_HEALTH = [{"f2f": "hello", "timeout": 3}, {"f2f": "stats", "timeout": 3}]
GATEWAY_HEALTH = [{"f2f": "hello", "timeout": 3}, {"port": "gw"}]
TARIFFS = {"credits.per_kb_down": 0.01, "credits.per_kb_up": 0.02, "credits.per_packet": 0.001,
           "credits.per_action": 0.1, "credits.per_kfuel": 1.0, "credits.per_sandbox_action": 0.05,
           "credits.per_entity_minute": 0.5,
           "credits.per_store_credit": 0.1}       # UX A4: store credits (KV/asset writes, canvas) -> account credits
CLIENT_PACKS = {"olife_client": "client", "olife_proto": "both"}


def _tools_olife(lab):
    from labcore import config
    return os.path.join(config.VC_ROOT, "tools", "olife")


def seed_db(sup, bots=0):
    """Аккаунты и баны dev-шлюза (tools/olife/gateway_*.json) -> БД supervisor (только отсутствующие); bot<i> —
    свой аккаунт и токен olife-bot<i> на каждого бота (учёт по аккаунтам)."""
    db = sup.db
    have = {a["name"] for a in db.accounts()}
    d = os.path.join(_tools_olife(sup.lab))
    try:
        with open(os.path.join(d, "gateway_tokens.json"), encoding="utf-8") as f:
            toks = json.load(f).get("tokens") or {}
    except (OSError, ValueError):
        toks = {}
    for tok, acct in toks.items():
        if acct not in have:
            db.add_account(acct, tok, "dev" if acct != "bots" else "bot", note="seed: gateway_tokens.json")
            have.add(acct)
    for i in range(1, int(bots) + 1):
        if "bot%d" % i not in have:
            db.add_account("bot%d" % i, "olife-bot%d" % i, "bot", note="seed: olife.up")
    try:
        with open(os.path.join(d, "gateway_bans.json"), encoding="utf-8") as f:
            bans = json.load(f)
    except (OSError, ValueError):
        bans = {}
    known = {(r["kind"], r["value"]) for r in db._rows("SELECT kind, value FROM bans")}
    for a in bans.get("accounts") or []:
        if ("account", a) not in known:
            db.ban("account", a, 0, "seed: gateway_bans.json", "seed")
    for ip in bans.get("ips") or []:
        if ("ip", ip) not in known:
            db.ban("ip", ip, 0, "seed: gateway_bans.json", "seed")
    db.seed_tariffs(TARIFFS)


def manifest_path(lab):
    return os.path.join(lab.data, "olife", "packs_manifest.json")


def make_manifest(lab):
    from labcore import config, supervise
    return supervise.pack_manifest(os.path.join(config.VC_ROOT, "content"), CLIENT_PACKS, manifest_path(lab))


def read_world_state(wdir):
    """export\\sup_state_{a,b}.json мира -> (самый свежий целый, [пути]). Запись чередуется: убийство посреди записи
    портит не больше одного файла."""
    best, paths = None, []
    for x in ("a", "b"):
        pth = os.path.join(wdir, "export", "sup_state_%s.json" % x)
        try:
            with open(pth, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        paths.append(pth)
        if best is None or (d.get("ms") or 0) > (best.get("ms") or 0):
            best = d
    return best, paths


def named_frames(st):
    out = []
    for fr in (st or {}).get("journal") or []:
        fr = list(fr) + [None] * (8 - len(fr))
        tick, gw, sess, typ, ctype, size, ms, err = fr[:8]
        out.append({"tick": tick, "gw": gw, "session": None if sess == -1 else sess, "type": typ,
                    "type_name": INTERNAL_NAMES.get(typ, str(typ)), "ctype": None if ctype in (-1, None) else ctype,
                    "ctype_name": CLIENT_NAMES.get(ctype) if ctype not in (-1, None) else None, "size": size,
                    "ms": ms, "err": err})
    return out


class OlifeHooks:
    """Хуки группы для lab.sup (ядро зовёт: started, died, capture, poll)."""

    def __init__(self, args):
        self.args = dict(args)
        self.last = {}               # счётчики с прошлого опроса: (источник, старт процесса, ключ) -> значения
        self.saved_t = time.time()
        self.storage_t = 0

    # ---------------------------------------------------------------- зависимости
    def started(self, sup, svc, restart):
        g, lab = svc.group, sup.lab
        if svc.role == "sandbox" and "world" in g.services and g.services["world"].state == "up":
            r = lab.stdin(g.services["world"].lease, "sandbox_reconnect", owner=g.owner, wait=3.0,
                          pattern=r"sandbox_reconnect queued")
            sup._event(g, "world", g.services["world"].lease, "dependency",
                       "sandbox %s -> world sandbox_reconnect (%s)" % ("restarted" if restart else "started",
                                                                      "ok" if r.get("matched") else "no reply"))
        if svc.role == "gateway":
            lab.f2f_quiet(svc.lease, "world_status", {"supervised": True, "note": ""}, timeout=3, owner=g.owner)
        if svc.role == "world":                 # UX A1: друзья/настройки аккаунтов БД -> мир (и события прошлого запуска -> БД)
            try:
                sup._event(g, "world", svc.lease, "friends_sync", _a1().world_started(sup, svc))
            except Exception as exc:
                sup._event(g, "world", svc.lease, "friends_sync", "error %s: %s" % (type(exc).__name__, exc))
        if svc.role == "world" and restart and "gateway" in g.services:
            lab.f2f_quiet(g.services["gateway"].lease, "world_status", {"note": ""}, timeout=3, owner=g.owner)
            sup._event(g, "gateway", g.services["gateway"].lease, "dependency",
                       "world restarted -> gateway reconnects to the same port; clients with --reconnect rejoin")

    def died(self, sup, svc, inc):
        g, lab = svc.group, sup.lab
        if svc.role == "world" and "gateway" in g.services and g.services["gateway"].state == "up":
            try:
                lab.f2f_quiet(g.services["gateway"].lease, "world_status", {"note": "incident " + inc["id"]},
                              timeout=3, owner=g.owner)
            except Exception:
                pass
            sup._event(g, "gateway", g.services["gateway"].lease, "dependency",
                       "world died -> sessions closed with 'world restarting' (no hold message in the client contract)")
        if svc.role == "sandbox":
            sup._event(g, "world", g.services.get("world").lease if "world" in g.services else None, "dependency",
                       "sandbox died -> world keeps ticking, scripted entities frozen until the restart")

    # ---------------------------------------------------------------- снимок при смерти
    def capture(self, sup, svc, d):
        import shutil
        g, lab = svc.group, sup.lab
        out = {"files": {}}
        wsvc = g.services.get("world")
        st = None
        if wsvc is not None:
            wdir = lab.leases[wsvc.lease].dir if wsvc.lease in lab.leases else None
            if wdir:
                st, paths = read_world_state(wdir)
                for pth in paths:
                    shutil.copyfile(pth, os.path.join(d, os.path.basename(pth)))
                    out["files"][os.path.basename(pth)] = "world supervisor state file (raw)"
        if st:
            frames = named_frames(st)
            age = round(time.time() - (st.get("ms") or 0) / 1000.0, 2)
            with open(os.path.join(d, "journal.json"), "w", encoding="utf-8") as f:
                json.dump({"world_tick": st.get("tick"), "state_age_s": age, "journal_total": st.get("journal_total"),
                           "frames": frames}, f, ensure_ascii=False, indent=1)
            with open(os.path.join(d, "journal.txt"), "w", encoding="utf-8") as f:
                f.write("# last %d incoming frames of the world (oldest first), world tick %s, state written %.2f s "
                        "before the capture\n" % (len(frames), st.get("tick"), age))
                f.write("tick   gw session type         client-type     size  err\n")
                for x in frames:
                    f.write("%-6s %-2s %-7s %-12s %-15s %-5s %s\n" % (x["tick"], x["gw"], x["session"], x["type_name"],
                                                                    x["ctype_name"] or "", x["size"], x["err"] or ""))
            out["files"]["journal.json"] = "last %d incoming frames (session, type, client type, size, tick)" % len(frames)
            out["files"]["journal.txt"] = "same, as a table"
            last = frames[-1] if frames else None
            sb = st.get("sandbox") or {}
            out.update(world_tick=st.get("tick"), state_age_s=age, journal_frames=len(frames),
                       journal_total=st.get("journal_total"), last_frame=last, players=st.get("players"),
                       sandbox_world_side={k: sb.get(k) for k in ("state", "results", "applied", "rejected", "fuel",
                                                                  "last_result_tick", "last_result", "last_error")})
            out["summary"] = "journal %d frames (total %s), last: tick %s session %s %s/%s %s B; state %.1f s old; " \
                             "players %d; sandbox last TickResult tick %s" % (
                                 len(frames), st.get("journal_total"), last and last["tick"], last and last["session"],
                                 last and last["type_name"], last and last["ctype_name"], last and last["size"], age,
                                 len(st.get("players") or []), sb.get("last_result_tick"))
        else:
            out["summary"] = "no world supervisor state file (journal_every = 0?)"
        sbs = g.services.get("sandbox")
        if sbs is not None:
            out["sandbox_service_last_stats"] = sbs.last_info.get("stats")
        gws = g.services.get("gateway")
        if gws is not None and svc.role == "gateway":
            out["gateway_last_metrics"] = (g.poll_data or {}).get("gateway")
        return out

    # ---------------------------------------------------------------- опрос: панель + учёт
    def _delta(self, key, cur):
        prev = self.last.get(key) or {}
        self.last[key] = dict(cur)
        return {k: max(0, (v or 0) - (prev.get(k) or 0)) for k, v in cur.items()}

    def poll(self, sup, g):
        lab, db = sup.lab, sup.db
        out = {}
        acc = {}                                  # account -> deltas this poll

        def add(a, **kw):
            d = acc.setdefault(a, {})
            for k, v in kw.items():
                d[k] = d.get(k, 0) + (v or 0)
        tariffs = db.tariffs()
        wsvc = g.services.get("world")
        if wsvc is not None and wsvc.lease in lab.leases:
            wl = lab.leases[wsvc.lease]
            st, _ = read_world_state(wl.dir)
            if st and wsvc.state == "up":
                out["world"] = {k: st.get(k) for k in ("tick", "entities", "scripted", "sessions", "tick_ms",
                                                       "journal_total", "uptime_s", "entities_by_owner")}
                out["world"]["state_age_s"] = round(time.time() - (st.get("ms") or 0) / 1000.0, 1)
                out["players"] = st.get("players") or []
                out["ops"] = st.get("ops")             # UX A2: players/mobs/bans/audit for the panel's op buttons
                out["sandbox"] = st.get("sandbox")
                out["journal"] = named_frames(st)[-40:]
                aa = st.get("acct_actions") or {}
                if isinstance(aa, dict):
                    for a, n in aa.items():
                        add(a, **self._delta(("w", wsvc.lease, wl.starts, a), {"actions": n}))
                for o, m in ((st.get("sandbox") or {}).get("owners") or {}).items() if isinstance(
                        (st.get("sandbox") or {}).get("owners"), dict) else []:
                    dd = self._delta(("sb", wsvc.lease, wl.starts, o), {"fuel": m.get("fuel"),
                                                                       "sandbox_actions": m.get("actions")})
                    add("owner:%s" % o, **dd)
                ebo = st.get("entities_by_owner") or {}
                if isinstance(ebo, dict):
                    for o, n in ebo.items():
                        db.set_counters("owner:%s" % o, {"entities": n})
                        add("owner:%s" % o, entity_minutes=n * g.poll_s / 60.0)
                try:                                  # UX A4: хранилище по аккаунтам -> storage/store_*; тарифы store.*
                    a4 = _a4().poll_store(self, sup, g, wsvc, wl, st, add, tariffs)
                    if a4:
                        out["store"] = a4
                except Exception as exc:
                    out["store_error"] = "%s: %s" % (type(exc).__name__, exc)
            # автосохранение: перезапуск поднимает мир с последнего сохранения (ARCHITECTURE §2 «Падение»)
            every = float(self.args.get("autosave_s", 30))
            if every > 0 and time.time() - self.saved_t > every and wsvc.state == "up":
                self.saved_t = time.time()
                try:
                    lab.stdin(wsvc.lease, "save", owner=g.owner, wait=0.5, journal=False)
                except Exception:
                    pass
            if time.time() - self.storage_t > 30:
                self.storage_t = time.time()
                size = 0
                for dp, _, fns in os.walk(os.path.join(wl.dir, "worlds")):
                    for fn in fns:
                        try:
                            size += os.path.getsize(os.path.join(dp, fn))
                        except OSError:
                            pass
                db.set_counters("_world", {"storage": size})
        gsvc = g.services.get("gateway")
        if gsvc is not None and gsvc.state == "up" and gsvc.lease in lab.leases:
            gl = lab.leases[gsvc.lease]
            rep = lab.f2f_quiet(gsvc.lease, "metrics", {}, timeout=3, owner=g.owner)
            m = rep.get("result") if rep.get("ok") else None
            if m:
                out["gateway"] = {k: m.get(k) for k in ("auth", "connections", "auth_ok", "total", "rejects", "packs",
                                                        "world", "supervised", "world_note", "rtt_ms")}
                out["gateway"]["sessions"] = len(m.get("sessions") or {})
                for sid_, c in (m.get("sessions") or {}).items():
                    dd = self._delta(("g", gsvc.lease, gl.starts, sid_), {"bytes_up": c.get("up"),
                                                                         "bytes_down": c.get("down"),
                                                                         "packets_up": c.get("up_msgs"),
                                                                         "packets_down": c.get("down_msgs")})
                    add(c.get("account") or "?", **dd)
        ssvc = g.services.get("sandbox")
        if ssvc is not None:
            out["sandbox_service"] = ssvc.last_info.get("stats")
        # тариф: кредиты по таблице (меняется без перезапуска: читается каждый опрос)
        for a, d in acc.items():
            cr = (d.get("bytes_down", 0) / 1024.0 * tariffs.get("credits.per_kb_down", 0)
                  + d.get("bytes_up", 0) / 1024.0 * tariffs.get("credits.per_kb_up", 0)
                  + (d.get("packets_up", 0) + d.get("packets_down", 0)) * tariffs.get("credits.per_packet", 0)
                  + d.get("actions", 0) * tariffs.get("credits.per_action", 0)
                  + d.get("fuel", 0) / 1000.0 * tariffs.get("credits.per_kfuel", 0)
                  + d.get("sandbox_actions", 0) * tariffs.get("credits.per_sandbox_action", 0)
                  + d.get("entity_minutes", 0) * tariffs.get("credits.per_entity_minute", 0)
                  + d.get("store_credits", 0) * tariffs.get("credits.per_store_credit", 0))       # UX A4
            d.pop("entity_minutes", None)
            d["credits"] = cr
            db.add_counters(a, d)
        out["metered"] = {a: {k: round(v, 3) for k, v in d.items() if v} for a, d in acc.items()}
        try:                                      # UX A1: события дружбы мира -> БД supervisor
            fr = _a1().poll(sup, g)
            if fr:
                out["friends_sync"] = fr
        except Exception as exc:
            out["friends_error"] = "%s: %s" % (type(exc).__name__, exc)
        try:                                      # волна 4b: тарифы limits.* -> set_limits песочнице группы
            lim = _w4b().poll_limits(sup, g)
            if lim:
                out["limits_pushed"] = lim
        except Exception as exc:
            out["limits_error"] = "%s: %s" % (type(exc).__name__, exc)
        return out


def build_supervised(lab, owner, args, create, log=None):
    """Сессия olife под supervisor: аренды создаются сразу (порты известны), старт мир -> песочница (+ миру
    sandbox_reconnect) -> шлюз (токены/баны из БД, раздача паков) -> клиенты (--reconnect). -> как build_session."""
    log = log or (lambda s: None)
    sup = lab.sup
    sid = args.get("session") or _sid()
    group = SUP_PREFIX + sid
    n = int(args.get("clients", 2))
    kind = args.get("client_kind", "bot")
    seed_db(sup, n)
    mpath = manifest_path(lab)
    if not os.path.exists(mpath) or args.get("manifest", True) == "refresh":
        make_manifest(lab)
    out = {"session": sid, "group": group, "leases": {}, "timing": {}, "client_kind": kind}
    made = []

    def mk(kind_, role, params):
        name = create(kind_, role, dict(params, session=sid))
        made.append(name)
        out["leases"][role] = name
        return name
    g = None
    try:
        sb_port = 0
        if args.get("sandbox", True):
            mk(args.get("sandbox_kind", "sandbox"), "sandbox", {})
            sb_port = lab.lease_info(out["leases"]["sandbox"])["ports"]["sb"]
        wp = {"ticks": int(args.get("ticks", 0)), "mode": args.get("world_mode", "--script"), "sandbox": sb_port,
              "journal_every": int(args.get("journal_every", 20))}
        if sb_port and args.get("sandbox_kind", "sandbox") == "sandbox":   # UX A2: /limits -> set_limits
            wp["opts"] = _a2().world_opts(None, lab.lease_info(out["leases"]["sandbox"])["ports"].get("f2f"))
        for k in ("view", "mobs", "scripted", "sandbox_proto", "secret"):
            if k in args:
                wp[k] = args[k]
        world = mk("world", "world", wp)
        game = lab.lease_info(world)["ports"]["game"]
        if args.get("gateway", True):
            mk("gateway", "gateway", {"upstream": game, "packs_manifest": mpath,
                                      "assets_dir": assets_dir_of(lab.lease_info(world)),     # UX A4
                                      "auth_url": "http://127.0.0.1:%d/sup" % lab.cfg["daemon"]["port"]
                                      if args.get("auth", "db") == "db" else ""})
        g = sup.group(group, owner, OlifeHooks(args), float(args.get("poll_s", 5)),
                      meta={"project": "olife", "session": sid, "clients": n, "client_kind": kind})
        pol = args.get("policy") or {}
        order = [("world", WORLD_HEALTH)] + ([("sandbox", SANDBOX_HEALTH)] if "sandbox" in out["leases"] else []) + \
                ([("gateway", GATEWAY_HEALTH)] if "gateway" in out["leases"] else [])
        for role, health in order:              # порядок старта: мир -> песочница -> шлюз (стоп — обратный)
            t0 = time.time()
            sup.add(group, role, out["leases"][role], health=health, policy=pol)
            out["timing"][role] = round(time.time() - t0, 2)
            log("olife supervised %s: %s %s up in %.2f s" % (group, role, out["leases"][role], out["timing"][role]))
        target = lab.lease_info(out["leases"]["gateway"])["ports"]["gw"] if "gateway" in out["leases"] else game
        for i in range(1, n + 1):
            cp = {"gateway": target, "name": "%s%d" % (kind, i), "token": "olife-bot%d" % i,
                  "reconnect": args.get("reconnect", 2), "ticks": int(args.get("client_ticks", 0))}
            for k in ("blocks", "walk"):
                if k in args:
                    cp[k] = args[k]
            role = "client%d" % i
            name = mk(kind, role, cp)
            t0 = time.time()
            lab.start(name, owner=owner)
            out["timing"][role] = round(time.time() - t0, 2)
            sup.member(group, role, name)
            log("olife supervised %s: %s %s ready in %.2f s" % (group, role, name, out["timing"][role]))
        out["panel"] = sup.write_panel("olife", "Olife", SUP_PREFIX)
        out["panel_url"] = "http://127.0.0.1:%d/sup/panel?prefix=%s&title=Olife" % (lab.cfg["daemon"]["port"],
                                                                                   SUP_PREFIX)
        out["gateway_port"], out["game_port"] = target if "gateway" in out["leases"] else None, game
        if "gateway" in out["leases"]:
            out["packs_http"] = lab.lease_info(out["leases"]["gateway"])["ports"]["http"]
        return out
    except Exception:
        if g is not None:
            g.stop = True
            for s_ in g.services.values():
                s_.stop = True
            g.state = "down"
        raise


def _group(lab, args, owner=None):
    if args.get("group"):
        return lab.sup.get(args["group"])
    live = [g for n, g in lab.sup.groups.items() if n.startswith(SUP_PREFIX) and g.state == "up"]
    mine = [g for g in live if owner is None or g.owner == owner]
    pick = mine if len(mine) == 1 else live
    if len(pick) != 1:
        raise KeyError("which olife group? live: %s (pass group)" % ", ".join(g.name for g in live) or "none")
    return pick[0]


def f_up(ctx, args):
    lab = ctx.lab
    ttl = args.get("ttl") or 1800
    made = []

    def create(kind, role, params):
        r = ctx.lease(kind, params=params, ttl=ttl)
        made.append(r["lease"]["name"])
        return r["lease"]["name"]
    try:
        return build_supervised(lab, ctx.owner, args, create)
    except Exception:
        for name in reversed(made):
            try:
                ctx.release(name)
            except Exception:
                pass
        raise


def f_down(ctx, args):
    g = _group(ctx.lab, args, ctx.owner)
    return ctx.lab.sup.down(g.name, ctx.owner, release=args.get("release", True))


def f_supstatus(ctx, args):
    st = ctx.lab.sup.state(SUP_PREFIX, args.get("group"))
    short = {}
    for n, g in st["groups"].items():
        p = g.get("poll") or {}
        short[n] = {"owner": g["owner"], "state": g["state"],
                    "services": {s["role"]: {k: s[k] for k in ("lease", "state", "pid", "restarts", "uptime_s",
                                                                "last_incident")} | {
                        "health": (s["last_check"] or {}).get("ok")} for s in g["services"]},
                    "members": g["members"], "world": p.get("world"), "players": len(p.get("players") or []),
                    "gateway": p.get("gateway"), "poll_error": g.get("poll_error")}
    return {"groups": short, "incidents": [{k: i[k] for k in ("id", "service", "why", "exit", "summary")}
                                           for i in st["incidents"][:10]],
            "counters": st["counters"], "tariffs": st["tariffs"], "bans": st["bans"],
            "panel": os.path.join(ctx.lab.data, "dashboard", "olife.html"),
            "panel_url": "http://127.0.0.1:%d/sup/panel?prefix=%s&title=Olife" % (ctx.lab.cfg["daemon"]["port"],
                                                                                  SUP_PREFIX)}


def f_incidents(ctx, args):
    if args.get("id"):
        return ctx.lab.sup.incident(args["id"])
    rows = ctx.lab.sup.db.incidents(int(args.get("last", 20)))
    return {"incidents": [r for r in rows if (r["grp"] or "").startswith(SUP_PREFIX)]}


def f_players(ctx, args):
    g = _group(ctx.lab, args, ctx.owner)
    r = ctx.lab.stdin(g.services["world"].lease, "players", owner=ctx.owner, wait=2.0, pattern=r"player")
    return {"group": g.name, "lines": [x for x in r["lines"] if "olife_world" in x],
            "polled": (g.poll_data or {}).get("players")}


def f_kick(ctx, args):
    g = _group(ctx.lab, args, ctx.owner)
    r = ctx.lab.stdin(g.services["world"].lease, "kick %d" % int(args["eid"]), owner=ctx.owner, wait=2.0,
                      pattern=r"kick")
    ctx.lab.sup.db.event(g.name, "world", g.services["world"].lease, "kick", {"eid": args["eid"], "by": ctx.owner})
    return {"group": g.name, "lines": r["lines"][-3:]}


def f_ban(ctx, args):
    if args.get("ip"):                          # antifraud 16.10: CIDR, срок, немедленный kick (olife_fraud.ipban)
        return _fraud().ipban(ctx.lab, args["ip"], args.get("minutes", 0), args.get("reason", ""), ctx.owner,
                              args.get("via") or "cli", force=bool(args.get("force")))
    kind = "ip" if args.get("ip") else "account"
    val = args.get("ip") or args["account"]
    r = ctx.lab.sup.db.ban(kind, val, args.get("minutes", 0), args.get("reason", ""), ctx.owner)
    ctx.lab.sup.db.event(None, None, None, "ban", r)
    r["note"] = "gateways with --auth-url pick it up within 2 s and disconnect the account's sessions"
    return r


def f_unban(ctx, args):
    if args.get("ip"):
        return _fraud().ipunban(ctx.lab, args["ip"], ctx.owner, args.get("via") or "cli")
    kind = "ip" if args.get("ip") else "account"
    r = ctx.lab.sup.db.unban(kind, args.get("ip") or args["account"], ctx.owner)
    ctx.lab.sup.db.event(None, None, None, "unban", dict(r, value=args.get("ip") or args["account"], by=ctx.owner))
    return r


def f_tariff(ctx, args):
    db = ctx.lab.sup.db
    if args.get("action", "list") == "set":
        # волна 4b: limits.* -> set_limits сразу в работающие песочницы (supervisor + свои); прочее — как было
        return _w4b().tariff_set(ctx.lab, ctx.owner, args["key"], args.get("value"))
    db.seed_tariffs(TARIFFS)
    return {"tariffs": db.tariffs()}


def f_accounts(ctx, args):
    db = ctx.lab.sup.db
    if args.get("action") == "add":
        tok = args.get("token")
        if not tok:                             # путь игрока: «выдать другу аккаунт» — токен генерируется здесь
            import secrets
            tok = "olife-f-" + secrets.token_urlsafe(18)
        r = db.add_account(args["name"], tok, args.get("role", "player"), args.get("note"))
        if not args.get("token"):
            r["token"] = tok
        return r
    return {"accounts": db.accounts(), "logins": db.logins(int(args.get("last", 20))), "counters": db.counters()}


def f_packs(ctx, args):
    m = make_manifest(ctx.lab)
    return {"manifest": manifest_path(ctx.lab), "version": m["version"], "files": m["files"],
            "packs": {k: {"side": v["side"], "files": len(v["files"]), "bytes": v["bytes"]} for k, v in
                      m["packs"].items()},
            "note": "a running gateway re-reads it on change (packs.version += 1); clients are not notified yet: the "
                    "client contract has no message for it (follow-up)"}


def f_kill(ctx, args):
    g = _group(ctx.lab, args, ctx.owner)
    return ctx.lab.sup.kill(g.name, args["role"], ctx.owner, args.get("how", "proc"))


def f_restart(ctx, args):
    g = _group(ctx.lab, args, ctx.owner)
    return ctx.lab.sup.restart(g.name, args["role"], ctx.owner)


# ---------------------------------------------------------------- шаги сценариев (olife_restart)
def _sup_group(sx):
    return sx.lab.sup.get(sx.data["group"])


def st_kill(sx, args, step):
    r = sx.lab.sup.kill(sx.data["group"], args.get("role", "world"), sx.owner, args.get("how", "proc"))
    sx.data.setdefault("kills", []).append(r)
    return {"ok": True, "result": r}


def st_wait_restart(sx, args, step):
    """служба снова up после смерти: restarts >= n; результат — хронология из инцидента"""
    g = _sup_group(sx)
    role = args.get("role", "world")
    want = int(args.get("restarts", 1))
    end = time.time() + float(args.get("timeout", 60))
    svc = g.services[role]
    while time.time() < end:
        if svc.restarts >= want and svc.state == "up":
            inc = sx.lab.sup.incident(svc.last_incident)
            k = (sx.data.get("kills") or [{}])[-1]
            rs = inc.get("restart") or {}
            tl = {"t_kill": k.get("t"), "t_death": inc.get("t_death"), "t_detect": inc.get("t_detect"),
                  "t_restart": rs.get("t_restart"), "t_ready": rs.get("t_ready"), "backoff_s": rs.get("backoff_s"),
                  "start_s": rs.get("start_s")}
            base = tl["t_kill"] or tl["t_death"]
            rel = {kk: round(v - base, 3) for kk, v in tl.items() if kk.startswith("t_") and v}
            res = {"role": role, "lease": svc.lease, "restarts": svc.restarts, "incident": svc.last_incident,
                   "timeline_rel_s": rel, "backoff_s": tl["backoff_s"], "start_s": tl["start_s"],
                   "capture": (inc.get("capture") or {}).get("summary")}
            sx.data.setdefault("metrics", {}).setdefault("supervisor", {}).setdefault("restarts", []).append(res)
            return {"ok": True, "result": res}
        if svc.state == "failed":
            return {"ok": False, "error": "%s gave up restarting" % role}
        if sx.cancelled:
            return {"ok": False, "error": "cancelled"}
        time.sleep(0.25)
    return {"ok": False, "error": "%s not restarted in %s s (state %s, restarts %d)" % (role, args.get("timeout", 60),
                                                                                       svc.state, svc.restarts)}


def _bots(sx):
    return [(r, n) for r, n in _roles(sx).items() if r.startswith("client") and sx.lab.leases[n].kind == "bot"]


def st_wait_bots(sx, args, step):
    """боты снова в игре после перезапуска мира: state=play и reconnects >= min_reconnects"""
    end = time.time() + float(args.get("timeout", 60))
    want = int(args.get("min_reconnects", 1))
    skip = set(args.get("skip") or [])
    last = {}
    while time.time() < end:
        for role, name in _bots(sx):
            if role in skip:
                continue
            last[name] = _status(sx, role, "status name=")
        if last and all(b.get("state") == "play" and int(b.get("reconnects") or 0) >= want for b in last.values()):
            res = {n: {k: b.get(k) for k in ("state", "reconnects", "session", "eid", "self_div", "syncs")}
                   for n, b in last.items()}
            sx.data.setdefault("metrics", {}).setdefault("supervisor", {})["bots_after"] = res
            return {"ok": True, "result": res}
        time.sleep(1.0)
    return {"ok": False, "error": "bots not back: %s" % {n: {k: b.get(k) for k in ("state", "reconnects", "disconnect")}
                                                         for n, b in last.items()}}


def st_incident(sx, args, step):
    """последний инцидент роли: каталог с journal.json (>= min_frames кадров), хвостами логов, перезапуском ok"""
    import shutil
    g = _sup_group(sx)
    svc = g.services[args.get("role", "world")]
    if not svc.last_incident:
        return {"ok": False, "error": "no incident for %s" % svc.role}
    inc = sx.lab.sup.incident(svc.last_incident)
    cap = inc.get("capture") or {}
    dst = os.path.join(sx.out_dir(), "incident_%s" % svc.role)
    shutil.copytree(inc["dir"], dst, dirs_exist_ok=True)
    bad = []
    if args.get("role", "world") == "world" and int(cap.get("journal_frames") or 0) < int(args.get("min_frames", 1)):
        bad.append("journal frames %s < %s" % (cap.get("journal_frames"), args.get("min_frames", 1)))
    if not any(isinstance(v, dict) and v.get("lines") for v in (inc.get("logs") or {}).values()):
        bad.append("no log tails")
    if not (inc.get("restart") or {}).get("ok"):
        bad.append("restart not ok: %s" % inc.get("restart"))
    res = {"id": inc["id"], "dir": inc["dir"], "copied": dst, "why": inc["why"], "exit": inc["exit"],
           "summary": inc.get("summary"), "journal_frames": cap.get("journal_frames"),
           "state_age_s": cap.get("state_age_s"), "last_frame": cap.get("last_frame"),
           "sandbox_last_result": (cap.get("sandbox_world_side") or {}).get("last_result"),
           "restart": inc.get("restart"), "logs": {k: v.get("lines") for k, v in (inc.get("logs") or {}).items()
                                                   if isinstance(v, dict)}}
    sx.data.setdefault("metrics", {}).setdefault("supervisor", {}).setdefault("incidents", []).append(
        {k: res[k] for k in ("id", "why", "exit", "journal_frames", "state_age_s")})
    return {"ok": not bad, "result": res, "error": "; ".join(bad) or None}


def st_world_sandbox(sx, args, step):
    """мир снова соединён с песочницей (после её перезапуска + sandbox_reconnect)"""
    end = time.time() + float(args.get("timeout", 20))
    w = {}
    while time.time() < end:
        w = _status(sx, "world", "status tick=")
        if str(w.get("sandbox", "")).startswith("connected"):
            return {"ok": True, "result": {"sandbox": w.get("sandbox"), "tick": w.get("tick")}}
        time.sleep(0.5)
    return {"ok": False, "error": "world sandbox state: %s" % w.get("sandbox")}


def st_ban(sx, args, step):
    """бан в БD supervisor -> шлюз (опрос /sup/bans, 2 с) рвёт сессию аккаунта (код 5); бот не переподключается"""
    db = sx.lab.sup.db
    acct = args["account"]
    if args.get("unban"):
        return {"ok": True, "result": db.unban("account", acct, sx.owner)}
    db.ban("account", acct, args.get("minutes", 1), args.get("reason", "scenario"), sx.owner)
    role = args["role"]
    lease = _roles(sx)[role]
    end = time.time() + float(args.get("timeout", 15))
    b = {}
    while time.time() < end:
        p = sx.lab.leases[lease].proc
        if p is not None and not p.alive():
            # бот без переподключения (код 5 не из RECONNECT_CODES) закрывается сам: доказательство — его лог
            tail = sx.lab.logs(lease, tail=80)["lines"]
            hit = [x for x in tail if "disconnected by server: 5" in x]
            back = [x for x in tail if "reconnecting #" in x and tail.index(x) > (tail.index(hit[-1]) if hit else 0)]
            ok = bool(hit) and not back
            return {"ok": ok, "result": {"account": acct, "bot_exit": p.info().get("exit"),
                                         "line": hit[-1][-160:] if hit else None, "reconnected_after": bool(back)},
                    "error": None if ok else "bot exited without a ban disconnect: %s" % tail[-3:]}
        try:
            b = _status(sx, role, "status name=")
        except Exception:
            time.sleep(0.3)
            continue
        if b.get("state") == "closed" and str(b.get("disconnect", "")).startswith("5"):
            time.sleep(float(args.get("hold_s", 3)))
            p = sx.lab.leases[lease].proc
            if p is not None and not p.alive():        # бот без переподключения вышел сам за hold_s — это и есть успех
                continue                               # (ветка «процесс завершился» выше проверит лог: код 5, без reconnect)
            try:
                b = _status(sx, role, "status name=")
            except Exception:
                continue                               # вышел между проверкой и запросом — та же ветка выше
            ok = b.get("state") == "closed"
            return {"ok": ok, "result": {"account": acct, "state": b.get("state"), "reconnects": b.get("reconnects"),
                                         "disconnect": "5 banned"},
                    "error": None if ok else "banned bot came back: %s" % b.get("state")}
        time.sleep(0.5)
    return {"ok": False, "error": "ban not applied: %s" % {k: b.get(k) for k in ("state", "disconnect")}}


_W3S = {}


def _w3s():
    """волна 3a (olife_w3s): настоящая песочница — шаги/возможности/перф в sandbox_real.py (свой модуль, чтобы не
    мешать правкам plugin.py другими агентами); загружается заново при каждой перезагрузке плагина."""
    if "m" not in _W3S:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "olife_sandbox_real", os.path.join(os.path.dirname(os.path.abspath(__file__)), "sandbox_real.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _W3S["m"] = m
    return _W3S["m"]


_W3G = {}
_W4A = {}


def _w4a():
    """волна 4a (olife_w4a): редактор/консоль/инструменты — шаги в editor_w4a.py (свой модуль); перезагружается и при
    правке самого editor_w4a.py (mtime), не только plugin.py"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "editor_w4a.py")
    mt = os.path.getmtime(path)
    if _W4A.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_editor_w4a", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _W4A["m"], _W4A["mtime"] = m, mt
    return _W4A["m"]


def _w3g():
    """волна 3c (olife_w3g): Rust-шлюз — шаги нагрузки/выдержки и перф в gateway_rs.py (свой модуль, как sandbox_real.py)"""
    if "m" not in _W3G:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "olife_gateway_rs", os.path.join(os.path.dirname(os.path.abspath(__file__)), "gateway_rs.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _W3G["m"] = m
    return _W3G["m"]


_W4B = {}


def _w4b():
    """волна 4b (olife_w4b): билеты, тарифы песочницы вживую, горячая перезагрузка паков, байты моста — olife_w4b.py
    (свой модуль; перезагружается и при правке самого файла, как _w4a)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_w4b.py")
    mt = os.path.getmtime(path)
    if _W4B.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_w4b", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        if "m" in _W4B:
            m._PUSHED.update(_W4B["m"]._PUSHED)       # что уже отправлено песочницам — не терять при перезагрузке
        _W4B["m"], _W4B["mtime"] = m, mt
    return _W4B["m"]


_W4C = {}


def _w4c():
    """волна 4c (olife_w4c): сетевой код — шаги предсказания/дельт/инвентаря в netcode.py (свой модуль; перезагружается
    при правке самого файла, как _w4a/_w4b)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "netcode.py")
    mt = os.path.getmtime(path)
    if _W4C.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_netcode_w4c", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _W4C["m"], _W4C["mtime"] = m, mt
    return _W4C["m"]


_W5P = {}


def _w5p():
    """волна 5p (olife_w5p): профиль такта мира (prof=1) и трассы LuaJIT — olife_w5p.py (перезагружается при правке)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_w5p.py")
    mt = os.path.getmtime(path)
    if _W5P.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_w5p", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _W5P["m"], _W5P["mtime"] = m, mt
    return _W5P["m"]


_A1 = {}


def _a1():
    """UX A1 (olife_a1): права, друзья, форк — olife_a1.py (перезагружается при правке самого файла, как _w4a)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_a1.py")
    mt = os.path.getmtime(path)
    if _A1.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_a1", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        if "m" in _A1:
            m._FRESH.update(_A1["m"]._FRESH)
        _A1["m"], _A1["mtime"] = m, mt
    return _A1["m"]


def _a1_step(name):
    return lambda sx, args, step: getattr(_a1(), _a1().NAMES[name])(sx, args, step)


_A2 = {}


def _a2():
    """UX A2 (olife_a2): чат, команды оператора (olife.op), обратная связь — olife_a2.py (перезагрузка по mtime)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_a2.py")
    mt = os.path.getmtime(path)
    if _A2.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_a2", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _A2["m"], _A2["mtime"] = m, mt
    return _A2["m"]


_A4 = {}


def _a4():
    """UX A4 (olife_a4): хранилище (KV, активы CAS, canvas, снимки) — store_a4.py (перезагрузка по mtime, как _w4a)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store_a4.py")
    mt = os.path.getmtime(path)
    if _A4.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_store_a4", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _A4["m"], _A4["mtime"] = m, mt
    return _A4["m"]


_A3 = {}


def _a3():
    """UX A3 (olife_a3): API скриптов моба — olife_a3.py (перезагрузка по mtime этого файла)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_a3.py")
    mt = os.path.getmtime(path)
    if _A3.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_a3", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _A3["m"], _A3["mtime"] = m, mt
    return _A3["m"]


def _a3_step(name):
    return lambda sx, args, step: getattr(_a3(), _a3().NAMES[name])(sx, args, step)


_B1 = {}


def _b1():
    """UX B1 (olife_b1): «мои мобы» — панель, спасти/уничтожить/восстановить, камера, версии кода — olife_b1.py
    (перезагрузка по mtime этого файла)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_b1.py")
    mt = os.path.getmtime(path)
    if _B1.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_b1", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _B1["m"], _B1["mtime"] = m, mt
    return _B1["m"]


def _b1_step(name):
    return lambda sx, args, step: getattr(_b1(), _b1().NAMES[name])(sx, args, step)


_B2 = {}


def _b2():
    """UX B2 (olife_b2): «Спамер» — снимки мобов, бросок шара, экземпляры из снимка — olife_b2.py (перезагрузка по mtime)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_b2.py")
    mt = os.path.getmtime(path)
    if _B2.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_b2", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _B2["m"], _B2["mtime"] = m, mt
    return _B2["m"]


def _b2_step(name):
    return lambda sx, args, step: getattr(_b2(), _b2().NAMES[name])(sx, args, step)


_MENU = {}


def _menu():
    """UX B (olife_menu, 16.10): меню клиента, экран статуса входа, вайтлист по нику — olife_menu.py (перезагрузка по
    mtime; шаги и возможности — обёртки)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_menu.py")
    mt = os.path.getmtime(path)
    if _MENU.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_menu", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _MENU["m"], _MENU["mtime"] = m, mt
    return _MENU["m"]


def _menu_step(name):
    return lambda sx, args, step: getattr(_menu(), _menu().NAMES[name])(sx, args, step)


_FRAUD = {}


def _fraud():
    """антифрод и бан по IP (olife_antifraud, 16.10) — olife_fraud.py (перезагрузка по mtime; возможности — обёртки)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_fraud.py")
    mt = os.path.getmtime(path)
    if _FRAUD.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_fraud", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _FRAUD["m"], _FRAUD["mtime"] = m, mt
    return _FRAUD["m"]


def _fraud_step(name):
    return lambda sx, args, step: getattr(_fraud(), _fraud().NAMES[name])(sx, args, step)


_PUB = {}


def _pub():
    """игра с друзьями по сети (olife_friends, 16.10): публичный режим, lab olife ip|invite|bundle, сценарии olife_public /
    olife_bundle — olife_public.py (перезагрузка по mtime)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_public.py")
    mt = os.path.getmtime(path)
    if _PUB.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_public", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _PUB["m"], _PUB["mtime"] = m, mt
    return _PUB["m"]


def _pub_step(name):
    return lambda sx, args, step: getattr(_pub(), _pub().NAMES[name])(sx, args, step)


_PLAY = {}


def _play():
    """путь игрока (olife_play, 02.10): lab play olife / --dry-run, lab olife play-up|play-down — olife_play.py
    (перезагружается при правке самого файла, как _w4a)"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "olife_play.py")
    mt = os.path.getmtime(path)
    if _PLAY.get("mtime") != mt:
        import importlib.util
        spec = importlib.util.spec_from_file_location("olife_play", path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.bind(globals())
        _PLAY["m"], _PLAY["mtime"] = m, mt
    return _PLAY["m"]


def _play_step(name):
    return lambda sx, args, step: _play().steps()[name](sx, args, step)


def _w5p_step(name):
    return lambda sx, args, step: _w5p().steps()[name](sx, args, step)


def _w4c_step(name):
    """шаг волны 4c берётся из модуля в момент вызова (правка netcode.py действует без перезагрузки plugin.py)"""
    return lambda sx, args, step: _w4c().steps()[name](sx, args, step)


def _w4b_step(name):
    """шаг волны 4b берётся из модуля в момент вызова: правка olife_w4b.py действует без перезагрузки plugin.py"""
    return lambda sx, args, step: _w4b().steps()[name](sx, args, step)


def register(api):
    obj = {"type": "object"}
    api.feature("session", f_session, "lease world + gateway + sandbox + N clients/bots as one session",
                {"type": "object", "properties": {"clients": {"type": "integer"}, "client_kind": {"type": "string"},
                                                  "sandbox": {"type": "boolean"}, "ttl": {"type": "number"}}},
                mcp=True)
    api.feature("release", f_release, "release all leases of a session {session}",
                {"type": "object", "properties": {"session": {"type": "string"}}, "required": ["session"]})
    api.feature("status", f_status, "world status (stdin), gateway metrics, sandbox stats {session}", obj)
    api.feature("consistency", f_consistency, "per-tick state comparison world vs clients {session}", obj)
    api.feature("sandbox_probe", f_sandbox_probe, "negative sandbox attempts {session|lease, attempts?}", obj)
    api.scenario(start=sc_start, info=sc_info, finish=sc_finish, stop=sc_stop,
                 steps={"olife_run": st_run, "olife_stdin": st_stdin, "olife_consistency": st_consistency,
                        "olife_sandbox": st_sandbox, "olife_metrics": st_metrics, "olife_status": st_world_status,
                        "olife_quiet": st_quiet, "olife_blocks": st_blocks, "olife_negative_proto": st_negative_proto,
                        "olife_kill": st_kill, "olife_wait_restart": st_wait_restart, "olife_wait_bots": st_wait_bots,
                        "olife_incident": st_incident, "olife_world_sandbox": st_world_sandbox, "olife_ban": st_ban,
                        **_w3s().steps(), **_w3g().steps(), **_w4a().steps(),
                        **{k: _w4b_step(k) for k in _w4b().steps()},
                        **{k: _w4c_step(k) for k in _w4c().steps()},
                        **{k: _w5p_step(k) for k in _w5p().steps()},
                        **{k: _play_step(k) for k in _play().steps()},
                        **{k: _a1_step(k) for k in _a1().NAMES},
                        **_a2().steps(),
                        **_a4().steps(),             # UX A4: store
                        **{k: _a3_step(k) for k in _a3().NAMES},    # UX A3: mob script API
                        **{k: _b1_step(k) for k in _b1().NAMES},    # UX B1: my mobs panel
                        **{k: _b2_step(k) for k in _b2().NAMES},    # UX B2: Spammer
                        **{k: _menu_step(k) for k in _menu().NAMES},    # UX B: menu, status screen, whitelist
                        **{k: _fraud_step(k) for k in _fraud().NAMES},   # antifraud, IP bans (olife_fraud.py)
                        **{k: _pub_step(k) for k in _pub().NAMES}})      # olife_friends: public play, bundle
    _w3s().register(api)            # волна 3a: olife.sandbox_meters, перф sandbox_load (sandbox_real.py)
    _w4b().register(api)            # волна 4b: olife.limits (тарифы -> set_limits)
    _play().register(api)           # путь игрока: olife.play_up/play_down/play_status/sync (olife_play.py)
    _w3g().register(api)            # волна 3c: шаги olife_gw_load/olife_soak, перф gateway_load (gateway_rs.py)
    _a1().register(api)             # UX A1: olife.friend, olife.settings (olife_a1.py)
    _a2().register(api)             # UX A2: olife.op, olife.mobs (olife_a2.py) + live panel template
    _menu().register(api)           # UX B: olife.auth_name, olife.whitelist (olife_menu.py)
    _fraud().register(api)          # antifraud: olife.ip_check, olife.gw_sync, olife.fraud (olife_fraud.py)
    _pub().register(api)            # olife_friends: olife.ip, olife.invite, olife.bundle (olife_public.py)
    # этап 6: supervisor (lab olife ...; ядро labcore/supervise.py)
    S = {"type": "object", "properties": {"group": {"type": "string"}}}
    api.feature("up", f_up, "supervised olife session: world -> sandbox -> gateway (+N bots with --reconnect); health, "
                "restart with backoff, incidents, DB accounts/bans/counters/tariffs, panel {clients=2, client_kind=bot, "
                "sandbox=true, policy?, poll_s=5, autosave_s=30, ttl}",
                {"type": "object", "properties": {"clients": {"type": "integer"}, "sandbox": {"type": "boolean"},
                                                  "policy": {"type": "object"}}}, mcp=True)
    api.feature("down", f_down, "stop supervising and release the group (clients -> gateway -> sandbox -> world)", S)
    api.feature("sup_status", f_supstatus, "supervised groups: services health/restarts/uptime, world, players, "
                "counters, incidents, panel path", S, mcp=True)
    api.feature("incidents", f_incidents, "incidents of olife groups {last=20} | {id} -> full record", obj)
    api.feature("players", f_players, "players online (world `players` + last poll) {group?}", S)
    api.feature("kick", f_kick, "kick a player by eid {eid, group?}", obj)
    api.feature("ban", f_ban, "ban an account (or ip) in the supervisor DB {account|ip, minutes=0 (permanent), "
                "reason}", obj)
    api.feature("unban", f_unban, "lift bans {account|ip}", obj)
    api.feature("tariff", f_tariff, "tariffs {action=list|set, key, value} (applied at the next poll, no restart)", obj)
    api.feature("accounts", f_accounts, "accounts/logins/counters {action=list|add, name, token, role}", obj)
    api.feature("packs", f_packs, "generate the pack manifest (content/olife_client + olife_proto: path, sha256, "
                "size, side)", obj)
    api.feature("kill", f_kill, "crash a supervised service for a test {role, how=proc|tree, group?}", obj)
    api.feature("restart", f_restart, "operator restart of a supervised service {role, group?}", obj)


def selftest():
    _a2().selftest()
    _menu().selftest()
    _fraud().selftest()
    _pub().selftest()
    _play().selftest()
    _w3s().selftest()
    _w4b().selftest()
    _w4c().selftest()
    w = [{"tick": t, "ts": 1000.0 + t * 50, "hash": "h%d" % t} for t in range(1, 21)]
    c = [{"tick": t, "t_recv": 1002.0 + t * 50, "hash": "h%d" % t} for t in range(3, 21) if t != 10]
    c.append({"tick": 25, "t_recv": 0, "hash": "x"})            # хвост, которого мир ещё не записал — не считается
    r = compare_states(w, {"a": c, "b": [{"tick": 5, "t_recv": 1300.0, "hash": "bad"}]})
    assert r["clients"]["a"]["compared"] == 17 and r["clients"]["a"]["missing"] == 1, r
    assert r["divergence_count"] == 1 and r["clients"]["b"]["divergences"] == 1, r
    assert r["clients"]["a"]["latency_ms"]["p50"] == 2.0, r
