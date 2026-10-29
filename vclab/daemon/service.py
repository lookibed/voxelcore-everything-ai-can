"""Lab — сервис демона: аренды экземпляров, процессы в Job Object, порты, F2F-пул, журнал, прогоны, плагины.

Аренда (lease) = один экземпляр одного вида (kind) проекта: имя, владелец, порты из пула, каталог data\\inst\\<имя>,
Job Object, процесс(ы), TTL. Чужую аренду менять нельзя (not-owner), кроме force (правило «стоп = убить всё»).
Состояние аренд — data\\state\\leases.json: рестарт демона восстанавливает аренды и порты, а процессы признаёт своими
только при совпадении pid + create_time (KILL_ON_JOB_CLOSE обычно уже убил их вместе со старым демоном)."""
import contextlib
import hashlib
import json
import os
import shutil
import threading
import time
import traceback

from vclab import VERSION
from vclab import config
from vclab import policy
from vclab.leases import procs
from vclab.scenario.decode import read_tail
from vclab.f2f import F2FPool
from vclab.scenario.journal import Journal
from vclab.leases.logwatch import LogMirror
from vclab.leases.ports import PortPool
from vclab.projects import Feature, Projects, expand, prepare
from vclab.scenario.runs import Runs
from vclab.scenario.scenario import ScenarioError, ScenarioService


@contextlib.contextmanager
def _nojournal():
    yield {"result": None}


def _flat(seq):
    """Аргументы: элемент-список (подстановка «{param.extra}» целиком) раскрывается на месте."""
    out = []
    for a in seq:
        if isinstance(a, (list, tuple)):
            out.extend(_flat(a))
        elif a is not None:
            out.append(a)
    return out


class LabError(Exception):
    STATUS = {"not-found": 404, "not-owner": 403, "bad-request": 400, "busy": 409, "not-running": 409,
              "instance-dead": 409, "f2f-timeout": 504, "f2f-unreachable": 502, "start-failed": 500,
              "feature-error": 500, "policy": 403, "isolation-failed": 500, "no-stdin": 409,
              "engine-mismatch": 500, "admin-required": 403, "foreign-leases": 409, "live-leases": 409,
              "draining": 503}

    def __init__(self, code, message, **extra):
        super().__init__(message)
        self.code, self.message, self.extra = code, message, extra
        self.status = self.STATUS.get(code, 400)

    def body(self):
        return {"ok": False, "error": self.code, "message": self.message, **self.extra}


class Lease:
    FIELDS = ("name", "project", "kind", "owner", "ttl", "created", "expires", "ports", "dir", "params", "state",
              "error", "run", "auto_run", "junctions", "starts", "last_action", "procs_hist", "ready_info",
              "mode", "reason", "isolation", "engine", "engine_version")

    def __init__(self, **kw):
        self.name = kw["name"]
        self.project = kw["project"]
        self.kind = kw["kind"]
        self.owner = kw.get("owner")
        self.ttl = kw.get("ttl", 900)
        self.created = kw.get("created", time.time())
        self.expires = kw.get("expires", self.created + self.ttl)
        self.ports = kw.get("ports", {})
        self.dir = kw["dir"]
        self.params = kw.get("params", {})
        self.state = kw.get("state", "leased")
        self.error = kw.get("error")
        self.run = kw.get("run")
        self.auto_run = kw.get("auto_run", False)
        self.junctions = kw.get("junctions", [])
        self.starts = kw.get("starts", 0)
        self.last_action = kw.get("last_action")
        self.procs_hist = kw.get("procs_hist", [])
        self.ready_info = kw.get("ready_info")
        self.mode = kw.get("mode")              # None (тест) | play | final-check (только role=runtime)
        self.reason = kw.get("reason")
        self.isolation = kw.get("isolation")    # {clock, window, argv, verified, flags} последнего старта
        self.engine = kw.get("engine")          # этап 4: id движка ([engines.<id>]) и его версия ("0.31", "0.32")
        self.engine_version = kw.get("engine_version")
        self.stdin_poked = False
        self.proc = None
        self.job = None
        self.lock = threading.RLock()
        self.stopping = False

    def to_dict(self, live=False):
        d = {k: getattr(self, k) for k in self.FIELDS}
        d["proc"] = self.proc.info() if self.proc else None
        if live:
            d["expires_in"] = round(self.expires - time.time(), 1)
            d["job_pids"] = self.job.pids() if self.job else []
        return d


class FeatureCtx:
    """То, что видит функция плагина: вызовы идут через сервис (журнал, владелец, аренды)."""

    def __init__(self, lab, feature, owner, via=None):
        self.lab, self.feature, self.owner, self.via = lab, feature, owner, via
        self.project = lab.projects.get(feature.project) if feature.project and feature.project != "core" else None

    def f2f(self, lease, cmd, args=None, timeout=60.0):
        return self.lab.f2f(lease, cmd, args or {}, timeout=timeout, owner=self.owner)

    def call(self, lease, cmd, args=None, timeout=60.0):
        """Как f2f, но возвращает result и бросает при ok:false."""
        rep = self.f2f(lease, cmd, args, timeout)
        if not rep.get("ok"):
            raise LabError("f2f-error", "%s: %s (%s)" % (cmd, rep.get("error"), rep.get("where")), reply=rep)
        return rep.get("result")

    def lease(self, kind, project=None, params=None, ttl=None, name=None, start=False):
        return self.lab.create_lease(project or self.feature.project, kind, self.owner, ttl=ttl, name=name,
                                     params=params, start=start)

    def start(self, lease, **kw):
        return self.lab.start(lease, owner=self.owner, **kw)

    def stop(self, lease):
        return self.lab.stop(lease, owner=self.owner)

    def release(self, lease):
        return self.lab.release(lease, owner=self.owner)

    def info(self, lease):
        return self.lab.lease_info(lease)

    def log_tail(self, lease, stream=None, lines=60, grep=None):
        return self.lab.logs(lease, stream=stream, tail=lines, grep=grep)["lines"]

    def run_dir(self, lease):
        return self.lab.run_dir_of(self.lab._get(lease))


class Lab:
    def __init__(self, cfg=None, watch=True, background=True):
        self.cfg = cfg or config.load()
        self.data = self.cfg["daemon"]["data"]
        for sub in ("state", "inst", "builds", "journal", "logs", "runs"):
            os.makedirs(os.path.join(self.data, sub), exist_ok=True)
        self.started = time.time()
        self.journal = Journal(os.path.join(self.data, "journal", "journal.jsonl"))
        self.runs = Runs(self.data)
        self.pool = F2FPool()
        self.ports = PortPool(self.cfg["ports"]["first"], self.cfg["ports"]["last"])
        self.leases = {}
        self.lock = threading.RLock()
        self._exe_cache = {}
        self.state_path = os.path.join(self.data, "state", "leases.json")
        self.projects = Projects(self.cfg["project_dirs"], on_event=self._project_event)
        self._sync_stock()
        self._core_features()
        aborted = self.runs.abort_open("aborted: daemon restart")
        if aborted:
            self.journal.event("lab.runs_aborted", ", ".join(aborted))
        self._load_state()
        self.scen = ScenarioService(self)
        from vclab.quality.golden import Golden
        self.golden = Golden(self)
        self.mirrors = []
        if watch:
            for name, path in self.cfg.get("watch", {}).items():
                self.mirrors.append(LogMirror(name, path, self.data, on_new=self._mirror_new).start())
        self._stop = False
        self.watchdog = policy.Watchdog(self.own_pids, on_new=self._foreign_new,
                                        every=float((self.cfg.get("watchdog") or {}).get("every", 5.0)))
        if self.cfg["daemon"].get("isolated"):
            self.watchdog.disabled = True       # чужие для изолированного демона — аренды общего: не «foreign»
        from vclab.daemon.admin import DaemonControl         # этап 5: роли, drain, аудит, версия кода
        self.ctl = DaemonControl(self)
        if background:
            threading.Thread(target=self._reaper, name="reaper", daemon=True).start()
            threading.Thread(target=self._reloader, name="reloader", daemon=True).start()
            if (self.cfg.get("watchdog") or {}).get("enabled", True):
                threading.Thread(target=self._watch_procs, name="watchdog", daemon=True).start()

    # ------------------------------------------------------------------ служебное
    def _project_event(self, what, name, detail=None):
        try:
            self.journal.event("lab." + what, (detail or "")[-300:] if isinstance(detail, str) else detail,
                               plugin=None, args={"project": name}, error=what.endswith("failed"))
        except Exception:
            pass

    def _mirror_new(self, name, archive, first):
        self.journal.event("lab.log_mirror", "new %s session -> %s" % (name, archive), args={"watch": name})

    def _reaper(self):
        every = float(self.cfg["leases"]["reap_every"])
        while not self._stop:
            time.sleep(every)
            now = time.time()
            with self.lock:
                expired = [l for l in self.leases.values() if l.expires < now]
            for l in expired:
                try:
                    self.journal.event("lab.lease_expired", "ttl %s s, owner %s" % (l.ttl, l.owner),
                                       instance=l.name, agent=l.owner, run=l.run, run_dir=self._run_dir_id(l.run))
                    self.release(l.name, force=True, reason="expired")
                except Exception:
                    pass

    def own_pids(self):
        """pid всех процессов аренд (дерево Job) — свои для сторожа и для sysload."""
        out = set()
        with self.lock:
            ls = list(self.leases.values())
        for l in ls:
            if l.proc and l.proc.pid:
                out.add(l.proc.pid)
            if l.job is not None:
                try:
                    out.update(l.job.pids())
                except Exception:
                    pass
        return out

    def _foreign_new(self, p):
        self.journal.event("lab.foreign_process", "%s pid %s%s: %s" % (
            p.get("name"), p.get("pid"), " (STOCK runtime)" if p.get("stock") else "", p.get("cmdline")),
            error=True, args={"pid": p.get("pid"), "exe": p.get("exe"), "stock": p.get("stock"), "f2f": p.get("f2f")})

    def _watch_procs(self):
        while not self._stop:
            self.watchdog.tick()
            self._watch_headless()
            time.sleep(self.watchdog.every)

    def _reloader(self):
        while not self._stop:
            time.sleep(1.0)
            try:
                if self.projects.scan():
                    self._sync_stock()
            except Exception:
                pass

    def shutdown(self):
        self._stop = True
        for m in self.mirrors:
            m.stop()

    def health(self):
        ctl = getattr(self, "ctl", None)
        return {"ok": True, "service": "labd", "version": VERSION, "pid": os.getpid(), "started": self.started,
                "isolated": bool(self.cfg["daemon"].get("isolated")), "starter": self.cfg["daemon"].get("starter"),
                "state": ctl.state if ctl else None, "code_hash": ctl.summary()["code_hash"] if ctl else None,
                "uptime_s": round(time.time() - self.started, 1), "generation": self.projects.generation,
                "leases": len(self.leases), "data": self.data, "vc_root": config.VC_ROOT,
                "port": self.cfg["daemon"]["port"], "ports": [self.ports.first, self.ports.last],
                "projects": sorted(self.projects.projects), "watch": [m.info() for m in self.mirrors]}

    def base_ctx(self):
        # machine.<ключ> — корни машины (machine.toml), work_root/repo_root — новые подстановки репозитория
        return {"vc_root": config.VC_ROOT, "lab_dir": config.LAB_DIR, "lab_data": self.data,
                "python": self.python_exe(), "work_root": config.WORK_ROOT, "repo_root": config.REPO_ROOT,
                "machine": config.machine_ctx()}

    @staticmethod
    def python_exe():
        """python.exe демона (pythonw.exe -> python.exe рядом: вывод в файлы, окна нет — CREATE_NO_WINDOW)."""
        import sys
        exe = sys.executable
        cand = os.path.join(os.path.dirname(exe), "python.exe")
        return cand if os.path.basename(exe).lower() == "pythonw.exe" and os.path.exists(cand) else exe

    # ------------------------------------------------------------------ движки (этап 4: версия — измерение)
    def engines(self, proj=None):
        """{id: описание} — [engines.*] lab.toml, поверх — проекта; подстановки {vc_root} и т.п. раскрыты."""
        base = self.base_ctx()
        if proj is not None:
            base["project_dir"] = proj.dir
        out = {}
        for k, v in (self.cfg.get("engines") or {}).items():
            if isinstance(v, dict):
                out[k] = dict(v)
        if proj is not None:
            for k, v in proj.engines.items():
                out[k] = dict(out.get(k, {}), **v)
        res = {}
        for k, v in out.items():
            e = expand(v, base)
            e["id"] = k
            e.setdefault("version", k)
            e.setdefault("builds", {})
            res[k] = e
        return res

    def default_engine(self, proj=None):
        if proj is not None and proj.default_engine:
            return proj.default_engine
        d = (self.cfg.get("engines") or {}).get("default")
        return d if isinstance(d, str) else "v031"

    def engine_of(self, proj, spec, params=None):
        """(id, описание) движка аренды: параметр аренды engine -> engine вида -> умолчание проекта/lab.toml."""
        eid = (params or {}).get("engine") or spec.get("engine") or self.default_engine(proj)
        if eid == "none":                     # не движок (шлюз, песочница, Java-сервер): версии нет
            return None, {"id": None, "version": None, "builds": {}}
        engs = self.engines(proj)
        if eid not in engs:
            if not engs and eid == self.default_engine(proj):
                return eid, {"id": eid, "version": eid, "builds": {}}
            raise LabError("bad-request", "unknown engine %r (have: %s)" % (eid, ", ".join(sorted(engs)) or "none"))
        return eid, engs[eid]

    def _engine_hello_path(self):
        return os.path.join(self.data, "state", "engine_hello.json")

    def _note_engine_hello(self, l, hello):
        """Последний hello каждой сборки (по sha256 exe аренды) -> state\\engine_hello.json: `lab engines` показывает
        версию, коммит и флаги без отдельного запуска движка."""
        try:
            if not hello or not l.run:
                return
            run = self.runs.active.get(l.run) or {}
            ex = ((run.get("meta") or {}).get("exe") or {}).get(l.name) or {}
            sha = ex.get("sha256")
            if not sha:
                return
            path = self._engine_hello_path()
            try:
                with open(path, encoding="utf-8") as f:
                    data = json.load(f)
            except (OSError, ValueError):
                data = {}
            data[sha] = {"version": hello.get("version"), "impl": hello.get("impl"), "flags": hello.get("flags"),
                         "build": (hello.get("build") or {}).get("commit"),
                         "gl": (hello.get("gl") or {}).get("renderer"), "src": ex.get("src"), "lease": l.name,
                         "engine": l.engine, "t": time.time()}
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
            os.replace(tmp, path)
        except Exception:
            pass

    def engines_info(self, proj=None):
        """`lab engines`: описание каждого движка + для его exe (F2F-сборка), stock и builds — sha256, ключи F2F, которые
        знает образ (policy.exe_caps), и последний hello этой сборки (версия, коммит, флаги; из аренд)."""
        try:
            with open(self._engine_hello_path(), encoding="utf-8") as f:
                hellos = json.load(f)
        except (OSError, ValueError):
            hellos = {}
        out = {}
        for eid, e in self.engines(proj).items():
            e = dict(e)
            files = {}
            names = dict(e.get("builds") or {})
            if e.get("exe") and e["exe"] not in names.values():
                names.setdefault("exe", e["exe"])
            if e.get("stock"):
                names.setdefault("stock", e["stock"])
            for nm, path in names.items():
                info = {"path": path, "exists": bool(path and os.path.isfile(path))}
                if info["exists"]:
                    sha = policy.file_sha(path)
                    info["sha256"] = sha
                    info["size"] = os.path.getsize(path)
                    caps = policy.exe_caps(path)
                    info["f2f"] = {k: v for k, v in caps.items()}
                    info["stock"] = bool(policy.is_stock(path, sha))
                    if sha in hellos:
                        info["hello"] = hellos[sha]
                files[nm] = info
            e["files"] = files
            out[eid] = e
        return out

    def _sync_stock(self):
        """Стоковые exe всех версий движка — для policy.is_stock (тестовый вид со стоковым exe любой версии — отказ)."""
        try:
            stocks = set()
            for e in self.engines().values():
                if e.get("stock"):
                    stocks.add(e["stock"])
            for p in list(self.projects.projects.values()):
                for e in self.engines(p).values():
                    if e.get("stock"):
                        stocks.add(e["stock"])
            policy.EXTRA_STOCK[:] = sorted(stocks)
        except Exception:
            pass

    # ------------------------------------------------------------------ состояние
    def _save_state(self):
        with self.lock:
            data = [l.to_dict() for l in self.leases.values()]
        tmp = self.state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"saved": time.time(), "leases": data}, f, ensure_ascii=False, indent=1, default=str)
        os.replace(tmp, self.state_path)

    def _load_state(self):
        try:
            with open(self.state_path, encoding="utf-8") as f:
                saved = json.load(f).get("leases", [])
        except (OSError, ValueError):
            return
        for d in saved:
            try:
                l = Lease(**{k: d.get(k) for k in Lease.FIELDS if d.get(k) is not None})
                l.run, l.auto_run = None, False          # прогоны прежнего демона закрыты как aborted
                for p in l.ports.values():
                    self.ports.reserve(l.name, p)
                if d.get("proc") and d["proc"].get("pid"):
                    spec = self._spec(l)
                    l.job = procs.Job(l.name, kill_on_close=spec.get("kill_on_close", True))
                    l.proc = procs.adopt(l.job, d["proc"])
                    l.proc.on_exit.append(self._on_exit(l))
                    if not l.proc.alive() and l.state in ("ready", "starting"):
                        l.state = "dead"
                        l.error = "process gone after daemon restart"
                self.leases[l.name] = l
                self.journal.event("lab.lease_restored", "%s state %s, proc %s" % (
                    l.name, l.state, "alive" if l.proc and l.proc.alive() else "none/dead"), instance=l.name,
                    agent=l.owner)
            except Exception:
                self.journal.event("lab.lease_restore_failed", traceback.format_exc(limit=3), error=True)
        self._save_state()

    # ------------------------------------------------------------------ аренды
    def _get(self, name):
        with self.lock:
            l = self.leases.get(name)
        if l is None:
            raise LabError("not-found", "no lease %r (have: %s)" % (name, ", ".join(sorted(self.leases)) or "none"))
        return l

    def _check_owner(self, l, owner, force=False):
        if force or owner is None or l.owner is None or owner == l.owner:
            return
        raise LabError("not-owner", "lease %s belongs to %s, not %s (force=true only for the user's stop)" % (
            l.name, l.owner, owner))

    def _touch(self, l, action):
        l.expires = time.time() + l.ttl
        l.last_action = action

    def _spec(self, l):
        proj = self.projects.get(l.project)
        if l.kind not in proj.kinds:
            raise LabError("bad-request", "project %s has no kind %r (have: %s)" % (
                l.project, l.kind, ", ".join(proj.kinds)))
        return self.kind_spec(proj, l.kind, l.params)

    def kind_spec(self, proj, kind, params=None):
        """Вид с перекрытиями движка аренды (этап 4a): `[kinds.<вид>.by_engine.<id>]` поверх вида — для другой версии
        движка свои exe/args/window/size/params (params сливаются по ключам). Движок — параметр аренды `engine` ->
        `engine` вида -> умолчание проекта/lab.toml."""
        spec = proj.kinds[kind]
        over = spec.get("by_engine") or {}
        if not over:
            return spec
        eid = (params or {}).get("engine") or spec.get("engine") or self.default_engine(proj)
        o = over.get(eid)
        if not isinstance(o, dict):
            return spec
        out = {k: v for k, v in spec.items() if k != "by_engine"}
        for k, v in o.items():
            if k == "params" and isinstance(v, dict):
                out["params"] = dict(spec.get("params") or {}, **v)
            else:
                out[k] = v
        out["by_engine_applied"] = eid
        return out

    @contextlib.contextmanager
    def _journaled(self, tool, args, lease=None, owner=None, plugin=None):
        l = self.leases.get(lease) if lease else None
        run = l.run if l else None
        rd0 = self._run_dir_id(run)
        e = self.journal.begin(tool, args, instance=lease, run=run, agent=owner or (l.owner if l else None),
                               plugin=plugin)
        box = {"result": None}

        def rd():
            # прогон мог открыться внутри вызова (первый start) или закрыться (release)
            if l is not None and l.run and l.run != e.get("run") and self._run_dir_id(l.run):
                e["run"] = l.run
                return self._run_dir_id(l.run)
            return rd0
        try:
            yield box
        except LabError as exc:
            self.journal.end(e, "%s: %s" % (exc.code, exc.message), error=True, run_dir=rd())
            raise
        except Exception as exc:
            self.journal.end(e, "%s: %s" % (type(exc).__name__, exc), error=True, run_dir=rd())
            raise
        else:
            res = box["result"]
            err = isinstance(res, dict) and res.get("ok") is False
            self.journal.end(e, res, error=err, run_dir=rd())

    def create_lease(self, project, kind, owner, ttl=None, name=None, params=None, start=False, mode=None,
                     reason=None, interactive=False, via=None):
        with self._journaled("lab.lease", {"project": project, "kind": kind, "ttl": ttl, "name": name,
                                           "params": params, "mode": mode, "reason": reason}, owner=owner) as box:
            try:
                proj = self.projects.get(project)
            except KeyError as exc:
                raise LabError("not-found", exc.args[0] if exc.args else str(exc))
            if kind not in proj.kinds:
                raise LabError("not-found", "project %s has no kind %r (have: %s)" % (
                    project, kind, ", ".join(proj.kinds)))
            spec = self.kind_spec(proj, kind, params)
            self.ctl.check_new_work()          # этап 5: drain — новые аренды не выдаются (503 draining)
            if spec.get("role") == "runtime":
                # стоковый рантайм: только lab play --user / --final-check (vclab/policy.py)
                try:
                    policy.check_runtime_lease(owner, mode, reason, interactive=interactive, via=via)
                except policy.PolicyError as exc:
                    self.journal.event("lab.policy_refused", "%s.%s by %s: %s" % (project, kind, owner, exc.message),
                                       error=True, agent=owner, args={"project": project, "kind": kind,
                                                                      "mode": mode})
                    raise LabError("policy", exc.message, project=project, kind=kind)
            elif mode:
                raise LabError("bad-request", "mode %r is only for role=runtime kinds" % mode)
            eid, eng = self.engine_of(proj, spec, params)
            ttl = min(float(ttl or self.cfg["leases"]["default_ttl"]), float(self.cfg["leases"]["max_ttl"]))
            with self.lock:
                if name:
                    if name in self.leases:
                        raise LabError("busy", "lease %s exists (owner %s)" % (name, self.leases[name].owner))
                else:
                    n = 1
                    while "%s-%s-%d" % (project, kind, n) in self.leases:
                        n += 1
                    name = "%s-%s-%d" % (project, kind, n)
                d = os.path.join(self.data, "inst", name)
                l = Lease(name=name, project=project, kind=kind, owner=owner, ttl=ttl, dir=d,
                          params=dict(params or {}), mode=mode, reason=reason, engine=eid,
                          engine_version=str(eng["version"]) if eng.get("version") else None)
                self.leases[name] = l
            try:
                for pname in spec.get("ports", []):
                    l.ports[pname] = self.ports.allocate(name)
            except Exception as exc:
                self.ports.release_owner(name)
                with self.lock:
                    self.leases.pop(name, None)
                raise LabError("busy", str(exc))
            os.makedirs(d, exist_ok=True)
            self._save_state()
            box["result"] = {"ok": True, "lease": l.to_dict(live=True)}
        if start:
            try:
                box["result"]["start"] = self.start(name, owner=owner)
            except LabError as exc:
                exc.extra.setdefault("lease", name)     # аренда остаётся (state failed): клиент должен знать имя
                raise
        return box["result"]

    def renew(self, name, owner=None, ttl=None, force=False):
        l = self._get(name)
        self._check_owner(l, owner, force)
        if ttl:
            l.ttl = min(float(ttl), float(self.cfg["leases"]["max_ttl"]))
        self._touch(l, "renew")
        self._save_state()
        return {"ok": True, "lease": l.name, "expires_in": round(l.expires - time.time(), 1), "ttl": l.ttl}

    def lease_info(self, name):
        return self._get(name).to_dict(live=True)

    def ps(self):
        with self.lock:
            ls = list(self.leases.values())
        f2f = self.pool.status()
        out = []
        for l in ls:
            d = l.to_dict(live=True)
            d["f2f"] = f2f.get(l.name)
            out.append(d)
        wd = self.watchdog
        if wd.last is None or time.time() - wd.last > wd.every * 2:
            wd.tick()                      # без фонового потока (тесты) или он отстал — свежий список
        return {"ok": True, "leases": out, "ports_used": dict(sorted(self.ports.used.items())),
                "foreign": wd.foreign, "foreign_checked": wd.last, "watchdog_error": wd.error,
                "daemon": self.ctl.summary()}

    # ------------------------------------------------------------------ сборки exe
    def build_copy(self, src):
        """Копия exe по содержимому: data\\builds\\<имя>-<sha12>.exe. Оригинал могут пересобирать во время прогонов;
        экземпляры запускают неизменную копию, одна копия на содержимое (а не на агента)."""
        st = os.stat(src)
        key = (os.path.normcase(src), st.st_size, st.st_mtime_ns)
        if key in self._exe_cache and os.path.exists(self._exe_cache[key][0]):
            return self._exe_cache[key]
        h = hashlib.sha256()
        with open(src, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        sha = h.hexdigest()
        stem, ext = os.path.splitext(os.path.basename(src))
        dst = os.path.join(self.data, "builds", "%s-%s%s" % (stem, sha[:12], ext))
        if not os.path.exists(dst):
            tmp = dst + ".tmp%d" % os.getpid()
            shutil.copy2(src, tmp)
            os.replace(tmp, dst)
        self._exe_cache[key] = (dst, sha)
        return dst, sha

    def _ctx(self, l, spec, proj):
        ctx = self.base_ctx()
        size = str(l.params.get("size") or spec.get("size") or "854x480")
        w, h = (size.lower().split("x") + ["0"])[:2]
        run_dir = self._run_dir_id(l.run) or ""
        ctx.update({"project_dir": proj.dir, "dir": l.dir, "lease": l.name, "owner": l.owner or "",
                    "port": dict(l.ports), "size": size, "size_w": int(w), "size_h": int(h), "run_dir": run_dir,
                    "kind": l.kind, "project": l.project})
        ctx.update({k: v for k, v in proj.dirs(ctx).items()})
        try:
            eid, eng = self.engine_of(proj, spec, l.params)
        except LabError:
            eid, eng = l.engine, {"id": l.engine, "version": l.engine_version, "builds": {}}
        ctx["engine"] = eng
        params = {}
        ctx["param"] = params
        for k, v in (spec.get("params") or {}).items():
            params[k] = expand(v, ctx)
        for k, v in l.params.items():
            params[k] = v
        return ctx

    def run_dir_of(self, l):
        return self._run_dir_id(l.run)

    def _run_dir_id(self, rid):
        if not rid:
            return None
        run = self.runs.active.get(rid)
        return run["dir"] if run else None

    def _ensure_run(self, l):
        if l.run and l.run in self.runs.active:
            return self.runs.active[l.run]
        proj = self.projects.get(l.project)
        dirs = proj.dirs(dict(self.base_ctx(), project_dir=proj.dir))
        run = self.runs.open(l.project, l.name, dirs.get("runs_dir"), owner=l.owner, meta={"auto": True})
        run["leases"].append(l.name)
        l.run, l.auto_run = run["id"], True
        return run

    def _log_paths(self, l, spec, ctx):
        out = {"stdout": os.path.join(l.dir, "logs", "%s.out.log" % l.kind),
               "stderr": os.path.join(l.dir, "logs", "%s.err.log" % l.kind)}
        for k, v in (spec.get("logs") or {}).items():
            out[k] = expand(v, ctx)
        return out

    def _archive_logs(self, l, tag):
        """Копия логов экземпляра в logs\\ прогона (перед стартом — прошлые, при остановке — текущие)."""
        rd = self._run_dir_id(l.run)
        if not rd:
            return []
        try:
            spec = self._spec(l)
            paths = self._log_paths(l, spec, self._ctx(l, spec, self.projects.get(l.project)))
        except Exception:
            return []
        saved = []
        for stream, p in paths.items():
            if os.path.isfile(p) and os.path.getsize(p) > 0:
                # одно имя на старт: «stop», «dead» и «prev» того же старта перезаписывают одну копию
                dst = os.path.join(rd, "logs", "%s_%s_start%d.log" % (l.name, stream, l.starts))
                try:
                    shutil.copyfile(p, dst)
                    saved.append(dst)
                except OSError:
                    pass
        return saved

    def _on_exit(self, l):
        def cb(proc):
            if proc is not l.proc:
                return
            self.pool.drop(l.name)
            if l.stopping:
                return
            l.state = "dead"
            info = proc.info()
            tail = self._tails(l, 40)
            l.error = "exited: %s" % info["exit"]
            self.journal.event("lab.instance_dead", "%s: %s" % (l.name, info["exit"]), instance=l.name,
                               agent=l.owner, run=l.run, run_dir=self._run_dir_id(l.run), error=True,
                               args={"exit_code": proc.exit_code})
            if l.run:
                self.runs.add_event(l.run, {"t": time.time(), "event": "instance-dead", "lease": l.name,
                                            "exit": info["exit"], "tail": tail})
            self._archive_logs(l, "dead")
            try:
                self._save_state()
            except Exception:
                pass
        return cb

    def _tails(self, l, n=60):
        try:
            spec = self._spec(l)
            paths = self._log_paths(l, spec, self._ctx(l, spec, self.projects.get(l.project)))
        except Exception:
            return {}
        out = {}
        for stream, p in paths.items():
            lines = read_tail(p, n)
            if lines:
                out[stream] = lines
        return out

    def _dead_error(self, l):
        info = l.proc.info() if l.proc else {}
        tails = self._tails(l, 60)
        spec = self._spec(l)
        main = spec.get("default_log") or next(iter(spec.get("logs") or {}), "stderr")
        return LabError("instance-dead", "%s is not running (%s)" % (l.name, info.get("exit") or l.state),
                        lease=l.name, exit_code=info.get("exit_code"), exit=info.get("exit"),
                        log_tail=tails.get(main, []), stderr_tail=tails.get("stderr", [])[-20:],
                        stdout_tail=tails.get("stdout", [])[-20:])

    # ------------------------------------------------------------------ старт / стоп
    def start(self, name, owner=None, restart=False, params=None, force=False):
        l = self._get(name)
        self._check_owner(l, owner, force)
        with self._journaled("lab.start", {"restart": restart, "params": params}, lease=name, owner=owner) as box, \
                l.lock:
            if l.proc and l.proc.alive():
                if not restart:
                    raise LabError("busy", "%s already running (pid %s); restart=true to restart" % (
                        name, l.proc.pid))
                self._stop_locked(l, "restart")
            if params:
                l.params.update(params)
            proj = self.projects.get(l.project)
            spec = self._spec(l)
            eid, eng = self.engine_of(proj, spec, l.params)
            l.engine, l.engine_version = eid, (str(eng["version"]) if eng.get("version") else None)
            run = self._ensure_run(l)
            self._archive_logs(l, "prev")
            l.starts += 1
            t0 = time.time()
            timing = {}
            ctx = self._ctx(l, spec, proj)
            exe_src = expand(spec["exe"], ctx)
            if not os.path.isabs(exe_src):
                exe_src = os.path.join(proj.dir, exe_src)
            if not os.path.exists(exe_src):
                raise LabError("start-failed", "exe not found: %s" % exe_src)
            exe, sha = exe_src, None
            if spec.get("copy_exe"):
                exe, sha = self.build_copy(exe_src)
            else:
                sha = policy.file_sha(exe_src)       # без копии — всё равно sha в прогон/историю (кэш по mtime)
            ctx.update({"exe": exe, "exe_src": exe_src, "exe_dir": os.path.dirname(exe_src), "exe_sha": sha or ""})
            timing["exe_s"] = round(time.time() - t0, 3)
            t1 = time.time()
            paths = self._log_paths(l, spec, ctx)
            for p in paths.values():          # прошлые логи уже в прогоне; готовность ищет только свежие строки
                try:
                    os.remove(p)
                except OSError:
                    pass
            l.junctions = prepare(spec.get("prepare"), ctx, l.dir, proj.dir)
            timing["prepare_s"] = round(time.time() - t1, 3)
            argv = [exe] + [str(a) for a in _flat(expand(spec.get("args", []), ctx))]
            iso = self._isolation_plan(l, spec, exe_src, exe, sha, argv)
            cwd = expand(spec.get("cwd", "{dir}"), ctx)
            env = expand(spec.get("env") or {}, ctx)
            if l.job is None:
                l.job = procs.Job(l.name, kill_on_close=spec.get("kill_on_close", True))
            t2 = time.time()
            l.stopping = False
            l.proc = procs.spawn(l.job, l.kind, argv, cwd, paths["stdout"], paths["stderr"], env=env,
                                 stdin_pipe=bool(spec.get("stdin")), console=bool(spec.get("console")))
            l.proc.on_exit.append(self._on_exit(l))
            l.stdin_poked = False         # новый процесс — новая консоль: «тычок» читателю stdin нужен заново (этап 6)
            timing["spawn_s"] = round(time.time() - t2, 3)
            l.state, l.error = "starting", None
            l.procs_hist = (l.procs_hist + [{"pid": l.proc.pid, "started": l.proc.started}])[-10:]
            self._touch(l, "start")
            self._save_state()
            run["meta"].setdefault("exe", {})[l.name] = {"path": exe, "src": exe_src, "sha256": sha,
                                                          "engine": l.engine, "engine_version": l.engine_version,
                                                          "role": spec.get("role", "test")}
            run["meta"].setdefault("engines", {})[l.name] = l.engine_version
            try:
                ready = self._ready(l, spec, ctx, paths, iso)
                if iso and iso.get("role") == "headless":
                    self._verify_headless(l, spec, iso, float(spec.get("window_check_s", 2.0)))
                elif iso and not iso.get("verified"):
                    self._verify_isolation(l, spec, iso)
            except LabError as exc:
                l.state, l.error = "failed", exc.message
                tails = self._tails(l, 40)
                self._stop_locked(l, "start-failed")
                l.state = "failed"
                self._save_state()
                exc.extra.setdefault("log_tail", tails)
                raise
            timing["ready_s"] = round(time.time() - t2, 3)
            timing["total_s"] = round(time.time() - t0, 3)
            l.state = "ready"
            l.ready_info = ready
            self._touch(l, "start")
            self._save_state()
            box["result"] = {"ok": True, "lease": name, "pid": l.proc.pid, "ports": l.ports, "dir": l.dir,
                             "run": l.run, "run_dir": run["dir"], "exe": exe, "exe_sha256": sha, "argv": argv,
                             "timing": timing, "ready": ready, "isolation": l.isolation, "engine": l.engine,
                             "engine_version": l.engine_version}
        return box["result"]

    def _ready(self, l, spec, ctx, paths, iso=None):
        out = []
        for st in spec.get("ready") or []:
            st = expand(st, ctx)
            t0 = time.time()
            if not l.proc.alive():
                raise self._dead_error(l)
            if "f2f" in st:
                rep = self._f2f_raw(l, spec, st["f2f"], expand(st.get("args", {}), ctx),
                                    timeout=float(st.get("timeout", 60)), connect_timeout=float(st.get("timeout", 60)))
                if not rep.get("ok"):
                    raise LabError("start-failed", "ready f2f %s: %s" % (st["f2f"], rep.get("error")), reply=rep)
                out.append({"f2f": st["f2f"], "s": round(time.time() - t0, 3), "result": rep.get("result")})
                if iso and iso.get("role") != "headless" and not iso.get("verified") and st["f2f"] == "hello":
                    self._verify_isolation(l, spec, iso, rep.get("result"))   # до любых шагов кадров
            elif "log" in st:
                line = self._wait_log(l, paths[st.get("stream", "stderr")], st["log"], float(st.get("timeout", 60)))
                out.append({"log": st["log"], "s": round(time.time() - t0, 3), "line": line})
            elif "pump_log" in st:
                r = self._pump(l, spec, paths[st.get("stream", "latest")], st["pump_log"],
                               int(st.get("max_frames", 600)), st.get("step") or {"ticks": 1, "frames": 1})
                out.append({"pump_log": st["pump_log"], "s": round(time.time() - t0, 3), **r})
            elif "pump_f2f" in st:
                cond = st["pump_f2f"]
                frames = 0
                while True:
                    rep = self._f2f_raw(l, spec, cond.get("cmd", "hello"), {}, timeout=30)
                    val = (rep.get("result") or {}).get(cond["field"]) if rep.get("ok") else None
                    if val == cond.get("value", True):
                        break
                    if frames >= int(st.get("max_frames", 600)):
                        raise LabError("start-failed", "pump_f2f %s.%s != %r after %d frames" % (
                            cond.get("cmd", "hello"), cond["field"], cond.get("value", True), frames))
                    rep = self._f2f_raw(l, spec, "step", st.get("step") or {"ticks": 1, "frames": 1}, timeout=30)
                    if not rep.get("ok"):
                        raise LabError("start-failed", "pump step: %s" % rep.get("error"))
                    frames += 1
                out.append({"pump_f2f": cond, "frames": frames, "s": round(time.time() - t0, 3)})
            else:
                raise LabError("bad-request", "unknown ready step %s" % st)
        return out

    # ------------------------------------------------------------------ изоляция (этап 3а, vclab/policy.py)
    def _isolation_plan(self, l, spec, exe_src, exe, sha, argv):
        """Перед запуском: стоковый exe вне role=runtime — отказ; exe движка без --f2f — отказ; ключи часов и окна
        добавляются, если сборка их знает; realtime без поддержки сборки — отказ. -> план проверки или None."""
        role = spec.get("role", "test")
        if role == "runtime":
            if not l.mode:
                raise LabError("policy", "%s: runtime kind started without a play/final-check session" % l.name)
            l.isolation = {"role": "runtime", "mode": l.mode, "reason": l.reason}
            return None
        if role == "headless":
            # этап 4: без окна и без ввода — стоковый exe любой версии разрешён; окна проверяются после готовности
            bad = policy.check_headless(spec, argv)
            if bad:
                self.journal.event("lab.policy_refused", "%s.%s headless: %s" % (l.project, l.kind, "; ".join(bad)),
                                   error=True, agent=l.owner, instance=l.name)
                raise LabError("policy", "%s: headless kind %s: %s" % (l.name, l.kind, "; ".join(bad)))
            l.isolation = {"role": "headless", "stock": bool(policy.is_stock(exe_src, sha) or policy.is_stock(exe, sha)),
                           "argv": "--headless", "verified": False, "windows": None}
            return l.isolation
        if policy.is_stock(exe_src, sha) or policy.is_stock(exe, sha):
            raise LabError("policy", "%s: %s is the stock runtime VoxelCore.exe — only `lab play` (role=runtime) may "
                                     "start it; test leases use the F2F test build" % (l.name, exe_src))
        required, tok, hello = policy.isolation_spec(spec, exe_src)
        if not required:
            return None
        if tok and tok not in (argv[:argv.index("--")] if "--" in argv else argv):   # после `--` — аргументы проекта
            raise LabError("policy", "%s: kind %s must be started with %s (input isolation); argv has none" % (
                l.name, l.kind, tok))
        plan = {"argv": tok, "hello": dict(hello), "verified": False}
        if policy.is_engine_exe(exe_src):
            caps = policy.exe_caps(exe)
            clock = str(l.params.get("clock") or spec.get("clock") or "virtual")
            window = str(l.params.get("window") or spec.get("window") or
                         (self.cfg.get("isolation") or {}).get("window", "hidden"))
            if clock not in policy.CLOCKS or window not in policy.WINDOWS:
                raise LabError("bad-request", "clock %r / window %r: allowed %s / %s" % (
                    clock, window, policy.CLOCKS, policy.WINDOWS))
            def engine_args(extra):
                # этап 4a: ключи движка — ДО `--` (после него — аргументы проекта: vc.get_project_arg; клиент сервера
                # `-- --gateway ...`); иначе движок их не видит и стартует с часами virtual и окном normal
                if "--" in argv:
                    i = argv.index("--")
                    argv[i:i] = extra
                else:
                    argv.extend(extra)
            eng_argv = argv[:argv.index("--")] if "--" in argv else argv
            if caps.get("--f2f-clock"):
                if "--f2f-clock" not in eng_argv:
                    engine_args(["--f2f-clock", clock])
                plan["hello"].setdefault("flags.clock", clock)
            elif clock != "virtual":
                raise LabError("start-failed", "%s: clock=%s needs a test build with --f2f-clock (%s has none: old "
                                               "VoxelCoreF2F.exe)" % (l.name, clock, exe_src))
            if caps.get("--f2f-window") and "--f2f-window" not in eng_argv:
                engine_args(["--f2f-window", window])
            plan.update(clock=clock, window=window if caps.get("--f2f-window") else None,
                        caps={k: v for k, v in caps.items() if v})
            # этап 4a: hello.version сборки должен быть версией движка аренды ([engines.<id>].f2f_version:
            # "0.31-f2f", "0.32-f2f"); другая версия — engine-mismatch (дерево убито, как при isolation-failed)
            try:
                _eid, eng = self.engine_of(self.projects.get(l.project), spec, l.params)
            except LabError:
                eng = {}
            want = eng.get("f2f_version")
            if want:
                plan["version"] = list(want) if isinstance(want, (list, tuple)) else [str(want)]
        l.isolation = plan
        return plan

    def _verify_isolation(self, l, spec, plan, hello=None):
        """hello.flags сверяются с планом; несовпадение — экземпляр убивается (дерево Job), ошибка isolation-failed.
        [isolation].enforce = false (lab.toml, решение пользователя) — только запись в журнал."""
        if hello is None:
            rep = self._f2f_raw(l, spec, "hello", {}, timeout=30, connect_timeout=30)
            hello = rep.get("result") if rep.get("ok") else {}
        bad = policy.verify_hello(hello, plan.get("hello"))
        vbad = policy.verify_version(hello, plan.get("version"))
        plan["flags"] = (hello or {}).get("flags")
        plan["hello_version"] = (hello or {}).get("version")
        plan["build_commit"] = ((hello or {}).get("build") or {}).get("commit")
        plan["verified"] = not bad and not vbad
        self._note_engine_hello(l, hello)
        if vbad and not bad:
            self.journal.event("lab.engine_mismatch", "%s: %s" % (l.name, vbad), instance=l.name, agent=l.owner,
                               run=l.run, error=True, args={"version": plan["hello_version"], "want": plan["version"]})
            plan["mismatch"] = [vbad]
            pid = l.proc.pid if l.proc else None
            if l.job is not None:
                l.job.terminate()
            if l.proc:
                l.proc.wait(5)
            hint = ""
            try:
                for oid, oe in self.engines(self.projects.get(l.project)).items():
                    ov = oe.get("f2f_version")
                    if ov and plan["hello_version"] in (ov if isinstance(ov, (list, tuple)) else [ov]):
                        hint = "; this build is engine %s: lease with --param engine=%s" % (oid, oid)
            except Exception:
                pass
            raise LabError("engine-mismatch", "%s killed: %s — the lease asks engine %s (%s), the exe is another "
                           "version%s" % (l.name, vbad, l.engine, l.engine_version, hint), lease=l.name, pid=pid,
                           version=plan["hello_version"], want=plan["version"])
        if not bad:
            return
        if vbad:
            bad = bad + [vbad]
        plan["mismatch"] = bad
        enforce = (self.cfg.get("isolation") or {}).get("enforce", True)
        self.journal.event("lab.isolation_failed", "%s: %s%s" % (l.name, "; ".join(bad),
                           "" if enforce else " (enforce=false: kept)"), instance=l.name, agent=l.owner, run=l.run,
                           error=True, args={"flags": plan["flags"], "want": plan.get("hello")})
        if not enforce:
            return
        pid = l.proc.pid if l.proc else None
        if l.job is not None:
            l.job.terminate()
        if l.proc:
            l.proc.wait(5)
        raise LabError("isolation-failed", "%s killed: hello does not confirm input isolation (%s). The test build must "
                       "report hello.flags {input:\"isolated\", clock}; rebuild VoxelCoreF2F.exe" % (l.name, "; ".join(bad)),
                       lease=l.name, pid=pid, flags=plan["flags"], want=plan.get("hello"))

    def _headless_violation(self, l, plan, wins, where):
        plan["windows"] = wins
        plan["verified"] = False
        self.journal.event("lab.isolation_failed", "%s (headless, %s): %d top-level window(s): %s" % (
            l.name, where, len(wins), ", ".join("%s pid %s%s" % (w["cls"], w["pid"], " visible" if w["visible"]
                                                                  else "") for w in wins[:5])),
            instance=l.name, agent=l.owner, run=l.run, error=True, args={"windows": wins[:20]})
        enforce = (self.cfg.get("isolation") or {}).get("enforce", True)
        if not enforce:
            return False
        if l.job is not None:
            l.job.terminate()
        if l.proc:
            l.proc.wait(5)
        return True

    def _verify_headless(self, l, spec, plan, seconds=2.0):
        """Headless: у процессов дерева Job нет окон верхнего уровня (EnumWindows, только чтение). Опрос seconds
        секунд после готовности (окно движок создал бы при инициализации). Окно есть — дерево убито, isolation-failed."""
        end = time.time() + max(0.0, seconds)
        checks = 0
        while True:
            pids = (l.job.pids() if l.job is not None else []) or ([l.proc.pid] if l.proc else [])
            wins = policy.top_windows(pids)
            checks += 1
            if wins:
                if self._headless_violation(l, plan, wins, "start"):
                    raise LabError("isolation-failed", "%s killed: headless instance created %d top-level window(s) "
                                   "(%s) — a headless kind must not have a window" % (
                                       l.name, len(wins), ", ".join(w["cls"] for w in wins[:5])),
                                   lease=l.name, windows=wins[:20])
                return
            if time.time() >= end or not (l.proc and l.proc.alive()):
                break
            time.sleep(0.25)
        plan.update(verified=True, windows=[], window_checks=checks, checked_pids=len(pids))

    def _watch_headless(self):
        """Сторож (поток watchdog): живые headless-аренды без окон всё время работы, не только на старте."""
        with self.lock:
            ls = [l for l in self.leases.values() if (l.isolation or {}).get("role") == "headless" and l.proc
                  and l.proc.alive() and not l.stopping]
        for l in ls:
            try:
                wins = policy.top_windows(l.job.pids() if l.job is not None else [l.proc.pid])
                if wins and self._headless_violation(l, l.isolation, wins, "watchdog"):
                    l.state, l.error = "failed", "isolation-failed: headless window"
                    self._save_state()
            except Exception:
                pass

    # ------------------------------------------------------------------ stdin (этап 4: lab stdin)
    def stdin(self, name, text, owner=None, wait=2.0, pattern=None, stream=None, force=False, poke=None,
              journal=True):
        """Строка в stdin экземпляра (вид со stdin = true) -> новые строки лога за wait секунд (или до pattern).
        stdin_poke = "console" (VoxelCore --stdin-cmd на Windows): читатель движка ждёт _kbhit() консоли, а не данных
        канала; консоль экземпляра без окна (CREATE_NO_WINDOW), поэтому один раз в её буфер ввода кладётся одно
        событие клавиши (вспомогательный процесс AttachConsole(pid) + WriteConsoleInputW) — после этого читатель
        блокируется на getline канала и читает строки отсюда. Окно, фокус и ввод пользователя не участвуют."""
        import re as _re
        l = self._get(name)
        self._check_owner(l, owner, force)
        cm = (self._journaled("lab.stdin", {"text": text, "wait": wait}, lease=name, owner=owner) if journal
              else _nojournal())          # этап 6: health-проверки supervisor раз в N с — не в журнал
        with cm as box:
            spec = self._spec(l)
            if not spec.get("stdin"):
                raise LabError("no-stdin", "kind %s of %s has no stdin channel (stdin = true)" % (l.kind, l.project))
            if not l.proc or not l.proc.alive():
                raise self._dead_error(l) if l.proc else LabError("not-running", "%s is not started" % name)
            paths = self._log_paths(l, spec, self._ctx(l, spec, self.projects.get(l.project)))
            stream = stream or spec.get("default_log") or "stdout"
            if stream not in paths:
                raise LabError("bad-request", "stream %r: have %s" % (stream, ", ".join(paths)))
            before = len(read_tail(paths[stream], 0))
            line = text if text.endswith("\n") else text + "\n"
            l.proc.write_stdin(line)
            want_poke, poke = poke, None
            poke = want_poke if want_poke is False else None
            if spec.get("stdin_poke") == "console" and not l.stdin_poked and poke is not False:
                poke = procs.console_poke(l.proc.pid)
                l.stdin_poked = bool(poke.get("ok"))
            rx = _re.compile(pattern) if pattern else None
            end = time.time() + float(wait or 0)
            new = []
            while True:
                lines = read_tail(paths[stream], 0)
                new = lines[before:]
                if rx is not None and any(rx.search(x) for x in new):
                    break
                if time.time() >= end or not l.proc.alive():
                    break
                time.sleep(0.05)
            self._touch(l, "stdin")
            box["result"] = {"ok": True, "lease": name, "sent": text, "stream": stream, "lines": new,
                             "matched": bool(rx and any(rx.search(x) for x in new)) if rx else None,
                             "poke": poke}
        return box["result"]

    def _wait_log(self, l, path, pattern, timeout):
        import re
        rx = re.compile(pattern)
        end = time.time() + timeout
        while True:
            for line in read_tail(path, 0):
                if rx.search(line):
                    return line
            if not l.proc.alive():
                raise self._dead_error(l)
            if time.time() > end:
                raise LabError("start-failed", "log %s: /%s/ not seen in %.0f s" % (
                    os.path.basename(path), pattern, timeout), log_tail=read_tail(path, 20))
            time.sleep(0.1)

    def _pump(self, l, spec, path, pattern, max_frames, step):
        """Шагать кадры F2F, пока в логе не появится строка: стартовый сценарий движка идёт только в кадрах."""
        import re
        rx = re.compile(pattern)
        frames = 0
        while True:
            for line in read_tail(path, 0):
                if rx.search(line):
                    return {"frames": frames, "line": line}
            if frames >= max_frames:
                raise LabError("start-failed", "/%s/ not in %s after %d frames" % (
                    pattern, os.path.basename(path), frames), log_tail=read_tail(path, 30))
            rep = self._f2f_raw(l, spec, "step", step, timeout=60)
            if not rep.get("ok"):
                raise LabError("start-failed", "pump step: %s" % rep.get("error"), reply=rep)
            frames += 1

    def _stop_locked(self, l, why):
        """Мягко (шаги stop дескриптора), потом TerminateJobObject всего дерева."""
        l.stopping = True
        steps = []
        spec = None
        try:
            spec = self._spec(l)
        except Exception:
            pass
        p = l.proc
        if p and p.alive() and spec:
            for st in spec.get("stop") or []:
                # if_param: шаг только при непустом параметре аренды (игровой сервер: F2F quit только в lockstep)
                if st.get("if_param") and not l.params.get(st["if_param"]):
                    continue
                t0 = time.time()
                try:
                    if "f2f" in st:
                        self._f2f_raw(l, spec, st["f2f"], {}, timeout=float(st.get("timeout", 5)))
                    elif "stdin" in st:
                        p.write_stdin(st["stdin"])
                        if spec.get("stdin_poke") == "console" and not l.stdin_poked:
                            l.stdin_poked = bool(procs.console_poke(p.pid).get("ok"))
                    if "wait_exit" in st or "f2f" in st or "stdin" in st:
                        p.wait(float(st.get("wait_exit", 5)))
                    steps.append({"step": st, "s": round(time.time() - t0, 3), "alive": p.alive()})
                except Exception as exc:
                    steps.append({"step": st, "error": str(exc)})
                if not p.alive():
                    break
        forced = False
        if l.job is not None and p and not p.alive():
            end = time.time() + 1.0       # процесс вышел сам: список Job пустеет с небольшой задержкой
            while l.job.pids() and time.time() < end:
                time.sleep(0.02)
        if l.job is not None and (l.job.pids() or (p and p.alive())):
            forced = bool(l.job.pids())
            l.job.terminate()
            if p:
                p.wait(5)
        self.pool.drop(l.name)
        archived = self._archive_logs(l, "stop")
        if l.state not in ("failed",):
            l.state = "stopped"
        return {"steps": steps, "forced_kill": forced, "exit": p.info()["exit"] if p else None,
                "archived": archived, "why": why}

    def stop(self, name, owner=None, force=False):
        l = self._get(name)
        self._check_owner(l, owner, force)
        with self._journaled("lab.stop", {}, lease=name, owner=owner) as box, l.lock:
            r = self._stop_locked(l, "stop")
            self._touch(l, "stop")
            self._save_state()
            box["result"] = {"ok": True, "lease": name, **r}
        return box["result"]

    def release(self, name, owner=None, force=False, keep_dir=False, reason="release"):
        l = self._get(name)
        self._check_owner(l, owner, force)
        with self._journaled("lab.release", {"force": force, "reason": reason}, lease=name, owner=owner) as box, \
                l.lock:
            r = self._stop_locked(l, reason)
            removed = False
            for j in l.junctions or []:
                try:
                    if os.path.isjunction(j):
                        os.rmdir(j)      # только ссылка; содержимое пака не трогается
                except OSError:
                    pass
            inst_root = os.path.join(self.data, "inst")
            if not keep_dir and os.path.normcase(os.path.abspath(l.dir)).startswith(
                    os.path.normcase(inst_root) + os.sep):
                for _ in range(10):
                    try:
                        shutil.rmtree(l.dir)
                        removed = True
                        break
                    except FileNotFoundError:
                        break
                    except OSError:
                        time.sleep(0.3)
            if l.job:
                l.job.close()
                l.job = None
            self.ports.release_owner(l.name)
            run = None
            if l.run and l.auto_run:
                verdict = "dead" if l.error and l.error.startswith("exited") else ("failed" if l.state == "failed"
                                                                                  else "done")
                run = self.runs.close(l.run, verdict=verdict)
            with self.lock:
                self.leases.pop(l.name, None)
            self._save_state()
            box["result"] = {"ok": True, "lease": name, "removed_dir": removed, "run": l.run,
                             "run_dir": run["dir"] if run else None, **r}
        return box["result"]

    def stop_all(self, owner=None):
        """«Стоп» пользователя: снять все аренды (force)."""
        with self.lock:
            names = list(self.leases)
        out = []
        for n in names:
            try:
                out.append(self.release(n, owner=owner, force=True, reason="stop-all"))
            except Exception as exc:
                out.append({"ok": False, "lease": n, "error": str(exc)})
        return {"ok": True, "released": out}

    # ------------------------------------------------------------------ логи
    def logs(self, name, stream=None, tail=80, grep=None):
        l = self._get(name)
        spec = self._spec(l)
        paths = self._log_paths(l, spec, self._ctx(l, spec, self.projects.get(l.project)))
        stream = stream or spec.get("default_log") or next(iter(spec.get("logs") or {}), "stderr")
        if stream not in paths:
            raise LabError("bad-request", "stream %r: have %s" % (stream, ", ".join(paths)))
        return {"ok": True, "lease": name, "stream": stream, "path": paths[stream],
                "lines": read_tail(paths[stream], int(tail or 0), grep=grep), "streams": list(paths)}

    # ------------------------------------------------------------------ F2F
    def _f2f_raw(self, l, spec, cmd, args, timeout=60.0, connect_timeout=2.0):
        port_name = spec.get("f2f")
        if not port_name:
            raise LabError("bad-request", "kind %s of %s has no F2F port" % (l.kind, l.project))
        conn = self.pool.get(l.name, l.ports[port_name])
        # параметр аренды f2f_idle=false выключает простойную команду (lockstep: пакет в случайный такт сервера)
        conn.idle = None if str(l.params.get("f2f_idle", "")).lower() in ("false", "0", "off") else spec.get("f2f_idle")
        alive = l.proc.alive if l.proc else (lambda: False)
        try:
            return conn.call(cmd, args, timeout=timeout, connect_timeout=connect_timeout, alive=alive)
        except TimeoutError as exc:
            if not alive():
                raise self._dead_error(l)
            raise LabError("f2f-timeout", str(exc), lease=l.name)
        except (ConnectionError, OSError) as exc:
            if not alive():
                raise self._dead_error(l)
            raise LabError("f2f-unreachable", "%s: %s" % (type(exc).__name__, exc), lease=l.name,
                           port=l.ports[port_name])

    def f2f(self, name, cmd, args=None, timeout=60.0, owner=None, force=False):
        l = self._get(name)
        self._check_owner(l, owner, force)
        args = dict(args or {})
        with self._journaled("lab.f2f", {"cmd": cmd, "args": args}, lease=name, owner=owner) as box:
            if cmd == "@disconnect":
                self.pool.drop(name)
                box["result"] = {"ok": True, "result": "disconnected"}
                return box["result"]
            spec = self._spec(l)
            if not l.proc or not l.proc.alive():
                raise self._dead_error(l) if l.proc else LabError("not-running", "%s is not started" % name)
            shot = None
            if cmd == "shot":
                label = str(args.pop("name", "") or "shot")
                if not args.get("path"):
                    run = self._ensure_run(l)
                    n = len(run["shots"]) + 1
                    args["path"] = os.path.join(run["dir"], "shots", "%03d_%s_%s.png" % (n, l.name, label))
                shot = label
            t0 = time.time()
            rep = self._f2f_raw(l, spec, cmd, args, timeout=float(timeout))
            dt = time.time() - t0
            self._touch(l, "f2f " + cmd)
            if shot and rep.get("ok") and l.run:
                res = rep.get("result") or {}
                self.runs.add_shot(l.run, {"name": shot, "lease": l.name, "path": res.get("path") or args["path"],
                                           "sha256": res.get("sha256"), "w": res.get("w"), "h": res.get("h"),
                                           "t": time.time()})
            rep = dict(rep)
            rep["f2f_ms"] = round(dt * 1000, 2)
            box["result"] = rep
        return box["result"]

    def f2f_quiet(self, name, cmd, args=None, timeout=60.0, owner=None):
        """F2F без записи в журнал (такты таймлайна, циклы ожидания: тысячи вызовов). Владелец и смерть процесса
        проверяются как у f2f; вызывающий журналирует сводку (scenario.timeline, scenario.step)."""
        l = self._get(name)
        self._check_owner(l, owner)
        spec = self._spec(l)
        if not l.proc or not l.proc.alive():
            raise self._dead_error(l) if l.proc else LabError("not-running", "%s is not started" % name)
        rep = self._f2f_raw(l, spec, cmd, dict(args or {}), timeout=float(timeout))
        if time.time() - (l.expires - l.ttl) > 5:
            self._touch(l, "f2f " + cmd)
        return rep

    # ------------------------------------------------------------------ прогоны
    def open_run(self, project, scenario, owner=None, leases=None, meta=None):
        proj = self.projects.get(project)
        dirs = proj.dirs(dict(self.base_ctx(), project_dir=proj.dir))
        run = self.runs.open(project, scenario, dirs.get("runs_dir"), owner=owner, meta=meta)
        for n in leases or []:
            l = self._get(n)
            self._check_owner(l, owner)
            if l.run and l.auto_run and l.run in self.runs.active:
                self.runs.close(l.run, verdict="superseded", extra={"next_run": run["id"]})
            l.run, l.auto_run = run["id"], False
            run["leases"].append(n)
        self._save_state()
        self.journal.event("lab.run_open", run["dir"], run=run["id"], agent=owner, run_dir=run["dir"],
                           args={"project": project, "scenario": scenario, "leases": leases})
        return {"ok": True, "run": run}

    def attach_run(self, name, rid, owner=None):
        """Привязать аренду к открытому прогону (интерпретатор сценариев: аренды создаются внутри своего прогона)."""
        l = self._get(name)
        self._check_owner(l, owner)
        run = self.runs.active.get(rid)
        if run is None:
            raise LabError("not-found", "run %s is not open" % rid)
        if l.run and l.auto_run and l.run in self.runs.active and l.run != rid:
            self.runs.close(l.run, verdict="superseded", extra={"next_run": rid})
        l.run, l.auto_run = rid, False
        if name not in run["leases"]:
            run["leases"].append(name)
        self._save_state()
        return {"ok": True, "lease": name, "run": rid}

    def close_run(self, rid, verdict=None, owner=None, extra=None):
        run = self.runs.close(rid, verdict=verdict, extra=extra)
        if run is None:
            raise LabError("not-found", "run %s is not open" % rid)
        with self.lock:
            for l in self.leases.values():
                if l.run == rid:
                    l.run = None
        self._save_state()
        self.journal.event("lab.run_close", verdict or "done", run=rid, agent=owner, run_dir=run["dir"])
        return {"ok": True, "run": run}

    # ------------------------------------------------------------------ возможности (плагины)
    def _core_features(self):
        lab = self

        def pump_log(ctx, args):
            l = lab._get(args["lease"])
            spec = lab._spec(l)
            paths = lab._log_paths(l, spec, lab._ctx(l, spec, lab.projects.get(l.project)))
            return lab._pump(l, spec, paths[args.get("stream", "latest")], args["pattern"],
                             int(args.get("max_frames", 600)), args.get("step") or {"ticks": 1, "frames": 1})

        def features(ctx, args):
            return {k: v.info() for k, v in lab.projects.features().items()}

        def reload(ctx, args):
            return {"changed": lab.projects.scan(), "generation": lab.projects.generation,
                    "errors": lab.projects.errors,
                    "plugin_errors": {n: p.plugin_error for n, p in lab.projects.projects.items() if p.plugin_error}}

        def stdin_f(ctx, args):
            return lab.stdin(args["lease"], args["text"], owner=ctx.owner, wait=float(args.get("wait", 2.0)),
                             pattern=args.get("pattern"), stream=args.get("stream"))

        def engines_f(ctx, args):
            proj = lab.projects.get(args["project"]) if args.get("project") else None
            return {"default": lab.default_engine(proj), "engines": lab.engines_info(proj)}

        core = {
            "core.stdin": Feature("core.stdin", stdin_f, "line to the stdin of a lease (kind stdin = true; VoxelCore "
                                  "--stdin-cmd admin commands) -> new log lines: {lease, text, wait=2, pattern?, "
                                  "stream?}", {"type": "object", "properties": {"lease": {"type": "string"},
                                                                                "text": {"type": "string"},
                                                                                "wait": {"type": "number"},
                                                                                "pattern": {"type": "string"}},
                                               "required": ["lease", "text"]}, project="core",
                                  version="core@" + VERSION),
            "core.engines": Feature("core.engines", engines_f, "engine versions ([engines.*]): {project?}",
                                    project="core", version="core@" + VERSION),
            "core.pump_log": Feature("core.pump_log", pump_log, "F2F step until a log line matches: "
                                     "{lease, pattern, stream=latest, max_frames=600, step={ticks,frames}}",
                                     {"type": "object", "properties": {"lease": {"type": "string"},
                                                                       "pattern": {"type": "string"}},
                                      "required": ["lease", "pattern"]}, project="core", version="core@" + VERSION),
            "core.features": Feature("core.features", features, "list all features (core + project plugins)",
                                     project="core", version="core@" + VERSION),
            "core.reload": Feature("core.reload", reload, "rescan project descriptors and plugins now",
                                   project="core", version="core@" + VERSION),
        }
        try:                        # этап 2б: история (SQLite, писатель — демон), ворота, панель, lab play, загрузка ПК
            from vclab.quality.history import install_core
            install_core(self, core, Feature, VERSION)
        except Exception:
            self.journal.event("lab.stage2b_failed", traceback.format_exc(limit=6), error=True)
        try:                        # этап 6: supervisor (службы, перезапуск, инциденты, БД состояния, панель)
            from vclab.supervise import install as _sup_install
            _sup_install(self, core, Feature, VERSION)
        except Exception:
            self.journal.event("lab.stage6_failed", traceback.format_exc(limit=6), error=True)
        try:                        # этап 3а: замеры только на простаивающем ПК (vclab/quality/perf.py)
            from vclab.quality.perf import PerfService, idle_reasons, lab_activity
            from vclab.quality import sysload as _sl
            self.perf = PerfService(self)

            def f_perf(ctx, a):
                act = a.get("action", "start")
                if act == "start":
                    return lab.perf.start(a["project"], a["scenario"], ctx.owner, args=a.get("args") or {},
                                          wait_idle_s=a.get("wait_idle_s"), idle_window_s=a.get("idle_window_s"),
                                          allow_contended=bool(a.get("allow_contended")))
                if act == "list":
                    return {n: sorted(p.perf_runners) for n, p in lab.projects.projects.items()}
                raise KeyError("action start|list")

            def f_idle(ctx, a):
                th = lab.perf.th()
                s = _sl.sample(float(a.get("seconds", th["sample_window_s"])))
                reasons = idle_reasons(s, th, lab_activity(lab))
                return {"idle": not reasons, "reasons": reasons, "thresholds": th,
                        "sample": {k: s.get(k) for k in ("cpu_total_pct", "cpu_others_pct", "user_idle_s", "gpu",
                                                         "foreign_engines", "top", "foreground")}}
            core["core.perf"] = Feature("core.perf", f_perf, "perf run on an idle PC {project, scenario, args?, "
                                        "wait_idle_s?, idle_window_s?, allow_contended?} -> job (lab job <id>)",
                                        {"type": "object", "properties": {"project": {"type": "string"},
                                                                          "scenario": {"type": "string"},
                                                                          "args": {"type": "object"}}},
                                        project="core", version="core@" + VERSION)
            core["core.idle"] = Feature("core.idle", f_idle, "is the PC idle for measurements now (lab perf "
                                        "definition) {seconds?}", project="core", version="core@" + VERSION)
        except Exception:
            self.journal.event("lab.stage3a_failed", traceback.format_exc(limit=6), error=True)
        self.projects.core_features = core

    ADMIN_FEATURES = {"core.gate_accept": "gate.accept"}       # этап 5: только admin (храповик поднимает человек)
    NEW_WORK_FEATURES = {"core.perf": "start", "core.play": "start"}     # во время drain — 503

    def call(self, feature, args=None, owner=None, via=None, role=None):
        feats = self.projects.features()
        if feature in ("", "list", None):
            feature = "core.features"
        f = feats.get(feature)
        if f is None:
            raise LabError("not-found", "no feature %r (have: %s)" % (feature, ", ".join(sorted(feats))))
        if feature in self.ADMIN_FEATURES:
            self.ctl.require(self.ADMIN_FEATURES[feature], owner, role, via=via,
                             args={k: v for k, v in (args or {}).items() if k in ("project", "run", "frames")})
        if feature in self.NEW_WORK_FEATURES and (args or {}).get("action", "start" if feature == "core.perf"
                                                                     else "status") == self.NEW_WORK_FEATURES[feature]:
            self.ctl.check_new_work()
        with self._journaled("lab.call", {"feature": feature, "args": args}, lease=(args or {}).get("lease")
                             if isinstance((args or {}).get("lease"), str) and (args or {}).get("lease") in self.leases
                             else None, owner=owner, plugin=f.version) as box:
            try:
                res = f.fn(FeatureCtx(self, f, owner, via), dict(args or {}))
            except LabError:
                raise
            except PermissionError as exc:          # отказ политики (lab play без --user/--final-check и т.п.)
                raise LabError("policy", str(exc))
            except Exception as exc:
                raise LabError("feature-error", "%s: %s" % (type(exc).__name__, exc),
                               trace=traceback.format_exc(limit=8))
            box["result"] = {"ok": True, "feature": feature, "version": f.version, "result": res}
        return box["result"]
