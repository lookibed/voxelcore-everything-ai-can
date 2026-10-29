#!/usr/bin/env python3
"""AlphaMine performance suite, streaming load (the user's 20-50 MapChunk/s while walking into new terrain):

  python3 tools/alphamine/perf/perf_stream.py [--tag T] [--f2f] [--variant lp] [--switch k=v ...] [--walk 3600]

A fresh copy of golden/world_b (generated around the spawn only: chunks x -27..175, z -20..61, spawn -101,-5);
the pack's autowalk follows the straight line x = -100.5 heading -Z (yaw 180, no zig-zag) for --walk ticks
(3600 = 180 s, ~650 blocks): after ~150 blocks the server generates and populates chunks on demand, and the client
receives full + partial MapChunks at 20-40/s, as in the user's sessions. The line steering makes the route the same
whatever the random spawn offset (EntityPlayerMP +-10); the terrain is the same (seeded world), the server's
generation speed is real time.

Since lab stage 3a both modes are `lab perf` runs on realtime leases of the test build (perf_normal: 1390x855,
--f2f: perf_walk 854x480); the text below describes the former setup. Normal launch (default): perf_normal.py on the runtime VoxelCore.exe (window of the user's settings.toml, 120 fps
limit, load-distance 16 as alphamine_world.lua sets it). --f2f: perf_walk.py on VoxelCoreF2F-v.exe :25571, 854x480,
2 frames per tick paced at 50 ms (costs = pack Lua + world pass).
--variant lp: the pack with block JSONs from `gen_pack_blocks.py --engine-light off` (every block light-passing
and sky-light-passing, no emission: the engine light is trivially 15 everywhere), in a separate user dir with a
content/alphamine junction to <repo>\\projects\\alphamine\\external\\run\\alphamine_lp (the shared pack is not touched; see
make_variant.py).
Report adds (perflib.stream_stats): MapChunk/s per 5 s window, fps by rate bucket (< 8, 8-20, 20-35, >= 35),
appearance delay MapChunk -> world.set_chunk_data p50/p95 (samples.csv of perf.lua).
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "external"))  # было внешний каталог AlphaMine
LP_PACK = os.path.join(ALPHA, "run", "alphamine_lp")
LP_RT_DIR = os.path.join(ALPHA, "run", "vc_rt_lp")
LP_F2F_DIR = os.path.join(ALPHA, "run", "vc_f2f_lp")
LINE = "-100.5,-4.5"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="run")
    ap.add_argument("--f2f", action="store_true")
    ap.add_argument("--variant", choices=["base", "lp"], default="base")
    ap.add_argument("--walk", type=int, default=3600)
    ap.add_argument("--settle", type=int, default=300)
    ap.add_argument("--switch", action="append", default=[])
    ap.add_argument("--autowalk", action="append", default=[], help="extra autowalk k=v (menu=1: GuiIngameMenu open)")
    ap.add_argument("--walk-mode", choices=["glide", "walk"], default="glide",
                    help="glide (default): autowalk glide=1 at --speed blocks/tick over the terrain (same route and "
                    "speed every run); walk: the player's physics (stops at hills, swims)")
    ap.add_argument("--speed", type=float, default=0.2158, help="glide speed, blocks per tick (0.2158 = walking)")
    o = ap.parse_args()
    tag = "stream_%s%s" % ("lp_" if o.variant == "lp" else "", o.tag)
    argv = ["--tag", tag, "--walk", str(o.walk), "--settle", str(o.settle), "--yaw", "180", "--turn", "0",
            "--line=" + LINE]
    for sw in o.switch:
        argv += ["--switch", sw]
    if o.walk_mode == "glide":
        argv += ["--autowalk", "glide=1", "--autowalk", "speed=%g" % o.speed]
    for kv in o.autowalk:
        argv += ["--autowalk", kv]
    if o.variant == "lp":
        argv += ["--pack", LP_PACK]
    if not o.f2f:
        argv += ["--timeout", str(120 + (o.walk + o.settle + 100) / 20.0 * 1.5)]
    # lab stage 3a: both go through `lab perf` (realtime test build leases, idle PC); --f2f = 854x480 frame
    import perf_walk as PW
    import perf_normal as PN
    P = PW if o.f2f else PN
    sys.argv = ["perf_walk.py" if o.f2f else "perf_normal.py"] + argv
    if o.variant == "lp" and not os.path.exists(os.path.join(LP_PACK, "package.json")):
        raise SystemExit("variant pack %s missing: run tools/alphamine/perf/make_variant.py first" % LP_PACK)
    return P.main()


if __name__ == "__main__":
    sys.exit(main())
