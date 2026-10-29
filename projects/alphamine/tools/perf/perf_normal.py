#!/usr/bin/env python3
"""AlphaMine perf, normal launch semantics (real time, the curve the user sees) — thin wrapper over
`tools/lab/lab perf alphamine perf_normal` (lab stage 3a):

  python3 tools/alphamine/perf/perf_normal.py [--tag before] [--walk 1200] [--yaw 180] [--switch k=v] [--line ax,az]
                                              [--autowalk k=v] [--pack <variant dir>] [--wait-idle 600]

The lab daemon waits for an idle PC, then runs the alphamine server (fresh copy of golden/world_b) and the TEST build
VoxelCoreF2F.exe with `--f2f-clock realtime` (input isolated, no focus; frame 1390x855 = the user's window) as leases;
the pack profiler + autowalk drive the walk (stand 100, walk, settle 300 ticks after the 441 spawn chunks). Output:
<runs_dir>\\<stamp>_alphamine_perf_normal_<tag>\\ (perf.csv, perf_report.md, perf_summary.json with host_load, chart);
contended runs are tagged and ignored by gates. The stock VoxelCore.exe is never started (only `lab play --user`).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perflab  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    perflab.common_args(ap)
    return perflab.run("perf_normal", ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())
