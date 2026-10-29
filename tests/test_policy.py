"""Этап 3а — принуждение правил софтом (vclab/policy.py, service.py, play.py, perf.py), без движка:
- стоковый рантайм: аренда вида role=runtime агентом — отказ policy (403); lab play без --user/--final-check, --user не
  от user / не интерактивно / через MCP, --final-check субагентом или без причины — отказ; копия стокового exe (та же
  sha) в тестовом виде — отказ;
- изоляция: exe движка (копия python.exe с именем VoxelCoreFake.exe + tests/fake_engine.py) без --f2f — отказ;
  hello.flags.input != "isolated" или без flags (старая сборка) — экземпляр убит, isolation-failed; честные флаги —
  ready; clock=realtime на сборке без --f2f-clock — отказ; сборка с ключами — ядро добавляет --f2f-clock/--f2f-window;
- сторож: процесс движка вне аренд — foreign в ps (и не убит);
- lab perf: ожидание простоя (фейковый sysload), отказ, contended, чистый прогон, история.
Порты 25640–25649."""
import json
import os
import shutil
import subprocess
import sys
import textwrap
import time

import psutil
import pytest

from conftest import HERE, PY, toml_str
from vclab import config
from vclab.quality import perf as P
from vclab import policy
from vclab.daemon.service import Lab, LabError

FAKE_ENGINE = os.path.join(HERE, "fake_engine.py")
PYHOME = os.path.dirname(PY)


def write_project(tmp):
    exe_dir = os.path.join(tmp, "exe")
    os.makedirs(exe_dir, exist_ok=True)
    eng = os.path.join(exe_dir, "VoxelCoreFake.exe")          # «exe движка» для ядра (имя voxelcore*)
    shutil.copy2(PY, eng)
    stock = os.path.join(exe_dir, "VoxelCore.exe")             # «стоковый рантайм» (policy.stock_exe подменяется)
    shutil.copy2(PY, stock)
    stock_copy = os.path.join(exe_dir, "VoxelCoreRenamed.exe")  # та же sha под другим именем
    shutil.copy2(PY, stock_copy)
    for p in (stock, stock_copy):
        with open(p, "ab") as f:                               # другое содержимое, чем у «тестовой сборки»
            f.write(b"\0stock-runtime-marker")
    shutil.copystat(PY, stock_copy)
    proj = os.path.join(tmp, "projects", "pol")
    os.makedirs(proj, exist_ok=True)
    env = '{ PYTHONHOME = %s, PATH = %s, FAKE_FLAGS = "{param.flags}", FAKE_VERSION = "{param.version}" }' % (
        toml_str(PYHOME), toml_str(PYHOME))
    with open(os.path.join(proj, "project.toml"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [project]
        name = "pol"
        runs_dir = "{lab_data}\\\\runs_pol"
        plugin = "plugin.py"

        [kinds.eng]
        exe = %(eng)s
        ports = ["f2f"]
        f2f = "f2f"
        cwd = "{dir}"
        args = [%(fake)s, "--f2f", "{port.f2f}", "--dir", "{dir}"]
        env = %(env)s
        params = { flags = "", version = "" }
        default_log = "stdout"
        ready = [ { f2f = "hello", timeout = 20 }, { pump_f2f = { cmd = "hello", field = "frame", value = 2 }, max_frames = 5 } ]
        stop = [ { f2f = "quit", wait_exit = 5 } ]

        [kinds.sep]
        exe = %(eng)s
        ports = ["f2f"]
        f2f = "f2f"
        cwd = "{dir}"
        args = [%(fake)s, "--f2f", "{port.f2f}", "--dir", "{dir}", "--", "--gateway", "7"]
        env = %(env)s
        params = { flags = "", version = "" }
        clock = "realtime"
        ready = [ { f2f = "hello", timeout = 20 } ]
        stop = [ { f2f = "quit", wait_exit = 5 } ]
        [kinds.sep.by_engine.v032]
        size = "320x200"
        window = "normal"
        args = [%(fake)s, "--f2f", "{port.f2f}", "--f2f-size", "{size}", "--dir", "{dir}", "--", "--gateway", "{param.gw}"]
        params = { version = "0.32-f2f", gw = "32" }

        [kinds.noflag]
        exe = %(eng)s
        ports = ["f2f"]
        f2f = "f2f"
        cwd = "{dir}"
        args = [%(fake)s, "--port", "{port.f2f}"]
        env = %(env)s

        [kinds.stockexe]
        exe = %(stock_copy)s
        ports = ["f2f"]
        f2f = "f2f"
        args = ["-c", "import time; time.sleep(30)", "--f2f", "{port.f2f}"]
        env = %(env)s

        [kinds.rt]
        role = "runtime"
        exe = %(py)s
        args = ["-c", "import time; time.sleep(60)"]
        kill_on_close = false

        [kinds.java]
        exe = %(py)s
        ports = ["f2f"]
        f2f = "f2f"
        isolation = { argv = "--f2f", hello = { "flags.input" = "isolated" } }
        args = [%(fake)s, "--f2f", "{port.f2f}"]
        env = { FAKE_FLAGS = "none" }
        ready = [ { f2f = "hello", timeout = 20 } ]

        [play]
        order = ["rt"]
        engine = "rt"
        """) % {"eng": toml_str(eng), "fake": toml_str(FAKE_ENGINE), "env": env, "py": toml_str(PY),
                "stock_copy": toml_str(stock_copy)})
    with open(os.path.join(proj, "plugin.py"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent('''
        PLUGIN_VERSION = 1
        def demo(px, a):
            import json, os
            name = px.lease("eng", params={"flags": ""})
            px.progress("lease %s clock param %s" % (name, px.lab.leases[name].params.get("clock")))
            p = os.path.join(px.out_dir, "perf_summary.json")
            json.dump({"meta": {"name": "demo"}, "all": {"frames": 10, "fps_5s": {"min": 50.0, "p5": 51.0,
                       "median": 60.0, "max": 61.0}}}, open(p, "w"))
            return {"ok": True, "summary_json": p, "lease_clock": px.lab.leases[name].params.get("clock")}
        def register(api):
            api.perf("demo", demo)
        '''))
    return {"eng": eng, "stock": stock, "stock_copy": stock_copy}


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    exes = write_project(tmpdir_win)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "25640-25649")
    monkeypatch.setattr(policy, "stock_exe", lambda: exes["stock"])
    cfg = config.load()
    cfg["watchdog"] = {"enabled": False}
    lb = Lab(cfg, watch=False, background=True)
    lb.exes = exes
    yield lb
    try:
        lb.stop_all()
    except Exception:
        pass
    lb.shutdown()


# ------------------------------------------------------------------------------------------------ стоковый рантайм
def test_runtime_lease_refused_for_agents(lab):
    with pytest.raises(LabError) as e:
        lab.create_lease("pol", "rt", "agent_X")
    assert e.value.code == "policy" and e.value.status == 403 and "play-only" in e.value.message
    with pytest.raises(LabError) as e:                       # mode из прямой аренды не принимается (только lab play)
        lab.create_lease("pol", "eng", "agent_X", mode="play")
    assert e.value.code == "bad-request"
    cases = [
        ("agent_X", None, None, False, "cli", "play-only"),
        ("agent_X", "play", None, True, "cli", "owner must be 'user'"),
        ("user", "play", None, False, "cli", "interactive"),
        ("user", "play", None, True, "mcp", "interactive"),
        ("agent_X", "final-check", "release check of the pack", False, "mcp", "subagents never"),
        ("claude", "final-check", "", False, "mcp", "--reason"),
    ]
    for owner, mode, reason, inter, via, msg in cases:
        with pytest.raises(PermissionError) as e:
            lab.play.start("pol", owner, mode=mode, reason=reason, interactive=inter, via=via)
        assert msg in str(e.value), (owner, mode, str(e.value))
        assert lab.leases == {}
    refused = [x for x in lab.journal.tail(80, top_only=False) if x.get("tool") == "lab.policy_refused"]
    assert len(refused) >= len(cases) + 1
    # через вызов возможности (как HTTP/MCP): PermissionError -> LabError policy
    with pytest.raises(LabError) as e:
        lab.call("core.play", {"project": "pol", "action": "start", "user": True, "interactive": True},
                 owner="agent_X", via="mcp")
    assert e.value.code == "policy"


def test_runtime_final_check_allowed_and_recorded(lab):
    s = lab.play.start("pol", "claude", mode="final-check", reason="release check before tagging 0.31",
                       via="mcp", max_s=4)
    assert s["state"] == "running" and s["mode"] == "final-check", s
    l = lab.leases[s["leases"]["rt"]]
    assert l.mode == "final-check" and l.isolation == {"role": "runtime", "mode": "final-check",
                                                       "reason": "release check before tagging 0.31"}
    t0 = time.time()
    while lab.play.status(s["id"])["state"] not in ("done", "failed") and time.time() - t0 < 30:
        time.sleep(0.2)
    st = lab.play.status(s["id"])
    assert st["state"] == "done", st
    rep = json.load(open(os.path.join(st["run_dir"], "play_report.json"), encoding="utf-8"))
    assert rep["runtime"]["mode"] == "final-check" and rep["runtime"]["reason"].startswith("release check")
    t0 = time.time()
    rows = []
    while time.time() - t0 < 10 and not rows:
        rows = lab.history.runs("pol", kind="runtime_session")
        time.sleep(0.2)
    assert rows and rows[0]["tag"] == "final-check" and rows[0]["extra"]["reason"].startswith("release check")
    assert rows[0]["extra"]["owner"] == "claude"


def test_stock_exe_copy_refused(lab):
    r = lab.create_lease("pol", "stockexe", "agent_X")
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_X")
    assert e.value.code == "policy" and "stock runtime" in e.value.message
    assert lab.leases[r["lease"]["name"]].proc is None           # не запускался


# ------------------------------------------------------------------------------------------------ изоляция
def test_engine_without_f2f_refused(lab):
    r = lab.create_lease("pol", "noflag", "agent_X")
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_X")
    assert e.value.code == "policy" and "--f2f" in e.value.message


def test_isolated_engine_ready(lab):
    r = lab.create_lease("pol", "eng", "agent_X", start=True)
    st = r["start"]
    assert st["isolation"]["verified"] is True and st["isolation"]["flags"]["input"] == "isolated"
    assert st["isolation"]["clock"] == "virtual" and "--f2f-clock" not in st["argv"]   # сборка ключа не знает
    ps = lab.ps()
    assert ps["leases"][0]["isolation"]["verified"] is True


@pytest.mark.parametrize("flags", ['{"input": "os", "clock": "virtual"}', "none"])
def test_isolation_kill(lab, flags):
    r = lab.create_lease("pol", "eng", "agent_X", params={"flags": flags})
    name = r["lease"]["name"]
    with pytest.raises(LabError) as e:
        lab.start(name, owner="agent_X")
    assert e.value.code == "isolation-failed" and e.value.status == 500
    pid = e.value.extra["pid"]
    assert pid and not psutil.pid_exists(pid) or psutil.Process(pid).status() == psutil.STATUS_ZOMBIE
    l = lab.leases[name]
    assert l.state == "failed" and not l.proc.alive()
    assert l.isolation["verified"] is False and l.isolation["mismatch"]
    ev = [x for x in lab.journal.tail(80, top_only=False) if x.get("tool") == "lab.isolation_failed"]
    assert ev and name in ev[-1]["result"]


def test_isolation_generic_kind_kill(lab):
    """Не движок (Java-клиент): требования из дескриптора isolation = {argv, hello} — тот же путь убийства."""
    r = lab.create_lease("pol", "java", "agent_X")
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_X")
    assert e.value.code == "isolation-failed"


def test_realtime_needs_capable_build(lab, monkeypatch):
    r = lab.create_lease("pol", "eng", "agent_X", params={"clock": "realtime"})
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_X")
    assert e.value.code == "start-failed" and "--f2f-clock" in e.value.message
    lab.release(r["lease"]["name"], owner="agent_X")
    # сборка знает ключи -> ядро добавляет их и требует flags.clock == realtime
    monkeypatch.setattr(policy, "exe_caps", lambda p: {"--f2f": True, "--f2f-clock": True, "--f2f-window": True})
    r = lab.create_lease("pol", "eng", "agent_X", params={"clock": "realtime"}, start=True)
    argv = r["start"]["argv"]
    assert argv[argv.index("--f2f-clock") + 1] == "realtime" and argv[argv.index("--f2f-window") + 1] == "hidden"
    assert r["start"]["isolation"]["hello"] == {"flags.input": "isolated", "flags.clock": "realtime"}
    lab.release(r["lease"]["name"], owner="agent_X")
    # сборка сообщает другие часы -> убита
    r = lab.create_lease("pol", "eng", "agent_X", params={"clock": "realtime",
                                                         "flags": '{"input": "isolated", "clock": "virtual"}'})
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_X")
    assert e.value.code == "isolation-failed" and "flags.clock" in e.value.message


def test_policy_units(tmpdir_win):
    p = os.path.join(tmpdir_win, "VoxelCoreX.exe")
    with open(p, "wb") as f:
        f.write(b"MZ....--f2f\x00--f2f-size\x00--f2f-clock\x00")
    assert policy.is_engine_exe(p) and not policy.is_engine_exe("C:\\x\\java.exe")
    caps = policy.exe_caps(p)
    assert caps["--f2f-clock"] and not caps["--f2f-window"]
    assert policy.verify_hello({"flags": {"input": "isolated"}}, {"flags.input": "isolated"}) == []
    assert policy.verify_hello({}, {"flags.input": "isolated"}) == ["flags.input: want 'isolated', got None"]
    assert policy.short_cmd(["java", "-cp", "a" * 500, "Main"]) == "java -cp <cp 500 chars> Main"
    assert policy.owner_class("user") == "user" and policy.owner_class("claude") == "main"
    assert policy.owner_class("agent_P") == "agent"


# ------------------------------------------------------------------------------------------------ сторож
def test_watchdog_reports_foreign(lab):
    env = dict(os.environ, PYTHONHOME=PYHOME, PATH=PYHOME + ";" + os.environ.get("PATH", ""))
    p = subprocess.Popen([lab.exes["eng"], "-c", "import time; time.sleep(60)"], env=env,
                         creationflags=0x08000000)
    try:
        r = lab.create_lease("pol", "eng", "agent_X", start=True)          # своя аренда — не foreign
        own = r["start"]["pid"]
        lab.watchdog.tick()
        fr = {f["pid"]: f for f in lab.ps()["foreign"]}
        assert p.pid in fr and own not in fr
        assert fr[p.pid]["state"] == "foreign" and fr[p.pid]["name"].lower() == "voxelcorefake.exe"
        ev = [x for x in lab.journal.tail(80, top_only=False) if x.get("tool") == "lab.foreign_process"]
        assert any(str(p.pid) in str(x.get("result")) for x in ev)
        lab.watchdog.tick()
        assert p.poll() is None                                             # только отчёт, не убийство
    finally:
        p.kill()


# ------------------------------------------------------------------------------------------------ lab perf
def snap(**kw):
    s = {"t": time.time(), "cpu_total_pct": 5.0, "cpu_others_pct": 2.0, "user_idle_s": 900.0, "gpu": [
        {"name": "g", "util_pct": 1.0, "mem_used_mb": 100.0}], "foreign_engines": [], "top": []}
    s.update(kw)
    return s


TH = dict(P.DEFAULTS, idle_window_s=1.0, wait_idle_s=3.0, sample_every_s=0.1, sample_window_s=0.0)


def test_idle_reasons():
    th = dict(P.DEFAULTS)
    assert P.idle_reasons(snap(), th) == []
    assert "foreign engine" in P.idle_reasons(snap(foreign_engines=[{"name": "java.exe", "pid": 7}]), th)[0]
    assert "other processes" in P.idle_reasons(snap(cpu_others_pct=40.0), th)[0]
    assert "GPU busy" in P.idle_reasons(snap(gpu=[{"util_pct": 80.0}]), th)[0]
    assert P.idle_reasons(snap(gpu=[{"util_pct": 80.0}]), th, gpu_counts=False) == []
    assert "user input" in P.idle_reasons(snap(user_idle_s=3.0), th)[0]
    assert P.idle_reasons(snap(), th, ["lab lease x is running"]) == ["lab lease x is running"]


def test_wait_idle_logic():
    # фейковые часы: 1 с на снимок; занято 3 снимка, потом свободно -> простой после окна 2 с
    clock = {"t": 0.0}
    seq = [snap(user_idle_s=1.0)] * 3 + [snap()] * 10
    it = iter(seq)

    def sample():
        clock["t"] += 1.0
        return next(it)
    th = dict(TH, idle_window_s=2.0, wait_idle_s=20.0, sample_window_s=1.0, sample_every_s=1.0)
    r = P.wait_idle(sample, lambda: [], th, clock=lambda: clock["t"], sleep=lambda s: None)
    assert r["idle"] and r["streak_s"] >= 2.0 and r["waited_s"] <= 6
    # никогда не простаивает -> отказ по таймауту с последними причинами
    clock["t"] = 0.0
    r = P.wait_idle(lambda: (clock.__setitem__("t", clock["t"] + 1.0), snap(cpu_others_pct=50.0))[1],
                    lambda: [], th, clock=lambda: clock["t"], sleep=lambda s: None)
    assert not r["idle"] and r["waited_s"] >= 20 and "other processes" in r["reasons"][0]
    # активность лаборатории — тоже занятость
    clock["t"] = 0.0
    r = P.wait_idle(lambda: (clock.__setitem__("t", clock["t"] + 1.0), snap())[1],
                    lambda: ["lab job j1 is running"], th, clock=lambda: clock["t"], sleep=lambda s: None)
    assert not r["idle"] and r["reasons"] == ["lab job j1 is running"]
    # summarize: хоть один занятый снимок -> contended (contended_share = 0)
    s = P.summarize([{"busy": False}, {"busy": True, "reasons": ["user input 3 s ago < 120 s"]}], dict(P.DEFAULTS))
    assert s["contended"] is True and s["busy_share"] == 0.5
    assert P.summarize([{"busy": False}] * 3, dict(P.DEFAULTS))["contended"] is False


CAPS = {"--f2f": True, "--f2f-clock": True, "--f2f-window": True}


def _perf(lab, sample_fn, allow=False):
    policy.exe_caps = lambda p: CAPS             # «новая сборка»: ключи часов есть (восстанавливает фикстура)
    lab.cfg["perf"] = {k: TH[k] for k in ("idle_window_s", "wait_idle_s", "sample_every_s", "sample_window_s")}
    job = lab.perf.start("pol", "demo", "agent_X", args={"tag": "t1"}, allow_contended=allow, sample_fn=sample_fn)
    t0 = time.time()
    while lab.scen.get(job["id"])["state"] == "running" and time.time() - t0 < 60:
        time.sleep(0.1)
    return lab.scen.get(job["id"], 100)


@pytest.fixture(autouse=True)
def _restore_caps():
    orig = policy.exe_caps
    yield
    policy.exe_caps = orig


def test_perf_refused_when_busy(lab):
    j = _perf(lab, lambda own=(): snap(user_idle_s=2.0))
    assert j["state"] == "failed" and j["result"]["refused"] == "not-idle"
    assert "user input" in j["result"]["reasons"][0] and lab.leases == {}
    assert any("REFUSED" in x for x in j["progress"])


def test_perf_clean_and_contended(lab):
    j = _perf(lab, lambda own=(): snap())
    res = j["result"]
    assert j["state"] == "done" and res["verdict"] == "ok" and res["contended"] is False, j
    assert res["result"]["lease_clock"] == "realtime"                 # аренда движка — часы realtime
    ps = json.load(open(os.path.join(res["dir"], "perf_summary.json"), encoding="utf-8"))
    assert ps["host_load"]["contended"] is False and ps["host_load"]["n"] >= 1
    assert ps["meta"]["scenario"] == "demo" and ps["meta"]["tag"] == "t1" and ps["meta"]["clock"] == "realtime"
    assert lab.leases == {}
    # пользователь вернулся посреди замера -> contended
    calls = {"n": 0}

    def flaky(own=()):
        calls["n"] += 1
        return snap(user_idle_s=1.0) if own else snap()       # во время прогона (есть свои pid) — пользователь активен
    j = _perf(lab, flaky)
    assert j["result"]["verdict"] == "contended" and j["result"]["contended"] is True
    # --allow-contended при занятом ПК: прогон идёт, но сразу contended
    j = _perf(lab, lambda own=(): snap(cpu_others_pct=90.0), allow=True)
    assert j["result"]["contended"] is True and "not idle before the run" in j["result"]["host_load"]["reasons"][0]
    # история: kind perf, contended помечен; ворота такие не сравнивают
    t0 = time.time()
    rows = []
    while time.time() - t0 < 10 and len(rows) < 3:
        rows = lab.history.runs("pol", kind="perf")
        time.sleep(0.2)
    assert sorted(r["contended"] for r in rows) == [0, 1, 1]
    assert {r["scenario"] for r in rows} == {"demo"} and {r["tag"] for r in rows} == {"t1"}


# ------------------------------------------------------------------------------------------------ этап 4a: версия сборки
def _argv(lab, name):
    return json.load(open(os.path.join(lab.leases[name].dir, "argv.json")))


def test_hello_version_per_engine(lab):
    """hello.version принимается по [engines.<id>].f2f_version: 0.31-f2f на v031 (умолчание), 0.32-f2f на v032;
    0.32-f2f на v031 и чужая строка на v032 — engine-mismatch, дерево убито, подсказка --param engine=v032."""
    r = lab.create_lease("pol", "eng", "agent_X", params={"flags": ""})
    st = lab.start(r["lease"]["name"], owner="agent_X")
    iso = st["isolation"]
    assert st["engine"] == "v031" and iso["verified"] and iso["hello_version"] == "0.31-f2f" and iso["version"] == ["0.31-f2f"]
    lab.release(r["lease"]["name"], owner="agent_X")

    r = lab.create_lease("pol", "eng", "agent_X", params={"flags": "", "version": "0.32-f2f"})
    name = r["lease"]["name"]
    with pytest.raises(LabError) as e:
        lab.start(name, owner="agent_X")
    assert e.value.code == "engine-mismatch" and e.value.status == 500, e.value.message
    assert "want '0.31-f2f', got '0.32-f2f'" in e.value.message and "--param engine=v032" in e.value.message
    l = lab.leases[name]
    assert l.state == "failed" and not l.proc.alive() and l.isolation["verified"] is False
    assert any(x.get("tool") == "lab.engine_mismatch" for x in lab.journal.tail(40, top_only=False))
    lab.release(name, owner="agent_X")

    r = lab.create_lease("pol", "eng", "agent_X", params={"flags": "", "version": "0.32-f2f", "engine": "v032"})
    st = lab.start(r["lease"]["name"], owner="agent_X")
    assert st["engine_version"] == "0.32" and st["isolation"]["verified"] and st["isolation"]["hello_version"] == "0.32-f2f"
    assert lab.leases[r["lease"]["name"]].to_dict()["engine_version"] == "0.32"
    lab.release(r["lease"]["name"], owner="agent_X")

    r = lab.create_lease("pol", "eng", "agent_X", params={"flags": "", "version": "0.33-dev", "engine": "v032"})
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_X")
    assert e.value.code == "engine-mismatch" and "'0.33-dev'" in e.value.message


def test_isolation_still_checked_on_v032(lab):
    """На v032 проверка flags.input та же, что на 0.31: без isolated — isolation-failed (версия верная)."""
    r = lab.create_lease("pol", "eng", "agent_X", params={"engine": "v032", "version": "0.32-f2f",
                                                          "flags": json.dumps({"clock": "virtual", "input": "os"})})
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_X")
    assert e.value.code == "isolation-failed" and "flags.input" in e.value.message


def test_engine_flags_before_double_dash_and_by_engine(lab):
    """Ключи --f2f-clock/--f2f-window вставляются ДО `--` (после — аргументы проекта); by_engine.v032 перекрывает
    args/size/window/params вида только для аренды с engine=v032."""
    monkeypatch_caps = pytest.MonkeyPatch()
    monkeypatch_caps.setattr(policy, "exe_caps", lambda p: {"--f2f": True, "--f2f-clock": True, "--f2f-window": True})
    try:
        _double_dash(lab)
    finally:
        monkeypatch_caps.undo()


def _double_dash(lab):
    r = lab.create_lease("pol", "sep", "agent_X")
    st = lab.start(r["lease"]["name"], owner="agent_X")
    a = _argv(lab, r["lease"]["name"])
    i = a.index("--")
    assert a.index("--f2f-clock") < i and a.index("--f2f-window") < i and a[i + 1:] == ["--gateway", "7"], a
    assert st["isolation"]["flags"]["clock"] == "realtime" and st["isolation"]["window"] == "hidden"
    lab.release(r["lease"]["name"], owner="agent_X")

    r = lab.create_lease("pol", "sep", "agent_X", params={"engine": "v032"})
    st = lab.start(r["lease"]["name"], owner="agent_X")
    a = _argv(lab, r["lease"]["name"])
    i = a.index("--")
    assert a[a.index("--f2f-size") + 1] == "320x200" and a[i + 1:] == ["--gateway", "32"], a
    assert a[a.index("--f2f-window") + 1] == "normal" and a.index("--f2f-window") < i
    assert st["engine_version"] == "0.32" and st["isolation"]["hello_version"] == "0.32-f2f"
    lab.release(r["lease"]["name"], owner="agent_X")


def test_f2f_after_double_dash_is_not_isolation(lab, tmpdir_win):
    """`--f2f` только среди аргументов проекта (после `--`) не считается: отказ policy."""
    proj = os.path.join(tmpdir_win, "projects", "pol", "project.toml")
    src = open(proj, encoding="utf-8").read()
    with open(proj, "a", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [kinds.late]
        exe = %s
        ports = ["f2f"]
        f2f = "f2f"
        args = ["-c", "import time; time.sleep(30)", "--", "--f2f", "{port.f2f}"]
        """) % toml_str(lab.exes["eng"]))
    try:
        lab.projects.scan()
        assert "late" in lab.projects.get("pol").kinds
        r = lab.create_lease("pol", "late", "agent_X")
        with pytest.raises(LabError) as e:
            lab.start(r["lease"]["name"], owner="agent_X")
        assert e.value.code == "policy" and "--f2f" in e.value.message
    finally:
        open(proj, "w", encoding="utf-8").write(src)


def test_engines_info(lab):
    info = lab.engines_info()
    v32 = info["v032"]
    assert v32["f2f_version"] == "0.32-f2f" and info["v031"]["f2f_version"] == "0.31-f2f"
    f = v32["files"]["f2f"]
    if not f["exists"]:
        pytest.skip("VoxelCoreF2F-032.exe is not on this machine")
    assert len(f["sha256"]) == 64 and f["f2f"]["--f2f"] and f["f2f"]["--f2f-clock"] and f["f2f"]["--f2f-window"]
    assert not f["stock"] and v32["files"]["stock"]["stock"] and "exe" not in v32["files"]   # exe == builds.f2f


def test_daemon_stop_refused_with_live_leases(monkeypatch, tmpdir_win):
    """labctl stop против демона старого кода (нет /daemon/info, этап 5 — запасной путь клиента): роль admin и отказ
    при любой аренде (02.10: рестарт демона ради правки ядра убил сессию другого агента). Аудит — в <data>\\audit.jsonl."""
    from vclab.cli import labctl as labctl
    posted = []

    class Stub:
        def __init__(self, port=None, owner=None, role=None):
            self.port, self.owner, self.role = port or 1, owner or "someone@cli", role

        def alive(self, *a):
            return {"pid": 999999999, "data": tmpdir_win}

        def get(self, path):
            if path == "/daemon/info":
                return {"detail": "Not Found"}
            return {"leases": [{"name": "srv-world-1", "owner": "srv_w2", "state": "ready", "proc": {"alive": True}},
                               {"name": "x-dead-1", "owner": "a", "state": "dead", "proc": {"alive": False}}]}

        def post(self, path, body=None):
            posted.append(path)
            return {"ok": True}

    monkeypatch.setattr(labctl, "LabClient", Stub)
    r = labctl.stop()                                         # агент (не из [roles].admins)
    assert not r["ok"] and r["error"] == "admin-required" and posted == []
    r = labctl.stop(owner="claude", role="agent")             # главная сессия с --as-agent — тоже agent
    assert not r["ok"] and r["error"] == "admin-required" and posted == []
    r = labctl.stop(owner="claude")
    assert not r["ok"] and r["error"] == "live-leases" and "srv-world-1 (srv_w2, ready)" in r["message"]
    assert r["live"] == ["srv-world-1 (srv_w2, ready)"] and posted == []
    r = labctl.stop(owner="claude", force=True)
    assert r["ok"] and posted == ["/shutdown"]
    from vclab.daemon.admin import read_audit
    au = read_audit(os.path.join(tmpdir_win, "audit.jsonl"))
    assert [(e["owner"], e["result"], e.get("error")) for e in au] == [
        ("someone@cli", "refused", "admin-required"), ("claude", "refused", "admin-required"),
        ("claude", "refused", "live-leases"), ("claude", "ok", None)]
    assert au[-1]["legacy_daemon"] and len(au[-1]["leases"]) == 2
