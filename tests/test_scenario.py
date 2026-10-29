"""Интерпретатор сценариев на фейковом F2F (vclab/scenario/scenario.py): наследование base, шаги F2F / ядра / плагина,
expect, optional, translate, размер кадра, lockstep-хук, таймлайн (такты, ключевые кадры, state_every, gui как шаг),
каталог прогона (снимки, states.jsonl, report.json, журнал), освобождение аренд. Порты 25680–25689."""
import json
import os

import pytest

from vclab import config
from vclab.scenario import scenario
from vclab.daemon.service import Lab
from scen_project import write_scen_project


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    write_scen_project(tmpdir_win)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "25680-25689")
    cfg = config.load()
    lb = Lab(cfg, watch=False, background=True)
    lb.tmp = tmpdir_win
    assert "scen" in lb.projects.projects, lb.projects.errors
    assert not lb.projects.projects["scen"].plugin_error, lb.projects.projects["scen"].plugin_error
    yield lb
    lb.stop_all()
    lb.shutdown()


def run(lab, names, impl="a", **opts):
    j = lab.scen.start("scen", names if isinstance(names, list) else [names], impl, "tester", opts=opts, wait=True)
    rep = json.load(open(os.path.join(j["dir"], "report.json"), encoding="utf-8"))
    return j, rep, rep["scenario"]


def test_load_base_and_size(lab):
    proj, (s,) = lab.scen.load("scen", ["child"])
    assert [st["cmd"] for st in s.prefix] == ["step"]           # base до первого mode
    assert s.body[0]["cmd"] == "mode" and s.size == "4x2" and s.setup == {"world": "w1"}
    assert [c["name"] for c in s.chain] == ["child", "base"] and len(s.sha256) == 64
    _, (w,) = lab.scen.load("scen", ["wide"])
    assert w.size == "8x8"
    with pytest.raises(scenario.ScenarioError, match="different frame sizes"):
        lab.scen.start("scen", ["child", "wide"], "a", "tester")
    with pytest.raises(scenario.ScenarioError, match="impl"):
        lab.scen.start("scen", ["child"], "zz", "tester")
    with pytest.raises(scenario.ScenarioError, match="no scenario"):
        lab.scen.load("scen", ["nope"])


def test_steps_run(lab):
    j, rep, sc = run(lab, "child")
    assert j["verdict"] == "ok" and sc["ok"], sc.get("error")
    r = sc["results"][0]
    shots = {s["name"]: s for s in r["shots"]}
    assert list(shots) == ["s3", "s5", "s6k"]
    # кадр фейка = f(такт, нажатые клавиши): s3 после step 3 от mode, s5 после wait (шаг плагина), s6k с клавишей
    from vclab.quality.compare import load_rgb
    px = lambda n: tuple(int(v) for v in load_rgb(os.path.join(j["dir"], shots[n]["file"]))[0, 0])
    assert px("s3") == (10, 3, 30) and px("s5") == (10, 5, 30) and px("s6k") == (10, 6, 70)
    for s in shots.values():
        assert s["sha256"] == s["sha256_rgb"] and len(s["file_sha256"]) == 64 and (s["w"], s["h"]) == (4, 2)
    steps = {e["n"]: e for e in r["steps"]}
    assert steps[1]["ok"] and steps[1]["cmd"] == "mode"                       # n — сквозной номер (префикс 1 шаг)
    assert steps[4]["result"] == {"frames": 2, "tick": 5}                       # wait плагина
    assert not steps[9]["ok"] and "unknown-command" in steps[9]["error"]        # bogus optional — не остановил
    lines = [json.loads(x) for x in open(os.path.join(j["dir"], r["out"], "states.jsonl"), encoding="utf-8")]
    assert [l["n"] for l in lines] == [5, 8]
    assert lines[1]["state"]["last_input"] == {"keys": {"K3": True}}            # translate плагина
    assert sc["prefix"]["steps"][0]["cmd"] == "step"
    assert sc["inputs"]["scenario"]["sha256"] == r["sha256"] and sc["inputs"]["info"] == {"world": "w1"}
    assert set(sc["inputs"]["inputs"]) == {"patch", "world", "opt"}            # only_b — не для impl a
    assert sc["inputs"]["inputs"]["opt"]["absent"]
    # аренды освобождены, журнал прогона есть, run закрыт с вердиктом
    assert not lab.leases
    tools = [json.loads(x)["tool"] for x in open(os.path.join(j["dir"], "journal.jsonl"), encoding="utf-8")]
    assert "scenario.step" in tools and "lab.release" in tools
    assert rep["verdict"] == "ok" and rep["closed"]
    assert any(e["name"].startswith("child/") for e in rep["shots"])           # снимки и в отчёте прогона демона


def test_expect_fails_and_releases(lab):
    j, rep, sc = run(lab, "bad_expect")
    assert j["verdict"] == "failed" and not sc["ok"]
    r = sc["results"][0]
    assert "expect: tick 1 != 99" in r["error"] and r["shots"] == []
    assert not lab.leases


def test_shot_size_checked(lab):
    j, rep, sc = run(lab, "wide")
    assert not sc["ok"] and "scenario size 8x8" in sc["results"][0]["error"]


def test_lockstep_hook(lab):
    j, rep, sc = run(lab, "lock")
    # 3 такта клиента — 3 шага сервера, все через lockstep_tick плагина (этап 3б)
    assert sc["ok"] and sc["finish"] == {"server_steps": 3, "ticks": ["step"] * 3}
    assert sc["server_mode"] == "lockstep" and sc["inputs"]["server"] == "lockstep"


def test_lockstep_run_and_realtime(lab):
    j, rep, sc = run(lab, "lock_in")
    assert sc["ok"] and sc["finish"]["ls_inputs"] == 1 and sc["finish"]["server_steps"] == 2   # input забран плагином
    st = [e for e in sc["results"][0]["steps"] if e["cmd"] == "state"][0]["result"]
    assert st["last_input"] == {"keys": {"K3": True}} and st["tick"] == 2
    # --realtime: тот же сценарий без lockstep — ни хуков, ни шагов сервера; ключ golden server=realtime
    j, rep, sc = run(lab, "lock", realtime=True)
    assert sc["ok"] and sc["finish"] == {"server_steps": 0}
    assert sc["server_mode"] == "realtime" and sc["inputs"]["server"] == "realtime"
    assert sc["inputs"]["id"] != run(lab, "lock")[2]["inputs"]["id"]


def test_lockstep_timeline(lab):
    j, rep, sc = run(lab, "tl_lock")
    r = sc["results"][0]
    assert sc["ok"], r.get("error")
    t = sc["finish"]["ticks"]
    assert len(t) == 10 and t[6] == "gui" and t.count("gui") == 1          # gui-такт — тоже через lockstep_tick
    assert sc["finish"]["server_steps"] == 10 and r["timeline"]["lockstep"] and r["timeline"]["pace_ms"] == 0


def test_lockstep_project_default():
    class P:
        name, scenario_hooks = "x", {}
        scenario = {"server_f2f": True}
    b = scenario.Scenario("b", "b.json", {"steps": []}, "0" * 64)
    s = scenario.Scenario("l", "l.json", {"steps": []}, "0" * 64)
    s.base = b
    off = scenario.Scenario("o", "o.json", {"setup": {"server": {"f2f": False}}, "steps": []}, "0" * 64)
    assert not s.lockstep
    for x in (s, off):
        scenario.set_lockstep_default(x, P())
    assert s.lockstep and b.lockstep and s.lockstep_declared is None
    assert not off.lockstep and off.lockstep_declared is False                # объявленное сильнее умолчания


def test_lockstep_without_hook_refused():
    class P:
        name, scenario, scenario_hooks = "x", {}, {}
    s = scenario.Scenario("l", "l.json", {"server": {"f2f": True}, "steps": []}, "0" * 64)
    s.size = "4x2"
    with pytest.raises(scenario.ScenarioError, match="server_step"):
        scenario.ScenarioService(None).check(P(), [s], "a")


def test_timeline(lab):
    j, rep, sc = run(lab, "tl")
    assert sc["ok"], sc.get("error")
    r = sc["results"][0]
    assert [s["name"] for s in r["shots"]] == ["kf_0003", "kf_0010"]
    assert r["timeline"]["last_tick"] == 10 and r["tick_mismatch"]["count"] == 0
    assert [s["tick"] for s in r["shots"]] == [3, 10]
    st = [json.loads(x) for x in open(os.path.join(j["dir"], r["out"], "states.jsonl"), encoding="utf-8")]
    assert [x["tick"] for x in st] == [3, 5, 10] and st[0]["kf"] and not st[1]["kf"]
    assert st[0]["state"]["tick"] == 3 and st[2]["state"]["chat"][0]["text"] == "hi"
    ev = [(e["tick"], e["cmd"]) for e in r["events"]]
    assert ev == [(0, "input"), (4, "chat"), (6, "gui")]
    setup = [e["cmd"] for e in r["steps"]]
    assert setup == ["step", "mode"]                                            # setup.steps + mode (такт 0)
    assert r["steps"][1]["args"] == {"fixed": True, "seed": 7}                  # timeline_mode проекта


def test_compare_runs_and_series(lab):
    from vclab.quality.compare import compare_api
    a, _, _ = run(lab, "child")
    b, _, _ = run(lab, "child")
    r = compare_api(lab, a["run"], b["run"], project="scen")
    assert r["ok"] and r["summary"]["all_identical"] and r["summary"]["sha_equal"] == 3, r
    assert os.path.exists(os.path.join(r["out"], "report.md"))
    t1, _, _ = run(lab, "tl")
    t2, _, _ = run(lab, "tl")
    r = compare_api(lab, t1["run"], t2["run"], project="scen")
    s = r["per_scenario"]["tl"]
    assert s["keyframes"] == 2 and s["keyframes_100"] == 2 and s["first_divergence_tick"] is None, r
    cj = json.load(open(os.path.join(r["out"], "compare.json"), encoding="utf-8"))
    assert cj["scenarios"]["tl"]["series"]["summary"]["states_compared"] == 3
    assert os.path.exists(cj["scenarios"]["tl"]["series"]["summary"]["drift_png"])
