"""Этап 5 (vclab/daemon/admin.py): роли, эвристика чужих аренд, drain, аудит, версия кода, reload-core, изолированный демон.

Общий демон 127.0.0.1:25700 тесты не трогают: в процессе — Lab без HTTP (порты аренд 26330–26339), настоящие
демоны — только изолированные (labctl.start_isolated) на 25846/25847 с временными каталогами данных
(аренды 26310–26319 и 26320–26329)."""
import json
import os
import subprocess
import sys
import time

import psutil
import pytest

from conftest import LAB, PY, write_dummy_project
from vclab.daemon import admin
from vclab import config
from vclab.daemon.client import LabClient
from vclab.daemon.service import Lab, LabError


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    write_dummy_project(tmpdir_win)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "26330-26339")
    monkeypatch.delenv("LAB_ISOLATED", raising=False)
    monkeypatch.delenv("LAB_STARTER", raising=False)
    cfg = config.load()
    cfg["leases"]["reap_every"] = 0.2
    lb = Lab(cfg, watch=False, background=True)
    calls = []
    lb.ctl.exit_fn = lambda what: calls.append(("exit", what))          # без настоящего выхода процесса теста
    lb.ctl.respawn_fn = lambda: calls.append(("respawn",)) or {"wmi_pid": 0, "fake": True}
    lb.calls = calls
    yield lb
    lb.stop_all()
    lb.shutdown()


def audit_of(lb):
    return lb.ctl.audit.tail(0)


def test_roles_refusal(lab):
    c = lab.ctl
    assert c.admins == ["user", "claude"]
    assert c.role("claude") == "admin" and c.role("user") == "admin" and c.role("agentA") == "agent"
    assert c.role("claude", "agent") == "agent" and c.role("agentA", "admin") == "agent"   # заголовок только понижает
    for fn in (lambda: c.stop("agentA"), lambda: c.restart("agentA"), lambda: c.upgrade("agentA"),
               lambda: c.start_drain("agentA"), lambda: c.undrain("agentA"), lambda: c.reload_core("agentA"),
               lambda: c.stop("claude", "agent"), lambda: c.require("release.all", "agentA"),
               lambda: c.require("golden.promote", "agentA", scope="data")):
        with pytest.raises(LabError) as ei:
            fn()
        assert ei.value.code == "admin-required" and ei.value.status == 403
        assert "ask the main session" in ei.value.message
    # ворота: принять храповик — admin; агенту 403 ещё до вызова возможности
    with pytest.raises(LabError) as ei:
        lab.call("core.gate_accept", {"project": "dummy", "run": "nope"}, owner="agentA")
    assert ei.value.code == "admin-required"
    with pytest.raises(LabError) as ei:
        lab.call("core.gate_accept", {"project": "dummy", "run": "nope"}, owner="claude", role="agent")
    assert ei.value.code == "admin-required"
    au = audit_of(lab)
    assert au[0]["action"] == "daemon.start"
    refused = [e for e in au if e.get("result") == "refused"]
    assert len(refused) == 11 and {e["error"] for e in refused} == {"admin-required"}
    assert {e["action"] for e in refused} >= {"daemon.stop", "daemon.restart", "daemon.upgrade", "daemon.drain",
                                              "daemon.undrain", "daemon.reload-core", "release.all", "golden.promote",
                                              "gate.accept"}
    assert all("t" in e and "at" in e and "leases" in e for e in refused)
    assert lab.calls == []                      # ни одного выхода/перезапуска


def test_heuristic_foreign_leases_and_live(lab):
    c = lab.ctl
    name = lab.create_lease("dummy", "fake", "agentA")["lease"]["name"]
    # чужая аренда (даже без процесса) — немедленные операции отказ при любой роли
    for fn in (lambda: c.stop("claude"), lambda: c.restart("claude"), lambda: c.reload_core("claude")):
        with pytest.raises(LabError) as ei:
            fn()
        assert ei.value.code == "foreign-leases" and ei.value.status == 409 and name in ei.value.message
        assert "drain" in ei.value.message
    lab.release(name, owner="agentA")
    # своя живая аренда: stop/restart — live-leases с подсказкой drain
    own = lab.create_lease("dummy", "fake", "claude", start=True)["lease"]["name"]
    with pytest.raises(LabError) as ei:
        c.restart("claude")
    assert ei.value.code == "live-leases" and "lab daemon drain" in ei.value.message
    # --force (admin) проходит: перезапуск выполнен (подменённый respawn/exit), запись аудита с арендами
    r = c.restart("claude", force=True, reason="test force")
    assert r["ok"] and lab.calls == [("respawn",), ("exit", "restart")]
    au = audit_of(lab)
    ok = [e for e in au if e["action"] == "daemon.restart" and e["result"] == "ok"][-1]
    assert ok["force"] and ok["reason"] == "test force" and ok["live"] == 1 and own in ok["leases"][0]
    perf = [e for e in au if e["action"] == "daemon.restart.perform"][-1]
    assert perf["result"] == "exiting" and perf["from_hash"] and perf["to_hash"]
    pend = json.load(open(c.version_path, encoding="utf-8"))["pending"]
    assert pend["action"] == "restart" and pend["by"] == "claude"


def test_drain_lifecycle(lab):
    c = lab.ctl
    a = lab.create_lease("dummy", "fake", "agentA", start=True)["lease"]["name"]
    r = c.start_drain("claude", then="restart", timeout=60, reason="core update")
    assert r["ok"] and r["state"] == "draining" and any(a in w for w in r["drain"]["waiting_for"])
    # новые аренды — 503 draining (и через ps видно состояние)
    with pytest.raises(LabError) as ei:
        lab.create_lease("dummy", "fake", "agentB")
    assert ei.value.code == "draining" and ei.value.status == 503
    ps = lab.ps()["daemon"]
    assert ps["state"] == "draining" and ps["drain"]["then"] == "restart" and ps["drain"]["by"] == "claude"
    with pytest.raises(LabError) as ei:
        c.start_drain("claude")
    assert ei.value.code == "busy"
    # владелец аренды продолжает работать: F2F по своей аренде идёт
    assert lab.f2f(a, "hello", owner="agentA")["ok"]
    assert lab.calls == []
    lab.release(a, owner="agentA")
    t0 = time.time()
    while not lab.calls and time.time() - t0 < 10:
        time.sleep(0.1)
    assert lab.calls == [("respawn",), ("exit", "restart")] and c.state == "exiting"
    acts = [(e["action"], e["result"]) for e in audit_of(lab)]
    assert ("daemon.drain", "refused") in acts                 # повторный drain (busy) — тоже в аудите
    acts = [x for x in acts if x != ("daemon.drain", "refused")]
    assert acts[-3:] == [("daemon.drain", "draining"), ("daemon.drain.complete", "drained"),
                         ("daemon.restart.perform", "exiting")]


def test_drain_timeout_and_undrain(lab):
    c = lab.ctl
    a = lab.create_lease("dummy", "fake", "agentA")["lease"]["name"]
    c.start_drain("claude", then="upgrade", timeout=1)
    t0 = time.time()
    while c.state != "serving" and time.time() - t0 < 10:
        time.sleep(0.1)
    assert c.state == "serving" and lab.calls == []          # таймаут: действие не выполнено, демон обслуживает
    e = audit_of(lab)[-1]
    assert e["action"] == "daemon.drain.timeout" and e["result"] == "timeout" and any(a in w for w in e["waiting_for"])
    c.start_drain("user", timeout=0)                         # без действия и без таймаута
    with pytest.raises(LabError):
        lab.create_lease("dummy", "fake", "agentB")
    with pytest.raises(LabError) as ei:
        c.undrain("agentA")
    assert ei.value.code == "admin-required"
    assert c.undrain("user")["was"] == "draining"
    assert lab.create_lease("dummy", "fake", "agentB")["ok"]
    # upgrade без аренд других — в очередь, выполняется сам, когда аренд не остаётся
    for n in list(lab.leases):
        lab.release(n, force=True)
    r = c.upgrade("claude", timeout=30)
    assert r["ok"] and not r["queued"]
    t0 = time.time()
    while not lab.calls and time.time() - t0 < 10:
        time.sleep(0.1)
    assert lab.calls == [("respawn",), ("exit", "upgrade")]


def test_reload_core(lab, tmpdir_win, monkeypatch):
    c = lab.ctl
    old_hist_cls = type(lab.history)
    r = c.reload_core("claude", reason="test")
    assert r["ok"] and set(r["reloaded"]) | set(r["unchanged"]) == set(admin.SAFE_RELOAD)
    assert "history" in r["reloaded"] and "golden" in r["reloaded"]
    assert type(lab.history) is sys.modules["vclab.quality.history"].History and type(lab.history) is not old_hist_cls
    assert type(lab.golden) is sys.modules["vclab.quality.golden"].Golden
    # возможности ядра работают после перезагрузки
    h = lab.call("core.history", {"project": "dummy", "last": 3}, owner="agentA")
    assert h["ok"]
    with pytest.raises(LabError) as ei:
        c.reload_core("claude", modules=["service"])
    assert ei.value.code == "bad-request" and "restart-only" in ei.value.message
    # сломанный исходник: проверка до reload, ничего не перезагружено
    bad = os.path.join(tmpdir_win, "badcore")
    os.makedirs(bad)
    with open(os.path.join(bad, "gate.py"), "w") as f:
        f.write("def broken(:\n")
    monkeypatch.setattr(admin, "_source_path", lambda n: os.path.join(bad, n + ".py"))   # было: admin.LABCORE
    rr = admin.reload_modules(["gate"], lab)
    assert not rr["ok"] and rr["error"].startswith("validate gate: SyntaxError") and rr["reloaded"] == []
    e = [x for x in audit_of(lab) if x["action"] == "daemon.reload-core"]
    assert e[0]["result"] == "ok" and "history" in e[0]["reloaded"]


def test_code_hash_stale(lab):
    c = lab.ctl
    info = c.info()
    assert info["code_hash"] == info["disk_hash"] and not info["stale"]
    c.loaded["vclab/quality/gate.py"] = "0" * 16
    c.loaded["vclab/daemon/service.py"] = "0" * 16
    info = c.info()
    assert info["stale"] and info["stale_files"] == {"reloadable": ["vclab/quality/gate.py"],
                                                     "restart_only": ["vclab/daemon/service.py"]}
    assert "vclab/daemon/client.py" not in admin.code_files() and "vclab/daemon/labd.py" in admin.code_files()
    v = json.load(open(c.version_path, encoding="utf-8"))
    assert v["current"]["code_hash"] == admin.combined(admin.file_hashes()) and v["history"][-1]["via"] == "start"


# ------------------------------------------------------------------------------------------------ настоящие демоны
PA, PB = 25846, 25847


@pytest.fixture
def two(tmpdir_win):
    from vclab.cli import labctl as labctl
    for p in (PA, PB):
        assert LabClient(p).alive() is None, "port %d busy" % p
    projects = write_dummy_project(tmpdir_win)
    ra = labctl.start_isolated(PA, owner="isoA", data=os.path.join(tmpdir_win, "dA"), extra=["--projects", projects])
    rb = labctl.start_isolated(PB, owner="isoB", data=os.path.join(tmpdir_win, "dB"), extra=["--projects", projects])
    assert ra["ok"] and rb["ok"], (ra, rb)
    yield ra, rb
    for p, o in ((PA, "isoA"), (PB, "isoB")):
        c = LabClient(p, owner=o)
        h = c.alive()
        if h:
            c.post("/stop-all")
            labctl.stop(p, force=True, owner=o)


def test_isolated_daemons(two, tmpdir_win):
    from vclab.cli import labctl as labctl
    ra, rb = two
    assert ra["lease_ports"] == [26310, 26319] and rb["lease_ports"] == [26320, 26329]
    assert admin.isolated_data(25801).endswith(os.path.join("lab", "isolated", "25801"))
    a, b = LabClient(PA, owner="isoA"), LabClient(PB, owner="isoB")
    ha, hb = a.get("/health"), b.get("/health")
    assert ha["isolated"] and ha["starter"] == "isoA" and ha["ports"] == [26310, 26319] and ha["state"] == "serving"
    assert hb["starter"] == "isoB" and ha["data"] != hb["data"] and ha["pid"] != hb["pid"]
    # нет общего состояния: аренда в A не видна в B; журналы/аудит в своих каталогах
    la = a.post("/leases", {"project": "dummy", "kind": "fake", "start": True})
    assert la["ok"] and 26310 <= la["lease"]["ports"]["f2f"] <= 26319
    assert [l["name"] for l in b.get("/leases")["leases"]] == []
    assert os.path.exists(os.path.join(ha["data"], "audit.jsonl")) and os.path.exists(os.path.join(hb["data"],
                                                                                                    "audit.jsonl"))
    # ps CLI: баннер ISOLATED, --daemon выбирает демон; неработающий порт не поднимается сам
    out = subprocess.run([PY, "-X", "utf8", os.path.join(LAB, "bin", "lab.py"), "--daemon", str(PA), "ps", "--table"],
                         capture_output=True, timeout=60, text=True, encoding="utf-8")
    assert out.returncode == 0 and "ISOLATED daemon :%d (starter isoA)" % PA in out.stdout, out.stdout + out.stderr
    out = subprocess.run([PY, "-X", "utf8", os.path.join(LAB, "bin", "lab.py"), "--daemon", "25849", "ps"],
                         capture_output=True, timeout=60, text=True, encoding="utf-8")
    assert out.returncode == 1 and "not running on 25849" in out.stdout and LabClient(25849).alive() is None
    # чужой агент: уровень демона — 403; starter B на демоне A — тоже чужой
    for who in ("intruder", "isoB"):
        r = LabClient(PA, owner=who).post("/daemon/stop", {"force": True})
        assert r["error"] == "admin-required", r
    assert LabClient(PA, owner="isoA").post("/golden/promote", {"run": "x", "reason": "r"})["error"] == "admin-required"
    # starter A: restart с живой своей арендой — отказ, drain --then restart -> после release новый процесс
    r = a.post("/daemon/restart", {})
    assert r["error"] == "live-leases"
    r = a.post("/daemon/drain", {"then": "restart", "timeout": 60})
    assert r["ok"] and r["state"] == "draining"
    e = LabClient(PA, owner="other").post("/leases", {"project": "dummy", "kind": "fake"})
    assert e["error"] == "draining"
    assert a.post("/leases/%s/release" % la["lease"]["name"], {})["ok"]
    n = labctl._wait_new(a, ha["pid"], 60)
    assert n and n["pid"] != ha["pid"] and n["isolated"] and n["starter"] == "isoA" and n["ports"] == [26310, 26319]
    assert not psutil.pid_exists(ha["pid"]) or psutil.Process(ha["pid"]).status() == psutil.STATUS_ZOMBIE
    # upgrade без аренд — сразу; версия в state\daemon.json, аудит
    r = labctl.upgrade(PA, owner="isoA", reason="test upgrade")
    assert r["ok"] and r["new"] and r["new"]["pid"] != n["pid"], r
    st = labctl.status(PA, owner="isoA")
    assert st["code_hash"] == st["disk_hash"] and not st["stale"] and st["you"]["daemon_rights"] == "starter"
    hist = st["history"]
    assert [x["via"] for x in hist[-3:]] == ["start", "restart", "upgrade"] and hist[-1]["by"] == "isoA"
    au = labctl.audit(PA, 50)["entries"]
    acts = [(x["action"], x["result"]) for x in au]
    for want in (("daemon.stop", "refused"), ("daemon.drain", "draining"), ("daemon.drain.complete", "drained"),
                 ("daemon.restart.perform", "exiting"), ("daemon.upgrade", "draining"),
                 ("daemon.upgrade.perform", "exiting"), ("daemon.start", "ok")):
        assert want in acts, (want, acts)
    starts = [x for x in au if x["action"] == "daemon.start"]
    assert [x["via"] for x in starts] == ["start", "restart", "upgrade"] and starts[-1]["after_pid"]
    # B не тронут всем этим
    assert b.get("/health")["pid"] == hb["pid"]
    # starter останавливает свой демон
    assert labctl.stop(PB, owner="isoB")["ok"] and LabClient(PB).alive() is None
