"""machine.toml — корни ЭТОЙ машины (не в git; образец — machine.toml.example в корне репозитория).

Единственное место, где живут пути конкретного ПК: каталоги движков и тестовых сборок, рабочий каталог (данные
демона, прогоны, изолированные демоны), MSYS2, Python для Windows и WSL, мост WSL <-> Windows. Остальной код и
дескрипторы ссылаются на них подстановками `{machine.<ключ>}` (engines/registry.toml, projects/*/project.toml).

Файл ищется: $LAB_MACHINE, иначе <repo>/machine.toml. Нет файла — пустой словарь (lab doctor скажет, чего не хватает).
Чтение работает и на Windows-Python 3.11+ (tomllib), и на WSL-Python 3.10 (tomli, иначе — разбор простого подмножества
TOML: [таблицы], ключ = 'строка' | "строка" | число | true/false, комментарии)."""
import os
import re

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS = {
    # ключ: (обязателен, описание) — lab doctor и machine.toml.example
    "engines_root": (True, "каталог, где лежат распакованные стоковые релизы VoxelCore (voxelcore-<версия>_win64)"),
    "builds_root": (True, "каталог тестовых сборок F2F (VoxelCoreF2F-<версия>.exe) и их логов сборки"),
    "work_root": (True, "рабочий каталог: данные демона (<work_root>\\lab), прогоны, изолированные демоны"),
    "python_win": (True, "python.exe Windows (3.11+, pywin32, psutil, fastapi, uvicorn, numpy, Pillow, jinja2)"),
    "python_wsl": (False, "python3 в WSL (MCP-сервер voxelcore, тонкие клиенты)"),
    "msys2": (False, "корень MSYS2 (CLANG64) — только для сборки F2F-патчей (f2f/build)"),
    "vc_root": (False, "рабочий рантайм для запусков паков ({vc_root}: content, res, latest.log); "
                       "по умолчанию — root движка по умолчанию из registry"),
    "wsl_mount": (False, "префикс дисков Windows в WSL (по умолчанию /mnt)"),
    "powershell": (False, "powershell.exe (MCP voxelcore: запасные снимки окна)"),
    "cargo": (False, "cargo (проекты с Rust-службами; ядру не нужен)"),
}


def path():
    return os.environ.get("LAB_MACHINE") or os.path.join(REPO_ROOT, "machine.toml")


def _parse_value(v):
    v = v.strip()
    if v[:3] in ("'''", '"""'):
        raise ValueError("multiline strings are not supported by the fallback parser")
    if v.startswith("'"):
        return v[1:v.index("'", 1)]
    if v.startswith('"'):
        m = re.match(r'"((?:[^"\\]|\\.)*)"', v)
        return bytes(m.group(1), "utf-8").decode("unicode_escape") if m else v
    if v.startswith("["):
        inner = v[1:v.rindex("]")]
        return [_parse_value(x) for x in re.findall(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"|[^,\s]+", inner)]
    v = v.split("#", 1)[0].strip()
    if v in ("true", "false"):
        return v == "true"
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def _mini_toml(text):
    out, cur = {}, None
    cur = out
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[([^\]]+)\]", line)
        if m:
            cur = out
            for part in m.group(1).strip().split("."):
                cur = cur.setdefault(part.strip().strip('"'), {})
            continue
        k, _, v = line.partition("=")
        cur[k.strip().strip('"')] = _parse_value(v)
    return out


def loads(text):
    try:
        import tomllib
        return tomllib.loads(text)
    except ImportError:
        pass
    try:
        import tomli
        return tomli.loads(text)
    except ImportError:
        return _mini_toml(text)


def load_file(p):
    with open(p, encoding="utf-8") as f:
        return loads(f.read())


_CACHE = {}


def load(p=None, reload=False):
    """-> dict machine.toml (пустой, если файла нет). Ключ `_path` — откуда прочитано (или где искали)."""
    p = p or path()
    if p in _CACHE and not reload:
        return _CACHE[p]
    try:
        m = load_file(p)
        m["_found"] = True
    except FileNotFoundError:
        m = {"_found": False}
    m["_path"] = p
    _CACHE[p] = m
    return m


def subst(value, m=None):
    """{machine.<ключ>} в строке (для лаунчеров и doctor без контекста демона)."""
    m = m if m is not None else load()

    def rep(mo):
        cur = m
        for part in mo.group(1).split("."):
            if not isinstance(cur, dict) or part not in cur:
                raise KeyError("machine.toml: no key %r (%s)" % (mo.group(1), m.get("_path")))
            cur = cur[part]
        return str(cur)
    return re.sub(r"\{machine\.([\w.]+)\}", rep, value) if isinstance(value, str) else value


def public(m=None):
    """Копия без служебных ключей (_path, _found) — для контекста подстановок."""
    m = m if m is not None else load()
    return {k: v for k, v in m.items() if not k.startswith("_")}
