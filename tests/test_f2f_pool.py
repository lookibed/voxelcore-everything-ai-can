"""F2F-пул против фейкового сервера: постоянное соединение, задержка, таймаут и сброс, переподключение после
обрыва, keepalive в простое, ответ не в UTF-8."""
import os
import subprocess
import sys
import time

import pytest

from conftest import HERE, PY
from vclab.f2f import F2FPool
from vclab.leases.ports import port_free

PORT = 25690


@pytest.fixture
def pool():
    p = F2FPool()
    yield p
    p.close()


@pytest.fixture
def fake(tmpdir_win):
    assert port_free(PORT)
    p = subprocess.Popen([PY, os.path.join(HERE, "fake_f2f.py"), str(PORT)], cwd=tmpdir_win,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    yield p, tmpdir_win
    p.kill()
    p.wait()


def test_pool_roundtrip_latency(fake, pool):
    c = pool.get("x", PORT)
    rep = c.call("hello", connect_timeout=10)
    assert rep["ok"] and rep["result"]["impl"] == "fake"
    times = []
    for _ in range(200):
        t0 = time.perf_counter()
        assert c.call("step", {"ticks": 1, "frames": 1})["ok"]
        times.append((time.perf_counter() - t0) * 1000)
    times.sort()
    print("warm F2F roundtrip (fake): median %.3f ms, p95 %.3f ms" % (times[100], times[190]))
    assert times[100] < 20
    assert c.calls == 201


def test_timeout_drops_and_reconnects(fake, pool):
    c = pool.get("x", PORT)
    c.call("hello", connect_timeout=10)
    with pytest.raises(TimeoutError):
        c.call("sleep", {"s": 1.0}, timeout=0.3)
    assert not c.connected()
    time.sleep(1.0)
    # фейк держит одно соединение за раз: после того как он дочитал старое, новое подключение проходит
    assert c.call("hello", connect_timeout=5)["ok"]


def test_non_utf8_reply(fake, pool):
    c = pool.get("x", PORT)
    rep = c.call("cp1251", connect_timeout=10)
    assert rep["ok"] is False and rep["error"] == "Ошибка"


def test_keepalive_when_idle(fake, pool):
    proc, d = fake
    c = pool.get("x", PORT)
    c.idle = {"cmd": "keepalive", "every_s": 0.3}
    c.call("hello", connect_timeout=10)
    time.sleep(1.5)
    with open(os.path.join(d, "keepalive.txt")) as f:
        n = len(f.read().split())
    assert n >= 3, n


def test_dead_server_raises(fake, pool):
    proc, _ = fake
    c = pool.get("x", PORT)
    c.call("hello", connect_timeout=10)
    with pytest.raises((ConnectionError, OSError)):
        c.call("crash", timeout=5, alive=lambda: proc.poll() is None)
