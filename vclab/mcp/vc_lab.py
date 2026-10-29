"""vc_start/vc_stop/vc_input через демон лаборатории (этап 3а): MCP `voxelcore` больше не запускает VoxelCore.exe сам.

- vc_start: аренда `vc.dev` (projects/vc/project.toml) = тестовая сборка VoxelCoreF2F.exe с
  `--f2f <порт> --f2f-clock realtime --f2f-window normal`, те же --res/--dir, что у прежнего vc_start (по умолчанию
  VC_ROOT): latest.log, autorun_app_script.txt, export\\ — на прежних местах. Демон проверяет hello.flags.input ==
  "isolated" (иначе убивает экземпляр). `lab ps` видит аренду (владелец LAB_OWNER сервера MCP или claude).
- play=true (+ reason): стоковый VoxelCore.exe — только как `lab play vc --final-check` главной сессии (claude);
  запись runtime_session в истории. Субагентам и циклам замеров — никогда.
- Ввод: настоящий ввод ОС экземпляр не видит (изоляция). vc_input -> F2F `input` (клавиши, мышь, текст) или любая
  команда F2F (обработчики пака, `state`...) на порт этого экземпляра через демон.

Канал к демону — bin/labpipe.py (один процесс Windows-Python, JSON-строки; ~1–2 мс на вызов)."""
import json
import os
import subprocess
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _win_py():
    """python_win из machine.toml (WSL-путь к python.exe Windows)."""
    from vclab import machine
    from vclab.config import win_to_wsl
    p = machine.load().get("python_win")
    if not p:
        raise RuntimeError("machine.toml: python_win is not set (lab doctor)")
    return win_to_wsl(p)


class LabPipe:
    def __init__(self, vc_root):
        self.vc_root = vc_root
        self.proc = None
        self.lock = threading.Lock()
        self.seq = 0
        self.owner = os.environ.get("LAB_OWNER") or "claude"

    def _ensure(self):
        if self.proc is not None and self.proc.poll() is None:
            return
        pipe = subprocess.check_output(["wslpath", "-w", os.path.join(REPO, "bin", "labpipe.py")],
                                       text=True).strip()
        env = dict(os.environ)
        env["LAB_OWNER"] = self.owner
        env["WSLENV"] = (env.get("WSLENV", "") + ":LAB_OWNER").lstrip(":")
        self.proc = subprocess.Popen([_win_py(), "-X", "utf8", "-u", "-B", pipe], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd="/mnt/c", env=env,
                                     text=True, encoding="utf-8", bufsize=1)

    def call(self, method, path, body=None, timeout=120.0):
        with self.lock:
            for attempt in (0, 1):
                self._ensure()
                self.seq += 1
                req = {"id": self.seq, "m": method, "p": path, "b": body, "t": timeout, "owner": self.owner}
                try:
                    self.proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
                    self.proc.stdin.flush()
                    line = self.proc.stdout.readline()
                except (OSError, ValueError):
                    line = ""
                if not line:
                    try:
                        self.proc.kill()
                    except Exception:
                        pass
                    self.proc = None
                    if attempt:
                        raise RuntimeError("labpipe died (Windows python / bin/labpipe.py)")
                    continue
                rep = json.loads(line)
                if rep.get("error"):
                    raise RuntimeError(rep["error"])
                return rep.get("r") or {}

    def get(self, path, timeout=60.0):
        return self.call("GET", path, None, timeout)

    def post(self, path, body=None, timeout=120.0):
        return self.call("POST", path, body or {}, timeout)


class Dev:
    """Состояние экземпляра vc_start этого сервера MCP: аренда (vc.dev) или сеанс final-check (vc-main)."""

    PROJECT = "vc"

    def __init__(self, vc_root, to_win):
        self.vc_root = vc_root
        self.to_win = to_win
        self.lab = LabPipe(vc_root)
        self.lease = None          # имя аренды
        self.play = None           # id сеанса final-check
        self.log_path = os.path.join(vc_root, "latest.log")
        self.info_cache = (0.0, None)

    # ------------------------------------------------------------------ состояние
    def adopt(self):
        """После рестарта сервера MCP: своя живая аренда vc.* этого владельца — снова наша (не чужие процессы)."""
        if self.lease:
            return self.lease
        r = self.lab.get("/leases")
        for l in r.get("leases") or []:
            p = l.get("proc") or {}
            if l.get("project") == self.PROJECT and l.get("owner") == self.lab.owner and p.get("alive"):
                self.lease = l["name"]
                self.play = None if l["kind"] == "dev" else (l.get("run") or "final-check")
                self._log_from(l)
                return self.lease
        return None

    def _log_from(self, l):
        d = (l.get("params") or {}).get("dir")
        if d:
            self.log_path = d if d.startswith("/") else _wsl(d)
            self.log_path = os.path.join(self.log_path, "latest.log")

    def info(self, fresh=False):
        if not self.adopt():
            return None
        t, inf = self.info_cache
        if not fresh and inf is not None and time.time() - t < 1.0:
            return inf
        r = self.lab.get("/leases/%s" % self.lease)
        if not r.get("ok"):
            self.lease, self.play = None, None
            return None
        self.info_cache = (time.time(), r["lease"])
        return r["lease"]

    def pid(self):
        l = self.info()
        p = (l or {}).get("proc") or {}
        return p.get("pid") if p.get("alive") else None

    def renew(self):
        if self.lease:
            try:
                self.lab.post("/leases/%s/renew" % self.lease, {})
            except Exception:
                pass

    def foreign(self):
        r = self.lab.get("/leases")
        return r.get("foreign") or []

    # ------------------------------------------------------------------ старт / стоп
    def start(self, script=None, extra=None, play=False, reason=None, engine_exe=None, size=None):
        extra = list(extra or [])
        d, res = None, None
        out = []
        i = 0
        while i < len(extra):                    # --dir / --res из args — параметры аренды (как раньше у exe)
            if extra[i] in ("--dir", "--res") and i + 1 < len(extra):
                if extra[i] == "--dir":
                    d = extra[i + 1]
                else:
                    res = extra[i + 1]
                i += 2
                continue
            out.append(extra[i])
            i += 1
        extra = out
        d_wsl = _wsl(d) if d else self.vc_root
        d_win = d if d and not d.startswith("/") else self.to_win(d_wsl)
        autorun = os.path.join(d_wsl, "autorun_app_script.txt")
        if script is not None:
            with open(autorun, "w", encoding="utf-8") as f:
                f.write(script.strip())
        elif os.path.exists(autorun):
            os.remove(autorun)
        self.log_path = os.path.join(d_wsl, "latest.log")
        if play:
            params = {"runtime.dir": d_win, "runtime.extra": extra}
            r = self.lab.post("/call/core.play", {"args": {"project": self.PROJECT, "action": "start",
                                                           "final_check": True, "reason": reason, "params": params}},
                              timeout=300)
            if not r.get("ok"):
                return r
            sess = r["result"]
            self.play = sess.get("id")
            self.lease = (sess.get("leases") or {}).get("runtime")
            return {"ok": True, "lease": self.lease, "session": self.play, "mode": "final-check",
                    "procs": sess.get("procs")}
        params = {"dir": d_win, "extra": extra}
        if res:
            params["res"] = res if not res.startswith("/") else self.to_win(res)
        if engine_exe:
            params["engine_exe"] = engine_exe if not engine_exe.startswith("/") else self.to_win(engine_exe)
        if size:
            params["extra"] = params["extra"] + ["--f2f-size", size]
        r = self.lab.post("/leases", {"project": self.PROJECT, "kind": "dev", "ttl": 3600, "params": params,
                                      "start": True}, timeout=300)
        lease = (r.get("lease") or {}).get("name") if isinstance(r.get("lease"), dict) else r.get("lease")
        if r.get("ok"):
            self.lease, self.play = r["lease"]["name"], None
        elif lease:
            try:                                     # аренда осталась в состоянии failed — снять, чтобы не висела
                self.lab.post("/leases/%s/release" % lease, {})
            except Exception:
                pass
        return r

    def stop(self):
        if not self.adopt():
            return {"ok": True, "message": "no vc_start instance of %s" % self.lab.owner}
        name = self.lease
        if self.play:
            r = self.lab.post("/call/core.play", {"args": {"project": self.PROJECT, "action": "stop"}}, timeout=120)
        else:
            r = self.lab.post("/leases/%s/release" % name, {}, timeout=120)
        self.lease, self.play = None, None
        self.info_cache = (0.0, None)
        return dict(r, lease=name)

    # ------------------------------------------------------------------ F2F
    def f2f(self, cmd, args=None, timeout=60.0):
        if not self.adopt():
            raise RuntimeError("no vc_start instance (vc_start first)")
        if self.play:
            raise RuntimeError("the final-check runtime is the stock exe: no F2F port, no input (it is the user's)")
        return self.lab.post("/f2f/%s" % self.lease, {"cmd": cmd, "args": args or {}, "timeout": timeout},
                             timeout=timeout + 10)


def _wsl(p):
    if p.startswith("/"):
        return p
    p = p.replace("\\", "/")
    if len(p) > 1 and p[1] == ":":
        return "/mnt/%s%s" % (p[0].lower(), p[2:])
    return p


# ---------------------------------------------------------------------------------------------- клавиши vc_keys -> F2F
KEY_ALIASES = {"esc": "escape", "ctrl": "left-ctrl", "lctrl": "left-ctrl", "rctrl": "right-ctrl",
               "shift": "left-shift", "lshift": "left-shift", "rshift": "right-shift", "alt": "left-alt",
               "lalt": "left-alt", "ralt": "right-alt", "grave": "grave-accent", "equal": "equal",
               "pgup": "page-up", "pgdn": "page-down"}


def key_name(tok):
    t = tok.strip().lower()
    return KEY_ALIASES.get(t, t)


def sequence_to_f2f(seq, tap_ms=60):
    """Синтаксис vc_keys ('enter', 'up:1500', 'ctrl+up:800', 'wait:500', 'text:iddqd', 'wheelup', 'wheeldown:3')
    -> список действий [("input", args) | ("sleep", s)]. Имена — движка (escape, left-shift, a, f1) или LWJGL."""
    acts = []
    for tok in seq.split():
        name, _, arg = tok.partition(":")
        low = name.lower()
        if low == "wait":
            acts.append(("sleep", float(arg or 0) / 1000.0))
        elif low == "text":
            acts.append(("input", {"chars": arg}))
            acts.append(("sleep", tap_ms / 1000.0))
        elif low in ("wheelup", "wheeldown"):
            n = int(arg or 1)
            acts.append(("input", {"mouse": {"wheel": n if low == "wheelup" else -n}}))
            acts.append(("sleep", tap_ms / 1000.0))
        else:
            keys = [key_name(k) for k in name.split("+")]
            hold = float(arg) / 1000.0 if arg else tap_ms / 1000.0
            acts.append(("input", {"keys": {k: True for k in keys}}))
            acts.append(("sleep", hold))
            acts.append(("input", {"keys": {k: False for k in keys}}))
            acts.append(("sleep", tap_ms / 1000.0))
    return acts
