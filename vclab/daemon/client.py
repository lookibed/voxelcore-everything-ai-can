"""HTTP-клиент демона (stdlib): им пользуются lab.py (CLI), labctl.py и mcp_bridge.py. Владелец — LAB_OWNER.
Этап 5: роль — LAB_ROLE=agent (или role="agent") шлёт X-Lab-Role: agent и только понижает права владельца;
порт — LAB_PORT / --daemon (изолированный демон 25800–25849)."""
import getpass
import json
import os
import socket
import http.client


def default_owner():
    return os.environ.get("LAB_OWNER") or "%s@cli" % getpass.getuser()


def default_role():
    r = (os.environ.get("LAB_ROLE") or "").strip().lower()
    return r or None


class LabClient:
    def __init__(self, port=None, owner=None, host="127.0.0.1", client="cli", role=None):
        self.port = int(port or os.environ.get("LAB_PORT") or 25700)
        self.host = host
        self.owner = owner or default_owner()
        self.client = client          # X-Lab-Client: cli | mcp | pipe (демон: lab play --user только из cli)
        self.role = role or default_role()      # "agent" — понизить роль (субагент с LAB_OWNER главной сессии)
        self._conn = None

    def request(self, method, path, body=None, timeout=600.0):
        """Постоянное HTTP/1.1-соединение (http.client): ~1 мс на вызов против ~15 мс у urllib с новым соединением
        на каждый POST (замер 01.10). Обрыв — одна попытка с новым соединением."""
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json", "X-Lab-Owner": self.owner, "X-Lab-Client": self.client}
        if self.role:
            headers["X-Lab-Role"] = self.role
        for attempt in (0, 1):
            conn = self._conn
            if conn is None:
                conn = self._conn = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
            conn.timeout = timeout
            if conn.sock is not None:
                conn.sock.settimeout(timeout)
            try:
                conn.request(method, path, body=data, headers=headers)
                r = conn.getresponse()
                raw = r.read()
            except (ConnectionError, http.client.HTTPException, OSError):
                self.close()
                if attempt:
                    raise
                continue
            try:
                return json.loads(raw.decode("utf-8"))
            except ValueError:
                return {"ok": False, "error": "http-%d" % r.status, "message": raw[:500].decode("utf-8", "replace")}

    def close(self):
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass
        self._conn = None

    def get(self, path, timeout=60.0):
        return self.request("GET", path, timeout=timeout)

    def post(self, path, body=None, timeout=600.0):
        return self.request("POST", path, body or {}, timeout=timeout)

    def alive(self, timeout=1.0):
        try:
            s = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
            s.close()
        except OSError:
            return None
        try:
            h = self.get("/health", timeout=timeout + 2)
            return h if h.get("service") == "labd" else None
        except Exception:
            return None
