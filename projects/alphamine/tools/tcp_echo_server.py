#!/usr/bin/env python3
"""Проба 5 AlphaMine: TCP-сервер в WSL для замера приёма VoxelCore (network.tcp_connect + recv(available())).
На каждое подключение шлёт N байт (по умолчанию 8 МБ, байт i = (i*7 + i//4096) & 255), затем эхо принятого
до закрытия. Печатает время отправки. Запуск: python3 tools/alphamine/tcp_echo_server.py [port] [bytes] [conns]
(conns — сколько подключений обслужить до выхода; по умолчанию 1)."""
import socket, sys, time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 25580
size = int(sys.argv[2]) if len(sys.argv) > 2 else 8 * 1024 * 1024
conns = int(sys.argv[3]) if len(sys.argv) > 3 else 1
data = bytes(((i * 7 + i // 4096) & 255) for i in range(size))
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port))
srv.listen(4)
srv.settimeout(120)
print(f"listening 0.0.0.0:{port}, {size} bytes per connection", flush=True)
for _ in range(conns):
    try:
        c, addr = srv.accept()
    except socket.timeout:
        print("accept timeout", flush=True)
        break
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    t0 = time.time()
    c.sendall(data)
    print(f"{addr}: sent {size} B in {time.time() - t0:.3f} s", flush=True)
    c.settimeout(30)
    got = 0
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            got += len(b)
            c.sendall(b)
    except socket.timeout:
        pass
    print(f"{addr}: echoed {got} B, closed", flush=True)
    c.close()
srv.close()
