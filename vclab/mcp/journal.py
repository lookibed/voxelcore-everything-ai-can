"""Журнал вызовов MCP (<work_root>/mcp/journal/journal.jsonl) и сценарии (<work_root>/mcp/scenarios/*.json).

Общий для всех проектов: наборы имён инструментов (что снимать, что считать действием, что обязано сменить экран...)
расширяются инструментами проектов через extend(...) из projects/<проект>/mcp_tools.py; сценарии (scenario_run)
ждут состояния игры через поставщика состояния проекта (vc.STATE: command, match_state, wait_until, mark, fmt,
state; ставит mcp_tools.py проекта). Без поставщика scenario_run отвечает ошибкой, журнал работает.

Каждый вызов инструмента проходит через call(): запись в журнал (время, аргументы, длительность,
краткий итог, экран, пометки затыков) и скриншот окна до действия (и после — у долгих ожиданий).
Инструменты: journal_report, journal_set, scenario_save, scenario_run, scenario_list.
"""
import json
import os
import re
import time

# не снимать окно до вызова: чтение/отчёты и то, что само снимает окно или (пере)запускает движок
NO_SHOT = {"vc_log", "vc_status", "vc_screenshot", "vc_shader_cells", "vc_pixels", "vc_stop", "vc_start",
           "journal_report", "journal_set", "scenario_save", "scenario_list", "scenario_run"}
# без журнала вовсе (служебные)
NO_JOURNAL = {"journal_report", "journal_set", "scenario_list"}
# действия, из которых scenario_save строит шаги
ACTIONS = {"vc_click", "vc_keys", "vc_input", "vc_start", "vc_stop", "vc_wait_log"}
# действия, после которых экран обязан смениться (иначе пометка no_change)
CHANGERS = set()
# свой порог slow: заведомо долгие вызовы (ожидания помечаются только таймаутом, None = не помечать)
SLOW_S = {"vc_start": 60.0, "scenario_run": None, "vc_wait_log": None}
# запуски движка/игры: снимок после вызова всегда, предел шага сценария 240 с
START_TOOLS = {"vc_start"}
# чтение состояния/кадра: повтор того же состояния -> пометка same_state
STATE_TOOLS = {"vc_screenshot"}
# ожидания проекта: шаг сценария получает timeout = предел шага; экран после них не контрольная точка
WAIT_TOOLS = set()
# действия в игре, у которых таймаут ответа — не провал (кадр долгий; дальше ждём ожидаемое состояние)
STALL_TOOLS = set()
# префиксы инструментов, которые снимают кадр сами (F2F) — окно до вызова не снимать
SELF_SHOT_PREFIXES = ()


def extend(no_shot=(), actions=(), changers=(), slow=None, start=(), state=(), wait=(), stall=(), self_shot_prefixes=()):
    """Точка расширения для projects/<проект>/mcp_tools.py: имена инструментов проекта в наборах журнала."""
    global SELF_SHOT_PREFIXES
    NO_SHOT.update(no_shot)
    ACTIONS.update(actions)
    CHANGERS.update(changers)
    SLOW_S.update(slow or {})
    START_TOOLS.update(start)
    STATE_TOOLS.update(state)
    WAIT_TOOLS.update(wait)
    STALL_TOOLS.update(stall)
    SELF_SHOT_PREFIXES = tuple(SELF_SHOT_PREFIXES) + tuple(self_shot_prefixes)
TIMEOUT_RX = re.compile(r"не ответила|не появился|не дождались|не дошла|TimeoutError|timed out")
TRANSIENT = re.compile(r"Loading|Connecting|Progress|Working|DownloadTerrain|^none$")


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def register(tools, vc, text):
    root = vc.WORK_ROOT                          # WSL-путь <work_root> (machine.toml)
    jdir = os.path.join(root, "mcp", "journal")
    jpath = os.path.join(jdir, "journal.jsonl")
    sdir = getattr(vc, "SCENARIOS_DIR", None) or os.path.join(root, "mcp", "scenarios")

    def provider():
        """Поставщик состояния игры (ставит mcp_tools.py проекта: vc.STATE = {command, match_state, wait_until, mark,
        fmt, state}); без него сценарии не воспроизводятся."""
        st = getattr(vc, "STATE", None)
        if not st:
            raise RuntimeError("scenario_run: no game state provider (projects/<p>/mcp_tools.py sets vc.STATE)")
        return st
    cfg = {
        "enabled": os.environ.get("VC_JOURNAL", "1") != "0",
        # all — до каждого действия и после ожиданий дольше after_s; before — только до; off — без снимков
        "shots": os.environ.get("VC_JOURNAL_SHOTS", "all"),
        "slow_s": _env_float("VC_JOURNAL_SLOW", 5.0),
        "idle_s": _env_float("VC_JOURNAL_IDLE", 20.0),
        "after_s": 2.0,
    }
    J = {"idx": None, "stack": [], "last": None, "session": "%d-%d" % (os.getpid(), int(time.time()))}

    def load_all():
        out = []
        try:
            with open(jpath, encoding="utf-8") as f:
                for line in f:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
        except OSError:
            pass
        return out

    def next_idx():
        if J["idx"] is None:
            entries = load_all()
            J["idx"] = max([e.get("idx", 0) for e in entries] or [0])
            top = [e for e in entries if e.get("parent") is None]
            J["last"] = top[-1] if top else None
        J["idx"] += 1
        return J["idx"]

    def shot_dir():
        return os.path.join(jdir, time.strftime("%Y-%m-%d"))

    def snap(name):
        """Скриншот в <work_root>/mcp/journal/<дата>/<name>.png -> (путь, секунды) или (None, 0)."""
        if cfg["shots"] == "off":
            return None, 0.0
        t = time.time()
        try:
            pid = vc.current_pid()
            if not pid:
                return None, 0.0
            path, _ = vc.take_screenshot(name, shot_dir(), pid=pid)
            return path, time.time() - t
        except Exception as exc:  # окно свернуто/нет окна — не мешать действию
            return None, time.time() - t

    def brief(result):
        parts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
        s = " | ".join(" ".join(p.split("\n")[:3]) for p in parts)
        return s[:300]

    def rel(path):
        return os.path.relpath(path, root) if path else None

    def jmeta(**kw):
        if J["stack"]:
            J["stack"][-1]["meta"].update(kw)

    vc.jmeta = jmeta

    def call(name, args, shot_before=None):
        fn = tools[name][0]
        if not cfg["enabled"] or name in NO_JOURNAL:
            return fn(args)
        parent = J["stack"][-1]["idx"] if J["stack"] else None
        idx = next_idx()
        t0 = time.time()
        entry = {"idx": idx, "t": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t0)) + ".%03d" % (t0 % 1 * 1000),
                 "ts": round(t0, 3), "tool": name, "args": args, "session": J["session"]}
        if parent is not None:
            entry["parent"] = parent
        prev = J["last"] if parent is None else None
        if prev and prev.get("session") == J["session"]:
            entry["pause"] = round(t0 - prev["ts"] - prev.get("dur", 0), 2)
        if shot_before is None:
            # инструменты с SELF_SHOT_PREFIXES снимают кадр сами через F2F; окно VoxelCore к ним отношения не имеет
            shot_before = parent is None and name not in NO_SHOT and not (
                SELF_SHOT_PREFIXES and name.startswith(SELF_SHOT_PREFIXES))
        if shot_before:
            path, cost = snap("%04d_%s" % (idx, name))
            if path:
                entry["shot"], entry["shot_s"] = rel(path), round(cost, 3)
        frame = {"idx": idx, "meta": {}}
        J["stack"].append(frame)
        try:
            result = fn(args)
        except Exception as exc:  # как в handle(): ошибка инструмента — результат
            result = text(f"{type(exc).__name__}: {exc}", error=True)
        finally:
            J["stack"].pop()
        dur = time.time() - t0
        entry["dur"] = round(dur, 2)
        meta = frame["meta"]
        if (cfg["shots"] == "all" and dur > cfg["after_s"] and name not in NO_SHOT and not (
                SELF_SHOT_PREFIXES and name.startswith(SELF_SHOT_PREFIXES))) or \
                (name in START_TOOLS and cfg["shots"] != "off" and parent is None):
            path, cost = snap("%04d_%s_after" % (idx, name))
            if path:
                entry["shot_after"] = rel(path)
        entry["result"] = brief(result)
        entry["error"] = bool(result.get("isError"))
        for k in ("screen", "world", "before", "pending", "f2f_shot"):
            if meta.get(k) is not None:
                entry[k] = meta[k]
        # ---- пометки затыков
        flags = []
        slow_s = SLOW_S.get(name, cfg["slow_s"])
        if slow_s is not None and dur > slow_s:
            flags.append("slow")
        if meta.get("timeout") or TIMEOUT_RX.search(entry["result"]):
            flags.append("timeout")
        if entry["error"] and "timeout" not in flags:
            flags.append("error")
        key = meta.get("key")
        if name in CHANGERS and not entry["error"] and key and meta.get("before_key") == key:
            flags.append("no_change")
        if prev and key and prev.get("key") == key and name in (STATE_TOOLS | WAIT_TOOLS):
            flags.append("same_state")
        if entry.get("pause", 0) > cfg["idle_s"]:
            flags.append("idle")
        if key:
            entry["key"] = key[:2000]
        entry["flags"] = flags
        if "scenario" in meta:
            entry["scenario"] = meta["scenario"]
        os.makedirs(jdir, exist_ok=True)
        with open(jpath, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        if parent is None:
            J["last"] = entry
        return result

    vc.call_tool = call

    # ------------------------------------------------------------------ отчёт
    def parse_since(v):
        v = str(v).strip()
        if re.fullmatch(r"\d+(\.\d+)?", v) and float(v) > 1e9:
            return float(v)
        for fmt_ in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S"):
            try:
                return time.mktime(time.strptime(v, fmt_))
            except ValueError:
                pass
        m = re.fullmatch(r"(\d\d?):(\d\d)(?::(\d\d))?", v)
        if m:
            lt = time.localtime()
            return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, int(m.group(1)), int(m.group(2)),
                                int(m.group(3) or 0), 0, 0, -1))
        m = re.fullmatch(r"-?(\d+)\s*(s|m|h|с|м|ч)?", v)  # "10m" — последние 10 минут
        if m:
            mult = {"m": 60, "м": 60, "h": 3600, "ч": 3600}.get(m.group(2), 1)
            return time.time() - int(m.group(1)) * mult
        raise ValueError("since: HH:MM[:SS], 'YYYY-MM-DD HH:MM:SS', epoch или '10m'")

    def short_args(a):
        if not a:
            return ""
        s = ", ".join("%s=%s" % (k, json.dumps(v, ensure_ascii=False)) for k, v in a.items())
        return s if len(s) <= 38 else s[:37] + "…"

    def select(args, entries=None):
        entries = entries if entries is not None else load_all()
        if args.get("since") is not None:
            t = parse_since(args["since"])
            entries = [e for e in entries if e.get("ts", 0) >= t]
        if args.get("from") is not None:
            entries = [e for e in entries if e.get("idx", 0) >= int(args["from"])]
        if args.get("to") is not None:
            entries = [e for e in entries if e.get("idx", 0) <= int(args["to"])]
        top = [e for e in entries if e.get("parent") is None]
        if args.get("last") is not None or (args.get("since") is None and args.get("from") is None):
            n = int(args.get("last") or 30)
            top = top[-n:]
        return top, entries

    def journal_report(args):
        top, entries = select(args)
        if not top:
            return text("журнал пуст (за выбранный отрезок)")
        inner = bool(args.get("inner", False))
        kids = {}
        for e in entries:
            if e.get("parent") is not None:
                kids.setdefault(e["parent"], []).append(e)
        rows = ["%5s %-8s %-12s %-38s %7s %7s  %-24s %-18s %s" % (
            "idx", "время", "инструмент", "аргументы", "длит,с", "пауза", "экран", "пометки", "скриншот")]

        def row(e, pad=""):
            return "%5d %-8s %-12s %-38s %7.1f %7s  %-24s %-18s %s" % (
                e["idx"], e["t"][11:19], pad + e["tool"], short_args(e.get("args")), e.get("dur", 0),
                ("%.1f" % e["pause"]) if e.get("pause") is not None else "",
                (e.get("screen") or "")[:24], ",".join(e.get("flags", [])), e.get("shot_after") or e.get("shot") or "")
        for e in top:
            rows.append(row(e))
            if inner:
                for k in kids.get(e["idx"], []):
                    rows.append(row(k, "  "))
        span = top[-1]["ts"] + top[-1].get("dur", 0) - top[0]["ts"]
        busy = sum(e.get("dur", 0) for e in top)
        pauses = sum(e.get("pause", 0) or 0 for e in top[1:])
        shot_cost = sorted(e["shot_s"] for e in entries if e.get("shot_s"))
        out = ["журнал %s: шагов %d, отрезок %.0f с = инструменты %.0f с + паузы агента %.0f с%s" % (
            os.path.relpath(jpath, root), len(top), span, busy, pauses,
            (", скриншот до действия: медиана %.2f с" % shot_cost[len(shot_cost) // 2]) if shot_cost else "")]
        out += rows
        stuck = []
        by_idx = {b["idx"]: a for a, b in zip(top, top[1:])}  # предыдущий вызов
        for e in top:
            fl = e.get("flags", [])
            why = []
            if "timeout" in fl:
                why.append("таймаут/нет ответа игры")
            if "slow" in fl:
                why.append("долгий вызов %.1f с" % e.get("dur", 0))
            if "no_change" in fl:
                why.append("действие не сменило экран/кнопки")
            if "same_state" in fl:
                why.append("то же состояние, что в прошлом шаге (опрос без изменений)")
            if "idle" in fl:
                prev_e = by_idx.get(e["idx"])
                ready = prev_e is not None and not ({"timeout", "error"} & set(prev_e.get("flags", [])))
                why.append("агент молчал %.0f с перед вызовом (%s)" % (
                    e["pause"], "ответ прошлого шага был готов" if ready else "после таймаута/ошибки прошлого шага"))
            if "error" in fl:
                why.append("ошибка: " + e.get("result", "")[:80])
            if why:
                stuck.append("  #%d %s %s: %s" % (e["idx"], e["tool"], short_args(e.get("args")), "; ".join(why)))
        # повторяющиеся проходы одного и того же пути
        seq = [(e["tool"], json.dumps(e.get("args"), sort_keys=True, ensure_ascii=False)) for e in top if e["tool"] in ACTIONS]
        repeats = {}
        for i in range(len(seq) - 2):
            k = tuple(seq[i:i + 3])
            repeats[k] = repeats.get(k, 0) + 1
        rep = [(n, k) for k, n in repeats.items() if n > 1]
        out.append("")
        if stuck:
            out.append("где затык (%d):" % len(stuck))
            out += stuck
        else:
            out.append("затыков не найдено")
        if rep:
            n, k = max(rep)
            out.append("путь пройден вручную %d раз(а): %s — сохранить scenario_save и гонять scenario_run"
                       % (n, " → ".join("%s %s" % (t, a) for t, a in k)))
        top_pause = sorted([e for e in top if e.get("pause")], key=lambda e: -e["pause"])[:3]
        if top_pause:
            out.append("самые длинные паузы агента: " + ", ".join("#%d %.0f с" % (e["idx"], e["pause"]) for e in top_pause))
        return text("\n".join(out))

    def journal_set(args):
        for k in ("enabled",):
            if k in args:
                cfg[k] = bool(args[k])
        if "shots" in args:
            if args["shots"] not in ("all", "before", "off"):
                return text("shots: all | before | off", error=True)
            cfg["shots"] = args["shots"]
        for k in ("slow_s", "idle_s", "after_s"):
            if k in args:
                cfg[k] = float(args[k])
        return text("журнал: " + ", ".join("%s=%s" % kv for kv in cfg.items()) + "\nфайл: " + jpath)

    # ------------------------------------------------------------------ сценарии
    def spath(name):
        if not re.fullmatch(r"[\w.-]+", name):
            raise ValueError("имя сценария: буквы, цифры, _ . -")
        return os.path.join(sdir, name + ".json")

    def cp_name(screen, used):
        base = {"ingame": "world"}.get(screen) or re.sub(r"^Gui(Screen)?", "", screen or "step").lower() or "step"
        name, i = base, 2
        while name in used:
            name, i = "%s_%d" % (base, i), i + 1
        used.add(name)
        return name

    def scenario_save(args):
        name = args["name"]
        path = spath(name)
        if os.path.exists(path) and not args.get("overwrite"):
            return text("%s уже есть; overwrite=true" % path, error=True)
        sel = dict(args)
        if "from_idx" in sel:
            sel["from"] = sel.pop("from_idx")
        if "to_idx" in sel:
            sel["to"] = sel.pop("to_idx")
        if sel.get("last") is None and sel.get("from") is None:
            sel["last"] = 20
        top, _ = select(sel)
        steps, used, skipped = [], set(), []
        for e in top:
            if e["tool"] not in ACTIONS:
                continue
            if e.get("error") and not args.get("keep_errors"):
                skipped.append("#%d %s (ошибка)" % (e["idx"], e["tool"]))
                continue
            step = {"tool": e["tool"], "args": e.get("args") or {}}
            screen = e.get("screen")
            if screen and e["tool"] not in WAIT_TOOLS and not TRANSIENT.search(screen):
                step["expect"] = {"screen": re.escape(screen)}
                if e.get("world"):
                    step["expect"]["world"] = True
                step["checkpoint"] = cp_name(screen, used)
            step["limit"] = max(240 if e["tool"] in START_TOOLS else 10, int(e.get("dur", 0) * 2 + 5))
            step["from_journal"] = e["idx"]
            steps.append(step)
        if not steps:
            return text("в выбранном отрезке нет действий (%s)" % ", ".join(sorted(ACTIONS)), error=True)
        doc = {"name": name, "description": args.get("description", "сохранено из журнала"),
               "created": time.strftime("%Y-%m-%d %H:%M:%S"), "steps": steps}
        os.makedirs(sdir, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1)
        lines = ["%s: %d шагов" % (os.path.relpath(path, root), len(steps))]
        for i, st in enumerate(steps, 1):
            lines.append("  %2d %-10s %-40s -> %s" % (i, st["tool"], short_args(st["args"]),
                                                     "%s [%s]" % (st["expect"]["screen"], st["checkpoint"]) if "expect" in st else "-"))
        if skipped:
            lines.append("пропущены: " + ", ".join(skipped))
        return text("\n".join(lines))

    def scenario_list(args):
        out = []
        for fn in sorted(os.listdir(sdir)) if os.path.isdir(sdir) else []:
            if fn.endswith(".json"):
                try:
                    with open(os.path.join(sdir, fn), encoding="utf-8") as f:
                        doc = json.load(f)
                    cps = [s["checkpoint"] for s in doc.get("steps", []) if s.get("checkpoint")]
                    out.append("%s — %s; шагов %d; контрольные точки: %s" % (
                        fn[:-5], doc.get("description", ""), len(doc.get("steps", [])), ", ".join(cps)))
                except (OSError, ValueError) as exc:
                    out.append("%s — не читается: %s" % (fn, exc))
        return text("\n".join(out) or "сценариев нет (%s)" % sdir)

    def find_step(steps, ref):
        if ref is None:
            return None
        if isinstance(ref, int) or re.fullmatch(r"\d+", str(ref)):
            i = int(ref) - 1
            if not 0 <= i < len(steps):
                raise ValueError("шаг %s вне 1..%d" % (ref, len(steps)))
            return i
        for i, st in enumerate(steps):
            if st.get("checkpoint") == ref:
                return i
        raise ValueError("контрольной точки %r нет; есть: %s" % (
            ref, ", ".join(s["checkpoint"] for s in steps if s.get("checkpoint"))))

    def scenario_run(args):
        st_ = provider()
        name = args["name"]
        with open(spath(name), encoding="utf-8") as f:
            doc = json.load(f)
        steps = doc["steps"]
        run_idx = J["stack"][-1]["idx"] if J["stack"] else 0
        start_i, notes, here = 0, [], None
        until_i = find_step(steps, args.get("until"))
        if until_i is None:
            until_i = len(steps) - 1
        frm = args.get("from")
        if frm is not None:
            auto = str(frm) == "auto"
            i = len(steps) - 1 if auto else find_step(steps, frm)
            if not auto and re.fullmatch(r"\d+", str(frm)):
                start_i = i
            else:
                res, st = (st_["command"]("state", 3) if vc.current_pid() else ("not-running", None))
                where = st.get("screen") if st else ("не запущен" if res == "not-running" else "нет ответа")
                # самая поздняя контрольная точка не дальше указанной, которой соответствует текущее состояние
                # (fps-условия не проверяются: в мире уже)
                hit = None
                for j in range(i, -1, -1):
                    exp = {k: v for k, v in (steps[j].get("expect") or {}).items()
                           if k not in ("fps", "fps_lines", "fps_drop", "drop_below", "drop_grace")}
                    if steps[j].get("checkpoint") and st and exp and st_["match_state"](st, exp):
                        hit = j
                        break
                if hit is not None:
                    start_i, here = hit + 1, st
                    notes.append("движок в точке %r (%s)%s — начинаю с шага %d" % (
                        steps[hit]["checkpoint"], where,
                        "" if auto or hit == i else ", а не в %r" % frm, start_i + 1))
                else:
                    notes.append("движок не в точке %r и не в более ранних (%s) — начинаю сначала" % (frm, where))
        recs, ok, last_shot, last_state = [], True, None, None
        t_all = time.time()
        for k in range(start_i, until_i + 1):
            step = steps[k]
            tool = step["tool"]
            sargs = dict(step.get("args") or {})
            limit = float(step.get("limit", 30))
            if tool in WAIT_TOOLS and "timeout" not in sargs:
                sargs["timeout"] = limit
            rec = {"n": k + 1, "tool": tool, "args": sargs, "checkpoint": step.get("checkpoint"), "flags": []}
            skip = step.get("skip_if")
            if skip:
                st = st_["state"]["last"]
                if st and st_["match_state"](st, skip):
                    rec.update(skipped=True, tool_s=0, wait_s=0, total=0, screen=st.get("screen"))
                    recs.append(rec)
                    continue
            t0 = time.time()
            m0 = st_["mark"]()
            res = call(tool, sargs)
            rec["tool_s"] = time.time() - t0
            err = bool(res.get("isError"))
            rtext = brief(res)
            # действие проекта (STALL_TOOLS) ушло в игру, но ответ не пришёл из-за долгого кадра — не провал:
            # дальше ждём ожидаемое состояние шага (ожидания и vc_* так не прощаются)
            stalled = tool in STALL_TOOLS and \
                bool(TIMEOUT_RX.search(rtext))
            if err and not stalled and not step.get("optional"):
                rec.update(wait_s=0, total=rec["tool_s"], error=rtext)
                rec["flags"].append("error")
                ok = False
            expect = step.get("expect")
            if ok and expect:
                left = max(1.0, limit - rec["tool_s"])
                r = st_["wait_until"](expect, left, m0=m0)
                rec["wait_s"] = r["waited"]
                last_state = r.get("state") or last_state
                if r.get("fps") is not None:
                    rec["fps"] = r["fps"]
                if not r["ok"]:
                    ok = False
                    rec["flags"].append("timeout")
                    rec["error"] = "ожидание %s: %s" % (json.dumps(expect, ensure_ascii=False), r.get("reason"))
            else:
                rec.setdefault("wait_s", 0.0)
            if ok and err and stalled and not expect:
                ok = False
                rec["flags"].append("timeout")
                rec["error"] = rtext
            rec["total"] = time.time() - t0
            last_state = st_["state"]["last"] or last_state
            rec["screen"] = last_state.get("screen") if last_state else None
            if rec["total"] > float(step.get("slow_s", cfg["slow_s"])):
                rec["flags"].append("slow")
            if args.get("shots", True):
                path, _ = snap("%04d_scn_%s_%02d%s" % (run_idx, name, k + 1,
                                                        ("_" + step["checkpoint"]) if step.get("checkpoint") else ""))
                if path:
                    rec["shot"] = rel(path)
                    last_shot = path
            recs.append(rec)
            if not ok:
                break
        if not recs and here is not None:  # уже в конечной точке: только состояние и снимок
            last_state = here
            if args.get("shots", True):
                path, _ = snap("%04d_scn_%s_here" % (run_idx, name))
                last_shot = path or last_shot
        total = time.time() - t_all
        jmeta(scenario=name, screen=last_state.get("screen") if last_state else None,
              world=bool(last_state.get("world")) if last_state else None,
              timeout=not ok and any("timeout" in r["flags"] for r in recs))
        head = "сценарий %s: %s за %.1f с (%s из %d)" % (
            name, "ГОТОВО" if ok else "ОСТАНОВЛЕН", total,
            ("шаги %d..%d" % (start_i + 1, until_i + 1)) if start_i <= until_i else "шагов не осталось", len(steps))
        lines = [head] + notes
        lines.append("%3s %-10s %-34s %7s %7s %7s  %-22s %-12s %s" % (
            "шаг", "инструмент", "аргументы", "вызов,с", "ждал,с", "всего", "экран [точка]", "пометки", "скриншот"))
        for r in recs:
            scr = (r.get("screen") or "") + (" [%s]" % r["checkpoint"] if r.get("checkpoint") else "")
            lines.append("%3d %-10s %-34s %7.1f %7.1f %7.1f  %-22s %-12s %s" % (
                r["n"], r["tool"], short_args(r["args"])[:34], r.get("tool_s", 0), r.get("wait_s", 0),
                r.get("total", 0), scr[:22], ",".join(r["flags"]) + (" skip" if r.get("skipped") else ""),
                r.get("shot") or ""))
            if r.get("fps") is not None:
                lines[-1] += "  fps %.1f" % r["fps"]
        bad = [r for r in recs if r.get("error")]
        if bad:
            r = bad[-1]
            lines.append("затык на шаге %d (%s): %s" % (r["n"], r["tool"], r["error"]))
        slow = [r for r in recs if "slow" in r["flags"] and not r.get("error")]
        if slow:
            lines.append("долгие шаги: " + ", ".join("%d %s %.0f с" % (r["n"], r["tool"], r["total"]) for r in slow))
        lines.append("")
        lines.append(st_["fmt"](last_state))
        if last_shot:
            return {"content": [{"type": "text", "text": "\n".join(lines) + "\nскриншот: " + last_shot},
                                vc.image_result(last_shot, "")["content"][1]],
                    **({} if ok else {"isError": True})}
        return text("\n".join(lines), error=not ok)

    tools["journal_report"] = (journal_report, {
        "description": "Журнал вызовов vc_* и инструментов проектов: таблица шагов (длительность, пауза агента перед вызовом, экран, "
                       "пометки slow/timeout/no_change/same_state/idle/error, скриншот) и сводка «где затык». "
                       "last=N — последние N вызовов (по умолчанию 30); since — 'HH:MM', 'YYYY-MM-DD HH:MM:SS' или '10m'; "
                       "from/to — номера записей; inner=true — показать шаги внутри scenario_run.",
        "inputSchema": {"type": "object", "properties": {
            "last": {"type": "integer"}, "since": {"type": "string"}, "from": {"type": "integer"},
            "to": {"type": "integer"}, "inner": {"type": "boolean", "default": False}}},
    })
    tools["journal_set"] = (journal_set, {
        "description": "Настройки журнала: enabled, shots (all — скриншот до действия и после ожиданий дольше after_s; "
                       "before; off), slow_s (порог долгого вызова, 5), idle_s (порог паузы агента, 20), after_s (2). "
                       "Переменные окружения: VC_JOURNAL=0, VC_JOURNAL_SHOTS, VC_JOURNAL_SLOW, VC_JOURNAL_IDLE.",
        "inputSchema": {"type": "object", "properties": {
            "enabled": {"type": "boolean"}, "shots": {"type": "string", "enum": ["all", "before", "off"]},
            "slow_s": {"type": "number"}, "idle_s": {"type": "number"}, "after_s": {"type": "number"}}},
    })
    tools["scenario_save"] = (scenario_save, {
        "description": "Превратить хвост журнала в сценарий <work_root>/mcp/scenarios/<name>.json: действия (инструменты проекта, vc_click, "
                       "vc_keys, ...) с аргументами и ожидаемым экраном после шага (контрольная точка). last=N "
                       "или from/to (номера записей журнала, см. journal_report). Ошибочные шаги пропускаются.",
        "inputSchema": {"type": "object", "properties": {
            "name": {"type": "string"}, "last": {"type": "integer"}, "from": {"type": "integer"},
            "to": {"type": "integer"}, "description": {"type": "string"},
            "overwrite": {"type": "boolean", "default": False}, "keep_errors": {"type": "boolean", "default": False}},
            "required": ["name"]},
    })
    tools["scenario_list"] = (scenario_list, {
        "description": "Список сценариев <work_root>/mcp/scenarios/*.json с контрольными точками.",
        "inputSchema": {"type": "object", "properties": {}},
    })
    tools["scenario_run"] = (scenario_run, {
        "description": "Воспроизвести сценарий сервером без участия агента: шаги подряд, после каждого — плотный опрос "
                       "до ожидаемого экрана (до предела шага), скриншот на каждом шаге; в ответе отчёт по времени "
                       "шагов с пометками затыков, итоговое состояние и скриншот последнего шага. Состояние игры даёт "
                       "поставщик проекта (mcp_tools.py проекта); сценарии — scenario_list. from — контрольная точка (движок уже в ней — начать после неё; не в ней — с самой "
                       "поздней более ранней точки, которой соответствует текущее состояние; иначе сначала), 'auto' "
                       "(любая точка сценария) или номер шага; until — номер шага или контрольная точка, на которой "
                       "остановиться.",
        "inputSchema": {"type": "object", "properties": {
            "name": {"type": "string"}, "from": {"type": "string"}, "until": {"type": "string"},
            "shots": {"type": "boolean", "default": True}},
            "required": ["name"]},
    })
    return call
