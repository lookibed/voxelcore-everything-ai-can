"""Крошечный F2F-сервер для тестов (протокол f2f/PROTOCOL.md §1): hello, step, shot (PNG 4x2), echo, sleep, quit,
crash (выход с кодом 3 без ответа), cp1251 (ответ не в UTF-8). Печатает в stdout «listening <port>» и строку
по-русски в cp866 (как консоль Java), в stderr — в cp1251 (как сообщения Windows)."""
import json
import os
import socket
import struct
import sys
import time
import zlib


def png(path, w=4, h=2, rgb=(10, 20, 30)):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)
    import hashlib
    return hashlib.sha256(bytes(rgb) * w * h).hexdigest()      # как F2F §6: RGB построчно, без байтов фильтра


def main():
    port = int(sys.argv[1])
    delay = float(sys.argv[2]) if len(sys.argv) > 2 else 0
    time.sleep(delay)
    srv = socket.socket()
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    sys.stdout.buffer.write(("listening %d\nпривет из консоли\n" % port).encode("cp866"))
    sys.stdout.flush()
    sys.stderr.buffer.write("Отказано в доступе\n".encode("cp1251"))
    sys.stderr.flush()
    tick = frame = 0
    last_input, keys, chat = {}, {}, []
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
                cmd, args = req["cmd"], req.get("args") or {}
                res, ok = None, True
                if cmd == "hello":
                    res = {"impl": "fake", "tick": tick, "frame": frame, "handler": frame >= 3}
                elif cmd == "step":
                    tick += int(args.get("ticks", 1))
                    frame += int(args.get("frames", 1))
                    if frame == 5:
                        print("[fake] ready marker", flush=True)
                    res = {"tick": tick, "frame": frame}
                elif cmd == "shot":
                    # цвет зависит от такта и нажатых клавиш (сценарные тесты: разные такты — разные кадры)
                    rgb = (10, tick % 256, (30 + 40 * len([k for k, v in keys.items() if v])) % 256) \
                        if args.get("color", True) and tick else (10, 20, 30)
                    sha = png(args["path"], rgb=rgb)
                    res = {"path": args["path"], "w": 4, "h": 2, "sha256": sha, "tick": tick, "frame": frame}
                elif cmd == "mode":
                    tick = frame = 0
                    res = {"tick": 0, "frame": 0, "seed": args.get("seed")}
                elif cmd == "input":
                    last_input = args
                    keys.update(args.get("keys") or {})
                    res = {"queued": 1}
                elif cmd == "state":
                    res = {"tick": tick, "frame": frame, "screen": "ingame",
                           "player": {"x": float(tick), "y": 64.0, "z": 0.0, "yaw": 0.0, "pitch": 0.0},
                           "keys": {k: v for k, v in keys.items() if v}, "chat": [{"text": t, "age": 0} for t in chat],
                           "last_input": last_input}
                elif cmd == "chat":
                    chat.append(args.get("text", ""))
                    res = {"tick": tick}
                elif cmd in ("gui",):
                    tick += 1
                    frame += 1
                    res = {"tick": tick, "frame": frame, "screen": "gui", "handled": args}
                elif cmd == "render":
                    res = {"layers": args.get("layers") or {}, "rebuilt": False}
                elif cmd == "wait_check":
                    res = {"done": tick >= int(args.get("tick_at", 0)), "tick": tick}
                elif cmd == "status":
                    res = {"tick": tick, "frame": frame}
                elif cmd == "sleep":
                    time.sleep(float(args.get("s", 1)))
                    res = {"slept": args.get("s", 1)}
                elif cmd == "keepalive":
                    res = {"keepalive": True}
                    with open(os.path.join(os.getcwd(), "keepalive.txt"), "a") as f:
                        f.write("k\n")
                elif cmd == "crash":
                    os._exit(3)
                elif cmd == "cp1251":
                    conn.sendall(b'{"id": %d, "ok": false, "error": "' % req["id"] + "Ошибка".encode("cp1251") +
                                 b'"}\n')
                    continue
                elif cmd == "quit":
                    conn.sendall((json.dumps({"id": req["id"], "ok": True, "result": "bye"}) + "\n").encode())
                    conn.close()
                    sys.exit(0)
                else:
                    ok, res = False, None
                rep = {"id": req["id"], "ok": ok}
                if ok:
                    rep["result"] = res
                else:
                    rep["error"] = "unknown-command"
                conn.sendall((json.dumps(rep, ensure_ascii=False) + "\n").encode("utf-8"))
        conn.close()


if __name__ == "__main__":
    main()
