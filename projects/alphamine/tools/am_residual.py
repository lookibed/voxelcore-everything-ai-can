#!/usr/bin/env python3
"""AlphaMine phase 3: classify the pixels that differ between golden and a VoxelCore run of a layer.

  python3 tools/alphamine/am_residual.py <run_dir>/<layer> [--golden D:/.../golden/<layer>]

Per shot: differing pixels; "edge" = the VC pixel equals a golden pixel in its 8-neighbourhood (a texel or face
boundary shifted by a sub-pixel amount), "other" = real content differences; golden-only / vc-only coverage
(clear = black); the densest 16x16 cells of "other" pixels (x, y, count) to crop with am_crop.py.
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference"))
import compare as cmp  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--golden")
    ap.add_argument("--clear", default="0,0,0")
    o = ap.parse_args()
    layer = os.path.basename(os.path.normpath(o.run))
    gdir = o.golden or os.path.join(os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "external")), "golden"), layer)
    clear = np.array([int(v) for v in o.clear.split(",")])
    for fn in sorted(os.listdir(gdir)):
        if not fn.endswith(".png") or not os.path.exists(os.path.join(o.run, fn)):
            continue
        A = cmp.load(os.path.join(gdir, fn)); B = cmp.load(os.path.join(o.run, fn))
        d = np.abs(A - B).max(axis=2) > 0
        H, W = d.shape
        edge = 0
        other = np.zeros_like(d)
        for y, x in zip(*np.nonzero(d)):
            y0, y1, x0, x1 = max(0, y - 1), min(H, y + 2), max(0, x - 1), min(W, x + 2)
            if (A[y0:y1, x0:x1] == B[y, x]).all(axis=2).any():
                edge += 1
            else:
                other[y, x] = True
        ga = (A != clear).any(axis=2); vb = (B != clear).any(axis=2)
        cells = {}
        for y, x in zip(*np.nonzero(other)):
            cells[(x // 16 * 16, y // 16 * 16)] = cells.get((x // 16 * 16, y // 16 * 16), 0) + 1
        top = sorted(cells.items(), key=lambda t: -t[1])[:6]
        print("%-12s diff %5d  edge %5d  other %5d  golden-only %5d  vc-only %5d  top %s" % (
            fn[:-4], int(d.sum()), edge, int(other.sum()), int((ga & ~vb).sum()), int((vb & ~ga).sum()),
            " ".join("%d,%d:%d" % (k[0], k[1], v) for k, v in top)))


if __name__ == "__main__":
    main()
