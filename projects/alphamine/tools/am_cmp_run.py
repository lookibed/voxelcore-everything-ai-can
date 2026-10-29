#!/usr/bin/env python3
"""Compare the shots of a run directory with golden (per scenario): identical %, within tol, coverage, max|d|.
  python3 tools/alphamine/am_cmp_run.py <repo>/projects/alphamine/external/runs/<run> p4_dig p4_place [--tol 3] [--clear 0,0,0]
Writes <shot>_diff.png / _heat.png next to the run shots (tools/reference/compare.py metrics)."""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "reference"))
import compare as cmp  # noqa: E402

ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "external"))  # было внешний каталог AlphaMine


def wsl(p):
    p = p.replace("\\", "/")
    return "/mnt/%s/%s" % (p[0].lower(), p[3:]) if p[1:3] == ":/" else p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("scenarios", nargs="+")
    ap.add_argument("--tol", type=int, default=3)
    ap.add_argument("--clear", default="0,0,0")
    o = ap.parse_args()
    clear = [int(v) for v in o.clear.split(",")]
    run = wsl(o.run)
    for sc in o.scenarios:
        d = os.path.join(run, sc)
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".png") or fn.endswith(("_diff.png", "_heat.png")):
                continue
            g = os.path.join(ALPHA, "golden", sc, fn)
            if not os.path.exists(g):
                print("%-10s %-12s no golden" % (sc, fn))
                continue
            n = fn[:-4]
            m = cmp.metrics(cmp.load(g), cmp.load(os.path.join(d, fn)), o.tol, clear,
                            os.path.join(d, n + "_diff.png"), os.path.join(d, n + "_heat.png"))
            print("%-10s %-12s identical %7.3f%%  tol%d %7.3f%%  cov golden %6.2f%% vc %6.2f%%  max|d| %3d  bbox %s" % (
                sc, n, m["identical_pct"], o.tol, m["within_tol_pct"], m["coverage_a_pct"], m["coverage_b_pct"],
                m["max_delta"], m.get("bbox")))


if __name__ == "__main__":
    main()
