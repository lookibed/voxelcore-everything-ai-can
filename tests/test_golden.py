"""Golden (vclab/quality/golden.py) на фейковом проекте: promote (манифест, CAS, история), свежесть status (входы, файл
сценария, мир, подмена снимка), импорт старых каталогов (provenance: backfilled / unknown), regen (J/J: одинаковые
прогоны -> promote; шум -> большинство + noise). Порты 25680–25689."""
import json
import os
import time

import pytest

from vclab.quality.compare import compare_api, rgb_sha
from test_scenario import lab, run  # noqa: F401  (фикстура)


def test_promote_status_and_history(lab):
    j, rep, sc = run(lab, "child")
    with pytest.raises(Exception, match="reason"):
        lab.golden.promote(j["run"], "")
    r = lab.golden.promote(j["run"], "first golden", owner="tester")
    assert r["ok"] and r["promoted"][0]["shots"] == 3
    gd = os.path.join(lab.tmp, "golden", "child")
    man = json.load(open(os.path.join(gd, "golden.json"), encoding="utf-8"))
    assert man["impl"] == "a" and man["size"] == "4x2" and man["key"]["seed"] == 7
    assert set(man["shots"]) == {"s3", "s5", "s6k"} and man["produced"]["reason"] == "first golden"
    for s in man["shots"].values():
        assert os.path.exists(os.path.join(lab.tmp, "store", s["cas"]))          # CAS
        assert s["sha256_rgb"] == rgb_sha(os.path.join(gd, s["file"])) and s["approved"] == [s["sha256_rgb"]]
    assert all(v == "recorded" for v in man["provenance"].values())
    st = lab.golden.status("scen", ["child"])["goldens"][0]
    assert st["state"] == "fresh" and not st["reasons"], st
    # вход изменился -> stale с причиной; вернули -> fresh
    patch = os.path.join(lab.tmp, "inputs", "patch.txt")
    open(patch, "w").write("patch v2\n")
    st = lab.golden.status("scen", ["child"])["goldens"][0]
    assert st["state"] == "stale" and any(x.startswith("inputs.patch changed") for x in st["reasons"]), st
    open(patch, "w").write("patch v1\n")
    assert lab.golden.status("scen", ["child"])["goldens"][0]["state"] == "fresh"
    # сценарий (и база) / мир
    base = os.path.join(lab.tmp, "scenarios", "base.json")
    txt = open(base, encoding="utf-8").read()
    open(base, "w", encoding="utf-8").write(txt + "\n")
    st = lab.golden.status("scen", ["child"])["goldens"][0]
    assert st["state"] == "stale" and any("scenario.base.base changed" in x for x in st["reasons"]), st
    open(base, "w", encoding="utf-8").write(txt)
    reg = os.path.join(lab.tmp, "worlds", "w1", "region", "r.0.0.mcr")
    open(reg, "ab").write(b"\x02")
    st = lab.golden.status("scen", ["child"])["goldens"][0]
    assert st["state"] == "stale" and any(x.startswith("inputs.world changed") for x in st["reasons"])
    open(reg, "wb").write(b"\x01" * 100)
    # подменённый снимок
    png = os.path.join(gd, "s3.png")
    keep = open(png, "rb").read()
    open(png, "wb").write(open(os.path.join(gd, "s5.png"), "rb").read())
    st = lab.golden.status("scen", ["child"])["goldens"][0]
    assert st["state"] == "stale" and "s3: file differs from manifest" in st["reasons"]
    open(png, "wb").write(keep)
    # второй promote: история, прежний манифест в .history
    j2, _, _ = run(lab, "child")
    lab.golden.promote(j2["run"], "second", owner="tester")
    hist = [json.loads(x) for x in open(os.path.join(gd, "golden.history.jsonl"), encoding="utf-8")]
    assert [h["action"] for h in hist] == ["promote", "promote"] and hist[1]["previous"]["run"] == j["run"]
    assert hist[1]["previous_files_dir"] and os.path.exists(os.path.join(hist[1]["previous_files_dir"],
                                                                         "golden.json"))
    # сравнение прогона с golden
    r = compare_api(lab, j2["run"], "golden", project="scen")
    assert r["ok"] and r["summary"]["all_identical"], r


def _legacy(lab, name, steps, shots_from_run, mtime):
    """Каталог «старого раннера»: PNG + report.json (как run_vc_scenario --golden)."""
    import shutil
    d = os.path.join(lab.tmp, "golden", name)
    os.makedirs(d, exist_ok=True)
    rep = {"scenario": name, "impl": "a", "steps": steps, "shots": []}
    for s in shots_from_run:
        dst = os.path.join(d, s["name"] + ".png")
        shutil.copyfile(s["path"], dst)
        os.utime(dst, (mtime, mtime))
        rep["shots"].append({"name": s["name"], "sha256": s["sha256"]})
    json.dump(rep, open(os.path.join(d, "report.json"), "w"))
    return d


def test_import_provenance(lab):
    j, _, sc = run(lab, "legacy1")
    shots = [dict(s, path=os.path.join(j["dir"], s["file"])) for s in sc["results"][0]["shots"]]
    steps = [{"n": i, "cmd": s["cmd"], "args": s.get("args") or {}} for i, s in enumerate(
        json.load(open(os.path.join(lab.tmp, "scenarios", "legacy1.json")))["steps"])]
    future = time.time() + 3600
    _legacy(lab, "legacy1", steps, shots, future)                     # снят «после» всех входов
    bad = [dict(s, args={"seed": 6}) if s["cmd"] == "mode" else s for s in steps]
    _legacy(lab, "legacy2", bad, shots, time.time() - 3600 * 24)     # снят «до» входов, шаги другие
    os.makedirs(os.path.join(lab.tmp, "golden", "w_like", "region"), exist_ok=True)   # не снимки (мир) — пропуск
    r = lab.golden.import_existing("scen", owner="tester")
    names = {x["name"]: x for x in r["imported"]}
    assert set(names) == {"legacy1", "legacy2"}, r
    m1 = json.load(open(os.path.join(lab.tmp, "golden", "legacy1", "golden.json"), encoding="utf-8"))
    p = m1["provenance"]
    assert p["scenario"].startswith("backfilled") and p["inputs.patch"].startswith("backfilled")
    assert p["seed"].startswith("recorded") and p["harness"].startswith("unknown")
    assert m1["produced"]["source"] == "import" and m1["shots"]["x"]["sha256_rgb"] == shots[0]["sha256_rgb"]
    assert os.path.exists(os.path.join(lab.tmp, "store", m1["shots"]["x"]["cas"]))
    st = lab.golden.status("scen", ["legacy1"])["goldens"][0]
    assert st["state"] == "unverified" and any(u.startswith("harness") for u in st["unverified"]), st
    m2 = json.load(open(os.path.join(lab.tmp, "golden", "legacy2", "golden.json"), encoding="utf-8"))
    assert m2["provenance"]["scenario"].startswith("unknown") and "differs" in m2["provenance"]["scenario"]
    assert m2["provenance"]["inputs.patch"].startswith("unknown: input changed after the golden")
    assert lab.golden.import_existing("scen", ["legacy1"])["imported"][0]["skipped"]


def test_regen_identical_and_noisy(lab):
    r = lab.golden.regen("scen", "child", runs=2, owner="tester", reason="t", impl="a")
    assert r["ok"] and r["summary"]["identical"], r
    man = json.load(open(os.path.join(lab.tmp, "golden", "child", "golden.json"), encoding="utf-8"))
    assert man["produced"]["source"] == "regen" and "2/2 identical" in man["produced"]["reason"]
    r = lab.golden.regen("scen", "noisy", runs=3, owner="tester", impl="a")
    assert r["ok"] and r["summary"]["noisy"] == ["b"], r
    man = json.load(open(os.path.join(lab.tmp, "golden", "noisy", "golden.json"), encoding="utf-8"))
    counts = man["noise"]["shots"]["b"]
    assert sorted(counts.values()) == [1, 2]
    assert man["shots"]["b"]["sha256_rgb"] == max(counts, key=counts.get)    # большинство
    assert len(man["shots"]["b"]["approved"]) == 2
