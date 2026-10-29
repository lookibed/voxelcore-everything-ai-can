"""Возможности проекта alphamine (lab call alphamine.<имя>). Всё, что знает про Minecraft, живёт здесь, не в ядре.

  alphamine.wait     {lease, <условия F2F wait>, max_frames=2000, settle=0, realtime=true}
                     engine: цикл харнесса wait_check -> step{1,1} (50 мс стены на такт), как alpha_vc.wait;
                     ref_app: команда wait Java-клиента как есть.
  alphamine.gui      {lease, click|key|chars..., ticks=1, frames=1} — gui + step (engine), как Java F2FAgent.gui.
  alphamine.session  {world="world_a", size?, ref_app=false, connect=true, ttl?} — аренды server + engine
                     (+ ref_app), старт, connect обоих клиентов к своему серверу; ответ — имена аренд и порты.
  lab perf alphamine perf_normal|perf_walk  (этап 3а) — замер на простаивающем ПК: сервер (свежая копия мира) +
                     аренда rt (тестовая сборка, часы realtime, ввод изолирован), профайлер пака + autowalk,
                     CSV -> tools/alphamine/perf/perflib.py (perf.csv, perf_report.md, perf_summary.json, график).
"""
import json
import re
import time

PLUGIN_VERSION = 3
LWJGL_DIGITS = {str(c): str((c - 1) % 10) for c in range(2, 12)}   # KEY_1 = 2 ... KEY_0 = 11 (F2F.md 7.1)


def _kind(ctx, lease):
    return ctx.info(lease)["kind"]


def wait_loop(call, kind, args, timeout=600):
    """F2F wait. engine: обработчик пака не шагает кадры сам — цикл wait_check{begin} -> [50 мс стены] step{1,1} ->
    wait_check (как alpha_vc.wait / F2FAgent.waitFor у Java, realtime); ref_app: команда wait Java-клиента как есть.
    call(cmd, args, timeout) -> ответ F2F."""
    args = dict(args)
    if kind != "engine":
        return call("wait", args, float(args.pop("timeout", timeout)))
    max_frames = int(args.pop("max_frames", 2000))
    realtime = args.pop("realtime", True)
    settle = int(args.pop("settle", 0))
    partial = args.pop("partial", 0)
    args.pop("timeout", None)
    cond = dict(args)
    t0 = time.time()
    used = 0
    rep = call("wait_check", dict(cond, begin=True), 60)
    if not rep.get("ok"):
        return rep
    nxt = time.time()
    last = None
    while not rep["result"].get("done"):
        r = rep["result"]
        if r.get("fatal"):
            return {"ok": False, "where": "wait", "error": "%s after %d frames: %s" % (r["fatal"], used,
                                                                                     r.get("describe"))}
        if used >= max_frames:
            return {"ok": False, "where": "wait", "error": "timeout after %d frames (%.1f s): %s; not met: %s" % (
                used, time.time() - t0, r.get("describe"), r.get("why"))}
        if realtime:
            nxt += 0.05
            d = nxt - time.time()
            if d > 0:
                time.sleep(d)
            elif d < -1.0:
                nxt = time.time()
        last = call("step", {"ticks": 1, "frames": 1, "partial": partial}, 60)
        if not last.get("ok"):
            return last
        used += 1
        rep = call("wait_check", cond, 60)
        if not rep.get("ok"):
            return rep
    if settle > 0:
        last = call("step", {"ticks": settle, "frames": 1}, 60)
        rep = call("wait_check", cond, 60)
    r = rep["result"]
    return {"ok": True, "result": {"tick": r.get("tick"), "alpha_tick": r.get("alpha_tick"),
                                   "frame": ((last or {}).get("result") or {}).get("frame"),
                                   "frames": used, "screen": r.get("screen"), "map_chunks": r.get("map_chunks"),
                                   "new_chunks": r.get("new_chunks"), "wall_s": round(time.time() - t0, 2)}}


def wait(ctx, args):
    lease = args.pop("lease")
    return wait_loop(lambda c, a, t: ctx.f2f(lease, c, a, timeout=t), _kind(ctx, lease), args)


def gui(ctx, args):
    lease = args.pop("lease")
    if _kind(ctx, lease) != "engine":
        return ctx.f2f(lease, "gui", args)
    rep = ctx.f2f(lease, "gui", args)
    if not rep.get("ok"):
        return rep
    st = ctx.f2f(lease, "step", {"ticks": int(args.get("ticks", 1)), "frames": int(args.get("frames", 1))})
    if not st.get("ok"):
        return st
    r = dict(st["result"])
    r["screen"] = ((ctx.f2f(lease, "state", {"radius": 0}).get("result")) or {}).get("screen")
    r["handled"] = rep.get("result")
    return {"ok": True, "result": r}


def session(ctx, args):
    ttl = args.get("ttl")
    out = {"leases": {}}
    srv = ctx.lease("server", params={"world": args.get("world", "world_a")}, ttl=ttl)["lease"]
    out["leases"]["server"] = srv["name"]
    addr = "127.0.0.1:%d" % srv["ports"]["game"]
    out["server_start"] = ctx.start(srv["name"])["timing"]
    eng_params = {"server": addr}
    if args.get("size"):
        eng_params["size"] = args["size"]
    eng = ctx.lease("engine", params=eng_params, ttl=ttl)["lease"]
    out["leases"]["engine"] = eng["name"]
    out["engine_start"] = ctx.start(eng["name"])["timing"]
    if args.get("ref_app"):
        ref = ctx.lease("ref_app", params=dict(eng_params), ttl=ttl)["lease"]
        out["leases"]["ref_app"] = ref["name"]
        out["ref_app_start"] = ctx.start(ref["name"])["timing"]
    if args.get("connect", True):
        for k in ("engine", "ref_app"):
            if k in out["leases"]:
                out["connect_" + k] = ctx.f2f(out["leases"][k], "connect", {})
    return out


# ---------------------------------------------------------------------------------------------- сценарии (этап 2)
# Хуки интерпретатора labcore/scenario.py: всё, что знает про Minecraft — здесь. Семантика шагов — как у
# tools/alphamine/run_vc_scenario.py / e2e_run.py (приёмка: побайтно те же sha снимков).
def sc_info(scn):
    """Мир сервера: setup.server.world (свой или базового), у таймлайна setup.world; по умолчанию world_a
    (шаговые, как run_vc_scenario) / world_b (таймлайн, как e2e_run)."""
    s = scn
    while s is not None:
        st = s.setup or {}
        srv = st.get("server") if isinstance(st.get("server"), dict) else {}
        w = (srv or {}).get("world") or st.get("world")
        if w:
            return {"world": w}
        s = s.base
    return {"world": "world_b" if scn.kind == "timeline" else "world_a"}


def sc_start(sx):
    scn = sx.scn
    world = sc_info(scn)["world"]
    b = scn.raw.get("client_b") or {}
    if b and sx.lockstep:
        raise RuntimeError("lockstep: a second client (client_b) is not supported (as in run_vc_scenario --legacy)")
    srv_params = {"world": world}
    if b.get("user"):
        srv_params["ops"] = [b["user"]]
    if sx.lockstep:
        # пошаговый сервер (F2F.md §9): --f2f <порт аренды> — порт известен только после создания аренды
        srv = sx.lease("server", role="server", params=srv_params, start=False)
        t0 = time.time()
        st = sx.lab.start(srv, owner=sx.owner, params={"f2f_args": ["--f2f", str(sx.port(srv, "f2f"))]})
        sx.job.setdefault("timing", {})["start_server"] = round(time.time() - t0, 2)
        sx.job.setdefault("starts", {})["server"] = {k: st.get(k) for k in ("pid", "ports", "exe", "timing")}
    else:
        srv = sx.lease("server", role="server", params=srv_params)
    addr = "127.0.0.1:%d" % sx.port(srv, "game")
    sx.data["server_addr"] = addr
    if b:
        # второй Java-клиент на том же сервере (layer_entities_player): шаги, затем простой (свой keepalive)
        cb = sx.lease("ref_app", role="client_b", params={"server": addr, "user": b.get("user", "AlphaMineB")})
        for i, st in enumerate(b.get("steps", [])):
            cmd, args = st["cmd"], dict(st.get("args") or {})
            if cmd == "look":
                r = sc_look(sx, args, st, lease=cb)
            elif cmd == "wait":
                r = wait_loop(lambda c, a, t: sx.raw(c, a, t, lease=cb), "ref_app", args, st.get("limit", 600))
            else:
                r = sx.raw(cmd, args, st.get("limit", 600), lease=cb)
            sx.log("B%2d %-8s %s" % (i, cmd, json.dumps(r, ensure_ascii=False, default=str)[:150]))
            if not r.get("ok"):
                raise RuntimeError("client_b step %d %s: %s" % (i, cmd, r.get("error")))
    kind = {"java": "ref_app", "vc": "engine"}[sx.impl]
    cp = {"server": addr}
    if sx.lockstep:
        cp["f2f_idle"] = False      # простойный keepalive демона: пакет в случайный такт сервера
    sx.client = sx.lease(kind, role="client", params=cp)
    if sx.lockstep:
        ls_start(sx, srv)


# ---------------------------------------------------------------------------------------------- lockstep (F2F.md §9)
# Порядок такта, барьеры, отложенная мышь VoxelCore, connect/wait/mode — tools/alphamine/f2f_server.Lockstep (тот же
# класс, что у старых раннеров run_vc_scenario/e2e_run --lockstep: побайтно та же последовательность команд), только
# транспорт — аренды демона: клиент — sx.raw, сервер — F2F-порт аренды server (пул демона, журнал прогона).
def _f2f_server_mod():
    import os
    import sys
    d = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))),
                     "alphamine")
    if d not in sys.path:
        sys.path.insert(0, d)
    import f2f_server
    return f2f_server


class LabServer:
    """F2FServer поверх аренды server (тот же интерфейс, что f2f_server.F2FServer: hello/mode/step/freeze/state/quit)."""

    def __init__(self, sx, lease):
        self.sx, self.lease, self.last = sx, lease, None

    def call(self, cmd, args=None, timeout=None):
        r = self.sx.raw(cmd, args or {}, float(timeout or 120), lease=self.lease)
        if not r.get("ok"):
            raise RuntimeError("server %s: %s (%s)" % (cmd, r.get("error"), r.get("where")))
        return r.get("result")

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


def ls_start(sx, srv):
    """Связать клиент сессии с пошаговым сервером: hello сервера, sync {keepalive:false} клиента (простойный KeepAlive
    выключен с самого начала — как start_lockstep старого раннера)."""
    fs = _f2f_server_mod()
    server = LabServer(sx, srv)
    hello = None
    t_end = time.time() + 30
    while True:                      # порт F2F сервер открывает до «Done!», но на всякий случай — повтор
        try:
            hello = server.hello()
            break
        except RuntimeError:
            if time.time() > t_end:
                raise
            time.sleep(0.2)
    ls = fs.Lockstep(server, lambda c, a=None, timeout=None: sx.raw(c, a or {}, float(timeout or 600)),
                     "java" if sx.impl == "java" else "vc", user="Player")
    r = ls.sync(keepalive=False)
    if not r.get("ok"):
        raise RuntimeError("lockstep: client sync failed: %s" % r.get("error"))
    sx.data["ls"] = ls
    sx.data["ls_server"] = srv
    sx.log("lockstep server %s %s, client user %s" % (srv, json.dumps(hello, ensure_ascii=False)[:160], ls.user))


def ls_of(sx):
    ls = sx.data.get("ls")
    if ls is None:
        raise RuntimeError("lockstep scenario without a lockstep server (start hook)")
    return ls


def sc_lockstep_run(sx, cmd, args, step):
    """Команды сценария, которые в lockstep идут через Lockstep.run (как LS_CMDS старого раннера + шаги харнесса,
    вызывавшие внутри step/input). Остальное -> None (обычный путь ядра)."""
    ls = ls_of(sx)
    limit = step.get("limit", 600)
    if cmd in ("step", "wait", "gui", "connect", "mode"):
        return ls.run(cmd, dict(args), timeout=limit)
    if cmd == "input":
        return ls.run("input", sc_translate(sx, "input", dict(args)), timeout=limit)
    if cmd == "look":
        st = sx.raw("state", {"radius": 0})
        if not st.get("ok"):
            return st
        p = (st.get("result") or {}).get("player") or {}
        dx = int(round((float(args.get("yaw", p.get("yaw", 0))) - p.get("yaw", 0)) / 0.15))
        dy = int(round((p.get("pitch", 0) - float(args.get("pitch", p.get("pitch", 0)))) / 0.15))
        r = ls.run("input", {"mouse": {"dx": dx, "dy": dy}})
        if r.get("ok"):
            r = dict(r, result={"dx": dx, "dy": dy, "from": [p.get("yaw"), p.get("pitch")]})
        return r
    if cmd == "chat_age":
        return sc_chat_age(sx, args, step, stepper=lambda n: ls.step(n, 1))
    return None


def sc_lockstep_tick(sx, t):
    """Такт таймлайна (или такт step{N} ядра): барьер rx -> такт клиента (gui: событие + такт) -> такт сервера."""
    ls = ls_of(sx)
    if t.get("cmd") == "gui":
        return ls.run("gui", dict(t.get("gui") or {}, ticks=1, frames=1))
    a = t.get("args") or {}
    return ls.tick(frames=int(a.get("frames", 1)), partial=float(a.get("partial", 0) or 0))


def sc_server_step(sx, tick):
    """Шаг сервера после такта клиента, сделанного ядром (запасной путь без lockstep_tick): tx клиента (VoxelCore —
    sync {}, Java — из ответа), step сервера с барьером, затем барьер rx для следующего такта клиента."""
    ls = ls_of(sx)
    if ls.impl == "vc":
        ls.sync()
    else:
        ls._net((tick.get("reply") or {}).get("result"))
    res = ls.server_tick()
    if ls.impl == "vc":
        ls.sync(rx=ls.rx)
    else:
        sx.raw("sync", {"rx_bytes": ls.rx})
    return res


def sc_look(sx, args, step, lease=None):
    """Шаг харнесса look {yaw, pitch}: input.mouse {dx, dy}, чтобы в кадре следующего step взгляд стал ровно этим
    (yaw += dx·0.15, pitch −= dy·0.15)."""
    st = sx.raw("state", {"radius": 0}, lease=lease)
    if not st.get("ok"):
        return st
    p = (st.get("result") or {}).get("player") or {}
    dx = int(round((float(args.get("yaw", p.get("yaw", 0))) - p.get("yaw", 0)) / 0.15))
    dy = int(round((p.get("pitch", 0) - float(args.get("pitch", p.get("pitch", 0)))) / 0.15))
    r = sx.raw("input", {"mouse": {"dx": dx, "dy": dy}}, lease=lease)
    if r.get("ok"):
        r = dict(r, result={"dx": dx, "dy": dy, "from": [p.get("yaw"), p.get("pitch")]})
    return r


def sc_wait(sx, args, step):
    return wait_loop(lambda c, a, t: sx.raw(c, a, t), sx.kind_of(), args, step.get("limit", 600))


def sc_gui(sx, args, step):
    """Java F2FAgent.gui = событие + step{1,1}; engine: событие в обработчик пака, step здесь, затем экран."""
    if sx.kind_of() != "engine":
        return sx.raw("gui", args, step.get("limit", 600))
    rep = sx.raw("gui", args)
    if not rep.get("ok"):
        return rep
    st = sx.raw("step", {"ticks": int(args.get("ticks", 1)), "frames": int(args.get("frames", 1))})
    if not st.get("ok"):
        return st
    r = dict(st["result"])
    r["screen"] = ((sx.raw("state", {"radius": 0}).get("result")) or {}).get("screen")
    r["handled"] = rep.get("result")
    return {"ok": True, "result": r}


def sc_chat_age(sx, args, step, stepper=None):
    """Шагать, пока у свежей строки чата, подходящей под match, updateCounter не станет age (эхо сервера приходит
    в такт настенных часов; затухание строки зависит от её точного возраста)."""
    st = sx.raw("state", {"radius": 0})
    lines = (st.get("result") or {}).get("chat") or []
    line = next((c for c in lines if re.search(args.get("match", "."), c.get("text") or "")), None)
    if not line:
        return {"ok": False, "error": "chat_age: no chat line matches %r: %s" % (args.get("match"), lines)}
    n = int(args["age"]) - int(line.get("age", 0))
    if n < 0:
        return {"ok": False, "error": "chat_age: line already %s ticks old" % line.get("age")}
    if n <= 0:
        r = {"ok": True, "result": {}}
    else:
        r = stepper(n) if stepper else sx.raw("step", {"ticks": n, "frames": 1})
    if r.get("ok"):
        r = dict(r, result=dict(r.get("result") or {}, stepped=n, from_age=line.get("age")))
    return r


def sc_translate(sx, cmd, args):
    """input.keys: строка из цифр — код LWJGL (F2F.md 7.1); движку — имя клавиши ("3" -> "2")."""
    if cmd == "input" and args.get("keys") and sx.kind_of() == "engine":
        args = dict(args, keys={LWJGL_DIGITS.get(k, k): v for k, v in args["keys"].items()})
    return args


def sc_after_step(sx, step, reply):
    if step.get("cmd") != "render" or not reply.get("ok"):
        return reply
    res = reply.get("result") if isinstance(reply.get("result"), dict) else {}
    engine = sx.kind_of() == "engine"
    if engine and isinstance(res.get("layers"), dict):
        # движок не пересылает render паку: состояние слоёв — обработчику пака (EntityPickupFX = слой particles)
        sx.raw("layers", {"layers": res["layers"]})
    if res.get("rebuilt"):
        # после переключения света движок перестраивает ≤ 4 чанков за кадр: кадры без тактов до снимка
        st = sx.raw("status").get("result") or {}
        n = int(((st if isinstance(st, dict) else {}).get("engine_chunks") or 1000) / 4) + 10
        sr = sx.raw("step", {"ticks": 0, "frames": n})
        if not sr.get("ok"):
            return sr
        reply = dict(reply, settle_frames=n)
    return reply


def check_expect(expect, st):
    bad = []
    if "screen" in expect and not re.fullmatch(expect["screen"], st.get("screen") or ""):
        bad.append("screen %s != %s" % (st.get("screen"), expect["screen"]))
    p = st.get("player") or {}
    if "on_ground" in expect and bool(p.get("onGround")) != bool(expect["on_ground"]):
        bad.append("onGround %s" % p.get("onGround"))
    if "near" in expect:
        x, y, z = expect["near"][:3]
        r = expect["near"][3] if len(expect["near"]) > 3 else 1.0
        d = ((p.get("x", 1e9) - x) ** 2 + (p.get("y", 1e9) - y) ** 2 + (p.get("z", 1e9) - z) ** 2) ** 0.5
        if d > r:
            bad.append("player at %.4f %.4f %.4f, further than %s from %s" % (
                p.get("x", 0), p.get("y", 0), p.get("z", 0), r, expect["near"][:3]))
    if "health" in expect and p.get("health") != expect["health"]:
        bad.append("health %s != %s" % (p.get("health"), expect["health"]))
    for k in ("yaw", "pitch"):
        if k in expect and abs(p.get(k, 1e9) - expect[k]) > 1e-3:
            bad.append("%s %s != %s" % (k, p.get(k), expect[k]))
    if "entities" in expect:
        n = len((st.get("world") or {}).get("entities") or [])
        if n < int(expect["entities"]):
            bad.append("entities %d < %s" % (n, expect["entities"]))
    return bad


def sc_expect(sx, expect):
    st = sx.raw("state", {"radius": 4}).get("result") or {}
    return check_expect(expect, st)


def sc_timeline_setup(sx, setup):
    """Ключи setup таймлайна, которые знает только альфа: tp [x,y,z] (/tp + ожидания), look {yaw,pitch} + step{1,1}."""
    steps = []
    if setup.get("tp"):
        x, y, z = setup["tp"]
        steps += [
            {"cmd": "chat", "args": {"text": "/tp %s %s %s" % (x, y, z)}},
            {"cmd": "wait", "args": {"near": [x, y + 1.62, z, 3], "max_frames": 600}},
            {"cmd": "wait", "args": {"new_chunks": 1, "net_idle": 60, "max_frames": 6000}},
            {"cmd": "wait", "args": {"on_ground": True, "still": 40, "max_frames": 1200},
             "expect": {"on_ground": True, "screen": "ingame", "health": 20}},
        ]
    if setup.get("look"):
        steps += [{"cmd": "look", "args": setup["look"]}, {"cmd": "step", "args": {"ticks": 1, "frames": 1}}]
    return steps


def sc_finish(sx):
    out = {}
    if sx.client and sx.kind_of() == "engine":
        r = sx.raw("status")
        out["status"] = r.get("result") if r.get("ok") else r.get("error")
    ls = sx.data.get("ls")
    if ls is not None:
        out["lockstep"] = ls.report()
        try:
            out["server_state"] = ls.srv.state()
        except Exception as exc:
            out["server_state"] = "%s: %s" % (type(exc).__name__, exc)
    return out or None


POS = ("x", "y", "z", "mx", "my", "mz")


def _f32(v):
    import struct
    return None if v is None else struct.unpack("f", struct.pack("f", float(v)))[0]


def _pnum(p, k):
    ex = (p.get("exact") or {}).get(k)
    if ex is not None:
        return float(ex)
    v = p.get(k)
    return None if v is None else float(v)


def sc_compare_state(sa, sb):
    """Дампы state по категориям (порт e2e_compare.compare_state): player (позиция/скорость бит в бит — у VoxelCore
    строки exact %.17g, у Java double; yaw/pitch как float32; onGround/health/slot), inventory, blocks (FNV-хэш куба),
    entities (тип и позиция, |Δ| ≤ 1e-9; id — счётчик сервера, только в деталях), screen, chat."""
    out = {}
    pa, pb = sa.get("player") or {}, sb.get("player") or {}
    d, eq = {}, True
    for k in POS:
        a, b = _pnum(pa, k), _pnum(pb, k)
        if a != b:
            eq = False
            d[k] = [a, b, None if a is None or b is None else b - a]
    for k in ("yaw", "pitch"):
        a, b = _f32(pa.get(k)), _f32(pb.get(k))
        if a != b:
            eq = False
            d[k] = [a, b, None if a is None or b is None else b - a]
    for k in ("onGround", "health", "slot"):
        if pa.get(k) != pb.get(k):
            eq = False
            d[k] = [pa.get(k), pb.get(k)]
    out["player"] = (eq, d)
    inv = lambda p: sorted((int(i.get("slot", -1)), int(i.get("id", 0)), int(i.get("count", 0)), int(i.get("meta", 0)))
                           for i in (p.get("inventory") or []))
    ia, ib = inv(pa), inv(pb)
    out["inventory"] = (ia == ib, {} if ia == ib else {"a": ia, "b": ib})
    hk = lambda h: (h.get("blocks"), h.get("meta"), tuple(h.get("center") or ()))
    ha, hb = hk(sa.get("hash") or {}), hk(sb.get("hash") or {})
    out["blocks"] = (ha == hb, {} if ha == hb else {"a": list(ha), "b": list(hb)})
    ents = lambda st: [(e.get("id"), e.get("type"), e.get("x"), e.get("y"), e.get("z"))
                       for e in ((st.get("world") or {}).get("entities") or [])]
    ea, eb = ents(sa), ents(sb)
    e_eq = len(ea) == len(eb) and all(
        u[1] == v[1] and all(u[i] is not None and v[i] is not None and abs(float(u[i]) - float(v[i])) <= 1e-9
                             for i in (2, 3, 4)) for u, v in zip(ea, eb))
    out["entities"] = (e_eq, {} if e_eq else {"a": ea, "b": eb})
    out["screen"] = (sa.get("screen") == sb.get("screen"), {"a": sa.get("screen"), "b": sb.get("screen")})
    ca = [c.get("text") for c in sa.get("chat") or []]
    cb = [c.get("text") for c in sb.get("chat") or []]
    out["chat"] = (ca == cb, {} if ca == cb else {"a": ca, "b": cb})
    return out


# ---------------------------------------------------------------------------------------------- перф (этап 3а)
PERF_END_RX = r"\[alphamine_perf\] finished|GuiConnectFailed|tick error|kicked:|disconnected:"


def _perf_run(px, a, size):
    """Общий путь perf_normal / perf_walk: сервер + rt-движок (realtime), файлы управления паком в export\\ экземпляра,
    ожидание `[alphamine_perf] finished`, CSV-части -> perf.csv -> perflib.full_report. Ничего вне аренд."""
    import glob
    import os
    import sys
    lab = px.lab
    vc_root = lab.base_ctx()["vc_root"]
    perf_dir = os.path.join(vc_root, "tools", "alphamine", "perf")
    if perf_dir not in sys.path:
        sys.path.insert(0, perf_dir)
    import perflib
    tag = str(a.get("tag") or "run")
    run = "%s_%s" % (time.strftime("%Y%m%d_%H%M%S"), tag)
    srv = px.lease("server", params={"world": a.get("world", "world_b")})
    port = lab.leases[srv].ports["game"]
    px.progress("server %s on :%d (world %s)" % (srv, port, a.get("world", "world_b")))
    ep = {"server": "127.0.0.1:%d" % port, "size": a.get("size") or size}
    if a.get("pack"):
        ep["pack"] = a["pack"]          # вариант пака (Windows-путь), напр. D:\\Prog\\AlphaMine\\run\\alphamine_lp
    eng = px.lease("rt", params=ep, start=False)
    l = lab.leases[eng]
    exp = os.path.join(l.dir, "export")
    os.makedirs(exp, exist_ok=True)
    with open(os.path.join(exp, "alphamine_perf.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("run=%s\nperiod=5\n" % run + "".join(str(sw) + "\n" for sw in a.get("switch") or []))
    with open(os.path.join(exp, "alphamine_autowalk.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("stand=%d\nwalk=%d\nsettle=%d\nyaw=%g\nturn=%g\n" % (
            int(a.get("stand", 100)), int(a.get("walk", 1200)), int(a.get("settle", 300)), float(a.get("yaw", 180)),
            float(a.get("turn", 30))))
        if a.get("line"):
            ax, az = (float(v) for v in str(a["line"]).split(","))
            f.write("line=1\nax=%g\naz=%g\n" % (ax, az))
        for kv in a.get("autowalk") or []:
            f.write(str(kv) + "\n")
    st = lab.start(eng, owner=px.owner)
    px.progress("engine %s ready in %.1f s (%s, clock %s)" % (eng, st["timing"]["total_s"], st["exe"],
                                                             (st.get("isolation") or {}).get("clock")))
    t0 = time.time()
    timeout = float(a.get("timeout", 400))
    found = None
    last = 0
    while time.time() - t0 < timeout and not px.cancelled():
        lines = lab.logs(eng, stream="latest", tail=0, grep=PERF_END_RX)["lines"]
        if lines:
            found = lines[-1]
            break
        if time.time() - last > 20:
            last = time.time()
            stl = lab.logs(eng, stream="latest", tail=0, grep=r"\] status tick|autowalk")["lines"]
            if stl:
                px.progress("  " + stl[-1][stl[-1].find("[alphamine"):][:180])
        time.sleep(1.0)
    ok = bool(found and "[alphamine_perf] finished" in found)
    px.progress("end marker: %s after %.0f s" % (found, time.time() - t0))
    log_lines = lab.logs(eng, stream="latest", tail=0)["lines"]
    with open(os.path.join(px.out_dir, "latest_alphamine.log"), "w", encoding="utf-8") as f:
        f.write("\n".join(x for x in log_lines if "alphamine" in x or "[E]" in x or "[W]" in x) + "\n")
    parts_dir = os.path.join(exp, "alphamine_perf", run)
    lab.stop(eng, owner=px.owner)                     # каталог экземпляра жив до release: CSV забираем сейчас
    lab.stop(srv, owner=px.owner)
    out = px.out_dir

    def merge(pattern, dst):
        parts = sorted(glob.glob(os.path.join(parts_dir, pattern)))
        if parts:
            with open(dst, "w", encoding="utf-8", newline="\n") as f:
                for i, p in enumerate(parts):
                    rows = open(p, encoding="utf-8").read().splitlines()
                    f.write("\n".join(rows if i == 0 else rows[1:]) + "\n")
        return len(parts)
    n = merge("part_*.csv", os.path.join(out, "perf.csv"))
    merge("samples_*.csv", os.path.join(out, "samples.csv"))
    px.progress("%d CSV parts -> %s" % (n, os.path.join(out, "perf.csv")))
    if not n:
        return {"ok": False, "error": "no CSV parts (profiler did not write)", "end": found}
    errs = sum(1 for x in log_lines if re.search(r"frame error|tick error|update error", x))
    note = "lab perf, test build clock realtime (input isolated), frame %s, switches: %s" % (
        a.get("size") or size, " ".join(a.get("switch") or []) or "none")
    if not ok:
        note += " (run did not finish, see latest_alphamine.log)"
    if errs:
        note += " **%d frame/tick errors in the log: the run is not valid**" % errs
    res_all, res_walk, md = perflib.full_report(os.path.join(out, "perf.csv"), out, run, "normal", note=note)
    f5 = res_all.get("fps_5s") or {}
    return {"ok": ok and not errs, "summary_json": os.path.join(out, "perf_summary.json"), "end": found,
            "frames": res_all.get("frames"), "fps_5s": f5, "errors": errs}


def perf_normal(px, a):
    """Обычный запуск в реальном времени: окно пользователя 1390x855 (кадр F2F), сервер world_b, autowalk."""
    return _perf_run(px, a, "1390x855")


def perf_walk(px, a):
    """Тот же маршрут в стандартном кадре 854x480 (раньше — F2F с виртуальным временем; с этапа 3а — realtime)."""
    return _perf_run(px, a, "854x480")


def register(api):
    api.perf("perf_normal", perf_normal)
    api.perf("perf_walk", perf_walk)
    api.scenario(start=sc_start, translate=sc_translate, after_step=sc_after_step, expect=sc_expect,
                 timeline_setup=sc_timeline_setup, info=sc_info, finish=sc_finish, compare_state=sc_compare_state,
                 server_step=sc_server_step, lockstep_tick=sc_lockstep_tick, lockstep_run=sc_lockstep_run,
                 steps={"look": lambda sx, a, st: sc_look(sx, a, st), "wait": sc_wait, "gui": sc_gui,
                        "chat_age": lambda sx, a, st: sc_chat_age(sx, a, st)})
    # lockstep (server: {f2f: true}, F2F.md §9): сервер --f2f <порт аренды>, Lockstep из tools/alphamine/f2f_server.py
    api.feature("wait", wait, "F2F wait on an alphamine lease (engine: harness loop wait_check+step, realtime)",
                {"type": "object", "properties": {"lease": {"type": "string"}, "screen": {"type": "string"},
                                                  "world": {"type": "boolean"}, "chunks": {"type": "integer"},
                                                  "max_frames": {"type": "integer"}}, "required": ["lease"]},
                mcp=True)
    api.feature("gui", gui, "gui event + step{1,1} (engine), like Java F2FAgent.gui",
                {"type": "object", "properties": {"lease": {"type": "string"}}, "required": ["lease"]})
    api.feature("session", session, "lease+start server (+engine, +ref_app) and connect the clients",
                {"type": "object", "properties": {"world": {"type": "string"}, "ref_app": {"type": "boolean"},
                                                  "connect": {"type": "boolean"}, "size": {"type": "string"}}})


def selftest():
    assert callable(wait) and callable(gui) and callable(session)
    assert check_expect({"yaw": 90}, {"player": {"yaw": 90.0}}) == []
    assert sc_compare_state({"player": {"x": 1}}, {"player": {"x": 1}})["player"][0]
