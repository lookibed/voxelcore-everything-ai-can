"""Реестр версий движка: engines/registry.toml (в git, без путей машины) + machine.toml (где это лежит на этом ПК).

Каждая версия (`[engines.<id>]`) описывает происхождение (релиз: URL, sha256 zip, коммит; F2F: патч, ветка, коммит,
`f2f_version`) и раскладку файлов относительно корней машины:
  root   = {machine.engines_root}\\<install_dir>          (стоковый релиз: VoxelCore.exe, vctest.exe, res\\)
  f2f    = {machine.builds_root}\\<f2f_exe>                (тестовая сборка F2F)
machine.toml может перекрыть любой из путей версии: `[engines.<id>] root = '...'`, `f2f = '...'`, `stock`, `vctest`, `res`.
На выходе — словарь в формате, который ядро понимает с этапа 4 (`root res stock exe builds{f2f,stock,vctest}
f2f_version version commit description`), плюс поля происхождения как есть.

Политика «сток только пользователю» (README лаборатории «Этап 3а»/«Политика headless») исполняется в vclab/policy.py:
стоковый exe каждой версии из этого реестра (`stock`) попадает в policy.EXTRA_STOCK — в тестовых видах он запрещён,
в виде role = "headless" разрешён, оконный запуск стока — только `lab play --user` / `--final-check`."""
import os

from vclab import machine

REGISTRY = os.path.join(machine.REPO_ROOT, "engines", "registry.toml")
OVERRIDABLE = ("root", "res", "stock", "vctest", "f2f")


def _join(*parts):
    parts = [p for p in parts if p]
    return "\\".join([p.rstrip("\\/") for p in parts[:-1]] + parts[-1:])


def load_registry(path=None):
    path = path or os.environ.get("LAB_ENGINES") or REGISTRY
    try:
        return machine.load_file(path)
    except FileNotFoundError:
        return {}


def resolve(reg=None, m=None):
    """-> {"default": id, "<id>": {...}} в формате [engines.*] ядра. Пути без корня машины остаются пустыми строками
    (lab doctor назовёт, чего не хватает); подстановки {machine.*} раскрыты."""
    reg = reg if reg is not None else load_registry()
    m = m if m is not None else machine.load()
    engs = reg.get("engines") or {}
    over_all = m.get("engines") or {}
    out = {}
    if engs.get("default"):
        out["default"] = engs["default"]
    for eid, e in engs.items():
        if not isinstance(e, dict):
            continue
        over = over_all.get(eid) or {}
        d = {k: v for k, v in e.items()}
        er, br = m.get("engines_root") or "", m.get("builds_root") or ""
        root = over.get("root") or (_join(er, e["install_dir"]) if er and e.get("install_dir") else "")
        res = over.get("res") or (_join(root, "res") if root else "")
        stock = over.get("stock") or (_join(root, e.get("stock_exe", "VoxelCore.exe")) if root else "")
        vctest = over.get("vctest") or (_join(root, e["vctest_exe"]) if root and e.get("vctest_exe") else "")
        f2f = over.get("f2f") or (_join(br, e["f2f_exe"]) if br and e.get("f2f_exe") else "")
        d.update(root=root, res=res, stock=stock, exe=f2f or stock)
        builds = {"f2f": f2f, "stock": stock}
        if vctest:
            builds["vctest"] = vctest
        d["builds"] = {k: v for k, v in builds.items() if v}
        out[eid] = {k: machine.subst(v, m) if isinstance(v, str) else v for k, v in d.items()}
    return out


def default_id(reg=None):
    reg = reg if reg is not None else load_registry()
    return (reg.get("engines") or {}).get("default") or "v031"
