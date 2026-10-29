"""Wave 4b: tickets (olife_ticket.py vectors), auth service (HTTPS self-signed + sealed requests) and the dev gateway's
ticket checks end to end (world_fake.py + gateway_dev.py + auth_service.py as local processes, no engine).
  python3 tools/olife/tests/test_tickets.py        (WSL python 3.10 with `cryptography`, or Windows python 3.13)"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, TOOLS)
import olife_ticket as T  # noqa: E402


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_port(port, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


class TicketVectors(unittest.TestCase):
    def test_selftest(self):
        self.assertLessEqual(T.selftest(), 127)

    def test_vectors(self):
        with open(os.path.join(TOOLS, "protocol", "vectors", "tickets.json"), encoding="utf-8") as f:
            d = json.load(f)
        k = bytes.fromhex(d["gateway_key_hex"])
        self.assertEqual(T.gateway_key(bytes.fromhex(d["master_hex"]), d["gateway"]), k)
        v = T.Verifier(k, d["gateway"])
        for c in d["cases"]:
            r, acct = v.verify(c["ticket"], now=c["now"])
            self.assertEqual(r, c["want"], c["name"])
            self.assertEqual(acct, c.get("account"), c["name"])


class EndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="olife_w4b_")
        cls.procs = []
        master = os.urandom(32)
        with open(os.path.join(cls.dir, "master.key"), "w") as f:
            f.write(master.hex())
        cls.gw_id = "gw-test"
        with open(os.path.join(cls.dir, "gw.key"), "w") as f:
            json.dump({"key": T.gateway_key(master, cls.gw_id).hex(), "gateway": cls.gw_id}, f)
        wp, ap, ac, gp = free_port(), free_port(), free_port(), free_port()
        py = sys.executable

        def run(*a):
            p = subprocess.Popen([py, "-u", "-B"] + list(a), cwd=cls.dir, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT)
            cls.procs.append(p)
            return p
        run(os.path.join(TOOLS, "world_fake.py"), "--port", str(wp), "--secret", "s")
        cls.auth = run(os.path.join(TOOLS, "auth_service.py"), "--listen", str(ap), "--f2f", str(ac), "--dir", cls.dir,
                       "--master", os.path.join(cls.dir, "master.key"), "--gateways", cls.gw_id)
        assert wait_port(wp) and wait_port(ap) and wait_port(ac)
        run(os.path.join(TOOLS, "gateway_dev.py"), "--listen", str(gp), "--upstream", "127.0.0.1:%d" % wp,
            "--secret", "s", "--name", "gwname", "--ticket-key", os.path.join(cls.dir, "gw.key"))
        assert wait_port(gp)
        line = cls.auth.stdout.readline().decode() + cls.auth.stdout.readline().decode()
        cls.pub = line.split("sealed_pub=")[1].split()[0]
        cls.ports = {"gw": gp, "auth": ap, "auth_ctl": ac}

    @classmethod
    def tearDownClass(cls):
        for p in cls.procs:
            p.kill()

    def test_ticket_cases(self):
        import ticket_check
        rep = ticket_check.run(self.ports["gw"], "https://127.0.0.1:%d" % self.ports["auth"], self.ports["auth_ctl"],
                               self.gw_id, self.pub)
        bad = [r for r in rep["results"] if not r["ok"]]
        self.assertFalse(bad, bad)
        self.assertEqual(rep["passed"], rep["tests"])

    def test_plain_and_tamper(self):
        import auth_service as A
        url = "https://127.0.0.1:%d" % self.ports["auth"]
        r = A.client_ticket(url, "olife-dev", self.gw_id)                 # plain (allowed: require-sealed 0)
        self.assertTrue(r["ok"], r)
        self.assertEqual(A.client_ticket(url, "olife-dev", "gw-unknown", self.pub)["code"], "unknown_gateway")
        import urllib.request
        import ssl
        body = json.dumps({"v": 1, "epk": A.b64u(os.urandom(32)), "ct": A.b64u(os.urandom(60))}).encode()
        req = urllib.request.Request(url + "/ticket", data=body, method="POST")
        try:
            urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=5)
            self.fail("tampered seal accepted")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 400)


if __name__ == "__main__":
    unittest.main(verbosity=2)
