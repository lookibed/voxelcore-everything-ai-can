#!/usr/bin/env python3
"""F2F client (agents/F2F.md): one JSON line per request / response over TCP 127.0.0.1.

Usable without MCP:
    from f2f_client import F2F
    c = F2F(25570)                       # Java client started with --f2f 25570
    c.hello(); c.step(ticks=20, frames=1); c.shot(r"<repo>\\projects\\alphamine\\external\\shots\\x.png")
Command line:
    python3 tools/alphamine/f2f_client.py 25570 hello
    python3 tools/alphamine/f2f_client.py 25570 step '{"ticks": 20}'
"""
import json
import os
import socket
import subprocess
import sys
import time

POWERSHELL = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
RELAY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "f2f_relay.ps1")


def in_wsl():
    try:
        with open("/proc/version") as f:
            return "microsoft" in f.read().lower() and os.path.exists(POWERSHELL)
    except OSError:
        return False


class F2FError(RuntimeError):
    def __init__(self, cmd, reply):
        self.cmd, self.reply = cmd, reply
        super().__init__("%s: %s (%s)" % (cmd, reply.get("error"), reply.get("where")))


class _Relay:
    """WSL -> powershell.exe f2f_relay.ps1 -> Windows 127.0.0.1:port (line in, line out)."""

    def __init__(self, port, connect_timeout):
        import threading
        win = subprocess.check_output(["wslpath", "-w", RELAY], text=True).strip()
        self.proc = subprocess.Popen(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", win,
             "-Port", str(port), "-ConnectTimeout", str(connect_timeout)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd="/mnt/c")
        self.lines = []
        self.cv = threading.Condition()
        threading.Thread(target=self._pump, daemon=True).start()
        first = self.readline(connect_timeout + 30)
        if first is None or not first.startswith("@@F2F connected"):
            self.close()
            raise ConnectionRefusedError("F2F relay to 127.0.0.1:%s: %s" % (port, first))

    def _pump(self):
        for raw in self.proc.stdout:
            with self.cv:
                self.lines.append(raw.decode("utf-8", "replace").rstrip("\r\n"))
                self.cv.notify_all()
        with self.cv:
            self.lines.append(None)
            self.cv.notify_all()

    def readline(self, timeout):
        end = time.time() + timeout
        with self.cv:
            while not self.lines:
                left = end - time.time()
                if left <= 0:
                    raise TimeoutError("no F2F reply in %.0f s" % timeout)
                self.cv.wait(left)
            return self.lines.pop(0)

    def send(self, line):
        self.proc.stdin.write((line + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


class F2F:
    def __init__(self, port=25570, host="127.0.0.1", timeout=120.0, connect_timeout=0.0, relay=None):
        """connect_timeout > 0: keep retrying the connection that long (client still starting).
        relay: None = auto (inside WSL go through powershell.exe, WSL cannot reach Windows 127.0.0.1)."""
        self.addr = (host, int(port))
        self.timeout = timeout
        self.seq = 0
        self.sock = None
        self.relay = None
        self.buf = b""
        self.use_relay = in_wsl() if relay is None else relay
        self.connect_timeout = connect_timeout
        if self.use_relay:
            self._connect()
            return
        end = time.time() + connect_timeout
        while True:
            try:
                self._connect()
                break
            except OSError:
                if time.time() >= end:
                    raise
                time.sleep(0.25)

    def _connect(self):
        if self.use_relay:
            self.relay = _Relay(self.addr[1], self.connect_timeout)
            return
        s = socket.create_connection(self.addr, timeout=5.0)
        s.settimeout(self.timeout)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock, self.buf = s, b""

    def connected(self):
        return self.relay is not None or self.sock is not None

    def close(self):
        if self.relay:
            self.relay.close()
            self.relay = None
        if self.sock:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def raw(self, cmd, args=None, timeout=None):
        """Send one command, return the full reply dict (ok/result/error)."""
        self.seq += 1
        req = {"id": self.seq, "cmd": cmd, "args": args or {}}
        if not self.connected():
            self._connect()
        if self.relay:
            self.relay.send(json.dumps(req))
            line = self.relay.readline(timeout or self.timeout)
            if line is None:
                self.close()
                raise ConnectionError("F2F connection closed during %s" % cmd)
            return json.loads(line)
        self.sock.settimeout(timeout or self.timeout)
        self.sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                self.close()
                raise ConnectionError("F2F connection closed during %s" % cmd)
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line.decode("utf-8"))

    def call(self, cmd, args=None, timeout=None):
        """Send one command, return result or raise F2FError."""
        rep = self.raw(cmd, args, timeout)
        if not rep.get("ok"):
            raise F2FError(cmd, rep)
        return rep.get("result")

    # convenience wrappers ------------------------------------------------
    def hello(self):
        return self.call("hello")

    def mode(self, seed=0, **kw):
        return self.call("mode", dict(fixed=True, seed=seed, **kw))

    def step(self, ticks=1, frames=1, partial=0.0):
        return self.call("step", {"ticks": ticks, "frames": frames, "partial": partial})

    def input(self, **kw):
        return self.call("input", kw)

    def state(self, radius=8):
        return self.call("state", {"radius": radius})

    def shot(self, path):
        return self.call("shot", {"path": path})

    def chat(self, text):
        return self.call("chat", {"text": text})

    def gui(self, **kw):
        return self.call("gui", kw)

    def wait(self, timeout=None, **cond):
        return self.call("wait", cond, timeout=timeout)

    def connect(self, host=None, port=None):
        a = {}
        if host:
            a["host"] = host
        if port:
            a["port"] = port
        return self.call("connect", a)

    def quit(self):
        try:
            return self.call("quit", timeout=10)
        except (ConnectionError, OSError):
            return None


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    c = F2F(int(argv[1]))
    args = json.loads(argv[3]) if len(argv) > 3 else {}
    print(json.dumps(c.raw(argv[2], args), ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
