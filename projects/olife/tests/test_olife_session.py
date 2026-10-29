"""Этап 4 (без движка): жизненный цикл сессии olife на фейковых процессах — настоящие plugin.py, gateway.py, sandbox.py
проекта olife, мир и боты — tests/fake_olife.py (тот же протокол заглушки). Проект копируется во временный каталог под
именем olf (виды world/bot подменены фейками), чтобы не трогать настоящий дескриптор.
- olife.session {clients:2}: аренды world, gateway, sandbox, 2 клиента одной сессии, порты из пула, связь портов;
- состояние по тактам: 0 расхождений, задержка и байты шлюза; stdin миру (status);
- olife.release: обратный порядок, все мягко (exit 0), аренд и портов не осталось;
- сценарии: consistency ok + метрики в отчёте + история kind olife; расходящийся клиент -> failed; негативный (заглушка
  песочницы) ok; ошибка старта (шлюз не поднялся) -> вся сессия освобождена.
Порты 25610–25619."""
import json
import os
import shutil
import textwrap
import time

import pytest

from conftest import HERE, PY, toml_str
from vclab import config
from vclab import policy
from vclab.daemon.service import Lab, LabError

FAKE = os.path.join(HERE, "fake_olife.py")
OLIFE = os.path.join(os.path.dirname(HERE), "projects", "olife")


def write_project(tmp):
    proj = os.path.join(tmp, "projects", "olf")
    os.makedirs(os.path.join(proj, "scenarios"), exist_ok=True)
    for f in os.listdir(OLIFE):                    # plugin.py и его модули (sandbox_real.py, gateway_rs.py волн 3a/3g)
        if f.endswith(".py"):
            shutil.copy2(os.path.join(OLIFE, f), os.path.join(proj, f))
    for f in ("olife_consistency.json",):
        shutil.copy2(os.path.join(OLIFE, "scenarios", f), os.path.join(proj, "scenarios", f))
    # обвязка негативных попыток на заглушке (exec -> denied). Сценарий проекта olife_negative с волны 3a гоняет
    # настоящий olife-sandboxd (шаги olife_spawn/olife_sandbox_check), поэтому обвязка живёт только здесь
    with open(os.path.join(proj, "scenarios", "olf_negative_harness.json"), "w") as f:
        json.dump({"setup": {"session": {"clients": 0, "sandbox": True}},
                   "steps": [{"cmd": "olife_sandbox", "args": {"budget_ms": 500}},
                             {"cmd": "olife_stdin", "args": {"cmd": "status", "pattern": "status tick=", "wait": 3}}]}, f)
    with open(os.path.join(proj, "scenarios", "olf_short.json"), "w") as f:
        json.dump({"setup": {"session": {"clients": 2, "client_kind": "bot", "sandbox": False}},
                   "steps": [{"cmd": "olife_run", "args": {"seconds": 2}},
                             {"cmd": "olife_stdin", "args": {"cmd": "status", "pattern": "status tick="}},
                             {"cmd": "olife_consistency", "args": {"max_divergences": 0, "min_ticks": 10}},
                             {"cmd": "olife_metrics"}]}, f)
    with open(os.path.join(proj, "scenarios", "olf_diverge.json"), "w") as f:
        json.dump({"setup": {"session": {"clients": 1, "client_kind": "badbot", "sandbox": False}},
                   "steps": [{"cmd": "olife_run", "args": {"seconds": 2}},
                             {"cmd": "olife_consistency", "args": {"max_divergences": 0, "min_ticks": 10}}]}, f)
    # шлюз и песочница — лабораторные заглушки проекта (gateway.py — TCP-реле протокола заглушки, sandbox.py — всё
    # отклоняет): фейковые мир/боты говорят строками JSON. Настоящий дескриптор с 02.10 (волна 2) указывает на
    # tools/olife/gateway_dev.py и sandbox_stub.py (бинарный протокол) — их проверяют сценарии на движке.
    gw = textwrap.dedent("""
        [kinds.gateway]
        engine = "none"
        exe = "{python}"
        ports = ["gw", "f2f"]
        f2f = "f2f"
        cwd = "{dir}"
        args = ["-u", "{project_dir}\\\\gateway.py", "--listen", "{port.gw}", "--upstream", "127.0.0.1:{param.upstream}",
                "--f2f", "{port.f2f}", "--metrics", "{dir}\\\\gateway_metrics.json"]
        params = { upstream = 0 }
        default_log = "stdout"
        ready = [ { f2f = "hello", timeout = 20 }, { log = "\\\\[olife_gateway\\\\] ready", stream = "stdout", timeout = 20 } ]
        stop = [ { f2f = "quit", wait_exit = 3 } ]

        [kinds.sandbox]
        engine = "none"
        exe = "{python}"
        ports = ["sb", "f2f"]
        f2f = "f2f"
        cwd = "{dir}"
        args = ["-u", "{project_dir}\\\\sandbox.py", "--f2f", "{port.f2f}", "--dir", "{dir}"]
        default_log = "stdout"
        ready = [ { f2f = "hello", timeout = 20 } ]
        stop = [ { f2f = "quit", wait_exit = 3 } ]
        """)
    with open(os.path.join(proj, "project.toml"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [project]
        name = "olf"
        scenarios_dir = "{project_dir}\\\\scenarios"
        runs_dir = "{lab_data}\\\\runs_olf"
        plugin = "plugin.py"

        [scenario]
        impls = { vc = "world" }

        [kinds.world]
        engine = "none"
        exe = %(py)s
        ports = ["game"]
        stdin = true
        cwd = "{dir}"
        args = ["-u", %(fake)s, "world", "--port", "{port.game}"]
        params = { ticks = 0, mode = "", sandbox = 0 }
        default_log = "stdout"
        ready = [ { log = "\\\\[olife_world\\\\] ready", stream = "stdout", timeout = 20 } ]
        stop = [ { stdin = "olife.stop\\n", wait_exit = 5 } ]

        [kinds.bot]
        engine = "none"
        exe = %(py)s
        stdin = true
        cwd = "{dir}"
        args = ["-u", %(fake)s, "bot", "--gateway", "{param.gateway}", "--name", "{param.name}"]
        params = { gateway = 0, name = "bot", ticks = 0 }
        default_log = "stdout"
        ready = [ { log = "\\\\[olife_client\\\\] connected", stream = "stdout", timeout = 20 } ]
        stop = [ { stdin = "olife.stop\\n", wait_exit = 5 } ]

        [kinds.badbot]
        engine = "none"
        exe = %(py)s
        stdin = true
        cwd = "{dir}"
        args = ["-u", %(fake)s, "bot", "--gateway", "{param.gateway}", "--name", "{param.name}", "--corrupt", "1"]
        params = { gateway = 0, name = "bad", ticks = 0 }
        default_log = "stdout"
        ready = [ { log = "\\\\[olife_client\\\\] connected", stream = "stdout", timeout = 20 } ]
        stop = [ { stdin = "olife.stop\\n", wait_exit = 5 } ]


        """) % {"py": toml_str(PY), "fake": toml_str(FAKE)} + gw)
    return proj


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    write_project(tmpdir_win)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "25610-25619")
    cfg = config.load()
    cfg["watchdog"] = {"enabled": False}
    lb = Lab(cfg, watch=False, background=True)
    assert lb.projects.get("olf").plugin_error is None, lb.projects.get("olf").plugin_error
    yield lb
    try:
        lb.stop_all()
    except Exception:
        pass
    lb.shutdown()
    policy.EXTRA_STOCK[:] = []


def test_session_lifecycle(lab):
    t0 = time.time()
    s = lab.call("olf.session", {"clients": 2, "client_kind": "bot"}, owner="agent_O")["result"]
    sid, L = s["session"], s["leases"]
    assert set(L) == {"world", "gateway", "sandbox", "client1", "client2"}, L
    info = {r: lab.lease_info(n) for r, n in L.items()}
    assert all(i["state"] == "ready" and i["params"]["session"] == sid for i in info.values())
    assert info["gateway"]["params"]["upstream"] == info["world"]["ports"]["game"]          # связь портов
    assert info["client1"]["params"]["gateway"] == info["gateway"]["ports"]["gw"]
    ports = [p for i in info.values() for p in i["ports"].values()]
    assert len(ports) == len(set(ports)) and all(25610 <= p <= 25619 for p in ports)
    time.sleep(2.0)
    st = lab.call("olf.status", {"session": sid}, owner="agent_O")["result"]
    assert any("status tick=" in x for x in st["world"]), st
    assert st["sandbox"]["exec"] == 0 and st["gateway"]["total"]["down"] > 0
    c = lab.call("olf.consistency", {"session": sid}, owner="agent_O")["result"]
    assert c["divergence_count"] == 0 and c["compared"] >= 20, c
    assert set(c["clients"]) == {L["client1"], L["client2"]}
    assert c["latency_ms"]["n"] == c["compared"] and c["gateway"]["rtt_ms"]["n"] > 0 and c["gateway"]["conns"] == 2
    probe = lab.call("olf.sandbox_probe", {"session": sid}, owner="agent_O")["result"]
    assert probe["passed"] == probe["attempts"] and probe["alive_after"] is True
    other = lab.call("olf.release", {"session": sid}, owner="agent_X")["result"]            # чужой не освободит
    assert other["released"] == {} and len(lab.leases) == 5
    with pytest.raises(LabError) as e:
        lab.release(L["world"], owner="agent_X")
    assert e.value.code == "not-owner"
    rel = lab.call("olf.release", {"session": sid}, owner="agent_O")["result"]["released"]
    assert list(rel)[:2] == sorted([L["client1"], L["client2"]]) and list(rel)[-1] == L["world"]
    assert all(v["ok"] and v["exit"] == "exit 0" and not v["forced_kill"] for v in rel.values()), rel
    assert lab.leases == {} and lab.ports.used == {}
    print("session lifecycle %.1f s: %s" % (time.time() - t0, json.dumps({k: v["exit"] for k, v in rel.items()})))


def test_session_start_failure_releases_everything(lab, monkeypatch):
    spec = lab.projects.get("olf").kinds["gateway"]
    monkeypatch.setitem(spec, "ready", [{"log": "never-printed", "stream": "stdout", "timeout": 2}])
    with pytest.raises(LabError):
        lab.call("olf.session", {"clients": 1}, owner="agent_O")
    assert lab.leases == {}, list(lab.leases)                     # мир, поднятый до шлюза, тоже освобождён


def run_scn(lab, name):
    j = lab.scen.start("olf", [name], "vc", "agent_O", wait=True)
    run = lab.runs.get(j["id"])
    return j, run


def test_scenarios(lab):
    j, run = run_scn(lab, "olf_short")
    assert j["verdict"] == "ok", j["progress"]
    sc = run["scenario"]
    fin = sc["finish"]
    assert fin["olife"] is True and fin["metrics"]["consistency"]["divergences"] == 0
    assert fin["metrics"]["consistency"]["bytes_down"] > 0
    assert all(v["exit"] == "exit 0" for v in fin["metrics"]["release"].values()), fin["metrics"]["release"]
    assert os.path.exists(os.path.join(run["dir"], "shots", "olf_short", "olife_consistency.json"))
    assert lab.leases == {}
    t0 = time.time()
    rows = []
    while time.time() - t0 < 10 and not rows:
        rows = lab.history.runs("olf", kind="olife")
        time.sleep(0.2)
    assert rows and rows[0]["scenario"] == "olf_short" and rows[0]["verdict"] == "ok"
    perf = lab.history.perf(rows[0]["id"])
    assert perf.get("consistency.divergences") == 0
    j, run = run_scn(lab, "olf_diverge")
    assert j["verdict"] == "failed"
    step = run["scenario"]["results"][0]["steps"][-1]
    assert step["cmd"] == "olife_consistency" and "divergences" in step["error"]
    j, run = run_scn(lab, "olf_negative_harness")
    assert j["verdict"] == "ok", j["progress"]
    assert run["scenario"]["finish"]["metrics"]["negative"]["passed"] == 8
    assert lab.leases == {}
