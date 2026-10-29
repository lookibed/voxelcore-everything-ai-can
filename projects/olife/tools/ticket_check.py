"""Ticket auth checks against a running gateway (wave 4b): every case is one TCP connection with Hello{token=<case>}
and the expected outcome — Welcome (code 0) or Disconnect with a distinct code.

  python ticket_check.py --gateway <port> --auth https://127.0.0.1:<port> --auth-ctl <port> --gw-id <id>
                         [--sealed-pub <b64url>] [--banned-token olife-banned] [--json out.json]
Tickets come from the real auth service (HTTPS, sealed to the pinned key when --sealed-pub is given); expired ones
and ones for another gateway — from its control port `mint` (age_s / gateway), the forged one is a good ticket with
one changed character of the tag. Used by the lab step olife_ticket_auth (tools/lab/projects/olife/olife_w4b.py)."""
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from olife_proto import client as C  # noqa: E402
import negative as N  # noqa: E402


def ctl(port, cmd, args=None, timeout=5.0):
    s = socket.create_connection(("127.0.0.1", int(port)), timeout=timeout)
    s.sendall((json.dumps({"id": 1, "cmd": cmd, "args": args or {}}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        d = s.recv(65536)
        if not d:
            break
        buf += d
    s.close()
    r = json.loads(buf.split(b"\n", 1)[0])
    if not r.get("ok"):
        raise RuntimeError("ctl %s: %s" % (cmd, r.get("error")))
    return r["result"]


def hello(gw_port, token, name, want_packs=False, timeout=8.0):
    """-> {"code": 0 | Disconnect code, "reason", "ms", "packs": PacksChanged | None}"""
    t0 = time.perf_counter()
    s = N.conn(gw_port)
    s.sendall(C.frame("Hello", {"proto": C.VERSION, "name": name, "token": token, "engine": "ticket_check"}))
    want = ("Disconnect", "Welcome")
    nm, m, eof = N.read_until(s, want, timeout)
    out = {"ms": round((time.perf_counter() - t0) * 1000, 1)}
    if nm == "Welcome":
        out.update(code=0, reason="welcome", session=m["session"])
        if want_packs:
            nm2, m2, _ = N.read_until(s, ("PacksChanged", "Disconnect"), 3.0)
            out["packs"] = m2 if nm2 == "PacksChanged" else None
        try:
            s.sendall(C.frame("Bye", {"reason": "ticket_check"}))
        except OSError:
            pass
    elif nm == "Disconnect":
        out.update(code=m["code"], reason=m["reason"])
    else:
        out.update(code=None, reason="eof" if eof else "timeout")
    s.close()
    return out


def run(gw_port, auth_url, auth_ctl, gw_id, sealed_pub=None, banned_token="olife-banned", token="olife-test",
        packs=False, static_mode="both"):
    import auth_service as A
    res = []

    def case(name, tok, want, **kw):
        r = hello(gw_port, tok, "tk_" + name[:20], want_packs=kw.pop("packs", False))
        r.update(name=name, want=want, ok=r.get("code") == want, **kw)
        res.append(r)
        return r
    t0 = time.perf_counter()
    good = A.client_ticket(auth_url, token, gw_id, sealed_pub)
    issue_ms = round((time.perf_counter() - t0) * 1000, 1)
    if not good.get("ok"):
        raise RuntimeError("auth service refused the test token: %s" % good)
    tk = good["ticket"]
    case("good", tk, 0, ticket_len=len(tk), issue_ms=good.get("_ms"), sealed=bool(good.get("_sealed")),
         packs=packs)
    case("replayed", tk, 15)
    case("expired", ctl(auth_ctl, "mint", {"gateway": gw_id, "account": "test", "ttl": 30, "age_s": 120})["ticket"], 14)
    case("wrong_gateway", ctl(auth_ctl, "mint", {"gateway": gw_id + "-other", "account": "test"})["ticket"], 17)
    fresh = A.client_ticket(auth_url, token, gw_id, sealed_pub)["ticket"]
    forged = fresh[:-2] + ("A" if fresh[-2] != "A" else "B") + fresh[-1]
    case("bad_signature", forged, 16)
    case("malformed", "T1.%%%%not-a-ticket", 4)
    case("static_token", token, 4 if static_mode == "tickets" else 0)
    # banned account: the auth service refuses to issue; a ticket minted anyway (stolen key scenario) is refused by
    # the gateway's ban list from the supervisor
    b = A.client_ticket(auth_url, banned_token, gw_id, sealed_pub)
    res.append({"name": "banned_issue", "want": "banned", "code": b.get("code"), "reason": b.get("reason"),
                "ok": b.get("ok") is False and b.get("code") == "banned"})
    case("banned_ticket", ctl(auth_ctl, "mint", {"gateway": gw_id, "account": "banned"})["ticket"], 5)
    bad = A.client_ticket(auth_url, "no-such-token", gw_id, sealed_pub)
    res.append({"name": "bad_token_issue", "want": "auth", "code": bad.get("code"), "ok": bad.get("code") == "auth"})
    after = case("good_after", A.client_ticket(auth_url, token, gw_id, sealed_pub)["ticket"], 0)
    return {"tests": len(res), "passed": sum(1 for r in res if r["ok"]), "issue_ms_first": issue_ms,
            "results": res, "alive_after": after.get("code") == 0}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", type=int, required=True)
    ap.add_argument("--auth", required=True)
    ap.add_argument("--auth-ctl", type=int, required=True)
    ap.add_argument("--gw-id", required=True)
    ap.add_argument("--sealed-pub")
    ap.add_argument("--token", default="olife-test")
    ap.add_argument("--banned-token", default="olife-banned")
    ap.add_argument("--mode", default="both")
    ap.add_argument("--packs", action="store_true")
    ap.add_argument("--json")
    a = ap.parse_args()
    rep = run(a.gateway, a.auth, a.auth_ctl, a.gw_id, a.sealed_pub, a.banned_token, a.token, a.packs, a.mode)
    for r in rep["results"]:
        print("%-16s want %-7s got %-7s %s %s" % (r["name"], r["want"], r.get("code"), "ok " if r["ok"] else "BAD",
                                                (r.get("reason") or "")[:60]))
    print("passed %d/%d" % (rep["passed"], rep["tests"]))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=1)
    return 0 if rep["passed"] == rep["tests"] else 1


if __name__ == "__main__":
    sys.exit(main())
