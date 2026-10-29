"""Ворота-храповик на синтетической истории: основание = лучшее записанное / принятое, ε из шума Java/Java,
sha-совпадение, stale по mtime golden, регрессия состояния серии, перф (contended игнорируется), без автоподъёма."""
import os
import time

from vclab.quality import gate as G
from vclab.quality import history as H

T0 = time.mktime(time.strptime("20261001_120000", "%Y%m%d_%H%M%S"))


def rec(rid, scen, impl, ts, shots=(), series=(), kind="layers", contended=None, tag="t", perf=None, golden=None):
    return {"id": rid, "ts": ts, "project": "p", "scenario": scen, "impl": impl, "kind": kind, "tag": tag,
            "contended": contended, "dir": "D:\\runs\\" + rid, "source": "test",
            "shots": [{"name": n, "identical_pct": p, "sha": s, "golden": golden, "heat_png": "D:\\h\\%s.png" % n}
                      for n, p, s in shots],
            "series": [{"tick": t, "pct": p, "state_equal": e} for t, p, e in series], "perf": perf or {}}


def cfg(**kw):
    c = G.gate_cfg(None)
    c.update(kw)
    return c


def make(tmp):
    h = H.History(os.path.join(tmp, "h.sqlite"))
    # история vc: лучший 99.0 у r1, потом 98.5 (r2) — последний r3 = 98.9
    h.ingest(rec("r1", "layer_a", "vc", T0 + 1, [("f0", 99.0, "A1"), ("f1", 100.0, "B")]))
    h.ingest(rec("r2", "layer_a", "vc", T0 + 2, [("f0", 98.5, "A2"), ("f1", 100.0, "B")]))
    h.ingest(rec("r3", "layer_a", "vc", T0 + 3, [("f0", 98.9, "A3"), ("f1", 100.0, "B")]))
    # Java против golden: шум кадра f0 = 0.2 (99.8), f1 = 0
    h.ingest(rec("j1", "layer_a", "java", T0, [("f0", 99.8, "J"), ("f1", 100.0, "B")]))
    return h


def test_ratchet_eps_from_java_noise(tmpdir_win):
    h = make(tmpdir_win)
    res = G.evaluate(h, "p", "layers", cfg())
    # f0: 98.9 против лучшего 99.0, ε = 0.2 -> в пределах шума; f1: sha совпал -> ok
    assert res["verdict"] == "pass" and res["summary"]["regressions"] == 0 and res["ok"] == 2, res["summary"]
    # без шума Java та же разница — регрессия
    h.ingest(rec("j1", "layer_a", "java", T0, [("f0", 100.0, "J"), ("f1", 100.0, "B")]))
    res = G.evaluate(h, "p", "layers", cfg())
    assert res["verdict"] == "fail" and res["exit_code"] == 1
    r = res["regressions"][0]
    assert (r["scenario"], r["frame"], r["was"], r["now"], r["base_run"], r["base_src"]) == (
        "layer_a", "f0", 99.0, 98.9, "r1", "history-best")
    assert r["heat"] == "D:\\h\\f0.png"
    # eps проекта/сценария
    assert G.evaluate(h, "p", "layers", cfg(eps_by_scenario={"layer_a": 0.15}))["verdict"] == "pass"
    h.close()


def test_improved_never_promoted_accept_explicit(tmpdir_win):
    h = make(tmpdir_win)
    h.ingest(rec("r4", "layer_a", "vc", T0 + 4, [("f0", 99.6, "A4"), ("f1", 100.0, "B")]))
    res = G.evaluate(h, "p", "layers", cfg())
    assert [i["frame"] for i in res["improved"]] == ["f0"] and res["verdict"] == "pass"
    assert h.ratchet("p") == {}                      # ворота не поднимают храповик
    # следующий прогон 99.1: против лучшего записанного 99.6 (r4) — регрессия за пределом ε 0.2
    h.ingest(rec("r5", "layer_a", "vc", T0 + 5, [("f0", 99.1, "A5"), ("f1", 100.0, "B")]))
    assert G.evaluate(h, "p", "layers", cfg())["summary"]["regressions"] == 1
    # принятый храповик (явно) важнее лучшего записанного
    out = G.accept(h, "p", "r2")
    assert {a["frame"] for a in out["accepted"]} == {"f0", "f1"}
    res = G.evaluate(h, "p", "layers", cfg())
    f0 = [x for x in res["improved"] if x["frame"] == "f0"]
    assert res["verdict"] == "pass" and f0 and f0[0]["base_src"] == "accepted" and f0[0]["was"] == 98.5
    h.close()


def test_stale_golden_and_contended_excluded(tmpdir_win):
    h = make(tmpdir_win)
    g = os.path.join(tmpdir_win, "golden_f0.png")
    with open(g, "wb") as f:
        f.write(b"x")
    os.utime(g, (T0 + 2.5, T0 + 2.5))               # golden обновлён после r1, r2
    for rid, ts, p in (("r1", T0 + 1, 99.0), ("r2", T0 + 2, 98.5), ("r3", T0 + 3, 98.9)):
        h.ingest(rec(rid, "layer_a", "vc", ts, [("f0", p, "A" + rid)], golden=g))
    h.ingest(rec("r6", "layer_a", "vc", T0 + 6, [("f0", 99.5, "A6")], golden=g, contended=1))
    h.ingest(rec("r7", "layer_a", "vc", T0 + 7, [("f0", 98.0, "A7")], golden=g))
    G._EPOCH.clear()
    res = G.evaluate(h, "p", "layers", cfg())
    reg = res["regressions"]
    # основание — r3 (98.9): r1/r2 старше golden, r6 contended
    assert len(reg) == 1 and reg[0]["base_run"] == "r3" and reg[0]["was"] == 98.9
    # прогон, который старше своего golden, — stale, а не регрессия
    os.utime(g, (T0 + 100, T0 + 100))
    G._EPOCH.clear()
    res = G.evaluate(h, "p", "layers", cfg())
    assert res["summary"]["stale"] == 1 and res["summary"]["regressions"] == 0
    h.close()


def test_series_state_regression_and_perf(tmpdir_win):
    h = H.History(os.path.join(tmpdir_win, "h.sqlite"))
    h.ingest(rec("e1", "e2e_w", "vc", T0 + 1, series=[(1, 100.0, 1), (5, 95.0, 1)], kind="e2e"))
    h.ingest(rec("e2", "e2e_w", "vc", T0 + 2, series=[(1, 100.0, 1), (5, 95.0, 0)], kind="e2e"))
    h.ingest(rec("ej", "e2e_w", "java", T0, series=[(1, 100.0, 1), (5, 99.0, 1)], kind="e2e"))
    res = G.evaluate(h, "p", "e2e", cfg())
    assert res["verdict"] == "fail" and [x["frame"] for x in res["state_regressions"]] == ["kf_0005"]
    assert res["summary"]["regressions"] == 0
    # перф: семейство по тегу; contended — игнор; падение > допуска — warn (perf_fail=false) или fail
    pm = lambda v: {"all.fps_5s.p5": v}   # noqa: E731
    h.ingest(rec("p1", "perf_normal", "vc", T0 + 1, kind="perf", tag="after3_1", perf=pm(65.5), contended=0))
    h.ingest(rec("p2", "perf_normal", "vc", T0 + 2, kind="perf", tag="after3_2", perf=pm(30.0), contended=1))
    h.ingest(rec("px", "perf_normal", "vc", T0 + 3, kind="perf", tag="exp_nolm", perf=pm(5.0), contended=0))
    out = {(p["family"], p["verdict"]) for p in G.perf_eval(h, "p", cfg())}
    assert out == {("after", "ignored: contended")}, out
    h.ingest(rec("p3", "perf_normal", "vc", T0 + 4, kind="perf", tag="after4", perf=pm(30.0), contended=0))
    res = G.evaluate(h, "p", "perf", cfg())
    assert res["verdict"] == "warn" and res["exit_code"] == 3 and res["perf"][0]["best_run"] == "p1"
    assert G.evaluate(h, "p", "perf", cfg(perf_fail=True))["verdict"] == "fail"
    h.close()


def test_report_files(tmpdir_win):
    h = make(tmpdir_win)
    h.ingest(rec("j1", "layer_a", "java", T0, [("f0", 100.0, "J"), ("f1", 100.0, "B")]))
    res = G.write(G.evaluate(h, "p", "all", cfg()), os.path.join(tmpdir_win, "gates"))
    md = open(res["report_md"], encoding="utf-8").read()
    assert "## Регрессии" in md and "layer_a | 0.31 | f0 | 99.000 | 98.900" in md and "![heat](file:///D:/h/f0.png)" in md
    h.add_gate(res)
    assert h.gates("p")[0]["verdict"] == "fail"
    h.close()
