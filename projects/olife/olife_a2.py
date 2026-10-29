"""olife, UX A2 (03.10, агент olife_a2): чат, команды оператора, аудио-визуальная обратная связь.

Подключается из plugin.py (`_a2()`, перезагрузка по mtime этого файла), получает его глобалы (_roles, _group, ...).
Мир — `content/olife_world/modules/ops.lua` (чат, команды, аудит, баны/заморозка/лимиты, Notice), клиент —
`content/olife_client/modules/{chat,fx}.lua` (+ `layouts/chat.xml`, `chat_feed.xml`), протокол — client.yaml 120..123.

Команда оператора = текст чат-команды без «/» (или с ним): `olife.op {text, group?|session?|lease?, by?, via?}` -> stdin
мира `olife.op <rid> <by> <via> "<text>"` -> строка `op_result rid=<rid> code=<c> cmd=<cmd> text=<json>`. Тот же
исполнитель, что у чата («/kill 5» админа), аудит мира фиксирует `via` (chat | cli | panel). CLI: `lab olife op <текст>`,
`lab olife mobs [игрок]`, `lab olife kill|killall|freeze|unfreeze|limits|tp|say|audit ...` (cli_sup.py); панель
`/sup/panel` — кнопки по игрокам и мобам (POST /call/olife.op с via=panel).
Мир получает порт управления песочницы (`--opts sbctl=<порт f2f песочницы>`, `world_opts()` ниже): /limits -> `set_limits`
в sandboxd (та же команда, что тарифы волны 4b, но по владельцу ЭТОГО мира — БД тарифов общая на все миры).

Шаги сценариев:
  olife_a2_setup {admins, samples: [[account, name, code], ...], key?}  — админы, бенчи-примеры (запущены) -> data.a2.mobs
  olife_a2_chat {...}  — olife_chat: T/Enter + набор в окне, доставка с ролью и временем, лимит частоты (Notice 8),
        опоздавший получает историю, прокрутка окна, обратная связь (fx-журнал клиента)
  olife_a2_op {...}    — olife_op: отказы не-админа (16/17), /mobs, freeze/unfreeze (мир+бирка+Notice), limits вживую
        (sandboxd throttled), per-mob actions, kill/killall, tp, CLI и панель (via cli/panel), kick/ban/unban, аудит
"""
import ast
import json
import os
import re
import sys
import time

P = {}
NAMES = {"olife_a2_setup": "st_setup", "olife_a2_chat": "st_chat", "olife_a2_op": "st_op"}
_RID = {"n": 0}
PANEL_MARK = "olife-ops-a2"


def bind(g):
    P.update(g)


# ============================================================================================== мир / песочница
def world_opts(opts, ctl_port):
    """--opts мира + sbctl=<порт управления песочницы> (мир шлёт туда set_limits по /limits)"""
    if not ctl_port:
        return opts
    base = opts if opts and opts != "none" else "none"
    return "%s,sbctl=%d" % (base, int(ctl_port))


def _quote(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def run_op(lab, lease, owner, text, by="operator", via="cli", timeout=6.0):
    """stdin olife.op -> {code, cmd, text, rid}"""
    _RID["n"] += 1
    rid = "a2x%d%03d" % (int(time.time()) % 100000, _RID["n"] % 1000)
    text = text.strip()
    if text.startswith("/"):
        text = text[1:]
    by = re.sub(r"[^A-Za-z0-9_.:-]", "_", by or "operator")[:32] or "operator"
    via = re.sub(r"[^a-z]", "", via or "cli")[:8] or "cli"
    cmd = "olife.op %s %s %s %s" % (rid, by, via, _quote(text))
    r = lab.stdin(lease, cmd, owner=owner, wait=timeout, pattern=r"op_result\srid=%s\s" % rid)
    for line in r.get("lines") or []:
        i = line.find("op_result rid=%s " % rid)
        if i >= 0:
            m = re.match(r"op_result rid=\S+ code=(\d+) cmd=(\S*) text=(.*)$", line[i:].strip())
            if m:
                try:
                    txt = json.loads(m.group(3))
                except ValueError:
                    txt = m.group(3)
                return {"rid": rid, "code": int(m.group(1)), "cmd": m.group(2), "text": txt, "by": by, "via": via}
    return {"rid": rid, "code": None, "error": "no op_result in %.0f s" % timeout, "lines": (r.get("lines") or [])[-5:]}


def _world_of(lab, args, owner):
    """-> (аренда мира, владелец аренды, группа|None)"""
    if args.get("lease"):
        l = lab.leases[args["lease"]]
        return l.name, l.owner, None
    if args.get("session"):
        roles = P["session_leases"](lab, args["session"], None)
        l = lab.leases[roles["world"]]
        return l.name, l.owner, None
    g = P["_group"](lab, args, owner)
    return g.services["world"].lease, g.owner, g.name


def f_op(ctx, args):
    text = args.get("text")
    if not text and args.get("cmd"):
        text = " ".join([str(args["cmd"])] + [str(a) for a in args.get("args") or []])
    if not text:
        raise KeyError("text (chat command without '/') required, e.g. {\"text\": \"freeze #5\"}")
    lease, lowner, grp = _world_of(ctx.lab, args, ctx.owner)
    via = args.get("via") or ("panel" if (ctx.owner or "").startswith("panel") else "cli")
    by = args.get("by") or ctx.owner or via
    r = run_op(ctx.lab, lease, lowner, text, by=by, via=via)
    try:
        ctx.lab.sup.db.event(grp, "world", lease, "op", {"text": text, "by": by, "via": via, "code": r.get("code")})
    except Exception:
        pass
    r.update({"world": lease, "group": grp})
    return r


def f_mobs(ctx, args):
    return f_op(ctx, dict(args, text="mobs " + (args.get("player") or "")))


def register(api):
    obj = {"type": "object"}
    api.feature("op", lambda ctx, a: P["_a2"]().f_op(ctx, a), "UX A2: operator command in a world, as the chat command of an admin "
                "{text: 'kill #5'|'killall bob'|'freeze bob'|'limits bob fuel 20000'|'kick bob'|'ban bob 10 why'|"
                "'tp bob 0 90 0'|'mobs'|'say hi'|'audit 10', group?|session?|lease?, by?, via=cli|panel} -> op_result",
                {"type": "object", "properties": {"text": {"type": "string"}, "group": {"type": "string"},
                                                  "session": {"type": "string"}}}, mcp=True)
    api.feature("mobs", lambda ctx, a: P["_a2"]().f_mobs(ctx, a), "UX A2: mobs of the world (or of {player}) with status/credits {group?|session?}", obj)



# ============================================================================================== панель
def panel_template_has_ops():
    """Секция оператора A2 — в шаблоне панели ядра (labcore/supervise.py PANEL, restart-only): общий демон отдаёт её
    после `lab daemon upgrade` главной сессией; до того кнопки = тот же POST /call/olife.op (фича плагина, живая)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "labcore", "supervise.py")
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "PANEL" for t in node.targets):
            return PANEL_MARK in ast.literal_eval(node.value)
    return False


# ============================================================================================== общее для шагов
def _a(sx):
    return sx.data.setdefault("a2", {"mobs": {}})


def _m(sx):
    return sx.data.setdefault("metrics", {}).setdefault("a2", {})


def W():
    return P["_w4a"]()


def _world(sx):
    return P["_roles"](sx)["world"]


def _op(sx, text, via="cli", by="operator"):
    return run_op(sx.lab, _world(sx), sx.owner, text, by=by, via=via)


def _stdin(sx, cmd, pattern, wait=4.0):
    return sx.lab.stdin(_world(sx), cmd, owner=sx.owner, wait=wait, pattern=pattern)


def ops_state(sx):
    _stdin(sx, "olife.op_state", r"op_state\s")
    p = os.path.join(sx.lab.lease_info(_world(sx))["dir"], "export", "ops_state.json")
    for _ in range(20):
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.1)
    return {}


def audit_rows(sx):
    p = os.path.join(sx.lab.lease_info(_world(sx))["dir"], "export", "audit.jsonl")
    try:
        with open(p, encoding="utf-8") as f:
            return [json.loads(x) for x in f if x.strip()]
    except OSError:
        return []


def _lists(d, keys):
    """пустая Lua-таблица приходит JSON-объектом {} — привести к списку"""
    for k in keys:
        v = d.get(k)
        if isinstance(v, dict):
            d[k] = [v[x] for x in sorted(v, key=lambda z: int(z))] if v else []
    return d


def chat(sx, lease, op="state", **a):
    a["op"] = op
    r = sx.raw("chat", a, lease=lease)
    if not r.get("ok"):
        raise RuntimeError("chat %s on %s: %s" % (op, lease, r.get("error")))
    return _lists(r["result"], ("lines", "results", "notices", "gui", "feed"))


def fxs(sx, lease):
    r = sx.raw("fx", {}, lease=lease)
    return _lists(r.get("result") or {}, ("log",))


def fx_since(st, n0, event=None):
    return [e for e in st.get("log") or [] if e["n"] > n0 and (event is None or e["event"] == event)]


def wait_for(fn, timeout, every=0.1):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = fn()
        if last:
            return last
        time.sleep(every)
    return last


def _tools():
    tools = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "olife"))
    if tools not in sys.path:
        sys.path.insert(0, tools)
    import importlib
    for name in ("olife_proto.client",):
        try:
            importlib.reload(importlib.import_module(name))
        except Exception:
            pass
    return importlib.reload(importlib.import_module("chat_probe"))


def _gw(sx):
    return sx.lab.lease_info(P["_roles"](sx)["gateway"])["ports"]["gw"]


class Checks:
    def __init__(self):
        self.rows = []

    def __call__(self, name, ok, **detail):
        self.rows.append(dict({"check": name, "ok": bool(ok)}, **detail))
        return bool(ok)

    def bad(self):
        return [r["check"] for r in self.rows if not r["ok"]]


def _finish(sx, key, ck, extra=None):
    res = {"checks": len(ck.rows), "passed": len(ck.rows) - len(ck.bad()), "table": ck.rows}
    if extra:
        res.update(extra)
    _m(sx)[key] = res
    with open(os.path.join(sx.out_dir(), "olife_a2_%s.json" % key), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1, default=str)
    bad = ck.bad()
    return {"ok": not bad, "result": {"checks": res["checks"], "passed": res["passed"], "failed": bad},
            "error": "failed: %s" % bad if bad else None}


# ============================================================================================== шаги
def st_setup(sx, args, step):
    out = {}
    if args.get("admins") is not None:
        r = _stdin(sx, "olife.admins %s" % args["admins"], r"admins=")
        out["admins"] = [x for x in r["lines"] if "admins=" in x][-1:]
    for acct, name, code in args.get("samples") or []:
        r = _stdin(sx, "spawn_sample %s %s %s 1" % (acct, name, code), r"spawned_sample\saccount=%s\sname=%s\s" % (acct, name),
                   wait=6.0)
        ls = [x for x in r["lines"] if "spawned_sample account=%s name=%s " % (acct, name) in x]
        if not ls:
            return {"ok": False, "error": "no spawned_sample for %s/%s: %s" % (acct, name, r["lines"][-3:])}
        eid = int(ls[-1].split("eids=")[1].split()[0].split(",")[0])
        _a(sx)["mobs"][name] = {"eid": eid, "account": acct}
        out[name] = eid
    time.sleep(float(args.get("settle", 1.0)))
    return {"ok": True, "result": out}


def _type_chat(sx, lease, key, text):
    """реальный путь игрока: клавиша (t / enter) открывает окно чата, символы, Enter отправляет"""
    w = W()
    w.press_key(sx, lease, key)
    opened = wait_for(lambda: chat(sx, lease).get("open"), 3.0)
    time.sleep(0.15)
    w.inp(sx, lease, chars=text)
    time.sleep(0.1)
    w.press_key(sx, lease, "enter", hold=0.05)
    return bool(opened)


def st_chat(sx, args, step):
    ck = Checks()
    roles = P["_roles"](sx)
    A, B = roles["client1"], roles["client2"]
    cp = _tools()
    w = W()
    gw = _gw(sx)
    extra = {}
    fa0, fb0 = fxs(sx, A).get("n", 0), fxs(sx, B).get("n", 0)
    # 1. A: T -> окно -> «hello from alice» -> Enter; B получает с ролью admin, временем; у A окно с цветной строкой
    t0 = time.time()
    opened = _type_chat(sx, A, "t", "hello from alice")
    ck("A: T opens the chat overlay", opened)
    got = wait_for(lambda: [l for l in chat(sx, B)["lines"] if l["text"] == "hello from alice"], 4.0)
    ck("B receives A's line", bool(got), dt_s=round(time.time() - t0, 2))
    if got:
        l = got[-1]
        ck("line: sender = A's player name, role admin (1), kind player (0), time set",
           l["from"] == "client1" and l["role"] == 1 and l["kind"] == 0 and l["ms"] > 1.6e12, line=l)
        extra["line_b"] = l
    ga = chat(sx, A, "gui")
    vis = [g for g in (ga.get("gui") or []) if "hello from alice" in g.get("text", "")]
    ck("A overlay shows the line (admin colour)", bool(vis), gui_line=vis[-1] if vis else None,
       prompt=ga.get("prompt"), focused=ga.get("prompt_focused"))
    W().shot(sx, A, "a2_chat_overlay")
    w.press_key(sx, A, "escape")
    ck("A: Esc closes the overlay", wait_for(lambda: not chat(sx, A).get("open"), 3.0))
    # 2. B: Enter -> окно -> ответ; у A звук/событие chat (fx) и строка в HUD-ленте
    opened = _type_chat(sx, B, "enter", "hi alice, bob here")
    ck("B: Enter opens the chat overlay", opened)
    got = wait_for(lambda: [l for l in chat(sx, A)["lines"] if l["text"] == "hi alice, bob here"], 4.0)
    ck("A receives B's line (role player)", bool(got) and got[-1]["role"] == 0)
    w.press_key(sx, B, "escape")
    sa = fxs(sx, A)
    ev = fx_since(sa, fa0, "chat")
    ck("A: fx event 'chat' with sound fx_chat", bool(ev) and ev[-1].get("sound") == "fx_chat", events=ev[-2:])
    feed = chat(sx, A).get("feed") or []
    ck("A: HUD feed shows the new line", any("hi alice, bob here" in (x or "") for x in feed), feed=feed)
    W().shot(sx, A, "a2_chat_feed")
    # 3. лимит частоты: carol (протокол) 12 строк подряд -> принято <= запас 5 (+ пополнение), Notice 8, звук у карол нет —
    #    у B видно ровно принятые
    c = cp.ChatClient(gw, "olife-carol", "carol")
    c.pump(0.5)
    for i in range(12):
        c.say("flood %02d" % i)
    c.pump(2.0)
    acc = [l for l in c.lines() if l["from"] == "carol" and l["text"].startswith("flood")]
    nt = [m for m in c.of("Notice") if m["event"] == 8]
    ck("rate limit: carol's 12 lines -> 5..6 accepted", 5 <= len(acc) <= 6, accepted=len(acc))
    ck("rate limit: carol gets Notice 8 (code 20), at most one a second", 1 <= len(nt) <= 3 and nt[0]["code"] == 20,
       notices=len(nt))
    gb = wait_for(lambda: (lambda l: l if len(l) == len(acc) else None)(
        [x for x in chat(sx, B)["lines"] if x["from"] == "carol" and x["text"].startswith("flood")]), 3.0)
    ck("B sees exactly the accepted lines", gb is not None and len(gb) == len(acc))
    # 4. опоздавший: dev подключается -> ChatHistory со всем разговором по порядку
    d = cp.ChatClient(gw, "olife-dev", "dev")
    d.pump(1.0)
    h = d.history()
    texts = [l["text"] for l in (h or {}).get("lines") or []]
    want = ["hello from alice", "hi alice, bob here"] + [l["text"] for l in acc]
    idx = [texts.index(t) if t in texts else -1 for t in want]
    ck("late joiner: ChatHistory has the conversation in order", h is not None and -1 not in idx and idx == sorted(idx),
       history_n=len(texts), total=(h or {}).get("total"))
    ck("late joiner: join line of dev broadcast", any(l["text"] == "dev joined" for l in c.lines()) or
       any(l["text"] == "dev joined" for l in chat(sx, B)["lines"]))
    # 5. команды доступны в чате всем: /help у не-админа без админских команд
    r = d.command("/help")
    ck("/help for a player: no admin commands", r is not None and r["code"] == 0 and "/kill" not in r["text"]
       and "/mobs" in r["text"], code=r and r["code"])
    d.close()
    c.close()
    # 6. прокрутка окна у A: > 14 строк в журнале, ^ на 5 -> окно сдвинуто, «ещё»
    for i in range(4):
        chat(sx, B, "send", text="more %d" % i)
        time.sleep(0.15)
    opened = _type_chat(sx, A, "t", "scroll test")
    time.sleep(0.4)
    g0 = chat(sx, A, "gui")
    ck("A: log longer than the window", g0["count"] > 14, count=g0["count"])
    if g0.get("rects", {}).get("up"):
        w.click(sx, A, g0["rects"]["up"])
    else:
        chat(sx, A, "scroll", d=-5)
    g1 = wait_for(lambda: (lambda x: x if x["bottom"] < g0["bottom"] else None)(chat(sx, A, "gui")), 2.0) or chat(sx, A, "gui")
    ck("A: ^ scrolls back (by 5, not past the first window), 'more' shown",
       g1["bottom"] == max(14, g0["bottom"] - 5) and g1["bottom"] < g0["bottom"] and (g1.get("more") or "") != "",
       bottom=[g0["bottom"], g1["bottom"]], more=g1.get("more"))
    W().shot(sx, A, "a2_chat_scrolled")
    w.press_key(sx, A, "escape")
    sb = fxs(sx, B)
    extra["fx_a"] = sa.get("by_event")
    extra["fx_b"] = sb.get("by_event")
    st = ops_state(sx)
    extra["world"] = {k: (st.get("stats") or {}).get(k) for k in ("chat", "chat_throttled", "history_sent", "notices")}
    ck("world counters: chat >= 8, throttled >= 6, history sent >= 4",
       (st.get("stats") or {}).get("chat", 0) >= 8 and (st.get("stats") or {}).get("chat_throttled", 0) >= 6
       and (st.get("stats") or {}).get("history_sent", 0) >= 4, **extra["world"])
    return _finish(sx, "chat", ck, extra)


def _bench_status(sx, lease, eid):
    b = W().bench_of(W().state(sx, lease), eid)
    return b and b.get("status")


def _pos(sx, eid):
    d = W().bench_info(sx, eid)
    return d.get("pos")


def _moved(sx, eid, seconds=1.0):
    p0 = _pos(sx, eid)
    time.sleep(seconds)
    p1 = _pos(sx, eid)
    if not p0 or not p1:
        return None
    return sum((p1[i] - p0[i]) ** 2 for i in range(3)) ** 0.5


def _notice(sx, lease, fx0, event, timeout=3.0):
    return wait_for(lambda: fx_since(fxs(sx, lease), fx0, event), timeout)


def st_op(sx, args, step):
    try:
        return _st_op(sx, args, step)
    except Exception as exc:
        import traceback
        return {"ok": False, "error": "%s: %s | %s" % (type(exc).__name__, exc, traceback.format_exc(limit=8).replace("\n", " / "))}


def _st_op(sx, args, step):
    ck = Checks()
    roles = P["_roles"](sx)
    A, B = roles["client1"], roles["client2"]
    cp = _tools()
    w = W()
    gw = _gw(sx)
    mobs = _a(sx)["mobs"]
    e1, e2, ec = mobs["bmob1"]["eid"], mobs["bmob2"]["eid"], mobs["cmob"]["eid"]
    extra = {}

    def a_cmd(text, timeout=4.0):
        """админ alice из окна (F2F chat send = то же, что Enter в окне чата) -> OpResult у A"""
        n0 = len(chat(sx, A)["results"])
        chat(sx, A, "send", text=text)
        return wait_for(lambda: (lambda r: r[-1] if len(r) > n0 else None)(chat(sx, A)["results"]), timeout)

    # 1. не-админ: bob из окна (путь игрока: Enter, набор), carol протоколом -> 16 / 17, звук отказа у bob
    fb0 = fxs(sx, B).get("n", 0)
    _type_chat(sx, B, "enter", "/kill #%d" % e1)
    rb = wait_for(lambda: chat(sx, B)["results"][-1:] or None, 4.0)
    ck("bob /kill -> 16 forbidden", bool(rb) and rb[-1]["code"] == 16 and rb[-1]["cmd"] == "kill", r=rb and rb[-1])
    ev = fx_since(fxs(sx, B), fb0, "deny")
    ck("bob: fx deny (sound refuse, toast)", bool(ev) and ev[-1]["sound"] == "refuse", ev=ev[-1:])
    w.press_key(sx, B, "escape")
    c = cp.ChatClient(gw, "olife-carol", "carol").background()      # keeps carol alive while alice works
    r1, r2, r3 = c.command("/freeze bob"), c.command("/blah"), c.command("/mobs")
    ck("carol /freeze -> 16, /blah -> 17", (r1 or {}).get("code") == 16 and (r2 or {}).get("code") == 17)
    ck("carol /mobs -> only her own", (r3 or {}).get("code") == 0 and "#%d" % ec in r3["text"] and "#%d" % e1 not in r3["text"],
       text=(r3 or {}).get("text"))
    # 2. /mobs bob у админа
    r = a_cmd("/mobs bob")
    ck("alice /mobs bob -> 2 mobs", r and r["code"] == 0 and "#%d" % e1 in r["text"] and "#%d" % e2 in r["text"],
       text=r and r["text"])
    # 3. freeze / unfreeze моба: мир не двигает, бирка FROZEN у B, Notice 9 + звук fx_freeze
    ck("bmob1 moves before freeze", (_moved(sx, e1) or 0) > 0.3)
    fb0 = fxs(sx, B).get("n", 0)
    r = a_cmd("/freeze #%d" % e1)
    ck("alice /freeze mob -> 0", r and r["code"] == 0, text=r and r["text"])
    mv = _moved(sx, e1, 1.0)
    ck("frozen mob does not move (world)", mv is not None and mv < 0.01, moved=mv)
    ck("B: tag status FROZEN (4)", wait_for(lambda: _bench_status(sx, B, e1) == 4, 3.0))
    ev = _notice(sx, B, fb0, "frozen")
    ck("B: Notice -> fx 'frozen' (sound fx_freeze)", bool(ev) and ev[-1]["sound"] == "fx_freeze", ev=ev and ev[-1])
    w.press_key(sx, B, "1")
    time.sleep(0.4)
    W().shot(sx, B, "a2_tag_frozen")
    fb0 = fxs(sx, B).get("n", 0)
    r = a_cmd("/unfreeze #%d" % e1)
    ck("unfreeze -> mob moves again", r and r["code"] == 0 and (_moved(sx, e1, 1.0) or 0) > 0.3)
    ck("B: fx 'unfrozen'", bool(_notice(sx, B, fb0, "unfrozen")))
    ck("B: tag back to RUN (1)", wait_for(lambda: _bench_status(sx, B, e1) == 1, 3.0))
    # 4. лимиты вживую: /limits bob fuel 20000 + bucket 0 -> песочница throttled, бирка THROTTLED, Notice; обратно
    fb0 = fxs(sx, B).get("n", 0)
    r = a_cmd("/limits bob fuel 20000")
    r2 = a_cmd("/limits bob bucket 0")
    ck("alice /limits bob fuel|bucket -> 0", r and r["code"] == 0 and r2 and r2["code"] == 0, text=[r and r["text"], r2 and r2["text"]])
    owner = int(re.search(r"owner #(\d+)", (r or {}).get("text") or "owner #0").group(1))
    lim = wait_for(lambda: (lambda x: x if (x or {}).get("limits", {}).get("fuel_per_tick") == 20000 else None)(
        _sb_limits(sx, owner)), 3.0)
    ck("sandboxd: owner limits fuel_per_tick=20000 tick_cap=20000 bucket_max=0", lim is not None and
       lim["limits"].get("tick_cap") == 20000 and lim["limits"].get("bucket_max") == 0, limits=(lim or {}).get("limits"))
    th = wait_for(lambda: _bench_status(sx, B, e1) == 3, 5.0)
    ck("B: tag THROTTLED (3) while limited", th)
    ev = fx_since(fxs(sx, B), fb0, "limits")
    ck("B: fx 'limits' (Notice 4)", bool(ev), ev=ev[-1:])
    W().shot(sx, B, "a2_tag_throttled")
    st = ops_state(sx)
    ck("world: ctl replies ok", (st.get("stats") or {}).get("ctl_ok", 0) >= 2, ctl=st.get("ctl"))
    a_cmd("/limits bob fuel default")
    a_cmd("/limits bob bucket default")
    ck("defaults back -> tag RUN", wait_for(lambda: _bench_status(sx, B, e1) == 1, 6.0))
    # 5. per-mob actions (мир): /limits #e2 actions 0 -> моб стоит; default -> идёт
    r = a_cmd("/limits #%d actions 0" % e2)
    mv = _moved(sx, e2, 1.0)
    ck("mob limit actions=0 -> world rejects its actions", r and r["code"] == 0 and mv is not None and mv < 0.01, moved=mv)
    a_cmd("/limits #%d actions default" % e2)
    # demo_orbit's target ran on along its circle while the mob stood: moves > 2 blocks are refused ("step > 2")
    # until the circle comes back to it (period 6.3 s) -> wait for movement up to 8 s
    ck("mob limit default -> moves again", wait_for(lambda: (_moved(sx, e2, 0.5) or 0) > 0.2, 8.0, every=0.0))
    # 6. CLI и панель (тот же исполнитель, via cli/panel): freeze carol's mob через CLI, unfreeze через POST /call (панель)
    rc = _op(sx, "freeze #%d" % ec, via="cli", by=sx.owner or "operator")
    ck("CLI olife.op freeze -> 0", rc.get("code") == 0, r=rc)
    nc = wait_for(lambda: (c.pump(0.1), [m for m in c.of("Notice") if m["event"] == 9])[1], 3.0)
    ck("carol: Notice 9 (her mob frozen)", bool(nc))
    rp = _panel_call(sx, "unfreeze #%d" % ec)
    ck("panel POST /call/olife.op unfreeze -> 0", (rp.get("result") or {}).get("code") == 0, r=rp)
    live = PANEL_MARK in _panel_html(sx)
    ck("panel template (labcore/supervise.py) has the operator section", panel_template_has_ops(), live_daemon=live)
    # 7. tp: bob на 6 блоков вверх
    pb = (W().state(sx, B).get("camera") or {}).get("pos")
    r = a_cmd("/tp bob %.1f %.1f %.1f" % (pb[0], pb[1] + 6, pb[2])) if pb else None
    pb2 = wait_for(lambda: (lambda p: p if p and abs(p[1] - (pb[1] + 6)) < 0.6 else None)(
        (W().state(sx, B).get("camera") or {}).get("pos")), 3.0) if pb else None
    ck("/tp bob -> B camera moved by the world", r and r["code"] == 0 and pb2 is not None, before=pb, after=pb2)
    # 8. kill / killall
    fb0 = fxs(sx, B).get("n", 0)
    r = a_cmd("/kill #%d" % e1)
    gone = wait_for(lambda: W().bench_of(W().state(sx, B), e1) is None, 4.0)
    ck("/kill -> mob gone at world and B", r and r["code"] == 0 and gone and not W().bench_info(sx, e1).get("eid"))
    ck("B: fx 'killed' (sound delete)", bool(_notice(sx, B, fb0, "killed")))
    r = a_cmd("/killall bob")
    ck("/killall bob -> 1 left killed", r and r["code"] == 0 and "killed 1 mobs of bob" in r["text"], text=r and r["text"])
    # 9. kick bob (окно) -> Disconnect 10, fx kicked; ban carol -> 5, повторный вход отказан; unban -> вход
    fb0 = fxs(sx, B).get("n", 0)
    r = a_cmd("/kick bob test kick")
    ck("/kick bob -> 0", r and r["code"] == 0)
    # the kicked client ends its script (the windowed test client exits when the connection is closed) -> its log
    def blog(pat):
        try:
            return [x for x in sx.lab.logs(B, tail=400)["lines"] if pat in x]
        except Exception:
            return []
    kd = wait_for(lambda: blog("fx kicked sound=fx_kick"), 5.0)
    ck("B: Notice 5 -> fx 'kicked' (sound fx_kick), Disconnect 10", bool(kd) and bool(blog("disconnected by server: 10")),
       line=kd and kd[-1][-160:])
    r = a_cmd("/ban carol 1 a2 test")
    wait_for(lambda: (c.pump(0.1), c.disconnect_code())[1], 3.0)
    ck("/ban carol -> carol Disconnect 5", r and r["code"] == 0 and c.disconnect_code() == 5, dc=c.disconnect_code())
    c2 = cp.ChatClient(gw, "olife-carol", "carol", wait_welcome=False)
    c2.pump(1.5)
    ck("banned carol re-login refused (Disconnect 5)", c2.welcome is None and c2.disconnect_code() == 5,
       dc=c2.disconnect_code())
    r = a_cmd("/unban carol")
    c3 = cp.ChatClient(gw, "olife-carol", "carol")
    ck("/unban -> carol logs in", r and r["code"] == 0 and c3.welcome is not None)
    c3.close()
    # 10. аудит: все действия, отказ по правам, via chat/cli/panel; op-строки в чате у A
    rows = audit_rows(sx)
    cmds = [(x["cmd"], x["code"], x["via"]) for x in rows]
    need = {"kill", "killall", "freeze", "unfreeze", "limits", "kick", "ban", "unban", "tp"}
    ck("audit.jsonl: every op command", need <= {x["cmd"] for x in rows}, n=len(rows))
    ck("audit: refusals by rights (16) recorded", any(x[1] == 16 for x in cmds))
    ck("audit: via chat, cli and panel", {"chat", "cli", "panel"} <= {x[2] for x in cmds})
    opl = [l for l in chat(sx, A)["lines"] if l["kind"] == 2]
    ck("op lines broadcast in chat (kind 2)", len(opl) >= 8, n=len(opl))
    extra["audit_rows"] = len(rows)
    extra["fx_a"] = fxs(sx, A).get("by_event")
    extra["fx_b"] = fxs(sx, B).get("by_event")
    return _finish(sx, "op", ck, extra)


def _sb_limits(sx, owner):
    try:
        r = sx.call("limits", {"owner": owner}, lease=P["_roles"](sx)["sandbox"])
    except Exception:
        return None
    for o in (r or {}).get("owners") or []:
        if o.get("owner") == owner:
            return o
    return None


def _daemon(sx):
    return "http://127.0.0.1:%d" % sx.lab.cfg["daemon"]["port"]


def _panel_call(sx, text):
    """ровно то, что делает кнопка панели: POST /call/olife.op {args: {session, text, via: panel}}"""
    import urllib.request
    body = json.dumps({"args": {"session": sx.data["session"]["session"], "text": text, "via": "panel", "by": "panel"}})
    req = urllib.request.Request(_daemon(sx) + "/call/olife.op", data=body.encode(), method="POST",
                                 headers={"Content-Type": "application/json", "X-Lab-Client": "panel"})
    try:
        with urllib.request.urlopen(req, timeout=15) as f:
            return json.loads(f.read().decode())
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def _panel_html(sx):
    import urllib.request
    try:
        with urllib.request.urlopen(_daemon(sx) + "/sup/panel?prefix=olife&title=Olife", timeout=10) as f:
            return f.read().decode()
    except Exception as exc:
        return "error %s" % exc


def steps():
    def lazy(n):
        def f(sx, args, step):
            try:
                return getattr(P["_a2"](), NAMES[n])(sx, args, step)
            except Exception as exc:
                import traceback
                return {"ok": False, "error": "%s: %s | %s" % (type(exc).__name__, exc,
                                                               traceback.format_exc(limit=6).replace("\n", " / "))}
        return f
    return {n: lazy(n) for n in NAMES}


def selftest():
    assert world_opts("none", 123) == "none,sbctl=123"
    assert world_opts("snap=full", 5) == "snap=full,sbctl=5"
    assert world_opts("x", 0) == "x"
    assert _quote('a "b" \\c') == '"a \\"b\\" \\\\c"'
