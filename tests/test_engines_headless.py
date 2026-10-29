"""Этап 4 (без движка): версия движка — измерение; политика headless; канал stdin.
- engines: [engines.*] проекта поверх lab.toml, engine вида, параметр аренды engine, engine = "none", неизвестный —
  bad-request, подстановки {engine.*}, поля аренды engine/engine_version, run meta, ps;
- история: столбец engine_version (миграция старой базы), фильтр, записи без версии = 0.31; ворота: последний прогон
  на версию, основание и храповик только своей версии;
- headless: стоковый exe (любой версии: policy.EXTRA_STOCK) в виде role=headless — можно, окна проверяются (нет окон —
  verified); без --headless — отказ; процесс с окном верхнего уровня — убит, isolation-failed; стоковый exe другой
  версии в тестовом (оконном) виде — отказ;
- stdin: lab.stdin -> новые строки лога (pattern), вид без stdin — no-stdin; console_poke: читатель как у VoxelCore
  (_kbhit консоли + строка из канала) без события молчит, с событием читает.
Порты 25620–25629."""
import json
import os
import shutil
import sqlite3
import textwrap
import time

import pytest

from conftest import HERE, PY, toml_str
from vclab import config
from vclab.quality import gate as G
from vclab.quality import history as H
from vclab import policy
from vclab.leases import procs
from vclab.daemon.service import Lab, LabError

FAKE = os.path.join(HERE, "fake_world.py")
PYHOME = os.path.dirname(PY)


def write_project(tmp):
    exe_dir = os.path.join(tmp, "exe")
    os.makedirs(exe_dir, exist_ok=True)
    stock_a = os.path.join(exe_dir, "VoxelCore.exe")             # «стоковый 0.31» (policy.stock_exe подменяется)
    stock_b_dir = os.path.join(tmp, "vc032")
    os.makedirs(stock_b_dir, exist_ok=True)
    stock_b = os.path.join(stock_b_dir, "VoxelCore.exe")          # «стоковый 0.32» другого содержимого
    for p, mark in ((stock_a, b"\0stock-031"), (stock_b, b"\0stock-032")):
        shutil.copy2(PY, p)
        with open(p, "ab") as f:
            f.write(mark)
    proj = os.path.join(tmp, "projects", "eng")
    os.makedirs(proj, exist_ok=True)
    env = '{ PYTHONHOME = %s, PATH = %s }' % (toml_str(PYHOME), toml_str(PYHOME))
    with open(os.path.join(proj, "project.toml"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [project]
        name = "eng"
        runs_dir = "{lab_data}\\\\runs_eng"

        [engines]
        default = "vA"
        [engines.vA]
        version = "9.1"
        res = "{project_dir}\\\\resA"
        stock = %(stock_a)s
        builds = { f2f = "x" }
        [engines.vB]
        version = "9.2"
        res = "{project_dir}\\\\resB"
        stock = %(stock_b)s

        [kinds.plain]
        exe = %(py)s
        args = [%(fake)s, "headless", "--res", "{engine.res}", "--ver", "{engine.version}"]
        default_log = "stdout"
        ready = [ { log = "ready", stream = "stdout", timeout = 20 } ]

        [kinds.onB]
        engine = "vB"
        exe = %(py)s
        args = [%(fake)s, "headless", "--res", "{engine.res}"]
        ready = [ { log = "ready", stream = "stdout", timeout = 20 } ]
        default_log = "stdout"

        [kinds.noengine]
        engine = "none"
        exe = %(py)s
        args = ["-c", "print('x')"]

        [kinds.hl]
        role = "headless"
        engine = "vB"
        exe = "{engine.stock}"
        env = %(env)s
        args = [%(fake)s, "{param.mode}", "--headless"]
        params = { mode = "headless" }
        default_log = "stdout"
        window_check_s = 1.0
        ready = [ { log = "ready", stream = "stdout", timeout = 20 } ]

        [kinds.hl_noflag]
        role = "headless"
        engine = "vB"
        exe = "{engine.stock}"
        env = %(env)s
        args = [%(fake)s, "headless"]

        [kinds.stock_window]
        engine = "vB"
        exe = "{engine.stock}"
        env = %(env)s
        args = [%(fake)s, "headless", "--f2f", "1"]

        [kinds.kb]
        exe = %(py)s
        args = ["-u", %(fake)s, "kbhit"]
        stdin = true
        stdin_poke = "console"
        default_log = "stdout"
        ready = [ { log = "\\\\[kbhit\\\\] ready", stream = "stdout", timeout = 20 } ]

        [kinds.echo]
        exe = %(py)s
        args = ["-u", "-c", "import sys\\nfor l in sys.stdin: print('echo', l.strip(), flush=True)"]
        stdin = true
        default_log = "stdout"
        """) % {"py": toml_str(PY), "fake": toml_str(FAKE), "env": env, "stock_a": toml_str(stock_a),
                "stock_b": toml_str(stock_b)})
    return {"stock_a": stock_a, "stock_b": stock_b}


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    exes = write_project(tmpdir_win)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "25620-25629")
    monkeypatch.setattr(policy, "stock_exe", lambda: exes["stock_a"])
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
    policy.EXTRA_STOCK[:] = []


# ------------------------------------------------------------------------------------------------ движки
def test_engine_dimension_on_leases(lab):
    r = lab.create_lease("eng", "plain", "agent_E", start=True)
    l = r["lease"]
    assert (l["engine"], l["engine_version"]) == ("vA", "9.1")              # умолчание проекта
    assert r["start"]["engine_version"] == "9.1"
    argv = r["start"]["argv"]
    assert argv[argv.index("--ver") + 1] == "9.1" and argv[argv.index("--res") + 1].endswith("resA")
    run = lab.runs.active[lab.leases[l["name"]].run]
    assert run["meta"]["exe"][l["name"]]["engine_version"] == "9.1" and run["meta"]["engines"][l["name"]] == "9.1"
    r2 = lab.create_lease("eng", "plain", "agent_E", params={"engine": "vB"}, start=True)    # параметр перекрывает
    assert r2["lease"]["engine_version"] == "9.2" and r2["start"]["argv"][-1] == "9.2"
    r3 = lab.create_lease("eng", "onB", "agent_E")
    assert r3["lease"]["engine"] == "vB"
    r4 = lab.create_lease("eng", "noengine", "agent_E")
    assert r4["lease"]["engine"] is None and r4["lease"]["engine_version"] is None
    with pytest.raises(LabError) as e:
        lab.create_lease("eng", "plain", "agent_E", params={"engine": "v999"})
    assert e.value.code == "bad-request" and "unknown engine" in e.value.message
    ps = {x["name"]: x for x in lab.ps()["leases"]}
    assert ps[l["name"]]["engine_version"] == "9.1" and ps[r2["lease"]["name"]]["engine_version"] == "9.2"
    from vclab.cli import lab as cli                                                       # lab ps --table: столбец engine
    table = cli.ps_table(lab.ps())
    assert "engine" in table.splitlines()[0] and " 9.2 " in table
    engs = lab.engines(lab.projects.get("eng"))
    assert {"vA", "vB", "v031", "v032"} <= set(engs)                         # lab.toml + проект
    assert lab.default_engine(None) == "v031" and lab.default_engine(lab.projects.get("eng")) == "vA"
    assert lab.exes["stock_b"] in policy.EXTRA_STOCK                         # стоковые exe всех версий известны политике


def rec(rid, scen, ts, pct, sha, engine=None):
    return {"id": rid, "ts": ts, "project": "p", "scenario": scen, "impl": "vc", "kind": "layers", "verdict": "ok",
            "dir": "D:\\runs\\" + rid, "source": "lab-scenario", "engine_version": engine,
            "shots": [{"name": "f0", "sha": sha, "identical_pct": pct}]}


def test_history_and_gate_by_engine(tmpdir_win):
    path = os.path.join(tmpdir_win, "h.sqlite")
    db = sqlite3.connect(path)                                               # база до этапа 4: без столбца
    db.executescript(H.SCHEMA.replace(", engine_version TEXT", ""))
    db.execute("INSERT INTO runs(id, ts, project, scenario, impl, kind) VALUES('old', 1, 'p', 'layer_a', 'vc', "
               "'layers')")
    db.commit()
    db.close()
    h = H.History(path)
    try:
        cols = {r["name"] for r in h.q("PRAGMA table_info(runs)")}
        assert "engine_version" in cols
        assert H.engine_of(h.runs("p")[0]) == "0.31"                          # без версии = 0.31
        T = 1_800_000_000
        h.ingest(rec("a1", "layer_a", T, 99.0, "A"))                          # 0.31 (без версии), лучший
        h.ingest(rec("a2", "layer_a", T + 10, 98.99, "A2"))                   # 0.31 latest
        h.ingest(rec("b1", "layer_a", T + 20, 90.0, "B", "0.32"))             # 0.32: первый
        h.ingest(rec("b2", "layer_a", T + 30, 91.0, "B2", "0.32"))            # 0.32 latest, лучше своего
        assert [r["id"] for r in h.runs("p", engine="0.32")] == ["b2", "b1"]
        assert {r["id"] for r in h.runs("p", engine="0.31")} == {"a1", "a2", "old"}
        cfg = G.gate_cfg(None)
        cfg["eps"] = 0.05
        res = G.evaluate(h, "p", "all", cfg)
        runs = {r["id"]: r for r in res["runs"]}
        assert set(runs) == {"a2", "b2"} and runs["b2"]["engine_version"] == "0.32"
        assert res["engines"] == ["0.31", "0.32"]
        # 0.32 (91 %) не регрессия против лучшего 0.31 (99 %): основание — только своя версия (90 -> 91 улучшение)
        assert not res["regressions"], res["regressions"]
        imp = {(x["run"], x["frame"]): x for x in res["improved"]}
        assert ("b2", "f0") in imp and imp[("b2", "f0")]["base_run"] == "b1"
        h.accept("p", "layer_a", "f0", 99.5, "Z", "a1")                       # храповик принят на 0.31
        res = G.evaluate(h, "p", "all", cfg)
        reg = {x["run"] for x in res["regressions"]}
        assert reg == {"a2"}, res["regressions"]                              # 0.31 против храповика; 0.32 — нет
        md = G.report_md(res)
        assert "Версии движка: 0.31, 0.32" in md and "| layer_a | 0.31 | f0 |" in md
        rows = H.table(h.summary_rows("p", last=10))
        assert "engine" in rows.splitlines()[0] and "0.32" in rows
        cnt = {(c["engine_version"]): c["n"] for c in h.counts("p")}
        assert cnt == {"0.31": 3, "0.32": 2}
    finally:
        h.close()


def test_history_engine_from_lab_report(tmpdir_win):
    d = os.path.join(tmpdir_win, "20261002_120000_vc_world_vc")
    os.makedirs(d)
    report = {"id": os.path.basename(d), "project": "vc", "opened": 1.0, "closed": 2.0,
              "meta": {"exe": {"vc-vctest-1": {"sha256": "ab", "engine": "v032", "engine_version": "0.32"}}},
              "scenario": {"harness": "lab-scenario/1", "kind": "vctest", "engine_version": "0.32",
                           "results": [{"scenario": "world", "kind": "vctest", "ok": True, "exit_code": 0,
                                        "engine_version": "0.32", "dur": 0.5, "shots": []}]}}
    with open(os.path.join(d, "report.json"), "w") as f:
        json.dump(report, f)
    recs = H.parse_dir(d, "vc")
    assert recs and recs[0]["engine_version"] == "0.32" and recs[0]["kind"] == "vctest"
    assert recs[0]["perf"]["exit_code"] == 0.0


# ------------------------------------------------------------------------------------------------ headless
def test_headless_stock_allowed_no_window(lab):
    r = lab.create_lease("eng", "hl", "agent_E", start=True)
    iso = r["start"]["isolation"]
    assert iso["role"] == "headless" and iso["stock"] is True and iso["verified"] is True and iso["windows"] == []
    assert iso["window_checks"] >= 2
    assert r["start"]["exe"] == lab.exes["stock_b"]
    from vclab.cli import lab as cli
    assert "headless:STOCK" in cli.ps_table(lab.ps())


def test_headless_without_flag_refused(lab):
    r = lab.create_lease("eng", "hl_noflag", "agent_E")
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_E")
    assert e.value.code == "policy" and "--headless" in e.value.message
    assert lab.leases[r["lease"]["name"]].proc is None


def test_stock_other_version_in_window_kind_refused(lab):
    r = lab.create_lease("eng", "stock_window", "agent_E")
    with pytest.raises(LabError) as e:
        lab.start(r["lease"]["name"], owner="agent_E")
    assert e.value.code == "policy" and "stock runtime" in e.value.message
    assert lab.leases[r["lease"]["name"]].proc is None


def test_headless_with_window_killed(lab):
    r = lab.create_lease("eng", "hl", "agent_E", params={"mode": "window"})
    name = r["lease"]["name"]
    with pytest.raises(LabError) as e:
        lab.start(name, owner="agent_E")
    assert e.value.code == "isolation-failed" and "window" in e.value.message
    assert e.value.extra["windows"] and e.value.extra["windows"][0]["cls"].lower() == "static"
    l = lab.leases[name]
    assert l.state == "failed" and not l.proc.alive()
    ev = [x for x in lab.journal.tail(50, top_only=False) if x.get("tool") == "lab.isolation_failed"]
    assert ev and "headless" in str(ev[-1].get("result"))


def test_top_windows_readonly():
    import ctypes
    hwnd = ctypes.windll.user32.CreateWindowExW(0, "STATIC", "lab-test-own", 0, 0, 0, 5, 5, None, None, None, None)
    try:
        wins = policy.top_windows([os.getpid()])
        assert any(w["hwnd"] == hwnd and not w["visible"] for w in wins)
        assert policy.top_windows([]) == []
    finally:
        ctypes.windll.user32.DestroyWindow(hwnd)


# ------------------------------------------------------------------------------------------------ stdin
def test_stdin_channel(lab):
    r = lab.create_lease("eng", "echo", "agent_E", start=True)
    name = r["lease"]["name"]
    out = lab.stdin(name, "hello world", owner="agent_E", wait=5, pattern="echo hello world")
    assert out["matched"] is True and out["lines"][-1] == "echo hello world" and out["poke"] is None
    with pytest.raises(LabError) as e:
        lab.stdin(name, "x", owner="agent_Other")
    assert e.value.code == "not-owner"
    r2 = lab.create_lease("eng", "plain", "agent_E", start=True)
    with pytest.raises(LabError) as e:
        lab.stdin(r2["lease"]["name"], "x", owner="agent_E")
    assert e.value.code == "no-stdin"
    res = lab.call("core.stdin", {"lease": name, "text": "via feature", "pattern": "via feature"}, owner="agent_E")
    assert res["result"]["matched"] is True


def test_console_poke_like_voxelcore_reader(lab):
    """Читатель как у VoxelCore --stdin-cmd на Windows (_kbhit консоли, строка из канала): без события молчит."""
    r = lab.create_lease("eng", "kb", "agent_E", start=True)
    name = r["lease"]["name"]
    out = lab.stdin(name, "first", owner="agent_E", wait=1.5, pattern="got first", poke=False)
    assert out["matched"] is False and out["poke"] is False                 # строка лежит в канале, читатель ждёт kbhit
    out = lab.stdin(name, "second", owner="agent_E", wait=5, pattern="got second")
    assert out["poke"]["ok"] is True, out["poke"]
    assert out["matched"] is True and "got first" in out["lines"], out    # после события — обе строки по порядку
    out = lab.stdin(name, "third", owner="agent_E", wait=5, pattern="got third")
    assert out["matched"] is True and out["poke"] is None                 # событие нужно один раз
