"""Пути и настройки лаборатории. Демон и тесты работают на Windows-Python; пути — Windows.

Корни машины — machine.toml (vclab/machine.py), версии движка — engines/registry.toml (vclab/engines.py), настройки
демона — lab.toml в корне репозитория (без путей машины: подстановки {work_root}, {vc_root}, {machine.<ключ>})."""
import os
import re

from vclab import engines as _engines
from vclab import machine as _machine

REPO_ROOT = _machine.REPO_ROOT
LAB_DIR = REPO_ROOT                       # {lab_dir}: корень репозитория (раньше ...\tools\lab)
BIN_DIR = os.path.join(REPO_ROOT, "bin")  # bin\labd.py, bin\lab.py, bin\mcp_bridge.py — точки входа процессов
PROJECTS_DIR = os.path.join(REPO_ROOT, "projects")
MACHINE = _machine.load()


def _default_engine_root():
    try:
        engs = _engines.resolve(m=MACHINE)
        return (engs.get(engs.get("default") or _engines.default_id()) or {}).get("root") or None
    except Exception:
        return None


# {vc_root}: рабочий рантайм запусков паков (content, res, latest.log). machine.toml `vc_root`, иначе корень движка
# по умолчанию из реестра; LAB_VC_ROOT — перекрытие для тестов.
VC_ROOT = os.environ.get("LAB_VC_ROOT") or MACHINE.get("vc_root") or _default_engine_root() or REPO_ROOT
WORK_ROOT = os.environ.get("LAB_WORK_ROOT") or MACHINE.get("work_root") or os.path.join(REPO_ROOT, "work")


def wsl_to_win(path):
    """/mnt/<диск>/x/y -> <ДИСК>:\\x\\y (чистая функция, без wslpath)."""
    if isinstance(path, str):
        m = re.match(r"^/mnt/([a-zA-Z])(?:/(.*))?$", path)
        if m:
            return m.group(1).upper() + ":\\" + (m.group(2) or "").replace("/", "\\")
    return path


def win_to_wsl(path):
    if isinstance(path, str):
        m = re.match(r"^([A-Za-z]):[\\/]?(.*)$", path)
        if m:
            return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/"))
    return path


def subst_root(s):
    """{vc_root} {work_root} {repo_root} {machine.<ключ>} в строке lab.toml."""
    if not isinstance(s, str):
        return s
    s = s.replace("{vc_root}", VC_ROOT).replace("{work_root}", WORK_ROOT).replace("{repo_root}", REPO_ROOT)
    return _machine.subst(s, MACHINE)


def load(path=None):
    """lab.toml + engines/registry.toml + machine.toml + переопределения окружения (LAB_DATA, LAB_PORT, LAB_PORTS,
    LAB_ISOLATED, LAB_STARTER) -> dict."""
    path = path or os.environ.get("LAB_CONFIG") or os.path.join(REPO_ROOT, "lab.toml")
    cfg = _machine.load_file(path)
    d = cfg.setdefault("daemon", {})
    d["host"] = d.get("host", "127.0.0.1")
    d["port"] = int(os.environ.get("LAB_PORT") or d.get("port", 25700))
    data = os.environ.get("LAB_DATA") or d.get("data", "{work_root}\\lab")
    d["data"] = os.path.abspath(wsl_to_win(subst_root(data)))
    # этап 5: изолированный демон (lab daemon start --isolated) и роли (vclab/daemon/admin.py)
    d["isolated"] = bool(os.environ.get("LAB_ISOLATED")) or bool(d.get("isolated"))
    d["starter"] = os.environ.get("LAB_STARTER") or d.get("starter")
    r = cfg.setdefault("roles", {})
    r["admins"] = list(r.get("admins") or ("user", "claude"))
    p = cfg.setdefault("ports", {})
    if os.environ.get("LAB_PORTS"):
        a, b = os.environ["LAB_PORTS"].split("-")
        p["first"], p["last"] = int(a), int(b)
    p.setdefault("first", 25600)
    p.setdefault("last", 25699)
    cfg.setdefault("leases", {}).setdefault("default_ttl", 900)
    cfg["leases"].setdefault("max_ttl", 86400)
    cfg["leases"].setdefault("reap_every", 5)
    w = cfg.setdefault("watch", {})
    if os.environ.get("LAB_NO_WATCH"):
        w.clear()
    for k in list(w):
        w[k] = subst_root(w[k])
    # версии движка: реестр + корни машины; [engines] lab.toml (default, свои секции) — поверх
    engs = _engines.resolve(m=MACHINE)
    for k, v in (cfg.get("engines") or {}).items():
        engs[k] = dict(engs.get(k) or {}, **v) if isinstance(v, dict) else v
    cfg["engines"] = engs
    cfg.setdefault("defaults", {})
    extra = os.environ.get("LAB_PROJECTS")
    cfg["project_dirs"] = [PROJECTS_DIR] + ([wsl_to_win(x) for x in extra.split(os.pathsep) if x] if extra else [])
    return cfg


def machine_ctx():
    """{machine.<ключ>} для подстановок дескрипторов (без служебных ключей)."""
    return _machine.public(MACHINE)


# TODO(волна 5): поведение изменено при выносе имён: раньше без --project брался зашитый проект; теперь [defaults]
# project lab.toml, пусто — ошибка «--project is required».
def default_project(cfg=None):
    """Проект по умолчанию для команд без --project (lab.toml [defaults] project; раньше было зашито имя проекта)."""
    try:
        cfg = cfg or load()
        return (cfg.get("defaults") or {}).get("project") or None
    except Exception:
        return None
