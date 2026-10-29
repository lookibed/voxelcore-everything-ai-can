#!/usr/bin/env python3
"""Fake Olife world for gateway tests without the engine (contract internal; lab kind olife.world_fake): checks
GatewayHello (secret, proto) -> WorldHello; Attach -> Welcome; TickSync every 1/tps s to every session (Data); Ping ->
Pong; ChatSend -> ChatMessage Multicast to all sessions; ChatSend "burst:N" -> N x 1 MB ChunkData Multicast (slow
consumer test). Drops any gateway connection with a bad frame (like the real world). Decodes every client body again.
  python world_fake.py --port P [--secret S] [--tps 20] [--stats file.json] [--f2f <control port>]
Control port (lab F2F protocol, ctlport.py): hello, stats, quit. Used by the gateway throughput/soak tests
(tools/olife/gw_load.py) so that the gateway, not the world, is what is measured."""
import json, os, socket, sys, threading, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "lab", "projects", "olife"))
from olife_proto import client as C, internal as I  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

a = {sys.argv[i][2:]: sys.argv[i + 1] for i in range(1, len(sys.argv) - 1) if sys.argv[i].startswith("--")}
PORT, SECRET, TPS = int(a["port"]), a.get("secret", "olife-dev-secret"), int(a.get("tps", 20))
lock = threading.Lock()
gws = []          # (sock, sessions dict)
st = {"inputs": 0, "data": 0, "attach": 0, "detach": 0, "bad": 0, "tick": 0, "chat": 0, "bytes_in": 0}


send_lock = threading.Lock()   # sendall from the ticker and the reader threads must not interleave


def send(s, name, msg):
    fr = I.frame(name, msg)
    try:
        with send_lock:
            s.sendall(fr)
    except OSError:
        pass


def gw_conn(s):
    fr = I.framer()
    sess = {}
    hello = False
    try:
        while True:
            d = s.recv(262144)
            if not d:
                break
            st["bytes_in"] += len(d)
            fr.feed(d)
            while True:
                x = fr.next()
                if x is None:
                    break
                mid, body = x
                m = I.decode_body(mid, body)
                n = I.NAMES[mid]
                if not hello:
                    if n != "GatewayHello" or m["secret"] != SECRET or m["proto"] != I.VERSION:
                        raise ProtoError("bad hello")
                    hello = True
                    send(s, "WorldHello", {"proto": 1, "world": "fake", "tick": st["tick"], "tps": TPS,
                                           "client_proto": C.VERSION})
                    with lock:
                        gws.append((s, sess))
                    continue
                if n == "Attach":
                    st["attach"] += 1
                    sess[m["session"]] = m
                    w = C.body("Welcome", {"proto": 1, "session": m["session"], "player_eid": 100 + m["session"],
                                           "tick": st["tick"], "tps": TPS, "spawn": {"x": 8.5, "y": 82, "z": 8.5},
                                           "view_radius": 3, "world": "fake", "blocks": 10})
                    send(s, "Data", {"session": m["session"], "type": C.IDS["Welcome"], "payload": w})
                elif n == "Detach":
                    st["detach"] += 1
                    sess.pop(m["session"], None)
                elif n == "Data":
                    st["data"] += 1
                    cm = C.decode_body(m["type"], m["payload"])
                    if m["type"] == C.IDS["PlayerInput"]:
                        st["inputs"] += 1
                    elif m["type"] == C.IDS["ChatSend"]:
                        st["chat"] += 1
                        if cm["text"].startswith("burst:"):
                            blob = C.body("ChunkData", {"cx": 0, "cz": 0, "data": bytes(1000000), "hash": 0})
                            for _ in range(int(cm["text"][6:])):
                                send(s, "Multicast", {"sessions": list(sess), "type": C.IDS["ChunkData"], "payload": blob})
                            continue
                        p = C.body("ChatMessage", {"from": m["session"], "name": "x", "text": cm["text"]})
                        send(s, "Multicast", {"sessions": list(sess), "type": C.IDS["ChatMessage"], "payload": p})
                elif n == "Ping":
                    send(s, "Pong", m)
    except (OSError, ProtoError, KeyError) as e:
        st["bad"] += 1
    with lock:
        gws[:] = [g for g in gws if g[0] is not s]
    try:
        s.close()
    except OSError:
        pass


def ticker():
    while True:
        time.sleep(1.0 / TPS)
        st["tick"] += 1
        with lock:
            gl = list(gws)
        for s, sess in gl:
            for sid in list(sess):
                p = C.body("TickSync", {"tick": st["tick"], "server_ms": time.time() * 1000.0, "view_hash": 1,
                                        "entities": 0, "chunks": 0})
                send(s, "Data", {"session": sid, "type": C.IDS["TickSync"], "payload": p})
        if "stats" in a and st["tick"] % 20 == 0:
            with open(a["stats"], "w") as f:
                json.dump(st, f)


if a.get("f2f"):
    import ctlport
    ctlport.serve(a["f2f"], {"stats": lambda args: dict(st, gateways=len(gws), sessions=sum(len(g[1]) for g in gws))},
                  "olife-world-fake")
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(16)
threading.Thread(target=ticker, daemon=True).start()
print("[fake_world] ready port=%d" % PORT, flush=True)
while True:
    c, _ = srv.accept()
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    threading.Thread(target=gw_conn, args=(c,), daemon=True).start()
