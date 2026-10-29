"""Каталоги прогонов: <runs_dir проекта>\\<YYYYmmdd_HHMMSS>_<проект>_<сценарий>\\ с journal.jsonl, logs\\, shots\\,
report.json. Индекс всех прогонов (append-only) — data\\runs_index.jsonl."""
import json
import os
import re
import threading
import time


def safe(name):
    return re.sub(r"[^\w.-]+", "_", str(name))[:60] or "run"


class Runs:
    def __init__(self, data_dir):
        self.index = os.path.join(data_dir, "runs_index.jsonl")
        self.default_dir = os.path.join(data_dir, "runs")
        self.active = {}
        self.lock = threading.Lock()

    def open(self, project, scenario, runs_dir=None, owner=None, meta=None):
        runs_dir = runs_dir or self.default_dir
        stamp = time.strftime("%Y%m%d_%H%M%S")
        base = "%s_%s_%s" % (stamp, safe(project), safe(scenario))
        rid, n = base, 2
        while os.path.exists(os.path.join(runs_dir, rid)) or rid in self.active:
            rid, n = "%s_%d" % (base, n), n + 1
        d = os.path.join(runs_dir, rid)
        os.makedirs(os.path.join(d, "logs"), exist_ok=True)
        os.makedirs(os.path.join(d, "shots"), exist_ok=True)
        run = {"id": rid, "project": project, "scenario": scenario, "dir": d, "owner": owner,
               "opened": time.time(), "closed": None, "leases": [], "shots": [], "events": [],
               "verdict": None, "meta": meta or {}}
        with self.lock:
            self.active[rid] = run
        self._write_report(run)
        self._append_index({"id": rid, "project": project, "scenario": scenario, "dir": d, "owner": owner,
                            "opened": run["opened"], "state": "open"})
        return run

    def get(self, rid):
        with self.lock:
            run = self.active.get(rid)
        if run:
            return run
        for e in reversed(self.list(500)):
            if e["id"] == rid:
                try:
                    with open(os.path.join(e["dir"], "report.json"), encoding="utf-8") as f:
                        return json.load(f)
                except (OSError, ValueError):
                    return e
        return None

    def add_shot(self, rid, shot):
        with self.lock:
            run = self.active.get(rid)
            if run:
                run["shots"].append(shot)
        if run:
            self._write_report(run)

    def add_event(self, rid, ev):
        with self.lock:
            run = self.active.get(rid)
            if run:
                run["events"].append(ev)
        if run:
            self._write_report(run)

    def close(self, rid, verdict=None, extra=None):
        with self.lock:
            run = self.active.pop(rid, None)
        if not run:
            return None
        run["closed"] = time.time()
        run["verdict"] = verdict or run.get("verdict") or "done"
        if extra:
            run.update(extra)
        self._write_report(run)
        name = run["scenario"]
        if not isinstance(name, str):       # этап 2а: поле scenario отчёта — полный отчёт интерпретатора, в индекс — имя
            name = "+".join(r.get("scenario", "?") for r in (name or {}).get("results") or []) or \
                ((run.get("meta") or {}).get("scenario") or {}).get("names") or "scenario"
            name = "+".join(name) if isinstance(name, list) else name
        self._append_index({"id": rid, "project": run["project"], "scenario": name, "dir": run["dir"],
                            "owner": run["owner"], "opened": run["opened"], "closed": run["closed"],
                            "verdict": run["verdict"], "shots": len(run["shots"]), "state": "closed"})
        return run

    def abort_open(self, verdict):
        """Прогоны, открытые прежним демоном (в индексе state=open, в памяти их нет): закрыть с вердиктом."""
        out = []
        for e in self.list(100000):
            if e.get("state") == "open" and e["id"] not in self.active:
                rep = os.path.join(e["dir"], "report.json")
                try:
                    with open(rep, encoding="utf-8") as f:
                        run = json.load(f)
                except (OSError, ValueError):
                    run = dict(e)
                    if not os.path.isdir(e["dir"]):
                        run = None
                if run is not None:
                    run.update(closed=time.time(), verdict=verdict)
                    try:
                        self._write_report(run)
                    except OSError:
                        pass
                self._append_index({"id": e["id"], "state": "closed", "verdict": verdict, "closed": time.time()})
                out.append(e["id"])
        return out

    def _write_report(self, run):
        tmp = os.path.join(run["dir"], "report.json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(run, f, ensure_ascii=False, indent=1, default=str)
        os.replace(tmp, os.path.join(run["dir"], "report.json"))

    def _append_index(self, e):
        os.makedirs(os.path.dirname(self.index), exist_ok=True)
        with self.lock:
            with open(self.index, "a", encoding="utf-8") as f:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")

    def list(self, last=30, project=None):
        latest = {}
        try:
            with open(self.index, encoding="utf-8") as f:
                for line in f:
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    latest[e["id"]] = {**latest.get(e["id"], {}), **e}
        except OSError:
            pass
        out = [e for e in latest.values() if not project or e.get("project") == project]
        out.sort(key=lambda e: e.get("opened", 0))
        return out[-last:]
