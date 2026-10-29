"""olife, волна 4a (02.10, агент olife_w4a): слой игрока — редактор кода сущности, консоль, Injector/GravityGun.

Подключается из plugin.py (`_w4a()`, перезагрузка и по mtime этого файла), получает его глобалы (_roles, _kv, ...).
Клиенты — F2F 0.32 (вид client, окно hidden, ввод изолирован): действия игрока — F2F `input` (клавиши хотбара, ПКМ/ЛКМ,
клики мышью по кнопкам XML-документа по их прямоугольникам, символы в textbox), чтение — Lua-обработчик `olife`
(`gui` — документ редактора с прямоугольниками в пикселях кадра 854x480, `state` — бенчи/ответы/счётчики, `aim` —
повернуть игрока на сущность, как шаг `look` харнесса). Мир — stdin (`spawn_bench`, `bench <eid>`, `olife.admins`).
Шаги:
  olife_bench {account, name?, count=1, key?, admins?}  — бенч(и) аккаунту, eid -> data.w4a.benches[key]
  olife_editor {bench, code[], run_seconds}            — A открывает Injector'ом, набирает код, Run; сущность
        движется у мира и у B; ConsoleDelta только у A; B (админ) — только чтение, пока держит A (код 4/5); A Esc ->
        B берёт Edit, сохраняет, закрывает
  olife_gravity {bench, turn_deg, seconds}             — A хватает ЛКМ, крутит взгляд/идёт, отпускает; B видит те же
        позиции (сверка с миром), B не может схватить (код 8), после отпускания — может
  olife_editor_neg {bench, own?, mob?}                 — tools/olife/editor_neg.py: чужой аккаунт (коды 1/2/3/5/7/9/
        11/13/14), флуд консоли (<= 16 строк и 4 КиБ на дельту, <= 4 дельт/с, dropped > 0)
  olife_bench_code {bench, code, run=true, token}      — владелец через протокол ставит код и запускает
  olife_bench_check {bench, status?, code_fnv_of?, save_as?, same_as?, min_moved?} — `bench <eid>` мира, проверки
"""
import json
import math
import os
import time

P = {}

NAMES = {"olife_bench": "st_bench", "olife_editor": "st_editor", "olife_gravity": "st_gravity",
         "olife_editor_neg": "st_editor_neg", "olife_bench_code": "st_bench_code", "olife_bench_check": "st_bench_check",
         "olife_editor_extras": "st_editor_extras"}

EDITOR_CODE = [
    "-- typed by olife_editor (F2F input)",
    "local t = 0",
    "function on_tick(dt)",
    "t = t + dt",
    "local p = self.pos",
    "self:move_to({p[1] + math.cos(t) * 0.12, p[2], p[3] + math.sin(t) * 0.12})",
    "if math.floor(t * 20) % 20 == 0 then print('tick ' .. math.floor(t)) end",
    "end",
]


def bind(g):
    P.update(g)


def steps():
    return {n: _lazy(n) for n in NAMES}


def _lazy(n):
    def f(sx, args, step):
        return getattr(P["_w4a"](), NAMES[n])(sx, args, step)
    return f


# ---------------------------------------------------------------------------------------------- общее
def fnv_str(s):
    h = 2166136261
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 16777619) % 4294967296
    return h


def _w(sx):
    return sx.data.setdefault("w4a", {"benches": {}, "checks": {}})


def _m(sx):
    return sx.data.setdefault("metrics", {}).setdefault("w4a", {})


def _stdin(sx, cmd, pattern, wait=3.0, role="world"):
    lease = P["_roles"](sx)[role]
    return sx.lab.stdin(lease, cmd, owner=sx.owner, wait=wait, pattern=pattern)


def bench_info(sx, eid):
    r = _stdin(sx, "bench %d" % eid, r"bench\seid=%d" % eid)
    ls = [x for x in r["lines"] if "bench eid=%d " % eid in x]
    if not ls:
        return {}
    line = ls[-1][ls[-1].find("bench eid="):]
    d = P["_kv"](line)
    if isinstance(d.get("pos"), str):
        d["pos"] = [float(v) for v in d["pos"].split(",")]
    return d


def ol(sx, lease, op, quiet=True, **a):
    a["op"] = op
    r = (sx.raw if quiet else sx.f2f)("olife", a, lease=lease)
    if not r.get("ok"):
        raise RuntimeError("olife %s on %s: %s" % (op, lease, r.get("error")))
    return r["result"]


def inp(sx, lease, **a):
    r = sx.f2f("input", a, lease=lease)
    if not r.get("ok"):
        raise RuntimeError("input on %s: %s" % (lease, r.get("error")))
    return r.get("result")


def press_key(sx, lease, key, hold=0.08):
    inp(sx, lease, keys={key: True})
    time.sleep(hold)
    inp(sx, lease, keys={key: False})
    time.sleep(0.06)


def mouse_button(sx, lease, i, hold=0.12, x=None, y=None):
    b = [False, False, False]
    m = {"buttons": list(b)}
    if x is not None:
        m["x"], m["y"] = float(x), float(y)
    m["buttons"][i] = True
    inp(sx, lease, mouse=m)
    time.sleep(hold)
    inp(sx, lease, mouse={"buttons": b})
    time.sleep(0.06)


def click(sx, lease, rect):
    """клик ЛКМ по центру прямоугольника элемента (пиксели кадра): курсор, затем нажатие/отпускание"""
    inp(sx, lease, mouse={"x": float(rect["cx"]), "y": float(rect["cy"])})
    time.sleep(0.06)
    mouse_button(sx, lease, 0)


def wait_for(fn, timeout, every=0.1):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = fn()
        if last:
            return last
        time.sleep(every)
    return last


def gui(sx, lease):
    return ol(sx, lease, "gui")


def state(sx, lease):
    return ol(sx, lease, "state")


def bench_of(st, eid):
    for b in st.get("benches") or []:
        if b["eid"] == eid:
            return b
    return None


def eid_arg(sx, args, key="bench"):
    v = args.get(key, "alice")
    if isinstance(v, int):
        return v
    return _w(sx)["benches"][v][0]


def shot(sx, lease, name):
    try:
        r = sx.call("shot", {"name": name}, lease=lease)
        return r.get("path")
    except Exception as exc:  # снимок — улика, не условие
        return "shot failed: %s" % exc


def open_with_injector(sx, lease, eid, timeout=6.0):
    """реальный путь игрока: слот 1 (Injector), взгляд на сущность, ПКМ -> ToolUse -> ScriptState -> оверлей"""
    press_key(sx, lease, "1")
    ol(sx, lease, "aim", quiet=False, eid=eid)
    sel = wait_for(lambda: (state(sx, lease).get("camera") or {}).get("selected_eid") == eid, 2.0)
    mouse_button(sx, lease, 1)
    g = wait_for(lambda: (lambda x: x if x.get("doc") and x.get("st") else None)(gui(sx, lease)), timeout)
    return g or gui(sx, lease), bool(sel)


def script_row(g, kind, name=None):
    """UX round 1: строка панели скриптов редактора (kind new|server|file|template, name) -> прямоугольник кнопки"""
    for it in g.get("scripts") or []:
        if it.get("kind") == kind and (name is None or it.get("name") == name):
            return it.get("rect")
    return None


def clear_code(sx, lease, g):
    """«+ новый (пустой)» в панели скриптов (раньше — кнопка Clear)"""
    click(sx, lease, script_row(g, "new"))


def type_code(sx, lease, lines):
    for i, line in enumerate(lines):
        inp(sx, lease, chars=line)
        time.sleep(0.05)
        if i < len(lines) - 1:
            press_key(sx, lease, "enter", hold=0.05)


def last_reply(st, op, eid=None):
    for r in reversed(st.get("replies") or []):
        if r["op"] == op and (eid is None or r["eid"] == eid):
            return r
    return None


# ---------------------------------------------------------------------------------------------- шаги
def st_bench(sx, args, step):
    acct = args.get("account", "alice")
    key = args.get("key", acct)
    if args.get("admins") is not None:
        _stdin(sx, "olife.admins %s" % args["admins"], r"admins=")
    r = _stdin(sx, "spawn_bench %s %s %d" % (acct, args.get("name") or ("b_" + key), int(args.get("count", 1))),
               r"spawned_bench\saccount=%s\seids=" % acct, wait=5.0)
    ls = [x for x in r["lines"] if "spawned_bench account=%s eids=" % acct in x]
    if not ls:
        return {"ok": False, "error": "no spawned_bench line: %s" % r["lines"][-4:]}
    eids = [int(v) for v in ls[-1].split("eids=")[1].split()[0].split(",")]
    _w(sx)["benches"][key] = eids
    # UX A1: rights of the new benches {action: audience} (e.g. olife_gravity: move -> everyone, as before A1)
    for a, aud in (args.get("perms") or {}).items():
        for e in eids:
            _stdin(sx, "bench_perms %d %s %s" % (e, a, aud), r"perms\seid=%d" % e)
    return {"ok": True, "result": {"key": key, "eids": eids, "admins": args.get("admins"), "perms": args.get("perms")}}


def st_editor(sx, args, step):
    roles = P["_roles"](sx)
    A, B = roles["client1"], roles["client2"]
    eid = eid_arg(sx, args)
    code = args.get("code") or EDITOR_CODE
    rep = {"eid": eid}
    bad = []
    # 1. оба клиента видят бенч (EntityMeta пришла)
    seen = wait_for(lambda: bench_of(state(sx, A), eid) and bench_of(state(sx, B), eid), 20)
    if not seen:
        return {"ok": False, "error": "bench %d not seen by both clients" % eid}
    w0 = bench_info(sx, eid)
    rep["world_before"] = {k: w0.get(k) for k in ("status", "owner", "lock", "subs", "code_fnv", "pos")}
    # 2. A: Injector ПКМ -> редактор
    t0 = time.time()
    gA, selA = open_with_injector(sx, A, eid)
    rep["a_open_s"] = round(time.time() - t0, 2)
    stA = gA.get("st") or {}
    rep["a_open"] = {"selected_by_engine": selA, "doc": gA.get("doc"), "editing": stA.get("editing"),
                     "can_edit": stA.get("can_edit"), "lock_holder": stA.get("lock_holder")}
    if not (gA.get("doc") and stA.get("editing")):
        return {"ok": False, "error": "A editor not open/editing: %s" % rep["a_open"], "result": rep}
    rep["shot_a_open"] = shot(sx, A, "editor_a_open")
    # 3. A: Clear, клик в textbox, набор кода (символы + Enter), Run (Save+Run)
    clear_code(sx, A, gA)                       # UX round 1: «+ новый (пустой)» в панели скриптов
    click(sx, A, gA["rects"]["code"])
    type_code(sx, A, code)
    want = "\n".join(code)
    got = wait_for(lambda: (lambda g: g if (g.get("code") or "").rstrip() == want else None)(gui(sx, A)), 4.0)
    gA = got or gui(sx, A)
    rep["typed_ok"] = got is not None
    rep["typed_len"] = len(gA.get("code") or "")
    if not got:
        bad.append("typed text differs: %r" % (gA.get("code") or "")[:200])
    sa0 = state(sx, A)["stats"]
    click(sx, A, gA["rects"]["btn_run"])
    run_ok = wait_for(lambda: (gui(sx, A).get("st") or {}).get("status") == 1, 5.0)
    rep["a_run_status"] = bool(run_ok)
    if not run_ok:
        bad.append("A status not RUN after Run")
    w1 = bench_info(sx, eid)
    rep["world_after_run"] = {k: w1.get(k) for k in ("status", "code_len", "code_fnv", "lock", "subs", "pos")}
    rep["code_fnv_expected"] = fnv_str(gA.get("code") or "")
    if w1.get("code_fnv") != rep["code_fnv_expected"]:
        bad.append("world code fnv %s != typed %s" % (w1.get("code_fnv"), rep["code_fnv_expected"]))
    if w1.get("status") != "run":
        bad.append("world status %s" % w1.get("status"))
    # 4. движение: мир и B (реплика) — серия позиций
    series = []
    tend = time.time() + float(args.get("run_seconds", 4))
    while time.time() < tend:
        wi = bench_info(sx, eid)
        bi = bench_of(state(sx, B), eid) or {}
        series.append({"t": round(time.time() - t0, 2), "world": wi.get("pos"), "b": bi.get("pos")})
        time.sleep(0.4)
    pw = [s["world"] for s in series if s["world"]]
    moved = sum(math.dist(pw[i], pw[i + 1]) for i in range(len(pw) - 1)) if len(pw) > 1 else 0
    pb = [s["b"] for s in series if s["b"]]
    moved_b = sum(math.dist(pb[i], pb[i + 1]) for i in range(len(pb) - 1)) if len(pb) > 1 else 0
    gap = [math.dist(s["world"], s["b"]) for s in series if s["world"] and s["b"]]
    rep["movement"] = {"samples": len(series), "world_path": round(moved, 3), "b_path": round(moved_b, 3),
                       "world_b_gap_max": round(max(gap or [0]), 3), "world_b_gap_p50": round(sorted(gap)[len(gap) // 2], 3) if gap else None}
    if moved < 0.5:
        bad.append("bench did not move on the server (path %.3f)" % moved)
    if moved_b < 0.5:
        bad.append("bench did not move on client B (path %.3f)" % moved_b)
    # name tag / status у B (EntityMeta): RUN
    bb = bench_of(state(sx, B), eid) or {}
    rep["b_tag"] = {"label": bb.get("label"), "status": bb.get("status")}
    if bb.get("status") != 1 or not (bb.get("label") or "").endswith("RUN"):
        bad.append("B name tag not RUN: %s" % rep["b_tag"])
    ol(sx, B, "aim", quiet=False, eid=eid)
    time.sleep(0.3)
    rep["shot_b_tag"] = shot(sx, B, "bench_running_seen_by_b")
    # 5. консоль: только у A (подписан), у B — ни одной дельты и ни одного ScriptState
    sA, sB = state(sx, A), state(sx, B)
    gA = gui(sx, A)
    rep["console"] = {"a_deltas": sA["stats"]["deltas"] - sa0["deltas"], "a_lines": gA.get("console_lines"),
                      "a_tail": (gA.get("console") or "").splitlines()[-3:], "b_deltas": sB["stats"]["deltas"],
                      "b_states": sB["stats"]["states"], "meters": (gA.get("st") or {}).get("meters")}
    if rep["console"]["a_deltas"] < 1 or not any("tick" in x for x in rep["console"]["a_tail"]):
        bad.append("no console delta with script output at A")
    if sB["stats"]["deltas"] != 0 or sB["stats"]["states"] != 0:
        bad.append("B (not subscribed) got deltas/states: %s/%s" % (sB["stats"]["deltas"], sB["stats"]["states"]))
    rep["shot_a_run"] = shot(sx, A, "editor_a_running")
    # 6. B (админ) открывает: только чтение, лок у A -> код 4; сохранение в обход UI -> код 5
    gB, selB = open_with_injector(sx, B, eid)
    stB = gB.get("st") or {}
    sB = state(sx, B)
    rB = last_reply(sB, 1, eid)
    rep["b_open"] = {"selected_by_engine": selB, "doc": gB.get("doc"), "editing": stB.get("editing"),
                     "can_edit": stB.get("can_edit"), "lock_holder": stB.get("lock_holder"),
                     "code_editable": gB.get("code_editable"), "reply": rB}
    if not (gB.get("doc") and stB.get("can_edit") and not stB.get("editing") and stB.get("lock_holder") == "client1"
            and rB and rB["code"] == 4 and gB.get("code_editable") is False):
        bad.append("B open not read-only under A's lock: %s" % rep["b_open"])
    rep["shot_b_readonly"] = shot(sx, B, "editor_b_readonly")
    s = ol(sx, B, "send", quiet=False, name="ScriptSave", msg={"eid": eid, "code": "print('B was here')"})["seq"]
    r = wait_for(lambda: next((x for x in state(sx, B)["replies"] if x["seq"] == s), None), 3.0)
    rep["b_save_while_locked"] = r
    if not r or r["code"] != 5:
        bad.append("B save under A's lock: %s (want 5)" % r)
    time.sleep(0.6)
    rep["b_deltas_after_open"] = state(sx, B)["stats"]["deltas"]
    # 7. A: Esc закрывает и отдаёт лок (первый Esc может только снять фокус с textbox)
    for _ in range(3):
        press_key(sx, A, "escape")
        if wait_for(lambda: not gui(sx, A).get("doc"), 1.0):
            break
    closed = not gui(sx, A).get("doc")
    wl = wait_for(lambda: (lambda d: d if d.get("lock") == "-" else None)(bench_info(sx, eid)), 3.0)
    rep["a_esc"] = {"closed": closed, "world_lock": (wl or {}).get("lock"), "world_subs": (wl or {}).get("subs")}
    if not closed or not wl:
        bad.append("A Esc: closed=%s lock=%s" % (closed, (wl or {}).get("lock")))
    # 8. B: Edit -> лок у B, Save кнопкой -> ок, Close -> лок свободен
    gB = gui(sx, B)
    stB = gB.get("st") or {}
    rep["b_after_a_close"] = {"lock_holder": stB.get("lock_holder"), "edit_btn": (gB.get("rects") or {}).get("btn_edit")}
    click(sx, B, gB["rects"]["btn_edit"])
    got = wait_for(lambda: (gui(sx, B).get("st") or {}).get("editing"), 3.0)
    gB = gui(sx, B)
    rep["b_edit"] = {"editing": bool(got), "code_editable": gB.get("code_editable"), "lock": bench_info(sx, eid).get("lock")}
    if not got or gB.get("code_editable") is not True:
        bad.append("B did not get the lock after A closed: %s" % rep["b_edit"])
    else:
        n0 = len(state(sx, B)["replies"])
        click(sx, B, gB["rects"]["btn_save"])
        r = wait_for(lambda: next((x for x in state(sx, B)["replies"][n0:] if x["op"] == 2), None), 3.0) \
            if n0 < 32 else wait_for(lambda: last_reply(state(sx, B), 2, eid), 3.0)
        rep["b_save"] = r
        if not r or r["code"] != 0:
            bad.append("B save with the lock: %s" % r)
        rep["shot_b_edit"] = shot(sx, B, "editor_b_editing")
        click(sx, B, gB["rects"]["btn_close"])
        wl = wait_for(lambda: (lambda d: d if d.get("lock") == "-" else None)(bench_info(sx, eid)), 3.0)
        rep["b_close_lock"] = (wl or {}).get("lock")
        if not wl:
            bad.append("B close did not free the lock")
    w2 = bench_info(sx, eid)
    rep["world_end"] = {k: w2.get(k) for k in ("status", "code_fnv", "lock", "subs", "credits_min", "fuel_min",
                                               "actions_min", "rejected_min", "label")}
    if w2.get("status") != "run":
        bad.append("world status at end %s" % w2.get("status"))
    _m(sx)["editor"] = rep
    with open(os.path.join(sx.out_dir(), "olife_editor.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    return {"ok": not bad, "result": {k: rep[k] for k in ("eid", "a_open", "typed_ok", "a_run_status", "movement",
                                                          "console", "b_open", "b_save_while_locked", "a_esc",
                                                          "b_edit") if k in rep},
            "error": "; ".join(bad) or None}


def st_gravity(sx, args, step):
    roles = P["_roles"](sx)
    A, B = roles["client1"], roles["client2"]
    eid = eid_arg(sx, args)
    rep = {"eid": eid}
    bad = []
    if not wait_for(lambda: bench_of(state(sx, A), eid) and bench_of(state(sx, B), eid), 20):
        return {"ok": False, "error": "bench %d not seen by both" % eid}
    w0 = bench_info(sx, eid)
    rep["start"] = w0.get("pos")
    # A: слот 2 (GravityGun), взгляд, ЛКМ -> захват
    press_key(sx, A, "2")
    ol(sx, A, "aim", quiet=False, eid=eid)
    time.sleep(0.25)
    stA = state(sx, A)
    rep["a_tool"] = (stA.get("camera") or {}).get("tool")
    mouse_button(sx, A, 0)
    held = wait_for(lambda: state(sx, A).get("holding") == eid, 3.0)
    wh = bench_info(sx, eid)
    rep["a_grab"] = {"holding": bool(held), "world_holder": wh.get("holder"), "reply": last_reply(state(sx, A), 6, eid)}
    if not held or wh.get("holder") != "client1":
        return {"ok": False, "error": "A grab failed: %s" % rep["a_grab"], "result": rep}
    # B видит владельца, B не может схватить (8)
    time.sleep(0.3)
    bb = bench_of(state(sx, B), eid) or {}
    rep["b_sees_holder"] = bb.get("holder")
    if bb.get("holder") != "client1":
        bad.append("B does not see the holder: %s" % bb.get("holder"))
    press_key(sx, B, "2")
    ol(sx, B, "aim", quiet=False, eid=eid)
    time.sleep(0.25)
    nB = len(state(sx, B)["replies"])
    mouse_button(sx, B, 0)
    r = wait_for(lambda: next((x for x in state(sx, B)["replies"][nB:] if x["op"] == 6), None), 3.0)
    rep["b_grab_while_held"] = r
    if not r or r["code"] != 8:
        bad.append("B grab while A holds: %s (want 8)" % r)
    # A двигает: поворот взгляда шагами + шаги игрока; мир двигает сущность; серия мир/A/B
    yaw0 = (state(sx, A).get("camera") or {}).get("yaw") or 0
    pitch0 = (state(sx, A).get("camera") or {}).get("pitch") or 0
    turn = float(args.get("turn_deg", 60))
    nsteps = int(args.get("steps", 12))
    series = []
    pos0 = (state(sx, A).get("camera") or {}).get("pos")
    for i in range(1, nsteps + 1):
        ol(sx, A, "look", yaw=yaw0 + turn * i / nsteps, pitch=pitch0)
        if pos0 and i % 3 == 0:
            ol(sx, A, "place", pos=[pos0[0] + 0.4 * (i // 3), pos0[1], pos0[2]])
        time.sleep(0.15)
        series.append({"world": bench_info(sx, eid).get("pos"), "b": (bench_of(state(sx, B), eid) or {}).get("pos")})
    time.sleep(0.6)
    wm = bench_info(sx, eid)
    rep["moved_world"] = round(math.dist(w0["pos"], wm["pos"]), 3) if w0.get("pos") and wm.get("pos") else None
    if not rep["moved_world"] or rep["moved_world"] < 1.0:
        bad.append("held bench did not move (%.3f)" % (rep["moved_world"] or 0))
    # A отпускает (ЛКМ ещё раз)
    mouse_button(sx, A, 0)
    rel = wait_for(lambda: state(sx, A).get("holding") is None and bench_info(sx, eid).get("holder") == "-", 3.0)
    rep["a_release"] = bool(rel)
    if not rel:
        bad.append("A release failed")
    time.sleep(1.0)
    wf = bench_info(sx, eid)
    bf = bench_of(state(sx, B), eid) or {}
    af = bench_of(state(sx, A), eid) or {}
    rep["final"] = {"world": wf.get("pos"), "a": af.get("pos"), "b": bf.get("pos"), "b_holder": bf.get("holder")}
    for who, p in (("A", af.get("pos")), ("B", bf.get("pos"))):
        if not p or not wf.get("pos") or math.dist(p, wf["pos"]) > 0.01:
            bad.append("%s final pos %s != world %s" % (who, p, wf.get("pos")))
    gaps = [math.dist(s["world"], s["b"]) for s in series if s["world"] and s["b"]]
    rep["hold_series"] = {"samples": len(series), "b_gap_max": round(max(gaps or [0]), 3),
                          "b_gap_p50": round(sorted(gaps)[len(gaps) // 2], 3) if gaps else None}
    # после отпускания B может схватить (0) и отпустить
    nB = len(state(sx, B)["replies"])
    ol(sx, B, "aim", quiet=False, eid=eid)
    time.sleep(0.25)
    mouse_button(sx, B, 0)
    r = wait_for(lambda: next((x for x in state(sx, B)["replies"][nB:] if x["op"] == 6), None), 3.0)
    rep["b_grab_after"] = r
    if not r or r["code"] != 0:
        bad.append("B grab after release: %s" % r)
    else:
        rep["shot_b_holding"] = shot(sx, B, "gravity_b_holding")
        mouse_button(sx, B, 0)
        wait_for(lambda: bench_info(sx, eid).get("holder") == "-", 3.0)
    _m(sx)["gravity"] = rep
    with open(os.path.join(sx.out_dir(), "olife_gravity.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def _tools():
    import sys
    tools = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "olife"))
    if tools not in sys.path:
        sys.path.insert(0, tools)
    import importlib
    # the daemon is long-lived: the generated codecs (olife_proto.client) may be newer than its cached import
    # (UX round 1 added EntityEdit/EntityLook/ScriptProfile) -> reload them before the test client
    for name in ("olife_proto.client",):
        try:
            importlib.reload(importlib.import_module(name))
        except Exception:
            pass
    m = importlib.import_module("editor_neg")
    return importlib.reload(m)


def st_editor_neg(sx, args, step):
    neg = _tools()
    roles = P["_roles"](sx)
    gw = sx.lab.lease_info(roles["gateway"])["ports"]["gw"]
    eid = eid_arg(sx, args)
    own = eid_arg(sx, args, "own") if args.get("own") else 0
    rep = {"negative": neg.run(gw, eid, int(args.get("mob", 1)), miss_eid=own)}
    if args.get("own"):
        rep["flood"] = neg.flood(gw, eid_arg(sx, args, "own"), float(args.get("flood_seconds", 6)))
        rep["flood_world"] = bench_info(sx, eid_arg(sx, args, "own"))
    st = P["_status"](sx, "world", "status tick=")
    rep["world_alive"] = bool(st)
    rep["world_tick_ms"] = {k: st.get(k) for k in ("tick", "tps")}
    try:
        rep["gateway_alive"] = bool(sx.call("metrics", lease=roles["gateway"]))
    except Exception as exc:
        rep["gateway_alive"] = False
        rep["gateway_error"] = str(exc)
    with open(os.path.join(sx.out_dir(), "olife_editor_neg.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    n = rep["negative"]
    bad = [x["name"] for x in n["results"] if not x["ok"]]
    fl = rep.get("flood")
    if fl and not fl["ok"]:
        bad.append("flood %s" % {k: fl[k] for k in ("deltas_per_s", "lines_max", "text_bytes_max", "dropped")})
    if fl and (rep["flood_world"].get("console") or 0) > 64:
        bad.append("world console ring > 64")
    if not rep["world_alive"] or not rep["gateway_alive"]:
        bad.append("world/gateway dead")
    _m(sx)["editor_neg"] = {"tests": n["tests"], "passed": n["passed"],
                            "table": [{k: x.get(k) for k in ("name", "want_code", "got_code", "ok")} for x in n["results"]],
                            "flood": fl}
    return {"ok": not bad, "result": _m(sx)["editor_neg"], "error": "; ".join(bad) or None}


def st_bench_code(sx, args, step):
    neg = _tools()
    roles = P["_roles"](sx)
    gw = sx.lab.lease_info(roles["gateway"])["ports"]["gw"]
    eid = eid_arg(sx, args)
    code = args.get("code") or "\n".join(EDITOR_CODE)
    r = neg.set_code(gw, eid, code, bool(args.get("run", True)), args.get("token", "olife-carol"), args.get("name", "carol"))
    _w(sx)["checks"]["code_fnv:%d" % eid] = fnv_str(code)
    ok = all(v == 0 for v in r.values())
    return {"ok": ok, "result": {"eid": eid, "replies": r, "code_fnv": fnv_str(code)}, "error": None if ok else "replies %s" % r}


def st_bench_check(sx, args, step):
    eid = eid_arg(sx, args)
    t0 = time.time()
    d = wait_for(lambda: (lambda x: x if x.get("status") == args.get("status", x.get("status")) else None)(bench_info(sx, eid)),
                 float(args.get("timeout", 10)))
    d = d or bench_info(sx, eid)
    bad = []
    if args.get("status") and d.get("status") != args["status"]:
        bad.append("status %s != %s" % (d.get("status"), args["status"]))
    want = _w(sx)["checks"].get("code_fnv:%d" % eid)
    if args.get("code_same", True) and want is not None and d.get("code_fnv") != want:
        bad.append("code fnv %s != %s" % (d.get("code_fnv"), want))
    if args.get("min_moved"):
        p0 = d.get("pos")
        time.sleep(float(args.get("move_window", 2.0)))
        p1 = bench_info(sx, eid).get("pos")
        mv = math.dist(p0, p1) if p0 and p1 else 0
        d["moved"] = round(mv, 3)
        if mv < float(args["min_moved"]):
            bad.append("moved %.3f < %s" % (mv, args["min_moved"]))
    if args.get("min_console"):
        if (d.get("console") or 0) < int(args["min_console"]):
            bad.append("console %s < %s" % (d.get("console"), args["min_console"]))
    keep = {k: d.get(k) for k in ("status", "owner", "code_len", "code_fnv", "console", "cseq", "pos", "lock", "label",
                                  "moved", "credits_min")}
    keep["waited_s"] = round(time.time() - t0, 2)
    _m(sx).setdefault("bench_checks", []).append(dict(keep, eid=eid, tag=args.get("tag")))
    return {"ok": not bad, "result": keep, "error": "; ".join(bad) or None}


def st_editor_extras(sx, args, step):
    """A (владелец) снова открывает редактор: шаблон из `select mode=button` (клик по кнопке, затем по пункту), Run -> RUN;
    файл: имя в поле, Save file, Clear, Load file -> тот же код (config:olife/scripts/<имя>.lua); ошибка: код с синтаксической
    ошибкой, Run -> ERROR, строка ошибки в консоли, бирка ERROR у B; Stop -> STOP; Close"""
    roles = P["_roles"](sx)
    A, B = roles["client1"], roles["client2"]
    eid = eid_arg(sx, args)
    rep = {"eid": eid}
    bad = []
    g, _ = open_with_injector(sx, A, eid)
    if not (g.get("st") or {}).get("editing"):
        return {"ok": False, "error": "A not editing: %s" % (g.get("st"),)}
    r = g["rects"]
    # UX round 1: шаблон — строка «шаблон: orbit» панели скриптов (раньше select mode=button)
    click(sx, A, script_row(g, "template", "orbit"))
    time.sleep(0.2)
    g = gui(sx, A)
    rep["template_applied"] = (g.get("code") or "").startswith("-- small circle")
    rep["shot_tpl"] = shot(sx, A, "extras_template")
    if not rep["template_applied"]:
        bad.append("template not applied: %r" % (g.get("code") or "")[:60])
    click(sx, A, r["btn_run"])                  # правленый код -> кнопка RUN (сохранить + запустить)
    ok_run = wait_for(lambda: (gui(sx, A).get("st") or {}).get("status") == 1, 5.0)
    rep["template_run"] = bool(ok_run)
    if not ok_run:
        bad.append("template run not RUN")
    # файл: имя + СОХРАНИТЬ (на сервер и в config:olife/scripts/<имя>.lua), «новый», строка файла в панели -> тот же код
    click(sx, A, r["fname"])
    inp(sx, A, chars=args.get("file", "w4a_test"))
    time.sleep(0.1)
    code_before = gui(sx, A).get("code")
    click(sx, A, r["btn_save"])
    g = wait_for(lambda: (lambda x: x if script_row(x, "file", args.get("file", "w4a_test")) else None)(gui(sx, A)), 3.0) \
        or gui(sx, A)
    clear_code(sx, A, g)
    cleared = gui(sx, A).get("code") == ""
    click(sx, A, script_row(g, "file", args.get("file", "w4a_test")))
    g = gui(sx, A)
    rep["file"] = {"notice": g.get("notice"), "cleared": cleared, "restored": g.get("code") == code_before,
                   "files": g.get("files")}
    if not (cleared and rep["file"]["restored"]):
        bad.append("file save/load: %s" % rep["file"])
    # ошибка
    clear_code(sx, A, g)
    click(sx, A, r["code"])
    type_code(sx, A, ["function on_tick(dt)", "self:set_rot(0, (", "end"])
    click(sx, A, r["btn_run"])
    err = wait_for(lambda: (lambda x: x if (x.get("st") or {}).get("status") == 2 and any(
        l.startswith("! ") for l in (x.get("console") or "").splitlines()[-3:]) else None)(gui(sx, A)), 6.0)
    g = err or gui(sx, A)
    st = g.get("st") or {}
    tail = (g.get("console") or "").splitlines()[-3:]
    rep["error"] = {"status": st.get("status"), "error": st.get("error"), "console_tail": tail, "status_line": g.get("status")}
    if not err or not any(x.startswith("! ") for x in tail):
        bad.append("syntax error not reported: %s" % rep["error"])
    time.sleep(0.3)
    bb = bench_of(state(sx, B), eid) or {}
    rep["b_tag"] = bb.get("label")
    if not (bb.get("label") or "").endswith("ERROR"):
        bad.append("B tag not ERROR: %s" % bb.get("label"))
    rep["shot_error"] = shot(sx, A, "extras_error")
    rep["error_button"] = gui(sx, A).get("run_text")
    click(sx, A, r["btn_run"])                  # ERROR без правок -> кнопка STOP
    stopped = wait_for(lambda: (gui(sx, A).get("st") or {}).get("status") == 0, 3.0)
    rep["stopped"] = bool(stopped)
    if not stopped:
        bad.append("stop after error (button %s)" % rep["error_button"])
    click(sx, A, r["btn_close"])
    rep["closed"] = bool(wait_for(lambda: not gui(sx, A).get("doc"), 3.0))
    w = bench_info(sx, eid)
    rep["world"] = {k_: w.get(k_) for k_ in ("status", "lock", "subs", "label")}
    if w.get("status") != "stop" or w.get("lock") != "-":
        bad.append("world after extras: %s" % rep["world"])
    _m(sx)["editor_extras"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}
