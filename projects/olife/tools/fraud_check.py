"""Olife antifraud probes (16.10, olife_antifraud; agents/research/OLIFE_ANTIFRAUD.md): everything a test needs to act
as players coming from DIFFERENT addresses on one Windows machine — Windows routes all of 127.0.0.0/8 to the loopback
and a server sees the source address the client bound (checked: 127.0.0.2 / 127.0.0.70 arrive as such). Tests use
127.0.0.2..254 only; 127.0.0.1 (the local player, lab bots, the menu client) and 127.0.0.0/24 as a whole are never
banned (the supervisor refuses bans covering the exempt networks without force).

  ticket(auth_url, gateway, name=None, token=None, src=None)    POST /ticket from `src` -> reply dict (+ _ms)
  login(gw_port, auth_url, gw_id, name, src)                    ticket by nick + ChatClient from `src`
  pre_hello(gw_port, src)                                       TCP from `src`, no Hello: the gateway's verdict
  Forward(listen_port, target_port, src)                        TCP relay 127.0.0.1:<listen> -> 127.0.0.1:<target> whose
                                                                outgoing side binds `src` (the engine menu client
                                                                thus reaches the auth service / gateway as `src`)
Lab steps: tools/lab/projects/olife/olife_fraud.py (scenarios olife_ipban, olife_antifraud)."""
import http.client
import json
import os
import socket
import ssl
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from olife_proto import client as C  # noqa: E402
from chat_probe import ChatClient  # noqa: E402


def _hostport(url):
    rest = url.split("://", 1)[1].rstrip("/")
    host, port = rest.rsplit(":", 1)
    return host, int(port.split("/")[0])


def ticket(auth_url, gateway, name=None, token=None, src=None, timeout=6.0):
    """plain (not sealed) ticket request from the source address `src` -> reply dict (+ _ms, http)"""
    host, port = _hostport(auth_url)
    body = {"gateway": gateway}
    if token:
        body["token"] = token
    else:
        body["name"] = name
    sa = (src, 0) if src else None
    if auth_url.startswith("https"):
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        c = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx, source_address=sa)
    else:
        c = http.client.HTTPConnection(host, port, timeout=timeout, source_address=sa)
    t0 = time.perf_counter()
    try:
        c.request("POST", "/ticket", json.dumps(body), {"Content-Type": "application/json"})
        r = c.getresponse()
        data = r.read().decode("utf-8") or "{}"
        rep = json.loads(data)
        rep["http"] = r.status
    finally:
        c.close()
    rep["_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    return rep


def login(gw_port, auth_url, gw_id, name, src, timeout=8.0):
    """-> (ChatClient | None, ticket reply). The client may be closed (Disconnect) — see .closed / disconnect_code()"""
    rep = ticket(auth_url, gw_id, name=name, src=src)
    if not rep.get("ok"):
        return None, rep
    cl = ChatClient(gw_port, rep["ticket"], name, timeout=timeout, src=src)
    return cl, rep


def connect(gw_port, token, name, src, timeout=8.0):
    """Hello with a given token/ticket from `src` -> ChatClient (welcome or closed)"""
    return ChatClient(gw_port, token, name, timeout=timeout, src=src)


def pre_hello(gw_port, src, wait=2.5):
    """TCP connect from `src` and send NOTHING: an IP-banned / rate-limited address gets Disconnect before Hello.
    -> {"code", "reason", "ms"} | {"code": None (no verdict: the gateway waits for Hello), "closed"}"""
    s = socket.create_connection(("127.0.0.1", gw_port), timeout=3, source_address=(src, 0))
    fr = C.framer()
    t0 = time.time()
    s.settimeout(0.1)
    try:
        while time.time() - t0 < wait:
            try:
                d = s.recv(65536)
            except socket.timeout:
                continue
            except OSError as exc:
                return {"code": None, "closed": "error %s" % exc, "ms": round((time.time() - t0) * 1000, 1)}
            if not d:
                return {"code": None, "closed": "eof", "ms": round((time.time() - t0) * 1000, 1)}
            fr.feed(d)
            x = fr.next()
            if x is not None and C.NAMES[x[0]] == "Disconnect":
                m = C.decode_body(*x)
                return {"code": m["code"], "reason": m["reason"], "ms": round((time.time() - t0) * 1000, 1)}
        return {"code": None, "closed": None, "ms": round((time.time() - t0) * 1000, 1)}
    finally:
        try:
            s.close()
        except OSError:
            pass


class Forward:
    """TCP relay: 127.0.0.1:<port> (0 = free) -> 127.0.0.1:<target>, outgoing side bound to `src`"""

    def __init__(self, target, src, port=0):
        self.target, self.src = target, src
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", port))
        self.srv.listen(16)
        self.port = self.srv.getsockname()[1]
        self.alive = True
        self.n = 0
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while self.alive:
            try:
                a, _ = self.srv.accept()
            except OSError:
                break
            try:
                b = socket.create_connection(("127.0.0.1", self.target), timeout=5, source_address=(self.src, 0))
            except OSError:
                a.close()
                continue
            self.n += 1
            for x, y in ((a, b), (b, a)):
                threading.Thread(target=self._pipe, args=(x, y), daemon=True).start()

    @staticmethod
    def _pipe(x, y):
        try:
            x.settimeout(None)
            while True:
                d = x.recv(65536)
                if not d:
                    break
                y.sendall(d)
        except OSError:
            pass
        for s in (x, y):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def close(self):
        self.alive = False
        try:
            self.srv.close()
        except OSError:
            pass


if __name__ == "__main__":
    # smoke: python fraud_check.py <gw port> <auth url> <gw id> <nick> <src>
    gw, url, gid, nick, src = sys.argv[1:6]
    cl, rep = login(int(gw), url, gid, nick, src)
    print(json.dumps({"ticket": {k: v for k, v in rep.items() if k != "ticket"},
                      "welcome": bool(cl and cl.welcome), "closed": cl and cl.closed}, ensure_ascii=False))
    if cl:
        cl.close()
