"""Интерпретатор сценариев лаборатории (этап 2): один для всех форматов JSON проектов, поверх аренд демона.

Ядро не знает игры. Сценарий — это JSON в scenarios_dir проекта:
  шаговый   {"base", "base_until", "setup", "size", "clear", "server", "params", "steps": [{cmd, args, name, expect,
             optional, limit}]}
  таймлайн  {"size", "server", "setup": {base, steps, mode, render, <ключи плагина>}, "ticks", "pace_ms", "timeline":
             [{tick, input|chat|gui}], "keyframes", "keyframes_every", "state_every", "state_radius", "regions"}
Шаг: команда F2F (уходит экземпляру как есть, после translate плагина) или шаг ядра (shot, compare, sleep) или шаг
плагина (steps={...} в api.scenario: look, chat_age, wait, gui...). Наследование: "base" — шаги базового сценария до
первого шага cmd == base_until (по умолчанию mode), setup базового, если своего нет. Размер кадра: "size" сценария →
базового → setup.client.size → [scenario].default_size проекта (854x480); сравнение кадров разного размера — отказ.

Сессия: прогон (каталог <runs_dir>\\<время>_<проект>_<сценарий>), аренды экземпляров (хук start плагина; по умолчанию —
вид клиента из [scenario].impls[impl]), префикс (общая подготовка) один раз, тела сценариев, finish, освобождение аренд.
Выход: shots\\<сценарий>\\<снимок>.png, shots\\<сценарий>\\states.jsonl, report.json (поле scenario: шаги, снимки с
sha256 RGB и файла, тайминги, входы golden), journal.jsonl прогона.

Lockstep (server: {f2f: true} в сценарии или базовом): каждый такт клиента идёт хуком lockstep_tick плагина (барьер,
такт клиента, такт сервера — всё в плагине), без него — f2f step + хук server_step; команды, которые двигают игру или
должны пройти через барьеры (step, wait, gui, connect, mode, input...), плагин может забрать хуком lockstep_run
(вернул None — обычный путь). Нет server_step — отказ до старта экземпляров (сервер — это проект, не ядро)."""
import copy
import hashlib
import json
import os
import re
import threading
import time
import traceback

HARNESS = "lab-scenario/1"
CORE_STEPS = ("shot", "compare", "sleep", "note")


class ScenarioError(Exception):
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def safe(name):
    return re.sub(r"[^\w.-]+", "_", str(name))[:80] or "x"


# ---------------------------------------------------------------------------------------------- загрузка
class Scenario:
    """Разобранный сценарий: prefix (подготовка из base), body (свои шаги), setup, size, кадры таймлайна."""

    def __init__(self, name, path, raw, sha):
        self.name, self.path, self.raw, self.sha256 = name, path, raw, sha
        self.chain = [{"name": name, "file": os.path.basename(path), "sha256": sha}]
        self.prefix, self.body = [], list(raw.get("steps") or [])
        self.setup = raw.get("setup") or {}
        self.base = None
        self.kind = "vctest" if raw.get("kind") == "vctest" else (
            "timeline" if ("timeline" in raw or "ticks" in raw) else "steps")
        self.size = None
        self.keyframes, self.by_tick = [], {}

    # что нужно другим модулям
    @property
    def clear(self):
        c = self.raw.get("clear")
        for st in self.body:
            if st.get("cmd") == "render" and (st.get("args") or {}).get("clear"):
                c = st["args"]["clear"]
        return list(c or [0, 0, 0])

    @property
    def lockstep_declared(self):
        """server.f2f, объявленный сценарием или его базой (ближайший в цепочке), иначе None."""
        s = self
        while s is not None:
            srv = s.raw.get("server") or (s.raw.get("setup") or {}).get("server") or {}
            if isinstance(srv, dict) and "f2f" in srv:
                return bool(srv["f2f"])
            s = s.base
        return None

    @property
    def lockstep(self):
        """Объявленное в цепочке, иначе умолчание проекта ([scenario].server_f2f, ставит ScenarioService.load)."""
        d = self.lockstep_declared
        return bool(self.lockstep_default) if d is None else d

    lockstep_default = False

    def seed(self, mode_defaults=None):
        """Сид первого mode тела (у таймлайна — setup.mode поверх умолчаний проекта)."""
        if self.kind == "timeline":
            m = dict(mode_defaults or {})
            m.update(self.setup.get("mode") or {})
            return m.get("seed")
        for st in self.body + self.prefix:
            if st.get("cmd") == "mode" and (st.get("args") or {}).get("seed") is not None:
                return st["args"]["seed"]
        return None

    def describe(self):
        return {"name": self.name, "kind": self.kind, "size": self.size, "file": self.path, "sha256": self.sha256,
                "chain": self.chain, "prefix_steps": len(self.prefix), "body_steps": len(self.body),
                "lockstep": self.lockstep, "ticks": self.raw.get("ticks"), "keyframes": len(self.keyframes)}


def _read(path):
    with open(path, "rb") as f:
        data = f.read()
    if path.lower().endswith(".lua"):
        # этап 4: Lua-файл — сценарий вида vctest (тест движка 0.32 в стиле dev/tests под --test)
        return {"kind": "vctest", "test": path}, hashlib.sha256(data).hexdigest()
    try:
        raw = json.loads(data.decode("utf-8"))
    except ValueError as exc:
        raise ScenarioError("%s: bad JSON: %s" % (path, exc))
    return raw, hashlib.sha256(data).hexdigest()


def find_file(dirs, name):
    from vclab.config import wsl_to_win
    name = wsl_to_win(name)
    if os.path.isabs(name) and os.path.isfile(name):
        return name
    for d in dirs:
        for cand in (name, name + ".json", name + ".lua"):
            p = os.path.join(d, cand)
            if os.path.isfile(p):
                return p
    raise ScenarioError("no scenario %r in %s" % (name, "; ".join(dirs)))


def steps_until(scn, until="mode"):
    """Шаги сценария (prefix + body) до первого шага cmd == until — общая подготовка наследника."""
    out = []
    for st in scn.prefix + scn.body:
        if st.get("cmd") == until:
            break
        out.append(st)
    return out


def load(dirs, name, default_size="854x480", _depth=0):
    if _depth > 8:
        raise ScenarioError("base chain too deep at %s" % name)
    if isinstance(dirs, str):
        dirs = [dirs]
    path = find_file(dirs, name)
    raw, sha = _read(path)
    name = os.path.splitext(os.path.basename(path))[0]
    s = Scenario(name, path, raw, sha)
    base_name = raw.get("base") or (s.setup.get("base") if s.kind == "timeline" else None)
    if base_name:
        b = load(dirs, base_name, default_size, _depth + 1)
        s.base = b
        s.chain += b.chain
    if s.kind == "vctest":
        t = raw.get("test") or ""
        t = t if os.path.isabs(t) else os.path.join(os.path.dirname(path), t)
        if not os.path.isfile(t):
            raise ScenarioError("%s: vctest file %s not found" % (name, t))
        if t != path:
            with open(t, "rb") as f:
                s.chain.append({"name": os.path.basename(t), "file": t, "sha256": hashlib.sha256(f.read()).hexdigest()})
        s.test = t
    elif s.kind == "steps":
        if s.base is not None:
            s.prefix = steps_until(s.base, raw.get("base_until", "mode"))
            if "setup" not in raw:
                s.setup = s.base.setup
        else:
            # без base: подготовка = шаги до первого mode (alpha_spawn как первый сценарий общей сессии)
            k = next((i for i, st in enumerate(s.body) if st.get("cmd") == "mode"), None)
            if k:
                s.prefix, s.body = s.body[:k], s.body[k:]
        for st in s.prefix + s.body:
            if not isinstance(st, dict) or not st.get("cmd"):
                raise ScenarioError("%s: step without cmd: %s" % (name, st))
    else:
        _load_timeline(s)
    if raw.get("size"):
        s.size = raw["size"]
    elif s.base is not None and s.kind == "steps":
        s.size = s.base.size
    else:
        s.size = ((s.setup.get("client") or {}).get("size") if isinstance(s.setup.get("client"), dict) else None) \
            or default_size
    if not re.fullmatch(r"\d+x\d+", str(s.size)):
        raise ScenarioError("%s: bad size %r" % (name, s.size))
    return s


def set_lockstep_default(scn, proj):
    """[scenario].server_f2f проекта — умолчание lockstep для сценариев без своего server.f2f (вся цепочка base)."""
    d = bool((proj.scenario or {}).get("server_f2f", False))
    s = scn
    while s is not None:
        s.lockstep_default = d
        s = s.base


def _load_timeline(s):
    raw = s.raw
    if "ticks" not in raw:
        raise ScenarioError("%s: timeline without ticks" % s.name)
    ticks = int(raw["ticks"])
    by_tick = {}
    for e in raw.get("timeline", []):
        t = int(e["tick"])
        if not 0 <= t < ticks:
            raise ScenarioError("%s: timeline tick %d outside 0..%d" % (s.name, t, ticks - 1))
        if not any(k in e for k in ("input", "chat", "gui", "cmd")):
            raise ScenarioError("%s: timeline entry at %d has no input/chat/gui/cmd" % (s.name, t))
        g = e.get("gui")
        if g and (int(g.get("ticks", 1)) != 1 or int(g.get("frames", 1)) != 1):
            raise ScenarioError("%s: gui entry at %d must step exactly 1 tick + 1 frame" % (s.name, t))
        by_tick.setdefault(t, []).append(e)
    kf = set(int(k) for k in raw.get("keyframes", []))
    every = int(raw.get("keyframes_every", 0))
    if every:
        kf |= set(range(every, ticks + 1, every))
    bad = [k for k in kf if not 1 <= k <= ticks]
    if bad:
        raise ScenarioError("%s: keyframes outside 1..%d: %s" % (s.name, ticks, sorted(bad)))
    s.by_tick, s.keyframes = by_tick, sorted(kf)
    s.body = []


def timeline_setup(s, hook=None, sx=None, mode_defaults=None):
    """Шаги подготовки таймлайна: base (до mode) + setup.steps + шаги плагина по своим ключам setup (tp, look...) +
    mode (такт 0) + render."""
    st = s.setup or {}
    steps = []
    if s.base is not None:
        steps += steps_until(s.base, "mode")
    steps += list(st.get("steps") or [])
    if hook:
        steps += list(hook(sx, st) or [])
    mode = dict(mode_defaults or {})
    mode.update(st.get("mode") or {})
    steps.append({"cmd": "mode", "args": mode})
    if st.get("render"):
        steps.append({"cmd": "render", "args": st["render"]})
    return steps


# ---------------------------------------------------------------------------------------------- сессия
class Session:
    """То, что видит плагин в хуках сценария (sx): аренды, F2F текущего клиента, сценарий, вывод."""

    def __init__(self, svc, job, proj, scenarios, impl, owner, opts):
        self.svc, self.lab, self.job = svc, svc.lab, job
        self.project, self.scenarios, self.impl, self.owner = proj, scenarios, impl, owner
        self.opts = dict(opts or {})
        self.scn = scenarios[0]
        self.size = scenarios[0].size
        self.leases = {}             # роль -> имя аренды
        self.client = None           # аренда, которой идут шаги
        # opts.realtime — дымовой прогон «в реальном времени» (DETERMINISM §5): сервер по часам, темп, wait.realtime
        self.lockstep = any(s.lockstep for s in scenarios) and not self.opts.get("realtime")
        self.data = {}               # для плагина
        self.run = None
        from vclab.daemon.service import FeatureCtx
        from vclab.projects import Feature
        self.ctx = FeatureCtx(self.lab, Feature("scenario", None, project=proj.name,
                                                version=proj.plugin_version or proj.name), owner)

    # ---- аренды
    def lease(self, kind, role=None, params=None, start=True, ttl=None):
        p = dict(params or {})
        if "size" not in p and self.project.kinds.get(kind, {}).get("size") is not None:
            p["size"] = self.size
        extra = ((self.scn.raw.get("params") or {}).get(kind) or {})
        for k, v in extra.items():
            p.setdefault(k, v)
        r = self.lab.create_lease(self.project.name, kind, self.owner, ttl=ttl or self.opts.get("ttl") or 1800,
                                  params=p)
        name = r["lease"]["name"]
        self.leases[role or kind] = name
        self.lab.attach_run(name, self.run["id"], owner=self.owner)
        self.job["leases"] = dict(self.leases)
        if start:
            t0 = time.time()
            s = self.lab.start(name, owner=self.owner)
            self.job.setdefault("timing", {})["start_" + (role or kind)] = round(time.time() - t0, 2)
            self.job.setdefault("starts", {})[role or kind] = {k: s.get(k) for k in ("pid", "ports", "exe",
                                                                                      "exe_sha256", "timing")}
        return name

    def kind_of(self, lease=None):
        return self.lab.lease_info(lease or self.client)["kind"]

    def port(self, lease, name):
        return self.lab.lease_info(lease)["ports"][name]

    # ---- F2F
    def f2f(self, cmd, args=None, timeout=600.0, lease=None, journal=True):
        """-> ответ F2F {ok, result|error}. Ошибки демона (instance-dead, f2f-timeout) — тоже ответ ok:false с fatal."""
        lease = lease or self.client
        from vclab.daemon.service import LabError
        try:
            if journal:
                return self.lab.f2f(lease, cmd, dict(args or {}), timeout=float(timeout), owner=self.owner)
            return self.lab.f2f_quiet(lease, cmd, dict(args or {}), timeout=float(timeout), owner=self.owner)
        except LabError as exc:
            return {"ok": False, "error": "%s: %s" % (exc.code, exc.message), "fatal": exc.code,
                    "where": lease, "detail": {k: v for k, v in exc.extra.items() if k in ("exit", "log_tail")}}

    def raw(self, cmd, args=None, timeout=600.0, lease=None):
        return self.f2f(cmd, args, timeout, lease, journal=False)

    def call(self, cmd, args=None, timeout=600.0, lease=None):
        r = self.f2f(cmd, args, timeout, lease)
        if not r.get("ok"):
            raise ScenarioError("%s: %s" % (cmd, r.get("error")))
        return r.get("result")

    def log(self, line):
        self.svc.progress(self.job, line)

    @property
    def cancelled(self):
        return self.job.get("cancel")

    def out_dir(self, scn=None):
        d = os.path.join(self.run["dir"], "shots", safe((scn or self.scn).name))
        os.makedirs(d, exist_ok=True)
        return d


# ---------------------------------------------------------------------------------------------- интерпретатор
class Interpreter:
    def __init__(self, sx):
        self.sx = sx
        self.hooks = sx.project.scenario_hooks
        self.handlers = sx.project.step_handlers

    def hook(self, name, *a, default=None):
        fn = self.hooks.get(name)
        return fn(*a) if fn else default

    # ---- один шаг
    def exec_step(self, step, i, rep, out_dir, scn):
        sx = self.sx
        cmd = step["cmd"]
        args = copy.deepcopy(step.get("args") or {})
        t0 = time.time()
        e = {"n": i, "cmd": cmd, "args": step.get("args") or {}}
        if step.get("name"):
            e["name"] = step["name"]
        jr = self.sx.lab.journal
        je = jr.begin("scenario.step", {"n": i, "cmd": cmd, "args": e["args"], "scenario": scn.name},
                      instance=sx.client, run=sx.run["id"], agent=sx.owner)
        try:
            r = self._dispatch(cmd, args, step, i, rep, out_dir, scn, e)
        except Exception as exc:
            r = {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc), "trace": traceback.format_exc(limit=5)}
        if r.get("ok") and cmd not in CORE_STEPS:
            r = self.hook("after_step", sx, step, r, default=r) or r
        e["dur"] = round(time.time() - t0, 3)
        e["ok"] = bool(r.get("ok"))
        if e["ok"]:
            e["result"] = r.get("result")
            if r.get("settle_frames") is not None:
                e["settle_frames"] = r["settle_frames"]
        else:
            e["error"] = r.get("error") if not r.get("where") or r.get("fatal") else "%s (%s)" % (
                r.get("error"), r.get("where"))
            if r.get("fatal"):
                e["fatal"] = r["fatal"]
        if e["ok"] and step.get("expect"):
            if "expect" in self.hooks:
                bad = self.hooks["expect"](sx, step["expect"]) or []
                if bad:
                    e["ok"], e["error"] = False, "expect: " + "; ".join(bad)
            else:
                e["expect_skipped"] = "project plugin has no expect hook"
        if cmd == "state" and e["ok"]:
            self._state_line(out_dir, {"n": i, "step": True, "tick": (e.get("result") or {}).get("tick"),
                                       "state": e.get("result")})
        jr.end(je, {"ok": e["ok"], "dur": e["dur"]} if e["ok"] else e.get("error"), error=not e["ok"],
               run_dir=sx.run["dir"])
        rep["steps"].append(e)
        short = json.dumps(e.get("result"), ensure_ascii=False, default=str)[:140] if e["ok"] else e.get("error")
        sx.log("%3d %-10s %7.2f s %s %s" % (i, cmd, e["dur"], "ok " if e["ok"] else "ERR", short))
        return e

    def _dispatch(self, cmd, args, step, i, rep, out_dir, scn, e):
        sx = self.sx
        if cmd == "shot":
            return self.shot(step.get("name") or "%02d" % i, out_dir, rep, scn)
        if cmd == "sleep":
            time.sleep(float(args.get("s", 1)))
            return {"ok": True, "result": {"slept": args.get("s", 1)}}
        if cmd == "note":
            return {"ok": True, "result": args}
        if cmd == "compare":
            return self.compare_step(args, rep, scn)
        if sx.lockstep and "lockstep_run" in self.hooks:
            r = self.hooks["lockstep_run"](sx, cmd, args, step)
            if r is not None:
                return r
        if cmd in self.handlers:
            return self.handlers[cmd](sx, args, step) or {"ok": False, "error": "handler %s returned nothing" % cmd}
        args = self.hook("translate", sx, cmd, args, default=args)
        if sx.lockstep and cmd == "step":
            return self.lockstep_step(args, step)
        r = sx.f2f(cmd, args, timeout=float(step.get("limit", 600)))
        if sx.lockstep and cmd in ("gui",) and r.get("ok"):
            self.server_step({"cmd": cmd, "reply": r})
        return r

    def shot(self, name, out_dir, rep, scn, tick=None):
        sx = self.sx
        path = os.path.join(out_dir, name + ".png")
        r = sx.f2f("shot", {"path": path, "name": "%s/%s" % (scn.name, name)})
        if r.get("ok"):
            res = r.get("result") or {}
            from vclab.quality.compare import rgb_sha
            # sha256 — как ответил F2F (Java: RGB-байты; движок VoxelCore: байты PNG-файла), sha256_rgb — RGB кадра
            # из PNG (одинаковый смысл у обеих реализаций), file_sha256 — файл
            s = {"scenario": scn.name, "name": name, "file": os.path.relpath(path, sx.run["dir"]),
                 "sha256": res.get("sha256"), "sha256_rgb": rgb_sha(path) if os.path.exists(path) else None,
                 "file_sha256": sha256_file(path) if os.path.exists(path) else None,
                 "w": res.get("w"), "h": res.get("h"), "tick": res.get("tick") if tick is None else tick,
                 "frame": res.get("frame")}
            w, h = (int(v) for v in sx.size.split("x"))
            if s["w"] and (s["w"], s["h"]) != (w, h):
                return {"ok": False, "error": "shot %dx%d, scenario size %s (F2F.md 8)" % (s["w"], s["h"], sx.size)}
            rep["shots"].append(s)
            r = dict(r, result=dict(res, file_sha256=s["file_sha256"]))
        return r

    def compare_step(self, args, rep, scn):
        """{cmd: compare, args: {shot, against: golden|<путь png>, tol}} — сравнить снимок прогона сразу."""
        from vclab.quality import compare as C
        name = args.get("shot") or (rep["shots"][-1]["name"] if rep["shots"] else None)
        s = next((x for x in rep["shots"] if x["name"] == name), None)
        if s is None:
            return {"ok": False, "error": "compare: no shot %r yet" % name}
        a = os.path.join(self.sx.run["dir"], s["file"])
        against = args.get("against", "golden")
        if against == "golden":
            gdir = os.path.join(self.sx.svc.golden_dir(self.sx.project), scn.name)
            b = os.path.join(gdir, name + ".png")
        else:
            b = against
        if not os.path.exists(b):
            return {"ok": True, "result": {"shot": name, "skipped": "no reference %s" % b}}
        m = C.metrics_files(b, a, tol=int(args.get("tol", 0)), clear=scn.clear)
        return {"ok": True, "result": {"shot": name, "against": b, **{k: m.get(k) for k in (
            "identical_pct", "within_tol_pct", "coverage_a_pct", "coverage_b_pct", "bbox", "max_delta", "error")}}}

    def _state_line(self, out_dir, rec):
        with open(os.path.join(out_dir, "states.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")

    # ---- lockstep (точка подключения; сервер — в плагине)
    def server_step(self, tick):
        fn = self.hooks.get("server_step")
        if fn is None:
            raise ScenarioError("lockstep scenario, but the project plugin has no server_step hook")
        return fn(self.sx, tick)

    def lockstep_step(self, args, step):
        """step {ticks:N, frames:M} в lockstep: N тактов клиента по одному, после каждого — server_step; кадры — в
        последнем такте."""
        n, frames = int(args.get("ticks", 1)), int(args.get("frames", 1))
        last = {"ok": True, "result": {}}
        tick_hook = self.hooks.get("lockstep_tick")
        for k in range(max(n, 1) if n else 0):
            a = dict(args, ticks=1, frames=frames if k == n - 1 else 0)
            if tick_hook is not None:
                last = tick_hook(self.sx, {"cmd": "step", "args": a, "k": k, "n": n})
                if not last.get("ok"):
                    return last
                continue
            last = self.sx.f2f("step", a, timeout=float(step.get("limit", 600)), journal=False)
            if not last.get("ok"):
                return last
            self.server_step({"cmd": "step", "k": k, "n": n, "reply": last})
        if n == 0 and frames:
            last = self.sx.f2f("step", dict(args), journal=False)
        return last

    # ---- последовательность шагов
    def run_steps(self, steps, rep, out_dir, scn, first=0):
        for i, step in enumerate(steps, first):
            if self.sx.cancelled:
                rep["error"] = "cancelled"
                return False
            e = self.exec_step(step, i, rep, out_dir, scn)
            if not e["ok"] and (not step.get("optional") or e.get("fatal")):
                rep["error"] = "step %d %s: %s" % (i, step["cmd"], e.get("error"))
                return False
        return True

    # ---- таймлайн (порт e2e_run.run_timeline)
    def run_timeline(self, scn, rep, out_dir):
        sx = self.sx
        raw = scn.raw
        ticks = int(raw["ticks"])
        pace = 0.0 if sx.lockstep else float(raw.get("pace_ms", 50)) / 1000.0
        K = int(raw.get("state_every", 5))
        radius = int(raw.get("state_radius", 8))
        kfs = set(scn.keyframes)
        shots, events, lags, errors, mism = rep["shots"], [], [], [], []
        states = open(os.path.join(out_dir, "states.jsonl"), "w", encoding="utf-8")
        gui = self.handlers.get("gui")
        tick_hook = self.hooks.get("lockstep_tick") if sx.lockstep else None
        t0 = time.time()
        shift = 0.0
        done = 0
        ok = True
        t = 0
        jr = sx.lab.journal
        je = jr.begin("scenario.timeline", {"scenario": scn.name, "ticks": ticks, "pace_ms": pace * 1000},
                      instance=sx.client, run=sx.run["id"], agent=sx.owner)
        try:
            for t in range(ticks):
                if sx.cancelled:
                    errors.append({"tick": t, "cmd": "cancel", "error": "cancelled"})
                    ok = False
                    break
                if pace > 0:
                    # не быстрее темпа: задержка (GC, медленный снимок) сдвигает остаток расписания
                    target = t0 + t * pace + shift
                    d = target - time.time()
                    if d > 0:
                        time.sleep(d)
                    elif d < 0:
                        shift -= d
                lags.append(round(shift * 1000, 1))
                stepped = None
                for e in scn.by_tick.get(t, []):
                    for kind in ("input", "chat", "gui", "cmd"):
                        if kind not in e:
                            continue
                        if kind == "input":
                            r = sx.raw("input", self.hook("translate", sx, "input", dict(e["input"]),
                                                         default=dict(e["input"])))
                            ev_args = e["input"]
                        elif kind == "chat":
                            r = sx.raw("chat", {"text": e["chat"]})
                            ev_args = e["chat"]
                        elif kind == "gui":
                            g = dict(e["gui"], ticks=1, frames=1)
                            ev_args = e["gui"]
                            if tick_hook is not None:      # lockstep: событие + такт клиента + такт сервера
                                r = tick_hook(sx, {"cmd": "gui", "args": g, "gui": dict(e["gui"]), "tick": t})
                                if r.get("ok"):
                                    stepped = r
                            else:
                                r = gui(sx, g, {"cmd": "gui", "args": g}) if gui else sx.raw("gui", g)
                                if r.get("ok"):
                                    stepped = r
                                    if sx.lockstep:
                                        self.server_step({"cmd": "gui", "tick": t, "reply": r})
                        else:
                            r = sx.raw(e["cmd"], self.hook("translate", sx, e["cmd"], dict(e.get("args") or {}),
                                                          default=dict(e.get("args") or {})))
                            ev_args = e.get("args")
                            kind = e["cmd"]
                        ev = {"tick": t, "cmd": kind, "args": ev_args, "ok": r.get("ok"),
                              "result": r.get("result") if r.get("ok") else r.get("error")}
                        events.append(ev)
                        if not r.get("ok"):
                            errors.append(ev)
                            sx.log("tick %d: %s failed: %s" % (t, kind, ev["result"]))
                if stepped is None and tick_hook is not None:
                    stepped = tick_hook(sx, {"cmd": "step", "args": {"ticks": 1, "frames": 1}, "tick": t})
                if stepped is None:
                    stepped = sx.raw("step", {"ticks": 1, "frames": 1})
                    if stepped.get("ok") and sx.lockstep:
                        self.server_step({"cmd": "step", "tick": t, "reply": stepped})
                if not stepped.get("ok"):
                    errors.append({"tick": t, "cmd": "step", "error": stepped.get("error")})
                    sx.log("tick %d: step failed: %s" % (t, stepped.get("error")))
                    ok = False
                    break
                n = t + 1
                done = n
                got = (stepped.get("result") or {}).get("tick")
                if got is not None and int(got) != n:
                    mism.append([n, got])
                if n in kfs:
                    r = self.shot("kf_%04d" % n, out_dir, rep, scn, tick=n)
                    if not r.get("ok"):
                        errors.append({"tick": n, "cmd": "shot", "error": r.get("error")})
                if n % K == 0 or n in kfs:
                    r = sx.raw("state", {"radius": radius})
                    rec = {"tick": n, "kf": n in kfs, "wall_s": round(time.time() - t0, 3), "lag_ms": lags[-1]}
                    if r.get("ok"):
                        rec["state"] = r["result"]
                    else:
                        rec["error"] = r.get("error")
                        errors.append({"tick": n, "cmd": "state", "error": r.get("error")})
                    states.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
                    states.flush()
                if n % 50 == 0:
                    sx.log("tick %4d  wall %6.1f s  shift %6.0f ms  shots %d  errors %d" % (
                        n, time.time() - t0, lags[-1], len(shots), len(errors)))
        except Exception as exc:
            errors.append({"tick": t, "cmd": "exception", "error": "%s: %s" % (type(exc).__name__, exc)})
            sx.log("tick %d: %s: %s" % (t, type(exc).__name__, exc))
            ok = False
        finally:
            states.close()
        rep["timeline"] = {"ok": ok, "ticks": ticks, "last_tick": done, "pace_ms": pace * 1000,
                           "wall_s": round(time.time() - t0, 1), "schedule_shift_ms": lags[-1] if lags else None,
                           "late_ticks": sum(1 for a, b in zip([0.0] + lags, lags) if b > a),
                           "lockstep": sx.lockstep}
        rep["tick_mismatch"] = {"count": len(mism), "first": mism[:5]}
        rep["lags_ms"] = lags
        rep["events"] = events
        rep["errors"] = errors
        fine = ok and not [e for e in errors if e["cmd"] in ("step", "shot", "state")]
        jr.end(je, rep["timeline"], error=not fine, run_dir=sx.run["dir"])
        if not fine:
            rep["error"] = "timeline: %s" % (errors[0] if errors else "stopped")
        return fine


# ---------------------------------------------------------------------------------------------- служба (демон)
class ScenarioService:
    """Задания интерпретатора в демоне: поток на задание, прогресс, отмена."""

    def __init__(self, lab):
        self.lab = lab
        self.jobs = {}
        self.lock = threading.Lock()

    def project(self, name):
        return self.lab.projects.get(name)

    def dirs(self, proj):
        return proj.dirs(dict(self.lab.base_ctx(), project_dir=proj.dir))

    def scen_dirs(self, proj):
        d = self.dirs(proj).get("scenarios_dir")
        # без scenarios_dir — только явные пути (vctest: lab run vc D:\...\world.lua)
        return [d] if d else []

    def golden_dir(self, proj):
        return self.dirs(proj).get("golden_dir")

    def load(self, project, names):
        proj = self.project(project)
        size = (proj.scenario or {}).get("default_size") or (proj.compare or {}).get("size") or "854x480"
        scns = [load(self.scen_dirs(proj), n, size) for n in names]
        for sc in scns:
            set_lockstep_default(sc, proj)
        return proj, scns

    def check(self, proj, scns, impl, opts=None):
        impls = (proj.scenario or {}).get("impls") or {}
        if impls and impl not in impls:
            raise ScenarioError("project %s: impl %r unknown (have: %s)" % (proj.name, impl, ", ".join(impls)))
        kinds = {s.kind for s in scns}
        if "vctest" in kinds and len(kinds) > 1:
            raise ScenarioError("vctest scenarios run in a session of their own (not with steps/timeline)")
        if "vctest" in kinds:
            return
        sizes = sorted({s.size for s in scns})
        if len(sizes) > 1:
            raise ScenarioError("scenarios with different frame sizes in one session: %s (F2F.md 8)" % sizes)
        if len(scns) > 1:
            if any(s.kind == "timeline" for s in scns):
                raise ScenarioError("a timeline scenario runs alone (one per session)")
            p0 = scns[0].prefix
            for s in scns[1:]:
                if s.prefix != p0 or s.setup != scns[0].setup:
                    raise ScenarioError("%s: other preparation (base/setup) than %s — not in one session" % (
                        s.name, scns[0].name))
        if any(s.lockstep for s in scns) and not (opts or {}).get("realtime") and \
                "server_step" not in proj.scenario_hooks:
            raise ScenarioError("scenario declares server: {f2f: true} (lockstep), but project %s has no server_step "
                                "hook (the lockstep server is not implemented for it yet)" % proj.name)

    def progress(self, job, line):
        job["seq"] = job.get("seq", 0) + 1
        job["progress"].append("%s %s" % (time.strftime("%H:%M:%S"), line))
        if len(job["progress"]) > 400:
            del job["progress"][:100]
        job["updated"] = time.time()

    def start(self, project, names, impl, owner, opts=None, wait=False):
        opts = dict(opts or {})
        proj, scns = self.load(project, names)
        self.check(proj, scns, impl, opts)
        if opts.get("size") and opts["size"] != scns[0].size:
            raise ScenarioError("--size %s differs from the scenario size %s (F2F.md 8)" % (opts["size"], scns[0].size))
        title = "+".join(s.name for s in scns) if len(scns) <= 3 else "%s+%d" % (scns[0].name, len(scns) - 1)
        run = self.lab.open_run(project, "%s_%s" % (title, impl), owner=owner,
                                meta={"scenario": {"names": [s.name for s in scns], "impl": impl, "opts": opts,
                                                   "harness": HARNESS}})["run"]
        job = {"id": run["id"], "run": run["id"], "dir": run["dir"], "project": project, "scenarios": names,
               "impl": impl, "owner": owner, "state": "running", "started": time.time(), "updated": time.time(),
               "progress": [], "leases": {}, "timing": {}, "cancel": False}
        with self.lock:
            self.jobs[job["id"]] = job
        th = threading.Thread(target=self._run, args=(job, proj, scns, impl, owner, opts, run),
                              name="scenario-" + job["id"], daemon=True)
        job["thread"] = th
        th.start()
        if wait:
            th.join()
        return self.public(job)

    def bg(self, title, owner, fn):
        """Фоновое задание (golden regen и т.п.): fn(job) -> результат; прогресс и состояние — как у прогона."""
        base = jid = "%s_%s" % (time.strftime("%Y%m%d_%H%M%S"), safe(title))
        n = 2
        while jid in self.jobs:
            jid, n = "%s_%d" % (base, n), n + 1
        job = {"id": jid, "kind": "bg", "title": title, "owner": owner, "state": "running", "started": time.time(),
               "updated": time.time(), "progress": [], "cancel": False}
        with self.lock:
            self.jobs[jid] = job

        def go():
            try:
                job["result"] = fn(job)
                job["state"] = "done" if (job["result"] or {}).get("ok", True) else "failed"
            except Exception as exc:
                job["state"] = "failed"
                job["error"] = "%s: %s" % (type(exc).__name__, exc)
                job["trace"] = traceback.format_exc(limit=8)
            job["finished"] = time.time()
        th = threading.Thread(target=go, name="bg-" + jid, daemon=True)
        job["thread"] = th
        th.start()
        return self.public(job)

    def public(self, job, tail=40):
        d = {k: v for k, v in job.items() if k not in ("thread", "progress")}
        d["progress"] = job["progress"][-tail:]
        return d

    def get(self, jid, tail=40):
        with self.lock:
            job = self.jobs.get(jid)
        return self.public(job, tail) if job else None

    def cancel(self, jid, owner=None):
        with self.lock:
            job = self.jobs.get(jid)
        if job is None:
            return None
        job["cancel"] = True
        return self.public(job)

    def list(self):
        with self.lock:
            return [self.public(j, 3) for j in self.jobs.values()]

    # ---- выполнение
    def _run(self, job, proj, scns, impl, owner, opts, run):
        if scns[0].kind == "vctest":
            return self._run_vctest(job, proj, scns, impl, owner, opts, run)
        sx = Session(self, job, proj, scns, impl, owner, opts)
        sx.run = run
        it = Interpreter(sx)
        t_all = time.time()
        report = {"harness": HARNESS, "project": proj.name, "impl": impl, "size": sx.size, "owner": owner,
                  "server_mode": "lockstep" if sx.lockstep else "realtime",
                  "scenarios": [s.describe() for s in scns], "timing": {}, "results": [], "ok": False}
        verdict = "failed"
        try:
            info = it.hook("info", scns[0], default={}) or {}
            report["info"] = info
            from vclab.quality import golden as G
            try:
                report["inputs"] = G.compute_key(self.lab, proj, scns[0], impl, info, lockstep=sx.lockstep)
            except Exception as exc:
                report["inputs"] = {"error": "%s: %s" % (type(exc).__name__, exc)}
            t0 = time.time()
            if "start" in it.hooks:
                it.hooks["start"](sx)
            else:
                kind = ((proj.scenario or {}).get("impls") or {}).get(impl) or impl
                sx.client = sx.lease(kind, role="client")
            if not sx.client:
                raise ScenarioError("start hook did not set sx.client")
            report["timing"]["start"] = round(time.time() - t0, 1)
            report["leases"] = dict(sx.leases)
            report["exe"] = run["meta"].get("exe")
            ok = True
            prefix_rep = {"steps": [], "shots": []}
            if scns[0].kind == "steps":
                t0 = time.time()
                ok = it.run_steps(scns[0].prefix, prefix_rep, sx.out_dir(scns[0]), scns[0])
                report["timing"]["prefix"] = round(time.time() - t0, 1)
            report["prefix"] = prefix_rep
            for s in scns:
                if not ok:
                    break
                sx.scn = s
                rep = {"scenario": s.name, "kind": s.kind, "size": s.size, "steps": [], "shots": [],
                       "out": os.path.relpath(sx.out_dir(s), run["dir"]), "clear": s.clear,
                       "regions": s.raw.get("regions"), "sha256": s.sha256, "chain": s.chain}
                self.progress(job, "--- %s (%s, %s)" % (s.name, s.kind, impl))
                t0 = time.time()
                first = len(s.prefix)
                if s.kind == "steps":
                    rep["ok"] = it.run_steps(s.body, rep, sx.out_dir(s), s, first=first)
                else:
                    setup = timeline_setup(s, it.hooks.get("timeline_setup"), sx,
                                           (proj.scenario or {}).get("timeline_mode"))
                    ts = time.time()
                    rep["ok"] = it.run_steps(setup, rep, sx.out_dir(s), s)
                    rep["timing_setup"] = round(time.time() - ts, 1)
                    if rep["ok"]:
                        st = sx.raw("state", {"radius": int(s.raw.get("state_radius", 8))})
                        rep["state0"] = st.get("result")
                        self.progress(job, "--- timeline %d ticks, %s, %d keyframes" % (
                            int(s.raw["ticks"]), "lockstep" if sx.lockstep else "pace %s ms" % s.raw.get(
                                "pace_ms", 50), len(s.keyframes)))
                        rep["ok"] = it.run_timeline(s, rep, sx.out_dir(s))
                rep["dur"] = round(time.time() - t0, 1)
                with open(os.path.join(sx.out_dir(s), "scenario.json"), "w", encoding="utf-8") as f:
                    json.dump(s.raw, f, ensure_ascii=False, indent=1)
                report["results"].append(rep)
                ok = ok and rep["ok"]
            fin = it.hook("finish", sx, default=None)
            if fin is not None:
                report["finish"] = fin
            report["ok"] = ok and len(report["results"]) == len(scns)
            verdict = "ok" if report["ok"] else ("cancelled" if job.get("cancel") else "failed")
        except Exception as exc:
            report["error"] = "%s: %s" % (type(exc).__name__, exc)
            report["trace"] = traceback.format_exc(limit=8)
            self.progress(job, "ERROR %s" % report["error"])
        finally:
            try:
                it.hook("stop", sx)
            except Exception as exc:
                report["stop_error"] = str(exc)
            if not opts.get("keep"):
                for role, name in list(sx.leases.items()):
                    try:
                        self.lab.release(name, owner=owner, reason="scenario-end")
                    except Exception as exc:
                        report.setdefault("release_errors", []).append("%s: %s" % (name, exc))
            else:
                report["kept_leases"] = dict(sx.leases)
            report["timing"]["total"] = round(time.time() - t_all, 1)
            if opts.get("golden") and report.get("results"):
                try:
                    from vclab.quality import compare as C
                    report["compare"] = C.compare_run_golden(self.lab, proj, run["dir"], report)
                except Exception as exc:
                    report["compare"] = {"error": "%s: %s" % (type(exc).__name__, exc),
                                         "trace": traceback.format_exc(limit=6)}
            job["report"] = {k: report.get(k) for k in ("ok", "error", "timing", "leases")}
            self.lab.close_run(run["id"], verdict=verdict, owner=owner, extra={"scenario": report})
            job["state"] = "done" if verdict == "ok" else verdict
            job["verdict"] = verdict
            job["finished"] = time.time()
            self.progress(job, "=== %s in %.0f s -> %s" % (verdict, time.time() - t_all, run["dir"]))


# ---------------------------------------------------------------------------------------------- vctest (этап 4)
VCTEST_DEFAULT = {"headless": "vctest", "window": "vctest_window"}
VCTEST_MARK = "[lab-vctest] script finished"
VCTEST_STEP = 20                      # кадров/тактов за один F2F step при часах virtual


def vctest_copy_marked(src, dst_dir):
    """Копия теста с маркером конца в последней строке (имя файла то же: чанк `script:<имя>` и номера строк в
    traceback не меняются). Нужна только под F2F: тестовая сборка 0.32 не выходит сама после конца `--test`-скрипта
    (стоковый Mainloop: `testMode && appScripts.isFinished() -> quit`; в f2f::run_loop этой проверки нет), поэтому
    раннер ждёт маркер и сам шлёт F2F `quit`. Необработанная ошибка теста по-прежнему = abort (0xC0000409)."""
    os.makedirs(dst_dir, exist_ok=True)
    with open(src, "rb") as f:
        data = f.read()
    dst = os.path.join(dst_dir, os.path.basename(src))
    with open(dst, "wb") as f:
        f.write(data.rstrip(b"\r\n") + b"\n;print(\"" + VCTEST_MARK.encode() + b"\")\n")
    return dst


def vctest_wait_f2f(lab, l, spec, timeout, clock, log_path):
    """Ожидание теста под F2F: часы virtual — раннер шагает кадры (VCTEST_STEP за вызов), realtime — время идёт само;
    маркер конца в stdout -> F2F quit (выход 0). -> {finished, marker, steps, frames, quit}."""
    from vclab.scenario.decode import read_tail
    t_end = time.time() + timeout
    out = {"clock": clock, "steps": 0, "frames": 0, "marker": False, "quit": False}
    while time.time() < t_end:
        if not l.proc.alive():
            out["finished"] = True
            return out
        try:
            lines = read_tail(log_path, 0) if os.path.isfile(log_path) else []
        except Exception:
            lines = []
        if any(VCTEST_MARK in x for x in lines[-200:]):
            out["marker"] = True
            try:
                lab._f2f_raw(l, spec, "quit", {}, timeout=10)
            except Exception:
                pass
            out["quit"] = True
            out["finished"] = bool(l.proc.wait(15))
            return out
        if clock == "virtual":
            try:
                rep = lab._f2f_raw(l, spec, "step", {"ticks": VCTEST_STEP, "frames": VCTEST_STEP}, timeout=60)
                if rep.get("ok"):
                    out["steps"] += 1
                    out["frames"] = (rep.get("result") or {}).get("frame", out["frames"])
                else:
                    # часы virtual: ошибка app/test-скрипта приходит ошибкой `step` (движок НЕ делает abort, как в
                    # realtime/стоке; корутина мертва, следующие шаги — «cannot resume dead coroutine») -> провал, quit
                    out["step_error"] = rep.get("error")
                    out["script_error"] = True
                    try:
                        lab._f2f_raw(l, spec, "quit", {}, timeout=10)
                    except Exception:
                        pass
                    out["quit"] = True
                    out["finished"] = bool(l.proc.wait(15))
                    return out
            except Exception as exc:                 # процесс умер посреди шага (abort ошибки теста)
                out["step_error"] = "%s: %s" % (type(exc).__name__, exc)
                time.sleep(0.05)
        else:
            time.sleep(0.1)
    out["finished"] = not l.proc.alive()
    return out


def vctest_one(svc, sx, scn, opts, log=None):
    """Один тест движка 0.32 (`--test <file>`) под арендой: вид [scenario].vctest проекта (headless — стоковый exe,
    окно — тестовая сборка F2F с часами realtime), ожидание выхода, код выхода, `--log`, снимки Canvas, сохранённые
    скриптом в user:shots/*.png -> shots\\<сценарий>\\. Результат ok — код выхода 0."""
    import glob
    import shutil
    from vclab.daemon.service import LabError
    lab = svc.lab
    raw = scn.raw
    window = bool(opts.get("window") if opts.get("window") is not None else raw.get("window", False))
    kinds = dict(VCTEST_DEFAULT, **((sx.project.scenario or {}).get("vctest") or {}))
    kind = kinds["window" if window else "headless"]
    if kind not in sx.project.kinds:
        raise ScenarioError("project %s has no kind %r for vctest (%s)" % (
            sx.project.name, kind, "window" if window else "headless"))
    params = dict(raw.get("params") or {})
    params["test"] = scn.test
    if opts.get("engine"):
        params["engine"] = opts["engine"]
    f2f_kind = bool(sx.project.kinds[kind].get("f2f"))
    clock = None
    if f2f_kind:
        # этап 4a: под F2F по умолчанию часы virtual — раннер шагает кадры (детерминированно, как headless --test,
        # где время идёт без сна); realtime — по запросу (`--clock realtime` / "clock" в JSON сценария)
        clock = str(opts.get("clock") or raw.get("clock") or params.get("clock") or "virtual")
        params["clock"] = clock
    timeout = float(raw.get("timeout") or opts.get("timeout") or 180)
    out_dir = sx.out_dir(scn)
    rep = {"scenario": scn.name, "kind": "vctest", "size": scn.size, "steps": [], "shots": [],
           "out": os.path.relpath(out_dir, sx.run["dir"]), "sha256": scn.sha256, "chain": scn.chain,
           "test": scn.test, "mode": "window" if window else "headless", "lease_kind": kind}
    t0 = time.time()
    name = None
    try:
        name = sx.lease(kind, role="vctest:" + scn.name, params=params, start=False)
        if f2f_kind:
            marked = vctest_copy_marked(scn.test, os.path.join(lab.leases[name].dir, "vctest"))
            rep["test_copy"] = marked
            try:
                st = lab.start(name, owner=sx.owner, params={"test": marked})
            except LabError as exc:
                # часы realtime: ошибка теста = abort движка, иногда раньше hello готовности -> это вердикт теста
                # (код выхода), а не сбой лаборатории
                l0 = lab.leases.get(name)
                if exc.code != "instance-dead" or l0 is None or l0.proc is None or l0.proc.alive():
                    raise
                rep["start_error"] = exc.message
                st = {"engine": l0.engine, "engine_version": l0.engine_version, "isolation": l0.isolation,
                      "pid": l0.proc.pid}
        else:
            st = lab.start(name, owner=sx.owner)
        rep["start"] = {k: st.get(k) for k in ("pid", "exe", "exe_sha256", "argv", "engine", "engine_version",
                                               "isolation", "timing")}
        rep["engine"], rep["engine_version"] = st.get("engine"), st.get("engine_version")
        l = lab.leases[name]
        if f2f_kind:
            spec_l = lab._spec(l)
            paths_l = lab._log_paths(l, spec_l, lab._ctx(l, spec_l, sx.project))
            w = vctest_wait_f2f(lab, l, spec_l, timeout, (l.isolation or {}).get("clock") or clock, paths_l["stdout"])
            rep["f2f"] = w
            finished = bool(w.get("finished"))
        else:
            finished = l.proc.wait(timeout)
        rep["timeout"] = not finished
        if not finished:
            l.job.terminate()
            l.proc.wait(5)
        for _ in range(40):                    # поток ожидания выставляет код выхода чуть позже смерти процесса
            if l.proc.exit_code is not None:
                break
            time.sleep(0.05)
        rep["exit_code"] = l.proc.exit_code
        rep["exit"] = l.proc.info().get("exit")
        rep["dur"] = round(time.time() - t0, 2)
        spec = lab._spec(l)
        paths = lab._log_paths(l, spec, lab._ctx(l, spec, sx.project))
        logs = {}
        for stream, pth in paths.items():
            if os.path.isfile(pth) and os.path.getsize(pth) > 0:
                dst = os.path.join(out_dir, "%s.log" % stream)
                shutil.copyfile(pth, dst)
                from vclab.scenario.decode import read_tail
                lines = read_tail(pth, 0)
                logs[stream] = {"file": os.path.relpath(dst, sx.run["dir"]), "lines": len(lines)}
                errs = [x for x in lines if "[E]" in x or (not x.startswith(("[I]", "[W]", "[D]")) and re.search(
                    r"error|traceback|assert|terminating", x, re.I))]
                if errs:
                    logs[stream]["errors"] = errs[:15]          # сначала сообщение, потом traceback
                logs[stream]["tail"] = lines[-8:]
        rep["logs"] = logs
        for png in sorted(glob.glob(os.path.join(l.dir, "shots", "*.png"))):
            dst = os.path.join(out_dir, os.path.basename(png))
            shutil.copyfile(png, dst)
            from vclab.quality.compare import rgb_sha
            w = h = None
            try:
                import struct
                with open(dst, "rb") as f:
                    head = f.read(24)
                w, h = struct.unpack(">II", head[16:24])
            except Exception:
                pass
            rep["shots"].append({"scenario": scn.name, "name": os.path.splitext(os.path.basename(png))[0],
                                 "file": os.path.relpath(dst, sx.run["dir"]), "sha256": sha256_file(dst),
                                 "sha256_rgb": rgb_sha(dst), "file_sha256": sha256_file(dst), "w": w, "h": h})
        rep["ok"] = (not rep["timeout"]) and rep["exit_code"] == 0
        if f2f_kind and (rep.get("f2f") or {}).get("script_error"):
            rep["ok"] = False
            rep["error"] = "test script error (F2F step): %s" % str(rep["f2f"].get("step_error") or "").split("\n")[0][:300]
        elif f2f_kind and rep["ok"] and not (rep.get("f2f") or {}).get("marker"):
            rep["ok"] = False                      # вышел сам без маркера: скрипт не дошёл до конца (app.quit?)
            rep["error"] = "exit 0 without the end marker (the test did not reach its last line)"
        if not rep["ok"] and not rep.get("error"):
            rep["error"] = "timeout %.0f s" % timeout if rep["timeout"] else "exit %s" % rep["exit"]
    except Exception as exc:
        rep["ok"] = False
        rep["error"] = "%s: %s" % (type(exc).__name__, exc)
        rep["trace"] = traceback.format_exc(limit=6)
    if log:
        fx = rep.get("f2f") or {}
        log("vctest %s [%s, %s%s] -> %s, exit %s, %s s, %d shots%s" % (
            scn.name, rep.get("engine_version"), rep["mode"], ", clock %s" % fx.get("clock") if fx else "",
            "ok" if rep["ok"] else "FAILED (%s)" % rep.get("error"),
            rep.get("exit_code"), rep.get("dur"), len(rep["shots"]),
            ", %d steps / %s frames, marker %s, quit %s" % (fx.get("steps", 0), fx.get("frames"), fx.get("marker"),
                                                           fx.get("quit")) if fx else ""))
    return rep, name


def _run_vctest(self, job, proj, scns, impl, owner, opts, run):
    sx = Session(self, job, proj, scns, impl, owner, opts)
    sx.run = run
    t_all = time.time()
    report = {"harness": HARNESS, "project": proj.name, "impl": impl, "kind": "vctest", "size": sx.size,
              "owner": owner, "scenarios": [s.describe() for s in scns], "timing": {}, "results": [], "ok": False}
    verdict = "failed"
    try:
        for s in scns:
            if job.get("cancel"):
                break
            sx.scn = s
            self.progress(job, "--- %s (vctest %s)" % (s.name, s.test))
            rep, name = vctest_one(self, sx, s, opts, log=lambda line: self.progress(job, line))
            report["results"].append(rep)
            if name and not opts.get("keep"):
                try:
                    self.lab.release(name, owner=owner, reason="scenario-end")
                except Exception as exc:
                    report.setdefault("release_errors", []).append("%s: %s" % (name, exc))
                sx.leases = {k: v for k, v in sx.leases.items() if v != name}
        vers = sorted({r.get("engine_version") for r in report["results"] if r.get("engine_version")})
        report["engine_version"] = ",".join(vers) or None
        report["ok"] = bool(report["results"]) and all(r.get("ok") for r in report["results"]) and \
            len(report["results"]) == len(scns)
        verdict = "ok" if report["ok"] else ("cancelled" if job.get("cancel") else "failed")
    except Exception as exc:
        report["error"] = "%s: %s" % (type(exc).__name__, exc)
        report["trace"] = traceback.format_exc(limit=8)
        self.progress(job, "ERROR %s" % report["error"])
    finally:
        if opts.get("keep"):
            report["kept_leases"] = dict(sx.leases)
        else:
            for role, name in list(sx.leases.items()):
                try:
                    self.lab.release(name, owner=owner, reason="scenario-end")
                except Exception:
                    pass
        report["leases"] = dict(sx.leases)
        report["exe"] = run["meta"].get("exe")
        report["timing"]["total"] = round(time.time() - t_all, 1)
        job["report"] = {k: report.get(k) for k in ("ok", "error", "timing", "leases", "engine_version")}
        self.lab.close_run(run["id"], verdict=verdict, owner=owner, extra={"scenario": report})
        job["state"] = "done" if verdict == "ok" else verdict
        job["verdict"] = verdict
        job["finished"] = time.time()
        self.progress(job, "=== %s in %.0f s -> %s" % (verdict, time.time() - t_all, run["dir"]))


ScenarioService._run_vctest = _run_vctest
