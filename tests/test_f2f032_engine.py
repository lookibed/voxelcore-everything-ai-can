"""Этап 4a на настоящей тестовой сборке F2F 0.32 (VoxelCoreF2F-032.exe) под арендами: демон в процессе, временные data,
настоящий проект vc, порты 25695–25699. Ввод ОС не участвует (окна hidden, --f2f).
- vc.engine engine=v032 (часы virtual): hello.version 0.32-f2f, flags isolated; mode{seed 12345} + step{40,40} + shot =
  эталон меню из engine/032/README.md (02a16804…, 854×480);
- оконный vctest (vctest_window, --f2f + --test): world_window.lua — ok под virtual (раннер шагает, total_time ровно 1.0)
  и realtime; fail_assert — failed (virtual: ошибка шага; realtime: abort 0xC0000409); upstream world.lua в окне — failed
  «pack duplication [base]» (меню уже загрузило base); canvas_shot — PNG 927b36b5…;
- сборка 0.32 на аренде v031 — engine-mismatch.
Пропуск: LAB_SKIP_ENGINE=1 (из WSL — с WSLENV=LAB_SKIP_ENGINE) или нет VoxelCoreF2F-032.exe."""
import os
import time

import pytest

from vclab import config
from vclab import policy
from vclab.daemon.service import Lab, LabError

from vclab import config as _cfg_for_paths
_ENGS = _cfg_for_paths.load()["engines"]
F2F032 = ((_ENGS.get("v032") or {}).get("builds") or {}).get("f2f") or ""
RES032 = (_ENGS.get("v032") or {}).get("res") or ""
MENU_SHA = "02a16804b3c0dae9ec0b76932f674ed9e7b004e92bc9e4a87ad3e7a48cf3e045"
CANVAS_SHA = "927b36b54b6383f2b7e56307e5408933ab46aff4203f10b8e3b934539bfc619c"
pytestmark = pytest.mark.skipif(bool(os.environ.get("LAB_SKIP_ENGINE")) or not os.path.exists(F2F032),
                                reason="engine tests disabled (LAB_SKIP_ENGINE) or no VoxelCoreF2F-032.exe")


@pytest.fixture(scope="module")
def lab():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="lab032_") as tmp:
        old = {k: os.environ.get(k) for k in ("LAB_DATA", "LAB_NO_WATCH", "LAB_PORTS", "LAB_PROJECTS")}
        os.environ.update({"LAB_DATA": os.path.join(tmp, "data"), "LAB_NO_WATCH": "1", "LAB_PORTS": "25695-25699"})
        os.environ.pop("LAB_PROJECTS", None)
        cfg = config.load()
        cfg["watchdog"] = {"enabled": False}
        lb = Lab(cfg, watch=False, background=True)
        try:
            yield lb
        finally:
            lb.stop_all()
            lb.shutdown()
            policy.EXTRA_STOCK[:] = []
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


def test_menu_shot_matches_engine_readme(lab):
    r = lab.create_lease("vc", "engine", "agent_T", params={"engine": "v032"}, start=True)
    name = r["lease"]["name"]
    try:
        iso = r["start"]["isolation"]
        assert r["start"]["engine_version"] == "0.32" and iso["verified"] and iso["hello_version"] == "0.32-f2f"
        assert iso["flags"] == {"clock": "virtual", "input": "isolated", "window": "hidden"}, iso
        assert lab.f2f(name, "mode", {"fixed": True, "seed": 12345}, owner="agent_T")["ok"]
        st = lab.f2f(name, "step", {"ticks": 40, "frames": 40}, owner="agent_T")["result"]
        assert st["frame"] == 40 and st["screen"] == "menu"
        shot = lab.f2f(name, "shot", {"name": "menu"}, owner="agent_T")["result"]
        assert (shot["w"], shot["h"]) == (854, 480) and shot["sha256"] == MENU_SHA, shot
    finally:
        lab.release(name, owner="agent_T")


def vctest(lab, name, **opts):
    j = lab.scen.start("vc", [name], "vc", "agent_T", opts=dict({"window": True, "engine": "v032"}, **opts), wait=True)
    return j, lab.runs.get(j["id"])["scenario"]["results"][0]


def _stdout(lab, j, res):
    return open(os.path.join(lab.runs.get(j["id"])["dir"], res["logs"]["stdout"]["file"]), encoding="utf-8",
                errors="replace").read()


def test_vctest_window_virtual_and_realtime(lab):
    j, res = vctest(lab, "world_window", clock="virtual")
    assert j["verdict"] == "ok", j["progress"]
    f = res["f2f"]
    assert f["clock"] == "virtual" and f["marker"] and f["quit"] and f["steps"] >= 1 and res["exit_code"] == 0
    assert res["start"]["isolation"]["flags"]["input"] == "isolated"
    assert "--test" in res["start"]["argv"] and res["start"]["argv"][res["start"]["argv"].index("--f2f-clock") + 1] == "virtual"
    assert "total_time 1.0000000" in _stdout(lab, j, res) and "uptime delta 1\n" in _stdout(lab, j, res)
    j, res = vctest(lab, "world_window", clock="realtime")
    assert j["verdict"] == "ok", j["progress"]
    assert res["f2f"]["clock"] == "realtime" and res["f2f"]["steps"] == 0 and res["f2f"]["marker"]


def test_vctest_window_failures(lab):
    j, res = vctest(lab, "fail_assert", clock="virtual")
    assert j["verdict"] == "failed" and res["f2f"]["script_error"] and "intentional failure" in res["error"], res
    j, res = vctest(lab, "fail_assert", clock="realtime")
    assert j["verdict"] == "failed" and res["exit_code"] not in (0, None), res
    j, res = vctest(lab, "world")
    assert j["verdict"] == "failed" and "pack duplication [base]" in res["error"], res


def test_vctest_window_canvas(lab):
    j, res = vctest(lab, "canvas_shot")
    assert j["verdict"] == "ok" and len(res["shots"]) == 1 and res["shots"][0]["sha256"] == CANVAS_SHA, res


def test_f2f032_on_v031_lease_is_engine_mismatch(lab):
    r = lab.create_lease("vc", "dev", "agent_T", params={"engine_exe": F2F032, "res": RES032, "window": "hidden"})
    name = r["lease"]["name"]
    d = lab.leases[name].dir
    lab.leases[name].params["dir"] = d
    try:
        with pytest.raises(LabError) as e:
            lab.start(name, owner="agent_T")
        assert e.value.code == "engine-mismatch" and "got '0.32-f2f'" in e.value.message
        assert not lab.leases[name].proc.alive()
    finally:
        lab.release(name, owner="agent_T")
