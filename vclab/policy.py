"""Принуждение правил пользователя софтом (этап 3а), а не словами в заданиях агентам.

(A) Ни один движок или эталонный клиент, запущенный агентом, не реагирует на настоящий ввод, не захватывает курсор и
    не реагирует на фокус. Значит: вид экземпляра с exe движка (`voxelcore*`) запускается только тестовой сборкой с
    `--f2f` (ввод изолирован безусловно), после старта `hello.flags.input == "isolated"` (и `flags.clock` — запрошенные
    часы) — иначе экземпляр убивается (TerminateJobObject) и аренда получает ошибку `isolation-failed`. Стоковый
    рантайм `VC_ROOT\\VoxelCore.exe` (путь или та же sha256) — только вид `role = "runtime"`, а такой вид создаётся
    только из `lab play` (`--user`: владелец user, интерактивный CLI) или `--final-check` (владелец claude/user,
    обязательная причина). Любая другая аренда стокового exe — отказ `policy` (403).
(C) Этап 4: headless (`role = "headless"`): экземпляр без окна и без ввода (`--headless`, консоль без окна, stdin —
    только канал лаборатории) может запускать СТОКОВЫЙ exe любой версии движка: он физически не может принять ввод ОС.
    Проверка: ключ `--headless` в argv, нет `console`, после готовности и затем сторожем — у процессов дерева Job нет
    ни одного окна верхнего уровня (EnumWindows, только чтение). Окно нашлось — дерево убивается, isolation-failed.
    Стоковый exe в оконном (тестовом) виде — по-прежнему отказ, для всех версий (`stock` из [engines.*]).
(B) Замеры — только на простаивающем ПК: см. vclab/quality/perf.py (ожидание простоя, contended).

Плюс сторож: процессы `VoxelCore*.exe`/`java(w).exe` вне аренд и сеансов — `foreign` в `lab ps` (никогда не убиваются).
"""
import hashlib
import os
import time

from vclab import config

ENGINE_PREFIX = "voxelcore"
WATCH_NAMES = ("voxelcore", "java.exe", "javaw.exe")
RUNTIME_MODES = ("play", "final-check")
USER_OWNER = "user"
MAIN_OWNERS = ("claude", "user")         # главная сессия и пользователь: разовая финальная проверка
CLOCKS = ("virtual", "realtime")
WINDOWS = ("hidden", "normal")


class PolicyError(Exception):
    def __init__(self, message, **extra):
        super().__init__(message)
        self.message, self.extra = message, extra


def stock_exe():
    return os.path.join(config.VC_ROOT, "VoxelCore.exe")


_sha_cache = {}
EXTRA_STOCK = []          # стоковые exe других версий движка ([engines.<id>].stock), ставит Lab при загрузке


def file_sha(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    key = (os.path.normcase(os.path.abspath(path)), st.st_size, st.st_mtime_ns)
    if key not in _sha_cache:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        _sha_cache[key] = h.hexdigest()
    return _sha_cache[key]


def is_engine_exe(path):
    return os.path.basename(str(path or "")).lower().startswith(ENGINE_PREFIX)


def is_stock(path, sha=None):
    """Стоковый рантайм: тот же путь или та же sha256, что у VC_ROOT\\VoxelCore.exe (копия под другим именем)."""
    if not path:
        return False
    stocks = [stock_exe()] + [x for x in EXTRA_STOCK if x]
    norm = os.path.normcase(os.path.abspath(path))
    if any(norm == os.path.normcase(os.path.abspath(x)) for x in stocks):
        return True
    if not is_engine_exe(path) and sha is None:
        return False
    mine = None
    for st_path in stocks:
        st = file_sha(st_path)
        if not st:
            continue
        if mine is None:
            mine = sha or file_sha(path)
        if mine == st:
            return True
    return False


# ------------------------------------------------------------------------------------------------ headless (этап 4)
def check_headless(spec, argv):
    """Требования вида role=headless до запуска -> список нарушений (пусто — можно)."""
    bad = []
    if "--headless" not in argv:
        bad.append("argv has no --headless (a headless kind must not open a window)")
    if spec.get("console"):
        bad.append("console = true creates a console window")
    for tok in ("--f2f-window",):
        if tok in argv:
            bad.append("%s is meaningless for headless" % tok)
    return bad


def top_windows(pids):
    """Окна верхнего уровня процессов pids (EnumWindows + GetWindowThreadProcessId, только чтение) ->
    [{hwnd, pid, cls, title, visible}]. Ничего не меняет, фокус и ввод не трогает."""
    pids = set(int(p) for p in pids or () if p)
    if not pids:
        return []
    import win32gui
    import win32process
    out = []

    def cb(hwnd, _):
        try:
            _tid, pid = win32process.GetWindowThreadProcessId(hwnd)
        except Exception:
            return True
        if pid in pids:
            try:
                cls = win32gui.GetClassName(hwnd)
            except Exception:
                cls = "?"
            try:
                title = win32gui.GetWindowText(hwnd)
            except Exception:
                title = ""
            out.append({"hwnd": int(hwnd), "pid": pid, "cls": cls, "title": title[:80],
                        "visible": bool(win32gui.IsWindowVisible(hwnd))})
        return True
    try:
        win32gui.EnumWindows(cb, None)
    except Exception:
        pass
    return out


_caps = {}


def exe_caps(path):
    """Какие ключи F2F понимает сборка: поиск строк ключей в образе exe (неизвестный ключ движок считает ошибкой
    и не стартует, поэтому старой сборке их передавать нельзя). Кэш по (путь, размер, mtime)."""
    try:
        st = os.stat(path)
    except OSError:
        return {}
    key = (os.path.normcase(os.path.abspath(path)), st.st_size, st.st_mtime_ns)
    if key not in _caps:
        with open(path, "rb") as f:
            data = f.read()
        _caps[key] = {k: (k.encode() in data) for k in ("--f2f", "--f2f-clock", "--f2f-window", "--f2f-size")}
    return _caps[key]


def owner_class(owner):
    if owner == USER_OWNER:
        return "user"
    if owner in MAIN_OWNERS:
        return "main"
    return "agent"


def check_runtime_lease(owner, mode, reason=None, interactive=False, via=None):
    """Кто может поднять стоковый рантайм (вид role=runtime). -> None или PolicyError."""
    if mode not in RUNTIME_MODES:
        raise PolicyError("the stock runtime kind is play-only: `lab play <project> --user` (the user, interactive "
                          "CLI) or `lab play <project> --final-check --reason \"...\"` (main session claude / user); "
                          "agents use engine leases (test build, --f2f, input isolated)")
    if mode == "play":
        if owner != USER_OWNER:
            raise PolicyError("lab play --user: owner must be %r, not %r (an agent never starts the stock runtime)"
                              % (USER_OWNER, owner))
        if not interactive or via == "mcp":
            raise PolicyError("lab play --user is accepted only from an interactive CLI of the user (not MCP, not a "
                              "script without a terminal)")
    else:
        if owner not in MAIN_OWNERS:
            raise PolicyError("--final-check: owner must be one of %s (main session or the user), not %r — subagents "
                              "never start the stock runtime" % (", ".join(MAIN_OWNERS), owner))
        if not reason or len(str(reason).strip()) < 8:
            raise PolicyError("--final-check needs --reason \"...\" (why the stock runtime is needed: release check, "
                              "user request); it is written to history as runtime_session")


def isolation_spec(spec, exe, sha=None):
    """Требования изоляции вида: (required, argv_token, hello_expect dict). Для exe движка требования есть всегда —
    дескриптор их не отключает."""
    iso = spec.get("isolation") or {}
    if spec.get("role") == "runtime":
        return False, None, {}
    engine = is_engine_exe(exe)
    argv_tok = iso.get("argv") or ("--f2f" if engine else None)
    hello = dict(iso.get("hello") or {})
    if engine:
        hello.setdefault("flags.input", "isolated")
    return bool(engine or iso), argv_tok, hello


def lookup(d, dotted):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def verify_hello(result, expect):
    """-> список несовпадений ('flags.input: want isolated, got None')."""
    bad = []
    for k, want in (expect or {}).items():
        got = lookup(result or {}, k)
        if got != want:
            bad.append("%s: want %r, got %r" % (k, want, got))
    return bad


def verify_version(hello, accepted):
    """Этап 4a: hello.version тестовой сборки против версии движка аренды ([engines.<id>].f2f_version, строка или
    список: "0.31-f2f", "0.32-f2f"). -> None (принято / не требуется) или текст несовпадения."""
    if not accepted:
        return None
    got = (hello or {}).get("version")
    if got in accepted:
        return None
    return "version: want %s, got %r" % (" | ".join(repr(a) for a in accepted), got)


# ------------------------------------------------------------------------------------------------ сторож процессов
def scan_foreign(own_pids, names=WATCH_NAMES):
    """Процессы движка/Java, не принадлежащие арендам и сеансам демона. Только чтение списка процессов."""
    import psutil
    own = set(own_pids or ())
    out = []
    for p in psutil.process_iter(["pid", "name", "create_time", "ppid"]):
        try:
            name = (p.info.get("name") or "").lower()
            if not any(name.startswith(n) for n in names) or p.info["pid"] in own:
                continue
            try:
                exe = p.exe()
            except Exception:
                exe = None
            try:
                cmd = p.cmdline()
            except Exception:
                cmd = []
            out.append({"pid": p.info["pid"], "name": p.info.get("name"), "exe": exe,
                        "create_time": p.info.get("create_time"), "ppid": p.info.get("ppid"),
                        "cmdline": short_cmd(cmd), "f2f": "--f2f" in cmd,
                        "stock": bool(exe and name.startswith(ENGINE_PREFIX) and is_stock(exe))})
        except Exception:
            continue
    return out


def short_cmd(cmd, limit=240):
    """Короткая командная строка: у Java — без длинного -cp."""
    out = []
    skip = False
    for a in cmd or []:
        if skip:
            out.append("<cp %d chars>" % len(a))
            skip = False
            continue
        if a in ("-cp", "-classpath"):
            skip = True
        out.append(a)
    s = " ".join(out)
    return s if len(s) <= limit else s[:limit] + "..."


class Watchdog:
    """Поток демона: раз в `every` с список чужих процессов движка/Java; новый — запись `lab.foreign_process` в журнал.
    Ничего не убивает (агенты не запускают процессы вне аренд; отчёт делает нарушение видимым)."""

    def __init__(self, own_fn, on_new=None, every=5.0):
        self.own_fn, self.on_new, self.every = own_fn, on_new, every
        self.foreign = []
        self.seen = {}
        self.last = None
        self.error = None
        self.disabled = False       # изолированный демон (этап 5): процессы общего демона ему чужие — не сканировать

    def tick(self):
        if self.disabled:
            self.last = time.time()
            return self.foreign
        try:
            cur = scan_foreign(self.own_fn())
            self.error = None
        except Exception as exc:
            self.error = "%s: %s" % (type(exc).__name__, exc)
            return self.foreign
        now = time.time()
        keys = set()
        for p in cur:
            k = (p["pid"], round(p.get("create_time") or 0, 2))
            keys.add(k)
            if k not in self.seen:
                self.seen[k] = now
                if self.on_new:
                    try:
                        self.on_new(p)
                    except Exception:
                        pass
            p["first_seen"] = self.seen[k]
            p["state"] = "foreign"
        for k in list(self.seen):
            if k not in keys:
                del self.seen[k]
        self.foreign = cur
        self.last = now
        return cur
