"""Engine documentation for agents: VoxelCore docs + Lua binding sources, offline, per engine version.

Files live in <repo>/engines/docs/<version>/ (doc/ru, doc/en, src/logic/scripting/lua/libs, res/scripts|layouts|project),
fetched by bin/fetch_engine_docs.py. Tools (registered in voxelcore_mcp.TOOLS):
  vc_docs_search  — regex/substring over docs (+ C++ bindings, engine Lua) with file:line and context
  vc_docs_read    — a file or a line range
  vc_docs_list    — directory listing / available versions
"""
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOT = os.path.join(REPO, "engines", "docs")
TEXT_EXT = (".md", ".cpp", ".hpp", ".lua", ".xml", ".toml", ".json", ".txt", ".glsl", ".glslv", ".glslf")


def versions():
    if not os.path.isdir(ROOT):
        return []
    return sorted(v for v in os.listdir(ROOT) if os.path.isdir(os.path.join(ROOT, v)))


def _base(version):
    vs = versions()
    if not vs:
        raise ValueError("no engine docs in %s (run bin/fetch_engine_docs.py v0.32.7)" % ROOT)
    v = (version or vs[-1]).lstrip("v")
    if v not in vs:
        raise ValueError("no docs for %r; have %s" % (version, vs))
    return v, os.path.join(ROOT, v)


def _safe(base, rel):
    p = os.path.normpath(os.path.join(base, rel or ""))
    if not (p == base or p.startswith(base + os.sep)):
        raise ValueError("path outside the docs: %s" % rel)
    return p


def _scope_dirs(base, scope, lang):
    if scope == "docs":
        return [os.path.join(base, "doc", lang)]
    if scope == "api":
        return [os.path.join(base, "src")]
    if scope == "lua":
        return [os.path.join(base, "res")]
    return [os.path.join(base, "doc", lang), os.path.join(base, "src"), os.path.join(base, "res")]


def search(query, lang="ru", scope="all", version=None, regex=False, context=1, limit=40):
    v, base = _base(version)
    flags = re.IGNORECASE
    pat = re.compile(query if regex else re.escape(query), flags)
    hits, files = [], set()
    for d in _scope_dirs(base, scope, lang):
        for dirpath, _, names in os.walk(d):
            for n in sorted(names):
                if not n.endswith(TEXT_EXT):
                    continue
                p = os.path.join(dirpath, n)
                try:
                    lines = open(p, encoding="utf8", errors="replace").read().splitlines()
                except OSError:
                    continue
                rel = os.path.relpath(p, base).replace(os.sep, "/")
                for i, line in enumerate(lines):
                    if pat.search(line):
                        a, b = max(0, i - context), min(len(lines), i + context + 1)
                        snippet = "\n".join("%5d%s %s" % (j + 1, ":" if j == i else " ", lines[j]) for j in range(a, b))
                        hits.append("%s:%d\n%s" % (rel, i + 1, snippet))
                        files.add(rel)
                        if len(hits) >= limit:
                            return v, hits, files, True
    return v, hits, files, False


def read(path, start=1, lines=200, version=None):
    v, base = _base(version)
    p = _safe(base, path)
    if os.path.isdir(p):
        raise ValueError("%s is a directory (use vc_docs_list)" % path)
    data = open(p, encoding="utf8", errors="replace").read().splitlines()
    start = max(1, int(start or 1))
    end = min(len(data), start - 1 + int(lines or 200))
    body = "\n".join("%5d  %s" % (i + 1, data[i]) for i in range(start - 1, end))
    return v, "%s (lines %d-%d of %d)\n%s" % (path, start, end, len(data), body)


def listing(path="", version=None):
    v, base = _base(version)
    p = _safe(base, path)
    out = []
    for n in sorted(os.listdir(p)):
        q = os.path.join(p, n)
        out.append(n + "/" if os.path.isdir(q) else n)
    return v, out


def register(TOOLS, text):
    def t_search(a):
        v, hits, files, cut = search(a["query"], a.get("lang", "ru"), a.get("scope", "all"), a.get("version"),
                                     a.get("regex", False), a.get("context", 1), a.get("limit", 40))
        if not hits:
            return text("VoxelCore %s docs: nothing for %r (scope=%s, lang=%s)" % (v, a["query"], a.get("scope", "all"),
                                                                               a.get("lang", "ru")))
        head = "VoxelCore %s: %d hits in %d files%s\n\n" % (v, len(hits), len(files), " (limit reached)" if cut else "")
        return text(head + "\n\n".join(hits))

    def t_read(a):
        v, body = read(a["path"], a.get("start", 1), a.get("lines", 200), a.get("version"))
        return text("VoxelCore %s: %s" % (v, body))

    def t_list(a):
        if a.get("versions"):
            return text("engine docs versions: %s (root %s)" % (", ".join(versions()) or "none", ROOT))
        v, items = listing(a.get("path", ""), a.get("version"))
        return text("VoxelCore %s: %s/\n%s" % (v, a.get("path", "") or ".", "\n".join(items)))

    common = {"version": {"type": "string", "description": "версия движка, напр. 0.32.7 (по умолчанию новейшая)"}}
    TOOLS["vc_docs_search"] = (t_search, {
        "description": "Поиск по документации движка VoxelCore (офлайн, точная версия): doc/ru|en (Lua API "
                       "builtins/lib*.md, xml-ui-layouts, projects, ресурсы), C++-привязки Lua "
                       "(src/logic/scripting/lua/libs — точный список функций) и Lua самого движка (res/scripts, "
                       "res/layouts). Пример: query='play_sound_2d', scope='all'.",
        "inputSchema": {"type": "object", "properties": dict(common, **{
            "query": {"type": "string"},
            "lang": {"type": "string", "enum": ["ru", "en"], "default": "ru"},
            "scope": {"type": "string", "enum": ["all", "docs", "api", "lua"], "default": "all",
                      "description": "docs — doc/<lang>, api — C++ привязки, lua — res/ движка"},
            "regex": {"type": "boolean", "default": False},
            "context": {"type": "integer", "default": 1},
            "limit": {"type": "integer", "default": 40}}),
            "required": ["query"]},
    })
    TOOLS["vc_docs_read"] = (t_read, {
        "description": "Прочитать файл документации/исходника движка (путь как в vc_docs_search, напр. "
                       "doc/ru/scripting/builtins/libgui.md), с start/lines.",
        "inputSchema": {"type": "object", "properties": dict(common, **{
            "path": {"type": "string"}, "start": {"type": "integer", "default": 1},
            "lines": {"type": "integer", "default": 200}}), "required": ["path"]},
    })
    TOOLS["vc_docs_list"] = (t_list, {
        "description": "Список файлов документации движка (path — подкаталог, напр. doc/ru/scripting/builtins); "
                       "versions=true — какие версии есть.",
        "inputSchema": {"type": "object", "properties": dict(common, **{
            "path": {"type": "string", "default": ""}, "versions": {"type": "boolean", "default": False}})},
    })
