"""`lab doctor` — проверка машины: machine.toml, корни, движки реестра, Python, MSYS2, cargo, место на диске, порт демона.

  lab doctor [--json] [--probe] [--daemon P] [--engine ID ...]

Печатает таблицу «ок / чего не хватает / как починить» (ссылки — install/doctor.md#<якорь>). Код выхода 0 — нет FAIL.
Статус `info` — не ошибка: необязательное отсутствует (версии реестра с `legacy = true`, лишние ключи
machine.toml, symlink'и в engines/ и builds/ — репозиторий самодостаточен, ссылок наружу в нём нет). Обязательны версия движка по умолчанию и версии без legacy.
Без --probe движок не запускается вовсе: стоковый exe проверяется ключом `--version` (без окна: CREATE_NO_WINDOW,
движок печатает версию и выходит до создания окна), F2F — образом (какие ключи F2F знает сборка) и последним
`hello` этой сборки из данных демона (state\\engine_hello.json, по sha256). `--probe` — настоящий `hello.version`:
аренда `vc engine --param engine=<id>` на демоне (--daemon P — изолированный), hello, release. Тестовая сборка
запускается только так — арендой в режиме --f2f (ввод ОС изолирован, окно hidden), как требует политика."""
import json
import os
import shutil
import socket
import subprocess
import sys
import time

from vclab import config, engines, machine, policy

DOC = "install/doctor.md"
OK, WARN, FAIL, INFO = "ok", "warn", "FAIL", "info"
PY_MODULES = ("win32api", "win32job", "psutil", "fastapi", "uvicorn", "numpy", "PIL", "jinja2")
NO_WINDOW = 0x08000000


class Report:
    def __init__(self):
        self.rows = []

    def add(self, group, check, status, detail="", fix=""):
        self.rows.append({"group": group, "check": check, "status": status, "detail": detail,
                          "fix": ("%s#%s" % (DOC, fix)) if fix else ""})

    def worst(self):
        st = [r["status"] for r in self.rows]
        return FAIL if FAIL in st else (WARN if WARN in st else OK)

    def table(self):
        w = max([len(r["group"] + " " + r["check"]) for r in self.rows] + [10])
        out = ["%-*s  %-4s  %s" % (w, "check", "st", "detail / fix")]
        for r in self.rows:
            line = "%-*s  %-4s  %s" % (w, r["group"] + " " + r["check"], r["status"], r["detail"])
            if r["status"] not in (OK, INFO) and r["fix"]:
                line += "  -> " + r["fix"]
            out.append(line)
        n = {s: sum(1 for r in self.rows if r["status"] == s) for s in (OK, WARN, FAIL, INFO)}
        out.append("total: %d ok, %d warn, %d FAIL, %d info (machine.toml: %s)" % (
            n[OK], n[WARN], n[FAIL], n[INFO], machine.load().get("_path")))
        return "\n".join(out)


def _run(argv, timeout=15.0):
    try:
        r = subprocess.run(argv, capture_output=True, timeout=timeout, creationflags=NO_WINDOW if os.name == "nt" else 0)
        out = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
        return r.returncode, out
    except subprocess.TimeoutExpired:
        return None, "timeout %.0f s" % timeout
    except OSError as exc:
        return None, str(exc)


def _short(sha):
    return (sha or "")[:12]


def check_machine(rep, m):
    if not m.get("_found"):
        rep.add("machine", "machine.toml", FAIL, "not found: %s" % m.get("_path"), "machine-toml")
        return
    rep.add("machine", "machine.toml", OK, m["_path"])
    for key, (required, desc) in machine.KEYS.items():
        v = m.get(key)
        if not v:
            if required:
                rep.add("machine", key, FAIL, "missing: " + desc, "machine-toml")
            continue
        if key in ("engines_root", "builds_root"):
            rep.add("machine", key, OK if os.path.isdir(v) else FAIL, v, "roots")
        elif key == "work_root":
            if os.path.isdir(v):
                rep.add("machine", key, OK, v)
            else:
                parent = os.path.dirname(v.rstrip("\\/"))
                rep.add("machine", key, WARN if os.path.isdir(parent) else FAIL,
                        "%s (absent; the daemon creates it)" % v if os.path.isdir(parent) else "%s: parent missing" % v,
                        "roots")
    extra = sorted(k for k, v in m.items() if not k.startswith("_") and k not in machine.KEYS and k != "engines")
    if extra:
        rep.add("machine", "unknown keys", INFO, "ignored: %s (not in vclab/machine.py KEYS)" % ", ".join(extra),
                "machine-toml")


def check_links(rep):
    """Битые ссылки в engines/ и builds/ репозитория — снимок машины-источника (WSL-symlink на её каталоги): info."""
    broken = []
    for base in ("engines", "builds"):
        top = os.path.join(config.REPO_ROOT, base)
        try:
            names = os.listdir(top)
        except OSError:
            continue
        cands = [os.path.join(top, n) for n in names]
        for c in list(cands):
            if os.path.isdir(c) and not os.path.islink(c):
                try:
                    cands += [os.path.join(c, n) for n in os.listdir(c)]
                except OSError:
                    pass
        for c in cands:
            try:
                st = os.lstat(c)
            except OSError:
                continue
            if os.path.islink(c) or getattr(st, "st_reparse_tag", 0):
                if not os.path.exists(c) or not os.access(c, os.R_OK):
                    broken.append(os.path.relpath(c, config.REPO_ROOT))
                    continue
                try:
                    os.listdir(c) if os.path.isdir(c) else open(c, "rb").close()
                except OSError:
                    broken.append(os.path.relpath(c, config.REPO_ROOT))
    if broken:
        rep.add("repo", "links", WARN, "symlinks/broken links (the repository must not point outside; copy instead): %s" % ", ".join(
            sorted(broken)), "links")


def check_engines(rep, m, only=None, hellos=None):
    reg = engines.load_registry()
    res = engines.resolve(reg, m)
    default = res.get("default")
    rep.add("engines", "registry", OK if res else FAIL, "%s; default %s; %s" % (
        os.path.relpath(engines.REGISTRY, config.REPO_ROOT), default,
        ", ".join(k for k in res if k != "default")), "engines")
    for eid, e in res.items():
        if eid == "default" or (only and eid not in only):
            continue
        g = "engine " + eid
        if e.get("legacy") and eid != default and not only:
            # легаси-версия (снимок машины-источника): есть — проверяем как обычно, нет — info
            have = [x for x in (e.get("stock"), (e.get("builds") or {}).get("f2f")) if x and os.path.isfile(x)]
            if not have:
                rep.add(g, "legacy", INFO, "not installed (legacy = true in registry: only the source machine "
                        "snapshot needs it)", "legacy")
                continue
            sub = Report()
            _check_engine(sub, g, e, hellos)
            for r in sub.rows:
                if r["status"] != OK:
                    r["status"], r["detail"] = INFO, "legacy: " + r["detail"]
            rep.rows += sub.rows
            continue
        _check_engine(rep, g, e, hellos)
    return res


def _check_engine(rep, g, e, hellos):
    if not e.get("root") or not os.path.isdir(e["root"]):
        rep.add(g, "root", FAIL, e.get("root") or "engines_root not set", "engine-stock")
    else:
        rep.add(g, "root", OK, e["root"])
    stock = e.get("stock")
    if stock and os.path.isfile(stock):
        sha = policy.file_sha(stock)
        want = e.get("stock_sha256")
        st = OK if not want or sha == want else WARN
        code, out = _run([stock, "--version"], 15)
        lines = [x.strip() for x in out.splitlines()]
        plain = [x for x in lines if x and not x.startswith("[")]              # строки лога движка — с «[I] ...»
        build = [x.split("build:", 1)[1].strip() for x in lines if "build:" in x]
        ver = ("%s%s" % (plain[-1] if plain else "?", (" (build %s)" % build[0]) if build and build[0] else "")
               if code == 0 else "--version failed (%s): %s" % (code, out[:80]))
        if code != 0:
            st = FAIL
        rep.add(g, "stock", st, "%s  sha %s%s  version %s" % (
            stock, _short(sha), "" if not want or sha == want else " (registry %s)" % _short(want), ver),
            "engine-stock")
    else:
        rep.add(g, "stock", FAIL, "missing: %s" % (stock or "-"), "engine-stock")
    vct = (e.get("builds") or {}).get("vctest")
    if e.get("vctest_exe"):
        rep.add(g, "vctest", OK if vct and os.path.isfile(vct) else WARN, vct or "-", "engine-stock")
    f2f = (e.get("builds") or {}).get("f2f")
    if f2f and os.path.isfile(f2f):
        sha = policy.file_sha(f2f)
        want = e.get("f2f_sha256")
        caps = policy.exe_caps(f2f)
        keys = ",".join(k.replace("--f2f", "f2f") or "f2f" for k, v in caps.items() if v) or "no f2f keys"
        h = (hellos or {}).get(sha) or {}
        hv = h.get("version")
        st = OK
        notes = []
        if want and sha != want:
            st = WARN
            notes.append("registry sha %s" % _short(want))
        if not caps.get("--f2f"):
            st = FAIL
            notes.append("not an F2F build")
        if hv and hv != e.get("f2f_version"):
            st = FAIL
            notes.append("hello.version %s != %s" % (hv, e.get("f2f_version")))
        hello = ("last hello %s %s" % (hv, h.get("build") or "")) if hv else "hello: not seen (lab doctor --probe)"
        rep.add(g, "f2f", st, "%s  sha %s  keys %s  want %s; %s%s" % (
            f2f, _short(sha), keys, e.get("f2f_version"), hello, ("; " + "; ".join(notes)) if notes else ""),
            "engine-f2f")
    else:
        rep.add(g, "f2f", FAIL, "missing: %s (patch %s)" % (f2f or "builds_root not set", e.get("f2f_patch")),
                "engine-f2f")


def check_python(rep, m):
    v = sys.version_info
    rep.add("python", "win", OK if v >= (3, 11) else FAIL, "%s %d.%d.%d" % (sys.executable, v[0], v[1], v[2]),
            "python")
    if m.get("python_win") and os.path.normcase(os.path.abspath(m["python_win"])) != \
            os.path.normcase(os.path.abspath(sys.executable)) and os.name == "nt":
        rep.add("python", "win (machine.toml)", WARN, "doctor runs on %s, machine.toml says %s" % (
            sys.executable, m["python_win"]), "python")
    miss = []
    for mod in PY_MODULES:
        try:
            __import__(mod)
        except Exception:
            miss.append(mod)
    rep.add("python", "modules", FAIL if miss else OK, ("missing: " + ", ".join(miss)) if miss else
            ", ".join(PY_MODULES), "python")
    try:
        import pytest  # noqa: F401
        rep.add("python", "pytest", OK, "pytest " + pytest.__version__)
    except Exception:
        rep.add("python", "pytest", WARN, "missing (tests only)", "python")
    pw = m.get("python_wsl")
    if pw and os.name == "nt":
        code, out = _run(["wsl.exe", "-e", pw, "--version"], 20)
        rep.add("python", "wsl", OK if code == 0 else WARN, "%s: %s" % (pw, out[:60]), "python")


def check_tools(rep, m):
    ms = m.get("msys2")
    if ms:
        bash = os.path.join(ms, "usr", "bin", "bash.exe")
        clang = os.path.join(ms, "clang64", "bin", "clang.exe")
        if os.path.isfile(bash):
            rep.add("tools", "msys2", OK if os.path.isfile(clang) else WARN,
                    "%s%s" % (ms, "" if os.path.isfile(clang) else " (no clang64 toolchain: f2f/build/msys_setup.ps1)"),
                    "msys2")
        else:
            rep.add("tools", "msys2", WARN, "not found: %s (only needed to build F2F)" % ms, "msys2")
    cg = m.get("cargo")
    if cg and os.name == "nt":
        code, out = _run(["wsl.exe", "-e", cg, "--version"], 20)
        rep.add("tools", "cargo", OK if code == 0 else WARN, "%s: %s" % (cg, out[:60]), "cargo")


def check_disk(rep, m):
    seen = set()
    for key in ("work_root", "engines_root", "builds_root"):
        v = m.get(key)
        if not v:
            continue
        drive = os.path.splitdrive(v)[0] or v
        if drive in seen:
            continue
        seen.add(drive)
        p = v
        while p and not os.path.exists(p):
            p = os.path.dirname(p.rstrip("\\/"))
        try:
            u = shutil.disk_usage(p)
        except OSError as exc:
            rep.add("disk", drive, WARN, str(exc), "disk")
            continue
        gb = u.free / 1e9
        st = OK if gb >= 5 else (WARN if gb >= 1 else FAIL)
        rep.add("disk", drive, st, "%.1f GB free of %.0f GB (%s)" % (gb, u.total / 1e9, key), "disk")


def check_daemon(rep, port=None):
    from vclab.daemon.client import LabClient
    cfg = config.load()
    port = int(port or cfg["daemon"]["port"])
    c = LabClient(port)
    h = c.alive(1.0)
    if h:
        from vclab.daemon import admin
        want = admin.isolated_data(port) if h.get("isolated") else cfg["daemon"]["data"]
        same = os.path.normcase(h.get("data") or "") == os.path.normcase(want)
        rep.add("daemon", ":%d" % port, OK if same else WARN, "labd pid %s%s, data %s%s" % (
            h.get("pid"), " ISOLATED (starter %s)" % h.get("starter") if h.get("isolated") else "", h.get("data"),
            "" if same else " (another installation's daemon on this port)"), "daemon")
        return h
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
        rep.add("daemon", ":%d" % port, OK, "free (the daemon starts on first `lab` call)")
    except OSError:
        rep.add("daemon", ":%d" % port, FAIL, "busy: something else listens on 127.0.0.1:%d" % port, "daemon")
    finally:
        s.close()
    return None


def engine_hellos(daemon_info=None):
    data = (daemon_info or {}).get("data") or config.load()["daemon"]["data"]
    try:
        with open(os.path.join(data, "state", "engine_hello.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def probe(rep, port, ids):
    """hello.version каждой F2F-сборки — арендой vc.engine на демоне :port (тестовая сборка, --f2f, hidden)."""
    from vclab.daemon.client import LabClient
    c = LabClient(port, owner=os.environ.get("LAB_OWNER") or "doctor")
    if not c.alive(1.0):
        rep.add("probe", ":%d" % port, FAIL, "no labd on :%d (lab daemon start [--isolated])" % port, "daemon")
        return
    for eid in ids:
        t0 = time.time()
        r = c.post("/leases", {"project": "vc", "kind": "engine", "params": {"engine": eid}, "start": True,
                               "ttl": 180}, timeout=180)
        lease = (r.get("lease") or {}).get("name") or r.get("name")
        if not r.get("ok"):
            rep.add("probe", eid, FAIL, "%s: %s" % (r.get("error"), (r.get("message") or "")[:160]), "engine-f2f")
            if lease:
                c.post("/leases/%s/release" % lease, {})
            continue
        try:
            h = c.post("/f2f/%s" % lease, {"cmd": "hello"}, timeout=30)
            res = h.get("result") or {}
            fl = res.get("flags") or {}
            rep.add("probe", eid, OK if h.get("ok") else FAIL, "lease %s: hello.version %s, commit %s, flags %s/%s/%s, "
                    "%.1f s" % (lease, res.get("version"), (res.get("build") or {}).get("commit"), fl.get("clock"),
                                fl.get("input"), fl.get("window"), time.time() - t0), "engine-f2f")
        finally:
            c.post("/leases/%s/release" % lease, {})


def main(argv):
    argv = list(argv)
    as_json = "--json" in argv
    do_probe = "--probe" in argv
    port = None
    if "--daemon" in argv:
        port = int(argv[argv.index("--daemon") + 1])
    only = [argv[i + 1] for i, a in enumerate(argv) if a == "--engine" and i + 1 < len(argv)]
    m = machine.load()
    rep = Report()
    check_machine(rep, m)
    h = check_daemon(rep, port)
    engs = check_engines(rep, m, only, engine_hellos(h))
    check_links(rep)
    check_python(rep, m)
    check_tools(rep, m)
    check_disk(rep, m)
    if do_probe:
        ids = only or [k for k, e in engs.items() if k != "default" and (
            not e.get("legacy") or k == engs.get("default") or os.path.isfile((e.get("builds") or {}).get("f2f") or ""))]
        probe(rep, int(port or config.load()["daemon"]["port"]), ids)
    if as_json:
        print(json.dumps({"ok": rep.worst() != FAIL, "worst": rep.worst(), "rows": rep.rows}, ensure_ascii=False,
                         indent=1))
    else:
        print(rep.table())
    return 1 if rep.worst() == FAIL else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
