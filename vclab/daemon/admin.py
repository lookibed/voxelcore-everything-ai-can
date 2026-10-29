"""Этап 5: роли, drain, изолированный демон, аудит, горячая перезагрузка ядра (README «Этап 5»).

02.10 субагент сделал `lab daemon restart` ради своей правки ядра, пока у другого агента было 5 живых аренд: Job Objects
убили чужую сессию. Теперь это решает сам демон, а не слова в заданиях:

* Роли. Владелец (`X-Lab-Owner`) из `[roles].admins` (по умолчанию `user`, `claude`) — `admin`, остальные — `agent`.
  Заголовок `X-Lab-Role: agent` (`LAB_ROLE=agent`, `lab --as-agent`, `as_agent` в мосте) только понижает роль.
  Операции уровня демона (stop/restart/upgrade/drain/undrain/reload-core, `release --all --force`, `gate accept`,
  `golden promote`) — только `admin`; агент получает 403 `admin-required` («ask the main session»). На изолированном
  демоне права уровня демона есть и у того, кто его поднял (`starter`), — кроме `golden promote` (golden общий).
* Эвристика: немедленная операция (stop, restart, reload-core), когда хоть одна аренда (или задание) принадлежит
  другому владельцу, — отказ 409 `foreign-leases` при любой роли; `--force` — только admin. Живые аренды при
  stop/restart — отказ 409 `live-leases` с подсказкой `lab daemon drain`/`upgrade`.
* Drain: новые аренды/прогоны — 503 `draining`; ждём, пока кончатся аренды, задания и сеансы play (release или TTL),
  потом выполняем отложенное действие (restart / upgrade / stop) сами; таймаут — отмена, демон снова обслуживает.
* Перезапуск без вызывающего: новый labd поднимается через WMI (вне Job Object) с теми же аргументами и
  `--after-pid <старый pid>` (ждёт выхода старого), старый выходит.
* Аудит: `<data>\\audit.jsonl` — каждое действие уровня демона, в том числе отказы: кто, когда, что, итог, аренды.
* Версия кода: sha256 файлов демона (vclab/**/*.py без клиентских) при старте и после reload-core против
  файлов на диске — `lab daemon status` показывает устаревший демон и какие файлы можно перезагрузить без рестарта.
"""
import hashlib
import importlib
import importlib.util
import json
import os
import sys
import threading
import time
import traceback

from vclab import config

VCLAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))     # ...\vclab
# модули из чистых функций: importlib.reload на живом демоне безопасен (состояние — в БД/файлах; экземпляры
# History/Golden получают новый класс). Порядок — зависимости раньше.
SAFE_RELOAD = ("sysload", "compare", "gate", "dashboard", "history", "golden")
# полные имена модулей безопасного набора (пакет vclab разложен по подпакетам; раньше — плоский labcore.<имя>)
MODULES = {"sysload": "vclab.quality.sysload", "compare": "vclab.quality.compare", "gate": "vclab.quality.gate",
           "dashboard": "vclab.dashboard", "history": "vclab.quality.history", "golden": "vclab.quality.golden"}
# только CLI/мост: правка не требует ни рестарта, ни reload (раньше: client.py, cli2b.py, cli_sup.py в labcore)
CLIENT_ONLY = ("vclab/daemon/client.py",)
CLIENT_ONLY_DIRS = ("vclab/cli/", "vclab/mcp/")
DEFAULT_ADMINS = ("user", "claude")
ISOLATED_PORTS = (25800, 25849)                   # порты изолированных демонов
ISOLATED_LEASE_BASE = 25850                       # аренды изолированного демона P: 25850 + 10*(P-25800) .. +9
DRAIN_TIMEOUT = 3600.0
THEN = (None, "restart", "upgrade", "stop")


def isolated_lease_ports(port):
    i = int(port) - ISOLATED_PORTS[0]
    a = ISOLATED_LEASE_BASE + 10 * i
    return a, a + 9


def isolated_data(port):
    return os.path.join(config.WORK_ROOT, "lab", "isolated", str(int(port)))


# ------------------------------------------------------------------------------------------------ версия кода
def code_files():
    """Файлы, которые исполняет демон: vclab/**/*.py (без чисто клиентских: vclab/cli, vclab/mcp, daemon/client.py)."""
    out = {}
    for d, dirs, files in os.walk(VCLAB):
        dirs[:] = sorted(x for x in dirs if x != "__pycache__")
        for fn in sorted(files):
            if not fn.endswith(".py"):
                continue
            path = os.path.join(d, fn)
            rel = "vclab/" + os.path.relpath(path, VCLAB).replace(os.sep, "/")
            if rel in CLIENT_ONLY or rel.startswith(CLIENT_ONLY_DIRS):
                continue
            out[rel] = path
    return out


def file_hashes():
    out = {}
    for rel, path in code_files().items():
        try:
            with open(path, "rb") as f:
                out[rel] = hashlib.sha256(f.read()).hexdigest()[:16]
        except OSError:
            out[rel] = None
    return out


def combined(hashes):
    h = hashlib.sha256()
    for k in sorted(hashes):
        h.update(("%s:%s\n" % (k, hashes[k])).encode())
    return h.hexdigest()[:12]


def classify(rel):
    name = os.path.splitext(os.path.basename(rel))[0]
    if name in SAFE_RELOAD and rel == MODULES[name].replace(".", "/") + ".py":
        return "reloadable"
    return "restart-only"


def diff_hashes(loaded, disk):
    """-> {reloadable: [...], restart_only: [...]} — файлы, которые на диске не те, что исполняет демон."""
    out = {"reloadable": [], "restart_only": []}
    for rel in sorted(set(loaded) | set(disk)):
        if loaded.get(rel) != disk.get(rel):
            out["reloadable" if classify(rel) == "reloadable" else "restart_only"].append(rel)
    return out


# ------------------------------------------------------------------------------------------------ аудит
class Audit:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        os.makedirs(os.path.dirname(path), exist_ok=True)

    def write(self, entry):
        e = dict(entry)
        e.setdefault("t", time.time())
        e.setdefault("at", time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e["t"])))
        line = json.dumps(e, ensure_ascii=False, default=str)
        with self.lock:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        return e

    def tail(self, n=30):
        return read_audit(self.path, n)


def read_audit(path, n=30):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return []
    out = []
    for ln in lines[-int(n):] if n else lines:
        try:
            out.append(json.loads(ln))
        except ValueError:
            pass
    return out


# ------------------------------------------------------------------------------------------------ управление демоном
class DaemonControl:
    def __init__(self, lab):
        from vclab.daemon.service import LabError
        self.LabError = LabError
        self.lab = lab
        d = lab.cfg["daemon"]
        self.port = d.get("port")
        self.isolated = bool(d.get("isolated"))
        self.starter = d.get("starter")
        self.argv = list(d.get("argv") or [])
        self.admins = list((lab.cfg.get("roles") or {}).get("admins") or DEFAULT_ADMINS)
        self.audit = Audit(os.path.join(lab.data, "audit.jsonl"))
        self.loaded = file_hashes()
        self.reloaded = {}                    # модуль -> время последнего reload-core
        self.lock = threading.RLock()
        self.state = "serving"                # serving | draining | drained | exiting
        self.drain = None
        self._drain_seq = 0
        self.exit_fn = self._exit_process     # тесты в процессе подменяют (без настоящего выхода)
        self.respawn_fn = self._respawn_process
        self.version_path = os.path.join(lab.data, "state", "daemon.json")
        self._record_start()

    # ---------------------------------------------------------------- роли
    def role(self, owner, role_hdr=None):
        if str(role_hdr or "").lower() == "agent":
            return "agent"
        return "admin" if owner in self.admins else "agent"

    def daemon_rights(self, owner, role_hdr=None):
        """Права уровня демона: admin; на изолированном демоне — ещё и тот, кто его поднял."""
        if self.role(owner, role_hdr) == "admin":
            return "admin"
        if self.isolated and owner and owner == self.starter:
            return "starter"
        return None

    # ---------------------------------------------------------------- снимок занятости
    def lease_snapshot(self):
        with self.lab.lock:
            ls = list(self.lab.leases.values())
        out = []
        for l in ls:
            live = bool((l.proc is not None and l.proc.alive()) or l.state == "starting")
            out.append({"name": l.name, "owner": l.owner, "state": l.state, "live": live})
        return out

    def running_jobs(self):
        try:
            return [{"id": j.get("id"), "owner": j.get("owner")} for j in self.lab.scen.list()
                    if j.get("state") == "running"]
        except Exception:
            return []

    def play_sessions(self):
        play = getattr(self.lab, "play", None)
        if play is None:
            return []
        try:
            return [{"id": s.get("id"), "owner": s.get("owner"), "state": s.get("state")} for s in play.list()
                    if s.get("state") in ("starting", "running", "finishing")]
        except Exception:
            return []

    def busy(self):
        """Что держит drain: аренды (любые, не только живые: владелец может снова их запустить), задания, сеансы."""
        out = ["lease %s (%s, %s%s)" % (l["name"], l["owner"], l["state"], ", live" if l["live"] else "")
               for l in self.lease_snapshot()]
        out += ["job %s (%s)" % (j["id"], j["owner"]) for j in self.running_jobs()]
        out += ["play %s (%s, %s)" % (s["id"], s["owner"], s["state"]) for s in self.play_sessions()]
        return out

    # ---------------------------------------------------------------- проверки
    def _entry(self, action, owner, role_hdr, via=None, force=False, reason=None, **extra):
        snap = self.lease_snapshot()
        e = {"port": self.port, "pid": os.getpid(), "isolated": self.isolated, "action": action, "owner": owner,
             "role": self.role(owner, role_hdr), "role_hdr": role_hdr, "via": via, "force": bool(force),
             "reason": reason, "state": self.state, "code_hash": combined(self.loaded),
             "leases": ["%s (%s, %s%s)" % (l["name"], l["owner"], l["state"], ", live" if l["live"] else "")
                        for l in snap],
             "live": sum(1 for l in snap if l["live"]), "jobs": [j["id"] for j in self.running_jobs()]}
        e.update(extra)
        return e, snap

    def _refuse(self, e, code, message, **extra):
        e.update(result="refused", error=code, message=message)
        self.audit.write(e)
        raise self.LabError(code, message, audit=True, **extra)

    def guard(self, action, owner, role_hdr=None, via=None, force=False, reason=None, scope="daemon",
              check_others=False, check_live=False, **extra):
        """Роль + эвристика + живые аренды. -> запись аудита (без итога); отказ — LabError с записью аудита."""
        e, snap = self._entry(action, owner, role_hdr, via, force, reason, **extra)
        rights = "admin" if self.role(owner, role_hdr) == "admin" else (
            self.daemon_rights(owner, role_hdr) if scope == "daemon" else None)
        e["rights"] = rights
        if not rights:
            why = "agent" if owner in self.admins else "agent (owner %r is not in [roles].admins %s)" % (
                owner, self.admins)
            self._refuse(e, "admin-required", "%s is a daemon-level operation: admin only; caller %r is %s — ask the "
                         "main session (claude) or the user" % (action, owner, why))
        if force and rights not in ("admin", "starter"):
            self._refuse(e, "admin-required", "--force is admin only")
        if check_others:
            others = ["%s (%s, %s)" % (l["name"], l["owner"], l["state"]) for l in snap
                      if l["owner"] and l["owner"] != owner]
            others += ["job %s (%s)" % (j["id"], j["owner"]) for j in self.running_jobs()
                       if j["owner"] and j["owner"] != owner]
            if others and not force:
                self._refuse(e, "foreign-leases", "%s refused: %d lease(s)/job(s) of other owners: %s. Their session "
                             "would break. Use `lab daemon drain`/`lab daemon upgrade` (waits for them), or ask the "
                             "user; --force is admin only" % (action, len(others), ", ".join(others)), others=others)
        if check_live:
            live = ["%s (%s, %s)" % (l["name"], l["owner"], l["state"]) for l in snap if l["live"]]
            if live and not force:
                self._refuse(e, "live-leases", "%s refused: %d live lease(s) would be killed with the daemon (Job "
                             "Objects): %s. Use `lab daemon drain --then %s` or `lab daemon upgrade` (waits for the "
                             "leases to end)" % (action, len(live), ", ".join(live),
                                                 "stop" if action == "daemon.stop" else "restart"), live=live)
        return e

    def done(self, e, result="ok", **extra):
        e = dict(e, result=result, **extra)
        self.audit.write(e)
        return e

    # ---------------------------------------------------------------- данные (ворота, golden, release --all)
    def require(self, action, owner, role_hdr=None, via=None, scope="daemon", **extra):
        """Админ-операция без эвристики аренд (gate accept, golden promote, release --all --force): роль + аудит."""
        e = self.guard(action, owner, role_hdr, via=via, scope=scope, **extra)
        return self.done(e, result="allowed")

    # ---------------------------------------------------------------- drain
    def lease_allowed(self):
        """None — можно; иначе текст отказа. Во время drain: только задания, начатые до drain (свои внутренние аренды)."""
        with self.lock:
            if self.state == "serving":
                return None
            d = self.drain or {}
            cur = threading.current_thread()
            try:
                for jid in d.get("jobs_at_start") or ():
                    j = self.lab.scen.jobs.get(jid)
                    if j is not None and j.get("thread") is cur:
                        return None
            except Exception:
                pass
            return "daemon is %s (by %s%s): no new leases; retry after `lab daemon undrain` or the restart" % (
                self.state, d.get("by"), ", then %s" % d["then"] if d.get("then") else "")

    def check_new_work(self):
        msg = self.lease_allowed()
        if msg:
            raise self.LabError("draining", msg, drain=self.drain_info())

    def drain_info(self):
        with self.lock:
            if not self.drain:
                return None
            d = {k: v for k, v in self.drain.items() if k not in ("seq",)}
        d["waiting_for"] = self.busy()
        d["elapsed_s"] = round(time.time() - d["since"], 1)
        if d.get("deadline"):
            d["left_s"] = round(d["deadline"] - time.time(), 1)
        return d

    def start_drain(self, owner, role_hdr=None, via=None, timeout=None, then=None, reason=None, action="daemon.drain"):
        if then not in THEN:
            raise self.LabError("bad-request", "then: one of restart, upgrade, stop (or none)")
        e = self.guard(action, owner, role_hdr, via=via, reason=reason, then=then, timeout=timeout)
        with self.lock:
            if self.state in ("draining", "exiting"):
                d = self.drain or {}
                self.done(e, result="refused", error="busy", message="already %s" % self.state)
                raise self.LabError("busy", "daemon is already %s (by %s, then %s)" % (self.state, d.get("by"),
                                                                                     d.get("then")))
            timeout = DRAIN_TIMEOUT if timeout is None else float(timeout)
            self._drain_seq += 1
            self.drain = {"seq": self._drain_seq, "by": owner, "since": time.time(), "then": then, "reason": reason,
                          "timeout": timeout, "deadline": (time.time() + timeout) if timeout > 0 else None,
                          "jobs_at_start": [j["id"] for j in self.running_jobs()]}
            self.state = "draining"
            seq = self._drain_seq
        self.done(e, result="draining", waiting_for=self.busy())
        self.lab.journal.event("lab.drain", "by %s, then %s, timeout %s s" % (owner, then, timeout), agent=owner)
        threading.Thread(target=self._drain_loop, args=(seq,), name="drain", daemon=True).start()
        return {"ok": True, "state": self.state, "drain": self.drain_info()}

    def _drain_loop(self, seq):
        while True:
            with self.lock:
                if self.state != "draining" or not self.drain or self.drain["seq"] != seq:
                    return
                d = dict(self.drain)
            busy = self.busy()
            if not busy:
                with self.lock:
                    if self.state != "draining" or self.drain["seq"] != seq:
                        return
                    self.state = "drained"
                    self.drain["drained_at"] = time.time()
                self.audit.write({"port": self.port, "pid": os.getpid(), "action": "daemon.drain.complete",
                                  "owner": d["by"], "result": "drained", "then": d["then"],
                                  "waited_s": round(time.time() - d["since"], 1), "code_hash": combined(self.loaded)})
                if d["then"]:
                    try:
                        self._perform(d["then"], d["by"], d.get("reason"), drained=True)
                    except Exception as exc:
                        self.audit.write({"port": self.port, "action": "daemon.%s" % d["then"], "owner": d["by"],
                                          "result": "error", "message": "%s: %s" % (type(exc).__name__, exc)})
                        with self.lock:
                            self.state, self.drain = "serving", None
                return
            if d.get("deadline") and time.time() > d["deadline"]:
                with self.lock:
                    if self.drain and self.drain["seq"] == seq:
                        self.state, self.drain = "serving", None
                self.audit.write({"port": self.port, "pid": os.getpid(), "action": "daemon.drain.timeout",
                                  "owner": d["by"], "result": "timeout", "then": d["then"], "waiting_for": busy,
                                  "message": "drain timed out after %.0f s: action %s NOT performed, serving again"
                                             % (d["timeout"], d["then"])})
                self.lab.journal.event("lab.drain_timeout", "; ".join(busy)[:300], error=True, agent=d["by"])
                return
            time.sleep(0.5)

    def undrain(self, owner, role_hdr=None, via=None, reason=None):
        e = self.guard("daemon.undrain", owner, role_hdr, via=via, reason=reason)
        with self.lock:
            was = self.state
            if was == "exiting":
                self.done(e, result="refused", error="busy", message="exiting")
                raise self.LabError("busy", "daemon is already exiting")
            self.state, self.drain = "serving", None
        self.done(e, result="ok", was=was)
        return {"ok": True, "state": "serving", "was": was}

    # ---------------------------------------------------------------- немедленные действия
    def stop(self, owner, role_hdr=None, via=None, force=False, reason=None):
        e = self.guard("daemon.stop", owner, role_hdr, via=via, force=force, reason=reason, check_others=True,
                       check_live=True)
        self.done(e, result="ok")
        return self._perform("stop", owner, reason, audit=False)

    def restart(self, owner, role_hdr=None, via=None, force=False, reason=None):
        e = self.guard("daemon.restart", owner, role_hdr, via=via, force=force, reason=reason, check_others=True,
                       check_live=True)
        self.done(e, result="ok")
        return self._perform("restart", owner, reason, audit=False)

    def upgrade(self, owner, role_hdr=None, via=None, timeout=None, reason=None, force=False):
        """drain + рестарт на код с диска. Нет аренд — сразу; иначе — очередь (drain), отвечает сразу."""
        if force:
            e = self.guard("daemon.upgrade", owner, role_hdr, via=via, force=True, reason=reason, check_others=True,
                           check_live=True)
            self.done(e, result="ok", forced=True)
            return self._perform("upgrade", owner, reason, audit=False)
        r = self.start_drain(owner, role_hdr, via=via, timeout=timeout, then="upgrade", reason=reason,
                             action="daemon.upgrade")
        r["queued"] = bool(r["drain"]["waiting_for"])
        return r

    def _perform(self, what, owner, reason=None, audit=True, drained=False):
        disk = file_hashes()
        info = {"action": "daemon.%s.perform" % what, "owner": owner, "reason": reason, "port": self.port,
                "pid": os.getpid(), "from_hash": combined(self.loaded), "to_hash": combined(disk),
                "drained": drained}
        with self.lock:
            self.state = "exiting"
        if what in ("restart", "upgrade"):
            self._write_version({"pending": {"action": what, "by": owner, "at": time.time(),
                                             "from_hash": info["from_hash"], "to_hash": info["to_hash"],
                                             "reason": reason}})
            try:
                info["respawn"] = self.respawn_fn()
            except Exception as exc:
                with self.lock:
                    self.state = "serving"
                self.audit.write(dict(info, result="error", message="respawn failed: %s: %s" % (
                    type(exc).__name__, exc)))
                raise self.LabError("start-failed", "respawn failed: %s" % exc)
        self.audit.write(dict(info, result="exiting"))
        self.lab.journal.event("lab.daemon_" + what, "by %s: %s -> %s" % (owner, info["from_hash"], info["to_hash"]),
                               agent=owner)
        self.exit_fn(what)
        return {"ok": True, "action": what, "from_hash": info["from_hash"], "to_hash": info["to_hash"],
                "respawn": info.get("respawn"), "message": "labd exits%s" % (
                    "; the new daemon starts after this pid exits" if what != "stop" else "")}

    def _exit_process(self, what):
        def bye():
            time.sleep(0.4)
            try:
                self.lab.shutdown()
            finally:
                os._exit(0)
        threading.Thread(target=bye, name="exit", daemon=True).start()

    def _respawn_process(self):
        """Новый labd через WMI (вне Job Object): те же аргументы + --after-pid (ждёт выхода этого процесса)."""
        from vclab.cli import labctl as labctl
        exe = sys.executable
        cmd = '"%s" -X utf8 -B "%s"' % (exe, os.path.join(config.BIN_DIR, "labd.py"))
        cmd += "".join(' "%s"' % a for a in self.argv)
        cmd += " --after-pid %d" % os.getpid()
        pid = labctl._wmi_create(cmd, config.REPO_ROOT)
        return {"wmi_pid": pid, "cmdline": cmd}

    # ---------------------------------------------------------------- версия
    def _read_version(self):
        try:
            with open(self.version_path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def _write_version(self, upd):
        v = self._read_version()
        v.update(upd)
        tmp = self.version_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(v, f, ensure_ascii=False, indent=1)
        os.replace(tmp, self.version_path)

    def _record_start(self):
        v = self._read_version()
        pend = v.pop("pending", None)
        h = combined(self.loaded)
        rec = {"pid": os.getpid(), "started": time.time(), "code_hash": h, "via": (pend or {}).get("action") or
               "start", "by": (pend or {}).get("by"), "prev_hash": (v.get("current") or {}).get("code_hash"),
               "after_pid": self.lab.cfg["daemon"].get("after_pid")}
        hist = (v.get("history") or [])[-49:] + [rec]
        v.update(current=dict(rec, files=self.loaded), history=hist)
        v.pop("pending", None)
        try:
            os.makedirs(os.path.dirname(self.version_path), exist_ok=True)
            tmp = self.version_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(v, f, ensure_ascii=False, indent=1)
            os.replace(tmp, self.version_path)
        except OSError:
            pass
        self.audit.write({"port": self.port, "pid": os.getpid(), "action": "daemon.start", "owner": rec["by"],
                          "result": "ok", "via": rec["via"], "code_hash": h, "prev_hash": rec["prev_hash"],
                          "isolated": self.isolated, "starter": self.starter, "after_pid": rec["after_pid"],
                          "data": self.lab.data})

    # ---------------------------------------------------------------- reload-core
    def reload_core(self, owner, role_hdr=None, via=None, force=False, reason=None, modules=None):
        e = self.guard("daemon.reload-core", owner, role_hdr, via=via, force=force, reason=reason, check_others=True)
        names = list(modules or SAFE_RELOAD)
        bad = [m for m in names if m not in SAFE_RELOAD]
        if bad:
            self.done(e, result="refused", error="bad-request", message="not reloadable: %s" % bad)
            raise self.LabError("bad-request", "not reloadable (restart-only): %s; safe set: %s" % (
                ", ".join(bad), ", ".join(SAFE_RELOAD)))
        names = [m for m in SAFE_RELOAD if m in names]
        res = reload_modules(names, self.lab)
        if res["ok"]:
            for m in res["reloaded"]:
                rel = MODULES[m].replace(".", "/") + ".py"
                self.loaded[rel] = res["hashes"].get(rel, self.loaded.get(rel))
                self.reloaded[m] = time.time()
        disk = file_hashes()
        res.pop("hashes", None)
        res["stale_after"] = diff_hashes(self.loaded, disk)
        res["code_hash"] = combined(self.loaded)
        self.done(e, result="ok" if res["ok"] else "error", reloaded=res.get("reloaded"),
                  unchanged=res.get("unchanged"), error=res.get("error"), notes=res.get("notes"))
        return res

    # ---------------------------------------------------------------- состояние
    def info(self):
        disk = file_hashes()
        stale = diff_hashes(self.loaded, disk)
        v = self._read_version()
        return {"ok": True, "port": self.port, "pid": os.getpid(), "isolated": self.isolated, "starter": self.starter,
                "state": self.state, "drain": self.drain_info(), "admins": self.admins, "data": self.lab.data,
                "audit": self.audit.path, "code_hash": combined(self.loaded), "disk_hash": combined(disk),
                "stale": bool(stale["reloadable"] or stale["restart_only"]), "stale_files": stale,
                "reloaded": self.reloaded, "safe_reload": list(SAFE_RELOAD), "argv": self.argv,
                "started": self.lab.started, "history": (v.get("history") or [])[-5:],
                "leases": self.lease_snapshot(), "jobs": self.running_jobs()}

    def summary(self):
        return {"port": self.port, "isolated": self.isolated, "starter": self.starter, "state": self.state,
                "drain": self.drain_info(), "code_hash": combined(self.loaded)}


# ------------------------------------------------------------------------------------------------ reload
def _source_path(name):
    """Исходник модуля безопасного набора (тест подменяет функцию, раньше — переменную LABCORE)."""
    return os.path.join(os.path.dirname(VCLAB), *MODULES[name].split(".")) + ".py"


def _validate(name):
    """Исполнить исходник модуля в отдельном объекте (не в sys.modules): синтаксис и импорт до настоящего reload."""
    full = MODULES[name]
    path = _source_path(name)
    spec = importlib.util.spec_from_file_location(full, path)
    mod = importlib.util.module_from_spec(spec)
    mod.__package__ = full.rsplit(".", 1)[0]
    spec.loader.exec_module(mod)
    return mod


def reload_modules(names, lab=None):
    """Проверить все модули, потом importlib.reload по порядку; экземпляры lab.history / lab.golden — на новый класс.
    Замыкания, созданные при старте (history.install_core: функции возможностей core.*), остаются прежними; они
    вызывают модульные функции через объект модуля, поэтому видят новый код. Изменилась сама install_core — notes."""
    hashes = file_hashes()
    out = {"ok": True, "reloaded": [], "unchanged": [], "notes": [], "hashes": hashes}
    for n in names:
        try:
            _validate(n)
        except Exception as exc:
            out.update(ok=False, error="validate %s: %s: %s" % (n, type(exc).__name__, exc),
                       trace=traceback.format_exc(limit=4))
            return out
    for n in names:
        full = MODULES[n]
        mod = sys.modules.get(full)
        if mod is None:
            out["unchanged"].append(n)            # ещё не импортирован демоном: загрузится свежим при первом import
            continue
        old_install = getattr(mod, "install_core", None)
        old_code = _code_sig(old_install)
        try:
            mod = importlib.reload(mod)
        except Exception as exc:
            out.update(ok=False, error="reload %s: %s: %s (module may be half-updated: restart the daemon)" % (
                n, type(exc).__name__, exc), trace=traceback.format_exc(limit=4))
            return out
        out["reloaded"].append(n)
        if old_code is not None and _code_sig(getattr(mod, "install_core", None)) != old_code:
            out["notes"].append("%s.install_core changed: feature closures created at start keep the old code until "
                                "a restart (lab daemon upgrade)" % n)
    if lab is not None:
        for attr, mname, cls in (("history", "history", "History"), ("golden", "golden", "Golden")):
            obj = getattr(lab, attr, None)
            m = sys.modules.get(MODULES[mname])
            if obj is not None and m is not None and mname in out["reloaded"]:
                try:
                    obj.__class__ = getattr(m, cls)
                    out["notes"].append("lab.%s -> new class %s.%s" % (attr, mname, cls))
                except Exception as exc:
                    out["notes"].append("lab.%s: class swap failed (%s): restart needed" % (attr, exc))
    return out


def _code_sig(fn):
    """Байт-код функции и вложенных (без номеров строк): изменилась ли install_core по сути."""
    code = getattr(fn, "__code__", None)
    if code is None:
        return None
    h = hashlib.sha256()

    def walk(c):
        h.update(c.co_code)
        h.update(repr(c.co_names).encode())
        for k in c.co_consts:
            if hasattr(k, "co_code"):
                walk(k)
            else:
                h.update(repr(k).encode())
    walk(code)
    return h.hexdigest()
