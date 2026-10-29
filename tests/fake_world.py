"""Фейковые процессы этапа 4 (без движка): `python fake_world.py <режим> --k v ...`.
  world   — как заглушка мира проекта-сервера: TCP-порт --port, 20 тактов/с, состояние {tick, bench, players}, строка
            [fake_world] ready, export\\world_states.jsonl, stdin: status / world.stop (как --stdin-cmd)
  bot     — как бот: подключается к --gateway, join, реплика, ack, export\\client_states.jsonl; stdin world.stop;
            --corrupt 1 — портит hash реплики (расхождение должно быть видно)
  kbhit   — как читатель VoxelCore --stdin-cmd на Windows: ждёт msvcrt.kbhit() (консоль), потом читает строку
            из stdin (канал) и печатает «got <строка>»
  window  — headless-нарушитель: создаёт невидимое окно верхнего уровня (класс STATIC) и печатает ready
  headless — честный headless: печатает ready и спит (окон нет)"""
import json
import os
import socket
import sys
import threading
import time


def args():
    a, i, out = sys.argv[2:], 0, {}
    while i < len(a):
        if a[i].startswith("--") and i + 1 < len(a) and not a[i + 1].startswith("--"):
            out[a[i][2:]] = a[i + 1]
            i += 2
        else:
            out[a[i][2:]] = ""
            i += 1
    return out


def canon(s):
    return "%d|%.3f|%.3f|%.3f|%d" % (s["tick"], s["bench"]["x"], s["bench"]["y"], s["bench"]["z"], s["players"])


def stdin_cmds(handler):
    def run():
        for line in sys.stdin:
            line = line.strip()
            if line:
                print(handler(line), flush=True)
    threading.Thread(target=run, daemon=True).start()


def world(a):
    os.makedirs("export", exist_ok=True)
    srv = socket.socket()
    srv.bind(("127.0.0.1", int(a["port"])))
    srv.listen(16)
    srv.setblocking(False)
    st = {"tick": 0, "players": 0, "stop": False, "clients": []}
    lines = []

    def handler(cmd):
        if cmd == "status":
            return "[stdin-cmd] [fake_world] status tick=%d clients=%d players=%d" % (
                st["tick"], len(st["clients"]), st["players"])
        if cmd == "world.stop":
            st["stop"] = True
            return "[stdin-cmd] [fake_world] stopping"
        return "[stdin-cmd] unknown command %s" % cmd
    stdin_cmds(handler)
    print("[fake_world] ready port=%s" % a["port"], flush=True)
    while not st["stop"]:
        t0 = time.time()
        try:
            c, _ = srv.accept()
            c.setblocking(False)
            st["clients"].append({"s": c, "buf": b"", "name": None})
        except BlockingIOError:
            pass
        st["tick"] += 1
        alive = []
        for c in st["clients"]:
            try:
                data = c["s"].recv(65536)
                if data == b"":
                    continue
                c["buf"] += data
            except BlockingIOError:
                pass
            except OSError:
                continue
            while b"\n" in c["buf"]:
                ln, c["buf"] = c["buf"].split(b"\n", 1)
                m = json.loads(ln)
                if m.get("t") == "join" and not c["name"]:
                    c["name"] = m.get("name")
                    st["players"] += 1
            alive.append(c)
        st["clients"] = alive
        s = {"tick": st["tick"], "bench": {"x": 8 + (st["tick"] % 160) / 10, "y": 100, "z": 2},
             "players": st["players"]}
        ts = time.time() * 1000
        msg = (json.dumps({"t": "state", "tick": st["tick"], "ts": ts, "state": s, "hash": canon(s)}) + "\n").encode()
        for c in st["clients"]:
            try:
                c["s"].sendall(msg)
            except OSError:
                pass
        lines.append(json.dumps({"tick": st["tick"], "ts": ts, "hash": canon(s)}) + "\n")
        if st["tick"] % 10 == 0:
            with open("export/world_states.jsonl", "w") as f:
                f.write("".join(lines))
        time.sleep(max(0.0, 0.05 - (time.time() - t0)))
    with open("export/world_states.jsonl", "w") as f:
        f.write("".join(lines))


def bot(a):
    os.makedirs("export", exist_ok=True)
    s = socket.create_connection(("127.0.0.1", int(a["gateway"])))
    s.sendall((json.dumps({"t": "join", "name": a.get("name", "bot")}) + "\n").encode())
    print("[fake_client] connected %s gateway=%s" % (a.get("name"), a["gateway"]), flush=True)
    st = {"stop": False}
    stdin_cmds(lambda cmd: (st.__setitem__("stop", True), "[stdin-cmd] stopping")[1] if cmd == "world.stop"
               else "[stdin-cmd] ?")
    s.settimeout(0.2)
    buf, lines = b"", []
    corrupt = a.get("corrupt") == "1"
    while not st["stop"]:
        try:
            data = s.recv(65536)
            if not data:
                break
            buf += data
        except socket.timeout:
            continue
        while b"\n" in buf:
            ln, buf = buf.split(b"\n", 1)
            m = json.loads(ln)
            rep = dict(m["state"])
            if corrupt and m["tick"] % 7 == 0:
                rep["players"] += 100
            lines.append(json.dumps({"tick": m["tick"], "t_recv": time.time() * 1000, "ts": m["ts"],
                                     "hash": canon(rep), "server_hash": m["hash"]}) + "\n")
            s.sendall((json.dumps({"t": "ack", "tick": m["tick"]}) + "\n").encode())
            if len(lines) % 10 == 0:
                with open("export/client_states.jsonl", "w") as f:
                    f.write("".join(lines))
    with open("export/client_states.jsonl", "w") as f:
        f.write("".join(lines))


def kbhit(a):
    import msvcrt
    print("[kbhit] ready", flush=True)
    while True:
        if not msvcrt.kbhit():
            time.sleep(0.01)
            continue
        line = sys.stdin.readline()
        if not line:
            return
        print("got %s" % line.strip(), flush=True)


def window(a):
    import ctypes
    hwnd = ctypes.windll.user32.CreateWindowExW(0, "STATIC", "lab-headless-violation", 0, 0, 0, 10, 10,
                                                None, None, None, None)
    print("[fake] ready hwnd=%s" % hwnd, flush=True)
    time.sleep(120)


def headless(a):
    print("[fake] ready", flush=True)
    time.sleep(120)


if __name__ == "__main__":
    {"world": world, "bot": bot, "kbhit": kbhit, "window": window, "headless": headless}[sys.argv[1]](args())
