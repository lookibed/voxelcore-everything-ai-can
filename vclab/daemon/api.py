"""HTTP API демона (FastAPI). Тела запросов — JSON; владелец — заголовок X-Lab-Owner (или поле owner).
Ошибки — JSON {ok:false, error:<код>, message, ...} с кодом HTTP (404 not-found, 403 not-owner, 409 instance-dead...)."""
from typing import Any, Optional

from fastapi import Body, FastAPI, Header, Request
from fastapi.responses import JSONResponse

from vclab.scenario.scenario import ScenarioError
from vclab.daemon.service import LabError


def create_app(lab):
    app = FastAPI(title="labd", version="1.0", docs_url="/docs", redoc_url=None)

    @app.exception_handler(LabError)
    async def lab_error(request: Request, exc: LabError):
        return JSONResponse(status_code=exc.status, content=exc.body())

    @app.exception_handler(ScenarioError)
    async def scenario_error(request: Request, exc: ScenarioError):
        return JSONResponse(status_code=400, content={"ok": False, "error": "scenario", "message": str(exc)})

    @app.exception_handler(FileNotFoundError)
    async def fnf_error(request: Request, exc: FileNotFoundError):
        return JSONResponse(status_code=404, content={"ok": False, "error": "not-found", "message": str(exc)})

    @app.exception_handler(KeyError)
    async def key_error(request: Request, exc: KeyError):
        return JSONResponse(status_code=400, content={"ok": False, "error": "bad-request", "message": str(exc)})

    @app.exception_handler(Exception)
    async def any_error(request: Request, exc: Exception):
        import traceback
        return JSONResponse(status_code=500, content={"ok": False, "error": "internal", "message": "%s: %s" % (
            type(exc).__name__, exc), "trace": traceback.format_exc(limit=6)})

    def who(body_owner, header_owner):
        return body_owner or header_owner

    @app.get("/health")
    def health():
        return lab.health()

    @app.get("/projects")
    def projects():
        base = lab.base_ctx()
        out = {n: p.info(dict(base, project_dir=p.dir)) for n, p in lab.projects.projects.items()}
        return {"ok": True, "generation": lab.projects.generation, "errors": lab.projects.errors, "projects": out}

    @app.get("/leases")
    def leases():
        return lab.ps()

    @app.post("/leases")
    def lease_create(body: dict = Body(...), x_lab_owner: Optional[str] = Header(None),
                     x_lab_client: Optional[str] = Header(None)):
        # mode/reason (role=runtime) принимаются только через lab play (core.play); прямая аренда рантайма — отказ
        return lab.create_lease(body["project"], body["kind"], who(body.get("owner"), x_lab_owner),
                                ttl=body.get("ttl"), name=body.get("name"), params=body.get("params"),
                                start=bool(body.get("start")), via=x_lab_client)

    @app.get("/leases/{name}")
    def lease_get(name: str):
        return {"ok": True, "lease": lab.lease_info(name)}

    @app.post("/leases/{name}/renew")
    def lease_renew(name: str, body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None)):
        return lab.renew(name, who(body.get("owner"), x_lab_owner), ttl=body.get("ttl"), force=bool(body.get("force")))

    @app.post("/leases/{name}/release")
    def lease_release(name: str, body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None)):
        return lab.release(name, who(body.get("owner"), x_lab_owner), force=bool(body.get("force")),
                           keep_dir=bool(body.get("keep_dir")))

    @app.post("/stop-all")
    def stop_all(x_lab_owner: Optional[str] = Header(None), x_lab_role: Optional[str] = Header(None),
                 x_lab_client: Optional[str] = Header(None)):
        # этап 5: release --all --force (= «стоп» пользователя) — только admin (или starter изолированного демона)
        lab.ctl.require("release.all", x_lab_owner, x_lab_role, via=x_lab_client)
        return lab.stop_all(owner=x_lab_owner)

    @app.post("/proc/{name}/start")
    def proc_start(name: str, body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None)):
        return lab.start(name, who(body.get("owner"), x_lab_owner), restart=bool(body.get("restart")),
                         params=body.get("params"), force=bool(body.get("force")))

    @app.post("/proc/{name}/stop")
    def proc_stop(name: str, body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None)):
        return lab.stop(name, who(body.get("owner"), x_lab_owner), force=bool(body.get("force")))

    @app.post("/proc/{name}/stdin")
    def proc_stdin(name: str, body: dict = Body(...), x_lab_owner: Optional[str] = Header(None)):
        return lab.stdin(name, body["text"], who(body.get("owner"), x_lab_owner), wait=float(body.get("wait", 2.0)),
                         pattern=body.get("pattern"), stream=body.get("stream"), force=bool(body.get("force")),
                         poke=False if body.get("poke") is False else None)

    @app.get("/engines")
    def engines(project: Optional[str] = None):
        proj = lab.projects.get(project) if project else None
        return {"ok": True, "default": lab.default_engine(proj), "engines": lab.engines_info(proj)}

    @app.get("/proc/{name}")
    def proc_status(name: str):
        return {"ok": True, "lease": lab.lease_info(name)}

    @app.get("/proc/{name}/logs")
    def proc_logs(name: str, stream: Optional[str] = None, tail: int = 80, grep: Optional[str] = None):
        return lab.logs(name, stream=stream, tail=tail, grep=grep)

    @app.post("/f2f/{name}")
    def f2f(name: str, body: dict = Body(...), x_lab_owner: Optional[str] = Header(None)):
        return lab.f2f(name, body["cmd"], body.get("args") or {}, timeout=float(body.get("timeout", 60)),
                       owner=who(body.get("owner"), x_lab_owner), force=bool(body.get("force")))

    @app.get("/journal")
    def journal(last: int = 30, instance: Optional[str] = None, run: Optional[str] = None, inner: bool = False):
        return {"ok": True, "path": lab.journal.path,
                "entries": lab.journal.tail(last, instance=instance, run=run, top_only=not inner)}

    @app.get("/runs")
    def runs(last: int = 30, project: Optional[str] = None):
        return {"ok": True, "runs": lab.runs.list(last, project)}

    @app.post("/runs")
    def run_open(body: dict = Body(...), x_lab_owner: Optional[str] = Header(None)):
        return lab.open_run(body["project"], body.get("scenario", "adhoc"), who(body.get("owner"), x_lab_owner),
                            leases=body.get("leases"), meta=body.get("meta"))

    @app.get("/runs/{rid}")
    def run_get(rid: str):
        r = lab.runs.get(rid)
        if r is None:
            raise LabError("not-found", "no run %s" % rid)
        return {"ok": True, "run": r}

    @app.post("/runs/{rid}/close")
    def run_close(rid: str, body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None)):
        return lab.close_run(rid, body.get("verdict"), who(body.get("owner"), x_lab_owner), extra=body.get("extra"))

    @app.get("/features")
    def features():
        return {"ok": True, "generation": lab.projects.generation,
                "features": {k: v.info() for k, v in lab.projects.features().items()}}

    @app.post("/call/{feature}")
    def call(feature: str, body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
             x_lab_client: Optional[str] = Header(None), x_lab_role: Optional[str] = Header(None)):
        return lab.call(feature, body.get("args") or {}, owner=who(body.get("owner"), x_lab_owner), via=x_lab_client,
                        role=x_lab_role)

    # ---------------------------------------------------------------- этап 2: сценарии, сравнение, golden
    @app.post("/scenario/run")
    def scenario_run(body: dict = Body(...), x_lab_owner: Optional[str] = Header(None)):
        lab.ctl.check_new_work()
        names = body.get("scenarios") or [body["scenario"]]
        job = lab.scen.start(body["project"], names, body.get("impl") or "vc", who(body.get("owner"), x_lab_owner),
                             opts=body.get("opts") or {}, wait=bool(body.get("wait")))
        return {"ok": True, "job": job}

    @app.get("/scenario/jobs")
    def scenario_jobs():
        return {"ok": True, "jobs": lab.scen.list()}

    @app.get("/scenario/jobs/{jid}")
    def scenario_job(jid: str, tail: int = 40):
        j = lab.scen.get(jid, tail)
        if j is None:
            raise LabError("not-found", "no job %s" % jid)
        return {"ok": True, "job": j}

    @app.post("/scenario/jobs/{jid}/cancel")
    def scenario_cancel(jid: str, x_lab_owner: Optional[str] = Header(None)):
        j = lab.scen.cancel(jid, x_lab_owner)
        if j is None:
            raise LabError("not-found", "no job %s" % jid)
        return {"ok": True, "job": j}

    @app.get("/scenario/describe/{project}/{name}")
    def scenario_describe(project: str, name: str):
        proj, scns = lab.scen.load(project, [name])
        s = scns[0]
        return {"ok": True, "scenario": s.describe(), "prefix": s.prefix, "body": s.body, "setup": s.setup}

    @app.post("/compare")
    def compare(body: dict = Body(...)):
        from vclab.quality.compare import compare_api
        return compare_api(lab, body["a"], body.get("b") or "golden", project=body.get("project"),
                           out=body.get("out"), tol=body.get("tol"), scenarios=body.get("scenarios"))

    @app.get("/golden/{project}/status")
    def golden_status(project: str, names: Optional[str] = None):
        return lab.golden.status(project, names.split(",") if names else None)

    @app.post("/golden/{project}/import")
    def golden_import(project: str, body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None)):
        return lab.golden.import_existing(project, body.get("names"), owner=who(body.get("owner"), x_lab_owner),
                                          overwrite=bool(body.get("overwrite")))

    @app.post("/golden/promote")
    def golden_promote(body: dict = Body(...), x_lab_owner: Optional[str] = Header(None),
                       x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        # этап 5: golden общий для всех демонов — только настоящий admin (не starter изолированного)
        lab.ctl.require("golden.promote", who(body.get("owner"), x_lab_owner), x_lab_role, via=x_lab_client,
                        scope="data", run=body.get("run"))
        return lab.golden.promote(body["run"], body.get("reason"), owner=who(body.get("owner"), x_lab_owner),
                                  scenarios=body.get("scenarios"), force=bool(body.get("force")))

    @app.post("/golden/{project}/regen")
    def golden_regen(project: str, body: dict = Body(...), x_lab_owner: Optional[str] = Header(None)):
        lab.ctl.check_new_work()
        owner = who(body.get("owner"), x_lab_owner)
        name = body["scenario"]
        job = lab.scen.bg("regen_%s" % name, owner, lambda job: lab.golden.regen(
            project, name, runs=int(body.get("runs", 3)), owner=owner, reason=body.get("reason"),
            impl=body.get("impl") or "java", job=job, strict=bool(body.get("strict"))))
        return {"ok": True, "job": job}

    # ---------------------------------------------------------------- этап 6: supervisor (vclab/supervise.py)
    from fastapi.responses import HTMLResponse

    def sup():
        s = getattr(lab, "sup", None)
        if s is None:
            raise LabError("not-found", "supervisor is not installed (journal lab.stage6_failed)")
        return s

    @app.get("/sup/state")
    def sup_state(prefix: Optional[str] = None, group: Optional[str] = None):
        # панель-файл (file://) читает отсюда: только loopback, только чтение
        return JSONResponse(sup().state(prefix, group), headers={"Access-Control-Allow-Origin": "*"})

    @app.get("/sup/panel", response_class=HTMLResponse)
    def sup_panel(prefix: Optional[str] = None, title: str = "Supervisor"):
        from vclab.supervise import panel_html
        return panel_html(title, "/sup/state" + ("?prefix=" + prefix if prefix else ""), lab)

    @app.get("/sup/auth")
    def sup_auth(token_sha: str, ip: Optional[str] = None, gateway: Optional[str] = None):
        # шлюз: sha256 токена (сам токен по HTTP не ходит) -> аккаунт или отказ (auth/banned)
        return sup().db.auth(token_sha, ip, gateway)

    @app.get("/sup/bans")
    def sup_bans(gateway: Optional[str] = None):
        b = sup().db.active_bans()
        return {"ok": True, "accounts": b["accounts"], "ips": b["ips"]}

    # ---------------------------------------------------------------- этап 5: уровень демона (vclab/daemon/admin.py)
    def ctl_args(body, owner, role, client):
        return dict(owner=who(body.get("owner"), owner), role_hdr=role, via=client, reason=body.get("reason"))

    @app.post("/shutdown")          # прежний путь labctl stop: теперь те же проверки, что /daemon/stop
    @app.post("/daemon/stop")
    def daemon_stop(body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
                    x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        return lab.ctl.stop(force=bool(body.get("force")), **ctl_args(body, x_lab_owner, x_lab_role, x_lab_client))

    @app.post("/daemon/restart")
    def daemon_restart(body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
                       x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        return lab.ctl.restart(force=bool(body.get("force")), **ctl_args(body, x_lab_owner, x_lab_role, x_lab_client))

    @app.post("/daemon/upgrade")
    def daemon_upgrade(body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
                       x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        return lab.ctl.upgrade(timeout=body.get("timeout"), force=bool(body.get("force")),
                               **ctl_args(body, x_lab_owner, x_lab_role, x_lab_client))

    @app.post("/daemon/drain")
    def daemon_drain(body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
                     x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        return lab.ctl.start_drain(timeout=body.get("timeout"), then=body.get("then") or None,
                                   **ctl_args(body, x_lab_owner, x_lab_role, x_lab_client))

    @app.post("/daemon/undrain")
    def daemon_undrain(body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
                       x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        return lab.ctl.undrain(**ctl_args(body, x_lab_owner, x_lab_role, x_lab_client))

    @app.post("/daemon/reload-core")
    def daemon_reload(body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
                      x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        return lab.ctl.reload_core(force=bool(body.get("force")), modules=body.get("modules"),
                                   **ctl_args(body, x_lab_owner, x_lab_role, x_lab_client))

    @app.post("/daemon/config")     # правки конфигурации через API нет: lab.toml + lab daemon upgrade (admin)
    def daemon_config(body: dict = Body(default={}), x_lab_owner: Optional[str] = Header(None),
                      x_lab_role: Optional[str] = Header(None), x_lab_client: Optional[str] = Header(None)):
        lab.ctl.require("daemon.config", x_lab_owner, x_lab_role, via=x_lab_client)
        raise LabError("bad-request", "no live config edits: change lab.toml, then `lab daemon upgrade` (admin)")

    @app.get("/daemon/info")
    def daemon_info():
        return lab.ctl.info()

    @app.get("/daemon/whoami")
    def daemon_whoami(x_lab_owner: Optional[str] = Header(None), x_lab_role: Optional[str] = Header(None)):
        return {"ok": True, "owner": x_lab_owner, "role": lab.ctl.role(x_lab_owner, x_lab_role),
                "daemon_rights": lab.ctl.daemon_rights(x_lab_owner, x_lab_role)}

    @app.get("/daemon/audit")
    def daemon_audit(last: int = 30):
        return {"ok": True, "path": lab.ctl.audit.path, "entries": lab.ctl.audit.tail(last)}

    return app
