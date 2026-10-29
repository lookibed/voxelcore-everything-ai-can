#!/usr/bin/env python3
"""Проверка UX компьютера pc_wasmrt:pc (план «ПК» 07.10) в лаборатории: аренда `wasmrt world` (копия мира
fineltest, сценарий pc_world.lua ставит ПК и сажает игрока), ввод — только F2F `input` (мышь в координатах
окна 1408x902, точки экрана переводит обработчик пака `pc {op:map}`), снимки — F2F `shot` (кадровый буфер).

  python3 tools/scenarios/pc_ux_check.py v031|v032 [--lease NAME] [--keep] [--skip-doom]

Проверяет: рабочий стол с обоями, вход без притягивания камеры (zoom 0), кнопка «залочить мышь» XML-оверлея (камера
к экрану, курсор заперт), перетаскивание ярлыка (позиция в config:pc_wasmrt/desktop.json), ярлык в корзину и обратно,
проводник (export: с подложенными test.png и sample.mp4, двойные клики: PNG — просмотр, MP4 — видео),
Paint (штрихи мышью, цвет, сохранение PNG в export:pc_wasmrt/), кнопка «приблизить» оверлея, «встать» оверлея, Doom на
ПК (fps). С 07.10 (pc_ux2) кнопки «встать/залочиться» и ползунок зума из экрана убраны — они в layouts/pc_overlay.xml
(кнопки в HUD, клик — мышью по прямоугольнику из `pc state`.overlay.rects; подробная проверка — pc_overlay_check.py).
Итог — таблица шагов и путь прогона; код выхода — число провалов.
"""
import json, os, shutil, subprocess, sys, time

VC = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # TODO(переезд): был рабочий каталог движка (content, tools, worlds) — теперь корень репозитория
LAB = os.path.join(VC, "tools/lab/lab")
OWNER = os.environ.get("LAB_OWNER", "pc_ux")
W, H = 1024, 724
FAILS = []
ROWS = []


def lab(*args, timeout=200):
    env = dict(os.environ, LAB_OWNER=OWNER)
    out = subprocess.run([LAB, *args], capture_output=True, text=True, env=env, timeout=timeout).stdout
    i = out.find("{")
    if i < 0:
        return {"raw": out}
    try:
        return json.loads(out[i:])
    except json.JSONDecodeError:
        return {"raw": out}


class Pipe:
    """Постоянный канал к демону (tools/lab/labpipe.py на Windows-Python): CLI `lab` стоит ~0.2 с на вызов, а двойной
    клик должен уложиться в 0.5 с движка (GUI::doubleClickDelay)."""

    def __init__(self):
        win = subprocess.run(["wslpath", "-w", os.path.join(VC, "tools/lab/labpipe.py")], capture_output=True, text=True).stdout.strip()
        env = dict(os.environ, LAB_OWNER=OWNER, WSLENV=(os.environ.get("WSLENV", "") + ":LAB_OWNER").strip(":"))
        self.p = subprocess.Popen(["/mnt/c/Python313/python.exe", "-X", "utf8", "-B", win], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, env=env, cwd="/mnt/c")
        self.n = 0

    def post(self, path, body, timeout=60):
        self.n += 1
        self.p.stdin.write(json.dumps({"id": self.n, "m": "POST", "p": path, "b": body, "t": timeout, "owner": OWNER}) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        r = json.loads(line)
        if "error" in r:
            raise RuntimeError("pipe %s %s -> %s" % (path, body, r["error"]))
        return r["r"]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(5)
        except Exception:
            self.p.kill()


PIPE = None


def f2f(lease, cmd, args=None):
    r = PIPE.post("/f2f/%s" % lease, {"cmd": cmd, "args": args or {}, "timeout": 60})
    if not r.get("ok", False):
        raise RuntimeError("f2f %s %s -> %s" % (cmd, args, r))
    return r["result"]


def pc(lease, op, **kw):
    kw["op"] = op
    return f2f(lease, "pc", kw)


def mouse(lease, x, y, down=False):
    f2f(lease, "input", {"mouse": {"x": int(round(x)), "y": int(round(y)), "buttons": [down, False, False]}})


def win_point(lease, fx, fy):
    m = pc(lease, "map", x=fx, y=fy)
    if m.get("x") is None:
        raise RuntimeError("map %s,%s -> %s" % (fx, fy, m))
    return m["x"], m["y"]


def click(lease, fx, fy, double=False, pause=0.06):
    """Клик по точке фрейма экрана (двойной — два нажатия внутри 0.5 с GUI движка)."""
    x, y = win_point(lease, fx, fy)
    mouse(lease, x, y, False)
    time.sleep(pause)
    for _ in range(2 if double else 1):
        mouse(lease, x, y, True)
        time.sleep(pause)
        mouse(lease, x, y, False)
        time.sleep(pause)


def drag(lease, fx0, fy0, fx1, fy1, steps=6, pause=0.05):
    x, y = win_point(lease, fx0, fy0)
    mouse(lease, x, y, False)
    time.sleep(pause)
    mouse(lease, x, y, True)
    time.sleep(pause)
    for i in range(1, steps + 1):
        fx, fy = fx0 + (fx1 - fx0) * i / steps, fy0 + (fy1 - fy0) * i / steps
        x, y = win_point(lease, fx, fy)
        mouse(lease, x, y, True)
        time.sleep(pause)
    mouse(lease, x, y, False)
    time.sleep(pause)


def overlay_click(lease, name, pause=0.08):
    """Клик по XML-кнопке оверлея (standup | lock | zoom): мышь на центр прямоугольника из `pc state` (tick пака
    переводит активный фрейм на core:main, пока мышь над кнопкой), нажать, отпустить."""
    st = pc(lease, "state")
    r = ((st.get("overlay") or {}).get("rects") or {}).get(name)
    if not r:
        raise RuntimeError("overlay button %s: no rect (overlay_open=%s)" % (name, st.get("overlay_open")))
    x, y = r["x"] + r["w"] / 2, r["y"] + r["h"] / 2
    mouse(lease, x, y, False)
    time.sleep(0.12)
    mouse(lease, x, y, True)
    time.sleep(pause)
    mouse(lease, x, y, False)
    time.sleep(0.3)


def shot(lease, name):
    r = f2f(lease, "shot", {"name": name})
    return r.get("path", "?")


def log_grep(lease, rx, tail=400):
    env = dict(os.environ, LAB_OWNER=OWNER)
    out = subprocess.run([LAB, "logs", lease, "--tail", str(tail), "--grep", rx], capture_output=True, text=True, env=env).stdout
    return [l for l in out.splitlines() if not l.startswith("#")]


def check(name, ok, detail="", shot_path=""):
    ROWS.append((name, "ok" if ok else "FAIL", detail, shot_path))
    if not ok:
        FAILS.append(name)
    print("%-28s %-4s %s %s" % (name, "ok" if ok else "FAIL", detail, ("-> " + shot_path) if shot_path else ""), flush=True)


def icon_center(st, icon):
    p = st["icons"][icon]
    return p["x"] + 75, p["y"] + 46


def main():
    engine = sys.argv[1] if len(sys.argv) > 1 else "v031"
    lease = None
    keep = "--keep" in sys.argv
    skip_doom = "--skip-doom" in sys.argv
    global PIPE
    PIPE = Pipe()
    if "--lease" in sys.argv:
        lease = sys.argv[sys.argv.index("--lease") + 1]
        # чистый старт: настройки стола (config:pc_wasmrt) прошлого прогона убрать и перезапустить экземпляр
        cfg_dir = os.path.join(VC, "artifacts/lab/inst", lease, "config", "pc_wasmrt")
        if os.path.isdir(cfg_dir):
            shutil.rmtree(cfg_dir)
        r = lab("start", lease, "--restart", timeout=300)
        if not r.get("ok", False):
            print("restart failed:", json.dumps(r, ensure_ascii=False)[:1500])
            return 1
    if not lease:
        r = lab("lease", "wasmrt", "world", "--param", "engine=" + engine, "--param", "size=1408x902", "--start", timeout=300)
        if not r.get("ok", False) or not r.get("lease"):
            print("lease failed:", json.dumps(r, ensure_ascii=False)[:2000])
            return 1
        lease = r["lease"]["name"] if isinstance(r["lease"], dict) else r["lease"]
    print("lease", lease, "engine", engine)
    inst = os.path.join(VC, "artifacts/lab/inst", lease)
    export = os.path.join(inst, "export")
    config = os.path.join(inst, "config")
    # тестовые файлы для проводника (export: аренды)
    os.makedirs(export, exist_ok=True)
    shutil.copy(os.path.join(VC, "content/pc_wasmrt/textures/gui/wallpaper.png"), os.path.join(export, "test.png"))
    os.makedirs(os.path.join(inst, "screenshots"), exist_ok=True)
    shutil.copy(os.path.join(VC, "content/pc_wasmrt/icon.png"), os.path.join(inst, "screenshots", "shot_test.png"))
    sample = os.path.join(VC, "content/videoplayer/videos/sample.mp4")
    if os.path.isfile(sample):
        shutil.copy(sample, os.path.join(export, "sample.mp4"))
    try:
        st = pc(lease, "state")
        check("enter: camera stays", st["active"] and st["zoom"] == 0 and st["camera"] == 0 and not st["locked"],
              "zoom=%s camera=%s locked=%s" % (st["zoom"], st["camera"], st["locked"]), shot(lease, "01_desktop_default"))
        # «залочить мышь»: XML-кнопка оверлея (до 07.10 — кнопка на панели задач экрана)
        overlay_click(lease, "lock")
        st = pc(lease, "state")
        check("lock button", st["locked"] and st["zoom"] >= 0.99 and st["mouse_lock"] and st["camera"] != 0,
              "zoom=%s camera=%s mouse_lock=%s" % (st["zoom"], st["camera"], st["mouse_lock"]), shot(lease, "02_locked"))
        # лок мыши: мышь в углу окна (мимо экрана) — курсор прижат к краю экрана, не исчезает
        mouse(lease, 5, 5)
        time.sleep(0.2)
        st = pc(lease, "state")
        cur = st.get("cursor")
        check("mouse lock clamps cursor", bool(cur) and 0 <= cur[0] <= W and 0 <= cur[1] <= H, "cursor=%s" % cur)
        # перетаскивание ярлыка doom
        x0, y0 = icon_center(st, "doom")
        drag(lease, x0, y0, 520, 300)
        time.sleep(0.3)
        st = pc(lease, "state")
        d = [st["icons"]["doom"]["x"], st["icons"]["doom"]["y"]]
        cfg_path = os.path.join(config, "pc_wasmrt", "desktop.json")
        cfg = json.load(open(cfg_path, encoding="utf-8")) if os.path.isfile(cfg_path) else {}
        saved = cfg.get("icons", {}).get("doom")
        check("drag icon", abs(d[0] - (520 - 75)) <= 12 and abs(d[1] - (300 - 46)) <= 12 and saved == d,
              "doom at %s, config %s" % (d, saved), shot(lease, "03_drag"))
        # ярлык quake -> корзина, корзина, восстановить
        x0, y0 = icon_center(st, "quake")
        tx, ty = icon_center(st, "trash")
        drag(lease, x0, y0, tx, ty)
        time.sleep(0.3)
        st = pc(lease, "state")
        check("icon to trash", "quake" in (st["trash"] or []) and not st["icons"]["quake"]["visible"],
              "trash=%s" % st["trash"], shot(lease, "04_icon_trashed"))
        click(lease, tx, ty, double=True)
        time.sleep(0.4)
        st = pc(lease, "state")
        check("trash window", st.get("running") == "trash" and st["window"], "running=%s" % st.get("running"), shot(lease, "05_trash"))
        # «восстановить» первой строки: client_rect + (cw-140+65, 34+13+2)
        cr = st["client_rect"]
        click(lease, cr[0] + cr[2] - 140 + 65, cr[1] + 34 + 13)
        time.sleep(0.4)
        st = pc(lease, "state")
        check("restore icon", "quake" not in (st["trash"] or []) and st["icons"]["quake"]["visible"], "trash=%s" % st["trash"])
        pc(lease, "close")
        # проводник: двойной клик по ярлыку, место export:, PNG, назад, MP4
        x0, y0 = icon_center(st, "explorer")
        click(lease, x0, y0, double=True)
        time.sleep(0.5)
        st = pc(lease, "state")
        check("explorer opens", st.get("running") == "explorer", "running=%s path=%s entries=%s" % (st.get("running"), st.get("fs_path"), st.get("fs_entries")),
              shot(lease, "06_explorer_config"))
        click(lease, cr[0] + 6 + 74, cr[1] + 30 + 30 + 13)  # место 2: export:
        time.sleep(0.5)
        st = pc(lease, "state")
        check("explorer export:", st.get("fs_path") == "export:" and (st.get("fs_entries") or 0) >= 2,
              "path=%s entries=%s" % (st.get("fs_path"), st.get("fs_entries")), shot(lease, "07_explorer_export"))
        # строки проводника: папки, потом файлы, по имени без регистра (как list_dir в pc_os) — ряд i в клиенте
        # pos y = 32 + (i-1)*26, высота 24
        names = os.listdir(export)
        dirs_l = sorted([n for n in names if os.path.isdir(os.path.join(export, n))], key=str.lower)
        files_l = sorted([n for n in names if not os.path.isdir(os.path.join(export, n))], key=str.lower)
        listing = dirs_l + files_l
        png_row = listing.index("test.png") + 1
        mp4_row = listing.index("sample.mp4") + 1
        print("export listing", listing, "png row", png_row, "mp4 row", mp4_row)
        click(lease, cr[0] + 166 + 120, cr[1] + 44 + (png_row - 1) * 26, double=True)
        time.sleep(0.6)
        st = pc(lease, "state")
        check("png viewer", (st.get("fs_viewing") or "").endswith("test.png"), "viewing=%s" % st.get("fs_viewing"), shot(lease, "08_png_view"))
        click(lease, cr[0] + cr[2] - 100 + 45, cr[1] + 3 + 11)  # назад
        time.sleep(0.5)
        click(lease, cr[0] + 166 + 120, cr[1] + 44 + (mp4_row - 1) * 26, double=True)
        time.sleep(3.0)
        vid = log_grep(lease, r"video opened|video sample|explorer open video")
        check("mp4 from explorer", any("video opened" in l for l in vid), (vid[-1][-90:] if vid else "no log"), shot(lease, "09_mp4_play"))
        click(lease, cr[0] + cr[2] - 100 + 45, cr[1] + 2 + 11)  # назад (из видео)
        time.sleep(0.4)
        # файл pc_launch.txt -> корзина: выбрать строку, кнопка «в корзину»
        row = listing.index("pc_launch.txt") + 1
        click(lease, cr[0] + 166 + 120, cr[1] + 44 + (row - 1) * 26)
        time.sleep(0.2)
        click(lease, cr[0] + cr[2] - 106 + 50, cr[1] + 4 + 11)
        time.sleep(0.5)
        st = pc(lease, "state")
        trash_dir = os.path.join(config, "pc_wasmrt", "trash")
        in_trash = os.path.isfile(os.path.join(trash_dir, "pc_launch.txt")) and os.path.isfile(os.path.join(trash_dir, "index.json"))
        check("file to trash", st.get("trash_files") == 1 and in_trash and not os.path.isfile(os.path.join(export, "pc_launch.txt")),
              "trash_files=%s index=%s" % (st.get("trash_files"), in_trash), shot(lease, "09b_file_trashed"))
        # место screenshots (user:screenshots): каталог аренды с shot_test.png
        click(lease, cr[0] + 6 + 74, cr[1] + 30 + 60 + 13)
        time.sleep(0.5)
        st = pc(lease, "state")
        check("explorer screenshots", st.get("fs_path") == "user:screenshots" and (st.get("fs_entries") or 0) >= 1,
              "path=%s entries=%s" % (st.get("fs_path"), st.get("fs_entries")), shot(lease, "09c_screenshots"))
        pc(lease, "close")
        # корзина: восстановить файл
        tx, ty = icon_center(st, "trash")
        click(lease, tx, ty, double=True)
        time.sleep(0.4)
        click(lease, cr[0] + cr[2] - 140 + 65, cr[1] + 10 + 24 + 24 + 10 + 24 + 2 + 11)  # «восстановить» первого файла
        time.sleep(0.5)
        st = pc(lease, "state")
        check("restore file", st.get("trash_files") == 0 and os.path.isfile(os.path.join(export, "pc_launch.txt")),
              "trash_files=%s" % st.get("trash_files"), shot(lease, "09d_trash_restore_file"))
        pc(lease, "close")
        # Paint
        x0, y0 = icon_center(st, "paint")
        click(lease, x0, y0, double=True)
        time.sleep(0.5)
        st = pc(lease, "state")
        check("paint opens", st.get("running") == "paint", "running=%s" % st.get("running"))
        px, py = cr[0] + 8, cr[1] + 44  # холст 800x560
        drag(lease, px + 60, py + 60, px + 400, py + 300, steps=10)
        click(lease, cr[0] + 8 + 3 * 28 + 12, cr[1] + 8 + 12)  # цвет 4 (красный)
        drag(lease, px + 100, py + 400, px + 700, py + 120, steps=10)
        click(lease, cr[0] + 360 + 2 * 32 + 14, cr[1] + 8 + 12)  # размер 12
        drag(lease, px + 500, py + 480, px + 760, py + 500, steps=6)
        time.sleep(0.3)
        click(lease, cr[0] + 652 + 55, cr[1] + 9 + 11)  # сохранить
        time.sleep(0.6)
        st = pc(lease, "state")
        saved = st.get("last_saved") or ""
        saved_file = os.path.join(export, "pc_wasmrt", os.path.basename(saved)) if saved else ""
        size = os.path.getsize(saved_file) if saved_file and os.path.isfile(saved_file) else 0
        check("paint draws+saves", st.get("paint_strokes", 0) >= 3 and size > 1000,
              "strokes=%s saved=%s (%d bytes)" % (st.get("paint_strokes"), saved, size), shot(lease, "10_paint"))
        pc(lease, "close")
        # кнопка «приблизить» оверлея (до 07.10 — ползунок зума у края экрана): зум 0 -> у экрана, без лока мыши
        pc(lease, "lock", on=False)
        time.sleep(0.2)
        overlay_click(lease, "zoom")
        st = pc(lease, "state")
        check("zoom toggle button", (st["zoom"] or 0) >= 0.99 and st["camera"] != 0 and not st["mouse_lock"],
              "zoom=%.2f camera=%s mouse_lock=%s" % (st["zoom"], st["camera"], st["mouse_lock"]), shot(lease, "11_zoom_in"))
        # «встать» — кнопка оверлея
        overlay_click(lease, "standup")
        st = pc(lease, "state")
        check("stand up button", not st["active"] and st["camera"] == 0, "active=%s camera=%s" % (st["active"], st["camera"]),
              shot(lease, "12_standup"))
        # без лока курсор мимо экрана исчезает (стрелки на экране нет)
        pc(lease, "enter")
        mouse(lease, 5, 5)
        time.sleep(0.2)
        st = pc(lease, "state")
        check("no lock: cursor leaves", st["active"] and not st["mouse_lock"] and st.get("cursor") is None, "cursor=%s" % st.get("cursor"))
        # меню «пуск» и «Настройки»: включить притягивание камеры при входе -> следующий вход с зумом 1
        pc(lease, "lock", on=True)
        time.sleep(0.2)
        click(lease, 52, H - 15)
        time.sleep(0.3)
        st = pc(lease, "state")
        check("start menu", st.get("startmenu") is True, "", shot(lease, "14_startmenu"))
        pc(lease, "launch", id="settings")
        time.sleep(0.3)
        click(lease, cr[0] + 12 + 200, cr[1] + 36 + 14)  # строка «притягивать камеру»
        time.sleep(0.4)
        st = pc(lease, "state")
        check("settings: attach on", st.get("options", {}).get("attach_camera") is True, "options=%s" % st.get("options"),
              shot(lease, "15_settings"))
        pc(lease, "close")
        pc(lease, "leave")
        pc(lease, "enter")
        time.sleep(0.3)
        st = pc(lease, "state")
        # зум при входе — сохранённый ползунком (options.zoom), камера — pc_wasmrt:sleeping (индекс != 0)
        want = st.get("options", {}).get("zoom") or 1
        check("enter with attach", st["active"] and abs(st["zoom"] - want) < 0.01 and st["camera"] != 0,
              "zoom=%.2f (saved %.2f) camera=%s" % (st["zoom"], want, st["camera"]), shot(lease, "16_enter_attached"))
        pc(lease, "leave")
        if not skip_doom:
            pc(lease, "enter")
            pc(lease, "lock", on=True)
            time.sleep(0.3)
            pc(lease, "launch", id="doom")
            time.sleep(20)
            fps = [l for l in log_grep(lease, r"doom:wasm.json.*fps") if "fps" in l]
            scale = log_grep(lease, r"\[wasmrt\].*(canvas|scale|x3)")
            check("doom on pc", len(fps) >= 1, (fps[-1][-80:] if fps else "no fps lines") + (" | " + scale[-1][-70:] if scale else ""),
                  shot(lease, "13_doom"))
            pc(lease, "close")
        sysload = lab("sysload")
        print("sysload busy=%s reasons=%s" % (sysload.get("busy"), sysload.get("reasons")))
    finally:
        runs = lab("ps")
        run = ""
        for l in (runs.get("leases") or []) if isinstance(runs, dict) else []:
            if l.get("name") == lease:
                run = l.get("run", "")
        if not keep:
            lab("release", lease)
        PIPE.close()
    print("\n| шаг | результат | детали | кадр |\n|---|---|---|---|")
    for name, res, detail, sp in ROWS:
        print("| %s | %s | %s | %s |" % (name, res, detail.replace("|", "/"), os.path.basename(sp) if sp else ""))
    print("run:", run, "\nfailed:", len(FAILS), FAILS)
    return len(FAILS)


if __name__ == "__main__":
    sys.exit(main())
