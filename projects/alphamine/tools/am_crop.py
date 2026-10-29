#!/usr/bin/env python3
"""AlphaMine: zoomed side-by-side crop golden | vc | heat for eyeballing residual pixels (phase 3).

  python3 tools/alphamine/am_crop.py <golden.png> <vc.png> x0,y0,x1,y1 [--zoom 4] [--out /tmp/crop.png]

Heat panel: black = identical, red intensity = max |channel delta|.
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference"))
import compare as cmp  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a"); ap.add_argument("b"); ap.add_argument("box")
    ap.add_argument("--zoom", type=int, default=4); ap.add_argument("--out", default="/tmp/am_crop.png")
    o = ap.parse_args()
    x0, y0, x1, y1 = (int(v) for v in o.box.split(","))
    A = cmp.load(o.a)[y0:y1, x0:x1]; B = cmp.load(o.b)[y0:y1, x0:x1]
    d = np.abs(A - B).max(axis=2)
    H = np.zeros_like(A); H[:, :, 0] = np.where(d > 0, np.clip(64 + d * 4, 0, 255), 0)
    H[:, :, 1] = np.where(d > 0, np.clip(d * 2 - 128, 0, 255), 0)
    z = o.zoom
    pan = [np.repeat(np.repeat(P, z, 0), z, 1) for P in (A, B, H)]
    gap = np.full((pan[0].shape[0], 6, 3), 255, np.int16)
    cmp.write_png(o.out, np.concatenate([pan[0], gap, pan[1], gap, pan[2]], axis=1))
    print("%s: %d differing of %d, max %d" % (o.out, int((d > 0).sum()), d.size, int(d.max())))


if __name__ == "__main__":
    main()
