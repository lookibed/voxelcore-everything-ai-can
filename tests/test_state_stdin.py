"""Две известные ошибки ядра (docs/LESSONS.md §1):
1) запись leases.json из нескольких потоков через один `.tmp` без замка и повтора -> WinError 32 в обработчике запроса;
2) `lab stdin` искал ответ в окне последних 512 КиБ лога -> у длинного лога ответ терялся."""
import glob
import json
import os
import threading
import time

import pytest

from test_leases import lab  # noqa: F401  (фикстура Lab на временном проекте dummy)

_real_replace = os.replace


def _sharing_violation(dst):
    # как Windows: ERROR_SHARING_VIOLATION (32) -> PermissionError
    return OSError(None, "The process cannot access the file because it is being used by another process", dst, 32)


def _patch_replace(monkeypatch, fails):
    """os.replace на leases.json падает `fails` раз подряд (None — всегда)."""
    calls = {"n": 0, "failed": 0}

    def fake(src, dst, *a, **kw):
        if str(dst).endswith("leases.json"):
            calls["n"] += 1
            if fails is None or calls["failed"] < fails:
                calls["failed"] += 1
                raise _sharing_violation(dst)
        return _real_replace(src, dst, *a, **kw)
    monkeypatch.setattr(os, "replace", fake)
    return calls


def _state_tmps(lab):
    return glob.glob(os.path.join(os.path.dirname(lab.state_path), "*.tmp"))


def test_save_state_retries_sharing_violation(lab, monkeypatch):
    lab.create_lease("dummy", "survivor", "a")
    calls = _patch_replace(monkeypatch, 3)
    lab._save_state()
    assert calls == {"n": 4, "failed": 3}
    assert [x["name"] for x in json.load(open(lab.state_path, encoding="utf-8"))["leases"]] == ["dummy-survivor-1"]
    assert _state_tmps(lab) == []


def test_save_state_gives_up_without_raising(lab, monkeypatch):
    calls = _patch_replace(monkeypatch, None)
    t0 = time.time()
    r = lab.create_lease("dummy", "survivor", "a")          # обработчик запроса не падает, аренда выдана
    assert r["ok"] and r["lease"]["name"] == "dummy-survivor-1"
    assert calls["n"] == 10 and time.time() - t0 < 10
    assert _state_tmps(lab) == []                            # свой tmp убран
    monkeypatch.setattr(os, "replace", _real_replace)
    lab._save_state()                                        # следующая запись проходит
    assert json.load(open(lab.state_path, encoding="utf-8"))["leases"][0]["name"] == "dummy-survivor-1"


def test_save_state_concurrent_writers_and_reader(lab):
    """Восемь писателей + читатель, держащий leases.json открытым короткими интервалами (как антивирус/CLI)."""
    for _ in range(3):
        lab.create_lease("dummy", "survivor", "a")
    errors, stop = [], threading.Event()

    def writer():
        try:
            for _ in range(40):
                lab._save_state()
        except Exception as exc:                             # noqa: BLE001
            errors.append(repr(exc))

    def reader():
        while not stop.is_set():
            try:
                with open(lab.state_path, encoding="utf-8") as f:
                    f.read()
                    time.sleep(0.002)
            except OSError:
                pass
            time.sleep(0.003)
    rt = threading.Thread(target=reader)
    rt.start()
    ws = [threading.Thread(target=writer) for _ in range(8)]
    for t in ws:
        t.start()
    for t in ws:
        t.join()
    stop.set()
    rt.join()
    assert errors == []
    assert len(json.load(open(lab.state_path, encoding="utf-8"))["leases"]) == 3
    assert _state_tmps(lab) == []


def test_stdin_reply_after_long_log(lab):
    name = lab.create_lease("dummy", "echo", "a")["lease"]["name"]
    lab.start(name, owner="a")
    log = os.path.join(lab.leases[name].dir, "logs", "echo.out.log")
    assert os.path.getsize(log) > 1024 * 1024               # лог до команды длиннее окна 512 КиБ вдвое
    r = lab.stdin(name, "ping", owner="a", wait=10, pattern=r"^pong ping$")
    assert r["matched"] is True and r["lines"] == ["pong ping"], r["lines"][-3:]
    r = lab.stdin(name, "fill 6000", owner="a", wait=20, pattern=r"^pong fill")   # ответ сам длиннее окна
    assert r["matched"] is True and len(r["lines"]) == 6001 and r["lines"][0].startswith("fill 000000")
    r = lab.stdin(name, "nothing-back-yet", owner="a", wait=0.3, pattern=r"^never$")
    assert r["matched"] is False
    lab.stop(name, owner="a")


def test_read_since(tmpdir_win):
    from vclab.scenario import decode
    p = os.path.join(tmpdir_win, "big.log")
    with open(p, "wb") as f:
        f.write(b"".join(b"line %06d %s\n" % (i, b"y" * 100) for i in range(12000)))
    off = os.path.getsize(p)
    assert decode.read_since(p, off) == ([], off)
    with open(p, "ab") as f:
        f.write("ответ\nхвост без перевода".encode("cp866"))
    lines, end = decode.read_since(p, off)
    assert lines == ["ответ", "хвост без перевода"] and end == os.path.getsize(p)
    assert decode.read_since(p, 10 ** 9)[0][:1] == ["line 000000 " + "y" * 100]   # файл пересоздан короче: с начала
    assert decode.read_since(os.path.join(tmpdir_win, "none.log"), 0) == ([], 0)


def test_write_json_atomic_retry_and_cleanup(tmpdir_win, monkeypatch):
    from vclab.scenario import decode
    p = os.path.join(tmpdir_win, "s.json")
    n = {"c": 0}

    def flaky(src, dst):
        n["c"] += 1
        if n["c"] <= 2:
            raise _sharing_violation(dst)
        return _real_replace(src, dst)
    monkeypatch.setattr(os, "replace", flaky)
    decode.write_json_atomic(p, {"a": 1})
    assert json.load(open(p)) == {"a": 1} and n["c"] == 3
    monkeypatch.setattr(os, "replace", lambda s, d: (_ for _ in ()).throw(_sharing_violation(d)))
    with pytest.raises(PermissionError):
        decode.write_json_atomic(p, {"a": 2}, attempts=3)
    assert json.load(open(p)) == {"a": 1} and glob.glob(p + "*.tmp") == []
