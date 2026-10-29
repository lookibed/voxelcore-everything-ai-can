"""MCP-мост `lab` (stdio JSON-RPC, без пакета mcp): Claude Code в WSL запускает его Windows-питоном
(<python_win из machine.toml> -X utf8 -u <repo>\\bin\\mcp_bridge.py), мост ходит в демон labd по HTTP 127.0.0.1:25700 и
поднимает демон, если тот не отвечает. Состояние (аренды, процессы, F2F) живёт в демоне: перезапуск сессии Claude
или /mcp убивает только мост.

Постоянный набор: lab_ps, lab_lease, lab_release, lab_start, lab_stop, lab_f2f, lab_logs, lab_stdin, lab_runs, lab_call,
lab_history, lab_gate, lab_play (этап 2б), lab_run, lab_compare, lab_golden (этап 2а: сценарии, сравнение, golden).
Возможности плагинов с mcp=true дополнительно видны как lab_<проект>_<имя>; при перезагрузке плагинов мост шлёт
notifications/tools/list_changed (capabilities.tools.listChanged = true).

Этап 5 (роли): мост главной сессии запущен с LAB_OWNER=claude (.mcp.json) — это роль admin. Субагенты Claude Code
сейчас ходят через ТОТ ЖЕ процесс моста, мост их не различает: вызов без owner — от имени claude. Поэтому:
(1) операций уровня демона (stop/restart/upgrade/drain/reload-core) в мосте нет — только `lab_daemon` для чтения
(status, audit, whoami); (2) у каждого инструмента параметр `as_agent=true` (или LAB_ROLE=agent у моста) — заголовок
X-Lab-Role: agent, демон понижает роль; главная сессия пишет в задании субагенту «owner=<имя>, as_agent=true»;
(3) владелец не из [roles].admins — всегда agent; (4) эвристика демона: немедленная операция уровня демона при
аренде другого владельца — отказ при любой роли. Подмену owner=claude субагентом мост предотвратить не может
(локальный HTTP без секретов) — это видно в аудите (lab audit)."""
import base64
import json
import os
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if REPO not in sys.path:
    sys.path.insert(0, REPO)
from vclab.daemon.client import LabClient  # noqa: E402

PROTOCOL = "2024-11-05"
OUT_LOCK = threading.Lock()
STATE = {"initialized": False, "dyn": {}, "gen": None}


def send(obj):
    data = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
    with OUT_LOCK:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


class _Client:
    """LabClient с постоянным соединением; демон не отвечает — поднять его (labctl) и повторить один раз."""

    def __init__(self, owner, role=None):
        self.c = LabClient(owner=owner, client="mcp", role=role)

    def _do(self, fn, *a, **kw):
        try:
            return fn(*a, **kw)
        except (ConnectionError, OSError):
            self.c.close()
            from vclab.cli import labctl as labctl
            if self.c.port != labctl.shared_port():
                raise RuntimeError("labd :%d is not running (the bridge starts only the shared daemon)" % self.c.port)
            r = labctl.start()
            if not r.get("ok"):
                raise RuntimeError("labd is not running and did not start: %s" % r)
            return fn(*a, **kw)

    def get(self, path, timeout=60.0):
        return self._do(self.c.get, path, timeout=timeout)

    def post(self, path, body=None, timeout=600.0):
        return self._do(self.c.post, path, body, timeout=timeout)


_CLIENTS = {}
_CLIENTS_LOCK = threading.Lock()


def client(owner=None, role=None):
    """Клиент на поток, владельца и роль (http.client не потокобезопасен; вызовы моста идут параллельно)."""
    owner = owner or os.environ.get("LAB_OWNER") or "claude-mcp"
    role = role or (os.environ.get("LAB_ROLE") or "").strip().lower() or None
    key = (owner, role, threading.get_ident())
    with _CLIENTS_LOCK:
        c = _CLIENTS.get(key)
        if c is None:
            c = _CLIENTS[key] = _Client(owner, role)
    return c


def _role(a):
    return "agent" if a.get("as_agent") else None


def text(obj, error=False):
    s = obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False, indent=1, default=str)
    r = {"content": [{"type": "text", "text": s}]}
    if error:
        r["isError"] = True
    return r


def result(r):
    return text(r, error=isinstance(r, dict) and r.get("ok") is False)


OWNER = {"owner": {"type": "string", "description": "владелец аренды (по умолчанию LAB_OWNER моста или claude-mcp)"},
         "as_agent": {"type": "boolean", "description": "субагент: роль agent (X-Lab-Role) даже при владельце главной "
                                                        "сессии; операции уровня демона — 403 admin-required"}}


def _default_project():
    """Проект без явного project: lab.toml [defaults] project (раньше в мосте было зашито имя проекта)."""
    from vclab import config
    p = config.default_project()
    if not p:
        raise ValueError("project is required (no [defaults] project in lab.toml)")
    return p


def t_daemon(a):
    """Только чтение: status (код против диска, drain, роль), audit, whoami. Действия — CLI `lab daemon ...` (admin)."""
    c = client(a.get("owner"), _role(a))
    act = a.get("action", "status")
    if act == "audit":
        from vclab.cli import labctl as labctl
        r = c.get("/daemon/audit?last=%d" % int(a.get("last", 30)))
        return text(labctl.audit_table(r)) if r.get("ok") else result(r)
    if act == "whoami":
        return result(c.get("/daemon/whoami"))
    r = c.get("/daemon/info")
    if r.get("error") == "http-404" or (r.get("detail") == "Not Found" and "ok" not in r):
        return text("labd runs old code without stage 5 (no /daemon/info): roles/drain/audit not enforced by the "
                    "daemon; upgrade: `lab daemon upgrade` by admin when it has no leases", error=False)
    return result(r)


def t_ps(a):
    r = client().get("/leases")
    from vclab.cli import lab as cli
    return text(cli.ps_table(r) + "\n\nports: " + json.dumps(r.get("ports_used")))


def t_lease(a):
    return result(client(a.get("owner"), _role(a)).post("/leases", {k: a.get(k) for k in (
        "project", "kind", "ttl", "name", "params", "start")}))


def t_release(a):
    if a.get("all"):
        return result(client(a.get("owner"), _role(a)).post("/stop-all"))
    return result(client(a.get("owner"), _role(a)).post("/leases/%s/release" % a["lease"], {"force": bool(a.get("force"))}))


def t_start(a):
    return result(client(a.get("owner"), _role(a)).post("/proc/%s/start" % a["lease"], {
        "restart": bool(a.get("restart")), "params": a.get("params")}))


def t_stop(a):
    return result(client(a.get("owner"), _role(a)).post("/proc/%s/stop" % a["lease"], {}))


def t_f2f(a):
    t0 = time.perf_counter()
    r = client(a.get("owner"), _role(a)).post("/f2f/%s" % a["lease"], {"cmd": a["cmd"], "args": a.get("args") or {},
                                                             "timeout": a.get("timeout", 60)})
    r["bridge_ms"] = round((time.perf_counter() - t0) * 1000, 2)
    out = result(r)
    path = ((r.get("result") or {}) if isinstance(r.get("result"), dict) else {}).get("path")
    if a["cmd"] == "shot" and r.get("ok") and path and a.get("image", True) and os.path.exists(path):
        with open(path, "rb") as f:
            out["content"].append({"type": "image", "data": base64.b64encode(f.read()).decode("ascii"),
                                   "mimeType": "image/png"})
    return out


def t_logs(a):
    import urllib.parse
    q = "?tail=%d" % int(a.get("tail", 80))
    if a.get("stream"):
        q += "&stream=" + urllib.parse.quote(a["stream"])
    if a.get("grep"):
        q += "&grep=" + urllib.parse.quote(a["grep"])
    r = client().get("/proc/%s/logs%s" % (a["lease"], q))
    if not r.get("ok"):
        return result(r)
    return text("# %s %s (%s)\n%s" % (r["lease"], r["stream"], r["path"], "\n".join(r["lines"])))


def t_stdin(a):
    return result(client(a.get("owner"), _role(a)).post("/proc/%s/stdin" % a["lease"], {
        "text": a["text"], "wait": a.get("wait", 2.0), "pattern": a.get("pattern"), "stream": a.get("stream")},
        timeout=float(a.get("wait", 2.0)) + 30))


def t_runs(a):
    if a.get("id"):
        return result(client().get("/runs/%s" % a["id"]))
    q = "?last=%d" % int(a.get("last", 20)) + ("&project=%s" % a["project"] if a.get("project") else "")
    return result(client().get("/runs" + q))


def t_call(a):
    return result(client(a.get("owner"), _role(a)).post("/call/%s" % (a.get("feature") or "list"), {"args": a.get("args") or {}}))


def t_history(a):
    if a.get("action") == "import":
        return result(client().post("/call/core.history_import", {"args": {"project": a.get("project")}}))
    r = client().post("/call/core.history", {"args": {"project": a.get("project"), "scenario": a.get("scenario"),
                                                      "last": a.get("last", 20), "kind": a.get("kind"),
                                                      "table": True, "counts": True}})
    if not r.get("ok"):
        return result(r)
    res = r["result"]
    if a.get("json"):
        return text(res)
    return text("# %s (%s)\n%s\n\nвсего: %s" % (a.get("project"), res["db"], res["table"], ", ".join(
        "%s/%s %d" % (x["kind"], x["impl"], x["n"]) for x in res.get("counts") or [])))


def t_gate(a):
    if a.get("accept_run"):
        return result(client(a.get("owner"), _role(a)).post("/call/core.gate_accept", {"args": {
            "project": a["project"], "run": a["accept_run"], "frames": a.get("frames")}}))
    return result(client(a.get("owner"), _role(a)).post("/call/core.gate", {"args": {
        "project": a["project"], "suite": a.get("suite", "all"), "mode": a.get("mode", "latest"),
        "refresh": a.get("refresh", True)}}, timeout=6 * 3600))


def t_play(a):
    args = {"project": a.get("project"), "action": a.get("action", "status")}
    for k in ("params", "opts", "max_s", "session", "final_check", "reason"):
        if a.get(k) is not None:
            args[k] = a[k]
    return result(client(a.get("owner"), _role(a)).post("/call/core.play", {"args": args}, timeout=900))


def _job_text(j, rr=None):
    lines = ["job %s: %s%s -> %s" % (j["id"], j.get("state"), (" (%s)" % j["verdict"]) if j.get("verdict") else "",
                                     j.get("dir") or "")]
    sc = (rr or {}).get("scenario") or {}
    for res in sc.get("results") or []:
        lines.append("--- %s: %s, %d shots" % (res["scenario"], "ok" if res.get("ok") else "FAILED: %s" % res.get(
            "error"), len(res.get("shots") or [])))
        for s in res.get("shots") or []:
            lines.append("    %-12s rgb %s  f2f %s" % (s["name"], (s.get("sha256_rgb") or "")[:16],
                                                       (s.get("sha256") or "")[:16]))
    if sc.get("compare"):
        cm = sc["compare"]
        lines.append("vs golden: %s" % json.dumps(cm.get("summary") or cm.get("error"), ensure_ascii=False))
        for n, b in (cm.get("per_scenario") or {}).items():
            lines.append("    %s: %s" % (n, json.dumps(b, ensure_ascii=False)))
        lines.append("    report: %s" % os.path.join(cm.get("out") or "", "report.md"))
    if sc.get("timing"):
        lines.append("timing %s" % json.dumps(sc["timing"]))
    if j.get("result"):
        lines.append(json.dumps(j["result"], ensure_ascii=False, default=str)[:3000])
    if j.get("error"):
        lines.append("error: %s" % j["error"])
    lines.append("progress (tail):")
    lines += ["  " + x for x in (j.get("progress") or [])[-12:]]
    return "\n".join(lines)


def _wait_job(c, jid, timeout):
    end = time.time() + float(timeout)
    while True:
        r = c.get("/scenario/jobs/%s?tail=40" % jid)
        j = r.get("job") or {}
        if not r.get("ok") or j.get("state") != "running" or time.time() > end:
            return r
        time.sleep(1.0)


def t_run(a):
    c = client(a.get("owner"), _role(a))
    if a.get("job"):
        if a.get("cancel"):
            return result(c.post("/scenario/jobs/%s/cancel" % a["job"]))
        r = _wait_job(c, a["job"], a.get("timeout", 0) if a.get("wait") else 0)
    else:
        names = a.get("scenarios") or a.get("scenario")
        names = [names] if isinstance(names, str) else names
        r = c.post("/scenario/run", {"project": a.get("project") or _default_project(), "scenarios": names,
                                     "impl": a.get("impl", "vc"),
                                     "opts": {"golden": bool(a.get("golden")), "keep": bool(a.get("keep")),
                                              "realtime": bool(a.get("realtime"))}})
        if not r.get("ok"):
            return result(r)
        if a.get("wait", True):
            r = _wait_job(c, r["job"]["id"], a.get("timeout", 900))
    if not r.get("ok"):
        return result(r)
    j = r.get("job") or {}
    rr = c.get("/runs/%s" % j.get("run")).get("run") if j.get("run") and j.get("state") != "running" else None
    return text(_job_text(j, rr), error=j.get("state") in ("failed", "cancelled"))


def t_perf(a):
    """lab perf: замер только на простаивающем ПК (этап 3а). Задание демона; wait=true — ждать итога."""
    c = client(a.get("owner"), _role(a))
    if a.get("job"):
        r = _wait_job(c, a["job"], a.get("timeout", 0) if a.get("wait") else 0)
    else:
        r = c.post("/call/core.perf", {"args": {k: a.get(k) for k in (
            "project", "scenario", "args", "wait_idle_s", "idle_window_s", "allow_contended") if a.get(k) is not None}})
        if not r.get("ok"):
            return result(r)
        jid = r["result"]["id"]
        r = _wait_job(c, jid, a.get("timeout", 1800)) if a.get("wait") else c.get("/scenario/jobs/%s?tail=40" % jid)
    if not r.get("ok"):
        return result(r)
    j = r.get("job") or {}
    return text(_job_text(j), error=j.get("state") == "failed")


def t_compare(a):
    r = client().post("/compare", {"a": a["a"], "b": a.get("b") or "golden", "project": a.get("project"),
                                   "tol": a.get("tol"), "out": a.get("out")}, timeout=1800)
    out = result(r)
    if r.get("ok") and a.get("report", True) and r.get("report_md") and os.path.exists(r["report_md"]):
        with open(r["report_md"], encoding="utf-8") as f:
            out["content"].append({"type": "text", "text": f.read()[:20000]})
    return out


def t_golden(a):
    c = client(a.get("owner"), _role(a))
    act = a.get("action", "status")
    project = a.get("project") or _default_project()
    if act == "status":
        names = a.get("names")
        r = c.get("/golden/%s/status" % project + ("?names=%s" % ",".join(names) if names else ""), timeout=600)
        if not r.get("ok"):
            return result(r)
        lines = ["%-26s %-11s %-5s %s" % (g["name"], g["state"], g.get("impl") or "",
                                         "; ".join(g.get("reasons") or [])[:200]) for g in r["goldens"]]
        return text("\n".join(lines + ["counts: %s" % json.dumps(r["counts"])]))
    if act == "import":
        return result(c.post("/golden/%s/import" % project, {"names": a.get("names"),
                                                             "overwrite": bool(a.get("overwrite"))}, timeout=1800))
    if act == "promote":
        return result(c.post("/golden/promote", {"run": a["run"], "reason": a.get("reason"),
                                                 "scenarios": a.get("names"), "force": bool(a.get("force"))}))
    if act == "regen":
        r = c.post("/golden/%s/regen" % project, {"scenario": a["scenario"], "runs": int(a.get("runs", 3)),
                                                  "reason": a.get("reason"), "strict": bool(a.get("strict"))})
        if r.get("ok") and a.get("wait", True):
            r = _wait_job(c, r["job"]["id"], a.get("timeout", 1800))
        return text(_job_text(r["job"])) if r.get("ok") else result(r)
    return text("action: status | import | promote | regen", error=True)


L = {"lease": {"type": "string", "description": "имя аренды (lab_ps)"}}
STATIC = {
    "lab_daemon": (t_daemon, "Демон лаборатории (только чтение): action status — код демона против файлов на диске "
                             "(stale, что перезагружается без рестарта), состояние serving/draining, аренды, твоя роль; "
                             "audit — журнал действий уровня демона (last); whoami. Остановка/рестарт/upgrade/drain/"
                             "reload-core — только CLI `lab daemon ...` и только admin (главная сессия/пользователь).",
                   {"type": "object", "properties": dict(action={"type": "string", "enum": ["status", "audit",
                                                                                            "whoami"]},
                                                         last={"type": "integer"}, **OWNER)}),
    "lab_ps": (t_ps, "Аренды лаборатории: владелец, проект/вид, состояние, pid, порты, TTL, прогон.",
               {"type": "object", "properties": {}}),
    "lab_lease": (t_lease, "Взять экземпляр: project (vc, ... — lab_ps/lab projects), kind (engine, server, ref_app...), "
                           "ttl (с), name, params (перекрыть параметры вида), start=true — сразу запустить.",
                  {"type": "object", "properties": dict(project={"type": "string"}, kind={"type": "string"},
                                                        ttl={"type": "number"}, name={"type": "string"},
                                                        params={"type": "object"}, start={"type": "boolean"}, **OWNER),
                   "required": ["project", "kind"]}),
    "lab_release": (t_release, "Освободить аренду (стоп дерева процессов, логи в прогон, порты в пул). all=true + "
                               "force=true — снять ВСЕ аренды (стоп пользователя).",
                    {"type": "object", "properties": dict(L, force={"type": "boolean"}, all={"type": "boolean"},
                                                          **OWNER)}),
    "lab_start": (t_start, "Запустить экземпляр аренды (подготовка каталога, процесс в Job Object, ожидание "
                           "готовности). restart=true — перезапуск.",
                  {"type": "object", "properties": dict(L, restart={"type": "boolean"}, params={"type": "object"},
                                                        **OWNER), "required": ["lease"]}),
    "lab_stop": (t_stop, "Остановить экземпляр (мягко, затем TerminateJobObject); аренда остаётся.",
                 {"type": "object", "properties": dict(L, **OWNER), "required": ["lease"]}),
    "lab_f2f": (t_f2f, "Команда F2F экземпляру (hello mode step input state shot render gui chat connect wait quit "
                       "и команды пака). shot без path — в shots\\ прогона, картинка в ответе (image=false — без неё). "
                       "Умер процесс — ответ instance-dead с кодом выхода и хвостом лога.",
                {"type": "object", "properties": dict(L, cmd={"type": "string"}, args={"type": "object"},
                                                      timeout={"type": "number"}, image={"type": "boolean"}, **OWNER),
                 "required": ["lease", "cmd"]}),
    "lab_logs": (t_logs, "Хвост лога экземпляра (stream: latest | stdout | stderr; кодировка определяется "
                         "построчно: utf-8 / cp866 / cp1251), grep — regex.",
                 {"type": "object", "properties": dict(L, stream={"type": "string"}, tail={"type": "integer"},
                                                       grep={"type": "string"}), "required": ["lease"]}),
    "lab_stdin": (t_stdin, "Строка в stdin экземпляра (вид stdin = true): админ-команды VoxelCore --stdin-cmd (мир проекта: "
                           "status, help, команды пака). Ответ — новые строки лога за wait с (или до pattern).",
                  {"type": "object", "properties": dict(L, text={"type": "string"}, wait={"type": "number"},
                                                        pattern={"type": "string"}, stream={"type": "string"},
                                                        **OWNER), "required": ["lease", "text"]}),
    "lab_runs": (t_runs, "Прогоны (каталоги с journal.jsonl, logs, shots, report.json): последние last или один id.",
                 {"type": "object", "properties": {"last": {"type": "integer"}, "project": {"type": "string"},
                                                   "id": {"type": "string"}}}),
    "lab_history": (t_history, "История прогонов проекта из history.sqlite демона: таблица (время, сценарий, impl, вид, "
                               "тег, вердикт, мин. % снимков, мин. % кадров серии, равенство состояний, fps 5 с). "
                               "action=import — переимпортировать каталоги прогонов; json=true — сырые строки.",
                    {"type": "object", "properties": {"project": {"type": "string"}, "scenario": {"type": "string"},
                                                      "last": {"type": "integer"}, "kind": {"type": "string"},
                                                      "action": {"type": "string"}, "json": {"type": "boolean"}},
                     "required": ["project"]}),
    "lab_gate": (t_gate, "Ворота-храповик: каждый снимок/ключевой кадр против лучшего записанного (или принятого) "
                         "значения ± ε шума Java/Java; suite all|layers|e2e|u|perf, mode latest|run. Вердикт JSON + "
                         "markdown с тепловыми картами; храповик не поднимает (accept_run=<id> — поднять явно).",
                 {"type": "object", "properties": dict(project={"type": "string"}, suite={"type": "string"},
                                                       mode={"type": "string"}, refresh={"type": "boolean"},
                                                       accept_run={"type": "string"}, frames={"type": "array"},
                                                       **OWNER), "required": ["project"]}),
    "lab_play": (t_play, "Сеанс стокового рантайма VoxelCore.exe (аренда vc-main). Игра пользователя (--user) — только из "
                         "его CLI `lab play <project> --user`, через MCP — отказ. Через MCP: только action=start с "
                         "final_check=true и reason (разовая финальная проверка главной сессией claude по запросу/перед "
                         "релизом; субагентам и циклам замеров — никогда), stop, status, list. params "
                         "{\"server.world\": \"world_b\"}, opts [\"autowalk\"], max_s. Итог — play_report.md и запись "
                         "runtime_session с причиной в истории.",
                 {"type": "object", "properties": dict(project={"type": "string"}, action={"type": "string"},
                                                       params={"type": "object"}, opts={"type": "array"},
                                                       max_s={"type": "number"}, session={"type": "string"},
                                                       final_check={"type": "boolean"}, reason={"type": "string"},
                                                       **OWNER)}),
    "lab_perf": (t_perf, "Замер производительности только на простаивающем ПК (этап 3а): ждёт простоя (idle_window_s "
                         "подряд, не дольше wait_idle_s; нет чужих движков/Java, CPU/GPU ниже порогов, пользователь не "
                         "трогает ввод, нет других работ лаборатории), гонит перф-сценарий проекта на движке с часами "
                         "realtime (тестовая сборка, ввод изолирован), помечает contended и пишет в историю. Не дождался "
                         "простоя — отказ (allow_contended=true — прогон сразу contended). job=<id> — состояние задания.",
                 {"type": "object", "properties": dict(project={"type": "string"}, scenario={"type": "string"},
                                                       args={"type": "object"}, wait_idle_s={"type": "number"},
                                                       idle_window_s={"type": "number"},
                                                       allow_contended={"type": "boolean"}, wait={"type": "boolean"},
                                                       timeout={"type": "number"}, job={"type": "string"}, **OWNER)}),
    "lab_run": (t_run, "Прогон сценария интерпретатором демона: project (vc, ...), scenario или scenarios "
                       "(общая подготовка один раз), impl (vc|java), golden=true — сравнить с golden, keep — не снимать "
                       "аренды. wait (по умолчанию true, timeout 900 с) — ждать и вернуть sha снимков и сравнение; иначе "
                       "id задания. job=<id> — состояние задания (cancel=true — отменить).",
                {"type": "object", "properties": dict(project={"type": "string"}, scenario={"type": "string"},
                                                      scenarios={"type": "array", "items": {"type": "string"}},
                                                      impl={"type": "string", "enum": ["vc", "java"]},
                                                      golden={"type": "boolean"}, keep={"type": "boolean"}, realtime={"type": "boolean"},
                                                      wait={"type": "boolean"}, timeout={"type": "number"},
                                                      job={"type": "string"}, cancel={"type": "boolean"}, **OWNER)}),
    "lab_compare": (t_compare, "Сравнить прогоны/golden: a, b — id прогона, каталог прогона или сценария, «golden» "
                               "(golden сценариев a) или golden:<сценарий>. Одиночные снимки — identical/tol/покрытие/bbox, "
                               "diff/heat PNG; таймлайн — серия (кадры, state по категориям, первый такт расхождения, "
                               "drift.png). Возвращает сводку и report.md.",
                    {"type": "object", "properties": {"a": {"type": "string"}, "b": {"type": "string"},
                                                      "project": {"type": "string"}, "tol": {"type": "integer"},
                                                      "out": {"type": "string"}, "report": {"type": "boolean"}},
                     "required": ["a"]}),
    "lab_golden": (t_golden, "Golden с манифестами: action status (fresh/stale с причинами, unverified — неизвестное "
                             "происхождение) | import (манифесты существующих каталогов + CAS) | promote (run, reason) | "
                             "regen (scenario, runs=3: прогоны Java, J/J-сверка, promote большинства с шумом). project — "
                             "по умолчанию [defaults] project из lab.toml.",
                   {"type": "object", "properties": dict(action={"type": "string", "enum": ["status", "import",
                                                                                           "promote", "regen"]},
                                                         project={"type": "string"}, scenario={"type": "string"},
                                                         names={"type": "array", "items": {"type": "string"}},
                                                         run={"type": "string"}, reason={"type": "string"},
                                                         runs={"type": "integer"}, strict={"type": "boolean"},
                                                         force={"type": "boolean"}, overwrite={"type": "boolean"},
                                                         wait={"type": "boolean"}, timeout={"type": "number"},
                                                         **OWNER)}),
    "lab_call": (t_call, "Возможность плагина проекта или ядра: feature (<проект>.<имя>, "
                         "core.pump_log, core.engines, ...; 'list' — все с описаниями), args.",
                 {"type": "object", "properties": dict(feature={"type": "string"}, args={"type": "object"}, **OWNER),
                  "required": ["feature"]}),
}


def refresh_dynamic():
    """Возможности плагинов с mcp=true -> инструменты lab_<проект>_<имя>. True, если набор изменился."""
    try:
        r = client().get("/features", timeout=5)
    except Exception:
        return False
    if not r.get("ok"):
        return False
    dyn = {}
    for name, f in r["features"].items():
        if not f.get("mcp"):
            continue
        tname = "lab_" + name.replace(".", "_")
        schema = json.loads(json.dumps(f.get("schema") or {"type": "object", "properties": {}}))
        schema.setdefault("properties", {}).update(OWNER)

        def fn(a, _name=name):
            a = dict(a)
            owner = a.pop("owner", None)
            role = "agent" if a.pop("as_agent", None) else None
            return result(client(owner, role).post("/call/%s" % _name, {"args": a}))
        dyn[tname] = (fn, "[%s] %s" % (f.get("version"), f.get("description", "")), schema)
    sig = json.dumps({k: [v[1], v[2]] for k, v in dyn.items()}, sort_keys=True)
    changed = STATE.get("sig") is not None and sig != STATE["sig"]
    STATE["sig"] = sig
    STATE["dyn"] = dyn
    STATE["gen"] = r.get("generation")
    return changed


def poller():
    while True:
        time.sleep(2.0)
        try:
            if refresh_dynamic() and STATE["initialized"]:
                send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        except Exception:
            pass


def tools():
    allt = dict(STATIC)
    allt.update(STATE["dyn"])
    return allt


def handle(req):
    m = req.get("method")
    p = req.get("params") or {}
    if m == "initialize":
        return {"protocolVersion": p.get("protocolVersion", PROTOCOL),
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": "lab", "version": "1.0"}}
    if m == "ping":
        return {}
    if m == "tools/list":
        if STATE["sig"] is None:
            refresh_dynamic()
        return {"tools": [{"name": n, "description": d, "inputSchema": s} for n, (_, d, s) in tools().items()]}
    if m == "tools/call":
        name = p.get("name")
        t = tools().get(name)
        if t is None:
            refresh_dynamic()
            t = tools().get(name)
        if t is None:
            raise KeyError("unknown tool %s" % name)
        try:
            return t[0](p.get("arguments") or {})
        except Exception as exc:
            return text("%s: %s" % (type(exc).__name__, exc), error=True)
    raise KeyError("method not found: %s" % m)


def work(req):
    try:
        resp = {"jsonrpc": "2.0", "id": req["id"], "result": handle(req)}
    except KeyError as exc:
        resp = {"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32601, "message": str(exc)}}
    except Exception as exc:
        resp = {"jsonrpc": "2.0", "id": req["id"],
                "error": {"code": -32603, "message": "%s: %s" % (type(exc).__name__, exc)}}
    send(resp)


def worker(q):
    while True:
        work(q.get())


def main():
    import queue
    STATE["sig"] = None
    threading.Thread(target=poller, daemon=True).start()
    # несколько постоянных рабочих потоков: долгий lab_call не задерживает lab_ps другого агента той же сессии,
    # а у каждого потока своё постоянное HTTP-соединение с демоном
    q = queue.Queue()
    for _ in range(4):
        threading.Thread(target=worker, args=(q,), daemon=True).start()
    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line.decode("utf-8"))
        except ValueError:
            continue
        if "id" not in req:
            if req.get("method") == "notifications/initialized":
                STATE["initialized"] = True
            continue
        q.put(req)


if __name__ == "__main__":
    main()
