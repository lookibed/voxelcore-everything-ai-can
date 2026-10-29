"""Статическая панель истории: `<data>\\index.html` + `<data>\\dashboard\\<проект>.html` + `<data>\\SUMMARY.md`
(без сервера; Jinja2 + inline SVG — открывается файлом в браузере). Генерирует демон (`lab dashboard`,
`/call/core.dashboard`), читает только history.sqlite.

На странице проекта: таблица сценариев (последний %, лучший, ε J/J, спарклайн минимума по снимкам/кадрам во времени,
число прогонов, ссылка на каталог прогона), детализация по кадрам последнего прогона vc, перф-кривые (fps 5 с
min/p5/median по прогонам), история вердиктов ворот, игровые сессии (play)."""
import html
import json
import os
import time
from urllib.parse import quote

# категориальные цвета (палитра dataviz по умолчанию, слоты 1–3 проходят проверку попарно в обоих режимах)
SERIES = [("#2a78d6", "#3987e5"), ("#eb6834", "#d95926"), ("#1baf7a", "#199e70")]


def file_url(path):
    if not path:
        return ""
    p = str(path).replace("\\", "/")
    if p.startswith("/mnt/") and len(p) > 6:
        p = p[5].upper() + ":" + p[6:]
    return "file:///" + quote(p, safe="/:")


def _fmt(v, d=2):
    return "" if v is None else ("%.*f" % (d, v))


def svg_sparkline(values, w=140, h=26, lo=None, hi=None, title=""):
    """Спарклайн (последнее значение — точка). values: [(подпись, число|None)]."""
    pts = [(i, v) for i, (_, v) in enumerate(values) if v is not None]
    if not pts:
        return ""
    vs = [v for _, v in pts]
    lo = min(vs) if lo is None else lo
    hi = max(vs) if hi is None else hi
    if hi - lo < 1e-9:
        lo, hi = lo - 0.5, hi + 0.5
    n = max(1, len(values) - 1)

    def xy(i, v):
        return 3 + (w - 6) * i / n, h - 3 - (h - 6) * (v - lo) / (hi - lo)
    path = " ".join(("M" if k == 0 else "L") + "%.1f,%.1f" % xy(i, v) for k, (i, v) in enumerate(pts))
    lx, ly = xy(*pts[-1])
    tips = "".join('<circle cx="%.1f" cy="%.1f" r="5" fill="transparent"><title>%s: %s</title></circle>' % (
        *xy(i, v), html.escape(str(values[i][0])), _fmt(v, 3)) for i, v in pts)
    return ('<svg class="spark" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="%s">'
            '<path d="%s" fill="none" stroke="var(--s1)" stroke-width="1.5"/>'
            '<circle cx="%.1f" cy="%.1f" r="2.5" fill="var(--s1)"/>%s</svg>') % (
        w, h, w, h, html.escape(title), path, lx, ly, tips)


def svg_line_chart(series, width=760, height=260, x_label="", y_label="", title="", x_ticks=None, y_min=None):
    """Линейный график: series = [(имя, [(x, y), ...]), ...] (до 3 рядов), одна ось Y, легенда, подсказки <title>.
    x_ticks: [(x, подпись)] — подписи оси X (иначе числа)."""
    ml, mr, mt, mb = 44, 12, 26 if title else 10, 34
    pw, ph = width - ml - mr, height - mt - mb
    allp = [(x, y) for _, pts in series for x, y in pts if y is not None]
    if not allp:
        return '<svg width="%d" height="40"><text x="4" y="20" class="muted">нет данных</text></svg>' % width
    xs = [x for x, _ in allp]
    ys = [y for _, y in allp]
    x0, x1 = min(xs), max(xs)
    y0 = min(ys) if y_min is None else y_min
    y1 = max(ys)
    if x1 - x0 < 1e-9:
        x0, x1 = x0 - 1, x1 + 1
    if y1 - y0 < 1e-9:
        y1 = y0 + 1
    pad = (y1 - y0) * 0.05
    y1 += pad
    if y_min is None:
        y0 -= pad

    def X(x):
        return ml + pw * (x - x0) / (x1 - x0)

    def Y(y):
        return mt + ph - ph * (y - y0) / (y1 - y0)
    out = ['<svg class="chart" width="100%%" viewBox="0 0 %d %d" preserveAspectRatio="xMinYMin meet" role="img" '
           'aria-label="%s" style="max-width:%dpx">' % (width, height, html.escape(title), width),
           '<style>.t{font:11px system-ui,sans-serif;fill:var(--muted,#6b6a66)} .tt{font:600 12px system-ui,sans-serif;'
           'fill:var(--fg,#111)} .g{stroke:var(--grid,#e4e3df);stroke-width:1}</style>']
    if title:
        out.append('<text class="tt" x="%d" y="15">%s</text>' % (ml, html.escape(title)))
    for k in range(5):
        yv = y0 + (y1 - y0) * k / 4
        out.append('<line class="g" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>' % (ml, ml + pw, Y(yv), Y(yv)))
        out.append('<text class="t" x="%d" y="%.1f" text-anchor="end">%s</text>' % (ml - 4, Y(yv) + 4,
                                                                                    "%g" % round(yv, 1)))
    ticks = x_ticks or [(x0 + (x1 - x0) * k / 5, "%g" % round(x0 + (x1 - x0) * k / 5, 1)) for k in range(6)]
    step = max(1, len(ticks) // 8)
    for x, lab in ticks[::step]:
        out.append('<text class="t" x="%.1f" y="%d" text-anchor="middle">%s</text>' % (X(x), mt + ph + 14,
                                                                                       html.escape(str(lab))[:14]))
    if x_label:
        out.append('<text class="t" x="%d" y="%d" text-anchor="middle">%s</text>' % (ml + pw / 2, height - 3,
                                                                                      html.escape(x_label)))
    if y_label:
        out.append('<text class="t" x="10" y="%d" transform="rotate(-90 10 %d)" text-anchor="middle">%s</text>' % (
            mt + ph / 2, mt + ph / 2, html.escape(y_label)))
    lx = ml + pw
    for si, (name, pts) in enumerate(series[:3]):
        col = "var(--s%d)" % (si + 1)
        pts = [(x, y) for x, y in pts if y is not None]
        if not pts:
            continue
        d = " ".join(("M" if k == 0 else "L") + "%.1f,%.1f" % (X(x), Y(y)) for k, (x, y) in enumerate(pts))
        out.append('<path d="%s" fill="none" stroke="%s" stroke-width="2" stroke-linejoin="round"/>' % (d, col))
        lab = dict(x_ticks or [])
        for x, y in pts:
            out.append('<circle cx="%.1f" cy="%.1f" r="%s" fill="%s"><title>%s %s: %s</title></circle>' % (
                X(x), Y(y), "3" if len(pts) < 60 else "1.5", col, html.escape(name),
                html.escape(str(lab.get(x, "%g" % round(x, 1)))), "%g" % round(y, 2)))
        # легенда сверху справа
        tx = lx - 110 * (len(series[:3]) - si)
        out.append('<rect x="%d" y="%d" width="10" height="3" fill="%s"/><text class="t" x="%d" y="%d">%s</text>' % (
            tx, 6, col, tx + 14, 11, html.escape(name)))
    out.append("</svg>")
    return "".join(out)


CSS = """
:root{--bg:#fcfcfb;--fg:#0b0b0b;--muted:#52514e;--grid:#e4e3df;--card:#ffffff;--line:#dedcd6;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--good:#0a7a33;--bad:#c62828;--warn:#a86400}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#1a1a19;--fg:#fff;--muted:#c3c2b7;
--grid:#34332f;--card:#222220;--line:#3a3935;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--good:#4cc27a;--bad:#ff6b6b;
--warn:#e0a030}}
:root[data-theme="dark"]{--bg:#1a1a19;--fg:#fff;--muted:#c3c2b7;--grid:#34332f;--card:#222220;--line:#3a3935;
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--good:#4cc27a;--bad:#ff6b6b;--warn:#e0a030}
body{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;
padding:16px;max-width:1280px}
a{color:var(--s1)} h1{font-size:20px;margin:4px 0 2px} h2{font-size:16px;margin:22px 0 6px}
.muted{color:var(--muted)} table{border-collapse:collapse;width:100%;margin:6px 0}
th,td{border-bottom:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:middle;white-space:nowrap}
th{font-weight:600;color:var(--muted);font-size:12px} td.n{text-align:right;font-variant-numeric:tabular-nums}
.wrap{overflow-x:auto} .card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 12px;
margin:8px 0} .ok{color:var(--good);font-weight:600} .fail{color:var(--bad);font-weight:600}
.warn{color:var(--warn);font-weight:600} .tiles{display:flex;gap:10px;flex-wrap:wrap}
.tile{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px 12px;min-width:150px}
.tile b{display:block;font-size:20px} code{font-size:12px}
"""

INDEX = """<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport"
content="width=device-width,initial-scale=1"><title>Лаборатория — история</title><style>{{ css }}</style></head><body>
<h1>Лаборатория VoxelCore — история прогонов</h1>
<p class="muted">Сгенерировано {{ now }} из <code>{{ db }}</code>. Статическая страница; обновить: <code>lab dashboard</code>.</p>
<div class="wrap"><table><tr><th>проект</th><th>прогонов</th><th>по видам</th><th>последний прогон</th>
<th>последние ворота</th></tr>
{% for p in projects %}<tr><td><a href="dashboard/{{ p.name }}.html">{{ p.name }}</a></td><td class="n">{{ p.total }}</td>
<td class="muted">{{ p.kinds }}</td><td>{{ p.last }}</td><td>{% if p.gate %}<span class="{{ 'ok' if p.gate.verdict=='pass'
else 'fail' }}">{{ p.gate.verdict }}</span> {{ p.gate.when }} ({{ p.gate.suite }}, регрессий {{ p.gate.regressions }})
{% else %}<span class="muted">—</span>{% endif %}</td></tr>{% endfor %}
</table></div></body></html>"""

PROJECT = """<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport"
content="width=device-width,initial-scale=1"><title>{{ name }} — история</title><style>{{ css }}</style></head><body>
<p><a href="../index.html">← все проекты</a></p>
<h1>{{ name }}</h1>
<p class="muted">Сгенерировано {{ now }}. % — identical_pct снимка против golden (минимум по снимкам/кадрам прогона).
ε — шум Java/Java того же кадра (максимум 100 − % прогонов Java против golden), 0 — не записан.
Храповик: принятое значение (<code>lab gate accept</code>) или лучшее записанное после обновления golden.</p>
<div class="tiles">
<div class="tile"><span class="muted">прогонов</span><b>{{ total }}</b></div>
<div class="tile"><span class="muted">сценариев (vc)</span><b>{{ scen|length }}</b></div>
<div class="tile"><span class="muted">последние ворота</span><b class="{{ 'ok' if gate and gate.verdict=='pass' else 'fail' if gate else 'muted' }}">{{ gate.verdict if gate else '—' }}</b>
{% if gate %}<span class="muted">{{ gate.when }}, {{ gate.suite }}</span>{% endif %}</div>
{% if play %}<div class="tile"><span class="muted">последняя игра: fps медиана</span><b>{{ play.fps }}</b><span class="muted">{{ play.when }}</span></div>{% endif %}
</div>

<h2>Сценарии (паритет, реализация vc)</h2>
<div class="wrap"><table><tr><th>сценарий</th><th>движок</th><th>вид</th><th>последний %</th><th>лучший %</th><th>храповик</th>
<th>ε J/J</th><th>история</th><th>прогонов</th><th>последний прогон</th></tr>
{% for s in scen %}<tr><td><a href="#s-{{ s.name }}">{{ s.name }}</a></td><td>{{ s.engine }}</td><td class="muted">{{ s.kind }}</td>
<td class="n {{ 'fail' if s.drop else '' }}">{{ s.last }}</td><td class="n">{{ s.best }}</td><td class="n">{{ s.ratchet }}</td>
<td class="n">{{ s.eps }}</td><td>{{ s.spark|safe }}</td><td class="n">{{ s.n }}</td>
<td><a href="{{ s.url }}">{{ s.when }}</a> <span class="muted">{{ s.tag }}</span></td></tr>{% endfor %}
</table></div>

{% if perf %}<h2>Производительность (fps по окнам 5 с)</h2>
{% for p in perf %}<div class="card"><b>{{ p.scenario }}</b> <span class="muted">{{ p.n }} прогонов; contended отмечены *</span>
{{ p.svg|safe }}
<div class="wrap"><table><tr><th>прогон</th><th>тег</th><th>min</th><th>p5</th><th>медиана</th><th>кадров &gt; 33 мс</th>
<th>загрузка</th></tr>{% for r in p.rows %}<tr><td><a href="{{ r.url }}">{{ r.when }}</a></td><td>{{ r.tag }}</td>
<td class="n">{{ r.min }}</td><td class="n">{{ r.p5 }}</td><td class="n">{{ r.median }}</td><td class="n">{{ r.slow }}</td>
<td class="{{ 'warn' if r.contended else 'muted' }}">{{ r.load }}</td></tr>{% endfor %}</table></div></div>{% endfor %}{% endif %}

{% if others %}<h2>Тесты движка и сессии проектов (vctest, сессии; по версиям движка)</h2>
<div class="wrap"><table><tr><th>когда</th><th>сценарий</th><th>движок</th><th>вид</th><th>вердикт</th><th>метрики</th><th>прогон</th></tr>
{% for o in others %}<tr><td>{{ o.when }}</td><td>{{ o.scenario }}</td><td>{{ o.engine }}</td><td class="muted">{{ o.kind }}</td>
<td class="{{ 'ok' if o.verdict=='ok' else 'fail' }}">{{ o.verdict }}</td><td class="muted">{{ o.metrics }}</td>
<td><a href="{{ o.url }}">каталог</a></td></tr>{% endfor %}</table></div>{% endif %}

{% if plays %}<h2>Игровые сессии (lab play)</h2><div class="wrap"><table><tr><th>сессия</th><th>длительность, с</th>
<th>fps мин / p5 / медиана</th><th>чанков/с медиана / макс</th><th>ошибок</th><th>разрыв</th><th>отчёт</th></tr>
{% for p in plays %}<tr><td>{{ p.when }}</td><td class="n">{{ p.dur }}</td><td class="n">{{ p.fps }}</td><td class="n">{{ p.cr }}</td>
<td class="n">{{ p.err }}</td><td>{{ p.disc }}</td><td><a href="{{ p.url }}">{{ p.link }}</a></td></tr>{% endfor %}</table></div>{% endif %}

<h2>Ворота (история вердиктов)</h2>
{% if gates %}<div class="wrap"><table><tr><th>когда</th><th>набор</th><th>режим</th><th>вердикт</th><th>регрессий</th>
<th>улучшений</th><th>perf</th><th>отчёт</th></tr>{% for g in gates %}<tr><td>{{ g.when }}</td><td>{{ g.suite }}</td>
<td>{{ g.mode }}</td><td class="{{ 'ok' if g.verdict=='pass' else 'fail' }}">{{ g.verdict }}</td><td class="n">{{ g.regressions }}</td>
<td class="n">{{ g.improved }}</td><td>{{ g.perf }}</td><td><a href="{{ g.url }}">md</a></td></tr>{% endfor %}</table></div>
{% else %}<p class="muted">ещё не было (<code>lab gate {{ name }}</code>)</p>{% endif %}

<h2>По кадрам (последний прогон vc каждого сценария)</h2>
{% for s in scen %}<div class="card" id="s-{{ s.name }}"><b>{{ s.name }}</b> <span class="muted">{{ s.when }} {{ s.tag }}</span>
{% if s.curve %}{{ s.curve|safe }}{% endif %}
{% if s.frames %}<div class="wrap"><table><tr><th>кадр</th><th>%</th><th>лучший</th><th>ε</th><th>sha</th><th>тепловая карта</th></tr>
{% for f in s.frames %}<tr><td>{{ f.name }}</td><td class="n {{ 'fail' if f.drop else '' }}">{{ f.pct }}</td><td class="n">{{ f.best }}</td>
<td class="n">{{ f.eps }}</td><td><code>{{ f.sha }}</code></td><td>{% if f.heat %}<a href="{{ f.heat }}">heat</a>{% endif %}</td></tr>{% endfor %}
</table></div>{% endif %}</div>{% endfor %}
</body></html>"""


def _when(ts):
    return time.strftime("%m-%d %H:%M", time.localtime(ts or 0))


def project_data(h, project, gate_mod):
    """Данные страницы проекта (без HTML) — используются и в SUMMARY.md."""
    runs = h.runs(project)
    noise = gate_mod.noise_table(h, project)
    ratchet = h.ratchet(project)
    cache = {}
    from vclab.quality.history import engine_of, DEFAULT_ENGINE_VERSION
    by_scen = {}
    for r in runs:
        if r["impl"] == "vc" and r["kind"] in ("layers", "e2e"):
            by_scen.setdefault((r["scenario"], engine_of(r)), []).append(r)   # этап 4: строка на версию движка
    scen = []
    for key_ in sorted(by_scen):
        name, eng = key_
        rs = sorted(by_scen[key_], key=lambda r: r["ts"] or 0)
        hist = []
        for r in rs:
            hist.append((r, gate_mod.run_min_pct(h, r, cache)))
        vals = [(_when(r["ts"]), v) for r, v in hist]
        with_data = [x for x in hist if x[1] is not None]
        last_r, last_v = with_data[-1] if with_data else hist[-1]
        best = max((v for _, v in hist if v is not None), default=None)
        frames = []
        for key, cur in sorted(gate_mod.frames_of(h, last_r, cache).items()):
            pcts = [gate_mod.frames_of(h, r, cache).get(key, {}).get("pct") for r in rs]
            pcts = [p for p in pcts if p is not None]
            fb = max(pcts) if pcts else None
            eps = noise.get((name, key), 0.0)
            rt = ratchet.get((name, key))
            frames.append({"name": key, "pct": _fmt(cur.get("pct"), 3), "best": _fmt(fb, 3), "eps": _fmt(eps, 3),
                           "sha": (cur.get("sha") or "")[:12], "heat": file_url(cur.get("heat")),
                           "drop": cur.get("pct") is not None and fb is not None and cur["pct"] < fb - eps - 1e-9,
                           "ratchet": rt["best_pct"] if rt else None})
        curve = None
        se = h.series(last_r["id"])
        if se and any(s["pct"] is not None for s in se):
            curve = svg_line_chart([("identical %", [(s["tick"], s["pct"]) for s in se if s["pct"] is not None])],
                                   width=760, height=200, x_label="такт", title="кадры по тактам (последний прогон)")
        eps_vals = [noise.get((name, f["name"]), 0.0) for f in frames]
        rts = [ratchet[(name, f["name"])]["best_pct"] for f in frames if (name, f["name"]) in ratchet]
        scen.append({"name": name if eng == DEFAULT_ENGINE_VERSION else "%s@%s" % (name, eng), "engine": eng,
                     "kind": last_r["kind"], "last": _fmt(last_v, 3), "best": _fmt(best, 3),
                     "ratchet": _fmt(min(rts), 3) if rts else "—",
                     "eps": _fmt(max(eps_vals), 3) if eps_vals else "", "n": len(rs),
                     "spark": svg_sparkline(vals, title=name), "when": _when(last_r["ts"]), "tag": last_r["tag"] or "",
                     "url": file_url(last_r["dir"]), "frames": frames, "curve": curve, "last_v": last_v,
                     "best_v": best, "drop": any(f["drop"] for f in frames)})
    perf = []
    pruns = [r for r in runs if r["kind"] == "perf"]
    for name in sorted({r["scenario"] for r in pruns}):
        rs = sorted([r for r in pruns if r["scenario"] == name], key=lambda r: r["ts"] or 0)
        rows, s_min, s_p5, s_med, ticks = [], [], [], [], []
        for i, r in enumerate(rs):
            p = h.perf(r["id"])
            g = lambda k: p.get("all.fps_5s." + k, p.get("fps_5s." + k))  # noqa: E731
            hl = r.get("host_load") or {}
            rows.append({"when": _when(r["ts"]), "tag": r["tag"] or "", "min": _fmt(g("min"), 1), "p5": _fmt(g("p5"), 1),
                         "median": _fmt(g("median"), 1), "slow": _fmt(p.get("all.slow_frames"), 0),
                         "contended": r["contended"], "url": file_url(r["dir"]),
                         "load": ("contended: " + "; ".join(hl.get("reasons") or [])) if r["contended"] else (
                             "свободен" if r["contended"] == 0 else "не записана")})
            label = (r["tag"] or _when(r["ts"])) + ("*" if r["contended"] else "")
            ticks.append((i, label))
            s_min.append((i, g("min")))
            s_p5.append((i, g("p5")))
            s_med.append((i, g("median")))
        svg = svg_line_chart([("min", s_min), ("p5", s_p5), ("медиана", s_med)], width=900, height=260,
                             x_label="прогон (тег)", title="%s: fps 5 с" % name, x_ticks=ticks, y_min=0)
        perf.append({"scenario": name, "n": len(rs), "svg": svg, "rows": list(reversed(rows))})
    plays = []
    for r in [r for r in runs if r["kind"] == "play"]:
        p = h.perf(r["id"])
        ex = r.get("extra") or {}
        md = ex.get("report_md")
        plays.append({"when": _when(r["ts"]), "dur": _fmt(p.get("duration_s"), 0),
                      "fps": "%s / %s / %s" % (_fmt(p.get("fps_5s.min"), 1), _fmt(p.get("fps_5s.p5"), 1),
                                               _fmt(p.get("fps_5s.median"), 1)),
                      "fps_median": p.get("fps_5s.median"),
                      "cr": "%s / %s" % (_fmt(p.get("chunk_rate.median"), 1), _fmt(p.get("chunk_rate.max"), 1)),
                      "err": _fmt(p.get("errors"), 0), "disc": ex.get("disconnect") or "",
                      "url": file_url(md or r["dir"]), "link": "play_report.md" if md else "каталог"})
    others = []
    # тесты движка (vctest) и сессии проектов (вид записи = имя проекта, history.recs_lab2a)
    for r in [r for r in runs if r["kind"] == "vctest" or r["kind"] == r.get("project")][:40]:
        p = h.perf(r["id"])
        others.append({"when": _when(r["ts"]), "scenario": r["scenario"], "engine": engine_of(r), "kind": r["kind"],
                       "verdict": r["verdict"] or "", "url": file_url(r["dir"]),
                       "metrics": ", ".join("%s=%s" % (k, _fmt(v, 2)) for k, v in sorted(p.items())[:8])})
    gates = []
    for g in h.gates(project, 30):
        sm = g.get("summary") or {}
        gates.append({"when": _when(g["ts"]), "suite": g["suite"], "mode": g["mode"], "verdict": g["verdict"],
                      "regressions": g["regressions"], "improved": sm.get("improved", 0),
                      "perf": sm.get("perf", ""), "url": file_url(g["report_md"])})
    return {"name": project, "total": len(runs), "scen": scen, "perf": perf, "plays": plays, "gates": gates,
            "others": others,
            "gate": gates[0] if gates else None,
            "play": {"fps": _fmt(plays[0]["fps_median"], 1), "when": plays[0]["when"]} if plays else None}


def generate(h, data_dir, projects=None, gate_mod=None):
    """Записать index.html, dashboard\\<проект>.html, SUMMARY.md. Возвращает пути и счётчики."""
    import jinja2
    if gate_mod is None:
        from vclab.quality import gate as gate_mod
    env = jinja2.Environment(autoescape=True)
    projects = projects or h.projects()
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    os.makedirs(os.path.join(data_dir, "dashboard"), exist_ok=True)
    idx_rows = []
    datas = {}
    for p in projects:
        d = project_data(h, p, gate_mod)
        datas[p] = d
        page = env.from_string(PROJECT).render(css=CSS, now=now, **d)
        with open(os.path.join(data_dir, "dashboard", "%s.html" % p), "w", encoding="utf-8") as f:
            f.write(page)
        counts = {}
        for c in h.counts(p):
            k = "%s/%s" % (c["kind"], c["impl"])
            counts[k] = counts.get(k, 0) + c["n"]
        last = h.runs(p, last=1)
        idx_rows.append({"name": p, "total": d["total"], "kinds": ", ".join("%s %d" % kv for kv in sorted(counts.items())),
                         "last": _when(last[0]["ts"]) if last else "", "gate": d["gate"]})
    index = env.from_string(INDEX).render(css=CSS, now=now, db=h.path, projects=idx_rows)
    ip = os.path.join(data_dir, "index.html")
    with open(ip, "w", encoding="utf-8") as f:
        f.write(index)
    sp = os.path.join(data_dir, "SUMMARY.md")
    with open(sp, "w", encoding="utf-8") as f:
        f.write(summary_md(datas, now, h.path))
    return {"index": ip, "summary": sp, "pages": [os.path.join(data_dir, "dashboard", "%s.html" % p) for p in projects],
            "projects": {p: datas[p]["total"] for p in projects}}


def summary_md(datas, now, db):
    L = ["# Лаборатория — сводка для агентов", "",
         "Сгенерировано %s из `%s` (`lab dashboard`). Панель: `artifacts/lab/index.html`." % (now, db), ""]
    for p, d in datas.items():
        L.append("## %s (%d прогонов)" % (p, d["total"]))
        g = d["gate"]
        L.append("Последние ворота: %s" % ("**%s** %s, набор %s, регрессий %s — %s" % (
            g["verdict"], g["when"], g["suite"], g["regressions"], g["url"]) if g else "не было"))
        if d["scen"]:
            L.append("")
            L.append("| сценарий | последний % | лучший % | ε J/J | прогонов | последний |")
            L.append("|---|---|---|---|---|---|")
            for s in d["scen"]:
                L.append("| %s%s | %s | %s | %s | %d | %s %s |" % (s["name"], " ⚠" if s["drop"] else "", s["last"],
                                                                 s["best"], s["eps"], s["n"], s["when"], s["tag"]))
        for pf in d["perf"]:
            r = pf["rows"][0]
            L.append("")
            L.append("Перф %s: последний %s (%s) fps 5 с min/p5/медиана %s/%s/%s%s" % (
                pf["scenario"], r["when"], r["tag"], r["min"], r["p5"], r["median"],
                " — contended" if r["contended"] else ""))
        if d["plays"]:
            pl = d["plays"][0]
            L.append("")
            L.append("Последняя игровая сессия: %s, %s с, fps %s, чанков/с %s, ошибок %s" % (
                pl["when"], pl["dur"], pl["fps"], pl["cr"], pl["err"]))
        L.append("")
    return "\n".join(L) + "\n"
