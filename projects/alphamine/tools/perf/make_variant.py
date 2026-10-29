#!/usr/bin/env python3
"""Variant pack `alphamine` for performance experiments, without touching the shared pack (other agents run their
F2F clients with a junction to REPO/content/alphamine):

  python3 tools/alphamine/perf/make_variant.py [--engine-light off]

<repo>\\projects\\alphamine\\external\\run\\alphamine_lp: every subdir of content/alphamine is a junction (modules, shaders, ... edits
show up at once) except blocks/, which gen_pack_blocks.py --blocks-only --engine-light off writes; top-level files
are copied. Engine user dirs that use it: run\\vc_rt_lp (runtime VoxelCore.exe --dir, perf_normal.py --userdir)
and run\\vc_f2f_lp (F2F client, perf_walk.py --dir / am_client dir) get a content\\alphamine junction to it.
"""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))  # корень репозитория (было: рабочий каталог движка)
PACK = os.path.join(REPO, "packs", "alphamine")
ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "external"))  # было внешний каталог AlphaMine
OUT = os.path.join(ALPHA, "run", "alphamine_lp")
DIRS = [os.path.join(ALPHA, "run", "vc_rt_lp"), os.path.join(ALPHA, "run", "vc_f2f_lp")]
PS = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"


def win(p):
    return subprocess.check_output(["wslpath", "-w", p], text=True).strip()


def cmd(c):
    subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command", c], capture_output=True, cwd="/mnt/c")


def junction(link, target):
    if os.path.lexists(link):
        cmd("cmd /c rmdir '%s'" % win(link))
    cmd("cmd /c mklink /J '%s' '%s' | Out-Null" % (win(link), win(target)))
    if not os.path.isdir(link):
        raise SystemExit("junction %s -> %s failed" % (link, target))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine-light", choices=["on", "off"], default="off")
    o = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    for name in sorted(os.listdir(PACK)):
        src, dst = os.path.join(PACK, name), os.path.join(OUT, name)
        if os.path.isdir(src):
            if name == "blocks":
                continue
            junction(dst, src)
        else:
            shutil.copy2(src, dst)
    bl = os.path.join(OUT, "blocks")
    if os.path.lexists(bl) and not os.path.isdir(bl):
        os.remove(bl)
    r = subprocess.run([sys.executable, os.path.join(REPO, "projects", "alphamine", "tools", "gen_pack_blocks.py"), "--out", OUT,
                        "--blocks-only", "--engine-light", o.engine_light], capture_output=True, text=True)
    print(r.stdout.strip(), r.stderr.strip())
    if r.returncode:
        return 1
    for d in DIRS:
        os.makedirs(os.path.join(d, "content"), exist_ok=True)
        junction(os.path.join(d, "content", "alphamine"), OUT)
    print("variant pack %s (blocks: engine light %s); junctions in %s" % (OUT, o.engine_light, ", ".join(DIRS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
