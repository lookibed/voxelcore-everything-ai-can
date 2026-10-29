"""Olife UX A2 (03.10, olife_a2): protocol client for chat / operator command tests. Talks to the gateway exactly like a
game client (Hello with a token, KeepAlive replies, PlayerInput at 10/s) and keeps every chat-layer message:
ChatHistory, ChatLine, OpResult, Notice, ChatMessage, Disconnect. Used by the lab steps of tools/lab/projects/olife/
olife_a2.py (olife_chat: rate limit, late joiner history; olife_op: non-admin refusals, ban/unban).

  python chat_probe.py --gateway <port> --token olife-carol --name carol --say "hi" --say "/mobs" --seconds 2
"""
import argparse
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from olife_proto import client as C  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

KEEP = ("ChatHistory", "ChatLine", "OpResult", "Notice", "ChatMessage", "Disconnect", "Welcome", "EntityMeta",
        "RequestReply")


class ChatClient:
    def __init__(self, port, token, name, timeout=8.0, wait_welcome=True, src=None):
        # src: source address (antifraud tests: 127.0.0.2..254 — Windows routes all of 127/8 to the loopback)
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5,
                                          source_address=(src, 0) if src else None)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.fr = C.framer()
        self.name = name
        self.inbox = []            # (t, name, msg)
        self.welcome = None
        self.pos = None
        self.closed = None
        self.last_input = 0.0
        self.iseq = 0
        self.sent = []             # (t, text)
        import threading
        self.lock = threading.Lock()
        self.s.sendall(C.frame("Hello", {"proto": C.VERSION, "name": name, "token": token, "engine": "chat_probe"}))
        if wait_welcome:
            end = time.time() + timeout
            while self.welcome is None and time.time() < end and not self.closed:
                self.pump(0.2)
            if self.welcome is None and not self.closed:
                raise RuntimeError("%s: no Welcome" % name)
        else:
            self.pump(1.0)

    def send(self, name, msg):
        with self.lock:                      # the background pump sends inputs/keepalives from its thread
            self.s.sendall(C.frame(name, msg))

    def say(self, text):
        self.sent.append((time.time(), text))
        self.send("ChatSend", {"text": text})

    def background(self):
        """keep the session alive (KeepAlive, inputs) from a thread while the test does other things for many
        seconds; pump() of the caller then only waits"""
        import threading
        self.bg = True

        def loop():
            while self.bg and not self.closed:
                self._pump(0.2)
        threading.Thread(target=loop, daemon=True).start()
        return self

    def pump(self, seconds):
        if getattr(self, "bg", False):
            time.sleep(seconds)
            return
        self._pump(seconds)

    def _pump(self, seconds):
        end = time.time() + seconds
        self.s.settimeout(0.05)
        while time.time() < end and not self.closed:
            if self.welcome and time.time() - self.last_input >= 0.1:
                self.last_input = time.time()
                self.iseq += 1
                p = self.pos
                try:
                    self.send("PlayerInput", {"seq": self.iseq, "pos": {"x": p[0], "y": p[1], "z": p[2]},
                                              "rot": {"x": 0.0, "y": 0.0, "z": 0.0}})
                except OSError as exc:
                    self.closed = "send error %s" % exc
                    break
            try:
                d = self.s.recv(1 << 20)
            except socket.timeout:
                continue
            except OSError as exc:
                self.closed = "error %s" % exc
                break
            if not d:
                self.closed = self.closed or "eof"
                break
            self.fr.feed(d)
            while True:
                try:
                    x = self.fr.next()
                except ProtoError as exc:
                    self.closed = "proto %s" % exc
                    return
                if x is None:
                    break
                n = C.NAMES[x[0]]
                if n not in KEEP and n not in ("KeepAlive", "PlayerCorrect"):
                    continue
                m = C.decode_body(*x)
                if n == "Welcome":
                    self.welcome = m
                    self.pos = (m["spawn"]["x"], m["spawn"]["y"], m["spawn"]["z"])
                elif n == "KeepAlive":
                    self.send("KeepAliveReply", {"challenge": m["challenge"]})
                elif n == "PlayerCorrect":
                    self.pos = (m["pos"]["x"], m["pos"]["y"], m["pos"]["z"])
                if n in KEEP:
                    self.inbox.append((time.time(), n, m))
                    if n == "Disconnect":
                        self.closed = "disconnect %d %s" % (m["code"], m["reason"])

    def of(self, name):
        return [m for _, n, m in self.inbox if n == name]

    def lines(self):
        return [m["line"] for m in self.of("ChatLine")]

    def history(self):
        h = self.of("ChatHistory")
        return h[0] if h else None

    def result(self, cmd, after=0, timeout=3.0):
        """first OpResult for `cmd` arriving after inbox index `after`"""
        end = time.time() + timeout
        while time.time() < end:
            for t, n, m in self.inbox[after:]:
                if n == "OpResult" and m["cmd"] == cmd:
                    return m
            if self.closed:
                break
            self.pump(0.05)
        return None

    def command(self, text, timeout=3.0):
        k = len(self.inbox)
        self.say(text)
        cmd = text.lstrip("/").split()[0].lower() if text.strip("/ ") else ""
        return self.result(cmd, k, timeout)

    def disconnect_code(self):
        d = self.of("Disconnect")
        return d[-1]["code"] if d else None

    def close(self):
        self.bg = False
        try:
            self.send("Bye", {"reason": "chat_probe done"})
        except OSError:
            pass
        try:
            self.s.close()
        except OSError:
            pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", type=int, required=True)
    ap.add_argument("--token", default="olife-carol")
    ap.add_argument("--name", default="carol")
    ap.add_argument("--say", action="append", default=[])
    ap.add_argument("--seconds", type=float, default=2.0)
    a = ap.parse_args()
    c = ChatClient(a.gateway, a.token, a.name)
    for t in a.say:
        c.say(t)
        c.pump(0.2)
    c.pump(a.seconds)
    out = {k: c.of(k) for k in ("ChatHistory", "ChatLine", "OpResult", "Notice", "Disconnect")}
    print(json.dumps(out, ensure_ascii=False, indent=1, default=str))
    c.close()
