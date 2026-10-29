"""Этап 6: supervisor (control plane) поверх аренд — «Supervisor = развитие лаб-демона» (архитектура первого проекта-сервера).

Ядро общее (про конкретный проект здесь ничего): проект описывает свои службы и хуки в plugin.py, ядро даёт
  * группы служб (`Group`) поверх аренд: роль, health-проверки (stdin+шаблон, F2F-команда, порт в LISTEN у дерева Job),
    политика перезапуска (экспоненциальный бэкофф с потолком, предел перезапусков в окне -> `failed`), порядок старта =
    порядок `add`, остановка — обратный; неуправляемые участники (клиенты/боты) — только продление и показ;
  * перезапуск упавшего (`lab.start(restart=True)` той же аренды: те же порты, тот же каталог) и хуки зависимостей:
    `started(sup, svc, restart)`, `died(sup, svc, incident)`, `capture(sup, svc, dir) -> dict`, `poll(sup, group) -> dict`;
  * инциденты: `<data>\\incidents\\<время>_<группа>_<роль>\\` (incident.json/.md, хвосты логов, то, что дал capture),
    строка в БД;
  * БД состояния `<data>\\supervisor.sqlite` (писатель — только демон, как у истории): accounts, bans, counters, tariffs,
    incidents, service_events, logins; миграции по номеру схемы;
  * HTTP для шлюзов (api.py): `/sup/auth`, `/sup/bans`; панель: `/sup/state` (JSON) + `/sup/panel` (HTML+JS) и та же
    страница файлом `<data>\\dashboard\\<имя>.html` (fetch к демону на 127.0.0.1);
  * манифест паков (`pack_manifest`): путь, sha256, размер, сторона.
Код ядра подхватывается только рестартом демона (`lab daemon upgrade`); хуки проектов — горячо (plugin.py)."""
import collections
import hashlib
import json
import os
import sqlite3
import threading
import time
import traceback

SCHEMA_VERSION = 3
MIGRATIONS = [
    (1, [
        "CREATE TABLE IF NOT EXISTS accounts(name TEXT PRIMARY KEY, token_hash TEXT UNIQUE, role TEXT, created REAL,"
        " note TEXT)",
        "CREATE TABLE IF NOT EXISTS bans(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, value TEXT, until REAL,"
        " reason TEXT, by TEXT, created REAL, lifted REAL, lifted_by TEXT)",
        "CREATE TABLE IF NOT EXISTS counters(account TEXT, metric TEXT, value REAL, updated REAL,"
        " PRIMARY KEY(account, metric))",
        "CREATE TABLE IF NOT EXISTS tariffs(key TEXT PRIMARY KEY, value REAL, updated REAL, by TEXT)",
        "CREATE TABLE IF NOT EXISTS incidents(id TEXT PRIMARY KEY, ts REAL, grp TEXT, service TEXT, lease TEXT,"
        " why TEXT, exit TEXT, dir TEXT, summary TEXT, restart TEXT)",
        "CREATE TABLE IF NOT EXISTS service_events(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, grp TEXT,"
        " service TEXT, lease TEXT, event TEXT, detail TEXT)",
    ]),
    (2, [                     # вход игрока через шлюз регистрируется у supervisor (ARCHITECTURE §2 «Вход игрока»)
        "ALTER TABLE accounts ADD COLUMN last_seen REAL",
        "CREATE TABLE IF NOT EXISTS logins(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, account TEXT, ip TEXT,"
        " gateway TEXT, ok INTEGER, reason TEXT)",
        "CREATE INDEX IF NOT EXISTS logins_account ON logins(account, ts)",
    ]),
    (3, [                     # 03.10: друзья аккаунтов и настройки аккаунта (права по умолчанию и т.п.)
        "CREATE TABLE IF NOT EXISTS friends(a TEXT, b TEXT, state TEXT, created REAL, updated REAL, by TEXT,"
        " PRIMARY KEY(a, b))",
        "CREATE INDEX IF NOT EXISTS friends_b ON friends(b)",
        "CREATE TABLE IF NOT EXISTS account_settings(account TEXT, key TEXT, value TEXT, updated REAL, by TEXT,"
        " PRIMARY KEY(account, key))",
    ]),
]
SOCIAL_SQL = MIGRATIONS[2][1]         # идемпотентно (IF NOT EXISTS): плагин проекта создаёт таблицы на живом демоне


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class StateDB:
    """SQLite состояния supervisor. Один писатель — процесс демона (RLock); CLI/MCP — через демон."""

    def __init__(self, path):
        self.path = path
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False, timeout=30)
        self.db.row_factory = sqlite3.Row
        self.migrated = []
        with self.lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
            row = self.db.execute("SELECT value FROM meta WHERE key='schema'").fetchone()
            cur = int(row[0]) if row else 0
            for ver, stmts in MIGRATIONS:
                if ver <= cur:
                    continue
                for st in stmts:
                    try:
                        self.db.execute(st)
                    except sqlite3.OperationalError as exc:
                        if "duplicate column" not in str(exc):
                            raise
                self.db.execute("INSERT OR REPLACE INTO meta VALUES('schema', ?)", (str(ver),))
                self.migrated.append(ver)
                cur = ver
            self.db.commit()
        self.version = cur

    def close(self):
        with self.lock:
            self.db.close()

    def _rows(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.db.execute(sql, args).fetchall()]

    def _exec(self, sql, args=()):
        with self.lock:
            cur = self.db.execute(sql, args)
            self.db.commit()
            return cur

    # ---------------------------------------------------------------- accounts / auth
    def add_account(self, name, token=None, role="player", note=None):
        with self.lock:
            old = self.db.execute("SELECT * FROM accounts WHERE name=?", (name,)).fetchone()
            th = token_hash(token) if token else (old["token_hash"] if old else None)
            if th:
                self.db.execute("UPDATE accounts SET token_hash=NULL WHERE token_hash=? AND name<>?", (th, name))
            self.db.execute("INSERT OR REPLACE INTO accounts(name, token_hash, role, created, note, last_seen) "
                            "VALUES(?,?,?,?,?,?)", (name, th, role or (old["role"] if old else "player"),
                                                   old["created"] if old else time.time(),
                                                   note if note is not None else (old["note"] if old else None),
                                                   old["last_seen"] if old else None))
            self.db.commit()
        return {"account": name, "role": role}

    def accounts(self):
        return self._rows("SELECT name, role, created, last_seen, note FROM accounts ORDER BY name")

    def ban_of(self, account=None, ip=None, now=None):
        now = now or time.time()
        for kind, val in (("account", account), ("ip", ip)):
            if not val:
                continue
            r = self._rows("SELECT * FROM bans WHERE kind=? AND value=? AND lifted IS NULL AND (until IS NULL OR "
                           "until > ?) ORDER BY id DESC LIMIT 1", (kind, val, now))
            if r:
                return r[0]
        return None

    def auth(self, token_sha, ip=None, gateway=None):
        """Шлюз: sha256 токена -> {ok, account, role} | {ok: false, code: auth|banned, reason, until}."""
        with self.lock:
            row = self.db.execute("SELECT name, role FROM accounts WHERE token_hash=?", (token_sha,)).fetchone()
        if row is None:
            self._exec("INSERT INTO logins(ts, account, ip, gateway, ok, reason) VALUES(?,?,?,?,0,?)",
                       (time.time(), None, ip, gateway, "bad token"))
            return {"ok": False, "code": "auth", "reason": "bad token"}
        ban = self.ban_of(row["name"], ip)
        if ban:
            why = "banned%s: %s" % (" until %s" % time.strftime("%Y-%m-%d %H:%M", time.localtime(ban["until"]))
                                    if ban["until"] else "", ban["reason"] or "")
            self._exec("INSERT INTO logins(ts, account, ip, gateway, ok, reason) VALUES(?,?,?,?,0,?)",
                       (time.time(), row["name"], ip, gateway, why))
            return {"ok": False, "code": "banned", "reason": why[:200], "until": ban["until"]}
        with self.lock:
            self.db.execute("UPDATE accounts SET last_seen=? WHERE name=?", (time.time(), row["name"]))
            self.db.execute("INSERT INTO logins(ts, account, ip, gateway, ok, reason) VALUES(?,?,?,?,1,NULL)",
                            (time.time(), row["name"], ip, gateway))
            self.db.commit()
        return {"ok": True, "account": row["name"], "role": row["role"]}

    def logins(self, last=20):
        return self._rows("SELECT * FROM logins ORDER BY id DESC LIMIT ?", (int(last),))

    # ---------------------------------------------------------------- bans
    def ban(self, kind, value, minutes=0, reason="", by=None):
        if kind not in ("account", "ip"):
            raise ValueError("ban kind: account|ip")
        until = time.time() + float(minutes) * 60 if minutes and float(minutes) > 0 else None
        cur = self._exec("INSERT INTO bans(kind, value, until, reason, by, created) VALUES(?,?,?,?,?,?)",
                         (kind, value, until, reason, by, time.time()))
        return {"id": cur.lastrowid, "kind": kind, "value": value, "until": until, "reason": reason, "by": by}

    def unban(self, kind, value, by=None):
        cur = self._exec("UPDATE bans SET lifted=?, lifted_by=? WHERE kind=? AND value=? AND lifted IS NULL",
                         (time.time(), by, kind, value))
        return {"lifted": cur.rowcount}

    def active_bans(self):
        rows = self._rows("SELECT * FROM bans WHERE lifted IS NULL AND (until IS NULL OR until > ?) ORDER BY id",
                          (time.time(),))
        return {"accounts": sorted({r["value"] for r in rows if r["kind"] == "account"}),
                "ips": sorted({r["value"] for r in rows if r["kind"] == "ip"}), "rows": rows}

    # ---------------------------------------------------------------- counters / tariffs
    def add_counters(self, account, deltas):
        now = time.time()
        with self.lock:
            for m, v in deltas.items():
                if not v:
                    continue
                self.db.execute("INSERT INTO counters(account, metric, value, updated) VALUES(?,?,?,?) "
                                "ON CONFLICT(account, metric) DO UPDATE SET value=value+excluded.value, "
                                "updated=excluded.updated", (account, m, float(v), now))
            self.db.commit()

    def set_counters(self, account, values):
        now = time.time()
        with self.lock:
            for m, v in values.items():
                self.db.execute("INSERT OR REPLACE INTO counters(account, metric, value, updated) VALUES(?,?,?,?)",
                                (account, m, float(v or 0), now))
            self.db.commit()

    def counters(self):
        out = {}
        for r in self._rows("SELECT * FROM counters ORDER BY account, metric"):
            out.setdefault(r["account"], {})[r["metric"]] = r["value"]
        return out

    def seed_tariffs(self, defaults, by="default"):
        with self.lock:
            for k, v in defaults.items():
                self.db.execute("INSERT OR IGNORE INTO tariffs(key, value, updated, by) VALUES(?,?,?,?)",
                                (k, float(v), time.time(), by))
            self.db.commit()

    def set_tariff(self, key, value, by=None):
        self._exec("INSERT OR REPLACE INTO tariffs(key, value, updated, by) VALUES(?,?,?,?)",
                   (key, float(value), time.time(), by))
        return {"key": key, "value": float(value)}

    def tariffs(self):
        return {r["key"]: r["value"] for r in self._rows("SELECT key, value FROM tariffs ORDER BY key")}

    # ---------------------------------------------------------------- friends / account settings (схема 3)
    # friends(a, b, state): state 'friend' — пара хранится один раз (a < b); 'request' — запрос от a к b (направленный).
    # Писатель — демон (CLI проекта `lab <проект> friend ...`, события мира из sup_state `friends_ev` через плагин).
    def _pair(self, a, b):
        return (a, b) if a < b else (b, a)

    def friend_state(self, a, b):
        x, y = self._pair(a, b)
        with self.lock:
            if self.db.execute("SELECT 1 FROM friends WHERE a=? AND b=? AND state='friend'", (x, y)).fetchone():
                return "friend"
            if self.db.execute("SELECT 1 FROM friends WHERE a=? AND b=? AND state='request'", (a, b)).fetchone():
                return "request"
            if self.db.execute("SELECT 1 FROM friends WHERE a=? AND b=? AND state='request'", (b, a)).fetchone():
                return "incoming"
        return "none"

    def friend_set(self, a, b, state, by=None):
        """state: friend | request (a просит b) | none. -> {a, b, state, was}"""
        if not a or not b or a == b:
            raise ValueError("friend: two different accounts")
        if state not in ("friend", "request", "none"):
            raise ValueError("friend state: friend|request|none")
        was = self.friend_state(a, b)
        x, y = self._pair(a, b)
        now = time.time()
        with self.lock:
            if state in ("friend", "none"):
                self.db.execute("DELETE FROM friends WHERE (a=? AND b=?) OR (a=? AND b=?)", (a, b, b, a))
            if state == "friend":
                self.db.execute("INSERT INTO friends(a, b, state, created, updated, by) VALUES(?,?,?,?,?,?)",
                                (x, y, "friend", now, now, by))
            elif state == "request" and was not in ("friend", "request"):
                if was == "incoming":            # встречный запрос = дружба (как в мире)
                    self.db.execute("DELETE FROM friends WHERE a=? AND b=?", (b, a))
                    self.db.execute("INSERT INTO friends(a, b, state, created, updated, by) VALUES(?,?,?,?,?,?)",
                                    (x, y, "friend", now, now, by))
                    state = "friend"
                else:
                    self.db.execute("INSERT INTO friends(a, b, state, created, updated, by) VALUES(?,?,?,?,?,?)",
                                    (a, b, "request", now, now, by))
            elif state == "request":
                state = was if was == "friend" else "request"
            self.db.commit()
        return {"a": a, "b": b, "state": state, "was": was}

    def friend_cancel(self, a, b, by=None):
        """снять запрос a -> b (отказ или отмена)"""
        with self.lock:
            cur = self.db.execute("DELETE FROM friends WHERE a=? AND b=? AND state='request'", (a, b))
            self.db.commit()
        return {"a": a, "b": b, "removed": cur.rowcount}

    def friends_of(self, account):
        """-> {friends: [..], incoming: [..], outgoing: [..]}"""
        r = self._rows("SELECT a, b, state FROM friends WHERE a=? OR b=?", (account, account))
        fr = sorted({x["b"] if x["a"] == account else x["a"] for x in r if x["state"] == "friend"})
        inc = sorted(x["a"] for x in r if x["state"] == "request" and x["b"] == account)
        out = sorted(x["b"] for x in r if x["state"] == "request" and x["a"] == account)
        return {"account": account, "friends": fr, "incoming": inc, "outgoing": out}

    def friend_pairs(self):
        return self._rows("SELECT a, b, state, updated, by FROM friends ORDER BY a, b")

    def setting_set(self, account, key, value, by=None):
        if value is None:
            self._exec("DELETE FROM account_settings WHERE account=? AND key=?", (account, key))
        else:
            self._exec("INSERT OR REPLACE INTO account_settings(account, key, value, updated, by) VALUES(?,?,?,?,?)",
                       (account, key, str(value), time.time(), by))
        return {"account": account, "key": key, "value": value}

    def settings_of(self, account=None):
        if account:
            return {r["key"]: r["value"] for r in
                    self._rows("SELECT key, value FROM account_settings WHERE account=? ORDER BY key", (account,))}
        out = {}
        for r in self._rows("SELECT account, key, value FROM account_settings ORDER BY account, key"):
            out.setdefault(r["account"], {})[r["key"]] = r["value"]
        return out

    # ---------------------------------------------------------------- incidents / events
    def add_incident(self, rec):
        self._exec("INSERT OR REPLACE INTO incidents(id, ts, grp, service, lease, why, exit, dir, summary, restart) "
                   "VALUES(?,?,?,?,?,?,?,?,?,?)",
                   (rec["id"], rec["ts"], rec["group"], rec["role"], rec["lease"], rec["why"], rec.get("exit"),
                    rec["dir"], rec.get("summary"), json.dumps(rec.get("restart"), default=str)))

    def incidents(self, last=20, group=None):
        q, a = "SELECT * FROM incidents", []
        if group:
            q += " WHERE grp=?"
            a.append(group)
        rows = self._rows(q + " ORDER BY ts DESC LIMIT ?", a + [int(last)])
        for r in rows:
            try:
                r["restart"] = json.loads(r["restart"]) if r["restart"] else None
            except ValueError:
                pass
        return rows

    def event(self, grp, service, lease, event, detail=None):
        self._exec("INSERT INTO service_events(ts, grp, service, lease, event, detail) VALUES(?,?,?,?,?,?)",
                   (time.time(), grp, service, lease, event,
                    detail if isinstance(detail, str) or detail is None else json.dumps(detail, default=str)))

    def events(self, last=50, group=None):
        q, a = "SELECT * FROM service_events", []
        if group:
            q += " WHERE grp=?"
            a.append(group)
        return self._rows(q + " ORDER BY id DESC LIMIT ?", a + [int(last)])


# ------------------------------------------------------------------------------------------------- службы
DEFAULT_POLICY = {"max_restarts": 5, "window_s": 600.0, "backoff_s": 1.0, "factor": 2.0, "backoff_max_s": 30.0,
                  "stable_s": 60.0, "health_every_s": 5.0, "health_fails": 3, "health_grace_s": 10.0,
                  "renew_every_s": 60.0, "ttl": 1800}


def backoff_for(n, pol):
    """n-я подряд неудача (1, 2, ...) -> пауза перед перезапуском, с."""
    return min(float(pol["backoff_max_s"]), float(pol["backoff_s"]) * float(pol["factor"]) ** max(0, n - 1))


def kv(line):
    out = {}
    for tok in (line or "").split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                out[k] = float(v) if "." in v else int(v)
            except ValueError:
                out[k] = v
    return out


class Service:
    def __init__(self, group, role, lease, health=None, policy=None, managed=True):
        self.group, self.role, self.lease = group, role, lease
        self.health = list(health or [])
        self.policy = dict(DEFAULT_POLICY, **(policy or {}))
        self.managed = managed
        self.state = "new"
        self.restarts = 0
        self.fails = 0
        self.restart_times = collections.deque(maxlen=100)
        self.started_at = None
        self.checks = collections.deque(maxlen=30)
        self.last_check = None
        self.health_fails = 0
        self.last_status = None          # разобранная строка stdin-проверки (kv)
        self.last_info = {}              # последние ответы F2F-проверок по команде (stats, metrics, ...)
        self.last_exit = None
        self.last_incident = None
        self.next_restart_at = None
        self.backoff_s = None
        self.stop = False
        self.thread = None
        self.renewed = time.time()

    def info(self, lab=None):
        l = lab.leases.get(self.lease) if lab and self.state != "stopped" else None
        pid = l.proc.pid if l is not None and l.proc else None
        up = round(time.time() - self.started_at, 1) if self.started_at and self.state == "up" else None
        return {"role": self.role, "lease": self.lease, "managed": self.managed, "state": self.state,
                "lease_state": l.state if l is not None else "gone", "pid": pid, "uptime_s": up,
                "restarts": self.restarts, "fails": self.fails, "health_fails": self.health_fails,
                "last_check": self.last_check, "last_exit": self.last_exit, "last_incident": self.last_incident,
                "next_restart_in": round(self.next_restart_at - time.time(), 1) if self.next_restart_at else None,
                "backoff_s": self.backoff_s, "ports": l.ports if l is not None else None,
                "status": self.last_status, "policy": {k: self.policy[k] for k in ("max_restarts", "window_s",
                                                                                    "backoff_s", "backoff_max_s")}}


class Group:
    def __init__(self, name, owner, hooks=None, poll_s=5.0, meta=None):
        self.name, self.owner, self.hooks = name, owner, hooks
        self.poll_s = float(poll_s)
        self.meta = dict(meta or {})
        self.services = collections.OrderedDict()     # role -> Service (порядок старта)
        self.members = collections.OrderedDict()      # role -> lease (неуправляемые: клиенты, боты)
        self.created = time.time()
        self.poll_data = {}
        self.poll_t = None
        self.poll_error = None
        self.stop = False
        self.state = "up"
        self.timeline = collections.deque(maxlen=200)

    def note(self, event, role=None, detail=None):
        self.timeline.append({"t": round(time.time(), 3), "event": event, "role": role, "detail": detail})


class Supervisor:
    def __init__(self, lab):
        self.lab = lab
        self.db = StateDB(os.path.join(lab.data, "supervisor.sqlite"))
        self.groups = collections.OrderedDict()
        self.lock = threading.RLock()
        self.inc_root = os.path.join(lab.data, "incidents")

    # ---------------------------------------------------------------- служебное
    def _event(self, g, role, lease, event, detail=None):
        g.note(event, role, detail)
        try:
            self.db.event(g.name, role, lease, event, detail)
        except Exception:
            pass
        try:
            self.lab.journal.event("sup." + event, "%s/%s %s%s" % (g.name, role, lease or "",
                                                                    (": %s" % detail) if detail else "")[:400],
                                   instance=lease, agent=g.owner, args={"group": g.name, "role": role},
                                   error=event in ("death", "restart_failed", "gave_up", "health_kill"))
        except Exception:
            pass

    def _hook(self, g, name, *a):
        fn = getattr(g.hooks, name, None) if g.hooks is not None else None
        if fn is None:
            return None
        try:
            return fn(self, *a)
        except Exception as exc:
            self._event(g, a[0].role if a and isinstance(a[0], Service) else None, None, "hook_error",
                        "%s: %s: %s" % (name, type(exc).__name__, exc))
            return {"hook_error": "%s: %s" % (type(exc).__name__, exc), "trace": traceback.format_exc(limit=4)}

    def get(self, name):
        g = self.groups.get(name)
        if g is None:
            raise KeyError("no supervised group %r (have: %s)" % (name, ", ".join(self.groups) or "none"))
        return g

    def _check_owner(self, g, owner, force=False):
        if force or owner is None or owner == g.owner:
            return
        try:
            if self.lab.ctl.role(owner, None) == "admin":
                return
        except Exception:
            pass
        from vclab.daemon.service import LabError
        raise LabError("not-owner", "group %s belongs to %s" % (g.name, g.owner))

    # ---------------------------------------------------------------- группы
    def group(self, name, owner, hooks=None, poll_s=5.0, meta=None):
        with self.lock:
            g = self.groups.get(name)
            if g is not None and g.state != "down":
                self._check_owner(g, owner)
                if hooks is not None:
                    g.hooks = hooks
                return g
            g = Group(name, owner, hooks, poll_s, meta)
            self.groups[name] = g
        self._event(g, None, None, "group_up", {"owner": owner, "meta": meta})
        threading.Thread(target=self._poll_loop, args=(g,), name="sup-poll-" + name, daemon=True).start()
        return g

    def add(self, name, role, lease, health=None, policy=None, start=True, owner=None):
        """Управляемая служба (порядок вызовов = порядок старта). start: аренда не запущена -> запустить сейчас."""
        g = self.get(name)
        self._check_owner(g, owner)
        svc = Service(g, role, lease, health, policy)
        l = self.lab.leases.get(lease)
        if l is None:
            raise KeyError("no lease %s" % lease)
        running = l.proc is not None and l.proc.alive()
        if start and not running:
            t0 = time.time()
            self.lab.start(lease, owner=g.owner)
            self._event(g, role, lease, "start", {"s": round(time.time() - t0, 2)})
        elif not running:
            raise RuntimeError("%s is not running (start=false)" % lease)
        svc.state, svc.started_at = "up", time.time()
        g.services[role] = svc
        self._hook(g, "started", svc, False)
        svc.thread = threading.Thread(target=self._run, args=(svc,), name="sup-%s" % lease, daemon=True)
        svc.thread.start()
        return svc

    def member(self, name, role, lease, owner=None):
        g = self.get(name)
        self._check_owner(g, owner)
        g.members[role] = lease
        return g

    def down(self, name, owner=None, release=True, force=False):
        """Снять наблюдение; release — освободить аренды: участники (клиенты) -> службы в обратном порядке старта."""
        g = self.get(name)
        self._check_owner(g, owner, force)
        g.stop = True
        for s in g.services.values():
            s.stop = True
        for s in g.services.values():
            if s.thread is not None and s.thread is not threading.current_thread():
                s.thread.join(15)
        out = collections.OrderedDict()
        if release:
            order = list(reversed(list(g.members.items()))) + [(r, s.lease) for r, s in
                                                                reversed(list(g.services.items()))]
            for role, lease in order:
                if lease not in self.lab.leases:
                    continue
                try:
                    r = self.lab.release(lease, owner=g.owner, reason="supervisor-down")
                    out[lease] = {"role": role, "ok": True, "exit": r.get("exit"), "forced_kill": r.get("forced_kill")}
                except Exception as exc:
                    out[lease] = {"role": role, "ok": False, "error": str(exc)}
        for s in g.services.values():
            s.state = "stopped"
        g.state = "down"
        self._event(g, None, None, "group_down", {"release": release, "released": list(out)})
        return {"group": name, "released": out}

    def kill(self, name, role, owner=None, how="proc"):
        """Сбой «понарошку» (тест/оператор): убить процесс службы — supervisor увидит смерть и перезапустит.
        how=proc — TerminateProcess главного процесса (как падение), tree — TerminateJobObject всего дерева."""
        import psutil
        g = self.get(name)
        self._check_owner(g, owner)
        svc = g.services[role]
        l = self.lab.leases[svc.lease]
        pid = l.proc.pid if l.proc else None
        t = time.time()
        if how == "tree" and l.job is not None:
            l.job.terminate()
        elif pid:
            psutil.Process(pid).kill()
        self._event(g, role, svc.lease, "kill", {"how": how, "pid": pid, "by": owner})
        return {"group": name, "role": role, "lease": svc.lease, "pid": pid, "how": how, "t": t}

    def restart(self, name, role, owner=None):
        """Плановый перезапуск оператором (мягкий стоп, старт; не инцидент)."""
        g = self.get(name)
        self._check_owner(g, owner)
        svc = g.services[role]
        svc.state = "restarting"
        try:
            t0 = time.time()
            r = self.lab.start(svc.lease, owner=g.owner, restart=True)
            svc.state, svc.started_at, svc.health_fails = "up", time.time(), 0
            self._event(g, role, svc.lease, "restart_operator", {"s": round(time.time() - t0, 2)})
            self._hook(g, "started", svc, True)
            return {"ok": True, "lease": svc.lease, "pid": r.get("pid"), "s": round(time.time() - t0, 2)}
        except Exception as exc:
            svc.state = "down"
            self._event(g, role, svc.lease, "restart_failed", str(exc))
            raise

    def shutdown(self):
        for g in list(self.groups.values()):
            g.stop = True
            for s in g.services.values():
                s.stop = True
        try:
            self.db.close()
        except Exception:
            pass

    # ---------------------------------------------------------------- цикл службы
    def _sleep(self, svc, seconds):
        end = time.time() + seconds
        while time.time() < end and not svc.stop:
            time.sleep(min(0.1, max(0.0, end - time.time())))

    def _run(self, svc):
        g = svc.group
        next_health = time.time() + svc.policy["health_every_s"]
        while not svc.stop and not g.stop:
            l = self.lab.leases.get(svc.lease)
            if l is None:
                svc.state = "gone"
                self._event(g, svc.role, svc.lease, "gone", "lease released outside the supervisor")
                return
            try:
                if svc.state == "up":
                    p = l.proc
                    if p is None or (not p.alive() and not l.stopping):
                        self._death(svc, l, "exit", None)
                        next_health = time.time() + svc.policy["health_every_s"]
                        continue
                    if l.stopping and not p.alive():
                        svc.state = "stopped"
                        self._event(g, svc.role, svc.lease, "stopped", "lease stopped outside the supervisor")
                        continue
                    if svc.fails and svc.started_at and time.time() - svc.started_at > svc.policy["stable_s"]:
                        svc.fails = 0
                    if svc.health and time.time() >= next_health:
                        next_health = time.time() + svc.policy["health_every_s"]
                        if time.time() - (svc.started_at or 0) >= svc.policy["health_grace_s"]:
                            if not self._health(svc, l) and svc.health_fails >= int(svc.policy["health_fails"]):
                                self._health_kill(svc, l)
                                continue
                elif svc.state == "stopped":
                    if l.proc is not None and l.proc.alive() and l.state == "ready":
                        svc.state, svc.started_at = "up", time.time()
                        self._event(g, svc.role, svc.lease, "resumed")
                if time.time() - svc.renewed > svc.policy["renew_every_s"]:
                    svc.renewed = time.time()
                    try:
                        self.lab.renew(svc.lease, owner=g.owner, ttl=svc.policy["ttl"])
                    except Exception:
                        pass
            except Exception as exc:
                self._event(g, svc.role, svc.lease, "supervisor_error", "%s: %s" % (type(exc).__name__, exc))
                time.sleep(1.0)
            time.sleep(0.2)

    def _health(self, svc, l):
        g = svc.group
        ok_all, res = True, []
        for chk in svc.health:
            t0 = time.time()
            ok, info = False, None
            try:
                if "stdin" in chk:
                    r = self.lab.stdin(svc.lease, chk["stdin"], owner=g.owner, wait=float(chk.get("timeout", 3)),
                                       pattern=chk.get("pattern"), journal=False)
                    ok = bool(r.get("matched")) if chk.get("pattern") else True
                    import re
                    rx = re.compile(chk["pattern"]) if chk.get("pattern") else None
                    hit = [x for x in r.get("lines") or [] if rx is None or rx.search(x)]
                    info = hit[-1][-300:] if hit else None
                    if ok and info:
                        svc.last_status = kv(info)
                elif "f2f" in chk:
                    rep = self.lab.f2f_quiet(svc.lease, chk["f2f"], chk.get("args") or {},
                                             timeout=float(chk.get("timeout", 3)), owner=g.owner)
                    ok = bool(rep.get("ok"))
                    if ok:
                        svc.last_info[chk["f2f"]] = rep.get("result")
                    info = None if ok else rep.get("error")
                elif "port" in chk:
                    port = l.ports.get(chk["port"])
                    ok = port in listening_ports(l)
                    info = "%s %s" % (chk["port"], port)
            except Exception as exc:
                ok, info = False, "%s: %s" % (type(exc).__name__, exc)
            res.append({"check": next(k for k in ("stdin", "f2f", "port") if k in chk), "ok": ok,
                        "ms": round((time.time() - t0) * 1000, 1), "info": info if not ok or "port" in chk else None})
            ok_all = ok_all and ok
        svc.last_check = {"t": round(time.time(), 2), "ok": ok_all, "checks": res}
        svc.checks.append(svc.last_check)
        svc.health_fails = 0 if ok_all else svc.health_fails + 1
        if not ok_all:
            self._event(g, svc.role, svc.lease, "health_fail", {"n": svc.health_fails, "checks": res})
        return ok_all

    def _health_kill(self, svc, l):
        g = svc.group
        self._event(g, svc.role, svc.lease, "health_kill", "%d failed checks in a row" % svc.health_fails)
        l.stopping = True                     # не «смерть» для обработчика выхода лаборатории — её ведём мы
        try:
            if l.job is not None:
                l.job.terminate()
            if l.proc:
                l.proc.wait(5)
        finally:
            l.stopping = False
        self._death(svc, l, "health", svc.last_check)

    def _death(self, svc, l, why, detail):
        g = svc.group
        info = l.proc.info() if l.proc else {}
        t_detect = time.time()
        svc.state = "down"
        svc.last_exit = info.get("exit")
        self._event(g, svc.role, svc.lease, "death", {"why": why, "exit": info.get("exit"), "pid": info.get("pid")})
        inc = self._incident(svc, l, why, detail, info, t_detect)
        self._hook(g, "died", svc, inc)
        while not svc.stop and not g.stop:
            svc.fails += 1
            now = time.time()
            svc.restart_times.append(now)
            recent = [t for t in svc.restart_times if now - t <= svc.policy["window_s"]]
            if len(recent) > int(svc.policy["max_restarts"]):
                svc.state, svc.next_restart_at = "failed", None
                msg = "%d restarts in %.0f s > cap %d: giving up" % (len(recent), svc.policy["window_s"],
                                                                    svc.policy["max_restarts"])
                self._event(g, svc.role, svc.lease, "gave_up", msg)
                self._finish_incident(inc, {"ok": False, "gave_up": True, "message": msg, "fails": svc.fails})
                return
            svc.backoff_s = backoff_for(svc.fails, svc.policy)
            svc.state, svc.next_restart_at = "restarting", now + svc.backoff_s
            self._event(g, svc.role, svc.lease, "backoff", {"s": svc.backoff_s, "fail": svc.fails})
            self._sleep(svc, svc.backoff_s)
            if svc.stop or g.stop:
                return
            svc.next_restart_at = None
            t0 = time.time()
            try:
                r = self.lab.start(svc.lease, owner=g.owner, restart=True)
            except Exception as exc:
                self._event(g, svc.role, svc.lease, "restart_failed", "%s: %s" % (type(exc).__name__, exc))
                inc.setdefault("restart_attempts", []).append({"t": round(t0, 3), "ok": False, "error": str(exc)[:500],
                                                               "backoff_s": svc.backoff_s})
                continue
            svc.state, svc.started_at, svc.health_fails = "up", time.time(), 0
            svc.restarts += 1
            rr = {"ok": True, "t_death": info.get("ended"), "t_detect": round(t_detect, 3),
                  "t_restart": round(t0, 3), "t_ready": round(svc.started_at, 3), "backoff_s": svc.backoff_s,
                  "start_s": round(svc.started_at - t0, 2), "down_s": round(svc.started_at - (info.get("ended")
                                                                                          or t_detect), 2),
                  "attempt": svc.fails, "pid": r.get("pid"), "restarts": svc.restarts}
            self._event(g, svc.role, svc.lease, "restart_ok", rr)
            self._finish_incident(inc, rr)
            self._hook(g, "started", svc, True)
            return

    # ---------------------------------------------------------------- инциденты
    def _incident(self, svc, l, why, detail, info, t_detect):
        g = svc.group
        ts = time.strftime("%Y%m%d_%H%M%S", time.localtime(t_detect)) + "_%03d" % int((t_detect % 1) * 1000)
        iid = "%s_%s_%s" % (ts, g.name, svc.role)
        d = os.path.join(self.inc_root, iid)
        os.makedirs(d, exist_ok=True)
        logs = {}
        try:
            for stream, lines in self.lab._tails(l, 200).items():
                fn = "%s.tail.log" % stream
                with open(os.path.join(d, fn), "w", encoding="utf-8") as f:
                    f.write("\n".join(lines) + "\n")
                logs[stream] = {"file": fn, "lines": len(lines), "last": lines[-3:]}
        except Exception as exc:
            logs["error"] = str(exc)
        cap = self._hook(g, "capture", svc, d) or {}
        rec = {"id": iid, "ts": t_detect, "at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t_detect)),
               "group": g.name, "role": svc.role, "lease": svc.lease, "owner": g.owner, "why": why,
               "detail": detail, "exit": info.get("exit"), "exit_code": info.get("exit_code"), "pid": info.get("pid"),
               "t_death": info.get("ended"), "t_detect": round(t_detect, 3),
               "uptime_s": round((info.get("ended") or t_detect) - (svc.started_at or t_detect), 1),
               "restarts_before": svc.restarts, "health_last": list(svc.checks)[-5:], "last_status": svc.last_status,
               "last_info": svc.last_info, "logs": logs, "capture": cap, "dir": d,
               "group_poll": {k: v for k, v in (g.poll_data or {}).items() if k not in ("journal",)},
               "timeline": list(g.timeline)[-30:], "restart": None}
        rec["summary"] = "%s %s: %s (%s)%s" % (svc.role, svc.lease, why, info.get("exit"),
                                               ("; " + cap["summary"]) if isinstance(cap, dict) and cap.get("summary")
                                               else "")
        svc.last_incident = iid
        self._write_incident(rec)
        self._event(g, svc.role, svc.lease, "incident", {"id": iid, "dir": d})
        return rec

    def _finish_incident(self, rec, restart):
        rec["restart"] = restart
        self._write_incident(rec)

    def _write_incident(self, rec):
        d = rec["dir"]
        with open(os.path.join(d, "incident.json"), "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False, indent=1, default=str)
        md = ["# Incident %s" % rec["id"], "",
              "- group `%s`, role **%s**, lease `%s`, owner %s" % (rec["group"], rec["role"], rec["lease"], rec["owner"]),
              "- why: **%s**, exit `%s`, pid %s, uptime %s s, restarts before %s" % (
                  rec["why"], rec["exit"], rec["pid"], rec["uptime_s"], rec["restarts_before"]),
              "- detected %s" % rec["at"]]
        rs = rec.get("restart")
        if rs:
            md.append("- restart: %s" % ("ok in %s s after death (backoff %s s, start %s s, attempt %s)" % (
                rs.get("down_s"), rs.get("backoff_s"), rs.get("start_s"), rs.get("attempt")) if rs.get("ok")
                else "FAILED: %s" % rs.get("message")))
        cap = rec.get("capture") or {}
        if cap.get("summary"):
            md.append("- capture: %s" % cap["summary"])
        for k, v in (cap.get("files") or {}).items():
            md.append("- `%s` — %s" % (k, v))
        for stream, lg in (rec.get("logs") or {}).items():
            if isinstance(lg, dict):
                md.append("- log `%s` (%s lines), last: %s" % (lg["file"], lg["lines"], " | ".join(lg["last"])[-300:]))
        with open(os.path.join(d, "incident.md"), "w", encoding="utf-8") as f:
            f.write("\n".join(md) + "\n")
        try:
            self.db.add_incident(rec)
        except Exception:
            pass

    def incident(self, iid):
        p = os.path.join(self.inc_root, iid, "incident.json")
        with open(p, encoding="utf-8") as f:
            return json.load(f)

    # ---------------------------------------------------------------- опрос групп (панель, учёт)
    def _poll_loop(self, g):
        while not g.stop:
            t0 = time.time()
            if g.hooks is not None and getattr(g.hooks, "poll", None):
                r = self._hook(g, "poll", g)
                if isinstance(r, dict) and "hook_error" in r:
                    g.poll_error = r["hook_error"]
                elif r is not None:
                    g.poll_data, g.poll_t, g.poll_error = r, time.time(), None
            for role, lease in list(g.members.items()):
                l = self.lab.leases.get(lease)
                if l is not None and time.time() - (l.expires - l.ttl) > 60:
                    try:
                        self.lab.renew(lease, owner=g.owner, ttl=DEFAULT_POLICY["ttl"])
                    except Exception:
                        pass
            end = t0 + g.poll_s
            while time.time() < end and not g.stop:
                time.sleep(0.1)

    def state(self, prefix=None, group=None, include_down=False):
        groups = {}
        for name, g in list(self.groups.items()):
            if group and name != group or prefix and not name.startswith(prefix):
                continue
            if g.state == "down" and not include_down and name != group:
                continue            # снятые группы (их аренды могли переиспользовать имена) — только по имени
            mem = {}
            for role, lease in g.members.items():
                l = self.lab.leases.get(lease)
                mem[role] = {"lease": lease, "state": l.state if l is not None else "gone",
                             "kind": l.kind if l is not None else None,
                             "pid": l.proc.pid if l is not None and l.proc else None}
            groups[name] = {"owner": g.owner, "state": g.state, "created": g.created, "meta": g.meta,
                            "uptime_s": round(time.time() - g.created, 1),
                            "services": [s.info(self.lab) for s in g.services.values()], "members": mem,
                            "poll": g.poll_data, "poll_age_s": round(time.time() - g.poll_t, 1) if g.poll_t else None,
                            "poll_error": g.poll_error, "timeline": list(g.timeline)[-25:]}
        incs = [i for i in self.db.incidents(30) if not (prefix or group) or (i["grp"] or "").startswith(group or prefix)]
        return {"ok": True, "t": time.time(), "daemon_port": self.lab.cfg["daemon"]["port"], "groups": groups,
                "incidents": incs[:20], "accounts": self.db.accounts(), "bans": self.db.active_bans()["rows"],
                "counters": self.db.counters(), "tariffs": self.db.tariffs(), "logins": self.db.logins(10),
                "events": self.db.events(30), "schema": self.db.version}

    # ---------------------------------------------------------------- панель
    def write_panel(self, name="supervisor", title="Supervisor", prefix=""):
        d = os.path.join(self.lab.data, "dashboard")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "%s.html" % name)
        url = "http://127.0.0.1:%d/sup/state%s" % (self.lab.cfg["daemon"]["port"], "?prefix=" + prefix if prefix else "")
        with open(p, "w", encoding="utf-8") as f:
            f.write(panel_html(title, url, self.lab))
        return p


def listening_ports(l):
    import psutil
    ports = set()
    pids = []
    try:
        pids = l.job.pids() if l.job is not None else ([l.proc.pid] if l.proc else [])
    except Exception:
        pass
    for pid in pids:
        try:
            for c in psutil.Process(pid).net_connections(kind="tcp"):
                if c.status == psutil.CONN_LISTEN and c.laddr:
                    ports.add(c.laddr.port)
        except psutil.Error:
            pass
    return ports


# ------------------------------------------------------------------------------------------------- паки
SKIP_DIRS = {"__pycache__", ".git", ".svn"}


def pack_manifest(root, packs, out=None):
    """packs: {имя пака: сторона client|server|both} в каталоге root (content). -> манифест (и файл out).
    version — sha256 по отсортированным «пак/путь:sha»: меняется при любом изменении состава/содержимого."""
    m = {"generated": time.strftime("%Y-%m-%d %H:%M:%S"), "root": root, "packs": {}}
    lines = []
    for pk in sorted(packs):
        side = packs[pk]
        base = os.path.join(root, pk)
        if not os.path.isdir(base):
            raise FileNotFoundError("no pack dir %s" % base)
        files = []
        for dp, dns, fns in os.walk(base):
            dns[:] = sorted(x for x in dns if x not in SKIP_DIRS)
            for fn in sorted(fns):
                fp = os.path.join(dp, fn)
                with open(fp, "rb") as f:
                    data = f.read()
                rel = os.path.relpath(fp, base).replace(os.sep, "/")
                sha = hashlib.sha256(data).hexdigest()
                files.append({"path": rel, "sha256": sha, "size": len(data), "side": side})
                lines.append("%s/%s:%s" % (pk, rel, sha))
        m["packs"][pk] = {"side": side, "files": files, "bytes": sum(x["size"] for x in files)}
    m["version"] = hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()
    m["files"] = len(lines)
    if out:
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(m, f, ensure_ascii=False, indent=1)
        os.replace(tmp, out)
    return m


# ------------------------------------------------------------------------------------------------- подключение
def install(lab, core, Feature, version):
    """lab.sup + core.sup (действия для CLI/MCP). Маршруты HTTP — api.py (/sup/*)."""
    lab.sup = Supervisor(lab)
    sup = lab.sup
    try:
        sup.write_panel()
    except Exception:
        pass
    orig_shutdown = lab.shutdown

    def shutdown():
        orig_shutdown()
        sup.shutdown()
    lab.shutdown = shutdown

    def f_sup(ctx, a):
        act = a.get("action", "state")
        db = sup.db
        if act == "state":
            return sup.state(a.get("prefix"), a.get("group"))
        if act == "incidents":
            return {"incidents": db.incidents(int(a.get("last", 20)), a.get("group"))}
        if act == "incident":
            return sup.incident(a["id"])
        if act == "events":
            return {"events": db.events(int(a.get("last", 50)), a.get("group"))}
        if act == "accounts":
            return {"accounts": db.accounts(), "logins": db.logins(int(a.get("last", 20)))}
        if act == "account_add":
            r = db.add_account(a["name"], a.get("token"), a.get("role", "player"), a.get("note"))
            db.event(None, None, None, "account_add", {"name": a["name"], "by": ctx.owner})
            return r
        if act == "ban":
            r = db.ban(a.get("kind", "account"), a["value"], a.get("minutes", 0), a.get("reason", ""), ctx.owner)
            db.event(None, None, None, "ban", r)
            return r
        if act == "unban":
            r = db.unban(a.get("kind", "account"), a["value"], ctx.owner)
            db.event(None, None, None, "unban", {"value": a["value"], "by": ctx.owner, **r})
            return r
        if act == "bans":
            return db.active_bans()
        if act == "tariffs":
            return {"tariffs": db.tariffs()}
        if act == "tariff_set":
            r = db.set_tariff(a["key"], a["value"], ctx.owner)
            db.event(None, None, None, "tariff_set", dict(r, by=ctx.owner))
            return r
        if act == "counters":
            return {"counters": db.counters()}
        if act == "kill":
            return sup.kill(a["group"], a["role"], ctx.owner, a.get("how", "proc"))
        if act == "restart":
            return sup.restart(a["group"], a["role"], ctx.owner)
        if act == "down":
            return sup.down(a["group"], ctx.owner, release=a.get("release", True))
        if act == "manifest":
            return pack_manifest(a["root"], a["packs"], a.get("out"))
        if act == "panel":
            return {"file": sup.write_panel(a.get("name", "supervisor"), a.get("title", "Supervisor"),
                                            a.get("prefix", "")),
                    "url": "http://127.0.0.1:%d/sup/panel" % lab.cfg["daemon"]["port"]}
        raise KeyError("action: state|incidents|incident|events|accounts|account_add|ban|unban|bans|tariffs|"
                       "tariff_set|counters|kill|restart|down|manifest|panel")
    core["core.sup"] = Feature("core.sup", f_sup, "supervisor (stage 6): {action=state|incidents|incident|events|"
                               "accounts|account_add|ban|unban|bans|tariffs|tariff_set|counters|kill|restart|down|"
                               "manifest|panel, ...}", {"type": "object", "properties": {"action": {"type": "string"}}},
                               project="core", version="core@" + version)
    return sup


# ------------------------------------------------------------------------------------------------- HTML панели
# TODO(волна 6): секции панели проекта-сервера (кнопки оператора, вайтлист, антифрод) лежат в sup_panel.js его
# каталога в projects/; появятся в /sup/panel, когда проект (project.toml) переедет в репозиторий.
def panel_extras(lab=None):
    """(cli, js): sup_panel.js загруженных проектов (точка расширения панели) и префикс подсказок CLI —
    `lab <проект>` для единственного такого проекта, иначе `lab <project>`."""
    names, js = [], []
    projs = getattr(getattr(lab, "projects", None), "projects", None) or {}
    for name in sorted(projs):
        p = os.path.join(getattr(projs[name], "dir", "") or "", "sup_panel.js")
        if os.path.isfile(p):
            try:
                with open(p, encoding="utf-8") as f:
                    js.append("// ---- %s/sup_panel.js\n%s" % (name, f.read()))
                names.append(name)
            except OSError:
                pass
    cli = "lab %s" % names[0] if len(names) == 1 else "lab &lt;project&gt;"
    return cli, "\n".join(js)


def panel_html(title, url, lab=None):
    cli, js = panel_extras(lab)
    return (PANEL.replace("__TITLE__", title).replace("__URL__", url).replace("__CLI__", cli)
            .replace("__EXTRA_JS__", js))


PANEL = r"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__ — live</title>
<style>
:root{--bg:#fff;--fg:#1d2026;--mut:#69707d;--line:#e2e5ea;--ok:#1f8a4c;--bad:#c0392b;--warn:#b7791f;--card:#f6f7f9}
@media (prefers-color-scheme:dark){:root{--bg:#15171b;--fg:#e6e8eb;--mut:#9aa1ac;--line:#2b2f36;--card:#1d2026}}
body{background:var(--bg);color:var(--fg);font:13px/1.45 system-ui,Segoe UI,sans-serif;margin:0;padding:16px}
h1{font-size:18px;margin:0 0 4px}h2{font-size:15px;margin:18px 0 6px}h3{font-size:13px;margin:12px 0 4px;color:var(--mut)}
table{border-collapse:collapse;width:100%;margin:4px 0 8px}td,th{border-bottom:1px solid var(--line);padding:3px 6px;
text-align:left;vertical-align:top;font-variant-numeric:tabular-nums}th{color:var(--mut);font-weight:600}
.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}.mut{color:var(--mut)}
.card{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:8px 12px;margin:10px 0}
code{font:12px ui-monospace,Consolas,monospace}.wrap{overflow-x:auto}
</style></head><body>
<h1>__TITLE__ <span class="mut" id="ts"></span></h1>
<div class="mut">live from <code>__URL__</code> every 2 s · CLI: <code>__CLI__ status|players|kick &lt;eid&gt;|ban &lt;acct&gt; &lt;min&gt; &lt;reason&gt;|unban &lt;acct&gt;|restart &lt;role&gt;|tariff set &lt;k&gt; &lt;v&gt;|incidents|down</code></div>
<div id="err" class="bad"></div><div id="opmsg" class="mut"></div><div id="root"></div><div id="ext"></div>
<script>
const URL_ = "__URL__";
const esc = s => String(s ?? "").replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
const fmt = v => typeof v === "number" ? (Math.abs(v) >= 1000 ? Math.round(v).toLocaleString() : (+v.toFixed(2)).toString()) : esc(v);
const tm = t => t ? new Date(t*1000).toLocaleTimeString() : "";
function table(rows, cols){ if(!rows || !rows.length) return '<div class="mut">none</div>';
  return '<div class="wrap"><table><tr>'+cols.map(c=>'<th>'+esc(c[0])+'</th>').join('')+'</tr>'+
  rows.map(r=>'<tr>'+cols.map(c=>'<td>'+(c[1](r) ?? '')+'</td>').join('')+'</tr>').join('')+'</table></div>'; }
const stCls = s => s==="up"?"ok":(s==="restarting"||s==="down"?"warn":(s==="failed"||s==="gone"?"bad":"mut"));
function render(d){
  document.getElementById("ts").textContent = new Date(d.t*1000).toLocaleTimeString();
  let h = "";
  for (const [name, g] of Object.entries(d.groups)) {
    const p = g.poll || {};
    h += '<div class="card"><h2>'+esc(name)+' <span class="mut">owner '+esc(g.owner)+' · '+esc(g.state)+' · up '+fmt(g.uptime_s)+' s'+(g.poll_error?' · <span class="bad">poll: '+esc(g.poll_error)+'</span>':'')+'</span></h2>';
    h += '<h3>Services</h3>'+table(g.services, [["role",s=>'<b>'+esc(s.role)+'</b>'],["lease",s=>'<code>'+esc(s.lease)+'</code>'],
      ["state",s=>'<span class="'+stCls(s.state)+'">'+esc(s.state)+'</span>'+(s.next_restart_in!=null?' in '+fmt(s.next_restart_in)+' s':'')],
      ["health",s=>s.last_check?('<span class="'+(s.last_check.ok?'ok':'bad')+'">'+(s.last_check.ok?'ok':'fail ×'+s.health_fails)+'</span> '+s.last_check.checks.map(c=>c.check+' '+c.ms+'ms').join(', ')):'<span class="mut">—</span>'],
      ["restarts",s=>fmt(s.restarts)],["uptime s",s=>fmt(s.uptime_s)],["pid",s=>fmt(s.pid)],["last exit",s=>esc(s.last_exit)],
      ["last incident",s=>esc(s.last_incident)],["CLI",s=>'<code>__CLI__ restart '+esc(s.role)+'</code>']]);
    const mem = Object.entries(g.members||{}).map(([r,m])=>Object.assign({role:r},m));
    if (mem.length) h += '<h3>Clients (not managed)</h3>'+table(mem, [["role",m=>esc(m.role)],["lease",m=>'<code>'+esc(m.lease)+'</code>'],["kind",m=>esc(m.kind)],["state",m=>esc(m.state)]]);
    const w = p.world || {};
    h += '<h3>World</h3><div>tick '+fmt(w.tick)+' · entities <b>'+fmt(w.entities)+'</b> · scripted <b>'+fmt(w.scripted)+'</b> · sessions '+fmt(w.sessions)+
         ' · tick ms avg '+fmt((w.tick_ms||{}).avg)+' p95 '+fmt((w.tick_ms||{}).p95)+' · journal total '+fmt(w.journal_total)+' · state age '+fmt(w.state_age_s)+' s</div>';
    if (p.sandbox) h += '<div>sandbox (world side): '+esc(p.sandbox.state)+' results '+fmt(p.sandbox.results)+' applied '+fmt(p.sandbox.applied)+' rejected '+fmt(p.sandbox.rejected)+' fuel '+fmt(p.sandbox.fuel)+(p.sandbox.last_result?' · last TickResult tick '+fmt(p.sandbox.last_result.tick)+' ('+fmt(p.sandbox.last_result.entities)+' ent, '+fmt(p.sandbox.last_result.actions)+' act)':'')+'</div>';
    h += '<h3>Players online</h3>'+table(p.players, [["eid",x=>fmt(x.eid)],["name",x=>esc(x.name)],["account",x=>esc(x.account)],["session",x=>fmt(x.session)],
      ["pos",x=>(x.pos||[]).map(v=>(+v).toFixed(1)).join(', ')],["chunks",x=>fmt(x.chunks)],["inputs",x=>fmt(x.inputs)],["actions",x=>fmt(x.actions)],["CLI",x=>'<code>__CLI__ kick '+esc(x.eid)+'</code> · <code>__CLI__ ban '+esc(x.account)+' 10 reason</code>']]);
    if (p.ops && typeof opsHtml === "function") h += opsHtml(name, p.ops);   // кнопки оператора — sup_panel.js проекта
    if (p.gateway) h += '<div>gateway: auth '+esc(p.gateway.auth)+' · connections '+fmt(p.gateway.connections)+' · auth ok '+fmt(p.gateway.auth_ok)+' · bytes down '+fmt((p.gateway.total||{}).down)+' up '+fmt((p.gateway.total||{}).up)+' · rejects '+esc(JSON.stringify(p.gateway.rejects||{}))+' · packs v'+fmt((p.gateway.packs||{}).version)+' ('+fmt((p.gateway.packs||{}).files)+' files, served '+fmt((p.gateway.packs||{}).served)+')</div>';
    h += '<h3>Last journal frames (world input ring)</h3>'+table((p.journal||[]).slice(-15).reverse(), [["tick",f=>fmt(f.tick)],["gw",f=>fmt(f.gw)],["session",f=>fmt(f.session)],["type",f=>esc(f.type_name||f.type)],["client type",f=>esc(f.ctype_name||'')],["size",f=>fmt(f.size)],["err",f=>'<span class="bad">'+esc(f.err||'')+'</span>']]);
    h += '<h3>Timeline</h3>'+table((g.timeline||[]).slice(-12).reverse(), [["time",e=>tm(e.t)],["event",e=>esc(e.event)],["role",e=>esc(e.role)],["detail",e=>'<code>'+esc(typeof e.detail==="string"?e.detail:JSON.stringify(e.detail)).slice(0,220)+'</code>']]);
    h += '</div>';
  }
  if (!Object.keys(d.groups).length) h += '<div class="card mut">no supervised groups — <code>__CLI__ up</code></div>';
  const cnt = Object.entries(d.counters||{}).map(([a,m])=>Object.assign({account:a},m));
  h += '<h2>Accounts: counters and credits</h2>'+table(cnt, [["account",x=>esc(x.account)],["bytes down",x=>fmt(x.bytes_down)],["bytes up",x=>fmt(x.bytes_up)],["packets",x=>fmt((x.packets_up||0)+(x.packets_down||0))],["actions",x=>fmt(x.actions)],["fuel",x=>fmt(x.fuel)],["entities",x=>fmt(x.entities)],["storage",x=>fmt(x.storage)],["credits",x=>'<b>'+fmt(x.credits)+'</b>']]);
  h += '<h3>Tariffs</h3>'+table(Object.entries(d.tariffs||{}).map(([k,v])=>({k,v})), [["key",x=>'<code>'+esc(x.k)+'</code>'],["value",x=>fmt(x.v)],["CLI",x=>'<code>__CLI__ tariff set '+esc(x.k)+' &lt;v&gt;</code>']]);
  h += '<h3>Active bans</h3>'+table(d.bans, [["kind",b=>esc(b.kind)],["value",b=>esc(b.value)],["until",b=>b.until?new Date(b.until*1000).toLocaleString():'permanent'],["reason",b=>esc(b.reason)],["by",b=>esc(b.by)],["CLI",b=>'<code>__CLI__ unban '+esc(b.value)+'</code>']]);
  h += '<h3>Recent logins</h3>'+table(d.logins, [["time",x=>tm(x.ts)],["account",x=>esc(x.account)],["ip",x=>esc(x.ip)],["gateway",x=>esc(x.gateway)],["ok",x=>x.ok?'<span class="ok">ok</span>':'<span class="bad">'+esc(x.reason)+'</span>']]);
  h += '<h2>Incidents</h2>'+table(d.incidents, [["time",i=>tm(i.ts)],["group",i=>esc(i.grp)],["service",i=>'<b>'+esc(i.service)+'</b>'],["why",i=>esc(i.why)],["exit",i=>esc(i.exit)],
    ["restart",i=>i.restart?(i.restart.ok?'<span class="ok">ok, down '+fmt(i.restart.down_s)+' s</span>':'<span class="bad">'+esc(i.restart.message||'failed')+'</span>'):'<span class="warn">pending</span>'],["summary",i=>esc(i.summary)],["dir",i=>'<code>'+esc(i.dir)+'</code>']]);
  document.getElementById("root").innerHTML = h;
}
const BASE = URL_.startsWith("http") ? URL_.replace(/\/sup\/state.*$/, "") : "";
const q = s => "'" + String(s).replace(/[\\']/g, c => "\\" + c) + "'";
const EXT_TICKS = [];          // секции проектов (sup_panel.js) добавляют сюда свои обновления
__EXTRA_JS__
async function tick(){ try { const r = await fetch(URL_, {cache:"no-store"}); render(await r.json()); document.getElementById("err").textContent="";
  for (const f of EXT_TICKS) f(); }
  catch(e){ document.getElementById("err").textContent = "daemon not reachable: "+e; } }
tick(); setInterval(tick, 2000);
</script></body></html>
"""
