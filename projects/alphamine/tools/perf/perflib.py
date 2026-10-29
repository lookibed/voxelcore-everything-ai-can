#!/usr/bin/env python3
"""AlphaMine performance suite: CSV of the pack profiler (content/alphamine/modules/perf.lua) -> statistics, chart,
perf_report.md. Used by perf_walk.py / perf_normal.py / perf_report.py / perf_compare.py.

CSV columns (one row per rendered frame, row = [previous frame hook, this frame hook)):
  t, frame_ms (wall clock between frame hooks), engine_ms (time.delta of the engine), world_ms (engine world pass),
  lua_ms (sum of the pack sections), other_ms (= frame_ms - lua_ms - world_ms: engine update incl. chunk lighting,
  UI draw, swap/vsync/limiter; F2F: also the idle wait for the next command), gc_kb, gc_step, dirty, engine_chunks,
  x, z, phase (0 load, 1 stand, 2 walk, 3 settle, 4 done), pack sections (exclusive ms), counters.

Chart: matplotlib (WSL python3 if it has it, else the Windows C:\\Python313 python runs `perflib.py chart`).
"""
import csv
import json
import math
import os
import subprocess
import sys

SECTIONS = ["tick", "net", "inflate", "store", "physics", "texfx", "fx_upload", "ents_tick", "lm_write",
            "lm_setdata", "lm_upload", "encode", "setdata", "bc_flush", "frame", "ents_frame", "hand", "particles", "hud", "gui",
            "dump"]
COUNTERS = ["ticks", "map_chunks", "pre_chunks", "applied", "lm_writes", "lm_uploads", "block_changes", "bytes_in",
            "bc_deferred", "bc_applied"]
# chart / top-cost groups (7 categories, fixed order = fixed colours)
GROUPS = [
    ("chunk conversion (encode + set_chunk_data + deferred block changes)", ["encode", "setdata", "bc_flush"]),
    ("lightmap (write + upload)", ["lm_write", "lm_setdata", "lm_upload"]),
    ("network + MapChunk (net, inflate, store)", ["net", "inflate", "store"]),
    ("tick logic (physics, texfx + upload, entities, rest)", ["tick", "physics", "texfx", "fx_upload", "ents_tick"]),
    ("frame logic (hand, hud, gui, entities, rest)", ["frame", "ents_frame", "hand", "particles", "hud", "gui", "dump"]),
    ("engine world pass", ["world_ms"]),
    ("engine other (update, lighting, UI, swap)", ["other_ms"]),
]
COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#4a3aa7", "#9a9a92"]
PHASES = {0: "load", 1: "stand", 2: "walk", 3: "settle", 4: "done"}
WIN_PY = "/mnt/c/Python313/python.exe"


def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            d = {k: float(v) for k, v in r.items() if k}
            for c in SECTIONS + COUNTERS:
                d.setdefault(c, 0.0)
            rows.append(d)
    rows.sort(key=lambda r: r["t"])
    return rows


def pct(vals, p):
    if not vals:
        return 0.0
    v = sorted(vals)
    k = (len(v) - 1) * p / 100.0
    lo = int(math.floor(k))
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def windows(rows, width):
    """fps over consecutive wall-clock windows of `width` s (frames / wall time), like the status line."""
    out = []
    if not rows:
        return out
    t0 = rows[0]["t"] - rows[0]["frame_ms"] / 1000.0
    cur, n, start = None, 0, t0
    for r in rows:
        w = int((r["t"] - t0) // width)
        if cur is None:
            cur = w
        if w != cur:
            out.append({"t": t0 + (cur + 0.5) * width, "fps": n / width, "frames": n})
            cur, n = w, 0
        n += 1
    return out


def group_value(r, cols):
    return sum(r.get(c, 0.0) for c in cols)


def analyze(rows, mode="normal", phases=None):
    """Statistics of a run. mode: normal (wall-clock frames) | f2f (frames stepped by the harness: frame_ms includes
    the harness pacing, only pack sections and world_ms are costs)."""
    if phases is not None:
        rows = [r for r in rows if int(r["phase"]) in phases]
    res = {"frames": len(rows), "mode": mode}
    if not rows:
        return res
    dur = sum(r["frame_ms"] for r in rows) / 1000.0
    res["duration_s"] = dur
    fms = [r["frame_ms"] for r in rows]
    res["frame_ms"] = {"median": pct(fms, 50), "p95": pct(fms, 95), "p99": pct(fms, 99), "max": max(fms)}
    inst = [1000.0 / max(0.01, v) for v in fms]
    res["fps_frame"] = {"p1": pct(inst, 1), "p5": pct(inst, 5), "median": pct(inst, 50)}
    for w in (1, 5):
        ws = [x["fps"] for x in windows(rows, w)]
        if ws:
            res["fps_%ds" % w] = {"min": min(ws), "p5": pct(ws, 5), "median": pct(ws, 50), "max": max(ws),
                                  "n": len(ws)}
    res["fps_avg"] = len(rows) / dur if dur > 0 else 0
    # costs: total ms and share of wall time
    cols = SECTIONS + ["world_ms", "other_ms"]
    tot = {c: sum(r.get(c, 0.0) for r in rows) for c in cols}
    wall = sum(fms)
    res["total_ms"] = tot
    res["share_pct"] = {c: 100.0 * v / wall for c, v in tot.items()} if wall else {}
    res["per_frame_ms"] = {c: v / len(rows) for c, v in tot.items()}
    res["p99_frame_ms"] = {c: pct([r.get(c, 0.0) for r in rows], 99) for c in cols}
    res["max_frame_ms"] = {c: max(r.get(c, 0.0) for r in rows) for c in cols}
    res["groups_ms"] = {g: sum(tot.get(c, 0) for c in cs) for g, cs in GROUPS}
    cnt = {c: sum(r.get(c, 0.0) for r in rows) for c in COUNTERS}
    res["counters"] = cnt

    def per(a, b):
        return tot[a] / cnt[b] if cnt.get(b) else None
    res["per_event_ms"] = {
        "encode / applied chunk": per("encode", "applied"),
        "set_chunk_data / applied chunk": per("setdata", "applied"),
        "inflate / MapChunk": per("inflate", "map_chunks"),
        "lightmap write / chunk": per("lm_write", "lm_writes"),
        "lightmap set_data / upload": per("lm_setdata", "lm_uploads"),
        "lightmap update (glTexSubImage+mipmap) / upload": per("lm_upload", "lm_uploads"),
        "texfx upload / tick": per("fx_upload", "ticks"),
        "texfx compute / tick": per("texfx", "ticks"),
        "physics / tick": per("physics", "ticks"),
    }
    # slow frames: what the time went to (share of their total)
    thr = 33.3 if mode == "normal" else None
    if thr:
        slow = [r for r in rows if r["frame_ms"] > thr]
        res["slow_frames"] = len(slow)
        if slow:
            st = sum(r["frame_ms"] for r in slow)
            res["slow_share_pct"] = {g: 100.0 * sum(group_value(r, cs) for r in slow) / st for g, cs in GROUPS}
            res["slow_counters_per_frame"] = {c: sum(r.get(c, 0) for r in slow) / len(slow) for c in COUNTERS}
        fast = [r for r in rows if r["frame_ms"] <= thr]
        if fast:
            res["fast_counters_per_frame"] = {c: sum(r.get(c, 0) for r in fast) / len(fast) for c in COUNTERS}
    gc = [r["gc_step"] for r in rows if r["gc_step"] < 0]
    res["gc"] = {"cycles_frames": len(gc), "freed_kb": -sum(gc), "max_kb": max(r["gc_kb"] for r in rows),
                 "alloc_kb_per_frame": sum(r["gc_step"] for r in rows if r["gc_step"] > 0) / len(rows)}
    # cost-limited fps for F2F (pack + world pass only)
    cost = [r["lua_ms"] + r["world_ms"] for r in rows]
    res["pack_plus_world_ms"] = {"median": pct(cost, 50), "p95": pct(cost, 95), "p99": pct(cost, 99),
                                 "max": max(cost)}
    lua = [r["lua_ms"] for r in rows]
    res["lua_ms"] = {"median": pct(lua, 50), "p95": pct(lua, 95), "p99": pct(lua, 99), "max": max(lua),
                     "sum": sum(lua)}
    ranking = sorted(((g, v) for g, v in res["groups_ms"].items()), key=lambda x: -x[1])
    if mode != "normal":
        ranking = [x for x in ranking if not x[0].startswith("engine other")]
    res["top"] = ranking[:3]
    sec_rank = sorted(((c, tot[c]) for c in SECTIONS), key=lambda x: -x[1])
    res["top_sections"] = sec_rank[:6]
    return res


# ---------------------------------------------------------------------------------------------- streaming load
RATE_BUCKETS = [(0, 8, "< 8"), (8, 20, "8-20"), (20, 35, "20-35"), (35, 1e9, ">= 35")]


def load_samples(path):
    """samples.csv of perf.lua (t, name, value) -> {name: [(t, value)]}"""
    out = {}
    if not path or not os.path.exists(path):
        return out
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            try:
                out.setdefault(r["name"], []).append((float(r["t"]), float(r["value"])))
            except (KeyError, ValueError):
                pass
    return out


def stream_stats(rows, samples=None, phases=None, width=5):
    """Chunk streaming: MapChunk rate and fps per `width`-s window, fps by rate bucket, appearance delay."""
    if phases is not None:
        rows = [r for r in rows if int(r["phase"]) in phases]
    res = {}
    if not rows:
        return res
    t0 = rows[0]["t"] - rows[0]["frame_ms"] / 1000.0
    win = {}
    for r in rows:
        w = int((r["t"] - t0) // width)
        d = win.setdefault(w, {"frames": 0, "map_chunks": 0, "applied": 0, "slow": 0})
        d["frames"] += 1
        d["map_chunks"] += r.get("map_chunks", 0)
        d["applied"] += r.get("applied", 0)
        if r["frame_ms"] > 33.3:
            d["slow"] += 1
    ws = [win[k] for k in sorted(win)][:-1] or [win[k] for k in sorted(win)]   # last window is partial
    series = [{"t": (k + 0.5) * width, "fps": win[k]["frames"] / width, "rate": win[k]["map_chunks"] / width,
               "applied": win[k]["applied"] / width} for k in sorted(win)]
    res["windows"] = series
    rates = [w["map_chunks"] / width for w in ws]
    res["rate"] = {"max": max(rates), "median": pct(rates, 50), "p90": pct(rates, 90),
                   "windows_ge20": sum(1 for v in rates if v >= 20), "n": len(rates)}
    by = []
    for lo, hi, name in RATE_BUCKETS:
        sel = [w for w in ws if lo <= w["map_chunks"] / width < hi]
        if sel:
            f = [w["frames"] / width for w in sel]
            by.append({"bucket": name, "n": len(sel), "fps_avg": sum(f) / len(f), "fps_min": min(f),
                       "fps_median": pct(f, 50)})
    res["fps_by_rate"] = by
    if samples and samples.get("delay_ms"):
        tmin, tmax = rows[0]["t"] - rows[0]["frame_ms"] / 1000.0, rows[-1]["t"]
        d = [v for t, v in samples["delay_ms"] if tmin <= t <= tmax]
        if d:
            res["delay_ms"] = {"n": len(d), "p50": pct(d, 50), "p95": pct(d, 95), "max": max(d),
                               "p50_ticks": pct(d, 50) / 50.0, "p95_ticks": pct(d, 95) / 50.0}
    return res


def stream_md(st, title):
    if not st:
        return ""
    L = ["## streaming: %s" % title, ""]
    r = st["rate"]
    L.append("MapChunk/s per 5 s window: median %.1f, p90 %.1f, max %.1f; windows >= 20/s: %d of %d" % (
        r["median"], r["p90"], r["max"], r["windows_ge20"], r["n"]))
    L.append("")
    L.append("| MapChunk/s (5 s) | windows | fps avg | fps median | fps min |")
    L.append("|---|---|---|---|---|")
    for b in st["fps_by_rate"]:
        L.append("| %s | %d | %.1f | %.1f | %.1f |" % (b["bucket"], b["n"], b["fps_avg"], b["fps_median"], b["fps_min"]))
    L.append("")
    if st.get("delay_ms"):
        d = st["delay_ms"]
        L.append("terrain appearance delay (MapChunk -> set_chunk_data), %d chunks: p50 %.0f ms (%.1f ticks), p95 %.0f ms "
                 "(%.1f ticks), max %.0f ms" % (d["n"], d["p50"], d["p50_ticks"], d["p95"], d["p95_ticks"], d["max"]))
        L.append("")
    L.append("fps / MapChunk/s per 5 s: " + " ".join("%.0f/%.0f" % (w["fps"], w["rate"]) for w in st["windows"]))
    L.append("")
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------------------------------------- chart
def chart(csv_path, png_path, title="", mode="normal"):
    """Two panels over time: fps (1 s windows) and the stacked cost per second by group (ms per wall second)."""
    try:
        import matplotlib  # noqa: F401
    except ImportError:
        if os.path.exists(WIN_PY):
            def w(p):
                return subprocess.check_output(["wslpath", "-w", p], text=True).strip()
            subprocess.run([WIN_PY, w(os.path.abspath(__file__)), "chart", w(csv_path), w(png_path), title, mode],
                           check=True, cwd="/mnt/c")
            return png_path
        raise
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    rows = load_csv(csv_path)
    if not rows:
        return None
    t0 = rows[0]["t"]
    nsec = int(rows[-1]["t"] - t0) + 1
    sec = [[0.0] * len(GROUPS) for _ in range(nsec)]
    frames = [0] * nsec
    worst = [0.0] * nsec
    phase = [0] * nsec
    for r in rows:
        s = min(nsec - 1, int(r["t"] - t0))
        frames[s] += 1
        worst[s] = max(worst[s], r["frame_ms"])
        phase[s] = int(r["phase"])
        for gi, (g, cs) in enumerate(GROUPS):
            sec[s][gi] += group_value(r, cs)
    xs = list(range(nsec))
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(12, 7.5), sharex=True, gridspec_kw={"height_ratios": [1, 1.4]})
    fig.patch.set_facecolor("#ffffff")
    for ax in (a1, a2):
        ax.set_facecolor("#ffffff")
        ax.grid(axis="y", color="#e4e3dc", linewidth=0.8)
        for sp in ("top", "right"):
            ax.spines[sp].set_visible(False)
        for sp in ("left", "bottom"):
            ax.spines[sp].set_color("#9a9a92")
        ax.tick_params(colors="#55554f", labelsize=9)
    # phase bands
    for ax in (a1, a2):
        start = 0
        for i in range(1, nsec + 1):
            if i == nsec or phase[i] != phase[start]:
                if phase[start] == 2:
                    ax.axvspan(start, i, color="#f3f2ec", zorder=0)
                start = i
    if mode == "normal":
        a1.plot(xs, frames, color="#2a78d6", linewidth=2, label="fps (frames per second)")
        wf = [1000.0 / w if w > 0 else 0 for w in worst]
        a1.plot(xs, wf, color="#eb6834", linewidth=1.2, label="worst frame of the second, as fps")
        a1.set_ylabel("fps", color="#55554f")
        a1.legend(loc="upper right", frameon=False, fontsize=9)
    else:
        lua = [0.0] * nsec
        for r in rows:
            s = min(nsec - 1, int(r["t"] - t0))
            lua[s] = max(lua[s], r["lua_ms"] + r["world_ms"])
        a1.plot(xs, lua, color="#2a78d6", linewidth=2, label="worst frame: pack Lua + world pass, ms")
        a1.set_ylabel("ms", color="#55554f")
        a1.legend(loc="upper right", frameon=False, fontsize=9)
    a1.set_title(title, loc="left", fontsize=11, color="#1a1a19")
    groups = GROUPS if mode == "normal" else GROUPS[:-1]
    ys = [[sec[s][gi] for s in range(nsec)] for gi in range(len(groups))]
    a2.stackplot(xs, *ys, colors=COLORS[:len(groups)], labels=[g for g, _ in groups], edgecolor="#ffffff",
                 linewidth=0.5)
    a2.set_ylabel("ms per wall second", color="#55554f")
    a2.set_xlabel("time, s (shaded: walk phase)", color="#55554f")
    a2.legend(loc="upper left", bbox_to_anchor=(1.0, 1.0), frameon=False, fontsize=8)
    fig.tight_layout()
    fig.savefig(png_path, dpi=110)
    plt.close(fig)
    return png_path


# ---------------------------------------------------------------------------------------------- report
def fnum(v, d=2):
    if v is None:
        return "-"
    return ("%%.%df" % d) % v


def report_md(res_all, res_walk, meta, png_name):
    L = []
    L.append("# AlphaMine perf: %s" % meta.get("name", ""))
    L.append("")
    L.append("Режим: **%s**, CSV `%s`, кадров %d, %.1f с. %s" % (meta.get("mode"), meta.get("csv"), res_all["frames"],
             res_all.get("duration_s", 0), meta.get("note", "")))
    L.append("")
    L.append("![chart](%s)" % png_name)
    L.append("")
    L.append("## Top-3 costs (whole run)")
    L.append("")
    wall = sum(res_all["total_ms"].values()) if res_all.get("total_ms") else 0
    L.append("| # | group | total, ms | share of wall, % |")
    L.append("|---|---|---|---|")
    fsum = res_all["duration_s"] * 1000.0
    for i, (g, v) in enumerate(res_all["top"], 1):
        L.append("| %d | %s | %.0f | %.1f |" % (i, g, v, 100.0 * v / fsum if fsum else 0))
    L.append("")
    for name, res in (("whole run", res_all), ("walk phase", res_walk)):
        if not res or not res.get("frames"):
            continue
        L.append("## %s" % name)
        L.append("")
        if res["mode"] == "normal":
            L.append("| fps | min | p5 | median | max |")
            L.append("|---|---|---|---|---|")
            for k in ("fps_1s", "fps_5s"):
                if k in res:
                    f = res[k]
                    L.append("| %s windows | %.1f | %.1f | %.1f | %.1f |" % (k[4:], f["min"], f["p5"], f["median"],
                                                                          f["max"]))
            L.append("")
            L.append("frame ms: median %.1f, p95 %.1f, p99 %.1f, max %.1f; frames > 33 ms: %d" % (
                res["frame_ms"]["median"], res["frame_ms"]["p95"], res["frame_ms"]["p99"], res["frame_ms"]["max"],
                res.get("slow_frames", 0)))
        L.append("pack Lua per frame: median %.2f, p95 %.2f, p99 %.2f, max %.1f ms; pack + world pass p99 %.2f ms" % (
            res["lua_ms"]["median"], res["lua_ms"]["p95"], res["lua_ms"]["p99"], res["lua_ms"]["max"],
            res["pack_plus_world_ms"]["p99"]))
        L.append("")
        L.append("| section | total ms | ms/frame | p99 ms | max ms | share % |")
        L.append("|---|---|---|---|---|---|")
        for c in SECTIONS + ["world_ms", "other_ms"]:
            if res["mode"] != "normal" and c == "other_ms":
                continue
            L.append("| %s | %.0f | %.3f | %.2f | %.1f | %.1f |" % (c, res["total_ms"][c], res["per_frame_ms"][c],
                     res["p99_frame_ms"][c], res["max_frame_ms"][c], res["share_pct"][c]))
        L.append("")
        L.append("per event: " + ", ".join("%s %s ms" % (k, fnum(v, 3)) for k, v in res["per_event_ms"].items()))
        L.append("")
        L.append("counters: " + ", ".join("%s %d" % (k, v) for k, v in res["counters"].items()))
        L.append("")
        if res.get("slow_share_pct"):
            L.append("slow frames (> 33 ms) — where their time went: " + ", ".join(
                "%s %.1f%%" % (g, v) for g, v in res["slow_share_pct"].items()))
            L.append("")
            L.append("per slow frame: " + ", ".join("%s %.2f" % (k, v) for k, v in res["slow_counters_per_frame"].items()
                                                    if k != "bytes_in"))
            if res.get("fast_counters_per_frame"):
                L.append("; per fast frame: " + ", ".join("%s %.2f" % (k, v) for k, v in
                                                          res["fast_counters_per_frame"].items() if k != "bytes_in"))
            L.append("")
        g = res["gc"]
        L.append("GC: frames with a collection %d, freed %.0f KB, peak %.0f KB, allocated %.1f KB/frame" % (
            g["cycles_frames"], g["freed_kb"], g["max_kb"], g["alloc_kb_per_frame"]))
        L.append("")
    return "\n".join(L) + "\n"


def full_report(csv_path, out_dir, name, mode, note=""):
    rows = load_csv(csv_path)
    res_all = analyze(rows, mode)
    res_walk = analyze(rows, mode, phases={2})
    png = os.path.join(out_dir, "perf_chart.png")
    try:
        chart(csv_path, png, title="%s (%s)" % (name, mode), mode=mode)
    except Exception as exc:  # the numbers matter more than the picture
        note += " (chart failed: %s)" % exc
    meta = {"name": name, "mode": mode, "csv": os.path.basename(csv_path), "note": note}
    md = report_md(res_all, res_walk, meta, "perf_chart.png")
    samples = load_samples(os.path.join(os.path.dirname(csv_path), "samples.csv"))
    st_all = stream_stats(rows, samples)
    st_walk = stream_stats(rows, samples, phases={2})
    md += stream_md(st_all, "whole run") + stream_md(st_walk, "walk phase")
    with open(os.path.join(out_dir, "perf_report.md"), "w", encoding="utf-8") as f:
        f.write(md)
    with open(os.path.join(out_dir, "perf_summary.json"), "w", encoding="utf-8") as f:
        json.dump({"meta": meta, "all": res_all, "walk": res_walk, "stream_all": st_all, "stream_walk": st_walk},
                  f, indent=1)
    return res_all, res_walk, md


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "chart":
        chart(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "",
              sys.argv[5] if len(sys.argv) > 5 else "normal")
    else:
        print(__doc__)
