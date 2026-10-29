#!/usr/bin/env python3
"""Compare two E2E series (agents/F2F.md 8): A = reference (golden), B = run.

  python3 tools/alphamine/e2e/e2e_compare.py <repo>/projects/alphamine/external/golden/e2e_walk1 <repo>/projects/alphamine/external/runs/<run>/e2e_walk1
      [--out DIR (default B/vs_<A>)] [--tol 3] [--clear 0,0,0]

Keyframes (kf_NNNN.png present on both sides): identical % / within tol % / coverage A,B (tools/reference/compare.py
metrics) + per-region breakdown of the differing pixels (scenario "regions", first matching rect wins, rest = world).
States (states.jsonl, same tick on both sides): player pos/motion bit-exact (VoxelCore `exact` %.17g strings, Java
doubles), yaw/pitch as float32, onGround/health/slot; inventory; block hash (FNV-1a cube); entity list (type and
position within 1e-9, in order; ids only shown - the VoxelCore JSON writer keeps ~15 digits); screen; chat; world_packets (info only: network
arrival is not deterministic). Writes e2e_report.md, compare.json, drift.png (matplotlib of the Windows Python if
present, else a numpy raster via compare.write_png), and diff/heat PNGs of every keyframe that is not 100 %.
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))  # корень репозитория (было: рабочий каталог движка)
sys.path.insert(0, os.path.join(REPO, "projects", "vc", "reference"))
import compare as cmp  # noqa: E402

WINPY = "/mnt/c/Python313/python.exe"
DEFAULT_REGIONS = {"hotbar": [245, 400, 609, 480], "crosshair": [411, 224, 443, 256], "chat": [0, 190, 660, 480],
                   "hand": [500, 240, 854, 480]}
POS = ("x", "y", "z", "mx", "my", "mz")


def wsl(p):
    p = p.replace("\\", "/")
    return "/mnt/" + p[0].lower() + p[2:] if len(p) > 2 and p[1:3] == ":/" else p


def win(p):
    return p[5].upper() + ":\\" + p[7:].replace("/", "\\") if p.startswith("/mnt/") and len(p) > 6 else p


def load_series(d):
    run = {}
    if os.path.exists(os.path.join(d, "run.json")):
        with open(os.path.join(d, "run.json"), encoding="utf-8") as f:
            run = json.load(f)
    scn = {}
    if os.path.exists(os.path.join(d, "scenario.json")):
        with open(os.path.join(d, "scenario.json"), encoding="utf-8") as f:
            scn = json.load(f)
    states = {}
    with open(os.path.join(d, "states.jsonl"), encoding="utf-8") as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                states[r["tick"]] = r
    shots = {int(fn[3:7]): os.path.join(d, fn) for fn in os.listdir(d)
             if fn.startswith("kf_") and fn.endswith(".png") and len(fn) == 11}
    sha = {s["tick"]: s.get("sha256") for s in run.get("shots", [])}
    return {"dir": d, "run": run, "scn": scn, "states": states, "shots": shots, "sha": sha}


def f32(v):
    return None if v is None else float(np.float32(v))


def pnum(p, k):
    ex = (p.get("exact") or {}).get(k)
    if ex is not None:
        return float(ex)
    v = p.get(k)
    return None if v is None else float(v)


def inv_key(p):
    return sorted((int(i.get("slot", -1)), int(i.get("id", 0)), int(i.get("count", 0)), int(i.get("meta", 0)))
                  for i in (p.get("inventory") or []))


def ents(st):
    return [(e.get("id"), e.get("type"), e.get("x"), e.get("y"), e.get("z"))
            for e in ((st.get("world") or {}).get("entities") or [])]


def ents_equal(a, b):
    if len(a) != len(b):
        return False
    for u, v in zip(a, b):
        if u[1] != v[1]:   # type; ids are the server's counter (differs between server runs), shown in the detail only
            return False
        for i in (2, 3, 4):
            if u[i] is None or v[i] is None or abs(float(u[i]) - float(v[i])) > 1e-9:
                return False
    return True


def compare_state(sa, sb):
    """-> {category: (equal, detail)}"""
    out = {}
    pa, pb = sa.get("player") or {}, sb.get("player") or {}
    d = {}
    eq = True
    for k in POS:
        a, b = pnum(pa, k), pnum(pb, k)
        if a != b:
            eq = False
            d[k] = [a, b, None if a is None or b is None else b - a]
    for k in ("yaw", "pitch"):
        a, b = f32(pa.get(k)), f32(pb.get(k))
        if a != b:
            eq = False
            d[k] = [a, b, None if a is None or b is None else b - a]
    for k in ("onGround", "health", "slot"):
        if pa.get(k) != pb.get(k):
            eq = False
            d[k] = [pa.get(k), pb.get(k)]
    out["player"] = (eq, d)
    ia, ib = inv_key(pa), inv_key(pb)
    out["inventory"] = (ia == ib, {} if ia == ib else {"a": ia, "b": ib})
    ha, hb = sa.get("hash") or {}, sb.get("hash") or {}
    hk = lambda h: (h.get("blocks"), h.get("meta"), tuple(h.get("center") or ()))
    out["blocks"] = (hk(ha) == hk(hb), {} if hk(ha) == hk(hb) else {"a": list(hk(ha)), "b": list(hk(hb))})
    ea, eb = ents(sa), ents(sb)
    e_eq = ents_equal(ea, eb)
    out["entities"] = (e_eq, {} if e_eq else {"a": ea, "b": eb})
    out["screen"] = (sa.get("screen") == sb.get("screen"), {"a": sa.get("screen"), "b": sb.get("screen")})
    ca = [c.get("text") for c in sa.get("chat") or []]
    cb = [c.get("text") for c in sb.get("chat") or []]
    out["chat"] = (ca == cb, {} if ca == cb else {"a": ca, "b": cb})
    return out


def region_masks(h, w, regions):
    owner = np.full((h, w), -1, np.int16)
    names = list(regions)
    for i, n in enumerate(names):
        x0, y0, x1, y1 = regions[n]
        sub = owner[max(0, y0):min(h, y1), max(0, x0):min(w, x1)]
        sub[sub < 0] = i
    return names + ["world"], owner


def drift_png(path, rows, first_state, ticks, title, base=None):
    data = {"base": sorted([t, v] for t, v in (base or {}).items() if v is not None),"kf": [[r["tick"], r.get("identical_pct")] for r in rows if r.get("identical_pct") is not None],
            "tol": [[r["tick"], r.get("within_tol_pct")] for r in rows if r.get("within_tol_pct") is not None],
            "first_state": first_state, "ticks": ticks, "title": title}
    jpath = os.path.splitext(path)[0] + ".json"
    with open(jpath, "w") as f:
        json.dump(data, f)
    if os.path.exists(WINPY):
        script = r'''
import json, sys
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
d = json.load(open(sys.argv[1]))
fig, ax = plt.subplots(figsize=(10, 4), dpi=100)
if d["kf"]:
    t, v = zip(*d["kf"]); ax.plot(t, v, "o-", ms=3, lw=1.2, color="#1f5fbf", label="identical %")
if d["base"]:
    t, v = zip(*d["base"]); ax.plot(t, v, "s:", ms=2, lw=0.8, color="#7f7f7f", label="reference Java vs Java %")
if d["tol"]:
    t, v = zip(*d["tol"]); ax.plot(t, v, "-", lw=0.8, color="#bf7f1f", label="within tol %")
for k, tk in (d["first_state"] or {}).items():
    if tk is not None:
        ax.axvline(tk, color="#bf1f1f", lw=0.6, ls="--"); ax.text(tk, 1, " " + k, rotation=90, va="bottom", fontsize=7, color="#bf1f1f")
ax.set_xlim(0, d["ticks"]); ax.set_ylim(0, 100.5); ax.set_xlabel("tick"); ax.set_ylabel("% pixels")
ax.set_title(d["title"], fontsize=9); ax.grid(alpha=0.3); ax.legend(loc="lower left", fontsize=8)
fig.tight_layout(); fig.savefig(sys.argv[2])
'''
        spath = os.path.splitext(path)[0] + "_plot.py"
        with open(spath, "w") as f:
            f.write(script)
        r = subprocess.run([WINPY, win(spath), win(jpath), win(path)], capture_output=True, text=True, cwd="/mnt/c")
        os.remove(spath)
        if r.returncode == 0 and os.path.exists(path):
            return "matplotlib"
    # fallback: numpy raster 800x300, y = 0..100 %, grid every 10 %, red lines = first state divergences
    W, H, L, B = 820, 320, 10, 10
    img = np.full((H, W, 3), 255, np.int16)
    pw, ph = W - 2 * L, H - 2 * B
    X = lambda t: L + int(round(t / max(1, ticks) * (pw - 1)))
    Y = lambda v: B + int(round((100 - v) / 100 * (ph - 1)))
    for g in range(0, 101, 10):
        img[Y(g), L:L + pw] = 220
    for tk in (first_state or {}).values():
        if tk is not None:
            img[B:B + ph, X(tk)] = [220, 40, 40]
    pts = [(X(t), Y(v)) for t, v in data["kf"]]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(n + 1):
            img[y0 + (y1 - y0) * i // n, x0 + (x1 - x0) * i // n] = [30, 95, 190]
    for x, y in pts:
        img[max(0, y - 2):y + 3, max(0, x - 2):x + 3] = [30, 95, 190]
    cmp.write_png(path, img)
    return "numpy"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a", help="reference series dir (golden/<name>)")
    ap.add_argument("b", help="run series dir")
    ap.add_argument("--out", default=None)
    ap.add_argument("--tol", type=int, default=3)
    ap.add_argument("--clear", default="0,0,0")
    ap.add_argument("--baseline", default=None,
                    help="compare.json of a Java-vs-Java pair (reference noise): keyframes/state ticks where the "
                         "reference does not repeat itself are marked, and a first divergence outside them is given")
    o = ap.parse_args()
    A, B = load_series(wsl(o.a)), load_series(wsl(o.b))
    clear = [int(v) for v in o.clear.split(",")]
    base_kf, base_st = {}, {}
    if o.baseline:
        with open(wsl(o.baseline), encoding="utf-8") as f:
            bj = json.load(f)
        base_kf = {r["tick"]: r.get("identical_pct") for r in bj.get("keyframes", []) if "tick" in r}
        base_st = {r["tick"]: r for r in bj.get("states", [])}
    out = wsl(o.out) if o.out else os.path.join(B["dir"], "vs_" + os.path.basename(os.path.dirname(A["dir"].rstrip("/")))
                                                if os.path.basename(A["dir"].rstrip("/")) == os.path.basename(B["dir"].rstrip("/"))
                                                else os.path.basename(A["dir"].rstrip("/")))
    os.makedirs(out, exist_ok=True)
    scn = B["scn"] or A["scn"]
    regions = scn.get("regions") or DEFAULT_REGIONS
    ticks = int(scn.get("ticks") or max(list(A["states"]) + list(B["states"]) + [1]))
    ia, ib = A["run"].get("impl", "?"), B["run"].get("impl", "?")

    # ---------------------------------------------------------------- keyframes
    rows = []
    region_tot = {}
    first_kf = None
    names = owner = None
    for t in sorted(set(A["shots"]) | set(B["shots"])):
        if t not in A["shots"] or t not in B["shots"]:
            rows.append({"tick": t, "error": "missing in " + ("A" if t not in A["shots"] else "B")})
            continue
        a_img, b_img = cmp.load(A["shots"][t]), cmp.load(B["shots"][t])
        if a_img.shape != b_img.shape:
            rows.append({"tick": t, "error": "size %s vs %s" % (a_img.shape[:2], b_img.shape[:2])})
            continue
        if A["sha"].get(t) and A["sha"].get(t) == B["sha"].get(t):
            m = cmp.metrics(a_img, b_img, o.tol, clear)
        else:
            m = cmp.metrics(a_img, b_img, o.tol, clear)
            if m["identical_pct"] < 100:
                m = cmp.metrics(a_img, b_img, o.tol, clear, os.path.join(out, "kf_%04d_diff.png" % t),
                                os.path.join(out, "kf_%04d_heat.png" % t))
        if names is None:
            names, owner = region_masks(a_img.shape[0], a_img.shape[1], regions)
        diff = np.any(a_img != b_img, axis=2)
        reg = {}
        for i, n in enumerate(names):
            sel = owner == (i if n != "world" else -1)
            tot = int(sel.sum())
            dp = int((diff & sel).sum())
            reg[n] = {"diff": dp, "pixels": tot, "pct": round(100.0 * (tot - dp) / tot, 3) if tot else 100.0}
            region_tot[n] = region_tot.get(n, 0) + dp
        row = {"tick": t, "identical_pct": m["identical_pct"], "within_tol_pct": m["within_tol_pct"],
               "coverage_a_pct": m["coverage_a_pct"], "coverage_b_pct": m["coverage_b_pct"],
               "max_delta": m["max_delta"], "bbox": m.get("bbox"), "regions": reg}
        if m["identical_pct"] < 100 and first_kf is None:
            first_kf = t
        rows.append(row)

    # ---------------------------------------------------------------- states
    cats = ("player", "inventory", "blocks", "entities", "screen", "chat")
    first = {c: None for c in cats}
    first_detail = {}
    st_rows = []
    common = sorted(set(A["states"]) & set(B["states"]))
    for t in common:
        ra, rb = A["states"][t], B["states"][t]
        if "state" not in ra or "state" not in rb:
            st_rows.append({"tick": t, "error": ra.get("error") or rb.get("error")})
            continue
        res = compare_state(ra["state"], rb["state"])
        wa = (ra["state"].get("world") or {}).get("world_packets")
        wb = (rb["state"].get("world") or {}).get("world_packets")
        st_rows.append({"tick": t, **{c: res[c][0] for c in cats}, "world_packets": [wa, wb]})
        for c in cats:
            if not res[c][0] and first[c] is None:
                first[c] = t
                first_detail[c] = res[c][1]
    first_state = {c: first[c] for c in cats}
    cand = [v for v in [first_kf] + list(first.values()) if v is not None]
    first_any = min(cand) if cand else None
    first_clean = None   # first divergence where the reference (baseline Java vs Java) repeated itself
    if o.baseline:
        c2 = [r["tick"] for r in rows if r.get("identical_pct", 100) < 100 and base_kf.get(r["tick"], 0) >= 100]
        for r in st_rows:
            b = base_st.get(r["tick"]) or {}
            if any(c in r and not r[c] and b.get(c, False) for c in cats):
                c2.append(r["tick"])
        first_clean = min(c2) if c2 else None
    ended_a = (A["run"].get("timeline") or {}).get("last_tick") or max(A["states"], default=None)
    ended_b = (B["run"].get("timeline") or {}).get("last_tick") or max(B["states"], default=None)

    # ---------------------------------------------------------------- outputs
    title = "%s: %s (A) vs %s (B)" % (scn.get("name", "?"), ia, ib)
    marks = {k: v for k, v in first_state.items() if k in ("player", "blocks", "inventory", "entities")}
    if ended_b is not None and ended_b < ticks:
        marks["B stopped"] = ended_b
    how = drift_png(os.path.join(out, "drift.png"), rows, marks,
                    ticks, title, base_kf)
    good = [r for r in rows if "identical_pct" in r]
    summary = {"a": win(A["dir"]), "b": win(B["dir"]), "impl_a": ia, "impl_b": ib, "keyframes": len(good),
               "keyframes_100": sum(1 for r in good if r["identical_pct"] >= 100),
               "min_identical_pct": min([r["identical_pct"] for r in good], default=None),
               "mean_identical_pct": round(sum(r["identical_pct"] for r in good) / len(good), 3) if good else None,
               "first_divergent_keyframe": first_kf, "first_state_divergence": first_state,
               "first_divergence_tick": first_any, "first_divergence_outside_reference_noise": first_clean,
               "timeline_ticks_a": ended_a, "timeline_ticks_b": ended_b, "states_compared": len(common),
               "region_diff_pixels": dict(sorted(region_tot.items(), key=lambda kv: -kv[1])), "drift_png": win(os.path.join(out, "drift.png")),
               "drift_plot": how}
    with open(os.path.join(out, "compare.json"), "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "keyframes": rows, "states": st_rows, "first_detail": first_detail}, f,
                  ensure_ascii=False, indent=1)
    rel = lambda p: os.path.relpath(p, out).replace("\\", "/")
    L = ["# E2E %s: %s vs %s" % (scn.get("name", "?"), ia, ib), "",
         "- A (эталон): `%s`" % win(A["dir"]), "- B (прогон): `%s`" % win(B["dir"]),
         "- ключевых кадров: %d, из них 100 %%: %d; минимум %s %%, среднее %s %%" % (
             summary["keyframes"], summary["keyframes_100"], summary["min_identical_pct"], summary["mean_identical_pct"]),
         "- дампов state сравнено: %d; первое расхождение: %s" % (len(common), ", ".join(
             "%s — %s" % (c, "нет" if first[c] is None else "такт %d" % first[c]) for c in cats)),
         "- **первый такт расхождения: %s**" % first_any
         + ("; вне шума эталона (базовая пара Java/Java): **%s**" % first_clean if o.baseline else ""),
         "- тактов пройдено: A %s, B %s из %s%s" % (ended_a, ended_b, ticks, " — **B остановился раньше**"
                                                    if ended_b is not None and ended_b < ticks else ""),
         "- world_packets в конце: A %s, B %s (в реальном времени приход пакетов по тактам не детерминирован; на пошаговом сервере — детерминирован, F2F.md 9)" % (
             (st_rows[-1].get("world_packets") or [None, None])[0] if st_rows else None,
             (st_rows[-1].get("world_packets") or [None, None])[1] if st_rows else None),
         "", "![drift](%s)" % rel(os.path.join(out, "drift.png")), "",
         "## Ключевые кадры", "",
         "| такт | identical %% | tol%d %% | J/J %% | покрытие A/B %% | max Δ | %s | state (игрок, инв., блоки, сущн., экран) |" % (
             o.tol, " | ".join(n + " px" for n in (names or []))),
         "|---|---|---|---|---|---|%s---|" % ("---|" * len(names or []))]
    stmap = {r["tick"]: r for r in st_rows}
    for r in rows:
        if "error" in r:
            L.append("| %d | %s | | | | | %s |" % (r["tick"], r["error"], " | " * len(names or [])))
            continue
        s = stmap.get(r["tick"]) or {}
        flags = "".join("=" if s.get(c) else ("≠" if c in s else "·") for c in ("player", "inventory", "blocks", "entities", "screen"))
        bk = base_kf.get(r["tick"])
        L.append("| %d | %.3f | %.3f | %s | %.2f / %.2f | %d | %s | %s |" % (
            r["tick"], r["identical_pct"], r["within_tol_pct"], "—" if bk is None else "%.3f" % bk,
            r["coverage_a_pct"], r["coverage_b_pct"], r["max_delta"],
            " | ".join(str(r["regions"][n]["diff"]) for n in names), flags))
    L += ["", "## Первое расхождение", ""]
    if first_any is None:
        L.append("Нет: все ключевые кадры 100 %, все дампы state равны.")
    else:
        L.append("Такт **%d**." % first_any)
        if first_kf is not None:
            L += ["", "Первый ключевой кадр < 100 %%: такт %d — A `%s`, B `%s`, diff `%s`, heat `%s`." % (
                first_kf, win(A["shots"][first_kf]), win(B["shots"][first_kf]),
                win(os.path.join(out, "kf_%04d_diff.png" % first_kf)), win(os.path.join(out, "kf_%04d_heat.png" % first_kf))),
                "", "![A](%s) ![B](%s)" % (win(A["shots"][first_kf]).replace("\\", "/"), win(B["shots"][first_kf]).replace("\\", "/")),
                "", "![diff](%s)" % rel(os.path.join(out, "kf_%04d_diff.png" % first_kf))]
            rr = next(r for r in rows if r.get("tick") == first_kf)
            L.append("")
            L.append("Области: " + ", ".join("%s %d px (%.3f %%)" % (n, rr["regions"][n]["diff"], rr["regions"][n]["pct"]) for n in names))
        for c in cats:
            if first[c] is not None:
                L += ["", "State `%s`, первый такт %d:" % (c, first[c]), "", "```",
                      json.dumps(first_detail[c], ensure_ascii=False, indent=None)[:3000], "```"]
    L += ["", "## Причины по областям (сумма отличающихся пикселей по всем кадрам)", "",
          "| область | пикселей |", "|---|---|"] + ["| %s | %d |" % kv for kv in summary["region_diff_pixels"].items()]
    L += ["", "Области (`regions` сценария, первая подходящая): " + ", ".join("%s %s" % (k, v) for k, v in regions.items()) +
          ", остальное — world."]
    with open(os.path.join(out, "e2e_report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print("%s: keyframes %d, 100%% %d, min %s%%, mean %s%%; first divergent keyframe %s; first state divergence %s; "
          "first divergence tick %s (outside reference noise %s)\nreport %s\ndrift %s (%s)" % (
              title, summary["keyframes"], summary["keyframes_100"], summary["min_identical_pct"],
              summary["mean_identical_pct"], first_kf, json.dumps(first_state), first_any, first_clean,
              win(os.path.join(out, "e2e_report.md")), summary["drift_png"], how))
    for r in good:
        print("  kf %4d  %8.3f%%  tol %8.3f%%" % (r["tick"], r["identical_pct"], r["within_tol_pct"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
