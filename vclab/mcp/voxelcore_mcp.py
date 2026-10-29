#!/usr/bin/env python3
"""MCP-сервер (stdio, без зависимостей) для управления VoxelCore из WSL.

Этап 3а лаборатории (docs/RULES.md «Принуждение»): vc_start больше не запускает стоковый VoxelCore.exe —
это аренда `vc.dev` демона lab (тестовая сборка VoxelCoreF2F.exe, `--f2f <порт> --f2f-clock realtime`, ввод ОС
изолирован, окно без фокуса; `lab ps` её видит). Стоковый exe — только play=true + reason (= `lab play vc
--final-check`, главная сессия). vc_keys/vc_click (ввод ОС) такие экземпляры не видят: ввод — vc_input (F2F input).

Инструменты: vc_start, vc_stop, vc_status, vc_screenshot, vc_input, vc_keys, vc_click, vc_log, vc_wait_log,
vc_shader_cells, vc_pixels (отладка шейдеров через пиксели окна, см. pixel_debug.py);
journal_*, scenario_* (journal.py: журнал вызовов и сценарии); инструменты проектов — projects/<p>/mcp_tools.py
(register(TOOLS, vc_module, text) — как прежние инструменты игр рабочего каталога; см. projects/_template/mcp_tools.py).

Все вызовы Windows (процессы, скриншоты, клики, клавиши) идут через один постоянный процесс
PowerShell (PSWorker): запуск powershell.exe стоит ~0.9 с, вызов в живом процессе — единицы мс.

Окружение:
  VC_ROOT  — каталог запусков vc_start в WSL (--dir: latest.log, settings, content\); по умолчанию <work_root>/vc_dev.
  LAB_MCP_PROJECTS — через «:» имена проектов, чьи mcp_tools.py грузить (по умолчанию — все, у кого он есть).
"""

import base64
import json
import os
import re
import select
import subprocess
import sys
import time

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SERVER_DIR))
if REPO not in sys.path:
    sys.path.insert(0, REPO)
from vclab import machine as _machine  # noqa: E402
from vclab.config import win_to_wsl as _wsl_path  # noqa: E402

_M = _machine.load()
WORK_ROOT = _wsl_path(_M.get("work_root") or "") or os.path.join(REPO, "work")
# каталог vc_start (--dir аренды vc.dev): <work_root>/vc_dev — latest.log, settings, autorun_app_script.txt, content\
VC_ROOT = os.environ.get("VC_ROOT") or os.path.join(WORK_ROOT, "vc_dev")
if VC_ROOT.startswith(WORK_ROOT) and not os.path.isdir(VC_ROOT):
    os.makedirs(VC_ROOT, exist_ok=True)
POWERSHELL = _wsl_path(_M.get("powershell") or r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe")
PS_DIR = os.path.join(SERVER_DIR, "ps")
EXE_NAME = "VoxelCore.exe"
LOG_PATH = os.path.join(VC_ROOT, "latest.log")
# project_client.lua читает этот файл, чтобы узнать, какой сценарий запустить
AUTORUN_FILE = os.path.join(VC_ROOT, "autorun_app_script.txt")
SCREENS_DIR = os.path.join(WORK_ROOT, "mcp", "screens")

PROTOCOL_VERSION = "2024-11-05"

state = {"pid": None}
DEV = None          # vc_lab.Dev: аренда vc_start в демоне lab (создаётся при первом вызове)


def dev():
    global DEV
    if DEV is None:
        from vclab.mcp import vc_lab
        DEV = vc_lab.Dev(VC_ROOT, to_windows_path)
    return DEV


_winpaths = {}


def to_windows_path(path):
    if path not in _winpaths:
        if len(_winpaths) > 256:
            _winpaths.clear()
        _winpaths[path] = subprocess.check_output(["wslpath", "-w", path], text=True).strip()
    return _winpaths[path]


def powershell_oneshot(script, timeout=60):
    result = subprocess.run(
        [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
        capture_output=True, timeout=timeout,
        cwd=VC_ROOT,  # из UNC-каталога WSL powershell ругается на текущую папку
    )
    out = result.stdout.decode("utf-8", "replace").strip()
    err = result.stderr.decode("utf-8", "replace").strip()
    if result.returncode != 0:
        raise RuntimeError(err or out or f"powershell exit code {result.returncode}")
    return out


class PSWorker:
    """Постоянный powershell.exe: строка stdin = base64(UTF-8 кода), ответ — '@@VCPS OK|ERR base64'.
    Типы Add-Type компилируются один раз за жизнь процесса (повторный Add-Type того же кода — no-op)."""

    BOOT = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($line -eq $null) { break }
  $code = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
  $status = "OK"
  try { $out = (& ([ScriptBlock]::Create($code)) 2>&1 | Out-String) } catch { $status = "ERR"; $out = $_.Exception.Message }
  $b = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$out))
  [Console]::Out.WriteLine("@@VCPS " + $status + " " + $b)
  [Console]::Out.Flush()
}
'''

    def __init__(self):
        self.proc = None
        self.buf = b""

    def start(self):
        enc = base64.b64encode(self.BOOT.encode("utf-16-le")).decode("ascii")
        self.proc = subprocess.Popen(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=VC_ROOT)
        self.buf = b""

    def stop(self):
        if self.proc:
            try:
                self.proc.kill()
            except OSError:
                pass
        self.proc = None

    def call(self, script, timeout=60):
        if self.proc is None or self.proc.poll() is not None:
            self.start()
        line = base64.b64encode(script.encode("utf-8")) + b"\n"
        try:
            self.proc.stdin.write(line)
            self.proc.stdin.flush()
        except OSError:
            self.stop()
            raise
        fd = self.proc.stdout.fileno()
        deadline = time.time() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.time()
            if left <= 0:
                self.stop()  # процесс занят зависшим вызовом — следующий вызов поднимет новый
                raise TimeoutError(f"powershell не ответил за {timeout:.0f} с")
            ready, _, _ = select.select([fd], [], [], min(left, 1.0))
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    self.stop()
                    raise RuntimeError("powershell-воркер завершился")
                self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        parts = raw.decode("ascii", "replace").strip().split(" ")
        if len(parts) < 2 or parts[0] != "@@VCPS":
            raise RuntimeError("неожиданный ответ powershell: " + raw[:200].decode("utf-8", "replace"))
        out = base64.b64decode(parts[2]).decode("utf-8", "replace").strip() if len(parts) > 2 else ""
        if parts[1] != "OK":
            raise RuntimeError(out or "powershell error")
        return out


PS = PSWorker()


def powershell(script, timeout=60):
    """Выполнить код PowerShell в постоянном воркере (без 'exit' в коде!); при сбое воркера — отдельным процессом."""
    try:
        return PS.call(script, timeout)
    except (OSError, ValueError) as exc:  # воркер не поднялся / сломан канал
        PS.stop()
        sys.stderr.write(f"psworker: {exc}; fallback\n")
        return powershell_oneshot(script, timeout)


_clock = {"skew": 0.0, "at": 0.0}


def windows_now():
    """Текущее время по часам Windows (epoch). Метки latest.log ставит движок по часам Windows, а часы
    WSL2 уплывают (замечено +8 с) — возраст строк лога считать только от этого времени."""
    now = time.time()
    if now - _clock["at"] > 60:
        try:
            t0 = time.time()
            ms = int(powershell("[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()", timeout=10))
            t1 = time.time()
            _clock["skew"], _clock["at"] = (t0 + t1) / 2 - ms / 1000.0, t1
        except Exception:
            _clock["at"] = now
    return now - _clock["skew"]


def running_pids():
    """pid экземпляра vc_start этого владельца (аренда демона lab). Чужие процессы движка не трогаются и своими не
    считаются — они видны в `lab ps` как foreign."""
    pid = current_pid()
    return [pid] if pid else []


def current_pid():
    try:
        state["pid"] = dev().pid()
    except Exception as exc:
        sys.stderr.write("vc: lab unavailable: %s\n" % exc)
        state["pid"] = None
    return state["pid"]


def log_path():
    try:
        return dev().log_path
    except Exception:
        return LOG_PATH


def read_log():
    try:
        with open(log_path(), "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def wait_log(pattern, timeout, since_mtime=None):
    regex = re.compile(pattern)
    deadline = time.time() + timeout
    path = log_path()
    while time.time() < deadline:
        fresh = since_mtime is None or (
            os.path.exists(path) and os.path.getmtime(path) > since_mtime
        )
        if fresh:
            for line in read_log().splitlines():
                if regex.search(line):
                    return line
        time.sleep(0.5)
    return None


# ---------------------------------------------------------------- tools

def tool_vc_start(args):
    """Аренда vc.dev (тестовая сборка, realtime, ввод изолирован) или, с play=true + reason, финальная проверка на
    стоковом exe (lab play vc --final-check). Ничего вне демона lab не запускает."""
    restart = bool(args.get("restart", False))
    play = bool(args.get("play", False))
    d = dev()
    if play and not (args.get("reason") or "").strip():
        return text("play=true (стоковый VoxelCore.exe) — только разовая финальная проверка главной сессии: нужен "
                    "reason (зачем). Игра пользователя — его `lab play <project> --user`.", error=True)
    if play and d.lab.owner not in ("claude", "user"):
        return text("play=true: владелец %s — субагент; стоковый рантайм запускают только пользователь (lab play "
                    "--user) и главная сессия (claude, --final-check)" % d.lab.owner, error=True)
    pid = current_pid()
    if pid:
        if not restart:
            return text(f"экземпляр vc_start уже запущен (аренда {d.lease}, pid {pid}). Передай restart=true.")
        tool_vc_stop({})
    extra = list(args.get("args") or [])
    target = VC_ROOT
    if "--dir" in extra and extra.index("--dir") + 1 < len(extra):
        from vclab.mcp import vc_lab
        target = vc_lab._wsl(extra[extra.index("--dir") + 1])
    if os.path.normpath(target) == os.path.normpath(VC_ROOT):
        stock = [f for f in d.foreign() if f.get("stock")]
        if stock:     # прежний «уже запущен»: чужой (пользователя) стоковый рантайм в VC_ROOT — не трогаем
            return text("стоковый VoxelCore.exe уже работает вне лаборатории (pid %s) с --dir VC_ROOT — не трогаю. "
                        "Укажи свой --dir в args." % ", ".join(str(f["pid"]) for f in stock), error=True)
    lp = os.path.join(target, "latest.log")
    log_mtime = os.path.getmtime(lp) if os.path.exists(lp) else 0
    r = d.start(script=args.get("script"), extra=extra, play=play, reason=args.get("reason"),
                engine_exe=args.get("engine_exe"), size=args.get("size"))
    if not r.get("ok"):
        tail = r.get("log_tail")
        return text("vc_start: %s: %s%s" % (r.get("error"), r.get("message"),
                                            ("\n" + json.dumps(tail, ensure_ascii=False)[:1500]) if tail else ""),
                    error=True)
    pid = current_pid()
    if play:
        lines = [f"финальная проверка: стоковый VoxelCore.exe, аренда {d.lease}, сеанс {d.play}, pid {pid}"]
    else:
        st = r.get("start") or {}
        iso = st.get("isolation") or {}
        lines = [f"запущен pid {pid}: аренда {d.lease} (тестовая сборка {(st.get('exe') or '').split(chr(92))[-1]}, "
                 f"F2F :{(st.get('ports') or {}).get('f2f')}, часы {iso.get('clock')}, окно {iso.get('window')}, "
                 f"флаги {json.dumps(iso.get('flags'), ensure_ascii=False)}); ввод ОС не действует — vc_input"]
    marker = args.get("wait_for")
    timeout = float(args.get("timeout", 60))
    if marker:
        found = wait_log(marker, timeout, since_mtime=log_mtime)
        lines.append(f"маркер найден: {found}" if found else f"маркер '{marker}' не появился за {timeout:.0f}s")
    return text("\n".join(lines))


def tool_vc_stop(args):
    d = dev()
    if not current_pid() and not d.lease:
        state["pid"] = None
        return text("экземпляр vc_start не запущен (чужие процессы движка не трогаю: lab ps -> foreign)")
    r = d.stop()
    state["pid"] = None
    if os.path.exists(AUTORUN_FILE):
        os.remove(AUTORUN_FILE)
    if not r.get("ok"):
        return text("vc_stop: %s" % json.dumps(r, ensure_ascii=False)[:800], error=True)
    return text("остановлен: аренда %s (%s)" % (r.get("lease"), r.get("why") or r.get("state") or "release"))


def tool_vc_status(args):
    pid = current_pid()
    tail = read_log().splitlines()[-5:]
    d = dev()
    status = f"запущен, pid {pid}, аренда {d.lease}" if pid else "не запущен"
    if pid:
        d.renew()
    return text(status + "\nпоследние строки лога:\n" + "\n".join(tail))


def tool_vc_input(args):
    """F2F-ввод экземпляру vc_start (изолированному от ввода ОС): sequence (синтаксис vc_keys), click [x,y]
    (пиксели кадра; window=true — координаты скриншота vc_screenshot), text, input (сырой F2F input), cmd+args
    (любая команда F2F: обработчики пака, state...)."""
    from vclab.mcp import vc_lab
    d = dev()
    d.renew()
    out = []
    tap = int(args.get("tap_ms", 60)) / 1000.0
    if args.get("cmd"):
        out.append(d.f2f(args["cmd"], args.get("args") or {}, float(args.get("timeout", 60))))
    if args.get("input"):
        out.append(d.f2f("input", args["input"]))
    if args.get("click") is not None:
        x, y = (int(v) for v in args["click"])
        if args.get("window"):
            g = window_geometry()
            x, y = x - g["client"][0], y - g["client"][1]
        btn = {"left": 0, "right": 1, "middle": 2}.get(args.get("button", "left"), 0)
        down = [False, False, False]
        down[btn] = True
        for _ in range(max(1, min(3, int(args.get("count", 1))))):
            out.append(d.f2f("input", {"mouse": {"x": x, "y": y, "buttons": down}}))
            time.sleep(tap)
            out.append(d.f2f("input", {"mouse": {"x": x, "y": y, "buttons": [False, False, False]}}))
            time.sleep(tap)
    if args.get("text"):
        out.append(d.f2f("input", {"chars": args["text"]}))
    if args.get("sequence"):
        for kind, a in vc_lab.sequence_to_f2f(args["sequence"], int(args.get("tap_ms", 60))):
            if kind == "sleep":
                time.sleep(a)
            else:
                out.append(d.f2f("input", a))
    bad = [r for r in out if not r.get("ok")]
    msg = "; ".join(json.dumps(r.get("result") if r.get("ok") else r, ensure_ascii=False)[:200] for r in out[-6:])
    return text(("%d F2F-команд: " % len(out)) + (msg or "ничего не задано (sequence/click/text/input/cmd)"),
                error=bool(bad) or not out)


def tool_vc_screenshot(args):
    name = args.get("name") or time.strftime("screen_%Y%m%d_%H%M%S")
    out_path, info = take_screenshot(name)
    if not out_path:
        return text(info, error=True)
    return image_result(out_path, f"{out_path} ({info})")


def image_result(path, caption):
    with open(path, "rb") as f:
        data = base64.b64encode(f.read()).decode("ascii")
    return {
        "content": [
            {"type": "text", "text": caption},
            {"type": "image", "data": data, "mimeType": "image/png"},
        ]
    }


def take_screenshot(name, directory=None, pid=None):
    """Снимок экземпляра vc_start в <directory or <work_root>/mcp/screens>/<name>.png -> (путь, info) или (None, ошибка).
    Тестовая сборка: F2F shot (кадр из FBO, не зависит от окна и фокуса); не вышло — PrintWindow окна по pid аренды."""
    pid = pid or current_pid()
    if not pid:
        return None, "экземпляр vc_start не запущен"
    directory = directory or SCREENS_DIR
    out_path = os.path.join(directory, name + ".png")
    os.makedirs(directory, exist_ok=True)
    d = dev()
    if d.lease and not d.play and os.environ.get("VC_SHOT", "f2f") == "f2f":
        try:
            r = d.f2f("shot", {"path": to_windows_path(directory) + "\\" + name + ".png"}, timeout=30)
            if r.get("ok"):
                res = r.get("result") or {}
                return out_path, "F2F shot %sx%s sha256 %s" % (res.get("w"), res.get("h"), (res.get("sha256") or "")[:16])
        except Exception:
            pass
    ps1 = to_windows_path(os.path.join(PS_DIR, "vc_screenshot.ps1"))
    info = powershell(f"& '{ps1}' -ProcessId {pid} -OutPath '{to_windows_path(out_path)}'")
    return out_path, info


def window_geometry(pid=None):
    """Окно движка: dict(win=(l,t,r,b), client=(x,y) в координатах скриншота, size=(w,h) клиентской области)."""
    pid = pid or current_pid()
    if not pid:
        raise RuntimeError("VoxelCore не запущен")
    ps1 = to_windows_path(os.path.join(PS_DIR, "vc_geom.ps1"))
    wl, wt, wr, wb, cl, ct, cw, ch = map(int, powershell(f"& '{ps1}' -ProcessId {pid}").split())
    return {"win": (wl, wt, wr, wb), "client": (cl - wl, ct - wt), "size": (cw, ch)}


# Масштаб GUI движка (пиксели окна на единицу gui.get_viewport). В 0.31 при обычном DPI — 1.
GUI_SCALE = float(os.environ.get("VC_GUI_SCALE", "1"))


def program_to_window(x, y, width, height, geom=None):
    """Пиксель экрана программы, нарисованной картинкой по центру страницы (вписана с отступом 10 и целым масштабом)
    -> пиксель скриншота/vc_click."""
    geom = geom or window_geometry()
    cw, ch = geom["size"]
    vw, vh = cw / GUI_SCALE, ch / GUI_SCALE
    scale = min((vw - 20) / width, (vh - 20) / height)
    if scale >= 1:
        scale = int(scale)
    iw, ih = max(1, int(width * scale)) * GUI_SCALE, max(1, int(height * scale)) * GUI_SCALE
    left = geom["client"][0] + (cw - iw) / 2
    top = geom["client"][1] + (ch - ih) / 2
    return int(round(left + (x + 0.5) * iw / width)), int(round(top + (y + 0.5) * ih / height))


def tool_vc_shader_cells(args):
    from vclab.mcp import pixel_debug
    path, info = take_screenshot(args.get("name") or "shader_cells")
    if not path:
        return text(info, error=True)
    names = [n.strip() for n in (args.get("names") or "").split(",") if n.strip()]
    found, cells = pixel_debug.read_cells(path, names, int(args.get("max_cells") or 64))
    return text(pixel_debug.format_cells(found, cells), error=found is None)


def tool_vc_pixels(args):
    from vclab.mcp import pixel_debug
    path, info = take_screenshot(args.get("name") or "pixels")
    if not path:
        return text(info, error=True)
    x, y = int(args["x"]), int(args["y"])
    w = max(1, min(int(args.get("w") or 1), 32))
    h = max(1, min(int(args.get("h") or 1), 32))
    rows = pixel_debug.read_pixels(path, x, y, w, h)
    lines = [f"{path}: {w}x{h} from {x},{y} (координаты скриншота vc_screenshot, RRGGBB)"]
    for dy, row in enumerate(rows):
        lines.append(f"  y={y + dy:4d}: " + " ".join(f"{r:02x}{g:02x}{b:02x}" for r, g, b in row))
    return text("\n".join(lines))


ISOLATED = ("экземпляры vc_start (тестовая сборка --f2f) изолированы от ввода ОС: vc_keys/vc_click их не "
            "достигают. Используй vc_input: sequence (тот же синтаксис, что у vc_keys), click [x,y] (+window=true — "
            "координаты скриншота), text, input, cmd.")


def tool_vc_keys(args):
    pid = current_pid()
    if not pid:
        return text("VoxelCore не запущен", error=True)
    return text(ISOLATED, error=True)          # ввод ОС агентам запрещён (этап 3а); код ниже — для истории
    sequence = args["sequence"].replace("'", "")
    tap = int(args.get("tap_ms", 60))
    ps1 = to_windows_path(os.path.join(PS_DIR, "vc_keys.ps1"))
    out = powershell(f"& '{ps1}' -ProcessId {pid} -Sequence '{sequence}' -TapMs {tap}", timeout=300)
    return text(out)


def tool_vc_click(args):
    pid = current_pid()
    if not pid:
        return text("VoxelCore не запущен", error=True)
    return text(ISOLATED, error=True)          # ввод ОС агентам запрещён (этап 3а); код ниже — для истории
    ps1 = to_windows_path(os.path.join(PS_DIR, "vc_click.ps1"))
    button = "right" if args.get("button") == "right" else "left"
    count = max(1, min(3, int(args.get("count", 1))))
    out = powershell(f"& '{ps1}' -ProcessId {pid} -X {int(args['x'])} -Y {int(args['y'])} -Button {button} -Count {count}")
    return text(out)


def tool_vc_log(args):
    lines = read_log().splitlines()
    pattern = args.get("grep")
    if pattern:
        regex = re.compile(pattern)
        lines = [line for line in lines if regex.search(line)]
    tail = int(args.get("tail", 80))
    return text("\n".join(lines[-tail:]) or "(пусто)")


def tool_vc_wait_log(args):
    pattern = args["pattern"]
    timeout = float(args.get("timeout", 60))
    found = wait_log(pattern, timeout)
    if found:
        return text(found)
    return text(f"'{pattern}' не появился за {timeout:.0f}s", error=True)


def text(message, error=False):
    result = {"content": [{"type": "text", "text": message}]}
    if error:
        result["isError"] = True
    return result


TOOLS = {
    "vc_start": (tool_vc_start, {
        "description": "Запустить движок для разработки пака: аренда демона lab (vc.dev) — тестовая сборка "
                       "VoxelCoreF2F.exe с --f2f <порт> --f2f-clock realtime (время идёт само, ввод ОС изолирован, окно "
                       "без фокуса), --res/--dir как раньше (по умолчанию VC_ROOT: latest.log, export там же). "
                       "script — сценарий автозапуска через project_client.lua (user:<путь>.lua, "
                       "'none' — меню). wait_for — regex в latest.log. Ввод — vc_input. play=true + reason — стоковый "
                       "VoxelCore.exe как разовая финальная проверка главной сессии (lab play --final-check); "
                       "субагентам и замерам — никогда.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "script": {"type": "string"},
                "wait_for": {"type": "string"},
                "timeout": {"type": "number", "default": 60},
                "restart": {"type": "boolean", "default": False},
                "args": {"type": "array", "items": {"type": "string"},
                         "description": "Доп. аргументы движка (--dir, --res, --project...)"},
                "size": {"type": "string", "description": "кадр WxH (--f2f-size), по умолчанию сборки"},
                "engine_exe": {"type": "string", "description": "другая тестовая сборка (не стоковый exe)"},
                "play": {"type": "boolean", "default": False,
                         "description": "стоковый VoxelCore.exe: только финальная проверка главной сессии"},
                "reason": {"type": "string", "description": "для play=true: зачем (пишется в историю)"},
            },
        },
    }),
    "vc_stop": (tool_vc_stop, {
        "description": "Остановить экземпляр vc_start (освободить аренду lab). Чужие процессы движка не трогает.",
        "inputSchema": {"type": "object", "properties": {}},
    }),
    "vc_input": (tool_vc_input, {
        "description": "Ввод экземпляру vc_start через F2F (ввод ОС он не видит): sequence — синтаксис vc_keys "
                       "('enter', 'up:1500', 'ctrl+up:800', 'wait:500', 'text:iddqd', 'wheelup'; имена движка: "
                       "escape, left-shift, a, f1 или LWJGL); click [x,y] — пиксель кадра (window=true — координаты "
                       "скриншота vc_screenshot), button left|right|middle, count; text — символы; input — сырой "
                       "F2F input {keys, mouse, chars}; cmd+args — любая команда F2F (gui, state пака...).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sequence": {"type": "string"}, "click": {"type": "array", "items": {"type": "integer"}},
                "window": {"type": "boolean"}, "button": {"type": "string"}, "count": {"type": "integer"},
                "text": {"type": "string"}, "input": {"type": "object"}, "cmd": {"type": "string"},
                "args": {"type": "object"}, "tap_ms": {"type": "integer", "default": 60},
                "timeout": {"type": "number"},
            },
        },
    }),
    "vc_status": (tool_vc_status, {
        "description": "Запущен ли VoxelCore и последние строки latest.log.",
        "inputSchema": {"type": "object", "properties": {}},
    }),
    "vc_screenshot": (tool_vc_screenshot, {
        "description": "Скриншот окна VoxelCore; PNG сохраняется в <work_root>/mcp/screens и возвращается картинкой.",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}},
    }),
    "vc_keys": (tool_vc_keys, {
        "description": "ОТКЛЮЧЕНО для экземпляров vc_start (ввод ОС изолирован, этап 3а) — используй vc_input "
                       "(тот же синтаксис sequence). Было: нажатия клавиш в окно VoxelCore. sequence — токены через пробел: "
                       "'enter' (нажать), 'up:1500' (держать 1500 мс), 'ctrl+up:800' (вместе), 'wait:500' (пауза), "
                       "'text:iddqd' (набрать буквы). Имена: esc enter tab space backspace left up right down "
                       "ctrl/lctrl/rctrl shift/lshift/rshift alt/lalt/ralt minus equal comma period grave slash f1..f12 a-z 0-9; "
                       "'wheelup' / 'wheeldown:3' — щелчки колеса мыши над курсором.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sequence": {"type": "string"},
                "tap_ms": {"type": "integer", "default": 60},
            },
            "required": ["sequence"],
        },
    }),
    "vc_click": (tool_vc_click, {
        "description": "ОТКЛЮЧЕНО для экземпляров vc_start (ввод ОС изолирован) — используй vc_input click [x,y] "
                       "window=true. Было: клик мышью по окну VoxelCore (пиксели скриншота vc_screenshot).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "x": {"type": "integer"},
                "y": {"type": "integer"},
                "button": {"type": "string", "enum": ["left", "right"], "default": "left"},
                "count": {"type": "integer", "default": 1, "description": "2 — двойной клик (через 90 мс)"},
            },
            "required": ["x", "y"],
        },
    }),
    "vc_shader_cells": (tool_vc_shader_cells, {
        "description": "Отладка шейдера через пиксели: снимает окно VoxelCore и декодирует ячейки отладки "
                       "(полоса квадратов в левом верхнем углу: маркер 5A A5 3C, дальше числа RGB 24 бит, "
                       "фиксированная точка 0.001, смещение 2^23 — dbg_encode в content/pong/shaders/effects/pong.glsl). "
                       "names — имена ячеек через запятую (по порядку после маркера).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "names": {"type": "string"},
                "max_cells": {"type": "integer", "default": 64},
                "name": {"type": "string", "description": "имя файла скриншота"},
            },
        },
    }),
    "vc_pixels": (tool_vc_pixels, {
        "description": "Сырые RGB пиксели окна VoxelCore: прямоугольник w x h (до 32x32) от x, y в координатах "
                       "скриншота vc_screenshot.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "x": {"type": "integer"}, "y": {"type": "integer"},
                "w": {"type": "integer", "default": 1}, "h": {"type": "integer", "default": 1},
                "name": {"type": "string"},
            },
            "required": ["x", "y"],
        },
    }),
    "vc_log": (tool_vc_log, {
        "description": "Хвост latest.log, опционально отфильтрованный regex grep.",
        "inputSchema": {
            "type": "object",
            "properties": {"tail": {"type": "integer", "default": 80}, "grep": {"type": "string"}},
        },
    }),
    "vc_wait_log": (tool_vc_wait_log, {
        "description": "Ждать строку по regex в latest.log.",
        "inputSchema": {
            "type": "object",
            "properties": {"pattern": {"type": "string"}, "timeout": {"type": "number", "default": 60}},
            "required": ["pattern"],
        },
    }),
}


def jmeta(**kw):
    """Пометки для журнала от инструментов (экран, таймаут...); заменяется journal.register."""


STATE = None          # поставщик состояния игры для scenario_run (ставит mcp_tools.py проекта; см. journal.py)
PLUGINS = {}          # имя проекта -> то, что вернул register (прежние EAG/AM)
PLUGIN_ERRORS = {}


def load_project_tools():
    """Точка расширения: projects/<p>/mcp_tools.py с register(TOOLS, vc_module, text) -> инструменты проекта
    (инструменты игр переезжают сюда с проектами). Ошибка одного проекта не мешает остальным (PLUGIN_ERRORS)."""
    import importlib.util
    only = [x for x in os.environ.get("LAB_MCP_PROJECTS", "").split(":") if x]
    pdir = os.path.join(REPO, "projects")
    for name in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []:
        p = os.path.join(pdir, name, "mcp_tools.py")
        if name.startswith("_") or not os.path.isfile(p) or (only and name not in only):
            continue
        try:
            spec = importlib.util.spec_from_file_location("vclab_mcp_tools_" + name, p)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            PLUGINS[name] = mod.register(TOOLS, sys.modules[__name__], text)
        except Exception as exc:
            PLUGIN_ERRORS[name] = "%s: %s" % (type(exc).__name__, exc)


load_project_tools()

# Журнал вызовов и сценарии (journal.py): все tools/call идут через call_tool.
from vclab.mcp import journal  # noqa: E402
call_tool = journal.register(TOOLS, sys.modules[__name__], text)


# ---------------------------------------------------------------- JSON-RPC

def handle(request):
    method = request.get("method")
    params = request.get("params") or {}
    if method == "initialize":
        return {
            "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "voxelcore", "version": "0.1.0"},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [dict(name=name, **spec) for name, (_, spec) in TOOLS.items()]}
    if method == "tools/call":
        name = params.get("name")
        if name not in TOOLS:
            raise KeyError(f"unknown tool {name}")
        try:
            return call_tool(name, params.get("arguments") or {})
        except Exception as exc:  # ошибка инструмента — это результат, а не сбой протокола
            return text(f"{type(exc).__name__}: {exc}", error=True)
    raise KeyError(f"method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request = json.loads(line)
        if "id" not in request:
            continue  # уведомления (notifications/initialized и т.п.)
        try:
            response = {"jsonrpc": "2.0", "id": request["id"], "result": handle(request)}
        except KeyError as exc:
            response = {"jsonrpc": "2.0", "id": request["id"],
                        "error": {"code": -32601, "message": str(exc)}}
        except Exception as exc:
            response = {"jsonrpc": "2.0", "id": request["id"],
                        "error": {"code": -32603, "message": f"{type(exc).__name__}: {exc}"}}
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
