#!/usr/bin/env python3
"""Прогон функций Eaglercraft (пак eaglercraft на wasmrt) без ручного управления.

Команды игре идут через export:eagler_cmd.txt (их читает eaglercraft:eag_host, выполняет
VcDebug.java: dump / click <текст|#id> / clickxy / key <код> [мс] / type <текст> / wait <кадры>),
состояние — из строк [eagdbg] в latest.log, картинки — скриншоты окна.

    python3 tools/scenarios/eagler_drive.py            # весь план, отчёт в artifacts/eagler_report.txt
    python3 tools/scenarios/eagler_drive.py options    # только шаги с этим именем (подстрока)
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "mcp"))
import voxelcore_mcp as vc  # noqa: E402

ROOT = vc.VC_ROOT
CMD_FILE = os.path.join(ROOT, "export", "eagler_cmd.txt")
MANIFEST_FILE = os.path.join(ROOT, "export", "wasmrt_manifest.txt")
REPORT = os.path.join(ROOT, "artifacts", "eagler_report.txt")

_log_pos = 0


def log_mark():
    """Запоминает конец лога: следующие expect ищут только новые строки."""
    global _log_pos
    _log_pos = len(vc.read_log())


def new_lines():
    return vc.read_log()[_log_pos:].splitlines()


def expect(pattern, timeout=30):
    regex = re.compile(pattern)
    deadline = time.time() + timeout
    while time.time() < deadline:
        for line in new_lines():
            if regex.search(line):
                return line
        time.sleep(0.3)
    return None


def send(*lines):
    """Добавляет команды в очередь (файл забирается хостом раз в 0.5 с)."""
    with open(CMD_FILE, "a", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


def screen():
    """Текущий экран игры по последней строке [eagdbg] screen."""
    found = None
    for line in vc.read_log().splitlines():
        m = re.search(r"\[eagdbg\] screen (\S+)", line)
        if m:
            found = m.group(1)
    return found


def dump():
    log_mark()
    send("dump")
    if not expect(r"\[eagdbg\] dump", 20):
        return None
    time.sleep(0.5)
    buttons = []
    for line in new_lines():
        m = re.search(r'\[eagdbg\] button #(\d+) "(.*)" at (\d+),(\d+)(.*)', line)
        if m:
            buttons.append((int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5).strip()))
    return buttons


def goto_screen(name, *commands, timeout=40):
    log_mark()
    send(*commands)
    return expect(r"\[eagdbg\] screen " + re.escape(name), timeout)


def shot(name):
    path, _ = vc.take_screenshot("eagler_" + name)
    return path


LAUNCHER = os.environ.get("SPIDER_ROOT", "Spider") + "/tests/manual/real-world-eaglercraft/native_server/launcher.js"


def ensure_server():
    """Встроенный сервер (оригинальный classes_server.js в Node) — launcher.js на :25599."""
    import socket
    import subprocess
    try:
        socket.create_connection(("127.0.0.1", 25599), timeout=1).close()
        return
    except OSError:
        pass
    log = open(os.path.join(ROOT, "artifacts", "eagler_launcher.log"), "a")
    subprocess.Popen(["node", LAUNCHER], stdout=log, stderr=log, start_new_session=True)
    time.sleep(1)


def start():
    ensure_server()
    with open(MANIFEST_FILE, "w", encoding="utf-8") as f:
        f.write("eaglercraft:wasm.json\n")
    if os.path.exists(CMD_FILE):
        os.remove(CMD_FILE)
    log_mark()
    vc.tool_vc_start({"script": "user:tools/scenarios/wasmrt_page.lua", "restart": True})
    global _log_pos
    _log_pos = 0
    return expect(r"\[eagdbg\] screen (GuiScreenEditProfile|GuiMainMenu)", 240)


# ------------------------------------------------------------------ план

def step_boot(r):
    line = start()
    r.check("boot: первый экран", line is not None, line)
    r.note("boot", shot("boot"))


def step_profile(r):
    if screen() == "GuiScreenEditProfile":
        b = dump()
        r.check("profile: кнопки экрана профиля", bool(b), b)
        line = goto_screen("GuiMainMenu", "click Done")
        r.check("profile: Done -> главное меню", line is not None, line)
    r.check("main menu: без окна changelog", screen() == "GuiMainMenu", screen())
    time.sleep(1)
    r.note("main menu", shot("main_menu"))
    r.buttons_main = dump()
    r.check("main menu: кнопки", bool(r.buttons_main), r.buttons_main)


def step_options(r):
    line = goto_screen("GuiOptions", "click Options...")
    r.check("options: открыть", line is not None, line)
    time.sleep(1)
    r.note("options", shot("options"))
    b = dump()
    r.check("options: кнопки", bool(b), b)
    for sub, screen_name in (("Video Settings...", "GuiVideoSettings"), ("Controls...", "GuiControls")):
        line = goto_screen(screen_name, "click " + sub)
        r.check("options: " + sub, line is not None, line)
        time.sleep(1)
        r.note(sub, shot(screen_name))
        line = goto_screen("GuiOptions", "click Done")
        r.check("options: назад из " + sub, line is not None, line)
    line = goto_screen("GuiMainMenu", "click Done")
    r.check("options: назад в меню", line is not None, line)


def step_singleplayer(r):
    line = goto_screen("GuiSelectWorld", "click Singleplayer", timeout=30)
    r.check("singleplayer: список миров", line is not None, line)
    time.sleep(2)
    r.note("singleplayer", shot("singleplayer"))
    r.check("singleplayer: кнопки", True, dump())
    line = goto_screen("GuiScreenCreateWorldSelection", "click Create New World", timeout=30)
    r.check("singleplayer: выбор способа создания", line is not None, line)
    time.sleep(1)
    r.note("create selection", shot("create_selection"))
    r.check("create selection: кнопки", True, dump())
    line = goto_screen("GuiCreateWorld", "click Create New World", timeout=30)
    r.check("singleplayer: экран создания мира", line is not None, line)
    time.sleep(1)
    r.note("create world", shot("create_world"))
    r.check("create world: кнопки", True, dump())
    log_mark()
    send("click Create New World")
    line = expect(r"\[eagdbg\] screen ingame", 300)
    r.check("singleplayer: вход в мир", line is not None, line)
    time.sleep(5)
    r.note("in world", shot("ingame"))
    r.check("in world: состояние", True, dump())


def step_multiplayer(r):
    line = goto_screen("", "click Multiplayer", timeout=20)
    r.check("multiplayer: открыть", line is not None, line)
    time.sleep(2)
    r.note("multiplayer", shot("multiplayer"))
    r.check("multiplayer: экран", True, (screen(), dump()))
    goto_screen("GuiMainMenu", "key 1", timeout=20)


def step_texture_packs(r):
    line = goto_screen("", "click Texture Packs", timeout=20)
    r.check("texture packs: открыть", line is not None, line)
    time.sleep(2)
    r.note("texture packs", shot("texture_packs"))
    r.check("texture packs: экран", True, (screen(), dump()))
    goto_screen("GuiMainMenu", "key 1", timeout=20)


def step_fps(r):
    log_mark()
    line = expect(r"eaglercraft:wasm.json: [0-9.]+ fps", 15)
    r.check("fps в меню", line is not None, line)


PLAN = [
    ("boot", step_boot),
    ("profile", step_profile),
    ("fps", step_fps),
    ("options", step_options),
    ("texture", step_texture_packs),
    ("multiplayer", step_multiplayer),
    ("singleplayer", step_singleplayer),
]


class Report:
    def __init__(self):
        self.lines = []
        self.failed = 0
        self.buttons_main = None

    def check(self, what, ok, detail=None):
        if not ok:
            self.failed += 1
        line = f"{'OK  ' if ok else 'FAIL'} {what}" + (f"  | {detail}" if detail is not None else "")
        print(line, flush=True)
        self.lines.append(line)

    def note(self, what, path):
        line = f"     {what}: {path}"
        print(line, flush=True)
        self.lines.append(line)


def main():
    only = sys.argv[1:]
    r = Report()
    for name, fn in PLAN:
        if only and name != "boot" and not any(o in name for o in only):
            continue
        try:
            fn(r)
        except Exception as e:  # отчёт важнее одного шага
            r.check(name + ": исключение", False, repr(e))
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("\n".join(r.lines) + "\n")
    print(f"-- failed {r.failed}, report {REPORT}")


if __name__ == "__main__":
    main()
