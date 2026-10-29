"""Смоук на настоящем движке (VoxelCoreF2F.exe), без Java-сервера: два проекта через одни и те же инструменты.
Отдельный демон :25792, временные data (inst, builds), порты 25660–25669; прогоны пишутся в runs_dir проектов.
Пропуск: LAB_SKIP_ENGINE=1 (ПК занят замерами) или нет exe."""
import os
import struct

import pytest

from conftest import write_dummy_project  # noqa: F401  (тот же conftest)
from vclab.cli import labctl as labctl
from vclab.daemon.client import LabClient

PORT = 25792
EXE = os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")), "builds", "031", "VoxelCoreF2F-031.exe")
pytestmark = pytest.mark.skipif(bool(os.environ.get("LAB_SKIP_ENGINE")) or not os.path.exists(EXE),
                                reason="engine smoke disabled (LAB_SKIP_ENGINE) or no F2F build")


@pytest.fixture(scope="module")
def lab():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="labsmoke_") as tmp:
        assert LabClient(PORT).alive() is None
        r = labctl.start(PORT, extra=["--data", os.path.join(tmp, "data"), "--ports", "25660-25669", "--no-watch"])
        assert r["ok"], r
        c = LabClient(PORT, owner="smoke")
        yield c
        # этап 5: снять всё и остановить демон — admin (главная сессия claude)
        LabClient(PORT, owner="claude").post("/stop-all")
        labctl.stop(PORT, force=True, owner="claude")


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    assert head[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", head[16:24])


def non_black_pct(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    px = im.getdata()
    return 100.0 * sum(1 for p in px if p != (0, 0, 0)) / len(px)


def smoke(c, project, params=None):
    r = c.post("/leases", {"project": project, "kind": "engine", "ttl": 300, "params": params or {}, "start": True})
    assert r.get("ok") and r["start"]["ok"], r
    name = r["lease"]["name"]
    try:
        h = c.post("/f2f/" + name, {"cmd": "hello"})
        assert h["ok"] and h["result"]["impl"] == "vc" and (h["result"]["w"], h["result"]["h"]) == (854, 480)
        st = c.post("/f2f/" + name, {"cmd": "step", "args": {"ticks": 10, "frames": 10}})
        assert st["ok"], st
        shot = c.post("/f2f/" + name, {"cmd": "shot", "args": {"name": "smoke"}})
        assert shot["ok"], shot
        path = shot["result"]["path"]
        assert png_size(path) == (854, 480) and len(shot["result"]["sha256"]) == 64
        print("%s: start %.2f s (ready %s), hello %.2f ms, shot %s, non-black %.1f %%" % (
            project, r["start"]["timing"]["total_s"],
            [(x.get("f2f") or x.get("pump_log") or "pump_f2f", x.get("frames"), x["s"]) for x in r["start"]["ready"]],
            h["f2f_ms"], path, non_black_pct(path)))
        return name, path, h, r
    finally:
        rel = c.post("/leases/%s/release" % name, {})
        assert rel["ok"] and rel["exit"] == "exit 0" and not rel["forced_kill"], rel


def test_alphamine_engine_void(lab):
    name, path, h, r = smoke(lab, "alphamine")
    assert r["start"]["ready"][1]["pump_f2f"]["field"] == "handler"
    assert non_black_pct(path) > 50          # небо и HUD пустого мира


def test_wasmrt_engine_page(lab):
    name, path, h, r = smoke(lab, "wasmrt")
    assert "[wasmrt_page] ready" in r["start"]["ready"][1]["line"]
    assert non_black_pct(path) > 30          # плазма wasmdemo 160x100 на странице
