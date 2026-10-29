#!/usr/bin/env python3
"""AlphaMine: attribute the pixels that differ between golden and a run to the exhibits of the developer world
(golden/devworld, tools/alphamine/gen_devworld.py, agents/ALPHAMINE.md 10).

Every pixel of a viewpoint shot is labelled by casting its ray through the saved world: the camera is the Alpha one
(EntityRenderer.orientCamera: glTranslatef(0,0,-0.1), glRotatef(pitch,1,0,0), glRotatef(yaw+180,0,1,0), translate
-eye; gluPerspective(70, W/H)), the ray walks the block grid (DDA) and the first cell that the layer draws gives the
label: the exhibit that owns the cell (layout cells; fluid cells spread by the server belong to the exhibit whose box
+1 contains them), or "ground" / "tower" / "far". Layers: terrain_* skip the translucent pass (water, ice), water_*
sees only water/ice (terrain has no depth there). Shots are matched to viewpoints by name (g1_n ...).

  python3 tools/alphamine/am_rows.py <run_dir> [scenario ...] [--top 25] [--labels]    (run_dir = runs/<stamp>_x)
  python3 tools/alphamine/am_rows.py <run_dir>/<scenario>                              one scenario

Output: per scenario and viewpoint the exhibits sorted by differing pixels (diff / covered px, "edge" = the run pixel
equals a golden pixel in the 8-neighbourhood, i.e. a sub-pixel shift, "other" = real content), and a summary per
block id over all shots; rows.json next to the shots; --labels writes <shot>_labels.png (label colours) too.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "reference"))
import compare as cmp  # noqa: E402
import gen_devworld as gd  # noqa: E402

ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "external"))  # было внешний каталог AlphaMine
WORLD = os.path.join(ALPHA, "golden", "devworld")
PASS1 = {8, 9, 79}


def load_world(root, layout):
    """Dense ids and labels over the exhibit box. Label 0 = air/none, 1 = ground (flat base cells, plaza), 2.. =
    exhibit index + 2."""
    cells = [c for e in layout["exhibits"] for c in e["cells"]]
    x0 = min(c[0] for c in cells) - 24
    x1 = max(c[0] for c in cells) + 24
    z0 = min(c[2] for c in cells) - 24
    z1 = max(c[2] for c in cells) + 24
    y0, y1 = 56, 90
    ids = np.zeros((x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1), np.int16)
    for cx in range(x0 >> 4, (x1 >> 4) + 1):
        for cz in range(z0 >> 4, (z1 >> 4) + 1):
            lvl = gd.read_chunk(root, cx, cz)
            if lvl is None:
                continue
            B = np.frombuffer(bytes(lvl["Blocks"]), np.uint8).reshape(16, 16, 128)   # [x][z][y]
            for lx in range(16):
                x = cx * 16 + lx
                if not x0 <= x <= x1:
                    continue
                for lz in range(16):
                    z = cz * 16 + lz
                    if not z0 <= z <= z1:
                        continue
                    ids[x - x0, :, z - z0] = B[lx, lz, y0:y1 + 1]
    lab = np.zeros(ids.shape, np.int16)
    lab[ids != 0] = 1
    boxes = []
    for k, e in enumerate(layout["exhibits"]):
        xs = [c[0] for c in e["cells"]]
        ys = [c[1] for c in e["cells"]]
        zs = [c[2] for c in e["cells"]]
        if not xs:
            boxes.append(None)
            continue
        boxes.append((min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
        for c in e["cells"]:
            x, y, z = c[:3]
            if y0 <= y <= y1:
                lab[x - x0, y - y0, z - z0] = k + 2
    # cells changed by the server (fluids): owner = exhibit whose box +1 contains them
    base = np.zeros(ids.shape, np.int16)
    base[:, :64 - y0, :] = 1
    base[:, 64 - y0, :] = 2
    for x, y, z in zip(*np.nonzero((ids != base) & (lab <= 1))):
        wx, wy, wz = x + x0, y + y0, z + z0
        for k, b in enumerate(boxes):
            if b and b[0] - 1 <= wx <= b[1] + 1 and b[2] - 1 <= wy <= b[3] + 1 and b[4] - 1 <= wz <= b[5] + 1:
                lab[x, y, z] = k + 2
                break
    return {"ids": ids, "lab": lab, "origin": (x0, y0, z0)}


def rays(W, H, eye, yaw, pitch, fov=70.0):
    t = math.tan(math.radians(fov / 2))
    a = W / H
    px = (np.arange(W) + 0.5) / W * 2 - 1
    py = 1 - (np.arange(H) + 0.5) / H * 2
    X, Y = np.meshgrid(px * t * a, py * t)
    d = np.stack([X, Y, -np.ones_like(X)], -1)
    p, q = math.radians(pitch), math.radians(yaw + 180)
    Rx = np.array([[1, 0, 0], [0, math.cos(p), -math.sin(p)], [0, math.sin(p), math.cos(p)]])
    Ry = np.array([[math.cos(q), 0, math.sin(q)], [0, 1, 0], [-math.sin(q), 0, math.cos(q)]])
    M = (Rx @ Ry).T                      # camera -> world rotation
    dirs = d @ M.T
    origin = np.array(eye) + M @ np.array([0, 0, 0.1])
    return origin, dirs.reshape(-1, 3)


def cast(world, origin, dirs, mode, steps=400):
    """First drawn cell along each ray -> label (0 far)."""
    ids, lab = world["ids"], world["lab"]
    o = np.array(world["origin"])
    shape = np.array(ids.shape)
    n = dirs.shape[0]
    pos = np.floor(origin).astype(np.int64)[None, :].repeat(n, 0)
    step = np.sign(dirs).astype(np.int64)
    with np.errstate(divide="ignore", invalid="ignore"):
        inv = np.where(dirs != 0, 1.0 / dirs, np.inf)
    nxt = np.where(step > 0, pos + 1 - origin, origin - pos) * np.abs(inv)
    nxt = np.where(dirs == 0, np.inf, nxt)
    dt = np.abs(inv)
    out = np.zeros(n, np.int16)
    alive = np.ones(n, bool)
    for _ in range(steps):
        idx = np.nonzero(alive)[0]
        if not len(idx):
            break
        ax = np.argmin(nxt[idx], axis=1)
        r = np.arange(len(idx))
        pos[idx, ax] += step[idx, ax]
        nxt[idx, ax] += dt[idx, ax]
        g = pos[idx] - o
        inside = np.all((g >= 0) & (g < shape), axis=1)
        gone = ~inside & ((g[:, 1] < 0) | (g[:, 1] >= shape[1]) | np.any((g < -64) | (g >= shape + 64), axis=1))
        alive[idx[gone]] = False
        k = idx[inside]
        gi = g[inside]
        cid = ids[gi[:, 0], gi[:, 1], gi[:, 2]]
        if mode == "water":
            hit = np.isin(cid, list(PASS1))
        elif mode == "terrain":
            hit = (cid != 0) & ~np.isin(cid, list(PASS1))
        else:
            hit = cid != 0
        out[k[hit]] = lab[gi[hit, 0], gi[hit, 1], gi[hit, 2]]
        alive[k[hit]] = False
    return out


def label_names(layout):
    names = {0: "far", 1: "ground"}
    for k, e in enumerate(layout["exhibits"]):
        names[k + 2] = e["name"]
    return names


def classify(A, B):
    d = np.abs(A - B).max(axis=2) > 0
    H, W = d.shape
    edge = np.zeros_like(d)
    P = np.pad(A, ((1, 1), (1, 1), (0, 0)), constant_values=-1)
    for y, x in zip(*np.nonzero(d)):
        if (P[y:y + 3, x:x + 3] == B[y, x]).all(axis=2).any():
            edge[y, x] = True
    return d, edge


def mode_of(scenario):
    if "water" in scenario:
        return "water"
    if "terrain" in scenario:
        return "terrain"
    return "all"


def analyse(run_dir, scenario, layout, world, top, labels_png, summary):
    gdir = os.path.join(ALPHA, "golden", scenario)
    sdir = os.path.join(run_dir, scenario)
    vps = {v["name"]: v for v in layout["viewpoints"]}
    names = label_names(layout)
    res = []
    for fn in sorted(os.listdir(sdir)):
        name = fn[:-4]
        if not fn.endswith(".png") or name not in vps or not os.path.exists(os.path.join(gdir, fn)):
            continue
        A, B = cmp.load(os.path.join(gdir, fn)), cmp.load(os.path.join(sdir, fn))
        H, W = A.shape[:2]
        v = vps[name]
        eye = (v["pos"][0], v["pos"][1] + 1.62, v["pos"][2])
        origin, dirs = rays(W, H, eye, v["yaw"], v["pitch"])
        lab = cast(world, origin, dirs, mode_of(scenario)).reshape(H, W)
        d, edge = classify(A, B)
        rows = []
        for l in np.unique(lab):
            m = lab == l
            nd = int((d & m).sum())
            rows.append({"label": names.get(int(l), str(l)), "px": int(m.sum()), "diff": nd,
                         "edge": int((edge & m).sum()), "other": nd - int((edge & m).sum()),
                         "identical_pct": round(100.0 * (1 - nd / max(1, int(m.sum()))), 2)})
        rows.sort(key=lambda r: -r["other"])
        total = int(d.sum())
        print("--- %s/%s: diff %d px (%.2f %% identical), edge %d, other %d" % (
            scenario, name, total, 100.0 * (1 - total / (H * W)), int(edge.sum()), total - int(edge.sum())))
        for r in rows[:top]:
            if r["diff"]:
                print("  %-38s px %6d  diff %5d  edge %5d  other %5d  identical %6.2f %%" % (
                    r["label"][:38], r["px"], r["diff"], r["edge"], r["other"], r["identical_pct"]))
        res.append({"shot": name, "diff": total, "rows": rows})
        for r in rows:
            s = summary.setdefault(r["label"], {"px": 0, "diff": 0, "other": 0, "shots": set()})
            s["px"] += r["px"]
            s["diff"] += r["diff"]
            s["other"] += r["other"]
            if r["other"] > 0:
                s["shots"].add("%s/%s" % (scenario.replace("layer_", "").replace("_dev", ""), name))
        if labels_png:
            rng = np.random.RandomState(7)
            pal = rng.randint(40, 255, (len(names) + 2, 3))
            pal[0] = 0
            pal[1] = 60
            img = pal[lab]
            img[d] = img[d] // 3 + np.array([170, 0, 170]) * (~edge[d])[:, None] + np.array([170, 170, 0]) * edge[d][:, None]
            cmp.write_png(os.path.join(sdir, name + "_labels.png"), np.clip(img, 0, 255))
    with open(os.path.join(sdir, "rows.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("scenarios", nargs="*")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--labels", action="store_true")
    ap.add_argument("--world", default=WORLD)
    o = ap.parse_args()
    run = os.path.normpath(o.run)
    scen = o.scenarios
    if not scen:
        if os.path.exists(os.path.join(run, "report.json")):
            run, scen = os.path.dirname(run), [os.path.basename(run)]
        else:
            scen = sorted(n for n in os.listdir(run) if os.path.isdir(os.path.join(run, n)))
    with open(os.path.join(o.world, "devworld_layout.json"), encoding="utf-8") as f:
        layout = json.load(f)
    world = load_world(o.world, layout)
    summary = {}
    for s in scen:
        analyse(run, s, layout, world, o.top, o.labels, summary)
    print("=== per exhibit over all shots (sorted by 'other' pixels)")
    for k, s in sorted(summary.items(), key=lambda t: -t[1]["other"]):
        if s["diff"]:
            print("  %-38s px %7d  diff %6d  other %6d  identical %6.2f %%  %s" % (
                k[:38], s["px"], s["diff"], s["other"], 100.0 * (1 - s["diff"] / max(1, s["px"])),
                " ".join(sorted(s["shots"]))[:120]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
