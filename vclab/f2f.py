"""Пул постоянных F2F-соединений (f2f/PROTOCOL.md §1: TCP 127.0.0.1, одна строка JSON на запрос и ответ).

Ключ — имя аренды. Соединение держится между вызовами (установление дорого — ~0.7 с реле PowerShell в старом
пути, здесь ~1 мс). Обрыв — одна попытка переподключиться; таймаут — соединение сбрасывается (ответ мог прийти
позже и сбить нумерацию). Простой: если у аренды задан idle {cmd, every_s} — поток шлёт эту команду (keepalive
пака, у которого игровой сервер рвёт связь через 60 с тишины)."""
import json
import socket
import threading
import time


class F2FError(RuntimeError):
    pass


class F2FConn:
    def __init__(self, port, host="127.0.0.1"):
        self.addr = (host, int(port))
        self.sock = None
        self.buf = b""
        self.seq = 0
        self.lock = threading.RLock()
        self.last = time.time()
        self.idle = None        # {"cmd": "keepalive", "args": {}, "every_s": 1.0}
        self.calls = 0

    def connected(self):
        return self.sock is not None

    def connect(self, timeout=0.0, alive=None):
        end = time.time() + timeout
        while True:
            try:
                s = socket.create_connection(self.addr, timeout=5.0)
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                self.sock, self.buf = s, b""
                return
            except OSError:
                if alive is not None and not alive():
                    raise ConnectionRefusedError("process exited before F2F :%d accepted" % self.addr[1])
                if time.time() >= end:
                    raise
                time.sleep(0.1)

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock, self.buf = None, b""

    def _roundtrip(self, req, timeout):
        self.sock.settimeout(timeout)
        self.sock.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                raise ConnectionError("F2F connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        try:
            return json.loads(line.decode("utf-8"))
        except UnicodeDecodeError:
            # урок LESSONS «utf8 decode error»: what() Windows в cp1251 внутри JSON движка
            return json.loads(line.decode("cp1251", "replace"))

    def call(self, cmd, args=None, timeout=60.0, connect_timeout=0.0, alive=None, reconnect=True):
        with self.lock:
            if not reconnect and self.sock is None:
                raise ConnectionError("F2F not connected")
            self.seq += 1
            req = {"id": self.seq, "cmd": cmd, "args": args or {}}
            for attempt in (0, 1):
                if self.sock is None:
                    self.connect(connect_timeout, alive)
                try:
                    rep = self._roundtrip(req, timeout)
                    self.last = time.time()
                    self.calls += 1
                    return rep
                except socket.timeout:
                    self.close()
                    raise TimeoutError("F2F %s: no reply in %.1f s" % (cmd, timeout))
                except (ConnectionError, OSError):
                    self.close()
                    if attempt or cmd == "quit" or not reconnect:
                        if cmd == "quit":
                            return {"ok": True, "result": "connection closed"}
                        raise
                    if alive is not None and not alive():
                        raise


class F2FPool:
    def __init__(self):
        self.conns = {}
        self.lock = threading.Lock()
        self._stop = False
        threading.Thread(target=self._idle_loop, name="f2f-idle", daemon=True).start()

    def get(self, key, port):
        with self.lock:
            c = self.conns.get(key)
            if c is None or c.addr[1] != int(port):
                if c is not None:
                    c.close()
                c = F2FConn(port)
                self.conns[key] = c
            return c

    def drop(self, key):
        with self.lock:
            c = self.conns.pop(key, None)
        if c is not None:
            with c.lock:
                c.close()

    def close(self):
        self._stop = True
        with self.lock:
            keys = list(self.conns)
        for k in keys:
            self.drop(k)

    def status(self):
        with self.lock:
            return {k: {"port": c.addr[1], "connected": c.connected(), "calls": c.calls,
                        "idle_s": round(time.time() - c.last, 1), "keepalive": c.idle}
                    for k, c in self.conns.items()}

    def _idle_loop(self):
        while not self._stop:
            time.sleep(0.25)
            with self.lock:
                items = list(self.conns.values())
            for c in items:
                if not c.idle or not c.connected():
                    continue
                if time.time() - c.last < float(c.idle.get("every_s", 1.0)):
                    continue
                if not c.lock.acquire(blocking=False):
                    continue
                try:   # только по живому соединению: простой не должен переподключаться к чужому/новому процессу
                    c.call(c.idle.get("cmd", "keepalive"), c.idle.get("args"), timeout=5.0, reconnect=False)
                except Exception:
                    pass
                finally:
                    c.lock.release()
