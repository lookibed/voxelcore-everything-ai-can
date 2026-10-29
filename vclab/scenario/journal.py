"""Журнал действий лаборатории: JSONL в формате tools/mcp/journal.py (idx, t, ts, tool, args, session, parent, dur,
result, error, flags) + поля instance (аренда), run, agent (владелец), plugin (feature@версия).

Один писатель — демон: idx — счётчик в памяти (продолжает файл). Запись идёт в общий журнал data\\journal\\journal.jsonl
и в journal.jsonl каталога прогона, если вызов относится к прогону. Вложенные вызовы (F2F внутри возможности плагина)
получают parent (стек на поток)."""
import json
import os
import re
import threading
import time

TIMEOUT_RX = re.compile(r"timeout|timed out|no reply|не появился|не дождались", re.I)


class Journal:
    def __init__(self, path, slow_s=5.0):
        self.path = path
        self.slow_s = slow_s
        self.lock = threading.Lock()
        self.local = threading.local()
        self.session = "labd-%d-%d" % (os.getpid(), int(time.time()))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.idx = self._last_idx()

    def _last_idx(self):
        try:
            size = os.path.getsize(self.path)
            with open(self.path, "rb") as f:
                f.seek(max(0, size - 65536))
                lines = f.read().splitlines()
            for line in reversed(lines):
                try:
                    return int(json.loads(line)["idx"])
                except (ValueError, KeyError):
                    continue
        except OSError:
            pass
        return 0

    def _stack(self):
        st = getattr(self.local, "stack", None)
        if st is None:
            st = self.local.stack = []
        return st

    def begin(self, tool, args, instance=None, run=None, agent=None, plugin=None):
        with self.lock:
            self.idx += 1
            idx = self.idx
        t0 = time.time()
        st = self._stack()
        e = {"idx": idx, "t": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t0)) + ".%03d" % (t0 % 1 * 1000),
             "ts": round(t0, 3), "tool": tool, "args": args, "session": self.session}
        given = {"instance": instance, "run": run, "agent": agent, "plugin": plugin}
        if st:
            e["parent"] = st[-1]["idx"]
            for k in given:
                if given[k] is None and st[-1].get(k) is not None:
                    given[k] = st[-1][k]
        e.update({k: v for k, v in given.items() if v is not None})
        st.append(e)
        return e

    def end(self, e, result=None, error=False, run_dir=None, **extra):
        st = self._stack()
        if st and st[-1] is e:
            st.pop()
        dur = time.time() - e["ts"]
        e["dur"] = round(dur, 3)
        brief = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str)
        e["result"] = (brief or "")[:300]
        e["error"] = bool(error)
        flags = []
        if dur > self.slow_s and not e["tool"].endswith(("wait", "pump", "start")):
            flags.append("slow")
        if error and TIMEOUT_RX.search(e["result"]):
            flags.append("timeout")
        elif error:
            flags.append("error")
        e["flags"] = flags
        e.update({k: v for k, v in extra.items() if v is not None})
        self.write(e, run_dir)
        return e

    def event(self, tool, text, instance=None, run=None, agent=None, run_dir=None, error=False, **extra):
        e = self.begin(tool, extra.pop("args", {}), instance=instance, run=run, agent=agent)
        return self.end(e, text, error=error, run_dir=run_dir, **extra)

    def write(self, e, run_dir=None):
        line = json.dumps(e, ensure_ascii=False, default=str) + "\n"
        with self.lock:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(line)
            if run_dir:
                try:
                    with open(os.path.join(run_dir, "journal.jsonl"), "a", encoding="utf-8") as f:
                        f.write(line)
                except OSError:
                    pass

    def tail(self, last=30, instance=None, run=None, top_only=True):
        try:
            size = os.path.getsize(self.path)
            with open(self.path, "rb") as f:
                f.seek(max(0, size - 4 * 1024 * 1024))
                lines = f.read().splitlines()
        except OSError:
            return []
        out = []
        for line in reversed(lines):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if top_only and e.get("parent") is not None:
                continue
            if instance and e.get("instance") != instance:
                continue
            if run and e.get("run") != run:
                continue
            out.append(e)
            if len(out) >= last:
                break
        return list(reversed(out))
