#!/usr/bin/env python3
"""Rebuild the report of a perf run from its CSV:

  python3 tools/alphamine/perf/perf_report.py <run dir or perf.csv> [--mode normal|f2f]

Writes perf_report.md, perf_summary.json, perf_chart.png next to the CSV (see perflib.py for the columns).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perflib  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--mode", default=None)
    o = ap.parse_args()
    csv_path = o.path if o.path.endswith(".csv") else os.path.join(o.path, "perf.csv")
    out = os.path.dirname(os.path.abspath(csv_path))
    mode = o.mode or ("f2f" if "perf_walk" in out else "normal")
    _, _, md = perflib.full_report(csv_path, out, os.path.basename(out), mode)
    print(md)


if __name__ == "__main__":
    sys.exit(main())
