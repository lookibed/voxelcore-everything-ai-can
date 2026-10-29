"""olife, UX B2 (03.10, агент olife_b2): инструмент «Спамер» — снимки мобов в библиотеке владельца, бросок «покебола»,
новый экземпляр из снимка (OLIFE_UX §3). Подключается из plugin.py (`_b2()`, перезагрузка по mtime этого файла).

Мир: content/olife_world/modules/spammer.lua (+ store.lua snap_*); клиент: content/olife_client/modules/spammer.lua
(+ layouts/spammer.xml, spammer_hud.xml, предмет olife_client:spammer в слоте 2 — клавиша 3). Клиенты — F2F 0.32
(вид client): ввод — F2F `input` (клавиша 3, ЛКМ/ПКМ, [ ], Shift+колесо, клики по кнопкам страницы), чтение — F2F
`spammer {op=state|gui|...}` и `olife {op=state}`; мир — stdin (`spam_list`, `spam_status`, `bench`, `store_kv`,
`bench_perms`, `store_tariff`).
Шаги:
  olife_b2_setup {account, name, code}          — бенч <account> с кодом примера sandbox/samples/<code>.lua, RUN
        (spawn_sample), eid -> data.w4a.benches[name]
  olife_spammer_capture {bench, client}         — слот 3, взгляд на бенч, ЛКМ -> SpamReply op 1 код 0, SpamList с одним
        снимком: status RUN, code_fnv = `bench` мира, размер; HUD-строка «слот 1/1»
  olife_spammer_throw {bench, client, times=2, viewer} — ПКМ times раз: ответ «thrown» (шар, kind 5 виден у viewer),
        затем «spawned #n»: новый бенч того же владельца, имя <снимок>#n, code_fnv/модель/текстура/права = источнику,
        KV скопирован; счётчики памяти у источника и каждого экземпляра растут независимо; время броска -> спавна
  olife_spammer_perms {bench, client (bob)}     — чужой бенч без права clone -> код 3 (тост + refuse); clone=friends и
        дружба -> захват 0, снимок в библиотеке bob
  olife_spammer_limits {client}                 — store_tariff snap_max -> 51, spawn_per_min -> 52, mobs_max -> 53;
        отказы протоколом: нет снимка 50, плохое имя 15; тарифы возвращаются
  olife_spammer_gui {client, client_b}          — Shift+ПКМ -> страница: строки = снимки, «Имя» + поле + «Переименовать»
        -> op 4, список обновлён; второй снимок -> `]` и Shift+колесо меняют слот (хотбар остаётся на Спамере); «x» у
        client_b -> op 5, список пуст
"""
import json
import math
import os
import time

P = {}

NAMES = {"olife_b2_setup": "st_setup", "olife_spammer_capture": "st_capture", "olife_spammer_throw": "st_throw",
         "olife_spammer_perms": "st_perms", "olife_spammer_limits": "st_limits", "olife_spammer_gui": "st_gui"}


def bind(g):
    P.update(g)


def steps():
    return {n: _lazy(n) for n in NAMES}


def _lazy(n):
    def f(sx, args, step):
        return getattr(P["_b2"](), NAMES[n])(sx, args, step)
    return f


def W():
    return P["_w4a"]()


def A1():
    return P["_a1"]()


# ---------------------------------------------------------------------------------------------- общее
def _m(sx):
    return sx.data.setdefault("metrics", {}).setdefault("b2", {})


def _save(sx, name, rep):
    with open(os.path.join(sx.out_dir(), name), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)


def stdin(sx, cmd, pattern, wait=4.0):
    return W()._stdin(sx, cmd, pattern, wait)


def stdin_line(sx, cmd, prefix, wait=4.0):
    import re
    r = stdin(sx, cmd, re.escape(prefix), wait)
    ls = [x for x in r.get("lines") or [] if prefix in x]
    return ls[-1][ls[-1].find(prefix):] if ls else ""


def json_tail(line, key):
    i = line.find(key + "=")
    if i < 0:
        return None
    try:
        return json.JSONDecoder().raw_decode(line[i + len(key) + 1:])[0]
    except ValueError:
        return None


def sp(sx, lease, op="state", **a):
    a["op"] = op
    r = sx.raw("spammer", a, lease=lease)
    if not r.get("ok"):
        raise RuntimeError("spammer %s on %s: %s" % (op, lease, r.get("error")))
    return r["result"]


def kv(sx, eid):
    line = stdin_line(sx, "store_kv %d" % eid, "store_kv eid=%d" % eid)
    return json_tail(line, "kv") or {}


def snap_list(sx, account):
    line = stdin_line(sx, "spam_list %s" % account, "spam_list %s" % account)
    return {"quota": json_tail(line, "quota"), "snaps": json_tail(line, "snaps") or []}


def world_spam_status(sx):
    return stdin_line(sx, "spam_status", "spammer(")


def wait_reply(sx, lease, seq, pred=None, timeout=6.0):
    w = W()

    def f():
        for r in reversed(sp(sx, lease).get("replies") or []):
            if r["seq"] == seq and (pred is None or pred(r)):
                return r
        return None
    return w.wait_for(f, timeout, 0.08)


def select_spammer(sx, lease):
    w = W()
    w.press_key(sx, lease, "3")
    return w.wait_for(lambda: sp(sx, lease).get("held"), 3.0)


def send(sx, lease, name, msg):
    """запрос в обход UI (негативные случаи) -> SpamReply"""
    w = W()
    seq = w.ol(sx, lease, "send", name=name, msg=dict(msg))["seq"]
    return wait_reply(sx, lease, seq), seq


def bench_eids(sx):
    line = stdin_line(sx, "benches", "benches n=")
    out = {}
    for tok in line.split()[2:]:
        parts = tok.split(":")
        if len(parts) >= 4 and parts[0].isdigit():
            out[int(parts[0])] = {"name": parts[1], "owner": parts[2], "status": parts[3]}
    return out


# ---------------------------------------------------------------------------------------------- шаги
def st_setup(sx, args, step):
    """бенч <account> с кодом примера (spawn_sample: RUN), eid в data.w4a.benches[name]; alice -> admin-free"""
    acct, name, code = args.get("account", "alice"), args.get("name", "mc"), args.get("code", "demo_memory_counter")
    before = set(bench_eids(sx))
    r = stdin(sx, "spawn_sample %s %s %s 1" % (acct, name, code), r"spawned_sample\saccount=%s\sname=%s" % (acct, name), wait=6)
    ls = [x for x in r.get("lines") or [] if "spawned_sample account=%s name=%s" % (acct, name) in x]
    if not ls:
        return {"ok": False, "error": "no spawned_sample line: %s" % r.get("lines", [])[-3:]}
    eid = int(ls[-1].split("eids=")[1].split()[0].split(",")[0])
    W()._w(sx)["benches"][name] = [eid]
    # the bench sits on the ring around the spawn; put it in front of the players so the Spammer ray finds it
    info = W().bench_info(sx, eid)
    rep = {"eid": eid, "account": acct, "code": code, "pos": info.get("pos"), "status": info.get("status"), "new": sorted(set(bench_eids(sx)) - before)}
    if args.get("place"):
        p = args["place"]
        stdin(sx, "bench_place %d %.2f %.2f %.2f" % (eid, p[0], p[1], p[2]), r"bench_place")
        rep["placed"] = p
    got = W().wait_for(lambda: (lambda k: k if k.get("count", 0) >= 1 else None)(kv(sx, eid)), 15, 0.5)
    rep["kv"] = got or kv(sx, eid)
    _m(sx)["setup"] = rep
    return {"ok": bool(got) and info.get("status") == "run", "result": rep,
            "error": None if got else "memory counter did not start: %s" % rep["kv"]}


def st_capture(sx, args, step):
    w = W()
    roles = P["_roles"](sx)
    A = roles[args.get("client", "client1")]
    eid = w.eid_arg(sx, args)
    rep, bad = {"eid": eid}, []
    if not w.wait_for(lambda: w.bench_of(w.state(sx, A), eid), 20):
        return {"ok": False, "error": "bench %d not seen by %s" % (eid, A)}
    held = select_spammer(sx, A)
    st0 = sp(sx, A)
    rep["held"] = {"held": bool(held), "slot": st0.get("slot"), "keys_ok": st0.get("keys_ok"), "hud": st0.get("hud")}
    if not held:
        return {"ok": False, "error": "key 3 did not select the Spammer: %s" % rep["held"], "result": rep}
    rep["shot_hud"] = w.shot(sx, A, "b2_spammer_in_hand")
    w.ol(sx, A, "aim", quiet=False, eid=eid)
    w.wait_for(lambda: (w.state(sx, A).get("camera") or {}).get("selected_eid") == eid, 2.0)
    src = w.bench_info(sx, eid)
    n0 = len(st0.get("replies") or [])
    t0 = time.time()
    w.mouse_button(sx, A, 0)
    r = w.wait_for(lambda: next((x for x in (sp(sx, A).get("replies") or [])[n0:] if x["op"] == 1), None), 5.0)
    rep["capture_s"] = round(time.time() - t0, 3)
    rep["reply"] = r
    if not r or r["code"] != 0 or r["eid"] != eid:
        return {"ok": False, "error": "capture reply %s" % r, "result": rep}
    lst = w.wait_for(lambda: (lambda s: s if s.get("list") and s["list"]["count"] >= 1 else None)(sp(sx, A)), 3.0) or sp(sx, A)
    snaps = lst.get("snaps") or []
    mine = [s for s in snaps if s["id"] == r["id"]]
    rep["snapshot"] = mine[0] if mine else None
    rep["list"] = lst.get("list")
    rep["hud"] = lst.get("hud")
    rep["cur"] = lst.get("cur")
    rep["feedback"] = A1().feedback(sx, A)
    if not mine:
        bad.append("snapshot #%s not in the client list %s" % (r["id"], snaps))
    else:
        s = mine[0]
        if s["code_fnv"] != src.get("code_fnv"):
            bad.append("snapshot code_fnv %s != world %s" % (s["code_fnv"], src.get("code_fnv")))
        if s["status"] != (1 if src.get("status") == "run" else 0):
            bad.append("snapshot status %s, bench %s" % (s["status"], src.get("status")))
        if s["src_eid"] != eid or s["name"] != src.get("name"):
            bad.append("snapshot src %s/%s" % (s["src_eid"], s["name"]))
    if lst.get("cur") != r["id"]:
        bad.append("the new snapshot is not the selected slot (%s)" % lst.get("cur"))
    if "слот 1/1" not in (lst.get("hud") or ""):
        bad.append("HUD line: %s" % lst.get("hud"))
    if "grab" not in (rep["feedback"]["sounds"] or []) or "Снимок" not in (rep["feedback"]["toast"] or ""):
        bad.append("capture feedback: %s" % rep["feedback"])
    wl = snap_list(sx, src.get("owner") or "alice")
    rep["world_list"] = wl
    if not any(s["id"] == r["id"] for s in wl["snaps"]):
        bad.append("world library has no #%s: %s" % (r["id"], wl))
    rep["world_status"] = world_spam_status(sx)
    rep["shot_captured"] = w.shot(sx, A, "b2_captured")
    W()._w(sx)["checks"]["snap:%s" % args.get("bench", "alice")] = {"id": r["id"], "src": src, "size": mine and mine[0]["size"]}
    _m(sx)["capture"] = {k: rep.get(k) for k in ("eid", "capture_s", "reply", "snapshot", "list", "hud", "world_status")}
    _save(sx, "olife_spammer_capture.json", rep)
    return {"ok": not bad, "result": _m(sx)["capture"], "error": "; ".join(bad) or None}


def st_throw(sx, args, step):
    w = W()
    roles = P["_roles"](sx)
    A = roles[args.get("client", "client1")]
    B = roles[args.get("viewer", "client2")]
    eid = w.eid_arg(sx, args)
    chk = W()._w(sx)["checks"].get("snap:%s" % args.get("bench", "alice")) or {}
    src = w.bench_info(sx, eid)
    src_rules = A1().perms_line(sx, eid)
    rep, bad = {"eid": eid, "snapshot": chk.get("id"), "throws": []}, []
    select_spammer(sx, A)
    cam = w.state(sx, A).get("camera") or {}
    yaw0 = cam.get("yaw") or 0
    times = int(args.get("times", 2))
    spawned = []
    for i in range(times):
        # look almost level and to the side: the ball arcs ~1 s and lands a few blocks ahead, not on the source bench
        w.ol(sx, A, "look", yaw=yaw0 + 50 + 40 * i, pitch=-3)
        time.sleep(0.2)
        n0 = len(sp(sx, A).get("replies") or [])
        t0 = time.time()
        w.mouse_button(sx, A, 1)
        thrown = w.wait_for(lambda: next((x for x in (sp(sx, A).get("replies") or [])[n0:] if x["op"] == 2), None), 5.0)
        if not thrown or thrown["code"] != 0 or thrown["reason"] != "thrown":
            bad.append("throw %d: %s" % (i + 1, thrown))
            rep["throws"].append({"thrown": thrown})
            continue
        ball = thrown["eid"]
        seen_b = w.wait_for(lambda: (lambda s: any(b["eid"] == ball for b in s.get("balls") or []) or
                                      any(e["eid"] == ball and e["state"] == 1 for e in s.get("events") or []))(sp(sx, B)), 2.0, 0.03)
        landed = wait_reply(sx, A, thrown["seq"], lambda r: str(r.get("reason", "")).startswith("spawned"), 8.0)
        t_land = round(time.time() - t0, 3)
        ev_b = w.wait_for(lambda: next((e for e in sp(sx, B).get("events") or [] if e["eid"] == ball and e["state"] == 2), None), 3.0)
        rec = {"thrown": thrown, "ball_seen_by_b": bool(seen_b), "landed": landed, "land_s": t_land, "b_event": ev_b}
        if not landed:
            bad.append("throw %d: no spawned reply (%s)" % (i + 1, sp(sx, A).get("replies")[-2:]))
            rep["throws"].append(rec)
            continue
        new = landed["eid"]
        spawned.append(new)
        time.sleep(0.3)
        info = w.bench_info(sx, new)
        rules = A1().perms_line(sx, new)
        rec["world"] = {k: info.get(k) for k in ("name", "owner", "status", "code_fnv", "model", "texture", "pos", "label")}
        rec["rules"] = rules
        want_name = "%s#%d" % (src.get("name"), i + 1)
        if info.get("name") != want_name:
            bad.append("throw %d: name %s != %s" % (i + 1, info.get("name"), want_name))
        if info.get("owner") != src.get("owner") or info.get("code_fnv") != src.get("code_fnv") or info.get("status") != src.get("status"):
            bad.append("throw %d: owner/code/status %s vs %s" % (i + 1, rec["world"], {k: src.get(k) for k in ("owner", "code_fnv", "status")}))
        if str(info.get("model")) != str(src.get("model")) or str(info.get("texture")) != str(src.get("texture")):
            bad.append("throw %d: look %s/%s vs %s/%s" % (i + 1, info.get("model"), info.get("texture"), src.get("model"), src.get("texture")))
        if {k: v for k, v in rules.items() if k not in ("eid", "owner")} != {k: v for k, v in src_rules.items() if k not in ("eid", "owner")}:
            bad.append("throw %d: rules %s != %s" % (i + 1, rules, src_rules))
        if not seen_b:
            bad.append("throw %d: B did not see the ball (kind 5)" % (i + 1))
        if not ev_b:
            bad.append("throw %d: B got no landed SpamBall event" % (i + 1))
        d = math.dist(info["pos"], src["pos"]) if info.get("pos") and src.get("pos") else None
        rec["dist_from_source"] = round(d, 2) if d is not None else None
        rep["throws"].append(rec)
        rep["shot_%d" % (i + 1)] = w.shot(sx, A, "b2_spawned_%d" % (i + 1))
        time.sleep(0.4)
    rep["spawned"] = spawned
    # B sees the instances (EntityMeta) with the owner's name
    if spawned:
        okb = w.wait_for(lambda: all(w.bench_of(w.state(sx, B), e) for e in spawned), 6.0)
        rep["b_sees"] = [w.bench_of(w.state(sx, B), e) for e in spawned]
        if not okb:
            bad.append("B does not see all instances: %s" % rep["b_sees"])
    # memory: each instance starts from the captured KV and counts on by itself
    if spawned and args.get("memory", True):
        k0 = {e: kv(sx, e) for e in [eid] + spawned}
        time.sleep(float(args.get("memory_seconds", 3.0)))
        k1 = {e: kv(sx, e) for e in [eid] + spawned}
        rep["memory"] = {"before": k0, "after": k1}
        for e in [eid] + spawned:
            if (k1[e].get("count") or 0) < (k0[e].get("count") or 0) + 2:
                bad.append("eid %d: count did not go on (%s -> %s)" % (e, k0[e].get("count"), k1[e].get("count")))
        for e in spawned:
            if (k1[e].get("runs") or 0) != (k1[eid].get("runs") or 0) + 1:
                bad.append("eid %d: runs %s (the copy starts its script anew, source %s)" % (e, k1[e].get("runs"), k1[eid].get("runs")))
    lst = sp(sx, A)
    rep["list_after"] = lst.get("list")
    cur = next((s for s in lst.get("snaps") or [] if s["id"] == lst.get("cur")), None)
    rep["snapshot_after"] = cur
    if cur and cur.get("spawned") != len(spawned):
        bad.append("spawned counter %s != %d" % (cur.get("spawned"), len(spawned)))
    rep["feedback"] = A1().feedback(sx, A)
    rep["world_status"] = world_spam_status(sx)
    rep["shot_b"] = w.shot(sx, B, "b2_instances_seen_by_b")
    W()._w(sx)["checks"]["spawned"] = spawned
    _m(sx)["throw"] = {k: rep.get(k) for k in ("eid", "snapshot", "throws", "spawned", "memory", "snapshot_after", "world_status")}
    _save(sx, "olife_spammer_throw.json", rep)
    return {"ok": not bad, "result": _m(sx)["throw"], "error": "; ".join(bad[:12]) or None}


def st_perms(sx, args, step):
    """bob (client2) без права clone -> 3; clone=friends + дружба -> 0 (снимок в библиотеке bob)"""
    w = W()
    roles = P["_roles"](sx)
    B = roles[args.get("client", "client2")]
    eid = w.eid_arg(sx, args)
    rep, bad = {"eid": eid}, []
    stdin(sx, "bench_perms %d clone owner" % eid, r"perms eid=%d" % eid)
    select_spammer(sx, B)
    w.ol(sx, B, "aim", quiet=False, eid=eid)
    w.wait_for(lambda: (w.state(sx, B).get("camera") or {}).get("selected_eid") == eid, 2.0)
    n0 = len(sp(sx, B).get("replies") or [])
    w.mouse_button(sx, B, 0)
    r = w.wait_for(lambda: next((x for x in (sp(sx, B).get("replies") or [])[n0:] if x["op"] == 1), None), 5.0)
    rep["denied"] = {"reply": r, "feedback": A1().feedback(sx, B)}
    if not r or r["code"] != 3 or "refuse" not in (rep["denied"]["feedback"]["sounds"] or []):
        bad.append("bob capture without clone: %s" % rep["denied"])
    rep["shot_denied"] = w.shot(sx, B, "b2_capture_denied")
    stdin(sx, "bench_perms %d clone friends" % eid, r"perms eid=%d" % eid)
    stdin(sx, "olife.friend_set alice bob friend", r"friend_set")
    time.sleep(0.3)
    n0 = len(sp(sx, B).get("replies") or [])
    w.mouse_button(sx, B, 0)
    r2 = w.wait_for(lambda: next((x for x in (sp(sx, B).get("replies") or [])[n0:] if x["op"] == 1), None), 5.0)
    rep["allowed"] = {"reply": r2, "feedback": A1().feedback(sx, B)}
    if not r2 or r2["code"] != 0:
        bad.append("bob capture with clone=friends: %s" % r2)
    else:
        lst = w.wait_for(lambda: (lambda s: s if s.get("list") and s["list"]["count"] >= 1 else None)(sp(sx, B)), 3.0) or sp(sx, B)
        snaps = lst.get("snaps") or []
        rep["bob_list"] = {"count": (lst.get("list") or {}).get("count"), "snaps": snaps}
        s = next((x for x in snaps if x["id"] == r2["id"]), None)
        if not s or s["src_owner"] != "alice":
            bad.append("bob's library: %s" % rep["bob_list"])
        wl = snap_list(sx, "bob")
        rep["world_bob"] = wl
        if not any(x["id"] == r2["id"] for x in wl["snaps"]):
            bad.append("world: bob's library has no #%s" % r2["id"])
        W()._w(sx)["checks"]["snap:bob"] = {"id": r2["id"]}
    _m(sx)["perms"] = {k: rep.get(k) for k in ("eid", "denied", "allowed", "bob_list")}
    _save(sx, "olife_spammer_perms.json", rep)
    return {"ok": not bad, "result": _m(sx)["perms"], "error": "; ".join(bad) or None}


def st_limits(sx, args, step):
    """квота снимков (51), лимит спавнов в минуту (52), лимит мобов (53), нет снимка (50), плохое имя (15)"""
    w = W()
    roles = P["_roles"](sx)
    A = roles[args.get("client", "client1")]
    eid = w.eid_arg(sx, args)
    rep, bad = {"eid": eid, "codes": {}}, []
    select_spammer(sx, A)
    w.ol(sx, A, "aim", quiet=False, eid=eid)
    w.wait_for(lambda: (w.state(sx, A).get("camera") or {}).get("selected_eid") == eid, 2.0)
    cur = sp(sx, A).get("cur")

    def lmb_code():
        n0 = len(sp(sx, A).get("replies") or [])
        w.mouse_button(sx, A, 0)
        r = w.wait_for(lambda: next((x for x in (sp(sx, A).get("replies") or [])[n0:] if x["op"] == 1), None), 5.0)
        return r and r["code"], r

    def rmb_code():
        w.ol(sx, A, "look", yaw=150, pitch=-25)
        time.sleep(0.15)
        n0 = len(sp(sx, A).get("replies") or [])
        w.mouse_button(sx, A, 1)
        r = w.wait_for(lambda: next((x for x in (sp(sx, A).get("replies") or [])[n0:] if x["op"] == 2), None), 5.0)
        return r and r["code"], r
    # 51: snap_max = the current count
    q = snap_list(sx, "alice")["quota"] or {}
    stdin(sx, "store_tariff snap_max %d" % max(1, q.get("count", 1)), r"store_tariff snap_max")
    c, r = lmb_code()
    rep["codes"]["snap_quota_51"] = {"code": c, "reply": r, "feedback": A1().feedback(sx, A)}
    stdin(sx, "store_tariff snap_max 32", r"store_tariff snap_max")
    if c != 51:
        bad.append("snap quota -> %s (want 51)" % c)
    # 52: spawn_per_min = 1 (two instances were thrown within the minute)
    stdin(sx, "store_tariff spawn_per_min 1", r"store_tariff spawn_per_min")
    c, r = rmb_code()
    rep["codes"]["spawn_rate_52"] = {"code": c, "reply": r, "feedback": A1().feedback(sx, A)}
    stdin(sx, "store_tariff spawn_per_min 10", r"store_tariff spawn_per_min")
    if c != 52:
        bad.append("spawn rate -> %s (want 52)" % c)
    # 53: mobs_max = the benches alice has now
    mobs = W()._kv(stdin_line(sx, "spam_mobs alice", "spam_mobs alice"))
    stdin(sx, "store_tariff mobs_max %d" % max(1, mobs.get("mobs", 1)), r"store_tariff mobs_max")
    c, r = rmb_code()
    rep["codes"]["mob_limit_53"] = {"code": c, "reply": r, "mobs": mobs}
    stdin(sx, "store_tariff mobs_max 32", r"store_tariff mobs_max")
    if c != 53:
        bad.append("mob limit -> %s (want 53)" % c)
    # protocol refusals (bypassing the UI)
    r50, _ = send(sx, A, "SpamThrow", {"id": 999999, "origin": {"x": 0, "y": 0, "z": 0}, "dir": {"x": 0, "y": -1, "z": 0}, "name": ""})
    rep["codes"]["no_snapshot_50"] = r50
    if not r50 or r50["code"] != 50:
        bad.append("no snapshot -> %s (want 50)" % (r50 and r50["code"]))
    r15, _ = send(sx, A, "SpamSlotOp", {"op": 2, "id": cur or 1, "name": "bad/name"})
    rep["codes"]["bad_name_15"] = r15
    if not r15 or r15["code"] != 15:
        bad.append("bad name -> %s (want 15)" % (r15 and r15["code"]))
    r14, _ = send(sx, A, "SpamCapture", {"target": 0, "origin": {"x": 0, "y": 0, "z": 0}, "dir": {"x": 0, "y": 0, "z": 0}})
    rep["codes"]["bad_dir_14"] = r14
    if not r14 or r14["code"] != 14:
        bad.append("bad dir -> %s (want 14)" % (r14 and r14["code"]))
    rep["world_status"] = world_spam_status(sx)
    _m(sx)["limits"] = {k: {kk: (v.get(kk) if isinstance(v, dict) else v) for kk in ("code",)} if isinstance(v, dict) else v
                        for k, v in rep["codes"].items()}
    _save(sx, "olife_spammer_limits.json", rep)
    return {"ok": not bad, "result": _m(sx)["limits"], "error": "; ".join(bad) or None}


def st_gui(sx, args, step):
    """A: Shift+ПКМ -> страница; «Имя» + поле + «Переименовать»; второй снимок (экземпляр #1) -> `]` и Shift+колесо;
    B: «x» -> удаление снимка bob"""
    w = W()
    roles = P["_roles"](sx)
    A = roles[args.get("client", "client1")]
    B = roles[args.get("client_b", "client2")]
    rep, bad = {}, []
    select_spammer(sx, A)
    w.inp(sx, A, keys={"left-shift": True})
    time.sleep(0.08)
    w.mouse_button(sx, A, 1)
    w.inp(sx, A, keys={"left-shift": False})
    g = w.wait_for(lambda: (lambda x: x if x.get("doc") and x.get("rows") else None)(sp(sx, A, "gui")), 4.0)
    rep["page_open"] = bool(g)
    if not g:
        return {"ok": False, "error": "Shift+RMB did not open the library page: %s" % sp(sx, A, "gui"), "result": rep}
    rep["page"] = {"quota": g.get("quota"), "sel": g.get("sel"), "rows": [{k: r.get(k) for k in ("id", "name", "text", "info")} for r in g["rows"]]}
    rep["shot_page"] = w.shot(sx, A, "b2_library_page")
    # rename the first row through the UI
    row = g["rows"][0]
    w.click(sx, A, row["rename"])
    time.sleep(0.15)
    w.click(sx, A, g["rects"]["sp_name"])
    for _ in range(40):                       # clear the field (backspace), then type
        w.inp(sx, A, keys={"backspace": True})
        w.inp(sx, A, keys={"backspace": False})
    new_name = args.get("name", "counter_v2")
    w.inp(sx, A, chars=new_name)
    time.sleep(0.15)
    n0 = len(sp(sx, A).get("replies") or [])
    w.click(sx, A, g["rects"]["sp_rename_ok"])
    r = w.wait_for(lambda: next((x for x in (sp(sx, A).get("replies") or [])[n0:] if x["op"] == 4), None), 4.0)
    rep["rename"] = {"reply": r, "feedback": A1().feedback(sx, A)}
    renamed = w.wait_for(lambda: any(s["id"] == row["id"] and s["name"] == new_name for s in sp(sx, A).get("snaps") or []), 3.0)
    rep["rename"]["list_updated"] = bool(renamed)
    wl = snap_list(sx, "alice")
    rep["rename"]["world"] = next((s for s in wl["snaps"] if s["id"] == row["id"]), None)
    if not r or r["code"] != 0 or not renamed or (rep["rename"]["world"] or {}).get("name") != new_name:
        bad.append("rename: %s" % rep["rename"])
    g2 = sp(sx, A, "gui")
    rep["page_after_rename"] = [r_.get("text") for r_ in g2.get("rows") or []]
    rep["shot_renamed"] = w.shot(sx, A, "b2_library_renamed")
    w.click(sx, A, g2["rects"]["sp_close"])
    w.wait_for(lambda: not sp(sx, A, "gui").get("doc"), 3.0)
    # a second snapshot: alice captures her own instance #1 -> 2 slots; `]` and Shift+wheel move the slot
    inst = (W()._w(sx)["checks"].get("spawned") or [None])[0]
    if inst:
        w.ol(sx, A, "aim", quiet=False, eid=inst)
        w.wait_for(lambda: (w.state(sx, A).get("camera") or {}).get("selected_eid") == inst, 2.0)
        n0 = len(sp(sx, A).get("replies") or [])
        w.mouse_button(sx, A, 0)
        r2 = w.wait_for(lambda: next((x for x in (sp(sx, A).get("replies") or [])[n0:] if x["op"] == 1), None), 5.0)
        rep["second_capture"] = r2
        if not r2 or r2["code"] != 0:
            bad.append("second capture: %s" % r2)
        st = w.wait_for(lambda: (lambda s: s if len(s.get("snaps") or []) >= 2 else None)(sp(sx, A)), 3.0) or sp(sx, A)
        cur0 = st.get("cur")
        w.press_key(sx, A, "right-bracket")
        st1 = w.wait_for(lambda: (lambda s: s if s.get("cur") != cur0 else None)(sp(sx, A)), 2.0)
        rep["bracket"] = {"cur0": cur0, "cur1": st1 and st1.get("cur"), "key_cycles": (st1 or sp(sx, A))["stats"].get("key_cycles"),
                          "hud": (st1 or sp(sx, A)).get("hud")}
        if not st1:
            bad.append("] did not change the slot: %s" % rep["bracket"])
        cur1 = (st1 or sp(sx, A)).get("cur")
        w.inp(sx, A, keys={"left-shift": True})
        time.sleep(0.06)
        w.inp(sx, A, mouse={"wheel": -1})
        time.sleep(0.25)
        w.inp(sx, A, mouse={"wheel": 0})
        st2 = w.wait_for(lambda: (lambda s: s if s.get("cur") != cur1 else None)(sp(sx, A)), 2.0)
        w.inp(sx, A, keys={"left-shift": False})
        s2 = st2 or sp(sx, A)
        rep["wheel"] = {"cur1": cur1, "cur2": s2.get("cur"), "slot": s2.get("slot"), "held": s2.get("held"),
                        "wheel_cycles": s2["stats"].get("wheel_cycles"), "hud": s2.get("hud")}
        if not st2 or not s2.get("held"):
            bad.append("Shift+wheel: %s" % rep["wheel"])
        rep["shot_slots"] = w.shot(sx, A, "b2_two_slots")
    # B deletes its snapshot from the page («x»)
    select_spammer(sx, B)
    w.inp(sx, B, keys={"left-shift": True})
    time.sleep(0.08)
    w.mouse_button(sx, B, 1)
    w.inp(sx, B, keys={"left-shift": False})
    gb = w.wait_for(lambda: (lambda x: x if x.get("doc") and x.get("rows") else None)(sp(sx, B, "gui")), 4.0)
    rep["b_page"] = bool(gb)
    if gb:
        n0 = len(sp(sx, B).get("replies") or [])
        w.click(sx, B, gb["rows"][0]["delete"])
        rd = w.wait_for(lambda: next((x for x in (sp(sx, B).get("replies") or [])[n0:] if x["op"] == 5), None), 4.0)
        empty = w.wait_for(lambda: len(sp(sx, B).get("snaps") or []) == 0, 3.0)
        rep["delete"] = {"reply": rd, "list_empty": bool(empty), "world": snap_list(sx, "bob"), "feedback": A1().feedback(sx, B)}
        if not rd or rd["code"] != 0 or not empty or rep["delete"]["world"]["snaps"]:
            bad.append("delete: %s" % rep["delete"])
        rep["shot_b_empty"] = w.shot(sx, B, "b2_library_empty")
        gb2 = sp(sx, B, "gui")
        if gb2.get("doc"):
            w.click(sx, B, gb2["rects"]["sp_close"])
    else:
        bad.append("B: library page did not open")
    rep["world_status"] = world_spam_status(sx)
    _m(sx)["gui"] = {k: rep.get(k) for k in ("page_open", "rename", "second_capture", "bracket", "wheel", "delete")}
    _save(sx, "olife_spammer_gui.json", rep)
    return {"ok": not bad, "result": _m(sx)["gui"], "error": "; ".join(bad) or None}
