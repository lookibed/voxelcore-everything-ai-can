"""История прогонов в SQLite: `<data>\\history.sqlite` (по умолчанию VC_ROOT\\artifacts\\lab\\history.sqlite).

Единственный писатель — демон labd (Windows-Python): SQLite через /mnt/d из WSL небезопасен (блокировки DrvFs/9P —
microsoft/WSL#2395), поэтому WSL ходит только через демон (`lab history`, MCP `lab_history`, `/call/core.history*`).

Таблицы:
  runs(id, ts, project, scenario, impl, kind, tag, size, exe_sha, golden_id, contended, host_load, verdict, dir,
       source, ingested, extra)
  shots(run, name, sha, identical_pct, tol_pct, coverage, max_delta, golden, heat_png, diff_png)
  series(run, tick, pct, state_equal)
  perf(run, metric, value)
  gates(id, ts, project, suite, mode, verdict, regressions, report_json, report_md, summary)
  ratchet(project, scenario, frame, best_pct, sha, run, accepted_ts, note)      — только явным `lab gate accept`

Импорт как есть (адаптеры, все терпимы к отсутствующим полям):
  * старые раннеры первого проекта паритета: `<run>\\<scenario>\\report.json` (impl, compare[], shots[]) — слои/u_*/alpha_spawn;
  * E2E: `<run>\\<scenario>\\run.json` + `vs_golden\\compare.json` (keyframes, states) — серия по тактам;
  * перф: `<run>\\perf_summary.json` (fps по окнам 1 с/5 с, кадры > 33 мс...);
  * сессия пользователя: `status_lines.txt` / `play_report.json` (lab play);
  * прогоны лаборатории: `<run>\\report.json` с id/project (этап 1: снимки с sha256) и единый report.json этапа 2а
    (shots с identical_pct, series/keyframes, states, timings, golden) — какие поля есть, те и берутся.
"""
import glob
import json
import os
import re
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs(
  id TEXT PRIMARY KEY, ts REAL, project TEXT, scenario TEXT, impl TEXT, kind TEXT, tag TEXT, size TEXT,
  exe_sha TEXT, golden_id TEXT, contended INTEGER, host_load TEXT, verdict TEXT, dir TEXT, source TEXT,
  ingested REAL, extra TEXT, engine_version TEXT);
CREATE INDEX IF NOT EXISTS runs_ps ON runs(project, scenario, ts);
CREATE TABLE IF NOT EXISTS shots(
  run TEXT, name TEXT, sha TEXT, identical_pct REAL, tol_pct REAL, coverage REAL, max_delta REAL, golden TEXT,
  heat_png TEXT, diff_png TEXT, PRIMARY KEY(run, name));
CREATE TABLE IF NOT EXISTS series(
  run TEXT, tick INTEGER, pct REAL, state_equal INTEGER, PRIMARY KEY(run, tick));
CREATE TABLE IF NOT EXISTS perf(
  run TEXT, metric TEXT, value REAL, PRIMARY KEY(run, metric));
CREATE TABLE IF NOT EXISTS gates(
  id TEXT PRIMARY KEY, ts REAL, project TEXT, suite TEXT, mode TEXT, verdict TEXT, regressions INTEGER,
  report_json TEXT, report_md TEXT, summary TEXT);
CREATE TABLE IF NOT EXISTS ratchet(
  project TEXT, scenario TEXT, frame TEXT, best_pct REAL, sha TEXT, run TEXT, accepted_ts REAL, note TEXT,
  PRIMARY KEY(project, scenario, frame));
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
"""
SCHEMA_VERSION = "2"
RUN_COLS = ("id", "ts", "project", "scenario", "impl", "kind", "tag", "size", "exe_sha", "golden_id", "contended",
            "host_load", "verdict", "dir", "source", "ingested", "extra", "engine_version")
# этап 4: версия движка — измерение. Записи до этапа 4 (и адаптеры старых раннеров) версии не знают: это 0.31.
DEFAULT_ENGINE_VERSION = "0.31"


def engine_of(r):
    """Версия движка записи истории (None -> 0.31: всё, что записано до этапа 4, шло на 0.31)."""
    v = r.get("engine_version") if isinstance(r, dict) else None
    return str(v) if v else DEFAULT_ENGINE_VERSION


def _engine_from_exe(exe, report=None):
    vers = set()
    if isinstance(exe, dict):
        if exe.get("engine_version"):
            vers.add(str(exe["engine_version"]))
        for v in exe.values():
            if isinstance(v, dict) and v.get("engine_version"):
                vers.add(str(v["engine_version"]))
    if isinstance(report, dict) and report.get("engine_version"):
        vers.add(str(report["engine_version"]))
    return ",".join(sorted(vers)) or None

STAMP_RX = re.compile(r"^(\d{8})_(\d{4,6})")


def stamp_ts(name):
    """'20261001_021611_perf_parity2' -> epoch (местное время); None, если имени без метки."""
    m = STAMP_RX.match(os.path.basename(str(name)))
    if not m:
        return None
    hms = (m.group(2) + "00")[:6]
    try:
        return time.mktime(time.strptime(m.group(1) + hms, "%Y%m%d%H%M%S"))
    except ValueError:
        return None


def _json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _num(v):
    try:
        return None if v is None else float(v)
    except (TypeError, ValueError):
        return None


def _flat(prefix, d, out, depth=2):
    """{'fps_5s': {'min': 1}} -> {'fps_5s.min': 1} (только числа)."""
    for k, v in (d or {}).items():
        key = "%s.%s" % (prefix, k) if prefix else str(k)
        if isinstance(v, bool):
            continue
        if isinstance(v, (int, float)):
            out[key] = float(v)
        elif isinstance(v, dict) and depth > 0:
            _flat(key, v, out, depth - 1)
    return out


def _bool(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, dict):        # состояние по полям (player, inventory, ...) -> все равны?
        vals = [x for k, x in v.items() if isinstance(x, bool)]
        return int(all(vals)) if vals else None
    return int(bool(v))


def _size_of(items):
    for c in items or []:
        if isinstance(c, dict) and c.get("w") and c.get("h"):
            return "%sx%s" % (c["w"], c["h"])
    return None


# ------------------------------------------------------------------------------------------------ адаптеры
def rec_layer(report, path, project, outer=None):
    """Старый report.json сценария (run_vc_scenario/run_u/am_layers): compare[] + shots[]."""
    outer = outer or os.path.basename(os.path.dirname(os.path.dirname(path)))
    scen = report.get("scenario") or os.path.basename(os.path.dirname(path))
    impl = report.get("impl") or "?"
    sha = {s.get("name"): s.get("sha256") for s in report.get("shots") or [] if isinstance(s, dict)}
    shots = []
    seen = set()
    golden_dirs = set()
    for c in report.get("compare") or []:
        if not isinstance(c, dict):
            continue
        name = c.get("name") or os.path.splitext(os.path.basename(str(c.get("a") or "")))[0]
        if not name or name in seen:
            continue
        seen.add(name)
        if c.get("b"):
            golden_dirs.add(os.path.dirname(str(c["b"])))
        shots.append({"name": name, "sha": sha.get(name), "identical_pct": _num(c.get("identical_pct")),
                      "tol_pct": _num(c.get("within_tol_pct")), "coverage": _num(c.get("coverage_a_pct")),
                      "max_delta": _num(c.get("max_delta")), "golden": c.get("b"),
                      "heat_png": c.get("heat_png"), "diff_png": c.get("diff_png") or c.get("diff_image")})
    for n, h in sha.items():
        if n not in seen:
            shots.append({"name": n, "sha": h})
    perf = {}
    if _num(report.get("dur")) is not None:
        perf["dur_s"] = _num(report["dur"])
    _flat("timing", report.get("timing") or {}, perf, 0)
    golden = report.get("golden")
    kind = "golden" if golden is True else "layers"
    if scen.startswith("e2e"):
        kind = "e2e"
    ts = stamp_ts(outer) or stamp_ts(report.get("started") or "") or os.path.getmtime(path)
    return {"id": "%s/%s" % (outer, scen), "ts": ts, "project": project, "scenario": scen, "impl": impl,
            "kind": kind, "tag": outer[16:] if stamp_ts(outer) else outer,
            "size": _size_of(report.get("compare")), "exe_sha": None,
            "golden_id": ("legacy:" + _win_slash(sorted(golden_dirs)[0])) if golden_dirs else None,
            "verdict": "ok" if report.get("ok") else ("fail" if report.get("ok") is False else None),
            "dir": os.path.dirname(path), "source": "legacy-report", "shots": shots, "series": [], "perf": perf,
            "extra": {k: report.get(k) for k in ("window", "world", "session", "golden") if k in report}}


def _win_slash(p):
    """/mnt/<диск>/x -> <ДИСК>:/x (раньше — только диск D, зашитый в коде)."""
    m = re.match(r"^/mnt/([a-zA-Z])/(.*)$", p) if isinstance(p, str) else None
    return "%s:/%s" % (m.group(1).upper(), m.group(2)) if m else p


def rec_e2e(run, path, project, outer=None):
    """E2E: run.json (+ vs_golden/compare.json): серия identical_pct по тактам ключевых кадров, равенство состояния."""
    d = os.path.dirname(path)
    outer = outer or os.path.basename(os.path.dirname(d))
    scen = run.get("scenario") or os.path.basename(d)
    cmp_ = _json(os.path.join(d, "vs_golden", "compare.json")) or {}
    ticks = {}
    for k in cmp_.get("keyframes") or []:
        t = k.get("tick")
        if t is not None:
            ticks[int(t)] = {"tick": int(t), "pct": _num(k.get("identical_pct")), "state_equal": None}
    for s in cmp_.get("states") or []:
        t = s.get("tick")
        if t is None:
            continue
        eq = _bool({k: v for k, v in s.items() if isinstance(v, bool)})
        ticks.setdefault(int(t), {"tick": int(t), "pct": None, "state_equal": None})["state_equal"] = eq
    summ = cmp_.get("summary") or {}
    perf = {}
    _flat("timing", run.get("timing") or {}, perf, 0)
    for k in ("min_identical_pct", "mean_identical_pct", "keyframes_100", "first_divergence_tick"):
        if _num(summ.get(k)) is not None:
            perf["e2e." + k] = _num(summ[k])
    shots = []
    for s in run.get("shots") or []:
        if isinstance(s, dict) and s.get("name"):
            shots.append({"name": s["name"], "sha": s.get("sha256")})
    ts = stamp_ts(outer) or stamp_ts(run.get("started") or "") or os.path.getmtime(path)
    return {"id": "%s/%s" % (outer, scen), "ts": ts, "project": project, "scenario": scen,
            "impl": run.get("impl") or "?", "kind": "e2e", "tag": outer[16:] if stamp_ts(outer) else outer,
            "size": run.get("size"), "exe_sha": (run.get("exe") or {}).get("sha256") if isinstance(run.get("exe"),
                                                                                                     dict) else None,
            "golden_id": ("legacy:" + str(summ["a"])) if summ.get("a") else None,
            "verdict": None if not cmp_ else ("ok" if summ.get("first_divergence_outside_reference_noise") is None
                                              else "diverged"),
            "dir": d, "source": "legacy-e2e", "shots": shots, "series": sorted(ticks.values(), key=lambda x: x["tick"]),
            "perf": perf, "extra": {"world": run.get("world"), "golden_run": bool(run.get("golden")),
                                    "first_divergence_tick": summ.get("first_divergence_tick"),
                                    "drift_png": summ.get("drift_png")}}


PERF_METRICS = ("frames", "duration_s", "fps_avg", "slow_frames", "fps_5s", "fps_1s", "fps_frame", "frame_ms",
                "lua_ms", "pack_plus_world_ms")


def rec_perf(summary, path, project):
    d = os.path.dirname(path)
    name = os.path.basename(d)
    meta = summary.get("meta") or {}
    rest = name[16:] if stamp_ts(name) else name
    m = re.match(r"^(perf_[a-z0-9]+)_?(.*)$", rest)
    scen, tag = (m.group(1), m.group(2)) if m else (rest, "")
    if meta.get("scenario"):                      # lab perf (этап 3а) пишет сценарий и тег явно
        scen, tag = meta["scenario"], meta.get("tag") or ""
    perf = {}
    for phase in ("all", "walk"):
        ph = summary.get(phase) or {}
        for k in PERF_METRICS:
            if k in ph:
                if isinstance(ph[k], dict):
                    _flat("%s.%s" % (phase, k), ph[k], perf, 0)
                elif _num(ph[k]) is not None:
                    perf["%s.%s" % (phase, k)] = _num(ph[k])
    load = summary.get("host_load") or summary.get("sysload")
    return {"id": name, "ts": stamp_ts(name) or os.path.getmtime(path), "project": project, "scenario": scen,
            "impl": "vc", "kind": "perf", "tag": tag, "size": None, "exe_sha": None, "golden_id": None,
            "contended": _bool(load.get("contended")) if isinstance(load, dict) else None, "host_load": load,
            "verdict": None, "dir": d, "source": "legacy-perf", "shots": [], "series": [], "perf": perf,
            "extra": {"mode": meta.get("mode"), "note": meta.get("note"),
                      "experimental": tag.startswith(("exp_", "probe")) or "probe" in tag}}


def rec_lab(report, path, project=None):
    """report.json прогона лаборатории (этап 1) или единый отчёт этапа 2а. Терпим к любым отсутствующим полям."""
    d = os.path.dirname(path)
    shots = []
    for s in report.get("shots") or []:
        if not isinstance(s, dict):
            continue
        cmpd = s.get("compare") if isinstance(s.get("compare"), dict) else {}
        g = s.get("golden") if isinstance(s.get("golden"), dict) else {}
        shots.append({
            "name": s.get("name") or os.path.splitext(os.path.basename(str(s.get("path") or "")))[0],
            "sha": s.get("sha256") or s.get("sha"),
            "identical_pct": _num(s.get("identical_pct", cmpd.get("identical_pct"))),
            "tol_pct": _num(s.get("tol_pct", s.get("within_tol_pct", cmpd.get("within_tol_pct")))),
            "coverage": _num(s.get("coverage", s.get("coverage_pct", cmpd.get("coverage_a_pct")))),
            "max_delta": _num(s.get("max_delta", cmpd.get("max_delta"))),
            "golden": s.get("golden_path") or g.get("path") or (s.get("golden") if isinstance(s.get("golden"), str)
                                                                 else None),
            "heat_png": s.get("heat_png") or s.get("heat") or cmpd.get("heat_png"),
            "diff_png": s.get("diff_png") or s.get("diff") or cmpd.get("diff_png")})
    series = []
    raw_series = report.get("series") or report.get("keyframes") or []
    if isinstance(raw_series, dict):
        raw_series = raw_series.get("keyframes") or raw_series.get("points") or []
    by_tick = {}
    for k in raw_series:
        if not isinstance(k, dict) or k.get("tick") is None:
            continue
        by_tick[int(k["tick"])] = {"tick": int(k["tick"]),
                                   "pct": _num(k.get("pct", k.get("identical_pct"))),
                                   "state_equal": _bool(k.get("state_equal", k.get("state")))}
    for s in report.get("states") or []:
        if isinstance(s, dict) and s.get("tick") is not None:
            e = by_tick.setdefault(int(s["tick"]), {"tick": int(s["tick"]), "pct": None, "state_equal": None})
            if e["state_equal"] is None:
                e["state_equal"] = _bool(s.get("equal", {k: v for k, v in s.items() if isinstance(v, bool)}))
    series = sorted(by_tick.values(), key=lambda x: x["tick"])
    perf = {}
    _flat("timing", report.get("timings") or report.get("timing") or {}, perf, 1)
    if isinstance(report.get("perf"), dict):
        _flat("", report["perf"], perf, 2)
    meta = report.get("meta") or {}
    exe = meta.get("exe") or report.get("exe") or {}
    exe_sha = None
    if isinstance(exe, dict):
        if exe.get("sha256"):
            exe_sha = exe["sha256"]
        else:
            shas = sorted({v.get("sha256") for v in exe.values() if isinstance(v, dict) and v.get("sha256")})
            exe_sha = ",".join(shas) or None
    g = report.get("golden")
    golden_id = (g.get("id") or g.get("manifest") or g.get("name")) if isinstance(g, dict) else (
        g if isinstance(g, str) else report.get("golden_id"))
    load = report.get("host_load") or report.get("sysload") or meta.get("host_load")
    v = report.get("verdict")
    if isinstance(v, dict):
        v = v.get("verdict") or v.get("status")
    scen = report.get("scenario") or os.path.basename(d)
    impl = report.get("impl") or meta.get("impl") or ("vc" if shots else None)
    kind = report.get("kind") or ("e2e" if series else ("layers" if any(s["identical_pct"] is not None
                                                                        for s in shots) else "lab"))
    size = report.get("size") or _size_of(report.get("shots"))
    engine_version = _engine_from_exe(exe, report) or _engine_from_exe(meta.get("engines") and {
        k: {"engine_version": v} for k, v in (meta.get("engines") or {}).items()})
    return {"id": report.get("id") or os.path.basename(d), "engine_version": engine_version,
            "ts": _num(report.get("opened")) or
            stamp_ts(os.path.basename(d)) or os.path.getmtime(path),
            "project": report.get("project") or project, "scenario": scen, "impl": impl, "kind": kind,
            "tag": report.get("tag"), "size": size, "exe_sha": exe_sha, "golden_id": golden_id,
            "contended": _bool(load.get("contended")) if isinstance(load, dict) else None, "host_load": load,
            "verdict": v, "dir": d, "source": "lab-report", "shots": shots, "series": series, "perf": perf,
            "extra": {"owner": report.get("owner"), "leases": report.get("leases"),
                      "events": len(report.get("events") or [])}}


def _metric_dicts(obj, scen_names, ctx=None, depth=0):
    """Обход любого отчёта сравнения: словари с identical_pct (кадр) — с контекстом сценария по ключам/полям."""
    if depth > 8:
        return
    if isinstance(obj, dict):
        ctx = obj.get("scenario") if isinstance(obj.get("scenario"), str) else ctx
        if "identical_pct" in obj or "pct" in obj and ("tick" in obj or "name" in obj):
            yield ctx, obj
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                yield from _metric_dicts(v, scen_names, k if k in scen_names else ctx, depth + 1)
    elif isinstance(obj, list):
        for v in obj:
            yield from _metric_dicts(v, scen_names, ctx, depth + 1)


def recs_lab2a(report, path, project=None):
    """Единый отчёт интерпретатора этапа 2а: report.json прогона, поле scenario = {harness, impl, size, results[]
    (scenario, shots[] с sha256/tick), compare (vclab/quality/compare.py)}. Одна запись истории на сценарий прогона."""
    d = os.path.dirname(path)
    sc = report.get("scenario") or {}
    base = rec_lab(dict(report, scenario=None, shots=[]), path, project)
    names = [r.get("scenario") for r in sc.get("results") or [] if isinstance(r, dict) and r.get("scenario")]
    if not names:
        names = [n for n in ((sc.get("scenarios") or [{}])[0].get("name"),) if n]
    found = {}
    # полный отчёт сравнения (vclab/quality/compare.py: <run>\vs_golden\compare.json), иначе краткий из report.json
    cj = _json(os.path.join(d, "vs_golden", "compare.json")) or {}
    for scen, sd in (cj.get("scenarios") or {}).items():
        if not isinstance(sd, dict):
            continue
        rows = []
        if sd.get("kind") == "timeline":
            ser = sd.get("series") or {}
            rows += [dict(k, scenario=scen) for k in ser.get("keyframes") or [] if isinstance(k, dict)]
            for st in ser.get("states") or []:
                if isinstance(st, dict) and st.get("tick") is not None and "error" not in st:
                    rows.append({"scenario": scen, "tick": st["tick"], "state_equal": _bool(
                        {k: v for k, v in st.items() if isinstance(v, bool)})})
        else:
            rows += [dict(m, scenario=scen) for m in sd.get("shots") or [] if isinstance(m, dict)]
        found[scen] = rows
    for ctx, m in ([] if found else _metric_dicts(sc.get("compare") or {}, set(names))):
        scen = m.get("scenario") or ctx or (names[0] if len(names) == 1 else None)
        if not scen:
            continue
        found.setdefault(scen, []).append(m)
    inputs = sc.get("inputs") if isinstance(sc.get("inputs"), dict) else {}
    out = []
    for res in sc.get("results") or [{"scenario": n} for n in names]:
        scen = res.get("scenario")
        if not scen:
            continue
        rec = dict(base)
        rec["id"] = "%s/%s" % (base["id"], scen)
        rec["scenario"] = scen
        rec["engine_version"] = res.get("engine_version") or _engine_from_exe(sc.get("exe"), sc) or \
            base.get("engine_version")
        rec["impl"] = sc.get("impl") or base.get("impl")
        rec["size"] = res.get("size") or sc.get("size") or base.get("size")
        rec["golden_id"] = inputs.get("key") or inputs.get("id") or inputs.get("golden_id") or base.get("golden_id")
        rec["verdict"] = "ok" if res.get("ok") else ("fail" if res.get("ok") is False else base.get("verdict"))
        shots = {}
        series = {}
        for s in res.get("shots") or []:
            if isinstance(s, dict) and s.get("name"):
                shots[s["name"]] = {"name": s["name"], "sha": s.get("sha256")}
                if s.get("tick") is not None and res.get("kind") == "timeline":
                    series[int(s["tick"])] = {"tick": int(s["tick"]), "pct": None, "state_equal": None}
        for m in found.get(scen, []):
            name = m.get("name") or m.get("shot") or m.get("frame")
            tick = m.get("tick")
            pct = _num(m.get("identical_pct", m.get("pct")))
            if "error" in m and pct is None and m.get("state_equal") is None:
                continue
            if tick is not None and (res.get("kind") == "timeline" or name is None):
                e = series.setdefault(int(tick), {"tick": int(tick), "pct": None, "state_equal": None})
                e["pct"] = pct if pct is not None else e["pct"]
                if m.get("state_equal") is not None or isinstance(m.get("state"), (bool, dict)):
                    e["state_equal"] = _bool(m.get("state_equal", m.get("state")))
                continue
            if name is not None:
                e = shots.setdefault(str(name), {"name": str(name), "sha": m.get("sha256")})
                e.update({"identical_pct": pct, "tol_pct": _num(m.get("within_tol_pct", m.get("tol_pct"))),
                          "coverage": _num(m.get("coverage_b_pct", m.get("coverage_a_pct", m.get("coverage")))),
                          "max_delta": _num(m.get("max_delta")), "golden": m.get("golden") or m.get("a"),
                          "sha": m.get("sha_b") or e.get("sha"),
                          "heat_png": m.get("heat_png") or m.get("heat"),
                          "diff_png": m.get("diff_png") or m.get("diff")})
        rec["shots"] = list(shots.values())
        rec["series"] = sorted(series.values(), key=lambda x: x["tick"])
        rec["kind"] = "e2e" if res.get("kind") == "timeline" else ("layers" if rec["shots"] else "lab")
        if res.get("kind") == "vctest":
            rec["kind"] = "vctest"
        elif (sc.get("finish") or {}).get(rec.get("project") or "") if isinstance(sc.get("finish"), dict) else False:
            # сессия проекта: finish.<имя проекта> в сценарии -> вид записи = имя проекта (раньше — одно зашитое имя)
            rec["kind"] = rec["project"]
        perf = {}
        if _num(res.get("dur")) is not None:
            perf["dur_s"] = _num(res["dur"])
        if res.get("kind") == "vctest" and res.get("exit_code") is not None:
            perf["exit_code"] = _num(res["exit_code"])
        fin = sc.get("finish") if isinstance(sc.get("finish"), dict) else {}
        if isinstance(fin.get("metrics"), dict):
            _flat("", fin["metrics"], perf, 2)
        _flat("timing", sc.get("timing") or {}, perf, 0)
        rec["perf"] = perf
        rec["source"] = "lab-scenario"
        rec["extra"] = dict(base.get("extra") or {}, harness=sc.get("harness"), run=base["id"])
        if sc.get("server_mode"):
            rec["extra"]["server_mode"] = sc["server_mode"]        # lockstep | realtime (этап 3б)
        am = cj.get("a_meta") if isinstance(cj.get("a_meta"), dict) else {}
        if res.get("kind") == "timeline" and am.get("kind") == "golden" and am.get("dir"):
            # серия: кадры golden — каталог сценария (ворота берут из него mtime golden.json: прогон старше — stale)
            rec["extra"]["golden_dir"] = os.path.join(am["dir"], scen)
        out.append(rec)
    return out


def rec_play(rep, path, project):
    d = os.path.dirname(path)
    perf = {}
    _flat("", rep.get("metrics") or {}, perf, 2)
    load = rep.get("host_load")
    return {"id": rep.get("id") or os.path.basename(d), "ts": _num(rep.get("started")) or stamp_ts(
        os.path.basename(d)) or os.path.getmtime(path), "project": rep.get("project") or project,
            "scenario": rep.get("scenario") or "play", "impl": "vc", "kind": "play", "tag": rep.get("tag"),
            "size": rep.get("size"), "exe_sha": rep.get("exe_sha"), "golden_id": None,
            "contended": _bool(load.get("contended")) if isinstance(load, dict) else None, "host_load": load,
            "verdict": rep.get("verdict"), "dir": d, "source": rep.get("source") or "play", "shots": [],
            "series": [], "perf": perf, "extra": {"report_md": rep.get("report_md"), "exit": rep.get("exit"),
                                                  "errors": len(rep.get("errors") or []),
                                                  "disconnect": rep.get("disconnect")}}


def rec_runtime_session(rep, path, project):
    """Сеанс стокового рантайма (этап 3а): отдельная запись kind=runtime_session с режимом (play | final-check),
    владельцем и причиной — видно, кто, когда и зачем поднимал VoxelCore.exe."""
    rt = rep.get("runtime") or {}
    base = rec_play(rep, path, project)
    base.update({"id": "%s/runtime_session" % base["id"], "kind": "runtime_session", "tag": rt.get("mode"),
                 "perf": {k: v for k, v in base["perf"].items() if k in ("duration_s",)}})
    base["extra"] = dict(base["extra"], mode=rt.get("mode"), reason=rt.get("reason"), owner=rep.get("owner"),
                         via=rt.get("via"), play_run=rep.get("id"))
    return base


def parse_dir(d, project, play_parser=None):
    """Все записи истории из каталога прогона (верхнего уровня). Ничего не пишет."""
    out = []
    name = os.path.basename(d.rstrip("\\/"))
    top = _json(os.path.join(d, "report.json"))
    if isinstance(top, dict) and top.get("id") and top.get("opened") and not top.get("closed"):
        top = None                                  # прогон ещё идёт (report.json пишется по ходу) — позже
    if isinstance(top, dict) and top.get("id") and (top.get("project") or project):
        if isinstance(top.get("scenario"), dict):
            out += recs_lab2a(top, os.path.join(d, "report.json"), project)
        elif not (isinstance(top.get("meta"), dict) and (top["meta"].get("play") or top["meta"].get("perf"))):
            out.append(rec_lab(top, os.path.join(d, "report.json"), project))
    pr = _json(os.path.join(d, "play_report.json"))
    if isinstance(pr, dict):
        out.append(rec_play(pr, os.path.join(d, "play_report.json"), project))
        if (pr.get("runtime") or {}).get("mode"):
            out.append(rec_runtime_session(pr, os.path.join(d, "play_report.json"), project))
    elif os.path.isfile(os.path.join(d, "status_lines.txt")) and play_parser:
        rep = play_parser(os.path.join(d, "status_lines.txt"))
        if rep:
            rep.setdefault("id", name)
            rep.setdefault("source", "legacy-status-lines")
            out.append(rec_play(rep, os.path.join(d, "status_lines.txt"), project))
    ps = _json(os.path.join(d, "perf_summary.json"))
    if isinstance(ps, dict):
        out.append(rec_perf(ps, os.path.join(d, "perf_summary.json"), project))
    try:
        subs = sorted(os.listdir(d))
    except OSError:
        subs = []
    for sub in subs:
        sd = os.path.join(d, sub)
        if not os.path.isdir(sd) or sub in ("logs", "shots", "vs_golden"):
            continue
        rj = os.path.join(sd, "run.json")
        rp = os.path.join(sd, "report.json")
        if os.path.isfile(rj):
            r = _json(rj)
            if isinstance(r, dict):
                out.append(rec_e2e(r, rj, project, name))
        elif os.path.isfile(rp):
            r = _json(rp)
            if isinstance(r, dict) and ("compare" in r or "impl" in r):
                out.append(rec_layer(r, rp, project, name))
            elif isinstance(r, dict) and r.get("id"):
                out.append(rec_lab(r, rp, project))
    return out


# ------------------------------------------------------------------------------------------------ база
class History:
    def __init__(self, path):
        self.path = path
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False, timeout=30)
        self.db.row_factory = sqlite3.Row
        with self.lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.executescript(SCHEMA)
            cols = {r[1] for r in self.db.execute("PRAGMA table_info(runs)").fetchall()}
            if "engine_version" not in cols:          # база до этапа 4: столбец версии движка
                self.db.execute("ALTER TABLE runs ADD COLUMN engine_version TEXT")
            self.db.execute("INSERT OR REPLACE INTO meta VALUES('schema', ?)", (SCHEMA_VERSION,))
            self.db.commit()

    def close(self):
        with self.lock:
            self.db.close()

    # -------------------------------------------------------------- запись
    def ingest(self, rec):
        """Upsert одной записи (runs + дети заменяются целиком)."""
        rid = rec["id"]
        load = rec.get("host_load")
        contended = rec.get("contended")
        if contended is None and isinstance(load, dict) and load.get("contended") is not None:
            contended = int(bool(load["contended"]))
        with self.lock:
            c = self.db
            c.execute("DELETE FROM shots WHERE run=?", (rid,))
            c.execute("DELETE FROM series WHERE run=?", (rid,))
            c.execute("DELETE FROM perf WHERE run=?", (rid,))
            c.execute("INSERT OR REPLACE INTO runs(%s) VALUES(%s)" % (",".join(RUN_COLS), ",".join("?" * len(RUN_COLS))), (
                rid, rec.get("ts"), rec.get("project"), rec.get("scenario"), rec.get("impl"), rec.get("kind"),
                rec.get("tag"), rec.get("size"), rec.get("exe_sha"), rec.get("golden_id"),
                None if contended is None else int(bool(contended)),
                json.dumps(load, ensure_ascii=False, default=str) if load is not None else None,
                rec.get("verdict"), rec.get("dir"), rec.get("source"), time.time(),
                json.dumps(rec.get("extra") or {}, ensure_ascii=False, default=str), rec.get("engine_version")))
            c.executemany("INSERT OR REPLACE INTO shots VALUES(?,?,?,?,?,?,?,?,?,?)", [
                (rid, s["name"], s.get("sha"), s.get("identical_pct"), s.get("tol_pct"), s.get("coverage"),
                 s.get("max_delta"), s.get("golden"), s.get("heat_png"), s.get("diff_png"))
                for s in rec.get("shots") or [] if s.get("name")])
            c.executemany("INSERT OR REPLACE INTO series VALUES(?,?,?,?)", [
                (rid, int(s["tick"]), s.get("pct"), s.get("state_equal")) for s in rec.get("series") or []])
            c.executemany("INSERT OR REPLACE INTO perf VALUES(?,?,?)", [
                (rid, k, v) for k, v in (rec.get("perf") or {}).items() if v is not None])
            c.commit()
        return rid

    def delete(self, rid):
        with self.lock:
            for t in ("shots", "series", "perf"):
                self.db.execute("DELETE FROM %s WHERE run=?" % t, (rid,))
            self.db.execute("DELETE FROM runs WHERE id=?", (rid,))
            self.db.commit()

    def ingest_dir(self, d, project, play_parser=None):
        recs = parse_dir(d, project, play_parser)
        for r in recs:      # отчёт 2а: запись на сценарий; прежняя запись «весь прогон» (если была) больше не нужна
            parent = (r.get("extra") or {}).get("run")
            if parent and parent != r["id"]:
                self.delete(parent)
        return [self.ingest(r) for r in recs]

    def import_tree(self, roots, project, play_parser=None, since=None):
        """Импорт всех каталогов прогонов под roots (повторный импорт — upsert, безопасен)."""
        stats = {"dirs": 0, "runs": 0, "by_kind": {}, "errors": []}
        for root in roots:
            for d in sorted(glob.glob(os.path.join(root, "*"))):
                if not os.path.isdir(d):
                    continue
                if since and os.path.getmtime(d) < since:
                    continue
                stats["dirs"] += 1
                try:
                    recs = parse_dir(d, project, play_parser)
                except Exception as exc:
                    stats["errors"].append("%s: %s: %s" % (d, type(exc).__name__, exc))
                    continue
                for r in recs:
                    parent = (r.get("extra") or {}).get("run")
                    if parent and parent != r["id"]:
                        self.delete(parent)
                    try:
                        self.ingest(r)
                    except Exception as exc:
                        stats["errors"].append("%s: %s: %s" % (r.get("id"), type(exc).__name__, exc))
                        continue
                    stats["runs"] += 1
                    k = "%s/%s" % (r.get("kind"), r.get("impl"))
                    stats["by_kind"][k] = stats["by_kind"].get(k, 0) + 1
        return stats

    def add_gate(self, g):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO gates VALUES(?,?,?,?,?,?,?,?,?,?)", (
                g["id"], g["ts"], g["project"], g["suite"], g.get("mode"), g["verdict"], len(g.get("regressions") or []),
                g.get("report_json"), g.get("report_md"), json.dumps(g.get("summary") or {}, ensure_ascii=False)))
            self.db.commit()

    def accept(self, project, scenario, frame, pct, sha, run, note=None):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO ratchet VALUES(?,?,?,?,?,?,?,?)",
                            (project, scenario, frame, pct, sha, run, time.time(), note))
            self.db.commit()

    # -------------------------------------------------------------- чтение
    def q(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.db.execute(sql, args).fetchall()]

    def runs(self, project=None, scenario=None, last=None, kind=None, impl=None, since=None, engine=None):
        sql, a = "SELECT * FROM runs WHERE 1=1", []
        if engine:                                  # версия движка; 0.31 — ещё и записи без версии (до этапа 4)
            if str(engine) == DEFAULT_ENGINE_VERSION:
                sql += " AND (engine_version IS NULL OR engine_version=?)"
            else:
                sql += " AND engine_version=?"
            a.append(str(engine))
        for col, v in (("project", project), ("scenario", scenario), ("kind", kind), ("impl", impl)):
            if v:
                if isinstance(v, (list, tuple)):
                    sql += " AND %s IN (%s)" % (col, ",".join("?" * len(v)))
                    a += list(v)
                else:
                    sql += " AND %s=?" % col
                    a.append(v)
        if since:
            sql += " AND ts>=?"
            a.append(since)
        sql += " ORDER BY ts DESC, id DESC"
        if last:
            sql += " LIMIT %d" % int(last)
        rows = self.q(sql, a)
        for r in rows:
            for k in ("extra", "host_load"):
                try:
                    r[k] = json.loads(r[k]) if r.get(k) else None
                except ValueError:
                    pass
        return rows

    def shots(self, run):
        return self.q("SELECT * FROM shots WHERE run=? ORDER BY name", (run,))

    def series(self, run):
        return self.q("SELECT * FROM series WHERE run=? ORDER BY tick", (run,))

    def perf(self, run):
        return {r["metric"]: r["value"] for r in self.q("SELECT metric, value FROM perf WHERE run=?", (run,))}

    def gates(self, project=None, last=20):
        sql, a = "SELECT * FROM gates", []
        if project:
            sql += " WHERE project=?"
            a.append(project)
        rows = self.q(sql + " ORDER BY ts DESC LIMIT %d" % int(last), a)
        for r in rows:
            try:
                r["summary"] = json.loads(r["summary"]) if r.get("summary") else {}
            except ValueError:
                pass
        return rows

    def ratchet(self, project):
        return {(r["scenario"], r["frame"]): r for r in self.q("SELECT * FROM ratchet WHERE project=?", (project,))}

    def projects(self):
        return [r["project"] for r in self.q("SELECT DISTINCT project FROM runs ORDER BY project") if r["project"]]

    def counts(self, project=None):
        sql = "SELECT project, kind, impl, COALESCE(engine_version, '%s') engine_version, COUNT(*) n FROM runs" % \
            DEFAULT_ENGINE_VERSION
        a = []
        if project:
            sql += " WHERE project=?"
            a.append(project)
        return self.q(sql + " GROUP BY project, kind, impl, 4 ORDER BY project, kind, impl, 4", a)

    def summary_rows(self, project, scenario=None, last=20, engine=None):
        """Для `lab history`: прогоны с минимумом/средним % по снимкам и серии, perf-ключами."""
        out = []
        for r in self.runs(project, scenario, last, engine=engine):
            sh = self.shots(r["id"])
            se = self.series(r["id"])
            pcts = [s["identical_pct"] for s in sh if s["identical_pct"] is not None]
            spct = [s["pct"] for s in se if s["pct"] is not None]
            st = [s["state_equal"] for s in se if s["state_equal"] is not None]
            pf = self.perf(r["id"])
            out.append({"id": r["id"], "ts": time.strftime("%Y-%m-%d %H:%M", time.localtime(r["ts"] or 0)),
                        "scenario": r["scenario"], "impl": r["impl"], "kind": r["kind"], "tag": r["tag"],
                        "engine": engine_of(r),
                        "verdict": r["verdict"], "contended": r["contended"], "shots": len(sh),
                        "min_pct": round(min(pcts), 3) if pcts else None,
                        "mean_pct": round(sum(pcts) / len(pcts), 3) if pcts else None,
                        "keyframes": len(spct), "kf_min_pct": round(min(spct), 3) if spct else None,
                        "states_equal": "%d/%d" % (sum(st), len(st)) if st else None,
                        "fps_5s": {k: round(pf[m], 1) for k, m in (
                            ("min", "all.fps_5s.min"), ("p5", "all.fps_5s.p5"), ("median", "all.fps_5s.median"),
                            ("min", "fps_5s.min"), ("p5", "fps_5s.p5"), ("median", "fps_5s.median")) if m in pf}
                        or None, "dir": r["dir"]})
        return out


def table(rows):
    """Текстовая таблица для `lab history --table`."""
    head = "%-16s %-26s %-6s %-5s %-6s %-22s %-8s %5s %9s %9s %8s %-20s" % (
        "ts", "scenario", "engine", "impl", "kind", "tag", "verdict", "shots", "min%", "kf min%", "states",
        "fps5 min/p5/med")
    lines = [head]
    for r in rows:
        f = r.get("fps_5s") or {}
        lines.append("%-16s %-26s %-6s %-5s %-6s %-22s %-8s %5s %9s %9s %8s %-20s" % (
            r["ts"], (r["scenario"] or "")[:26], (r.get("engine") or "")[:6], (r["impl"] or "")[:5], (r["kind"] or "")[:6],
            (r["tag"] or "")[:22], (r["verdict"] or "")[:8], r["shots"] or "",
            "" if r["min_pct"] is None else "%.3f" % r["min_pct"],
            "" if r["kf_min_pct"] is None else "%.3f" % r["kf_min_pct"], r["states_equal"] or "",
            "/".join("%g" % f[k] for k in ("min", "p5", "median") if k in f) +
            (" C" if r.get("contended") else "")))
    return "\n".join(lines)


# ------------------------------------------------------------------------------------------------ демон
def import_roots(lab, proj):
    """[history].import дескриптора (подстановки как в prepare) + runs_dir проекта."""
    from vclab.projects import expand
    ctx = dict(lab.base_ctx(), project_dir=proj.dir)
    dirs = proj.dirs(ctx)
    ctx.update(dirs)
    roots = [expand(x, ctx) for x in ((proj.raw or {}).get("history") or {}).get("import") or []]
    if dirs.get("runs_dir"):
        roots.append(dirs["runs_dir"])
    out = []
    for r in roots:
        if r and os.path.isdir(r) and os.path.normcase(r) not in [os.path.normcase(x) for x in out]:
            out.append(r)
    return out


def install_core(lab, core, Feature, version):
    """Подключить к демону: lab.history (единственный писатель), lab.play, автоприём закрытых прогонов в историю и
    возможности ядра core.history*, core.gate*, core.dashboard, core.play, core.sysload."""
    from vclab import dashboard
    from vclab.quality import gate
    from vclab import play
    from vclab.quality import sysload
    lab.history = History(os.path.join(lab.data, "history.sqlite"))
    lab.play = play.PlayManager(lab)
    h = lab.history

    def play_parser_for(proj):
        return play.legacy_parser(((proj.raw or {}).get("play") or {}).get("report") or {})

    # прогон закрылся (интерпретатор, аренда, play) -> его каталог в историю (фоном; ошибки — в журнал)
    orig_close = lab.runs.close

    def close_and_ingest(rid, verdict=None, extra=None):
        run = orig_close(rid, verdict=verdict, extra=extra)
        if run and run.get("dir"):
            def bg():
                try:
                    time.sleep(0.2)
                    proj = lab.projects.get(run.get("project"))
                    h.ingest_dir(run["dir"], run.get("project"), play_parser_for(proj))
                except Exception as exc:
                    try:
                        lab.journal.event("lab.history_ingest_failed", "%s: %s" % (rid, exc), error=True)
                    except Exception:
                        pass
            threading.Thread(target=bg, name="ingest-" + rid, daemon=True).start()
        return run
    lab.runs.close = close_and_ingest

    orig_shutdown = lab.shutdown

    def shutdown():
        orig_shutdown()
        try:
            h.close()
        except Exception:
            pass
    lab.shutdown = shutdown

    def f_history(ctx, a):
        rows = h.summary_rows(a.get("project"), a.get("scenario"), int(a.get("last", 20)), engine=a.get("engine"))
        if a.get("kind"):
            rows = [r for r in rows if r["kind"] == a["kind"]]
        out = {"db": h.path, "rows": rows}
        if a.get("table"):
            out["table"] = table(rows)
        if a.get("counts"):
            out["counts"] = h.counts(a.get("project"))
        return out

    def f_ingest(ctx, a):
        proj = lab.projects.get(a["project"])
        return {"ingested": h.ingest_dir(a["dir"], a["project"], play_parser_for(proj))}

    def f_import(ctx, a):
        names = [a["project"]] if a.get("project") else sorted(lab.projects.projects)
        out = {}
        for n in names:
            proj = lab.projects.get(n)
            roots = a.get("roots") or import_roots(lab, proj)
            t0 = time.time()
            st = h.import_tree(roots, n, play_parser_for(proj))
            st["roots"] = roots
            st["s"] = round(time.time() - t0, 2)
            out[n] = st
        return {"db": h.path, "import": out, "counts": h.counts(a.get("project"))}

    def f_gate(ctx, a):
        project = a["project"]
        proj = lab.projects.get(project)
        cfg = gate.gate_cfg(proj)
        suite = a.get("suite", "all")
        mode = a.get("mode", "latest")
        log = []
        runs = None
        pre = sysload.check(1.0)
        if a.get("refresh", True):
            h.import_tree(import_roots(lab, proj), project, play_parser_for(proj))
        if mode == "run":
            stop = None
            if a.get("stop_on_user"):          # ночные ворота: пользователь вернулся — оставшиеся сценарии не гонять
                def stop():
                    idle = sysload.user_idle_s()
                    return "user active (idle %.0f s)" % idle if idle is not None and idle < 60 else None
            dirs = gate.run_suite(lab, project, suite, ctx.owner, cfg, progress=log.append, should_stop=stop)
            ids = []
            for d in dirs:
                ids += h.ingest_dir(d, project, play_parser_for(proj))
            runs = [r for r in h.runs(project) if r["id"] in ids and r["impl"] == "vc"]
        res = gate.evaluate(h, project, suite, cfg, runs=runs, mode=mode)
        res["host_load"] = {"busy": pre["busy"], "reasons": pre["reasons"]}
        res["progress"] = log
        gate.write(res, os.path.join(lab.data, "gates"))
        h.add_gate(res)
        if a.get("dashboard", True):
            try:
                res["dashboard"] = dashboard.generate(h, lab.data)["index"]
            except Exception as exc:
                res["dashboard_error"] = "%s: %s" % (type(exc).__name__, exc)
        short = {k: res[k] for k in ("id", "verdict", "exit_code", "summary", "report_md", "report_json", "host_load")}
        short["regressions"] = res["regressions"][:50]
        short["state_regressions"] = res["state_regressions"][:20]
        short["perf"] = res["perf"]
        short["dashboard"] = res.get("dashboard")
        return short

    def f_accept(ctx, a):
        return gate.accept(h, a["project"], a["run"], a.get("frames"), a.get("note") or ("by %s" % ctx.owner))

    def f_dashboard(ctx, a):
        if a.get("refresh"):
            for n in (a.get("projects") or sorted(lab.projects.projects)):
                proj = lab.projects.get(n)
                h.import_tree(import_roots(lab, proj), n, play_parser_for(proj))
        return dashboard.generate(h, lab.data, a.get("projects"))

    def f_play(ctx, a):
        act = a.get("action", "status")
        if act == "start":
            # этап 3а: стоковый рантайм — только --user (интерактивный CLI пользователя) или --final-check с причиной
            mode = "play" if a.get("user") else ("final-check" if a.get("final_check") else None)
            return lab.play.start(a["project"], ctx.owner, params=a.get("params"), opts=a.get("opts"),
                                  max_s=a.get("max_s"), ttl=a.get("ttl"), mode=mode, reason=a.get("reason"),
                                  interactive=bool(a.get("interactive")), via=ctx.via)
        if act == "stop":
            return lab.play.stop(a.get("session"), a.get("project"), ctx.owner, wait=float(a.get("wait", 90)))
        if act == "list":
            return lab.play.list()
        return lab.play.status(a.get("session"), a.get("project"))

    def f_sysload(ctx, a):
        own = []
        for l in list(lab.leases.values()):
            if l.job:
                try:
                    own += l.job.pids()
                except Exception:
                    pass
        return sysload.check(float(a.get("seconds", 2.0)), own)

    P = {"type": "object", "properties": {"project": {"type": "string"}}}

    def sch(**props):
        return {"type": "object", "properties": {k: ({"type": v} if isinstance(v, str) else v)
                                                  for k, v in props.items()}}
    feats = [
        ("core.history", f_history, "history rows {project, scenario?, last=20, kind?, table?, counts?}",
         sch(project="string", scenario="string", last="integer", kind="string", table="boolean", counts="boolean")),
        ("core.history_ingest", f_ingest, "ingest one run dir into history {project, dir}",
         sch(project="string", dir="string")),
        ("core.history_import", f_import, "import all run dirs of a project ([history].import + runs_dir) {project?}",
         P),
        ("core.gate", f_gate, "ratchet gate {project, suite=all|layers|e2e|u|perf, mode=latest|run, refresh=true}",
         sch(project="string", suite="string", mode="string", refresh="boolean")),
        ("core.gate_accept", f_accept, "raise the ratchet explicitly with a run's values {project, run, frames?}",
         sch(project="string", run="string", frames="array", note="string")),
        ("core.dashboard", f_dashboard, "write artifacts/lab/index.html, dashboard/<project>.html, SUMMARY.md",
         sch(projects="array", refresh="boolean")),
        ("core.play", f_play, "stock runtime session {project, action=start|stop|status|list, user?|final_check?, "
                              "reason?, params?, opts?, max_s?} (start: user=true only from the user's interactive CLI; "
                              "final_check=true + reason — main session claude/user)",
         sch(project="string", action="string", params="object", opts="array", max_s="number", session="string",
             user="boolean", final_check="boolean", reason="string", interactive="boolean")),
        ("core.sysload", f_sysload, "PC load now: CPU/GPU/user activity, busy + reasons {seconds=2}",
         sch(seconds="number")),
    ]
    for name, fn, desc, schema in feats:
        core[name] = Feature(name, fn, desc, schema, project="core", version="core@" + version)
    return core
