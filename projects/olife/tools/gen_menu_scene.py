"""Olife UX B (16.10, olife_menu): 3D scene of the client main menu as ONE VCM model for <modelviewer src=...>.

The engine's <modelviewer> shows one model asset and VCM has no "include another model" primitive, so the scene is baked:
the user's OBJ models of content/olife_client/models (bench = the `cmd` cube, bone, Injector, Spammer + ball, GravityGun)
are converted to VCM `@tri` primitives (positions transformed: scale -> rotate Y -> move, normalised to a target height),
standing on a planks floor. Materials: OBJ `usemtl` = texture name (as the engine does for OBJ); the bench's `$0..$5`
(block-side placeholders, shown as debug faces in a model viewer) -> entities/olife_bench.

  python3 tools/olife/gen_menu_scene.py            # -> content/olife_client/models/olife_menu_scene.vcm
  python3 tools/olife/gen_menu_scene.py --check    # exit 1 if the file is not up to date
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MODELS = os.path.join(ROOT, "content", "olife_client", "models")
OUT = os.path.join(MODELS, "olife_menu_scene.vcm")

# (obj, target height or None = keep scale, rot_y degrees, (x, y, z) position of the bbox bottom centre, texture override)
SCENE = [
    ("olife_bench", 0.9, 20, (0.0, 0.0, 0.0), "entities/olife_bench"),
    ("olife_bone", 1.25, -30, (-1.05, 0.0, 0.35), None),
    ("olife_injector", None, 65, (1.0, 0.0, 0.45), None),
    ("olife_gravitygun", None, -55, (-0.15, 0.95, -0.15), None),
    ("olife_spammer", None, 160, (0.95, 0.0, -0.75), None),
    ("olife_spamball", 0.3, 0, (-0.35, 0.0, 1.05), None),
]
OBJ_SCALE = {"olife_injector": 0.8, "olife_gravitygun": 0.62, "olife_spammer": 0.85}
FLOOR = 1.7          # half size of the planks floor


def read_obj(path):
    v, vt, faces, mat = [], [], [], "$0"
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "v":
                v.append(tuple(float(x) for x in p[1:4]))
            elif p[0] == "vt":
                vt.append((float(p[1]), float(p[2]) if len(p) > 2 else 0.0))
            elif p[0] == "usemtl":
                mat = p[1]
            elif p[0] == "f":
                idx = []
                for tok in p[1:]:
                    a = tok.split("/")
                    vi = int(a[0])
                    ti = int(a[1]) if len(a) > 1 and a[1] else 0
                    idx.append((vi - 1 if vi > 0 else len(v) + vi, (ti - 1 if ti > 0 else len(vt) + ti) if ti else None))
                faces.append((mat, idx))
    return v, vt, faces


def fmt(x):
    s = "%.4f" % x
    s = s.rstrip("0").rstrip(".") if "." in s else s
    return "0" if s in ("-0", "") else s


def build():
    # no comments in the output: the VCM text parser's comment syntax is not documented (generated file, see above)
    # the floor: 4x4 tiles (a VCM box larger than 1.0 gets undefined auto UVs - the whole atlas shows through)
    out, n, t = [], 4, 2 * FLOOR / 4
    for i in range(n):
        for j in range(n):
            x0, z0 = -FLOOR + i * t, -FLOOR + j * t
            out.append("@box from (%s,-0.08,%s) to (%s,0,%s) texture \"blocks:planks\"" % (
                fmt(x0), fmt(z0), fmt(x0 + t), fmt(z0 + t)))
    tris = 0
    for name, height, rot, pos, tex in SCENE:
        v, vt, faces = read_obj(os.path.join(MODELS, name + ".obj"))
        xs, ys, zs = zip(*v)
        cx, cz, y0 = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2, min(ys)
        h = max(ys) - min(ys)
        k = (height / h) if height else OBJ_SCALE.get(name, 1.0)
        c, s = math.cos(math.radians(rot)), math.sin(math.radians(rot))

        def tr(p):
            x, y, z = (p[0] - cx) * k, (p[1] - y0) * k, (p[2] - cz) * k
            return (x * c + z * s + pos[0], y + pos[1], -x * s + z * c + pos[2])
        for mat, idx in faces:
            texture = tex or mat
            for i in range(1, len(idx) - 1):            # fan triangulation
                tri = (idx[0], idx[i], idx[i + 1])
                pts = [tr(v[a]) for a, _ in tri]
                uv = []
                for _, t in tri:
                    uu = vt[t] if t is not None and t < len(vt) else (0.0, 0.0)
                    uv += [uu[0], uu[1]]
                out.append("@tri a (%s) b (%s) c (%s) uv (%s) texture \"%s\" cull-face off" % (
                    ",".join(fmt(x) for x in pts[0]), ",".join(fmt(x) for x in pts[1]),
                    ",".join(fmt(x) for x in pts[2]), ",".join(fmt(x) for x in uv), texture))
                tris += 1
    return "\n".join(out) + "\n", tris


def main():
    text, tris = build()
    if "--check" in sys.argv:
        try:
            with open(OUT, encoding="utf-8") as f:
                same = f.read() == text
        except OSError:
            same = False
        print("olife_menu_scene.vcm %s (%d triangles)" % ("up to date" if same else "STALE", tris))
        sys.exit(0 if same else 1)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote %s: %d triangles, %d bytes" % (OUT, tris, len(text.encode("utf-8"))))


if __name__ == "__main__":
    main()
