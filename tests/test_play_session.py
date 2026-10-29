"""lab play целиком в процессе теста (Lab без HTTP) на временном проекте playdemo: «сервер» (stdin-стоп, порт game)
и «движок» (python пишет latest.log в формате VoxelCore со строками статуса и событиями, выходит сам или ждёт стопа).
Проверяется: связь портов ([[play.link]]), опция-файл, наблюдение, отчёт по выходу, история, release аренд.
Порты 25650–25659. Плюс: панель по итоговой истории, sysload."""
import json
import os
import textwrap
import time

import pytest

from conftest import PY, toml_str
from vclab import config
from vclab.quality import sysload
from vclab.daemon.service import Lab

ENGINE = r'''
import os, sys, time
srv = open(os.path.join("export", "server.txt")).read().strip()
walk = os.path.exists(os.path.join("export", "autowalk.txt"))
life = float(sys.argv[1])
def log(lvl, msg):
    t = time.time()
    f.write("[%s] %s.%03d+0300 [           lua-debug] %s\n" % (lvl, time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(t)), int(t * 1000) % 1000, msg))
    f.flush()
with open("latest.log", "w", encoding="utf-8") as f:
    log("I", "[demo] connected to %s in 12.0 ms" % srv)
    log("I", "[demo_app] ready")
    log("I", "[demo] chat: autowalk=%s" % walk)
    n, t0 = 0, time.time()
    while time.time() - t0 < life:
        n += 1
        log("I", "[demo] status tick %d fps %.1f map_chunks %d stored 441 engine 793 dirty 0/0 net in 10 KB, ticks 2.00 ms/tick, encode 1 ms, inflate 1 ms" % (n * 100, 30.0 + n, n * 40))
        if n == 2:
            log("E", "[demo] frame error: boom")
        time.sleep(0.4)
    log("I", "[demo] leaving the world: Disconnect")
'''


def write_project(tmp, life):
    proj = os.path.join(tmp, "projects", "playdemo")
    os.makedirs(proj, exist_ok=True)
    eng = os.path.join(proj, "engine.py")
    with open(eng, "w", encoding="utf-8") as f:
        f.write(ENGINE)
    srv = ("import sys; sys.stderr.write('Done!\\n'); sys.stderr.flush(); "
           "[sys.exit(0) for line in sys.stdin if line.strip() == 'stop']")
    with open(os.path.join(proj, "project.toml"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [project]
        name = "playdemo"
        runs_dir = "{lab_data}\\\\runs_playdemo"

        [kinds.server]
        exe = %(py)s
        ports = ["game"]
        args = ["-c", %(srv)s]
        stdin = true
        default_log = "stderr"
        ready = [ { log = "Done!", stream = "stderr", timeout = 20 } ]
        stop = [ { stdin = "stop\\n", wait_exit = 5 } ]

        [kinds.runtime]
        role = "runtime"
        exe = %(py)s
        args = [%(eng)s, "{param.life}"]
        params = { server = "none", life = %(life)s }
        logs = { latest = "{dir}\\\\latest.log" }
        default_log = "latest"
        kill_on_close = false
        prepare = [ { action = "write", path = "export\\\\server.txt", text = "{param.server}" } ]
        ready = [ { log = "\\\\[demo_app\\\\] ready", stream = "latest", timeout = 20 } ]

        [play]
        order = ["server", "runtime"]
        engine = "runtime"
        names = { runtime = "demo-main" }
        [[play.link]]
        from = "server"
        port = "game"
        to = "runtime"
        param = "server"
        format = "127.0.0.1:{port}"
        [play.options.autowalk]
        files = [ { kind = "runtime", path = "export\\\\autowalk.txt", text = "walk=1\\n" } ]
        [play.report]
        server_kind = "server"
        server_stream = "stderr"
        status = 'status tick (?P<tick>\\d+) fps (?P<fps>[\\d.]+) map_chunks (?P<map_chunks>\\d+)'
        [play.report.events]
        connect = 'connected to (?P<server>\\S+) in'
        chat = 'chat: (?P<text>.*)$'
        disconnect = 'leaving the world: (?P<reason>.*)$'
        """) % {"py": toml_str(PY), "srv": toml_str(srv), "eng": toml_str(eng), "life": json.dumps(str(life))})
    return os.path.join(tmp, "projects")


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    write_project(tmpdir_win, 3.0)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "25650-25659")
    cfg = config.load()
    lb = Lab(cfg, watch=False, background=True)
    lb.tmp = tmpdir_win
    yield lb
    try:
        lb.stop_all()
    except Exception:
        pass
    lb.shutdown()


def wait_state(lab, sid, states, timeout=40):
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = lab.play.status(sid)
        if s["state"] in states:
            return s
        time.sleep(0.2)
    raise AssertionError("play session stuck: %s" % lab.play.status(sid))


def test_play_exit_report_history(lab):
    assert hasattr(lab, "history") and hasattr(lab, "play"), "stage 2b not installed in the daemon"
    # этап 3а: сеанс рантайма — только пользователь из интерактивного CLI (--user) или --final-check
    s = lab.play.start("playdemo", "user", opts=["autowalk"], mode="play", interactive=True, via="cli")
    assert s["state"] == "running" and set(s["leases"]) == {"server", "runtime"}
    assert s["leases"]["runtime"] == "demo-main"
    port = lab.leases[s["leases"]["server"]].ports["game"]
    assert 25650 <= port <= 25659
    # второй старт того же проекта — отказ (рантайм один)
    with pytest.raises(RuntimeError):
        lab.play.start("playdemo", "user", mode="play", interactive=True, via="cli")
    with pytest.raises(PermissionError):                     # агент — отказ политики
        lab.play.start("playdemo", "other")
    done = wait_state(lab, s["id"], ("done", "failed"))
    assert done["state"] == "done", lab.play.status(s["id"]).get("trace")
    rep = json.load(open(os.path.join(done["run_dir"], "play_report.json"), encoding="utf-8"))
    assert rep["ended_by"] == "exit" and rep["metrics"]["status_lines"] >= 5
    assert rep["metrics"]["fps_5s"]["min"] == 31.0
    assert rep["errors_total"] == 1 and rep["disconnect"] == "Disconnect"
    assert [e for e in rep["events"] if e["event"] == "connect"][0]["server"] == "127.0.0.1:%d" % port
    assert [e for e in rep["events"] if e["event"] == "chat"][0]["text"] == "autowalk=True"
    assert rep["server"]["tail"][0].startswith("Done!")
    assert rep["host_load"]["n"] >= 1 and "contended" in rep["host_load"]
    assert os.path.isfile(os.path.join(done["run_dir"], "play_report.md"))
    assert os.path.isfile(os.path.join(done["run_dir"], "engine_latest.log"))
    assert lab.leases == {}                                  # аренды освобождены
    rows = lab.history.runs("playdemo", kind="play")
    assert rows and rows[0]["id"] == done["run"] and lab.history.perf(rows[0]["id"])["fps_5s.min"] == 31.0
    rs = lab.history.runs("playdemo", kind="runtime_session")
    assert rs and rs[0]["tag"] == "play" and rs[0]["extra"]["owner"] == "user" and rs[0]["extra"]["via"] == "cli"


def test_play_stop_and_max_s(lab, tmpdir_win):
    write_project(tmpdir_win, 60.0)                         # движок сам не выходит
    lab.projects.scan()
    s = lab.play.start("playdemo", "claude", mode="final-check", reason="stop path of the session watcher")
    time.sleep(1.5)
    r = lab.play.stop(s["id"], owner="tester", wait=40)
    assert r["state"] == "done" and r["verdict"] in ("done", "crash")
    rep = json.load(open(os.path.join(r["run_dir"], "play_report.json"), encoding="utf-8"))
    assert rep["ended_by"] == "stop:tester" and lab.leases == {}
    s = lab.play.start("playdemo", "claude", max_s=2, mode="final-check", reason="max_s path of the watcher")
    done = wait_state(lab, s["id"], ("done", "failed"))
    assert done["state"] == "done"
    rep = json.load(open(os.path.join(done["run_dir"], "play_report.json"), encoding="utf-8"))
    assert rep["ended_by"] == "max_s"


def test_dashboard_from_history(lab):
    from vclab import dashboard
    from vclab.quality import history as H
    h = lab.history
    T = time.time() - 3600
    for i, p in enumerate((99.0, 98.0, 99.5)):
        h.ingest({"id": "v%d" % i, "ts": T + i, "project": "playdemo", "scenario": "layer_q", "impl": "vc",
                  "kind": "layers", "tag": "t%d" % i, "dir": "D:\\r\\v%d" % i,
                  "shots": [{"name": "0_a", "identical_pct": p, "sha": "s%d" % i}]})
    h.ingest({"id": "pf", "ts": T, "project": "playdemo", "scenario": "perf_normal", "impl": "vc", "kind": "perf",
              "tag": "a1", "dir": "D:\\r\\pf", "perf": {"all.fps_5s.min": 20, "all.fps_5s.p5": 30,
                                                       "all.fps_5s.median": 100}})
    out = dashboard.generate(h, os.path.join(lab.tmp, "dash"), ["playdemo"])
    page = open(out["pages"][0], encoding="utf-8").read()
    assert "layer_q" in page and "<svg" in page and "99.500" in page and "perf_normal" in page
    assert "file:///D:/r/v2" in page
    idx = open(out["index"], encoding="utf-8").read()
    assert "dashboard/playdemo.html" in idx
    summ = open(out["summary"], encoding="utf-8").read()
    assert "layer_q" in summ and "Перф perf_normal" in summ


def test_sysload_sample_and_verdict():
    s = sysload.sample(0.5, with_gpu=False)
    assert 0 <= s["cpu_total_pct"] <= 100 and "busy" in s and isinstance(s["top"], list)
    quiet = {"cpu_others_pct": 2, "user_idle_s": 600, "foreground": {"cpu_pct": 1}, "gpu": None}
    busy = {"cpu_others_pct": 55, "user_idle_s": 3, "top": [{"name": "chrome.exe", "cpu_pct": 40}],
            "foreground": {"name": "chrome.exe", "cpu_pct": 30, "own": False}}
    assert not sysload.flags(quiet)["busy"]
    f = sysload.flags(busy)
    assert f["busy"] and f["user_active"] and len(f["reasons"]) == 2
    v = sysload.verdict([quiet] * 8 + [busy] * 2)
    assert v["contended"] is True and v["busy_share"] == 0.2
    assert sysload.verdict([quiet] * 9 + [busy])["contended"] is False
    eng = dict(quiet, foreign_engines=[{"pid": 1, "name": "voxelcoref2f-v.exe"}])
    assert sysload.flags(eng)["busy"]
