"""labctl — управление демоном labd (`lab daemon ...` вызывает его же).

  labctl.py start [--isolated] [--port P]           изолированный: порт 25800–25849, data artifacts\\lab\\isolated\\<P>
  labctl.py status | list                            код демона против файлов на диске (stale), drain, роль; list — изолированные
  labctl.py stop|restart [--force] [--reason R]      admin; отказ при живых/чужих арендах (подсказка: drain/upgrade)
  labctl.py drain [--timeout S] [--then restart|upgrade|stop] | undrain
  labctl.py upgrade [--timeout S] [--wait] [--reason R]   drain + рестарт на код с диска (admin)
  labctl.py reload-core [--module m ...] [--force]   горячая перезагрузка безопасных модулей (admin)
  labctl.py audit [--last N]                         artifacts\\lab\\audit.jsonl
  общие: --port P (= --daemon P, LAB_PORT), --owner X (LAB_OWNER), --as-agent (LAB_ROLE=agent)
Решения принимает демон (vclab/daemon/admin.py, этап 5); прежний демон без /daemon/* — запасной путь на стороне клиента:
та же проверка роли, отказ при любой аренде, запись аудита в <data>\\audit.jsonl.
start — если не отвечает: pythonw.exe labd.py через WMI Win32_Process.Create (процесс вне Job Object вызывающего,
без унаследованных дескрипторов: вызов из WSL/моста возвращается сразу, демон переживает мост и сессию Claude).
Окна консоли нет; лог — <data>\\labd.log. PowerShell не нужен."""
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if REPO not in sys.path:
    sys.path.insert(0, REPO)
HERE = os.path.dirname(os.path.abspath(__file__))
from vclab.daemon.client import LabClient  # noqa: E402


def _wmi_create(cmdline, cwd):
    import pythoncom
    import win32com.client
    pythoncom.CoInitialize()
    try:
        wmi = win32com.client.GetObject("winmgmts:\\\\.\\root\\cimv2")
        proc = wmi.Get("Win32_Process")
        startup = wmi.Get("Win32_ProcessStartup").SpawnInstance_()
        startup.ShowWindow = 0
        params = proc.Methods_("Create").InParameters.SpawnInstance_()
        params.CommandLine = cmdline
        params.CurrentDirectory = cwd
        params.ProcessStartupInformation = startup
        out = proc.ExecMethod_("Create", params)
        rv, pid = int(out.ReturnValue), int(out.ProcessId)
        del out, params, startup, proc, wmi      # COM-ссылки отпустить до CoUninitialize (иначе шум «releasing IUnknown»)
        if rv != 0:
            raise RuntimeError("Win32_Process.Create failed: %s" % rv)
        return pid
    finally:
        import gc
        gc.collect()
        pythoncom.CoUninitialize()


def start(port=None, wait=20.0, extra=(), owner=None):
    """extra — доп. аргументы labd.py (--data, --ports, --projects, --no-watch): тесты поднимают отдельный демон."""
    c = LabClient(port, owner=owner)
    h = c.alive()
    if h:
        return {"ok": True, "already": True, "pid": h["pid"], "port": c.port, "isolated": h.get("isolated")}
    exe = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    if not os.path.exists(exe):
        exe = sys.executable
    from vclab import config
    cmd = '"%s" -X utf8 -B "%s" --port %d' % (exe, os.path.join(config.BIN_DIR, "labd.py"), c.port)
    cmd += "".join(' "%s"' % a for a in extra)
    t0 = time.time()
    pid = _wmi_create(cmd, config.REPO_ROOT)
    while time.time() - t0 < wait:
        h = c.alive(0.5)
        if h:
            return {"ok": True, "pid": h["pid"], "port": c.port, "started_s": round(time.time() - t0, 2)}
        time.sleep(0.1)
    return {"ok": False, "error": "labd did not answer in %.0f s (wmi pid %d); see <data>\\labd.log" % (wait, pid)}


LIVE_STATES = ("leased", "starting", "ready")


def _cfg():
    from vclab import config
    return config.load()


def shared_port():
    try:
        return int(_cfg()["daemon"]["port"])
    except Exception:
        return 25700


def live_leases(c):
    """Аренды с живыми процессами (KILL_ON_JOB_CLOSE: остановка демона убивает их деревья)."""
    try:
        r = c.get("/leases")
    except Exception:
        return []
    out = []
    for l in r.get("leases", []):
        p = l.get("proc") or {}
        if p.get("alive") or l.get("state") in ("starting",):
            out.append("%s (%s, %s)" % (l.get("name"), l.get("owner"), l.get("state")))
    return out


def all_leases(c):
    try:
        return ["%s (%s, %s)" % (l.get("name"), l.get("owner"), l.get("state")) for l in c.get("/leases").get("leases", [])]
    except Exception:
        return []


# ------------------------------------------------------------------------------------------------ изолированный
def _port_free(port):
    import socket
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def free_isolated_port():
    from vclab.daemon.admin import ISOLATED_PORTS
    for p in range(ISOLATED_PORTS[0], ISOLATED_PORTS[1] + 1):
        if LabClient(p).alive(0.3) is None and _port_free(p):
            return p
    raise RuntimeError("no free isolated daemon port in %d-%d" % ISOLATED_PORTS)


def start_isolated(port=None, owner=None, data=None, extra=(), wait=20.0):
    """Изолированный демон: свой порт (25800–25849), свой каталог состояния/экземпляров, свой диапазон портов аренд,
    без зеркала latest.log и без сканера чужих процессов; права уровня демона — у admin и у того, кто поднял."""
    from vclab.daemon import admin
    from vclab.daemon.client import default_owner
    port = int(port or free_isolated_port())
    lo, hi = admin.ISOLATED_PORTS
    if not lo <= port <= hi:
        return {"ok": False, "error": "isolated daemon port must be in %d-%d (the shared one is %d)" % (
            lo, hi, shared_port())}
    owner = owner or default_owner()
    data = data or admin.isolated_data(port)
    a, b = admin.isolated_lease_ports(port)
    args = ["--data", data, "--ports", "%d-%d" % (a, b), "--no-watch", "--isolated", "--starter", owner]
    r = start(port, wait=wait, extra=list(args) + list(extra), owner=owner)
    if r.get("ok") and r.get("already") and not r.get("isolated"):
        return {"ok": False, "error": "port %d runs a non-isolated daemon" % port}
    r.update(isolated=True, data=data, lease_ports=[a, b], starter=owner,
             hint="target it: lab --daemon %d <cmd> (or LAB_PORT=%d); stop: lab --daemon %d daemon stop" % (
                 port, port, port))
    return r


def list_isolated():
    from vclab.daemon.admin import ISOLATED_PORTS
    out = []
    for p in range(ISOLATED_PORTS[0], ISOLATED_PORTS[1] + 1):
        h = LabClient(p).alive(0.2)
        if h:
            out.append({"port": p, "pid": h.get("pid"), "isolated": h.get("isolated"), "starter": h.get("starter"),
                        "state": h.get("state"), "leases": h.get("leases"), "data": h.get("data"),
                        "code_hash": h.get("code_hash")})
    return {"ok": True, "isolated": out}


# ------------------------------------------------------------------------------------------------ уровень демона
def _client(port=None, owner=None, role=None):
    return LabClient(port, owner=owner, role=role)


def _is_legacy(c):
    """Демон без этапа 5: FastAPI отвечает 404 {"detail": "Not Found"} на /daemon/info."""
    r = c.get("/daemon/info")
    legacy = (r.get("ok") is False and r.get("error") == "http-404") or (r.get("detail") == "Not Found" and
                                                                         "ok" not in r)
    return legacy, r


def _legacy(c, h, action, force=False, reason=None):
    """Демон старого кода (без /daemon/*): решение на стороне клиента — роль, отказ при любой аренде, аудит."""
    from vclab.daemon import admin
    cfg = _cfg()
    admins = cfg["roles"]["admins"]
    role = "agent" if (c.role or "") == "agent" else ("admin" if c.owner in admins else "agent")
    leases = all_leases(c)
    live = live_leases(c)
    e = {"port": c.port, "pid": h.get("pid"), "action": action, "owner": c.owner, "role": role, "via": "cli-legacy",
         "force": force, "reason": reason, "leases": leases, "live": len(live), "legacy_daemon": True}
    audit = admin.Audit(os.path.join(h.get("data") or cfg["daemon"]["data"], "audit.jsonl"))
    if role != "admin":
        audit.write(dict(e, result="refused", error="admin-required"))
        return {"ok": False, "error": "admin-required", "message": "%s is a daemon-level operation: admin only "
                "(%s); caller %r is agent — ask the main session" % (action, ", ".join(admins), c.owner)}
    if leases and not force:
        audit.write(dict(e, result="refused", error="live-leases"))
        return {"ok": False, "error": "live-leases", "message": "refused: the running daemon is old code (no drain); "
                "%d lease(s) would be lost: %s. Wait until they are released, then repeat" % (len(leases),
                                                                                            ", ".join(leases)),
                "live": live, "leases": leases}
    audit.write(dict(e, result="ok"))
    c.post("/shutdown")
    import psutil
    try:
        psutil.Process(h["pid"]).wait(10)
    except psutil.Error:
        pass
    return {"ok": True, "stopped_pid": h["pid"], "legacy_daemon": True}


def stop(port=None, force=False, owner=None, role=None, reason=None):
    c = _client(port, owner, role)
    h = c.alive()
    if not h:
        return {"ok": True, "already": "stopped"}
    legacy, _ = _is_legacy(c)
    if legacy:
        return _legacy(c, h, "daemon.stop", force, reason)
    r = c.post("/daemon/stop", {"force": force, "reason": reason})
    if r.get("ok"):
        _wait_exit(h["pid"])
        r["stopped_pid"] = h["pid"]
    return r


def _wait_exit(pid, timeout=10):
    import psutil
    try:
        psutil.Process(pid).wait(timeout)
    except psutil.Error:
        pass


def _wait_new(c, old_pid, timeout=60.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        h = c.alive(0.5)
        if h and h.get("pid") != old_pid:
            return h
        time.sleep(0.3)
    return None


def restart(port=None, force=False, owner=None, role=None, reason=None):
    c = _client(port, owner, role)
    h = c.alive()
    if not h:
        return start(port, owner=owner)
    legacy, _ = _is_legacy(c)
    if legacy:
        r = _legacy(c, h, "daemon.restart", force, reason)
        return start(port, owner=owner) if r.get("ok") else r
    r = c.post("/daemon/restart", {"force": force, "reason": reason})
    if r.get("ok"):
        n = _wait_new(c, h["pid"])
        r["new"] = {"pid": n.get("pid"), "code_hash": n.get("code_hash")} if n else None
        r["ok"] = bool(n)
    return r


def upgrade(port=None, owner=None, role=None, reason=None, timeout=None, wait=False, force=False):
    c = _client(port, owner, role)
    h = c.alive()
    if not h:
        return start(port, owner=owner)
    legacy, _ = _is_legacy(c)
    if legacy:            # прежний код без drain: только когда аренд нет
        r = _legacy(c, h, "daemon.upgrade", force, reason)
        if not r.get("ok"):
            return r
        s = start(port, owner=owner)
        s["upgraded_from"] = "legacy pid %s" % h["pid"]
        return s
    r = c.post("/daemon/upgrade", {"timeout": timeout, "reason": reason, "force": force})
    if not r.get("ok"):
        return r
    if r.get("action") == "upgrade" or not r.get("queued") or wait:
        wt = (float(timeout) if timeout else 3600.0) + 60 if r.get("queued") else 60.0
        n = _wait_new(c, h["pid"], wt)
        r["new"] = {"pid": n.get("pid"), "code_hash": n.get("code_hash")} if n else None
        if not n:
            r["ok"] = False
            r["error"] = "new daemon did not answer in %.0f s (drain timed out or start failed: lab audit)" % wt
    return r


def drain(port=None, owner=None, role=None, reason=None, timeout=None, then=None):
    c = _client(port, owner, role)
    if not c.alive():
        return {"ok": False, "error": "labd is not running on %d" % c.port}
    return c.post("/daemon/drain", {"timeout": timeout, "then": then, "reason": reason})


def undrain(port=None, owner=None, role=None, reason=None):
    c = _client(port, owner, role)
    return c.post("/daemon/undrain", {"reason": reason})


def reload_core(port=None, owner=None, role=None, reason=None, modules=None, force=False):
    c = _client(port, owner, role)
    return c.post("/daemon/reload-core", {"modules": modules or None, "force": force, "reason": reason})


def status(port=None, owner=None, role=None):
    from vclab.daemon import admin
    c = _client(port, owner, role)
    h = c.alive()
    disk = admin.file_hashes()
    if not h:
        return {"ok": False, "error": "labd is not running on %d" % c.port, "disk_hash": admin.combined(disk)}
    legacy, info = _is_legacy(c)
    if legacy:
        changed = []
        for rel, path in admin.code_files().items():
            try:
                if os.path.getmtime(path) > h.get("started", 0):
                    changed.append(rel)
            except OSError:
                pass
        return {"ok": True, "port": c.port, "pid": h.get("pid"), "legacy_daemon": True, "code_hash": None,
                "disk_hash": admin.combined(disk), "stale": True,
                "message": "daemon runs old code without stage 5 (/daemon/info missing): roles/drain/audit are not "
                           "enforced by it. Upgrade: `lab daemon upgrade` by admin when it has no leases",
                "files_changed_since_start": changed, "uptime_s": h.get("uptime_s"), "leases": h.get("leases")}
    who = c.get("/daemon/whoami")
    info["you"] = {"owner": c.owner, "role": who.get("role"), "daemon_rights": who.get("daemon_rights")}
    info.pop("history", None) if not info.get("history") else None
    return info


def audit(port=None, last=30):
    c = _client(port)
    if c.alive():
        r = c.get("/daemon/audit?last=%d" % int(last))
        if r.get("ok"):
            return r
    from vclab.daemon import admin
    data = _cfg()["daemon"]["data"]
    if port and int(port) != shared_port():
        data = admin.isolated_data(port)
    path = os.path.join(data, "audit.jsonl")
    return {"ok": True, "path": path, "entries": admin.read_audit(path, last), "from_file": True}


def audit_table(r):
    rows = ["%-19s %-6s %-22s %-14s %-7s %-9s %-16s %s" % ("at", "port", "action", "owner", "rights", "result", "error",
                                                          "leases / message")]
    for e in r.get("entries") or []:
        rows.append("%-19s %-6s %-22s %-14s %-7s %-9s %-16s %s" % (
            e.get("at", ""), e.get("port", ""), (e.get("action") or "")[:22], (e.get("owner") or "-")[:14],
            (e.get("rights") or e.get("role") or "-")[:7], (e.get("result") or "")[:9], (e.get("error") or "")[:16],
            ("%d: %s" % (len(e.get("leases") or []), ", ".join(e.get("leases") or [])) if e.get("leases")
             else (e.get("message") or ""))[:110]))
    return "\n".join(rows)


def ensure(port=None):
    c = LabClient(port)
    return c.alive() or start(port)


def _opt(argv, name, flag=False, many=False):
    vals = []
    while name in argv:
        i = argv.index(name)
        if flag:
            argv.pop(i)
            return True
        vals.append(argv[i + 1])
        del argv[i:i + 2]
    if flag:
        return False
    return vals if many else (vals[-1] if vals else None)


def main(argv, port=None, owner=None, role=None):
    import json
    argv = list(argv)
    p = _opt(argv, "--port") or _opt(argv, "--daemon")
    port = int(p) if p else port
    owner = _opt(argv, "--owner") or owner
    if _opt(argv, "--as-agent", flag=True):
        role = "agent"
    force = _opt(argv, "--force", flag=True)
    reason = _opt(argv, "--reason")
    timeout = _opt(argv, "--timeout")
    timeout = float(timeout) if timeout is not None else None
    act = argv[1] if len(argv) > 1 else "status"
    table = _opt(argv, "--table", flag=True)
    if act == "start":
        if _opt(argv, "--isolated", flag=True):
            r = start_isolated(port, owner=owner)
        else:
            if port and port != shared_port():
                from vclab.daemon.admin import ISOLATED_PORTS
                if ISOLATED_PORTS[0] <= port <= ISOLATED_PORTS[1]:
                    print(json.dumps({"ok": False, "error": "port %d is in the isolated range: use --isolated" % port}))
                    return 1
            r = start(port, owner=owner)
    elif act == "stop":
        r = stop(port, force=force, owner=owner, role=role, reason=reason)
    elif act == "restart":
        r = restart(port, force=force, owner=owner, role=role, reason=reason)
    elif act == "upgrade":
        r = upgrade(port, owner=owner, role=role, reason=reason, timeout=timeout,
                    wait=_opt(argv, "--wait", flag=True), force=force)
    elif act == "drain":
        then = _opt(argv, "--then")
        r = drain(port, owner=owner, role=role, reason=reason, timeout=timeout,
                  then=None if then in (None, "none") else then)
    elif act == "undrain":
        r = undrain(port, owner=owner, role=role, reason=reason)
    elif act == "reload-core":
        r = reload_core(port, owner=owner, role=role, reason=reason, modules=_opt(argv, "--module", many=True),
                        force=force)
    elif act == "audit":
        r = audit(port, int(_opt(argv, "--last") or 30))
        if table:
            print(audit_table(r))
            return 0
    elif act == "list":
        r = list_isolated()
    elif act in ("status", "ensure"):
        r = {"status": status, "ensure": ensure}[act](port) if act == "ensure" else status(port, owner, role)
    else:
        print(__doc__)
        return 2
    print(json.dumps(r, ensure_ascii=False, indent=1, default=str))
    return 0 if r.get("ok", True) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
