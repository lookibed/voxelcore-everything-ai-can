"""Проекты: дескриптор projects/<имя>/project.toml (виды экземпляров, каталоги, сравнение) + необязательный plugin.py.

Ядро ничего не знает о конкретной игре: экземпляр — это процесс, описанный в дескрипторе (exe, шаблон аргументов,
подготовка каталога, порты, готовность, остановка, логи). Подстановки в строках — {ключ} или {ключ|по умолчанию}:
  lab_data, lab_dir, work_root, repo_root (= repo), packs ({repo_root}\\packs), engine.<поле>, machine.<ключ>, project_dir, dir (каталог экземпляра), lease, owner, exe, exe_dir, size, size_w, size_h,
  port.<имя>, param.<имя>, run_dir.
Строка, целиком равная одной подстановке, получает значение как есть (список, число).
Плагин: register(api) -> api.feature("имя", fn, description=..., schema=..., mcp=False); fn(ctx, args) -> dict.
Перезагрузка: правка project.toml или plugin.py видна без рестарта демона (опрос mtime раз в секунду); при ошибке
загрузки остаётся прежняя версия, ошибка — в /projects и в журнале (plugin_load_failed)."""
import importlib.util
import json
import os
import re
import shutil
import threading
import time
import tomllib
import traceback

RX = re.compile(r"\{([A-Za-z_][\w.]*)(?:\|([^{}]*))?\}")
KIND_KEYS = {"description", "exe", "copy_exe", "args", "cwd", "ports", "params", "env", "prepare", "ready", "stop",
             "logs", "f2f", "f2f_idle", "size", "stdin", "console", "kill_on_close", "shots", "default_log",
             # этап 3а (принуждение): role = "test" | "runtime" (стоковый рантайм — только lab play / final-check),
             # isolation = {argv = "--f2f", hello = {"flags.input" = "isolated"}}, clock/window — умолчания F2F-сборки
             "role", "isolation", "clock", "window",
             # этап 4: engine = "<id>" из [engines.*] (lab.toml или проекта); role = "headless" — без окна и ввода
             # (стоковый exe разрешён, проверка EnumWindows); stdin_poke = "console" — см. service.stdin;
             # window_check_s — сколько секунд после готовности проверять отсутствие окон
             "engine", "stdin_poke", "window_check_s",
             # этап 4a: by_engine = { v032 = { exe, args, window, size, params... } } — перекрытия вида для аренды
             # с другим движком (service.kind_spec); ключи — те же, что у вида
             "by_engine"}
ROLES = ("test", "runtime", "headless")


class TemplateError(KeyError):
    pass


def lookup(ctx, key, default=None):
    cur = ctx
    for part in key.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            if default is not None:
                return default
            raise TemplateError("template {%s}: unknown key (have: %s)" % (key, ", ".join(sorted(
                ctx.keys() if isinstance(ctx, dict) else []))))
    return cur


def expand(value, ctx):
    if isinstance(value, str):
        m = RX.fullmatch(value)
        if m:
            return lookup(ctx, m.group(1), m.group(2))
        return RX.sub(lambda m: str(lookup(ctx, m.group(1), m.group(2))), value)
    if isinstance(value, list):
        return [expand(v, ctx) for v in value]
    if isinstance(value, dict):
        return {k: expand(v, ctx) for k, v in value.items()}
    return value


def _inside(path, root):
    path, root = os.path.normcase(os.path.abspath(path)), os.path.normcase(os.path.abspath(root))
    return path == root or path.startswith(root.rstrip("\\/") + os.sep)


# ---------------------------------------------------------------- подготовка каталога экземпляра
def prepare(steps, ctx, inst_dir, project_dir, log=None):
    """Выполнить шаги prepare. Относительные dst/path/link — от каталога экземпляра, src — от каталога проекта.
    Возвращает список созданных junction (их снимают до удаления каталога)."""
    junctions = []

    def dst_of(p):
        p = expand(p, ctx)
        return p if os.path.isabs(p) else os.path.join(inst_dir, p)

    def src_of(p):
        p = expand(p, ctx)
        return p if os.path.isabs(p) else os.path.join(project_dir, p)

    def junction(link, target):
        if not os.path.isdir(target):
            raise FileNotFoundError("junction target %s" % target)
        if os.path.lexists(link):
            if os.path.isjunction(link) or os.path.islink(link):
                if os.path.normcase(os.path.realpath(link)) == os.path.normcase(os.path.realpath(target)):
                    junctions.append(link)
                    return
                os.rmdir(link)
            else:
                raise FileExistsError("%s exists and is not a junction" % link)
        os.makedirs(os.path.dirname(link), exist_ok=True)
        import _winapi
        _winapi.CreateJunction(target, link)
        junctions.append(link)

    for st in steps or []:
        act = st.get("action")
        t0 = time.time()
        if act == "mkdir":
            os.makedirs(dst_of(st["path"]), exist_ok=True)
        elif act == "write":
            path = dst_of(st["path"])
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if "json" in st:
                data = json.dumps(expand(st["json"], ctx), ensure_ascii=False, indent=1)
            else:
                data = expand(st.get("text", ""), ctx)
            with open(path, "w", encoding=st.get("encoding", "utf-8"), newline="\n") as f:
                f.write(data)
        elif act == "template":
            path = dst_of(st["dst"])
            with open(src_of(st["src"]), encoding="utf-8") as f:
                body = f.read()
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(expand(body, ctx))
        elif act == "copy":
            path = dst_of(st["dst"])
            os.makedirs(os.path.dirname(path), exist_ok=True)
            shutil.copy2(src_of(st["src"]), path)
        elif act == "copytree":
            dst = dst_of(st["dst"])
            if not _inside(dst, inst_dir):
                raise PermissionError("copytree dst outside the instance dir: %s" % dst)
            if os.path.exists(dst) and st.get("fresh", True):
                shutil.rmtree(dst)
            src = src_of(st["src"])
            if not os.path.isdir(src):
                raise FileNotFoundError("copytree src %s" % src)
            robo = shutil.which("robocopy")
            if robo and st.get("robocopy", True):
                # тысячи мелких файлов мира: robocopy /MT:16 ~1 с против ~10 с shutil.copytree (замер 01.10)
                import subprocess
                cmd = [robo, src, dst, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/MT:16", "/R:1", "/W:1"]
                if st.get("exclude"):
                    cmd += ["/XF"] + list(st["exclude"])
                rc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    stdin=subprocess.DEVNULL, creationflags=0x08000000).returncode
                if rc >= 8:
                    raise RuntimeError("robocopy %s -> %s failed: exit %d" % (src, dst, rc))
            else:
                ign = shutil.ignore_patterns(*st.get("exclude", [])) if st.get("exclude") else None
                shutil.copytree(src, dst, ignore=ign, dirs_exist_ok=True)
        elif act == "junction":
            junction(dst_of(st["link"]), src_of(st["target"]))
        elif act == "packs":
            packs = expand(st.get("packs", []), ctx)
            if isinstance(packs, str):
                packs = [p for p in re.split(r"[,\s]+", packs) if p]
            content = src_of(st.get("content", "{repo_root}\\packs"))
            for p in packs:
                junction(os.path.join(dst_of(st.get("into", "content")), p), os.path.join(content, p))
        elif act == "append":
            # дописать строки в файл (например, ops.txt сервера: оператор второго клиента)
            path = dst_of(st["path"])
            lines = expand(st.get("lines", []), ctx)
            if isinstance(lines, str):
                lines = [x for x in re.split(r"[,\s]+", lines) if x]
            if lines:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "a", encoding=st.get("encoding", "utf-8"), newline="\n") as f:
                    for x in lines:
                        f.write("%s\n" % x)
        elif act == "properties":
            src, path = src_of(st["src"]), dst_of(st["dst"])
            sets = {k: str(v) for k, v in expand(st.get("set", {}), ctx).items()}
            enc = st.get("encoding", "latin-1")
            with open(src, encoding=enc) as f:
                lines = f.read().splitlines()
            out, done = [], set()
            for line in lines:
                k = line.split("=", 1)[0].strip()
                if k in sets and not line.lstrip().startswith("#"):
                    out.append("%s=%s" % (k, sets[k]))
                    done.add(k)
                else:
                    out.append(line)
            out += ["%s=%s" % (k, v) for k, v in sets.items() if k not in done]
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding=enc, newline="\n") as f:
                f.write("\n".join(out) + "\n")
        else:
            raise ValueError("prepare: unknown action %r" % act)
        if log:
            log("%s %.3f s" % (act, time.time() - t0))
    return junctions


# ---------------------------------------------------------------- проекты и плагины
class Feature:
    def __init__(self, name, fn, description="", schema=None, mcp=False, project=None, version=None):
        self.name, self.fn, self.description = name, fn, description
        self.schema = schema or {"type": "object", "properties": {}}
        self.mcp, self.project, self.version = mcp, project, version

    def info(self):
        return {"name": self.name, "description": self.description, "schema": self.schema, "mcp": self.mcp,
                "project": self.project, "version": self.version}


SCENARIO_HOOKS = ("start", "step", "translate", "after_step", "expect", "timeline_setup", "info", "finish",
                  "server_step", "lockstep_tick", "lockstep_run", "compare_state", "stop")


class PluginApi:
    def __init__(self, project, version):
        self.project, self.version = project, version
        self.features = {}
        self.scenario_hooks = {}
        self.step_handlers = {}
        self.perf_runners = {}

    def perf(self, name, fn=None, description=""):
        """Перф-сценарий проекта для `lab perf <project> <name>` (этап 3а): fn(px, args) -> dict. Ядро до вызова ждёт
        простоя ПК, во время — пишет загрузку (sysload.Sampler), после — помечает contended и кладёт в историю.
        px: lease(kind, params, clock="realtime") (аренда в прогоне, старт), out_dir, progress(line), cancelled(),
        own_pids(), ctx (FeatureCtx). Результат: {"ok", "summary_json": путь perf_summary.json, ...}."""
        def deco(f):
            self.perf_runners[name] = {"fn": f, "description": description or (f.__doc__ or "").strip()}
            return f
        return deco(fn) if fn is not None else deco

    def scenario(self, steps=None, **hooks):
        """Хуки интерпретатора сценариев (vclab/scenario/scenario.py) — всё, что знает про конкретную игру:
          start(sx)                       аренды и старт экземпляров сессии (по умолчанию — клиент вида impl)
          steps={"look": fn, ...}         шаги харнесса, которых нет в F2F: fn(sx, args, step) -> reply {ok, result}
          translate(sx, cmd, args)        аргументы F2F под реализацию (коды клавиш и т.п.) -> args
          after_step(sx, step, reply)     пост-обработка шага (досылка состояния, кадры перестройки) -> reply
          expect(sx, expect) -> [ошибки]  проверка поля expect шага
          timeline_setup(sx, setup)       шаги подготовки таймлайна из ключей setup, которых ядро не знает -> [step]
          info(scn) -> {world, ...}       ключи сценария для golden (мир, сервер) и для старта
          finish(sx) -> dict              итог сессии (статус клиента и т.п.)
          server_step(sx, tick)           lockstep: шаг сервера после каждого такта клиента (server: {f2f: true})
          lockstep_tick(sx, tick) -> reply  lockstep: весь такт (барьер, клиент, server_step); tick = {cmd: step|gui,
                                          args, gui?, k?, n?, tick?}; нет хука — f2f step + server_step
          lockstep_run(sx, cmd, args, step) lockstep: забрать команду сценария (step, wait, connect, mode, input...)
                                          -> reply или None (обычный путь)
          compare_state(a, b)             сравнение дампов state по категориям -> {cat: (equal, detail)}
          stop(sx)                        перед освобождением аренд"""
        bad = set(hooks) - set(SCENARIO_HOOKS)
        if bad:
            raise ValueError("unknown scenario hooks %s (known: %s)" % (sorted(bad), ", ".join(SCENARIO_HOOKS)))
        self.scenario_hooks.update(hooks)
        self.step_handlers.update(steps or {})

    def feature(self, name, fn=None, description="", schema=None, mcp=False):
        full = name if "." in name else "%s.%s" % (self.project, name)

        def deco(f):
            self.features[full] = Feature(full, f, description or (f.__doc__ or "").strip(), schema, mcp,
                                          self.project, self.version)
            return f
        return deco(fn) if fn is not None else deco


class Project:
    def __init__(self, path):
        self.path = path
        self.dir = os.path.dirname(path)
        with open(path, "rb") as f:
            raw = tomllib.load(f)
        meta = raw.get("project", {})
        self.name = meta.get("name") or os.path.basename(self.dir)
        self.description = meta.get("description", "")
        self.raw = raw
        self.meta = meta
        self.kinds = raw.get("kinds", {})
        if not self.kinds:
            raise ValueError("%s: no [kinds.*]" % path)
        for k, spec in self.kinds.items():
            bad = set(spec) - KIND_KEYS
            if bad:
                raise ValueError("%s: kind %s: unknown keys %s" % (path, k, sorted(bad)))
            if "exe" not in spec:
                raise ValueError("%s: kind %s: exe is required" % (path, k))
            for eid, ov in (spec.get("by_engine") or {}).items():
                if not isinstance(ov, dict):
                    raise ValueError("%s: kind %s: by_engine.%s must be a table" % (path, k, eid))
                bad = set(ov) - KIND_KEYS - {"by_engine"} | ({"by_engine"} & set(ov))
                if bad:
                    raise ValueError("%s: kind %s: by_engine.%s: unknown keys %s" % (path, k, eid, sorted(bad)))
        for k, spec in self.kinds.items():
            if spec.get("role", "test") not in ROLES:
                raise ValueError("%s: kind %s: role %r (allowed: %s)" % (path, k, spec.get("role"), ", ".join(ROLES)))
        # движки проекта (перекрывают/дополняют [engines.*] lab.toml); default — умолчание проекта
        eng = raw.get("engines", {}) or {}
        self.engines = {k: v for k, v in eng.items() if isinstance(v, dict)}
        self.default_engine = eng.get("default") if isinstance(eng.get("default"), str) else None
        self.compare = raw.get("compare", {})
        self.scenario = raw.get("scenario", {})
        self.golden = raw.get("golden", {})
        self.scenario_hooks = {}
        self.step_handlers = {}
        self.perf_runners = {}
        self.plugin_path = os.path.join(self.dir, meta["plugin"]) if meta.get("plugin") else None
        self.features = {}
        self.plugin_error = None
        self.plugin_version = None

    def dirs(self, base_ctx):
        out = {}
        for key in ("scenarios_dir", "golden_dir", "runs_dir", "golden_store"):
            if self.meta.get(key):
                out[key] = expand(self.meta[key], base_ctx)
        return out

    def info(self, base_ctx=None):
        d = {"name": self.name, "description": self.description, "descriptor": self.path,
             "kinds": {k: {"description": v.get("description", ""), "ports": v.get("ports", []),
                           "params": v.get("params", {}), "f2f": v.get("f2f"), "role": v.get("role", "test"),
                           "engine": v.get("engine")}
                       for k, v in self.kinds.items()},
             "engines": sorted(self.engines), "default_engine": self.default_engine,
             "compare": self.compare, "scenario": self.scenario, "golden": self.golden,
             "scenario_hooks": sorted(self.scenario_hooks), "step_handlers": sorted(self.step_handlers),
             "perf": sorted(self.perf_runners),
             "roles": {k: v.get("role", "test") for k, v in self.kinds.items()},
             "plugin": self.plugin_path, "plugin_version": self.plugin_version,
             "plugin_error": self.plugin_error, "features": sorted(self.features)}
        if base_ctx is not None:
            try:
                d.update(self.dirs(base_ctx))
            except TemplateError as exc:
                d["dirs_error"] = str(exc)
        return d

    def load_plugin(self, gen):
        if not self.plugin_path:
            return {}
        spec = importlib.util.spec_from_file_location("labplugin_%s_%d" % (self.name, gen), self.plugin_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        version = "%s@%s" % (self.name, getattr(mod, "PLUGIN_VERSION", int(os.path.getmtime(self.plugin_path))))
        api = PluginApi(self.name, version)
        mod.register(api)
        if hasattr(mod, "selftest"):
            mod.selftest()
        self.plugin_version = version
        self.scenario_hooks, self.step_handlers = api.scenario_hooks, api.step_handlers
        self.perf_runners = api.perf_runners
        return api.features


class Projects:
    def __init__(self, dirs, on_event=None):
        self.dirs = dirs
        self.projects = {}
        self.errors = {}
        self.generation = 0
        self.mtimes = {}
        self.lock = threading.RLock()
        self.on_event = on_event or (lambda *a, **k: None)
        self.core_features = {}
        self.scan()

    def _files(self):
        out = []
        for d in self.dirs:
            if not os.path.isdir(d):
                continue
            for name in sorted(os.listdir(d)):
                if name.startswith("_"):          # projects/_template и т.п. — не проекты (новый репозиторий)
                    continue
                p = os.path.join(d, name, "project.toml")
                if os.path.isfile(p):
                    out.append(p)
        return out

    def _stamp(self, path):
        st = [os.path.getmtime(path)]
        plug = os.path.join(os.path.dirname(path), "plugin.py")
        if os.path.exists(plug):
            st.append(os.path.getmtime(plug))
        return tuple(st)

    def scan(self):
        """Загрузить новые/изменённые проекты. True, если что-то поменялось."""
        changed = False
        with self.lock:
            seen = set()
            for path in self._files():
                seen.add(path)
                stamp = self._stamp(path)
                if self.mtimes.get(path) == stamp:
                    continue
                self.mtimes[path] = stamp
                try:
                    proj = Project(path)
                    try:
                        proj.features = proj.load_plugin(self.generation + 1)
                    except Exception:
                        proj.plugin_error = traceback.format_exc(limit=6)
                        old = self.projects.get(proj.name)
                        if old is not None:
                            proj.features = old.features    # прежняя рабочая версия остаётся
                            proj.plugin_version = old.plugin_version
                            proj.scenario_hooks, proj.step_handlers = old.scenario_hooks, old.step_handlers
                            proj.perf_runners = old.perf_runners
                        self.on_event("plugin_load_failed", proj.name, proj.plugin_error)
                    self.projects[proj.name] = proj
                    self.errors.pop(path, None)
                    changed = True
                    self.on_event("project_loaded", proj.name, proj.plugin_version)
                except Exception:
                    self.errors[path] = traceback.format_exc(limit=4)
                    self.on_event("project_load_failed", path, self.errors[path])
                    changed = True
            for name, proj in list(self.projects.items()):
                if proj.path not in seen:
                    del self.projects[name]
                    self.mtimes.pop(proj.path, None)
                    changed = True
            if changed:
                self.generation += 1
        return changed

    def get(self, name):
        with self.lock:
            p = self.projects.get(name)
        if p is None:
            raise KeyError("unknown project %r (have: %s)" % (name, ", ".join(sorted(self.projects))))
        return p

    def features(self):
        with self.lock:
            out = dict(self.core_features)
            for p in self.projects.values():
                out.update(p.features)
            return out
