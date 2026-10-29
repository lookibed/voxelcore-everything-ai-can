#!/usr/bin/env python3
"""Попиксельное сравнение скриншота VoxelCore (окно, экран игры 854×480 по смещению) с эталоном Edge.

  compare.py <наш.png> <эталон.png> [--ox 277 --oy 225] [--tol 8] [--out diff.png] [--rect x,y,w,h]

Наш скриншот — окно движка (PrintWindow), экран игры лежит в нём 1:1 (по умолчанию 277,225).
Эталон — PNG 854×480 из edge_ref.js. Печатает долю совпавших пикселей (|Δ| ≤ tol по всем каналам),
среднюю и максимальную разницу, и пишет diff.png (серый — совпало, пурпурный — разница).

Режим F2F (AlphaMine, agents/F2F.md §7): два кадра одного размера, без смещения, метрика в процентах:

  compare.py --f2f <a.png> <b.png> [--tol 0] [--clear 0,0,0] [--out diff.png] [--heat heat.png] [--json]

identical_pct — пиксели, равные во всех каналах; within_tol_pct — |Δканал| ≤ tol; coverage_a/b_pct — пиксели
≠ clear (доля кадра, которую слой реально закрасил); bbox — рамка отличающихся пикселей. Та же функция
`metrics()` — в MCP am_compare / am_layers.
"""
import argparse, os, struct, sys, zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mcp"))
import numpy as np
from pixel_debug import read_png


def load(path):
    w, h, bpp, rows = read_png(path)
    a = np.frombuffer(b"".join(bytes(r) for r in rows), dtype=np.uint8).reshape(h, w, bpp)
    return a[:, :, :3].astype(np.int16)


def write_png(path, rgb):
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].astype(np.uint8).tobytes() for y in range(h))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def metrics(A, B, tol=0, clear=(0, 0, 0), diff_out=None, heat_out=None):
    """A, B — int16 [h, w, 3]. Проценты по agents/F2F.md §7. diff: серый A (приглушён) + пурпурный — Δ > tol,
    жёлтый — 0 < Δ ≤ tol; heat: максимум |Δ| по каналам, 0 — чёрный, дальше синий → красный → жёлтый → белый (255)."""
    if A.shape != B.shape:
        return {"error": "размеры разные: %sx%s и %sx%s" % (A.shape[1], A.shape[0], B.shape[1], B.shape[0])}
    h, w, _ = A.shape
    n = h * w
    d = np.abs(A - B).max(axis=2)
    same = d == 0
    within = d <= tol
    clear = np.array(list(clear)[:3], dtype=np.int16)
    cov_a = (A != clear).any(axis=2)
    cov_b = (B != clear).any(axis=2)
    ident = int(same.sum())
    res = {"w": int(w), "h": int(h), "pixels": n, "identical": ident, "identical_pct": 100.0 * ident / n,
           "tol": int(tol), "within_tol": int(within.sum()), "within_tol_pct": 100.0 * float(within.sum()) / n,
           "coverage_a_pct": 100.0 * float(cov_a.sum()) / n, "coverage_b_pct": 100.0 * float(cov_b.sum()) / n,
           "clear": [int(c) for c in clear], "diff_pixels": n - ident, "over_tol": int(n - within.sum()),
           "max_delta": int(d.max()), "mean_delta": float(d.mean()), "bbox": None}
    if ident < n:
        ys, xs = np.nonzero(~same)
        res["bbox"] = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
    if diff_out:
        gray = (A.sum(axis=2) // 3).astype(np.int16)
        img = np.stack([gray, gray, gray], axis=2) // 2 + 64
        img[~same & within] = [255, 255, 0]
        img[~within] = [255, 0, 255]
        write_png(diff_out, img)
        res["diff_png"] = diff_out
    if heat_out:
        t = d.astype(np.float32) / 255.0
        r = np.clip(t * 3.0, 0, 1)
        g = np.clip(t * 3.0 - 1.0, 0, 1)
        b = np.clip(1.0 - np.abs(t * 3.0 - 0.5) * 2.0, 0, 1) + np.clip(t * 3.0 - 2.0, 0, 1)
        img = (np.stack([r, g, np.clip(b, 0, 1)], axis=2) * 255).astype(np.int16)
        img[same] = [0, 0, 0]
        img[~same] = np.maximum(img[~same], 40)  # даже Δ=1 видно на чёрном
        write_png(heat_out, img)
        res["heat_png"] = heat_out
    return res


def fmt_row(label, m):
    """Строка таблицы для людей."""
    if "error" in m:
        return "%-22s %s" % (label, m["error"])
    return "%-22s %8.3f %8.3f %7.2f %7.2f  %s" % (
        label, m["identical_pct"], m["within_tol_pct"], m["coverage_a_pct"], m["coverage_b_pct"],
        "-" if not m.get("bbox") else "%d px, max Δ %d, bbox %s" % (m["diff_pixels"], m["max_delta"], m["bbox"]))


TABLE_HEAD = "%-22s %8s %8s %7s %7s  %s" % ("", "ident%", "tol%", "covA%", "covB%", "отличия")


def main_f2f(argv):
    import json
    ap = argparse.ArgumentParser(prog="compare.py --f2f")
    ap.add_argument("a"); ap.add_argument("b")
    ap.add_argument("--tol", type=int, default=0)
    ap.add_argument("--clear", default="0,0,0", help="цвет очистки r,g,b (для покрытия)")
    ap.add_argument("--out", help="diff.png"); ap.add_argument("--heat", help="heat.png")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    m = metrics(load(a.a), load(a.b), a.tol, [int(x) for x in a.clear.split(",")], a.out, a.heat)
    if a.json:
        print(json.dumps(m, ensure_ascii=False, indent=1))
    else:
        print(TABLE_HEAD)
        print(fmt_row(os.path.basename(a.a), m))
    return 1 if "error" in m else 0


def main():
    if "--f2f" in sys.argv[1:]:
        argv = [x for x in sys.argv[1:] if x != "--f2f"]
        sys.exit(main_f2f(argv))
    ap = argparse.ArgumentParser()
    ap.add_argument("ours"); ap.add_argument("ref")
    ap.add_argument("--ox", type=int, default=277); ap.add_argument("--oy", type=int, default=225)
    ap.add_argument("--tol", type=int, default=8); ap.add_argument("--out")
    ap.add_argument("--rect", help="x,y,w,h в координатах экрана игры (854×480)")
    a = ap.parse_args()
    ours, ref = load(a.ours), load(a.ref)
    rh, rw, _ = ref.shape
    crop = ours[a.oy:a.oy + rh, a.ox:a.ox + rw]
    if crop.shape != ref.shape:
        sys.exit("размеры не совпали: наш %s, эталон %s" % (crop.shape, ref.shape))
    if a.rect:
        x, y, w, h = map(int, a.rect.split(","))
        crop, ref = crop[y:y + h, x:x + w], ref[y:y + h, x:x + w]
    d = np.abs(crop - ref)
    per_px = d.max(axis=2)
    same = (per_px <= a.tol).mean()
    print("совпало %.2f%% пикселей (допуск %d); средняя разница %.2f, максимум %d; пикселей с Δ>64: %d" % (
        same * 100, a.tol, d.mean(), per_px.max(), int((per_px > 64).sum())))
    if a.out:
        gray = (crop.sum(axis=2) // 3).astype(np.int16)
        out = np.stack([gray, gray, gray], axis=2) // 2 + 64
        mask = per_px > a.tol
        out[mask] = [255, 0, 255]
        write_png(a.out, out)
        print("diff:", a.out)


if __name__ == "__main__":
    main()
