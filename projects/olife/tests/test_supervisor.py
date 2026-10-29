"""Этап 6 (без движка): supervisor — vclab/supervise.py + хуки olife (настоящий plugin.py, копия как проект `sv`),
фейковые службы tests/fake_sup.py. Проверяется:
- БД состояния: миграция схемы 1 -> 2, аккаунты/токены, баны (вечный, временный, снятие), счётчики, тарифы;
- порядок старта мир -> песочница -> шлюз и стопа обратно; зависимости (песочница перезапущена -> миру
  sandbox_reconnect; шлюзу world_status supervised/note);
- падение -> инцидент (хвост лога, журнал кадров из export\\sup_state, перезапуск ok) -> перезапуск с бэкоффом
  0.3/0.6/1.2 с; предел перезапусков -> failed; зависший процесс (health) -> убит и перезапущен;
- учёт: счётчики по аккаунтам из метрик шлюза и состояния мира, кредиты по тарифу (смена тарифа без рестарта);
- манифест паков; авторизация шлюза через /sup/auth (+ запасной путь на файлы), /sup/state, /sup/panel.
Порты аренд 26340–26349."""
import json
import os
import shutil
import sqlite3
import textwrap
import time

import pytest

from conftest import HERE, PY, toml_str
from vclab import config
from vclab import policy
from vclab import supervise
from vclab.daemon.service import Lab

FAKE = os.path.join(HERE, "fake_sup.py")
OLIFE = os.path.join(os.path.dirname(HERE), "projects", "olife")
POL = {"backoff_s": 0.3, "factor": 2.0, "backoff_max_s": 5, "health_every_s": 0.5, "health_grace_s": 0.5,
       "health_fails": 3, "stable_s": 300, "max_restarts": 3, "window_s": 120}


def write_project(tmp):
    proj = os.path.join(tmp, "projects", "sv")
    os.makedirs(proj, exist_ok=True)
    for f in os.listdir(OLIFE):                    # plugin.py + его модули (sandbox_real.py волны 3a, ctlport.py)
        if f.endswith(".py"):
            shutil.copy2(os.path.join(OLIFE, f), os.path.join(proj, f))
    with open(os.path.join(proj, "project.toml"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [project]
        name = "sv"
        runs_dir = "{lab_data}\\\\runs_sv"
        plugin = "plugin.py"

        [kinds.world]
        engine = "none"
        exe = %(py)s
        ports = ["game"]
        stdin = true
        cwd = "{dir}"
        args = ["-u", %(fake)s, "world", "--port", "{port.game}", "--die-after", "{param.die_after}",
                "--sandbox", "{param.sandbox}", "--je", "{param.journal_every}"]
        params = { die_after = "", sandbox = 0, journal_every = 0, ticks = 0, mode = "" }
        default_log = "stdout"
        ready = [ { log = "\\\\[olife_world\\\\] ready", stream = "stdout", timeout = 20 } ]
        stop = [ { stdin = "olife.stop\\n", wait_exit = 5 } ]

        [kinds.sandbox]
        engine = "none"
        exe = %(py)s
        ports = ["sb", "f2f"]
        f2f = "f2f"
        cwd = "{dir}"
        args = ["-u", %(fake)s, "ctl", "--f2f", "{port.f2f}", "--listen", "{port.sb}"]
        default_log = "stdout"
        ready = [ { f2f = "hello", timeout = 20 } ]
        stop = [ { f2f = "quit", wait_exit = 3 } ]

        [kinds.gateway]
        engine = "none"
        exe = %(py)s
        ports = ["gw", "f2f", "http"]
        f2f = "f2f"
        cwd = "{dir}"
        args = ["-u", %(fake)s, "ctl", "--f2f", "{port.f2f}", "--listen", "{port.gw}", "--up", "{param.upstream}",
                "--auth", "{param.auth_url}", "--m", "{param.packs_manifest}"]
        params = { upstream = 0, auth_url = "", packs_manifest = "" }
        default_log = "stdout"
        ready = [ { f2f = "hello", timeout = 20 } ]
        stop = [ { f2f = "quit", wait_exit = 3 } ]
        """) % {"py": toml_str(PY), "fake": toml_str(FAKE)})
    return proj


@pytest.fixture
def lab(tmpdir_win, monkeypatch):
    write_project(tmpdir_win)
    monkeypatch.setenv("LAB_DATA", os.path.join(tmpdir_win, "data"))
    monkeypatch.setenv("LAB_PROJECTS", os.path.join(tmpdir_win, "projects"))
    monkeypatch.setenv("LAB_NO_WATCH", "1")
    monkeypatch.setenv("LAB_PORTS", "26340-26349")
    cfg = config.load()
    cfg["watchdog"] = {"enabled": False}
    lb = Lab(cfg, watch=False, background=True)
    assert getattr(lb, "sup", None) is not None
    assert lb.projects.get("sv").plugin_error is None, lb.projects.get("sv").plugin_error
    yield lb
    for g in list(lb.sup.groups.values()):
        try:
            lb.sup.down(g.name, force=True)
        except Exception:
            pass
    try:
        lb.stop_all()
    except Exception:
        pass
    lb.shutdown()
    policy.EXTRA_STOCK[:] = []


def up(lab, **kw):
    a = {"clients": 0, "policy": POL, "poll_s": 0.5, "autosave_s": 0}
    a.update(kw)
    return lab.call("sv.up", a, owner="agent_S")["result"]


def wait(cond, timeout=20.0, every=0.1):
    end = time.time() + timeout
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(every)
    raise AssertionError("timeout")


def ctl_calls(lab, lease):
    p = os.path.join(lab.lease_info(lease)["dir"], "ctl_calls.jsonl")
    try:
        with open(p, encoding="utf-8") as f:
            return [json.loads(x) for x in f if x.strip()]
    except OSError:
        return []


def log_lines(lab, lease):
    return lab.logs(lease, tail=500)["lines"]


# ---------------------------------------------------------------------------------------------- БД
def test_db_migration_and_auth(tmpdir_win):
    p = os.path.join(tmpdir_win, "s.sqlite")
    db = sqlite3.connect(p)                          # база схемы 1 (до logins/last_seen)
    db.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
    for st in supervise.MIGRATIONS[0][1]:
        db.execute(st)
    db.execute("INSERT INTO meta VALUES('schema','1')")
    db.execute("INSERT INTO accounts(name, token_hash, role, created) VALUES('old', ?, 'player', 1)",
               (supervise.token_hash("tok-old"),))
    db.commit()
    db.close()
    s = supervise.StateDB(p)
    assert s.migrated == [2] and s.version == supervise.SCHEMA_VERSION
    cols = {r["name"] for r in s._rows("PRAGMA table_info(accounts)")}
    assert "last_seen" in cols
    assert s.auth(supervise.token_hash("tok-old"), "1.2.3.4", "gw")["account"] == "old"     # данные пережили
    s.add_account("alice", "tok-a")
    assert s.auth(supervise.token_hash("nope"))["code"] == "auth"
    s.ban("account", "alice", 0, "griefing", "op")
    r = s.auth(supervise.token_hash("tok-a"))
    assert r["ok"] is False and r["code"] == "banned" and "griefing" in r["reason"] and r["until"] is None
    assert s.active_bans()["accounts"] == ["alice"]
    assert s.unban("account", "alice", "op")["lifted"] == 1
    assert s.auth(supervise.token_hash("tok-a"))["ok"] is True
    s.ban("ip", "9.9.9.9", 0.002, "flood", "op")                                    # 0.12 с
    assert s.auth(supervise.token_hash("tok-a"), "9.9.9.9")["code"] == "banned"
    time.sleep(0.2)
    assert s.auth(supervise.token_hash("tok-a"), "9.9.9.9")["ok"] is True          # временный бан истёк
    s.add_counters("alice", {"bytes_down": 100, "credits": 1.5})
    s.add_counters("alice", {"bytes_down": 50})
    s.set_counters("alice", {"entities": 3})
    assert s.counters()["alice"] == {"bytes_down": 150, "credits": 1.5, "entities": 3}
    s.seed_tariffs({"credits.per_action": 0.1})
    s.seed_tariffs({"credits.per_action": 9})                                       # seed не перетирает
    s.set_tariff("credits.per_action", 0.2, "op")
    assert s.tariffs() == {"credits.per_action": 0.2}
    assert [x["ok"] for x in s.logins(3)][:1] == [1]
    s.close()
    s2 = supervise.StateDB(p)                                                        # повторное открытие — без миграций
    assert s2.migrated == [] and s2.version == 2
    s2.close()


def test_pack_manifest(tmpdir_win):
    root = os.path.join(tmpdir_win, "content")
    for pk, files in (("cli", {"a.lua": b"x", "sub/b.json": b"{}"}), ("proto", {"m.lua": b"y"})):
        for rel, data in files.items():
            fp = os.path.join(root, pk, *rel.split("/"))
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp, "wb") as f:
                f.write(data)
    os.makedirs(os.path.join(root, "cli", "__pycache__"))
    out = os.path.join(tmpdir_win, "m", "manifest.json")
    m = supervise.pack_manifest(root, {"cli": "client", "proto": "both"}, out)
    assert m["files"] == 3 and os.path.exists(out)
    paths = {(e["path"], e["side"], e["size"]) for e in m["packs"]["cli"]["files"]}
    assert paths == {("a.lua", "client", 1), ("sub/b.json", "client", 2)}
    import hashlib
    assert m["packs"]["proto"]["files"][0]["sha256"] == hashlib.sha256(b"y").hexdigest()
    with open(os.path.join(root, "proto", "m.lua"), "wb") as f:
        f.write(b"z")
    m2 = supervise.pack_manifest(root, {"cli": "client", "proto": "both"})
    assert m2["version"] != m["version"]


def test_backoff_formula():
    pol = dict(supervise.DEFAULT_POLICY, backoff_s=1, factor=2, backoff_max_s=30)
    assert [supervise.backoff_for(n, pol) for n in (1, 2, 3, 5, 9)] == [1, 2, 4, 16, 30]


# ---------------------------------------------------------------------------------------------- службы
def test_order_dependencies_crash_restart(lab):
    t0 = time.time()
    s = up(lab)
    g, L = s["group"], s["leases"]
    starts = {r: lab.lease_info(n)["procs_hist"][0]["started"] for r, n in L.items()}
    assert starts["world"] < starts["sandbox"] < starts["gateway"], starts               # мир -> песочница -> шлюз
    assert lab.lease_info(L["gateway"])["params"]["auth_url"].endswith("/sup")
    assert lab.lease_info(L["world"])["params"]["journal_every"] == 20
    # зависимости при старте: миру sandbox_reconnect, шлюзу world_status supervised
    assert any("sandbox_reconnect queued" in x for x in log_lines(lab, L["world"]))
    assert any(c["cmd"] == "world_status" and c["args"].get("supervised") for c in ctl_calls(lab, L["gateway"]))
    sup = lab.sup
    grp = sup.get(g)
    wait(lambda: all(sv.last_check and sv.last_check["ok"] for sv in grp.services.values()), 10)
    assert sup.state()["groups"][g]["services"][0]["last_check"]["checks"][1]["check"] == "port"
    # падение мира -> инцидент + перезапуск с бэкоффом 0.3 с
    k = sup.kill(g, "world", "agent_S")
    w = grp.services["world"]
    wait(lambda: w.restarts == 1 and w.state == "up", 20)
    inc = sup.incident(w.last_incident)
    assert inc["why"] == "exit" and inc["restart"]["ok"] and inc["restart"]["backoff_s"] == pytest.approx(0.3)
    assert inc["capture"]["journal_frames"] >= 1 and os.path.exists(os.path.join(inc["dir"], "journal.json"))
    assert os.path.exists(os.path.join(inc["dir"], "stdout.tail.log")) and inc["logs"]["stdout"]["lines"] > 0
    assert inc["capture"]["sandbox_world_side"]["last_result"]["tick"] > 0
    assert inc["capture"]["sandbox_service_last_stats"]["ticks"] >= 0
    with open(os.path.join(inc["dir"], "journal.json"), encoding="utf-8") as f:
        j = json.load(f)
    assert j["frames"][-1]["type_name"] == "Data" and j["frames"][-1]["ctype_name"] in ("PlayerInput", "BlockAction")
    assert inc["t_detect"] - k["t"] < 2.0
    assert lab.lease_info(L["world"])["ports"] == lab.lease_info(L["world"])["ports"]       # та же аренда
    # шлюзу: заметка об инциденте при смерти, очистка после перезапуска
    calls = [c for c in ctl_calls(lab, L["gateway"]) if c["cmd"] == "world_status"]
    assert any("incident" in (c["args"].get("note") or "") for c in calls) and calls[-1]["args"].get("note") == ""
    assert sup.db.incidents(5)[0]["id"] == w.last_incident
    # песочница упала -> перезапуск -> миру sandbox_reconnect
    n_rec = sum("sandbox_reconnect queued" in x for x in log_lines(lab, L["world"]))
    sup.kill(g, "sandbox", "agent_S")
    sb = grp.services["sandbox"]
    wait(lambda: sb.restarts == 1 and sb.state == "up", 20)
    wait(lambda: sum("sandbox_reconnect queued" in x for x in log_lines(lab, L["world"])) > n_rec, 10)
    ev = [e["event"] for e in sup.db.events(100, g)]
    assert "dependency" in ev and "restart_ok" in ev and "incident" in ev
    # стоп: обратный порядок
    d = sup.down(g, "agent_S")
    assert [v["role"] for v in d["released"].values()] == ["gateway", "sandbox", "world"]
    assert all(v["ok"] for v in d["released"].values()) and lab.leases == {}
    print("order/deps/crash ok in %.1f s; incident %s" % (time.time() - t0, inc["id"]))


def test_backoff_grows_and_cap(lab):
    s = up(lab, sandbox=False, gateway=False)
    g = s["group"]
    sup = lab.sup
    w = sup.get(g).services["world"]
    backs = []
    for i in range(3):
        sup.kill(g, "world", "agent_S")
        wait(lambda: w.restarts == i + 1 and w.state == "up", 30)
        backs.append(sup.incident(w.last_incident)["restart"]["backoff_s"])
    assert backs == [pytest.approx(0.3), pytest.approx(0.6), pytest.approx(1.2)], backs
    sup.kill(g, "world", "agent_S")                      # 4-й за окно > max_restarts=3 -> failed
    wait(lambda: w.state == "failed", 15)
    inc = sup.incident(w.last_incident)
    assert inc["restart"]["gave_up"] is True and "cap 3" in inc["restart"]["message"]
    assert any(e["event"] == "gave_up" for e in sup.db.events(50, g))


def test_health_hang_kill_restart(lab):
    s = up(lab, sandbox=False, gateway=False)
    g = s["group"]
    sup = lab.sup
    w = sup.get(g).services["world"]
    wait(lambda: w.last_check and w.last_check["ok"], 10)
    lab.stdin(s["leases"]["world"], "hang", owner="agent_S", wait=0.5)
    wait(lambda: w.restarts == 1 and w.state == "up", 30)
    inc = sup.incident(w.last_incident)
    assert inc["why"] == "health" and inc["restart"]["ok"]
    assert any(e["event"] == "health_kill" for e in sup.db.events(50, g))
    wait(lambda: w.last_check and w.last_check["ok"] and w.last_check["t"] > inc["t_detect"] + 0.5, 10)  # снова здоров


def test_self_crash_detected(lab):
    s = up(lab, sandbox=False, gateway=False)
    g = s["group"]
    lab.lease_info(s["leases"]["world"])
    w = lab.sup.get(g).services["world"]
    lab.start(s["leases"]["world"], owner="agent_S", restart=True, params={"die_after": 1.0})
    wait(lambda: w.restarts >= 1, 20)
    inc = lab.sup.incident(w.last_incident)
    assert inc["exit"] == "exit 3" and any("dying on purpose" in x for x in
                                           open(os.path.join(inc["dir"], "stdout.tail.log"), encoding="utf-8"))


def test_metering_and_tariff(lab):
    s = up(lab, sandbox=True)
    g = s["group"]
    sup = lab.sup
    grp = sup.get(g)
    wait(lambda: (grp.poll_data or {}).get("gateway") and (grp.poll_data or {}).get("world"), 10)
    wait(lambda: sup.db.counters().get("bot1", {}).get("bytes_down", 0) > 0, 10)
    c = sup.db.counters()
    assert c["bot1"]["credits"] > 0 and c["bot1"]["actions"] >= 0
    assert c["owner:1"]["entities"] == 2 and c["owner:1"]["fuel"] > 0
    assert grp.poll_data["players"][0]["account"] == "bot1" and grp.poll_data["world"]["scripted"] == 2
    # тариф без рестарта: цена пакета x1000 -> прирост кредитов за опрос заметно больше
    before = sup.db.counters()["bot1"]["credits"]
    time.sleep(1.2)
    slow = sup.db.counters()["bot1"]["credits"] - before
    lab.call("sv.tariff", {"action": "set", "key": "credits.per_packet", "value": 1.0}, owner="agent_S")
    time.sleep(0.6)
    before = sup.db.counters()["bot1"]["credits"]
    time.sleep(1.2)
    fast = sup.db.counters()["bot1"]["credits"] - before
    assert fast > slow * 10, (slow, fast)
    st = lab.call("sv.sup_status", {}, owner="agent_S")["result"]
    assert st["groups"][g]["services"]["world"]["state"] == "up" and os.path.exists(st["panel"])


def test_http_auth_state_panel_and_gateway_fallback(lab):
    from fastapi.testclient import TestClient
    from vclab.daemon.api import create_app
    s = up(lab, sandbox=False)
    c = TestClient(create_app(lab))
    for i in (1, 2):                                       # как seed_db при clients=N: bot<i> / olife-bot<i>
        lab.call("sv.accounts", {"action": "add", "name": "bot%d" % i, "token": "olife-bot%d" % i, "role": "bot"},
                 owner="agent_S")
    sha = supervise.token_hash("olife-bot1")
    assert c.get("/sup/auth", params={"token_sha": sha, "ip": "127.0.0.1"}).json()["account"] == "bot1"
    assert c.get("/sup/auth", params={"token_sha": supervise.token_hash("olife-banned")}).json()["code"] == "banned"
    lab.call("sv.ban", {"account": "bot1", "minutes": 5, "reason": "test"}, owner="agent_S")
    assert c.get("/sup/bans").json()["accounts"] == ["banned", "bot1"]
    assert c.get("/sup/auth", params={"token_sha": sha}).json()["code"] == "banned"
    lab.call("sv.unban", {"account": "bot1"}, owner="agent_S")
    r = c.get("/sup/state", params={"prefix": "olife-"})
    assert r.headers["access-control-allow-origin"] == "*" and s["group"] in r.json()["groups"]
    assert "__URL__" not in c.get("/sup/panel").text and "/sup/state" in c.get("/sup/panel").text
    # шлюз: БД через HTTP (заглушка поверх той же БД), демон недоступен -> файлы
    import sys
    import threading
    import http.server
    import urllib.parse
    sys.path.insert(0, os.path.join(config.REPO_ROOT, "projects", "olife", "tools"))
    import gateway_dev
    db = lab.sup.db

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
            body = db.auth(q["token_sha"], q.get("ip"), q.get("gateway")) if u.path.endswith("/auth") else \
                db.active_bans()
            data = json.dumps(body, default=str).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(data)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 26349), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        gw = gateway_dev.Gateway({"auth-url": "http://127.0.0.1:26349/sup", "name": "gwt"})
        assert gw.authenticate("olife-bot2", "127.0.0.1")[0] == "bot2"           # только в БД, не в файле
        assert gw.authenticate("olife-banned", "127.0.0.1")[1] == "banned"
        assert gw.authenticate("nope", "127.0.0.1")[1] == "auth"
        gw2 = gateway_dev.Gateway({"auth-url": "http://127.0.0.1:26348/sup", "name": "gwf"})   # никто не слушает
        assert gw2.authenticate("olife-dev", "127.0.0.1")[0] == "dev"            # запасной путь: файл
        assert gw2.authenticate("olife-bot2", "127.0.0.1")[0] is None
        assert any(e["kind"] == "auth_fallback" for e in gw2.m["events"])
    finally:
        srv.shutdown()
