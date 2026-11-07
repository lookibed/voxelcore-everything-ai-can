"""MCP tools of vclab/model_ref (registered in voxelcore_mcp.TOOLS):
  vc_model_export — any .blend -> VoxelCore files (VCM with named bones, PNG textures, VCA per animation, export.json)
  vc_model_ref    — export + frame-by-frame pixel compare Blender vs the engine (F2F lease, hidden, virtual clock):
                    runs detached under `heavy`, waits up to wait_s, returns the table, the worst frame's panel as an
                    image and the report paths; status=<out dir> polls a run that is still going.
"""
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if REPO not in sys.path:
    sys.path.insert(0, REPO)
from vclab.model_ref import model_ref as MR  # noqa: E402

TOOL_NAMES = ("vc_model_export", "vc_model_ref")


def _unix(p):
    if p and len(p) > 2 and p[1] == ":":
        return MR.unix(p)
    return os.path.abspath(p) if p else p


def _table(rep):
    lines = ["| anim@view | frames | IoU min | px only one side, max | colour err mean | colour bad px max | failed |",
             "|---|---|---|---|---|---|---|"]
    for k, s in (rep.get("summary") or {}).items():
        lines.append("| %s | %d | %.4f | %d | %.2f | %.1f%% | %d |" % (
            k, s["frames"], s["iou_min"], s["only_px_max"], s["color_mean"], 100 * s["color_bad_share_max"],
            s.get("fail_frames", 0)))
    return "\n".join(lines)


def _result(out, text):
    """the run as MCP content: the verdict, the table, failed frames, the baseline, the worst frame's panel"""
    import base64
    sp = os.path.join(out, "summary.json")
    if not os.path.isfile(sp):
        return {"content": [{"type": "text", "text": text}]}
    rep = json.load(open(sp, encoding="utf-8"))
    exp = rep.get("export") or {}
    hello = (rep.get("engine") or {}).get("hello") or {}
    msg = [rep.get("verdict_line", ""), "", _table(rep)]
    if rep.get("fails"):
        msg += ["", "failed frames (worst first):"] + ["- " + f for f in rep["fails"][:10]]
        if len(rep["fails"]) > 10:
            msg.append("- ... %d more in report.html" % (len(rep["fails"]) - 10))
    if rep.get("baseline"):
        msg += ["", "vs previous run %s:" % rep["baseline"]["from"]] + [
            "- %s: IoU min %.4f -> %.4f, colour %.2f -> %.2f, failed %d -> %d%s" % (
                d["key"], d["iou_min"][0], d["iou_min"][1], d["color_mean"][0], d["color_mean"][1], d["fails"][0],
                d["fails"][1], " WORSE" if d["worse"] else "") for d in rep["baseline"]["delta"]]
    if exp:
        msg += ["", "export: %s (%d bones, %d tris, textures %s)%s" % (
            MR.win(os.path.join(out, "export")), len(exp.get("bones", [])), exp.get("tris", 0),
            [t["file"] for t in exp.get("textures", [])],
            "".join("\n  warning: " + w for w in exp.get("warnings") or []))]
    th = rep.get("thresholds") or {}
    msg += ["report: %s" % MR.win(os.path.join(out, "report.html")),
            "views %s; thresholds IoU >= %s, bad colour <= %s, colour mean <= %s; engine %s, flags %s" % (
                ", ".join(rep.get("views", [])), th.get("min_iou"), th.get("max_bad_color"), th.get("max_color_mean"),
                hello.get("version"), json.dumps(hello.get("flags"))),
            "panel = Blender | VoxelCore | map (red: only Blender, cyan: only engine, yellow: colour > 24/255)"]
    content = [{"type": "text", "text": text + "\n".join(msg)}]
    det = rep.get("frames_detail") or {}
    if det:
        nm = min(det, key=lambda n: (det[n]["iou"], -det[n]["color_bad_share"]))
        pp = os.path.join(out, "diff", nm + ".png")
        if os.path.isfile(pp):
            r = det[nm]
            content.append({"type": "text", "text": "worst frame %s: IoU %.4f, only B %d / E %d, colour %.2f%s" % (
                nm, r["iou"], r["only_blender"], r["only_engine"], r["color_mean"],
                (", bones " + ", ".join("%s %d%%" % (b, 100 * w) for b, w in r["bones"])) if r.get("bones") else "")})
            content.append({"type": "image", "data": base64.b64encode(open(pp, "rb").read()).decode("ascii"),
                            "mimeType": "image/png"})
    return {"content": content}


def _progress(out):
    try:
        return open(os.path.join(out, "progress.log"), encoding="utf-8").read().strip().splitlines()
    except OSError:
        return []


def register(TOOLS, text, journal=None):
    def t_export(a):
        blend = _unix(a["blend"])
        name = a.get("name") or os.path.splitext(os.path.basename(blend))[0]
        out = _unix(a.get("out")) or os.path.join(MR.default_out(name), "export")
        m = MR.export(blend, out, a.get("name"), a.get("anims"), a.get("rest_frame"), a.get("rest"),
                      a.get("root_y", -0.5), a.get("scale", 1.0), a.get("poses", False))
        lines = ["export: %s" % MR.win(out), "vcm: %s; textures: %s" % (
            m["vcm"], ", ".join("%s=%s" % (t["slot"], t["file"]) for t in m["textures"])),
            "bones (%d): %s" % (len(m["bones"]), ", ".join(
                "%s<%s" % (b["name"], b["parent"]) if b["parent"] else b["name"] for b in m["bones"])),
            "tris: %d; anims: %s" % (m["tris"], ", ".join(
                "%s (%s, frames %d-%d @%g fps)" % (n, an["file"], an["start"], an["end"], an["fps"])
                for n, an in m["anims"].items()) or "none")]
        lines += ["warning: " + w for w in m.get("warnings") or []]
        return text("\n".join(lines))

    def t_ref(a):
        if a.get("status"):
            out = _unix(a["status"])
        else:
            blend = _unix(a["blend"])
            name = a.get("name") or os.path.splitext(os.path.basename(blend))[0]
            out = _unix(a.get("out")) or MR.default_out(name)
            MR.check_win_path(out, "out")
            os.makedirs(out, exist_ok=True)
            for f in ("progress.log", "run.log"):            # summary.json stays: the baseline of this run
                try:
                    os.remove(os.path.join(out, f))
                except OSError:
                    pass
            cmd = [sys.executable, "-m", "vclab.model_ref.model_ref", "--blend", blend, "--out", out]
            for sp in a.get("anims") or []:
                cmd += ["--anim", sp]
            if a.get("views"):
                a = dict(a, views=",".join(a["views"]) if isinstance(a["views"], list) else a["views"])
            for k, flag in (("name", "--name"), ("rest_frame", "--rest-frame"), ("rest", "--rest"),
                            ("scale", "--scale"), ("every", "--every"), ("ssao", "--ssao"), ("shading", "--shading"),
                            ("root_y", "--root-y"), ("daemon", "--daemon"), ("views", "--views"),
                            ("min_iou", "--min-iou"), ("max_bad_color", "--max-bad-color"),
                            ("max_color_mean", "--max-color-mean"), ("baseline", "--baseline")):
                if a.get(k) is not None:
                    cmd += [flag, str(a[k])]
            if a.get("cam"):
                cmd += ["--cam", json.dumps(a["cam"])]
            heavy = ["heavy", "--label", "model_ref-" + name, "--"]
            try:
                subprocess.run(["heavy", "status"], capture_output=True, timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                heavy = []
            log = open(os.path.join(out, "run.log"), "w")
            subprocess.Popen(heavy + cmd, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.time() + float(a.get("wait_s", 600))
        while time.time() < deadline:
            prog = _progress(out)
            if prog and (prog[-1][9:].startswith("done") or prog[-1][9:].startswith("error")):
                break
            time.sleep(2)
        prog = _progress(out)
        last = prog[-1][9:] if prog else ""
        if last.startswith("error"):
            tail = ""
            try:
                tail = open(os.path.join(out, "run.log"), encoding="utf-8", errors="replace").read()[-1500:]
            except OSError:
                pass
            return text("model_ref failed (%s):\n%s\n\n%s" % (out, "\n".join(prog[-8:]), tail), error=True)
        if not last.startswith("done") or not os.path.isfile(os.path.join(out, "summary.json")):
            return text("model_ref still running (%s); last: %s\npoll: vc_model_ref {\"status\": \"%s\"}" % (
                out, "\n".join(prog[-4:]) or "(queued in heavy?)", out))
        return _result(out, "")

    TOOLS["vc_model_export"] = (t_export, {
        "description": "Экспорт любой сцены Blender (.blend) в форматы VoxelCore: VCM (именованные @bone, @tri с UV), "
                       "PNG-текстуры ($0, $1...: картинка материала или сплошной цвет), VCA на каждую анимацию "
                       "(каждый кадр, rotation XYZ), export.json. Риги: иерархия объектов (анимированные объекты = "
                       "кости) и Armature (кости; скиннинг — по доминирующей группе на треугольник, предупреждение "
                       "при смешанных весах). anims: ['walk=0-24', 'run=@RunAction']; пусто — маркеры таймлайна "
                       "(маркер '_'/'end' закрывает отрезок) или весь диапазон сцены. Пути WSL или Windows; out по "
                       "умолчанию <work_root>/model_ref/<имя>/export (диск Windows: Blender — программа Windows).",
        "inputSchema": {"type": "object", "properties": {
            "blend": {"type": "string"}, "out": {"type": "string"}, "name": {"type": "string"},
            "anims": {"type": "array", "items": {"type": "string"}},
            "rest_frame": {"type": "integer", "description": "кадр позы покоя (по умолчанию начало сцены)"},
            "rest": {"type": "string", "enum": ["identity", "frame"],
                     "description": "identity: у анимированных объектов поворот в покое сброшен (по умолчанию)"},
            "root_y": {"type": "number", "default": -0.5}, "scale": {"type": "number", "default": 1.0},
            "poses": {"type": "boolean", "description": "ещё <name>_poses.json: позы костей по кадрам"}},
            "required": ["blend"]},
    })
    TOOLS["vc_model_ref"] = (t_ref, {
        "description": "Покадровое попиксельное сравнение модели: рендер Blender против VoxelCore, с вердиктом. "
                       "Экспорт .blend (как vc_model_export), затем аренда F2F vc/vctest_window на своём демоне "
                       "(по умолчанию 25802; hidden, 854x480, virtual — флаги проверяются), только слой сущностей, "
                       "fullbright, без SSAO; Blender повторяет затенение граней движка. Камеры — по габаритам модели "
                       "за все кадры, ракурсы views (front34, back34 по умолчанию; ещё front back left right top). "
                       "Кадр проваливается при IoU < min_iou (0.999), плохом цвете > max_bad_color (1%) или средней "
                       "ошибке цвета > max_color_mean (3/255); у провала — кости, где расхождение. Сравнение с прошлым "
                       "прогоном в том же out (или baseline) — WORSE. Идёт через heavy в фоне; ждёт wait_s (600), "
                       "возвращает вердикт, таблицу, провалы и худший кадр картинкой; не дождался — status=<out>. "
                       "Смотри худший кадр глазами.",
        "inputSchema": {"type": "object", "properties": {
            "blend": {"type": "string"}, "anims": {"type": "array", "items": {"type": "string"}},
            "out": {"type": "string"}, "name": {"type": "string"},
            "status": {"type": "string", "description": "каталог уже запущенного прогона: опрос/результат"},
            "every": {"type": "integer", "default": 1}, "ssao": {"type": "integer", "default": 0},
            "views": {"type": "array", "items": {"type": "string",
                                                 "enum": ["front34", "back34", "front", "back", "left", "right", "top"]}},
            "min_iou": {"type": "number", "default": 0.999}, "max_bad_color": {"type": "number", "default": 0.01},
            "max_color_mean": {"type": "number", "default": 3.0},
            "baseline": {"type": "string", "description": "summary.json прошлого прогона (по умолчанию — в out)"},
            "shading": {"type": "string", "enum": ["vc", "flat"]},
            "cam": {"type": "object", "description": "одна своя камера вместо views: {pos, target, fov}, оси VC"},
            "rest_frame": {"type": "integer"}, "rest": {"type": "string", "enum": ["identity", "frame"]},
            "root_y": {"type": "number"}, "scale": {"type": "number"},
            "daemon": {"type": "integer", "description": "демон lab для аренды (свой изолированный, не игровой)"},
            "wait_s": {"type": "number", "default": 600}}},
    })
    if journal is not None:
        journal.extend(no_shot=TOOL_NAMES, slow={n: None for n in TOOL_NAMES})
