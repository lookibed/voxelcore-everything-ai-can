"""Вынесено из tests/test_history.py (ядро) в волне 1: импорт реальных прогонов первого проекта паритета."""
import os
import time

import pytest

from vclab.quality import history as H
from vclab import play as P

ALPHA_RUNS = r"D:\Prog\AlphaMine\runs"


@pytest.mark.skipif(not os.path.isdir(ALPHA_RUNS), reason="no D:\\Prog\\AlphaMine\\runs")
def test_import_real_alphamine_runs(tmpdir_win):
    """Существующие каталоги импортируются как есть; числа сверены с записями ALPHAMINE §9."""
    h = H.History(os.path.join(tmpdir_win, "h.sqlite"))
    t0 = time.time()
    st = h.import_tree([ALPHA_RUNS], "alphamine", P.legacy_parser({}))
    dt = time.time() - t0
    assert st["errors"] == []
    assert st["dirs"] >= 147 and st["runs"] >= 250, st
    kinds = st["by_kind"]
    assert kinds.get("layers/vc", 0) >= 150 and kinds.get("layers/java", 0) >= 40 and kinds.get("perf/vc", 0) >= 25
    assert kinds.get("e2e/java", 0) >= 5 and kinds.get("e2e/vc", 0) >= 5 and kinds.get("play/vc", 0) >= 1
    # ALPHAMINE §9, таблица: before 17.6 / 21.0 / 105.3; after3_1 42.2 / 65.5 / 114.2
    for rid, exp in (("20261001_014948_perf_normal_before", (17.6, 21.0, 105.3)),
                     ("20261001_021750_perf_normal_after3_1", (42.2, 65.5, 114.2))):
        p = h.perf(rid)
        got = tuple(round(p["all.fps_5s." + k], 1) for k in ("min", "p5", "median"))
        assert got == exp, (rid, got)
    # §9 «Паритет после изменений»: alpha_spawn 87.98 / 91.33 / 93.14–93.16 / 74.55 в perf_parity2
    sh = {s["name"]: s["identical_pct"] for s in h.shots("20261001_021611_perf_parity2/alpha_spawn")}
    assert round(sh["0_yaw0"], 2) == 87.98 and round(sh["3_yaw270"], 2) == 74.55
    print("imported %s in %.2f s" % (st, dt))
    h.close()
