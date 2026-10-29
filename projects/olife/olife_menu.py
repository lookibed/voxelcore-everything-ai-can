"""olife UX B (16.10, агент olife_menu): меню клиента, экран статуса входа, вайтлист по нику. Подключается из plugin.py
(`_menu()`, перезагрузка по mtime; шаги и возможности — обёртки, функция берётся из свежего модуля).

Клиент (content/olife_client): app-скрипт scripts/app/olife.lua -> страница меню layouts/pages/olife_menu.xml (3D-сценка
<modelviewer> по VCM models/olife_menu_scene.vcm, ip:port, ник, «Войти», последние серверы в config:) -> экран статуса
layouts/pages/olife_status.xml (модуль состояния olife_client:status; модуль входа olife_client:login) -> игра (HUD-статус
layouts/olife_status.xml: паки на лету, «мир перезапускается»). F2F `menu` (страница меню/статуса и мир) — снимок
состояния: поля, прямоугольники кнопок, строки статуса, ошибки, баннеры.

Вайтлист (п.3): БД supervisor, таблица account_settings (миграция 3, без новой схемы): account = "_wl:<scope>",
key = <ник> -> "1"; key = "_enabled" -> on|off. scope = id шлюза билетов (аудитория билета: игра пользователя —
gw-olife-play, сессия сценария — gw-<sid>), "*" — все шлюзы. Сервис билетов при входе по нику (без токена) спрашивает
`POST /call/olife.auth_name {name, ip, gateway}`. Управление — `lab olife whitelist ...` (cli_sup.py) = `/whitelist ...` в
чате админа (мир -> HTTP демона, --opts sup=<порт>,wl=<scope>) = кнопки панели /sup/panel (секция Whitelist).

Шаги сценариев `olife_menu_status` (все фазы и ошибки) и `olife_menu_whitelist`: см. NAMES и docstring'и."""
import json
import os
import re
import socket
import threading
import time
import urllib.request

P = {}                                      # глобалы plugin.py (bind)
NICK_RX = re.compile(r"^[A-Za-z0-9_.\-]{2,24}$")
PLAY_SCOPE = "gw-olife-play"


def bind(g):
    P.update(g)


# ============================================================================================== вайтлист (п.3)
def _sdb(lab):
    return P["_a1"]().social(lab.sup.db)


def wl_acct(scope):
    return "_wl:%s" % (scope or "*")


def wl_state(lab, scope):
    """-> {scope, enabled, names, global_enabled, global_names}"""
    sdb = _sdb(lab)
    own = sdb.settings_of(wl_acct(scope))
    glob = sdb.settings_of(wl_acct("*")) if scope != "*" else own
    return {"scope": scope, "enabled": own.get("_enabled") == "on",
            "names": sorted(k for k, v in own.items() if not k.startswith("_") and v == "1"),
            "global_enabled": glob.get("_enabled") == "on",
            "global_names": sorted(k for k, v in glob.items() if not k.startswith("_") and v == "1")}


def wl_op(lab, op, scope, name=None, by=None, via="cli"):
    sdb = _sdb(lab)
    scope = scope or PLAY_SCOPE
    acct = wl_acct(scope)
    if op in ("add", "remove"):
        if not name or not NICK_RX.match(name):
            return {"ok": False, "code": "bad_name", "reason": "nick: 2..24 of A-Z a-z 0-9 _ . -"}
        sdb.setting_set(acct, name, "1" if op == "add" else None, by)
    elif op in ("on", "off"):
        sdb.setting_set(acct, "_enabled", "on" if op == "on" else None, by)     # off = no row (nothing left behind)
    elif op not in ("list", "status"):
        return {"ok": False, "code": "args", "reason": "op: list|add|remove|on|off"}
    st = wl_state(lab, scope)
    if op != "list":
        _audit(lab, {"by": by, "via": via, "op": op, "scope": scope, "name": name, "enabled": st["enabled"]})
    st["ok"], st["op"] = True, op
    st["text"] = "whitelist %s: %s, %d: %s%s" % (scope, "on" if st["enabled"] else "off", len(st["names"]),
                                                ", ".join(st["names"]) or "-",
                                                "" if scope == "*" else " (global *: %s, %d)" % (
                                                    "on" if st["global_enabled"] else "off", len(st["global_names"])))
    return st


def _audit(lab, rec):
    try:
        d = os.path.join(lab.data, "olife")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "whitelist_audit.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(dict(rec, ts=time.time()), ensure_ascii=False) + "\n")
    except OSError:
        pass


def auth_name(lab, name, ip=None, gateway=None):
    """вход по нику (сервис билетов) -> {ok, account, role} | {ok: false, code, reason}"""
    db = lab.sup.db
    F = P["_fraud"]()                       # antifraud 16.10: IP ban/rates, reserved/similar nicks (olife_fraud.py)
    scope = (gateway or "*").replace("auth:", "")

    def login(ok, reason=None):
        db._exec("INSERT INTO logins(ts, account, ip, gateway, ok, reason) VALUES(?,?,?,?,?,?)",
                 (time.time(), name if isinstance(name, str) else None, ip, "nick:" + scope, 1 if ok else 0, reason))
    pre = F.nick_precheck(lab, name, ip, scope)
    if pre:
        login(False, pre["code"])
        return pre
    if not isinstance(name, str) or not NICK_RX.match(name):
        return {"ok": False, "code": "bad_name", "reason": "nick: 2..24 of A-Z a-z 0-9 _ . -"}
    with db.lock:
        row = db.db.execute("SELECT name, role, token_hash FROM accounts WHERE name=?", (name,)).fetchone()
    if row is not None and row["token_hash"]:
        login(False, "nick_reserved")
        return {"ok": False, "code": "nick_reserved",
                "reason": "nick %s belongs to an account with a token: log in with its token" % name}
    ban = db.ban_of(name, ip)
    if ban:
        why = "banned%s: %s" % (" until %s" % time.strftime("%Y-%m-%d %H:%M", time.localtime(ban["until"]))
                                if ban["until"] else "", ban["reason"] or "")
        login(False, why)
        return {"ok": False, "code": "banned", "reason": why[:200], "until": ban["until"]}
    st = wl_state(lab, scope)
    if st["enabled"] or st["global_enabled"]:
        if name not in st["names"] and name not in st["global_names"]:
            login(False, "whitelist")
            return {"ok": False, "code": "whitelist",
                    "reason": "nick %s is not on the whitelist of %s" % (name, scope)}
    post = F.nick_postcheck(lab, name, ip, scope)
    if post:
        login(False, post["code"])
        return post
    F.note_login(lab, name, ip)
    if row is None:
        db.add_account(name, None, "player", note="nick login (UX B whitelist) %s" % scope)
    with db.lock:
        db.db.execute("UPDATE accounts SET last_seen=? WHERE name=?", (time.time(), name))
        db.db.commit()
    login(True)
    return {"ok": True, "account": name, "role": row["role"] if row is not None else "player"}


def scope_of(lab, args, owner=None):
    """--gw <id> | --session S (gw-<S>) | play (gw-olife-play)"""
    if args.get("scope"):
        return args["scope"]
    if args.get("session"):
        return "gw-%s" % args["session"]
    return PLAY_SCOPE


def f_auth_name(ctx, args):
    return auth_name(ctx.lab, args.get("name"), args.get("ip"), args.get("gateway"))


def f_whitelist(ctx, args):
    op = args.get("op") or "list"
    return wl_op(ctx.lab, op, scope_of(ctx.lab, args), args.get("name"), by=args.get("by") or ctx.owner,
                 via=args.get("via") or "cli")


def world_opts(lab, opts, scope):
    """--opts мира + sup=<порт демона>,wl=<scope> (/whitelist в чате -> POST /call/olife.whitelist)"""
    base = opts if opts and opts != "none" else "none"
    return "%s,sup=%d,wl=%s" % (base, int(lab.cfg["daemon"]["port"]), scope)


def register(api):
    obj = {"type": "object"}
    api.feature("auth_name", lambda ctx, a: P["_menu"]().f_auth_name(ctx, a),
                "UX B: nick login check for the auth service {name, ip?, gateway?} -> {ok, account} | {code: "
                "bad_name|nick_reserved|banned|whitelist, reason}", obj)
    api.feature("whitelist", lambda ctx, a: P["_menu"]().f_whitelist(ctx, a),
                "UX B: whitelist by nick {op=list|add|remove|on|off, name?, scope? (gateway id; default gw-olife-play; "
                "'*' = all) | session?}", obj)


# ============================================================================================== шаги
def _w():
    return P["_w4a"]()


def _client(sx):
    return sx.data["menu"]["lease"]


def mstate(sx, op=None, **a):
    if op:
        a["op"] = op
    r = sx.raw("menu", a, lease=_client(sx))
    if not r.get("ok"):
        raise RuntimeError("menu F2F: %s" % r.get("error"))
    return r["result"]


def _md(sx):
    return sx.data.setdefault("menu", {"checks": [], "cases": {}, "shots": {}})


def _check(sx, name, ok, detail=None):
    _md(sx)["checks"].append({"name": name, "ok": bool(ok), "detail": detail})
    return bool(ok)


def _shot(sx, name):
    p = _w().shot(sx, _client(sx), "menu_" + name)
    _md(sx)["shots"][name] = p
    return p


def _session(sx):
    return sx.data["session"]


def _w4b(sx):
    return _session(sx).get("w4b") or {}


def write_config(sx, account="dev", token="olife-dev", name=None, extra=None):
    """export\\olife_server.txt клиента (формат config_text лаборатории)"""
    s, w = _session(sx), _w4b(sx)
    lines = ["# olife_menu test %s" % s["session"], "gateway=127.0.0.1:%d" % s["gateway_port"]]
    if w.get("auth_url"):
        lines += ["auth=%s" % w["auth_url"], "gw_id=%s" % w["gw_id"], "auth_pub=%s" % w["auth_pub"], "auth_verify=0"]
    if account:
        lines += ["account=%s" % account, "name=%s" % (name or account)]
    if token:
        lines.append("token=%s" % token)
    lines.append("reconnect=3")
    for k, v in (extra or {}).items():
        lines.append("%s=%s" % (k, v))
    return "\n".join(lines) + "\n"


def _cfg_path(sx, tag):
    d = os.path.join(sx.lab.data, "olife", "menu")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "%s_%s.txt" % (_session(sx)["session"], tag))


def st_start(sx, args, step):
    """клиент F2F 0.32 с app-скриптом пака (= «Сценарии» -> olife): главное меню — страница olife_menu, 3D-сценка
    (VCM, вращение камеры), поля из export:olife_server.txt (автозаполнение), последние серверы"""
    md = _md(sx)
    path = _cfg_path(sx, "autofill")
    if args.get("config", "session") == "empty":
        text = "# empty\n"
    else:
        text = write_config(sx, args.get("account", "dev"), args.get("token", "olife-dev"))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    t0 = time.time()
    lease = sx.lease("menu_app", role="client1", params={"config": path, "autologin": int(args.get("autologin", 0))})
    md["lease"] = lease
    md["config_path"] = path
    md["lease_dir"] = sx.lab.lease_info(lease)["dir"]
    W = _w()
    st = W.wait_for(lambda: (lambda r: r if r.get("page") == "menu" and r.get("menu_doc_ok") else None)(
        _try(lambda: mstate(sx))), float(args.get("timeout", 40)))
    rep = {"start_s": round(time.time() - t0, 2)}
    bad = []
    if not st:
        return {"ok": False, "error": "menu page not shown: %s" % _try(lambda: mstate(sx))}
    a1 = (st.get("scene") or {}).get("angle")
    time.sleep(0.8)
    st2 = mstate(sx)
    a2 = (st2.get("scene") or {}).get("angle")
    rep["scene"] = {"src": st2.get("scene_src"), "angle0": a1, "angle1": a2, "recreated": (st2.get("scene") or {}).get("n"),
                    "err": (st2.get("scene") or {}).get("err"), "rect": (st2.get("menu_rects") or {}).get("mn_scene")}
    if not _check(sx, "menu: modelviewer src = VCM olife_menu_scene", st2.get("scene_src") == "olife_menu_scene",
                  st2.get("scene_src")):
        bad.append("scene src %s" % st2.get("scene_src"))
    turned = a1 is not None and a2 is not None and 0.5 < ((a2 - a1) % 360) < 60
    if not _check(sx, "menu: camera turns slowly (8 deg/s)", turned, [a1, a2]):
        bad.append("scene angle %s -> %s" % (a1, a2))
    rep["fields"], rep["autofill"], rep["texts"] = st2.get("fields"), st2.get("autofill"), st2.get("texts")
    if args.get("config", "session") != "empty":
        want = "127.0.0.1:%d" % _session(sx)["gateway_port"]
        if not _check(sx, "menu: autofill address/nick", (st2.get("texts") or {}).get("addr") == want and
                      (st2.get("texts") or {}).get("nick") == args.get("account", "dev"), st2.get("texts")):
            bad.append("autofill fields %s, want %s" % (st2.get("texts"), want))
    rep["rects"] = {k: v for k, v in (st2.get("menu_rects") or {}).items() if v}
    rep["shot"] = _shot(sx, args.get("shot", "main"))
    # the form: a bad nick -> no login, a hint in red, the button flashes, the refusal sound (fx deny = `refuse`)
    if args.get("form_check", True):
        nick0 = (st2.get("texts") or {}).get("nick")
        fx0 = (st2.get("fx") or {}).get("n", 0)
        _type_into(sx, "mn_nick", "x")
        _click(sx, "mn_login")
        time.sleep(0.3)
        st3 = mstate(sx)
        evs = [e.get("event") for e in (st3.get("fx") or {}).get("last") or []]
        snd = [e.get("sound") for e in (st3.get("fx") or {}).get("last") or []]
        okf = (st3.get("presses") or {}).get("invalid", 0) >= 1 and (st3.get("status") or {}).get("attempt", 0) == 0 \
            and "ник" in ((st3.get("texts") or {}).get("hint") or "") and (st3.get("fx") or {}).get("n", 0) > fx0 \
            and "deny" in evs and (st3.get("flashes") or 0) >= 1
        rep["form"] = {"hint": (st3.get("texts") or {}).get("hint"), "fx_events": evs, "sounds": snd,
                       "flashes": st3.get("flashes"), "attempt": (st3.get("status") or {}).get("attempt")}
        if not _check(sx, "menu: bad nick -> hint, flash, refusal sound, no login", okf, rep["form"]):
            bad.append("form check %s" % rep["form"])
        _type_into(sx, "mn_nick", nick0 or "dev")
    md["start"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# engine's own pages at 854x480 (res/layouts/pages/main.xml, scripts.xml of 0.32): button centres, frame pixels
ENGINE_MAIN_SCRIPTS = (427, 202)        # «Сценарии»
ENGINE_SCRIPTS_FIRST = (427, 237)       # the first script of the list = «olife [olife_client]» (the only app script)


def st_engine_path(sx, args, step):
    """путь пользователя без lab: VoxelCore 0.32 (F2F) в главном меню движка -> «Сценарии» -> olife [olife_client] ->
    меню клиента (страница olife_menu, автозаполнение) -> «Выход» -> снова главное меню движка (скрипт закончился)"""
    W = _w()
    path = _cfg_path(sx, "engine")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(write_config(sx, "dev", "olife-dev"))
    lease = sx.lease("menu_client", role="client_engine", params={"config": path})
    rep, bad = {}, []
    time.sleep(1.0)
    for name, (x, y) in (("scripts", ENGINE_MAIN_SCRIPTS), ("olife", ENGINE_SCRIPTS_FIRST)):
        W.click(sx, lease, {"cx": x, "cy": y})
        time.sleep(0.8)
    st = W.wait_for(lambda: (lambda r: r if r.get("page") == "menu" else None)(
        _try(lambda: (sx.raw("menu", {}, lease=lease).get("result") or {}))), 15)
    rep["menu"] = {"page": (st or {}).get("page"), "texts": (st or {}).get("texts")}
    if not st:
        bad.append("Сценарии -> olife did not open the client's menu")
    else:
        want = "127.0.0.1:%d" % _session(sx)["gateway_port"]
        if (st.get("texts") or {}).get("addr") != want:
            bad.append("autofill %s" % st.get("texts"))
        rep["shot"] = W.shot(sx, lease, "menu_engine_path")
        q = (st.get("menu_rects") or {}).get("mn_quit")
        W.click(sx, lease, q)
        end = time.time() + 10
        fin = False
        while time.time() < end and not fin:
            lg = sx.lab.logs(lease, stream="stdout", tail=40, grep="client script finished")
            fin = bool(lg.get("lines"))
            time.sleep(0.2)
        rep["quit_to_engine_menu"] = fin
        if not fin:
            bad.append("Выход did not end the client script")
        rep["shot_after"] = W.shot(sx, lease, "menu_engine_after_quit")
    try:
        sx.lab.release(lease, owner=sx.owner, reason="step done")
        sx.leases.pop("client_engine", None)
    except Exception:
        pass
    _check(sx, "engine menu: Сценарии -> olife -> client menu -> Выход", not bad, bad or None)
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def _try(fn, default=None):
    try:
        return fn()
    except Exception:
        return default or {}


def _rect(st, name):
    r = (st.get("menu_rects") or {}).get(name)
    if r:
        return r
    sp = st.get("status_page") or {}
    return (sp.get("rects") or {}).get(name)


def _click(sx, name, st=None):
    st = st or mstate(sx)
    r = _rect(st, name)
    if not r:
        raise RuntimeError("no rect %s on page %s" % (name, st.get("page")))
    _w().click(sx, _client(sx), r)
    return r


def _type_into(sx, field, text):
    """клик в поле, Ctrl+A, набор (замена выделенного), проверка текста; запасной путь — Backspace"""
    W = _w()
    C = _client(sx)
    _click(sx, field)
    time.sleep(0.08)
    W.inp(sx, C, keys={"left-ctrl": True})
    W.press_key(sx, C, "a", hold=0.05)
    W.inp(sx, C, keys={"left-ctrl": False})
    time.sleep(0.05)
    W.inp(sx, C, chars=text)
    time.sleep(0.15)
    key = {"mn_addr": "addr", "mn_nick": "nick"}[field]
    got = (mstate(sx).get("texts") or {}).get(key)
    if got != text:
        _click(sx, field)
        for _ in range(len(got or "") + 4):
            W.press_key(sx, C, "end", hold=0.02)
            W.press_key(sx, C, "backspace", hold=0.02)
        W.inp(sx, C, chars=text)
        time.sleep(0.15)
        got = (mstate(sx).get("texts") or {}).get(key)
    return got


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Silent:
    """TCP-сервер, который принимает соединения и молчит (шлюз завис: нет Welcome)"""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.conns, self.accepted, self.stop = [], 0, False
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while not self.stop:
            try:
                c, _ = self.sock.accept()
                self.accepted += 1
                self.conns.append(c)
            except OSError:
                return

    def close(self):
        self.stop = True
        for c in self.conns:
            try:
                c.close()
            except OSError:
                pass
        self.sock.close()


class Mitm:
    """HTTP-«посредник» перед раздачей паков шлюза: пересылает GET, а файл `swap` (pack/path) подменяет (другие байты
    при том же манифесте) — клиент обязан поймать расхождение sha256."""

    def __init__(self, upstream_port, swap):
        import http.server
        mitm = self
        self.upstream, self.swap, self.served, self.swapped = upstream_port, swap, 0, 0

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                try:
                    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (mitm.upstream, self.path), timeout=5) as r:
                        data, code = r.read(), r.status
                except urllib.error.HTTPError as e:
                    data, code = e.read(), e.code
                except Exception as exc:
                    data, code = str(exc).encode(), 502
                if self.path == "/files/" + mitm.swap:
                    data = data.replace(b"return", b"return --[[ swapped in transit ]]", 1) + b"\n-- mitm\n"
                    mitm.swapped += 1
                mitm.served += 1
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def _addr(sx, spec):
    s = _session(sx)
    if spec in (None, "session"):
        return "127.0.0.1:%d" % s["gateway_port"]
    if spec == "free":
        return "127.0.0.1:%d" % _free_port()
    if spec.startswith("port:"):
        return "127.0.0.1:%s" % spec.split(":", 1)[1]
    return spec


def wait_result(sx, attempt0, timeout):
    """ждать, пока попытка входа (attempt > attempt0) закончится: done (в игре) или error; -> (state, samples)"""
    end = time.time() + timeout
    samples, last = [], {}
    while time.time() < end:
        st = _try(lambda: mstate(sx))
        s = st.get("status") or {}
        if s.get("attempt", 0) > attempt0:
            sp = st.get("status_page") or {}
            if sp.get("lines"):
                samples.append({"t": round(time.time() - (end - timeout), 2), "current": s.get("current"),
                                "page_lines": sp.get("lines"), "progress": s.get("progress_text"),
                                "file": s.get("current_file")})
            if s.get("error") or (s.get("done") and (st.get("client") or {}).get("state") == "play"):
                return st, samples
        last = st
        time.sleep(0.05)
    return last, samples


def _login(sx, args, step_name):
    """заполнить поля (если заданы), нажать кнопку (Войти / Повторить), дождаться конца попытки, проверить ожидание.
    expect: "play" | {"kind", "code", "phase", "text"}; then: "back" (на меню) | "leave" (из игры в меню) | "stay"."""
    md = _md(sx)
    st0 = mstate(sx)
    attempt0 = (st0.get("status") or {}).get("attempt", 0)
    rep = {"step": step_name}
    if args.get("button", "login") == "login":
        if st0.get("page") != "menu":
            return {"ok": False, "error": "not on the menu page: %s" % st0.get("page")}
        if args.get("addr") is not None:
            rep["addr"] = _type_into(sx, "mn_addr", _addr(sx, args["addr"]))
        if args.get("nick") is not None:
            rep["nick"] = _type_into(sx, "mn_nick", args["nick"])
        _click(sx, "mn_login")
    else:
        _click(sx, "st_retry", st0)
    t0 = time.time()
    st, samples = wait_result(sx, attempt0, float(args.get("timeout", 45)))
    rep["s"] = round(time.time() - t0, 2)
    s = st.get("status") or {}
    rep["lines"] = s.get("lines")
    rep["error"] = s.get("error")
    rep["error_text"] = s.get("error_text")
    rep["phases"] = {p["id"]: p["state"] for p in s.get("phases") or []}
    rep["phase_ms"] = {p["id"]: p.get("ms") for p in s.get("phases") or [] if p.get("ms") is not None}
    rep["client"] = st.get("client")
    rep["packs"] = st.get("packs")
    rep["log"] = [(x.get("phase"), x.get("state")) for x in (s.get("log") or [])[-40:]]
    rep["samples"] = samples[:3] + samples[-3:] if len(samples) > 6 else samples
    rep["progress_seen"] = sorted({x["progress"] for x in samples if x.get("progress")})[:8]
    rep["files_seen"] = sorted({x["file"] for x in samples if x.get("file")})[:8]
    exp = args.get("expect", "play")
    bad = []
    if exp == "play":
        if not (s.get("done") and (st.get("client") or {}).get("state") == "play"):
            bad.append("not in play: %s" % (s.get("error_text") or rep["phases"]))
        for p in s.get("phases") or []:
            if p["state"] not in ("ok", "skip"):
                bad.append("phase %s %s" % (p["id"], p["state"]))
        seq = [ph for ph, state in rep["log"] if state == "run"]
        for need in args.get("phases_run") or []:
            if need not in seq:
                bad.append("phase %s never ran (runs: %s)" % (need, seq))
        for need in args.get("phases_skip") or []:
            if rep["phases"].get(need) != "skip":
                bad.append("phase %s is %s, want skip" % (need, rep["phases"].get(need)))
        if args.get("rev") is not None and (rep["packs"] or {}).get("rev") != args["rev"]:
            bad.append("packs rev %s, want %s" % ((rep["packs"] or {}).get("rev"), args["rev"]))
    else:
        e = s.get("error") or {}
        if not e:
            bad.append("no error (phases %s)" % rep["phases"])
        else:
            if exp.get("kind") and e.get("kind") != exp["kind"]:
                bad.append("error kind %s, want %s" % (e.get("kind"), exp["kind"]))
            if exp.get("code") is not None and str(e.get("code")) != str(exp["code"]):
                bad.append("error code %s, want %s" % (e.get("code"), exp["code"]))
            if exp.get("phase") and e.get("phase") != exp["phase"]:
                bad.append("error phase %s, want %s" % (e.get("phase"), exp["phase"]))
            if exp.get("text") and exp["text"].lower() not in (e.get("text") or "").lower():
                bad.append("error text %r has no %r" % (e.get("text"), exp["text"]))
            # the page draws what the state says (gate by text): lines, the error line, Повторить visible
            sp = st.get("status_page") or {}
            if sp.get("lines") != s.get("lines"):
                bad.append("page lines differ from the state: %s" % sp.get("lines"))
            tx = sp.get("texts") or {}
            et = " ".join(x for x in (tx.get("st_err1"), tx.get("st_err2"), tx.get("st_err3")) if x)
            norm = lambda x: "".join((x or "").split())          # noqa: E731 (3 label lines, cut at spaces)
            full = norm(s.get("error_text"))
            if not (full.startswith(norm(et)) and len(norm(et)) >= min(len(full), 150)):
                bad.append("page error lines %r do not show %r" % (et, s.get("error_text")))
            if not ((sp.get("rects") or {}).get("st_retry") or {}).get("visible"):
                bad.append("Повторить not visible")
            rep["page_error_line"] = et
    rep["shot"] = _shot(sx, args.get("shot") or step_name)
    if exp == "play" and args.get("after_shots", True):
        # coordinator 16.10: never an empty status panel over the game. 1 s and 3 s after the login: if the HUD status
        # (or the menu status page) is visible, it must show phase lines (state of status.lua and the label nodes)
        rep["after"] = {}
        for at in (1.0, 3.0):
            dt = t0 + rep["s"] + at - time.time()
            if dt > 0:
                time.sleep(dt)
            sa = _try(lambda: mstate(sx))
            seen = {}
            for which in ("status_hud", "status_page"):
                v = sa.get(which) or {}
                if not v:
                    continue
                vis = bool(v.get("visible", ((v.get("rects") or {}).get("root") or {}).get("visible")))
                lines = [x for x in (v.get("lines") or []) if x]
                seen[which] = {"visible": vis, "lines": len(lines), "title": (v.get("texts") or {}).get("st_title"),
                               "first": lines[0] if lines else None}
                if vis and not lines:
                    bad.append("%s visible %.0f s after the login with no phase lines (title %r)" % (
                        which, at, (v.get("texts") or {}).get("st_title")))
                if which == "status_hud" and at >= 3.0 and vis and not (sa.get("status") or {}).get("banner"):
                    bad.append("HUD status still visible %.0f s after the login (no banner): %s" % (
                        at, {k: v.get(k) for k in ("seq", "state_seq", "vis", "hold", "since_done")}))
                if vis and (v.get("texts") or {}).get("st_title") in (None, "", "Olife"):
                    bad.append("%s visible %.0f s after the login with the default title" % (which, at))
            seen["status_mode"] = (sa.get("status") or {}).get("mode")
            seen["banner"] = (sa.get("status") or {}).get("banner")
            seen["shot"] = _shot(sx, "%s_%ds" % (args.get("shot") or step_name, int(at)))
            rep["after"]["%ds" % int(at)] = seen
    then = args.get("then", "back" if exp != "play" else "stay")
    if then == "back":
        _click(sx, "st_back")
        ok = _w().wait_for(lambda: _try(lambda: mstate(sx)).get("page") == "menu", 8)
        rep["back"] = bool(ok)
        if not ok:
            bad.append("Назад did not return to the menu")
    elif then == "leave":
        rep["leave"] = leave(sx)
        if not rep["leave"].get("menu"):
            bad.append("leave: not back on the menu %s" % rep["leave"])
    _check(sx, step_name, not bad, bad or None)
    md["cases"][step_name] = {k: rep.get(k) for k in ("s", "error", "phases", "phase_ms", "page_error_line", "shot")}
    md.setdefault("details", {})[step_name] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def leave(sx):
    t0 = time.time()
    mstate(sx, "leave")
    ok = _w().wait_for(lambda: (lambda st: st.get("page") == "menu" and not st.get("world_open"))(
        _try(lambda: mstate(sx))), 15)
    return {"menu": bool(ok), "s": round(time.time() - t0, 2)}


def st_login(sx, args, step):
    return _login(sx, args, args.get("name") or "login")


def st_leave(sx, args, step):
    r = leave(sx)
    return {"ok": r["menu"], "result": r, "error": None if r["menu"] else "not back on the menu"}


def _packs_change(sx, path, text=None, append=None, regen=True):
    """файл в копии паков сессии (что раздаёт шлюз); regen=False — без нового манифеста (шлюз ответит 409)"""
    from labcore import supervise
    pk = _w4b(sx)["packs"]
    fp = os.path.join(pk["root"], *path.split("/"))
    if text is None:
        with open(fp, encoding="utf-8") as f:
            text = f.read() + (append or "")
    with open(fp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if regen:
        m = supervise.pack_manifest(pk["root"], P["CLIENT_PACKS"], pk["manifest"])
        return {"version": m["version"], "files": m["files"]}
    return {"regen": False}


def st_packs(sx, args, step):
    """правка раздачи (rev.lua / любой файл) — до входа: клиент скачает её на экране статуса"""
    r = _packs_change(sx, args["path"], args.get("text"), args.get("append"), bool(args.get("regen", True)))
    return {"ok": True, "result": r}


def _banners_since(st, n0):
    s = st.get("status") or {}
    return (s.get("banner_log") or [])[n0:] if isinstance(s.get("banner_log"), list) else []


def st_ingame(sx, args, step):
    """в игре: what = packs_live (rev.lua -> применено вживую, баннер), packs_reopen (scripts/world.lua -> переоткрытие
    мира, вход заново), restart (стоп/старт мира: «мир перезапускается, держитесь», фазы переподключения, снова в игре).
    Проверка — по баннерам и строкам статуса (F2F menu), HUD-элемент видим во время события."""
    what = args["what"]
    st0 = mstate(sx)
    if (st0.get("client") or {}).get("state") != "play":
        return {"ok": False, "error": "client not in play: %s" % st0.get("client")}
    n0 = (st0.get("status") or {}).get("banners", 0)
    rec0 = (st0.get("client") or {}).get("reconnects") or 0
    rep = {"what": what}
    bad = []
    t0 = time.time()
    if what == "packs_live":
        rev = int(args.get("rev", 6))
        rep["change"] = _packs_change(sx, "olife_client/modules/hot/rev.lua",
                                      "-- olife_menu: live pack change\nreturn {rev = %d}\n" % rev)
    elif what == "packs_reopen":
        rep["change"] = _packs_change(sx, "olife_client/scripts/world.lua",
                                      append="\n-- olife_menu: needs a world reopen %d\n" % int(time.time()))
    elif what == "restart":
        roles = P["_roles"](sx)

        def bounce():                   # in the background: the step watches the client meanwhile
            try:
                sx.lab.stop(roles["world"], owner=sx.owner)
                rep["world_stopped_s"] = round(time.time() - t0, 2)
                time.sleep(float(args.get("down_s", 2)))
                sx.lab.start(roles["world"], owner=sx.owner)
                rep["world_restart_s"] = round(time.time() - t0, 2)
            except Exception as exc:
                rep["world_restart_error"] = "%s: %s" % (type(exc).__name__, exc)
        th = threading.Thread(target=bounce, daemon=True)
        th.start()
    else:
        return {"ok": False, "error": "what: packs_live|packs_reopen|restart"}
    want = {"packs_live": ["packs_live"], "packs_reopen": ["packs_reopen", "reconnected"],
            "restart": ["restarting", "reconnected"]}[what]
    hud_seen, shot_done, end = False, False, time.time() + float(args.get("timeout", 45))
    st = st0
    while time.time() < end:
        st = _try(lambda: mstate(sx))
        kinds = [b.get("kind") for b in _banners_since(st, n0)]
        hud = st.get("status_hud") or {}
        if hud.get("visible"):
            hud_seen = True
            if not shot_done and ((st.get("status") or {}).get("banner") or {}).get("kind") == want[0]:
                rep["hud"] = {"title": (hud.get("texts") or {}).get("st_title"),
                              "banner": ((st.get("status") or {}).get("banner") or {}).get("text"),
                              "lines": hud.get("lines")}
                rep["shot"] = _shot(sx, "ingame_" + what)
                shot_done = True
        if all(k in kinds for k in want) and (st.get("client") or {}).get("state") == "play" and hud_seen and \
                not (st.get("status") or {}).get("error"):
            if what == "packs_live" and (st.get("packs") or {}).get("rev") != int(args.get("rev", 6)):
                time.sleep(0.1)
                continue
            break
        time.sleep(0.05)
    if what == "restart":
        th.join(30)
    rep["s"] = round(time.time() - t0, 2)
    rep["banners"] = _banners_since(st, n0)
    rep["client"] = st.get("client")
    rep["packs"] = st.get("packs")
    rep["log_tail"] = [(x.get("phase"), x.get("state"), x.get("text")) for x in
                       ((st.get("status") or {}).get("log") or [])[-40:]]
    kinds = [b.get("kind") for b in rep["banners"]]
    for k in want:
        if k not in kinds:
            bad.append("no banner %s (got %s)" % (k, kinds))
    if (st.get("client") or {}).get("state") != "play":
        bad.append("client not back in play: %s" % st.get("client"))
    if not hud_seen:
        bad.append("HUD status element never visible")
    if what == "packs_live":
        if (st.get("packs") or {}).get("rev") != int(args.get("rev", 6)):
            bad.append("rev %s, want %s" % ((st.get("packs") or {}).get("rev"), args.get("rev", 6)))
        if ((st.get("client") or {}).get("reconnects") or 0) != rec0:
            bad.append("live change reconnected")
    else:
        if ((st.get("client") or {}).get("reconnects") or 0) <= rec0:
            bad.append("no reconnect (reconnects %s)" % (st.get("client") or {}).get("reconnects"))
        runs = [p for p, s_, _ in rep["log_tail"] if s_ == "run"]
        for ph in ("ticket", "connect", "welcome"):
            if ph not in runs:
                bad.append("reconnect phase %s not shown (runs %s)" % (ph, runs))
    if what == "restart":
        txt = " ".join(b.get("text") or "" for b in rep["banners"] if b.get("kind") == "restarting")
        rep["restart_text"] = txt
        if "держитесь" not in txt:
            bad.append("restart banner text: %r" % txt)
    _check(sx, "ingame " + what, not bad, bad or None)
    _md(sx)["cases"]["ingame_" + what] = {k: rep.get(k) for k in ("s", "banners", "shot", "hud")}
    _md(sx).setdefault("details", {})["ingame_" + what] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def st_case(sx, args, step):
    """ошибочные случаи входа (каждый: подготовка -> вход -> ожидаемая ошибка на экране статуса -> (исправление ->
    «Повторить» -> игра -> выход) -> «Назад»)."""
    case = args["case"]
    sid = _session(sx)["session"]
    nick = args.get("nick") or ("m%s%s" % (case[:4], sid[-5:]))
    roles = P["_roles"](sx)
    out = {"case": case}
    if case == "no_server":
        r = _login(sx, {"addr": "free", "nick": "dev", "expect": {"kind": "no_server", "code": "tcp", "phase": "connect"},
                        "timeout": 20}, "case_no_server")
    elif case == "timeout":
        sil = Silent()
        try:
            r = _login(sx, {"addr": "port:%d" % sil.port, "nick": "dev", "timeout": 30,
                            "expect": {"kind": "timeout", "code": "welcome", "phase": "welcome"}}, "case_timeout")
            r.setdefault("result", {})["silent_accepted"] = sil.accepted
        finally:
            sil.close()
    elif case == "auth_down":
        sx.lab.stop(roles["auth"], owner=sx.owner)
        try:
            r = _login(sx, {"addr": "session", "nick": "dev", "expect": {"kind": "auth_down", "code": "http 0",
                                                                         "phase": "ticket"}, "then": "stay",
                            "timeout": 20}, "case_auth_down")
        finally:
            sx.lab.start(roles["auth"], owner=sx.owner)
        if r.get("ok"):
            r2 = _login(sx, {"button": "retry", "expect": "play", "then": "leave"}, "case_auth_down_retry")
            r = _merge(r, r2)
    elif case == "bad_token":
        cfgp = os.path.join(_md(sx)["lease_dir"], "export", "olife_server.txt")
        with open(cfgp, encoding="utf-8") as f:
            orig = f.read()
        with open(cfgp, "w", encoding="utf-8", newline="\n") as f:
            f.write(orig.replace("token=olife-dev", "token=olife-wrong-token"))
        try:
            r = _login(sx, {"addr": "session", "nick": "dev", "expect": {"kind": "ticket", "code": "auth",
                                                                         "phase": "ticket", "text": "bad token"},
                            "timeout": 20}, "case_bad_token")
        finally:
            with open(cfgp, "w", encoding="utf-8", newline="\n") as f:
                f.write(orig)
    elif case == "banned":
        reason = "olife_menu test ban %s" % sid
        sx.lab.sup.db.ban("account", nick, 10, reason, by=sx.owner)
        try:
            r = _login(sx, {"addr": "session", "nick": nick, "then": "stay", "timeout": 20,
                            "expect": {"kind": "banned", "code": "banned", "phase": "ticket", "text": reason}},
                       "case_banned")
        finally:
            sx.lab.sup.db.unban("account", nick, by=sx.owner)
        time.sleep(3.0)              # the gateway polls the ban list every 2 s: until then it still refuses with code 5
        if r.get("ok"):
            r = _merge(r, _login(sx, {"button": "retry", "expect": "play", "then": "leave"}, "case_banned_unban_retry"))
    elif case == "whitelist":
        scope = _w4b(sx).get("gw_id")
        out["on"] = wl_op(sx.lab, "on", scope, by=sx.owner, via="scenario")
        try:
            r = _login(sx, {"addr": "session", "nick": nick, "then": "stay", "timeout": 20,
                            "expect": {"kind": "whitelist", "code": "whitelist", "phase": "ticket",
                                       "text": "whitelist"}}, "case_whitelist")
            out["add"] = wl_op(sx.lab, "add", scope, nick, by=sx.owner, via="scenario")
            if r.get("ok"):
                r = _merge(r, _login(sx, {"button": "retry", "expect": "play", "then": "leave"},
                                     "case_whitelist_add_retry"))
        finally:
            out["off"] = wl_op(sx.lab, "off", scope, by=sx.owner, via="scenario")
            wl_op(sx.lab, "remove", scope, nick, by=sx.owner, via="scenario")
    elif case == "nick_reserved":
        r = _login(sx, {"addr": "session", "nick": "alice", "timeout": 20,
                        "expect": {"kind": "nick", "code": "nick_reserved", "phase": "ticket"}}, "case_nick_reserved")
    elif case == "nick_open":
        r = _login(sx, {"addr": "session", "nick": nick, "expect": "play", "then": "leave"}, "case_nick_open")
    elif case == "http409":
        rel = "olife_client/modules/hot/rev.lua"
        _packs_change(sx, rel, "-- olife_menu: manifest version\nreturn {rev = 11}\n")
        _packs_change(sx, rel, "-- olife_menu: changed after the manifest\nreturn {rev = 12}\n", regen=False)
        try:
            r = _login(sx, {"addr": "session", "nick": "dev", "timeout": 30,
                            "expect": {"kind": "download", "code": "409", "phase": "download"}}, "case_http409")
        finally:
            _packs_change(sx, rel, "-- olife_menu: back in line with the manifest\nreturn {rev = 12}\n")
    elif case == "sha256":
        r = _case_sha(sx, out)
    else:
        return {"ok": False, "error": "unknown case %s" % case}
    res = r.get("result") or {}
    res.update(out)
    return {"ok": r.get("ok"), "result": res, "error": r.get("error")}


def _merge(a, b):
    ra, rb = dict(a.get("result") or {}), b.get("result") or {}
    ra["then"] = rb
    err = "; ".join(x for x in (a.get("error"), b.get("error")) if x) or None
    return {"ok": bool(a.get("ok")) and bool(b.get("ok")), "result": ra, "error": err}


def _case_sha(sx, out):
    """второй шлюз той же сессии (тот же мир, ключ билетов, манифест), но раздача паков — через посредника, который
    подменяет modules/hot/rev.lua в пути; файл в манифесте изменён (клиент обязан его скачать)"""
    s, w = _session(sx), _w4b(sx)
    rel = "olife_client/modules/hot/rev.lua"
    _packs_change(sx, rel, "-- olife_menu: sha256 case\nreturn {rev = 13}\n")
    gw_main = sx.lab.lease_info(P["_roles"](sx)["gateway"])
    upstream_http = None
    mitm = None
    name = None
    try:
        # the mitm gateway: same kind/params as the session's (its own ports), packs url -> the proxy
        params = dict(gw_main.get("params") or {})
        params.pop("session", None)
        name = sx.lease("gateway", role="gateway_mitm", params=params, start=False)
        gi = sx.lab.lease_info(name)
        upstream_http = gi["ports"]["http"]
        mitm = Mitm(upstream_http, rel)
        sx.lab.start(name, owner=sx.owner, params={"packs_url": "http://127.0.0.1:%d" % mitm.port})
        out["mitm"] = {"gateway": name, "gw_port": gi["ports"]["gw"], "http": upstream_http, "proxy": mitm.port}
        r = _login(sx, {"addr": "port:%d" % gi["ports"]["gw"], "nick": "dev", "timeout": 30,
                        "expect": {"kind": "sha256", "code": "sha256", "phase": "verify", "text": "modules/hot/rev.lua"}},
                   "case_sha256")
        out["mitm"]["served"], out["mitm"]["swapped"] = mitm.served, mitm.swapped
        if not mitm.swapped:
            r["ok"] = False
            r["error"] = (r.get("error") or "") + "; the proxy never swapped the file"
        return r
    finally:
        if mitm:
            mitm.close()
        if name:
            try:
                sx.lab.release(name, owner=sx.owner, reason="case done")
                sx.leases.pop("gateway_mitm", None)
            except Exception:
                pass


def st_report(sx, args, step):
    """итог: проверки, случаи, снимки -> shots\\<сценарий>\\olife_menu.json; число фаз и ошибок"""
    md = _md(sx)
    checks = md["checks"]
    ok = [c for c in checks if c["ok"]]
    rep = {"checks": len(checks), "ok": len(ok), "failed": [c for c in checks if not c["ok"]], "cases": md["cases"],
           "shots": md["shots"], "start": md.get("start")}
    path = os.path.join(sx.out_dir(), "olife_menu.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(dict(rep, all_checks=checks, details=md.get("details")), f, ensure_ascii=False, indent=1, default=str)
    sx.data.setdefault("metrics", {})["menu"] = {"checks": len(checks), "ok": len(ok), "cases": list(md["cases"])}
    return {"ok": len(ok) == len(checks), "result": {"checks": len(checks), "ok": len(ok), "file": path,
                                                     "failed": rep["failed"][:5]},
            "error": None if len(ok) == len(checks) else "%d checks failed" % (len(checks) - len(ok))}


def st_whitelist_chat(sx, args, step):
    """/whitelist из чата админа (мир -> HTTP демона) = lab olife whitelist (возможность) = панель: одна БД"""
    from_a2 = P["_a2"]()
    roles = P["_roles"](sx)
    scope = _w4b(sx).get("gw_id")
    nick = "wlchat%s" % _session(sx)["session"][-5:]
    rep, bad = {}, []
    r1 = from_a2.run_op(sx.lab, roles["world"], sx.owner, "/whitelist add %s" % nick, by="dev", via="cli")
    rep["op_add"] = r1
    st = wl_state(sx.lab, scope)
    if nick not in st["names"]:
        bad.append("world /whitelist add did not reach the DB: %s / %s" % (r1, st))
    r2 = from_a2.run_op(sx.lab, roles["world"], sx.owner, "/whitelist list", by="dev", via="cli")
    rep["op_list"] = r2
    if nick not in str(r2.get("text")):
        bad.append("/whitelist list: %s" % r2)
    r3 = from_a2.run_op(sx.lab, roles["world"], sx.owner, "/whitelist remove %s" % nick, by="dev", via="cli")
    rep["op_remove"] = r3
    if nick in wl_state(sx.lab, scope)["names"]:
        bad.append("remove did not reach the DB")
    _check(sx, "whitelist via world op", not bad, bad or None)
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def st_whitelist(sx, args, step):
    """п.3, вайтлист по нику: одна БД supervisor и три пути управления — чат админа (`/whitelist ...`: мир -> HTTP
    демона), CLI (`lab olife whitelist` = возможность olife.whitelist), панель (POST /call/olife.whitelist via=panel);
    не-админ в чате — отказ 16. Затем вход из меню по нику: вайтлист включён, ник в списке -> игра; ника нет -> экран
    статуса «нет в вайтлисте» -> добавить (CLI) -> «Повторить» -> игра; выключен -> вход по любому свободному нику."""
    cp = P["_a2"]()._tools()
    roles = P["_roles"](sx)
    scope = _w4b(sx).get("gw_id")
    sid = _session(sx)["session"]
    gw = _session(sx)["gateway_port"]
    rep, bad = {"scope": scope}, []
    n_in, n_out, n_cli, n_panel = "wlin%s" % sid[-5:], "wlout%s" % sid[-5:], "wlcli%s" % sid[-5:], "wlpan%s" % sid[-5:]
    sx.lab.stdin(roles["world"], "olife.admins dev", owner=sx.owner, wait=3.0, pattern=r"admins=")

    def ck(name, ok, **detail):
        rep.setdefault("checks", []).append({"name": name, "ok": bool(ok), **detail})
        _check(sx, "whitelist: " + name, ok, detail or None)
        if not ok:
            bad.append(name)
    d = cp.ChatClient(gw, "olife-dev", "dev").background()
    c = cp.ChatClient(gw, "olife-carol", "carol").background()
    try:
        r = d.command("/whitelist on", timeout=6)
        st = wl_state(sx.lab, scope)
        ck("chat /whitelist on (admin) -> OpResult 0, DB on", r and r.get("code") == 0 and st["enabled"],
           reply=r, enabled=st["enabled"])
        r = d.command("/whitelist add %s" % n_in, timeout=6)
        ck("chat /whitelist add -> DB has the nick", r and r.get("code") == 0 and n_in in wl_state(sx.lab, scope)["names"],
           reply=r)
        r = d.command("/whitelist list", timeout=6)
        ck("chat /whitelist list -> the nick in the answer", r and r.get("code") == 0 and n_in in (r.get("text") or ""),
           reply=r)
        r = c.command("/whitelist list", timeout=4)
        ck("chat: a player (carol) -> 16 admins only", r and r.get("code") == 16, reply=r)
        ops = [l for l in d.lines() if "[op] whitelist" in (l.get("text") or "")]
        ck("chat: op line broadcast for changes", len(ops) >= 2, op_lines=len(ops))
    finally:
        for x in (c, d):
            try:
                x.close()
            except Exception:
                pass
    # CLI = the feature (same function lab olife whitelist calls through the daemon)
    r = wl_op(sx.lab, "add", scope, n_cli, by="operator", via="cli")
    ck("CLI whitelist add -> DB", r.get("ok") and n_cli in wl_state(sx.lab, scope)["names"], reply=r.get("text"))
    # panel: the button posts /call/olife.whitelist (via=panel) to the daemon
    body = json.dumps({"args": {"op": "add", "name": n_panel, "scope": scope, "via": "panel"}, "owner": "panel"}).encode()
    req = urllib.request.Request("http://127.0.0.1:%d/call/olife.whitelist" % sx.lab.cfg["daemon"]["port"], data=body,
                                 method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        pr = json.loads(resp.read().decode("utf-8"))
    ck("panel POST /call/olife.whitelist -> DB", pr.get("ok") and n_panel in wl_state(sx.lab, scope)["names"],
       reply=(pr.get("result") or {}).get("text"))
    fresh = P["_a1"]()._fresh_supervise().panel_html("Olife", "/sup/state")
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/sup/panel?prefix=olife-&title=Olife" % sx.lab.cfg["daemon"]["port"],
                                    timeout=5) as resp:
            live = "olife-whitelist-b" in resp.read().decode("utf-8", "replace")
    except Exception:
        live = None
    ck("panel template (labcore/supervise.py) has the Whitelist section", "olife-whitelist-b" in fresh,
       live_daemon=live, note="the running daemon serves it after `lab daemon upgrade`")
    # stdin op of the lab (`lab olife op whitelist ...` = world op via=cli)
    r = P["_a2"]().run_op(sx.lab, roles["world"], sx.owner, "/whitelist remove %s" % n_cli, by="operator", via="cli")
    ck("lab op /whitelist remove (world -> daemon) -> DB", r.get("code") == 0 and
       n_cli not in wl_state(sx.lab, scope)["names"], reply=r)
    # audit: world (chat/cli) and the daemon's whitelist_audit.jsonl
    try:
        with open(os.path.join(sx.lab.data, "olife", "whitelist_audit.jsonl"), encoding="utf-8") as f:
            aud = [json.loads(x) for x in f if scope in x]
    except OSError:
        aud = []
    vias = sorted({a.get("via") for a in aud})
    ck("audit: whitelist_audit.jsonl has chat, cli, panel", {"chat", "cli", "panel"} <= set(vias), vias=vias, n=len(aud))
    # the menu: nick logins under the whitelist
    if args.get("menu", True):
        r1 = _login(sx, {"addr": "session", "nick": n_in, "expect": "play", "then": "leave"}, "wl_listed_nick")
        ck("menu: listed nick -> play", r1.get("ok"), error=r1.get("error"))
        r2 = _login(sx, {"addr": "session", "nick": n_out, "then": "stay",
                         "expect": {"kind": "whitelist", "code": "whitelist", "phase": "ticket"}}, "wl_unlisted_nick")
        ck("menu: unlisted nick -> status screen: whitelist", r2.get("ok"), error=r2.get("error"))
        wl_op(sx.lab, "add", scope, n_out, by="operator", via="cli")
        r3 = _login(sx, {"button": "retry", "expect": "play", "then": "leave"}, "wl_added_retry")
        ck("menu: added (CLI) -> Повторить -> play", r3.get("ok"), error=r3.get("error"))
        wl_op(sx.lab, "off", scope, by="operator", via="cli")
        r4 = _login(sx, {"addr": "session", "nick": "wlfree%s" % sid[-5:], "expect": "play", "then": "leave"},
                    "wl_off_any_nick")
        ck("menu: whitelist off -> any free nick plays", r4.get("ok"), error=r4.get("error"))
    for n in (n_in, n_out, n_cli, n_panel):
        wl_op(sx.lab, "remove", scope, n, by="operator", via="cleanup")
    wl_op(sx.lab, "off", scope, by="operator", via="cleanup")
    rep["final"] = wl_state(sx.lab, scope)
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


NAMES = {"olife_menu_engine": "st_engine_path", "olife_menu_wl": "st_whitelist", "olife_menu_start": "st_start", "olife_menu_login": "st_login", "olife_menu_leave": "st_leave",
         "olife_menu_packs": "st_packs", "olife_menu_ingame": "st_ingame", "olife_menu_case": "st_case",
         "olife_menu_report": "st_report", "olife_menu_wl_chat": "st_whitelist_chat"}


def selftest():
    assert NICK_RX.match("dev") and not NICK_RX.match("a") and not NICK_RX.match("Вася")
    assert wl_acct(None) == "_wl:*"
