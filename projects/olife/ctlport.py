"""Порт управления заглушек olife (шлюз, песочница) в протоколе F2F лаборатории: строки JSON
{"id", "cmd", "args"} -> {"id", "ok", "result"|"error"}. Даёт lab f2f / ready (hello) / stop (quit) без особых случаев
в ядре. hello.flags.input = "none": у процесса нет окна и ввода ОС вообще."""
import json
import os
import socket
import sys
import threading


def serve(port, handlers, impl):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", int(port)))
    srv.listen(4)

    def client(conn):
        buf = b""
        with conn:
            while True:
                try:
                    chunk = conn.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        req = json.loads(line)
                    except ValueError:
                        continue
                    cmd, args = req.get("cmd"), req.get("args") or {}
                    try:
                        if cmd == "hello":
                            res = {"impl": impl, "pid": os.getpid(), "flags": {"input": "none", "window": "none"}}
                        elif cmd == "quit":
                            conn.sendall((json.dumps({"id": req.get("id"), "ok": True, "result": "bye"}) + "\n").encode())
                            handlers.get("_quit", lambda: None)()
                            os._exit(0)
                        elif cmd in handlers:
                            res = handlers[cmd](args)
                        else:
                            raise KeyError("unknown cmd %r (have: hello, quit, %s)" % (cmd, ", ".join(
                                k for k in handlers if not k.startswith("_"))))
                        rep = {"id": req.get("id"), "ok": True, "result": res}
                    except Exception as exc:
                        rep = {"id": req.get("id"), "ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}
                    conn.sendall((json.dumps(rep, default=str) + "\n").encode())

    def loop():
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=client, args=(conn,), daemon=True).start()
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    print("[%s] control port %s" % (impl, port), flush=True)
    return t


def argmap(argv):
    out, i = {}, 0
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            out[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    return out


if __name__ == "__main__":
    sys.exit("library")
