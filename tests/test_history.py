"""История (этап 2б): адаптеры каталогов прогонов (старые раннеры, E2E, перф, лаборатория, единый отчёт 2а), upsert,
импорт на синтетических каталогах (импорт реальных прогонов первого проекта — в его тестах, волна 6)."""
import json
import os
import time

import pytest

from vclab.quality import history as H
from vclab import play as P



def wj(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f)


def legacy_layer(root, outer, scen, impl, pcts, golden_dir="D:\\g", shas=None):
    d = os.path.join(root, outer, scen)
    shots = [{"name": "%d_f" % i, "sha256": (shas or {}).get(i, "sha%d_%s" % (i, outer))} for i in range(len(pcts))]
    cmp_ = [{"name": "%d_f" % i, "identical_pct": p, "within_tol_pct": p, "coverage_a_pct": 99.0, "max_delta": 3,
             "w": 854, "h": 480, "b": os.path.join(golden_dir, scen, "%d_f.png" % i),
             "heat_png": os.path.join(d, "%d_f_heat.png" % i)} for i, p in enumerate(pcts)]
    wj(os.path.join(d, "report.json"), {"scenario": scen, "impl": impl, "dir": d, "steps": [], "shots": shots,
                                        "compare": cmp_, "ok": True, "dur": 12.5})
    return d


def test_adapters_and_upsert(tmpdir_win):
    root = os.path.join(tmpdir_win, "runs")
    legacy_layer(root, "20261001_010000_vc_a", "layer_x", "vc", [99.5, 98.0])
    legacy_layer(root, "20261001_010000_vc_a", "layer_y", "vc", [100.0])
    # E2E: run.json + vs_golden/compare.json
    e = os.path.join(root, "20261001_020000_e2e_vc", "e2e_w")
    wj(os.path.join(e, "run.json"), {"scenario": "e2e_w", "impl": "vc", "size": "854x480", "timing": {"setup": 4}})
    wj(os.path.join(e, "vs_golden", "compare.json"), {
        "summary": {"a": "D:\\golden\\e2e_w", "min_identical_pct": 90.0, "first_divergence_outside_reference_noise": 5},
        "keyframes": [{"tick": 1, "identical_pct": 100.0}, {"tick": 5, "identical_pct": 90.0}],
        "states": [{"tick": 1, "player": True, "inventory": True}, {"tick": 5, "player": True, "inventory": False}]})
    # перф
    wj(os.path.join(root, "20261001_030000_perf_normal_after3_1", "perf_summary.json"), {
        "meta": {"mode": "normal"}, "all": {"frames": 9000, "fps_5s": {"min": 42.2, "p5": 65.5, "median": 114.2},
                                           "slow_frames": 162, "fps_avg": 99.0}})
    # прогон лаборатории (этап 1)
    wj(os.path.join(root, "20261001_040000_proj_engine", "report.json"), {
        "id": "20261001_040000_proj_engine", "project": "proj", "scenario": "proj-engine-1",
        "opened": 1790000000.0, "closed": 1790000100.0, "shots": [{"name": "smoke", "sha256": "abc", "w": 854, "h": 480}],
        "meta": {"exe": {"proj-engine-1": {"sha256": "exe1"}}}, "verdict": "done"})
    # единый отчёт этапа 2а: report.json прогона (scenario = отчёт интерпретатора) + vs_golden/compare.json
    r2 = os.path.join(root, "20261001_050000_proj_layer_z_vc")
    wj(os.path.join(r2, "report.json"), {
        "id": "20261001_050000_proj_layer_z_vc", "project": "proj", "opened": 1790001000.0, "closed": 1790001100.0,
        "verdict": "ok", "shots": [], "meta": {},
        "scenario": {"harness": "lab-scenario/1", "impl": "vc", "size": "854x480", "timing": {"total": 30},
                     "inputs": {"key": "gold-key-1"},
                     "results": [{"scenario": "layer_z", "kind": "steps", "ok": True, "dur": 20,
                                  "shots": [{"name": "0_a", "sha256": "s0", "tick": 10}]},
                                 {"scenario": "e2e_t", "kind": "timeline", "ok": True,
                                  "shots": [{"name": "kf_0001", "sha256": "k1", "tick": 1}]}]}})
    wj(os.path.join(r2, "vs_golden", "compare.json"), {"scenarios": {
        "layer_z": {"kind": "steps", "shots": [{"name": "0_a", "identical_pct": 97.5, "within_tol_pct": 97.5,
                                                "coverage_b_pct": 99, "max_delta": 9, "sha_b": "s0",
                                                "a": "D:\\golden\\layer_z\\0_a.png", "heat_png": "h.png"}]},
        "e2e_t": {"kind": "timeline", "series": {"keyframes": [{"name": "kf_0001", "tick": 1, "identical_pct": 99.0}],
                                                 "states": [{"tick": 1, "player": True, "chat": False}]}}}})
    h = H.History(os.path.join(tmpdir_win, "h.sqlite"))
    st = h.import_tree([root], "proj", P.legacy_parser({}))
    assert st["errors"] == [] and st["dirs"] == 5
    assert st["by_kind"] == {"layers/vc": 3, "e2e/vc": 2, "perf/vc": 1, "lab/vc": 1}, st["by_kind"]
    x = h.shots("20261001_010000_vc_a/layer_x")
    assert [round(s["identical_pct"], 1) for s in x] == [99.5, 98.0] and x[0]["sha"] == "sha0_20261001_010000_vc_a"
    se = h.series("20261001_020000_e2e_vc/e2e_w")
    assert [(s["tick"], s["pct"], s["state_equal"]) for s in se] == [(1, 100.0, 1), (5, 90.0, 0)]
    pf = h.perf("20261001_030000_perf_normal_after3_1")
    assert pf["all.fps_5s.p5"] == 65.5 and pf["all.slow_frames"] == 162
    r = h.runs("proj", kind="perf")[0]
    assert r["scenario"] == "perf_normal" and r["tag"] == "after3_1"
    z = h.runs("proj", scenario="layer_z")[0]
    assert z["golden_id"] == "gold-key-1" and z["source"] == "lab-scenario"
    assert h.shots(z["id"])[0]["identical_pct"] == 97.5 and h.shots(z["id"])[0]["heat_png"] == "h.png"
    t = h.runs("proj", scenario="e2e_t")[0]
    assert t["kind"] == "e2e" and [(s["tick"], s["pct"], s["state_equal"]) for s in h.series(t["id"])] == [(1, 99.0, 0)]
    lab = h.runs("proj", kind="lab")[0]
    assert lab["exe_sha"] == "exe1" and h.shots(lab["id"])[0]["sha"] == "abc"
    # повторный импорт — upsert, не дубли
    n0 = len(h.runs("proj"))
    h.import_tree([root], "proj")
    assert len(h.runs("proj")) == n0
    rows = h.summary_rows("proj", last=50)
    assert any(r["scenario"] == "layer_x" and abs(r["min_pct"] - 98.0) < 1e-9 for r in rows)
    assert "layer_x" in H.table(rows)
    h.close()


def test_missing_fields_tolerated(tmpdir_win):
    root = os.path.join(tmpdir_win, "runs")
    wj(os.path.join(root, "x", "s1", "report.json"), {"impl": "vc"})                   # без compare/shots/scenario
    wj(os.path.join(root, "y", "report.json"), {"id": "y", "project": "p"})             # пустой отчёт лаборатории
    wj(os.path.join(root, "z", "e", "run.json"), {})                                    # E2E без сравнения
    with open(os.path.join(root, "x", "garbage.json"), "w") as f:
        f.write("{not json")
    wj(os.path.join(root, "w", "report.json"), {"id": "w", "project": "p", "opened": 1.0, "closed": None})  # идёт
    h = H.History(os.path.join(tmpdir_win, "h.sqlite"))
    st = h.import_tree([root], "p")
    assert st["errors"] == [] and st["runs"] == 3
    h.close()
