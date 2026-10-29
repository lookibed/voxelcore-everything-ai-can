"""Аренды целиком в процессе теста (Lab без HTTP) на временном проекте «dummy»: фейковый F2F-процесс, дерево
cmd -> python, процесс со stdin-остановкой. Данные — во временном каталоге, порты — 25680–25689."""
import json
import os
import time

import psutil
import pytest

from conftest import HERE, PY, write_dummy_project
from vclab import config
from vclab.leases.logwatch import LogMirror
from vclab.daemon.service import Lab, LabError



@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    write_dummy_project(tmpdir_win)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "25680-25689")
    cfg = config.load()
    cfg["leases"]["reap_every"] = 0.2
    labs = []

    def make():
        lb = Lab(cfg, watch=False, background=True)
        labs.append(lb)
        return lb
    lb = make()
    lb.make = make
    lb.tmp = tmpdir_win
    yield lb
    for x in labs:
        try:
            x.stop_all()
        except Exception:
            pass
        x.shutdown()


def test_lifecycle(lab):
    r = lab.create_lease("dummy", "fake", "agentA")
    name, port = r["lease"]["name"], r["lease"]["ports"]["f2f"]
    assert name == "dummy-fake-1" and 25680 <= port <= 25689
    assert lab.ports.used[port] == name
    s = lab.start(name, owner="agentA")
    assert s["ok"] and s["ready"][0]["result"]["impl"] == "fake"
    assert s["ready"][1]["frames"] == 5 and "ready marker" in s["ready"][1]["line"]
    d = lab.leases[name].dir
    assert json.load(open(os.path.join(d, "cfg.json"))) == {"port": port, "who": "agentA"}
    assert os.path.isjunction(os.path.join(d, "content", "packx"))
    h = lab.f2f(name, "hello", owner="agentA")
    assert h["ok"] and h["result"]["frame"] == 5 and h["f2f_ms"] < 50
    shot = lab.f2f(name, "shot", {"name": "first"}, owner="agentA")
    assert shot["ok"] and os.path.exists(shot["result"]["path"]) and "\\shots\\001_dummy-fake-1_first.png" in \
        shot["result"]["path"]
    out = lab.logs(name, stream="stdout")["lines"]
    err = lab.logs(name, stream="stderr")["lines"]
    assert "привет из консоли" in out and err == ["Отказано в доступе"]
    st = lab.stop(name, owner="agentA")
    assert st["exit"] == "exit 0" and not st["forced_kill"], st
    assert lab.leases[name].state == "stopped"
    rel = lab.release(name, owner="agentA")
    assert rel["removed_dir"] and not os.path.exists(d)
    assert port not in lab.ports.used and name not in lab.leases
    rep = json.load(open(os.path.join(rel["run_dir"], "report.json"), encoding="utf-8"))
    assert rep["verdict"] == "done" and rep["shots"][0]["sha256"] and rep["closed"]
    logs = os.listdir(os.path.join(rel["run_dir"], "logs"))
    assert "dummy-fake-1_stdout_start1.log" in logs, logs
    tools = [e["tool"] for e in map(json.loads, open(os.path.join(rel["run_dir"], "journal.jsonl"), encoding="utf-8"))]
    assert "lab.start" in tools and "lab.f2f" in tools and "lab.stop" in tools and "lab.release" in tools
    assert rep["meta"]["exe"][name]["path"] == PY


def test_owner_and_force(lab):
    name = lab.create_lease("dummy", "fake", "agentA")["lease"]["name"]
    with pytest.raises(LabError) as e:
        lab.start(name, owner="agentB")
    assert e.value.code == "not-owner"
    lab.start(name, owner="agentA")
    with pytest.raises(LabError):
        lab.f2f(name, "hello", owner="agentB")
    assert lab.f2f(name, "hello", owner="agentB", force=True)["ok"]
    lab.release(name, owner="agentB", force=True)
    assert name not in lab.leases


def test_instance_dead(lab):
    name = lab.create_lease("dummy", "fake", "a")["lease"]["name"]
    lab.start(name, owner="a")
    with pytest.raises(LabError) as e:
        lab.f2f(name, "crash", owner="a", timeout=10)
    b = e.value.body()
    assert b["error"] == "instance-dead" and b["exit_code"] == 3 and b["exit"] == "exit 3"
    assert "привет из консоли" in b["log_tail"]
    time.sleep(0.2)
    assert lab.leases[name].state == "dead"
    with pytest.raises(LabError) as e2:          # следующий вызов — сразу, без таймаута
        t0 = time.time()
        lab.f2f(name, "hello", owner="a")
    assert e2.value.code == "instance-dead" and time.time() - t0 < 1
    assert any(x["tool"] == "lab.instance_dead" for x in lab.journal.tail(20, top_only=False))


def test_ready_timeout_reports_dead(lab):
    name = lab.create_lease("dummy", "fake", "a", params={"delay": "x"})["lease"]["name"]   # фейк падает сразу
    with pytest.raises(LabError) as e:
        lab.start(name, owner="a")
    assert e.value.code in ("instance-dead", "start-failed")
    assert lab.leases[name].state == "failed"


def test_ttl_expiry(lab):
    name = lab.create_lease("dummy", "fake", "a", ttl=1.0)["lease"]["name"]
    pid = lab.start(name, owner="a")["pid"]
    lab.leases[name].expires = time.time() + 0.5
    end = time.time() + 5
    while name in lab.leases and time.time() < end:
        time.sleep(0.1)
    assert name not in lab.leases
    assert not psutil.pid_exists(pid) or psutil.Process(pid).status() == psutil.STATUS_ZOMBIE
    assert any(e["tool"] == "lab.lease_expired" for e in lab.journal.tail(30, top_only=False))


def test_tree_killed_on_release(lab):
    name = lab.create_lease("dummy", "tree", "a")["lease"]["name"]
    s = lab.start(name, owner="a")
    marker = os.path.join(lab.leases[name].dir, "child.pid")
    end = time.time() + 15
    while not os.path.exists(marker) and time.time() < end:
        time.sleep(0.05)
    child = int(open(marker).read())
    assert child in lab.leases[name].job.pids() and s["pid"] in lab.leases[name].job.pids()
    r = lab.release(name, owner="a")
    assert r["forced_kill"]
    end = time.time() + 5
    while psutil.pid_exists(child) and time.time() < end:
        time.sleep(0.05)
    assert not psutil.pid_exists(child) and not psutil.pid_exists(s["pid"])


def test_stdin_soft_stop(lab):
    name = lab.create_lease("dummy", "stdin", "a")["lease"]["name"]
    s = lab.start(name, owner="a")
    assert s["ready"][0]["line"] == "Done!"
    st = lab.stop(name, owner="a")
    assert st["exit"] == "exit 0" and not st["forced_kill"], st


def test_daemon_restart_readopts(lab):
    name = lab.create_lease("dummy", "survivor", "a")["lease"]["name"]
    st = lab.start(name, owner="a")
    pid, rid = st["pid"], st["run"]
    port_lease = lab.create_lease("dummy", "fake", "a")["lease"]
    lab.shutdown()
    lab2 = lab.make()                         # «новый демон» на тех же данных
    assert name in lab2.leases and lab2.leases[name].proc.alive() and lab2.leases[name].proc.adopted
    assert lab2.ports.used[port_lease["ports"]["f2f"]] == port_lease["name"]
    run = [r for r in lab2.runs.list(50) if r["id"] == rid][0]
    assert run["state"] == "closed" and run["verdict"].startswith("aborted"), run
    assert json.load(open(os.path.join(run["dir"], "report.json"), encoding="utf-8"))["verdict"].startswith("aborted")
    lab2.release(name, owner="a")
    end = time.time() + 5
    while psutil.pid_exists(pid) and time.time() < end:
        time.sleep(0.05)
    assert not psutil.pid_exists(pid)


def test_plugin_feature_and_reload(lab):
    name = lab.create_lease("dummy", "fake", "a")["lease"]["name"]
    lab.start(name, owner="a")
    r = lab.call("dummy.hello2", {"lease": name}, owner="a")
    assert r["ok"] and r["result"]["impl"] == "fake" and r["version"] == "dummy@1"
    gen = lab.projects.generation
    plug = os.path.join(lab.tmp, "projects", "dummy", "plugin.py")
    time.sleep(0.05)
    with open(plug, "a", encoding="utf-8") as f:
        f.write("    api.feature('two', lambda ctx, a: 2, 'second', mcp=True)\nPLUGIN_VERSION = 2\n")
    os.utime(plug, (time.time() + 2, time.time() + 2))
    lab.projects.scan()
    assert lab.projects.generation > gen and lab.call("dummy.two", {}, owner="a")["result"] == 2
    with open(plug, "a", encoding="utf-8") as f:
        f.write("this is not python\n")
    os.utime(plug, (time.time() + 4, time.time() + 4))
    lab.projects.scan()
    p = lab.projects.get("dummy")
    assert p.plugin_error and "dummy.two" in lab.projects.features()     # старая версия осталась
    entries = lab.journal.tail(50, top_only=False)
    assert any(e["tool"] == "lab.plugin_load_failed" for e in entries)
    call = [e for e in entries if e["tool"] == "lab.call"][0]
    assert call["plugin"].startswith("dummy@") and call["agent"] == "a"
    inner = [e for e in entries if e.get("parent") == call["idx"]]
    assert inner and inner[0]["tool"] == "lab.f2f" and inner[0]["instance"] == name


def test_log_mirror(tmpdir_win):
    log = os.path.join(tmpdir_win, "latest.log")
    with open(log, "w", encoding="utf-8") as f:
        f.write("2026/10/01 10:00:00 header A\nline 1\n")
    m = LogMirror("t", log, os.path.join(tmpdir_win, "data"))
    assert m.poll() is True
    with open(log, "a", encoding="utf-8") as f:
        f.write("line 2\n")
    assert m.poll() is False
    first_arch = m.st["archive"]
    with open(log, "w", encoding="utf-8") as f:          # «перезапуск движка»: файл пересоздан
        f.write("2026/10/01 10:05:00 header B\nx\n")
    assert m.poll() is True
    assert open(first_arch, encoding="utf-8").read() == "2026/10/01 10:00:00 header A\nline 1\nline 2\n"
    assert open(m.st["archive"], encoding="utf-8").read().startswith("2026/10/01 10:05:00 header B")
    m2 = LogMirror("t", log, os.path.join(tmpdir_win, "data"))    # рестарт демона: продолжает тот же архив
    with open(log, "a", encoding="utf-8") as f:
        f.write("y\n")
    assert m2.poll() is False and open(m2.st["archive"], encoding="utf-8").read().endswith("x\ny\n")
