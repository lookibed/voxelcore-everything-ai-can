"""olife, волна 3a (02.10, агент olife_w3s): НАСТОЯЩАЯ песочница olife-sandboxd в сессии лаборатории.

Подключается из plugin.py (`_w3s()`), получает его глобалы (build_session, read_jsonl, stats, _roles, ...).
  olife.sandbox_meters {session|lease, owner?, entities?} — счётчики сервиса с порта управления (F2F `meters`):
      время такта сервиса (mean/p50/p95/p99/max), по владельцам (такты, сущность-такты, топливо, кредиты, действия,
      отброшенные, статусы, kills/traps, пик памяти), по сущностям (entities=true).
  шаги сценариев:
    olife_spawn {spawns: [[code, owner, count, owners], ...], wait_entities?} — `spawn_scripted` миру через stdin
        (скрипт content/olife_world/sandbox/<code>.lua; count сущностей на каждого из owners владельцев с owner).
    olife_sandbox_check {controls, warmup_ticks, max_bad_control_rows, world_ms_p95_max, expect: [...], min_rows}
        — мир `olife.sandbox_dump` (export/sandbox_entities.json), строки по тактам export/sandbox_ticks.jsonl,
        `meters` сервиса, `hello` (жив), status мира; проверки: контрольные владельцы обновляются КАЖДЫЙ такт
        (moved == n и ok == n в каждой строке после прогрева), ожидания по сущностям-нарушителям (статусы,
        ошибка, текст, отказы мира, отброшенные действия, kills владельца), такт мира p95 <= порога, все живы.
  перф: `lab perf olife sandbox_load` — мир + шлюз + настоящая песочница + боты, 500 сущностей у 50 владельцев,
        мс/такт мира и сервиса, топливо/кредиты по владельцам -> perf_summary.json.
"""
import json
import os
import time

P = {}          # глобалы plugin.py (bind)


def bind(plugin_globals):
    P.update(plugin_globals)


# ---------------------------------------------------------------------------------------------- общее
def _stdin(lab, owner, lease, cmd, pattern, wait=3.0):
    r = lab.stdin(lease, cmd, owner=owner, wait=wait, pattern=pattern)
    return r


def _kv(line):
    return P["_kv"](line)


def world_status(lab, owner, world):
    r = _stdin(lab, owner, world, "status", r"status\stick=")
    lines = [x for x in r["lines"] if "status tick=" in x]
    if not lines:
        return {}
    line = lines[-1]
    d = _kv(line)
    # tick_ms avg=.. p95=.. max=.. — ключи без префикса в _kv: разобрать отдельно
    i = line.find("tick_ms ")
    if i >= 0:
        t = _kv(line[i + 8:].split(" phases_avg")[0])
        d["tick_ms"] = {k: t.get(k) for k in ("avg", "p95", "max")}
    j = line.find("sandbox=")
    if j >= 0:
        d["sandbox"] = line[j + 8:].split(" uptime=")[0]
    return d


def spawn(lab, owner, world, spawns, log=None):
    out = []
    for sp in spawns:
        code, o, count, owners = sp[0], int(sp[1]), int(sp[2]), int(sp[3]) if len(sp) > 3 else 1
        cmd = "spawn_scripted %s %d %d %d" % (code, o, count, owners)
        r = _stdin(lab, owner, world, cmd, r"spawn_scripted (queued|:)")
        line = next((x for x in r["lines"] if "spawn_scripted" in x), None)
        out.append({"cmd": cmd, "line": line, "ok": bool(line and "queued" in line)})
        if log:
            log("  %s -> %s" % (cmd, line))
    return out


def wait_entities(lab, owner, world, n, timeout=20.0):
    t0 = time.time()
    st = {}
    while time.time() - t0 < timeout:
        st = world_status(lab, owner, world)
        if int(st.get("entities") or 0) >= n:
            return True, st
        time.sleep(0.5)
    return False, st


def _read_json(path, tries=20):
    for _ in range(tries):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.2)
    return None


def collect(lab, owner, roles, call):
    """мир: dump + строки по тактам + status; песочница: hello + meters (с сущностями)."""
    world = roles["world"]
    wdir = lab.lease_info(world)["dir"]
    dump_path = os.path.join(wdir, "export", "sandbox_entities.json")
    try:
        os.remove(dump_path)
    except OSError:
        pass
    r = _stdin(lab, owner, world, "olife.sandbox_dump", r"sandbox_dump entities=")
    dump = _read_json(dump_path)
    rows = P["read_jsonl"](os.path.join(wdir, "export", "sandbox_ticks.jsonl"))
    ws = world_status(lab, owner, world)
    sb = roles.get("sandbox")
    alive, meters, err = False, None, None
    if sb:
        try:
            alive = bool(call(sb, "hello", {}))
            meters = call(sb, "meters", {"entities": True})
        except Exception as exc:
            err = "%s: %s" % (type(exc).__name__, exc)
    procs = {}
    for role, name in roles.items():
        p = lab.leases[name].proc if name in lab.leases else None
        procs[role] = p is not None and p.alive()
    return {"dump": dump, "dump_line": next((x for x in r["lines"] if "sandbox_dump" in x), None), "rows": rows,
            "world_status": ws, "sandbox_alive": alive, "meters": meters, "meters_error": err, "procs": procs}


# ---------------------------------------------------------------------------------------------- оценка
def _q(v, p):
    if not v:
        return None
    s = sorted(v)
    return s[min(len(s) - 1, int(p * (len(s) - 1) + 0.5))]


def world_ms_stats(rows, warm_from=None):
    v = [float(r["world_ms"]) for r in rows if r.get("world_ms") is not None and (warm_from is None or
                                                                                   (r.get("at") or 0) >= warm_from)]
    return P["stats"](v)


def sandbox_ms_stats(rows, warm_from=None):
    v = [float(r["wall_us"]) / 1000.0 for r in rows if r.get("wall_us") is not None and (warm_from is None or
                                                                                         (r.get("at") or 0) >= warm_from)]
    return P["stats"](v)


def control_rows(rows, controls, warm_from, warmup=0):
    """контрольный владелец обновляется каждый такт: moved == n и ok == n в каждой строке после прогрева
    (прогрев — от первой строки этого владельца: владельцы, созданные spawn_scripted, появляются позже)"""
    out = {}
    for c in controls:
        key = str(c)
        first = next(((r.get("at") or 0) for r in rows if key in (r.get("owners") or {})), None)
        start = max(warm_from, (first or 0) + warmup)
        n_rows, bad, examples = 0, 0, []
        for r in rows:
            if first is None or (r.get("at") or 0) < start:
                continue
            n_rows += 1
            o = (r.get("owners") or {}).get(key)
            good = bool(o) and o.get("moved") == o.get("n") and (o.get("st") or {}).get("ok") == o.get("n") and o["n"] > 0
            if not good:
                bad += 1
                if len(examples) < 5:
                    examples.append({"tick": r.get("tick"), "at": r.get("at"), "row": o})
        out[key] = {"rows": n_rows, "bad": bad, "examples": examples}
    return out


def _ents_of(dump, owner, script):
    return [e for e in (dump or {}).get("entities") or [] if e.get("owner") == owner and
            (script is None or e.get("script") == script)]


def check_expect(dump, meters, x):
    """одно ожидание по сущностям владельца owner со скриптом script -> {case, ok, why, seen...}"""
    ents = _ents_of(dump, int(x["owner"]), x.get("script"))
    res = {"case": x.get("case") or "%s/%s" % (x["owner"], x.get("script")), "owner": x["owner"],
           "script": x.get("script"), "entities": len(ents)}
    why = []
    if not ents:
        why.append("no entities")
    st, err, text, rej, drop, appl, moved = {}, None, None, 0, 0, 0, 0
    for e in ents:
        for k, v in (e.get("st") or {}).items():
            st[k] = st.get(k, 0) + v
        err = err or e.get("err")
        text = text or e.get("text")
        rej += e.get("rejected") or 0
        drop += e.get("dropped") or 0
        appl += e.get("applied") or 0
    res.update(statuses=st, error=err, text=(text or "")[:80], text_len=len(text or ""), rejected=rej, dropped=drop,
               applied=appl)
    om = next((o for o in (meters or {}).get("owners") or [] if o.get("owner") == int(x["owner"])), {})
    res["owner_kills"], res["owner_traps"] = om.get("kills"), om.get("traps")
    res["owner_fuel"], res["owner_credits"] = om.get("fuel"), om.get("credits")
    if x.get("status_any") and not any(st.get(s) for s in x["status_any"]):
        why.append("none of %s seen" % x["status_any"])
    for s in x.get("status_none") or []:
        if st.get(s):
            why.append("%s seen %d times" % (s, st[s]))
    if x.get("err_contains") and x["err_contains"] not in (err or ""):
        why.append("error %r lacks %r" % (err, x["err_contains"]))
    if x.get("text_prefix") and not (text or "").startswith(x["text_prefix"]):
        why.append("text %r lacks prefix %r" % ((text or "")[:60], x["text_prefix"]))
    if x.get("text_len_max") is not None and len(text or "") > int(x["text_len_max"]):
        why.append("text %d bytes > %d" % (len(text or ""), int(x["text_len_max"])))
    if x.get("min_rejected") is not None and rej < int(x["min_rejected"]):
        why.append("world rejected %d < %d" % (rej, int(x["min_rejected"])))
    if x.get("min_dropped") is not None and drop < int(x["min_dropped"]):
        why.append("service dropped %d < %d" % (drop, int(x["min_dropped"])))
    if x.get("min_applied") is not None and appl < int(x["min_applied"]):
        why.append("world applied %d < %d" % (appl, int(x["min_applied"])))
    if x.get("min_kills") is not None and (om.get("kills") or 0) < int(x["min_kills"]):
        why.append("owner kills %s < %d" % (om.get("kills"), int(x["min_kills"])))
    res["ok"] = not why
    res["why"] = "; ".join(why) or None
    return res


def owner_billing(meters, dump):
    """по владельцам: топливо и кредиты всего / на сущность-такт / на такт; сводка min/p50/max по владельцам"""
    per = []
    for o in (meters or {}).get("owners") or []:
        et = max(o.get("entity_ticks") or 0, 1)
        t = max(o.get("ticks") or 0, 1)
        per.append({"owner": o.get("owner"), "ticks": o.get("ticks"), "entity_ticks": o.get("entity_ticks"),
                    "fuel": o.get("fuel"), "credits": o.get("credits"), "api_credits": o.get("api_credits"),
                    "fuel_per_entity_tick": round((o.get("fuel") or 0) / et), "credits_per_tick": round(
                        (o.get("credits") or 0) / t, 2), "actions": o.get("actions"),
                    "dropped": o.get("actions_dropped"), "status": o.get("status"), "kills": o.get("kills"),
                    "mem_peak": o.get("mem_peak")})

    def dist(k):
        v = [x[k] for x in per if x.get(k) is not None]
        return {"min": min(v), "p50": _q(v, 0.5), "max": max(v), "sum": round(sum(v), 2)} if v else None
    return per, {"owners": len(per), "fuel_per_entity_tick": dist("fuel_per_entity_tick"),
                 "credits_per_tick": dist("credits_per_tick"), "fuel": dist("fuel"), "credits": dist("credits")}


def evaluate(data, spec):
    rows = data["rows"]
    dump = data["dump"] or {}
    meters = data["meters"] or {}
    first = min((r.get("at") or 0) for r in rows) if rows else 0
    warm_from = first + int(spec.get("warmup_ticks", 20))
    rep = {"rows": len(rows), "first_at": first, "warm_from": warm_from}
    bad = []
    if len(rows) < int(spec.get("min_rows", 60)):
        bad.append("only %d TickResult rows < %d" % (len(rows), int(spec.get("min_rows", 60))))
    ctl = control_rows(rows, spec.get("controls") or [], warm_from, int(spec.get("warmup_ticks", 20)))
    rep["controls"] = ctl
    for c, v in ctl.items():
        if v["rows"] == 0 or v["bad"] > int(spec.get("max_bad_control_rows", 0)):
            bad.append("control owner %s: %d of %d rows not fully updated" % (c, v["bad"], v["rows"]))
    exp = [check_expect(dump, meters, x) for x in spec.get("expect") or []]
    rep["expect"] = exp
    for x in exp:
        if not x["ok"]:
            bad.append("%s: %s" % (x["case"], x["why"]))
    rep["world_ms"] = world_ms_stats(rows, warm_from)
    rep["world_ms_all"] = world_ms_stats(rows)
    rep["sandbox_ms"] = sandbox_ms_stats(rows, warm_from)
    warm = [r for r in rows if (r.get("at") or 0) >= warm_from]
    names = ("incoming", "sandbox_apply", "world", "replication_and_input", "send")
    rep["phases_ms"] = {n: P["stats"]([float(r["ph"][i]) for r in warm if r.get("ph")]) for i, n in enumerate(names)}
    rep["input_ms"] = P["stats"]([float(r["in_ms"]) for r in warm if r.get("in_ms") is not None])
    rep["world_status"] = {k: data["world_status"].get(k) for k in ("tick", "tps", "entities", "sessions", "tick_ms",
                                                                  "sandbox")}
    lim = spec.get("world_ms_p95_max")
    if lim is not None and rep["world_ms"] and rep["world_ms"]["p95"] > float(lim):
        bad.append("world tick p95 %.2f ms > %.2f" % (rep["world_ms"]["p95"], float(lim)))
    if not data["sandbox_alive"]:
        bad.append("sandbox not alive: %s" % data.get("meters_error"))
    dead = [r for r, a in data["procs"].items() if not a]
    if dead:
        bad.append("processes dead: %s" % dead)
    if not str(data["world_status"].get("sandbox", "")).startswith("connected"):
        bad.append("world sandbox link: %s" % data["world_status"].get("sandbox"))
    # счётчики по владельцам/сущностям есть с обеих сторон
    w_ents = len(dump.get("entities") or [])
    s_ents = len(meters.get("entities") or [])
    w_owners = len(dump.get("owners") or {})
    s_owners = len(meters.get("owners") or [])
    rep["meters"] = {"world_entities": w_ents, "service_entities": s_ents, "world_owners": w_owners,
                     "service_owners": s_owners, "service_tick_ms": meters.get("tick_ms"),
                     "service_ticks": meters.get("ticks"), "world_results": dump.get("results"),
                     "world_rejected_by_reason": dump.get("rejected_by_reason"), "late": dump.get("late"),
                     "skipped": dump.get("skipped"), "load_errors": dump.get("load_errors")}
    if spec.get("min_entities") and (w_ents < int(spec["min_entities"]) or s_ents < int(spec["min_entities"])):
        bad.append("meters: world %d / service %d entities < %d" % (w_ents, s_ents, int(spec["min_entities"])))
    if spec.get("min_owners") and (w_owners < int(spec["min_owners"]) or s_owners < int(spec["min_owners"])):
        bad.append("meters: world %d / service %d owners < %d" % (w_owners, s_owners, int(spec["min_owners"])))
    per, summ = owner_billing(meters, dump)
    rep["billing"] = summ
    rep["billing_per_owner"] = per
    rep["ok"] = not bad
    rep["errors"] = bad
    return rep


def table_md(rep):
    out = ["| case | owner | statuses | error / text | world rej | dropped | kills | ok |", "|---|---|---|---|---|---|---|---|"]
    for x in rep.get("expect") or []:
        et = (x.get("error") or x.get("text") or "")[:50].replace("|", "/")
        out.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            x["case"], x["owner"], " ".join("%s:%d" % kv for kv in sorted((x.get("statuses") or {}).items())), et,
            x.get("rejected"), x.get("dropped"), x.get("owner_kills"), "PASS" if x["ok"] else "FAIL " + (x["why"] or "")))
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------- лаборатория
def f_meters(ctx, args):
    lease = args.get("lease") or P["session_leases"](ctx.lab, args["session"], ctx.owner)["sandbox"]
    a = {k: args[k] for k in ("owner", "entities") if k in args}
    return ctx.call(lease, "meters", a)


def st_spawn(sx, args, step):
    roles = P["_roles"](sx)
    res = spawn(sx.lab, sx.owner, roles["world"], args.get("spawns") or [], log=sx.log)
    bad = [r["cmd"] for r in res if not r["ok"]]
    want = args.get("wait_entities")
    st = None
    if want and not bad:
        ok, st = wait_entities(sx.lab, sx.owner, roles["world"], int(want), float(args.get("timeout", 20)))
        if not ok:
            bad.append("world has %s entities < %s" % (st.get("entities"), want))
    return {"ok": not bad, "result": {"spawned": res, "entities": (st or {}).get("entities")},
            "error": "; ".join(bad) or None}


def st_check(sx, args, step):
    roles = P["_roles"](sx)
    data = collect(sx.lab, sx.owner, roles, lambda l, c, a: sx.call(c, a, lease=l))
    rep = evaluate(data, args)
    rep["table_md"] = table_md(rep)
    with open(os.path.join(sx.out_dir(), "olife_sandbox.json"), "w", encoding="utf-8") as f:
        json.dump(dict(rep, dump=data["dump"], service_meters=data["meters"]), f, ensure_ascii=False, indent=1, default=str)
    with open(os.path.join(sx.out_dir(), "olife_sandbox_rows.jsonl"), "w", encoding="utf-8") as f:
        for r in data["rows"]:
            f.write(json.dumps(r) + "\n")
    summary = {k: rep[k] for k in ("rows", "world_ms", "world_ms_all", "sandbox_ms", "phases_ms", "input_ms",
                                   "world_status", "meters", "billing")}
    summary["controls"] = {c: {"rows": v["rows"], "bad": v["bad"]} for c, v in rep["controls"].items()}
    summary["expect"] = [{k: x.get(k) for k in ("case", "owner", "ok", "statuses", "why", "error", "text",
                                                 "rejected", "dropped", "owner_kills")} for x in rep["expect"]]
    sx.data.setdefault("metrics", {})["sandbox"] = summary
    return {"ok": rep["ok"], "result": summary, "error": "; ".join(rep["errors"]) or None}


# ---------------------------------------------------------------------------------------------- перф
LOAD_DEFAULT = {"clients": 2, "client_kind": "bot", "sandbox": True, "scripted": 0, "spawn": [["typical", 1, 10, 50]],
                "entities": 500, "seconds": 30, "warmup_ticks": 60}


def perf_sandbox_load(px, a):
    """500 скриптовых сущностей (typical) у 50 владельцев + 2 бота: мс/такт мира и сервиса, топливо/кредиты."""
    args = dict(LOAD_DEFAULT, **{k: v for k, v in (a or {}).items() if k != "tag"})
    lab = px.lab

    def mk(kind, role, params):
        return px.lease(kind, params=dict(params))
    s = P["build_session"](mk, lab.lease_info, args, log=px.progress)
    roles = dict(s["leases"])
    px.progress("session %s: %s" % (s["session"], roles))
    sp = spawn(lab, px.owner, roles["world"], args["spawn"], log=px.progress)
    ok, st = wait_entities(lab, px.owner, roles["world"], int(args["entities"]), 30)
    px.progress("entities: %s (%s)" % (st.get("entities"), "ok" if ok else "NOT REACHED"))
    prof_from = st.get("tick")             # волна 5p: окно профиля такта (prof=1 в world_opts) — после спавна
    t0 = time.time()
    while time.time() - t0 < float(args["seconds"]) and not px.cancelled():
        time.sleep(1.0)
        dead = [r for r, n in roles.items() if lab.leases[n].proc is None or not lab.leases[n].proc.alive()]
        if dead:
            px.progress("DEAD: %s" % dead)
            break
    prof = None
    if "prof=1" in str(args.get("world_opts") or ""):      # волна 5p: профиль такта мира (olife_w5p.py)
        try:
            prof = P["_w5p"]().collect(lab, px.owner, roles["world"], px.out_dir, prof_from,
                                       int(args["warmup_ticks"]), "")
        except Exception as e:
            prof = {"error": "%s: %s" % (type(e).__name__, e)}
    data = collect(lab, px.owner, roles, lambda l, c, ar: lab.f2f(l, c, ar, owner=px.owner).get("result"))
    rep = evaluate(data, {"warmup_ticks": int(args["warmup_ticks"]), "min_rows": 200,
                          "min_entities": int(args["entities"]), "min_owners": 50})
    gm = None
    try:
        gm = lab.f2f(roles["gateway"], "metrics", {}, owner=px.owner).get("result")
    except Exception:
        pass
    summary = {"ok": rep["ok"] and ok, "errors": rep["errors"], "session": s["session"], "start_s": s["timing"],
               "spawn": sp, "entities": st.get("entities"), "seconds": args["seconds"],
               "world_ms": rep["world_ms"], "world_ms_all": rep["world_ms_all"], "sandbox_ms": rep["sandbox_ms"],
               "phases_ms": rep["phases_ms"], "input_ms": rep["input_ms"],
               "world_status": rep["world_status"], "meters": rep["meters"], "billing": rep["billing"],
               "billing_per_owner": rep["billing_per_owner"],
               "gateway_total": (gm or {}).get("total"), "rows": rep["rows"],
               "world_opts": args.get("world_opts"), "prof": prof}
    path = os.path.join(px.out_dir, "perf_summary.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1, default=str)
    with open(os.path.join(px.out_dir, "olife_sandbox_rows.jsonl"), "w", encoding="utf-8") as f:
        for r in data["rows"]:
            f.write(json.dumps(r) + "\n")
    px.progress("world ms %s | sandbox ms %s | billing %s" % (rep["world_ms"], rep["sandbox_ms"], rep["billing"]))
    return {"ok": summary["ok"], "summary_json": path, "world_ms": rep["world_ms"], "sandbox_ms": rep["sandbox_ms"],
            "entities": st.get("entities"), "errors": rep["errors"]}


def steps():
    return {"olife_spawn": st_spawn, "olife_sandbox_check": st_check}


def register(api):
    api.feature("sandbox_meters", f_meters, "real olife-sandboxd meters (control port `meters`): service tick ms, "
                "per owner fuel/credits/actions/statuses/kills, per entity with entities=true {session|lease, owner?, "
                "entities?}", {"type": "object", "properties": {"session": {"type": "string"},
                                                                 "lease": {"type": "string"},
                                                                 "owner": {"type": "integer"},
                                                                 "entities": {"type": "boolean"}}})
    api.perf("sandbox_load", perf_sandbox_load, "500 scripted entities (typical) of 50 owners on the real "
             "olife-sandboxd + world + gateway + 2 bots: world/sandbox ms per tick, fuel/credits per owner")


def selftest():
    rows = [{"tick": t, "at": t + 1, "wall_us": 1000, "world_ms": 1.0,
             "owners": {"1": {"n": 2, "moved": 2, "st": {"ok": 2}}, "9": {"n": 1, "moved": 0, "st": {"throttled": 1}}}}
            for t in range(1, 101)]
    rows[50]["owners"]["1"]["moved"] = 1
    c = control_rows(rows, [1], 10)
    assert c["1"]["bad"] == 1 and c["1"]["rows"] == 92, c
    dump = {"entities": [{"eid": 5, "owner": 9, "script": "neg_loop", "st": {"throttled": 100}, "rejected": 0}]}
    x = check_expect(dump, {"owners": [{"owner": 9, "kills": 0}]}, {"owner": 9, "script": "neg_loop",
                                                                     "status_any": ["throttled"], "status_none": ["ok"]})
    assert x["ok"], x
    x = check_expect(dump, {}, {"owner": 9, "script": "neg_loop", "status_any": ["killed"]})
    assert not x["ok"], x
