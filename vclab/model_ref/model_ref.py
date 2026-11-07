#!/usr/bin/env python3
"""model_ref — frame-by-frame pixel compare of a model + animations: Blender (the source) vs VoxelCore (F2F test build).

Lab tool (07.11.2026; MCP: vc_model_ref / vc_model_export). Typical — one .blend, the rest is derived:
  python3 -m vclab.model_ref.model_ref --blend hero.blend [--anim walk=0-24] [--anim run=@RunAction] [--out DIR]
    -> DIR/export/ (blender_export.py: hero.vcm, textures, <anim>.vca, export.json), then the compare
  python3 -m vclab.model_ref.model_ref --blend hero.blend --export-only        # just the VoxelCore files
  python3 -m vclab.model_ref.model_ref --blend b.blend --vcm m.vcm --png t.png --anim walk=walk.vca@0   # own export
Without --anim the exporter takes timeline markers (one animation per marker) or the scene range.
  ... --sub 2                                        # also half frames (between the keys: curves)
  ... --states 'idle:1, walk:2/0.25, idle:1/0.4'     # state switches with crossfades (engine = the client's blend)
DIR defaults to <work_root>/model_ref/<name> and must be on a Windows drive (Blender is a Windows program).

Blender side (blender_frames.py): the .blend rendered by the engine stand's camera, the engine's model shading
reproduced (texel * (0.8 + 0.2 * dot(face normal, SUN)), back faces culled), no AA, transparent film.
Engine side (F2F): lease `vc/vctest_window` (hidden, 854x480, virtual clock, isolated input; flags checked) with
stand.lua and the pack refview (copied into the lease dir): one entity, the VCM loaded with its skeleton, the
textures and VCAs loaded at run time as a game client does; F2F `render` = only the entities layer, lighting off,
clear magenta; pose = the track at t = k / fps exactly, then `step` + `shot`.
Compare per frame: silhouette IoU and the pixels only in one of them (geometry / pose), colour error inside both
(texture / UV / shading). Cameras framed on the model's bbox over all frames, --views front34,back34 by default.
Verdict: a frame fails below --min-iou / above --max-bad-color / --max-color-mean, with the bones its bad pixels are on
(track.json of the export); the previous summary.json in --out (or --baseline) -> WORSE per anim@view. Exit code:
0 ok, 1 some frame failed, 2 the run failed. Out: blender/, engine/, diff/<frame>.png (blender | engine | map),
sheet_<anim>_<view>.png, summary.json (+ summary.prev.json), history.jsonl, report.md, report.html, progress.log.
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
           timeout=900, curves="auto"):
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
           "root_y": root_y, "scale": scale, "poses": poses, "curves": curves}
    jp = os.path.join(out, "export_job.json")
    json.dump(job, open(jp, "w"))
    r = subprocess.run([blender_exe(), "-b", win(blend), "--python", win(os.path.join(HERE, "blender_export.py")), "--",
                        win(jp)], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0 or "model_ref export:" not in r.stdout:
        raise RuntimeError("blender export failed: " + (r.stdout + r.stderr)[-2000:])
    return json.load(open(os.path.join(out, "export.json"), encoding="utf-8"))


# ------------------------------------------------------------------------------------------------- Blender
def blender_frames(a, frames, out):
    job = {"out": win(out), "w": W, "h": H, "cam": frames[0]["cam"], "root_y": a.root_y, "shading": a.shading,
           "frames": [{"name": f["name"], "frame": f["bframe"], "subframe": f.get("subframe", 0.0),
                       "action": f.get("action"), "cam": f["cam"],
                       "blend": f.get("blend") if a.states and a.states_ref == "slerp" else None} for f in frames],
           "nla": getattr(a, "nla", None) if a.states and a.states_ref == "nla" else None}
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
        info["cam"] = f2f(a.daemon, lease, "ref", dict(op="cam", **frames[0]["cam"]))
        f2f(a.daemon, lease, "step", {"frames": 3})
        t0 = time.time()
        pose_key = cam_key = None
        for i, fr in enumerate(frames):
            key = json.dumps(fr.get("layers")) if fr.get("layers") else (fr["anim"], fr["t"])
            if key != pose_key:
                if fr.get("layers"):
                    f2f(a.daemon, lease, "ref", {"op": "blend", "layers": fr["layers"], "bones": a.bones})
                else:
                    f2f(a.daemon, lease, "ref", {"op": "pose", "anim": fr["anim"], "t": fr["t"]})
                pose_key = key
            if fr["view"] != cam_key:
                f2f(a.daemon, lease, "ref", dict(op="cam", **fr["cam"]))
                cam_key = fr["view"]
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
    return res, b, e, Image.fromarray(D, "RGB"), (ob | oe | big)


def panel(b, e, diff, crop):
    bg = Image.new("RGBA", b.size, CLEAR + (255,))
    bb = Image.alpha_composite(bg, b).convert("RGB")
    w, h = crop[2] - crop[0], crop[3] - crop[1]
    out = Image.new("RGB", (w * 3 + 8, h), (30, 30, 30))
    for i, im in enumerate((bb, e, diff)):
        out.paste(im.crop(crop), (i * (w + 4), 0))
    return out


# ------------------------------------------------------------------------------------------------- views, bones
VIEWS = {   # direction from the model to the camera, VC axes (the model's front is -Z, as the engine's entities)
    "front34": (-0.55, 0.3, -0.8), "back34": (0.55, 0.3, 0.8), "front": (0, 0.15, -1), "back": (0, 0.15, 1),
    "left": (-1, 0.15, 0), "right": (1, 0.15, 0), "top": (0.15, 1, -0.35),
}
FOV = 40.0


def _norm(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def auto_cams(bbox, views, fov=FOV):
    """a camera per view that holds the bbox (over all frames) whole: the bounding sphere in the vertical fov"""
    lo, hi = bbox
    c = [(lo[i] + hi[i]) / 2 for i in range(3)]
    r = max(0.05, math.sqrt(sum((hi[i] - lo[i]) ** 2 for i in range(3))) / 2)
    dist = r / math.sin(math.radians(fov / 2)) * 1.04
    cams = {}
    for v in views:
        d = _norm(VIEWS[v])
        cams[v] = {"pos": [round(c[i] + d[i] * dist, 4) for i in range(3)], "target": [round(x, 4) for x in c],
                   "fov": fov}
    return cams


def project(cam, pts):
    """VC entity-space points -> pixel coordinates of the 854x480 frame (the stand's camera: look_at, vertical fov)"""
    pos, tgt = cam["pos"], cam["target"]
    f = _norm([tgt[i] - pos[i] for i in range(3)])
    r = _norm([f[1] * 0 - f[2] * 1, f[2] * 0 - f[0] * 0, f[0] * 1 - f[1] * 0])      # f x up(0,1,0)
    u = [r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]]
    th = math.tan(math.radians(cam["fov"] / 2))
    out = []
    for p in pts:
        d = [p[i] - pos[i] for i in range(3)]
        z = max(1e-4, sum(d[i] * f[i] for i in range(3)))
        x = sum(d[i] * r[i] for i in range(3)) / (z * th * W / H)
        y = sum(d[i] * u[i] for i in range(3)) / (z * th)
        out.append(((x + 1) / 2 * W, (1 - y) / 2 * H))
    return out


def bones_at(track, fr):
    """[(bone, pivot xyz, centre xyz)] of the frame (rest pose when the track has no such frame)"""
    if not track:
        return []
    rows = track["anims"].get(fr["anim"]) if fr["anim"] else None
    row = rows[fr["k"]] if rows and fr["k"] < len(rows) else track["anims"]["_rest"][0]
    return [(b, v[:3], v[3:]) for b, v in zip(track["bones"], row)]


def attribute(mask, cam, bones):
    """the bad pixels of a frame -> share per bone: nearest bone segment (pivot -> geometry centre) on screen"""
    ys, xs = np.nonzero(mask)
    if not len(xs) or not bones:
        return []
    if len(xs) > 4000:
        sel = np.linspace(0, len(xs) - 1, 4000).astype(int)
        xs, ys = xs[sel], ys[sel]
    P = np.stack([xs, ys], axis=1).astype(float)
    best = np.full(len(P), 1e18)
    who = np.zeros(len(P), int)
    for j, (_b, pv, cn) in enumerate(bones):
        (ax, ay), (bx, by) = project(cam, [pv, cn])
        A, AB = np.array([ax, ay]), np.array([bx - ax, by - ay])
        L = float(AB @ AB)
        t = np.clip(((P - A) @ AB) / L, 0, 1) if L > 1e-9 else np.zeros(len(P))
        d = ((A + t[:, None] * AB - P) ** 2).sum(axis=1)
        upd = d < best
        best[upd], who[upd] = d[upd], j
    cnt = np.bincount(who, minlength=len(bones))
    order = np.argsort(-cnt)
    return [(bones[j][0], round(float(cnt[j]) / len(P), 2)) for j in order[:3] if cnt[j] > 0]


# ------------------------------------------------------------------------------------------------- verdict, history
def frame_fail(r, a):
    why = []
    if r["iou"] < a.min_iou:
        why.append("IoU %.4f < %.4f (%d px only one side)" % (r["iou"], a.min_iou, r["only_blender"] + r["only_engine"]))
    if r["color_bad_share"] > a.max_bad_color:
        why.append("colour off on %.1f%% > %.1f%%" % (100 * r["color_bad_share"], 100 * a.max_bad_color))
    if r["color_mean"] > a.max_color_mean:
        why.append("colour mean %.2f > %.2f" % (r["color_mean"], a.max_color_mean))
    return why


def baseline_delta(prev, rep):
    """per anim/view: IoU min and colour of the previous run vs this one"""
    out = []
    pa, ca = prev.get("summary") or {}, rep["summary"]
    for key, s in ca.items():
        p = pa.get(key)
        if not p:
            continue
        d = {"key": key, "iou_min": [p["iou_min"], s["iou_min"]], "color_mean": [p["color_mean"], s["color_mean"]],
             "fails": [p.get("fail_frames", 0), s.get("fail_frames", 0)]}
        d["worse"] = (s["iou_min"] < p["iou_min"] - 0.0005 or s["color_mean"] > p["color_mean"] + 0.5
                      or s.get("fail_frames", 0) > p.get("fail_frames", 0))
        d["better"] = (s["iou_min"] > p["iou_min"] + 0.0005 or s["color_mean"] < p["color_mean"] - 0.5
                       or s.get("fail_frames", 0) < p.get("fail_frames", 0))
        out.append(d)
    return out


def html_report(out):
    """report.html next to summary.json: verdict, table, the baseline, then every frame (blender | engine | map)"""
    rep = json.load(open(os.path.join(out, "summary.json")))
    rows = "".join("<tr class='%s'><td>%s</td><td>%d</td><td>%.4f</td><td>%.4f</td><td>%s</td><td>%d</td><td>%.2f</td>"
                   "<td>%.1f%%</td><td>%d</td></tr>" % (
                       "bad" if s.get("fail_frames") else "", k, s["frames"], s["iou_min"], s["iou_mean"],
                       s["iou_worst_frame"], s["only_px_max"], s["color_mean"], 100 * s["color_bad_share_max"],
                       s.get("fail_frames", 0)) for k, s in rep["summary"].items())
    base = ""
    if rep.get("baseline"):
        base = "<h2>vs previous run (%s)</h2><table><tr><th>anim@view</th><th>IoU min</th><th>colour mean</th>" \
               "<th>failed frames</th><th></th></tr>%s</table>" % (rep["baseline"]["from"], "".join(
                   "<tr class='%s'><td>%s</td><td>%.4f &rarr; %.4f</td><td>%.2f &rarr; %.2f</td><td>%d &rarr; %d</td>"
                   "<td>%s</td></tr>" % ("bad" if d["worse"] else "", d["key"], d["iou_min"][0], d["iou_min"][1],
                                         d["color_mean"][0], d["color_mean"][1], d["fails"][0], d["fails"][1],
                                         "WORSE" if d["worse"] else ("better" if d["better"] else "same"))
                   for d in rep["baseline"]["delta"]))
    fails = "".join("<li>%s</li>" % f for f in rep.get("fails", [])[:40])
    frames = ""
    for name, r in rep["frames_detail"].items():
        frames += ('<figure class="%s"><img src="diff/%s.png" loading="lazy"><figcaption>%s t=%.3f &middot; IoU %.4f '
                   '&middot; only B %d / E %d &middot; colour %.2f, bad %.2f%%%s</figcaption></figure>' % (
                       "bad" if r.get("fail") else "", name, name, r["t"], r["iou"], r["only_blender"],
                       r["only_engine"], r["color_mean"], 100 * r["color_bad_share"],
                       (" &middot; " + ", ".join("%s %d%%" % (b, 100 * w) for b, w in r["bones"])) if r.get("bones")
                       else ""))
    th = rep.get("thresholds", {})
    html = """<!doctype html><meta charset="utf-8"><title>model_ref %s</title>
<style>body{font:14px system-ui;background:#111;color:#ddd;margin:16px}table{border-collapse:collapse}td,th{border:1px solid #444;
padding:4px 8px}tr.bad td{color:#f77}figure{display:inline-block;margin:6px}figure.bad{outline:3px solid #e33}
img{image-rendering:pixelated;max-width:100%%}figcaption{font-size:12px}.v{font-size:20px;font-weight:bold}
.ok{color:#6d6}.fail{color:#f55}</style><h1>model_ref: %s</h1><p class="v %s">%s</p><p>thresholds: IoU &ge; %s,
colour off &le; %s%% of pixels, colour mean &le; %s; views %s; shading %s, ssao %s</p><table><tr><th>anim@view</th>
<th>frames</th><th>IoU min</th><th>IoU mean</th><th>worst</th><th>px only one side, max</th><th>colour err mean</th>
<th>colour bad px max</th><th>failed</th></tr>%s</table>%s<ul>%s</ul>
<p>panel: Blender | VoxelCore | map: red = only Blender, cyan = only engine, yellow = colour off by &gt; 24/255, grey =
small. Failed frames framed in red; bones = where the bad pixels are (nearest bone).</p>%s""" % (
        rep["model"], rep["model"], "ok" if rep["verdict"] == "ok" else "fail", rep["verdict_line"],
        th.get("min_iou"), 100 * th.get("max_bad_color", 0), th.get("max_color_mean"), ", ".join(rep["views"]),
        rep["args"].get("shading"), rep["args"].get("ssao"), rows, base, fails, frames)
    open(os.path.join(out, "report.html"), "w", encoding="utf-8").write(html)
    return os.path.join(out, "report.html")


# ------------------------------------------------------------------------------------------------- states
def parse_states(spec):
    """'idle:1, walk:2/0.25, idle:1/0.25' -> [(anim, seconds, fade into it, seconds)]"""
    out = []
    for part in [p.strip() for p in spec.split(",") if p.strip()]:
        m = re.match(r"^([\w.-]+):([\d.]+)(?:/([\d.]+))?$", part)
        if not m:
            raise ValueError("state %r: anim:seconds[/fade seconds]" % part)
        out.append((m.group(1), float(m.group(2)), float(m.group(3) or 0)))
    return out


def smoothstep(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def states_poses(a):
    """the state timeline -> engine poses (one or two layers, the second with the eased weight) and the NLA job of
    the Blender side; every state's animation loops from its own t = 0 (a script's play_anim)"""
    st = parse_states(a.states)
    fps = None
    for name, _d, _f in st:
        if name not in a.anims:
            raise ValueError("state anim %r: have %s" % (name, list(a.anims)))
        f_, _ = vca_meta(a.anims[name]["vca"])
        fps = fps or f_
    starts, f = [], 0
    for name, d, fade in st:
        starts.append(f)
        f += int(round(d * fps))
    total = f
    nla = {"states": []}
    for i, (name, d, fade) in enumerate(st):
        an = a.anims[name]
        until = (starts[i + 1] + st[i + 1][2] * fps) if i + 1 < len(st) else total
        nla["states"].append({"anim": name, "start": starts[i], "until": until + 1, "fade": fade * fps,
                              "action": an.get("action"), "a0": an["start"], "a1": an["end"]})
    poses = []
    for j in range(0, total, a.every):
        for q in range(a.sub):
            fr = j + q / a.sub
            i = max(k for k in range(len(st)) if starts[k] <= fr)

            def layer(k):
                an = a.anims[st[k][0]]
                ln = an["end"] - an["start"]
                lf = (fr - starts[k]) % ln if ln > 0 else 0.0
                blend.append({"frame": an["start"] + lf, "action": an.get("action")})
                return {"anim": st[k][0], "t": round(lf / fps, 6)}, lf
            blend = []
            cur, lf = layer(i)
            layers = [cur]
            fade = st[i][2] * fps
            if i > 0 and fade > 0 and fr - starts[i] < fade:
                prev, lfp = layer(i - 1)
                blend.reverse()                          # [outgoing, incoming]
                w = smoothstep((fr - starts[i]) / fade)
                cur["w"] = round(w, 6)
                blend[1]["w"] = cur["w"]
                layers = [prev, cur]
                if w < 0.5:
                    lf = lfp
                    i_dom = i - 1
                else:
                    i_dom = i
            else:
                i_dom = i
            poses.append({"pname": "st_%04d" % j + ("_%02d" % (100 * q // a.sub) if q else ""), "anim": st[i_dom][0],
                          "k": int(lf), "t": fr / fps, "bframe": j, "subframe": q / a.sub, "fps": fps,
                          "layers": layers, "blend": blend, "state": i})
    return poses, nla


# ------------------------------------------------------------------------------------------------- main
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
    ap.add_argument("--curves", choices=["auto", "bake", "linear"], default="auto",
                    help="exporter: auto = Blender's keys as VCA bezier where they map 1:1 (verified), the rest baked "
                         "per frame with smooth handles; bake = all baked (smooth); linear = baked, curve linear")
    ap.add_argument("--states", help="states test: 'idle:1, walk:2/0.25, idle:1/0.25' = anim:seconds[/fade into it];"
                         " engine = the client's crossfade (slerp, smoothstep), Blender = NLA strips with the same ramp")
    ap.add_argument("--states-ref", choices=["slerp", "nla"], default="slerp",
                    help="Blender side of --states: slerp = the client's crossfade on Blender's own poses (checks the "
                         "engine implementation), nla = NLA strips (per channel lerp, as an animator sees it)")
    ap.add_argument("--sub", type=int, default=1, help="poses per frame: 2 = also every half frame (between keys)")
    ap.add_argument("--vcm", help="compare an existing export instead (then --png and --anim name=file.vca@start)")
    ap.add_argument("--png", action="append", default=[], help="with --vcm: texture $0, $1, ... in order")
    ap.add_argument("--daemon", type=int, default=int(os.environ.get("MODEL_REF_DAEMON", 25802)),
                    help="lab daemon for the engine lease (own isolated daemon, not the play one)")
    ap.add_argument("--every", type=int, default=1, help="every N-th frame of each animation")
    ap.add_argument("--views", default="front34,back34",
                    help="cameras framed on the model's bbox over all frames: " + ",".join(VIEWS))
    ap.add_argument("--cam", help='one fixed camera instead of --views: JSON {"pos", "target", "fov"} (VC, entity)')
    ap.add_argument("--root-y", type=float, default=-0.5, help="VC y of the Blender z=0 plane, relative to the entity")
    ap.add_argument("--min-iou", type=float, default=0.999, help="a frame fails below (silhouette match)")
    ap.add_argument("--max-bad-color", type=float, default=0.01, help="a frame fails above (share of pixels > 24/255)")
    ap.add_argument("--max-color-mean", type=float, default=3.0, help="a frame fails above (mean colour error /255)")
    ap.add_argument("--baseline", help="summary.json (or its dir) to compare with; default: the previous run in --out")
    ap.add_argument("--keep", action="store_true", help="keep the engine lease (debug)")
    ap.add_argument("--ssao", type=int, default=0, help="engine graphics.ssao (0 off: the export alone; 1 = game look)")
    ap.add_argument("--shading", choices=["vc", "flat"], default="vc",
                    help="vc: Blender reproduces the engine's per-face model shading (default); flat: texels only")
    a = ap.parse_args(argv)
    if isinstance(a.cam, str):
        a.cam = json.loads(a.cam)
    return a


def run(a):
    """export (unless --vcm) + Blender frames + engine frames + compare + verdict -> the summary dict"""
    a.blend = os.path.abspath(a.blend)
    a.out = os.path.abspath(a.out or default_out(a.name or os.path.splitext(os.path.basename(a.blend))[0]))
    check_win_path(a.out, "--out")
    check_win_path(a.blend, "--blend")
    os.makedirs(a.out, exist_ok=True)
    _PROGRESS[0] = os.path.join(a.out, "progress.log")
    open(_PROGRESS[0], "w").close()
    prev, prev_from = None, None
    bp = a.baseline and (os.path.join(a.baseline, "summary.json") if os.path.isdir(a.baseline) else a.baseline)
    bp = bp or os.path.join(a.out, "summary.json")
    if os.path.isfile(bp):
        try:
            prev = json.load(open(bp, encoding="utf-8"))
            prev_from = "%s (%s)" % (bp, prev.get("time", "?"))
        except ValueError:
            prev = None
    a.anims, track = {}, None
    if a.vcm:
        a.textures = [os.path.abspath(p) for p in a.png]
        for sp in a.anim:
            name, rest = sp.split("=", 1)
            path, start = (rest.rsplit("@", 1) + ["0"])[:2]
            fps_, dur_ = vca_meta(os.path.abspath(path))
            a.anims[name] = {"vca": os.path.abspath(path), "start": int(start), "end": int(start) + round(dur_ * fps_)}
        bbox = [[-0.6, -0.5, -0.6], [0.6, 1.5, 0.6]]                          # unknown: a humanoid-sized box
        tj = os.path.join(os.path.dirname(os.path.abspath(a.vcm)), "track.json")  # our export next to it: framing, bones
        if os.path.isfile(tj):
            track = json.load(open(tj, encoding="utf-8"))
            bbox = track["bbox"]
    else:
        ed = os.path.join(a.out, "export")
        log("export: %s" % a.blend)
        m = export(a.blend, ed, a.name, a.anim, a.rest_frame, a.rest, a.root_y, a.scale, a.poses, curves=a.curves)
        a.manifest = m
        for w in m.get("warnings") or []:
            log("export warning: " + w)
        log("export: %d bones, %d tris, textures %s, anims %s" % (len(m["bones"]), m["tris"],
                                                                  [t["file"] for t in m["textures"]], list(m["anims"])))
        a.vcm = os.path.join(ed, m["vcm"])
        a.textures = [os.path.join(ed, t["file"]) for t in m["textures"]]
        for name, an in m["anims"].items():
            a.anims[name] = {"vca": os.path.join(ed, an["file"]), "start": an["start"], "end": an["end"],
                             "action": an.get("action")}
        if a.export_only:
            log("done (export only): " + ed)
            return {"export": m, "dir": ed, "verdict": "ok"}
        track = json.load(open(os.path.join(ed, "track.json"), encoding="utf-8"))
        bbox = m["bbox"]
    rep_states = None
    cams = {"cam": a.cam} if a.cam else auto_cams(bbox, [v.strip() for v in a.views.split(",") if v.strip()])
    poses = []
    for name, an in a.anims.items():
        fps, dur = vca_meta(an["vca"])
        n = max(1, int(round(dur * fps)))
        for k in range(0, n, a.every):
            for j in range(a.sub):                   # --sub N: N-1 poses between frames (between the keys)
                poses.append({"pname": "%s_%03d" % (name, k) + ("_%02d" % (100 * j // a.sub) if j else ""),
                              "anim": name, "k": k, "t": (k + j / a.sub) / fps, "bframe": an["start"] + k,
                              "subframe": j / a.sub, "fps": fps, "action": an.get("action")})
    if a.states:
        poses, nla = states_poses(a)
        rep_states = nla
    if not poses:
        poses.append({"pname": "rest", "anim": None, "k": 0, "t": 0, "bframe": a.rest_frame or 0, "fps": 1})
    frames = []
    for p in poses:
        for v, c in cams.items():
            frames.append(dict(p, name="%s_%s" % (p["pname"], v), view=v, cam=c))
    dirs = {k: os.path.join(a.out, k) for k in ("blender", "engine", "diff")}
    for d in dirs.values():
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)
    rep = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "model": os.path.basename(a.vcm),
           "args": {k: v for k, v in vars(a).items() if k not in ("anims", "anim", "manifest")}, "anims": a.anims,
           "views": list(cams), "cams": cams, "frames": len(frames), "export": getattr(a, "manifest", None),
           "thresholds": {"min_iou": a.min_iou, "max_bad_color": a.max_bad_color, "max_color_mean": a.max_color_mean},
           "states": rep_states}
    a.nla = rep_states
    a.bones = [b["name"] for b in (getattr(a, "manifest", None) or {}).get("bones", [])] or (
        track["bones"] if track else [])
    log("blender: %d frames (%d poses x %d views)" % (len(frames), len(poses), len(cams)))
    rep["blender_s"] = blender_frames(a, frames, dirs["blender"])
    log("blender: done in %ss; engine" % rep["blender_s"])
    rep["engine"] = engine_frames(a, frames, dirs["engine"])
    log("compare")
    results, groups, loaded = {}, {}, {}
    boxes = {}
    for fr in frames:
        res, b, e, diff, bad = compare(os.path.join(dirs["blender"], fr["name"] + ".png"),
                                       os.path.join(dirs["engine"], fr["name"] + ".png"))
        res["t"] = round(fr["t"], 4)
        res["view"] = fr["view"]
        why = frame_fail(res, a)
        if why:
            res["fail"] = why
            res["bones"] = attribute(bad, fr["cam"], bones_at(track, fr))
        results[fr["name"]] = res
        loaded[fr["name"]] = (b, e, diff)
        key = "%s@%s" % ("states" if fr.get("layers") else (fr["anim"] or "rest"), fr["view"])
        groups.setdefault(key, []).append(fr["name"])
        bb, gb = res["bbox"], boxes.get(fr["view"], [W, H, 0, 0])
        boxes[fr["view"]] = [min(gb[0], bb[0]), min(gb[1], bb[1]), max(gb[2], bb[2]), max(gb[3], bb[3])]
    sheets = {}
    for key, names in groups.items():
        gb = boxes[results[names[0]]["view"]]
        crop = (max(0, gb[0] - 12), max(0, gb[1] - 12), min(W, gb[2] + 12), min(H, gb[3] + 12))
        if crop[2] <= crop[0] or crop[3] <= crop[1]:
            crop = (0, 0, W, H)
        rows = []
        for nm in names:
            b, e, diff = loaded[nm]
            p = panel(b, e, diff, crop)
            p.save(os.path.join(dirs["diff"], nm + ".png"))
            r = results[nm]
            d = ImageDraw.Draw(p)
            d.text((4, 2), "%s IoU %.4f  only B %d / E %d  colour %.1f bad %.1f%%%s" % (
                nm, r["iou"], r["only_blender"], r["only_engine"], r["color_mean"], 100 * r["color_bad_share"],
                ("  FAIL " + ",".join(b_ for b_, _ in r.get("bones", []))) if r.get("fail") else ""),
                fill=(255, 80, 80) if r.get("fail") else (255, 255, 255))
            rows.append(p)
        cols = 2
        pw, ph = rows[0].size
        sheet = Image.new("RGB", (pw * cols + 6 * (cols - 1), (ph + 6) * math.ceil(len(rows) / cols)), (0, 0, 0))
        for i, p in enumerate(rows):
            sheet.paste(p, ((i % cols) * (pw + 6), (i // cols) * (ph + 6)))
        sp = os.path.join(a.out, "sheet_%s.png" % key.replace("@", "_"))
        sheet.save(sp)
        sheets[key] = sp
    agg = {}
    for key, names in groups.items():
        rs = [results[n] for n in names]
        worst = min(rs, key=lambda r: (r["iou"], -r["color_bad_share"]))
        agg[key] = {"frames": len(rs), "iou_min": worst["iou"], "iou_mean": round(sum(r["iou"] for r in rs) / len(rs), 4),
                    "iou_worst_frame": next(n for n in names if results[n] is worst),
                    "only_px_max": max(r["only_blender"] + r["only_engine"] for r in rs),
                    "color_mean": round(sum(r["color_mean"] for r in rs) / len(rs), 2),
                    "color_bad_share_max": max(r["color_bad_share"] for r in rs),
                    "fail_frames": sum(1 for r in rs if r.get("fail"))}
    failed = [(n, r) for n, r in results.items() if r.get("fail")]
    failed.sort(key=lambda nr: (nr[1]["iou"], -nr[1]["color_bad_share"]))
    rep["fails"] = ["%s: %s%s" % (n, "; ".join(r["fail"]), (" — bones " + ", ".join(
        "%s %d%%" % (b, 100 * w) for b, w in r["bones"])) if r.get("bones") else "") for n, r in failed]
    rep["verdict"] = "fail" if failed else "ok"
    best_iou = min(r["iou"] for r in results.values())
    rep["verdict_line"] = ("FAIL: %d of %d frames below the thresholds; worst %s" % (len(failed), len(results),
                           rep["fails"][0]) if failed else
                           "OK: %d frames, IoU min %.4f, colour mean max %.2f" % (
                               len(results), best_iou, max(r["color_mean"] for r in results.values())))
    rep.update({"summary": agg, "frames_detail": results, "sheets": sheets})
    rep["worst"] = {k: v["iou_worst_frame"] for k, v in agg.items()}
    if prev:
        delta = baseline_delta(prev, rep)
        rep["baseline"] = {"from": prev_from, "delta": delta, "worse": [d["key"] for d in delta if d["worse"]]}
        if rep["baseline"]["worse"]:
            rep["verdict_line"] += " | WORSE than the previous run: " + ", ".join(
                "%s IoU %.4f->%.4f" % (d["key"], d["iou_min"][0], d["iou_min"][1]) for d in delta if d["worse"])
    if os.path.isfile(os.path.join(a.out, "summary.json")):
        shutil.copy(os.path.join(a.out, "summary.json"), os.path.join(a.out, "summary.prev.json"))
    json.dump(rep, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    with open(os.path.join(a.out, "history.jsonl"), "a", encoding="utf-8") as fo:
        fo.write(json.dumps({"time": rep["time"], "blend": a.blend, "engine": (rep["engine"].get("hello") or {}).get(
            "version"), "verdict": rep["verdict"], "summary": {k: {kk: v[kk] for kk in (
                "iou_min", "color_mean", "color_bad_share_max", "fail_frames")} for k, v in agg.items()}}) + "\n")
    lines = ["# model_ref: %s" % rep["model"], "", rep["verdict_line"], "",
             "Blender (%s shading, no AA, back faces culled) vs VoxelCore %s F2F (entities only, fullbright, ssao %d), "
             "views %s; thresholds IoU >= %s, bad colour <= %.1f%%, colour mean <= %s." % (
                 a.shading, (rep["engine"].get("hello") or {}).get("version"), a.ssao, ", ".join(cams), a.min_iou,
                 100 * a.max_bad_color, a.max_color_mean), "",
             "| anim@view | frames | IoU min | IoU mean | worst frame | px only one side, max | colour err mean | "
             "colour bad px max | failed |", "|---|---|---|---|---|---|---|---|---|"]
    for key, s_ in agg.items():
        lines.append("| %s | %d | %.4f | %.4f | %s | %d | %.2f | %.1f%% | %d |" % (
            key, s_["frames"], s_["iou_min"], s_["iou_mean"], s_["iou_worst_frame"], s_["only_px_max"],
            s_["color_mean"], 100 * s_["color_bad_share_max"], s_["fail_frames"]))
    if rep["fails"]:
        lines += ["", "Failed frames (worst first):"] + ["- " + f for f in rep["fails"][:20]]
    if rep.get("baseline"):
        lines += ["", "vs %s:" % prev_from] + ["- %s: IoU min %.4f -> %.4f, colour %.2f -> %.2f, failed %d -> %d%s" % (
            d["key"], d["iou_min"][0], d["iou_min"][1], d["color_mean"][0], d["color_mean"][1], d["fails"][0],
            d["fails"][1], " WORSE" if d["worse"] else "") for d in rep["baseline"]["delta"]]
    open(os.path.join(a.out, "report.md"), "w").write("\n".join(lines) + "\n")
    rep["report_html"] = html_report(a.out)
    json.dump(rep, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    log("done: %s -> %s" % (rep["verdict_line"], rep["report_html"]))
    print("\n".join(lines))
    print("report:", rep["report_html"])
    return rep


def main():
    """exit 0 = every frame within the thresholds, 1 = some frame failed, 2 = the run itself failed"""
    try:
        rep = run(build_args())
    except Exception as exc:
        log("error: %s: %s" % (type(exc).__name__, exc))
        import traceback
        traceback.print_exc()
        return 2
    return 0 if rep.get("verdict") == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
