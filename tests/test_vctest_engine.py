"""Этап 4 на настоящем движке: стоковый VoxelCore 0.32 headless (без окна и ввода — role=headless) под арендами.
Демон в процессе, временные data, настоящий проект vc, порты 25605–25609.
- vctest: upstream dev/tests/world.lua -> ok, exit 0, версия 0.32, окон нет; провальный assert -> failed с кодом выхода;
  Canvas, сохранённый скриптом в user:shots/ -> PNG в прогоне;
(сессия проекта-сервера с миром, шлюзом и ботом — в тестах этого проекта, projects/<проект>/tests, волна 6.)
Пропуск: LAB_SKIP_ENGINE=1 (из WSL — с WSLENV=LAB_SKIP_ENGINE) или нет стокового 0.32."""
import os
import struct
import time

import pytest

from vclab import config
from vclab import policy
from vclab.daemon.service import Lab

from vclab import config as _cfg_for_paths
_ENGS = _cfg_for_paths.load()["engines"]
STOCK032 = (_ENGS.get("v032") or {}).get("stock") or ""
pytestmark = pytest.mark.skipif(bool(os.environ.get("LAB_SKIP_ENGINE")) or not os.path.exists(STOCK032),
                                reason="engine tests disabled (LAB_SKIP_ENGINE) or no stock 0.32")


@pytest.fixture(scope="module")
def lab():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="labvct_") as tmp:
        old = {k: os.environ.get(k) for k in ("LAB_DATA", "LAB_NO_WATCH", "LAB_PORTS", "LAB_PROJECTS")}
        os.environ.update({"LAB_DATA": os.path.join(tmp, "data"), "LAB_NO_WATCH": "1", "LAB_PORTS": "25605-25609"})
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


def vctest(lab, name):
    j = lab.scen.start("vc", [name], "vc", "agent_T", wait=True)
    return j, lab.runs.get(j["id"])["scenario"]["results"][0]


def test_vctest_world(lab):
    j, res = vctest(lab, "world")
    assert j["verdict"] == "ok", j["progress"]
    assert res["exit_code"] == 0 and res["engine_version"] == "0.32" and res["mode"] == "headless"
    iso = res["start"]["isolation"]
    assert iso["role"] == "headless" and iso["stock"] and iso["verified"] and iso["windows"] == []
    log = os.path.join(lab.runs.get(j["id"])["dir"], res["logs"]["stdout"]["file"])
    text = open(log, encoding="utf-8", errors="replace").read()
    assert "engine version: 0.32" in text and "created world 'demo'" in text
    print("vctest world: %s s, exit %s" % (res["dur"], res["exit"]))


def test_vctest_failure_and_canvas(lab):
    j, res = vctest(lab, "fail_assert")
    assert j["verdict"] == "failed" and res["exit_code"] not in (0, None)
    assert any("intentional failure" in x for x in res["logs"]["stderr"]["errors"]), res["logs"]
    j, res = vctest(lab, "canvas_shot")
    assert j["verdict"] == "ok" and len(res["shots"]) == 1
    png = os.path.join(lab.runs.get(j["id"])["dir"], res["shots"][0]["file"])
    with open(png, "rb") as f:
        head = f.read(24)
    assert head[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", head[16:24]) == (64, 32)
