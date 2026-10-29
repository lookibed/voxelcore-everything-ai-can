"""Волна 4c (olife_w4c): сетевой код Olife в лаборатории — предсказание движения, дельты снимков, инвентарь.
Отдельный модуль (как sandbox_real.py / gateway_rs.py), plugin.py загружает его через _w4c() и отдаёт свои функции (bind).

Параметры сессии (setup.session): world_opts — строка `--opts` мира ("snap=full|delta,snap_budget=1200,keyframe=100,inv=0|1"),
bot_opts — `--opts` ботов ("move=predict|legacy,drops=N,radius=R,sprint=0|1"; строка или список по клиентам).
Шлюз — gateway_dev.py: инжектор задержки `latency {rtt_ms, name?|session?}` на порту управления (половина RTT в каждую сторону).

Шаги:
  olife_latency {rtt_ms, name?}         задержка на шлюзе (всем или одной сессии по имени бота)
  olife_pred_phase {rtt_ms, name?, seconds, label}
                                        задержка -> сброс статистики предсказания у ботов -> прогон -> `status` ботов:
                                        расхождения предсказания (err p50/p95/max), поправки/мин, величина скачка, длина
                                        переигровки, RTT шлюза; итог в metrics.prediction[label]
  olife_move_check {settle_s=1.5, max_hash_mismatch=0}
                                        olife.halt ботам, пауза, затем `olife.move_state` мира и ботов: хэш состояния движения
                                        (f32 позиции/скорости + флаги) и ack == seq у каждого бота
  olife_snap_phase {mode, seconds, label}
                                        `olife.snap <mode>` миру, прогон, байты: снимки сущностей мира (snap_bytes), весь трафик
                                        вниз шлюза; на такт и на сессию; итог в metrics.snap[label] (+ сравнение фаз)
  olife_inventory_check {min_drops, min_picks_cross, min_placed}
                                        olife.dump_inventory мира -> копия ботам -> olife.check_inventory: зеркало каждого бота
                                        равно инвентарю мира (слоты, выбранный, hash), баланс предметов мира = 0
"""
import json
import os
import shutil
import time

P = {}


def bind(plugin_globals):
    P.update(plugin_globals)


def _roles(sx):
    return dict(sx.data["session"]["leases"])


def _bots(sx):
    return {r: n for r, n in _roles(sx).items() if r.startswith("client") and sx.lab.leases[n].kind == "bot"}


def _alive_wait(sx, seconds):
    end = time.time() + seconds
    while time.time() < end:
        for role, name in _roles(sx).items():
            p = sx.lab.leases[name].proc
            if p is not None and not p.alive():
                return "%s %s died: %s" % (role, name, p.info().get("exit"))
        if sx.cancelled:
            return "cancelled"
        time.sleep(0.25)
    return None


def _stdin_lines(sx, lease, cmd, pattern, wait=3.0):
    r = sx.lab.stdin(lease, cmd, owner=sx.owner, wait=wait, pattern=pattern)
    return [x for x in r["lines"]]


def _kv(line):
    return P["_kv"](line)


def _bot_status(sx, name):
    lines = [x for x in _stdin_lines(sx, name, "status", r"status\sname=") if "status name=" in x]
    return _kv(lines[-1]) if lines else {}


def _world_status(sx):
    lease = _roles(sx)["world"]
    lines = [x for x in _stdin_lines(sx, lease, "status", r"status\stick=") if "status tick=" in x]
    return _kv(lines[-1]) if lines else {}


def _gw_metrics(sx):
    roles = _roles(sx)
    if "gateway" not in roles:
        return {}
    try:
        return sx.call("metrics", lease=roles["gateway"]) or {}
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc)}


# ---------------------------------------------------------------------------------------------- шаги
def st_latency(sx, args, step):
    roles = _roles(sx)
    a = {"rtt_ms": float(args.get("rtt_ms", 0))}
    if args.get("name"):
        a["name"] = args["name"]
    r = sx.call("latency", a, lease=roles["gateway"])
    return {"ok": True, "result": r}


PRED_KEYS = ("pred_acks", "pred_inputs", "pred_states", "pred_mismatch", "pred_corr", "pred_hard", "pred_unknown_ack", "pred_corr_min",
             "pred_err_p50", "pred_err_p95", "pred_err_max", "pred_err_nz", "pred_snap_p50", "pred_snap_p95",
             "pred_snap_max", "pred_replay_p50", "pred_replay_max", "pred_unacked_max", "self_div", "state",
             "inv_div", "delta_unknown_slot")


def st_pred_phase(sx, args, step):
    roles = _roles(sx)
    rtt = float(args.get("rtt_ms", 0))
    label = args.get("label") or "rtt%d" % int(rtt)
    lat = {"rtt_ms": rtt}
    if args.get("name"):
        lat["name"] = args["name"]
    sx.call("latency", lat, lease=roles["gateway"])
    time.sleep(float(args.get("settle_s", 0.5)))
    for _, name in _bots(sx).items():
        _stdin_lines(sx, name, "olife.pred_reset", r"predict\sstats\sreset", wait=2.0)
    g0 = _gw_metrics(sx)
    w0 = _world_status(sx)
    err = _alive_wait(sx, float(args.get("seconds", 10)))
    if err:
        return {"ok": False, "error": err, "fatal": "dead"}
    g1 = _gw_metrics(sx)
    w1 = _world_status(sx)
    bots = {}
    for _, name in sorted(_bots(sx).items()):
        b = _bot_status(sx, name)
        bots[name] = {k: b.get(k) for k in PRED_KEYS}
    out = {"rtt_ms": rtt, "target": args.get("name") or "all", "seconds": float(args.get("seconds", 10)),
           "bots": bots, "gateway_rtt_ms": (g1 or {}).get("rtt_ms"),
           "world": {k: (w1.get(k, 0) or 0) - (w0.get(k, 0) or 0) for k in ("mv_inputs", "mv_sim", "mv_drop",
                                                                            "mv_stale", "mv_teleports", "mv_states")}}
    sx.data["metrics"].setdefault("prediction", {})[label] = out
    bad = [n for n, b in bots.items() if b.get("state") != "play" or b.get("self_div")]
    mx = args.get("max_hard")
    if mx is not None:
        bad += ["%s hard=%s" % (n, b.get("pred_hard")) for n, b in bots.items() if (b.get("pred_hard") or 0) > int(mx)]
    return {"ok": not bad, "result": out, "error": ("bad bots: %s" % bad) if bad else None}


def _move_lines(lines, marker):
    out = {}
    for x in lines:
        i = x.find(marker)
        if i < 0:
            continue
        kv = _kv(x[i:])
        if "eid" in kv:
            out[str(kv["eid"])] = kv
    return out


def st_move_check(sx, args, step):
    roles = _roles(sx)
    for _, name in _bots(sx).items():
        _stdin_lines(sx, name, "olife.halt", r"halt", wait=2.0)
    time.sleep(float(args.get("stop_s", 1.5)))          # keys 0: the player stops and lands (both sides simulate)
    for _, name in _bots(sx).items():
        _stdin_lines(sx, name, "olife.freeze", r"freeze", wait=2.0)
    time.sleep(float(args.get("settle_s", 1.5)))        # no more inputs: the last PlayerState arrives (> RTT)
    wl = _stdin_lines(sx, roles["world"], "olife.move_state", r"move\seid=", wait=3.0)
    world = _move_lines(wl, "[olife_world] move ")
    res, bad = {}, []
    for _, name in sorted(_bots(sx).items()):
        bl = _stdin_lines(sx, name, "olife.move_state", r"move\seid=", wait=3.0)
        mine = _move_lines(bl, "[olife_client] move ")
        if not mine:
            bad.append("%s: no move_state" % name)
            continue
        eid, c = next(iter(mine.items()))
        w = world.get(eid)
        r = {"eid": eid, "client_hash": c.get("hash"), "world_hash": w and w.get("hash"), "client_seq": c.get("seq"),
             "client_ack": c.get("ack"), "world_ack": w and w.get("ack"), "client_pos": c.get("pos"),
             "world_pos": w and w.get("pos")}
        r["hash_equal"] = bool(w) and w.get("hash") == c.get("hash")
        r["all_acked"] = c.get("ack") == c.get("seq") and bool(w) and w.get("ack") == c.get("seq")
        res[name] = r
        if not r["hash_equal"]:
            bad.append("%s: hash %s != world %s" % (name, c.get("hash"), w and w.get("hash")))
        if not r["all_acked"]:
            bad.append("%s: ack %s/%s seq %s" % (name, c.get("ack"), w and w.get("ack"), c.get("seq")))
    sx.data["metrics"]["move_check"] = res
    if args.get("resume", True):
        for _, name in _bots(sx).items():
            _stdin_lines(sx, name, "olife.walk", r"walk", wait=2.0)
    return {"ok": not bad, "result": res, "error": "; ".join(bad) or None}


def st_snap_phase(sx, args, step):
    roles = _roles(sx)
    mode = args.get("mode", "delta")
    label = args.get("label") or mode
    _stdin_lines(sx, roles["world"], "olife.snap %s" % mode, r"snap\smode=", wait=3.0)
    if args.get("budget") is not None:
        _stdin_lines(sx, roles["world"], "olife.snap_budget %d %d" % (int(args["budget"]), int(args.get("near", 24))),
                     r"snap\sbudget=", wait=3.0)
    time.sleep(float(args.get("settle_s", 1.0)))
    w0, g0 = _world_status(sx), _gw_metrics(sx)
    err = _alive_wait(sx, float(args.get("seconds", 10)))
    if err:
        return {"ok": False, "error": err, "fatal": "dead"}
    w1, g1 = _world_status(sx), _gw_metrics(sx)
    ticks = max(1, (w1.get("tick") or 0) - (w0.get("tick") or 0))
    sess = max(1, w1.get("sessions") or 1)
    d = lambda k: (w1.get(k) or 0) - (w0.get(k) or 0)  # noqa: E731
    down = ((g1.get("total") or {}).get("down") or 0) - ((g0.get("total") or {}).get("down") or 0)
    out = {"mode": mode, "ticks": ticks, "sessions": sess, "entities": w1.get("entities"),
           "snap_bytes": d("snap_bytes"), "snap_bytes_per_tick": round(d("snap_bytes") / ticks, 1),
           "snap_bytes_per_tick_session": round(d("snap_bytes") / ticks / sess, 1),
           "gateway_down": down, "gateway_down_per_tick": round(down / ticks, 1),
           "gateway_down_per_s_session": round(down / ticks * 20 / sess, 1),
           "sync_bytes": d("sync_bytes"), "chunk_bytes": d("chunk_bytes"), "block_bytes": d("block_bytes"),
           "mv_bytes": d("mv_bytes"), "inv_bytes": d("inv_bytes"),
           "deferred": d("snap_deferred"), "decimated": d("snap_decimated"), "keyframes": d("snap_keyframes"),
           "moves": d("snap_moves"), "d8": d("snap_d8"), "d16": d("snap_d16"), "pa": d("snap_pa"),
           "budget": args.get("budget"), "near": args.get("near")}
    sm = sx.data["metrics"].setdefault("snap", {})
    sm[label] = out
    if "full" in sm and "delta" in sm and sm["full"]["snap_bytes_per_tick"]:
        sm["delta_vs_full"] = {
            "snap_bytes_ratio": round(sm["delta"]["snap_bytes_per_tick"] / sm["full"]["snap_bytes_per_tick"], 3),
            "gateway_down_ratio": round(sm["delta"]["gateway_down_per_tick"] / max(1e-9, sm["full"]["gateway_down_per_tick"]), 3)}
    return {"ok": True, "result": out}


def st_inventory_check(sx, args, step):
    roles = _roles(sx)
    lines = _stdin_lines(sx, roles["world"], "olife.dump_inventory", r"dump_inventory\splayers=", wait=3.0)
    wdir = sx.lab.lease_info(roles["world"])["dir"]
    src = os.path.join(wdir, "export", "inventory_world.json")
    time.sleep(0.3)
    try:
        with open(src, encoding="utf-8") as f:
            world = json.load(f)
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": "no world inventory dump: %s (%s)" % (exc, lines[-2:])}
    rep = {"world": {k: world.get(k) for k in ("tick", "in_inventories", "on_ground", "balance", "ledger", "stats")},
           "bots": {}}
    bad = []
    for _, name in sorted(_bots(sx).items()):
        d = sx.lab.lease_info(name)["dir"]
        shutil.copyfile(src, os.path.join(d, "export", "inventory_check.json"))
        _stdin_lines(sx, name, "olife.check_inventory", r"check_inventory", wait=3.0)
        time.sleep(0.2)
        try:
            with open(os.path.join(d, "export", "inventory_bot.json"), encoding="utf-8") as f:
                b = json.load(f)
        except (OSError, ValueError) as exc:
            b = {"error": str(exc)}
        rep["bots"][name] = b
        if b.get("error") or not b.get("match") or b.get("div") or b.get("items_ok") is False:
            bad.append("%s: %s" % (name, {k: b.get(k) for k in ("match", "div", "items_ok", "error")} |
                                   {"diff": (b.get("diff") or [])[:5]}))
    st = world.get("stats") or {}
    if world.get("balance") != 0:
        bad.append("item balance %s != 0" % world.get("balance"))
    for k, key in (("min_drops", "drops"), ("min_picks_cross", "picks_cross"), ("min_placed", "placed"),
                   ("min_picks", "picks")):
        if k in args and (st.get(key) or 0) < int(args[k]):
            bad.append("%s %s < %s" % (key, st.get(key), args[k]))
    with open(os.path.join(sx.out_dir(), "olife_inventory.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    summary = {"world": rep["world"], "bots": {n: {k: b.get(k) for k in ("match", "rev", "total", "div", "items_ok")}
                                               for n, b in rep["bots"].items()}}
    sx.data["metrics"]["inventory"] = summary
    if not rep["bots"]:
        bad.append("no bots")
    return {"ok": not bad, "result": summary, "error": "; ".join(bad) or None}


_CODEC = {}


def _codec():
    """olife_proto.client of tools/olife, reloaded when gen_codecs.py rewrote it (the daemon outlives schema changes:
    a cached old codec sent MoveInput without `hash` and the gateway cut the session — 02.10)"""
    import importlib
    import sys
    tools = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "olife"))
    if tools not in sys.path:
        sys.path.insert(0, tools)
    path = os.path.join(tools, "olife_proto", "client.py")
    mt = os.path.getmtime(path)
    if _CODEC.get("mtime") != mt:
        import olife_proto.wire
        import olife_proto.client
        importlib.reload(olife_proto.wire)
        _CODEC["m"], _CODEC["mtime"] = importlib.reload(olife_proto.client), mt
    return _CODEC["m"]


def speedhack(gw_port, seconds=3.0, rate=50.0, name="hack"):
    """протокольный клиент (без движка): Hello, затем MoveInput(fwd) с частотой `rate`/с (больше 20/с реального времени)
    в течение `seconds`; ответы на KeepAlive; итог — отправлено, последний PlayerState (ack, pos) и путь от первого."""
    import socket
    C = _codec()
    s = socket.create_connection(("127.0.0.1", int(gw_port)), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(C.frame("Hello", {"proto": C.VERSION, "name": name, "token": "olife-test", "engine": "speedhack"}))
    fr = C.framer()
    s.settimeout(0.005)
    first = last = None
    welcome = disc = None
    sent, seq = 0, 0
    t0 = time.time()
    nxt = t0
    end = t0 + 30.0
    started = None
    while time.time() < end:
        try:
            data = s.recv(65536)
            if not data:
                break
            fr.feed(data)
        except socket.timeout:
            pass
        while True:
            x = fr.next()
            if x is None:
                break
            mid, body = x
            nm = C.NAMES.get(mid)
            if nm == "Welcome":
                welcome = C.decode_body(mid, body)
                started = time.time()
                end = started + seconds + 1.0
                nxt = started
            elif nm == "KeepAlive":
                s.sendall(C.frame("KeepAliveReply", {"challenge": C.decode_body(mid, body)["challenge"]}))
            elif nm == "PlayerState":
                m = C.decode_body(mid, body)
                if first is None:
                    first = m
                last = m
            elif nm == "Disconnect":
                disc = C.decode_body(mid, body)
                end = 0
        if started and time.time() < started + seconds and time.time() >= nxt:
            seq += 1
            s.sendall(C.frame("MoveInput", {"seq": seq, "keys": 1 + 32, "yaw": 0.0, "pitch": 0.0, "hash": 0}))
            sent += 1
            nxt += 1.0 / rate
    try:
        s.sendall(C.frame("Bye", {"reason": "speedhack done"}))
        s.close()
    except OSError:
        pass
    out = {"sent": sent, "seconds": seconds, "rate": rate, "welcome": bool(welcome), "disconnect": disc}
    if first and last:
        dx, dz = last["pos"]["x"] - first["pos"]["x"], last["pos"]["z"] - first["pos"]["z"]
        out.update({"first_ack": first["ack"], "last_ack": last["ack"], "moved": round((dx * dx + dz * dz) ** 0.5, 3),
                    "last_pos": last["pos"]})
    return out


def st_speedhack(sx, args, step):
    """античит: клиент шлёт MoveInput в rate раз/с (спидхак); мир моделирует не больше 20/с реального времени (+ запас
    move_burst), лишнее — отброшено (mv_drop), путь <= скорость бега * время + запас"""
    roles = _roles(sx)
    gw_port = sx.lab.lease_info(roles["gateway"])["ports"]["gw"]
    w0 = _world_status(sx)
    r = speedhack(gw_port, float(args.get("seconds", 3)), float(args.get("rate", 50)))
    time.sleep(0.5)
    w1 = _world_status(sx)
    r["world_drop"] = (w1.get("mv_drop") or 0) - (w0.get("mv_drop") or 0)
    r["world_sim_all"] = (w1.get("mv_sim") or 0) - (w0.get("mv_sim") or 0)
    r["hack_simulated"] = r["sent"] - r["world_drop"]          # the bots of the session drop nothing (see phases)
    r["hack_sim_per_s"] = round(r["hack_simulated"] / max(0.1, r["seconds"]), 1)
    # sprint 4.05 b/s * time, + burst 10 inputs (0.5 s) of slack
    limit = 4.05 * (r["seconds"] + 0.5) + 0.5
    r["moved_limit"] = round(limit, 2)
    sx.data["metrics"]["speedhack"] = r
    bad = []
    if not r.get("welcome"):
        bad.append("no Welcome")
    if r.get("moved") is None or r["moved"] > limit:
        bad.append("moved %s > %.2f" % (r.get("moved"), limit))
    if r["hack_simulated"] > 20 * r["seconds"] + 12:
        bad.append("world simulated %d inputs in %.1f s (> 20/s + burst)" % (r["hack_simulated"], r["seconds"]))
    return {"ok": not bad, "result": r, "error": "; ".join(bad) or None}


def inventory_negative(gw_port, name="invneg"):
    """протокольный клиент: недопустимые запросы инвентаря -> InvReject с ожидаемой причиной; постановка блока без
    предмета -> BlockReject 7 + InvReject 5; поток 40 InvAction за раз -> часть отклонена по частоте (1)"""
    import socket
    C = _codec()
    s = socket.create_connection(("127.0.0.1", int(gw_port)), timeout=5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(C.frame("Hello", {"proto": C.VERSION, "name": name, "token": "olife-test", "engine": "invneg"}))
    fr = C.framer()
    s.settimeout(0.02)
    got = {"InvReject": [], "BlockReject": [], "InventoryState": 0, "welcome": None, "inv": None}

    def pump(sec):
        end = time.time() + sec
        while time.time() < end:
            try:
                data = s.recv(65536)
                if not data:
                    return
                fr.feed(data)
            except socket.timeout:
                pass
            while True:
                x = fr.next()
                if x is None:
                    break
                mid, body = x
                nm = C.NAMES.get(mid)
                if nm in ("InvReject", "BlockReject"):
                    got[nm].append(C.decode_body(mid, body))
                elif nm == "InventoryState":
                    got["InventoryState"] += 1
                    got["inv"] = C.decode_body(mid, body)
                elif nm == "Welcome":
                    got["welcome"] = C.decode_body(mid, body)
                elif nm == "KeepAlive":
                    s.sendall(C.frame("KeepAliveReply", {"challenge": C.decode_body(mid, body)["challenge"]}))
    pump(1.5)
    cases = [("bad slot (select 12)", {"op": 1, "slot": 12, "slot2": 0, "count": 0}, 2),
             ("bad slot (move 200)", {"op": 2, "slot": 200, "slot2": 1, "count": 0}, 2),
             ("empty slot (drop 30)", {"op": 3, "slot": 30, "slot2": 0, "count": 1}, 3),
             ("count over (drop 999 of slot 0)", {"op": 3, "slot": 0, "slot2": 0, "count": 999}, 4),
             ("unknown op 9", {"op": 9, "slot": 0, "slot2": 0, "count": 0}, 4)]
    res = []
    seq = 0
    for title, a, want in cases:
        seq += 1
        n0 = len(got["InvReject"])
        s.sendall(C.frame("InvAction", dict(a, seq=seq)))
        pump(0.3)
        rs = [x for x in got["InvReject"][n0:] if x["seq"] == seq]
        res.append({"case": title, "want": want, "got": rs[0]["reason"] if rs else None,
                    "ok": bool(rs) and rs[0]["reason"] == want})
    # place without the item: select empty hotbar slot 9, place stone next to the spawn
    w = got["welcome"] or {"spawn": {"x": 8.5, "y": 80, "z": 8.5}}
    seq += 1
    s.sendall(C.frame("InvAction", {"seq": seq, "op": 1, "slot": 9, "slot2": 0, "count": 0}))
    pump(0.3)
    b0, i0 = len(got["BlockReject"]), len(got["InvReject"])
    # a cell high in the air next to the spawn (in reach, replaceable, nobody stands there): only the item is missing
    bx, by, bz = int(w["spawn"]["x"]) + 2, int(w["spawn"]["y"]) + 6, int(w["spawn"]["z"]) + 2
    s.sendall(C.frame("BlockAction", {"seq": 7777, "action": 1, "pos": {"x": bx, "y": by, "z": bz}, "block": 10,
                                      "states": 0}))
    pump(0.5)
    br = [x["reason"] for x in got["BlockReject"][b0:]]
    ir = [x["reason"] for x in got["InvReject"][i0:]]
    res.append({"case": "place without the item (slot 9 empty)", "want": "BlockReject 7 + InvReject 5",
                "got": {"block": br, "inv": ir}, "ok": 7 in br and 5 in ir})
    # flood: 40 selects at once -> the bucket (burst 20, 10/s) refuses part of them with reason 1
    i0 = len(got["InvReject"])
    for k in range(40):
        seq += 1
        s.sendall(C.frame("InvAction", {"seq": seq, "op": 1, "slot": k % 10, "slot2": 0, "count": 0}))
    pump(0.8)
    rate = sum(1 for x in got["InvReject"][i0:] if x["reason"] == 1)
    res.append({"case": "flood 40 InvAction", "want": ">= 15 rate refusals", "got": rate, "ok": rate >= 15})
    try:
        s.sendall(C.frame("Bye", {"reason": "invneg done"}))
        s.close()
    except OSError:
        pass
    return {"tests": len(res), "passed": sum(1 for x in res if x["ok"]), "results": res,
            "inventory_states": got["InventoryState"]}


def st_inventory_negative(sx, args, step):
    roles = _roles(sx)
    gw_port = sx.lab.lease_info(roles["gateway"])["ports"]["gw"]
    r = inventory_negative(gw_port)
    w = _world_status(sx)
    r["world_alive"] = bool(w)
    sx.data["metrics"]["inventory_negative"] = r
    ok = r["passed"] == r["tests"] and r["world_alive"]
    return {"ok": ok, "result": r, "error": None if ok else "failed: %s" % [x for x in r["results"] if not x["ok"]]}


def steps():
    return {"olife_latency": st_latency, "olife_pred_phase": st_pred_phase, "olife_move_check": st_move_check,
            "olife_snap_phase": st_snap_phase, "olife_inventory_check": st_inventory_check,
            "olife_speedhack": st_speedhack, "olife_inventory_negative": st_inventory_negative}


def register(api):
    pass


def selftest():
    m = _move_lines(["x [olife_world] move eid=6 name=bot1 ack=10 inputs=10 hash=123 pos=1,2,3 vel=0,0,0 flags=1"],
                    "[olife_world] move ")
    assert m["6"]["hash"] == 123 and m["6"]["ack"] == 10, m
