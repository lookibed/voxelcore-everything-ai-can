"""olife, волна 4b (02.10, агент olife_w4b): билеты, тарифы песочницы вживую, горячая перезагрузка паков, бинарный
контракт песочницы. Подключается из plugin.py (`_w4b()`), получает его глобалы (build_session, _roles, seed_db, ...).

Сессия (setup.session сценария, olife.session):
  auth_ticket=true   — аренда `auth` (tools/olife/auth_service.py, HTTPS с самоподписанным сертификатом), мастер-ключ
                       и ключ запечатывания x25519 генерирует лаборатория (<data>\\olife\\w4b\\<сессия>\\), шлюзу —
                       его ключ K_gw (--ticket-key) и аудитория gw-<сессия>, клиентам — --auth https://..., --gw-id,
                       --auth-pub (закреплённый ключ), --auth-verify 0. auth_mode: both|tickets (шлюз).
  packs_reload=true  — копия паков клиента (olife_client + olife_proto) в <data>\\olife\\w4b\\<сессия>\\content и
                       манифест по ней; шлюз раздаёт и следит (PacksChanged); шаг olife_packs_change меняет копию.
Тарифы (БД supervisor, таблица tariffs): `limits.default.<поле>` и `limits.owner.<n>.<поле>`, поля LIMIT_FIELDS ->
  `set_limits` порту управления olife-sandboxd (слияние, со следующего такта). Доставка: `lab olife tariff set` (сразу
  всем песочницам групп supervisor и песочницам вызывающего), опрос групп supervisor (каждые poll_s), шаг
  olife_tariff_set. Ключ удалён -> поле возвращается к умолчанию сервиса.
Шаги: olife_ticket_auth, olife_bots_check, olife_tariff_set, olife_tariff_check, olife_packs_change, olife_packs_wait,
  olife_sandbox_wire."""
import json
import os
import shutil
import sys
import time

P = {}          # глобалы plugin.py (bind)

LIMIT_FIELDS = ("fuel_per_tick", "bucket_max", "tick_cap", "entity_budget", "max_actions", "max_text_bytes",
                "mem_max", "hard_cap_ticks", "hard_cap_fuel")
DEFAULT_LIMITS = {"fuel_per_tick": 2_000_000, "bucket_max": 40_000_000, "tick_cap": 10_000_000, "entity_budget": None,
                  "max_actions": 64, "max_text_bytes": 4096, "mem_max": 64 << 20, "hard_cap_ticks": 10,
                  "hard_cap_fuel": 200_000_000}          # = Limits::default() в <olife-src>/sandboxd/src/protocol.rs
_PUSHED = {}    # аренда песочницы -> {цель ("*" | "<owner>"): {поле: значение}} последнее отправленное


def bind(plugin_globals):
    P.update(plugin_globals)


def _tools():
    from labcore import config
    return os.path.join(config.REPO_ROOT, "projects", "olife", "tools")


def _import_tools():
    t = _tools()
    if t not in sys.path:
        sys.path.insert(0, t)


def w4b_dir(lab, sid):
    d = os.path.join(lab.data, "olife", "w4b", sid)
    os.makedirs(d, exist_ok=True)
    return d


# ============================================================================================== сессия: билеты, паки
def make_keys(lab, sid):
    """мастер-ключ сервиса билетов + ключ шлюза gw-<sid> + ключ запечатывания x25519 (открытый — клиентам)."""
    _import_tools()
    import olife_ticket as T
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization as S
    d = w4b_dir(lab, sid)
    master = os.urandom(32)
    gw_id = "gw-" + sid
    paths = {"master": os.path.join(d, "auth_master.key"), "gw_key": os.path.join(d, "gateway_ticket.key"),
             "seal": os.path.join(d, "auth_seal_x25519.key")}
    with open(paths["master"], "w", encoding="utf-8") as f:
        f.write(master.hex())
    with open(paths["gw_key"], "w", encoding="utf-8") as f:
        json.dump({"key": T.gateway_key(master, gw_id).hex(), "gateway": gw_id}, f)
    sk = X25519PrivateKey.generate()
    with open(paths["seal"], "w", encoding="utf-8") as f:
        f.write(sk.private_bytes(S.Encoding.Raw, S.PrivateFormat.Raw, S.NoEncryption()).hex())
    pub = T.b64u(sk.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw))
    return dict(paths, gw_id=gw_id, pub=pub)


def make_packs(lab, sid):
    """копия паков клиента (то, что раздаёт шлюз) + манифест по ней"""
    from labcore import config, supervise
    root = os.path.join(w4b_dir(lab, sid), "content")
    for pk in P["CLIENT_PACKS"]:
        dst = os.path.join(root, pk)
        if os.path.isdir(dst):
            shutil.rmtree(dst)
        shutil.copytree(os.path.join(config.PACKS_DIR, pk), dst,
                        ignore=shutil.ignore_patterns("__pycache__", ".git"))
    out = os.path.join(w4b_dir(lab, sid), "packs_manifest.json")
    m = supervise.pack_manifest(root, P["CLIENT_PACKS"], out)
    return {"root": root, "manifest": out, "version": m["version"], "files": m["files"]}


def session_extra(info, args, sid, start, log=None):
    """build_session: до шлюза. info — lease_info лаборатории или FeatureCtx.info (bound) -> lab.
    -> {"gateway": {...}, "client": {...}, "info": {...}}"""
    owner_obj = getattr(info, "__self__", None)
    lab = getattr(owner_obj, "lab", owner_obj)
    out = {"gateway": {}, "client": {}, "info": {}}
    sup_url = "http://127.0.0.1:%d/sup" % lab.cfg["daemon"]["port"]
    if args.get("auth_ticket"):
        if getattr(lab, "sup", None) is not None:
            P["seed_db"](lab.sup, 0)                 # аккаунты/баны dev (dev, bots, test, banned) — в БД supervisor
        k = make_keys(lab, sid)
        auth = start("auth", "auth", {"master": k["master"], "seal_key": k["seal"], "gateways": k["gw_id"],
                                      "auth_url": sup_url, "ttl": int(args.get("ticket_ttl", 30)),
                                      "require_sealed": int(bool(args.get("require_sealed", 0))),
                                      "tls": int(args.get("tls", 1))})
        ai = info(auth)
        url = "%s://127.0.0.1:%d" % ("https" if int(args.get("tls", 1)) else "http", ai["ports"]["https"])
        out["gateway"].update(ticket_key=k["gw_key"], gw_id=k["gw_id"], auth_url=sup_url,
                              auth_mode=args.get("auth_mode", "both"))
        out["client"].update(auth=url, gw_id=k["gw_id"], auth_pub=k["pub"], auth_verify=0)
        out["info"].update(auth_url=url, auth_ctl=ai["ports"]["f2f"], gw_id=k["gw_id"], auth_pub=k["pub"],
                           auth_lease=auth, keys_dir=w4b_dir(lab, sid), auth_mode=args.get("auth_mode", "both"))
    if args.get("packs_reload"):
        pk = make_packs(lab, sid)
        out["gateway"]["packs_manifest"] = pk["manifest"]
        out["info"]["packs"] = pk
    if log and out["info"]:
        log("olife w4b %s: %s" % (sid, {k: v for k, v in out["info"].items() if k != "packs"}))
    return out


# ============================================================================================== тарифы -> set_limits
def limits_from_tariffs(tariffs):
    """{"limits.default.fuel_per_tick": v, "limits.owner.7.max_actions": v} -> {"*": {...}, "7": {...}}"""
    out = {}
    for k, v in (tariffs or {}).items():
        parts = k.split(".")
        if len(parts) == 3 and parts[0] == "limits" and parts[1] == "default" and parts[2] in LIMIT_FIELDS:
            out.setdefault("*", {})[parts[2]] = int(v)
        elif len(parts) == 4 and parts[0] == "limits" and parts[1] == "owner" and parts[3] in LIMIT_FIELDS:
            out.setdefault(str(int(parts[2])), {})[parts[3]] = int(v)
    return out


def _proc_key(lab, lease):
    """аренда + pid процесса: новый процесс песочницы (перезапуск, то же имя аренды в новом прогоне) получает всё"""
    l = lab.leases.get(lease)
    return "%s#%s" % (lease, l.proc.pid if l is not None and l.proc else "-")


def push_limits(lab, owner, lease, tariffs, force=False):
    """разница с последним отправленным этому процессу -> set_limits на порт управления песочницы.
    -> [{target, limits, reply}]"""
    want = limits_from_tariffs(tariffs)
    prev = _PUSHED.setdefault(_proc_key(lab, lease), {})
    sent = []
    for tgt in sorted(set(want) | set(prev)):
        w, p = want.get(tgt, {}), prev.get(tgt, {})
        diff = {f: v for f, v in w.items() if force or p.get(f) != v}
        for f in p:                                   # ключ тарифа удалён -> умолчание сервиса
            if f not in w:
                diff[f] = DEFAULT_LIMITS.get(f)
        if not diff:
            continue
        t0 = time.time()
        rep = lab.f2f_quiet(lease, "set_limits", {"owner": "*" if tgt == "*" else int(tgt), "limits": diff},
                            timeout=3, owner=owner)
        sent.append({"target": tgt, "limits": diff, "ok": bool(rep.get("ok")), "ms": round((time.time() - t0) * 1000, 1),
                     "reply": rep.get("result") if rep.get("ok") else rep.get("error")})
        if rep.get("ok"):
            if w:
                prev[tgt] = dict(w)
            else:
                prev.pop(tgt, None)
    return sent


def _real_sandboxes(lab, owner=None):
    """аренды настоящей песочницы (вид sandbox) в работе: групп supervisor и (owner) — вызывающего"""
    out = {}
    sup = getattr(lab, "sup", None)
    if sup is not None:
        for g in list(sup.groups.values()):
            s = g.services.get("sandbox")
            if g.name.startswith(P["SUP_PREFIX"]) and g.state == "up" and s is not None and s.state == "up":
                out[s.lease] = g.owner
    with lab.lock:
        for l in lab.leases.values():
            if l.kind == "sandbox" and l.project == "olife" and (owner is None or l.owner == owner) and \
                    l.proc is not None and l.proc.alive():
                out.setdefault(l.name, l.owner)
    return out


def push_all(lab, owner=None):
    tariffs = lab.sup.db.tariffs()
    res = {}
    for lease, own in _real_sandboxes(lab, owner).items():
        try:
            res[lease] = push_limits(lab, own, lease, tariffs)
        except Exception as exc:
            res[lease] = {"error": "%s: %s" % (type(exc).__name__, exc)}
    return res


def poll_limits(sup, g):
    """из OlifeHooks.poll: тарифы БД -> песочница группы (на случай перезапуска песочницы — с force)"""
    s = g.services.get("sandbox")
    if s is None or s.state != "up":
        return None
    return push_limits(sup.lab, g.owner, s.lease, sup.db.tariffs())


def tariff_set(lab, owner, key, value):
    """`lab olife tariff set` и шаг olife_tariff_set: БД + сразу во все песочницы (supervisor + свои)"""
    db = lab.sup.db
    if value is None or value == "" or value == "delete":
        db._exec("DELETE FROM tariffs WHERE key=?", (key,))
        r = {"key": key, "deleted": True}
    else:
        r = db.set_tariff(key, value, owner)
    db.event(None, None, None, "tariff_set", dict(r, by=owner))
    r["pushed"] = push_all(lab, owner) if key.startswith("limits.") else {}
    return r


# ============================================================================================== шаги
def _roles(sx):
    return P["_roles"](sx)


def _info(sx):
    return (sx.data.get("session") or {}).get("w4b") or {}


def _status_kv(sx, role, marker):
    return P["_status"](sx, role, marker)


def st_ticket_auth(sx, args, step):
    """tools/olife/ticket_check.py против шлюза сессии: good/replayed/expired/wrong_gateway/bad_signature/malformed/
    static/banned/bad token -> коды; плюс живость шлюза и мира"""
    _import_tools()
    import importlib
    tc = importlib.import_module("ticket_check")
    importlib.reload(tc)
    inf = _info(sx)
    roles = _roles(sx)
    gw_port = sx.lab.lease_info(roles["gateway"])["ports"]["gw"]
    rep = tc.run(gw_port, inf["auth_url"], inf["auth_ctl"], inf["gw_id"],
                 inf["auth_pub"] if args.get("sealed", True) else None, packs=bool(args.get("packs")),
                 static_mode=inf.get("auth_mode", "both"))
    try:
        gm = sx.call("metrics", lease=roles["gateway"])
        rep["gateway_tickets"] = gm.get("tickets")
        rep["gateway_rejects"] = gm.get("rejects")
    except Exception as exc:
        rep["gateway_error"] = str(exc)
    try:
        rep["auth_metrics"] = {k: v for k, v in sx.call("metrics", lease=inf["auth_lease"]).items() if k != "events"}
    except Exception as exc:
        rep["auth_error"] = str(exc)
    with open(os.path.join(sx.out_dir(), "olife_ticket_auth.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    table = [{k: r.get(k) for k in ("name", "want", "code", "ok", "ms", "reason")} for r in rep["results"]]
    sx.data.setdefault("metrics", {})["tickets"] = {"tests": rep["tests"], "passed": rep["passed"], "table": table,
                                                    "gateway": rep.get("gateway_tickets"),
                                                    "auth": rep.get("auth_metrics")}
    ok = rep["passed"] == rep["tests"]
    return {"ok": ok, "result": {"tests": rep["tests"], "passed": rep["passed"], "table": table,
                                 "gateway_tickets": rep.get("gateway_tickets")},
            "error": None if ok else "failed: %s" % [r["name"] for r in rep["results"] if not r["ok"]]}


def st_bots_check(sx, args, step):
    """боты в игре: state=play, tickets >= min_tickets (вход через HTTPS-билет), packs_* по ожиданию"""
    bots = {}
    for role, name in _roles(sx).items():
        if role.startswith("client") and sx.lab.leases[name].kind == "bot":
            bots[name] = _status_kv(sx, role, "status name=")
    bad = []
    for n, b in bots.items():
        if b.get("state") != "play":
            bad.append("%s state %s (%s)" % (n, b.get("state"), b.get("disconnect")))
        if int(b.get("tickets") or 0) < int(args.get("min_tickets", 0)):
            bad.append("%s tickets %s" % (n, b.get("tickets")))
    res = {n: {k: b.get(k) for k in ("state", "tickets", "ticket_ms", "reconnects", "self_div", "syncs",
                                     "packs_version", "packs_rev", "packs_path", "disconnect")} for n, b in bots.items()}
    sx.data.setdefault("metrics", {}).setdefault("bots_check", []).append(res)
    return {"ok": bool(bots) and not bad, "result": res, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------- тарифы
def _sandbox_rows(sx):
    wdir = sx.lab.lease_info(_roles(sx)["world"])["dir"]
    return P["read_jsonl"](os.path.join(wdir, "export", "sandbox_ticks.jsonl"))


def st_tariff_set(sx, args, step):
    """тариф в БД supervisor + доставка (как `lab olife tariff set`); фиксирует такт сервиса в момент доставки"""
    sb = _roles(sx)["sandbox"]
    before = sx.call("meters", {}, lease=sb)
    rows = _sandbox_rows(sx)
    t0 = time.time()
    res = []
    for key, val in (args.get("set") or {}).items():
        res.append(tariff_set(sx.lab, sx.owner, key, val))
        sx.data.setdefault("tariff_keys", set()).add(key)
    ms = round((time.time() - t0) * 1000, 1)
    lim = sx.call("limits", {}, lease=sb)
    mark = {"t": t0, "service_ticks": before.get("ticks"), "world_rows": len(rows),
            "last_row_tick": rows[-1]["tick"] if rows else None, "push_ms": ms}
    sx.data.setdefault("tariff_marks", []).append(mark)
    pushed = [p for r in res for v in (r.get("pushed") or {}).values() if isinstance(v, list) for p in v]
    ok = all(p.get("ok") for p in pushed) and bool(pushed) == bool(args.get("expect_push", True))
    out = {"mark": mark, "pushed": pushed, "limits": lim}
    sx.data.setdefault("metrics", {}).setdefault("tariff", []).append({"set": args.get("set"), "mark": mark,
                                                                       "pushed": pushed})
    return {"ok": ok, "result": out, "error": None if ok else "push failed: %s" % pushed}


def st_tariff_check(sx, args, step):
    """после последней доставки: у owner — status `want` (throttled) начиная не позже чем через `within` строк (тактов
    результата), у others — ни одного throttled; строки — export/sandbox_ticks.jsonl мира (по TickResult)"""
    time.sleep(float(args.get("wait_s", 2.0)))
    mark = (sx.data.get("tariff_marks") or [{}])[-1]
    rows = _sandbox_rows(sx)
    after = [r for r in rows if mark.get("last_row_tick") is None or r["tick"] > mark["last_row_tick"]]
    o, want = str(args["owner"]), args.get("want", "throttled")
    others = [str(x) for x in args.get("others") or []]
    first = None
    for i, r in enumerate(after):
        st = ((r.get("owners") or {}).get(o) or {}).get("st") or {}
        if st.get(want):
            first = i
            break
    n_after = len(after)
    hit = [r for r in after if (((r.get("owners") or {}).get(o) or {}).get("st") or {}).get(want)]
    oth_bad = {x: sum(1 for r in after if (((r.get("owners") or {}).get(x) or {}).get("st") or {}).get("throttled"))
               for x in others}
    oth_rows = {x: sum(1 for r in after if x in (r.get("owners") or {})) for x in others}
    within = int(args.get("within", 2))

    def avg(rows_, x, k):
        v = [((r.get("owners") or {}).get(x) or {}).get(k) or 0 for r in rows_ if x in (r.get("owners") or {})]
        return round(sum(v) / len(v), 2) if v else None
    before = [r for r in rows if mark.get("last_row_tick") is not None and r["tick"] <= mark["last_row_tick"]][-40:]
    tail = after[(first or 0) + 1:]
    fuel_rep = {x: {"fuel_before": avg(before, x, "fuel"), "fuel_after": avg(tail, x, "fuel"),
                    "moved_before": avg(before, x, "moved"), "moved_after": avg(tail, x, "moved")}
                for x in [o] + others}
    with open(os.path.join(sx.out_dir(), "olife_tariff_rows_%d.jsonl" % len(sx.data.get("metrics", {})
                                                                            .get("tariff_check", []))),
              "w", encoding="utf-8") as f:
        for r in before + after:
            f.write(json.dumps(r) + "\n")
    # такт, с которого сервис работает с новыми лимитами владельца (`limits` -> state.applied_tick): «следующий такт»
    applied = None
    try:
        lim = sx.call("limits", {"owner": int(o)}, lease=_roles(sx)["sandbox"])
        st_ = next((x.get("state") or {} for x in lim.get("owners") or [] if str(x.get("owner")) == o), {})
        applied = st_.get("applied_tick")
    except Exception as exc:
        lim = {"error": str(exc)}
    first_tick = after[first]["tick"] if first is not None else None
    bad = []
    if first is None:
        bad.append("owner %s never %s in %d rows after the change" % (o, want, n_after))
    elif applied is not None:
        if first_tick - applied >= within:
            bad.append("owner %s %s from tick %s, limits applied at tick %s (> %d ticks)" % (o, want, first_tick,
                                                                                           applied, within - 1))
    elif first >= within:
        bad.append("owner %s %s only from row %d after the change (> %d)" % (o, want, first + 1, within))
    share = len(hit) / max(1, n_after - (first or 0))
    if first is not None and share < float(args.get("min_share", 0)):
        bad.append("owner %s %s in %d of %d rows (< %.0f %%)" % (o, want, len(hit), n_after - first,
                                                               100 * float(args.get("min_share", 0))))
    fmax = args.get("max_fuel_per_row")             # средний расход топлива владельца на строку после смены
    if fmax is not None and (fuel_rep[o]["fuel_after"] or 0) > float(fmax):
        bad.append("owner %s fuel/row %s > %s" % (o, fuel_rep[o]["fuel_after"], fmax))
    for x in others:
        if oth_bad[x]:
            bad.append("owner %s throttled %d times" % (x, oth_bad[x]))
        if not oth_rows[x]:
            bad.append("owner %s absent after the change" % x)
    res = {"owner": o, "want": want, "rows_after": n_after, "first_row": None if first is None else first + 1,
           "first_tick": first_tick, "applied_tick": applied, "mark": mark,
           "owner_rows_with_want": len(hit), "share": round(share, 3), "fuel_per_row": fuel_rep,
           "others_throttled": oth_bad, "others_rows": oth_rows,
           "sample": after[first]["owners"].get(o) if first is not None else None}
    sx.data.setdefault("metrics", {}).setdefault("tariff_check", []).append(res)
    return {"ok": not bad, "result": res, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------- паки
def st_packs_change(sx, args, step):
    """изменить файл в копии паков сессии (что раздаёт шлюз) и пересобрать манифест"""
    from labcore import supervise
    pk = _info(sx)["packs"]
    fp = os.path.join(pk["root"], *args["path"].split("/"))
    os.makedirs(os.path.dirname(fp), exist_ok=True)
    if "text" in args:
        data = args["text"]
    else:
        with open(fp, encoding="utf-8") as f:
            data = f.read()
        data += args.get("append", "")
    with open(fp, "w", encoding="utf-8", newline="\n") as f:
        f.write(data)
    t0 = time.time()
    m = supervise.pack_manifest(pk["root"], P["CLIENT_PACKS"], pk["manifest"])
    mark = {"t": t0, "path": args["path"], "version": m["version"], "files": m["files"]}
    sx.data.setdefault("packs_marks", []).append(mark)
    return {"ok": True, "result": mark}


def st_packs_wait(sx, args, step):
    """каждый бот применил последнюю версию манифеста: packs_version, packs_rev (если задан), путь пака (reopen ->
    world:content/olife_client) и снова в игре; время от правки до применения — по статусу ботов"""
    mark = (sx.data.get("packs_marks") or [{}])[-1]
    want_v = (mark.get("version") or "")[:12]
    end = time.time() + float(args.get("timeout", 30))
    last = {}
    while time.time() < end:
        done = True
        for role, name in _roles(sx).items():
            if not (role.startswith("client") and sx.lab.leases[name].kind == "bot"):
                continue
            b = _status_kv(sx, role, "status name=")
            if name not in last or not last[name].get("_done"):
                b["_t"] = round(time.time() - mark.get("t", time.time()), 2)
                ok = str(b.get("packs_version")) == want_v
                if "rev" in args:
                    ok = ok and str(b.get("packs_rev")) == str(args["rev"])
                if args.get("reopen"):
                    ok = ok and str(b.get("packs_path", "")).startswith("world:content") and b.get("state") == "play"
                b["_done"] = ok
                last[name] = b
            done = done and last[name]["_done"]
        if done and last:
            break
        time.sleep(0.5)
    gm = None
    try:
        gm = sx.call("metrics", lease=_roles(sx)["gateway"]).get("packs")
    except Exception:
        pass
    res = {"version": want_v, "path": mark.get("path"), "gateway_packs": gm,
           "bots": {n: {k: b.get(k) for k in ("_done", "_t", "state", "packs_version", "packs_rev", "packs_path",
                                              "packs_applied", "packs_live", "packs_reopen", "packs_dl",
                                              "reconnects", "self_div")} for n, b in last.items()}}
    sx.data.setdefault("metrics", {}).setdefault("packs", []).append(res)
    bad = [n for n, b in last.items() if not b.get("_done")]
    return {"ok": bool(last) and not bad, "result": res, "error": "not applied: %s" % bad if bad else None}


# ---------------------------------------------------------------- песочница: байты на проводе
def st_sandbox_wire(sx, args, step):
    """байты мир<->песочница на такт (статус моста: sent/results, bytes_out/bytes_in) и транспорт"""
    wl = _roles(sx)["world"]
    r = sx.lab.stdin(wl, "status", owner=sx.owner, wait=3.0, pattern=r"status\stick=")
    line = next((x for x in reversed(r["lines"]) if "status tick=" in x), "")
    i = line.find("sandbox=")
    sb = line[i + 8:].split(" ")[0] if i >= 0 else ""
    kv = {}
    if "(" in sb:
        for tok in sb[sb.find("(") + 1:].rstrip(")").split(","):
            if "=" in tok:
                k, v = tok.split("=", 1)
                try:
                    kv[k] = float(v)
                except ValueError:
                    kv[k] = v
    proto = sb.split("(")[0]
    res = {"proto": proto, "sent": kv.get("sent"), "results": kv.get("results"), "bytes_out": kv.get("bytes_out"),
           "bytes_in": kv.get("bytes_in"), "late": kv.get("late"), "skipped": kv.get("skipped"),
           "in_per_tick": round(kv["bytes_out"] / kv["sent"]) if kv.get("sent") and kv.get("bytes_out") else None,
           "result_per_tick": round(kv["bytes_in"] / kv["results"]) if kv.get("results") and kv.get("bytes_in")
           else None, "in_ms_avg": kv.get("in_ms_avg"), "res_ms_avg": kv.get("res_ms_avg")}
    sx.data.setdefault("metrics", {})["sandbox_wire"] = res
    want = args.get("proto")
    ok = bool(kv) and (not want or proto.endswith(want))
    return {"ok": ok, "result": res, "error": None if ok else "bridge status: %s" % sb[:200]}


def on_stop(sx):
    """конец сценария (и при провале): ключи тарифов, которые ставил сценарий, удалить из БД (общая БД supervisor)"""
    keys = sorted(sx.data.get("tariff_keys") or [])
    if keys:
        for k in keys:
            sx.lab.sup.db._exec("DELETE FROM tariffs WHERE key=?", (k,))
        sx.data.setdefault("metrics", {})["tariff_cleanup"] = keys


def steps():
    return {"olife_ticket_auth": st_ticket_auth, "olife_bots_check": st_bots_check,
            "olife_tariff_set": st_tariff_set, "olife_tariff_check": st_tariff_check,
            "olife_packs_change": st_packs_change, "olife_packs_wait": st_packs_wait,
            "olife_sandbox_wire": st_sandbox_wire}


def f_limits(ctx, args):
    """olife.limits {push=false} — тарифы limits.* из БД -> какие set_limits ушли бы/ушли (push) песочницам"""
    t = ctx.lab.sup.db.tariffs()
    out = {"limits": limits_from_tariffs(t), "sandboxes": _real_sandboxes(ctx.lab, ctx.owner)}
    if args.get("push"):
        out["pushed"] = push_all(ctx.lab, ctx.owner)
    return out


def register(api):
    api.feature("limits", f_limits, "sandbox limits from DB tariffs (limits.default.<f>, limits.owner.<n>.<f>) "
                "{push=false}", {"type": "object"})


def selftest():
    lt = limits_from_tariffs({"limits.default.fuel_per_tick": 1e6, "limits.owner.7.max_actions": 8,
                              "limits.owner.7.bogus": 1, "credits.per_kb_up": 0.02})
    assert lt == {"*": {"fuel_per_tick": 1000000}, "7": {"max_actions": 8}}, lt
