"""Отчёт игровой сессии: строки статуса сессии пользователя 01.10 00:51–00:56 (сохранены в
D:\\Prog\\AlphaMine\\runs\\20261001_0051_user_session\\status_lines.txt) и сырые строки latest.log с шаблонами
дескриптора alphamine ([play.report])."""
import os
import tomllib

import pytest

from vclab import play as P

STATUS = r"D:\Prog\AlphaMine\runs\20261001_0051_user_session\status_lines.txt"
DESC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "projects", "alphamine",
                    "project.toml")


def rcfg():
    with open(DESC, "rb") as f:
        return tomllib.load(f)["play"]["report"]


@pytest.mark.skipif(not os.path.isfile(STATUS), reason="no saved status lines")
def test_user_session_status_lines(tmpdir_win):
    st = P.load_status_table(STATUS)
    assert len(st) >= 50 and st[0]["tick"] == 201 and st[0]["map_chunks"] == 344
    m = P.summarize_status(st)
    # ALPHAMINE §9: «fps по 5-секундным окнам мин 6.5 / медиана 32 / макс 120», 4437 MapChunk
    assert m["fps_5s"]["min"] == 6.5 and round(m["fps_5s"]["max"]) == 120 and 30 <= m["fps_5s"]["median"] <= 34, m
    assert m["chunks_total"] == 4437, m
    # провалы — там, где MapChunk по 25–30 в секунду
    assert m["chunk_rate"]["max"] >= 25 and m["fps_when_chunks_ge20"] < m["fps_when_chunks_lt5"], m
    rep = {"id": "user_session", "project": "alphamine", "status_samples": st, "metrics": m,
           "started": st[0]["t"], "ended": st[-1]["t"], "ended_by": "exit", "exit": "exit 0", "verdict": "done"}
    md_path = P.write_report(rep, os.path.join(tmpdir_win, "out"), rcfg())
    md = open(md_path, encoding="utf-8").read()
    assert "fps по окнам статуса" in md and "6.5" in md and "play_fps.svg" in md
    assert os.path.getsize(os.path.join(tmpdir_win, "out", "play_fps.svg")) > 1000
    assert os.path.isfile(os.path.join(tmpdir_win, "out", "play_report.json"))
    # тот же файл через импорт истории (legacy_parser)
    r = P.legacy_parser(rcfg())(STATUS)
    assert r["metrics"]["fps_5s"]["min"] == 6.5 and r["metrics"]["duration_s"] > 240


LOG = """[I] 2026/10/01 15:24:26.587+0300 [           lua-debug] [alphamine_app] connecting to 127.0.0.1:25601
[I] 2026/10/01 15:24:26.750+0300 [           lua-debug] [alphamine] connected to 127.0.0.1:25601 in 88.0 ms
[I] 2026/10/01 15:24:26.869+0300 [           lua-debug] [alphamine] login ok (entity 0) at tick 4
[I] 2026/10/01 15:24:26.870+0300 [           lua-debug] [alphamine] chat: §ePlayer joined the game.
[E] 2026/10/01 15:24:23.345+0300 [      gl-framebuffer] framebuffer is not complete!
[E] 2026/10/01 15:24:24.345+0300 [      gl-framebuffer] framebuffer is not complete!
[I] 2026/10/01 15:24:36.709+0300 [           lua-debug] [alphamine] status tick 200 fps 18.5 map_chunks 292 stored 441 engine 598 dirty 8/8 net in 1141 KB, ticks 2.42 ms/tick, encode 263 ms, inflate 30 ms
[I] 2026/10/01 15:24:41.712+0300 [           lua-debug] [alphamine] status tick 300 fps 19.4 map_chunks 437 stored 441 engine 793 dirty 4/4 net in 1714 KB, ticks 2.38 ms/tick, encode 332 ms, inflate 46 ms
[I] 2026/10/01 15:24:43.000+0300 [           lua-debug] [alphamine] frame error: attempt to index nil
[W] 2026/10/01 15:24:44.000+0300 [             sockets] slow
[I] 2026/10/01 15:24:46.669+0300 [           lua-debug] [alphamine] status tick 400 fps 53.9 map_chunks 441 stored 441 engine 793 dirty 0/0 net in 1730 KB, ticks 2.33 ms/tick, encode 335 ms, inflate 46 ms
[I] 2026/10/01 15:24:50.000+0300 [           lua-debug] [alphamine] leaving the world: Disconnect
"""
SERVER = """2026-10-01 15:24:20 [INFO] Done! For help, type "help" or "?"
2026-10-01 15:24:26 [INFO] Player [/127.0.0.1:50123] logged in with entity id 1
2026-10-01 15:24:50 [INFO] Player lost connection: Quitting
"""


def test_log_parsing_with_descriptor():
    c = rcfg()
    lines = LOG.strip().splitlines()
    rep = P.build_report({"id": "x", "project": "alphamine", "started": 0, "ended": 30, "ended_by": "exit",
                          "exit": "exit 0"}, lines, SERVER.strip().splitlines(), c)
    m = rep["metrics"]
    assert m["status_lines"] == 3 and m["fps_5s"]["min"] == 18.5 and m["fps_5s"]["max"] == 53.9
    assert m["chunk_rate"]["max"] == pytest.approx((437 - 292) / 5.003, rel=1e-3)
    assert rep["errors_total"] == 3 and rep["warnings_total"] == 1        # 2 framebuffer + frame error
    assert rep["errors"][0]["count"] == 2 and "framebuffer" in rep["errors"][0]["first"]
    ev = rep["event_counts"]
    assert ev["connect"] == 1 and ev["login"] == 1 and ev["chat"] == 1 and ev["disconnect"] == 1
    assert rep["disconnect"] == "Disconnect"
    chat = [e for e in rep["events"] if e["event"] == "chat"][0]
    assert chat["text"] == "§ePlayer joined the game."
    sv = rep["server"]
    assert [e["event"] for e in sv["events"]] == ["join", "leave"] and sv["events"][1]["reason"] == "Quitting"
    md = P.report_md(rep)
    assert "разрыв | Disconnect" in md and "×2" in md and "запись пакетов | не реализовано" in md
