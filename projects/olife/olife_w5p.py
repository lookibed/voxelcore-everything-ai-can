"""olife, волна 5p (02.10, агент olife_w5p): профиль такта мира. Подключается из plugin.py (`_w5p()`).

Мир с `--opts prof=1[,jitlog=1]` пишет на каждый такт строку `export\\world_prof.csv` (фазы и подшаги такта, события,
GC, время движка между тактами; content/olife_world/modules/prof.lua) и сводку трасс LuaJIT `export\\world_jit.txt`
(команда `olife.jit`). Шаги:
  olife_prof_mark            — запомнить текущий такт мира (начало окна сводки, после прогрева/спавна)
  olife_prof {tag?, warmup_ticks?} — `olife.jit`, копия CSV/сводки трасс в прогон, prof_summary.json + prof_table.md
Перф `sandbox_load` (sandbox_real.py) зовёт collect() сам, если мир шёл с prof=1.
Анализ без лаборатории: python3 olife_w5p.py <world_prof.csv> [from_tick]."""
import csv
import json
import os
import sys
import time

P = {}          # глобалы plugin.py (bind)


def bind(plugin_globals):
    P.update(plugin_globals)


def _pct(v, q):
    if not v:
        return None
    v = sorted(v)
    i = min(len(v) - 1, max(0, int(round(q * (len(v) - 1)))))
    return v[i]


def stats(v):
    if not v:
        return None
    return {"n": len(v), "mean": round(sum(v) / len(v), 4), "p50": round(_pct(v, 0.5), 4),
            "p95": round(_pct(v, 0.95), 4), "p99": round(_pct(v, 0.99), 4), "max": round(max(v), 4)}


def read_csv(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        rows = []
        for r in csv.DictReader(f):
            if None in r.values() or None in r:
                continue                   # недописанная строка (файл читается, пока мир пишет)
            try:
                rows.append({k: float(v) for k, v in r.items() if v not in (None, "")})
            except ValueError:
                pass                       # недописанная последняя строка (процесс убит посреди записи)
        return rows


TIME_COLS_SKIP = ("tick", "t_ms", "kb_start", "kb_end", "kb_freed_between")


def analyse(rows, from_tick=None, warmup_ticks=0):
    if from_tick is None:
        from_tick = rows[0]["tick"] if rows else 0
    w = [r for r in rows if r["tick"] >= from_tick + warmup_ticks]
    if not w:
        return {"rows": 0}
    cols = [c for c in w[0].keys() if c not in ("tick",)]
    out = {"rows": len(w), "from_tick": from_tick + warmup_ticks, "to_tick": w[-1]["tick"],
           "cols": {c: stats([r[c] for r in w if c in r]) for c in cols}}
    # аллокации и GC: прирост кучи за такт (без сборки внутри такта), такты со сборкой внутри и между
    alloc = [r["kb_end"] - r["kb_start"] for r in w]
    out["alloc_kb_per_tick"] = stats([a for a in alloc if a >= 0])
    out["gc_in_tick"] = sum(1 for a in alloc if a < 0)
    out["gc_between_ticks"] = sum(1 for r in w if r.get("kb_freed_between", 0) > 0)
    out["heap_kb"] = stats([r["kb_end"] for r in w])
    # всплески: такты дороже p95 — какие колонки дают избыток против медианного такта, какие события с ними
    tm = [r["tick_ms"] for r in w]
    p95 = _pct(tm, 0.95)
    med = {c: _pct([r[c] for r in w if c in r], 0.5) for c in cols}
    spikes = [r for r in w if r["tick_ms"] >= p95]
    normal = [r for r in w if r["tick_ms"] < p95]
    out["alloc_kb_by_phase"] = {c: stats([r[c] for r in w if r.get(c, -1) >= 0]) for c in cols if c.startswith("kb_")
                                and c not in ("kb_start", "kb_end", "kb_freed_between")}
    tcols = [c for c in cols if c not in TIME_COLS_SKIP and not c.startswith("tr_") and not c.startswith("kb_") and c not in
             ("frames", "chunks", "keyframes", "results", "late", "skipped", "sessions", "entities", "sb_results")]

    def excess(group):
        ex = {}
        for c in tcols:
            if c in ("tick_ms", "ph_in", "ph_sb", "ph_world", "ph_repl", "ph_send", "post", "gap"):
                continue
            ex[c] = round(sum(r.get(c, 0) for r in group) / max(1, len(group)) - (med.get(c) or 0), 3)
        return dict(sorted(ex.items(), key=lambda kv: -kv[1])[:8])

    def ev(group):
        n = max(1, len(group))
        return {"n": len(group),
                "tick_ms_mean": round(sum(r["tick_ms"] for r in group) / n, 3),
                "gc_in_tick": round(sum(1 for r in group if r["kb_end"] < r["kb_start"]) / n, 3),
                "gc_between": round(sum(1 for r in group if r.get("kb_freed_between", 0) > 0) / n, 3),
                "keyframe": round(sum(1 for r in group if r.get("keyframes", 0) > 0) / n, 3),
                "chunks": round(sum(1 for r in group if r.get("chunks", 0) > 0) / n, 3),
                "results_0": round(sum(1 for r in group if r.get("results", 0) == 0) / n, 3),
                "results_2plus": round(sum(1 for r in group if r.get("results", 0) >= 2) / n, 3),
                "late": round(sum(1 for r in group if r.get("late", 0) > 0) / n, 3),
                "trace_events": round(sum(1 for r in group if r.get("tr_start", 0) + r.get("tr_abort", 0) > 0) / n, 3),
                "alloc_kb_mean": round(sum(max(0, r["kb_end"] - r["kb_start"]) for r in group) / n, 1)}
    out["spikes"] = {"threshold_ms": p95, "spike": ev(spikes), "normal": ev(normal), "excess_ms": excess(spikes)}
    top = sorted(w, key=lambda r: -r["tick_ms"])[:10]
    out["top_ticks"] = []
    for r in top:
        ex = {c: round(r.get(c, 0) - (med.get(c) or 0), 2) for c in tcols
              if c not in ("tick_ms", "ph_in", "ph_sb", "ph_world", "ph_repl", "ph_send", "post", "gap")}
        out["top_ticks"].append({"tick": int(r["tick"]), "tick_ms": r["tick_ms"],
                                 "top": dict(sorted(ex.items(), key=lambda kv: -kv[1])[:4]),
                                 "kb": [r["kb_start"], r["kb_end"]], "freed_before": r.get("kb_freed_between"),
                                 "keyframes": r.get("keyframes"), "chunks": r.get("chunks"),
                                 "results": r.get("results"), "tr": [r.get("tr_start"), r.get("tr_stop"),
                                                                     r.get("tr_abort"), r.get("tr_flush")]})
    tr = {k: sum(r.get(k, 0) for r in w) for k in ("tr_start", "tr_stop", "tr_abort", "tr_flush")}
    out["trace_events_window"] = tr
    return out


ORDER = ["tick_ms", "ph_in", "in_recv", "h_move", "h_block", "h_inv", "h_other", "admin",
         "ph_sb", "sb_recv", "sb_decode", "sb_conv", "sb_apply",
         "ph_world", "w_ents", "w_move", "w_inv", "w_rehash", "w_editor",
         "ph_repl", "r_blocks", "r_terms", "r_interest", "r_snap", "r_full", "r_editor", "r_move", "r_inv", "r_sync",
         "si_index", "si_list", "si_view", "si_events", "si_encode",
         "ph_send", "s_net", "s_sb", "post", "post_states", "post_rows", "post_sup", "gap"]
KB_ORDER = ["kb_in", "kb_sb", "kb_world", "kb_repl", "kb_si", "kb_send", "kb_post"]


def table_md(summ, title=""):
    c = summ.get("cols") or {}
    out = ["%s (тактов %s, %s..%s)" % (title, summ.get("rows"), summ.get("from_tick"), summ.get("to_tick")), "",
           "| колонка | mean | p50 | p95 | p99 | max |", "|---|---|---|---|---|---|"]
    for k in ORDER:
        s = c.get(k)
        if s:
            out.append("| %s | %.3f | %.3f | %.3f | %.3f | %.3f |" % (k, s["mean"], s["p50"], s["p95"], s["p99"], s["max"]))
    ak = summ.get("alloc_kb_by_phase") or {}
    if ak:
        out += ["", "| рост кучи, КБ (такты без сборки внутри фазы) | n | p50 | p95 | max |", "|---|---|---|---|---|"]
        for k in KB_ORDER:
            x = ak.get(k)
            if x:
                out.append("| %s | %d | %.0f | %.0f | %.0f |" % (k, x["n"], x["p50"], x["p95"], x["max"]))
    return "\n".join(out)


def collect(lab, owner, world_lease, out_dir, from_tick=None, warmup_ticks=0, tag=""):
    """olife.jit (если включён jitlog) -> копия export\\world_prof.csv, world_jit.txt -> сводка в out_dir."""
    import shutil
    info = lab.lease_info(world_lease)
    ex = os.path.join(info["dir"], "export")
    res = {"tag": tag}
    try:
        r = lab.stdin(world_lease, "olife.jit", owner=owner, wait=3.0, pattern=r"jit\sstatus")
        res["jit_line"] = [x for x in r["lines"] if "jit status" in x][-1:] or None
    except Exception as e:                     # мир без нового модуля / без stdin — сводка всё равно по CSV
        res["jit_error"] = str(e)
    time.sleep(0.3)
    sfx = ("_" + tag) if tag else ""
    for name in ("world_prof.csv", "world_jit.txt"):
        src = os.path.join(ex, name)
        if os.path.exists(src):
            base, ext = os.path.splitext(name)
            shutil.copyfile(src, os.path.join(out_dir, base + sfx + ext))
    src = os.path.join(ex, "world_prof.csv")
    if not os.path.exists(src):
        res["error"] = "no world_prof.csv (world without --opts prof=1?)"
        return res
    rows = read_csv(src)
    summ = analyse(rows, from_tick, warmup_ticks)
    summ["jit_line"] = res.get("jit_line")
    with open(os.path.join(out_dir, "prof_summary%s.json" % sfx), "w", encoding="utf-8") as f:
        json.dump(summ, f, ensure_ascii=False, indent=1)
    with open(os.path.join(out_dir, "prof_table%s.md" % sfx), "w", encoding="utf-8") as f:
        f.write(table_md(summ, tag or "world tick") + "\n")
    res.update({"rows": summ.get("rows"), "tick_ms": (summ.get("cols") or {}).get("tick_ms"),
                "spikes": summ.get("spikes"), "trace_events_window": summ.get("trace_events_window")})
    return res


def _world_tick(sx):
    lease = P["_roles"](sx)["world"]
    r = sx.lab.stdin(lease, "status", owner=sx.owner, wait=3.0, pattern=r"status\stick=")
    for x in reversed(r["lines"]):
        if "status tick=" in x:
            return P["_kv"](x).get("tick")
    return None


def st_prof_mark(sx, args, step):
    t = _world_tick(sx)
    sx.data["prof_from_tick"] = t
    return {"ok": t is not None, "result": {"from_tick": t}, "error": None if t is not None else "no world status"}


def st_prof(sx, args, step):
    lease = P["_roles"](sx)["world"]
    res = collect(sx.lab, sx.owner, lease, sx.out_dir(), sx.data.get("prof_from_tick"),
                  int(args.get("warmup_ticks", 0)), args.get("tag", ""))
    sx.data.setdefault("metrics", {})["prof"] = {k: res.get(k) for k in ("rows", "tick_ms", "trace_events_window",
                                                                          "jit_line")}
    return {"ok": "error" not in res, "result": res, "error": res.get("error")}


def steps():
    return {"olife_prof_mark": st_prof_mark, "olife_prof": st_prof}


if __name__ == "__main__":
    rows = read_csv(sys.argv[1])
    ft = float(sys.argv[2]) if len(sys.argv) > 2 else None
    s = analyse(rows, ft)
    print(table_md(s, os.path.basename(sys.argv[1])))
    print(json.dumps({k: s.get(k) for k in ("alloc_kb_per_tick", "alloc_kb_by_phase", "gc_in_tick", "gc_between_ticks", "heap_kb", "spikes",
                                        "trace_events_window")}, ensure_ascii=False, indent=1))
