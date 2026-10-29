"""labpipe — постоянный канал WSL -> демон labd для инструментов без своего Windows-Python (MCP `voxelcore`:
vc_start/vc_input/vc_stop). WSL в NAT не видит 127.0.0.1 Windows, а запуск CLI `lab` на каждый вызов стоит ~0.15 с;
здесь один процесс Windows-Python держит HTTP-соединение (LabClient) и отвечает строками JSON:

  -> {"id": 1, "m": "GET"|"POST", "p": "/leases", "b": {...}, "t": 60, "owner": "claude"}
  <- {"id": 1, "r": <ответ демона>}   или {"id": 1, "error": "..."}

Демон не отвечает — поднимается labctl (как у CLI). Клиент помечается X-Lab-Client: pipe (не cli: `lab play --user`
отсюда не пройдёт)."""
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if REPO not in sys.path:
    sys.path.insert(0, REPO)
from vclab.daemon.client import LabClient  # noqa: E402

_clients = {}


def client(owner):
    owner = owner or os.environ.get("LAB_OWNER") or "claude"
    c = _clients.get(owner)
    if c is None:
        c = _clients[owner] = LabClient(owner=owner, client="pipe")
    return c


def main():
    started = False
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError as exc:
            sys.stdout.write(json.dumps({"error": "bad json: %s" % exc}) + "\n")
            sys.stdout.flush()
            continue
        out = {"id": req.get("id")}
        try:
            c = client(req.get("owner"))
            if not started and not c.alive():
                from vclab.cli import labctl as labctl
                r = labctl.start()
                if not r.get("ok"):
                    raise RuntimeError("labd did not start: %s" % r)
            started = True
            m = req.get("m", "GET")
            out["r"] = c.request(m, req["p"], (req.get("b") or {}) if m != "GET" else None,
                                 timeout=float(req.get("t", 120)))
        except Exception as exc:
            out["error"] = "%s: %s" % (type(exc).__name__, exc)
        sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
