"""Настоящий демон (labctl -> WMI -> pythonw labd.py) на отдельном порту 25791 с временными данными и проектом dummy:
HTTP API, коды ошибок, CLI, и главное свойство Job Object — убитый демон не оставляет сирот."""
import json
import os
import subprocess
import sys
import time

import psutil
import pytest

from conftest import LAB, PY, write_dummy_project
from vclab.cli import labctl as labctl
from vclab.daemon.client import LabClient

PORT = 25791


def _start(tmp):
    projects = write_dummy_project(tmp)
    r = labctl.start(PORT, extra=["--data", os.path.join(tmp, "data"), "--ports", "25670-25679",
                                  "--projects", projects, "--no-watch"])
    assert r["ok"], r
    return r


@pytest.fixture
def daemon(tmpdir_win):
    assert LabClient(PORT).alive() is None, "port %d busy" % PORT
    r = _start(tmpdir_win)
    yield LabClient(PORT, owner="agentA"), r
    c = LabClient(PORT, owner="agentA")
    if c.alive():
        # этап 5: снять всё и остановить демон — admin (главная сессия claude)
        LabClient(PORT, owner="claude").post("/stop-all")
        labctl.stop(PORT, force=True, owner="claude")


def test_http_api(daemon):
    c, started = daemon
    h = c.get("/health")
    assert h["service"] == "labd" and h["projects"] == ["dummy", "vc"] and h["ports"] == [25670, 25679]
    print("daemon cold start via WMI: %.2f s" % started["started_s"])
    p = c.get("/projects")["projects"]
    assert set(p["dummy"]["kinds"]) == {"fake", "tree", "stdin", "echo", "survivor"} and "dummy.hello2" in p["dummy"]["features"]
    assert p["vc"]["kinds"]["engine"]["f2f"] == "f2f" and p["vc"]["plugin_error"] is None
    r = c.post("/leases", {"project": "dummy", "kind": "fake", "ttl": 120, "start": True})
    name = r["lease"]["name"]
    assert r["start"]["ok"] and r["start"]["ready"][1]["frames"] == 5
    assert c.post("/f2f/" + name, {"cmd": "hello"})["result"]["impl"] == "fake"
    other = LabClient(PORT, owner="agentB")
    e = other.post("/f2f/" + name, {"cmd": "hello"})
    assert e["ok"] is False and e["error"] == "not-owner"
    assert other.post("/leases/nope/release", {})["error"] == "not-found"
    shot = c.post("/f2f/" + name, {"cmd": "shot", "args": {"name": "x"}})
    assert shot["ok"] and os.path.exists(shot["result"]["path"])
    logs = c.get("/proc/%s/logs?stream=stdout&tail=5" % name)
    assert "привет из консоли" in logs["lines"]
    feat = c.post("/call/dummy.hello2", {"args": {"lease": name}})
    assert feat["ok"] and feat["result"]["impl"] == "fake"
    dead = c.post("/f2f/" + name, {"cmd": "crash"})
    assert dead["error"] == "instance-dead" and dead["exit"] == "exit 3", dead
    ps = c.get("/leases")
    assert ps["leases"][0]["state"] == "dead"
    j = c.get("/journal?last=10&instance=" + name)["entries"]
    assert [e["tool"] for e in j][-1] == "lab.instance_dead" or any(e["tool"] == "lab.instance_dead" for e in j)
    rel = c.post("/leases/%s/release" % name, {})
    assert rel["ok"] and rel["removed_dir"]
    runs = c.get("/runs?last=5")["runs"]
    assert runs[-1]["state"] == "closed" and runs[-1]["verdict"] == "dead"
    # CLI (Windows python) против того же демона
    out = subprocess.run([PY, "-X", "utf8", os.path.join(LAB, "bin", "lab.py"), "ps"], capture_output=True,
                         env=dict(os.environ, LAB_PORT=str(PORT)), timeout=30)
    assert out.returncode == 0 and json.loads(out.stdout)["leases"] == []


def test_daemon_death_kills_instances(daemon, tmpdir_win):
    c, started = daemon
    r = c.post("/leases", {"project": "dummy", "kind": "tree", "start": True})
    name = r["lease"]["name"]
    d = c.get("/proc/" + name)["lease"]["dir"]
    marker = os.path.join(d, "child.pid")
    end = time.time() + 15
    while not os.path.exists(marker) and time.time() < end:
        time.sleep(0.05)
    child, main = int(open(marker).read()), r["start"]["pid"]
    assert psutil.pid_exists(child) and psutil.pid_exists(main)
    t0 = time.time()
    psutil.Process(started["pid"]).kill()          # демон падает (не shutdown)
    while (psutil.pid_exists(child) or psutil.pid_exists(main)) and time.time() - t0 < 5:
        time.sleep(0.05)
    assert not psutil.pid_exists(child) and not psutil.pid_exists(main)
    print("daemon killed -> instance tree gone in %.2f s" % (time.time() - t0))
    # новый демон на тех же данных: аренда восстановлена, процесс признан мёртвым, порт снова занят ею
    r2 = _start(tmpdir_win)
    c2 = LabClient(PORT, owner="agentA")
    ps = c2.get("/leases")
    l = [x for x in ps["leases"] if x["name"] == name][0]
    assert l["state"] == "dead" and l["proc"]["alive"] is False
    assert c2.post("/leases/%s/release" % name, {})["ok"]
