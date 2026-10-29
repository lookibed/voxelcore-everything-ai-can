#!/usr/bin/env python3
"""Compare two perf runs (before/after):

  python3 tools/alphamine/perf/perf_compare.py <run A> <run B> [--phase walk|all] [--md out.md]

Run = directory with perf.csv (perf_walk.py / perf_normal.py output). Prints markdown tables: fps (normal runs),
frame ms, pack Lua per frame, per section total/per frame/p99, per event costs, with the percent change B vs A.
Lab stage 3a: a run whose perf_summary.json has host_load.contended = true (PC was busy) or no load record is refused
as a comparison side (`--allow-contended` prints the table anyway, marked NOT VALID).
"""
import json
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perflib  # noqa: E402


def chg(a, b):
    if a is None or b is None:
        return "-"
    if a == 0:
        return "-" if b == 0 else "new"
    return "%+.1f%%" % (100.0 * (b - a) / a)


def f(v, d=2):
    return "-" if v is None else ("%%.%df" % d) % v


def load_state(d):
    """-> (ok_to_compare, text) по host_load в perf_summary.json."""
    try:
        with open(os.path.join(d, "perf_summary.json"), encoding="utf-8") as f:
            ps = json.load(f)
    except (OSError, ValueError):
        return False, "no perf_summary.json"
    hl = ps.get("host_load")
    if not isinstance(hl, dict) or hl.get("contended") is None:
        return False, "load not recorded"
    if hl.get("contended"):
        return False, "CONTENDED: " + "; ".join(hl.get("reasons") or [])
    return True, "clean (%s samples)" % hl.get("n")


def run(path, phase):
    csv_path = path if path.endswith(".csv") else os.path.join(path, "perf.csv")
    d = os.path.dirname(os.path.abspath(csv_path))
    mode = "f2f" if "perf_walk" in d else "normal"
    try:
        with open(os.path.join(d, "perf_summary.json"), encoding="utf-8") as f:
            if (json.load(f).get("meta") or {}).get("clock") == "realtime":
                mode = "normal"          # lab perf (stage 3a): every run is real time
    except (OSError, ValueError):
        pass
    rows = perflib.load_csv(csv_path)
    return perflib.analyze(rows, mode, phases={2} if phase == "walk" else None), d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--phase", default="walk", choices=["walk", "all"])
    ap.add_argument("--md", default=None)
    ap.add_argument("--allow-contended", action="store_true", help="compare even contended / unrecorded runs (the "
                    "table is marked NOT VALID)")
    o = ap.parse_args()
    A, da = run(o.a, o.phase)
    B, db = run(o.b, o.phase)
    sa, sb = load_state(da), load_state(db)
    if not (sa[0] and sb[0]):
        msg = "host load: A %s; B %s" % (sa[1], sb[1])
        if not o.allow_contended:
            print("REFUSED: measurements are valid only on an idle PC (lab perf). " + msg)
            return 4
        print("WARNING: NOT VALID comparison - " + msg)
    L = ["# perf compare (%s phase)" % o.phase, "", "A = `%s` (%s)  " % (da, sa[1]), "B = `%s` (%s)" % (db, sb[1]), ""]
    if not (sa[0] and sb[0]):
        L += ["**NOT VALID: a side was measured on a busy PC or without a load record**", ""]
    L += ["| metric | A | B | change |", "|---|---|---|---|"]
    L.append("| frames / duration s | %d / %.1f | %d / %.1f | |" % (A["frames"], A.get("duration_s", 0), B["frames"],
                                                                   B.get("duration_s", 0)))
    if A["mode"] == "normal" and B["mode"] == "normal":
        for k in ("fps_1s", "fps_5s"):
            for s in ("min", "p5", "median", "max"):
                if k in A and k in B:
                    L.append("| fps %s windows %s | %.1f | %.1f | %s |" % (k[4:], s, A[k][s], B[k][s], chg(A[k][s], B[k][s])))
        for s in ("p1", "p5", "median"):
            L.append("| fps per frame %s | %.1f | %.1f | %s |" % (s, A["fps_frame"][s], B["fps_frame"][s],
                                                               chg(A["fps_frame"][s], B["fps_frame"][s])))
        for s in ("median", "p95", "p99", "max"):
            L.append("| frame ms %s | %.1f | %.1f | %s |" % (s, A["frame_ms"][s], B["frame_ms"][s],
                                                          chg(A["frame_ms"][s], B["frame_ms"][s])))
        L.append("| frames > 33 ms | %d | %d | %s |" % (A.get("slow_frames", 0), B.get("slow_frames", 0),
                                                       chg(A.get("slow_frames", 0), B.get("slow_frames", 0))))
    for s in ("median", "p95", "p99", "max", "sum"):
        L.append("| pack Lua ms/frame %s | %.2f | %.2f | %s |" % (s, A["lua_ms"][s], B["lua_ms"][s],
                                                                 chg(A["lua_ms"][s], B["lua_ms"][s])))
    for s in ("median", "p99", "max"):
        L.append("| pack + world pass ms %s | %.2f | %.2f | %s |" % (s, A["pack_plus_world_ms"][s],
                 B["pack_plus_world_ms"][s], chg(A["pack_plus_world_ms"][s], B["pack_plus_world_ms"][s])))
    L += ["", "| section | A total ms | B total ms | change | A ms/frame | B ms/frame | A p99 | B p99 | A max | B max |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for c in perflib.SECTIONS + ["world_ms", "other_ms"]:
        L.append("| %s | %.0f | %.0f | %s | %.3f | %.3f | %.2f | %.2f | %.1f | %.1f |" % (
            c, A["total_ms"][c], B["total_ms"][c], chg(A["total_ms"][c], B["total_ms"][c]), A["per_frame_ms"][c],
            B["per_frame_ms"][c], A["p99_frame_ms"][c], B["p99_frame_ms"][c], A["max_frame_ms"][c], B["max_frame_ms"][c]))
    L += ["", "| per event, ms | A | B | change |", "|---|---|---|---|"]
    for k in A["per_event_ms"]:
        a, b = A["per_event_ms"][k], B["per_event_ms"].get(k)
        L.append("| %s | %s | %s | %s |" % (k, f(a, 3), f(b, 3), chg(a, b)))
    L += ["", "| counter | A | B |", "|---|---|---|"]
    for k in perflib.COUNTERS:
        L.append("| %s | %d | %d |" % (k, A["counters"][k], B["counters"][k]))
    L += ["", "top-3 A: " + "; ".join("%s %.0f ms" % x for x in A["top"]),
          "top-3 B: " + "; ".join("%s %.0f ms" % x for x in B["top"]), ""]
    md = "\n".join(L) + "\n"
    print(md)
    if o.md:
        with open(o.md, "w", encoding="utf-8") as fo:
            fo.write(md)


if __name__ == "__main__":
    sys.exit(main())
