"""Фейковая «тестовая сборка движка» для тестов этапа 3а: запускается копией python.exe с именем VoxelCore*.exe
(ядро видит exe движка), понимает ключи `--f2f <port>`, `--f2f-clock C`, `--f2f-window W`, `--res`, `--dir`.
hello.flags берутся из окружения FAKE_FLAGS (JSON; "none" — поля flags нет, как у старой сборки); иначе — честные
{clock, input:"isolated", window} из ключей. hello.version — FAKE_VERSION (по умолчанию "0.31-f2f", как у тестовой
сборки 0.31: движок по умолчанию v031 требует его, этап 4a). Пишет argv в argv.json каталога запуска."""
import json
import os
import socket
import sys


def main():
    a = sys.argv[1:]
    opts = {}
    i = 0
    while i < len(a):
        if a[i].startswith("--") and i + 1 < len(a):
            opts[a[i]] = a[i + 1]
            i += 2
        else:
            i += 1
    with open("argv.json", "w") as f:
        json.dump(a, f)
    port = int(opts["--f2f"])
    env = os.environ.get("FAKE_FLAGS")
    if env == "none":
        flags = None
    elif env:
        flags = json.loads(env)
    else:
        flags = {"clock": opts.get("--f2f-clock", "virtual"), "input": "isolated",
                 "window": opts.get("--f2f-window", "normal")}
    srv = socket.socket()
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    print("listening %d" % port, flush=True)
    frame = 0
    while True:
        conn, _ = srv.accept()
        buf = b""
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                req = json.loads(line)
                cmd = req["cmd"]
                res = {}
                if cmd == "hello":
                    res = {"impl": "vc", "version": os.environ.get("FAKE_VERSION") or "0.31-f2f", "frame": frame}
                    if flags is not None:
                        res["flags"] = flags
                elif cmd == "step":
                    frame += 1
                    res = {"frame": frame}
                elif cmd == "input":
                    res = {"queued": 1}
                elif cmd == "quit":
                    conn.sendall((json.dumps({"id": req["id"], "ok": True, "result": "bye"}) + "\n").encode())
                    conn.close()
                    sys.exit(0)
                conn.sendall((json.dumps({"id": req["id"], "ok": True, "result": res}) + "\n").encode())
        conn.close()


if __name__ == "__main__":
    main()
