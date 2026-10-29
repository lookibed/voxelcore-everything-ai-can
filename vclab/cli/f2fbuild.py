"""lab f2f build|verify|release|recipe — сборка тестовой сборки F2F по рецепту релиза и сверка со стоком (f2f/README.md).

  lab f2f recipe  <id>                                   параметры рецепта: registry + machine.toml, что есть на диске
  lab f2f build   <id> [--src DIR] [--vcpkg DIR] [--configure auto|always|never] [--out EXE] [--allow-busy]
                       [--no-verify] [--force]          configure (если нужно) + build в <src>\\build-mingw, копия exe
                                                         в {builds_root}\\<каталог f2f_exe>\\VoxelCoreF2F-<ver>-<sha8>.exe,
                                                         затем verify
  lab f2f verify  <id> --exe EXE [--prev EXE] [--report PATH]   сверка со стоком той же версии + F2F-проверка -> отчёт
  lab f2f release <id> [--exe EXE] [--report MD] [--repo OWNER/NAME] [--publish]   GitHub Release (по умолчанию dry-run)

Без демона: сборка — MSYS2 CLANG64 ({machine.msys2}), сверка — прямые запуски exe:
  * сток той же версии — только `--version` и `--headless --script <env_dump>` (окна нет);
  * F2F — `--headless --script` (дамп) и `--f2f <порт> --f2f-window hidden --f2f-clock virtual` (hello/selftest/кадр
    меню); после hello проверяется hello.flags.input == "isolated" и окно hidden, иначе процесс убивается.
Параметры версии — engines/registry.toml (build_*: база, vcpkg, VC_BUILD_NAME, имя exe, дамп, эталон меню);
пути машины — machine.toml (msys2, builds_root; `[engines.<id>] f2f_src`, `vcpkg`)."""
import datetime
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

from vclab import engines, machine

REPO = machine.REPO_ROOT
RELEASE_REPO = "lookibed/voxelcore-everything-ai-can"


def _opt(argv, name, default=None, flag=False):
    if name not in argv:
        return default
    i = argv.index(name)
    if flag:
        argv.pop(i)
        return True
    argv.pop(i)
    return argv.pop(i)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def msys_path(p):
    """D:\\a\\b -> /d/a/b (MSYS2); уже MSYS/POSIX — как есть."""
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", p)
    if not m:
        return p.replace("\\", "/")
    return "/" + m.group(1).lower() + "/" + m.group(2).replace("\\", "/")


def win_path(p):
    """/mnt/d/a или /d/a -> D:\\a (на Windows-Python пути приходят как есть)."""
    m = re.match(r"^/(?:mnt/)?([a-zA-Z])/(.*)$", p or "")
    return (m.group(1).upper() + ":\\" + m.group(2).replace("/", "\\")) if m else p


def _git(src, *args):
    """git в worktree, созданном из WSL: .git указывает на /mnt/d/... — переводим в D:/... для Windows-git."""
    gd = None
    dotgit = os.path.join(src, ".git")
    if os.path.isfile(dotgit):
        with open(dotgit, encoding="utf-8") as f:
            line = f.read().strip()
        if line.startswith("gitdir: "):
            gd = win_path(line[8:]) if os.name == "nt" else line[8:]
    cmd = ["git", "-c", "safe.directory=*", "-c", "core.autocrlf=input", "-c", "core.filemode=false"]
    cmd += (["--git-dir", gd, "--work-tree", src] if gd else ["-C", src]) + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    return (r.stdout.strip() if r.returncode == 0 else None), r.stderr.strip()


# ----------------------------------------------------------------------------------------------- рецепт
def recipe(eid, src=None, vcpkg=None):
    m = machine.load()
    reg = engines.load_registry()
    e = (reg.get("engines") or {}).get(eid)
    if not isinstance(e, dict):
        raise SystemExit("lab f2f: no engine %r in %s" % (eid, engines.REGISTRY))
    res = engines.resolve(reg, m).get(eid) or {}
    over = (m.get("engines") or {}).get(eid) or {}
    builds_root = m.get("builds_root") or ""
    f2f_exe = e.get("f2f_exe") or ""
    sub = os.path.dirname(f2f_exe.replace("\\", "/"))
    stem = os.path.splitext(os.path.basename(f2f_exe.replace("\\", "/")))[0] or "VoxelCoreF2F-" + eid
    out_dir = "\\".join(x for x in (builds_root.rstrip("\\"), sub.replace("/", "\\")) if x)
    r = {
        "engine": eid, "version": e.get("version"), "f2f_version": e.get("f2f_version"),
        "branch": e.get("f2f_branch"), "branch_commit_registry": e.get("f2f_commit"), "patch": e.get("f2f_patch"),
        "upstream": e.get("build_upstream"), "base": e.get("build_base"),
        "vcpkg_commit": e.get("build_vcpkg_commit"), "vcpkg_since": e.get("build_vcpkg_since"),
        "build_name": e.get("build_name", ""), "recipe_note": e.get("build_recipe_note") or "vcpkg",
        "output": e.get("build_output") or "VoxelCore.exe",
        "env_dump": os.path.join(REPO, *(e.get("build_env_dump") or "f2f/tests/env_dump.lua").split("/")),
        "menu_shot_sha256": e.get("menu_shot_sha256") or "",
        "msys2": m.get("msys2") or "C:\\msys64",
        "src": src or over.get("f2f_src") or "", "vcpkg": vcpkg or over.get("vcpkg") or "",
        "out_dir": out_dir, "out_stem": stem, "logs": (out_dir + "\\logs") if out_dir else "",
        "stock": res.get("stock") or "", "res": res.get("res") or "", "stock_sha256": e.get("stock_sha256") or "",
        "current_f2f": res.get("builds", {}).get("f2f") or "", "current_f2f_sha256": e.get("f2f_sha256") or "",
    }
    return r


def check_recipe(r):
    """-> list[(what, ok, note)] — что есть на диске для сборки."""
    out = []
    out.append(("msys2", os.path.isfile(os.path.join(r["msys2"], "usr", "bin", "bash.exe")), r["msys2"]))
    clang = os.path.join(r["msys2"], "clang64", "bin", "clang.exe")
    out.append(("clang64", os.path.isfile(clang), clang))
    src_ok = bool(r["src"]) and os.path.isdir(os.path.join(r["src"], "src"))
    out.append(("src", src_ok, r["src"] or "machine.toml [engines.%s] f2f_src = '...' (worktree ветки %s)" % (
        r["engine"], r["branch"])))
    if src_ok:
        br, _ = _git(r["src"], "rev-parse", "--abbrev-ref", "HEAD")
        head, _ = _git(r["src"], "rev-parse", "HEAD")
        dirty, _ = _git(r["src"], "status", "--porcelain", "--untracked-files=no")
        out.append(("branch", br == r["branch"], "%s @ %s%s" % (br, (head or "?")[:10],
                                                              ", %d modified" % len(dirty.splitlines()) if dirty else ", clean")))
        r["head"], r["dirty"] = head, bool(dirty)
    vk = r["vcpkg"]
    vk_ok = bool(vk) and os.path.isfile(os.path.join(vk, "scripts", "buildsystems", "vcpkg.cmake"))
    note = vk or "machine.toml [engines.%s] vcpkg = '...' (checkout %s: f2f/build/vcpkg_clone.sh)" % (
        r["engine"], (r["vcpkg_commit"] or "?")[:8])
    if vk_ok:
        vh, _ = _git(vk, "rev-parse", "HEAD")
        ok = bool(vh) and bool(r["vcpkg_commit"]) and vh.startswith(r["vcpkg_commit"][:8])
        out.append(("vcpkg", ok, "%s @ %s (registry %s)" % (vk, (vh or "?")[:10], (r["vcpkg_commit"] or "?")[:10])))
    else:
        out.append(("vcpkg", False, note))
    out.append(("stock", bool(r["stock"]) and os.path.isfile(r["stock"]), r["stock"] or "engines_root/install_dir"))
    out.append(("builds_root", bool(r["out_dir"]) and os.path.isdir(os.path.dirname(r["out_dir"]) or r["out_dir"]),
                r["out_dir"]))
    return out


# ----------------------------------------------------------------------------------------------- сборка
def _cpu_busy():
    """Тяжёлая сборка — только на незанятом ПК: CPU чужих процессов и активный пользователь (GPU сборке не мешает)."""
    try:
        from vclab.quality import sysload
    except Exception as e:                 # psutil нет — не блокируем, но говорим
        return ["sysload unavailable: %s" % e]
    s = sysload.sample(2.0, with_gpu=False)
    f = sysload.flags(dict(s, gpu=[]))
    return [x for x in f["reasons"] if not x.startswith("GPU")]


def run_step(r, step, log):
    env = dict(os.environ, MSYSTEM="CLANG64", CHERE_INVOKING="1",
               SRC=msys_path(r["src"]), VCPKG_ROOT=msys_path(r["vcpkg"]), BUILD_NAME=r["build_name"],
               RECIPE_NOTE=r["recipe_note"], VCPKG_MAX_CONCURRENCY="4")
    script = msys_path(os.path.join(REPO, "f2f", "build", "build_mingw.sh"))
    bash = os.path.join(r["msys2"], "usr", "bin", "bash.exe")
    t0 = time.time()
    with open(log, "a", encoding="utf-8") as f:
        f.write("START %s %s\n" % (step, datetime.datetime.now().isoformat(timespec="seconds")))
        f.flush()
        p = subprocess.run([bash, "-lc", "bash '%s' %s" % (script, step)], stdout=f, stderr=subprocess.STDOUT,
                           env=env, cwd=r["src"])
        f.write("END %s rc=%s %.0f s\n" % (step, p.returncode, time.time() - t0))
    return p.returncode, round(time.time() - t0, 1)


def build(eid, argv):
    src = _opt(argv, "--src")
    vk = _opt(argv, "--vcpkg")
    conf = _opt(argv, "--configure", "auto")
    out = _opt(argv, "--out")
    allow_busy = _opt(argv, "--allow-busy", flag=True)
    no_verify = _opt(argv, "--no-verify", flag=True)
    force = _opt(argv, "--force", flag=True)
    r = recipe(eid, win_path(src) if src else None, win_path(vk) if vk else None)
    checks = check_recipe(r)
    bad = [c for c in checks if not c[1] and c[0] in ("msys2", "clang64", "src", "vcpkg")]
    if bad and not (force and all(c[0] == "branch" for c in bad)):
        print(json.dumps({"ok": False, "error": "recipe incomplete", "checks": checks}, ensure_ascii=False, indent=1))
        return 2
    if not allow_busy:
        busy = _cpu_busy()
        if busy:
            print(json.dumps({"ok": False, "error": "PC is busy (build waits for an idle PC; --allow-busy to override)",
                              "reasons": busy}, ensure_ascii=False))
            return 3
    os.makedirs(r["logs"], exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    log = os.path.join(r["logs"], "f2f_build_%s_%s.log" % (eid, stamp))
    bdir = os.path.join(r["src"], "build-mingw")
    times = {}
    print("lab f2f build %s: src %s (%s), vcpkg %s, log %s" % (
        eid, r["src"], (r.get("head") or "?")[:10], r["vcpkg"], log), flush=True)
    if conf == "always" or (conf == "auto" and not os.path.isfile(os.path.join(bdir, "CMakeCache.txt"))):
        print("configure ...", flush=True)
        rc, times["configure_s"] = run_step(r, "configure", log)
        if rc:
            print(json.dumps({"ok": False, "error": "configure failed rc=%s" % rc, "log": log}))
            return 1
    print("build ...", flush=True)
    rc, times["build_s"] = run_step(r, "build", log)
    if rc:
        print(json.dumps({"ok": False, "error": "build failed rc=%s" % rc, "log": log, "times": times}))
        return 1
    built = os.path.join(bdir, r["output"])
    head = r.get("head") or ""
    target = out or os.path.join(r["out_dir"], "%s-%s.exe" % (r["out_stem"], head[:8] or stamp))
    if os.path.abspath(target).lower() == os.path.abspath(r["current_f2f"] or "-").lower():
        print(json.dumps({"ok": False, "error": "refusing to overwrite the registered F2F exe %s (live leases use it); "
                                                "pass another --out" % target}))
        return 2
    shutil.copy2(built, target)
    res = {"ok": True, "engine": eid, "exe": target, "sha256": sha256(target), "size": os.path.getsize(target),
           "branch_head": head, "dirty": r.get("dirty"), "times": times, "log": log}
    print(json.dumps(res, ensure_ascii=False, indent=1), flush=True)
    with open(target + ".build.json", "w", encoding="utf-8") as f:       # для verify/release без повторной сборки
        json.dump(res, f, ensure_ascii=False, indent=1)
    if no_verify:
        return 0
    return verify(eid, ["--exe", target], build_info=res)


# ----------------------------------------------------------------------------------------------- PE: секции, импорт, строки
def pe_info(path):
    data = open(path, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96)
    imp_rva = struct.unpack_from("<I", data, dd + 8)[0]
    secs = []
    so = opt + opt_size
    for i in range(nsec):
        name = data[so + 40 * i: so + 40 * i + 8].rstrip(b"\0").decode("ascii", "replace")
        vsize, va, rsize, raw = struct.unpack_from("<IIII", data, so + 40 * i + 8)
        secs.append((name, vsize, va, rsize, raw))

    def off(rva):
        for _n, vs, va, rs, raw in secs:
            if va <= rva < va + max(vs, rs):
                return raw + rva - va
        raise ValueError("rva %x" % rva)

    def cstr(o):
        return data[o:data.index(b"\0", o)].decode("ascii", "replace")
    imports = {}
    if imp_rva:
        o = off(imp_rva)
        while True:
            oft, _ts, _fc, name_rva, ft = struct.unpack_from("<IIIII", data, o)
            if not name_rva:
                break
            dll = cstr(off(name_rva))
            fns = []
            t = off(oft or ft)
            ptr = 8 if magic == 0x20B else 4
            while True:
                v = struct.unpack_from("<Q" if ptr == 8 else "<I", data, t)[0]
                if not v:
                    break
                if v >> (63 if ptr == 8 else 31):
                    fns.append("#%d" % (v & 0xFFFF))
                else:
                    fns.append(cstr(off(v & 0x7FFFFFFF) + 2))
                t += ptr
            imports[dll] = sorted(fns)
            o += 20
    pats = [rb"\d+\.\d+\.\d+ Win32 WGL[ A-Za-z0-9-]*", rb"libpng version [\d.]+", rb"OpenSSL \d+\.\d+\.\d+[a-z]? +\d+ \w+ \d{4}",
            rb"CLIENT libcurl [\d.]+", rb"LuaJIT 2\.1\.\d+", rb"llvm-project-\d+\.\d+\.\d+", rb"FreeType [\d.]+"]
    strings = sorted({m.group(0).decode("ascii") for p in pats for m in re.finditer(p, data)})
    dlls = sorted(imports, key=str.lower)
    fn = sorted("%s!%s" % (d.lower(), f) for d in imports for f in imports[d])
    md5 = lambda xs: hashlib.md5("\n".join(xs).encode()).hexdigest()   # noqa: E731
    return {"size": len(data), "sections": {n: vs for n, vs, *_ in secs},
            "debug_sections": [n for n, *_ in secs if n.startswith(".debug") or n.startswith("/")],
            "dlls": dlls, "dlls_md5": md5([d.lower() for d in dlls]), "functions": fn, "functions_md5": md5(fn),
            "strings": strings, "strings_md5": md5(strings)}


# ----------------------------------------------------------------------------------------------- запуски
def _run(argv, cwd, timeout=120):
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        return "timeout", (e.stdout or b"").decode("utf-8", "replace"), ""


def version_of(exe):
    rc, out, _ = _run([exe, "--headless", "--version"], os.path.dirname(exe), 30)
    lines = [x.strip() for x in out.splitlines() if x.strip()]
    return lines[-1] if lines else "rc=%s" % rc


def env_dump(exe, res, script, tmp):
    d = tempfile.mkdtemp(prefix="envdump_", dir=tmp)
    rc, out, err = _run([exe, "--headless", "--res", res, "--dir", d, "--script", script], os.path.dirname(exe), 180)
    lines = [x.rstrip("\r") for x in out.splitlines()]
    env = [x for x in lines if x.startswith("[env] ")]
    hdr = {}
    for x in lines:
        m = re.search(r"\] build: (.*)$", x)
        if m and "build" not in hdr:
            hdr["build"] = m.group(1).strip()
        m = re.search(r"engine version: (.*)$", x)
        if m:
            hdr["engine_version"] = m.group(1).strip()
    norm = "\n".join(env) + "\n"
    jit = next((x.split("=", 1)[1].split(" arch=")[0] for x in env if x.startswith("[env] jit.version=")), None)
    return {"rc": rc, "lines": len(env), "sha256": hashlib.sha256(norm.encode()).hexdigest(), "jit": jit,
            "header": hdr, "text": norm}


def without_f2f(text):
    """Дамп F2F минус глобальный `f2f` (5 функций) — должно совпасть со стоком побайтно."""
    out, removed = [], []
    for x in text.splitlines():
        m = re.match(r"^\[env\] globals\((\d+)\)=(.*)$", x)
        if m:
            toks = m.group(2).split(" ")
            if "f2f:table" in toks:
                toks.remove("f2f:table")
                removed.append("globals: f2f:table")
            x = "[env] globals(%d)=%s" % (len(toks), " ".join(toks))
        elif x.startswith("[env] f2f("):
            removed.append(x[6:])
            continue
        out.append(x)
    return "\n".join(out) + "\n", removed


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def f2f_probe(exe, res, tmp, f2f_version, menu_sha):
    """hello (версия, флаги изоляции) -> selftest -> mode/step/shot меню -> quit. Флаги не те — процесс убит."""
    from vclab.f2f import F2FConn
    d = tempfile.mkdtemp(prefix="f2fprobe_", dir=tmp)
    port = _free_port()
    argv = [exe, "--f2f", str(port), "--f2f-size", "854x480", "--f2f-clock", "virtual", "--f2f-window", "hidden",
            "--res", res, "--dir", d]
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    p = subprocess.Popen(argv, cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=flags)
    out = {"argv": " ".join(argv[1:]), "port": port}
    c = F2FConn(port)
    try:
        h = c.call("hello", {}, timeout=60, connect_timeout=90, alive=lambda: p.poll() is None)
        hello = h.get("result") or {}
        fl = hello.get("flags") or {}
        out["hello"] = {k: hello.get(k) for k in ("impl", "version", "w", "h", "screen", "flags", "build", "gl")}
        iso_ok = fl.get("input") == "isolated" and fl.get("window") == "hidden" and fl.get("clock") == "virtual"
        out["isolation_ok"] = iso_ok
        out["version_ok"] = hello.get("version") == f2f_version
        if not iso_ok:
            p.kill()
            out["killed"] = "isolation-failed: flags %s" % fl
            return out
        st = c.call("selftest", {}, timeout=30).get("result") or {}
        th = c.call("selftest", {"throw": True}, timeout=30)
        out["selftest"] = {
            "cp1251": st.get("cp1251"), "emoji_kept": st.get("emoji") == "\U0001F600", "broken": st.get("broken"),
            "control": st.get("control"), "valid": st.get("valid"), "ansi_code_page": st.get("ansi_code_page"),
            "throw": {"ok": th.get("ok"), "error": th.get("error")}}
        out["selftest_ok"] = (st.get("cp1251") == "Ошибка" and st.get("emoji") == "\U0001F600"
                              and th.get("ok") is False and "Ошибка" in (th.get("error") or ""))
        c.call("mode", {"fixed": True, "seed": 12345}, timeout=30)
        c.call("step", {"ticks": 40, "frames": 40}, timeout=120)
        shot = os.path.join(d, "menu.png")
        s = c.call("shot", {"path": shot}, timeout=60).get("result") or {}
        out["menu_shot"] = {"w": s.get("w"), "h": s.get("h"), "sha256": s.get("sha256")}
        out["menu_ok"] = (s.get("sha256") == menu_sha) if menu_sha else None
        c.call("quit", {}, timeout=10)
        try:
            p.wait(15)
        except subprocess.TimeoutExpired:
            p.kill()
        out["exit"] = p.poll()
    except Exception as e:                          # noqa: BLE001 — отчёт, не падение
        out["error"] = "%s: %s" % (type(e).__name__, e)
    finally:
        c.close()
        if p.poll() is None:
            p.kill()
            p.wait(10)
    return out


# ----------------------------------------------------------------------------------------------- verify + отчёт
def verify(eid, argv, build_info=None):
    exe = win_path(_opt(argv, "--exe") or "")
    prev = _opt(argv, "--prev")
    report = _opt(argv, "--report")
    r = recipe(eid)
    check_recipe(r)
    if not exe or not os.path.isfile(exe):
        print(json.dumps({"ok": False, "error": "--exe: no file %r" % exe}))
        return 2
    if build_info is None and os.path.isfile(exe + ".build.json"):
        with open(exe + ".build.json", encoding="utf-8") as f:
            build_info = json.load(f)
    prev = win_path(prev) if prev else (r["current_f2f"] if r["current_f2f"] and os.path.isfile(r["current_f2f"])
                                         and os.path.abspath(r["current_f2f"]) != os.path.abspath(exe) else None)
    stock = r["stock"]
    tmp = tempfile.mkdtemp(prefix="f2fverify_%s_" % eid)
    try:
        cols = [("stock", stock)] + ([("prev_f2f", prev)] if prev else []) + [("new_f2f", exe)]
        info = {}
        for name, p in cols:
            print("verify %s: %s" % (name, p), flush=True)
            i = {"path": p, "sha256": sha256(p), "pe": pe_info(p), "version": version_of(p),
                 "env": env_dump(p, r["res"], r["env_dump"], tmp)}
            info[name] = i
        print("verify new_f2f: F2F probe (hidden, virtual clock)", flush=True)
        probe = f2f_probe(exe, r["res"], tmp, r["f2f_version"], r["menu_shot_sha256"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    s, n = info["stock"], info["new_f2f"]
    n_wo, removed = without_f2f(n["env"]["text"])
    eq = {
        "version": s["version"] == n["version"],
        "build_header": s["env"]["header"].get("build") == n["env"]["header"].get("build"),
        "jit": s["env"]["jit"] == n["env"]["jit"],
        "env_minus_f2f": hashlib.sha256(n_wo.encode()).hexdigest() == s["env"]["sha256"],
        "dlls": s["pe"]["dlls_md5"] == n["pe"]["dlls_md5"],
        "strings": s["pe"]["strings_md5"] == n["pe"]["strings_md5"],
        "stock_sha256_registry": s["sha256"] == r["stock_sha256"],
    }
    fn_s, fn_n = set(s["pe"]["functions"]), set(n["pe"]["functions"])
    extra_fn, missing_fn = sorted(fn_n - fn_s), sorted(fn_s - fn_n)
    for name in info:
        if name != "stock":
            wo, _ = without_f2f(info[name]["env"]["text"])
            info[name]["env"]["minus_f2f_eq_stock"] = hashlib.sha256(wo.encode()).hexdigest() == s["env"]["sha256"]
    if "prev_f2f" in info:
        a, b = open(info["prev_f2f"]["path"], "rb").read(), open(exe, "rb").read()
        res_prev = {"same_size": len(a) == len(b),
                    "bytes_differ": sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))}
    else:
        res_prev = None
    passed = (all(v for k, v in eq.items()) and probe.get("isolation_ok") and probe.get("version_ok")
              and probe.get("selftest_ok") and probe.get("menu_ok") is not False and not probe.get("error"))
    res = {"ok": bool(passed), "engine": eid, "exe": exe, "sha256": n["sha256"], "equivalence": eq,
           "env_removed": removed, "imports_extra_in_f2f": extra_fn, "imports_missing_in_f2f": missing_fn,
           "probe": probe, "vs_prev_f2f": res_prev}
    date = datetime.date.today().isoformat()
    report = report or os.path.join(REPO, "f2f", "reports", "%s-%s.md" % (eid, date))
    os.makedirs(os.path.dirname(report), exist_ok=True)
    with open(report, "w", encoding="utf-8", newline="\n") as f:
        f.write(render_report(eid, r, info, probe, res, build_info))
    res["report"] = report
    print(json.dumps({k: v for k, v in res.items()}, ensure_ascii=False, indent=1))
    return 0 if passed else 1


def _short(h, n=16):
    return (h or "")[:n] + ("…" if h and len(h) > n else "")


def neutral(text, r):
    """Пути этой машины в отчёте (он в git) -> {machine.*} / {f2f_src} / {vcpkg}."""
    m = machine.load()
    subs = [(r.get("src"), "{f2f_src}"), (r.get("vcpkg"), "{vcpkg}"), (REPO, "<repo>")]
    subs += [(m.get(k), "{machine.%s}" % k) for k in ("builds_root", "engines_root", "work_root")]
    for a, b in sorted(((a, b) for a, b in subs if a), key=lambda x: -len(x[0])):
        text = re.sub(re.escape(a.rstrip("\\")), lambda _m: b, text, flags=re.I)
    return text


def render_report(eid, r, info, probe, res, build_info):
    return neutral(_render_report(eid, r, info, probe, res, build_info), r)


def _render_report(eid, r, info, probe, res, build_info):
    cols = list(info)
    L = []
    w = L.append
    hv = (probe.get("hello") or {})
    hb = hv.get("build") or {}
    w("# F2F %s (%s): сборка по рецепту и сверка со стоком — %s" % (eid, r["f2f_version"], datetime.date.today()))
    w("")
    w("Сгенерировано `lab f2f verify %s` (vclab/cli/f2fbuild.py). Вердикт: **%s**." % (eid, "OK" if res["ok"] else "FAIL"))
    w("")
    w("## Сборка")
    w("| что | значение |")
    w("|---|---|")
    w("| ветка | `%s` @ `%s` (%s) |" % (r["branch"], (build_info or {}).get("branch_head", "")[:10] or hb.get("commit", "?"),
                                      r["src"] or "-"))
    w("| база патча | `%s` (`git diff %s %s` = `%s`) |" % (r["base"], r["base"], r["branch"], r["patch"]))
    w("| рецепт | MSYS2 CLANG64, %s, `x64-mingw-static`, MinGW Makefiles, Release, `-j4`, `VC_BUILD_NAME=\"%s\"` |" % (
        r["recipe_note"], r["build_name"]))
    w("| vcpkg | `%s` (%s) |" % (r["vcpkg_commit"], r["vcpkg"] or "-"))
    if build_info:
        t = build_info.get("times") or {}
        w("| время | %s |" % ", ".join("%s %s с" % (k.replace("_s", ""), v) for k, v in t.items()))
        w("| лог | `%s` |" % build_info.get("log"))
    w("| exe | `%s`, %d байт, sha256 `%s` |" % (res["exe"], info["new_f2f"]["pe"]["size"], res["sha256"]))
    w("")
    w("## Эквивалентность со стоком %s" % r["version"])
    w("| проверка | " + " | ".join("%s (`%s`)" % (c, _short(info[c]["sha256"], 8)) for c in cols) + " | равно стоку |")
    w("|---|" + "---|" * (len(cols) + 1))

    def row(name, f, key=None):
        vals = [f(info[c]) for c in cols]
        w("| %s | %s | %s |" % (name, " | ".join(str(v) for v in vals), "" if key is None else
                                ("да" if res["equivalence"].get(key) else "**нет**")))
    row("`--version`", lambda i: "`%s`" % i["version"], "version")
    row("лог `build:`", lambda i: "`%s`" % i["env"]["header"].get("build"), "build_header")
    row("`jit.version`", lambda i: "`%s`" % i["env"]["jit"], "jit")
    row("дамп окружения (`%s`), строк / sha256" % os.path.relpath(r["env_dump"], REPO).replace("\\", "/"),
        lambda i: "%d / `%s`" % (i["env"]["lines"], _short(i["env"]["sha256"])), None)
    row("дамп минус глобальный `f2f` = сток", lambda i: "—" if "minus_f2f_eq_stock" not in i["env"] else
        ("да" if i["env"]["minus_f2f_eq_stock"] else "**нет**"), "env_minus_f2f")
    row("строки библиотек (md5 набора)", lambda i: "`%s`" % i["pe"]["strings_md5"][:8], "strings")
    row("импортируемые DLL (число, md5)", lambda i: "%d, `%s`" % (len(i["pe"]["dlls"]), i["pe"]["dlls_md5"][:8]), "dlls")
    row("импортируемые функции (число, md5)", lambda i: "%d, `%s`" % (len(i["pe"]["functions"]),
                                                                     i["pe"]["functions_md5"][:8]), None)
    row("размер / `.text` / `.rdata`", lambda i: "%d / %s / %s" % (i["pe"]["size"], i["pe"]["sections"].get(".text"),
                                                                 i["pe"]["sections"].get(".rdata")), None)
    row("секции `.debug*`", lambda i: ", ".join(i["pe"]["debug_sections"]) or "нет", None)
    w("")
    if res.get("vs_prev_f2f"):
        vp = res["vs_prev_f2f"]
        w("Новая F2F против прежней (`%s`): размер %s, отличается байт: %d." % (
            os.path.basename(info["prev_f2f"]["path"]), "тот же" if vp["same_size"] else "**другой**", vp["bytes_differ"]))
    w("Глобальный `f2f` в дампе F2F: %s." % "; ".join("`%s`" % x for x in res["env_removed"]))
    w("Строки библиотек стока: %s." % ", ".join("`%s`" % x for x in info["stock"]["pe"]["strings"]))
    if res["imports_extra_in_f2f"] or res["imports_missing_in_f2f"]:
        w("Импорт F2F против стока: лишние %s; нет %s." % (
            ", ".join("`%s`" % x for x in res["imports_extra_in_f2f"]) or "—",
            ", ".join("`%s`" % x for x in res["imports_missing_in_f2f"]) or "—"))
    w("Стоковый exe = реестр (`stock_sha256`): %s." % ("да" if res["equivalence"]["stock_sha256_registry"] else "**нет**"))
    w("Побайтно сборка с артефактом не совпадает и не должна (другой снимок MSYS2, путь исходников, F2F-код).")
    w("")
    w("## F2F-проверка (новая сборка, `--f2f-window hidden --f2f-clock virtual`, 854×480)")
    w("| проверка | результат |")
    w("|---|---|")
    w("| `hello.version` | `%s` (ожидается `%s`) — %s |" % (hv.get("version"), r["f2f_version"],
                                                           "да" if probe.get("version_ok") else "**нет**"))
    w("| `hello.flags` | `%s` — %s |" % (json.dumps(hv.get("flags"), ensure_ascii=False),
                                       "изолировано" if probe.get("isolation_ok") else "**НЕ изолировано, убит**"))
    hf = hb.get("flags") or {}
    w("| `hello.build` | commit `%s`, dirty `%s`; %s; `%s` |" % (hb.get("commit"), hb.get("dirty"), hf.get("compiler"),
                                                                 hf.get("recipe")))
    w("| `hello.gl` | %s |" % ((hv.get("gl") or {}).get("renderer")))
    st = probe.get("selftest") or {}
    w("| `selftest` | cp1251 → `%s`, emoji %s, broken `%s`, throw → `%s` — %s |" % (
        st.get("cp1251"), "сохранён" if st.get("emoji_kept") else "**потерян**", st.get("broken"),
        (st.get("throw") or {}).get("error"), "да" if probe.get("selftest_ok") else "**нет**"))
    ms = probe.get("menu_shot") or {}
    w("| меню `mode{fixed, seed 12345}` + `step{40,40}` + `shot` | %s×%s `%s` (эталон `%s`) — %s |" % (
        ms.get("w"), ms.get("h"), _short(ms.get("sha256")), _short(r["menu_shot_sha256"]) or "—",
        {True: "да", False: "**нет**", None: "эталона нет"}[probe.get("menu_ok")]))
    if probe.get("error"):
        w("| ошибка | `%s` |" % probe["error"])
    w("")
    return "\n".join(L) + "\n"


# ----------------------------------------------------------------------------------------------- release
def release(eid, argv):
    exe = _opt(argv, "--exe")
    rep = _opt(argv, "--report")
    repo = _opt(argv, "--repo", RELEASE_REPO)
    publish = _opt(argv, "--publish", flag=True)
    r = recipe(eid)
    check_recipe(r)
    head = (r.get("head") or r["branch_commit_registry"] or "")[:8]
    exe = win_path(exe) if exe else os.path.join(r["out_dir"], "%s-%s.exe" % (r["out_stem"], head))
    if not rep:
        d = os.path.join(REPO, "f2f", "reports")
        cands = sorted(x for x in (os.listdir(d) if os.path.isdir(d) else []) if x.startswith(eid + "-") and x.endswith(".md"))
        rep = os.path.join(d, cands[-1]) if cands else ""
    patch = os.path.join(REPO, *(r["patch"] or "").split("/")) if r["patch"] else ""
    tag = "f2f-%s-%s" % (eid, head)
    assets, missing = [], []
    for p in (exe, rep, patch):
        if p and os.path.isfile(p):
            assets.append({"path": p, "name": os.path.basename(p), "size": os.path.getsize(p), "sha256": sha256(p)})
        else:
            missing.append(p or "?")
    title = "F2F test build %s (%s, branch %s @ %s)" % (r["f2f_version"], eid, r["branch"], head)
    cmd = ["gh", "release", "create", tag, "--repo", repo, "--title", title, "--notes-file",
           rep or "<report>", "--target", "main"] + [a["path"] for a in assets]
    out = {"ok": not missing, "dry_run": not publish, "tag": tag, "repo": repo, "title": title, "assets": assets,
           "total_bytes": sum(a["size"] for a in assets), "missing": missing, "command": cmd}
    if missing or not publish:
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return 0 if not missing else 2
    if shutil.which("gh"):
        run = cmd
    else:                                   # gh только в WSL: те же аргументы, пути -> /mnt/<диск>/...
        run = ["wsl.exe", "-e"] + [_to_wsl(x) if re.match(r"^[A-Za-z]:[\\/]", x) else x for x in cmd]
    p = subprocess.run(run, capture_output=True, text=True)
    out.update(published=p.returncode == 0, stdout=p.stdout.strip(), stderr=p.stderr.strip()[-2000:])
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0 if p.returncode == 0 else 1


def _to_wsl(p):
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", p or "")
    return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/")) if m else p


# ----------------------------------------------------------------------------------------------- вход
def main(argv):
    """argv = [sub, id, ...] (после `lab f2f`)."""
    argv = list(argv)
    if len(argv) < 2:
        print(__doc__)
        return 2
    sub, eid = argv[0], argv[1]
    rest = argv[2:]
    if sub == "recipe":
        r = recipe(eid)
        checks = check_recipe(r)
        print(json.dumps({"recipe": r, "checks": [{"what": a, "ok": b, "note": c} for a, b, c in checks]},
                         ensure_ascii=False, indent=1))
        return 0
    if sub == "build":
        return build(eid, rest)
    if sub == "verify":
        return verify(eid, rest)
    if sub == "release":
        return release(eid, rest)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
