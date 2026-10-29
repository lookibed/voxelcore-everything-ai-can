"""`lab perf <project> <scenario>` (этап 3а): замер производительности только на простаивающем ПК — софтом.

Правило пользователя: замеры действительны только на свободном ПК. Ядро:
  1. ждёт простоя: `idle_window_s` (30) секунд подряд все снимки sysload «свободны», не дольше `wait_idle_s` (600);
     не дождались — отказ (`--allow-contended` — замер идёт, но прогон сразу помечен contended);
  2. открывает прогон `<runs_dir>\\<время>_<проект>_<сценарий>_<tag>`, зовёт перф-сценарий проекта
     (`api.perf(name, fn)` в plugin.py) — тот берёт аренды движка с `clock = "realtime"` (тестовая сборка, ввод
     изолирован) и пишет perf_summary.json;
  3. всё время прогона снимает загрузку (те же признаки простоя); хоть один занятый снимок (доля >
     `contended_share`, по умолчанию 0) — прогон `contended`; `host_load` (снимки, причины, пороги, ожидание) — в
     perf_summary.json и report.json; история (kind perf) и ворота contended-прогоны не сравнивают.

«Простой» (idle_reasons): нет чужих процессов движка/Java (не аренды этого замера), CPU посторонних < `others_cpu_pct`,
GPU < `gpu_busy_pct` (до старта своих экземпляров: потом GPU грузим мы), ввод пользователя не моложе `user_idle_s`,
нет других активных работ лаборатории (аренды с живым процессом, задания `lab run`, сеансы `lab play`).
"""
import json
import os
import threading
import time
import traceback

from vclab.quality import sysload

DEFAULTS = {"idle_window_s": 30.0, "wait_idle_s": 600.0, "user_idle_s": 120.0, "others_cpu_pct": 15.0,
            "gpu_busy_pct": 15.0, "sample_every_s": 2.0, "sample_window_s": 1.0, "contended_share": 0.0}


def thresholds(cfg=None, over=None):
    th = dict(DEFAULTS)
    for k, v in (cfg or {}).items():
        if k in th:
            th[k] = float(v)
    for k, v in (over or {}).items():
        if v is not None and k in th:
            th[k] = float(v)
    return th


def idle_reasons(s, th, lab_busy=(), gpu_counts=True):
    """Снимок sysload -> список причин «не простой» (пусто = простой)."""
    out = []
    fe = s.get("foreign_engines") or []
    if fe:
        out.append("foreign engine/java processes: %s" % ", ".join(
            "%s(%s)" % (x.get("name"), x.get("pid")) for x in fe[:6]))
    oc = s.get("cpu_others_pct")
    if oc is not None and oc >= th["others_cpu_pct"]:
        top = ", ".join("%s %.0f%%" % (t["name"], t["cpu_pct"]) for t in (s.get("top") or [])[:3])
        out.append("other processes %.1f%% CPU >= %.0f%% (%s)" % (oc, th["others_cpu_pct"], top))
    g = s.get("gpu") or []
    if gpu_counts and g:
        u = max(x["util_pct"] for x in g)
        if u >= th["gpu_busy_pct"]:
            out.append("GPU busy %.0f%% >= %.0f%%" % (u, th["gpu_busy_pct"]))
    idle = s.get("user_idle_s")
    if idle is None:
        out.append("user input idle unknown (GetLastInputInfo)")
    elif idle < th["user_idle_s"]:
        out.append("user input %.0f s ago < %.0f s" % (idle, th["user_idle_s"]))
    out += list(lab_busy or ())
    return out


def lab_activity(lab, exclude_leases=(), exclude_jobs=()):
    """Другие активные работы лаборатории (аренда с живым процессом, задание, сеанс play) -> [причины]."""
    out = []
    ex = set(exclude_leases or ())
    with lab.lock:
        ls = list(lab.leases.values())
    for l in ls:
        if l.name in ex:
            continue
        if l.proc is not None and l.proc.alive():
            out.append("lab lease %s (%s, owner %s) is running" % (l.name, l.state, l.owner))
    try:
        for j in lab.scen.list():
            if j.get("state") == "running" and j.get("id") not in set(exclude_jobs or ()):
                out.append("lab job %s (%s) is running" % (j.get("id"), j.get("owner")))
    except Exception:
        pass
    play = getattr(lab, "play", None)
    if play is not None:
        try:
            for s in play.list():
                if s.get("state") in ("starting", "running", "finishing"):
                    out.append("lab play session %s is %s" % (s.get("id"), s.get("state")))
        except Exception:
            pass
    return out


def wait_idle(sample_fn, busy_fn, th, progress=None, cancelled=None, clock=time.time, sleep=time.sleep):
    """Ждать `idle_window_s` секунд подряд без причин занятости, не дольше `wait_idle_s`.
    sample_fn() -> снимок sysload; busy_fn() -> причины лаборатории. -> {idle, waited_s, samples, reasons, streak_s}."""
    t0 = clock()
    streak_start = None
    samples = []
    last_reasons = []
    last_print = 0.0
    while True:
        if cancelled and cancelled():
            return {"idle": False, "cancelled": True, "waited_s": round(clock() - t0, 1), "samples": samples[-60:],
                    "reasons": ["cancelled"]}
        s = sample_fn()
        reasons = idle_reasons(s, th, busy_fn())
        now = clock()
        samples.append(_compact(s, reasons))
        if reasons:
            streak_start = None
            last_reasons = reasons
        elif streak_start is None:
            streak_start = now - th["sample_window_s"]
        streak = (now - streak_start) if streak_start is not None else 0.0
        if progress and (now - last_print >= 15 or (not reasons and streak >= th["idle_window_s"])):
            last_print = now
            progress("idle %.0f/%.0f s" % (streak, th["idle_window_s"]) if not reasons else
                     "busy (%.0f s waited): %s" % (now - t0, "; ".join(reasons)))
        if streak >= th["idle_window_s"]:
            return {"idle": True, "waited_s": round(now - t0, 1), "streak_s": round(streak, 1),
                    "samples": samples[-60:], "reasons": []}
        if now - t0 >= th["wait_idle_s"]:
            return {"idle": False, "waited_s": round(now - t0, 1), "streak_s": round(streak, 1),
                    "samples": samples[-60:], "reasons": last_reasons}
        sleep(max(0.0, th["sample_every_s"] - th["sample_window_s"]))


def _compact(s, reasons):
    g = s.get("gpu") or []
    return {"t": s.get("t"), "cpu_total": s.get("cpu_total_pct"), "cpu_others": s.get("cpu_others_pct"),
            "gpu": max((x["util_pct"] for x in g), default=None), "user_idle_s": s.get("user_idle_s"),
            "foreign": len(s.get("foreign_engines") or []), "busy": bool(reasons), "reasons": reasons[:4]}


class RunMonitor:
    """Снимки загрузки во время замера (поток). own_fn() -> pid своих экземпляров (их CPU/процессы не считаются);
    GPU учитывается, пока своих процессов нет."""

    def __init__(self, sample_fn, busy_fn, th):
        self.sample_fn, self.busy_fn, self.th = sample_fn, busy_fn, th
        self.samples = []
        self._stop = threading.Event()
        self._t = None

    def _loop(self):
        while not self._stop.is_set():
            try:
                s, gpu_counts = self.sample_fn()
                reasons = idle_reasons(s, self.th, self.busy_fn(), gpu_counts=gpu_counts)
                self.samples.append(_compact(s, reasons))
            except Exception as exc:
                self.samples.append({"t": time.time(), "busy": None, "reasons": ["sample failed: %s" % exc]})
            self._stop.wait(max(0.0, self.th["sample_every_s"] - self.th["sample_window_s"]))

    def start(self):
        self._t = threading.Thread(target=self._loop, name="perf-load", daemon=True)
        self._t.start()
        return self

    def stop(self):
        self._stop.set()
        if self._t:
            self._t.join(self.th["sample_window_s"] + 10)
        return summarize(self.samples, self.th)


def summarize(samples, th, pre=None, forced=False):
    known = [s for s in samples if s.get("busy") is not None]
    busy = [s for s in known if s["busy"]]
    reasons = []
    for s in busy:
        for r in s.get("reasons") or []:
            key = r.split(":")[0].split(" (")[0]
            if key not in [x.split(":")[0].split(" (")[0] for x in reasons]:
                reasons.append(r)
    share = (len(busy) / len(known)) if known else None
    contended = None if share is None else share > th["contended_share"]
    if forced:
        contended = True
        reasons = ["not idle before the run (--allow-contended): %s" % "; ".join((pre or {}).get("reasons") or [])] \
            + reasons
    return {"contended": contended, "busy_share": None if share is None else round(share, 3), "n": len(known),
            "reasons": reasons[:8], "thresholds": th, "samples": samples[-400:],
            "idle_before": {k: v for k, v in (pre or {}).items() if k != "samples"} if pre else None,
            "definition": "vclab/quality/perf.py idle_reasons"}


class PerfX:
    """То, что видит перф-сценарий проекта (fn(px, args))."""

    def __init__(self, svc, job, proj, scenario, owner, run, args):
        self.svc, self.lab, self.job, self.proj = svc, svc.lab, job, proj
        self.scenario, self.owner, self.run, self.args = scenario, owner, run, args
        self.out_dir = run["dir"]
        self.leases = []
        from vclab.daemon.service import FeatureCtx
        from vclab.projects import Feature
        self.ctx = FeatureCtx(self.lab, Feature("perf." + scenario, None, project=proj.name), owner)

    def progress(self, line):
        self.svc.lab.scen.progress(self.job, line)

    def cancelled(self):
        return bool(self.job.get("cancel"))

    def lease(self, kind, params=None, clock="realtime", start=True, ttl=None):
        """Аренда в прогоне замера; движок — тестовая сборка с часами `clock` (по умолчанию realtime)."""
        p = dict(params or {})
        spec = self.proj.kinds.get(kind) or {}
        from vclab import policy
        if policy.is_engine_exe(str(spec.get("exe") or "")) or spec.get("f2f"):
            p.setdefault("clock", clock)
        r = self.lab.create_lease(self.proj.name, kind, self.owner, ttl=ttl or 3600, params=p)
        name = r["lease"]["name"]
        self.leases.append(name)
        self.lab.attach_run(name, self.run["id"], owner=self.owner)
        if start:
            self.lab.start(name, owner=self.owner)
        return name

    def own_pids(self):
        out = set()
        for n in self.leases:
            l = self.lab.leases.get(n)
            if l is None:
                continue
            if l.proc and l.proc.pid:
                out.add(l.proc.pid)
            if l.job is not None:
                try:
                    out.update(l.job.pids())
                except Exception:
                    pass
        return out

    def f2f(self, lease, cmd, args=None, timeout=60):
        return self.lab.f2f(lease, cmd, args or {}, timeout=timeout, owner=self.owner)

    def release_all(self):
        for n in reversed(self.leases):
            if n in self.lab.leases:
                try:
                    self.lab.release(n, owner=self.owner, force=True, reason="perf-end")
                except Exception:
                    pass


class PerfService:
    def __init__(self, lab):
        self.lab = lab

    def th(self, over=None):
        return thresholds(self.lab.cfg.get("perf") or {}, over)

    def start(self, project, scenario, owner, args=None, wait_idle_s=None, idle_window_s=None, allow_contended=False,
              sample_fn=None):
        proj = self.lab.projects.get(project)
        runner = proj.perf_runners.get(scenario)
        if runner is None:
            raise KeyError("project %s has no perf scenario %r (have: %s; plugin.py api.perf)" % (
                project, scenario, ", ".join(sorted(proj.perf_runners)) or "none"))
        th = self.th({"wait_idle_s": wait_idle_s, "idle_window_s": idle_window_s})
        args = dict(args or {})
        title = "perf_%s_%s" % (project, scenario)
        return self.lab.scen.bg(title, owner, lambda job: self._run(job, proj, scenario, runner, owner, args, th,
                                                                     allow_contended, sample_fn))

    def _run(self, job, proj, scenario, runner, owner, args, th, allow_contended, sample_fn=None):
        lab = self.lab
        progress = (lambda line: lab.scen.progress(job, line))
        job["perf"] = {"project": proj.name, "scenario": scenario, "thresholds": th}
        # свои — только аренды этого замера: движки других аренд и агентов — чужие (и причина «lab lease ... running»)
        sample = sample_fn or (lambda own=(): sysload.sample(th["sample_window_s"], own_pids=set(own)))
        progress("waiting for an idle PC: %.0f s in a row, at most %.0f s (thresholds %s)" % (
            th["idle_window_s"], th["wait_idle_s"], json.dumps({k: th[k] for k in (
                "user_idle_s", "others_cpu_pct", "gpu_busy_pct")})))
        pre = wait_idle(lambda: sample(), lambda: lab_activity(lab, exclude_jobs=(job["id"],)), th, progress,
                        lambda: bool(job.get("cancel")))
        job["perf"]["idle_before"] = {k: v for k, v in pre.items() if k != "samples"}
        if not pre["idle"] and (pre.get("cancelled") or not allow_contended):
            progress("REFUSED: PC not idle after %.0f s: %s" % (pre["waited_s"], "; ".join(pre["reasons"])))
            lab.journal.event("lab.perf_refused", "%s/%s: %s" % (proj.name, scenario, "; ".join(pre["reasons"])),
                              agent=owner, error=True)
            return {"ok": False, "refused": "not-idle", "waited_s": pre["waited_s"], "reasons": pre["reasons"]}
        tag = str(args.get("tag") or "run")
        run = lab.open_run(proj.name, "%s_%s" % (scenario, tag), owner=owner,
                           meta={"perf": {"scenario": scenario, "tag": tag, "args": args, "idle_before": pre}})["run"]
        job["run"], job["dir"] = run["id"], run["dir"]
        px = PerfX(self, job, proj, scenario, owner, run, args)
        mon = RunMonitor(lambda: (sample(px.own_pids()), not px.own_pids()),
                         lambda: lab_activity(lab, exclude_leases=px.leases, exclude_jobs=(job["id"],)), th).start()
        res, err = None, None
        t0 = time.time()
        try:
            res = runner["fn"](px, args) or {}
        except Exception as exc:
            err = "%s: %s" % (type(exc).__name__, exc)
            job["trace"] = traceback.format_exc(limit=8)
            progress("perf scenario failed: " + err)
        finally:
            load = summarize(mon.stop().get("samples") or [], th, pre, forced=not pre["idle"])
            px.release_all()
        load["run_s"] = round(time.time() - t0, 1)
        ok = err is None and bool(res.get("ok", True))
        sj = (res or {}).get("summary_json") or os.path.join(run["dir"], "perf_summary.json")
        if os.path.isfile(sj):
            try:
                with open(sj, encoding="utf-8") as f:
                    d = json.load(f)
                d["host_load"] = load
                d.setdefault("meta", {}).update({"scenario": scenario, "tag": tag, "lab_run": run["id"],
                                                 "clock": "realtime", "owner": owner})
                with open(sj, "w", encoding="utf-8") as f:
                    json.dump(d, f, ensure_ascii=False, indent=1, default=str)
            except Exception as exc:
                progress("host_load not written to %s: %s" % (sj, exc))
        verdict = ("contended" if load.get("contended") else "ok") if ok else "failed"
        progress("host load: %s (busy share %s of %d samples)%s" % (
            "CONTENDED" if load.get("contended") else "clean", load.get("busy_share"), load.get("n"),
            ": " + "; ".join(load.get("reasons") or []) if load.get("contended") else ""))
        lab.close_run(run["id"], verdict, owner=owner, extra={"perf": {"result": _short(res), "error": err,
                                                                       "host_load": {k: v for k, v in load.items()
                                                                                     if k != "samples"}}})
        progress("=== %s -> %s" % (verdict, run["dir"]))
        return {"ok": ok, "verdict": verdict, "contended": load.get("contended"), "run": run["id"],
                "dir": run["dir"], "result": _short(res), "error": err,
                "host_load": {k: v for k, v in load.items() if k != "samples"}}


def _short(res):
    if not isinstance(res, dict):
        return res
    return {k: v for k, v in res.items() if k not in ("md", "rows")}
