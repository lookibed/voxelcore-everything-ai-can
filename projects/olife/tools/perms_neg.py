"""Olife UX A1: protocol tests of rights / fork / friends without the UI (like editor_neg.py, the same Client).
  admin_matrix(gw, eid, sacrificial, bench_pos) — an admin (Attach perms or `olife.admins`) passes every right of an
        entity whose rules are all "owner": move (grab+release), read, edit (+save), run (+stop), look, fork (+delete
        of the fork), destroy (sacrificial bench), storage_read/write (PermsCheck) -> all 0
  negative(gw, eid, mob_eid, own_eid) — a stranger and bad values: rights set by a non-owner 3, bad action/audience/
        list account 15, unknown entity 1, not a bench 2, check bad action 15, fork unknown 1, friends: self/unknown/
        empty 16, accept/deny/remove without a request 17, bad op 15; fork limit (11 forks a minute -> 18)
Used by the lab steps olife_perms_admin / olife_perms_neg (tools/lab/projects/olife/olife_a1.py)."""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from editor_neg import Client  # noqa: E402

ACTIONS = ["move", "read_code", "edit_code", "run", "appearance", "clone", "destroy", "storage_read", "storage_write"]


class PClient(Client):
    """editor_neg.Client keeps RequestReply (A1 replies too); the fork id comes from the reason "forked #<eid>"."""

    def fork(self, eid, name=""):
        """EntityFork (its field `name` clashes with req's first argument)"""
        self.seq += 1
        self.send("EntityFork", {"seq": self.seq, "eid": eid, "name": name})
        return self.seq


def _fork_eid(r):
    if r and r.get("code") == 0 and "#" in (r.get("reason") or ""):
        try:
            return int(r["reason"].split("#")[1].split()[0])
        except ValueError:
            return None
    return None


def _dir(o, p):
    d = [p[0] - o["x"], p[1] - o["y"], p[2] - o["z"]]
    n = sum(x * x for x in d) ** 0.5 or 1.0
    return {"x": d[0] / n, "y": d[1] / n, "z": d[2] / n}


def admin_matrix(gw, eid, sacrificial, bench_pos, token="olife-dev", name="dev"):
    c = PClient(gw, token, name)
    res = {}
    try:
        c.pump(0.5)
        o = c.eye()
        d = _dir(o, bench_pos)
        r = c.reply(c.req("ToolUse", tool=2, action=2, target=eid, origin=o, dir=d))
        res["move"] = r and r["code"]
        if res["move"] == 0:
            c.reply(c.req("ToolUse", tool=2, action=3, target=eid, origin=o, dir=d))
        c.pump(0.2)
        r = c.reply(c.req("ScriptOpen", eid=eid, edit=False))
        res["read_code"] = r and r["code"]
        c.reply(c.req("ScriptLockRelease", eid=eid, close=True))
        r = c.reply(c.req("ScriptOpen", eid=eid, edit=True))
        res["edit_code"] = r and r["code"]
        if res["edit_code"] == 0:
            s = c.reply(c.req("ScriptSave", eid=eid, code="-- admin was here\nfunction on_tick(dt) end\n"))
            res["edit_code_save"] = s and s["code"]
        c.reply(c.req("ScriptLockRelease", eid=eid, close=True))
        r = c.reply(c.req("ScriptRun", eid=eid))
        res["run"] = r and r["code"]
        if res["run"] == 0:
            c.reply(c.req("ScriptStop", eid=eid))
        res["appearance"] = (c.reply(c.edit(eid, 3, "", "olife_bench", "")) or {}).get("code")
        c.pump(1.0)                                     # request bucket
        r = c.reply(c.fork(eid))
        res["clone"] = r and r["code"]
        fe = _fork_eid(r)
        if fe:
            res["clone_fork_eid"] = fe
            res["clone_fork_deleted"] = (c.reply(c.edit(fe, 1)) or {}).get("code")
        res["destroy"] = (c.reply(c.edit(sacrificial, 1)) or {}).get("code")
        for i, a in ((8, "storage_read"), (9, "storage_write")):
            res[a] = (c.reply(c.req("PermsCheck", eid=eid, action=i)) or {}).get("code")
        alive = c.closed is None
    finally:
        c.close()
    cells = {a: res.get(a) for a in ACTIONS}
    return {"cells": cells, "extra": {k: v for k, v in res.items() if k not in cells}, "client_alive": alive,
            "ok": all(v == 0 for v in cells.values()) and alive}


def negative(gw, eid, mob_eid=0, own_eid=0, token="olife-carol", name="carol", admin_token="olife-dev"):
    """eid: a bench of another account (stranger rights: defaults); own_eid: a bench of `name` (bad values)"""
    out = []

    def check(case, r, want):
        got = r["code"] if r else None
        out.append({"name": case, "want_code": want, "got_code": got, "reason": r and r["reason"], "ok": got == want})
    c = PClient(gw, token, name)
    try:
        c.pump(0.5)
        check("perms_set_not_owner", c.reply(c.req("EntityPermsSet", eid=eid, action=1, audience=3, list=[])), 3)
        if own_eid:
            check("perms_bad_action_0", c.reply(c.req("EntityPermsSet", eid=own_eid, action=0, audience=3, list=[])), 15)
            check("perms_bad_action_10", c.reply(c.req("EntityPermsSet", eid=own_eid, action=10, audience=3, list=[])), 15)
            check("perms_bad_audience", c.reply(c.req("EntityPermsSet", eid=own_eid, action=1, audience=4, list=[])), 15)
            check("perms_bad_list_name", c.reply(c.req("EntityPermsSet", eid=own_eid, action=1, audience=2,
                                                        list=["ok_name", "bad name!"])), 15)
            check("perms_own_ok", c.reply(c.req("EntityPermsSet", eid=own_eid, action=2, audience=0, list=[])), 0)
            check("check_bad_action", c.reply(c.req("PermsCheck", eid=own_eid, action=0)), 15)
        check("perms_unknown_eid", c.reply(c.req("EntityPermsSet", eid=999999, action=1, audience=3, list=[])), 1)
        if mob_eid:
            check("perms_not_bench", c.reply(c.req("EntityPermsSet", eid=mob_eid, action=1, audience=3, list=[])), 2)
        c.pump(1.2)
        check("check_stranger_destroy", c.reply(c.req("PermsCheck", eid=eid, action=7)), 3)
        check("check_stranger_read", c.reply(c.req("PermsCheck", eid=eid, action=2)), 0)
        check("fork_stranger_default", c.reply(c.fork(eid)), 3)
        check("fork_unknown_eid", c.reply(c.fork(999999)), 1)
        check("look_stranger", c.reply(c.edit(eid, 3, "", "olife_bone", "")), 3)
        check("grab_rights_before_ray", c.reply(c.req("ToolUse", tool=2, action=2, target=eid, origin=c.eye(),
                                                      dir={"x": 0.0, "y": 1.0, "z": 0.0})), 7)
        c.pump(1.2)
        check("friend_self", c.reply(c.req("FriendRequest", op=1, account=name)), 16)
        check("friend_unknown", c.reply(c.req("FriendRequest", op=1, account="nobody_zz")), 16)
        check("friend_empty", c.reply(c.req("FriendRequest", op=1, account="")), 16)
        check("friend_bad_name", c.reply(c.req("FriendRequest", op=1, account="a b")), 16)
        check("friend_accept_none", c.reply(c.req("FriendRequest", op=2, account="bob")), 17)
        check("friend_deny_none", c.reply(c.req("FriendRequest", op=3, account="bob")), 17)
        check("friend_remove_none", c.reply(c.req("FriendRequest", op=4, account="bob")), 17)
        check("friend_bad_op", c.reply(c.req("FriendRequest", op=9, account="bob")), 15)
        check("friend_list", c.reply(c.req("FriendRequest", op=5, account="")), 0)
        alive = c.closed is None
    finally:
        c.close()
    # fork limit: an admin forks 11 times in a minute -> the 11th is 18; the forks are deleted again
    a = PClient(gw, admin_token, "dev")
    codes, made = [], []
    try:
        a.pump(0.3)
        for _ in range(11):
            r = a.reply(a.fork(eid, "limit_fork"))
            codes.append(r and r["code"])
            fe = _fork_eid(r)
            if fe:
                made.append(fe)
            a.pump(0.15)
        a.pump(1.0)
        deleted = []
        for fe in made:
            deleted.append((a.reply(a.edit(fe, 1)) or {}).get("code"))
            a.pump(0.15)
        alive_a = a.closed is None
    finally:
        a.close()
    out.append({"name": "fork_limit_11_per_min", "want_code": 18, "got_code": codes[-1] if codes else None,
                "codes": codes, "deleted": deleted, "ok": codes[:10] == [0] * 10 and codes[10:] == [18]
                and all(x == 0 for x in deleted)})
    return {"tests": len(out), "passed": sum(1 for x in out if x["ok"]), "results": out,
            "client_alive": alive and alive_a}
