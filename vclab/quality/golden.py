"""Golden с манифестом и CAS (этап 2): <golden_dir>\\<сценарий>\\golden.json + копии PNG рядом (как раньше) + хранилище
по содержимому <golden_store>\\sha256\\ab\\<sha256 файла>.png (история: прежние снимки не теряются при promote).

Манифест (schema 1):
  name, project, impl, size, kind (steps|timeline)
  key        входы, от которых зависит эталон: scenario {name, sha256, chain[{name, file, sha256}]}, size, seed, impl,
             harness, inputs {имя: {kind file|tree, path, sha256|sha1}} — список входов задаёт проект ([golden].inputs:
             мир, патчи Java, jar/bin сервера, exe движка для vc, пак...), с подстановкой {info.world} и т.п.
  provenance {поле: recorded | backfilled | unknown: <почему>} — для импортированных эталонов честно: recorded — записано
             при съёмке; backfilled — значение взято при импорте, вход старше эталона (не менялся после съёмки);
             unknown — вход менялся после съёмки или его нечем проверить.
  produced   {run, date, owner, source: lab|import|regen, reason, runner}
  shots      {имя: {file, sha256_file, sha256_rgb, w, h, cas, approved:[sha256_rgb...]}}
  noise      {runs, shots: {имя: {sha: n}}, kf: {такт: min identical %}} — шум эталона J/J (regen)
Свежесть (status): ключ пересчитывается из текущих файлов; отличие записанного/backfilled поля -> stale (с причиной),
unknown -> в списке unverified; файл снимка не совпал с манифестом -> modified."""
import hashlib
import json
import os
import shutil
import time

from vclab import config
from vclab.scenario.scenario import HARNESS, ScenarioError, load as load_scenario, sha256_file

SCHEMA = 1
_TREE_CACHE = {}


# ---------------------------------------------------------------------------------------------- хэши входов
def hash_file(path, algo="sha256"):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _walk(path):
    out = []
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for fn in sorted(files):
            p = os.path.join(root, fn)
            try:
                st = os.stat(p)
            except OSError:
                continue
            out.append((os.path.relpath(p, path).replace("\\", "/"), p, st.st_size, st.st_mtime_ns))
    return out


def hash_tree(path, exclude=("session.lock",)):
    """sha256 по отсортированным строкам «путь sha256(содержимого)» (без session.lock); кэш по (размеры, mtime)."""
    files = [f for f in _walk(path) if os.path.basename(f[0]) not in exclude]
    sig = (os.path.normcase(path), len(files), sum(f[2] for f in files), max([f[3] for f in files] or [0]))
    if sig in _TREE_CACHE:
        return _TREE_CACHE[sig]
    h = hashlib.sha256()
    for rel, p, size, _ in files:
        h.update(("%s %s\n" % (rel, hash_file(p))).encode("utf-8"))
    res = {"sha256": h.hexdigest(), "files": len(files), "bytes": sum(f[2] for f in files),
           "newest": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(max([f[3] for f in files] or [0]) / 1e9))}
    _TREE_CACHE[sig] = res
    return res


def newest_mtime(path):
    if os.path.isfile(path):
        return os.path.getmtime(path)
    return max([f[3] for f in _walk(path)] or [0]) / 1e9


def _ctx(lab, proj, info, impl):
    from vclab.projects import expand
    ctx = lab.base_ctx()
    ctx["project_dir"] = proj.dir
    ctx.update(proj.dirs(dict(ctx)))
    ctx["info"] = dict(info or {})
    ctx["impl"] = impl
    return ctx, expand


def compute_inputs(lab, proj, impl, info):
    ctx, expand = _ctx(lab, proj, info, impl)
    out = {}
    for spec in (proj.golden or {}).get("inputs", []):
        if spec.get("impls") and impl not in spec["impls"]:
            continue
        name = spec["name"]
        try:
            path = expand(spec.get("file") or spec.get("tree"), ctx)
        except KeyError as exc:
            out[name] = {"error": "template: %s" % exc}
            continue
        algo = spec.get("hash", "sha256")
        if spec.get("file"):
            if os.path.isfile(path):
                out[name] = {"kind": "file", "path": path, algo: hash_file(path, algo),
                             "mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(path)))}
            else:
                out[name] = {"kind": "file", "path": path, "missing": True}
        else:
            if os.path.isdir(path):
                t = hash_tree(path)
                out[name] = {"kind": "tree", "path": path, "sha256": t["sha256"], "files": t["files"],
                             "newest": t["newest"]}
            else:
                out[name] = {"kind": "tree", "path": path, "missing": True}
        if spec.get("optional") and out[name].get("missing"):
            out[name] = {"kind": out[name]["kind"], "path": path, "absent": True}
    return out


def compute_key(lab, proj, scn, impl, info, lockstep=None):
    """lockstep: режим сервера прогона (None — как объявлено сценарием/умолчанием проекта); поле ключа server =
    lockstep | realtime (этап 3б: golden снимаются на пошаговом сервере, дымовой прогон в реальном времени — другой ключ)."""
    mode_defaults = (proj.scenario or {}).get("timeline_mode")
    if lockstep is None:
        from vclab.scenario.scenario import set_lockstep_default
        set_lockstep_default(scn, proj)
        lockstep = scn.lockstep
    key = {"scenario": {"name": scn.name, "sha256": scn.sha256, "chain": scn.chain}, "size": scn.size,
           "seed": scn.seed(mode_defaults), "impl": impl, "harness": HARNESS,
           "server": "lockstep" if lockstep else "realtime", "info": dict(info or {}),
           "inputs": compute_inputs(lab, proj, impl, info)}
    key["id"] = key_id(key)
    return key


def key_id(key):
    """Короткий id ключа (16 hex): равные входы — равный id (история/ворота группируют прогоны по нему)."""
    return hashlib.sha256(json.dumps(key_fields(key), sort_keys=True, default=str).encode("utf-8")).hexdigest()[:16]


def _hval(d):
    """Значимая часть входа для сравнения."""
    if not isinstance(d, dict):
        return d
    for k in ("sha256", "sha1"):
        if k in d:
            return d[k]
    if d.get("absent"):
        return "absent"
    if d.get("missing"):
        return "missing"
    return json.dumps(d, sort_keys=True)


def key_fields(key):
    """Плоский вид ключа: {поле: значение для сравнения}."""
    out = {"scenario": (key.get("scenario") or {}).get("sha256")}
    for c in (key.get("scenario") or {}).get("chain", [])[1:]:
        out["scenario.base." + c["name"]] = c.get("sha256")
    for k in ("size", "seed", "impl", "harness", "server"):
        if k == "server" and "server" not in key:
            continue          # ключи до этапа 3б (поле не записано): не «изменилось», а неизвестно
        out[k] = key.get(k)
    for k, v in (key.get("info") or {}).items():
        out["info." + k] = v
    for k, v in (key.get("inputs") or {}).items():
        out["inputs." + k] = _hval(v)
    return out


# ---------------------------------------------------------------------------------------------- хранилище
class Store:
    def __init__(self, root):
        self.root = root

    def put(self, path):
        sha = sha256_file(path)
        ext = os.path.splitext(path)[1] or ".bin"
        rel = os.path.join("sha256", sha[:2], sha + ext)
        dst = os.path.join(self.root, rel)
        if not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            tmp = dst + ".tmp%d" % os.getpid()
            shutil.copyfile(path, tmp)
            os.replace(tmp, dst)
        return sha, rel.replace("\\", "/")

    def path(self, rel):
        return os.path.join(self.root, rel)


class Golden:
    def __init__(self, lab):
        self.lab = lab

    def proj(self, project):
        return self.lab.projects.get(project)

    def dirs(self, proj):
        d = proj.dirs(dict(self.lab.base_ctx(), project_dir=proj.dir))
        gd = d.get("golden_dir")
        if not gd:
            raise ScenarioError("project %s has no golden_dir" % proj.name)
        store = d.get("golden_store") or (proj.golden or {}).get("store")
        if store and "{" in store:
            from vclab.projects import expand
            store = expand(store, dict(self.lab.base_ctx(), project_dir=proj.dir, **d))
        return gd, Store(store or os.path.join(os.path.dirname(gd.rstrip("\\/")), "lab", "store"))

    def manifest(self, proj, name):
        gd, _ = self.dirs(proj)
        p = os.path.join(gd, name, "golden.json")
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def _write_manifest(self, d, man):
        tmp = os.path.join(d, "golden.json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(man, f, ensure_ascii=False, indent=1, default=str)
        os.replace(tmp, os.path.join(d, "golden.json"))

    def _history(self, d, entry):
        with open(os.path.join(d, "golden.history.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")

    @staticmethod
    def shot_dirs(gd):
        out = []
        for n in sorted(os.listdir(gd)) if os.path.isdir(gd) else []:
            d = os.path.join(gd, n)
            if os.path.isdir(d) and any(f.endswith(".png") for f in os.listdir(d)):
                out.append(n)
        return out

    # ---- status
    def status(self, project, names=None):
        proj = self.proj(project)
        gd, _ = self.dirs(proj)
        names = names or self.shot_dirs(gd)
        rows = []
        for n in names:
            rows.append(self.status_one(proj, n))
        counts = {}
        for r in rows:
            counts[r["state"]] = counts.get(r["state"], 0) + 1
        return {"ok": True, "project": project, "golden_dir": gd, "counts": counts, "goldens": rows}

    def status_one(self, proj, name):
        gd, _ = self.dirs(proj)
        d = os.path.join(gd, name)
        man = self.manifest(proj, name)
        if man is None:
            return {"name": name, "state": "no-manifest", "reasons": ["no golden.json (lab golden import)"]}
        reasons, unverified, modified = [], [], []
        for sn, s in (man.get("shots") or {}).items():
            p = os.path.join(d, s.get("file") or sn + ".png")
            if not os.path.exists(p):
                modified.append("%s: file missing" % sn)
            elif s.get("sha256_file") and sha256_file(p) != s["sha256_file"]:
                modified.append("%s: file differs from manifest" % sn)
        try:
            dirs = self.lab.scen.scen_dirs(proj)
            size = (proj.scenario or {}).get("default_size") or "854x480"
            scn = load_scenario(dirs, name, size)
        except ScenarioError as exc:
            return {"name": name, "state": "stale", "reasons": ["scenario: %s" % exc], "impl": man.get("impl")}
        info = man.get("key", {}).get("info") or {}
        hook = proj.scenario_hooks.get("info")
        if hook:
            try:
                info = hook(scn) or info
            except Exception:
                pass
        cur = key_fields(compute_key(self.lab, proj, scn, man.get("impl") or "java", info))
        old = key_fields(man.get("key") or {})
        prov = man.get("provenance") or {}
        for k, v in cur.items():
            p = prov.get(k, "recorded")
            if str(p).startswith("unknown"):
                unverified.append("%s (%s)" % (k, p))
                continue
            if k not in old:
                unverified.append("%s (not in manifest)" % k)
                continue
            if old[k] != v:
                reasons.append("%s changed: %s -> %s" % (k, _short(old[k]), _short(v)))
        for k in old:
            if k not in cur and not str(prov.get(k, "")).startswith("unknown"):
                reasons.append("%s no longer an input" % k)
        # fresh — все входы ключа известны и равны; unverified — отличий не видно, но часть входов неизвестного
        # происхождения (импорт старых эталонов); stale — что-то известное изменилось
        state = "stale" if reasons or modified else ("unverified" if unverified else "fresh")
        return {"name": name, "state": state, "reasons": reasons + modified, "unverified": unverified,
                "impl": man.get("impl"), "size": man.get("size"), "shots": len(man.get("shots") or {}),
                "produced": man.get("produced"), "noise": bool(man.get("noise"))}

    # ---- import of the existing goldens
    def import_existing(self, project, names=None, owner=None, overwrite=False):
        proj = self.proj(project)
        gd, store = self.dirs(proj)
        out = []
        for n in names or self.shot_dirs(gd):
            if self.manifest(proj, n) and not overwrite:
                out.append({"name": n, "skipped": "has golden.json"})
                continue
            try:
                out.append(self._import_one(proj, gd, store, n, owner))
            except Exception as exc:
                out.append({"name": n, "error": "%s: %s" % (type(exc).__name__, exc)})
        return {"ok": True, "project": project, "store": store.root, "imported": out}

    def _import_one(self, proj, gd, store, name, owner):
        from vclab.quality import compare as C
        d = os.path.join(gd, name)
        rep = _json(os.path.join(d, "report.json"))
        runj = _json(os.path.join(d, "run.json"))
        src = rep or runj or {}
        runner = ("run.json (e2e_run.py)" if runj else ("report.json (am_scenario/am_layers: window)" if rep and "window"
                                                       in rep else ("report.json (run_vc_scenario/run_u)" if rep
                                                                    else "none")))
        recorded = {}
        for s in src.get("shots") or []:
            k = s.get("name") or (os.path.splitext(s.get("file", ""))[0] if s.get("file") else None)
            if k:
                recorded[k] = s.get("sha256")
        shots, notes = {}, []
        sizes = set()
        pngs = sorted(f for f in os.listdir(d) if f.endswith(".png") and not f.endswith(("_diff.png", "_heat.png")))
        mt = []
        for fn in pngs:
            p = os.path.join(d, fn)
            k = fn[:-4]
            img = C.load_rgb(p)
            h, w = img.shape[:2]
            sizes.add("%dx%d" % (w, h))
            rgb = hashlib.sha256(img.astype("uint8").tobytes()).hexdigest()
            fsha, rel = store.put(p)
            shots[k] = {"file": fn, "sha256_file": fsha, "sha256_rgb": rgb, "w": w, "h": h, "cas": rel,
                        "approved": [rgb]}
            if recorded.get(k) and recorded[k] != rgb:
                shots[k]["recorded_sha256"] = recorded[k]
                notes.append("%s: PNG RGB sha differs from the runner's report (file replaced later?)" % k)
            elif k not in recorded:
                shots[k]["recorded_sha256"] = None
            mt.append(os.path.getmtime(p))
        produced_ts = min(mt) if mt else None
        started = src.get("started")
        prov = {}
        # сценарий: тот ли файл снял эталон
        size = (proj.scenario or {}).get("default_size") or "854x480"
        scn = None
        try:
            scn = load_scenario(self.lab.scen.scen_dirs(proj), name, size)
        except ScenarioError as exc:
            notes.append("scenario: %s" % exc)
            prov["scenario"] = "unknown: %s" % exc
        info = {}
        if scn is not None and proj.scenario_hooks.get("info"):
            try:
                info = proj.scenario_hooks["info"](scn) or {}
            except Exception:
                info = {}
        if src.get("world"):
            info = dict(info, world=src["world"])
            prov["info.world"] = "recorded"
        impl = src.get("impl") or "java"
        key = compute_key(self.lab, proj, scn, impl, info) if scn else {"inputs": {}, "info": info}
        if scn is not None:
            match, why = _scenario_matches(scn, d, src)
            prov["scenario"] = "backfilled: %s" % why if match else "unknown: %s" % why
            for c in scn.chain[1:]:
                prov["scenario.base." + c["name"]] = prov["scenario"]
            if not match:
                key["scenario"]["sha256"] = None
        key["size"] = sorted(sizes)[0] if len(sizes) == 1 else sorted(sizes)
        prov["size"] = "recorded (from the PNGs)"
        seed = _seed_from_report(src)
        if seed is not None:
            key["seed"] = seed
            prov["seed"] = "recorded (mode step of the runner's report)"
        else:
            prov["seed"] = "backfilled: from the scenario file" if key.get("seed") is not None else "unknown"
        prov["impl"] = "recorded" if src.get("impl") else "unknown: assumed java"
        for k, v in (key.get("info") or {}).items():
            prov.setdefault("info." + k, "backfilled: from the scenario (plugin info)")
        for k, v in (key.get("inputs") or {}).items():
            path = v.get("path")
            if v.get("absent"):
                prov["inputs." + k] = "backfilled: absent now; assumed absent then"
                continue
            if not path or v.get("missing"):
                prov["inputs." + k] = "unknown: input missing now"
                continue
            nm = newest_mtime(path)
            if produced_ts and nm and nm <= produced_ts:
                prov["inputs." + k] = "backfilled: input older than the golden (%s <= %s)" % (
                    _ts(nm), _ts(produced_ts))
            else:
                prov["inputs." + k] = "unknown: input changed after the golden (%s > %s)" % (
                    _ts(nm), _ts(produced_ts) if produced_ts else "?")
                v["at_import"] = True
        key["harness"] = None
        prov["harness"] = "unknown: legacy runner (%s)" % runner
        noise = None
        rn = _json(os.path.join(d, "reference_noise.json"))
        if rn:
            noise = {"source": "reference_noise.json (e2e_compare Java vs Java)",
                     "kf": {str(r["tick"]): r.get("identical_pct") for r in rn.get("keyframes", []) if "tick" in r},
                     "summary": rn.get("summary")}
        extra_files = {}
        for fn in ("states.jsonl", "scenario.json", "reference_noise.json", "report.json", "run.json"):
            p = os.path.join(d, fn)
            if os.path.exists(p):
                fsha, rel = store.put(p)
                extra_files[fn] = {"sha256_file": fsha, "cas": rel}
        man = {"schema": SCHEMA, "name": name, "project": proj.name, "impl": impl, "size": key["size"],
               "kind": "timeline" if any(k.startswith("kf_") for k in shots) else "steps",
               "key": key, "provenance": prov,
               "produced": {"source": "import", "runner": runner, "run": src.get("started") or None,
                            "date": _ts(produced_ts) if produced_ts else None, "started": started,
                            "promoted_from": (runj or {}).get("promoted_from"),
                            "imported": time.strftime("%Y-%m-%d %H:%M:%S"), "imported_by": owner},
               "shots": shots, "files": extra_files, "noise": noise, "notes": notes}
        self._write_manifest(d, man)
        self._history(d, {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "action": "import", "by": owner,
                          "shots": {k: v["sha256_rgb"] for k, v in shots.items()}})
        return {"name": name, "shots": len(shots), "impl": impl, "size": man["size"], "scenario": prov.get("scenario"),
                "unknown": sorted(k for k, v in prov.items() if str(v).startswith("unknown")), "notes": notes}

    # ---- promote
    def promote(self, run_id, reason, owner=None, scenarios=None, force=False, noise=None, source="lab"):
        from vclab.quality import compare as C
        if not reason:
            raise ScenarioError("promote needs a reason")
        run = self.lab.runs.get(run_id)
        if run is None:
            raise ScenarioError("no run %s" % run_id)
        rep = _json(os.path.join(run["dir"], "report.json")) or run
        sc = rep.get("scenario") or {}
        if not sc.get("results"):
            raise ScenarioError("run %s has no scenario results (not a lab run)" % run_id)
        proj = self.proj(rep.get("project") or sc.get("project"))
        gd, store = self.dirs(proj)
        out = []
        for r in sc["results"]:
            if scenarios and r["scenario"] not in scenarios:
                continue
            if not r.get("ok") and not force:
                out.append({"name": r["scenario"], "error": "run not ok (force=true to promote anyway)"})
                continue
            d = os.path.join(gd, r["scenario"])
            os.makedirs(d, exist_ok=True)
            old = self.manifest(proj, r["scenario"])
            stamp = time.strftime("%Y%m%d_%H%M%S")
            hist = os.path.join(d, ".history", stamp)
            moved = []
            # прежнее содержимое: снимки — в CAS (если их там нет), служебные файлы — в .history\<время>\
            for fn in sorted(os.listdir(d)):
                p = os.path.join(d, fn)
                if not os.path.isfile(p) or fn == "golden.history.jsonl":
                    continue
                if fn.endswith(".png") or fn in ("golden.json", "states.jsonl", "scenario.json", "report.json",
                                                 "run.json", "reference_noise.json"):
                    if fn.endswith(".png"):
                        store.put(p)
                    os.makedirs(hist, exist_ok=True)
                    shutil.move(p, os.path.join(hist, fn)) if not fn.endswith(".png") else os.remove(p)
                    moved.append(fn)
            shots = {}
            for s in r.get("shots") or []:
                src = os.path.join(run["dir"], s["file"])
                fn = s["name"] + ".png"
                shutil.copyfile(src, os.path.join(d, fn))
                fsha, rel = store.put(src)
                approved = [s.get("sha256")]
                if noise and noise.get("shots", {}).get(s["name"]):
                    approved = sorted(noise["shots"][s["name"]], key=lambda k: -noise["shots"][s["name"]][k])
                rgb = s.get("sha256_rgb") or C.rgb_sha(src)
                approved = [rgb] if approved == [s.get("sha256")] else approved
                shots[s["name"]] = {"file": fn, "sha256_file": fsha, "sha256_rgb": rgb, "w": s.get("w"),
                                    "h": s.get("h"), "tick": s.get("tick"), "cas": rel, "approved": approved}
            files = {}
            od = os.path.join(run["dir"], r.get("out") or os.path.join("shots", r["scenario"]))
            for fn in ("states.jsonl", "scenario.json"):
                p = os.path.join(od, fn)
                if os.path.exists(p) and (fn != "states.jsonl" or r.get("kind") == "timeline"):
                    shutil.copyfile(p, os.path.join(d, fn))
                    fsha, rel = store.put(p)
                    files[fn] = {"sha256_file": fsha, "cas": rel}
            key = dict(sc.get("inputs") or {})
            if key.get("scenario", {}).get("name") != r["scenario"]:
                # многосценарный прогон: ключ сценария — свой (входы те же)
                key = dict(key, scenario={"name": r["scenario"], "sha256": r.get("sha256"), "chain": r.get("chain")})
            man = {"schema": SCHEMA, "name": r["scenario"], "project": proj.name, "impl": sc.get("impl"),
                   "size": r.get("size") or sc.get("size"), "kind": r.get("kind"), "key": key,
                   "provenance": {k: "recorded" for k in key_fields(key)},
                   "produced": {"source": source, "run": run_id, "run_dir": run["dir"], "owner": rep.get("owner"),
                                "date": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(rep.get("opened") or
                                                                                          time.time())),
                                "promoted": time.strftime("%Y-%m-%d %H:%M:%S"), "promoted_by": owner,
                                "reason": reason, "harness": sc.get("harness"), "exe": sc.get("exe")},
                   "shots": shots, "files": files, "noise": noise, "notes": []}
            if noise and noise.get("reference_noise"):
                with open(os.path.join(d, "reference_noise.json"), "w", encoding="utf-8") as f:
                    json.dump(noise["reference_noise"], f, ensure_ascii=False, indent=1)
                man["noise"] = {k: v for k, v in noise.items() if k != "reference_noise"}
            self._write_manifest(d, man)
            self._history(d, {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "action": "promote", "by": owner,
                              "reason": reason, "run": run_id, "previous": (old or {}).get("produced"),
                              "previous_shots": {k: v.get("sha256_rgb") for k, v in ((old or {}).get("shots") or
                                                                                    {}).items()},
                              "previous_files_dir": hist if moved else None,
                              "shots": {k: v["sha256_rgb"] for k, v in shots.items()}})
            out.append({"name": r["scenario"], "dir": d, "shots": len(shots), "replaced": bool(old) or bool(moved)})
        return {"ok": all("error" not in o for o in out), "run": run_id, "promoted": out}


    # ---- regen: N прогонов Java, J/J-сверка, promote
    def regen(self, project, name, runs=3, owner=None, reason=None, impl="java", job=None, strict=False):
        from vclab.quality import compare as C
        log = (lambda line: self.lab.scen.progress(job, line)) if job else (lambda line: None)
        done = []
        for i in range(int(runs)):
            log("regen %s: run %d/%d (%s)" % (name, i + 1, runs, impl))
            r = self.lab.scen.start(project, [name], impl, owner, opts={"tag": "regen"}, wait=True)
            done.append(r)
            if job is not None:
                job.setdefault("runs", []).append(r["run"])
            log("regen %s: run %d -> %s (%s)" % (name, i + 1, r.get("verdict"), r["run"]))
            if r.get("verdict") != "ok":
                return {"ok": False, "error": "run %d failed: %s" % (i + 1, (r.get("report") or {}).get("error")),
                        "runs": [x["run"] for x in done]}
        reps = [_json(os.path.join(x["dir"], "report.json")) or {} for x in done]
        per = {}
        for i, rp in enumerate(reps):
            res = ((rp.get("scenario") or {}).get("results") or [{}])[0]
            for s in res.get("shots") or []:
                per.setdefault(s["name"], {}).setdefault(s.get("sha256_rgb") or s.get("sha256"), []).append(i)
        noisy = {k: {sha: len(v) for sha, v in d.items()} for k, d in per.items() if len(d) > 1}
        majority = {k: max(d, key=lambda sha: len(d[sha])) for k, d in per.items()}
        score = [sum(1 for k, d in per.items() for sha, idx in d.items() if i in idx and sha == majority[k])
                 for i in range(len(reps))]
        best = max(range(len(reps)), key=lambda i: (score[i], -i))
        summary = {"runs": [x["run"] for x in done], "shots": len(per), "noisy": sorted(noisy), "best_run": best,
                   "identical": not noisy}
        if not noisy:
            res = self.promote(done[0]["run"], "regen %d/%d identical%s" % (len(done), len(done),
                                                                            ": " + reason if reason else ""),
                               owner=owner, source="regen")
            return {"ok": res["ok"], "summary": summary, "promote": res}
        log("regen %s: noisy shots %s" % (name, ", ".join(sorted(noisy))))
        if strict:
            return {"ok": False, "error": "reference not repeatable (strict): %s" % sorted(noisy), "summary": summary}
        noise = {"runs": summary["runs"], "shots": noisy, "best_run": done[best]["run"]}
        others = [i for i in range(len(reps)) if i != best]
        if others and any(((r.get("scenario") or {}).get("results") or [{}])[0].get("kind") == "timeline"
                          for r in reps):
            proj = self.proj(project)
            A, B = C.run_source(done[best]["dir"]), C.run_source(done[others[0]]["dir"])
            cr = C.compare_sources(A, B, os.path.join(done[others[0]]["dir"], "vs_regen_best"),
                                   compare_state=proj.scenario_hooks.get("compare_state"),
                                   default_regions=(proj.compare or {}).get("regions"))
            se = (cr["scenarios"].get(name) or {}).get("series")
            if se:
                noise["kf"] = {str(r["tick"]): r.get("identical_pct") for r in se["keyframes"] if "tick" in r}
                noise["reference_noise"] = {"summary": se["summary"], "keyframes": [
                    {k: r.get(k) for k in ("tick", "identical_pct", "within_tol_pct")} for r in se["keyframes"]],
                    "states": se["states"]}
        res = self.promote(done[best]["run"], "regen %d runs, majority (noisy: %s)%s" % (
            len(done), ", ".join(sorted(noisy)), ": " + reason if reason else ""), owner=owner, noise=noise,
            source="regen")
        return {"ok": res["ok"], "summary": summary, "promote": res}


def _scenario_matches(scn, d, src):
    """Совпадает ли текущий файл сценария с тем, что снял эталон: e2e — scenario.json в каталоге golden; шаговые —
    команды/аргументы шагов в report.json раннера против prefix+body сценария."""
    sj = _json(os.path.join(d, "scenario.json"))
    if sj is not None:
        cur = dict(scn.raw)
        cur.setdefault("name", scn.name)
        a = {k: v for k, v in sj.items() if not k.startswith("_")}
        if json.dumps(a, sort_keys=True) == json.dumps(cur, sort_keys=True):
            return True, "scenario.json in the golden equals the current file"
        diff = sorted(k for k in set(a) | set(cur) if a.get(k) != cur.get(k))
        return False, "scenario.json in the golden differs from the current file in %s" % diff
    steps = [(s.get("cmd"), json.dumps(s.get("args") or {}, sort_keys=True)) for s in (src.get("steps") or [])]
    if not steps:
        return False, "no steps recorded by the runner"
    first = (src.get("steps") or [{}])[0].get("n", 0)
    allsteps = scn.prefix + scn.body
    want = [(s.get("cmd"), json.dumps(s.get("args") or {}, sort_keys=True)) for s in allsteps[first:first + len(steps)]]
    if steps == want and first + len(steps) == len(allsteps):
        return True, "the runner's %d recorded steps equal the current scenario (from step %d)" % (len(steps), first)
    for i, (a, b) in enumerate(zip(steps, want)):
        if a != b:
            return False, "recorded step %d (%s) differs from the current scenario (%s)" % (first + i, a[0], b[0])
    return False, "recorded %d steps from %d, scenario has %d" % (len(steps), first, len(allsteps))


def _seed_from_report(src):
    for s in src.get("steps") or []:
        if s.get("cmd") == "mode" and (s.get("args") or {}).get("seed") is not None:
            return s["args"]["seed"]
    return None


def _json(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _ts(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))


def _short(v):
    s = str(v)
    return s[:12] if len(s) > 16 and all(c in "0123456789abcdef" for c in s) else s[:60]
