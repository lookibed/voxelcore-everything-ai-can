"""Волна 3c (olife_w3g): Rust-шлюз olife-gateway в лаборатории — шаги нагрузки/выдержки и перф-сценарии.
Отдельный модуль (как sandbox_real.py), чтобы не мешать правкам plugin.py другими агентами; plugin.py загружает его через
_w3g() и отдаёт сюда свои функции (bind). Шлюз сессии выбирается параметром сессии gateway_kind ("gateway" — эталон
gateway_dev.py, "gateway_rs" — Rust) или --impl rs у lab run; мир — world_kind ("world" — настоящий, "world_fake" —
tools/olife/world_fake.py, чтобы мерить шлюз, а не мир).

Шаги сценариев:
  olife_gw_load {bots=20, rate=55, seconds=30, chat_every=0, chat_len=200, sample_s=1, min_ratio=0.95, prefix}
      аренда gw_load (tools/olife/gw_load.py: протокольные боты под лимитом шлюза), замер процесса шлюза (psutil: CPU,
      рабочий набор, private bytes, потоки) раз в sample_s, итог gw_load.json; ок — все боты дошли до конца (Disconnect
      только "bye"), отправлено >= min_ratio плана, шлюз жив, нет новых отказов кроме "closed".
  olife_soak {... seconds=600, sample_s=5, warmup_s=60, max_growth_pct=10, max_growth_mb=4}
      то же + память стабильна: медиана private bytes последних 10 % замеров <= медиана первых 10 % после прогрева
      * (1 + pct) + mb; наклон (МБ/мин) — в отчёте.
Перф (`lab perf olife gateway_load --param impl=rs|py ...`): сессия мир (fake|real) + шлюз + нагрузка, итог perf_summary.json.
"""
import json
import os
import time

P = {}


def bind(plugin_globals):
    P.update(plugin_globals)


LOAD_DEFAULT = {"bots": 20, "rate": 55, "seconds": 30, "chat_every": 0, "chat_len": 200, "sample_s": 1.0,
                "min_ratio": 0.95, "prefix": "load"}
SOAK_DEFAULT = dict(LOAD_DEFAULT, seconds=600, sample_s=5.0, warmup_s=60.0, max_growth_pct=10.0, max_growth_mb=4.0)


def _median(v):
    s = sorted(v)
    return s[len(s) // 2] if s else None


def _proc_sample(p):
    import psutil
    try:
        ct = p.cpu_times()
        mi = p.memory_info()
        priv = getattr(mi, "private", None) or getattr(mi, "vms", 0)
        try:
            handles = p.num_handles()
        except (AttributeError, psutil.Error):
            handles = None
        return {"t": time.time(), "cpu": ct.user + ct.system, "rss": mi.rss, "private": priv,
                "threads": p.num_threads(), "handles": handles}
    except psutil.Error:
        return None


def memory_verdict(samples, warmup_s, pct, mb):
    """медиана private первых/последних 10 % замеров после прогрева, рост, наклон МБ/мин (МНК)"""
    if not samples:
        return {"ok": False, "why": "no samples"}
    t0 = samples[0]["t"]
    s = [x for x in samples if x["t"] - t0 >= warmup_s]
    if len(s) < 10:
        return {"ok": False, "why": "too few samples after warmup (%d)" % len(s)}
    k = max(1, len(s) // 10)
    first = _median([x["private"] for x in s[:k]])
    last = _median([x["private"] for x in s[-k:]])
    limit = first * (1 + pct / 100.0) + mb * 1048576
    n = len(s)
    xs = [(x["t"] - s[0]["t"]) / 60.0 for x in s]
    ys = [x["private"] / 1048576.0 for x in s]
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs) or 1e-9
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
    return {"ok": last <= limit, "first_mb": round(first / 1048576, 2), "last_mb": round(last / 1048576, 2),
            "growth_mb": round((last - first) / 1048576, 3), "growth_pct": round((last - first) * 100.0 / first, 2),
            "limit_mb": round(limit / 1048576, 2), "slope_mb_per_min": round(slope, 4), "samples": n,
            "rss_first_mb": round(_median([x["rss"] for x in s[:k]]) / 1048576, 2),
            "rss_last_mb": round(_median([x["rss"] for x in s[-k:]]) / 1048576, 2),
            "max_private_mb": round(max(x["private"] for x in s) / 1048576, 2)}


def run_load(lab, owner, gw_lease, lease_fn, release_fn, args, progress=None, cancelled=None, watch=None,
             soak=False):
    """нагрузка gw_load на шлюз gw_lease + замер его процесса. lease_fn(kind, params) -> имя запущенной аренды."""
    import psutil
    a = dict(SOAK_DEFAULT if soak else LOAD_DEFAULT, **(args or {}))
    progress = progress or (lambda s: None)
    gl = lab.leases[gw_lease]
    gp = psutil.Process(gl.proc.info()["pid"])
    gport = lab.lease_info(gw_lease)["ports"]["gw"]
    call = lambda c, ar=None: lab.f2f(gw_lease, c, ar or {}, owner=owner).get("result")  # noqa: E731
    m0 = call("metrics") or {}
    params = {"gateway": gport}
    for k in ("bots", "rate", "seconds", "chat_every", "chat_len", "prefix"):
        params[k] = a[k]
    params["progress"] = 30 if soak else 10
    s0 = _proc_sample(gp)
    load = lease_fn("gw_load", params)
    ldir = lab.lease_info(load)["dir"]
    samples = [s0] if s0 else []
    errors = []
    budget = float(a["seconds"]) + int(a["bots"]) * 0.02 + 60
    t_start = time.time()
    last_note = t_start
    while True:
        p = lab.leases[load].proc
        if p is None or not p.alive():
            break
        if time.time() - t_start > budget:
            errors.append("gw_load did not finish in %.0f s" % budget)
            break
        if cancelled and cancelled():
            errors.append("cancelled")
            break
        time.sleep(float(a["sample_s"]))
        x = _proc_sample(gp)
        if x is None:
            errors.append("gateway process gone")
            break
        samples.append(x)
        for role, name in (watch or {}).items():
            wp = lab.leases[name].proc
            if wp is not None and not wp.alive():
                errors.append("%s %s died: %s" % (role, name, wp.info().get("exit")))
        if errors:
            break
        if soak and time.time() - last_note >= 60:
            last_note = time.time()
            progress("soak %.0f s: gateway private %.1f MB, rss %.1f MB, cpu %.1f s, threads %d" % (
                time.time() - t_start, x["private"] / 1048576, x["rss"] / 1048576, x["cpu"], x["threads"]))
    exit_info = lab.leases[load].proc.info() if lab.leases[load].proc else {}
    try:
        with open(os.path.join(ldir, "gw_load.json"), encoding="utf-8") as f:
            res = json.load(f)
    except (OSError, ValueError) as exc:
        res = None
        errors.append("no gw_load.json: %s" % exc)
    m1 = None
    try:
        m1 = call("metrics")
    except Exception as exc:
        errors.append("gateway metrics: %s" % exc)
    try:
        release_fn(load)
    except Exception as exc:
        errors.append("release %s: %s" % (load, exc))
    # процесс шлюза: CPU (% одного ядра), память
    cpu = []
    for x, y in zip(samples, samples[1:]):
        dt = y["t"] - x["t"]
        if dt > 0:
            cpu.append((y["cpu"] - x["cpu"]) * 100.0 / dt)
    wall = (samples[-1]["t"] - samples[0]["t"]) if len(samples) > 1 else 0
    gw = {"pid": gp.pid, "samples": len(samples),
          "cpu_pct_avg": round((samples[-1]["cpu"] - samples[0]["cpu"]) * 100.0 / wall, 2) if wall else None,
          "cpu_pct_p95": round(sorted(cpu)[int(0.95 * (len(cpu) - 1))], 2) if cpu else None,
          "cpu_s": round(samples[-1]["cpu"] - samples[0]["cpu"], 3) if samples else None,
          "rss_mb": {"start": round(samples[0]["rss"] / 1048576, 2), "end": round(samples[-1]["rss"] / 1048576, 2),
                     "max": round(max(x["rss"] for x in samples) / 1048576, 2)} if samples else None,
          "private_mb": {"start": round(samples[0]["private"] / 1048576, 2),
                         "end": round(samples[-1]["private"] / 1048576, 2),
                         "max": round(max(x["private"] for x in samples) / 1048576, 2)} if samples else None,
          "threads_max": max(x["threads"] for x in samples) if samples else None,
          "handles": [samples[0].get("handles"), samples[-1].get("handles")] if samples else None}
    rej0, rej1 = (m0.get("rejects") or {}), ((m1 or {}).get("rejects") or {})
    gw["rejects_delta"] = {k: v - rej0.get(k, 0) for k, v in rej1.items() if v - rej0.get(k, 0)}
    t0, t1 = (m0.get("total") or {}), ((m1 or {}).get("total") or {})
    gw["delta"] = {k: t1.get(k, 0) - t0.get(k, 0) for k in ("up", "down", "up_msgs", "down_msgs", "world_in", "world_out")}
    gw["world_to_gateway_ms"] = (m1 or {}).get("world_to_gateway_ms")
    gw["rtt_ms"] = (m1 or {}).get("rtt_ms")
    gw["impl"] = (m1 or {}).get("impl") or "gateway_dev.py"
    gw["world_queue"] = (m1 or {}).get("world_queue")
    out = {"ok": False, "errors": errors, "args": a, "gw_load_exit": exit_info.get("exit"), "gateway": gw}
    if res:
        planned = res.get("planned_msgs") or 1
        ratio = (res["total"]["sent"] - res["bots"] * 2) / planned      # без Hello/Bye
        out["load"] = {k: res.get(k) for k in ("duration_s", "bots", "total", "sent_per_s", "recv_per_s",
                                               "sent_bytes_per_s", "recv_bytes_per_s", "planned_msgs",
                                               "disconnect_codes", "errors", "welcome_ms", "sync_ms")}
        out["load"]["sent_ratio"] = round(ratio, 4)
        bad_codes = {c: n for c, n in (res.get("disconnect_codes") or {}).items() if c != "bye"}
        if bad_codes:
            errors.append("disconnects other than bye: %s" % bad_codes)
        if res.get("errors"):
            errors.append("client errors: %s" % res["errors"][:5])
        if ratio < float(a["min_ratio"]):
            errors.append("sent %.1f%% of the plan < %.0f%% (client could not keep the rate?)" % (
                ratio * 100, float(a["min_ratio"]) * 100))
        if (res.get("disconnect_codes") or {}).get("bye", 0) != res["bots"]:
            errors.append("bots ending with bye: %s of %d" % ((res.get("disconnect_codes") or {}).get("bye"), res["bots"]))
    unexpected = {k: v for k, v in gw["rejects_delta"].items() if k not in ("closed",)}
    if unexpected:
        errors.append("gateway rejects during load: %s" % unexpected)
    if soak:
        out["memory"] = memory_verdict(samples, float(a["warmup_s"]), float(a["max_growth_pct"]),
                                       float(a["max_growth_mb"]))
        if not out["memory"].get("ok"):
            errors.append("memory not stable: %s" % out["memory"])
    out["ok"] = not errors
    out["samples"] = samples
    return out


def _summary(rep):
    s = {k: rep.get(k) for k in ("ok", "errors")}
    s["load"] = {k: (rep.get("load") or {}).get(k) for k in ("bots", "sent_per_s", "recv_per_s", "sent_ratio",
                                                            "recv_bytes_per_s", "disconnect_codes", "sync_ms")}
    g = rep["gateway"]
    s["gateway"] = {k: g.get(k) for k in ("impl", "cpu_pct_avg", "cpu_pct_p95", "cpu_s", "rss_mb", "private_mb",
                                          "threads_max", "rejects_delta", "world_to_gateway_ms", "world_queue")}
    if "memory" in rep:
        s["memory"] = rep["memory"]
    return s


def _step(sx, args, soak):
    roles = P["_roles"](sx)
    gw = roles["gateway"]
    n = len([k for k in sx.leases if k.startswith("gw_load")]) + 1
    role = "gw_load_%d" % n

    def lease_fn(kind, params):
        return sx.lease(kind, role=role, params=params)

    def release_fn(name):
        sx.lab.release(name, owner=sx.owner, reason="gw_load done")
        sx.leases.pop(role, None)
    watch = {r: nm for r, nm in roles.items() if r in ("world", "gateway")}
    rep = run_load(sx.lab, sx.owner, gw, lease_fn, release_fn, args, progress=sx.log,
                   cancelled=lambda: sx.cancelled, watch=watch, soak=soak)
    name = (args or {}).get("name") or ("soak" if soak else "load_%d" % n)
    with open(os.path.join(sx.out_dir(), "olife_gw_%s.json" % name), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)
    s = _summary(rep)
    sx.data.setdefault("metrics", {}).setdefault("gw_load", {})[name] = s
    return {"ok": rep["ok"], "result": s, "error": "; ".join(rep["errors"]) or None}


def st_gw_load(sx, args, step):
    return _step(sx, args or {}, soak=False)


def st_soak(sx, args, step):
    return _step(sx, args or {}, soak=True)


# ---------------------------------------------------------------------------------------------- перф
def perf_gateway_load(px, a):
    """lab perf olife gateway_load --param impl=rs|py --param world=fake|real --param bots=50 --param seconds=30
    [--param soak=1 --param clients=6 ...]: сессия + нагрузка + замер процесса шлюза на простаивающем ПК."""
    a = dict(a or {})
    impl = a.pop("impl", "rs")
    world = a.pop("world", "fake")
    soak = str(a.pop("soak", "0")) in ("1", "true", "True")
    a.pop("tag", None)
    sess = {"clients": int(a.pop("clients", 0)), "client_kind": "bot", "sandbox": False,
            "gateway_kind": "gateway_rs" if impl == "rs" else "gateway",
            "world_kind": "world_fake" if world == "fake" else "world"}
    if "blocks" in a:
        sess["blocks"] = a.pop("blocks")
    if impl == "rs":
        # все протокольные боты идут с 127.0.0.1: прод-лимиты соединений на IP подняты только для замера
        sess["gateway_params"] = {"max_conns_per_ip": 1024, "conn_rate_ip": 1000, "conn_burst_ip": 1024}
    lab = px.lab

    def mk(kind, role, params):
        return px.lease(kind, params=dict(params))
    s = P["build_session"](mk, lab.lease_info, sess, log=px.progress)
    roles = dict(s["leases"])
    px.progress("session %s: %s" % (s["session"], roles))
    time.sleep(1.0)
    rep = run_load(lab, px.owner, roles["gateway"], lambda k, p: px.lease(k, params=dict(p)),
                   lambda n: lab.release(n, owner=px.owner, reason="gw_load done"), a, progress=px.progress,
                   cancelled=px.cancelled, watch={r: n for r, n in roles.items() if r in ("world", "gateway")},
                   soak=soak)
    summary = dict(_summary(rep), impl=impl, world=world, session=s["session"], start_s=s["timing"])
    path = os.path.join(px.out_dir, "perf_summary.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(dict(summary, samples=rep["samples"], full=dict(rep, samples=None)), f, ensure_ascii=False,
                  indent=1, default=str)
    px.progress("%s: sent %s/s recv %s/s | gateway cpu %s%% private %s MB | sync %s" % (
        impl, summary["load"].get("sent_per_s"), summary["load"].get("recv_per_s"),
        summary["gateway"].get("cpu_pct_avg"), summary["gateway"].get("private_mb"),
        (summary["load"].get("sync_ms") or {}).get("p50")))
    return dict(summary, summary_json=path)


def steps():
    return {"olife_gw_load": st_gw_load, "olife_soak": st_soak}


def register(api):
    if hasattr(api, "perf"):
        api.perf("gateway_load", perf_gateway_load, "Rust (impl=rs) or Python (impl=py) gateway under N protocol bots (gw_load) with a fake (world=fake) or real world: msgs/s, gateway CPU/memory, TickSync delay; soak=1 adds the memory-stability verdict")


def selftest():
    t = 1000.0
    flat = [{"t": t + i * 5, "private": 10 * 1048576 + (i % 3) * 1000, "rss": 8 * 1048576} for i in range(200)]
    v = memory_verdict(flat, 60, 10, 4)
    assert v["ok"] and abs(v["slope_mb_per_min"]) < 0.01, v
    leak = [{"t": t + i * 5, "private": 10 * 1048576 + i * 200000, "rss": 8 * 1048576} for i in range(200)]
    v = memory_verdict(leak, 60, 10, 4)
    assert not v["ok"] and v["slope_mb_per_min"] > 2, v
