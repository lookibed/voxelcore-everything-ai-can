"""Зеркало перезаписываемых логов (VC_ROOT\\latest.log): движок пересоздаёт файл при каждом старте, и лог прошлой
сессии терялся (01.10, сессия 00:51). Поток раз в секунду смотрит первую строку и размер: та же первая строка —
дописать прирост в текущий архив; другая — новый архив data\\logs\\<имя>\\<время>.log. Ловит и чужие старты
(vc_start старого MCP, пользователь руками). Состояние — data\\state\\watch_<имя>.json (рестарт демона продолжает)."""
import json
import os
import threading
import time


class LogMirror:
    def __init__(self, name, path, data_dir, on_new=None, every=1.0):
        self.name, self.path = name, path
        self.out_dir = os.path.join(data_dir, "logs", name)
        self.state_path = os.path.join(data_dir, "state", "watch_%s.json" % name)
        self.on_new = on_new
        self.every = every
        self.st = {"first": None, "archive": None, "offset": 0}
        try:
            with open(self.state_path, encoding="utf-8") as f:
                self.st.update(json.load(f))
        except (OSError, ValueError):
            pass
        self._stop = False
        self.thread = threading.Thread(target=self._loop, name="watch-" + name, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self._stop = True

    def _save(self):
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        tmp = self.state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.st, f)
        os.replace(tmp, self.state_path)

    def poll(self):
        try:
            size = os.path.getsize(self.path)
            with open(self.path, "rb") as f:
                first = f.readline(400)
                if not first.endswith(b"\n"):
                    return None      # первая строка ещё пишется
                first_s = first.decode("utf-8", "replace").rstrip()
                new = first_s != self.st["first"] or size < self.st["offset"] or not self.st["archive"]
                if new:
                    os.makedirs(self.out_dir, exist_ok=True)
                    stamp = time.strftime("%Y%m%d_%H%M%S", time.localtime(os.path.getmtime(self.path)))
                    arch, n = os.path.join(self.out_dir, stamp + ".log"), 2
                    while os.path.exists(arch):
                        arch, n = os.path.join(self.out_dir, "%s_%d.log" % (stamp, n)), n + 1
                    self.st = {"first": first_s, "archive": arch, "offset": 0}
                if size > self.st["offset"]:
                    f.seek(self.st["offset"])
                    data = f.read(size - self.st["offset"])
                    with open(self.st["archive"], "ab") as out:
                        out.write(data)
                    self.st["offset"] += len(data)
                    self._save()
                if new:
                    self._save()
                    if self.on_new:
                        self.on_new(self.name, self.st["archive"], first_s)
                return new
        except OSError:
            return None

    def _loop(self):
        while not self._stop:
            self.poll()
            time.sleep(self.every)

    def info(self):
        return {"name": self.name, "path": self.path, **self.st}
