#!/usr/bin/env python3
"""model_ref — frame-by-frame pixel compare of a model + animations: Blender (the source) vs VoxelCore (F2F test build).

Lab tool (07.11.2026; MCP: vc_model_ref / vc_model_export). Typical — one .blend, the rest is derived:
  python3 -m vclab.model_ref.model_ref --blend hero.blend [--anim walk=0-24] [--anim run=@RunAction] [--out DIR]
    -> DIR/export/ (blender_export.py: hero.vcm, textures, <anim>.vca, export.json), then the compare
  python3 -m vclab.model_ref.model_ref --blend hero.blend --export-only        # just the VoxelCore files
  python3 -m vclab.model_ref.model_ref --blend b.blend --vcm m.vcm --png t.png --anim walk=walk.vca@0   # own export
Without --anim the exporter takes timeline markers (one animation per marker) or the scene range.
DIR defaults to <work_root>/model_ref/<name> and must be on a Windows drive (Blender is a Windows program).

Blender side (blender_frames.py): the .blend rendered by the engine stand's camera, the engine's model shading
reproduced (texel * (0.8 + 0.2 * dot(face normal, SUN)), back faces culled), no AA, transparent film.
Engine side (F2F): lease `vc/vctest_window` (hidden, 854x480, virtual clock, isolated input; flags checked) with
stand.lua and the pack refview (copied into the lease dir): one entity, the VCM loaded with its skeleton, the
textures and VCAs loaded at run time as a game client does; F2F `render` = only the entities layer, lighting off,
clear magenta; pose = the track at t = k / fps exactly, then `step` + `shot`.
Compare per frame: silhouette IoU and the pixels only in one of them (geometry / pose), colour error inside both
(texture / UV / shading). Out: blender/, engine/, diff/<frame>.png (blender | engine | map), sheet_<anim>.png,
summary.json, report.md, report.html, progress.log.
"""
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
if REPO not in sys.path:
    sys.path.insert(0, REPO)
LAB = os.path.join(REPO, "bin", "lab")
CLEAR = (255, 0, 255)
W, H = 854, 480
DEFAULT_CAM = {"pos": [-1.8, 0.6, -3.0], "target": [0, 0.4, 0], "fov": 40}
_PROGRESS = [None]


def log(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    if _PROGRESS[0]:
        with open(_PROGRESS[0], "a", encoding="utf-8") as fo:
            fo.write(line + "\n")


def win(p):
    return subprocess.check_output(["wslpath", "-w", os.path.abspath(p)], text=True).strip()


def unix(p):
    return subprocess.check_output(["wslpath", "-u", p], text=True).strip()


def machine():
    try:
        from vclab import machine as m
        return m.load()
    except Exception:
        return {}


def blender_exe():
    """$BLENDER, machine.toml `blender`, then the usual install places"""
    cands = [os.environ.get("BLENDER"), machine().get("blender")]
    cands += ["/mnt/d/Prog/Blender/blender.exe", "/mnt/c/Program Files/Blender Foundation/Blender 4.5/blender.exe",
              "/mnt/c/Program Files/Blender Foundation/Blender 4.4/blender.exe",
              "/mnt/c/Program Files/Blender Foundation/Blender 4.2/blender.exe"]
    for c in cands:
        if not c:
            continue
        p = unix(c) if re.match(r"^[A-Za-z]:\\", c) else c
        if os.path.isfile(p):
            return p
    raise RuntimeError("Blender not found: set machine.toml `blender = 'D:\\...\\blender.exe'` or $BLENDER")


def default_out(name):
    wr = machine().get("work_root")
    base = unix(wr) if wr else os.path.join(REPO, "work")
    return os.path.join(base, "model_ref", name)


def check_win_path(p, what):
    if not os.path.abspath(p).startswith("/mnt/"):
        raise RuntimeError("%s must be on a Windows drive (/mnt/<x>/...), Blender cannot read %s" % (what, p))


def lab(daemon, *args, timeout=300):
    env = dict(os.environ, LAB_OWNER=os.environ.get("LAB_OWNER", "claude"), WSLENV="LAB_OWNER")
    r = subprocess.run([LAB, "--daemon", str(daemon)] + list(args), capture_output=True, text=True, timeout=timeout,
                       env=env)
    out = r.stdout.strip()
    try:
        return json.loads(out)
    except ValueError:
        return {"ok": False, "error": (out + r.stderr)[-800:]}


def f2f(daemon, lease, cmd, args=None):
    r = lab(daemon, "f2f", lease, cmd, json.dumps(args or {}))
    if not r.get("ok"):
        raise RuntimeError("f2f %s: %s" % (cmd, r.get("error")))
    return r.get("result")


def vca_meta(path):
    txt = open(path, encoding="utf-8").read()
    m = re.search(r"@configure([^\n]*)", txt) or None
    fps = float(re.search(r"fps\s+([\d.]+)", m.group(1)).group(1)) if m else 60.0
    dur = float(re.search(r"duration\s+([\d.]+)", m.group(1)).group(1)) if m else 1.0
    return fps, dur


# ------------------------------------------------------------------------------------------------- export
def export(blend, out, name=None, anims=None, rest_frame=None, rest=None, root_y=-0.5, scale=1.0, poses=False,
           timeout=900):
    """blender_export.py: the .blend -> out/ (VCM, PNG, VCA, export.json); returns the manifest.
    anims: [{"name", "start", "end"} | {"name", "action"}] or specs "walk=0-24" / "run=@Action"."""
    check_win_path(out, "the export dir")
    os.makedirs(out, exist_ok=True)
    specs = []
    for sp in anims or []:
        if isinstance(sp, dict):
            specs.append(sp)
            continue
        nm, rest_s = sp.split("=", 1)
        if rest_s.startswith("@"):
            specs.append({"name": nm, "action": rest_s[1:]})
        else:
            m = re.match(r"^(-?\d+)\s*[-:]\s*(-?\d+)$", rest_s)
            if not m:
                raise ValueError("anim spec %r: name=START-END or name=@Action" % sp)
            specs.append({"name": nm, "start": int(m.group(1)), "end": int(m.group(2))})
    job = {"out": win(out), "name": name, "anims": specs, "rest_frame": rest_frame, "rest": rest or "identity",
           "root_y": root_y, "scale": scale, "poses": poses}
    jp = os.path.join(out, "export_job.json")
    json.dump(job, open(jp, "w"))
    r = subprocess.run([blender_exe(), "-b", win(blend), "--python", win(os.path.join(HERE, "blender_export.py")), "--",
                        win(jp)], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0 or "model_ref export:" not in r.stdout:
        raise RuntimeError("blender export failed: " + (r.stdout + r.stderr)[-2000:])
    return json.load(open(os.path.join(out, "export.json"), encoding="utf-8"))


# ------------------------------------------------------------------------------------------------- Blender
def blender_frames(a, frames, out):
    job = {"out": win(out), "w": W, "h": H, "cam": a.cam, "root_y": a.root_y, "shading": a.shading,
           "frames": [{"name": f["name"], "frame": f["bframe"], "action": f.get("action")} for f in frames]}
    jp = os.path.join(a.out, "blender_job.json")
    json.dump(job, open(jp, "w"))
    t0 = time.time()
    r = subprocess.run([blender_exe(), "-b", win(a.blend), "--python", win(os.path.join(HERE, "blender_frames.py")),
                        "--", win(jp)], capture_output=True, text=True, timeout=3600)
    if r.returncode != 0 or "model_ref blender:" not in r.stdout:
        raise RuntimeError("blender failed: " + (r.stdout + r.stderr)[-1500:])
    return round(time.time() - t0, 1)


# ------------------------------------------------------------------------------------------------- engine (F2F)
def engine_frames(a, frames, out):
    r = lab(a.daemon, "lease", "vc", "vctest_window", "--param", "test=" + win(os.path.join(HERE, "stand.lua")),
            "--ttl", "1800")
    if not r.get("ok"):
        raise RuntimeError("lease: %s" % r.get("error"))
    lease = r["lease"]["name"]
    ldir = unix(r["lease"]["dir"])
    info = {"lease": lease}
    log("engine: lease %s" % lease)
    try:
        shutil.copytree(os.path.join(HERE, "refview"), os.path.join(ldir, "content", "refview"), dirs_exist_ok=True)
        rd = os.path.join(ldir, "ref")
        os.makedirs(rd, exist_ok=True)
        json.dump({"settings": {"graphics.ssao": a.ssao}}, open(os.path.join(rd, "stand_opts.json"), "w"))
        rel = {}
        for i, p in enumerate([a.vcm] + a.textures + [an["vca"] for an in a.anims.values()]):
            dst = "%02d_%s" % (i, os.path.basename(p))
            shutil.copy(p, os.path.join(rd, dst))
            rel[p] = "ref/" + dst
        s = lab(a.daemon, "start", lease, timeout=200)
        if not s.get("ok", True) and s.get("error"):
            raise RuntimeError("start: %s" % s.get("error"))
        hello = f2f(a.daemon, lease, "hello")
        fl = hello.get("flags") or {}
        info["hello"] = {"version": hello.get("version"), "flags": fl, "w": hello.get("w"), "h": hello.get("h")}
        if fl.get("window") != "hidden" or fl.get("input") != "isolated" or fl.get("clock") != "virtual":
            raise RuntimeError("lease not isolated: %s" % fl)
        for _ in range(20):
            f2f(a.daemon, lease, "step", {"frames": 10})
            try:
                if "stand ready" in json.dumps(f2f(a.daemon, lease, "ref", {"op": "info"})):
                    break
            except RuntimeError:
                pass
        info["load"] = f2f(a.daemon, lease, "ref", {"op": "load", "vcm": rel[a.vcm],
                                                     "textures": [rel[t] for t in a.textures],
                                                     "anims": {n: rel[an["vca"]] for n, an in a.anims.items()}})
        f2f(a.daemon, lease, "render", {"all": False, "layers": {"entities": True}, "clear": list(CLEAR)})
        info["cam"] = f2f(a.daemon, lease, "ref", dict(op="cam", **a.cam))
        f2f(a.daemon, lease, "step", {"frames": 3})
        t0 = time.time()
        for i, fr in enumerate(frames):
            f2f(a.daemon, lease, "ref", {"op": "pose", "anim": fr["anim"], "t": fr["t"]})
            f2f(a.daemon, lease, "step", {"frames": 2})
            f2f(a.daemon, lease, "shot", {"path": win(os.path.join(out, fr["name"] + ".png"))})
            if i % 24 == 23:
                log("engine: %d/%d frames" % (i + 1, len(frames)))
        info["shots_s"] = round(time.time() - t0, 1)
    finally:
        if not a.keep:
            lab(a.daemon, "release", lease)
        else:
            info["kept"] = True
    return info


# ------------------------------------------------------------------------------------------------- compare
def compare(bpath, epath):
    """silhouettes (Blender alpha > 127, engine != the clear colour) and colours -> metrics + the diff map"""
    b = Image.open(bpath).convert("RGBA")
    e = Image.open(epath).convert("RGB")
    B = np.asarray(b).astype(np.int32)
    E = np.asarray(e).astype(np.int32)
    inb = B[..., 3] > 127
    ine = np.abs(E - np.array(CLEAR)).sum(axis=2) > 60
    both, ob, oe = inb & ine, inb & ~ine, ine & ~inb
    d = np.abs(B[..., :3] - E).sum(axis=2) / 3.0
    big = both & (d > 24)
    v = np.minimum(255, (d * 4).astype(np.int32))
    D = np.zeros((H, W, 3), np.uint8)
    small = both & ~big
    D[small] = np.stack([v // 3] * 3, axis=-1)[small]
    D[big] = np.stack([v, v, np.zeros_like(v)], axis=-1)[big]
    D[ob] = (255, 40, 40)
    D[oe] = (40, 200, 255)
    any_ = inb | ine
    ys, xs = np.nonzero(any_)
    bbox = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())] if len(xs) else [W, H, 0, 0]
    inter, nob, noe = int(both.sum()), int(ob.sum()), int(oe.sum())
    union = inter + nob + noe
    cerr = d[both]
    res = {"iou": round(inter / union, 4) if union else 1.0, "px_blender": inter + nob, "px_engine": inter + noe,
           "only_blender": nob, "only_engine": noe, "color_mean": round(float(cerr.mean()), 2) if inter else 0,
           "color_p95": round(float(np.percentile(cerr, 95)), 2) if inter else 0,
           "color_bad_share": round(int(big.sum()) / inter, 4) if inter else 0, "bbox": bbox}
    return res, b, e, Image.fromarray(D, "RGB")


def panel(b, e, diff, crop):
    bg = Image.new("RGBA", b.size, CLEAR + (255,))
    bb = Image.alpha_composite(bg, b).convert("RGB")
    w, h = crop[2] - crop[0], crop[3] - crop[1]
    out = Image.new("RGB", (w * 3 + 8, h), (30, 30, 30))
    for i, im in enumerate((bb, e, diff)):
        out.paste(im.crop(crop), (i * (w + 4), 0))
    return out


def html_report(out):
    """report.html next to summary.json: the table, then per animation every frame (blender | engine | map)"""
    rep = json.load(open(os.path.join(out, "summary.json")))
    rows = "".join("<tr><td>%s</td><td>%d</td><td>%.4f</td><td>%.4f</td><td>%s</td><td>%d</td><td>%.2f</td><td>%.1f%%</td></tr>" % (
        a, s["frames"], s["iou_min"], s["iou_mean"], s["iou_worst_frame"], s["only_px_max"], s["color_mean"],
        100 * s["color_bad_share_max"]) for a, s in rep["summary"].items())
    frames = ""
    for name, r in rep["frames_detail"].items():
        bad = r["iou"] < 0.999 or r["color_bad_share"] > 0.01
        frames += ('<figure class="%s"><img src="diff/%s.png" loading="lazy"><figcaption>%s t=%.3f &middot; IoU %.4f &middot; '
                   'only B %d / E %d &middot; colour %.2f, bad %.2f%%</figcaption></figure>' % (
                       "bad" if bad else "", name, name, r["t"], r["iou"], r["only_blender"], r["only_engine"],
                       r["color_mean"], 100 * r["color_bad_share"]))
    html = """<!doctype html><meta charset="utf-8"><title>model_ref %s</title>
<style>body{font:14px system-ui;background:#111;color:#ddd;margin:16px}table{border-collapse:collapse}td,th{border:1px solid #444;
padding:4px 8px}figure{display:inline-block;margin:6px}figure.bad{outline:3px solid #e33}img{image-rendering:pixelated;max-width:100%%}
figcaption{font-size:12px}</style><h1>model_ref: %s</h1><p>%s</p><table><tr><th>anim</th><th>frames</th><th>IoU min</th>
<th>IoU mean</th><th>worst</th><th>px only one side, max</th><th>colour err mean</th><th>colour bad px max</th></tr>%s</table>
<p>panel: Blender | VoxelCore | map: red = only Blender, cyan = only engine, yellow = colour off by &gt; 24/255, grey = small.
Frames framed in red: IoU &lt; 0.999 or &gt; 1%% bad colour.</p>%s""" % (
        os.path.basename(rep["args"]["vcm"]), os.path.basename(rep["args"]["vcm"]),
        "shading %s, ssao %s, camera %s" % (rep["args"].get("shading"), rep["args"].get("ssao"), json.dumps(rep["args"]["cam"])),
        rows, frames)
    open(os.path.join(out, "report.html"), "w", encoding="utf-8").write(html)
    return os.path.join(out, "report.html")


def build_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--blend", required=True, help="the source scene")
    ap.add_argument("--anim", action="append", default=[],
                    help="exporter: name=START-END | name=@Action; with --vcm: name=file.vca@<blender frame of t=0>")
    ap.add_argument("--out", help="output dir (default <work_root>/model_ref/<blend name>), on a Windows drive")
    ap.add_argument("--name", help="model name for the export (default: the .blend name)")
    ap.add_argument("--rest-frame", type=int, help="exporter: frame of the rest pose (default scene start)")
    ap.add_argument("--rest", choices=["identity", "frame"], default="identity",
                    help="exporter: animated objects' rest rotation dropped (identity) or as at --rest-frame")
    ap.add_argument("--scale", type=float, default=1.0, help="exporter: Blender metres -> blocks")
    ap.add_argument("--poses", action="store_true", help="exporter: also <name>_poses.json (bone poses per frame)")
    ap.add_argument("--export-only", action="store_true", help="only export the VoxelCore files, no compare")
    ap.add_argument("--vcm", help="compare an existing export instead (then --png and --anim name=file.vca@start)")
    ap.add_argument("--png", action="append", default=[], help="with --vcm: texture $0, $1, ... in order")
    ap.add_argument("--daemon", type=int, default=int(os.environ.get("MODEL_REF_DAEMON", 25802)),
                    help="lab daemon for the engine lease (own isolated daemon, not the play one)")
    ap.add_argument("--every", type=int, default=1, help="every N-th frame of each animation")
    ap.add_argument("--cam", default=json.dumps(DEFAULT_CAM), help="JSON {pos, target, fov}: VC axes, entity space")
    ap.add_argument("--root-y", type=float, default=-0.5, help="VC y of the Blender z=0 plane, relative to the entity")
    ap.add_argument("--keep", action="store_true", help="keep the engine lease (debug)")
    ap.add_argument("--ssao", type=int, default=0, help="engine graphics.ssao (0 off: the export alone; 1 = game look)")
    ap.add_argument("--shading", choices=["vc", "flat"], default="vc",
                    help="vc: Blender reproduces the engine's per-face model shading (default); flat: texels only")
    a = ap.parse_args(argv)
    a.cam = json.loads(a.cam) if isinstance(a.cam, str) else a.cam
    return a


def run(a):
    """export (unless --vcm) + Blender frames + engine frames + compare -> the summary dict"""
    a.blend = os.path.abspath(a.blend)
    a.out = os.path.abspath(a.out or default_out(a.name or os.path.splitext(os.path.basename(a.blend))[0]))
    check_win_path(a.out, "--out")
    check_win_path(a.blend, "--blend")
    os.makedirs(a.out, exist_ok=True)
    _PROGRESS[0] = os.path.join(a.out, "progress.log")
    open(_PROGRESS[0], "w").close()
    a.anims = {}
    if a.vcm:
        a.textures = [os.path.abspath(p) for p in a.png]
        for sp in a.anim:
            name, rest = sp.split("=", 1)
            path, start = (rest.rsplit("@", 1) + ["0"])[:2]
            a.anims[name] = {"vca": os.path.abspath(path), "start": int(start)}
    else:
        ed = os.path.join(a.out, "export")
        log("export: %s" % a.blend)
        m = export(a.blend, ed, a.name, a.anim, a.rest_frame, a.rest, a.root_y, a.scale, a.poses)
        a.manifest = m
        for w in m.get("warnings") or []:
            log("export warning: " + w)
        log("export: %d bones, %d tris, textures %s, anims %s" % (len(m["bones"]), m["tris"],
                                                                  [t["file"] for t in m["textures"]], list(m["anims"])))
        a.vcm = os.path.join(ed, m["vcm"])
        a.textures = [os.path.join(ed, t["file"]) for t in m["textures"]]
        for name, an in m["anims"].items():
            a.anims[name] = {"vca": os.path.join(ed, an["file"]), "start": an["start"], "action": an.get("action")}
        if a.export_only:
            log("done (export only): " + ed)
            return {"export": m, "dir": ed}
    frames = []
    for name, an in a.anims.items():
        fps, dur = vca_meta(an["vca"])
        n = max(1, int(round(dur * fps)))
        for k in range(0, n, a.every):
            frames.append({"name": "%s_%03d" % (name, k), "anim": name, "k": k, "t": k / fps,
                           "bframe": an["start"] + k, "fps": fps, "action": an.get("action")})
    if not frames:
        frames.append({"name": "rest", "anim": None, "k": 0, "t": 0, "bframe": a.rest_frame or 0, "fps": 1})
    dirs = {k: os.path.join(a.out, k) for k in ("blender", "engine", "diff")}
    for d in dirs.values():
        os.makedirs(d, exist_ok=True)
    rep = {"args": {k: v for k, v in vars(a).items() if k not in ("anims", "anim")}, "anims": a.anims,
           "frames": len(frames), "export": getattr(a, "manifest", None)}
    log("blender: %d frames" % len(frames))
    rep["blender_s"] = blender_frames(a, frames, dirs["blender"])
    log("blender: done in %ss; engine" % rep["blender_s"])
    rep["engine"] = engine_frames(a, frames, dirs["engine"])
    log("compare")
    results, by_anim = {}, {}
    gb = [W, H, 0, 0]
    loaded = {}
    for fr in frames:
        res, b, e, diff = compare(os.path.join(dirs["blender"], fr["name"] + ".png"),
                                  os.path.join(dirs["engine"], fr["name"] + ".png"))
        res["t"] = round(fr["t"], 4)
        results[fr["name"]] = res
        loaded[fr["name"]] = (b, e, diff)
        bb = res["bbox"]
        gb = [min(gb[0], bb[0]), min(gb[1], bb[1]), max(gb[2], bb[2]), max(gb[3], bb[3])]
        by_anim.setdefault(fr["anim"] or "rest", []).append(fr["name"])
    m = 12
    crop = (max(0, gb[0] - m), max(0, gb[1] - m), min(W, gb[2] + m), min(H, gb[3] + m))
    sheets = {}
    for anim, names in by_anim.items():
        rows = []
        for nm in names:
            b, e, diff = loaded[nm]
            p = panel(b, e, diff, crop)
            p.save(os.path.join(dirs["diff"], nm + ".png"))
            r = results[nm]
            d = ImageDraw.Draw(p)
            d.text((4, 2), "%s t=%.3f IoU %.3f  only B %d / E %d  colour mean %.1f bad %.1f%%" % (
                nm, r["t"], r["iou"], r["only_blender"], r["only_engine"], r["color_mean"],
                100 * r["color_bad_share"]), fill=(255, 255, 255))
            rows.append(p)
        cols = 2
        pw, ph = rows[0].size
        sheet = Image.new("RGB", (pw * cols + 6 * (cols - 1), (ph + 6) * math.ceil(len(rows) / cols)), (0, 0, 0))
        for i, p in enumerate(rows):
            sheet.paste(p, ((i % cols) * (pw + 6), (i // cols) * (ph + 6)))
        sp = os.path.join(a.out, "sheet_%s.png" % anim)
        sheet.save(sp)
        sheets[anim] = sp
    agg = {}
    for anim, names in by_anim.items():
        rs = [results[n] for n in names]
        worst = min(rs, key=lambda r: r["iou"])
        agg[anim] = {"frames": len(rs), "iou_min": worst["iou"], "iou_mean": round(sum(r["iou"] for r in rs) / len(rs), 4),
                     "iou_worst_frame": next(n for n in names if results[n] is worst),
                     "only_px_max": max(r["only_blender"] + r["only_engine"] for r in rs),
                     "color_mean": round(sum(r["color_mean"] for r in rs) / len(rs), 2),
                     "color_bad_share_max": max(r["color_bad_share"] for r in rs)}
    rep.update({"summary": agg, "frames_detail": results, "sheets": sheets, "crop": crop})
    json.dump(rep, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    lines = ["# model_ref: %s" % os.path.basename(a.vcm), "",
             "Blender (%s shading, no AA, back faces culled) vs VoxelCore %s F2F (entities only, fullbright, ssao %d, magenta clear), "
             "camera %s." % (a.shading, (rep["engine"].get("hello") or {}).get("version"), a.ssao, json.dumps(a.cam)), "",
             "| anim | frames | IoU min | IoU mean | worst frame | px only one side, max | colour err mean | colour bad px max |",
             "|---|---|---|---|---|---|---|---|"]
    for anim, s in agg.items():
        lines.append("| %s | %d | %.4f | %.4f | %s | %d | %.2f | %.1f%% |" % (
            anim, s["frames"], s["iou_min"], s["iou_mean"], s["iou_worst_frame"], s["only_px_max"], s["color_mean"],
            100 * s["color_bad_share_max"]))
    lines += ["", "diff panel: blender | engine | map (red: only Blender, cyan: only engine, yellow: colour off by > 24, "
              "grey: small colour difference)."]
    open(os.path.join(a.out, "report.md"), "w").write("\n".join(lines) + "\n")
    rep["report_html"] = html_report(a.out)
    rep["worst"] = {an: max(names, key=lambda n: (1 - results[n]["iou"]) * 100 + results[n]["color_bad_share"])
                    for an, names in by_anim.items()}
    json.dump(rep, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    log("done: " + rep["report_html"])
    print("\n".join(lines))
    print("sheets:", json.dumps(sheets))
    print("report:", rep["report_html"])
    return rep



def main():
    try:
        rep = run(build_args())
    except Exception as exc:
        log("error: %s: %s" % (type(exc).__name__, exc))
        raise
    return 0 if rep else 1


if __name__ == "__main__":
    sys.exit(main())
