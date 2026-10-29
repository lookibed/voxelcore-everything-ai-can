#!/usr/bin/env python3
"""olife_caret (16.10): caret / selection / click-to-index check of the Olife editor textbox on VoxelCore 0.32 (F2F build).
Drives tools/scenarios/olife_caret_probe.lua (app script) through its stage file + F2F shot/input, measures in the frame:
caret column (pure white, >= 14 px), selection columns (additive blue), glyph ink, and compares them with the render pen
x of 0.32 draw_text (spaces 8 px = glyphInterval, other glyphs = FreeType advance). Click: middle of code point 20 of the
line -> the caret the engine chose (calcIndexAt), want = start + 21.

1) lease (one F2F client, no server; size 854x480 or the full window 1920x1080):
   LAB_OWNER=olife_caret tools/lab/lab lease olife menu_app --ttl 2400 --name olife-caret-1 --param size=854x480 \
     --param 'script=D:\Prog\VoxelCore\voxelcore-0.31.0_pre_gemini\tools\scenarios\olife_caret_probe.lua' \
     --param script_name=olife_caret_probe.lua --param 'packs=["olife_proto","olife_client","olife_caret_probe"]' --start
2) python3 tools/scenarios/olife_caret_run.py <out dir under artifacts/olife_caret> [variants 1..11] [lines 1,2,3]
3) tools/lab/lab release olife-caret-1
Variants: see VARIANTS in the probe (1/2 = the editor's olife_mono with/without line numbers, 3/4 stock font,
5/6 isFixedPitch=0, 7-10 condensed 0.5 em, 11 = the real olife_client:editor document). Output: PNGs + measure.json.
"""
import json, os, re, subprocess, sys, time
import numpy as np
from PIL import Image
VC = "/mnt/d/Prog/VoxelCore/voxelcore-0.31.0_pre_gemini"
WIN = "D:\\Prog\\VoxelCore\\voxelcore-0.31.0_pre_gemini"
LEASE = os.environ.get("CARET_LEASE", "olife-caret-1")
# 22.10 (v0327): CARET_INST — каталог экземпляров демона (изолированный: artifacts/lab/isolated/<порт>/inst),
# CARET_PEN=0327 — перо draw_text 0.32.3+ (каждый символ, и пробел, = advance шрифта; glyphInterval = advance '0')
INST = os.environ.get("CARET_INST", "artifacts/lab/inst")
PEN0327 = os.environ.get("CARET_PEN") == "0327"
out = sys.argv[1]
variants = [int(x) for x in (sys.argv[2] if len(sys.argv) > 2 else "1,2,3,4,5,6,7,8,9,10").split(",")]
lines = [int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else "1,2,3").split(",")]
os.makedirs(os.path.join(VC, "artifacts/olife_caret", out), exist_ok=True)
env = dict(os.environ, LAB_OWNER=os.environ.get("LAB_OWNER", "olife_caret"))
seq = [int(time.time()) % 100000]

def lab(*a):
    r = subprocess.run([VC + "/tools/lab/lab", *a], capture_output=True, text=True, env=env, cwd=VC)
    try:
        return json.loads(r.stdout)
    except Exception:
        raise RuntimeError(r.stdout + r.stderr)

def f2f(cmd, args):
    r = lab("f2f", LEASE, cmd, json.dumps(args))
    if not r.get("ok"):
        raise RuntimeError(r)
    return r.get("result")

CUR = [0, 0]
def stage(v, l, mode):
    seq[0] += 1
    CUR[0], CUR[1] = v, l
    with open(os.path.join(VC, INST, LEASE, "export/caret_stage.txt"), "w") as f:
        f.write("%d %d %s %d\n" % (v, l, mode, seq[0]))
    time.sleep(0.9)

def shot(name):
    p = "%s\\artifacts\\olife_caret\\%s\\%s.png" % (WIN, out.replace("/", "\\"), name)
    f2f("shot", {"path": p})
    return np.asarray(Image.open(os.path.join(VC, "artifacts/olife_caret", out, name + ".png")).convert("RGB")).astype(int)

def measure_caret(img):
    white = (img[:, :, 0] == 255) & (img[:, :, 1] == 255) & (img[:, :, 2] == 255)
    white[:36, :] = False              # title label
    cols = [x for x in range(img.shape[1]) if white[:, x].sum() >= 14]
    if not cols:
        return None
    x0, x1 = min(cols), max(cols)
    rows = np.where(white[:, x0])[0]
    y0, y1 = int(rows.min()), int(rows.max())
    band = img[y0:y1 + 1].max(axis=2)
    glyph = band > 90
    glyph[:, x0:x1 + 1] = False
    xs = np.where(glyph.any(axis=0))[0]
    xs = xs[xs > 60] if len(xs) else xs
    return {"caret_x": x0, "caret_w": x1 - x0 + 1, "band": [y0, y1], "text_end": int(xs.max()) if len(xs) else None}

def measure_sel(img, band):
    y0, y1 = band
    b = img[y0:y1 + 1]
    top = b[0:3].reshape(-1, img.shape[1], 3) if False else b
    selcol = []
    for x in range(img.shape[1]):
        col = b[:, x, :]
        # selection: additive (0.8,0.9,1.0)*0.25 -> blue >= 45 and blue > red in rows without glyph ink
        quiet = col[col.max(axis=1) < 110]
        if len(quiet) >= 3 and np.median(quiet[:, 2]) >= 45 and np.median(quiet[:, 2] - quiet[:, 0]) >= 8:
            selcol.append(x)
    glyph = b.max(axis=2) > 140
    xs = np.where(glyph.any(axis=0))[0]
    xs = xs[xs > 60]
    return {"sel": [min(selcol), max(selcol)] if selcol else None, "text_end": int(xs.max()) if len(xs) else None}

LOGP = os.path.join(VC, INST, LEASE, "latest.log")
OUTLOG = os.path.join(VC, INST, LEASE, "logs/menu_app.out.log")
def logtxt():
    return open(OUTLOG, encoding="utf-8", errors="replace").read()
def logged_caret():
    import re
    for _ in range(10):
        hits = re.findall(r"stage %d %d report %d .*?caret=(\d+)" % (CUR[0], CUR[1], seq[0]), logtxt())
        if hits:
            return int(hits[-1])
        time.sleep(0.3)
    return None

def init_lines():
    import re
    txt = logtxt()
    vp = re.findall(r"ready viewport=(\d+)x(\d+)", txt)[-1]
    return int(vp[0])
VW = init_lines()
if VW >= 1200:
    LINES = ["--    Olife  sample:  orbit  flight.  on_tick(dt) is called 20 times per second in the sandbox.",
             "Пример Olife: облёт по кругу. Вызывается двадцать раз в секунду в песочнице сервера.",
             "-- Пример Olife: облёт по кругу. on_tick(dt) вызывается 20 раз в секунду в песочнице."]
else:
    LINES = ["--    Olife  sample:  orbit.  on_tick(dt) 20 times/s.",
             "Пример: облёт по кругу, двадцать раз в секунду.",
             "-- Пример Olife: облёт. on_tick(dt) 20 раз в секунду."]
STARTS = [0, len(LINES[0]) + 1, len(LINES[0]) + len(LINES[1]) + 2]
FONT = {11: "olife_mono", 1: "olife_mono", 2: "olife_mono", 3: None, 4: None, 5: "caret_unfixed", 6: "caret_unfixed",
        7: "caret_narrow", 8: "caret_narrow", 9: "caret_narrow2", 10: "caret_narrow2",
        12: "caret_orig", 13: "caret_orig"}
def _adv_px(path):   # FreeType-like: advance of 'a' at 16 px (hinted 26.6 rounding: 9.63 -> 10, 8.0 -> 8)
    from fontTools.ttLib import TTFont
    f = TTFont(path); a = f["hmtx"][f.getBestCmap()[ord("a")]][0]
    return int(round(a * 16 / f["head"].unitsPerEm))
WIDE = {"olife_mono": _adv_px(VC + "/content/olife_client/fonts/olife_mono.ttf"),
        "caret_unfixed": _adv_px(VC + "/content/olife_caret_probe/fonts/caret_unfixed.ttf"),
        "caret_orig": _adv_px(VC + "/content/olife_caret_probe/fonts/caret_orig.ttf"),
        "caret_narrow": 8, "caret_narrow2": 8}
print("advance px:", WIDE, flush=True)
def adv_of(v, ch):   # how 0.32 draw_text advances: spaces/tabs = glyphInterval (8), others = FreeType xAdvance
    if ch in " \t" and not PEN0327:
        return 8
    return WIDE.get(FONT[v], 8)
def wpos_of(v):
    hits = re.findall(r"stage %d \d+ \w+ \d+ v=%d .*?wpos=(-?\d+),(-?\d+)" % (v, v), logtxt())
    return int(hits[-1][0]) if hits else 20
def pen_x(v, l, k):  # render pen x of code point k of line l (textbox wpos + padding 6 + line numbers pane 40)
    x0 = wpos_of(v) + 6 + (40 if v % 2 == 1 else 0)
    return x0 + sum(adv_of(v, c) for c in LINES[l - 1][:k])
res = []
for v in variants:
    for l in lines:
        stage(v, l, "caret")
        m = measure_caret(shot("v%d_l%d_caret" % (v, l)))
        r = {"v": v, "line": l, "caret": m}
        if m:
            stage(v, l, "sel")
            f2f("input", {"keys": {"LSHIFT": True}}); time.sleep(0.1)
            f2f("input", {"keys": {"END": True}}); time.sleep(0.1)
            f2f("input", {"keys": {"END": False}}); time.sleep(0.1)
            f2f("input", {"keys": {"LSHIFT": False}}); time.sleep(0.25)
            r["sel"] = measure_sel(shot("v%d_l%d_sel" % (v, l)), m["band"])
            stage(v, l, "hold")
            # mouse: click the middle of code point K of this line -> the engine's index (calcIndexAt) in the log
            K = 20
            y = (m["band"][0] + m["band"][1]) // 2
            x = pen_x(v, l, K) + adv_of(v, LINES[l - 1][K]) // 2
            f2f("input", {"mouse": {"x": float(x), "y": float(y), "buttons": [False, False, False]}}); time.sleep(0.1)
            f2f("input", {"mouse": {"x": float(x), "y": float(y), "buttons": [True, False, False]}}); time.sleep(0.12)
            f2f("input", {"mouse": {"x": float(x), "y": float(y), "buttons": [False, False, False]}}); time.sleep(0.2)
            stage(v, l, "report")
            r["click"] = {"x": x, "y": y, "k": K, "caret": logged_caret(), "want": STARTS[l - 1] + K + 1}
            stage(v, l, "hold")
        gap = (m["caret_x"] - m["text_end"]) if m and m["text_end"] else None
        sgap = (r["sel"]["sel"][1] - r["sel"]["text_end"]) if r.get("sel") and r["sel"]["sel"] and r["sel"]["text_end"] else None
        r["caret_gap"], r["sel_gap"] = gap, sgap
        pen_end = pen_x(v, l, len(LINES[l - 1]))
        r["pen_end"] = pen_end
        r["caret_vs_pen"] = (m["caret_x"] - pen_end) if m else None
        r["sel_vs_pen"] = (r["sel"]["sel"][1] + 1 - pen_end) if r.get("sel") and r["sel"]["sel"] else None
        print("   pen_end=%d caret-pen=%s sel_end-pen=%s click=%s" % (pen_end, r["caret_vs_pen"], r["sel_vs_pen"], r.get("click")), flush=True)
        print("v%d line%d caret_x=%s text_end=%s caret_gap=%s | sel=%s text_end=%s sel_gap=%s" % (
            v, l, m and m["caret_x"], m and m["text_end"], gap, r.get("sel", {}).get("sel"),
            r.get("sel", {}).get("text_end"), sgap), flush=True)
        res.append(r)
json.dump(res, open(os.path.join(VC, "artifacts/olife_caret", out, "measure.json"), "w"), indent=1)
