"""olife, UX A3 (03.10, агент olife_a3): API скриптов моба — block / entity (вид, скелет, анимация, звук, 3D-текст) /
memory, ответы на запросы через такт, тарификация по таблице цен, репликация вида клиентам, сохранение через рестарты.

Подключается из plugin.py (`_a3()`, перезагрузка по mtime этого файла), получает его глобалы (_roles, _kv, _w4a, ...).
Мир — content/olife_world/modules/mobapi.lua (+ мост sandbox.lua: Ext/Answers/LoadKeep), песочница —
/root/olife/sandboxd (prelude.lua, service.rs: LoadKeep, --state-dir), клиент — content/olife_client/modules/mobview.lua
(F2F `mobview`: то, что видит движок клиента: transform size/rot, текстуры/модели/матрицы костей, анимация, звуки, текст).
Скрипты теста — content/olife_world/sandbox/a3_api_test.lua (все вызовы, результаты — в memory моба: `mob_api <eid>`),
a3_cost_probe.lua (по одному вызову раз в 10 тактов: цена из строк export/sandbox_ticks.jsonl, поле api).

Шаги:
  olife_a3_api {account="alice", viewer="client2"}   — все вызовы: ответы запросов, отказы мира (rejected), вид у мира
        и у клиента B (размер, поворот, текстуры, кость, модель кости, анимация идёт, 3D-текст, видимость), звуки у B;
        отказ по правам (заглушка `olife.api_deny`): звук -> forbidden, у B звуков нет, после `api_allow` снова есть
  olife_a3_costs {account="costprobe"}               — цена каждого вызова (кредиты API, топливо такта) по строкам мира
  olife_a3_restart {}                                — рестарт мира (stop/start аренды): память и переменная скрипта
        продолжаются (LoadKeep), вид снова у B; жёсткое убийство песочницы + старт: переменная продолжается из образа
        (--state-dir), память — из хранилища мира
  olife_a3_demos {account="alice", samples=[...]}   — примеры demo_* через spawn_sample: каждый работает и даёт свой эффект
"""
import json
import math
import os
import time

P = {}
NAMES = {"olife_a3_api": "st_api", "olife_a3_costs": "st_costs", "olife_a3_restart": "st_restart",
         "olife_a3_demos": "st_demos"}
DEMOS = ["demo_spin_scale", "demo_texture_swap", "demo_sound_collision", "demo_block_painter", "demo_memory_counter"]
BONES = ["body", "rody", "body1", "rody1", "body2", "rody2"]


def bind(g):
    P.update(g)


def _d(sx):
    return sx.data.setdefault("a3", {"benches": {}})


def _m(sx):
    return sx.data.setdefault("metrics", {}).setdefault("a3", {})


def _stdin(sx, cmd, pattern, wait=4.0, role="world"):
    lease = P["_roles"](sx)[role]
    return sx.lab.stdin(lease, cmd, owner=sx.owner, wait=wait, pattern=pattern)


def wait_for(fn, timeout, every=0.25):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = fn()
        if last:
            return last
        time.sleep(every)
    return last


def mob_api(sx, eid):
    """`mob_api <eid>` мира -> dict: ver, scale[3], tex{slot: tex}, bones{name: {...}}, anim, rot[3], mem{key: value}"""
    r = _stdin(sx, "mob_api %d" % eid, r"mob_api\seid=%d\s" % eid)
    ls = [x for x in r["lines"] if "mob_api eid=%d " % eid in x]
    if not ls:
        return {}
    line = ls[-1][ls[-1].find("mob_api eid="):]
    out = {}
    mem_part = line.split(" mem=", 1)
    head = mem_part[0]
    for tok in head.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    for k in ("eid", "owner", "ver", "mem_bytes"):
        try:
            out[k] = int(out.get(k, 0))
        except ValueError:
            pass
    for k in ("scale", "rot"):
        try:
            out[k] = [float(x) for x in out.get(k, "").split(",")]
        except ValueError:
            out[k] = None
    tex = {}
    if out.get("tex") and out["tex"] != "-":
        for t in out["tex"].split(","):
            s, _, v = t.partition("=")
            tex[s] = v
    out["tex"] = tex
    bones = {}
    if out.get("bones") and out["bones"] != "-":
        for b in out["bones"].split(";"):
            f = b.split(":")
            if len(f) >= 6:
                bones[f[0]] = {"flags": int(f[1]), "pos": [float(x) for x in f[2].split(",")],
                               "rot": [float(x) for x in f[3].split(",")], "scale": float(f[4]), "model": ":".join(f[5:])}
    out["bones"] = bones
    mem = {}
    if len(mem_part) > 1 and mem_part[1].strip() != "-":
        for kv in mem_part[1].strip().split(";"):
            k, _, v = kv.partition("=")
            try:
                val = json.loads(v)
                mem[k] = val[0] if isinstance(val, list) and len(val) == 1 else val
            except ValueError:
                mem[k] = v
    out["mem"] = mem
    return out


def mobview(sx, lease, eid=None):
    a = {} if eid is None else {"eid": eid}
    r = sx.raw("mobview", a, lease=lease)
    if not r.get("ok"):
        raise RuntimeError("mobview on %s: %s" % (lease, r.get("error")))
    return r["result"]


def ent_view(v, eid):
    for e in v.get("entities") or []:
        if e.get("eid") == eid:
            return e
    return None


def spawn_bench(sx, account, key, step=None):
    r = P["_w4a"]().st_bench(sx, {"account": account, "key": key}, step)
    if not r.get("ok"):
        raise RuntimeError("spawn_bench %s: %s" % (account, r.get("error")))
    eid = r["result"]["eids"][0]
    _d(sx)["benches"][key] = eid
    return eid


def bench_code(sx, eid, code):
    r = _stdin(sx, "bench_code %d %s" % (eid, code), r"bench_code\seid=%d" % eid)
    ls = [x for x in r["lines"] if "bench_code eid=%d" % eid in x]
    if not ls or "loaded=true" not in ls[-1]:
        raise RuntimeError("bench_code %d %s: %s" % (eid, code, (ls or r["lines"][-3:])))
    return P["_kv"](ls[-1][ls[-1].find("bench_code"):])


def sb_meters(sx):
    roles = P["_roles"](sx)
    try:
        return sx.call("meters", {}, lease=roles["sandbox"])
    except Exception as exc:                              # улика, не условие
        return {"error": str(exc)}


def near(a, b, eps=0.02):
    return a is not None and b is not None and len(a) == len(b) and all(abs(x - y) <= eps for x, y in zip(a, b))


def is_identity(m):
    return m is not None and near(m, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], 1e-3)


# ---------------------------------------------------------------------------------------------- olife_a3_api
def st_api(sx, args, step):
    roles = P["_roles"](sx)
    acct = args.get("account", "alice")
    viewers = [roles[r] for r in (args.get("viewers") or ["client2", "client1"]) if r in roles]
    B = viewers[0]
    eid = spawn_bench(sx, acct, "api", step)
    rep, bad = {"eid": eid, "account": acct}, []
    t0 = time.time()
    rep["bench_code"] = bench_code(sx, eid, args.get("code", "a3_api_test"))
    need = ("fill", "acted", "rej_memory.set", "rej_text3d", "q_far", "sounds")
    st = wait_for(lambda: (lambda x: x if all(k in x.get("mem", {}) for k in need) else None)(mob_api(sx, eid)),
                  float(args.get("timeout", 30)), 0.5)
    st = st or mob_api(sx, eid)
    rep["world_s"] = round(time.time() - t0, 2)
    mem = st.get("mem") or {}
    rep["world"] = {k: st.get(k) for k in ("owner", "ver", "scale", "visible", "model", "tex", "bones", "text", "color",
                                           "anim", "anim_speed", "anim_loop", "rot", "fill", "mem_bytes")}
    rep["memory"] = mem
    missing = [k for k in need if k not in mem]
    if missing:
        bad.append("script results missing: %s (mem %s)" % (missing, sorted(mem)))
    # --- queries (answered next tick)
    q = {}
    q["ray"] = str(mem.get("q_ray", "")).count("@") == 1 and not str(mem.get("q_ray")).startswith("miss")
    q["get_same_as_ray"] = mem.get("q_get_same") is True
    q["area"] = str(mem.get("q_area", "")).startswith("3x1x3:")
    q["replaceable_above"] = mem.get("q_repl_above") is True
    q["find"] = isinstance(mem.get("q_find"), (int, float)) and mem.get("q_find", 0) >= 1
    nn = str(mem.get("q_near", "-1/0")).split("/")
    q["nearby_players"] = len(nn) == 2 and int(nn[1]) >= 2
    q["bones"] = mem.get("q_bones") == ",".join(BONES)
    q["far_refused"] = mem.get("q_far") == "nil/reach"
    q["fill_9_of_9"] = mem.get("fill") == "9/0/9"
    q["block_set_one"] = mem.get("q_set_one") == "base:planks"
    rep["queries"] = q
    for k, v in q.items():
        if not v:
            bad.append("query check %s failed (%s)" % (k, {kk: mem.get(kk) for kk in mem if kk.startswith("q_") or kk == "fill"}))
    # --- refusals of the world (rejected events back to the script)
    want_rej = {"rej_set_scale": "bounds", "rej_set_texture": "bad texture", "rej_sound.play": "bad sound",
                "rej_bone.set": "bad bone", "rej_text3d": "bad text", "rej_memory.set": "value too large"}
    rep["rejected"] = {k: mem.get(k) for k in want_rej}
    for k, v in want_rej.items():
        if mem.get(k) != v:
            bad.append("%s = %r, want %r" % (k, mem.get(k), v))
    # --- world state
    w = rep["world"]
    if not near(w.get("scale"), [1.5, 2.0, 1.5], 1e-3):
        bad.append("world scale %s" % w.get("scale"))
    if w.get("tex") != {"*": "blocks:stone"}:
        bad.append("world tex %s" % w.get("tex"))
    bb = w.get("bones") or {}
    if not (bb.get("body") and near(bb["body"]["rot"], [0, 0, 30], 0.01) and near(bb["body"]["pos"], [0, 0.25, 0], 0.01)):
        bad.append("world bone body %s" % bb.get("body"))
    if not (bb.get("rody1") and bb["rody1"]["model"] == "olife_bone"):
        bad.append("world bone rody1 %s" % bb.get("rody1"))
    if w.get("anim") != "olife_wave" or w.get("anim_loop") != "true":
        bad.append("world anim %s loop %s" % (w.get("anim"), w.get("anim_loop")))
    if w.get("text") != "A3_api" or str(w.get("color")) != "ffcc00ff":
        bad.append("world text %s color %s" % (w.get("text"), w.get("color")))
    if not (w.get("rot") and abs(w["rot"][1] - 45) < 0.01):
        bad.append("world rot %s" % w.get("rot"))
    # --- client B (and A): the engine's view of the entity
    views = {}
    for lease in viewers:
        def ok_view(lease=lease):
            v = mobview(sx, lease, eid)
            e = ent_view(v, eid)
            if e and e.get("app") and e["app"].get("ver", 0) >= st.get("ver", 0) and e.get("applied") == e["app"].get("ver") \
                    and (e.get("anim") or {}).get("frames", 0) > 3 and e.get("text3d"):
                return v
            return None
        v = wait_for(ok_view, 10, 0.3) or mobview(sx, lease, eid)
        e = ent_view(v, eid) or {}
        sk = e.get("skeleton") or {}
        bones = sk.get("bones") or {}
        cv = {"size": e.get("size"), "rot_matrix": e.get("rot_matrix"), "textures": sk.get("textures"),
              "visible": sk.get("visible"), "body_matrix": (bones.get("body") or {}).get("matrix"),
              "rody1_model": (bones.get("rody1") or {}).get("model"), "rody_model": (bones.get("rody") or {}).get("model"),
              "anim": e.get("anim"), "text3d": e.get("text3d"), "app_ver": (e.get("app") or {}).get("ver"),
              "tracks": v.get("tracks"), "stats": v.get("stats")}
        chk = {"size": near(cv["size"], [1.5, 2.0, 1.5], 1e-3),
               "rot_yaw45": cv["rot_matrix"] is not None and abs(abs(cv["rot_matrix"][0]) - math.sqrt(0.5)) < 0.01
               and abs(cv["rot_matrix"][5] - 1) < 0.01,
               "textures": cv["textures"] == ["blocks:stone"] * 6,
               "bone_body": cv["body_matrix"] is not None and not is_identity(cv["body_matrix"]),
               "bone_model": cv["rody1_model"] == "olife_bone",
               "anim_playing": bool(cv["anim"] and cv["anim"].get("name") == "olife_wave" and cv["anim"].get("playing")
                                    and cv["anim"].get("frames", 0) > 3 and not cv["anim"].get("err")),
               "text3d": bool(cv["text3d"] and cv["text3d"].get("text") == "A3 api"),
               "app_ver": (cv["app_ver"] or 0) >= st.get("ver", 0)}
        # the animation advances on the client (two polls)
        t1 = (cv["anim"] or {}).get("t")
        time.sleep(0.5)
        e2 = ent_view(mobview(sx, lease, eid), eid) or {}
        t2 = (e2.get("anim") or {}).get("t")
        chk["anim_time_advances"] = t1 is not None and t2 is not None and t1 != t2
        cv["anim_t"] = [t1, t2]
        cv["checks"] = chk
        views[lease] = cv
        for k, ok in chk.items():
            if not ok:
                bad.append("client %s: %s (%s)" % (lease, k, {kk: cv.get(kk) for kk in ("size", "textures", "rody1_model",
                                                                                       "anim", "text3d", "app_ver")}))
    rep["clients"] = views
    # --- visibility toggles (script: hidden at n%200 in [100,200), shown otherwise): B sees both states
    seen = set()
    vis_log = []

    def vis():
        e = ent_view(mobview(sx, B, eid), eid) or {}
        v = (e.get("skeleton") or {}).get("visible")
        a = (e.get("app") or {}).get("visible")
        if not vis_log or vis_log[-1][1:] != [v, a]:
            vis_log.append([round(time.time() - t0, 2), v, a])
        if v is not None:
            seen.add(bool(v))
        return len(seen) == 2
    wait_for(vis, 14, 0.25)
    rep["visible_seen"] = sorted(seen)
    rep["visible_log"] = vis_log
    if seen != {True, False}:
        bad.append("visibility toggle not seen on B: %s (log [t, engine, message]: %s)" % (sorted(seen), vis_log))
    # --- sounds (event every 40 ticks) on B; then the permission stub refuses sound.play
    def b_sounds():
        return [s for s in (mobview(sx, B).get("sounds") or []) if s.get("eid") == eid]
    s0 = b_sounds()
    time.sleep(4.5)
    s1 = b_sounds()
    rep["sounds_b"] = {"before": len(s0), "after_4.5s": len(s1),
                       "last": s1[-1] if s1 else None,
                       "names": sorted({s["sound"] for s in s1})}
    if len(s1) - len(s0) < 2 or rep["sounds_b"]["names"] != ["olife/ok"]:
        bad.append("sounds on B: %s" % rep["sounds_b"])
    _stdin(sx, "olife.api_deny %s sound" % acct, r"mobapi\(")
    time.sleep(0.6)                                    # a sound already in flight (result of the previous tick)
    d0 = len(b_sounds())
    forb = wait_for(lambda: mob_api(sx, eid).get("mem", {}).get("rej_sound.play") == "forbidden", 6, 0.5)
    time.sleep(3.0)
    d1 = len(b_sounds())
    _stdin(sx, "olife.api_allow %s sound" % acct, r"mobapi\(")
    time.sleep(4.5)
    d2 = len(b_sounds())
    rep["permission_stub"] = {"rejected_forbidden": bool(forb), "sounds_while_denied": d1 - d0,
                              "sounds_after_allow": d2 - d1}
    if not forb or d1 - d0 != 0 or d2 - d1 < 1:
        bad.append("permission stub: %s" % rep["permission_stub"])
    rep["mobapi_status"] = [x for x in _stdin(sx, "mobapi_status", r"mobapi\(")["lines"] if "mobapi(" in x][-1:]
    rep["sandbox"] = {k: (sb_meters(sx) or {}).get(k) for k in ("answers", "loads_kept", "persisted", "restored_owners",
                                                                  "loads", "load_errors")}
    _d(sx)["api_eid"] = eid
    _m(sx)["api"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad[:12]) or None}


# ---------------------------------------------------------------------------------------------- olife_a3_costs
COST_NAMES = ["set_scale", "set_rot", "set_visible", "set_texture", "set_model", "skeleton:set_bone",
              "skeleton:set_bone_model", "skeleton:reset", "play_anim", "stop_anim", "play_sound", "text3d", "block.set",
              "block.fill_area 4x1x4", "block.get", "block.get_area 8x4x8", "block.raycast", "block.is_replaceable",
              "block.find r4", "nearby", "skeleton:bones", "memory (load)", "memory.set"]
COST_WANT = [1, 1, 1, 10, 10, 2, 10, 2, 5, 1, 20, 2, 50, 50 + 2 * 16, 2, 5 + 256 // 64, 20, 2, 20 + 729 // 64, 20, 2, 5, 2]


def st_costs(sx, args, step):
    roles = P["_roles"](sx)
    acct = args.get("account", "costprobe")
    eid = spawn_bench(sx, acct, "costs", step)
    bench_code(sx, eid, "a3_cost_probe")
    owner = mob_api(sx, eid).get("owner")
    wdir = sx.lab.lease_info(roles["world"])["dir"]
    path = os.path.join(wdir, "export", "sandbox_ticks.jsonl")

    def rows():
        out = []
        for r in P["read_jsonl"](path):
            o = (r.get("owners") or {}).get(str(owner))
            if o:
                out.append({"tick": r.get("tick"), "api": o.get("api", 0), "fuel": o.get("fuel", 0),
                            "credits": o.get("credits", 0), "rejected": o.get("rejected", 0), "applied": o.get("applied", 0)})
        return out
    got = wait_for(lambda: (lambda l: l if len([x for x in l if x["api"] > 0]) >= len(COST_NAMES) else None)(rows()),
                   float(args.get("timeout", 30)), 1.0)
    allr = got or rows()
    calls = [x for x in allr if x["api"] > 0]
    idle = [x for x in allr if x["api"] == 0 and x["fuel"] > 0]
    idle_fuel = sorted(x["fuel"] for x in idle)
    base = idle_fuel[len(idle_fuel) // 2] if idle_fuel else 0
    table, bad = [], []
    for i, name in enumerate(COST_NAMES):
        c = calls[i] if i < len(calls) else None
        row = {"call": name, "api_credits": c and c["api"], "want": COST_WANT[i], "fuel": c and c["fuel"],
               "fuel_over_idle": c and (c["fuel"] - base), "credits": c and c["credits"], "tick": c and c["tick"],
               "rejected": c and c["rejected"]}
        table.append(row)
        if not c or c["api"] != COST_WANT[i]:
            bad.append("%s: api %s != %s" % (name, c and c["api"], COST_WANT[i]))
        elif c["rejected"]:
            bad.append("%s rejected by the world" % name)
    rep = {"eid": eid, "owner": owner, "rows": len(allr), "calls_seen": len(calls), "idle_fuel_median": base,
           "table": table}
    _m(sx)["costs"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad[:8]) or None}


# ---------------------------------------------------------------------------------------------- olife_a3_restart
def _kill(sx, lease):
    import psutil
    l = sx.lab.leases[lease]
    pid = l.proc.pid if l.proc else None
    if pid:
        psutil.Process(pid).kill()
    return pid


def st_restart(sx, args, step):
    roles = P["_roles"](sx)
    eid = _d(sx).get("api_eid")
    if eid is None:
        return {"ok": False, "error": "olife_a3_api must run first"}
    B = roles.get(args.get("viewer", "client2"))
    rep, bad = {}, []
    m0 = mob_api(sx, eid)
    rep["before"] = {"var": m0["mem"].get("var"), "count": m0["mem"].get("count"), "loads": m0["mem"].get("loads"),
                     "ver": m0.get("ver"), "scale": m0.get("scale"), "anim": m0.get("anim")}
    sess0 = mobview(sx, B).get("client_session") if B else None
    # 1. world restart (stop/start of the same lease: registry + store saved at stop) -> LoadKeep keeps the VM
    _stdin(sx, "save", r"save requested")
    time.sleep(1.5)
    t0 = time.time()
    sx.lab.stop(roles["world"], owner=sx.owner)
    sx.lab.start(roles["world"], owner=sx.owner)
    rep["world_restart_s"] = round(time.time() - t0, 2)
    v0 = m0["mem"].get("var") or 0
    c0 = m0["mem"].get("count") or 0
    m1 = wait_for(lambda: (lambda x: x if (x.get("mem", {}).get("var") or 0) >= v0 + 3 else None)(mob_api(sx, eid)),
                  25, 0.5) or mob_api(sx, eid)
    rep["after_world"] = {"var": m1["mem"].get("var"), "count": m1["mem"].get("count"), "loads": m1["mem"].get("loads"),
                          "ver": m1.get("ver"), "scale": m1.get("scale"), "tex": m1.get("tex"), "anim": m1.get("anim")}
    if m1["mem"].get("loads") != m0["mem"].get("loads"):
        bad.append("world restart: the script was loaded fresh (loads %s -> %s)" % (m0["mem"].get("loads"),
                                                                                  m1["mem"].get("loads")))
    if (m1["mem"].get("var") or 0) < v0 + 3:
        bad.append("world restart: variable did not continue (%s -> %s)" % (v0, m1["mem"].get("var")))
    if (m1["mem"].get("count") or 0) <= c0:
        bad.append("world restart: memory count did not continue (%s -> %s)" % (c0, m1["mem"].get("count")))
    if not near(m1.get("scale"), [1.5, 2.0, 1.5], 1e-3) or m1.get("tex") != {"*": "blocks:stone"}:
        bad.append("world restart: appearance not persisted (%s %s)" % (m1.get("scale"), m1.get("tex")))
    # the client came back (reconnect) and got the persisted appearance again; the animation is not persisted
    if B:
        dbg = {}

        def back():
            v = mobview(sx, B, eid)
            dbg.update(session=v.get("session"), client_session=v.get("client_session"), stats=v.get("stats"))
            if v.get("client_session") in (None, sess0):          # not reconnected yet (it waits 5 s)
                return None
            e = ent_view(v, eid)
            return e if e and e.get("app") and e.get("applied") and near(e.get("size"), [1.5, 2.0, 1.5], 1e-3) else None
        e = wait_for(back, 30, 0.5)
        rep["after_world_client"] = {"session": [sess0, dbg.get("client_session")], "size": e and e.get("size"), "textures": e and (e.get("skeleton") or {}).get("textures"),
                                     "anim": e and e.get("anim")} if e else None
        if not e:
            bad.append("world restart: client B did not get the appearance back")
        elif (e.get("anim") or {}).get("playing"):
            bad.append("world restart: B still plays the animation the world forgot: %s (%s)" % (e.get("anim"), dbg))
    rep["sandbox_after_world"] = {k: (sb_meters(sx) or {}).get(k) for k in ("loads_kept", "loads", "restored_owners")}
    if not (rep["sandbox_after_world"].get("loads_kept") or 0) >= 1:
        bad.append("sandbox loads_kept = %s" % rep["sandbox_after_world"].get("loads_kept"))
    # 2. the sandbox crashes (hard kill) and starts again in the same dir -> owner images from --state-dir
    m2 = mob_api(sx, eid)
    v2 = m2["mem"].get("var") or 0
    c2 = m2["mem"].get("count") or 0
    pid = _kill(sx, roles["sandbox"])
    time.sleep(0.5)
    t1 = time.time()
    sx.lab.start(roles["sandbox"], owner=sx.owner, restart=True)
    rep["sandbox_restart_s"] = round(time.time() - t1, 2)
    rep["sandbox_killed_pid"] = pid
    # the world reconnects by itself (every 2 s); the script continues from the persisted image
    seen = []

    def cont():
        x = mob_api(sx, eid)
        v = x.get("mem", {}).get("var")
        if v is not None and (not seen or seen[-1] != v):
            seen.append(v)
        return x if len(seen) >= 4 else None
    m3 = wait_for(cont, 30, 0.4) or mob_api(sx, eid)
    rep["after_sandbox"] = {"var_before_kill": v2, "var_series": seen, "count_before": c2,
                            "count": m3["mem"].get("count"), "loads": m3["mem"].get("loads")}
    rep["sandbox_after_kill"] = {k: (sb_meters(sx) or {}).get(k) for k in ("loads_kept", "loads", "restored_owners",
                                                                             "persisted")}
    if m3["mem"].get("loads") != m0["mem"].get("loads"):
        bad.append("sandbox restart: the script was loaded fresh (loads %s)" % m3["mem"].get("loads"))
    # the image is at most persist_every ticks old: the variable goes on from >= v2 - 2 (never back to 1)
    if not seen or min(seen) < max(1, v2 - 2) or seen[-1] <= v2:
        bad.append("sandbox restart: variable series %s after %s" % (seen, v2))
    if (m3["mem"].get("count") or 0) <= c2:
        bad.append("sandbox restart: memory count %s <= %s" % (m3["mem"].get("count"), c2))
    if not (rep["sandbox_after_kill"].get("restored_owners") or 0) >= 1:
        bad.append("sandbox restored_owners = %s" % rep["sandbox_after_kill"].get("restored_owners"))
    _m(sx)["restart"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------------------------------------- olife_a3_demos
def st_demos(sx, args, step):
    roles = P["_roles"](sx)
    acct = args.get("account", "alice")
    B = roles.get(args.get("viewer", "client2"))
    names = args.get("samples") or DEMOS
    eids, rep, bad = {}, {}, []
    for n in names:
        r = _stdin(sx, "spawn_sample %s %s %s 1" % (acct, n, n), r"spawned_sample\saccount=%s\sname=%s" % (acct, n), wait=5)
        ls = [x for x in r["lines"] if "spawned_sample account=%s name=%s " % (acct, n) in x]
        if not ls:
            bad.append("spawn_sample %s: %s" % (n, r["lines"][-3:]))
            continue
        eids[n] = int(ls[-1].split("eids=")[1].split(",")[0].split()[0])
    time.sleep(float(args.get("seconds", 8)))
    for n, eid in eids.items():
        b = P["_w4a"]().bench_info(sx, eid)
        m = mob_api(sx, eid)
        con = [x for x in _stdin(sx, "bench_console %d 6" % eid, r"console\seid=%d" % eid)["lines"]
               if "console eid=%d" % eid in x]
        d = {"eid": eid, "status": b.get("status"), "sb": b.get("sb"), "ver": m.get("ver"), "scale": m.get("scale"),
             "tex": m.get("tex"), "bones": sorted((m.get("bones") or {}).keys()), "mem": m.get("mem"),
             "console": [c[c.find("kind="):][:160] for c in con[-3:]]}
        rep[n] = d
        if d["status"] != "run":
            bad.append("%s status %s" % (n, d["status"]))
    if B and eids:
        v = mobview(sx, B)
        for n, eid in eids.items():
            e = ent_view(v, eid) or {}
            rep[n]["client_b"] = {"size": e.get("size"), "textures": ((e.get("skeleton") or {}).get("textures") or [None])[0],
                                  "sounds": len([s for s in v.get("sounds") or [] if s.get("eid") == eid])}
    # per-demo effect
    def eff(n, cond, what):
        if n in rep and not cond(rep[n]):
            bad.append("%s: %s (%s)" % (n, what, {k: rep[n].get(k) for k in ("ver", "scale", "tex", "bones", "mem",
                                                                               "console", "client_b")}))
    eff("demo_spin_scale", lambda d: near(d["scale"], [1.5, 1.5, 1.5], 1e-3) and "body" in d["bones"], "scale 1.5 + bone")
    eff("demo_texture_swap", lambda d: (d["ver"] or 0) >= 3 and d["tex"].get("*"), "texture swaps")
    eff("demo_sound_collision", lambda d: (d.get("client_b") or {}).get("sounds", 0) >= 1, "sound on B")
    eff("demo_block_painter", lambda d: any("painter: fill_done placed=" in c for c in d["console"]), "fill + read back")
    eff("demo_memory_counter", lambda d: (d["mem"] or {}).get("count", 0) >= 3 and (d["mem"] or {}).get("runs") == 1,
        "memory counter")
    _m(sx)["demos"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}
