"""Загрузка ПК: CPU (psutil), GPU (nvidia-smi, если есть), активность пользователя (GetLastInputInfo — только чтение
времени последнего ввода, не ввод) и процесс переднего плана (GetForegroundWindow — только чтение).

Зачем: правило «не гонять замеры, когда ПК занят» исполняется механически. Прогон помечается `contended`, если во время
него пользователь был активен и его процесс(ы) грузили CPU выше порога, или посторонние процессы в сумме выше порога,
или GPU занят до старта своих экземпляров. Перф-вердикты ворот по `contended`-прогонам игнорируются.

  sample(seconds=1.0, own_pids=())   -> один снимок (dict)
  Sampler(own_pids_fn, every=2.0)    -> .start() / .stop() -> сводка за прогон (dict)
  verdict(samples, thresholds)        -> {contended, reasons}
Пороги — THRESHOLDS (перекрываются аргументом)."""
import ctypes
import os
import shutil
import subprocess
import threading
import time

THRESHOLDS = {
    "user_active_s": 60.0,       # ввод пользователя не позже N с назад = пользователь активен
    "foreground_cpu_pct": 10.0,  # процесс переднего плана (не наш) грузит CPU выше (в % одного ядра / число ядер)
    "others_cpu_pct": 30.0,      # сумма CPU посторонних процессов, % всей машины
    "gpu_busy_pct": 30.0,        # загрузка GPU по nvidia-smi (имеет смысл до старта своих экземпляров)
    "contended_share": 0.2,      # доля снимков прогона с признаком занятости, начиная с которой прогон contended
    "foreign_engines": 1,        # столько чужих процессов движка/Java (VoxelCore*.exe, java.exe) уже = занято
}
ENGINE_NAMES = ("voxelcore", "java.exe", "javaw.exe")

# системные процессы, которые не считаются «пользователь работает» (их фон есть всегда)
IGNORE = {"system idle process", "system", "idle", "registry", "memory compression", "dwm.exe", "csrss.exe",
          "svchost.exe", "searchindexer.exe", "msmpeng.exe", "audiodg.exe", "wmiprvse.exe", "lsass.exe",
          "services.exe", "wininit.exe", "smss.exe", "fontdrvhost.exe"}


class _LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]


def user_idle_s():
    """Секунды с последнего ввода пользователя (клавиатура/мышь) — только чтение; None вне Windows."""
    try:
        lii = _LASTINPUTINFO()
        lii.cbSize = ctypes.sizeof(lii)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(lii)):
            return None
        tick = ctypes.windll.kernel32.GetTickCount() & 0xFFFFFFFF
        return round(((tick - lii.dwTime) & 0xFFFFFFFF) / 1000.0, 1)
    except Exception:
        return None


def foreground_pid():
    try:
        hwnd = ctypes.windll.user32.GetForegroundWindow()
        if not hwnd:
            return None
        pid = ctypes.c_ulong()
        ctypes.windll.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return pid.value or None
    except Exception:
        return None


_NVSMI = None


def nvidia_smi():
    global _NVSMI
    if _NVSMI is None:
        cands = [shutil.which("nvidia-smi"), r"C:\Windows\System32\nvidia-smi.exe",
                 r"C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"]
        _NVSMI = next((c for c in cands if c and os.path.exists(c)), "")
    return _NVSMI or None


def gpu():
    """[{name, util_pct, mem_used_mb}] или None (нет nvidia-smi / ошибка)."""
    exe = nvidia_smi()
    if not exe:
        return None
    try:
        out = subprocess.run([exe, "--query-gpu=name,utilization.gpu,memory.used", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=5, stdin=subprocess.DEVNULL,
                             creationflags=0x08000000 if os.name == "nt" else 0).stdout
    except Exception:
        return None
    res = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 3:
            try:
                res.append({"name": parts[0], "util_pct": float(parts[1]), "mem_used_mb": float(parts[2])})
            except ValueError:
                pass
    return res or None


def _descendants(pids):
    import psutil
    out = set()
    for p in pids or ():
        try:
            pr = psutil.Process(p)
            out.add(p)
            out.update(c.pid for c in pr.children(recursive=True))
        except Exception:
            pass
    return out


def sample(seconds=1.0, own_pids=(), with_gpu=True, top=5):
    """Один снимок за `seconds`: CPU машины, CPU посторонних процессов (без own_pids, их детей и самого демона),
    процесс переднего плана, простой пользователя, GPU."""
    import psutil
    ncpu = psutil.cpu_count() or 1
    own = _descendants(set(own_pids or ()) | {os.getpid()})
    procs = {}
    for p in psutil.process_iter(["name"]):
        try:
            p.cpu_percent(None)
            procs[p.pid] = p
        except Exception:
            pass
    psutil.cpu_percent(None)
    time.sleep(seconds)
    total = psutil.cpu_percent(None)
    per = []
    for pid, p in procs.items():
        try:
            c = p.cpu_percent(None) / ncpu
        except Exception:
            continue
        name = (p.info.get("name") or "").lower()
        if c <= 0.05 or pid in own or name in IGNORE:
            continue
        per.append((c, pid, name))
    per.sort(reverse=True)
    foreign = []
    for pid, p in procs.items():
        name = (p.info.get("name") or "").lower()
        if pid not in own and any(name.startswith(e) for e in ENGINE_NAMES):
            foreign.append({"pid": pid, "name": name})
    others = round(sum(c for c, _, _ in per), 1)
    own_cpu = 0.0
    for pid in own:
        p = procs.get(pid)
        if p is not None:
            try:
                own_cpu += p.cpu_percent(None) / ncpu
            except Exception:
                pass
    fg = foreground_pid()
    fg_name, fg_cpu = None, None
    if fg:
        for c, pid, name in per:
            if pid == fg:
                fg_name, fg_cpu = name, round(c, 1)
                break
        if fg_name is None:
            try:
                fg_name = psutil.Process(fg).name().lower()
            except Exception:
                pass
            fg_cpu = 0.0
    s = {"t": time.time(), "cpu_total_pct": round(total, 1), "cpu_others_pct": others,
         "top": [{"name": n, "pid": pid, "cpu_pct": round(c, 1)} for c, pid, n in per[:top]],
         "foreground": {"pid": fg, "name": fg_name, "cpu_pct": fg_cpu, "own": bool(fg and fg in own)},
         "user_idle_s": user_idle_s(), "ncpu": ncpu,
         "foreign_engines": foreign}
    if with_gpu:
        s["gpu"] = gpu()
    s.update(flags(s))
    return s


def flags(s, th=None):
    th = dict(THRESHOLDS, **(th or {}))
    reasons = []
    idle = s.get("user_idle_s")
    fg = s.get("foreground") or {}
    active = idle is not None and idle < th["user_active_s"]
    if active and not fg.get("own") and (fg.get("cpu_pct") or 0) >= th["foreground_cpu_pct"]:
        reasons.append("user active: %s %.1f%% CPU (idle %.0f s)" % (fg.get("name"), fg.get("cpu_pct"), idle))
    if (s.get("cpu_others_pct") or 0) >= th["others_cpu_pct"]:
        top = ", ".join("%s %.0f%%" % (t["name"], t["cpu_pct"]) for t in (s.get("top") or [])[:3])
        reasons.append("other processes %.0f%% CPU (%s)" % (s["cpu_others_pct"], top))
    fe = s.get("foreign_engines") or []
    if th["foreign_engines"] and len(fe) >= th["foreign_engines"]:
        reasons.append("foreign engine/java processes: %s" % ", ".join(sorted({x["name"] for x in fe})))
    g = s.get("gpu") or []
    if s.get("gpu_counts", True) and g and max(x["util_pct"] for x in g) >= th["gpu_busy_pct"]:
        reasons.append("GPU busy %.0f%%" % max(x["util_pct"] for x in g))
    return {"user_active": active, "busy": bool(reasons), "reasons": reasons}


def verdict(samples, th=None):
    """Сводка по снимкам прогона: contended, если доля «занятых» снимков >= contended_share."""
    th = dict(THRESHOLDS, **(th or {}))
    samples = [s for s in samples or [] if s]
    if not samples:
        return {"contended": None, "reasons": ["no samples"], "n": 0}
    busy = [s for s in samples if flags(s, th)["busy"]]
    share = len(busy) / len(samples)
    reasons = []
    for s in busy:
        for r in flags(s, th)["reasons"]:
            if r.split(":")[0] not in [x.split(":")[0] for x in reasons]:
                reasons.append(r)

    def agg(key):
        v = [s.get(key) for s in samples if s.get(key) is not None]
        return {"avg": round(sum(v) / len(v), 1), "max": round(max(v), 1)} if v else None
    gpus = [max(x["util_pct"] for x in s["gpu"]) for s in samples if s.get("gpu")]
    return {"contended": share >= th["contended_share"], "busy_share": round(share, 2), "n": len(samples),
            "reasons": reasons[:6], "cpu_total": agg("cpu_total_pct"), "cpu_others": agg("cpu_others_pct"),
            "gpu_util": {"avg": round(sum(gpus) / len(gpus), 1), "max": max(gpus)} if gpus else None,
            "user_active_share": round(sum(1 for s in samples if flags(s, th)["user_active"]) / len(samples), 2),
            "thresholds": th}


class Sampler:
    """Фоновый сбор снимков на время прогона. own_pids_fn() -> pid своих экземпляров (их CPU не считается).
    GPU учитывается только в снимках до первого непустого own_pids (потом его грузим мы сами)."""

    def __init__(self, own_pids_fn=None, every=2.0, window=1.0, th=None):
        self.own_pids_fn = own_pids_fn or (lambda: ())
        self.every, self.window, self.th = every, window, th
        self.samples = []
        self._stop = threading.Event()
        self._t = None

    def _loop(self):
        while not self._stop.is_set():
            try:
                own = tuple(self.own_pids_fn() or ())
                s = sample(self.window, own)
                s["gpu_counts"] = not own
                s.update(flags(s, self.th))
                self.samples.append(s)
            except Exception:
                pass
            self._stop.wait(max(0.0, self.every - self.window))

    def start(self):
        self._t = threading.Thread(target=self._loop, name="sysload", daemon=True)
        self._t.start()
        return self

    def stop(self):
        self._stop.set()
        if self._t:
            self._t.join(self.window + 6)
        return self.summary()

    def summary(self):
        v = verdict(self.samples, self.th)
        v["samples"] = [{k: s.get(k) for k in ("t", "cpu_total_pct", "cpu_others_pct", "user_idle_s", "busy")}
                        | {"gpu": max((x["util_pct"] for x in s.get("gpu") or []), default=None)}
                        for s in self.samples]
        return v


def check(seconds=2.0, own_pids=(), th=None):
    """Разовая проверка «можно ли сейчас мерить»: снимок + вердикт (для CLI `lab sysload` и перед перф/play)."""
    s = sample(seconds, own_pids)
    f = flags(s, th)
    return {"ok": True, "busy": f["busy"], "reasons": f["reasons"], "sample": s}
