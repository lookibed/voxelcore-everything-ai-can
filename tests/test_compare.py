"""Метрики сравнения (vclab/quality/compare.py поверх tools/reference/compare.py) на известных парах PNG: 100 %, один пиксель,
допуск, покрытие, bbox, разные размеры (отказ), области; серия: первое расхождение кадра и state, baseline (шум J/J)."""
import json
import os

import numpy as np

from vclab.quality import compare as C


def png(path, arr):
    C.cmp_mod().write_png(path, np.asarray(arr, dtype=np.int16))
    return path


def img(w=10, h=4, rgb=(0, 0, 0)):
    a = np.zeros((h, w, 3), np.int16)
    a[:, :] = rgb
    return a


def test_metrics_known_pairs(tmpdir_win):
    a = img()
    a[0, 0] = [255, 255, 255]                      # покрытие A: 1 пиксель из 40
    b = a.copy()
    pa, pb = png(os.path.join(tmpdir_win, "a.png"), a), png(os.path.join(tmpdir_win, "b.png"), b)
    m = C.metrics_files(pa, pb)
    assert m["identical_pct"] == 100.0 and m["bbox"] is None and m["coverage_a_pct"] == 2.5
    b[2, 7] = [3, 0, 0]                             # Δ 3 в одном пикселе
    b[3, 9] = [0, 100, 0]                           # Δ 100
    pb = png(os.path.join(tmpdir_win, "b.png"), b)
    m = C.metrics_files(pa, pb, tol=3, diff_out=os.path.join(tmpdir_win, "d.png"),
                        heat_out=os.path.join(tmpdir_win, "h.png"))
    assert m["identical"] == 38 and m["identical_pct"] == 95.0 and m["within_tol_pct"] == 97.5
    assert m["bbox"] == [7, 2, 9, 3] and m["max_delta"] == 100 and m["coverage_b_pct"] == 7.5
    assert os.path.exists(m["diff_png"]) and os.path.exists(m["heat_png"])
    assert C.rgb_sha(pa) == __import__("hashlib").sha256(a.astype(np.uint8).tobytes()).hexdigest()
    pc = png(os.path.join(tmpdir_win, "c.png"), img(w=12))
    assert "size mismatch" in C.metrics_files(pa, pc)["error"]
    r = C.compare_shot(pa, pb, tmpdir_win, "x", 0, [0, 0, 0], regions={"left": [0, 0, 5, 4], "corner": [8, 2, 10, 4]})
    assert r["regions"]["corner"]["diff"] == 1 and r["regions"]["world"]["diff"] == 1
    assert r["regions"]["left"]["diff"] == 0 and r["regions"]["left"]["pixels"] == 20
    assert os.path.exists(os.path.join(tmpdir_win, "x_diff.png"))


def _series(d, frames, states):
    os.makedirs(d, exist_ok=True)
    shots = {}
    for t, arr in frames.items():
        p = png(os.path.join(d, "kf_%04d.png" % t), arr)
        shots["kf_%04d" % t] = {"path": p, "sha256": C.rgb_sha(p)}
    with open(os.path.join(d, "states.jsonl"), "w") as f:
        for t, st in states.items():
            f.write(json.dumps({"tick": t, "state": st}) + "\n")
    with open(os.path.join(d, "scenario.json"), "w") as f:
        json.dump({"ticks": 30, "timeline": []}, f)
    return d


def test_series_first_divergence_and_baseline(tmpdir_win):
    fa = {10: img(), 20: img(), 30: img()}
    fb = {10: img(), 20: img(), 30: img(rgb=(1, 0, 0))}
    sa = {5: {"p": 1}, 10: {"p": 1}, 15: {"p": 2}, 20: {"p": 2}}
    sb = {5: {"p": 1}, 10: {"p": 1}, 15: {"p": 3}, 20: {"p": 3}}
    A = C.scenario_dir_source(_series(os.path.join(tmpdir_win, "A", "e2e"), fa, sa))
    B = C.scenario_dir_source(_series(os.path.join(tmpdir_win, "B", "e2e"), fb, sb))
    rep = C.compare_sources(A, B, os.path.join(tmpdir_win, "out"))
    s = rep["scenarios"]["e2e"]["series"]["summary"]
    assert s["keyframes"] == 3 and s["keyframes_100"] == 2 and s["first_divergent_keyframe"] == 30
    assert s["first_state_divergence"] == {"state": 15} and s["first_divergence_tick"] == 15
    assert s["timeline_ticks_a"] == 20 and os.path.exists(s["drift_png"])
    # категории плагина + baseline: такт 15 — шум эталона (J/J тоже расходился), кадр 30 — нет
    cs = lambda a, b: {"p": (a["p"] == b["p"], {})}
    base = {"keyframes": [{"tick": 30, "identical_pct": 100.0}], "states": [{"tick": 15, "p": False}]}
    se = C.series(A["scenarios"]["e2e"], B["scenarios"]["e2e"], os.path.join(tmpdir_win, "out"), 3, [0, 0, 0],
                  None, cs, base)
    assert se["summary"]["first_divergence_tick"] == 15
    assert se["summary"]["first_divergence_outside_reference_noise"] == 30
    md = open(os.path.join(tmpdir_win, "out", "report.md"), encoding="utf-8").read()
    assert "первый такт расхождения: 15" in md
    # разные размеры серий: сравнение отклоняется целиком
    A["meta"]["size"], B["meta"]["size"] = "854x480", "1390x855"
    rep = C.compare_sources(A, B, os.path.join(tmpdir_win, "out2"))
    assert "frame sizes differ" in rep["error"]
