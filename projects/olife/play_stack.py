"""Olife: «коляска» сеанса игры (вид play_stack проекта olife; 02.10, агент olife_play).

Сеанс `lab play olife` ядра (labcore/play.py) запускает виды по порядку [play].order: сначала этот процесс, потом
стоковый рантайм. Процесс через HTTP демона (тот же владелец, что у сеанса) вызывает `olife.play_up` — стек под
supervisor (мир на постоянном мире пользователя, песочница, сервис билетов, Rust-шлюз, аккаунт user, примеры бенчей,
файл подключения клиента), печатает `[olife_play] stack ready` (готовность вида), раз в 10 с — строку статуса стека и
события (вход/выход игрока, инцидент, перезапуск службы). На `stop` в stdin (шаг stop вида; так play.py гасит сервер
после выхода движка) — `olife.play_down` (сводка olife_session.json/md в каталог прогона, сохранение мира, снятие
группы) и выход. Убит без stop — группу снимает хук опроса (PlayHooks: «коляска» мертва > 30 с).

  python play_stack.py --owner <владелец> --lease <аренда> --dir <каталог аренды> --run-dir <каталог прогона>
                       --mode play|dry --daemon-port 25700 [--public 1]
--public 1 (olife_friends 16.10, `play.bat public`): стек на фиксированных портах [play.public] на 0.0.0.0, вайтлист включён;
после готовности — строки приглашения (`olife.ip`: LAN, VPN, внешний IP) в журнал коляски.
"""
import http.client
import json
import os
import sys
import threading
import time


def argmap(argv):
    out, i = {}, 0
    while i < len(argv):
        if argv[i].startswith("--"):
            k = argv[i][2:].replace("-", "_")
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                out[k] = argv[i + 1]
                i += 2
                continue
            out[k] = ""
        i += 1
    return out


A = argmap(sys.argv[1:])
PORT = int(A.get("daemon_port") or os.environ.get("LAB_PORT") or 25700)
OWNER = A.get("owner") or "user"


def log(line):
    print("[olife_play] " + line, flush=True)


def call(feature, args, timeout=600.0):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=timeout)
    body = json.dumps({"args": args}).encode("utf-8")
    conn.request("POST", "/call/%s" % feature, body=body, headers={"Content-Type": "application/json",
                                                                   "X-Lab-Owner": OWNER, "X-Lab-Client": "play_stack"})
    r = conn.getresponse()
    raw = r.read()
    conn.close()
    d = json.loads(raw.decode("utf-8"))
    if not d.get("ok"):
        raise RuntimeError("%s: %s %s" % (feature, d.get("error"), (d.get("message") or "")[:600]))
    return d.get("result")


def tms(t):
    """такт мира: {avg, p95, max} -> строка"""
    if isinstance(t, dict):
        return "tick_ms avg %.2f p95 %.2f max %.2f" % (t.get("avg") or 0, t.get("p95") or 0, t.get("max") or 0)
    return "tick_ms %s" % t


STOP = threading.Event()


def reader():
    for line in sys.stdin:
        if line.strip() in ("stop", "quit", "olife.stop"):
            STOP.set()
            return
    STOP.set()              # stdin закрыт — тоже конец


def main():
    t0 = time.time()
    mode = A.get("mode") or "play"
    public = (A.get("public") or "0") not in ("0", "", "false")
    log("stack starting mode=%s public=%d owner=%s daemon=%d lease=%s" % (mode, public, OWNER, PORT, A.get("lease")))
    try:
        up = call("olife.play_up", {"mode": mode, "sidecar": A.get("lease"), "run_dir": A.get("run_dir") or None,
                                    "public": 1 if public else 0}, timeout=900)
    except Exception as exc:
        log("stack FAILED: %s" % exc)
        return 3
    with open(os.path.join(A.get("dir") or ".", "play_stack.json"), "w", encoding="utf-8") as f:
        json.dump(up, f, ensure_ascii=False, indent=1)
    log("group %s leases %s" % (up["group"], " ".join("%s=%s" % kv for kv in up["leases"].items())))
    log("world %s (%s); samples spawned now: %s; benches: %s" % (up["worlds"], up["worlds_source"],
                                                                ",".join(up["samples_spawned"]) or "none (already there)",
                                                                " ".join("%s:%s:%s" % (b["eid"], b["name"], b["status"])
                                                                         for b in up.get("benches") or [])))
    host = "0.0.0.0" if up.get("public") else "127.0.0.1"
    log("gateway %s:%d (tickets only, gw_id %s), auth https://%s:%d, packs http %s:%d, admin 127.0.0.1:%d" % (
        host, up["gateway_port"], up["gw_id"], host, up["auth_port"], host, up["packs_http"], up["admin_port"]))
    if up.get("public"):
        wl = up.get("whitelist") or {}
        log("PUBLIC: friends connect to <this PC>:%d (router: forward TCP %d, %d, %d); whitelist %s (%d: %s)" % (
            up["gateway_port"], up["gateway_port"], up["auth_port"], up["packs_http"],
            "on" if wl.get("enabled") else "OFF", len(wl.get("names") or []), ",".join(wl.get("names") or []) or "-"))
    log("client config %s; token file %s; panel %s" % (up.get("client_config") or up["config"], up["token_file"],
                                                        up["panel"]))
    log("stack ready in %.1f s (%s)" % (time.time() - t0, " ".join("%s %.2fs" % kv for kv in up["timing"].items())))
    if up.get("public"):
        try:                                    # внешний IP — echo-сервис, до 12 с; не держит готовность стека
            ip = call("olife.ip", {"auth_pub": up.get("auth_pub")}, timeout=60)
            for line in (ip.get("text") or "").splitlines():
                log("invite " + line)
        except Exception as exc:                # noqa: BLE001
            log("invite: %s" % exc)
    threading.Thread(target=reader, daemon=True).start()
    players, incidents, restarts = set(), set(), {}
    last = 0.0
    while not STOP.is_set():
        STOP.wait(1.0)
        if STOP.is_set() or time.time() - last < 10:
            continue
        last = time.time()
        try:
            st = call("olife.play_status", {"group": up["group"]}, timeout=20)
        except Exception as exc:
            log("status error: %s" % exc)
            continue
        if st.get("state") != "up":
            log("group is %s (taken down outside the session)" % st.get("state"))
            break
        now = set(st.get("players") or [])
        for p in sorted(now - players):
            log("login %s" % p)
        for p in sorted(players - now):
            log("logout %s" % p)
        players = now
        for i in st.get("incidents") or []:
            if i["id"] not in incidents:
                incidents.add(i["id"])
                log("incident %s %s %s: %s" % (i["id"], i["service"], i["why"], (i.get("summary") or "")[:200]))
        for role, s in (st.get("services") or {}).items():
            if s.get("restarts", 0) > restarts.get(role, 0):
                log("restart %s (total %d)" % (role, s["restarts"]))
            restarts[role] = s.get("restarts", 0)
        log("status players %d tick %s %s entities %s scripted %s gw_sessions %s rejects %s" % (
            len(now), st.get("world_tick"), tms(st.get("tick_ms")), st.get("entities"), st.get("scripted"),
            st.get("gw_sessions"), json.dumps(st.get("gw_rejects"), ensure_ascii=False)))
    log("stopping: play_down")
    try:
        out = call("olife.play_down", {"group": up["group"], "run_dir": A.get("run_dir") or None,
                                       "reason": "session end"}, timeout=300)
        st = out.get("status") or {}
        log("summary world tick %s %s entities %s; players at stop %s; incidents %d" % (
            st.get("world_tick"), tms(st.get("tick_ms")), st.get("entities"), ",".join(st.get("players") or []) or "-",
            len(st.get("incidents") or [])))
        for b in out.get("benches") or []:
            log("bench %s %s owner=%s status=%s" % (b["eid"], b["name"], b["owner"], b["status"]))
        m = out.get("sandbox_meters") or {}
        for v in (m.get("owners") or []) if isinstance(m, dict) else []:
            log("sandbox owner %s fuel %s credits %s actions %s ticks %s kills %s status %s" % (
                v.get("owner"), v.get("fuel"), v.get("credits"), v.get("actions"), v.get("ticks"), v.get("kills"),
                json.dumps(v.get("status"))))
        for a, c in sorted((out.get("counters") or {}).items()):
            log("meter %s %s" % (a, json.dumps(c, ensure_ascii=False)[:300]))
        log("released %s" % " ".join("%s:%s" % (k, (v or {}).get("exit")) for k, v in
                                    ((out.get("down") or {}).get("released") or {}).items()))
        log("session summary %s" % " ".join(out.get("files") or []))
    except Exception as exc:
        log("play_down FAILED: %s" % exc)
        return 4
    log("stack stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
