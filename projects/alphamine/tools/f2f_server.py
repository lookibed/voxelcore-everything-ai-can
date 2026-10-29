#!/usr/bin/env python3
"""Lockstep (steppable) Java Alpha server for F2F tests: client library and harness driver (agents/F2F.md 9).

The server is started with `--f2f PORT` (server_v.py --f2f 25593, ref/start_server.ps1 -F2F 25593) and then never
ticks by itself. One JSON line per request / response over TCP 127.0.0.1:PORT (inside WSL through f2f_relay.ps1,
like the client F2F):
  hello                                   {impl:"server", version, port, tick, total_ticks, seed, freeze}
  mode   {seed}                           reseed World.rand / updateLCG / Entity.rand by id / Math.random replacement,
                                          next entity id rounded up to 1000, scheduled ticks renumbered, tracker and
                                          keepalive phases 0, tick = 0
  step   {ticks=1, barriers:{user: K}}    wait until the user's connection read K bytes (the client's tx_total), then
                                          N ticks, every tick flushed synchronously (data queue, then chunk queue)
                                          -> {tick, total_ticks, clients:{user:{tx_total, rx_total, ...}}, wait_ms, tick_ms}
  freeze {random_ticks, plants, fluids, scheduled, autosave}
  state  {}                               players, entities, loaded chunks + FNV hash of their blocks/meta, generators
  quit

Lockstep order (one "tick" of the harness):
  client: step {ticks:1, frames, rx_bytes: <server tx_total of the previous server step>}
          (Java: the barrier and tx_total are in the step reply; VoxelCore: `sync {rx_bytes}` before the engine step and
          `sync {}` after it - the engine answers `step` itself, the pack answers `sync`)
  server: step {ticks:1, barriers: {user: <client tx_total>}}
So client tick T sends, server tick T processes exactly those bytes and answers, client tick T+1 processes exactly the
answer. No wall clock anywhere: no pacing, `wait` = wait_check + lockstep ticks, `realtime` is meaningless.

    from f2f_server import F2FServer, Lockstep
    srv = F2FServer(25593)
    ls = Lockstep(srv, call, impl="java", user="Player")    # call(cmd, args, timeout) -> reply dict of the client
    ls.run("connect"); ls.run("wait", {"world": True}); ls.mode({"seed": 1}); ls.step(100, 1)
Command line:
    python3 tools/alphamine/f2f_server.py 25593 hello
    python3 tools/alphamine/f2f_server.py 25593 state
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import f2f_client  # noqa: E402

DEFAULT_PORT = 25593


class F2FServerError(RuntimeError):
    pass


class F2FServer:
    """Connection to the lockstep server (F2FServer.java)."""

    def __init__(self, port=DEFAULT_PORT, timeout=120.0, connect_timeout=30.0):
        self.port = int(port)
        self.c = f2f_client.F2F(self.port, timeout=timeout, connect_timeout=connect_timeout)
        self.last = None

    def call(self, cmd, args=None, timeout=None):
        rep = self.c.raw(cmd, args or {}, timeout=timeout)
        if not rep.get("ok"):
            raise F2FServerError("server %s: %s (%s)" % (cmd, rep.get("error"), rep.get("where")))
        return rep.get("result")

    def hello(self):
        return self.call("hello")

    def mode(self, seed=0, **kw):
        return self.call("mode", dict(seed=seed, **kw))

    def step(self, ticks=1, barriers=None, timeout_ms=30000):
        a = {"ticks": ticks, "timeout_ms": timeout_ms}
        if barriers is not None:
            a["barriers"] = barriers
        self.last = self.call("step", a, timeout=timeout_ms / 1000.0 + 60)
        return self.last

    def freeze(self, **kw):
        return self.call("freeze", kw)

    def state(self):
        return self.call("state")

    def quit(self):
        try:
            return self.call("quit", timeout=30)
        except (ConnectionError, OSError, F2FServerError):
            return None

    def close(self):
        self.c.close()


class Lockstep:
    """One F2F client + the lockstep server: every client tick is followed by exactly one server tick.

    call(cmd, args, timeout=None) -> reply dict {ok, result|error} of the client (impl "java" or "vc"). The client's
    username is the barrier key on the server (Java: Session.username, VoxelCore: alphamine_f2f.json "user")."""

    def __init__(self, server, call, impl, user="Player", log=None):
        self.srv, self.call, self.impl, self.user = server, call, impl, user
        self.rx = 0          # cumulative bytes the server sent to this client (server step reply)
        self.tx = 0          # cumulative bytes the client handed to its connection (client reply)
        self.ticks = 0       # lockstep ticks driven by this object
        self.server_ms = 0.0
        self.client_ms = 0.0
        self.waits = {"client_ms": 0.0, "server_ms": 0.0}
        self.log = log
        # VoxelCore: mouse deltas wait for the next rendering pass. The engine consumes queued input in every pass of
        # `step`, but the pack applies the look only in a rendered frame (frame hook), so a delta before a frames:0
        # pass (intermediate tick of a lockstep step{N,1}) would be lost; Java accumulates it until the next frame.
        self.pending_look = [0, 0]

    # ------------------------------------------------------------------ primitives
    def _c(self, cmd, args=None, timeout=None):
        t0 = time.time()
        r = self.call(cmd, args or {}, timeout=timeout)
        self.client_ms += (time.time() - t0) * 1000
        return r

    def _net(self, res):
        if isinstance(res, dict) and res.get("tx_total") is not None:
            self.tx = int(res["tx_total"])
            if res.get("user"):
                self.user = res["user"]

    def sync(self, rx=None, keepalive=None):
        a = {}
        if rx is not None:
            a["rx_bytes"] = rx
        if keepalive is not None:
            a["keepalive"] = keepalive
        r = self._c("sync", a)
        if r.get("ok"):
            self._net(r["result"])
            self.waits["client_ms"] += float(r["result"].get("waited_ms") or 0)
        return r

    def server_tick(self):
        t0 = time.time()
        res = self.srv.step(1, {self.user: self.tx})
        self.server_ms += (time.time() - t0) * 1000
        self.waits["server_ms"] += float(res.get("wait_ms") or 0)
        c = (res.get("clients") or {}).get(self.user)
        if c:
            self.rx = int(c["tx_total"])
        self.ticks += 1
        return res

    def tick(self, frames=1, partial=0.0, gui=None):
        """One lockstep tick: client tick (+frames) with the rx barrier, then one server tick. `gui`: the client tick
        is a `gui` command (event + step{1, frames})."""
        if self.impl == "java":
            if gui is not None:
                r = self._c("gui", dict(gui, ticks=1, frames=frames, rx_bytes=self.rx))
            else:
                r = self._c("step", {"ticks": 1, "frames": frames, "partial": partial, "rx_bytes": self.rx})
            if not r.get("ok"):
                return r
            self._net(r["result"])
        else:
            s = self.sync(rx=self.rx)
            if not s.get("ok"):
                return s
            if frames > 0 and self.pending_look != [0, 0]:
                li = self._c("input", {"mouse": {"dx": self.pending_look[0], "dy": self.pending_look[1]}})
                if not li.get("ok"):
                    return li
                self.pending_look = [0, 0]
            handled = None
            if gui is not None:
                h = self._c("gui", gui)
                if not h.get("ok"):
                    return h
                handled = h.get("result")
            # frames=0: the engine still runs one pass without rendering; the alpha tick then runs in the pass or in
            # the `sync` below (f2f.lua handle() catches up the ticks due by the virtual clock)
            r = self._c("step", {"ticks": 1, "frames": frames, "partial": partial})
            if not r.get("ok"):
                return r
            s = self.sync()
            if not s.get("ok"):
                return s
            r = {"ok": True, "result": dict(r["result"], tx_total=s["result"].get("tx_total"),
                                            rx_total=s["result"].get("rx_total"), screen=s["result"].get("screen"))}
            if handled is not None:
                r["result"]["handled"] = handled
        self.server_tick()
        r["result"]["server_tick"] = self.srv.last.get("tick")
        return r

    def step(self, ticks=1, frames=1, partial=0.0):
        """`step {ticks:N, frames:M}` in lockstep: N lockstep ticks, the frames rendered after the last one (as the
        Java F2FAgent.step does: N ticks, then M frames). ticks=0: frames only, the server does not tick."""
        if ticks <= 0:
            return self._c("step", {"ticks": 0, "frames": frames, "partial": partial})
        r = None
        for i in range(ticks):
            r = self.tick(frames=frames if i == ticks - 1 else 0, partial=partial)
            if not r.get("ok"):
                return r
        return r

    # ------------------------------------------------------------------ composite commands
    def connect(self, args=None, timeout=15.0):
        r = self._c("connect", args or {})
        if not r.get("ok"):
            return r
        self._net(r["result"])
        if self.impl == "vc":
            # the pack sends Packet2Handshake from the engine's connect callback (main thread, next engine pass):
            # passes without ticks until it is out, so the server reads it in a fixed tick
            end = time.time() + timeout
            while True:
                s = self.sync()
                if not s.get("ok"):
                    return s
                if self.tx > 0 or s["result"].get("net_state") in ("error", "closed") or time.time() > end:
                    break
                st = self._c("step", {"ticks": 0, "frames": 0})
                if not st.get("ok"):
                    return st
            r["result"]["tx_total"] = self.tx
        if not self.tx:
            return {"ok": False, "error": "connect: no handshake sent (tx_total 0): %s" % json.dumps(r.get("result"))}
        return r

    def wait(self, args, max_frames=None):
        """`wait` in lockstep: wait_check (no stepping) + lockstep ticks until the condition holds."""
        cond = {k: v for k, v in args.items() if k not in ("max_frames", "settle", "realtime", "partial")}
        max_frames = int(args.get("max_frames", 2000) if max_frames is None else max_frames)
        settle = int(args.get("settle", 0))
        partial = args.get("partial", 0)
        t0 = time.time()
        used = 0
        rep = self._c("wait_check", dict(cond, begin=True))
        if not rep.get("ok"):
            return rep
        while not rep["result"].get("done"):
            res = rep["result"]
            if res.get("fatal"):
                return {"ok": False, "error": "%s after %d frames: %s" % (res["fatal"], used, res.get("describe"))}
            if used >= max_frames:
                return {"ok": False, "error": "timeout after %d lockstep ticks (%.1f s): %s; %s" % (
                    used, time.time() - t0, res.get("describe"), res.get("why"))}
            st = self.tick(frames=1, partial=partial)
            if not st.get("ok"):
                return st
            used += 1
            rep = self._c("wait_check", cond)
            if not rep.get("ok"):
                return rep
        if settle > 0:
            st = self.step(settle, 1, partial)
            if not st.get("ok"):
                return st
        res = dict(rep["result"])
        res.update(frames=used, wall_s=round(time.time() - t0, 2), server_tick=(self.srv.last or {}).get("tick"))
        return {"ok": True, "result": res}

    def mode(self, args, server_seed=None):
        """Client `mode` (idle keepalive off) and server `mode` at the same lockstep point."""
        a = dict(args, keepalive=False)
        r = self._c("mode", a)
        if not r.get("ok"):
            return r
        seed = args.get("seed", 0) if server_seed is None else server_seed
        r["result"]["server"] = self.srv.mode(int(seed))
        return r

    def run(self, cmd, args=None, timeout=None):
        """One scenario step in lockstep: commands that advance the game go through the lockstep loop, the rest
        straight to the client."""
        args = dict(args or {})
        if cmd == "step":
            return self.step(int(args.get("ticks", 1)), int(args.get("frames", 1)), float(args.get("partial", 0)))
        if cmd == "wait":
            return self.wait(args)
        if cmd == "gui":
            frames = int(args.pop("frames", 1))
            ticks = int(args.pop("ticks", 1))
            if ticks != 1:
                return {"ok": False, "error": "lockstep gui: only ticks=1"}
            r = self.tick(frames=frames, gui=args)
            if r.get("ok") and self.impl == "vc" and "screen" not in r["result"]:
                r["result"]["screen"] = (self._c("state", {"radius": 0}).get("result") or {}).get("screen")
            return r
        if cmd == "connect":
            return self.connect(args)
        if cmd == "input" and self.impl == "vc" and isinstance(args.get("mouse"), dict) and (
                args["mouse"].get("dx") or args["mouse"].get("dy")):
            m = dict(args["mouse"])
            self.pending_look[0] += int(m.pop("dx", 0) or 0)
            self.pending_look[1] += int(m.pop("dy", 0) or 0)
            rest = dict(args)
            if m:
                rest["mouse"] = m
            else:
                rest.pop("mouse")
            if rest:
                r = self._c("input", rest, timeout=timeout)
                if not r.get("ok"):
                    return r
            return {"ok": True, "result": {"deferred_look": list(self.pending_look)}}
        if cmd == "mode":
            return self.mode(args)
        return self._c(cmd, args, timeout=timeout)

    def report(self):
        return {"ticks": self.ticks, "tx": self.tx, "rx": self.rx, "user": self.user,
                "client_ms": round(self.client_ms, 1), "server_ms": round(self.server_ms, 1),
                "barrier_wait_ms": {k: round(v, 1) for k, v in self.waits.items()}}


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    s = F2FServer(int(argv[1]))
    args = json.loads(argv[3]) if len(argv) > 3 else {}
    print(json.dumps(s.c.raw(argv[2], args), ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
