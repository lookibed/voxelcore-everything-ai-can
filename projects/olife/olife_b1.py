"""olife, UX B1 (03.10, агент olife_b1): Инжектор в руках = режим «мои мобы».

Подключается из plugin.py (`_b1()`, перезагрузка по mtime этого файла), получает его глобалы (_roles, _kv, _w4a, _a2, ...).
Мир: content/olife_world/modules/mobs.lua; клиент: content/olife_client/modules/mobs.lua (+ layouts/mobs.xml, вкладка
«Профиль» редактора). Клиенты — оконные F2F 0.32: действия игрока — F2F `input` (клавиши 1/M/V, клики по
прямоугольникам XML), чтение — Lua-обработчики `mobs {op=gui|state|camera|ui|open}` и `olife {op=gui}` (поле `mob`).
Шаги (сценарий olife_mobs):
  olife_b1_list    {owner=client1, other=client2, empty=client3}  — панель на M с Injector'ом: строки = бенчи аккаунта у
        мира (eid, имя, статус, позиция ≤ 0.5, loaded, метрики), у B — только его, у C — пусто; обновление по watch;
        «Выбрать» → маркер HUD + подсветка; кнопка HUD видна только с Injector'ом
  olife_b1_camera  {mob}            — выбор моба, V → третье лицо (камера в 3..6 бл от моба, смотрит на него, едет за
        ним), V → из глаз (≤ 1 бл), V → своя камера (first-person, у игрока)
  olife_b1_rescue  {mob}            — мир двигает бенч под землю (bench_place), «Спасти» → MobConfirm (не двигается),
        «Подтвердить» → назад на последнюю безопасную позицию (≤ 1 бл), MobRescued, звук; чужой → 3; плохой токен → 23
  olife_b1_destroy {mob, other}     — «Уничтожить» без подтверждения не действует (1.5 с), «Отмена»; с подтверждением —
        сущности нет, слот «последнее состояние» у владельца; чужой → 3
  olife_b1_restore {mob}            — KV + вид до /kill оператора (A2), убитый в списке мёртвых, чужой → 3, «Восстановить»
        + подтверждение → новый eid с тем же code_fnv, моделью, KV, RUN и движется; повтор → 26
  olife_b1_editor  {bench}          — три СОХРАНИТЬ → три версии, вкладка «Профиль» (владелец, права, хэш), «Вернуть» #2 →
        четыре версии, код у мира = fnv(v2), «Открыть» #3 → текст в редакторе; Run кода с ошибкой в строке 2 → ERROR,
        подпись «ошибка в строке 2», каретка на этой строке
"""
import json
import math
import os
import time

P = {}

NAMES = {"olife_b1_list": "st_list", "olife_b1_camera": "st_camera", "olife_b1_rescue": "st_rescue",
         "olife_b1_destroy": "st_destroy", "olife_b1_restore": "st_restore", "olife_b1_editor": "st_editor"}

STATUS = {"stop": 0, "run": 1, "error": 2}


def bind(g):
    P.update(g)


def steps():
    return {n: _lazy(n) for n in NAMES}


def _lazy(n):
    def f(sx, args, step):
        return getattr(P["_b1"](), NAMES[n])(sx, args, step)
    return f


def W():
    return P["_w4a"]()


def A2():
    return P["_a2"]()


# ---------------------------------------------------------------------------------------------- общее
def _b(sx):
    return sx.data.setdefault("b1", {"restored": {}})


def _m(sx):
    return sx.data.setdefault("metrics", {}).setdefault("b1", {})


def _save(sx, name, rep):
    with open(os.path.join(sx.out_dir(), name), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)


def _clients(sx):
    roles = P["_roles"](sx)
    return roles["client1"], roles["client2"], roles["client3"]


def mob_eid(sx, key):
    """ключ бенча (olife_bench) или имя примера (olife_a2_setup) или eid; восстановленный моб — новый eid"""
    if isinstance(key, int):
        return key
    r = _b(sx)["restored"].get(key)
    if r:
        return r
    w4a = (sx.data.get("w4a") or {}).get("benches") or {}
    if key in w4a:
        return w4a[key][0]
    a2 = (sx.data.get("a2") or {}).get("mobs") or {}
    if key in a2:
        return a2[key]["eid"]
    raise KeyError("no mob %r" % key)


def mb(sx, lease, op, **a):
    a["op"] = op
    r = sx.raw("mobs", a, lease=lease)
    if not r.get("ok"):
        raise RuntimeError("mobs %s on %s: %s" % (op, lease, r.get("error")))
    return r["result"]


def fx_log(sx, lease):
    r = sx.raw("fx", {}, lease=lease)
    return (r.get("result") or {}).get("log") or []


def fx_events(sx, lease, since=0):
    return [x["event"] for x in fx_log(sx, lease) if x["n"] > since]


def fx_n(sx, lease):
    r = sx.raw("fx", {}, lease=lease)
    return (r.get("result") or {}).get("n") or 0


def world_benches(sx, account=None):
    r = W()._stdin(sx, "benches", r"benches n=")
    ls = [x for x in r["lines"] if "benches n=" in x]
    out = []
    if not ls:
        return out
    for tok in ls[-1].split("benches n=")[1].split()[1:]:
        p = tok.split(":")
        if len(p) >= 4 and (account is None or p[2] == account):
            out.append({"eid": int(p[0]), "name": p[1], "owner": p[2], "status": p[3]})
    return out


def mob_safe(sx, eid):
    r = W()._stdin(sx, "mob_safe %d" % eid, r"mob_safe eid=%d" % eid)
    ls = [x for x in r["lines"] if "mob_safe eid=%d " % eid in x]
    d = P["_kv"](ls[-1][ls[-1].find("mob_safe eid="):]) if ls else {}
    for k in ("pos", "target"):
        if isinstance(d.get(k), str) and "," in d[k]:
            d[k] = [float(v) for v in d[k].split(",")]
    return d


def mob_dead(sx, account):
    r = W()._stdin(sx, "mob_dead %s" % account, r"mob_dead account=%s" % account)
    ls = [x for x in r["lines"] if "mob_dead account=%s " % account in x]
    out = []
    if ls:
        for tok in ls[-1].split("mob_dead account=%s " % account)[1].split()[1:]:
            p = tok.split(":")
            d = {"eid": int(p[0]), "name": p[1]}
            for kv in p[2:]:
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    d[k] = int(v) if v.isdigit() else v
            out.append(d)
    return out


def mob_versions(sx, eid):
    r = W()._stdin(sx, "mob_versions %d" % eid, r"mob_versions eid=%d" % eid)
    ls = [x for x in r["lines"] if "mob_versions eid=%d " % eid in x]
    out = []
    if ls:
        for tok in ls[-1].split("mob_versions eid=%d " % eid)[1].split()[1:]:
            p = tok.split(":")
            d = {"n": int(p[0])}
            for kv in p[1:]:
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    d[k] = int(v) if v.isdigit() else v
            out.append(d)
    return out


def store_kv(sx, eid):
    r = W()._stdin(sx, "store_kv %d" % eid, r"store_kv eid=%d" % eid)
    ls = [x for x in r["lines"] if "store_kv eid=%d " % eid in x]
    if not ls:
        return {}
    i = ls[-1].find("kv=")
    try:
        return json.loads(ls[-1][i + 3:])
    except ValueError:
        return {}


def req(sx, lease, name, msg, timeout=3.0):
    """запрос из оконного клиента (F2F olife send) -> RequestReply по seq"""
    w = W()
    seq = w.ol(sx, lease, "send", name=name, msg=dict(msg))["seq"]
    r = w.wait_for(lambda: next((x for x in w.state(sx, lease)["replies"] if x["seq"] == seq), None), timeout, 0.05)
    time.sleep(0.11)
    return r, seq


def code_of(r):
    return r["code"] if r else None


def open_panel(sx, lease, timeout=4.0):
    """реальный путь игрока: слот 1 (Injector), клавиша M -> оверлей; запасной — mobs open (пишется в отчёт)"""
    w = W()
    w.press_key(sx, lease, "1")
    time.sleep(0.1)
    w.press_key(sx, lease, "m")
    g = w.wait_for(lambda: (lambda x: x if x.get("doc") and x.get("list_tick") else None)(mb(sx, lease, "gui")), timeout)
    if g:
        return g, "key:m"
    mb(sx, lease, "open")
    g = w.wait_for(lambda: (lambda x: x if x.get("doc") and x.get("list_tick") else None)(mb(sx, lease, "gui")), timeout)
    return g or mb(sx, lease, "gui"), "f2f open"


def close_panel(sx, lease):
    w = W()
    if mb(sx, lease, "gui").get("doc"):
        w.press_key(sx, lease, "m")
        if not w.wait_for(lambda: not mb(sx, lease, "gui").get("doc"), 2.0):
            g = mb(sx, lease, "gui")
            if g.get("doc") and (g.get("rects") or {}).get("mb_close"):
                w.click(sx, lease, g["rects"]["mb_close"])
                w.wait_for(lambda: not mb(sx, lease, "gui").get("doc"), 2.0)


def row_of(g, eid):
    for r in g.get("rows") or []:
        if r["eid"] == eid:
            return r
    return None


def dead_row_of(g, eid):
    for r in g.get("dead") or []:
        if r["eid"] == eid:
            return r
    return None


def wait_confirm(sx, lease, op, eid, timeout=3.0):
    w = W()
    return w.wait_for(lambda: (lambda c: c if c and c.get("op") == op and c.get("eid") == eid else None)(
        mb(sx, lease, "state").get("confirm")), timeout)


def confirm(sx, lease):
    """клик «Подтвердить» в панели (или ui confirm, если панель закрыта)"""
    w = W()
    g = mb(sx, lease, "gui")
    if g.get("doc") and (g.get("rects") or {}).get("mb_ok") and g["rects"]["mb_ok"].get("visible"):
        w.click(sx, lease, g["rects"]["mb_ok"])
        return "click"
    mb(sx, lease, "ui", call="confirm")
    return "ui"


# ---------------------------------------------------------------------------------------------- шаги
def st_list(sx, args, step):
    w = W()
    A, B, C = _clients(sx)
    rep, bad = {}, []
    # все бенчи у мира
    wb = {b["eid"]: b for b in world_benches(sx)}
    acct = {A: "alice", B: "bob", C: "carol"}
    # HUD button: only with the Injector in hand
    w.press_key(sx, A, "2")
    time.sleep(0.3)
    rep["hud_btn_gravity"] = mb(sx, A, "state").get("hud_btn")
    w.press_key(sx, A, "1")
    time.sleep(0.3)
    rep["hud_btn_injector"] = mb(sx, A, "state").get("hud_btn")
    if rep["hud_btn_gravity"] or not rep["hud_btn_injector"]:
        bad.append("HUD button: gravity %s injector %s" % (rep["hud_btn_gravity"], rep["hud_btn_injector"]))
    # M without the Injector: refused with a toast, no panel
    w.press_key(sx, A, "2")
    time.sleep(0.2)
    n0 = fx_n(sx, A)
    w.press_key(sx, A, "m")
    time.sleep(0.5)
    rep["m_without_injector"] = {"open": mb(sx, A, "gui").get("doc"), "fx": fx_events(sx, A, n0)}
    if rep["m_without_injector"]["open"] or "deny" not in rep["m_without_injector"]["fx"]:
        bad.append("M without the Injector: %s" % rep["m_without_injector"])
    for who, lease in (("a", A), ("b", B), ("c", C)):
        g, how = open_panel(sx, lease)
        rows = g.get("rows") or []
        want = {e: b for e, b in wb.items() if b["owner"] == acct[lease]}
        got = {r["eid"]: r for r in rows}
        r = {"how": how, "doc": g.get("doc"), "rows": len(rows), "want": len(want), "count": g.get("count")}
        if not g.get("doc") or how != "key:m":
            bad.append("%s: panel not opened by M (%s)" % (who, how))
        if set(got) != set(want):
            bad.append("%s rows %s != world %s" % (who, sorted(got), sorted(want)))
        mism = []
        for eid, b in want.items():
            rw = got.get(eid)
            if not rw:
                continue
            info = w.bench_info(sx, eid)
            d = math.dist(info["pos"], rw["pos"]) if info.get("pos") else None
            mt = {"eid": eid, "name_ok": rw["name"] == b["name"], "status_ok": rw["status"] == STATUS.get(info.get("status")),
                  "pos_gap": round(d, 3) if d is not None else None, "loaded": rw["loaded"],
                  "credits_row": rw["credits_min"], "credits_world": info.get("credits_min"),
                  "fuel_row": rw["fuel_min"], "fuel_world": info.get("fuel_min"), "code_fnv_ok": rw["code_fnv"] == info.get("code_fnv"),
                  "where": rw.get("where"), "line1": rw.get("line1"), "line2": rw.get("line2")}
            if not (mt["name_ok"] and mt["status_ok"] and mt["code_fnv_ok"] and mt["loaded"] and d is not None and d <= 0.6):
                mism.append(mt)
            if info.get("status") == "run":
                cw, cr = float(info.get("credits_min") or 0), float(rw["credits_min"] or 0)
                if cw <= 0 or cr <= 0 or abs(cw - cr) > max(5.0, 0.35 * cw):
                    mism.append(dict(mt, why="credits"))
            r.setdefault("mobs", []).append(mt)
        if mism:
            bad.append("%s rows differ from the world: %s" % (who, mism[:3]))
        rep[who] = r
        if who == "a":
            # watch refresh: the list tick grows while the panel is open
            t0 = g.get("list_tick")
            t1 = w.wait_for(lambda: (lambda x: x if (x.get("list_tick") or 0) > (t0 or 0) else None)(mb(sx, A, "gui")), 3.0)
            r["watch"] = {"tick0": t0, "tick1": (t1 or {}).get("list_tick")}
            if not t1:
                bad.append("A: no watch refresh of the list")
            # select the first row: marker + highlight
            rw = rows[0] if rows else None
            if rw and rw.get("select"):
                n0 = fx_n(sx, A)
                w.click(sx, A, rw["select"])
                st = w.wait_for(lambda: (lambda x: x if x.get("sel") == rw["eid"] and x.get("marker") else None)(mb(sx, A, "state")), 3.0)
                r["select"] = {"sel": (st or {}).get("sel"), "marker": (st or {}).get("marker"), "mark_id": (st or {}).get("mark_id"),
                               "part_id": (st or {}).get("part_id"), "fx": fx_events(sx, A, n0)}
                if not st or not st.get("mark_id"):
                    bad.append("A select: %s" % r["select"])
                r["shot_panel"] = w.shot(sx, A, "b1_panel_a")
                close_panel(sx, A)
                time.sleep(0.3)
                r["marker_after_close"] = mb(sx, A, "state").get("marker")
                r["shot_marker"] = w.shot(sx, A, "b1_marker_a")
                if not r["marker_after_close"]:
                    bad.append("A: marker gone after closing the panel")
            else:
                bad.append("A: no row to select")
        else:
            r["shot"] = w.shot(sx, lease, "b1_panel_%s" % who)
            close_panel(sx, lease)
    _m(sx)["list"] = {k: rep.get(k) for k in ("a", "b", "c", "hud_btn_injector", "hud_btn_gravity")}
    _save(sx, "olife_b1_list.json", rep)
    return {"ok": not bad, "result": {k: rep[k] for k in ("a", "b", "c") if k in rep}, "error": "; ".join(bad) or None}


def st_camera(sx, args, step):
    w = W()
    A = _clients(sx)[0]
    eid = mob_eid(sx, args.get("mob", "m_orbit"))
    rep, bad = {"eid": eid}, []
    if not w.wait_for(lambda: w.bench_of(w.state(sx, A), eid), 10):
        return {"ok": False, "error": "mob %d not seen by A" % eid}
    sel = mb(sx, A, "state")
    if sel.get("sel") != eid:
        # select through the panel row of this mob
        g, _ = open_panel(sx, A)
        rw = row_of(g, eid)
        if rw and rw.get("select"):
            w.click(sx, A, rw["select"])
        close_panel(sx, A)
    w.wait_for(lambda: mb(sx, A, "state").get("sel") == eid, 2.0)
    rep["selected"] = mb(sx, A, "state").get("sel")
    n0 = fx_n(sx, A)
    w.press_key(sx, A, "v")
    c1 = w.wait_for(lambda: (lambda x: x if x.get("mode") == 1 and x.get("active") else None)(mb(sx, A, "camera")), 3.0)
    rep["third"] = {"camera": c1, "fx": fx_events(sx, A, n0)}
    if not c1:
        bad.append("V did not switch to third person: %s" % mb(sx, A, "camera"))
    else:
        samples = []
        for _ in range(6):
            c = mb(sx, A, "camera")
            if c.get("active") and c.get("mob_pos"):
                cp, mp = c["active"]["pos"], c["mob_pos"]
                d = math.dist(cp, mp)
                v = [mp[i] - cp[i] for i in range(3)]
                l = math.sqrt(sum(x * x for x in v)) or 1
                f = c["active"]["front"]
                dot = sum(v[i] / l * f[i] for i in range(3))
                samples.append({"dist": round(d, 2), "dot": round(dot, 3), "cam": [round(x, 2) for x in cp],
                                "mob": [round(x, 2) for x in mp], "player_cam": c.get("player_cam"), "cam_idx": c.get("cam_idx")})
            time.sleep(0.25)
        rep["third"]["samples"] = samples
        rep["shot_third"] = w.shot(sx, A, "b1_cam_third")
        if not samples or any(not (3.0 <= s["dist"] <= 6.5) or s["dot"] < 0.9 or s["player_cam"] != s["cam_idx"] for s in samples):
            bad.append("third person: %s" % samples[:3])
        mob_moved = math.dist(samples[0]["mob"], samples[-1]["mob"]) if len(samples) > 1 else 0
        cam_moved = math.dist(samples[0]["cam"], samples[-1]["cam"]) if len(samples) > 1 else 0
        rep["third"]["mob_moved"], rep["third"]["cam_moved"] = round(mob_moved, 3), round(cam_moved, 3)
        if mob_moved > 0.3 and cam_moved < 0.2:
            bad.append("third person camera did not follow the mob (mob %.2f, cam %.2f)" % (mob_moved, cam_moved))
    w.press_key(sx, A, "v")
    c2 = w.wait_for(lambda: (lambda x: x if x.get("mode") == 2 and x.get("active") else None)(mb(sx, A, "camera")), 3.0)
    rep["eyes"] = {"camera": c2}
    if not c2:
        bad.append("V did not switch to the eyes mode")
    else:
        time.sleep(0.3)
        c = mb(sx, A, "camera")
        d = math.dist(c["active"]["pos"], c["mob_pos"]) if c.get("mob_pos") else None
        rep["eyes"]["dist"] = round(d, 3) if d is not None else None
        rep["shot_eyes"] = w.shot(sx, A, "b1_cam_eyes")
        if d is None or d > 1.0:
            bad.append("eyes camera %s from the mob" % d)
    w.press_key(sx, A, "v")
    c0 = w.wait_for(lambda: (lambda x: x if x.get("mode") == 0 else None)(mb(sx, A, "camera")), 3.0)
    time.sleep(0.3)
    c = mb(sx, A, "camera")
    rep["back"] = {"camera": c, "dist_player": round(math.dist(c["active"]["pos"], c["player_pos"]), 3)
                   if c.get("active") and c.get("player_pos") else None}
    if not c0 or c.get("player_cam") != c.get("first_idx") or (rep["back"]["dist_player"] or 99) > 2.5:
        bad.append("back to own camera: %s" % rep["back"])
    rep["shot_back"] = w.shot(sx, A, "b1_cam_back")
    _m(sx)["camera"] = {"third": {k: rep["third"].get(k) for k in ("samples", "mob_moved", "cam_moved", "fx")},
                        "eyes_dist": rep["eyes"].get("dist"), "back": rep["back"].get("dist_player")}
    _save(sx, "olife_b1_camera.json", rep)
    return {"ok": not bad, "result": _m(sx)["camera"], "error": "; ".join(bad) or None}


def st_rescue(sx, args, step):
    w = W()
    A, B, C = _clients(sx)
    eid = mob_eid(sx, args.get("mob", "a_stop"))
    rep, bad = {"eid": eid}, []
    home = w.bench_info(sx, eid).get("pos")
    rep["home"] = home
    s0 = w.wait_for(lambda: (lambda d: d if (d.get("n") or 0) >= 1 and d.get("target") else None)(mob_safe(sx, eid)), 4.0)
    rep["safe_before"] = s0
    if not s0:
        return {"ok": False, "error": "no safe position sampled: %s" % mob_safe(sx, eid), "result": rep}
    # the world drops it underground (fell through)
    w._stdin(sx, "bench_place %d %.3f %.3f %.3f" % (eid, home[0], home[1] - float(args.get("depth", 25)), home[2]), r"bench_place")
    time.sleep(0.6)
    s1 = mob_safe(sx, eid)
    rep["safe_under"] = s1
    if s1.get("safe_now") not in ("false", False) or not s1.get("target"):
        bad.append("underground state: %s" % s1)
    # carol (stranger): rescue -> 3
    rc, _ = req(sx, C, "MobAction", {"eid": eid, "op": 1, "token": 0})
    rep["carol"] = rc
    if code_of(rc) != 3:
        bad.append("carol rescue: %s (want 3)" % rc)
    # alice: panel -> «Спасти» -> MobConfirm, nothing moves
    g, how = open_panel(sx, A)
    rw = row_of(g, eid)
    if not rw or not rw.get("rescue"):
        return {"ok": False, "error": "no row/rescue button for %d: %s" % (eid, g.get("rows")), "result": rep}
    rep["row_under"] = {"where": rw.get("where"), "loaded": rw.get("loaded")}
    n0 = fx_n(sx, A)
    w.click(sx, A, rw["rescue"])
    c = wait_confirm(sx, A, 1, eid)
    rep["confirm"] = {"confirm": c, "fx": fx_events(sx, A, n0)}
    if not c or "confirm" not in rep["confirm"]["fx"]:
        bad.append("no MobConfirm for rescue: %s" % rep["confirm"])
    time.sleep(0.8)
    p_wait = w.bench_info(sx, eid).get("pos")
    rep["pos_after_confirm_only"] = p_wait
    if not p_wait or math.dist(p_wait, [home[0], home[1] - float(args.get("depth", 25)), home[2]]) > 0.1:
        bad.append("mob moved before the confirmation: %s" % p_wait)
    rep["shot_confirm"] = w.shot(sx, A, "b1_rescue_confirm")
    # a wrong token -> 23 (the pending confirmation stays)
    rb, _ = req(sx, A, "MobAction", {"eid": eid, "op": 1, "token": (c or {}).get("token", 1) + 1 if c else 777})
    rep["bad_token"] = rb
    if code_of(rb) != 23:
        bad.append("bad token: %s (want 23)" % rb)
    n1 = fx_n(sx, A)
    rep["confirm_how"] = confirm(sx, A)
    ok = w.wait_for(lambda: (lambda st: st if st.get("rescued") else None)(mb(sx, A, "state")), 4.0)
    p2 = w.bench_info(sx, eid).get("pos")
    rep["after"] = {"pos": p2, "rescued": (ok or {}).get("rescued"), "fx": fx_events(sx, A, n1),
                    "replies": [r for r in (ok or mb(sx, A, "state")).get("replies") or [] if r["op"] == 13]}
    tgt = s1.get("target") or s0.get("target")
    if not ok or not p2 or not tgt or math.dist(p2, tgt) > 1.0:
        bad.append("not rescued to %s: %s" % (tgt, rep["after"]))
    if "rescue" not in rep["after"]["fx"]:
        bad.append("no rescue feedback: %s" % rep["after"]["fx"])
    time.sleep(0.4)
    rep["shot_after"] = w.shot(sx, A, "b1_rescue_after")
    rep["marks"] = mb(sx, A, "state").get("rescue_marks")
    close_panel(sx, A)
    _m(sx)["rescue"] = {k: rep.get(k) for k in ("home", "safe_under", "carol", "confirm", "pos_after_confirm_only", "bad_token", "after")}
    _save(sx, "olife_b1_rescue.json", rep)
    return {"ok": not bad, "result": _m(sx)["rescue"], "error": "; ".join(bad) or None}


def st_destroy(sx, args, step):
    w = W()
    A, B, C = _clients(sx)
    eid = mob_eid(sx, args.get("mob", "a_del"))
    other = mob_eid(sx, args.get("other", "a_stop"))
    rep, bad = {"eid": eid}, []
    rc, _ = req(sx, C, "MobAction", {"eid": other, "op": 2, "token": 0})
    rep["carol"] = rc
    if code_of(rc) != 3:
        bad.append("carol destroy: %s (want 3)" % rc)
    g, _ = open_panel(sx, A)
    rw = row_of(g, eid)
    if not rw or not rw.get("destroy"):
        return {"ok": False, "error": "no row/destroy for %d" % eid, "result": rep}
    w.click(sx, A, rw["destroy"])
    c = wait_confirm(sx, A, 2, eid)
    rep["confirm1"] = c
    time.sleep(1.5)
    alive = w.bench_info(sx, eid)
    rep["alive_without_confirm"] = bool(alive.get("eid"))
    if not c or not alive.get("eid"):
        bad.append("destroy without confirmation: confirm %s alive %s" % (bool(c), alive.get("eid")))
    # cancel
    g = mb(sx, A, "gui")
    if (g.get("rects") or {}).get("mb_cancel"):
        w.click(sx, A, g["rects"]["mb_cancel"])
    rep["cancelled"] = bool(w.wait_for(lambda: not mb(sx, A, "state").get("confirm"), 2.0))
    if not rep["cancelled"]:
        bad.append("cancel did not clear the confirmation")
    # a stale token after the cancel is refused (the world forgot it)
    rs, _ = req(sx, A, "MobAction", {"eid": eid, "op": 2, "token": (c or {}).get("token") or 5})
    rep["stale_token"] = rs
    if code_of(rs) != 23:
        bad.append("stale token after cancel: %s (want 23)" % rs)
    # again: confirm -> gone
    g = mb(sx, A, "gui")
    rw = row_of(g, eid)
    w.click(sx, A, rw["destroy"])
    c2 = wait_confirm(sx, A, 2, eid)
    n0 = fx_n(sx, A)
    rep["confirm_how"] = confirm(sx, A)
    gone = w.wait_for(lambda: not w.bench_info(sx, eid).get("eid"), 4.0)
    rep["gone"] = bool(gone)
    rep["fx"] = fx_events(sx, A, n0)
    if not gone or "destroy" not in rep["fx"]:
        bad.append("destroy with confirmation: gone %s fx %s" % (gone, rep["fx"]))
    dead = mob_dead(sx, "alice")
    rep["dead_world"] = dead
    if not any(d["eid"] == eid for d in dead):
        bad.append("no last-state slot for %d: %s" % (eid, dead))
    gd = w.wait_for(lambda: (lambda x: x if dead_row_of(x, eid) else None)(mb(sx, A, "gui")), 3.0)
    rep["dead_row"] = dead_row_of(gd or {}, eid)
    if not rep["dead_row"]:
        bad.append("panel shows no dead row for %d" % eid)
    rep["shot"] = w.shot(sx, A, "b1_destroy_dead_row")
    close_panel(sx, A)
    _m(sx)["destroy"] = {k: rep.get(k) for k in ("carol", "alive_without_confirm", "cancelled", "stale_token", "gone", "fx", "dead_world")}
    _save(sx, "olife_b1_destroy.json", rep)
    return {"ok": not bad, "result": _m(sx)["destroy"], "error": "; ".join(bad) or None}


def st_restore(sx, args, step):
    w = W()
    A, B, C = _clients(sx)
    key = args.get("mob", "m_orbit")
    eid = mob_eid(sx, key)
    rep, bad = {"eid": eid}, []
    # state before the kill: KV, look, code
    w._stdin(sx, "store_kv_set %d b1key hello" % eid, r"store_kv_set queued")
    time.sleep(0.4)
    rl, _ = req(sx, A, "EntityEdit", {"eid": eid, "op": 3, "name": "", "model": "olife_bone", "texture": "blocks:planks"})
    rep["look_set"] = code_of(rl)
    time.sleep(0.3)
    before = w.bench_info(sx, eid)
    rep["before"] = {k: before.get(k) for k in ("code_fnv", "model", "texture", "status", "name", "owner")}
    rep["kv_before"] = store_kv(sx, eid)
    if rep["kv_before"].get("b1key") != "hello":
        bad.append("KV not set before: %s" % rep["kv_before"])
    # operator kills it (A2 /kill through stdin olife.op)
    n0 = fx_n(sx, A)
    rk = A2().run_op(sx.lab, P["_roles"](sx)["world"], sx.owner, "/kill #%d" % eid, by="operator", via="cli")
    rep["kill"] = rk
    if rk.get("code") != 0:
        return {"ok": False, "error": "kill failed: %s" % rk, "result": rep}
    gone = w.wait_for(lambda: not w.bench_info(sx, eid).get("eid"), 4.0)
    rep["killed_fx"] = fx_events(sx, A, n0)
    dead = mob_dead(sx, "alice")
    rep["dead_world"] = dead
    if not gone or not any(d["eid"] == eid for d in dead):
        bad.append("killed mob has no last-state slot: gone %s dead %s" % (gone, dead))
    # carol: restore alice's dead mob -> 3
    rc, _ = req(sx, C, "MobAction", {"eid": eid, "op": 3, "token": 0})
    rep["carol"] = rc
    if code_of(rc) != 3:
        bad.append("carol restore: %s (want 3)" % rc)
    # alice: panel -> dead row -> «Восстановить» -> confirm -> ok
    g, _ = open_panel(sx, A)
    gd = w.wait_for(lambda: (lambda x: x if dead_row_of(x, eid) else None)(mb(sx, A, "gui")), 3.0)
    dr = dead_row_of(gd or {}, eid)
    if not dr or not dr.get("restore"):
        return {"ok": False, "error": "no dead row for %d: %s" % (eid, (gd or g).get("dead")), "result": rep}
    rep["shot_dead"] = w.shot(sx, A, "b1_restore_dead_row")
    w.click(sx, A, dr["restore"])
    c = wait_confirm(sx, A, 3, eid)
    rep["confirm"] = c
    if not c:
        bad.append("no MobConfirm for restore")
    n1 = fx_n(sx, A)
    rep["confirm_how"] = confirm(sx, A)
    st = w.wait_for(lambda: (lambda x: x if any(r["src"] == eid for r in x.get("restored") or []) else None)(mb(sx, A, "state")), 5.0)
    rep["restored_fx"] = fx_events(sx, A, n1)
    if not st:
        return {"ok": False, "error": "no MobRestored: %s" % [r for r in mb(sx, A, "state").get("replies") or [] if r["op"] == 15], "result": rep}
    new = next(r["eid"] for r in st["restored"] if r["src"] == eid)
    _b(sx)["restored"][key] = new
    rep["new_eid"] = new
    after = w.bench_info(sx, new)
    rep["after"] = {k: after.get(k) for k in ("code_fnv", "model", "texture", "status", "name", "owner", "pos")}
    if after.get("code_fnv") != before.get("code_fnv") or after.get("model") != before.get("model") \
            or after.get("texture") != before.get("texture") or after.get("owner") != before.get("owner"):
        bad.append("restored differs: %s vs %s" % (rep["after"], rep["before"]))
    rep["kv_after"] = store_kv(sx, new)
    if rep["kv_after"].get("b1key") != "hello":
        bad.append("KV not restored: %s" % rep["kv_after"])
    if before.get("status") == "run":
        run = w.wait_for(lambda: w.bench_info(sx, new).get("status") == "run", 4.0)
        p0 = w.bench_info(sx, new).get("pos")
        time.sleep(2.5)
        p1 = w.bench_info(sx, new).get("pos")
        rep["runs"] = {"run": bool(run), "moved": round(math.dist(p0, p1), 3) if p0 and p1 else None}
        if not run or (rep["runs"]["moved"] or 0) < 0.3:
            bad.append("restored mob not running / not moving: %s" % rep["runs"])
    if "restore" not in rep["restored_fx"]:
        bad.append("no restore feedback: %s" % rep["restored_fx"])
    # the slot is consumed: again -> 26
    r2, _ = req(sx, A, "MobAction", {"eid": eid, "op": 3, "token": 0})
    rep["again"] = r2
    if code_of(r2) != 26:
        bad.append("second restore: %s (want 26)" % r2)
    # the new mob is in the list, the dead row is gone
    g2 = w.wait_for(lambda: (lambda x: x if row_of(x, new) and not dead_row_of(x, eid) else None)(mb(sx, A, "gui")), 3.0)
    rep["panel_after"] = {"row": bool(row_of(g2 or {}, new)), "dead_row": bool(dead_row_of(g2 or mb(sx, A, "gui"), eid))}
    if not g2:
        bad.append("panel after restore: %s" % rep["panel_after"])
    rep["shot_after"] = w.shot(sx, A, "b1_restore_after")
    close_panel(sx, A)
    _m(sx)["restore"] = {k: rep.get(k) for k in ("before", "kill", "killed_fx", "carol", "new_eid", "after", "kv_after", "runs", "again", "restored_fx")}
    _save(sx, "olife_b1_restore.json", rep)
    return {"ok": not bad, "result": _m(sx)["restore"], "error": "; ".join(bad) or None}


V_CODES = [
    ["-- v1", "function on_tick(dt) end"],
    ["-- v2 second", "local t = 0", "function on_tick(dt) t = t + dt end"],
    ["-- v3 third", "function on_tick(dt) end", "-- end"],
]
ERR_CODE = ["function on_tick(dt)", "local x = = 1", "end"]


def st_editor(sx, args, step):
    w = W()
    A = _clients(sx)[0]
    eid = mob_eid(sx, args.get("bench", "a_stop"))
    rep, bad = {"eid": eid}, []
    g, _ = w.open_with_injector(sx, A, eid)
    if not (g.get("st") or {}).get("editing"):
        return {"ok": False, "error": "A not editing %d: %s" % (eid, g.get("st")), "result": rep}
    saves = []
    for i, code in enumerate(V_CODES):
        w.clear_code(sx, A, g)
        w.click(sx, A, g["rects"]["code"])
        w.type_code(sx, A, code)
        want = "\n".join(code)
        got = w.wait_for(lambda: (lambda x: x if (x.get("code") or "").rstrip() == want else None)(w.gui(sx, A)), 4.0)
        n0 = len(w.state(sx, A)["replies"])
        w.click(sx, A, g["rects"]["btn_save"])
        r = w.wait_for(lambda: next((x for x in w.state(sx, A)["replies"][n0:] if x["op"] == 2), None), 4.0) \
            if n0 < 32 else w.wait_for(lambda: w.last_reply(w.state(sx, A), 2, eid), 4.0)
        saves.append({"typed": bool(got), "reply": code_of(r), "fnv": w.fnv_str(want)})
        time.sleep(0.2)
    rep["saves"] = saves
    vers = mob_versions(sx, eid)
    rep["versions_world"] = vers
    if len(vers) != 3 or [v["fnv"] for v in vers] != [s["fnv"] for s in saves]:
        bad.append("versions after 3 saves: %s (want fnv %s)" % (vers, [s["fnv"] for s in saves]))
    # tab «Профиль»: profile text + rows
    g = w.gui(sx, A)
    w.click(sx, A, g["rects"]["tab_mob"])
    gm = w.wait_for(lambda: (lambda x: x if x.get("tab") == "mob" and len(((x.get("mob") or {}).get("rows") or [])) >= 3
                             and "владелец" in ((x.get("mob") or {}).get("pf_mob") or "") else None)(w.gui(sx, A)), 5.0)
    gm = gm or w.gui(sx, A)
    m = gm.get("mob") or {}
    rep["profile"] = {"pf_mob": m.get("pf_mob"), "ver_note": m.get("ver_note"), "rows": [{k: r.get(k) for k in ("n", "fnv", "author", "note")} for r in m.get("rows") or []]}
    rep["shot_profile"] = w.shot(sx, A, "b1_editor_profile")
    pf = m.get("pf_mob") or ""
    if "alice" not in pf or "коммитов 3" not in pf or "права:" not in pf:
        bad.append("profile text: %r" % pf[:200])
    if [r["n"] for r in m.get("rows") or []] != [3, 2, 1]:
        bad.append("version rows: %s" % rep["profile"]["rows"])
    # «Вернуть» #2 -> a 4th commit, the world's code = v2
    row2 = next((r for r in m.get("rows") or [] if r["n"] == 2), None)
    n0 = len(w.state(sx, A)["replies"])
    w.click(sx, A, row2["restore"])
    r = w.wait_for(lambda: next((x for x in w.state(sx, A)["replies"][n0:] if x["op"] == 18), None), 4.0) \
        if n0 < 32 else w.wait_for(lambda: w.last_reply(w.state(sx, A), 18, eid), 4.0)
    rep["restore_reply"] = r
    vers2 = w.wait_for(lambda: (lambda v: v if len(v) == 4 else None)(mob_versions(sx, eid)), 3.0) or mob_versions(sx, eid)
    wi = w.bench_info(sx, eid)
    rep["after_restore"] = {"versions": vers2, "world_fnv": wi.get("code_fnv"), "want_fnv": saves[1]["fnv"],
                            "editor_code_is_v2": (w.gui(sx, A).get("code") or "").rstrip() == "\n".join(V_CODES[1])}
    if code_of(r) != 0 or len(vers2) != 4 or wi.get("code_fnv") != saves[1]["fnv"] or vers2[-1].get("note", "").startswith("save"):
        bad.append("restore of #2: %s" % rep["after_restore"])
    # «Открыть» #3 -> the v3 text in the editor as an unsaved edit
    gm = w.wait_for(lambda: (lambda x: x if len(((x.get("mob") or {}).get("rows") or [])) == 4 else None)(w.gui(sx, A)), 3.0) or w.gui(sx, A)
    row3 = next((r for r in (gm.get("mob") or {}).get("rows") or [] if r["n"] == 3), None)
    if row3:
        w.click(sx, A, row3["open"])
        opened = w.wait_for(lambda: (w.gui(sx, A).get("code") or "").rstrip() == "\n".join(V_CODES[2]), 3.0)
        rep["open_v3"] = {"opened": bool(opened), "edited": w.gui(sx, A).get("edited"), "notice": w.gui(sx, A).get("notice")}
        if not opened or not rep["open_v3"]["edited"]:
            bad.append("open #3: %s" % rep["open_v3"])
    else:
        bad.append("no row #3 after the restore")
    # error line: Run broken code (line 2) -> ERROR, label, caret on line 2
    w.click(sx, A, g["rects"]["tab_code"])
    time.sleep(0.2)
    g = w.gui(sx, A)
    w.clear_code(sx, A, g)
    w.click(sx, A, g["rects"]["code"])
    w.type_code(sx, A, ERR_CODE)
    w.click(sx, A, g["rects"]["btn_run"])
    err = w.wait_for(lambda: (lambda x: x if (x.get("st") or {}).get("status") == 2 else None)(w.gui(sx, A)), 6.0)
    ge = err or w.gui(sx, A)
    m = ge.get("mob") or {}
    rep["error"] = {"status": (ge.get("st") or {}).get("status"), "error": (ge.get("st") or {}).get("error"),
                    "err_line": m.get("err_line"), "err_caret": m.get("err_caret"), "caret": m.get("caret"), "caret_line": m.get("caret_line")}
    rep["shot_error"] = w.shot(sx, A, "b1_editor_error_line")
    want_line = 2
    cl = m.get("caret_line")
    if not err or not (m.get("err_line") or "").endswith(" %d" % want_line) or cl not in (want_line - 1, want_line):
        bad.append("error line: %s" % rep["error"])
    rep["caret_line_base"] = None if cl is None else ("0-based" if cl == want_line - 1 else ("1-based" if cl == want_line else "?"))
    w.click(sx, A, g["rects"]["btn_run"])                   # STOP (ERROR without edits)
    w.wait_for(lambda: (w.gui(sx, A).get("st") or {}).get("status") == 0, 3.0)
    w.click(sx, A, g["rects"]["btn_close"])
    w.wait_for(lambda: not w.gui(sx, A).get("doc"), 3.0)
    _m(sx)["editor"] = {k: rep.get(k) for k in ("saves", "versions_world", "profile", "restore_reply", "after_restore", "open_v3", "error", "caret_line_base")}
    _save(sx, "olife_b1_editor.json", rep)
    return {"ok": not bad, "result": _m(sx)["editor"], "error": "; ".join(bad) or None}
