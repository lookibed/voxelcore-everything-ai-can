"""Этап 3а на настоящем движке: новая тестовая сборка (`--f2f-clock`, `hello.flags`). Lab в процессе теста, порты
25630–25639, временные data и --dir. Проверяется:
- vc.dev (то, что делает MCP vc_start): часы realtime, окно normal, hello.flags {clock: realtime, input: isolated,
  window: normal} проверены демоном; кадры идут без step; step -> clock-realtime; shot (FBO) работает; release;
- vc.engine (виртуальные часы, окно hidden по умолчанию) — флаги и окно (раньше — вид engine первого проекта);
- старая сборка без hello.flags (если лежит рядом) — убита, isolation-failed.
Пропуск: LAB_SKIP_ENGINE=1 (с WSLENV=LAB_SKIP_ENGINE из WSL) или сборка без --f2f-clock."""
import os
import time

import pytest

from vclab import config
from vclab import policy
from vclab.daemon.service import Lab, LabError

from vclab import config as _cfg_for_paths
_ENGS = _cfg_for_paths.load()["engines"]
EXE = ((_ENGS.get(_ENGS.get("default") or "v031") or {}).get("builds") or {}).get("f2f") or ""
OLD = os.path.join(os.path.dirname(EXE), "VoxelCoreF2F-v.exe") if EXE else ""   # сборка до 527e3084: hello без flags
NEW = os.path.exists(EXE) and policy.exe_caps(EXE).get("--f2f-clock")
pytestmark = pytest.mark.skipif(bool(os.environ.get("LAB_SKIP_ENGINE")) or not NEW,
                                reason="engine tests disabled (LAB_SKIP_ENGINE) or the F2F build has no --f2f-clock")


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "25630-25639")
    cfg = config.load()
    lb = Lab(cfg, watch=False, background=True)
    lb.tmp = tmpdir_win
    yield lb
    lb.stop_all()
    lb.shutdown()


def test_vc_dev_realtime(lab):
    d = os.path.join(lab.tmp, "vcdir")
    os.makedirs(d)
    t0 = time.time()
    r = lab.create_lease("vc", "dev", "smoke", params={"dir": d}, start=True)
    st = r["start"]
    name = r["lease"]["name"]
    iso = st["isolation"]
    assert iso["verified"] and iso["flags"] == {"clock": "realtime", "input": "isolated", "window": "normal"}, iso
    argv = st["argv"]
    assert argv[argv.index("--f2f-clock") + 1] == "realtime" and argv[argv.index("--dir") + 1] == d
    h1 = lab.f2f(name, "hello", owner="smoke")["result"]
    time.sleep(1.5)
    h2 = lab.f2f(name, "hello", owner="smoke")["result"]
    assert h2["frame"] > h1["frame"] and h2["time"] > h1["time"], (h1["frame"], h2["frame"])
    s = lab.f2f(name, "step", {"ticks": 1, "frames": 1}, owner="smoke")
    assert s["ok"] is False and "clock-realtime" in str(s.get("error"))
    shot = lab.f2f(name, "shot", {"name": "menu"}, owner="smoke")
    assert shot["ok"] and os.path.getsize(shot["result"]["path"]) > 1000
    assert os.path.isfile(os.path.join(d, "latest.log"))           # --dir как у vc_start: лог в каталоге
    rel = lab.release(name, owner="smoke")
    assert rel["ok"] and not rel["forced_kill"], rel
    print("vc.dev realtime: start %.1f s, frames %d -> %d over 1.5 s, shot %s" % (
        st["timing"]["total_s"], h1["frame"], h2["frame"], shot["result"]["sha256"][:16]))
    assert time.time() - t0 < 60


def test_engine_virtual_hidden(lab):
    r = lab.create_lease("vc", "engine", "smoke")
    name = r["lease"]["name"]
    try:
        st = lab.start(name, owner="smoke")
    except LabError as exc:
        pytest.fail("vc engine start: %s %s" % (exc.code, exc.message))
    iso = st["isolation"]
    assert iso["flags"] == {"clock": "virtual", "input": "isolated", "window": "hidden"}, iso
    lab.release(name, owner="smoke")


@pytest.mark.skipif(not os.path.exists(OLD) or policy.exe_caps(OLD).get("--f2f-clock"),
                    reason="no old build without hello.flags")
def test_old_build_killed(lab):
    r = lab.create_lease("vc", "dev", "smoke", params={"engine_exe": OLD, "dir": os.path.join(lab.tmp, "olddir")})
    name = r["lease"]["name"]
    with pytest.raises(LabError) as e:
        lab.start(name, owner="smoke")
    assert e.value.code == "isolation-failed" and "flags.input" in e.value.message
    l = lab.leases[name]
    assert not l.proc.alive() and l.state == "failed"
