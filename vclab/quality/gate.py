"""Ворота-храповик: `lab gate <project> [--suite layers|all|e2e|perf] [--mode latest|run]`.

Для каждой пары (сценарий, кадр) — снимок (`0_yaw0`) или ключевой кадр серии (`kf_0158`):
  baseline = принятое значение храповика (`lab gate accept`, таблица ratchet), иначе лучшее записанное значение
             прогонов vc этого сценария после последнего обновления golden этого кадра (без contended);
  ε        = шум Java/Java этого кадра: max(100 − identical_pct) по прогонам impl=java против golden (их пишут
             старые раннеры: java_normal/java_layers/e2e_java*), + [gate].eps проекта (по умолчанию 0);
  regress, если now < baseline − ε; improved, если now > baseline + ε (только список: ворота НИКОГДА не поднимают
  храповик и не трогают golden — это делает человек/агент явно: `lab gate accept <project> <run>`).
  Совпал sha с baseline — ok без метрики. Прогон старше файла golden — stale (сравнивался с прежним golden).
  Серия: state_equal был 1 в baseline, стал 0 — регрессия состояния.
Перф (набор perf/all): последний неэкспериментальный прогон сценария против лучшего (по [gate].perf_metric) ×
(1 − perf_rel_tol); прогон contended — вердикт игнорируется («ignored: contended»); по умолчанию перф даёт warn,
fail — только при [gate].perf_fail = true.
Код выхода CLI: 0 pass, 1 fail, 2 нет данных/ошибка, 3 warn.
Режимы: latest (по умолчанию) — последние записанные прогоны (история обновляется импортом каталогов прогонов
проекта); run — сначала прогнать набор интерпретатором этапа 2а (vclab/scenario/scenario.py, golden-сравнение), импорт,
потом ворота по этим прогонам."""
import fnmatch
import json
import os
import time

DEFAULT_SUITES = {
    "layers": ["layer_*"],
    "e2e": ["e2e_*"],
    "u": ["u_*"],
    "all": ["layer_*", "u_*", "alpha_spawn", "e2e_*", "p4_*"],
    "perf": [],
}
EXIT = {"pass": 0, "fail": 1, "error": 2, "nodata": 2, "warn": 3}


def gate_cfg(proj):
    g = dict((getattr(proj, "raw", None) or {}).get("gate") or {})
    g.setdefault("eps", 0.0)
    g.setdefault("perf_metric", "all.fps_5s.p5")
    g.setdefault("perf_rel_tol", 0.25)
    g.setdefault("perf_fail", False)
    g.setdefault("exclude_tags", ["exp_", "probe"])
    suites = dict(DEFAULT_SUITES)
    suites.update(g.get("suites") or {})
    g["suites"] = suites
    return g


def win_path(p):
    if not p:
        return p
    p = str(p)
    if p.startswith("/mnt/") and len(p) > 6:
        p = p[5].upper() + ":" + p[6:].replace("/", "\\")
    return p


_EPOCH = {}


def golden_epoch(path):
    """mtime файла golden (снимок) или каталога golden (серия: run.json/report.json). None — неизвестно."""
    if not path:
        return None
    p = win_path(path)
    if p.startswith("legacy:"):
        p = p[7:]
    p = p.replace("/", os.sep) if os.sep == "\\" else p
    if p in _EPOCH and time.time() - _EPOCH[p][1] < 60:
        return _EPOCH[p][0]
    v = None
    try:
        if os.path.isfile(p):
            v = os.path.getmtime(p)
        elif os.path.isdir(p):
            for f in ("golden.json", "run.json", "report.json", "manifest.json"):   # golden.json — манифест lab (этап 3б)
                if os.path.isfile(os.path.join(p, f)):
                    v = os.path.getmtime(os.path.join(p, f))
                    break
    except OSError:
        v = None
    _EPOCH[p] = (v, time.time())
    return v


def _engine(r):
    """Версия движка прогона (этап 4): записи без версии — 0.31."""
    from vclab.quality.history import engine_of
    return engine_of(r)


def _ratchet_engine(h, rt, cache):
    key = ("ratchet-engine", rt.get("run"))
    if key not in cache:
        rows = h.q("SELECT engine_version FROM runs WHERE id=?", (rt.get("run"),)) if rt.get("run") else []
        cache[key] = _engine(rows[0] if rows else {})
    return cache[key]


def _server_mode(r):
    ex = r.get("extra")
    return ex.get("server_mode") if isinstance(ex, dict) else None


def frames_of(h, r, cache=None):
    """{кадр: {pct, sha, heat, diff, state_equal, golden}} прогона: снимки по имени, серия — kf_%04d."""
    key = (r["id"], r.get("ingested"))
    if cache is not None and key in cache:
        return cache[key]
    out = {}
    for s in h.shots(r["id"]):
        out[s["name"]] = {"pct": s["identical_pct"], "sha": s["sha"], "heat": s["heat_png"], "diff": s["diff_png"],
                          "state_equal": None, "golden": s["golden"]}
    gdir = None
    gid = r.get("golden_id") or ""
    if gid.startswith("legacy:"):
        gdir = gid
    elif (r.get("extra") or {}).get("golden_dir") if isinstance(r.get("extra"), dict) else None:
        gdir = r["extra"]["golden_dir"]        # серия прогона lab (history: extra.golden_dir, этап 3б)
    for s in h.series(r["id"]):
        k = "kf_%04d" % s["tick"]
        e = out.setdefault(k, {"pct": None, "sha": None, "heat": None, "diff": None, "state_equal": None,
                               "golden": gdir})
        if s["pct"] is not None:
            e["pct"] = s["pct"]
        if s["state_equal"] is not None:
            e["state_equal"] = s["state_equal"]
        if e.get("golden") is None:
            e["golden"] = gdir
    if cache is not None:
        cache[key] = out
    return out


def run_min_pct(h, r, cache=None):
    if isinstance(r, str):
        r = (h.q("SELECT * FROM runs WHERE id=?", (r,)) or [{"id": r}])[0]
    v = [f["pct"] for f in frames_of(h, r, cache).values() if f["pct"] is not None]
    return min(v) if v else None


def noise_table(h, project, cache=None):
    """ε по кадру: max(100 − pct) прогонов Java против golden (J/J шум). Прогоны-эталоны (kind golden) не считаются."""
    out = {}
    for r in h.runs(project, impl="java", kind=("layers", "e2e")):
        if (r.get("extra") or {}).get("golden_run"):
            continue
        for k, f in frames_of(h, r, cache).items():
            if f["pct"] is None:
                continue
            n = max(0.0, 100.0 - f["pct"])
            key = (r["scenario"], k)
            if n > out.get(key, -1):
                out[key] = n
    return out


def in_suite(name, patterns):
    return any(fnmatch.fnmatch(name, p) for p in patterns)


def _excluded(tag, cfg):
    return any(x in (tag or "") for x in cfg.get("exclude_tags") or [])


def evaluate(h, project, suite="all", cfg=None, runs=None, mode="latest", now=None):
    """Чистая функция над историей: вердикт ворот (dict). runs — прогоны под оценкой (иначе последние vc)."""
    cfg = cfg or gate_cfg(None)
    pats = cfg["suites"].get(suite)
    if pats is None:
        raise ValueError("unknown suite %r (have: %s)" % (suite, ", ".join(cfg["suites"])))
    cache = {}
    noise = noise_table(h, project, cache)
    ratchet = h.ratchet(project)
    allvc = [r for r in h.runs(project, impl="vc", kind=("layers", "e2e"))]
    if runs is None:
        latest = {}
        for r in sorted(allvc, key=lambda r: (r["ts"] or 0, r["id"])):
            if in_suite(r["scenario"], pats) and (not _excluded(r["tag"], cfg) or r["source"] == "lab-scenario"):
                latest[(r["scenario"], _engine(r))] = r      # этап 4: последний прогон на каждую версию движка
        runs = list(latest.values())
    res = {"project": project, "suite": suite, "mode": mode, "ts": now or time.time(), "runs": [], "regressions": [],
           "state_regressions": [], "improved": [], "stale": [], "new": [], "ok": 0, "frames": 0,
           "perf": [], "eps_default": cfg["eps"]}
    res["engines"] = sorted({_engine(r) for r in runs})
    for r in sorted(runs, key=lambda r: (r["scenario"], _engine(r))):
        fr = frames_of(h, r, cache)
        ev = _engine(r)
        res["runs"].append({"id": r["id"], "scenario": r["scenario"], "ts": r["ts"], "dir": r["dir"],
                            "frames": len(fr), "contended": r.get("contended"), "engine_version": ev})
        # основание — прогоны того же режима сервера (этап 3б: дымовой realtime не основание для lockstep и наоборот)
        sm = _server_mode(r)
        # и той же версии движка (этап 4: 0.32 против 0.32; сравнение версий — история/панель, не храповик)
        others = [o for o in allvc if o["scenario"] == r["scenario"] and o["id"] != r["id"] and o.get("contended") != 1
                  and (sm is None or _server_mode(o) in (None, sm)) and _engine(o) == ev]
        for k, cur in sorted(fr.items()):
            if cur["pct"] is None and cur["state_equal"] is None:
                continue
            res["frames"] += 1
            ep = golden_epoch(cur.get("golden"))
            item = {"scenario": r["scenario"], "frame": k, "now": cur["pct"], "run": r["id"], "run_dir": r["dir"],
                    "engine_version": ev,
                    "heat": cur.get("heat"), "diff": cur.get("diff"), "sha": cur.get("sha")}
            if ep and (r["ts"] or 0) + 1 < ep:
                res["stale"].append(dict(item, golden_mtime=ep, why="run older than its golden file"))
                continue
            eps = float(noise.get((r["scenario"], k), 0.0)) + float(
                (cfg.get("eps_by_scenario") or {}).get(r["scenario"], cfg["eps"]))
            rt = ratchet.get((r["scenario"], k))
            if rt and _ratchet_engine(h, rt, cache) != ev:
                rt = None                     # храповик принят на другой версии движка — не основание
            base = base_sha = base_run = None
            src = None
            if rt and (not ep or (rt["accepted_ts"] or 0) >= ep):
                base, base_sha, base_run, src = rt["best_pct"], rt["sha"], rt["run"], "accepted"
            else:
                for o in others:
                    if ep and (o["ts"] or 0) + 1 < ep:
                        continue
                    of = frames_of(h, o, cache).get(k)
                    if of and of["pct"] is not None and (base is None or of["pct"] > base):
                        base, base_sha, base_run, src = of["pct"], of["sha"], o["id"], "history-best"
            item.update(was=base, eps=round(eps, 4), base_run=base_run, base_src=src)
            # состояние (серии): было равно в каком-либо прогоне-основании, стало не равно
            if cur["state_equal"] == 0:
                had = any((frames_of(h, o, cache).get(k) or {}).get("state_equal") == 1 for o in others
                          if not (ep and (o["ts"] or 0) + 1 < ep))
                if had:
                    res["state_regressions"].append(dict(item))
            if cur["pct"] is None:
                continue
            if base is None:
                res["new"].append(item)
            elif base_sha and cur.get("sha") and base_sha == cur["sha"]:
                res["ok"] += 1
            elif cur["pct"] < base - eps - 1e-9:
                res["regressions"].append(dict(item, drop=round(base - cur["pct"], 4)))
            elif cur["pct"] > base + eps + 1e-9:
                res["improved"].append(dict(item, gain=round(cur["pct"] - base, 4)))
            else:
                res["ok"] += 1
    if suite in ("perf", "all"):
        res["perf"] = perf_eval(h, project, cfg)
    perf_bad = [p for p in res["perf"] if p["verdict"] == "regress"]
    if res["regressions"] or res["state_regressions"] or (perf_bad and cfg.get("perf_fail")):
        v = "fail"
    elif perf_bad:
        v = "warn"
    elif res["frames"] == 0 and not res["perf"]:
        v = "nodata"
    else:
        v = "pass"
    res["verdict"] = v
    res["exit_code"] = EXIT[v]
    res["summary"] = {"frames": res["frames"], "ok": res["ok"], "regressions": len(res["regressions"]),
                      "state_regressions": len(res["state_regressions"]), "improved": len(res["improved"]),
                      "stale": len(res["stale"]), "new": len(res["new"]), "runs": len(res["runs"]),
                      "perf": ",".join("%s/%s:%s" % (p["scenario"], p["family"], p["verdict"]) for p in res["perf"])}
    return res


def perf_family(tag, cfg):
    """Семейство перф-прогонов (сравниваются только внутри него: другой маршрут/нагрузка — другое семейство).
    [gate].perf_families = {имя = "маска тега"}; иначе — первое слово тега (stream_base2 -> stream, after3_1 -> after)."""
    for name, pat in (cfg.get("perf_families") or {}).items():
        if fnmatch.fnmatch(tag or "", pat):
            return name
    import re
    m = re.match(r"[A-Za-z]+", tag or "")
    return m.group(0) if m else (tag or "")


def perf_eval(h, project, cfg):
    metric = cfg["perf_metric"]
    tol = float(cfg["perf_rel_tol"])
    out = []
    pr = [r for r in h.runs(project, kind="perf") if not _excluded(r["tag"], cfg)
          and not (r.get("extra") or {}).get("experimental")]
    groups = {}
    for r in pr:
        groups.setdefault((r["scenario"], perf_family(r["tag"], cfg)), []).append(r)
    for (scen, fam) in sorted(groups):
        rs = sorted(groups[(scen, fam)], key=lambda r: r["ts"] or 0)
        cur = rs[-1]
        cv = h.perf(cur["id"]).get(metric)
        best, best_run = None, None
        for o in rs[:-1]:
            if o.get("contended") == 1:      # contended не бывает основанием (проверено этапом 3а: test_gate)
                continue
            v = h.perf(o["id"]).get(metric)
            if v is not None and (best is None or v > best):
                best, best_run = v, o["id"]
        item = {"scenario": scen, "family": fam, "metric": metric, "run": cur["id"], "tag": cur["tag"], "now": cv,
                "best": best, "best_run": best_run, "rel_tol": tol, "contended": cur.get("contended"),
                "run_dir": cur["dir"], "n": len(rs)}
        if cv is None:
            item["verdict"] = "nodata"
        elif cur.get("contended") == 1:
            item["verdict"] = "ignored: contended"
            item["load"] = (cur.get("host_load") or {}).get("reasons")
        elif best is None:
            item["verdict"] = "new"
        elif cv < best * (1 - tol):
            item["verdict"] = "regress"
        else:
            item["verdict"] = "ok"
        if cur.get("contended") is None and item["verdict"] in ("ok", "regress"):
            item["load"] = "not recorded (run made before sysload)"
        out.append(item)
    return out


def _img(p):
    from vclab.dashboard import file_url
    return file_url(p)


def report_md(res):
    L = ["# Ворота %s — набор %s (%s)" % (res["project"], res["suite"], res["mode"]), "",
         "Время: %s. Вердикт: **%s** (код выхода %d)." % (time.strftime("%Y-%m-%d %H:%M:%S",
                                                                       time.localtime(res["ts"])),
                                                         res["verdict"], res["exit_code"]), ""]
    s = res["summary"]
    if res.get("engines"):
        L.append("Версии движка: %s (основание и храповик — только в своей версии)." % ", ".join(res["engines"]))
    L.append("Прогонов %d, кадров %d: ok %d, регрессий %d (состояние %d), улучшений %d, stale %d, без основания %d." % (
        s["runs"], s["frames"], s["ok"], s["regressions"], s["state_regressions"], s["improved"], s["stale"], s["new"]))
    L.append("Основание: принятый храповик (`lab gate accept`) или лучшее записанное после обновления golden; "
             "ε = шум Java/Java кадра + [gate].eps (%.3g). Ворота храповик не поднимают." % res["eps_default"])
    L.append("")
    if res["regressions"]:
        L.append("## Регрессии")
        L.append("| сценарий | движок | кадр | было | стало | ε | основание | прогон |")
        L.append("|---|---|---|---|---|---|---|---|")
        for r in res["regressions"]:
            L.append("| %s | %s | %s | %.3f | %.3f | %.3f | %s %s | `%s` |" % (
                r["scenario"], r.get("engine_version", ""), r["frame"], r["was"], r["now"], r["eps"], r["base_src"],
                r["base_run"], r["run"]))
        L.append("")
        for r in res["regressions"][:30]:
            if r.get("heat"):
                L.append("**%s / %s** (%.3f → %.3f): ![heat](%s)" % (r["scenario"], r["frame"], r["was"], r["now"],
                                                                    _img(r["heat"])))
        L.append("")
    if res["state_regressions"]:
        L.append("## Регрессии состояния (было равно, стало нет)")
        for r in res["state_regressions"]:
            L.append("- %s %s (прогон `%s`)" % (r["scenario"], r["frame"], r["run"]))
        L.append("")
    if res["improved"]:
        L.append("## Улучшения (принять: `lab gate accept %s <run>`)" % res["project"])
        for r in res["improved"][:60]:
            L.append("- %s %s: %.3f → %.3f (+%.3f) `%s`" % (r["scenario"], r["frame"], r["was"], r["now"], r["gain"],
                                                           r["run"]))
        L.append("")
    if res["perf"]:
        L.append("## Перф")
        L.append("| сценарий / семейство | метрика | прогон | сейчас | лучший | допуск | вердикт |")
        L.append("|---|---|---|---|---|---|---|")
        for p in res["perf"]:
            L.append("| %s / %s (%d) | %s | %s (%s) | %s | %s | −%d%% | %s%s |" % (
                p["scenario"], p["family"], p["n"], p["metric"], p["run"], p["tag"], "%.1f" % p["now"] if p["now"] is not None else "",
                "%.1f" % p["best"] if p["best"] is not None else "", round(p["rel_tol"] * 100), p["verdict"],
                (" — " + (p["load"] if isinstance(p.get("load"), str) else "; ".join(p.get("load") or [])))
                if p.get("load") else ""))
        L.append("")
    if res["stale"]:
        L.append("## Stale (прогон старше файла golden — сравнивался с прежним golden)")
        by = {}
        for r in res["stale"]:
            by.setdefault(r["scenario"], []).append(r["frame"])
        for k, v in sorted(by.items()):
            L.append("- %s: %s" % (k, ", ".join(v[:12]) + (" …" if len(v) > 12 else "")))
        L.append("")
    L.append("## Прогоны под оценкой")
    for r in res["runs"]:
        L.append("- %s `%s` (%d кадров) %s" % (r["scenario"], r["id"], r["frames"], r["dir"]))
    return "\n".join(L) + "\n"


def write(res, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    gid = "%s_%s_%s" % (time.strftime("%Y%m%d_%H%M%S", time.localtime(res["ts"])), res["project"], res["suite"])
    jp = os.path.join(out_dir, gid + ".json")
    mp = os.path.join(out_dir, gid + ".md")
    res["id"] = gid
    res["report_json"], res["report_md"] = jp, mp
    with open(jp, "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1, default=str)
    with open(mp, "w", encoding="utf-8") as f:
        f.write(report_md(res))
    return res


def accept(h, project, run_id, frames=None, note=None):
    """Явно поднять храповик значениями прогона (все кадры или список frames). Ворота сами этого не делают."""
    rows = h.q("SELECT * FROM runs WHERE id=?", (run_id,))
    if not rows:
        raise KeyError("no run %s in history" % run_id)
    r = rows[0]
    done = []
    for k, f in frames_of(h, r).items():
        if f["pct"] is None or (frames and k not in frames):
            continue
        h.accept(project, r["scenario"], k, f["pct"], f["sha"], run_id, note)
        done.append({"frame": k, "pct": f["pct"]})
    return {"run": run_id, "scenario": r["scenario"], "accepted": done}


def suite_scenarios(scen_dir, patterns):
    try:
        names = sorted(os.path.splitext(f)[0] for f in os.listdir(scen_dir) if f.endswith(".json"))
    except OSError:
        return []
    return [n for n in names if in_suite(n, patterns)]


def run_suite(lab, project, suite, owner, cfg, progress=None, should_stop=None):
    """Прогнать набор интерпретатором этапа 2а (если есть): по одному сценарию на сессию, golden-сравнение.
    Возвращает каталоги прогонов. Нет интерпретатора — RuntimeError (ворота тогда работают в режиме latest)."""
    svc = getattr(lab, "scen", None) or getattr(lab, "scenarios", None)
    if svc is None or not hasattr(svc, "start"):
        try:
            from vclab.scenario import scenario as S
        except Exception as exc:
            raise RuntimeError("stage-2a interpreter is not available: %s" % exc)
        svc = S.ScenarioService(lab)
    proj = lab.projects.get(project)
    sdir = proj.dirs(dict(lab.base_ctx(), project_dir=proj.dir)).get("scenarios_dir")
    names = suite_scenarios(sdir, cfg["suites"][suite])
    dirs = []
    for n in names:
        if should_stop:
            why = should_stop()
            if why:
                if progress:
                    progress("stopped before %s: %s" % (n, why))
                break
        try:
            job = svc.start(project, [n], "vc", owner, opts={"golden": True}, wait=True)
            dirs.append(job.get("dir"))
            if progress:
                progress("%s -> %s %s" % (n, job.get("verdict") or job.get("state"), job.get("dir")))
        except Exception as exc:
            if progress:
                progress("%s: %s: %s" % (n, type(exc).__name__, exc))
    return [d for d in dirs if d]
