"""Смоук интерпретатора на настоящем движке (VoxelCoreF2F.exe) через отдельный демон :25793 (временные data,
порты 25650–25659): lab run wasmrt wasmrt_wasmdemo — аренда, шаги F2F, снимки 854x480 с sha256 (F2F, RGB, файл),
отчёт прогона; сравнение прогона с самим собой. Пропуск: LAB_SKIP_ENGINE=1 (WSLENV!) или нет exe."""
import json
import os

import pytest

from vclab.cli import labctl as labctl
from vclab.daemon.client import LabClient

PORT = 25793
EXE = r"D:\Prog\AlphaMine\engine\VoxelCoreF2F.exe"
pytestmark = pytest.mark.skipif(bool(os.environ.get("LAB_SKIP_ENGINE")) or not os.path.exists(EXE),
                                reason="engine smoke disabled (LAB_SKIP_ENGINE) or no F2F build")


@pytest.fixture(scope="module")
def lab():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="labscen_") as tmp:
        assert LabClient(PORT).alive() is None
        r = labctl.start(PORT, extra=["--data", os.path.join(tmp, "data"), "--ports", "25650-25659", "--no-watch"])
        assert r["ok"], r
        c = LabClient(PORT, owner="scen-smoke")
        yield c
        # этап 5: снять всё и остановить демон — admin (главная сессия claude)
        LabClient(PORT, owner="claude").post("/stop-all")
        labctl.stop(PORT, force=True, owner="claude")


def test_wasmrt_scenario(lab):
    r = lab.post("/scenario/run", {"project": "wasmrt", "scenarios": ["wasmrt_wasmdemo"], "impl": "vc", "wait": True},
                 timeout=300)
    assert r["ok"], r
    job = r["job"]
    assert job["verdict"] == "ok", job.get("progress")
    rep = json.load(open(os.path.join(job["dir"], "report.json"), encoding="utf-8"))["scenario"]
    res = rep["results"][0]
    shots = {s["name"]: s for s in res["shots"]}
    assert set(shots) == {"plasma_a", "plasma_b"}
    for s in shots.values():
        assert (s["w"], s["h"]) == (854, 480) and len(s["sha256_rgb"]) == 64
        assert os.path.exists(os.path.join(job["dir"], s["file"]))
    assert shots["plasma_a"]["sha256_rgb"] != shots["plasma_b"]["sha256_rgb"]     # плазма идёт по кадрам
    assert not lab.get("/leases")["leases"]
    c = lab.post("/compare", {"a": job["run"], "b": job["run"], "project": "wasmrt"})
    assert c["ok"] and c["summary"]["all_identical"], c
    print("wasmrt scenario: timing %s, shots %s" % (rep["timing"], {k: v["sha256_rgb"][:12] for k, v in shots.items()}))
