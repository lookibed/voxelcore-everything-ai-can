#!/usr/bin/env python3
"""AlphaMine perf `perf_walk` — thin wrapper over `tools/lab/lab perf alphamine perf_walk` (lab stage 3a):

  python3 tools/alphamine/perf/perf_walk.py [--tag before] [--walk 1200] [--switch k=v] [--wait-idle 600]

Same route as perf_normal in the standard F2F frame 854x480. Since stage 3a every perf run is on a realtime-clock
lease of the test build (time runs by itself, input isolated); the former virtual-time stepping (50 ms pacing through
am_client) is gone — numbers before 01.10 (virtual) and after (realtime) are different families.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perflab  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    perflab.common_args(ap)
    return perflab.run("perf_walk", ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())
