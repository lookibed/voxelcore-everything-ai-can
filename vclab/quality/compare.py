"""Сравнение прогонов и golden (этап 2): одна функция для одиночных снимков и для серий таймлайна.

Метрики кадра — vclab/quality/metrics.py `metrics()` (f2f/PROTOCOL.md §7: identical %, within tol %, coverage A/B,
bbox, max/mean Δ, diff/heat PNG); быстрый путь — равные sha256 RGB (тогда 100 % без чтения пикселей). Серия (таймлайн,
снимки kf_NNNN + states.jsonl) — порт e2e_compare.py первого проекта паритета: таблица по ключевым кадрам с разбивкой по
областям, сравнение дампов state по категориям (хук compare_state плагина; без него — равенство дампа целиком), первый
такт расхождения (кадр / категория), «вне шума эталона» по baseline (шум J/J из golden.json или reference_noise.json),
кривая drift.png. Кадры разного размера не сравниваются (F2F.md §8).

Источник (сторона A или B): каталог прогона лаборатории (report.json с полем scenario), каталог сценария golden
(<golden_dir>\\<сценарий>: golden.json или PNG + report.json/run.json старых раннеров) или любой такой же каталог
старого раннера. Выход: <out>\\compare.json + report.md (+ *_diff.png, *_heat.png, drift.png)."""
import hashlib
import json
import os
import sys
import time

import numpy as np

from vclab import config

_CMP = None


def cmp_mod():
    """vclab/quality/metrics.py (metrics, write_png; перенос tools/reference/compare.py) — один код метрик."""
    global _CMP
    if _CMP is None:
        from vclab.quality import metrics as c
        _CMP = c
    return _CMP


def load_rgb(path):
    """PNG -> int16 [h, w, 3] (как compare.load, но через Pillow: ~20 раз быстрее чистого питона)."""
    try:
        from PIL import Image
        with Image.open(path) as im:
            a = np.asarray(im.convert("RGB"), dtype=np.uint8)
        return a.astype(np.int16)
    except ImportError:
        return cmp_mod().load(path)


def rgb_sha(path):
    """sha256 RGB-байт кадра построчно сверху вниз — то же, что F2F shot.sha256 (не sha файла PNG)."""
    return hashlib.sha256(load_rgb(path).astype(np.uint8).tobytes()).hexdigest()


def metrics_files(a, b, tol=0, clear=(0, 0, 0), diff_out=None, heat_out=None):
    A, B = load_rgb(a), load_rgb(b)
    if A.shape != B.shape:
        return {"error": "size mismatch: %dx%d vs %dx%d (F2F.md 8: not compared)" % (
            A.shape[1], A.shape[0], B.shape[1], B.shape[0])}
    return cmp_mod().metrics(A, B, tol, clear, diff_out, heat_out)


# ---------------------------------------------------------------------------------------------- источники
def _json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _states(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    r = json.loads(line)
                    if r.get("tick") is not None and not r.get("step"):
                        out[int(r["tick"])] = r
    except OSError:
        return None
    return out or None


def scenario_dir_source(d, name=None):
    """Каталог одного сценария: golden (golden.json) или выход старого раннера (PNG + report.json/run.json)."""
    name = name or os.path.basename(d.rstrip("\\/"))
    shots = {}
    man = _json(os.path.join(d, "golden.json"))
    meta = {"kind": "dir", "dir": d}
    if man:
        meta.update(kind="golden", impl=man.get("impl"), size=man.get("size"), manifest=True,
                    noise=man.get("noise"))
        for sn, s in (man.get("shots") or {}).items():
            shots[sn] = {"path": os.path.join(d, s.get("file") or sn + ".png"), "sha256": s.get("sha256_rgb"),
                         "approved": s.get("approved") or []}
    else:
        rep = _json(os.path.join(d, "report.json")) or _json(os.path.join(d, "run.json")) or {}
        meta.update(impl=rep.get("impl"), size=rep.get("size"))
        known = {}
        for s in rep.get("shots") or []:
            k = s.get("name") or (os.path.splitext(s.get("file", ""))[0] if s.get("file") else None)
            if k:
                known[k] = s.get("sha256")
        for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if fn.endswith(".png") and not fn.endswith(("_diff.png", "_heat.png")) and fn != "drift.png":
                k = fn[:-4]
                # sha из отчёта старого раннера: у Java — RGB, у VoxelCore — файл PNG; для быстрого пути годится
                # только при равенстве с другой стороной того же рода, поэтому пометка
                shots[k] = {"path": os.path.join(d, fn), "sha256": None, "reported_sha256": known.get(k)}
    scn = _json(os.path.join(d, "scenario.json")) or {}
    noise = _json(os.path.join(d, "reference_noise.json"))
    return {"label": d, "meta": meta, "scenarios": {name: {
        "dir": d, "shots": shots, "states": _states(os.path.join(d, "states.jsonl")), "scenario": scn,
        "noise": noise, "kind": "timeline" if "ticks" in scn or any(k.startswith("kf_") for k in shots) else "steps",
        "clear": scn.get("clear"), "regions": scn.get("regions"), "ticks": scn.get("ticks")}}}


def run_source(run_dir):
    rep = _json(os.path.join(run_dir, "report.json")) or {}
    sc = rep.get("scenario")
    if not isinstance(sc, dict) or not sc.get("results"):
        return None                         # не прогон интерпретатора или прогон ещё не закрыт
    out = {"label": rep.get("id") or run_dir, "meta": {"kind": "run", "dir": run_dir, "impl": sc.get("impl"),
                                                        "size": sc.get("size"), "run": rep.get("id")},
           "scenarios": {}}
    for r in sc["results"]:
        d = os.path.join(run_dir, r.get("out") or os.path.join("shots", r["scenario"]))
        shots = {s["name"]: {"path": os.path.join(run_dir, s["file"]), "sha256": s.get("sha256_rgb") or s.get("sha256")}
                 for s in r.get("shots") or []}
        scn = _json(os.path.join(d, "scenario.json")) or {}
        out["scenarios"][r["scenario"]] = {
            "dir": d, "shots": shots, "states": _states(os.path.join(d, "states.jsonl")) if r.get("kind") == "timeline"
            else None, "scenario": scn, "kind": r.get("kind"), "clear": r.get("clear") or scn.get("clear"),
            "regions": scn.get("regions"), "ticks": scn.get("ticks"), "timeline": r.get("timeline"),
            "ok": r.get("ok")}
    return out


def resolve(lab, spec, project=None, scenarios=None):
    """Источник по строке: id прогона, каталог прогона, «golden» (нужны project и scenarios), golden:<сценарий>,
    каталог сценария."""
    if spec == "golden" or spec.startswith("golden:"):
        proj = lab.projects.get(project)
        gd = lab.scen.golden_dir(proj)
        names = [spec.split(":", 1)[1]] if ":" in spec else list(scenarios or [])
        out = {"label": "golden", "meta": {"kind": "golden", "dir": gd}, "scenarios": {}}
        for n in names:
            d = os.path.join(gd, n)
            if os.path.isdir(d):
                src = scenario_dir_source(d, n)
                out["scenarios"][n] = src["scenarios"][n]
                out["meta"].setdefault("impl", src["meta"].get("impl"))
                out["meta"].setdefault("size", src["meta"].get("size"))
            else:
                out["scenarios"][n] = {"dir": d, "shots": {}, "states": None, "missing": True}
        return out
    run = lab.runs.get(spec)
    d = run["dir"] if run and run.get("dir") else config.wsl_to_win(spec)
    if os.path.isfile(os.path.join(d, "report.json")):
        src = run_source(d)
        if src:
            return src
    if os.path.isdir(d):
        return scenario_dir_source(d)
    raise FileNotFoundError("compare: %r is neither a run id, a run dir, golden nor a scenario dir" % spec)


# ---------------------------------------------------------------------------------------------- сравнение
def region_masks(h, w, regions):
    owner = np.full((h, w), -1, np.int16)
    names = list(regions or {})
    for i, n in enumerate(names):
        x0, y0, x1, y1 = regions[n]
        sub = owner[max(0, y0):min(h, y1), max(0, x0):min(w, x1)]
        sub[sub < 0] = i
    return names + ["world"], owner


def compare_shot(pa, pb, out, name, tol, clear, sha_a=None, sha_b=None, regions=None, masks=None):
    if not os.path.exists(pa) or not os.path.exists(pb):
        return {"name": name, "error": "missing in %s" % ("A" if not os.path.exists(pa) else "B")}
    A, B = load_rgb(pa), load_rgb(pb)
    if A.shape != B.shape:
        return {"name": name, "error": "size mismatch: A %dx%d, B %dx%d (F2F.md 8: not compared)" % (
            A.shape[1], A.shape[0], B.shape[1], B.shape[0])}
    c = cmp_mod()
    if sha_a and sha_a == sha_b:
        m = c.metrics(A, B, tol, clear)
        m["sha_equal"] = True
    else:
        m = c.metrics(A, B, tol, clear)
        if m["identical_pct"] < 100:
            m = c.metrics(A, B, tol, clear, os.path.join(out, "%s_diff.png" % name), os.path.join(out, "%s_heat.png"
                                                                                               % name))
        m["sha_equal"] = bool(sha_a and sha_b and sha_a == sha_b) or m["identical_pct"] >= 100
    m["name"] = name
    m["a"], m["b"] = pa, pb
    m["sha_a"], m["sha_b"] = sha_a, sha_b
    if regions:
        names, owner = masks if masks else region_masks(A.shape[0], A.shape[1], regions)
        diff = np.any(A != B, axis=2)
        reg = {}
        for i, n in enumerate(names):
            sel = owner == (i if n != "world" else -1)
            tot = int(sel.sum())
            dp = int((diff & sel).sum())
            reg[n] = {"diff": dp, "pixels": tot, "pct": round(100.0 * (tot - dp) / tot, 3) if tot else 100.0}
        m["regions"] = reg
    return m


def default_compare_state(sa, sb):
    eq = json.dumps(sa, sort_keys=True, default=str) == json.dumps(sb, sort_keys=True, default=str)
    return {"state": (eq, {} if eq else {"a": "differs", "b": "differs"})}


def series(sa, sb, out, tol, clear, regions, compare_state, baseline=None, title=""):
    """Серия таймлайна: ключевые кадры kf_NNNN + дампы state по тактам. -> dict (как e2e_compare compare.json)."""
    kf = lambda shots: {int(k[3:7]): k for k in shots if k.startswith("kf_") and len(k) == 7}
    ka, kb = kf(sa["shots"]), kf(sb["shots"])
    rows, region_tot = [], {}
    first_kf = None
    masks = None
    for t in sorted(set(ka) | set(kb)):
        if t not in ka or t not in kb:
            rows.append({"tick": t, "error": "missing in " + ("A" if t not in ka else "B")})
            continue
        a, b = sa["shots"][ka[t]], sb["shots"][kb[t]]
        if masks is None and regions and os.path.exists(a["path"]):
            img = load_rgb(a["path"])
            masks = region_masks(img.shape[0], img.shape[1], regions)
        m = compare_shot(a["path"], b["path"], out, ka[t], tol, clear, a.get("sha256"), b.get("sha256"), regions,
                         masks)
        m["tick"] = t
        if "error" not in m:
            for n, r in (m.get("regions") or {}).items():
                region_tot[n] = region_tot.get(n, 0) + r["diff"]
            if m["identical_pct"] < 100 and first_kf is None:
                first_kf = t
        rows.append(m)
    cats, first, first_detail, st_rows = [], {}, {}, []
    A, B = sa.get("states") or {}, sb.get("states") or {}
    common = sorted(set(A) & set(B))
    for t in common:
        ra, rb = A[t], B[t]
        if "state" not in ra or "state" not in rb:
            st_rows.append({"tick": t, "error": ra.get("error") or rb.get("error")})
            continue
        res = compare_state(ra["state"], rb["state"])
        for c in res:
            if c not in cats:
                cats.append(c)
                first.setdefault(c, None)
        row = {"tick": t, **{c: bool(res[c][0]) for c in res}}
        wa = ((ra["state"].get("world") or {}) if isinstance(ra["state"], dict) else {}).get("world_packets")
        wb = ((rb["state"].get("world") or {}) if isinstance(rb["state"], dict) else {}).get("world_packets")
        if wa is not None or wb is not None:
            row["world_packets"] = [wa, wb]
        st_rows.append(row)
        for c in res:
            if not res[c][0] and first.get(c) is None:
                first[c] = t
                first_detail[c] = res[c][1]
    cand = [v for v in [first_kf] + list(first.values()) if v is not None]
    first_any = min(cand) if cand else None
    base_kf, base_st = {}, {}
    if baseline:
        base_kf = {r["tick"]: r.get("identical_pct") for r in baseline.get("keyframes", []) if "tick" in r}
        base_st = {r["tick"]: r for r in baseline.get("states", [])}
    first_clean = None
    if baseline:
        c2 = [r["tick"] for r in rows if r.get("identical_pct", 100) < 100 and (base_kf.get(r["tick"]) or 0) >= 100]
        for r in st_rows:
            bs = base_st.get(r["tick"]) or {}
            if any(c in r and not r[c] and bs.get(c, False) for c in cats):
                c2.append(r["tick"])
        first_clean = min(c2) if c2 else None
    ticks = int(sa.get("ticks") or sb.get("ticks") or max(list(A) + list(B) + [1]))
    ended_a = (sa.get("timeline") or {}).get("last_tick") or (max(A) if A else None)
    ended_b = (sb.get("timeline") or {}).get("last_tick") or (max(B) if B else None)
    marks = {k: v for k, v in first.items() if v is not None}
    if ended_b is not None and ended_b < ticks:
        marks["B stopped"] = ended_b
    good = [r for r in rows if "identical_pct" in r]
    drift = os.path.join(out, "drift_%s.png" % title.replace("/", "_")) if title else os.path.join(out, "drift.png")
    how = drift_png(drift, good, marks, ticks, title, base_kf)
    return {"keyframes": rows, "states": st_rows, "categories": cats, "first_detail": first_detail,
            "summary": {"keyframes": len(good), "keyframes_100": sum(1 for r in good if r["identical_pct"] >= 100),
                        "min_identical_pct": min([r["identical_pct"] for r in good], default=None),
                        "mean_identical_pct": round(sum(r["identical_pct"] for r in good) / len(good), 3)
                        if good else None,
                        "first_divergent_keyframe": first_kf, "first_state_divergence": first,
                        "first_divergence_tick": first_any, "first_divergence_outside_reference_noise": first_clean,
                        "baseline": bool(baseline), "timeline_ticks_a": ended_a, "timeline_ticks_b": ended_b,
                        "ticks": ticks, "states_compared": len(common),
                        "region_diff_pixels": dict(sorted(region_tot.items(), key=lambda kv: -kv[1])),
                        "drift_png": drift, "drift_plot": how},
            "baseline_kf": base_kf}


def drift_png(path, rows, marks, ticks, title, base=None):
    try:
        from matplotlib.figure import Figure
        from matplotlib.backends.backend_agg import FigureCanvasAgg
        fig = Figure(figsize=(10, 4), dpi=100)
        FigureCanvasAgg(fig)
        ax = fig.add_subplot(111)
        kf = [(r["tick"], r["identical_pct"]) for r in rows]
        if kf:
            t, v = zip(*kf)
            ax.plot(t, v, "o-", ms=3, lw=1.2, color="#1f5fbf", label="identical %")
        bs = sorted((t, v) for t, v in (base or {}).items() if v is not None)
        if bs:
            t, v = zip(*bs)
            ax.plot(t, v, "s:", ms=2, lw=0.8, color="#7f7f7f", label="reference J/J %")
        tl = [(r["tick"], r["within_tol_pct"]) for r in rows]
        if tl:
            t, v = zip(*tl)
            ax.plot(t, v, "-", lw=0.8, color="#bf7f1f", label="within tol %")
        for k, tk in (marks or {}).items():
            ax.axvline(tk, color="#bf1f1f", lw=0.6, ls="--")
            ax.text(tk, 1, " " + k, rotation=90, va="bottom", fontsize=7, color="#bf1f1f")
        ax.set_xlim(0, ticks)
        ax.set_ylim(0, 100.5)
        ax.set_xlabel("tick")
        ax.set_ylabel("% pixels")
        ax.set_title(title, fontsize=9)
        ax.grid(alpha=0.3)
        ax.legend(loc="lower left", fontsize=8)
        fig.tight_layout()
        fig.savefig(path)
        return "matplotlib"
    except Exception:
        W, H, L, Bm = 820, 320, 10, 10
        img = np.full((H, W, 3), 255, np.int16)
        pw, ph = W - 2 * L, H - 2 * Bm
        X = lambda t: L + int(round(t / max(1, ticks) * (pw - 1)))
        Y = lambda v: Bm + int(round((100 - v) / 100 * (ph - 1)))
        for g in range(0, 101, 10):
            img[Y(g), L:L + pw] = 220
        for tk in (marks or {}).values():
            img[Bm:Bm + ph, X(tk)] = [220, 40, 40]
        for r in rows:
            x, y = X(r["tick"]), Y(r["identical_pct"])
            img[max(0, y - 2):y + 3, max(0, x - 2):x + 3] = [30, 95, 190]
        cmp_mod().write_png(path, img)
        return "numpy"


def compare_sources(A, B, out, tol=None, series_tol=3, clear=None, regions=None, compare_state=None,
                    scenarios=None, title="", default_regions=None):
    """A, B — источники (resolve). -> отчёт {summary, scenarios: {имя: {shots|series}}}; пишет compare.json и
    report.md в out."""
    os.makedirs(out, exist_ok=True)
    t0 = time.time()
    sa, sb = A["meta"].get("size"), B["meta"].get("size")
    rep = {"schema": 1, "a": A["label"], "b": B["label"], "a_meta": A["meta"], "b_meta": B["meta"], "out": out,
           "date": time.strftime("%Y-%m-%d %H:%M:%S"), "scenarios": {}}
    if sa and sb and sa != sb:
        rep["error"] = "frame sizes differ: A %s, B %s (F2F.md 8: not compared)" % (sa, sb)
        _write(out, rep)
        return rep
    names = scenarios or [n for n in A["scenarios"] if n in B["scenarios"]] or list(B["scenarios"])
    tot = {"shots": 0, "identical_100": 0, "sha_equal": 0, "errors": 0}
    for n in names:
        a, b = A["scenarios"].get(n), B["scenarios"].get(n)
        if not a or not b or a.get("missing") or b.get("missing"):
            rep["scenarios"][n] = {"error": "scenario %s missing in %s" % (n, "A" if not a or a.get("missing")
                                                                          else "B")}
            tot["errors"] += 1
            continue
        cl = clear or b.get("clear") or a.get("clear") or [0, 0, 0]
        rg = regions if regions is not None else (b.get("regions") or a.get("regions"))
        sub = os.path.join(out, n) if len(names) > 1 else out
        os.makedirs(sub, exist_ok=True)
        timeline = (a.get("kind") == "timeline" or b.get("kind") == "timeline") and (a.get("states") or b.get(
            "states") or any(k.startswith("kf_") for k in a["shots"]))
        if timeline:
            rg = rg or default_regions
            base = b.get("noise") or a.get("noise")
            if isinstance(base, dict) and "keyframes" not in base and base.get("kf"):
                base = {"keyframes": [{"tick": int(t), "identical_pct": v} for t, v in base["kf"].items()]}
            s = series(a, b, sub, series_tol if tol is None else tol, cl, rg,
                       compare_state or default_compare_state, base if isinstance(base, dict) else None,
                       title=n)
            rows = [r for r in s["keyframes"]]
            rep["scenarios"][n] = {"kind": "timeline", "series": s, "tol": series_tol if tol is None else tol,
                                   "clear": cl}
        else:
            rows = []
            for name in sorted(set(a["shots"]) | set(b["shots"])):
                if name not in a["shots"] or name not in b["shots"]:
                    rows.append({"name": name, "error": "missing in " + ("A" if name not in a["shots"] else "B")})
                    continue
                x, y = a["shots"][name], b["shots"][name]
                m = compare_shot(x["path"], y["path"], sub, name, tol or 0, cl, x.get("sha256"), y.get("sha256"), rg)
                if x.get("approved") and m.get("sha_b") in x["approved"]:
                    m["approved_variant"] = True
                rows.append(m)
            rep["scenarios"][n] = {"kind": "steps", "shots": rows, "tol": tol or 0, "clear": cl}
        for m in rows:
            tot["shots"] += 1
            if "error" in m:
                tot["errors"] += 1
            else:
                tot["identical_100"] += int(m["identical_pct"] >= 100)
                tot["sha_equal"] += int(bool(m.get("sha_equal")))
    rep["summary"] = dict(tot, all_identical=tot["shots"] > 0 and tot["identical_100"] == tot["shots"],
                          dur_s=round(time.time() - t0, 2))
    _write(out, rep)
    return rep


def _fmt_row(m):
    if "error" in m:
        return "| %s | %s | | | | | |" % (m.get("name", m.get("tick")), m["error"])
    return "| %s | %.3f | %.3f | %.2f / %.2f | %d | %s | %s |" % (
        m.get("name"), m["identical_pct"], m["within_tol_pct"], m["coverage_a_pct"], m["coverage_b_pct"],
        m["max_delta"], m.get("bbox") or "-", "=" if m.get("sha_equal") else "≠")


def _write(out, rep):
    with open(os.path.join(out, "compare.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)
    L = ["# compare: %s vs %s" % (rep["a"], rep["b"]), "",
         "- A: `%s` (%s, %s)" % (rep["a_meta"].get("dir"), rep["a_meta"].get("kind"), rep["a_meta"].get("impl")),
         "- B: `%s` (%s, %s)" % (rep["b_meta"].get("dir"), rep["b_meta"].get("kind"), rep["b_meta"].get("impl")),
         "- %s" % rep["date"]]
    if rep.get("error"):
        L += ["", "**%s**" % rep["error"]]
    s = rep.get("summary") or {}
    if s:
        L += ["- снимков %d, 100 %%: %d, sha равны: %d, ошибок: %d" % (s["shots"], s["identical_100"], s["sha_equal"],
                                                                       s["errors"])]
    for n, sc in rep["scenarios"].items():
        L += ["", "## %s" % n, ""]
        if sc.get("error"):
            L.append("**%s**" % sc["error"])
            continue
        if sc["kind"] == "steps":
            L += ["| снимок | identical %% | tol%d %% | покрытие A/B %% | max Δ | bbox | sha |" % sc["tol"],
                  "|---|---|---|---|---|---|---|"] + [_fmt_row(m) for m in sc["shots"]]
            continue
        se = sc["series"]
        sm = se["summary"]
        L += ["- ключевых кадров %d, 100 %%: %d; минимум %s %%, среднее %s %%" % (
            sm["keyframes"], sm["keyframes_100"], sm["min_identical_pct"], sm["mean_identical_pct"]),
            "- дампов state: %d; первое расхождение по категориям: %s" % (sm["states_compared"], ", ".join(
                "%s — %s" % (c, "нет" if v is None else "такт %d" % v) for c, v in sm["first_state_divergence"].items())
                or "—"),
            "- **первый такт расхождения: %s**%s" % (sm["first_divergence_tick"], "; вне шума эталона: **%s**" % sm[
                "first_divergence_outside_reference_noise"] if sm["baseline"] else ""),
            "- тактов пройдено: A %s, B %s из %s" % (sm["timeline_ticks_a"], sm["timeline_ticks_b"], sm["ticks"]),
            "", "![drift](%s)" % os.path.basename(sm["drift_png"]), "",
            "| такт | identical % | tol% | J/J % | покрытие A/B % | max Δ | области (px) | state |", "|---|---|---|---|---|---|---|---|"]
        stmap = {r["tick"]: r for r in se["states"]}
        for r in se["keyframes"]:
            if "error" in r:
                L.append("| %d | %s | | | | | | |" % (r["tick"], r["error"]))
                continue
            st = stmap.get(r["tick"]) or {}
            flags = "".join("=" if st.get(c) else ("≠" if c in st else "·") for c in se["categories"])
            bk = se["baseline_kf"].get(r["tick"])
            L.append("| %d | %.3f | %.3f | %s | %.2f / %.2f | %d | %s | %s |" % (
                r["tick"], r["identical_pct"], r["within_tol_pct"], "—" if bk is None else "%.3f" % bk,
                r["coverage_a_pct"], r["coverage_b_pct"], r["max_delta"],
                " ".join("%s:%d" % (k, v["diff"]) for k, v in (r.get("regions") or {}).items() if v["diff"]) or "-",
                flags))
        for c, d in se["first_detail"].items():
            L += ["", "state `%s`, первый такт %s:" % (c, sm["first_state_divergence"].get(c)), "", "```",
                  json.dumps(d, ensure_ascii=False, default=str)[:3000], "```"]
    with open(os.path.join(rep["out"], "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


# ---------------------------------------------------------------------------------------------- точки входа
def compare_run_golden(lab, proj, run_dir, report):
    """После прогона с --golden: каждый сценарий против <golden_dir>\\<сценарий> (как старые раннеры)."""
    names = [r["scenario"] for r in report.get("results") or []]
    A = resolve(lab, "golden", proj.name, names)
    B = run_source(run_dir) if os.path.exists(os.path.join(run_dir, "report.json")) else None
    if B is None or not B["scenarios"]:
        B = _source_from_report(run_dir, report)
    hooks = proj.scenario_hooks
    rep = compare_sources(A, B, os.path.join(run_dir, "vs_golden"), tol=None if _is_series(report) else int(
        (proj.compare or {}).get("tol", 0)), regions=None, compare_state=hooks.get("compare_state"),
        series_tol=int((proj.compare or {}).get("series_tol", 3)), default_regions=(proj.compare or {}).get("regions"))
    return {"out": rep["out"], "summary": rep.get("summary"), "error": rep.get("error"),
            "per_scenario": {n: _brief(s) for n, s in rep["scenarios"].items()}}


def _is_series(report):
    return any(r.get("kind") == "timeline" for r in report.get("results") or [])


def _source_from_report(run_dir, report):
    out = {"label": run_dir, "meta": {"kind": "run", "dir": run_dir, "impl": report.get("impl"),
                                      "size": report.get("size")}, "scenarios": {}}
    for r in report.get("results") or []:
        d = os.path.join(run_dir, r.get("out") or os.path.join("shots", r["scenario"]))
        out["scenarios"][r["scenario"]] = {
            "dir": d, "shots": {s["name"]: {"path": os.path.join(run_dir, s["file"]),
                                            "sha256": s.get("sha256_rgb") or s.get("sha256")}
                                for s in r.get("shots") or []},
            "states": _states(os.path.join(d, "states.jsonl")) if r.get("kind") == "timeline" else None,
            "scenario": _json(os.path.join(d, "scenario.json")) or {}, "kind": r.get("kind"),
            "clear": r.get("clear"), "regions": r.get("regions"), "timeline": r.get("timeline"),
            "ticks": (r.get("timeline") or {}).get("ticks")}
    return out


def _brief(sc):
    if sc.get("error"):
        return {"error": sc["error"]}
    if sc["kind"] == "steps":
        return {m.get("name"): (m.get("error") or round(m["identical_pct"], 3)) for m in sc["shots"]}
    s = sc["series"]["summary"]
    return {k: s[k] for k in ("keyframes", "keyframes_100", "min_identical_pct", "first_divergence_tick",
                              "first_divergence_outside_reference_noise")}


def compare_api(lab, a, b, project=None, out=None, tol=None, scenarios=None):
    """lab compare <A> <B|golden>: B «golden» — golden сценариев A (A — прогон). Выход — в каталог прогона B
    (vs_<A>) или A (vs_golden), иначе out."""
    A = resolve(lab, a, project)
    if b == "golden" or b.startswith("golden:"):
        if not project:
            rep = _json(os.path.join(A["meta"]["dir"], "report.json")) or {}
            project = rep.get("project") or (rep.get("scenario") or {}).get("project")
        B = resolve(lab, b, project, list(A["scenarios"]))
        A, B = B, A                       # A — эталон, B — прогон (как e2e_compare)
    else:
        B = resolve(lab, b, project)
    proj = None
    try:
        proj = lab.projects.get(project) if project else None
    except KeyError:
        proj = None
    out = out or os.path.join(B["meta"]["dir"], "vs_" + _short(A["label"]))
    hooks = proj.scenario_hooks if proj else {}
    pc = (proj.compare if proj else {}) or {}
    rep = compare_sources(A, B, out, tol=tol, compare_state=hooks.get("compare_state"), scenarios=scenarios,
                          series_tol=int(pc.get("series_tol", 3)), default_regions=pc.get("regions"))
    return {"ok": not rep.get("error"), "out": out, "summary": rep.get("summary"), "error": rep.get("error"),
            "per_scenario": {n: _brief(s) for n, s in rep["scenarios"].items()},
            "report_md": os.path.join(out, "report.md")}


def _short(label):
    s = os.path.basename(str(label).rstrip("\\/")) or str(label)
    return s[:60]
