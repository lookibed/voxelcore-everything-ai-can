"""olife: антифрод и бан по IP (16.10, агент olife_antifraud) — agents/research/OLIFE_ANTIFRAUD.md.
Подключается из plugin.py (`_fraud()`, перезагрузка по mtime; возможности — обёртки, функция берётся из свежего модуля).

Источник правды — БД supervisor: баны по IP — таблица `bans` (kind `ip`, value — адрес или CIDR в каноническом виде,
until, reason, by = оператор | `fraud`); настройки — account_settings `_fraud:cfg` (ключ -> значение, нет строки =
умолчание DEFAULTS), доверие — `_fraud:trust` (аккаунт -> множитель порогов), страйки — `_fraud:strike` (`ip:<адрес>` |
`acct:<аккаунт>` -> "n|t"), снятия — `_fraud:cleared` (аккаунт -> время: мир обнуляет очки). Живое (окна частот, ники
с IP, привязка ника к IP, присутствие из gw_sync, кольцо событий) — в памяти демона (`lab._olife_fraud`, переживает
перезагрузку модуля, не рестарт демона). События — `<data>/olife/fraud_events.jsonl`, аудит — `fraud_audit.jsonl`.

Возможности (регистрация — register()):
  olife.ip_check   {ip, gateway?}                    сервис билетов (вход по токену): бан IP, частоты IP и /24, сессии с IP
  olife.auth_name  (olife_menu.py) зовёт nick_precheck/nick_postcheck/note_login: + ник (зарезервированные, похожие,
                   в игре с другого IP, grace), мультиаккаунт
  olife.gw_sync    {gateway, gw_id?, sessions: [[account, ip, name]], events: [{ip, kind, n}]}   шлюзы раз в 2 с ->
                   {accounts: [...], ips: [{net, until, reason, id}], cfg: {...}}
  olife.fraud      {action = status|events|set|clear|trust|report|cfg|ipban|unban|bans, ...}
Коды отказов (сервис билетов `code`): ip_banned, rate_ip, rate_net, multi_account, sessions_ip, nick_in_use,
nick_similar, nick_reserved."""
import collections
import ipaddress
import json
import os
import re
import threading
import time

P = {}
NICK_RX = re.compile(r"^[A-Za-z0-9_.\-]{2,24}$")

DEFAULTS = {
    "enabled": 1,
    "exempt": "127.0.0.1/32",          # автоматика (лимиты, автобаны) не трогает эти сети; ручные баны — да
    "ticket_rate_ip": 20, "ticket_rate_net": 60, "rate_window_s": 60,
    "net_prefix": 24, "net_prefix6": 64,
    "nicks_per_ip": 4, "nicks_window_s": 600,
    "sessions_per_ip": 3,
    "nick_grace_s": 300,
    "conn_rate_net": 60,               # шлюзы: новых соединений в секунду с подсети (всплеск ×3)
    "gw_limit_events": 5,              # отказов лимита шлюза с IP за одну сводку gw_sync -> страйк (автобан)
    "autoban_base_s": 60, "autoban_factor": 2, "autoban_max_s": 86400, "strike_forget_s": 86400,
    # скоринг в мире (fraud.lua берёт отсюда, `cfg`)
    "score_half_life_s": 30, "w_chat": 1, "w_cmd": 1, "w_action": 1, "w_req": 1, "w_spawn": 2, "w_reconnect": 3,
    "reconnect_free": 3, "reconnect_window_s": 60,
    "warn": 10, "throttle": 20, "kick": 35, "ban": 50, "throttle_s": 15,
    "ban_base_min": 5, "ip_after_bans": 2,
    "trust_step": 2, "trust_max": 8,
}
STR_KEYS = {"exempt"}
RESERVED = ("admin", "administrator", "op", "operator", "server", "root", "system", "console", "world", "olife",
            "moderator", "mod", "owner", "support", "null", "guest", "fraud", "supervisor")
# гомоглифы -> латиница (кириллица, греческий), цифры-двойники
HOMO = {"а": "a", "в": "b", "е": "e", "ё": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c", "т": "t",
        "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "ӏ": "l", "α": "a", "β": "b", "ε": "e", "ι": "i",
        "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "χ": "x", "ω": "w",
        "0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "9": "g", "i": "l", "|": "l", "!": "l"}


def bind(g):
    P.update(g)


# ============================================================================================== состояние
def _S(lab):
    s = getattr(lab, "_olife_fraud", None)
    if s is None:
        s = {"lock": threading.RLock(), "tickets": {}, "net": {}, "nicks": {}, "bind": {}, "presence": {},
             "events": collections.deque(maxlen=500), "worlds": {}, "gw_events": {}, "n": 0}
        lab._olife_fraud = s
    return s


def _sdb(lab):
    return P["_a1"]().social(lab.sup.db)


def cfg(lab):
    over = _sdb(lab).settings_of("_fraud:cfg")
    c = dict(DEFAULTS)
    for k, v in over.items():
        if k not in DEFAULTS:
            continue
        if k in STR_KEYS:
            c[k] = v
        else:
            try:
                c[k] = float(v) if "." in str(v) else int(v)
            except ValueError:
                pass
    return c


def _dir(lab):
    d = os.path.join(lab.data, "olife")
    os.makedirs(d, exist_ok=True)
    return d


def event(lab, kind, **kw):
    st = _S(lab)
    rec = dict(kw, kind=kind, ts=round(time.time(), 3))
    with st["lock"]:
        st["n"] += 1
        rec["n"] = st["n"]
        st["events"].append(rec)
    try:
        with open(os.path.join(_dir(lab), "fraud_events.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass
    return rec


def audit(lab, rec):
    try:
        with open(os.path.join(_dir(lab), "fraud_audit.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(dict(rec, ts=time.time()), ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


# ============================================================================================== адреса
def norm_ip(s):
    """'1.2.3.4' | '::ffff:1.2.3.4' | '1.2.3.4:5678' -> ip_address | None"""
    if s is None:
        return None
    s = str(s).strip()
    if s.count(":") == 1 and "." in s:          # ipv4:port
        s = s.split(":", 1)[0]
    s = s.strip("[]").split("%", 1)[0]
    try:
        a = ipaddress.ip_address(s)
    except ValueError:
        return None
    if a.version == 6 and a.ipv4_mapped:
        a = a.ipv4_mapped
    return a


def norm_net(s):
    """адрес или CIDR -> канонический ip_network (хостовые биты обнулены) | None"""
    try:
        n = ipaddress.ip_network(str(s).strip(), strict=False)
    except ValueError:
        return None
    return n


def net_str(n):
    return str(n.network_address) if n.prefixlen == n.max_prefixlen else str(n)


def subnet_of(a, c):
    return ipaddress.ip_network("%s/%d" % (a, int(c["net_prefix"] if a.version == 4 else c["net_prefix6"])),
                                strict=False)


def exempt_nets(c):
    out = []
    for x in re.split(r"[,\s]+", str(c.get("exempt") or "")):
        n = norm_net(x) if x else None
        if n is not None:
            out.append(n)
    return out


def is_exempt(a, c):
    return a is not None and any(a.version == n.version and a in n for n in exempt_nets(c))


def mask_ip(addr):
    """для не-админов: a.b.x.x (IPv6 — первые 2 группы)"""
    a = norm_ip(addr)
    if a is None:
        return "?"
    if a.version == 4:
        p = str(a).split(".")
        return "%s.%s.x.x" % (p[0], p[1])
    return ":".join(a.exploded.split(":")[:2]) + ":x"


# ============================================================================================== баны по IP
def ip_bans(lab):
    out = []
    for r in lab.sup.db.active_bans()["rows"]:
        if r["kind"] != "ip":
            continue
        n = norm_net(r["value"])
        if n is not None:
            out.append((n, r))
    return out


def ip_ban_of(lab, ip):
    a = norm_ip(ip)
    if a is None:
        return None
    for n, r in ip_bans(lab):
        if a.version == n.version and a in n:
            return r
    return None


def until_text(u):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(u)) if u else "навсегда"


def ban_text(r):
    return "бан по IP %s до %s: %s" % (r["value"], until_text(r.get("until")), r.get("reason") or "")


def _gateways(lab):
    out = []
    with lab.lock:
        for l in lab.leases.values():
            if l.project == "olife" and l.kind in ("gateway", "gateway_rs", "gateway_rs_public") and l.proc is not None and l.proc.alive():
                out.append((l.name, l.owner))
    return out


def push_kick(lab, nets, reason, code=5, ban=None):
    """немедленно на всех живых шлюзах olife (F2F `kick_ip`): kick сессий из сетей и (ban) бан в их список до
    следующего gw_sync — отказ до Hello сразу, а не через <= 2 с"""
    res = {}
    for name, owner in _gateways(lab):
        try:
            a = {"nets": nets, "reason": reason[:250], "code": code}
            if ban:
                a["ban"] = ban
            rep = lab.f2f_quiet(name, "kick_ip", a, timeout=3, owner=owner)
            res[name] = rep.get("result") if rep.get("ok") else {"error": rep.get("error")}
        except Exception as exc:
            res[name] = {"error": "%s: %s" % (type(exc).__name__, exc)}
    return res


def ipban(lab, value, minutes=0, reason="", by=None, via="cli", force=False, auto=False):
    n = norm_net(value)
    if n is None:
        return {"ok": False, "code": "args", "reason": "not an IP address or CIDR: %r" % value}
    c = cfg(lab)
    if not force and not auto:
        for e in exempt_nets(c):
            if e.version == n.version and (n.overlaps(e)):
                return {"ok": False, "code": "exempt",
                        "reason": "%s covers the exempt network %s (local player/lab); force=1 to ban anyway" % (n, e)}
    v = net_str(n)
    r = lab.sup.db.ban("ip", v, float(minutes or 0), reason or ("автобан" if auto else "operator"), by or "operator")
    r["text"] = ban_text(r)
    lab.sup.db.event(None, None, None, "ban", r)
    event(lab, "autoban_ip" if auto else "ipban", net=v, until=r["until"], reason=r["reason"], by=r["by"], via=via)
    audit(lab, {"op": "ipban", "net": v, "minutes": minutes, "reason": r["reason"], "by": r["by"], "via": via,
                "auto": auto})
    r["kicked"] = push_kick(lab, [v], ban_text(r), ban=[{"net": v, "until": r["until"], "reason": r["reason"]}])
    r["ok"] = True
    return r


def ipunban(lab, value, by=None, via="cli"):
    n = norm_net(value)
    v = net_str(n) if n is not None else str(value)
    r = lab.sup.db.unban("ip", v, by or "operator")
    lab.sup.db.event(None, None, None, "unban", dict(r, value=v, by=by))
    audit(lab, {"op": "unban_ip", "net": v, "by": by, "via": via, "lifted": r["lifted"]})
    event(lab, "unban_ip", net=v, by=by, via=via, lifted=r["lifted"])
    r.update(ok=True, value=v, text="unbanned ip %s (%d)" % (v, r["lifted"]))
    return r


def bans_list(lab):
    rows = lab.sup.db.active_bans()["rows"]
    out = [{"id": r["id"], "kind": r["kind"], "value": r["value"], "until": r["until"], "reason": r["reason"],
            "by": r["by"], "auto": r["by"] == "fraud"} for r in rows]
    txt = ["bans: %d" % len(out)] + ["#%d %s %s until %s by %s: %s" % (b["id"], b["kind"], b["value"],
                                                                      until_text(b["until"]), b["by"], b["reason"] or "")
                                    for b in out[-30:]]
    return {"ok": True, "bans": out, "text": "\n".join(txt)}


# ============================================================================================== страйки, автобан
def _strike(lab, key, bump=True):
    sdb, c = _sdb(lab), cfg(lab)
    cur = sdb.settings_of("_fraud:strike").get(key)
    n, t = 0, 0.0
    if cur:
        try:
            a, b = cur.split("|")
            n, t = int(a), float(b)
        except ValueError:
            pass
    if time.time() - t > float(c["strike_forget_s"]):
        n = 0
    if bump:
        n += 1
        sdb.setting_set("_fraud:strike", key, "%d|%.0f" % (n, time.time()), "fraud")
    return n


def autoban_ip(lab, ip, rule, detail=""):
    c = cfg(lab)
    a = norm_ip(ip)
    if a is None or is_exempt(a, c) or not int(c["enabled"]):
        event(lab, "autoban_skipped", ip=str(ip), rule=rule, why="exempt" if a is not None else "bad ip")
        return None
    if ip_ban_of(lab, str(a)):
        return None                               # уже забанен (идущие запросы гонки)
    n = _strike(lab, "ip:%s" % a)
    secs = min(float(c["autoban_base_s"]) * float(c["autoban_factor"]) ** (n - 1), float(c["autoban_max_s"]))
    return ipban(lab, str(a), secs / 60.0, "автобан: %s (страйк %d, %d с)%s" % (rule, n, round(secs),
                                                                             (": " + detail) if detail else ""),
                 by="fraud", via="auto", auto=True)


def _window(d, key, now, window):
    q = d.get(key)
    if q is None:
        q = d[key] = collections.deque()
    while q and q[0] < now - window:
        q.popleft()
    return q


def _refuse(lab, code, reason, ip, **kw):
    event(lab, "refused", code=code, ip=str(ip), reason=reason[:200], **kw)
    return dict({"ok": False, "code": code, "reason": reason[:250]}, **{k: v for k, v in kw.items() if k == "until"})


# ============================================================================================== проверки входа
def _online(lab, now=None):
    """[(account, ip, gateway)] из свежих сводок шлюзов"""
    now = now or time.time()
    out = []
    st = _S(lab)
    with st["lock"]:
        for gw, p in st["presence"].items():
            if now - p["t"] < 6.0:
                for s in p["sessions"]:
                    out.append((s[0], s[1], gw))
    return out


def ip_check(lab, ip, gateway=None, kind="token"):
    """бан IP, частоты IP и подсети, сессии с IP -> None | отказ"""
    c = cfg(lab)
    a = norm_ip(ip)
    b = ip_ban_of(lab, ip)
    if b:
        return _refuse(lab, "ip_banned", ban_text(b), ip, until=b.get("until"), gateway=gateway)
    if a is None or not int(c["enabled"]) or is_exempt(a, c):
        return None
    st, now = _S(lab), time.time()
    win = float(c["rate_window_s"])
    with st["lock"]:
        q = _window(st["tickets"], str(a), now, win)
        q.append(now)
        nip = len(q)
        net = subnet_of(a, c)
        qn = _window(st["net"], str(net), now, win)
        qn.append(now)
        nnet = len(qn)
    if nip > int(c["ticket_rate_ip"]):
        r = autoban_ip(lab, str(a), "частота билетов с IP %d за %d с > %d" % (nip, win, int(c["ticket_rate_ip"])))
        return _refuse(lab, "rate_ip", "антифрод: слишком часто с вашего адреса (%d за %d с, лимит %d)%s" % (
            nip, win, int(c["ticket_rate_ip"]), "; " + r["text"] if r else ""), ip, gateway=gateway,
            until=r["until"] if r else None)
    if nnet > int(c["ticket_rate_net"]):
        r = autoban_ip(lab, str(a), "частота билетов с подсети %s %d за %d с > %d" % (net, nnet, win,
                                                                                    int(c["ticket_rate_net"])))
        return _refuse(lab, "rate_net", "антифрод: слишком часто с подсети %s (%d за %d с, лимит %d)%s" % (
            net, nnet, win, int(c["ticket_rate_net"]), "; " + r["text"] if r else ""), ip, gateway=gateway,
            until=r["until"] if r else None)
    n_on = sum(1 for (_, sip, _) in _online(lab) if sip == str(a))
    if n_on >= int(c["sessions_per_ip"]):
        return _refuse(lab, "sessions_ip", "антифрод: с адреса %s уже %d сессий (лимит %d)" % (a, n_on,
                                                                                         int(c["sessions_per_ip"])),
                       ip, gateway=gateway)
    return None


def skeleton(name):
    s = "".join(HOMO.get(ch, ch) for ch in str(name).lower())
    return re.sub(r"[\s_.\-]+", "", s)


def nick_precheck(lab, name, ip, gateway=None):
    """до прежних проверок auth_name: бан IP/частоты/сессии, зарезервированные и похожие ники (и не-ASCII)"""
    r = ip_check(lab, ip, gateway, kind="nick")
    if r:
        return r
    if not isinstance(name, str) or not name:
        return None
    sk = skeleton(name)
    if name.lower() in RESERVED or sk in {skeleton(x) for x in RESERVED}:
        return _refuse(lab, "nick_reserved", "ник «%s» зарезервирован (служебное имя)" % name, ip, name=name)
    with lab.sup.db.lock:
        names = [r[0] for r in lab.sup.db.db.execute("SELECT name FROM accounts").fetchall()]
    if name in names:
        return None                                    # свой ник (дальше — прежние проверки)
    for other in names:
        if other.startswith("_"):
            continue
        if skeleton(other) == sk:
            return _refuse(lab, "nick_similar", "ник «%s» слишком похож на существующий «%s»" % (name, other), ip,
                           name=name, similar=other)
    if not NICK_RX.match(name):
        return None                                    # дальше bad_name
    return None


def nick_postcheck(lab, name, ip, gateway=None):
    """после прежних проверок (бан аккаунта, вайтлист): ник в игре/в grace с другого IP, мультиаккаунт"""
    c = cfg(lab)
    a = norm_ip(ip)
    now = time.time()
    st = _S(lab)
    for acct, sip, gw in _online(lab, now):
        if acct == name and sip != str(a):
            return _refuse(lab, "nick_in_use", "ник «%s» уже в игре с другого адреса (%s)" % (name, mask_ip(sip)),
                           ip, name=name)
    with st["lock"]:
        b = st["bind"].get(name)
    grace = float(c["nick_grace_s"])
    if b and b["ip"] != str(a) and now - b["t"] < grace:
        return _refuse(lab, "nick_in_use", "ник «%s» закреплён за другим адресом ещё %d с (grace)" % (
            name, int(grace - (now - b["t"]))), ip, name=name)
    if a is not None and int(c["enabled"]) and not is_exempt(a, c):
        win = float(c["nicks_window_s"])
        with st["lock"]:
            d = st["nicks"].setdefault(str(a), {})
            for k in [k for k, t in d.items() if t < now - win]:
                d.pop(k)
            known = name in d
            n = len(d) + (0 if known else 1)
            if known or n <= int(c["nicks_per_ip"]):
                d[name] = now
        if not known and n > int(c["nicks_per_ip"]):
            r = autoban_ip(lab, str(a), "мультиаккаунт: %d ников с IP за %d с > %d" % (n, win, int(c["nicks_per_ip"])))
            return _refuse(lab, "multi_account", "антифрод: с вашего адреса уже %d разных ников за %d мин (лимит %d)%s"
                           % (n - 1, win / 60, int(c["nicks_per_ip"]), "; " + r["text"] if r else ""), ip, name=name,
                           until=r["until"] if r else None)
    return None


def note_login(lab, name, ip):
    a = norm_ip(ip)
    st = _S(lab)
    with st["lock"]:
        st["bind"][name] = {"ip": str(a) if a else str(ip), "t": time.time()}


# ============================================================================================== шлюзы
def gw_sync(lab, args):
    c = cfg(lab)
    gw = str(args.get("gateway") or "?")
    st, now = _S(lab), time.time()
    sess = []
    for s in args.get("sessions") or []:
        if isinstance(s, (list, tuple)) and len(s) >= 2:
            a = norm_ip(s[1])
            sess.append((str(s[0]), str(a) if a else str(s[1]), str(s[2]) if len(s) > 2 else str(s[0])))
    with st["lock"]:
        st["presence"][gw] = {"t": now, "sessions": sess, "gw_id": args.get("gw_id")}
        for acct, ip, _ in sess:
            st["bind"][acct] = {"ip": ip, "t": now}
        for k in [k for k, p in st["presence"].items() if now - p["t"] > 60]:
            st["presence"].pop(k)
    hits = collections.Counter()
    for e in args.get("events") or []:
        if isinstance(e, dict) and e.get("ip"):
            hits[(str(e["ip"]), str(e.get("kind") or "limit"))] += int(e.get("n") or 1)
    for (ip, kind), n in hits.items():
        event(lab, "gw_" + kind, ip=ip, n=n, gateway=gw)
        if n >= int(c["gw_limit_events"]):
            autoban_ip(lab, ip, "шлюз %s: %d отказов «%s» за сводку" % (gw, n, kind))
    b = lab.sup.db.active_bans()
    ips = [{"net": r["value"], "until": r["until"], "reason": r["reason"] or "", "id": r["id"], "by": r["by"]}
           for r in b["rows"] if r["kind"] == "ip" and norm_net(r["value"]) is not None]
    return {"ok": True, "accounts": b["accounts"], "ips": ips,
            "cfg": {"enabled": int(c["enabled"]), "sessions_per_ip": int(c["sessions_per_ip"]),
                    "conn_rate_net": float(c["conn_rate_net"]), "net_prefix": int(c["net_prefix"]),
                    "net_prefix6": int(c["net_prefix6"]), "exempt": [str(n) for n in exempt_nets(c)]}}


# ============================================================================================== олперация fraud
def _trust(lab):
    out = {}
    for k, v in _sdb(lab).settings_of("_fraud:trust").items():
        try:
            out[k] = float(v)
        except ValueError:
            pass
    return out


def world_cfg(lab, args=None):
    """мир (fraud.lua) раз в 5 с: настройки скоринга, доверие, снятия; + сводка очков мира для панели"""
    args = args or {}
    if args.get("world"):
        st = _S(lab)
        with st["lock"]:
            st["worlds"][str(args["world"])] = {"t": time.time(), "scores": args.get("scores") or [],
                                                "stats": args.get("stats") or {}}
    cl = {}
    for k, v in _sdb(lab).settings_of("_fraud:cleared").items():
        try:
            cl[k] = float(v)
        except ValueError:
            pass
    c = cfg(lab)
    return {"ok": True, "cfg": {k: v for k, v in c.items() if k not in STR_KEYS}, "trust": _trust(lab), "cleared": cl,
            "exempt": [str(n) for n in exempt_nets(c)]}


def report(lab, args):
    """мир: порог пройден {account, ip, score, level=warn|throttle|kick|ban, reason, events}"""
    c = cfg(lab)
    acct, level = str(args.get("account") or ""), str(args.get("level") or "warn")
    ev = event(lab, "score_" + level, account=acct, ip=args.get("ip"), score=args.get("score"),
               reason=str(args.get("reason") or "")[:200], world=args.get("world"))
    out = {"ok": True, "event": ev["n"]}
    if level != "ban" or not acct:
        return out
    n = _strike(lab, "acct:%s" % acct)
    minutes = min(float(c["ban_base_min"]) * float(c["autoban_factor"]) ** (n - 1), float(c["autoban_max_s"]) / 60)
    r = lab.sup.db.ban("account", acct, minutes, "автобан: %s (страйк %d, %g мин)" % (
        str(args.get("reason") or "очки антифрода")[:150], n, round(minutes, 2)), "fraud")
    lab.sup.db.event(None, None, None, "ban", r)
    audit(lab, {"op": "autoban_account", "account": acct, "minutes": minutes, "strike": n, "by": "fraud",
                "via": "world"})
    event(lab, "autoban_account", account=acct, until=r["until"], strike=n, reason=r["reason"])
    out.update(minutes=minutes, until=r["until"], strike=n, reason=r["reason"])
    if n >= int(c["ip_after_bans"]) and args.get("ip"):
        ib = autoban_ip(lab, str(args["ip"]), "повторные автобаны аккаунта %s (%d)" % (acct, n))
        out["ip_ban"] = ib and {"net": ib["value"], "until": ib["until"]}
    return out


def clear(lab, target, by=None, via="cli"):
    """снять ложное срабатывание: аккаунт (очки, автобаны аккаунта и его IP, страйки, доверие ×step) | ip:<адрес> |
    nick:<ник> (привязка к IP)"""
    c, sdb, db = cfg(lab), _sdb(lab), lab.sup.db
    target = str(target or "").strip()
    out = {"ok": True, "target": target, "lifted": [], "via": via}
    if not target:
        return {"ok": False, "code": "args", "reason": "clear <account|ip:<addr>|nick:<nick>>"}
    st = _S(lab)
    if target.startswith("nick:"):
        n = target[5:]
        with st["lock"]:
            out["binding"] = st["bind"].pop(n, None)
    elif target.startswith("ip:") or norm_ip(target) is not None:
        ip = target[3:] if target.startswith("ip:") else target
        a = norm_ip(ip)
        for net, r in ip_bans(lab):
            if r["by"] == "fraud" and a is not None and a.version == net.version and a in net:
                db.unban("ip", r["value"], by or "operator")
                out["lifted"].append("ip " + r["value"])
        sdb.setting_set("_fraud:strike", "ip:%s" % a, None, by)
        with st["lock"]:
            st["tickets"].pop(str(a), None)
            st["nicks"].pop(str(a), None)
    else:
        acct = target
        for r in db.active_bans()["rows"]:
            if r["kind"] == "account" and r["value"] == acct and r["by"] == "fraud":
                db.unban("account", acct, by or "operator")
                out["lifted"].append("account " + acct)
                break
        ips = {b["ip"] for k, b in st["bind"].items() if k == acct}
        for r in db._rows("SELECT DISTINCT ip FROM logins WHERE account=? AND ts>?", (acct, time.time() - 86400)):
            if r["ip"]:
                ips.add(str(norm_ip(r["ip"]) or r["ip"]))
        for ip in ips:
            a = norm_ip(ip)
            for net, r in ip_bans(lab):
                if r["by"] == "fraud" and a is not None and a.version == net.version and a in net:
                    db.unban("ip", r["value"], by or "operator")
                    out["lifted"].append("ip " + r["value"])
            sdb.setting_set("_fraud:strike", "ip:%s" % a, None, by)
        sdb.setting_set("_fraud:strike", "acct:%s" % acct, None, by)
        tr = _trust(lab).get(acct, 1.0)
        tr2 = min(float(c["trust_max"]), tr * float(c["trust_step"]))
        sdb.setting_set("_fraud:trust", acct, "%g" % tr2, by)
        sdb.setting_set("_fraud:cleared", acct, "%.3f" % time.time(), by)
        out["trust"] = tr2
    audit(lab, {"op": "clear", "target": target, "by": by, "via": via, "lifted": out["lifted"],
                "trust": out.get("trust")})
    event(lab, "clear", target=target, by=by, via=via, lifted=out["lifted"], trust=out.get("trust"))
    out["text"] = "fraud clear %s: lifted %s%s" % (target, ", ".join(out["lifted"]) or "-",
                                                   "; trust x%g" % out["trust"] if "trust" in out else "")
    return out


def cfg_set(lab, key, value, by=None, via="cli"):
    if key not in DEFAULTS:
        return {"ok": False, "code": "args", "reason": "unknown key %r (keys: %s)" % (key, ", ".join(sorted(DEFAULTS)))}
    v = None if value in (None, "", "default", "delete") else str(value)
    if v is not None and key not in STR_KEYS:
        try:
            float(v)
        except ValueError:
            return {"ok": False, "code": "args", "reason": "%s: number expected, got %r" % (key, v)}
    if v is not None and key == "exempt":
        bad = [x for x in re.split(r"[,\s]+", v) if x and norm_net(x) is None]
        if bad:
            return {"ok": False, "code": "args", "reason": "exempt: not networks: %s" % bad}
    _sdb(lab).setting_set("_fraud:cfg", key, v, by)
    audit(lab, {"op": "set", "key": key, "value": v, "by": by, "via": via})
    event(lab, "set", key=key, value=v, by=by, via=via)
    val = cfg(lab)[key]
    return {"ok": True, "key": key, "value": val, "text": "fraud %s = %s%s" % (key, val, " (default)" if v is None else "")}


def status(lab, last=20):
    c = cfg(lab)
    st, now = _S(lab), time.time()
    with st["lock"]:
        ev = list(st["events"])[-int(last):]
        worlds = {k: v for k, v in st["worlds"].items() if now - v["t"] < 30}
        binds = {k: dict(v, age_s=round(now - v["t"], 1)) for k, v in list(st["bind"].items())[-50:]}
    rows = lab.sup.db.active_bans()["rows"]
    strikes = _sdb(lab).settings_of("_fraud:strike")
    over = _sdb(lab).settings_of("_fraud:cfg")
    online = _online(lab)
    scores = []
    for w, v in worlds.items():
        for s in v["scores"]:
            if isinstance(s, dict):
                scores.append(dict(s, world=w))
    scores.sort(key=lambda s: -float(s.get("score") or 0))
    auto = [r for r in rows if r["by"] == "fraud"]
    txt = ["antifraud %s: %d sessions online, %d autobans, %d ip bans, %d strikes" % (
        "on" if int(c["enabled"]) else "OFF", len(online), len(auto), sum(1 for r in rows if r["kind"] == "ip"),
        len(strikes))]
    for s in scores[:10]:
        txt.append("score %s %.1f %s" % (s.get("account"), float(s.get("score") or 0), s.get("level") or ""))
    for r in auto[-10:]:
        txt.append("autoban %s %s until %s: %s" % (r["kind"], r["value"], until_text(r["until"]), r["reason"]))
    for e in ev[-8:]:
        txt.append("event %s %s %s" % (time.strftime("%H:%M:%S", time.localtime(e["ts"])), e["kind"],
                                       e.get("code") or e.get("account") or e.get("ip") or e.get("net") or ""))
    return {"ok": True, "enabled": int(c["enabled"]), "cfg": c, "overrides": over, "defaults": DEFAULTS,
            "scores": scores[:100], "autobans": auto, "ip_bans": [r for r in rows if r["kind"] == "ip"],
            "strikes": strikes, "trust": _trust(lab), "online": [{"account": a, "ip": i, "gateway": g}
                                                                 for a, i, g in online],
            "bindings": binds, "events": ev, "text": "\n".join(txt)}


def f_fraud(ctx, args):
    act = args.get("action") or "status"
    lab, by, via = ctx.lab, args.get("by") or ctx.owner, args.get("via") or "cli"
    if act == "status":
        return status(lab, int(args.get("last", 20)))
    if act == "events":
        st = _S(lab)
        with st["lock"]:
            ev = list(st["events"])[-int(args.get("last", 50)):]
        return {"ok": True, "events": ev, "text": "\n".join(
            "%s %s %s" % (time.strftime("%H:%M:%S", time.localtime(e["ts"])), e["kind"],
                          json.dumps({k: v for k, v in e.items() if k not in ("ts", "kind", "n")}, ensure_ascii=False,
                                     default=str)[:160]) for e in ev)}
    if act == "set":
        return cfg_set(lab, args.get("key"), args.get("value"), by, via)
    if act == "clear":
        return clear(lab, args.get("target"), by, via)
    if act == "trust":
        f = float(args.get("value", 1))
        _sdb(lab).setting_set("_fraud:trust", args["account"], None if f == 1 else "%g" % f, by)
        audit(lab, {"op": "trust", "account": args["account"], "value": f, "by": by, "via": via})
        return {"ok": True, "account": args["account"], "trust": f, "text": "trust %s = x%g" % (args["account"], f)}
    if act == "report":
        return report(lab, args)
    if act == "cfg":
        return world_cfg(lab, args)
    if act == "ipban":
        return ipban(lab, args.get("value"), args.get("minutes", 0), args.get("reason", ""), by, via,
                     force=bool(args.get("force")))
    if act == "unban":
        return ipunban(lab, args.get("value"), by, via)
    if act == "bans":
        return bans_list(lab)
    if act == "reset_test":            # сценарии: снять всё, что оставил тест (адреса/аккаунты из списка)
        return reset_test(lab, args.get("ips") or [], args.get("accounts") or [], args.get("keys") or [])
    raise KeyError("action: status|events|set|clear|trust|report|cfg|ipban|unban|bans|reset_test")


def reset_test(lab, ips, accounts, keys):
    """тесты: баны/страйки/доверие/окна этих адресов и аккаунтов, ключи настроек -> умолчание; аккаунты удаляются"""
    db, sdb, st = lab.sup.db, _sdb(lab), _S(lab)
    out = {"ip_bans": 0, "account_bans": 0, "accounts": 0}
    rows = db.active_bans()["rows"]
    for ip in ips:
        a = norm_ip(ip)
        n = norm_net(ip)
        for r in rows:
            rn = norm_net(r["value"]) if r["kind"] == "ip" else None
            if rn is not None and n is not None and rn.version == n.version and (rn.overlaps(n)):
                if a is not None and rn.prefixlen < 25 and a not in rn:
                    continue
                out["ip_bans"] += db.unban("ip", r["value"], "test-cleanup")["lifted"]
        sdb.setting_set("_fraud:strike", "ip:%s" % (a or ip), None, "test-cleanup")
        with st["lock"]:
            st["tickets"].pop(str(a), None)
            st["nicks"].pop(str(a), None)
    with st["lock"]:
        st["net"].clear()
    for acct in accounts:
        out["account_bans"] += db.unban("account", acct, "test-cleanup")["lifted"]
        for k in ("_fraud:strike",):
            sdb.setting_set(k, "acct:%s" % acct, None, "test-cleanup")
        sdb.setting_set("_fraud:trust", acct, None, "test-cleanup")
        sdb.setting_set("_fraud:cleared", acct, None, "test-cleanup")
        with st["lock"]:
            st["bind"].pop(acct, None)
        with db.lock:
            row = db.db.execute("SELECT token_hash FROM accounts WHERE name=?", (acct,)).fetchone()
            if row is not None and not row["token_hash"]:
                db.db.execute("DELETE FROM accounts WHERE name=?", (acct,))
                out["accounts"] += 1
            db.db.commit()
    for k in keys:
        sdb.setting_set("_fraud:cfg", k, None, "test-cleanup")
    audit(lab, {"op": "reset_test", "ips": ips, "accounts": accounts, "keys": keys, "result": out})
    return dict(out, ok=True)


def f_ip_check(ctx, args):
    r = ip_check(ctx.lab, args.get("ip"), args.get("gateway"))
    return r or {"ok": True}


def f_gw_sync(ctx, args):
    return gw_sync(ctx.lab, args)


def register(api):
    obj = {"type": "object"}
    api.feature("ip_check", lambda ctx, a: P["_fraud"]().f_ip_check(ctx, a),
                "antifraud: IP check of the auth service {ip, gateway?} -> {ok} | {code: ip_banned|rate_ip|rate_net|"
                "sessions_ip, reason, until?}", obj)
    api.feature("gw_sync", lambda ctx, a: P["_fraud"]().f_gw_sync(ctx, a),
                "antifraud: gateway sync every 2 s {gateway, sessions: [[account, ip, name]], events: [{ip, kind, n}]}"
                " -> {accounts, ips: [{net, until, reason}], cfg}", obj)
    api.feature("fraud", lambda ctx, a: P["_fraud"]().f_fraud(ctx, a),
                "antifraud {action=status|events|set|clear|trust|report|cfg|ipban|unban|bans, key, value, target, "
                "account, value(ip|cidr), minutes, reason, force}", obj)


def selftest():
    assert skeleton("Admin") == skeleton("admin") == skeleton("аdmin") == skeleton("adm1n") == "admln"
    assert skeleton("d_e-v") == "dev" and skeleton("wlout11223") != skeleton("wlout12223")
    assert net_str(norm_net("127.0.0.70/26")) == "127.0.0.64/26" and net_str(norm_net("127.0.0.2")) == "127.0.0.2"
    assert str(norm_ip("::ffff:127.0.0.2")) == "127.0.0.2" and str(norm_ip("127.0.0.3:5555")) == "127.0.0.3"
    assert mask_ip("127.0.0.1:5000") == "127.0.x.x"
    assert is_exempt(norm_ip("127.0.0.1"), DEFAULTS) and not is_exempt(norm_ip("127.0.0.2"), DEFAULTS)


# ============================================================================================== шаги сценариев
# Тестовые адреса — только 127.0.0.2..254; 127.0.0.1 и 127.0.0.0/24 целиком не банятся (exempt; ipban без force их
# отвергает). Всё, что шаг создаёт (баны, страйки, доверие, аккаунты по нику, ключи настроек), записывается в
# sx.data["fraud"] и снимается шагом olife_fraud_cleanup (и в finish сценария — sc_finish не трогаем: шаг последний).
def _fd(sx):
    return sx.data.setdefault("fraud", {"checks": [], "ips": [], "accounts": [], "keys": [], "details": {}})


def _ck(sx, name, ok, **detail):
    _fd(sx)["checks"].append({"name": name, "ok": bool(ok), "detail": detail or None})
    return bool(ok)


def _track(sx, ips=(), accounts=(), keys=()):
    d = _fd(sx)
    for k, v in (("ips", ips), ("accounts", accounts), ("keys", keys)):
        for x in v:
            if x not in d[k]:
                d[k].append(x)


def _probe():
    P["_a2"]()._tools()
    import importlib
    return importlib.reload(importlib.import_module("fraud_check"))


def _ctx(sx):
    s = sx.data["session"]
    w = s.get("w4b") or {}
    roles = P["_roles"](sx)
    return {"gw": s["gateway_port"], "auth": w.get("auth_url"), "gw_id": w.get("gw_id"), "auth_lease": w.get("auth_lease"),
            "world": roles["world"], "sid": s["session"][-5:], "gateway": roles.get("gateway")}


def _post(sx, feature, args, owner="cli"):
    import urllib.request
    body = json.dumps({"args": args, "owner": owner}).encode()
    req = urllib.request.Request("http://127.0.0.1:%d/call/%s" % (sx.lab.cfg["daemon"]["port"], feature), data=body,
                                 method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.loads(r.read().decode("utf-8"))
    return d.get("result") if d.get("ok") else {"ok": False, "error": d.get("error") or d.get("message")}


def _wait(fn, timeout, every=0.1):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            last = fn()
        except Exception as exc:          # noqa: BLE001
            last = None
            _ = exc
        if last:
            return last
        time.sleep(every)
    return last


def _mint(sx, c, account, age_s=0):
    r = sx.lab.f2f_quiet(c["auth_lease"], "mint", {"account": account, "gateway": c["gw_id"], "age_s": age_s},
                         timeout=5, owner=sx.owner)
    return (r.get("result") or {}).get("ticket")


def _world_fraud(sx, c):
    sx.lab.stdin(c["world"], "olife.fraud_state", owner=sx.owner, wait=3.0, pattern=r"fraud_state\s")
    p = os.path.join(sx.lab.lease_info(c["world"])["dir"], "export", "fraud_state.json")
    for _ in range(20):
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.1)
    return {}


def _admins(sx, c):
    sx.lab.stdin(c["world"], "olife.admins dev", owner=sx.owner, wait=3.0, pattern=r"admins=")


def _close(*cls):
    for x in cls:
        try:
            if x is not None:
                x.close()
        except Exception:                # noqa: BLE001
            pass


def _result(sx, name, rep, n0):
    d = _fd(sx)
    mine = d["checks"][n0:]
    bad = [x["name"] for x in mine if not x["ok"]]
    d["details"][name] = rep
    return {"ok": not bad, "result": {"checks": len(mine), "ok": len(mine) - len(bad), "failed": bad, **rep},
            "error": ("failed: %s" % bad) if bad else None}


def st_ipban(sx, args, step):
    """п.1: бан по IP — чат админа `/ban ip`, CLI `lab olife ban --ip` (= olife.ban), панель (POST olife.fraud via=panel);
    немедленный kick сессий с адреса, сервис билетов `ip_banned` «бан по IP до …», шлюз — Disconnect 5 ещё до Hello,
    CIDR, отказ бана сети с 127.0.0.1, `/bans`, `/unban ip`, `/players` (админ — IP, игрок — маска), аудит"""
    F = _probe()
    c = _ctx(sx)
    n0 = len(_fd(sx)["checks"])
    rep = {}
    A, B, NET, OUT = "127.0.0.2", "127.0.0.70", "127.0.0.70/26", "127.0.0.130"
    victim = "ipv%s" % c["sid"]
    _track(sx, ips=[A, NET, OUT], accounts=[victim, "ipo%s" % c["sid"]])
    _admins(sx, c)
    d = F.ChatClient(c["gw"], "olife-dev", "dev").background()
    car = F.ChatClient(c["gw"], "olife-carol", "carol").background()
    v = None
    try:
        v, t = F.login(c["gw"], c["auth"], c["gw_id"], victim, A)
        _ck(sx, "victim from %s logs in by nick" % A, v is not None and v.welcome, ticket=t.get("code") or "ok")
        if v:
            v.background()
        r = d.command("/players", timeout=4)
        _ck(sx, "/players (admin) shows the full IP", r and r.get("code") == 0 and A in (r.get("text") or ""), reply=r)
        r2 = car.command("/players", timeout=4)
        _ck(sx, "/players (player) shows a masked IP", r2 and r2.get("code") == 0 and "127.0.x.x" in (r2.get("text") or "")
            and A not in (r2.get("text") or ""), reply=r2)
        t0 = time.time()
        r = d.command("/ban ip %s 5 test-ip-chat" % A, timeout=6)
        _ck(sx, "chat /ban ip -> OpResult 0", r and r.get("code") == 0, reply=r)
        kicked = _wait(lambda: v and v.closed and v.disconnect_code() == 5, 3.0)
        dm = (v.of("Disconnect") or [{}])[-1] if v else {}
        rep["kick_s"] = round(time.time() - t0, 2)
        _ck(sx, "the victim session is kicked at once (Disconnect 5 with the IP reason)", kicked and "IP" in str(dm.get("reason")),
            disconnect=dm, s=rep["kick_s"])
        rows = [b for b in _post(sx, "olife.fraud", {"action": "bans"})["bans"] if b["kind"] == "ip" and b["value"] == A]
        _ck(sx, "DB: bans row kind ip value %s (until ~ +5 min)" % A, rows and rows[-1]["until"] and
            abs(rows[-1]["until"] - (t0 + 300)) < 20, rows=rows)
        tk = F.ticket(c["auth"], c["gw_id"], name=victim, src=A)
        _ck(sx, "ticket from the banned IP -> ip_banned «бан по IP … до …»", tk.get("code") == "ip_banned" and
            "бан по IP" in (tk.get("reason") or "") and " до " in (tk.get("reason") or "") and tk.get("until"), reply=tk)
        tk2 = F.ticket(c["auth"], c["gw_id"], token="olife-carol", src=A)
        _ck(sx, "token login from the banned IP -> ip_banned too (olife.ip_check)", tk2.get("code") == "ip_banned", reply=tk2)
        ph = F.pre_hello(c["gw"], A)
        _ck(sx, "gateway: TCP from the banned IP -> Disconnect 5 before Hello", ph.get("code") == 5 and
            "IP" in (ph.get("reason") or ""), verdict=ph)
        # CLI = olife.ban {ip} (lab olife ban --ip), CIDR
        r = _post(sx, "olife.ban", {"ip": NET, "minutes": 5, "reason": "test-cidr-cli"})
        _ck(sx, "CLI ban --ip %s -> canonical 127.0.0.64/26" % NET, r.get("ok") and r.get("value") == "127.0.0.64/26", reply=r)
        tk = F.ticket(c["auth"], c["gw_id"], name="ipo%s" % c["sid"], src="127.0.0.100")
        _ck(sx, "CIDR: ticket from 127.0.0.100 (in /26) -> ip_banned", tk.get("code") == "ip_banned", reply=tk)
        tk = F.ticket(c["auth"], c["gw_id"], name="ipo%s" % c["sid"], src=OUT)
        _ck(sx, "CIDR: ticket from %s (outside) -> ticket" % OUT, tk.get("ok"), reply={k: tk.get(k) for k in ("ok", "code")})
        ph = _wait(lambda: (lambda x: x if x.get("code") == 5 else None)(F.pre_hello(c["gw"], "127.0.0.100", 1.0)), 4.0)
        _ck(sx, "CIDR: gateway refuses 127.0.0.100 before Hello (sync <= 2 s)", ph and ph.get("code") == 5, verdict=ph)
        r = _post(sx, "olife.ban", {"ip": "127.0.0.0/24", "minutes": 1, "reason": "must be refused"})
        _ck(sx, "ban of 127.0.0.0/24 (covers the exempt 127.0.0.1) is refused without force", r.get("ok") is False and
            r.get("code") == "exempt", reply=r)
        r = d.command("/bans", timeout=6)
        _ck(sx, "chat /bans lists both IP bans", r and r.get("code") == 0 and A in (r.get("text") or "") and
            "127.0.0.64/26" in (r.get("text") or ""), reply=(r or {}).get("text"))
        r = _post(sx, "olife.fraud", {"action": "unban", "value": NET, "via": "panel", "by": "panel"}, owner="panel")
        _ck(sx, "panel: unban CIDR (POST olife.fraud via=panel)", r.get("ok") and r.get("lifted") == 1, reply=r)
        r = car.command("/ban ip 127.0.0.9 1 x", timeout=4)
        _ck(sx, "player /ban ip -> 16", r and r.get("code") == 16, reply=r)
        r = d.command("/unban ip %s" % A, timeout=6)
        _ck(sx, "chat /unban ip -> 0", r and r.get("code") == 0, reply=r)
        time.sleep(2.5)
        v2, t2 = F.login(c["gw"], c["auth"], c["gw_id"], victim, A)
        _ck(sx, "after /unban ip: ticket + Welcome from %s" % A, v2 is not None and v2.welcome, ticket=t2.get("code") or "ok")
        _close(v2)
        try:
            with open(os.path.join(sx.lab.data, "olife", "fraud_audit.jsonl"), encoding="utf-8") as f:
                aud = [json.loads(x) for x in f if A in x or "127.0.0.64/26" in x][-10:]
        except OSError:
            aud = []
        vias = sorted({str(a.get("via")) for a in aud})
        _ck(sx, "audit fraud_audit.jsonl: ipban/unban via chat, cli, panel", {"chat", "cli", "panel"} <= set(vias), vias=vias)
        ops = P["_a2"]().ops_state(sx)
        wa = [a for a in ops.get("audit") or [] if a.get("cmd") in ("ban", "unban")]
        _ck(sx, "world audit has /ban ip and /unban ip", len(wa) >= 2, n=len(wa))
    finally:
        _close(v, d, car)
    return _result(sx, "ipban", rep, n0)


def st_menu_ipban(sx, args, step):
    """экран статуса меню-клиента (F2F 0.32): бан по IP -> «[banned ip_banned] бан по IP … до …»; снят -> «Повторить»
    -> игра; бан в игре -> Disconnect 5 с причиной на экране. Клиент ходит к сервису билетов и шлюзу через TCP-проброс
    с исходящим адресом 127.0.0.77 (127.0.0.1 не баним никогда)"""
    F = _probe()
    M = P["_menu"]()
    c = _ctx(sx)
    n0 = len(_fd(sx)["checks"])
    SRC = "127.0.0.77"
    nick = "ipm%s" % c["sid"]
    _track(sx, ips=[SRC], accounts=[nick])
    md = M._md(sx)
    auth_port = int(c["auth"].rsplit(":", 1)[1].split("/")[0])
    fa, fg = F.Forward(auth_port, SRC), F.Forward(c["gw"], SRC)
    rep = {"forward": {"auth": fa.port, "gw": fg.port}}
    try:
        text = M.write_config(sx, "dev", "olife-dev")
        text = text.replace("gateway=127.0.0.1:%d" % c["gw"], "gateway=127.0.0.1:%d" % fg.port)
        text = text.replace("auth=%s" % c["auth"], "auth=https://127.0.0.1:%d" % fa.port)
        auto = os.path.join(md["lease_dir"], "export", "olife_server.txt")      # the menu re-reads it on «Войти»
        with open(auto, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        r = _post(sx, "olife.ban", {"ip": SRC, "minutes": 3, "reason": "test-menu"})
        _ck(sx, "CLI ban --ip %s" % SRC, r.get("ok"), reply={k: r.get(k) for k in ("ok", "value", "until")})
        r1 = M._login(sx, {"addr": "127.0.0.1:%d" % fg.port, "nick": nick, "then": "stay",
                           "expect": {"kind": "banned", "code": "ip_banned", "phase": "ticket", "text": "бан по ip"}},
                      "fraud_ip_banned")
        _ck(sx, "menu: status screen [banned ip_banned] «бан по IP … до …»", r1.get("ok"), error=r1.get("error"),
            line=(r1.get("result") or {}).get("page_error_line"))
        r = _post(sx, "olife.unban", {"ip": SRC})
        time.sleep(2.5)
        r2 = M._login(sx, {"button": "retry", "expect": "play", "then": "stay", "after_shots": False}, "fraud_ip_unbanned")
        _ck(sx, "menu: unban -> Повторить -> play", r2.get("ok"), error=r2.get("error"))
        if r2.get("ok"):
            t0 = time.time()
            r = _post(sx, "olife.ban", {"ip": SRC, "minutes": 3, "reason": "test-ingame"})
            st = _wait(lambda: (lambda x: x if ("banned by IP" in x or "бан по IP" in x) else None)(
                json.dumps(M.mstate(sx), ensure_ascii=False)), 6.0)
            st = json.loads(st) if st else None
            s = (st or {}).get("status") or {}
            rep["ingame"] = {"s": round(time.time() - t0, 2), "error": s.get("error"), "client": (st or {}).get("client")}
            rep["ingame_shot"] = M._shot(sx, "fraud_ip_ingame")
            _ck(sx, "in game: IP ban -> Disconnect 5 «бан по IP … до …» on the status screen", st is not None,
                error=s.get("error"), s=rep["ingame"]["s"])
            _post(sx, "olife.unban", {"ip": SRC})
            try:
                M._click(sx, "st_back")
            except Exception:            # noqa: BLE001
                pass
            if not M._w().wait_for(lambda: M._try(lambda: M.mstate(sx)).get("page") == "menu", 6):
                try:
                    M.leave(sx)
                except Exception:        # noqa: BLE001
                    pass
    finally:
        _post(sx, "olife.unban", {"ip": SRC})
        fa.close()
        fg.close()
        try:                             # the autofill back to the session (other steps)
            with open(os.path.join(md["lease_dir"], "export", "olife_server.txt"), "w", encoding="utf-8",
                      newline="\n") as f:
                f.write(M.write_config(sx, "dev", "olife-dev"))
        except OSError:
            pass
    return _result(sx, "menu_ipban", rep, n0)


def st_nick(sx, args, step):
    """защита ника: зарезервированные, похожие (регистр, кириллица, цифры), имя Hello только ASCII; ник в игре с
    другого IP -> nick_in_use (билет) и Disconnect 18 (шлюз, билет выпущен в обход); тот же IP -> вход заменяет старую
    сессию (12); после выхода — grace (nick_in_use) -> `fraud clear nick:` -> вход"""
    F = _probe()
    c = _ctx(sx)
    n0 = len(_fd(sx)["checks"])
    rep = {}
    A, B = "127.0.0.11", "127.0.0.12"
    nick = "nk%s" % c["sid"]
    _track(sx, ips=[A, B], accounts=[nick])
    for n, want in (("admin", "nick_reserved"), ("Server", "nick_reserved"), ("аdmin", "nick_reserved"),
                    ("Dev", "nick_similar"), ("c4rol", "nick_similar"), ("саrol", "nick_similar"), ("d.e.v", "nick_similar")):
        tk = F.ticket(c["auth"], c["gw_id"], name=n, src=A)
        _ck(sx, "nick %r -> %s" % (n, want), tk.get("code") == want, reply={k: tk.get(k) for k in ("code", "reason")})
    x = F.connect(c["gw"], "olife-carol", "аdmin", A)
    _ck(sx, "Hello name with a Cyrillic letter -> 4 bad name", x.disconnect_code() == 4,
        closed=x.closed)
    _close(x)
    a, t = F.login(c["gw"], c["auth"], c["gw_id"], nick, A)
    _ck(sx, "A (%s) logs in as %s" % (A, nick), a is not None and a.welcome, ticket=t.get("code") or "ok")
    b = a2 = None
    try:
        if a:
            a.background()
        time.sleep(2.5)                  # the gateway reports the session (gw_sync)
        tk = F.ticket(c["auth"], c["gw_id"], name=nick, src=B)
        _ck(sx, "B (%s): ticket for the nick in play -> nick_in_use" % B, tk.get("code") == "nick_in_use",
            reply={k: tk.get(k) for k in ("code", "reason")})
        mt = _mint(sx, c, nick)
        b = F.connect(c["gw"], mt, nick, B)
        _ck(sx, "B with a ticket minted past the service -> Disconnect 18 nick_in_use", b.disconnect_code() == 18,
            closed=b.closed)
        _ck(sx, "A survives B's attempts", a is not None and not a.closed, closed=a and a.closed)
        a2, t2 = F.login(c["gw"], c["auth"], c["gw_id"], nick, A)
        ok12 = _wait(lambda: a and a.disconnect_code() == 12, 3.0)
        _ck(sx, "same IP re-login replaces the old session (12) and plays", a2 is not None and a2.welcome and ok12,
            old=a and a.closed)
        _close(a2)
        a2 = None
        time.sleep(2.5)
        tk = F.ticket(c["auth"], c["gw_id"], name=nick, src=B)
        _ck(sx, "after A left: B within the grace -> nick_in_use", tk.get("code") == "nick_in_use",
            reply={k: tk.get(k) for k in ("code", "reason")})
        r = _post(sx, "olife.fraud", {"action": "clear", "target": "nick:" + nick, "via": "cli"})
        b2, t3 = F.login(c["gw"], c["auth"], c["gw_id"], nick, B)
        _ck(sx, "fraud clear nick: -> B logs in", b2 is not None and b2.welcome, clear=r.get("text"),
            ticket=t3.get("code") or "ok")
        _close(b2)
    finally:
        _close(a, b, a2)
    return _result(sx, "nick", rep, n0)


def _until_s(sx, ip):
    rows = [r for r in _post(sx, "olife.fraud", {"action": "bans"})["bans"] if r["kind"] == "ip" and r["value"] == ip]
    if not rows:
        return None
    r = rows[-1]
    created = [x for x in sx.lab.sup.db._rows("SELECT created FROM bans WHERE id=?", (r["id"],))]
    return round(r["until"] - created[0]["created"]) if r["until"] and created else None


def st_limits(sx, args, step):
    """лимиты входа: билеты на IP (rate_ip) -> автобан 60 с, повтор -> 120 с (страйк 2); мультиаккаунт (multi_account);
    подсеть /24 (rate_net); сессии с IP (sessions_ip у сервиса, 13 у шлюза); соединения с /24 у шлюза -> события ->
    автобан. Пороги на время теста уменьшены (`fraud set`), потом — по умолчанию"""
    F = _probe()
    c = _ctx(sx)
    n0 = len(_fd(sx)["checks"])
    rep = {}
    R, MA, SI, CN = "127.0.0.21", "127.0.0.31", "127.0.0.51", "127.0.0.61"
    nets = ["127.0.0.%d" % i for i in range(41, 50)]
    sid = c["sid"]
    keys = ["ticket_rate_ip", "ticket_rate_net", "conn_rate_net", "gw_limit_events"]
    accts = ["ma%d%s" % (i, sid) for i in range(1, 6)] + ["si%d%s" % (i, sid) for i in range(1, 5)] + \
        ["nt%d%s" % (i, sid) for i in range(9)]
    _track(sx, ips=[R, MA, SI, CN] + nets, accounts=accts, keys=keys)
    F_ = P["_fraud"]()
    _post(sx, "olife.fraud", {"action": "reset_test", "ips": [R, MA, SI, CN] + nets})
    # 1. ticket rate per IP + exponential autoban
    _post(sx, "olife.fraud", {"action": "set", "key": "ticket_rate_ip", "value": 5})
    codes = [F.ticket(c["auth"], c["gw_id"], token="olife-carol", src=R).get("code") or "ok" for _ in range(6)]
    _ck(sx, "6 tickets/min from %s with rate 5 -> 5 ok, 6th rate_ip" % R, codes[:5] == ["ok"] * 5 and codes[5] == "rate_ip",
        codes=codes)
    d1 = _until_s(sx, R)
    _ck(sx, "autoban 1 of %s ~60 s (by fraud)" % R, d1 is not None and 55 <= d1 <= 65, seconds=d1)
    tk = F.ticket(c["auth"], c["gw_id"], token="olife-carol", src=R)
    _ck(sx, "next ticket -> ip_banned «автобан»", tk.get("code") == "ip_banned" and "автобан" in (tk.get("reason") or ""),
        reply=tk.get("reason"))
    _post(sx, "olife.unban", {"ip": R})                      # operator unban keeps the strike
    with F_._S(sx.lab)["lock"]:
        F_._S(sx.lab)["tickets"].pop(R, None)
    codes = [F.ticket(c["auth"], c["gw_id"], token="olife-carol", src=R).get("code") or "ok" for _ in range(6)]
    d2 = _until_s(sx, R)
    _ck(sx, "second time: autoban 2 ~120 s (x2 per strike)", codes[5] == "rate_ip" and d2 is not None and 115 <= d2 <= 125,
        seconds=d2, codes=codes)
    rep["autoban_s"] = [d1, d2]
    _post(sx, "olife.fraud", {"action": "set", "key": "ticket_rate_ip", "value": "default"})
    # 2. multi-account (nick cycling)
    codes = [F.ticket(c["auth"], c["gw_id"], name=n, src=MA).get("code") or "ok" for n in accts[:5]]
    _ck(sx, "5 nicks from %s (limit 4) -> 4 ok, 5th multi_account" % MA, codes[:4] == ["ok"] * 4 and
        codes[4] == "multi_account", codes=codes)
    _ck(sx, "multi_account -> autoban of %s" % MA, _until_s(sx, MA) is not None, seconds=_until_s(sx, MA))
    tk = F.ticket(c["auth"], c["gw_id"], name=accts[0], src=MA)
    _ck(sx, "even a known nick from the autobanned IP -> ip_banned", tk.get("code") == "ip_banned", reply=tk.get("code"))
    # 3. subnet rate (/24), every request from another address
    _post(sx, "olife.fraud", {"action": "reset_test", "ips": [R]})
    _post(sx, "olife.fraud", {"action": "set", "key": "ticket_rate_net", "value": 8})
    codes = [F.ticket(c["auth"], c["gw_id"], name=accts[9 + i], src=ip).get("code") or "ok" for i, ip in enumerate(nets)]
    _ck(sx, "9 addresses of 127.0.0.0/24, net rate 8 -> 9th rate_net", codes[:8] == ["ok"] * 8 and codes[8] == "rate_net",
        codes=codes)
    _post(sx, "olife.fraud", {"action": "set", "key": "ticket_rate_net", "value": "default"})
    _post(sx, "olife.fraud", {"action": "reset_test", "ips": nets})
    # 4. sessions per IP
    cl = []
    try:
        for n in accts[5:8]:
            x, t = F.login(c["gw"], c["auth"], c["gw_id"], n, SI)
            cl.append(x)
            if x:
                x.background()
        _ck(sx, "3 sessions from %s" % SI, all(x is not None and x.welcome for x in cl), n=len(cl))
        time.sleep(2.5)
        tk = F.ticket(c["auth"], c["gw_id"], name=accts[8], src=SI)
        _ck(sx, "4th ticket from %s -> sessions_ip" % SI, tk.get("code") == "sessions_ip", reply=tk.get("reason"))
        x = F.connect(c["gw"], _mint(sx, c, accts[8]), accts[8], SI)
        _ck(sx, "4th session (ticket past the service) -> gateway 13 too many sessions", x.disconnect_code() == 13,
            closed=x.closed)
        _close(x)
    finally:
        _close(*cl)
    # 5. gateway: connections per subnet -> events -> autoban
    _post(sx, "olife.fraud", {"action": "set", "key": "conn_rate_net", "value": 2})
    time.sleep(2.5)                      # cfg reaches the gateway with the next sync
    verdicts = []
    for _ in range(14):
        verdicts.append(F.pre_hello(c["gw"], CN, 0.05).get("code"))
    _ck(sx, "gateway: 14 connections from %s at net rate 2/s (burst 6) -> refusals 13" % CN, verdicts.count(13) >= 5,
        verdicts=verdicts)
    ban = _wait(lambda: _until_s(sx, CN), 6.0, 0.5)
    _ck(sx, "gateway limit events (gw_sync) -> autoban of %s" % CN, ban is not None, seconds=ban)
    _post(sx, "olife.fraud", {"action": "set", "key": "conn_rate_net", "value": "default"})
    time.sleep(2.5)                      # the default rate back on the gateway before the next steps
    st = _post(sx, "olife.fraud", {"action": "status", "last": 60})
    kinds = sorted({e["kind"] for e in st.get("events") or []})
    rep["events"] = kinds
    _ck(sx, "fraud status: autobans by fraud, events autoban_ip/refused/gw_conn_rate_net",
        {"autoban_ip", "refused", "gw_conn_rate_net"} <= set(kinds) and len(st.get("autobans") or []) >= 2, kinds=kinds,
        autobans=[(b["kind"], b["value"]) for b in st.get("autobans") or []])
    return _result(sx, "limits", rep, n0)


def _spam(cl, n, rate=15.0, prefix="spam"):
    for i in range(n):
        if cl.closed:
            break
        try:
            cl.say("%s %d" % (prefix, i))
        except OSError:
            break
        time.sleep(1.0 / rate)
    time.sleep(0.4)


def _notices(cl, ev):
    return [m for m in cl.of("Notice") if m["event"] == ev]


def st_score(sx, args, step):
    """скоринг в мире: флуд чата -> Notice 13 (предупреждение) -> Notice 14 (throttle) -> kick 10 «antifraud» ->
    после входа снова -> бан 5 (мир + БД supervisor, by fraud); `/unban` опа и 2-й автобан -> срок ×2 и бан IP;
    `/fraud` (админ — очки, игрок — 16), `lab olife fraud status`; `fraud clear` -> всё снято, доверие ×2 -> тот же
    флуд даёт только предупреждение. Переподключения в цикле и блоки сверх ведра — события в очках"""
    F = _probe()
    c = _ctx(sx)
    n0 = len(_fd(sx)["checks"])
    rep = {}
    IP, RC = "127.0.0.71", "127.0.0.81"
    nick, rcn = "spm%s" % c["sid"], "rcn%s" % c["sid"]
    _track(sx, ips=[IP, RC], accounts=[nick, rcn])
    _post(sx, "olife.fraud", {"action": "reset_test", "ips": [IP, RC], "accounts": [nick, rcn]})
    _admins(sx, c)
    d = F.ChatClient(c["gw"], "olife-dev", "dev").background()
    car = F.ChatClient(c["gw"], "olife-carol", "carol").background()
    s = None
    try:
        s, t = F.login(c["gw"], c["auth"], c["gw_id"], nick, IP)
        _ck(sx, "%s logs in from %s" % (nick, IP), s is not None and s.welcome, ticket=t.get("code") or "ok")
        s.background()
        _spam(s, 30)
        w, th = _notices(s, 13), _notices(s, 14)
        _ck(sx, "chat flood: Notice 13 warning, then Notice 14 throttle (code 22)", w and th and w[0]["code"] == 22,
            warn=w[:1], throttle=th[:1])
        _spam(s, 30)
        kicked = _wait(lambda: s.disconnect_code() == 10, 3.0)
        dm = (s.of("Disconnect") or [{}])[-1]
        _ck(sx, "flood on while throttled -> kick 10 «antifraud»", kicked and "antifraud" in (dm.get("reason") or ""),
            disconnect=dm)
        r = d.command("/fraud", timeout=6)
        _ck(sx, "/fraud (admin) shows the account with its score", r and r.get("code") == 0 and nick in (r.get("text") or ""),
            reply=(r or {}).get("text", "")[:400])
        r = car.command("/fraud", timeout=4)
        _ck(sx, "/fraud (player) -> 16", r and r.get("code") == 16, reply=r)
        s2, t = F.login(c["gw"], c["auth"], c["gw_id"], nick, IP)
        _ck(sx, "after the kick the account may come back", s2 is not None and s2.welcome, ticket=t.get("code") or "ok")
        if s2:
            s2.background()
            _spam(s2, 40)
            banned = _wait(lambda: s2.disconnect_code() == 5, 4.0)
            _ck(sx, "flood again -> autoban (Disconnect 5)", banned, closed=s2.closed)
            _close(s2)
        time.sleep(1.0)
        bans = [b for b in _post(sx, "olife.fraud", {"action": "bans"})["bans"] if b["kind"] == "account" and
                b["value"] == nick and b["by"] == "fraud"]
        _ck(sx, "supervisor DB: account autoban by fraud (5 min, strike 1)", bans and "страйк 1" in bans[-1]["reason"],
            bans=bans[-1:])
        tk = F.ticket(c["auth"], c["gw_id"], name=nick, src=IP)
        _ck(sx, "ticket for the autobanned account -> banned", tk.get("code") == "banned", reply=tk.get("reason"))
        st = _wait(lambda: (lambda x: x if any(e.get("account") == nick for e in x.get("scores") or []) else None)(
            _post(sx, "olife.fraud", {"action": "status"})), 7.0, 0.5)
        _ck(sx, "lab olife fraud status: world scores (poll 5 s) list the account", st is not None,
            scores=(st or {}).get("scores", [])[:3])
        # operator unban (not clear) -> the second autoban: x2 and the IP
        _post(sx, "olife.unban", {"account": nick})
        r = d.command("/unban %s" % nick, timeout=4)
        time.sleep(2.5)                  # the gateway's account ban list follows gw_sync (2 s)
        s3, t = F.login(c["gw"], c["auth"], c["gw_id"], nick, IP)
        rep["third_login"] = {"ticket": t.get("code") or "ok", "closed": s3 and s3.closed}
        if s3:
            s3.background()
            _spam(s3, 60)
            _wait(lambda: s3.disconnect_code() in (5, 10), 3.0)
            if s3.disconnect_code() == 10:            # kicked first: come back and go on
                time.sleep(0.5)
                s3, t = F.login(c["gw"], c["auth"], c["gw_id"], nick, IP)
                if s3:
                    s3.background()
                    _spam(s3, 40)
            _close(s3)
        time.sleep(1.5)
        bans = [b for b in _post(sx, "olife.fraud", {"action": "bans"})["bans"] if b["by"] == "fraud" and
                b["value"] in (nick, IP)]
        acc2 = [b for b in bans if b["kind"] == "account" and "страйк 2" in (b["reason"] or "")]
        ipb = [b for b in bans if b["kind"] == "ip"]
        _ck(sx, "2nd autoban: account x2 (10 min, strike 2) and the IP %s" % IP, acc2 and ipb,
            bans=[(b["kind"], b["value"], b["reason"]) for b in bans])
        rep["bans"] = [(b["kind"], b["value"], b["reason"]) for b in bans]
        # clear = false positive
        r = _post(sx, "olife.fraud", {"action": "clear", "target": nick, "via": "cli"})
        _ck(sx, "fraud clear: account + IP autobans lifted, trust x2", r.get("ok") and r.get("trust") == 2 and
            any("ip" in x for x in r.get("lifted") or []) and any("account" in x for x in r.get("lifted") or []),
            reply=r.get("text"))
        time.sleep(5.5)                  # the world takes the clear/trust with its 5 s poll
        s4, t = F.login(c["gw"], c["auth"], c["gw_id"], nick, IP)
        ok4 = s4 is not None and s4.welcome
        _ck(sx, "after clear: the account plays again", ok4, ticket=t.get("code") or "ok", closed=s4 and s4.closed)
        if ok4:
            s4.background()
            _spam(s4, 22)
            time.sleep(0.5)
            _ck(sx, "trust x2: the same flood (~17 points) -> no warning (warn 20), not throttled, not kicked",
                not _notices(s4, 13) and not _notices(s4, 14) and not s4.closed,
                notices=[m["event"] for m in s4.of("Notice")])
            _close(s4)
        # reconnect loop + block actions over the bucket
        for i in range(6):
            x, t = F.login(c["gw"], c["auth"], c["gw_id"], rcn, RC)
            if x and x.welcome and i == 5:
                for k in range(40):
                    p = x.pos or (8, 80, 8)
                    x.send("BlockAction", {"seq": k + 1, "action": 0, "pos": {"x": int(p[0]), "y": int(p[1]) - 1,
                                                                             "z": int(p[2])}, "block": 0, "states": 0})
                    time.sleep(0.02)
                x.pump(0.5)
            _close(x)
            time.sleep(0.2)
        fs = _world_fraud(sx, c)
        n = ((fs.get("acct") or {}).get(rcn) or {}).get("n") or {}
        _ck(sx, "world: reconnect loop and blocks over the bucket are scored", (n.get("reconnect") or 0) >= 2 and
            (n.get("action") or 0) >= 1, n=n)
        rep["world_stats"] = fs.get("stats")
    finally:
        _close(s, d, car)
    return _result(sx, "score", rep, n0)


def st_negative(sx, args, step):
    """сопротивление обходу (негативные ветки): повтор билета -> 15; замена IP при живой сессии -> 18 (билет в обход);
    смена ника в цикле -> multi_account + автобан; снятие — `lab olife fraud clear ip:`"""
    F = _probe()
    c = _ctx(sx)
    n0 = len(_fd(sx)["checks"])
    A, B, CY = "127.0.0.91", "127.0.0.92", "127.0.0.93"
    sid = c["sid"]
    nick = "ng%s" % sid
    cyc = ["cy%d%s" % (i, sid) for i in range(1, 7)]
    _track(sx, ips=[A, B, CY], accounts=[nick] + cyc)
    tk = F.ticket(c["auth"], c["gw_id"], name=nick, src=A)
    a = F.connect(c["gw"], tk.get("ticket"), nick, A)
    _ck(sx, "ticket -> Welcome", a.welcome is not None)
    a.background()
    r = F.connect(c["gw"], tk.get("ticket"), nick, A)
    _ck(sx, "replayed ticket -> 15", r.disconnect_code() == 15, closed=r.closed)
    _close(r)
    b = F.connect(c["gw"], _mint(sx, c, nick), nick, B)
    _ck(sx, "IP swap with a live session -> 18", b.disconnect_code() == 18, closed=b.closed)
    _close(a, b)
    codes = [F.ticket(c["auth"], c["gw_id"], name=n, src=CY).get("code") or "ok" for n in cyc]
    _ck(sx, "nick cycling (6 nicks) -> multi_account, then ip_banned", codes[4] == "multi_account" and
        codes[5] == "ip_banned", codes=codes)
    r = _post(sx, "olife.fraud", {"action": "clear", "target": "ip:" + CY, "via": "cli"})
    tk = F.ticket(c["auth"], c["gw_id"], name=cyc[0], src=CY)
    _ck(sx, "fraud clear ip: -> tickets again", tk.get("ok"), clear=r.get("text"))
    return _result(sx, "negative", {}, n0)


def st_cleanup(sx, args, step):
    """снять всё, что оставили шаги: баны адресов/аккаунтов, страйки, доверие, снятия, аккаунты по нику, ключи"""
    d = _fd(sx)
    r = _post(sx, "olife.fraud", {"action": "reset_test", "ips": d["ips"], "accounts": d["accounts"], "keys": d["keys"]})
    left = [b for b in _post(sx, "olife.fraud", {"action": "bans"})["bans"]
            if b["value"] in d["ips"] or b["value"] in d["accounts"] or b["value"] == "127.0.0.64/26"]
    _ck(sx, "cleanup: no test bans left", not left, left=left, reset=r)
    d["cleaned"] = "step"
    return {"ok": not left, "result": r, "error": None if not left else "left: %s" % left}


def st_report(sx, args, step):
    d = _fd(sx)
    checks = d["checks"]
    ok = [x for x in checks if x["ok"]]
    path = os.path.join(sx.out_dir(), "olife_fraud.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"checks": checks, "details": d["details"]}, f, ensure_ascii=False, indent=1, default=str)
    sx.data.setdefault("metrics", {})["fraud"] = {"checks": len(checks), "ok": len(ok)}
    bad = [x["name"] for x in checks if not x["ok"]]
    return {"ok": not bad, "result": {"checks": len(checks), "ok": len(ok), "file": path, "failed": bad},
            "error": ("%d checks failed" % len(bad)) if bad else None}


NAMES = {"olife_fraud_ipban": "st_ipban", "olife_fraud_menu_ipban": "st_menu_ipban", "olife_fraud_nick": "st_nick",
         "olife_fraud_limits": "st_limits", "olife_fraud_score": "st_score", "olife_fraud_negative": "st_negative",
         "olife_fraud_cleanup": "st_cleanup", "olife_fraud_report": "st_report"}
