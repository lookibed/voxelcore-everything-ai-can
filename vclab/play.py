"""`lab play <project>` — игровая сессия пользователя: аренды из дескриптора `[play]` проекта (например: игровой сервер
на свежей копии мира + стоковый рантайм `{vc_root}\\VoxelCore.exe` в обычном режиме), наблюдение за процессом (без ввода ОС, без
снимков экрана), по выходу — `play_report.md/json` + кривая fps (SVG) и запись в историю.

Ядро не знает игры: что запускать, как связать порты, какие строки — статус (fps, чанки), события (чат, сеть,
разрыв) — всё в `[play]` дескриптора проекта (см. docs/ONBOARDING.md «lab play»).

Жизненный цикл сессии (поток демона):
  sysload до старта -> аренды (order) -> общий прогон <runs_dir>\\<время>_<проект>_play -> файлы опций (--opt) ->
  старт по порядку с подстановкой портов ([[play.link]]) -> наблюдение раз в 1 с (продление аренд, max_s, stop) ->
  выход процесса `engine` (любой: пользователь закрыл окно, падение, stop) -> лог движка до release -> стоп остальных
  (сервер — мягко, stdin «stop») -> отчёт -> история -> закрыть прогон -> release.
Запись потока пакетов: точка подключения CAPTURE_HOOKS (не реализовано; `[play.capture]`)."""
import json
import os
import re
import shutil
import statistics
import threading
import time
import traceback

from vclab import policy
from vclab.quality import sysload
from vclab.scenario.decode import decode_line

VC_LOG_RX = re.compile(r"^\[(?P<lvl>[A-Z])\] (?P<d>\d{4}/\d\d/\d\d) (?P<t>\d\d:\d\d:\d\d(?:\.\d+)?)")

# Точка подключения записи пакетов (заготовка к перф-повторителю). Функция hook(session, phase) с phase in
# ("before_start", "after_start", "after_exit") может вернуть dict для отчёта. Пусто = не реализовано.
CAPTURE_HOOKS = []


# ------------------------------------------------------------------------------------------------ разбор
def _ts_of(line, date_hint=None):
    m = VC_LOG_RX.match(line)
    if not m:
        return None
    t = m.group("t")
    frac = 0.0
    if "." in t:
        t, f = t.split(".", 1)
        frac = float("0." + f)
    try:
        return time.mktime(time.strptime(m.group("d") + " " + t, "%Y/%m/%d %H:%M:%S")) + frac
    except ValueError:
        return None


def parse_status(lines, rx):
    """Строки статуса из лога движка -> [{t, <группы regex как числа>}]."""
    crx = re.compile(rx)
    out = []
    for line in lines:
        m = crx.search(line)
        if not m:
            continue
        s = {"t": _ts_of(line)}
        for k, v in m.groupdict().items():
            if v is None:
                continue
            try:
                s[k] = float(v)
            except ValueError:
                s[k] = v
        out.append(s)
    return out


def load_status_table(path, day=None):
    """Восстановленная таблица статуса (runs\\20261001_0051_user_session\\status_lines.txt): «# ...» — комментарии,
    строка «Columns: a b c» задаёт имена; время ЧЧ:ММ:СС.мс + день из имени каталога."""
    cols = None
    out = []
    if day is None:
        m = re.match(r"^(\d{8})", os.path.basename(os.path.dirname(path)))
        day = m.group(1) if m else time.strftime("%Y%m%d")
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                m = re.search(r"Columns:\s*(.*)$", line)
                if m:
                    cols = m.group(1).split()
                continue
            parts = line.split()
            names = cols or ["time", "tick", "fps", "map_chunks", "engine_chunks", "net_kb", "tick_ms", "encode_ms",
                             "inflate_ms"]
            s = {}
            for k, v in zip(names, parts):
                if k == "time":
                    hh, mm, ss = v.split(":")
                    base = time.mktime(time.strptime(day + hh + mm, "%Y%m%d%H%M"))
                    s["t"] = base + float(ss)
                else:
                    k = {"engine_chunks": "engine_chunks", "net_KB": "net_kb",
                         "ticks_ms_per_tick": "tick_ms"}.get(k, k)
                    try:
                        s[k] = float(v)
                    except ValueError:
                        s[k] = v
            if "t" in s and s["t"] is not None and out and s["t"] < out[-1]["t"] - 3600:
                s["t"] += 86400        # переход через полночь
            out.append(s)
    return out


def _pct(vals, p):
    v = sorted(vals)
    if not v:
        return None
    k = (len(v) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def summarize_status(samples, chunks_field="map_chunks"):
    """fps по окнам строк статуса (каждая строка — своё окно, обычно 5 с) и темп чанков (Δ поля / Δt)."""
    fps = [s["fps"] for s in samples if isinstance(s.get("fps"), (int, float))]
    res = {"status_lines": len(samples)}
    if fps:
        res["fps_5s"] = {"min": round(min(fps), 1), "p5": round(_pct(fps, 5), 1),
                         "median": round(statistics.median(fps), 1), "max": round(max(fps), 1), "n": len(fps)}
    rates = []
    for a, b in zip(samples, samples[1:]):
        if a.get("t") and b.get("t") and b["t"] > a["t"] and isinstance(a.get(chunks_field), (int, float)) and \
                isinstance(b.get(chunks_field), (int, float)):
            rates.append((b[chunks_field] - a[chunks_field]) / (b["t"] - a["t"]))
    if rates:
        res["chunk_rate"] = {"min": round(min(rates), 1), "median": round(statistics.median(rates), 1),
                             "max": round(max(rates), 1)}
        # окна с высокой нагрузкой чанками и fps в них (провалы «там, где MapChunk по 25–30 в секунду»)
        hi = [b.get("fps") for a, b, r in zip(samples, samples[1:], rates) if r >= 20 and b.get("fps") is not None]
        lo = [b.get("fps") for a, b, r in zip(samples, samples[1:], rates) if r < 5 and b.get("fps") is not None]
        if hi:
            res["fps_when_chunks_ge20"] = round(statistics.median(hi), 1)
        if lo:
            res["fps_when_chunks_lt5"] = round(statistics.median(lo), 1)
    if samples and isinstance(samples[-1].get(chunks_field), (int, float)):
        res["chunks_total"] = int(samples[-1][chunks_field])
    ts = [s["t"] for s in samples if s.get("t")]
    if len(ts) > 1:
        res["status_span_s"] = round(ts[-1] - ts[0], 1)
    return res


def scan_log(lines, levels=None, events=None, max_items=40):
    """Ошибки/предупреждения (сгруппированы по тексту, с числом) и события по шаблонам дескриптора."""
    levels = levels or {"error": r"^\[E\]|uncaught|Traceback|exception|stack traceback", "warning": r"^\[W\]"}
    lv = {k: re.compile(v, re.I) for k, v in levels.items()}
    ev = {k: re.compile(v) for k, v in (events or {}).items()}
    grouped = {k: {} for k in lv}
    found = []
    for i, line in enumerate(lines):
        for k, rx in lv.items():
            if rx.search(line):
                key = re.sub(r"^\[[A-Z]\] \S+ \S+ ", "", line)
                key = re.sub(r"\d+", "#", key)[:160]
                g = grouped[k].setdefault(key, {"count": 0, "first": line[:300], "line_no": i + 1})
                g["count"] += 1
                break
        for k, rx in ev.items():
            m = rx.search(line)
            if m:
                d = {k2: v for k2, v in m.groupdict().items() if v is not None}
                found.append({"event": k, "t": _ts_of(line), "line": line[:300], **d})
    out = {}
    for k, g in grouped.items():
        items = sorted(g.values(), key=lambda x: -x["count"])
        out[k] = {"total": sum(x["count"] for x in items), "distinct": len(items), "top": items[:max_items]}
    out["events"] = found[:2000]
    return out


def read_lines(path, tail=None):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return []
    lines = [decode_line(b)[0] for b in raw.split(b"\n")]
    lines = [l.rstrip("\r") for l in lines if l.strip()]
    return lines[-tail:] if tail else lines


def build_report(meta, engine_lines, server_lines, cfg):
    """meta: id, project, started, ended, exit, ended_by, host_load, leases... -> dict отчёта."""
    rep = dict(meta)
    st = parse_status(engine_lines, cfg["status"]) if cfg.get("status") else []
    rep["status_samples"] = st
    rep["metrics"] = summarize_status(st, cfg.get("chunks_field", "map_chunks"))
    if meta.get("started") and meta.get("ended"):
        rep["metrics"]["duration_s"] = round(meta["ended"] - meta["started"], 1)
    sc = scan_log(engine_lines, cfg.get("levels"), cfg.get("events"))
    rep["errors"] = sc["error"]["top"] if "error" in sc else []
    rep["errors_total"] = sc.get("error", {}).get("total", 0)
    rep["warnings"] = sc["warning"]["top"] if "warning" in sc else []
    rep["warnings_total"] = sc.get("warning", {}).get("total", 0)
    rep["events"] = sc["events"]
    rep["metrics"]["errors"] = rep["errors_total"]
    rep["metrics"]["warnings"] = rep["warnings_total"]
    cnt = {}
    for e in sc["events"]:
        cnt[e["event"]] = cnt.get(e["event"], 0) + 1
    rep["event_counts"] = cnt
    for k, v in cnt.items():
        rep["metrics"]["events." + k] = v
    disc = [e for e in sc["events"] if e["event"] in cfg.get("disconnect_events", ("disconnect",))]
    rep["disconnect"] = (disc[-1].get("reason") or disc[-1]["line"]) if disc else None
    ssc = scan_log(server_lines, cfg.get("server_levels") or {"error": r"SEVERE|Exception", "warning": r"WARNING"},
                   cfg.get("server_events"))
    rep["server"] = {"errors": ssc["error"]["top"][:10], "errors_total": ssc["error"]["total"],
                     "warnings_total": ssc["warning"]["total"], "events": ssc["events"][-50:],
                     "tail": server_lines[-int(cfg.get("server_tail", 25)):]}
    rep["engine_tail"] = engine_lines[-int(cfg.get("engine_tail", 15)):]
    if rep["errors_total"] and rep.get("ended_by") == "exit" and str(rep.get("exit", "")).startswith("0x"):
        rep["verdict"] = "crash"
    else:
        rep["verdict"] = rep.get("verdict") or ("crash" if str(rep.get("exit", "")).startswith("0xC") else "done")
    return rep


def fmt_ts(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)) if t else "?"


def report_md(rep, svg_name=None):
    m = rep.get("metrics") or {}
    f5 = m.get("fps_5s") or {}
    cr = m.get("chunk_rate") or {}
    L = ["# Игровая сессия %s — %s" % (rep.get("project", ""), rep.get("id", "")), ""]
    L.append("| | |\n|---|---|")
    L.append("| начало / конец | %s / %s |" % (fmt_ts(rep.get("started")), fmt_ts(rep.get("ended"))))
    L.append("| длительность | %s с |" % m.get("duration_s", m.get("status_span_s", "?")))
    L.append("| завершение | %s, код выхода %s |" % (rep.get("ended_by", "?"), rep.get("exit", "?")))
    L.append("| вердикт | **%s** |" % rep.get("verdict"))
    rt = rep.get("runtime") or {}
    if rt.get("mode"):
        L.append("| сеанс рантайма | %s (владелец %s)%s |" % (rt["mode"], rep.get("owner"),
                                                         ", причина: " + rt["reason"] if rt.get("reason") else ""))
    L.append("| fps по окнам статуса (мин / p5 / медиана / макс) | %s / %s / %s / %s (окон %s) |" % (
        f5.get("min"), f5.get("p5"), f5.get("median"), f5.get("max"), f5.get("n")))
    if cr:
        L.append("| чанков/с (мин / медиана / макс), всего | %s / %s / %s, %s |" % (
            cr.get("min"), cr.get("median"), cr.get("max"), m.get("chunks_total")))
    if "fps_when_chunks_ge20" in m or "fps_when_chunks_lt5" in m:
        L.append("| fps (медиана) при ≥ 20 чанков/с / при < 5 чанков/с | %s / %s |" % (
            m.get("fps_when_chunks_ge20"), m.get("fps_when_chunks_lt5")))
    L.append("| ошибки / предупреждения движка | %s / %s |" % (rep.get("errors_total", 0), rep.get("warnings_total", 0)))
    L.append("| разрыв | %s |" % (rep.get("disconnect") or "—"))
    hl = rep.get("host_load") or {}
    if hl:
        L.append("| загрузка ПК | %s%s |" % ("**contended** " if hl.get("contended") else "свободен ",
                                            "; ".join(hl.get("reasons") or [])))
    cap = rep.get("capture")
    L.append("| запись пакетов | %s |" % (cap if cap else "не реализовано (точка подключения play.CAPTURE_HOOKS)"))
    L.append("")
    if svg_name:
        L += ["![fps](%s)" % svg_name, ""]
    if rep.get("event_counts"):
        L.append("## События")
        L.append(", ".join("%s: %d" % kv for kv in sorted(rep["event_counts"].items())))
        L.append("")
        L.append("```")
        for e in [e for e in rep.get("events") or [] if e["event"] != "status"][:40]:
            L.append(e["line"][:200])
        L.append("```")
    for title, key in (("Ошибки движка", "errors"), ("Предупреждения движка", "warnings")):
        items = rep.get(key) or []
        if items:
            L.append("## %s (по тексту, с числом)" % title)
            for it in items[:15]:
                L.append("- ×%d `%s`" % (it["count"], it["first"][:180].replace("`", "'")))
            L.append("")
    sv = rep.get("server") or {}
    if sv:
        L.append("## Сервер (ошибок %s, предупреждений %s) — хвост лога" % (sv.get("errors_total"),
                                                                        sv.get("warnings_total")))
        L.append("```")
        L += [l[:200] for l in sv.get("tail") or []]
        L.append("```")
    if rep.get("engine_tail"):
        L.append("## Хвост лога движка")
        L.append("```")
        L += [l[:200] for l in rep["engine_tail"]]
        L.append("```")
    st = rep.get("status_samples") or []
    if st:
        L.append("## Строки статуса (fps, чанки)")
        keys = [k for k in ("tick", "fps", "map_chunks", "engine_chunks", "net_kb", "tick_ms") if k in st[0]]
        L.append("| время | " + " | ".join(keys) + " |")
        L.append("|---" * (len(keys) + 1) + "|")
        for s in st:
            L.append("| %s | %s |" % (time.strftime("%H:%M:%S", time.localtime(s["t"])) if s.get("t") else "",
                                      " | ".join("%g" % s[k] if isinstance(s.get(k), float) else str(s.get(k, ""))
                                                 for k in keys)))
    return "\n".join(L) + "\n"


def write_report(rep, out_dir, cfg=None):
    from vclab.dashboard import svg_line_chart
    os.makedirs(out_dir, exist_ok=True)
    st = rep.get("status_samples") or []
    svg_name = None
    if st and st[0].get("t"):
        t0 = st[0]["t"]
        series = [("fps", [((s["t"] - t0), s.get("fps")) for s in st if s.get("fps") is not None])]
        cf = (cfg or {}).get("chunks_field", "map_chunks")
        rates = []
        for a, b in zip(st, st[1:]):
            if a.get("t") and b.get("t") and b["t"] > a["t"] and cf in a and cf in b:
                rates.append((b["t"] - t0, (b[cf] - a[cf]) / (b["t"] - a["t"])))
        if rates:
            series.append(("чанков/с", rates))
        svg = svg_line_chart(series, width=760, height=240, x_label="с от первой строки статуса",
                             title="fps (окна строк статуса) и темп чанков")
        svg_name = "play_fps.svg"
        with open(os.path.join(out_dir, svg_name), "w", encoding="utf-8") as f:
            f.write(svg)
    md = report_md(rep, svg_name)
    rep["report_md"] = os.path.join(out_dir, "play_report.md")
    with open(rep["report_md"], "w", encoding="utf-8") as f:
        f.write(md)
    with open(os.path.join(out_dir, "play_report.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)
    return rep["report_md"]


def legacy_parser(cfg):
    """Для импорта истории: status_lines.txt старых сессий -> отчёт (без логов)."""
    def parse(path):
        d = os.path.dirname(path)
        log = os.path.join(d, "latest.log")
        if (cfg or {}).get("status") and os.path.isfile(log):
            # сохранённый лог сессии: полный отчёт (статус, ошибки, события); сервер — server*.err/.log рядом
            lines = read_lines(log)
            srv = []
            for n in sorted(os.listdir(d)):
                if n.startswith("server") and n.endswith((".err", ".log", ".txt")):
                    srv = read_lines(os.path.join(d, n))
                    break
            st = parse_status(lines, cfg["status"])
            if st:
                ts = [_ts_of(l) for l in lines]
                ts = [t for t in ts if t]
                rep = build_report({"id": os.path.basename(d), "project": None, "scenario": "play",
                                    "started": ts[0] if ts else st[0].get("t"),
                                    "ended": ts[-1] if ts else st[-1].get("t"), "ended_by": "saved log",
                                    "exit": None, "source": "legacy-latest-log"}, lines, srv, cfg)
                rep.pop("project", None)
                return rep
        st = load_status_table(path)
        if not st:
            return None
        rep = {"id": os.path.basename(os.path.dirname(path)), "status_samples": st,
               "metrics": summarize_status(st, (cfg or {}).get("chunks_field", "map_chunks")),
               "started": st[0].get("t"), "ended": st[-1].get("t"), "verdict": "done",
               "scenario": "play", "source": "legacy-status-lines"}
        rep["metrics"]["duration_s"] = round((st[-1]["t"] or 0) - (st[0]["t"] or 0), 1)
        return rep
    return parse


# ------------------------------------------------------------------------------------------------ сессии
def play_cfg(proj):
    """[play] дескриптора проекта (проверка обязательных полей)."""
    cfg = (proj.raw or {}).get("play")
    if not cfg:
        raise KeyError("project %s has no [play] section" % proj.name)
    order = cfg.get("order") or []
    engine = cfg.get("engine")
    if not order or engine not in order:
        raise ValueError("[play]: order = [...kinds] and engine = <kind from order> are required")
    for k in order:
        if k not in proj.kinds:
            raise ValueError("[play]: kind %r is not in [kinds.*]" % k)
    return cfg


class PlayManager:
    def __init__(self, lab):
        self.lab = lab
        self.sessions = {}
        self.lock = threading.RLock()

    # ---------------------------------------------------------- проверки
    def _exclusive(self, cfg, ctx):
        """Рантайм — один на машину: не стартовать, если такой exe уже работает (vc_start другого агента,
        пользователь) или аренда с тем же именем есть. Только чтение списка процессов."""
        exe = cfg.get("exclusive_exe")
        if not exe:
            return None
        from vclab.projects import expand
        exe = os.path.normcase(os.path.abspath(expand(exe, ctx)))
        import psutil
        for p in psutil.process_iter(["exe", "pid", "name"]):
            try:
                if p.info.get("exe") and os.path.normcase(p.info["exe"]) == exe:
                    return "%s already runs (pid %d) outside this session: the runtime engine is one per machine" % (
                        exe, p.info["pid"])
            except Exception:
                pass
        return None

    def start(self, project, owner, params=None, opts=None, max_s=None, ttl=None, wait=True, mode=None, reason=None,
              interactive=False, via=None):
        lab = self.lab
        proj = lab.projects.get(project)
        cfg = play_cfg(proj)
        # этап 3а: сеанс — только --user (пользователь, интерактивный CLI) или --final-check (claude/user + причина)
        try:
            policy.check_runtime_lease(owner, mode, reason, interactive=interactive, via=via)
        except policy.PolicyError as exc:
            lab.journal.event("lab.policy_refused", "play %s by %s (%s, via %s): %s" % (
                project, owner, mode, via, exc.message), error=True, agent=owner)
            raise PermissionError(exc.message)
        with self.lock:
            for s in self.sessions.values():
                if s["project"] == project and s["state"] in ("starting", "running", "finishing"):
                    raise RuntimeError("play session %s of %s is %s (owner %s)" % (s["id"], project, s["state"],
                                                                                   s["owner"]))
        names = cfg.get("names") or {}
        for kind, nm in names.items():
            if nm in lab.leases:
                raise RuntimeError("lease %s exists (owner %s): the %s is in use" % (nm, lab.leases[nm].owner, kind))
        why = self._exclusive(cfg, lab.base_ctx())
        if why:
            raise RuntimeError(why)
        sid = time.strftime("%Y%m%d_%H%M%S") + "_play_" + project
        sess = {"id": sid, "project": project, "owner": owner, "state": "starting", "started": time.time(),
                "mode": mode, "reason": reason, "via": via, "interactive": bool(interactive),
                "leases": {}, "run": None, "run_dir": None, "max_s": max_s, "opts": list(opts or []),
                "stop_req": None, "error": None, "report": None, "pre_load": None, "capture": None}
        with self.lock:
            self.sessions[sid] = sess
        try:
            sess["pre_load"] = sysload.check(1.0)
            self._start_leases(sess, proj, cfg, params or {}, ttl)
        except Exception as exc:
            sess["state"] = "failed"
            sess["error"] = "%s: %s" % (type(exc).__name__, exc)
            sess["trace"] = traceback.format_exc(limit=6)
            self._teardown(sess, cfg, reason="start-failed")
            raise
        sess["state"] = "running"
        sess["sampler"] = sysload.Sampler(lambda: self._pids(sess), every=5.0, window=1.0).start()
        t = threading.Thread(target=self._watch, args=(sess, proj, cfg), name="play-" + sid, daemon=True)
        sess["thread"] = t
        t.start()
        return self.info(sess)

    def _pids(self, sess):
        out = []
        for name in sess["leases"].values():
            l = self.lab.leases.get(name)
            if l and l.job:
                try:
                    out += l.job.pids()
                except Exception:
                    pass
        return out

    def _start_leases(self, sess, proj, cfg, params, ttl):
        lab = self.lab
        owner = sess["owner"]
        ttl = ttl or float(cfg.get("ttl", 3600))
        kp = {k: dict(v) for k, v in (cfg.get("params") or {}).items()}
        for key, val in params.items():            # "server.world=world_b" -> kp["server"]["world"]
            kind, _, p = key.partition(".")
            if p:
                kp.setdefault(kind, {})[p] = val
        for kind in cfg["order"]:
            rt = proj.kinds[kind].get("role") == "runtime"
            r = lab.create_lease(proj.name, kind, owner, ttl=ttl, name=(cfg.get("names") or {}).get(kind),
                                 params=kp.get(kind) or {}, mode=sess["mode"] if rt else None,
                                 reason=sess["reason"] if rt else None, interactive=sess["interactive"],
                                 via=sess["via"])
            sess["leases"][kind] = r["lease"]["name"]
        run = lab.open_run(proj.name, "play", owner, leases=list(sess["leases"].values()),
                           meta={"play": sess["id"], "opts": sess["opts"], "params": params})["run"]
        sess["run"], sess["run_dir"] = run["id"], run["dir"]
        from vclab.projects import expand
        for opt in sess["opts"]:
            o = (cfg.get("options") or {}).get(opt)
            if o is None:
                raise ValueError("unknown play option %r (have: %s)" % (opt, ", ".join(cfg.get("options") or {})))
            for fdesc in o.get("files") or []:
                l = lab._get(sess["leases"][fdesc["kind"]])
                p = os.path.join(l.dir, fdesc["path"])
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "w", encoding="utf-8", newline="\n") as f:
                    f.write(expand(fdesc.get("text", ""), lab.base_ctx()))
            for kind, pv in (o.get("params") or {}).items():
                lab._get(sess["leases"][kind]).params.update(pv)
        for hook in CAPTURE_HOOKS:
            sess["capture"] = hook(sess, "before_start")
        for kind in cfg["order"]:
            l = lab._get(sess["leases"][kind])
            for link in cfg.get("link") or []:
                if link.get("to") == kind:
                    src = lab._get(sess["leases"][link["from"]])
                    port = src.ports.get(link["port"])
                    l.params[link["param"]] = link.get("format", "{port}").replace("{port}", str(port))
            lab.start(l.name, owner=owner)
        for hook in CAPTURE_HOOKS:
            sess["capture"] = hook(sess, "after_start") or sess["capture"]

    def _watch(self, sess, proj, cfg):
        lab = self.lab
        eng_name = sess["leases"][cfg["engine"]]
        ended_by = "exit"
        try:
            while True:
                l = lab.leases.get(eng_name)
                if l is None or l.proc is None or not l.proc.alive():
                    break
                if sess["stop_req"]:
                    ended_by = "stop:" + sess["stop_req"]
                    break
                if sess["max_s"] and time.time() - sess["started"] > float(sess["max_s"]):
                    ended_by = "max_s"
                    break
                for n in sess["leases"].values():          # продлить аренды сессии (TTL не должен её оборвать)
                    ll = lab.leases.get(n)
                    if ll and ll.expires - time.time() < ll.ttl / 2:
                        ll.expires = time.time() + ll.ttl
                time.sleep(1.0)
            self._finish(sess, proj, cfg, ended_by)
        except Exception as exc:
            sess["state"] = "failed"
            sess["error"] = "%s: %s" % (type(exc).__name__, exc)
            sess["trace"] = traceback.format_exc(limit=8)
            try:
                self._teardown(sess, cfg, reason="watch-failed")
            except Exception:
                pass

    def _log_path(self, lease_name, stream):
        lab = self.lab
        l = lab._get(lease_name)
        spec = lab._spec(l)
        paths = lab._log_paths(l, spec, lab._ctx(l, spec, lab.projects.get(l.project)))
        return paths.get(stream or spec.get("default_log") or "stderr")

    def _finish(self, sess, proj, cfg, ended_by):
        lab = self.lab
        sess["state"] = "finishing"
        rcfg = cfg.get("report") or {}
        eng = lab._get(sess["leases"][cfg["engine"]])
        if eng.proc and eng.proc.alive():
            lab.stop(eng.name, owner=sess["owner"])           # stop/max_s: сначала шаги stop дескриптора
        info = eng.proc.info() if eng.proc else {}
        ended = time.time()
        eng_log = self._log_path(eng.name, rcfg.get("log_stream"))
        engine_lines = read_lines(eng_log)
        if sess["run_dir"] and os.path.isfile(eng_log):
            try:
                shutil.copyfile(eng_log, os.path.join(sess["run_dir"], "engine_latest.log"))
            except OSError:
                pass
        server_lines = []
        skind = rcfg.get("server_kind")
        for kind in reversed(cfg["order"]):                   # остальные — мягко (сервер сохраняет мир)
            if kind == cfg["engine"]:
                continue
            l = lab.leases.get(sess["leases"][kind])
            if l is None:
                continue
            p = self._log_path(l.name, rcfg.get("server_stream") if kind == skind else None)
            try:
                lab.stop(l.name, owner=sess["owner"])
            except Exception:
                pass
            if kind == skind:
                server_lines = read_lines(p)
        load = sess["sampler"].stop() if sess.get("sampler") else None
        for hook in CAPTURE_HOOKS:
            sess["capture"] = hook(sess, "after_exit") or sess["capture"]
        meta = {"id": sess["run"] or sess["id"], "session": sess["id"], "project": sess["project"],
                "scenario": "play", "started": sess["started"], "ended": ended, "ended_by": ended_by,
                "exit": info.get("exit"), "exit_code": info.get("exit_code"), "owner": sess["owner"],
                "leases": sess["leases"], "opts": sess["opts"], "host_load": load,
                "pre_load": (sess.get("pre_load") or {}).get("reasons"),
                "capture": sess.get("capture"), "engine_log": eng_log,
                "size": rcfg.get("size"),
                "runtime": {"mode": sess.get("mode"), "reason": sess.get("reason"), "via": sess.get("via")}}
        rep = build_report(meta, engine_lines, server_lines, rcfg)
        out = sess["run_dir"] or os.path.join(lab.data, "runs", sess["id"])
        write_report(rep, out, rcfg)
        sess["report"] = rep["report_md"]
        sess["verdict"] = rep["verdict"]
        sess["metrics"] = rep["metrics"]
        try:
            h = getattr(lab, "history", None)
            if h is not None:
                from vclab.quality import history as H
                h.ingest(H.rec_play(rep, os.path.join(out, "play_report.json"), sess["project"]))
                if sess.get("mode"):            # этап 3а: кто, когда и зачем поднимал стоковый рантайм
                    h.ingest(H.rec_runtime_session(rep, os.path.join(out, "play_report.json"), sess["project"]))
                sess["ingested"] = True
        except Exception as exc:
            sess["ingest_error"] = str(exc)
        self._teardown(sess, cfg, reason=ended_by, verdict=rep["verdict"])
        sess["state"] = "done"

    def _teardown(self, sess, cfg, reason, verdict=None):
        lab = self.lab
        if sess.get("sampler") and sess["state"] == "failed":
            try:
                sess["sampler"].stop()
            except Exception:
                pass
        if sess.get("run") and sess["run"] in lab.runs.active:
            try:
                lab.close_run(sess["run"], verdict or ("failed" if sess["state"] == "failed" else "done"),
                              owner=sess["owner"], extra={"play_report": sess.get("report"), "ended_by": reason})
            except Exception:
                pass
        for kind in reversed(cfg["order"]):
            n = sess["leases"].get(kind)
            if n and n in lab.leases:
                try:
                    lab.release(n, owner=sess["owner"], force=True, reason="play:" + reason)
                except Exception:
                    pass

    # ---------------------------------------------------------- API
    def stop(self, sid=None, project=None, owner=None, wait=60):
        s = self._find(sid, project)
        if s["state"] not in ("starting", "running"):
            return self.info(s)
        s["stop_req"] = owner or "stop"
        t0 = time.time()
        while s["state"] not in ("done", "failed") and time.time() - t0 < wait:
            time.sleep(0.25)
        return self.info(s)

    def _find(self, sid=None, project=None):
        with self.lock:
            if sid and sid in self.sessions:
                return self.sessions[sid]
            c = [s for s in self.sessions.values() if not project or s["project"] == project]
        if not c:
            raise KeyError("no play session%s" % (" for " + project if project else ""))
        return sorted(c, key=lambda s: s["started"])[-1]

    def info(self, s):
        d = {k: v for k, v in s.items() if k not in ("thread", "sampler", "pre_load")}
        d["elapsed_s"] = round(time.time() - s["started"], 1)
        d["pre_load_busy"] = (s.get("pre_load") or {}).get("busy")
        d["pre_load_reasons"] = (s.get("pre_load") or {}).get("reasons")
        if s.get("state") == "running":
            eng = None
            for n in s["leases"].values():
                l = self.lab.leases.get(n)
                if l and l.proc:
                    eng = eng or {}
                    eng[n] = {"pid": l.proc.pid, "alive": l.proc.alive(), "state": l.state}
            d["procs"] = eng
        return d

    def status(self, sid=None, project=None):
        try:
            return self.info(self._find(sid, project))
        except KeyError as exc:
            return {"state": "none", "message": str(exc)}

    def list(self):
        with self.lock:
            return [self.info(s) for s in self.sessions.values()]
