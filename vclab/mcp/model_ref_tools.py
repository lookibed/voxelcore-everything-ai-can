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
    lines = ["| anim | frames | IoU min | px only one side, max | colour err mean | colour bad px max | worst |",
             "|---|---|---|---|---|---|---|"]
    for an, s in (rep.get("summary") or {}).items():
        lines.append("| %s | %d | %.4f | %d | %.2f | %.1f%% | %s |" % (
            an, s["frames"], s["iou_min"], s["only_px_max"], s["color_mean"], 100 * s["color_bad_share_max"],
            (rep.get("worst") or {}).get(an, s["iou_worst_frame"])))
    return "\n".join(lines)


def _result(out, text, error=False):
    """the run's summary as MCP content: text + the worst frame's diff panel (blender | engine | map)"""
    sp = os.path.join(out, "summary.json")
    content = []
    if os.path.isfile(sp):
        rep = json.load(open(sp, encoding="utf-8"))
        worst = None
        for an, nm in (rep.get("worst") or {}).items():
            r = rep["frames_detail"][nm]
            if worst is None or r["iou"] < worst[1]["iou"]:
                worst = (nm, r)
        exp = rep.get("export") or {}
        msg = ["model_ref: %s" % out, "", _table(rep), "",
               "report: %s" % MR.win(os.path.join(out, "report.html")),
               "sheets: %s" % ", ".join(MR.win(p) for p in (rep.get("sheets") or {}).values()),
               "engine: %s, flags %s" % ((rep.get("engine") or {}).get("hello", {}).get("version"),
                                         json.dumps((rep.get("engine") or {}).get("hello", {}).get("flags"))),
               "panel = Blender | VoxelCore | map (red: only Blender, cyan: only engine, yellow: colour > 24/255)"]
        if exp:
            msg.insert(1, "export: %s (%d bones, %d tris, textures %s)%s" % (
                MR.win(os.path.join(out, "export")), len(exp.get("bones", [])), exp.get("tris", 0),
                [t["file"] for t in exp.get("textures", [])],
                "".join("\n  warning: " + w for w in exp.get("warnings") or [])))
        content.append({"type": "text", "text": text + "\n".join(msg)})
        if worst:
            pp = os.path.join(out, "diff", worst[0] + ".png")
            if os.path.isfile(pp):
                import base64
                content.append({"type": "text", "text": "worst frame %s: IoU %.4f, only B %d / E %d, colour %.2f" % (
                    worst[0], worst[1]["iou"], worst[1]["only_blender"], worst[1]["only_engine"],
                    worst[1]["color_mean"])})
                content.append({"type": "image", "data": base64.b64encode(open(pp, "rb").read()).decode("ascii"),
                                "mimeType": "image/png"})
    else:
        content.append({"type": "text", "text": text})
    res = {"content": content}
    if error:
        res["isError"] = True
    return res


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
            for f in ("summary.json", "progress.log", "run.log"):
                try:
                    os.remove(os.path.join(out, f))
                except OSError:
                    pass
            cmd = [sys.executable, "-m", "vclab.model_ref.model_ref", "--blend", blend, "--out", out]
            for sp in a.get("anims") or []:
                cmd += ["--anim", sp]
            for k, flag in (("name", "--name"), ("rest_frame", "--rest-frame"), ("rest", "--rest"),
                            ("scale", "--scale"), ("every", "--every"), ("ssao", "--ssao"), ("shading", "--shading"),
                            ("root_y", "--root-y"), ("daemon", "--daemon")):
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
        if not last.startswith("done"):
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
        "description": "Покадровое попиксельное сравнение модели: рендер Blender против VoxelCore. Экспорт .blend "
                       "(как vc_model_export), затем аренда F2F vc/vctest_window на своём демоне (по умолчанию "
                       "25802; окно hidden, 854x480, часы virtual — флаги проверяются), только слой сущностей, "
                       "fullbright, без SSAO; Blender повторяет затенение граней движка. Метрики на кадр: IoU "
                       "силуэтов, пиксели только с одной стороны, ошибка цвета; report.html, sheet_<anim>.png, "
                       "diff/. Идёт через heavy в фоне; ждёт wait_s (600) и возвращает таблицу и худший кадр "
                       "картинкой. Не дождался — status=<out> для опроса. Смотри худший кадр глазами.",
        "inputSchema": {"type": "object", "properties": {
            "blend": {"type": "string"}, "anims": {"type": "array", "items": {"type": "string"}},
            "out": {"type": "string"}, "name": {"type": "string"},
            "status": {"type": "string", "description": "каталог уже запущенного прогона: опрос/результат"},
            "every": {"type": "integer", "default": 1}, "ssao": {"type": "integer", "default": 0},
            "shading": {"type": "string", "enum": ["vc", "flat"]},
            "cam": {"type": "object", "description": "{pos:[x,y,z], target:[x,y,z], fov} — оси VC от сущности"},
            "rest_frame": {"type": "integer"}, "rest": {"type": "string", "enum": ["identity", "frame"]},
            "root_y": {"type": "number"}, "scale": {"type": "number"},
            "daemon": {"type": "integer", "description": "демон lab для аренды (свой изолированный, не игровой)"},
            "wait_s": {"type": "number", "default": 600}}},
    })
    if journal is not None:
        journal.extend(no_shot=TOOL_NAMES, slow={n: None for n in TOOL_NAMES})
