"""olife, UX A1 (03.10, агент olife_a1): права на сущности (модель «репозитория»), друзья, форк.

Подключается из plugin.py (`_a1()`, перезагрузка по mtime этого файла), получает его глобалы (_roles, _kv, _w4a, ...).
Мир: content/olife_world/modules/perms.lua; клиент: content/olife_client/modules/olife.lua (+ layouts/friends.xml).

БД supervisor (друзья, настройки аккаунта): таблицы `friends`, `account_settings` (миграция 3 в labcore/supervise.py).
Живой демон со старым ядром их ещё не знает: `social(db)` создаёт таблицы (IF NOT EXISTS) и берёт методы StateDB из
свежей копии supervise.py (тот же писатель — процесс демона, тот же RLock). После `lab daemon upgrade` — методы ядра.
Синхронизация мир <-> БД:
  мир -> БД: события дружбы (sup_state `friends_ev` у групп supervisor; stdin `friends_ev <since>` у сессий), последнее
             применённое — account_settings('_sync', 'friends_ev:<wid>'), wid — id сохранения мира;
  БД -> мир: при старте мира группы — полный `olife.friends <spec>` + `olife.acct_settings`; при правке оператором
             (`lab olife friend ...`) — `olife.friend_set a b state` в миры групп этого владельца и указанной сессии.
Возможности: olife.friend {action=list|add|remove|request|cancel|sync, a, b, account, session?}, olife.settings
{account, key?, value?}. Шаги сценариев olife_perms / olife_fork — ниже (NAMES).
"""
import json
import math
import os
import time

P = {}

NAMES = {"olife_friends_gui": "st_friends_gui", "olife_perms_gui": "st_perms_gui", "olife_perms_matrix": "st_matrix",
         "olife_perms_admin": "st_admin", "olife_perms_neg": "st_neg", "olife_friends_db": "st_friends_db",
         "olife_fork": "st_fork", "olife_a1_setup": "st_setup"}

ACTIONS = ["move", "read_code", "edit_code", "run", "appearance", "clone", "destroy", "storage_read", "storage_write"]
AUD = ["owner", "friends", "list", "everyone"]


def bind(g):
    P.update(g)


def steps():
    return {n: _lazy(n) for n in NAMES}


def _lazy(n):
    def f(sx, args, step):
        return getattr(P["_a1"](), NAMES[n])(sx, args, step)
    return f


def W():
    return P["_w4a"]()


# ---------------------------------------------------------------------------------------------- БД (друзья, настройки)
_FRESH = {}


def _fresh_supervise():
    if "m" not in _FRESH:
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "labcore", "supervise.py")
        spec = importlib.util.spec_from_file_location("labcore_supervise_a1", os.path.normpath(path))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        _FRESH["m"] = m
    return _FRESH["m"]


class _Social:
    """методы friends/settings новой StateDB поверх экземпляра старой (живой демон до upgrade)"""
    NAMES = ("friend_state", "friend_set", "friend_cancel", "friends_of", "friend_pairs", "setting_set", "settings_of",
             "_pair")

    def __init__(self, db):
        self._db = db
        cls = _fresh_supervise().StateDB
        for n in self.NAMES:
            setattr(self, n, getattr(cls, n).__get__(self))     # методы зовут друг друга через self

    def __getattr__(self, k):                                    # db, lock, _rows, _exec — у живой БД демона
        return getattr(self._db, k)


def social(db):
    if not getattr(db, "_a1_tables", False):
        with db.lock:
            for st in _fresh_supervise().SOCIAL_SQL:
                db.db.execute(st)
            db.db.commit()
        db._a1_tables = True
    return db if hasattr(db, "friends_of") else _Social(db)


def world_spec(db):
    sdb = social(db)
    items = []
    for r in sdb.friend_pairs():
        items.append("%s%s%s" % (r["a"], "+" if r["state"] == "friend" else ">", r["b"]))
    for a in db.accounts():
        items.append("=" + a["name"])
    return ",".join(items)


def settings_lines(db):
    out = []
    for acct, kv in social(db).settings_of().items():
        if acct.startswith("_"):
            continue
        parts = ["%s=%s" % (k, v) for k, v in sorted(kv.items()) if k in ("perms.default", "friends.requests")]
        if parts:
            out.append('olife.acct_settings %s "%s"' % (acct, ";".join(parts)))   # 0.32 console: quote = , ; :
    return out


def push_world(lab, lease, owner, db):
    spec = world_spec(db)
    # the 0.32 console tokenizer refuses bare `=`, `>`, `,` ("invalid character '='"): the spec goes as a quoted string
    r = lab.stdin(lease, 'olife.friends "%s"' % spec, owner=owner, wait=3.0, pattern=r"friends loaded")
    for line in settings_lines(db):
        lab.stdin(lease, line, owner=owner, wait=2.0, pattern=r"acct_settings")
    return {"spec_items": len(spec.split(",")) if spec else 0,
            "reply": next((x for x in r.get("lines", []) if "friends loaded" in x), None)}


def apply_events(db, wid, events, by="world"):
    """события мира [id, op, a, b] -> БД, только новее последнего применённого для этого wid"""
    sdb = social(db)
    key = "friends_ev:%s" % wid
    last = int(sdb.settings_of("_sync").get(key) or 0)
    n = 0
    for e in events or []:
        eid, op, a, b = int(e[0]), e[1], e[2], e[3]
        if eid <= last:
            continue
        if op == "friend":
            sdb.friend_set(a, b, "friend", by)
        elif op == "unfriend":
            sdb.friend_set(a, b, "none", by)
        elif op == "request":
            sdb.friend_set(a, b, "request", by)
        elif op == "cancel":
            sdb.friend_cancel(a, b, by)
        last = eid
        n += 1
    if n:
        sdb.setting_set("_sync", key, last, by)
    return {"wid": wid, "applied": n, "last": last}


def pull_stdin(lab, lease, owner, db):
    """мир сессии (без sup_state): события через stdin `friends_ev <since>`"""
    r = lab.stdin(lease, "friends_ev 0", owner=owner, wait=3.0, pattern=r"friends_ev wid=")
    wid, ev = None, []
    for x in r.get("lines", []):
        if "friends_ev wid=" in x:
            wid = x.split("wid=")[1].split()[0]
        elif "] fev id=" in x:
            d = P["_kv"](x[x.find("fev id="):])
            ev.append([d["id"], d["op"], d["a"], d["b"]])
    if not wid:
        return {"error": "no friends_ev reply"}
    return apply_events(db, wid, ev, "world:" + lease)


def world_started(sup, svc):
    """хук группы: мир (пере)запущен -> досинхронизировать события прошлого запуска из sup_state на диске, затем
    отдать миру состояние БД"""
    lab = sup.lab
    l = lab.leases.get(svc.lease)
    out = {}
    if l is not None:
        st, _ = P["read_world_state"](l.dir)
        fe = (st or {}).get("friends_ev")
        if fe and fe.get("wid"):
            out["pulled"] = apply_events(sup.db, fe["wid"], fe.get("events"), "world:" + svc.lease)
    out["pushed"] = push_world(lab, svc.lease, svc.group.owner, sup.db)
    return out


def poll(sup, g):
    wsvc = g.services.get("world")
    if wsvc is None or wsvc.state != "up" or wsvc.lease not in sup.lab.leases:
        return None
    st, _ = P["read_world_state"](sup.lab.leases[wsvc.lease].dir)
    fe = (st or {}).get("friends_ev")
    if not fe or not fe.get("wid"):
        return None
    return apply_events(sup.db, fe["wid"], fe.get("events"), "world:" + wsvc.lease)


def _target_worlds(lab, owner, session=None):
    out = []
    for n, g in list(getattr(lab.sup, "groups", {}).items()):
        if n.startswith(P["SUP_PREFIX"]) and g.state == "up" and g.owner == owner and "world" in g.services:
            out.append((g.services["world"].lease, g.owner))
    if session:
        roles = P["session_leases"](lab, session)
        if "world" in roles:
            out.append((roles["world"], owner))
    return out


def friend_cmd(lab, owner, action, a=None, b=None, session=None):
    db = lab.sup.db
    sdb = social(db)
    if action == "list":
        if a:
            return sdb.friends_of(a)
        return {"pairs": sdb.friend_pairs()}
    if action == "sync":
        res = []
        for lease, own in _target_worlds(lab, owner, session):
            res.append(dict(pull_stdin(lab, lease, own, db), lease=lease))
        return {"synced": res}
    if not a or not b:
        raise KeyError("friend %s: accounts a and b" % action)
    if action == "add":
        r = sdb.friend_set(a, b, "friend", owner)
        st = "friend"
    elif action == "remove":
        r = sdb.friend_set(a, b, "none", owner)
        st = "none"
    elif action == "request":
        r = sdb.friend_set(a, b, "request", owner)
        st = r["state"]
    elif action == "cancel":
        r = sdb.friend_cancel(a, b, owner)
        st = sdb.friend_state(a, b)
        st = {"incoming": "request", "request": "request"}.get(st, st)
        if st == "request":          # отменили a->b, а встречный b->a остался — мир получает его
            a, b = b, a
    else:
        raise KeyError("friend action: list|add|remove|request|cancel|sync")
    db.event(None, None, None, "friend_" + action, {"a": a, "b": b, "by": owner})
    pushed = []
    word = {"none": "off", "incoming": "off"}.get(st, st)     # `none` arrives as nil through the engine console parser
    for lease, own in _target_worlds(lab, owner, session):
        x = lab.stdin(lease, "olife.friend_set %s %s %s" % (a, b, word), owner=own, wait=2.0, pattern=r"friend_set")
        pushed.append({"lease": lease, "reply": next((y for y in x.get("lines", []) if "friend_set" in y), None)})
    return dict(r, pushed=pushed)


def f_friend(ctx, args):
    return friend_cmd(ctx.lab, ctx.owner, args.get("action", "list"), args.get("a") or args.get("account"),
                      args.get("b"), args.get("session"))


def f_settings(ctx, args):
    sdb = social(ctx.lab.sup.db)
    if args.get("key"):
        v = args.get("value")
        r = sdb.setting_set(args["account"], args["key"], None if v in (None, "delete") else v, ctx.owner)
        ctx.lab.sup.db.event(None, None, None, "account_setting", dict(r, by=ctx.owner))
        return r
    return {"settings": sdb.settings_of(args.get("account"))}


def register(api):
    obj = {"type": "object"}
    # обёртки: функция берётся из свежего модуля при каждом вызове (правка olife_a1.py — без перезагрузки plugin.py)
    api.feature("friend", lambda ctx, a: P["_a1"]().f_friend(ctx, a), "UX A1: friends in the supervisor DB {action=list|add|remove|request|cancel|sync, "
                "a, b | account, session?} (changes are pushed to the worlds of your groups and of `session`)", obj)
    api.feature("settings", lambda ctx, a: P["_a1"]().f_settings(ctx, a), "UX A1: per-account settings {account, key?, value?|delete}: perms.default="
                "move:friends,clone:everyone; friends.requests=open|closed (pushed to a world at its start)", obj)


# ---------------------------------------------------------------------------------------------- клиентские помощники
def req(sx, lease, name, msg, timeout=3.0):
    """запрос из оконного клиента (F2F olife send) -> RequestReply по seq"""
    w = W()
    seq = w.ol(sx, lease, "send", name=name, msg=dict(msg))["seq"]
    r = w.wait_for(lambda: next((x for x in w.state(sx, lease)["replies"] if x["seq"] == seq), None), timeout, 0.05)
    time.sleep(0.11)                              # ведро запросов мира 10/с
    return r, seq


def code_of(r):
    return r["code"] if r else None


def perms_line(sx, eid):
    r = W()._stdin(sx, "bench_perms %d" % eid, r"perms eid=%d" % eid)
    ls = [x for x in r["lines"] if "perms eid=%d " % eid in x]
    if not ls:
        return {}
    return P["_kv"](ls[-1][ls[-1].find("perms eid="):])


def friends_line(sx):
    r = W()._stdin(sx, "friends", r"friends pairs=")
    ls = [x for x in r["lines"] if "friends pairs=" in x]
    return P["_kv"](ls[-1][ls[-1].find("friends pairs="):]) if ls else {}


def fgui(sx, lease):
    return W().ol(sx, lease, "friends_gui")


def open_friends_hotkey(sx, lease):
    """Shift+` (как игрок); запасной путь — ui friends (записывается в отчёт)"""
    w = W()
    w.inp(sx, lease, keys={"left-shift": True})
    time.sleep(0.08)
    w.press_key(sx, lease, "grave-accent")
    w.inp(sx, lease, keys={"left-shift": False})
    g = w.wait_for(lambda: (lambda x: x if x.get("doc") else None)(fgui(sx, lease)), 3.0)
    if g:
        return g, "shift+grave"
    w.ol(sx, lease, "ui", call="friends")
    return w.wait_for(lambda: (lambda x: x if x.get("doc") else None)(fgui(sx, lease)), 3.0) or fgui(sx, lease), "ui"


def row_of(g, account, kind=None):
    for r in g.get("rows") or []:
        if r["account"] == account and (kind is None or r["kind"] == kind):
            return r
    return None


def close_friends(sx, lease):
    g = fgui(sx, lease)
    if g.get("doc") and (g.get("rects") or {}).get("fr_close"):
        W().click(sx, lease, g["rects"]["fr_close"])
        W().wait_for(lambda: not fgui(sx, lease).get("doc"), 3.0)


def close_editor(sx, lease):
    g = W().gui(sx, lease)
    if g.get("doc"):
        W().click(sx, lease, g["rects"]["btn_close"])
        W().wait_for(lambda: not W().gui(sx, lease).get("doc"), 3.0)


def feedback(sx, lease, n0=None):
    st = W().state(sx, lease)
    return {"toast": st.get("last_toast"), "sounds": (st.get("sounds") or [])[-4:],
            "denied": (st.get("stats") or {}).get("denied")}


def _save(sx, name, rep):
    with open(os.path.join(sx.out_dir(), name), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)


def _m(sx):
    return sx.data.setdefault("metrics", {}).setdefault("a1", {})


def _clients(sx):
    roles = P["_roles"](sx)
    return roles["client1"], roles["client2"], roles["client3"]


# ---------------------------------------------------------------------------------------------- шаги
def st_setup(sx, args, step):
    """админы мира (dev — для обхода прав), бенчи: цель матрицы и жертвы удаления далеко от луча"""
    w = W()
    w._stdin(sx, "olife.admins %s" % args.get("admins", "dev"), r"admins=")
    return {"ok": True, "result": {"admins": args.get("admins", "dev")}}


def st_friends_gui(sx, args, step):
    """B (bob) открывает чужой бенч Injector'ом -> Настройки -> «Друзья» -> имя alice -> «Добавить»; A получает
    запрос (тост + звук), открывает «Друзья» Shift+` и жмёт «Принять»; C (carol) просит alice, A «Отклоняет»;
    отказы C по протоколу (16/17/15)"""
    w = W()
    A, B, C = _clients(sx)
    eid = w.eid_arg(sx, args)
    rep = {"eid": eid}
    bad = []
    if not w.wait_for(lambda: all(w.bench_of(w.state(sx, x), eid) for x in (A, B, C)), 20):
        return {"ok": False, "error": "bench %d not seen by all three clients" % eid}
    # B: редактор (только чтение) -> Настройки -> Друзья
    g, _ = w.open_with_injector(sx, B, eid)
    rep["b_editor"] = {"doc": g.get("doc"), "can_edit": (g.get("st") or {}).get("can_edit")}
    w.click(sx, B, g["rects"]["tab_set"])
    g = w.wait_for(lambda: (lambda x: x if x.get("tab") == "set" else None)(w.gui(sx, B)), 3.0) or w.gui(sx, B)
    w.click(sx, B, g["rects"]["btn_friends"])
    fb = w.wait_for(lambda: (lambda x: x if x.get("doc") else None)(fgui(sx, B)), 4.0)
    rep["b_friends_open"] = bool(fb)
    if not fb:
        return {"ok": False, "error": "B: friends page did not open from the settings page", "result": rep}
    rep["shot_b_friends_empty"] = w.shot(sx, B, "a1_friends_b_empty")
    w.click(sx, B, fb["rects"]["fr_name"])
    w.inp(sx, B, chars="alice")
    time.sleep(0.15)
    n0 = len(w.state(sx, B)["replies"])
    w.click(sx, B, fb["rects"]["fr_add"])
    r = w.wait_for(lambda: next((x for x in w.state(sx, B)["replies"][n0:] if x["op"] == 10), None), 3.0)
    rep["b_request"] = {"reply": r, "feedback": feedback(sx, B)}
    if not r or r["code"] != 0 or r["reason"] != "requested":
        bad.append("B request: %s" % r)
    # A: входящий запрос (тост, звук) -> Shift+` -> «Принять»
    inc = w.wait_for(lambda: "bob" in ((w.state(sx, A).get("friends") or {}).get("incoming") or []), 3.0)
    rep["a_incoming"] = {"seen": bool(inc), "feedback": feedback(sx, A)}
    if not inc or "bob" not in (rep["a_incoming"]["feedback"]["toast"] or ""):
        bad.append("A did not get the request with a toast: %s" % rep["a_incoming"])
    fa, how = open_friends_hotkey(sx, A)
    rep["a_friends_open"] = how
    if how != "shift+grave":
        bad.append("Shift+` did not open the friends page (ui fallback used)")
    row = row_of(fa, "bob", "in")
    rep["a_row_bob"] = row and {k: row[k] for k in ("kind", "account")}
    rep["shot_a_incoming"] = w.shot(sx, A, "a1_friends_a_incoming")
    if not row or not row.get("accept"):
        bad.append("A: no incoming row for bob")
    else:
        w.click(sx, A, row["accept"])
    ok = w.wait_for(lambda: any(f["account"] == "bob" for f in (w.state(sx, A).get("friends") or {}).get("friends") or [])
                    and any(f["account"] == "alice" for f in (w.state(sx, B).get("friends") or {}).get("friends") or []), 4.0)
    rep["friends_after_accept"] = {"a": (w.state(sx, A).get("friends") or {}), "b": (w.state(sx, B).get("friends") or {}),
                                   "a_feedback": feedback(sx, A), "b_feedback": feedback(sx, B),
                                   "world": friends_line(sx)}
    if not ok:
        bad.append("accept: lists %s" % rep["friends_after_accept"])
    time.sleep(0.3)
    rep["shot_a_friends"] = w.shot(sx, A, "a1_friends_a_after_accept")
    rep["shot_b_friends"] = w.shot(sx, B, "a1_friends_b_after_accept")
    # C: запрос alice -> A отклоняет
    fc, how_c = open_friends_hotkey(sx, C)
    rep["c_friends_open"] = how_c
    if fc.get("doc"):
        w.click(sx, C, fc["rects"]["fr_name"])
        w.inp(sx, C, chars="alice")
        time.sleep(0.15)
        w.click(sx, C, fc["rects"]["fr_add"])
    out_c = w.wait_for(lambda: "alice" in ((w.state(sx, C).get("friends") or {}).get("outgoing") or []), 3.0)
    fa = w.wait_for(lambda: (lambda x: x if row_of(x, "carol", "in") else None)(fgui(sx, A)), 3.0) or fgui(sx, A)
    rowc = row_of(fa, "carol", "in")
    if not out_c or not rowc:
        bad.append("carol's request not seen (outgoing %s, A row %s)" % (bool(out_c), bool(rowc)))
    else:
        w.click(sx, A, rowc["deny"])
    gone = w.wait_for(lambda: not ((w.state(sx, C).get("friends") or {}).get("outgoing") or []), 3.0)
    rep["deny"] = {"c_outgoing_empty": bool(gone), "a_feedback": feedback(sx, A), "world": friends_line(sx)}
    if not gone:
        bad.append("deny: carol still has an outgoing request")
    # отказы C по протоколу (из оконного клиента, в обход UI)
    neg = {}
    for case, msg, want in (("self", {"op": 1, "account": "carol"}, 16), ("unknown", {"op": 1, "account": "nobody_zz"}, 16),
                            ("accept_none", {"op": 2, "account": "bob"}, 17), ("remove_not_friend", {"op": 4, "account": "alice"}, 17),
                            ("bad_op", {"op": 9, "account": "alice"}, 15)):
        r, _ = req(sx, C, "FriendRequest", msg)
        neg[case] = {"want": want, "got": code_of(r), "ok": code_of(r) == want}
        if code_of(r) != want:
            bad.append("C %s: %s (want %d)" % (case, code_of(r), want))
    rep["c_negative"] = neg
    rep["c_feedback"] = feedback(sx, C)
    if "refuse" not in (rep["c_feedback"]["sounds"] or []):
        bad.append("C refusals without the refuse sound: %s" % rep["c_feedback"])
    for x in (A, B, C):
        close_friends(sx, x)
    _m(sx)["friends_gui"] = {k: rep[k] for k in ("b_request", "a_incoming", "a_friends_open", "deny", "c_negative")}
    _save(sx, "olife_friends_gui.json", rep)
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def st_perms_gui(sx, args, step):
    """A (владелец) на странице «Настройки»: двигать -> «друз», форк -> «друз», запуск -> список carol (поле + OK);
    мир меняет правила, тосты; B видит панель только для чтения (вам: ...), «Форк» доступен; C — «Форк» недоступен"""
    w = W()
    A, B, C = _clients(sx)
    eid = w.eid_arg(sx, args)
    rep = {"eid": eid}
    bad = []
    g, _ = w.open_with_injector(sx, A, eid)
    w.click(sx, A, g["rects"]["tab_set"])
    g = w.wait_for(lambda: (lambda x: x if x.get("tab") == "set" and x.get("perms") and x.get("perm_rows") else None)(
        w.gui(sx, A)), 4.0) or w.gui(sx, A)
    rows = g.get("perm_rows") or []
    rep["a_panel"] = {"note": g.get("perm_note"), "can_admin": (g.get("perms") or {}).get("can_admin"),
                      "rows": len(rows), "seg_enabled": [s_.get("enabled") for s_ in (rows[0]["seg"] if rows else [])]}
    if len(rows) != 9 or not (g.get("perms") or {}).get("can_admin"):
        return {"ok": False, "error": "A rights panel: %s" % rep["a_panel"], "result": rep}
    n0 = len(w.state(sx, A)["replies"])
    w.click(sx, A, rows[0]["seg"][1])            # move -> friends
    time.sleep(0.25)
    w.click(sx, A, rows[5]["seg"][1])            # clone -> friends
    time.sleep(0.25)
    w.click(sx, A, rows[3]["list"])              # run: list = carol
    w.inp(sx, A, chars="carol")
    time.sleep(0.15)
    w.click(sx, A, rows[3]["ok"])
    rr = w.wait_for(lambda: (lambda l: l if len(l) >= 3 else None)(
        [x for x in w.state(sx, A)["replies"][n0:] if x["op"] == 8]), 4.0) or []
    rep["a_replies"] = [code_of(x) for x in rr]
    pl = w.wait_for(lambda: (lambda d: d if d.get("run") == "list[carol]" else None)(perms_line(sx, eid)), 3.0) \
        or perms_line(sx, eid)
    rep["world_rules"] = pl
    if not (pl.get("move") == "friends" and pl.get("clone") == "friends" and pl.get("run") == "list[carol]"):
        bad.append("world rules after the GUI: %s" % pl)
    if rep["a_replies"] != [0, 0, 0]:
        bad.append("A rights replies %s" % rep["a_replies"])
    time.sleep(0.3)
    ga = w.gui(sx, A)
    rep["a_after"] = {"feedback": feedback(sx, A), "seg_colors_active": None, "list_text": ga["perm_rows"][3].get("list_text")}
    if "Права" not in (rep["a_after"]["feedback"]["toast"] or ""):
        bad.append("A: no rights toast: %s" % rep["a_after"]["feedback"])
    rep["shot_a_settings"] = w.shot(sx, A, "a1_settings_owner")
    close_editor(sx, A)
    # B (друг): только чтение, вам — двигать/читать/форк; «Форк» включён
    for who, lease, want_fork, want_mine in (("b", B, True, {"move", "read_code", "clone"}),
                                             ("c", C, False, {"read_code", "run"})):
        gx, _ = w.open_with_injector(sx, lease, eid)
        w.click(sx, lease, gx["rects"]["tab_set"])
        gx = w.wait_for(lambda: (lambda x: x if x.get("tab") == "set" and x.get("perms") else None)(w.gui(sx, lease)), 4.0) \
            or w.gui(sx, lease)
        pm = gx.get("perms") or {}
        mine = {a for i, a in enumerate(ACTIONS) if (pm.get("mine") or 0) >> i & 1}
        seg = ((gx.get("perm_rows") or [{}])[0].get("seg") or [{}])
        rep[who] = {"can_admin": pm.get("can_admin"), "mine": sorted(mine), "note": gx.get("perm_note"),
                    "fork_enabled": (gx["rects"].get("btn_fork") or {}).get("enabled"),
                    "seg_enabled": seg[0].get("enabled") if seg else None}
        if pm.get("can_admin") or mine != want_mine or rep[who]["fork_enabled"] != want_fork or rep[who]["seg_enabled"]:
            bad.append("%s panel: %s (want mine %s, fork %s)" % (who, rep[who], sorted(want_mine), want_fork))
        rep["shot_" + who] = w.shot(sx, lease, "a1_settings_%s" % who)
        close_editor(sx, lease)
    _m(sx)["perms_gui"] = {k: rep.get(k) for k in ("a_panel", "a_replies", "world_rules", "b", "c")}
    _save(sx, "olife_perms_gui.json", rep)
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


MATRIX_CODE = "-- olife_perms matrix\nfunction on_tick(dt) end\n"


def _probe(sx, lease, eid, action, victim, home):
    """одно действие клиента lease над eid -> (код, подробности)"""
    w = W()
    if action == "move":
        w._stdin(sx, "bench_place %d %.3f %.3f %.3f" % (eid, home[0], home[1], home[2]), r"bench_place")
        w.ol(sx, lease, "aim", eid=eid)
        time.sleep(0.2)
        seq = w.ol(sx, lease, "tool", tool=2)["seq"]
        r = w.wait_for(lambda: next((x for x in w.state(sx, lease)["replies"] if x["seq"] == seq), None), 3.0, 0.05)
        if code_of(r) == 0:
            time.sleep(0.15)
            w.ol(sx, lease, "tool", tool=2)          # отпустить
            w.wait_for(lambda: w.bench_info(sx, eid).get("holder") == "-", 3.0)
        time.sleep(0.12)
        return code_of(r), r and r.get("reason")
    if action == "read_code":
        r, _ = req(sx, lease, "ScriptOpen", {"eid": eid, "edit": False})
        req(sx, lease, "ScriptLockRelease", {"eid": eid, "close": True})
        return code_of(r), r and r.get("reason")
    if action == "edit_code":
        r, _ = req(sx, lease, "ScriptOpen", {"eid": eid, "edit": True})
        extra = None
        if code_of(r) == 0:
            s, _ = req(sx, lease, "ScriptSave", {"eid": eid, "code": MATRIX_CODE})
            extra = "save %s" % code_of(s)
        req(sx, lease, "ScriptLockRelease", {"eid": eid, "close": True})
        return code_of(r), extra or (r and r.get("reason"))
    if action == "run":
        r, _ = req(sx, lease, "ScriptRun", {"eid": eid})
        extra = None
        if code_of(r) == 0:
            s, _ = req(sx, lease, "ScriptStop", {"eid": eid})
            extra = "stop %s" % code_of(s)
        return code_of(r), extra or (r and r.get("reason"))
    if action == "appearance":
        r, _ = req(sx, lease, "EntityEdit", {"eid": eid, "op": 3, "name": "", "model": "olife_bench", "texture": ""})
        return code_of(r), r and r.get("reason")
    if action == "clone":
        r, seq = req(sx, lease, "EntityFork", {"eid": eid, "name": ""})
        extra = None
        if code_of(r) == 0:
            fk = w.wait_for(lambda: next((x for x in w.state(sx, lease).get("forks") or [] if x["seq"] == seq), None), 3.0)
            if fk:
                d, _ = req(sx, lease, "EntityEdit", {"eid": fk["eid"], "op": 1, "name": "", "model": "", "texture": ""})
                extra = "fork #%d deleted %s" % (fk["eid"], code_of(d))
            else:
                extra = "no EntityForked"
        return code_of(r), extra or (r and r.get("reason"))
    if action == "destroy":
        r, _ = req(sx, lease, "EntityEdit", {"eid": victim, "op": 1, "name": "", "model": "", "texture": ""})
        return code_of(r), r and r.get("reason")
    i = ACTIONS.index(action) + 1
    r, _ = req(sx, lease, "PermsCheck", {"eid": eid, "action": i})
    return code_of(r), r and r.get("reason")


def st_matrix(sx, args, step):
    """матрица действия x аудитории: владелец (A) ставит всем 9 действиям аудиторию (список = [carol]) по протоколу;
    A, B (друг), C (в списке) пробуют каждое действие; ожидание: A всегда 0; B — friends/everyone; C — list/everyone;
    иначе 3. Плюс бит EntityPerms.mine == факт."""
    w = W()
    A, B, C = _clients(sx)
    actors = [("owner", A, "alice"), ("friend", B, "bob"), ("listed", C, "carol")]
    eid = w.eid_arg(sx, args)
    home = w.bench_info(sx, eid).get("pos")
    # жертвы удаления: 12 бенчей alice, далеко от луча к цели
    r = w._stdin(sx, "spawn_bench alice dv 12", r"spawned_bench\saccount=alice\seids=", wait=5.0)
    ls = [x for x in r["lines"] if "spawned_bench account=alice eids=" in x]
    victims = [int(v) for v in ls[-1].split("eids=")[1].split()[0].split(",")]
    for i, v in enumerate(victims):
        w._stdin(sx, "bench_place %d %.2f %.2f %.2f" % (v, home[0] + 20 + i, home[1], home[2] + 20), r"bench_place")
    vi = iter(victims)
    cells, bad = [], []
    t0 = time.time()
    for ai, aud in enumerate(AUD):
        codes = []
        for i, a in enumerate(ACTIONS):
            rr, _ = req(sx, A, "EntityPermsSet", {"eid": eid, "action": i + 1, "audience": ai, "list": ["carol"]})
            codes.append(code_of(rr))
        if codes != [0] * 9:
            bad.append("set %s: %s" % (aud, codes))
        mine = {}
        for role, lease, acct in actors:
            victim = next(vi)
            w._stdin(sx, "bench_perms %d destroy %s carol" % (victim, aud), r"perms eid=%d" % victim)
            for a in ACTIONS:
                got, note = _probe(sx, lease, eid, a, victim, home)
                want_ok = role == "owner" or aud == "everyone" or (aud == "friends" and role == "friend") or \
                    (aud == "list" and role == "listed")
                want = 0 if want_ok else 3
                cell = {"audience": aud, "actor": role, "account": acct, "action": a, "want": want, "got": got,
                        "ok": got == want, "note": note}
                cells.append(cell)
                if got != want:
                    bad.append("%s/%s/%s: got %s want %s (%s)" % (aud, role, a, got, want, note))
            pm = next((p for p in w.state(sx, lease).get("perms") or [] if p["eid"] == eid), None)
            mine[role] = pm and pm.get("mine")
        for role, lease, acct in actors:          # бит mine == ожидание по всем 9 действиям
            m = mine.get(role)
            if m is None:
                bad.append("%s/%s: no EntityPerms" % (aud, role))
                continue
            for i, a in enumerate(ACTIONS):
                want_ok = role == "owner" or aud == "everyone" or (aud == "friends" and role == "friend") or \
                    (aud == "list" and role == "listed")
                if bool(m >> i & 1) != want_ok:
                    bad.append("%s/%s mine bit %s=%s" % (aud, role, a, bool(m >> i & 1)))
    # таблица в стиле nagios: строка — (аудитория, актёр), колонки — действия
    table = []
    for aud in AUD:
        for role, _, acct in actors:
            row = {"audience": aud, "actor": "%s(%s)" % (role, acct)}
            for c in cells:
                if c["audience"] == aud and c["actor"] == role:
                    row[c["action"]] = ("OK %s" if c["ok"] else "FAIL %s") % c["got"]
            table.append(row)
    rep = {"eid": eid, "cells": len(cells), "passed": sum(1 for c in cells if c["ok"]), "seconds": round(time.time() - t0, 1),
           "table": table, "world_rules_end": perms_line(sx, eid)}
    _m(sx)["matrix"] = {k: rep[k] for k in ("cells", "passed", "seconds", "table")}
    _save(sx, "olife_perms_matrix.json", dict(rep, detail=cells))
    return {"ok": not bad and rep["passed"] == rep["cells"], "result": {k: rep[k] for k in ("cells", "passed", "seconds")},
            "error": "; ".join(bad[:20]) or None}


def _neg():
    import importlib
    import sys
    W()._tools()                                   # sys.path + свежие кодеки
    tools = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "olife"))
    if tools not in sys.path:
        sys.path.insert(0, tools)
    return importlib.reload(importlib.import_module("perms_neg"))


def st_admin(sx, args, step):
    """админ (dev в olife.admins) при всех правилах «owner» проходит все 9 действий (протокол)"""
    w = W()
    neg = _neg()
    gw = sx.lab.lease_info(P["_roles"](sx)["gateway"])["ports"]["gw"]
    eid = w.eid_arg(sx, args)
    for a in ACTIONS:
        w._stdin(sx, "bench_perms %d %s owner" % (eid, a), r"perms eid=%d" % eid)
    info = w.bench_info(sx, eid)
    r = w._stdin(sx, "spawn_bench alice adm_victim 1", r"spawned_bench\saccount=alice\seids=", wait=5.0)
    victim = int([x for x in r["lines"] if "spawned_bench account=alice eids=" in x][-1].split("eids=")[1].split()[0])
    w._stdin(sx, "bench_place %d %.2f %.2f %.2f" % (victim, info["pos"][0] + 30, info["pos"][1], info["pos"][2]), r"bench_place")
    rep = neg.admin_matrix(gw, eid, victim, info["pos"])
    rep["rules"] = perms_line(sx, eid)
    _m(sx)["admin"] = rep
    _save(sx, "olife_perms_admin.json", rep)
    return {"ok": rep["ok"], "result": rep, "error": None if rep["ok"] else "admin cells %s" % rep["cells"]}


def st_neg(sx, args, step):
    w = W()
    neg = _neg()
    gw = sx.lab.lease_info(P["_roles"](sx)["gateway"])["ports"]["gw"]
    eid = w.eid_arg(sx, args)
    for a in ACTIONS:                               # чужому — правила по умолчанию
        w._stdin(sx, "bench_perms %d %s %s" % (eid, a, "everyone" if a == "read_code" else "owner"), r"perms eid=%d" % eid)
    own = w.eid_arg(sx, args, "own") if args.get("own") else 0
    rep = {"negative": neg.negative(gw, eid, int(args.get("mob", 1)), own)}
    st = P["_status"](sx, "world", "status tick=")
    rep["world_alive"] = bool(st)
    try:
        rep["gateway_alive"] = bool(sx.call("metrics", lease=P["_roles"](sx)["gateway"]))
    except Exception as exc:
        rep["gateway_alive"], rep["gateway_error"] = False, str(exc)
    n = rep["negative"]
    bad = ["%s got %s want %s" % (x["name"], x["got_code"], x["want_code"]) for x in n["results"] if not x["ok"]]
    if not rep["world_alive"] or not rep["gateway_alive"] or not n["client_alive"]:
        bad.append("world/gateway/client dead")
    _m(sx)["neg"] = {"tests": n["tests"], "passed": n["passed"],
                     "table": [{k: x.get(k) for k in ("name", "want_code", "got_code", "ok")} for x in n["results"]]}
    _save(sx, "olife_perms_neg.json", rep)
    return {"ok": not bad, "result": _m(sx)["neg"], "error": "; ".join(bad) or None}


def st_friends_db(sx, args, step):
    """мир -> БД (события дружбы, sync), БД -> мир (add/request/remove оператором с отправкой в мир сессии)"""
    lab, owner = sx.lab, sx.owner
    sess = sx.data.get("session") or sx.data.get("olife", {}).get("session")
    roles = P["_roles"](sx)
    sid = lab.leases[roles["world"]].params.get("session")
    rep, bad = {"session": sid}, []
    rep["sync"] = friend_cmd(lab, owner, "sync", session=sid)
    db_alice = friend_cmd(lab, owner, "list", "alice")
    rep["db_alice_after_sync"] = db_alice
    if "bob" not in db_alice["friends"] or "carol" in db_alice["incoming"]:
        bad.append("DB after sync: %s" % db_alice)
    rep["add"] = friend_cmd(lab, owner, "add", "alice", "dave", sid)
    fl = friends_line(sx)
    rep["world_after_add"] = fl
    if "alice+dave" not in str(fl.get("pairs")):
        bad.append("world after add: %s" % fl)
    A = _clients(sx)[0]
    rep["a_sees_dave"] = bool(W().wait_for(lambda: any(f["account"] == "dave" for f in (W().state(sx, A).get("friends")
                                                                                      or {}).get("friends") or []), 3.0))
    if not rep["a_sees_dave"]:
        bad.append("A did not get the pushed friend dave")
    rep["remove"] = friend_cmd(lab, owner, "remove", "alice", "dave", sid)
    fl = friends_line(sx)
    rep["world_after_remove"] = fl
    if "alice+dave" in str(fl.get("pairs")):
        bad.append("world after remove: %s" % fl)
    rep["request"] = friend_cmd(lab, owner, "request", "dave", "alice", sid)
    rep["a_incoming_dave"] = bool(W().wait_for(lambda: "dave" in ((W().state(sx, A).get("friends") or {}).get("incoming")
                                                                  or []), 3.0))
    if not rep["a_incoming_dave"]:
        bad.append("A did not get the pushed request from dave")
    rep["cancel"] = friend_cmd(lab, owner, "cancel", "dave", "alice", sid)
    rep["world_end"] = friends_line(sx)
    if "dave>alice" in str(rep["world_end"].get("pending")):
        bad.append("world after cancel: %s" % rep["world_end"])
    rep["db_pairs_test_accounts"] = [p for p in friend_cmd(lab, owner, "list")["pairs"]
                                     if {p["a"], p["b"]} & {"alice", "bob", "carol", "dave"}]
    if args.get("cleanup", True):                 # тестовые аккаунты: не оставлять дружбы в общей БД
        sdb = social(lab.sup.db)
        for p in rep["db_pairs_test_accounts"]:
            sdb.friend_set(p["a"], p["b"], "none", owner)
    _m(sx)["friends_db"] = {k: rep.get(k) for k in ("db_alice_after_sync", "world_after_add", "world_after_remove",
                                                   "a_sees_dave", "a_incoming_dave", "world_end")}
    _save(sx, "olife_friends_db.json", rep)
    return {"ok": not bad, "result": _m(sx)["friends_db"], "error": "; ".join(bad) or None}


def st_fork(sx, args, step):
    """B (друг, clone=friends) жмёт «Форк» на странице «Настройки» бенча alice: новый бенч bob перед ним, код/вид/права
    как у источника, тост + звук; B открывает форк Shift+ПКМ, Run -> RUN и движение; C — отказ (3, тост, refuse);
    alice форкает форк bob (правила скопированы, clone=friends, alice — друг bob) -> 0; carol форк форка -> 3"""
    w = W()
    A, B, C = _clients(sx)
    eid = w.eid_arg(sx, args)
    rep, bad = {"eid": eid}, []
    w._stdin(sx, "olife.friend_set alice bob friend", r"friend_set")
    w._stdin(sx, "bench_perms %d clone friends" % eid, r"perms eid=%d" % eid)
    if not w.wait_for(lambda: w.bench_of(w.state(sx, A), eid), 20):
        return {"ok": False, "error": "bench not seen by A"}
    rl, _ = req(sx, A, "EntityEdit", {"eid": eid, "op": 3, "name": "", "model": "olife_bone", "texture": "blocks:planks"})
    rep["source_look"] = code_of(rl)
    src = w.bench_info(sx, eid)
    rep["source"] = {k: src.get(k) for k in ("code_fnv", "model", "texture", "owner", "status")}
    if not w.wait_for(lambda: all(w.bench_of(w.state(sx, x), eid) for x in (A, B, C)), 20):
        return {"ok": False, "error": "bench not seen by all"}
    # B: Injector -> Настройки -> Форк
    g, _ = w.open_with_injector(sx, B, eid)
    w.click(sx, B, g["rects"]["tab_set"])
    g = w.wait_for(lambda: (lambda x: x if x.get("tab") == "set" and (x.get("rects", {}).get("btn_fork") or {}).get("enabled")
                            else None)(w.gui(sx, B)), 4.0) or w.gui(sx, B)
    nf = len(w.state(sx, B).get("forks") or [])
    w.click(sx, B, g["rects"]["btn_fork"])
    fk = w.wait_for(lambda: (lambda l: l[nf] if len(l) > nf else None)(w.state(sx, B).get("forks") or []), 4.0)
    rep["b_fork"] = {"forked": fk, "feedback": feedback(sx, B)}
    rep["shot_b_fork"] = w.shot(sx, B, "a1_fork_b")
    if not fk:
        return {"ok": False, "error": "B fork: no EntityForked (%s)" % rep["b_fork"], "result": rep}
    fe = fk["eid"]
    fi = w.bench_info(sx, fe)
    rep["fork_world"] = {k: fi.get(k) for k in ("owner", "code_fnv", "model", "texture", "status", "forked_from", "pos")}
    if fi.get("owner") != "bob" or fi.get("code_fnv") != src.get("code_fnv") or fi.get("model") != src.get("model") \
            or str(fi.get("forked_from")) != str(eid) or fi.get("status") != "stop":
        bad.append("fork in the world: %s vs source %s" % (rep["fork_world"], rep["source"]))
    rep["fork_rules"] = perms_line(sx, fe)
    rep["source_rules"] = perms_line(sx, eid)
    if {k: v for k, v in rep["fork_rules"].items() if k not in ("eid", "owner")} != \
            {k: v for k, v in rep["source_rules"].items() if k not in ("eid", "owner")}:
        bad.append("fork rules differ: %s" % rep["fork_rules"])
    # the fork stands in front of bob (all players are at the spawn): move it aside, so carol's Injector ray hits the
    # source; bob opens the fork with Shift+RMB (no ray)
    w._stdin(sx, "bench_place %d %.2f %.2f %.2f" % (fe, src["pos"][0] + 5, src["pos"][1], src["pos"][2] + 5), r"bench_place")
    fb = rep["b_fork"]["feedback"]
    if "Форк" not in (fb["toast"] or ""):
        bad.append("B fork toast: %s" % fb)
    close_editor(sx, B)
    # B: Shift+ПКМ -> редактор форка (последний), Run -> RUN, движется (код источника)
    w.press_key(sx, B, "1")
    w.ol(sx, B, "look", yaw=0, pitch=89)
    time.sleep(0.2)
    w.inp(sx, B, keys={"left-shift": True})
    time.sleep(0.08)
    w.mouse_button(sx, B, 1)
    w.inp(sx, B, keys={"left-shift": False})
    gf = w.wait_for(lambda: (lambda x: x if x.get("doc") and x.get("open") == fe else None)(w.gui(sx, B)), 4.0)
    rep["b_open_fork"] = {"opened": bool(gf), "editing": ((gf or {}).get("st") or {}).get("editing")}
    if gf and (gf.get("st") or {}).get("editing"):
        w.click(sx, B, gf["rects"]["btn_run"])
        run = w.wait_for(lambda: w.bench_info(sx, fe).get("status") == "run", 4.0)
        p0 = w.bench_info(sx, fe).get("pos")
        time.sleep(2.0)
        p1 = w.bench_info(sx, fe).get("pos")
        rep["fork_run"] = {"run": bool(run), "moved": round(math.dist(p0, p1), 3) if p0 and p1 else None}
        if not run:
            bad.append("fork did not run")
        if args.get("min_moved") and (rep["fork_run"]["moved"] or 0) < float(args["min_moved"]):
            bad.append("fork did not move: %s" % rep["fork_run"])
        close_editor(sx, B)
    else:
        bad.append("B could not open/edit the fork via Shift+RMB: %s" % rep["b_open_fork"])
    # C: «Форк» — отказ (кнопка выключена: запрос из клиента в обход UI) + тост/звук
    gc, _ = w.open_with_injector(sx, C, eid)
    w.click(sx, C, gc["rects"]["tab_set"])
    gc = w.wait_for(lambda: (lambda x: x if x.get("tab") == "set" and x.get("perms") else None)(w.gui(sx, C)), 4.0) \
        or w.gui(sx, C)
    rep["c_fork_button_enabled"] = (gc["rects"].get("btn_fork") or {}).get("enabled")
    rep["c_opened"] = gc.get("open")
    if gc.get("open") != eid:
        bad.append("carol opened #%s, not the source #%d" % (gc.get("open"), eid))
    w.ol(sx, C, "ui", call="fork")
    rc = w.wait_for(lambda: next((x for x in reversed(w.state(sx, C)["replies"]) if x["op"] == 9), None), 3.0)
    rep["c_fork"] = {"reply": rc, "feedback": feedback(sx, C)}
    rep["shot_c_fork_denied"] = w.shot(sx, C, "a1_fork_c_denied")
    if code_of(rc) != 3 or rep["c_fork_button_enabled"] or "refuse" not in (rep["c_fork"]["feedback"]["sounds"] or []):
        bad.append("C fork: %s, button %s" % (rep["c_fork"], rep["c_fork_button_enabled"]))
    close_editor(sx, C)
    # форк форка: alice (друг bob) -> 0, carol -> 3
    ra, sa = req(sx, A, "EntityFork", {"eid": fe, "name": "fork_of_fork"})
    rc2, _ = req(sx, C, "EntityFork", {"eid": fe, "name": ""})
    rep["fork_of_fork"] = {"alice": code_of(ra), "carol": code_of(rc2)}
    if code_of(ra) != 0 or code_of(rc2) != 3:
        bad.append("fork of fork: %s" % rep["fork_of_fork"])
    ff = w.wait_for(lambda: next((x for x in w.state(sx, A).get("forks") or [] if x["seq"] == sa), None), 3.0)
    if ff:
        rep["fork_of_fork"]["eid"] = ff["eid"]
        rep["fork_of_fork"]["world"] = {k: w.bench_info(sx, ff["eid"]).get(k) for k in ("owner", "forked_from", "code_fnv")}
    _m(sx)["fork"] = {k: rep.get(k) for k in ("source", "fork_world", "fork_run", "c_fork", "fork_of_fork")}
    _save(sx, "olife_fork.json", rep)
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}
