"""Процессы Windows под Job Object: CreateProcess(SUSPENDED) -> AssignProcessToJobObject -> resume.

Всё дерево (дети, внуки: cmd -> java, launchwrapper) живёт в Job аренды; остановка — TerminateJobObject, никаких
Stop-Process -Name. KILL_ON_JOB_CLOSE: если демон умер, ОС закрывает дескриптор Job и убивает тестовые экземпляры
(нет сирот). stdout/stderr — сырые байты в файлы (кодировку решает decode.py при чтении). Смерть видна сразу:
поток ждёт дескриптор процесса (Popen.wait), код выхода расшифровывается (NTSTATUS)."""
import os
import subprocess
import threading
import time

import psutil
import win32api
import win32con
import win32job

CREATE_SUSPENDED = 0x00000004
CREATE_NO_WINDOW = 0x08000000
CREATE_NEW_PROCESS_GROUP = 0x00000200
SEM_FAILCRITICALERRORS = 0x0001
SEM_NOGPFAULTERRORBOX = 0x0002

NTSTATUS = {
    0xC0000005: "access violation",
    0xC0000409: "stack buffer overrun / abort (fail-fast)",
    0xC00000FD: "stack overflow",
    0xC000013A: "Ctrl+C / console closed",
    0xC0000135: "DLL not found",
    0xC0000142: "DLL init failed",
    0xE06D7363: "unhandled C++ exception",
    0x40010004: "terminated (debugger / TerminateProcess)",
    0xC000001D: "illegal instruction",
    0xC0000374: "heap corruption",
}
JOB_KILLED = 0x1AB0B  # код, с которым TerminateJobObject завершает процессы аренды


def quiet_errors():
    """Без окон «программа перестала работать»: режим наследуется дочерними процессами."""
    try:
        import ctypes
        ctypes.windll.kernel32.SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX)
    except Exception:
        pass


def describe_exit(code):
    if code is None:
        return None
    u = code & 0xFFFFFFFF
    if u == JOB_KILLED:
        return "killed by lab (TerminateJobObject)"
    if u >= 0x80000000:
        return "0x%08X %s" % (u, NTSTATUS.get(u, "NTSTATUS"))
    return "exit %d" % code


class Job:
    """Именованный (для отладки) Job Object с KILL_ON_JOB_CLOSE (kill_on_close=False — для «живущих дольше
    демона» запусков, напр. будущий vc_runtime пользователя)."""

    def __init__(self, name, kill_on_close=True):
        self.name = name
        self.kill_on_close = kill_on_close
        self.handle = win32job.CreateJobObject(None, "")
        info = win32job.QueryInformationJobObject(self.handle, win32job.JobObjectExtendedLimitInformation)
        flags = win32job.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
        if kill_on_close:
            flags |= win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        info["BasicLimitInformation"]["LimitFlags"] = flags
        win32job.SetInformationJobObject(self.handle, win32job.JobObjectExtendedLimitInformation, info)

    def assign(self, process_handle):
        win32job.AssignProcessToJobObject(self.handle, process_handle)

    def pids(self):
        if self.handle is None:
            return []
        try:
            return list(win32job.QueryInformationJobObject(self.handle, win32job.JobObjectBasicProcessIdList))
        except Exception:
            return []

    def terminate(self, code=JOB_KILLED):
        if self.handle is not None:
            try:
                win32job.TerminateJobObject(self.handle, code)
            except Exception:
                pass

    def close(self):
        if self.handle is not None:
            try:
                self.handle.Close()
            except Exception:
                pass
            self.handle = None


class Proc:
    """Процесс аренды. info() — сериализуемое состояние (pid + create_time — идентичность после рестарта демона)."""

    def __init__(self, name, argv, cwd, out_path, err_path):
        self.name, self.argv, self.cwd = name, argv, cwd
        self.out_path, self.err_path = out_path, err_path
        self.popen = None
        self.pid = None
        self.create_time = None
        self.started = None
        self.ended = None
        self.exit_code = None
        self.adopted = False
        self.on_exit = []
        self._ps = None

    def alive(self):
        if self.popen is not None:
            return self.popen.poll() is None
        if self._ps is not None:
            try:
                return self._ps.is_running() and self._ps.create_time() == self.create_time
            except psutil.Error:
                return False
        return False

    def info(self):
        return {"name": self.name, "pid": self.pid, "create_time": self.create_time, "argv": self.argv,
                "cwd": self.cwd, "stdout": self.out_path, "stderr": self.err_path, "started": self.started,
                "ended": self.ended, "exit_code": self.exit_code, "exit": describe_exit(self.exit_code),
                "alive": self.alive(), "adopted": self.adopted}

    def write_stdin(self, data):
        if self.popen is None or self.popen.stdin is None:
            raise RuntimeError("stdin of %s is not a pipe" % self.name)
        self.popen.stdin.write(data.encode("utf-8") if isinstance(data, str) else data)
        self.popen.stdin.flush()

    def _finish(self, code):
        self.exit_code = code
        self.ended = time.time()
        for cb in list(self.on_exit):
            try:
                cb(self)
            except Exception:
                pass

    def _waiter(self):
        code = self.popen.wait()
        self._finish(code)

    def wait(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if not self.alive():
                return True
            time.sleep(0.05)
        return not self.alive()


def spawn(job, name, argv, cwd, out_path, err_path, env=None, stdin_pipe=False, console=False):
    """Запуск в Job без гонки: процесс создаётся приостановленным, назначается в Job, затем продолжается —
    внуки, которых он породит, уже в Job. Наследуются только дескрипторы stdin/stdout/stderr (Popen close_fds)."""
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    p = Proc(name, argv, cwd, out_path, err_path)
    out = open(out_path, "ab")
    err = open(err_path, "ab") if err_path != out_path else out
    flags = CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP | (0 if console else CREATE_NO_WINDOW)
    try:
        full_env = None
        if env:
            full_env = dict(os.environ)
            full_env.update({k: str(v) for k, v in env.items()})
        p.popen = subprocess.Popen(argv, cwd=cwd, stdout=out, stderr=err,
                                   stdin=subprocess.PIPE if stdin_pipe else subprocess.DEVNULL,
                                   env=full_env, creationflags=flags, close_fds=True)
    finally:
        out.close()
        if err is not out:
            err.close()
    p.pid = p.popen.pid
    ps = psutil.Process(p.pid)
    try:
        job.assign(int(p.popen._handle))
    except Exception:
        p.popen.kill()
        raise
    p.create_time = ps.create_time()
    p._ps = ps
    ps.resume()
    p.started = time.time()
    threading.Thread(target=p._waiter, name="wait-%s-%d" % (name, p.pid), daemon=True).start()
    return p


POKE_SRC = r"""
import ctypes, sys
from ctypes import wintypes as W
k = ctypes.WinDLL("kernel32", use_last_error=True)
pid = int(sys.argv[1])
if not k.AttachConsole(pid):
    print("attach-failed %d" % ctypes.get_last_error()); sys.exit(2)
h = k.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)
if h in (0, -1, ctypes.c_void_p(-1).value):
    print("conin-failed %d" % ctypes.get_last_error()); sys.exit(3)
class KEY(ctypes.Structure):
    _fields_ = [("bKeyDown", W.BOOL), ("wRepeatCount", W.WORD), ("wVirtualKeyCode", W.WORD),
                ("wVirtualScanCode", W.WORD), ("uChar", W.WCHAR), ("dwControlKeyState", W.DWORD)]
class REC(ctypes.Structure):
    _fields_ = [("EventType", W.WORD), ("_pad", W.WORD), ("Event", KEY)]
r = REC(); r.EventType = 1
r.Event = KEY(True, 1, 0x0D, 0x1C, "\r", 0)
n = W.DWORD(0)
ok = k.WriteConsoleInputW(h, ctypes.byref(r), 1, ctypes.byref(n))
k.CloseHandle(h); k.FreeConsole()
print("poked %d %d" % (ok, n.value)); sys.exit(0 if ok else 4)
"""


def console_poke(pid, timeout=10.0):
    """Одно событие клавиши (Enter) в буфер ввода консоли процесса pid — консоль без окна (CREATE_NO_WINDOW).
    Нужно для VoxelCore --stdin-cmd на Windows: его читатель опрашивает _kbhit() (консоль), а строки берёт из
    std::cin (у нас — канал). Делает вспомогательный процесс без консоли (DETACHED_PROCESS): AttachConsole(pid)
    возможен только из процесса без своей консоли. Это не ввод ОС в окно: окна нет, событие не уходит ни в какое
    окно и не трогает фокус/курсор пользователя. -> {ok, out, rc, ms}"""
    import sys
    t0 = time.time()
    exe = sys.executable
    if os.path.basename(exe).lower() == "pythonw.exe":
        cand = os.path.join(os.path.dirname(exe), "python.exe")
        exe = cand if os.path.exists(cand) else exe
    DETACHED_PROCESS = 0x00000008
    try:
        r = subprocess.run([exe, "-c", POKE_SRC, str(int(pid))], capture_output=True, timeout=timeout,
                           creationflags=DETACHED_PROCESS, stdin=subprocess.DEVNULL)
        out = (r.stdout or b"").decode("utf-8", "replace").strip()
        return {"ok": r.returncode == 0, "rc": r.returncode, "out": out, "ms": round((time.time() - t0) * 1000, 1)}
    except Exception as exc:
        return {"ok": False, "rc": None, "out": "%s: %s" % (type(exc).__name__, exc),
                "ms": round((time.time() - t0) * 1000, 1)}


def adopt(job, info):
    """Процесс из файла состояния после рестарта демона: свой, только если совпадают pid и create_time.
    Возвращает Proc (alive или нет)."""
    p = Proc(info["name"], info.get("argv"), info.get("cwd"), info.get("stdout"), info.get("stderr"))
    p.pid, p.create_time, p.started = info.get("pid"), info.get("create_time"), info.get("started")
    p.adopted = True
    try:
        ps = psutil.Process(p.pid)
        if abs(ps.create_time() - (p.create_time or 0)) > 0.01:
            raise psutil.NoSuchProcess(p.pid)
        p._ps = ps
        h = win32api.OpenProcess(win32con.PROCESS_ALL_ACCESS, False, p.pid)
        try:
            job.assign(h)
        except Exception:
            pass
        import win32event
        import win32process

        def waiter():
            win32event.WaitForSingleObject(h, win32event.INFINITE)
            code = win32process.GetExitCodeProcess(h)
            h.Close()
            p._finish(code)
        threading.Thread(target=waiter, daemon=True).start()
    except psutil.Error:
        p.exit_code = info.get("exit_code")
        p.ended = info.get("ended") or time.time()
    return p
