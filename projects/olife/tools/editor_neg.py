"""Olife wave 4a: protocol client for the editor / console / tools layer, negative tests and the console flood check.
Talks to the gateway exactly like a game client (Hello with a token, KeepAlive replies, PlayerInput at 10/s so the
world keeps a fresh position) and sends the wave-4a requests directly — no UI, so it can also send what the UI never
would. Every request must end in a RequestReply with the expected code; the world and the gateway stay alive.

  python editor_neg.py --gateway <port> --eid <bench of another account> [--own <bench of carol>] [--json out.json]
Used by the lab steps olife_editor_neg / olife_console_flood / olife_bench_code (tools/lab/projects/olife/editor_w4a.py)."""
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from olife_proto import client as C  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

FLOOD_CODE = "function on_tick() for i = 1, 100 do print(string.rep('z', 1000)) end end\n"


class Client:
    def __init__(self, port, token, name, timeout=8.0):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.fr = C.framer()
        self.name = name
        self.seq = 0
        self.inbox = []             # (t, name, msg) of every wave-4a message and Disconnect
        self.welcome = None
        self.pos = None
        self.closed = None
        self.last_input = 0.0
        self.iseq = 0
        self.s.sendall(C.frame("Hello", {"proto": C.VERSION, "name": name, "token": token, "engine": "editor_neg"}))
        end = time.time() + timeout
        while self.welcome is None and time.time() < end and not self.closed:
            self.pump(0.2)
        if self.welcome is None:
            raise RuntimeError("%s: no Welcome (%s)" % (name, self.closed))

    def send(self, name, msg):
        self.s.sendall(C.frame(name, msg))

    def req(self, name, **msg):
        self.seq += 1
        msg["seq"] = self.seq
        self.send(name, msg)
        return self.seq

    def edit(self, eid, op, name="", model="", texture=""):
        """UX round 1: EntityEdit (its field `name` clashes with req's first argument)"""
        self.seq += 1
        self.send("EntityEdit", {"seq": self.seq, "eid": eid, "op": op, "name": name, "model": model, "texture": texture})
        return self.seq

    def pump(self, seconds):
        end = time.time() + seconds
        self.s.settimeout(0.05)
        while time.time() < end and not self.closed:
            if self.welcome and time.time() - self.last_input >= 0.1:      # stay "alive" at the world
                self.last_input = time.time()
                self.iseq += 1
                p = self.pos
                self.send("PlayerInput", {"seq": self.iseq, "pos": {"x": p[0], "y": p[1], "z": p[2]},
                                          "rot": {"x": 0.0, "y": 0.0, "z": 0.0}})
            try:
                d = self.s.recv(1 << 20)
            except socket.timeout:
                continue
            except OSError as exc:
                self.closed = "error %s" % exc
                break
            if not d:
                self.closed = "eof"
                break
            self.fr.feed(d)
            while True:
                try:
                    x = self.fr.next()
                except ProtoError as exc:
                    self.closed = "proto %s" % exc
                    return
                if x is None:
                    break
                n = C.NAMES[x[0]]
                m = C.decode_body(*x)
                if n == "Welcome":
                    self.welcome = m
                    self.pos = (m["spawn"]["x"], m["spawn"]["y"], m["spawn"]["z"])
                elif n == "KeepAlive":
                    self.send("KeepAliveReply", {"challenge": m["challenge"]})
                elif n == "PlayerCorrect":
                    self.pos = (m["pos"]["x"], m["pos"]["y"], m["pos"]["z"])
                elif n in ("ScriptState", "ConsoleDelta", "RequestReply", "EntityOwnership", "EntityMeta",
                           "Disconnect"):
                    self.inbox.append((time.time(), n, m))
                    if n == "Disconnect":
                        self.closed = "disconnect %d %s" % (m["code"], m["reason"])

    def reply(self, seq, timeout=3.0):
        end = time.time() + timeout
        while time.time() < end:
            for t, n, m in self.inbox:
                if n == "RequestReply" and m["seq"] == seq:
                    return m
            if self.closed:
                break
            self.pump(0.05)
        return None

    def state(self, eid, seq=None, timeout=3.0):
        end = time.time() + timeout
        while time.time() < end:
            for t, n, m in reversed(self.inbox):
                if n == "ScriptState" and m["eid"] == eid and (seq is None or m["seq"] == seq):
                    return m
            if self.closed:
                break
            self.pump(0.05)
        return None

    def eye(self):
        return {"x": self.pos[0], "y": self.pos[1] + 0.7, "z": self.pos[2]}

    def close(self):
        try:
            self.send("Bye", {"reason": "editor_neg done"})
        except OSError:
            pass
        try:
            self.s.close()
        except OSError:
            pass


def _dir(a, b):
    d = [b[i] - a[i] for i in range(3)]
    n = sum(x * x for x in d) ** 0.5 or 1.0
    return {"x": d[0] / n, "y": d[1] / n, "z": d[2] / n}


def run(gw_port, eid, mob_eid=0, token="olife-carol", name="carol", miss_eid=0):
    """negative: an account that is neither the owner of `eid` nor an admin. -> report {tests, passed, results}"""
    res = []

    def check(case, seq_or_reply, want, extra=None):
        r = seq_or_reply if isinstance(seq_or_reply, dict) or seq_or_reply is None else c.reply(seq_or_reply)
        got = r["code"] if r else None
        res.append(dict({"name": case, "want_code": want, "got_code": got, "reason": r and r["reason"],
                         "ok": got == want}, **(extra or {})))
    c = Client(gw_port, token, name)
    try:
        c.pump(0.5)
        s = c.req("ScriptOpen", eid=eid, edit=True)
        r = c.reply(s)
        st = c.state(eid, s)
        check("open_edit_not_owner", r, 3, {"state_can_edit": st and st["can_edit"], "state_editing": st and st["editing"],
                                            "state_received": st is not None})
        res[-1]["ok"] = res[-1]["ok"] and st is not None and not st["can_edit"] and not st["editing"]
        check("save_not_owner", c.req("ScriptSave", eid=eid, code="print('pwned')"), 3)
        check("run_not_owner", c.req("ScriptRun", eid=eid), 3)
        check("stop_not_owner", c.req("ScriptStop", eid=eid), 3)
        # UX round 1: entity settings / delete of somebody else's entity -> 3; bad values on the own bench -> 15
        c.pump(1.0)                         # the request bucket (10/s, burst 20) refills: these are not rate tests
        check("delete_not_owner", c.edit(eid, 1, "", "", ""), 3)
        check("rename_not_owner", c.edit(eid, 2, "pwned", "", ""), 3)
        check("look_not_owner", c.edit(eid, 3, "", "olife_bone", ""), 3)
        if miss_eid:
            check("look_bad_model", c.edit(miss_eid, 3, "", "../evil", ""), 15)
            check("look_bad_texture", c.edit(miss_eid, 3, "", "", "x:y"), 15)
            check("rename_bad_name", c.edit(miss_eid, 2, "   ", "", ""), 15)
            check("edit_bad_op", c.edit(miss_eid, 9, "", "", ""), 15)
        check("delete_unknown_eid", c.edit(999999, 1, "", "", ""), 1)
        c.pump(2.0)
        check("release_not_holder", c.req("ScriptLockRelease", eid=eid, close=False), 5)
        check("open_unknown_eid", c.req("ScriptOpen", eid=999999, edit=False), 1)
        if mob_eid:
            check("open_not_scripted", c.req("ScriptOpen", eid=mob_eid, edit=False), 2)
        o = c.eye()
        z = {"x": 0.0, "y": 0.0, "z": 0.0}
        check("tool_zero_dir", c.req("ToolUse", tool=2, action=2, target=eid, origin=o, dir=z), 14)
        check("tool_bad_tool", c.req("ToolUse", tool=9, action=1, target=eid, origin=o, dir={"x": 1.0, "y": 0.0, "z": 0.0}), 13)
        check("tool_injector_grab", c.req("ToolUse", tool=1, action=2, target=eid, origin=o, dir={"x": 1.0, "y": 0.0, "z": 0.0}), 13)
        far = {"x": o["x"] + 50.0, "y": o["y"], "z": o["z"]}
        check("tool_origin_far", c.req("ToolUse", tool=2, action=2, target=eid, origin=far, dir={"x": 1.0, "y": 0.0, "z": 0.0}), 14)
        up = {"x": 0.0, "y": 1.0, "z": 0.0}
        # a target in reach (a bench that does not move: miss_eid), but the ray goes up
        check("tool_ray_miss", c.req("ToolUse", tool=2, action=2, target=miss_eid or eid, origin=o, dir=up), 7)
        check("release_not_holding", c.req("ToolUse", tool=2, action=3, target=eid, origin=o, dir=up), 11)
        # rate: 40 requests at once -> the bucket (burst 20, 10/s) refuses some with 9
        seqs = [c.req("ScriptOpen", eid=eid, edit=False) for _ in range(40)]
        codes = [((c.reply(q, 4.0) or {}).get("code")) for q in seqs]
        res.append({"name": "rate_40_opens", "want_code": 9, "got_code": codes.count(9),
                    "ok": codes.count(9) >= 10 and codes.count(0) >= 10 and None not in codes,
                    "codes": {str(k): codes.count(k) for k in set(codes)}})
        alive = c.closed is None
    finally:
        c.close()
    return {"tests": len(res), "passed": sum(1 for x in res if x["ok"]), "results": res, "client_alive": alive}


def flood(gw_port, eid, seconds=6.0, token="olife-carol", name="carol"):
    """console flood: carol owns `eid`; runs a script printing 100 x 1000 B per tick and stays subscribed.
    -> ConsoleDelta counts/sizes (bounded: <= 16 lines and <= 4 KiB of text per delta, <= 4 deltas/s), dropped > 0"""
    c = Client(gw_port, token, name)
    try:
        s = c.req("ScriptOpen", eid=eid, edit=True)
        r_open = c.reply(s)
        r_save = c.reply(c.req("ScriptSave", eid=eid, code=FLOOD_CODE))
        r_run = c.reply(c.req("ScriptRun", eid=eid))
        t0 = time.time()
        n0 = len(c.inbox)
        c.pump(seconds)
        deltas = [(t, m) for t, n, m in c.inbox[n0:] if n == "ConsoleDelta" and m["eid"] == eid]
        lines = [len(m["lines"]) for _, m in deltas]
        tbytes = [sum(len(l["text"].encode("utf-8")) for l in m["lines"]) for _, m in deltas]
        dropped = sum(m["dropped"] for _, m in deltas)
        r_stop = c.reply(c.req("ScriptStop", eid=eid))
        r_rel = c.reply(c.req("ScriptLockRelease", eid=eid, close=True))
        el = time.time() - t0
    finally:
        c.close()
    rep = {"seconds": round(el, 2), "deltas": len(deltas), "deltas_per_s": round(len(deltas) / el, 2),
           "lines_max": max(lines or [0]), "lines_total": sum(lines), "text_bytes_max": max(tbytes or [0]),
           "dropped": dropped, "open": r_open and r_open["code"], "save": r_save and r_save["code"],
           "run": r_run and r_run["code"], "stop": r_stop and r_stop["code"], "release": r_rel and r_rel["code"]}
    rep["ok"] = (rep["open"] == 0 and rep["save"] == 0 and rep["run"] == 0 and rep["stop"] == 0 and len(deltas) > 0
                 and rep["lines_max"] <= 16 and rep["text_bytes_max"] <= 4096 and rep["deltas_per_s"] <= 4.5)
    return rep


def set_code(gw_port, eid, code, run_it=True, token="olife-carol", name="carol"):
    """owner sets the code of eid and runs it (olife_restart_editor) -> replies"""
    c = Client(gw_port, token, name)
    try:
        out = {"open": c.reply(c.req("ScriptOpen", eid=eid, edit=True))}
        out["save"] = c.reply(c.req("ScriptSave", eid=eid, code=code))
        if run_it:
            out["run"] = c.reply(c.req("ScriptRun", eid=eid))
        out["release"] = c.reply(c.req("ScriptLockRelease", eid=eid, close=True))
        c.pump(0.3)
    finally:
        c.close()
    return {k: (v and v["code"]) for k, v in out.items()}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", type=int, required=True)
    ap.add_argument("--eid", type=int, required=True)
    ap.add_argument("--own", type=int, default=0)
    ap.add_argument("--json")
    a = ap.parse_args()
    rep = {"negative": run(a.gateway, a.eid)}
    if a.own:
        rep["flood"] = flood(a.gateway, a.own)
    s = json.dumps(rep, indent=1, ensure_ascii=False)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            f.write(s)
    print(s)


if __name__ == "__main__":
    main()
