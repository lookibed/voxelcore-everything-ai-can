"""Engine documentation and sources for agents: VoxelCore docs + the whole source tree, offline, per engine version.

Two roots (bin/fetch_engine_docs.py fills both):
  engines/src/<version>/   the whole text tree of the tag (src/ all C++, res/, doc/) — on disk only, preferred;
  engines/docs/<version>/  the small git copy: doc/, Lua binding sources, res/scripts|layouts|project.
Versions: tags like 0.32.7, 0.32.8 and `main` (a snapshot of upstream main; its commit/date in ORIGIN.md). The DEFAULT
version is the lab's default engine (engines/registry.toml `default`), not the newest — answers about another version
than the one the projects run on were a real source of mistakes.
Tools (registered in voxelcore_mcp.TOOLS):
  vc_docs_search  — substring/regex with file:line and context; scope docs|api|lua|src|all, path prefix
  vc_docs_read    — a file or a line range
  vc_docs_list    — directory listing / available versions (with commit and whether the full tree is there)
  vc_docs_symbol  — where a C++/Lua name is defined (class/struct/function/method, Lua function, Lua binding entry)
                    and where it is used
  vc_docs_diff    — what changed between two versions: changed files (under a path / containing a query) or the
                    unified diff of one file
"""
import difflib
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOT = os.path.join(REPO, "engines", "docs")
SRC_ROOT = os.path.join(REPO, "engines", "src")
TEXT_EXT = (".md", ".cpp", ".hpp", ".h", ".c", ".inl", ".lua", ".xml", ".toml", ".json", ".txt", ".glsl", ".glslv",
            ".glslf", ".cmake", ".vcm", ".vca", ".ini", ".yml", ".yaml")
CODE_EXT = (".cpp", ".hpp", ".h", ".c", ".inl", ".lua", ".glsl", ".glslv", ".glslf")


def _dirs(root):
    return {v for v in os.listdir(root) if os.path.isdir(os.path.join(root, v))} if os.path.isdir(root) else set()


def _vkey(v):
    return (1, ()) if v == "main" else (0, tuple(int(x) if x.isdigit() else 0 for x in v.split(".")))


def versions():
    return sorted(_dirs(ROOT) | _dirs(SRC_ROOT), key=_vkey)


def default_version():
    try:
        from vclab import engines
        reg = engines.load_registry().get("engines") or {}
        v = str((reg.get(reg.get("default") or "") or {}).get("version") or "")
        if v in versions():
            return v
    except Exception:
        pass
    vs = [v for v in versions() if v != "main"]
    return vs[-1] if vs else (versions() or [None])[-1]


def _base(version):
    vs = versions()
    if not vs:
        raise ValueError("no engine docs in %s (run python3 bin/fetch_engine_docs.py --all)" % ROOT)
    v = str(version or default_version()).lstrip("v")
    if v not in vs:
        raise ValueError("no docs for %r; have %s" % (version, vs))
    full = os.path.join(SRC_ROOT, v)
    if os.path.isdir(full):
        return v, full, True
    return v, os.path.join(ROOT, v), False


def origin(v):
    for r in (SRC_ROOT, ROOT):
        p = os.path.join(r, v, "ORIGIN.md")
        if os.path.isfile(p):
            m = re.search(r"\(commit ([0-9a-f]+), ([0-9T:\-Z]+)\)", open(p, encoding="utf8").read())
            if m:
                return "%s %s" % (m.group(1), m.group(2)[:10])
    return ""


def header(v, full):
    o = origin(v)
    return "VoxelCore %s%s%s" % (v, " (%s)" % o if o else "", "" if full else " [docs+Lua bindings only; full tree: "
                                                                             "python3 bin/fetch_engine_docs.py v%s]" % v)


def _safe(base, rel):
    p = os.path.normpath(os.path.join(base, rel or ""))
    if not (p == base or p.startswith(base + os.sep)):
        raise ValueError("path outside the docs: %s" % rel)
    return p


def _scope_dirs(base, scope, lang, path=None):
    if path:
        return [_safe(base, path)]
    if scope == "docs":
        return [os.path.join(base, "doc", lang)]
    if scope == "api":
        return [os.path.join(base, "src", "logic", "scripting", "lua", "libs")]
    if scope == "lua":
        return [os.path.join(base, "res")]
    if scope == "src":
        return [os.path.join(base, "src")]
    return [os.path.join(base, "doc", lang), os.path.join(base, "src"), os.path.join(base, "res")]


_WALK = {}


def _walk(d, exts=TEXT_EXT):
    if os.path.isfile(d):
        return [d]
    key = (d, exts, os.path.getmtime(d) if os.path.isdir(d) else 0)
    if key not in _WALK:
        out = []
        for dirpath, dns, names in os.walk(d):
            dns.sort()
            for n in sorted(names):
                if n.endswith(exts) or n == "CMakeLists.txt":
                    out.append(os.path.join(dirpath, n))
        _WALK[key] = out
    return _WALK[key]


_TREES = {}          # base dir -> (ORIGIN.md mtime, {abs path: lines}): read once per fetch; /mnt/d stat/read per query
                     # cost seconds (the MCP server is long-lived)


_CHECKED = {}         # base -> time of the last ORIGIN.md stat (a stat on /mnt/d costs ~1 ms: once per 10 s, not per file)


def _tree(base):
    import time
    t = _TREES.get(base)
    now = time.time()
    if t is not None and now - _CHECKED.get(base, 0) < 10:
        return t[1]
    _CHECKED[base] = now
    o = os.path.join(base, "ORIGIN.md")
    mt = os.path.getmtime(o) if os.path.isfile(o) else 0
    if t is None or t[0] != mt:
        files = {}
        for dirpath, dns, names in os.walk(base):
            dns.sort()
            for n in sorted(names):
                if n.endswith(TEXT_EXT) or n == "CMakeLists.txt":
                    q = os.path.join(dirpath, n)
                    try:
                        files[q] = open(q, encoding="utf8", errors="replace").read().splitlines()
                    except OSError:
                        pass
        t = (mt, files)
        _TREES[base] = t
    return t[1]


def _base_of(p):
    for root in (SRC_ROOT, ROOT):
        if p.startswith(root + os.sep):
            v = os.path.relpath(p, root).split(os.sep)[0]
            return os.path.join(root, v)
    return None


def _walk(d, exts=TEXT_EXT):
    b = _base_of(d)
    if b is None:
        return []
    files = _tree(b)
    if d in files:
        return [d]
    pre = d.rstrip(os.sep) + os.sep
    return [q for q in files if q.startswith(pre) and (q.endswith(exts) or q.endswith("CMakeLists.txt"))]


def _lines(p):
    b = _base_of(p)
    if b is not None:
        ls = _tree(b).get(p)
        if ls is not None:
            return ls
    try:
        return open(p, encoding="utf8", errors="replace").read().splitlines()
    except OSError:
        return []


def search(query, lang="ru", scope="all", version=None, regex=False, context=1, limit=40, path=None):
    v, base, full = _base(version)
    pat = re.compile(query if regex else re.escape(query), re.IGNORECASE)
    hits, files = [], set()
    for d in _scope_dirs(base, scope, lang, path):
        for p in _walk(d):
            lines = _lines(p)
            rel = os.path.relpath(p, base).replace(os.sep, "/")
            for i, line in enumerate(lines):
                if pat.search(line):
                    a, b = max(0, i - context), min(len(lines), i + context + 1)
                    snippet = "\n".join("%5d%s %s" % (j + 1, ":" if j == i else " ", lines[j]) for j in range(a, b))
                    hits.append("%s:%d\n%s" % (rel, i + 1, snippet))
                    files.add(rel)
                    if len(hits) >= limit:
                        return v, full, hits, files, True
    return v, full, hits, files, False


def read(path, start=1, lines=200, version=None):
    v, base, full = _base(version)
    p = _safe(base, path)
    if not os.path.exists(p) and full:                   # a file of the git copy only (ORIGIN.md of docs)
        p = _safe(os.path.join(ROOT, v), path)
    if os.path.isdir(p):
        raise ValueError("%s is a directory (use vc_docs_list)" % path)
    data = _lines(p)
    if not data and not os.path.isfile(p):
        raise ValueError("no file %s in %s" % (path, v))
    start = max(1, int(start or 1))
    end = min(len(data), start - 1 + int(lines or 200))
    body = "\n".join("%5d  %s" % (i + 1, data[i]) for i in range(start - 1, end))
    return v, full, "%s (lines %d-%d of %d)\n%s" % (path, start, end, len(data), body)


def listing(path="", version=None):
    v, base, full = _base(version)
    p = _safe(base, path)
    out = []
    for n in sorted(os.listdir(p)):
        q = os.path.join(p, n)
        out.append(n + "/" if os.path.isdir(q) else n)
    return v, full, out


def symbol(name, version=None, path=None, refs=20):
    """-> v, full, definitions [(rel, line, text)], references [(rel, line, text)], ref_total"""
    v, base, full = _base(version)
    n = re.escape(name.split("::")[-1].split(".")[-1].split(":")[-1])
    qual = re.escape(name).replace(r"\.", r"[.:]")
    defs_rx = [
        re.compile(r"^\s*(template\s*<[^>]*>\s*)?(class|struct|enum(\s+class)?|union|namespace)\s+(\w+\s+)?%s\b(?!\s*;)" % n),
        re.compile(r"^[\w:<>,\s\*&~]*\b(\w+::)*%s\s*\([^;]*$" % n),            # C++ function/method definition head
        re.compile(r"^\s*(using|typedef)\b.*\b%s\b" % n),
        re.compile(r"^\s*(local\s+)?function\s+([\w.:]+[.:])?%s\s*\(" % n),     # Lua function
        re.compile(r"^\s*(local\s+)?([\w.]+\.)?%s\s*=\s*function\b" % n),
        re.compile(r"\{\s*\"%s\"\s*,\s*lua::wrap" % n),                        # Lua binding table entry
        re.compile(r"^\s*#\s*define\s+%s\b" % n),
    ]
    word = re.compile(r"(?<![\w])%s(?![\w])" % (qual if qual != n else n))
    defs, rf, total = [], [], 0
    dirs = [_safe(base, path)] if path else [os.path.join(base, "src"), os.path.join(base, "res")]
    for d in dirs:
        for p in _walk(d, CODE_EXT):
            rel = os.path.relpath(p, base).replace(os.sep, "/")
            for i, line in enumerate(_lines(p)):
                if not word.search(line):
                    continue
                s = line.strip()
                if any(rx.search(line) for rx in defs_rx) and not s.startswith(("return ", "//", "--", "if ", "else")):
                    defs.append((rel, i + 1, s[:200]))
                else:
                    total += 1
                    if len(rf) < refs:
                        rf.append((rel, i + 1, s[:160]))
    return v, full, defs, rf, total


def diff(a, b, path="", query=None, limit=60, context=3):
    va, base_a, fa = _base(a)
    vb, base_b, fb = _base(b)
    pa, pb = _safe(base_a, path), _safe(base_b, path)
    if os.path.isfile(pa) or os.path.isfile(pb):
        la, lb = _lines(pa), _lines(pb)
        d = list(difflib.unified_diff(la, lb, "%s/%s" % (va, path), "%s/%s" % (vb, path), n=context, lineterm=""))
        cut = len(d) > 400
        return va, vb, "\n".join(d[:400]) + ("\n… (%d more diff lines)" % (len(d) - 400) if cut else "") or "identical"

    def files(base, p):
        out = {}
        for f in _walk(p):
            out[os.path.relpath(f, base).replace(os.sep, "/")] = f
        return out
    A, B = files(base_a, pa), files(base_b, pb)
    pat = re.compile(re.escape(query), re.I) if query else None
    rows, n = [], 0
    for rel in sorted(set(A) | set(B)):
        ta = "\n".join(_lines(A[rel])) if rel in A else None
        tb = "\n".join(_lines(B[rel])) if rel in B else None
        if ta == tb:
            continue
        if pat and not ((ta and pat.search(ta)) or (tb and pat.search(tb))):
            continue
        n += 1
        if len(rows) >= limit:
            continue
        if ta is None:
            rows.append("A %s" % rel)
        elif tb is None:
            rows.append("D %s" % rel)
        else:
            sm = difflib.SequenceMatcher(None, ta.splitlines(), tb.splitlines(), autojunk=False)
            add = sum(j2 - j1 for op, i1, i2, j1, j2 in sm.get_opcodes() if op in ("insert", "replace"))
            rem = sum(i2 - i1 for op, i1, i2, j1, j2 in sm.get_opcodes() if op in ("delete", "replace"))
            rows.append("M %s (+%d -%d)" % (rel, add, rem))
    head = "%d changed files%s" % (n, " (first %d)" % limit if n > limit else "")
    return va, vb, head + "\n" + "\n".join(rows) + "\nfile diff: vc_docs_diff {from, to, path: '<file>'}"


def register(TOOLS, text):
    def t_search(a):
        v, full, hits, files, cut = search(a["query"], a.get("lang", "ru"), a.get("scope", "all"), a.get("version"),
                                           a.get("regex", False), a.get("context", 1), a.get("limit", 40), a.get("path"))
        h = header(v, full)
        if not hits:
            return text("%s: nothing for %r (scope=%s, path=%s)" % (h, a["query"], a.get("scope", "all"),
                                                                    a.get("path") or "-"))
        return text("%s: %d hits in %d files%s\n\n" % (h, len(hits), len(files), " (limit reached)" if cut else "")
                    + "\n\n".join(hits))

    def t_read(a):
        v, full, body = read(a["path"], a.get("start", 1), a.get("lines", 200), a.get("version"))
        return text("%s: %s" % (header(v, full), body))

    def t_list(a):
        if a.get("versions"):
            dv = default_version()
            rows = ["%s%s — %s, %s" % (v, " (default)" if v == dv else "", origin(v) or "?",
                                       "full tree" if os.path.isdir(os.path.join(SRC_ROOT, v)) else "docs only")
                    for v in versions()]
            return text("engine docs versions:\n" + "\n".join(rows))
        v, full, items = listing(a.get("path", ""), a.get("version"))
        return text("%s: %s/\n%s" % (header(v, full), a.get("path", "") or ".", "\n".join(items)))

    def t_symbol(a):
        v, full, defs, refs, total = symbol(a["name"], a.get("version"), a.get("path"), a.get("refs", 20))
        out = ["%s: %r — %d definitions, %d references" % (header(v, full), a["name"], len(defs), total)]
        out += ["DEF %s:%d  %s" % d for d in defs[:40]]
        out += ["ref %s:%d  %s" % r for r in refs]
        return text("\n".join(out))

    def t_diff(a):
        va, vb, body = diff(a.get("from") or default_version(), a.get("to") or "main", a.get("path", ""),
                            a.get("query"), a.get("limit", 60))
        return text("VoxelCore %s (%s) -> %s (%s): %s\n%s" % (va, origin(va), vb, origin(vb), a.get("path") or ".", body))

    common = {"version": {"type": "string", "description": "версия движка: 0.32.7, 0.32.8, main (по умолчанию — "
                                                           "версия лаборатории по умолчанию, engines/registry.toml)"}}
    TOOLS["vc_docs_search"] = (t_search, {
        "description": "Поиск по документации И ИСХОДНИКАМ движка VoxelCore (офлайн, точная версия; в ответе версия и "
                       "коммит). scope: docs — doc/<lang>; api — C++-привязки Lua (точный список функций); lua — res/ "
                       "движка (stdlib, меню, шейдеры); src — весь C++ (voxels, content, coders, audio, graphics, "
                       "objects…); all. path — подкаталог/файл (напр. src/voxels). Пример: query='make_route', scope='src'.",
        "inputSchema": {"type": "object", "properties": dict(common, **{
            "query": {"type": "string"},
            "lang": {"type": "string", "enum": ["ru", "en"], "default": "ru"},
            "scope": {"type": "string", "enum": ["all", "docs", "api", "lua", "src"], "default": "all"},
            "path": {"type": "string", "description": "ограничить подкаталогом или файлом"},
            "regex": {"type": "boolean", "default": False},
            "context": {"type": "integer", "default": 1},
            "limit": {"type": "integer", "default": 40}}),
            "required": ["query"]},
    })
    TOOLS["vc_docs_read"] = (t_read, {
        "description": "Прочитать файл документации или исходника движка (путь как в vc_docs_search, напр. "
                       "src/voxels/Pathfinding.cpp, doc/ru/scripting/builtins/libgui.md), с start/lines.",
        "inputSchema": {"type": "object", "properties": dict(common, **{
            "path": {"type": "string"}, "start": {"type": "integer", "default": 1},
            "lines": {"type": "integer", "default": 200}}), "required": ["path"]},
    })
    TOOLS["vc_docs_list"] = (t_list, {
        "description": "Список файлов документации/исходников (path — подкаталог, напр. src/voxels); versions=true — "
                       "какие версии есть, их коммиты, какая по умолчанию, есть ли полное дерево.",
        "inputSchema": {"type": "object", "properties": dict(common, **{
            "path": {"type": "string", "default": ""}, "versions": {"type": "boolean", "default": False}})},
    })
    TOOLS["vc_docs_symbol"] = (t_symbol, {
        "description": "Где определено имя в исходниках движка (класс/структура/функция/метод C++, функция Lua, запись "
                       "привязки {\"name\", lua::wrap}) и где используется. Примеры: name='Pathfinding::perform', "
                       "'make_route', 'resetContent', 'require'.",
        "inputSchema": {"type": "object", "properties": dict(common, **{
            "name": {"type": "string"}, "path": {"type": "string", "description": "ограничить подкаталогом"},
            "refs": {"type": "integer", "default": 20}}), "required": ["name"]},
    })
    TOOLS["vc_docs_diff"] = (t_diff, {
        "description": "Что изменилось в движке между версиями: from/to (по умолчанию версия лаборатории -> main); "
                       "path — подкаталог (список изменённых файлов, +/- строк) или файл (unified diff); query — только "
                       "файлы, где встречается строка. Пример: {from:'0.32.7', to:'0.32.8', path:'src/logic'}.",
        "inputSchema": {"type": "object", "properties": {
            "from": {"type": "string"}, "to": {"type": "string"}, "path": {"type": "string", "default": ""},
            "query": {"type": "string"}, "limit": {"type": "integer", "default": 60}}},
    })
