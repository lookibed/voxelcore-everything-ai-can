#!/usr/bin/env python3
"""Fetch VoxelCore docs and sources of an engine tag (or `main`) for MCP vc_docs_*.

    python3 bin/fetch_engine_docs.py v0.32.7          # docs (git) + full source tree (disk only)
    python3 bin/fetch_engine_docs.py main             # snapshot of upstream main (full tree; commit + date in ORIGIN.md)
    python3 bin/fetch_engine_docs.py v0.32.8 --docs-only
    python3 bin/fetch_engine_docs.py --all            # every version of engines/registry.toml without legacy + main

Two places:
  engines/docs/<v>/  in git — doc/, Lua binding sources (src/logic/scripting/lua/libs), res/scripts|layouts|project
                     (small; enough for the Lua API);
  engines/src/<v>/   NOT in git — the whole text tree of the tag: src/ (all C++), res/ (Lua, shaders, layouts, presets),
                     doc/, CMake files (a few MB). MCP prefers it when present.
Needs `gh` with access to github.com."""
import io
import os
import shutil
import subprocess
import sys
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPSTREAM = "MihailRis/voxelcore"
KEEP_DOCS = ("doc/", "src/logic/scripting/lua/libs/", "res/scripts/", "res/layouts/", "res/project/", "LICENSE")
TEXT_EXT = (".md", ".cpp", ".hpp", ".h", ".c", ".inl", ".lua", ".xml", ".toml", ".json", ".txt", ".glsl", ".glslv",
            ".glslf", ".cmake", ".vcm", ".vca", ".obj", ".ini", ".yml", ".yaml", ".py", ".sh", ".ps1")


def gh(*args):
    return subprocess.check_output(["gh", "api"] + list(args))


def registry_versions():
    sys.path.insert(0, REPO)
    from vclab import engines
    reg = engines.load_registry().get("engines") or {}
    return ["v" + e["version"] for k, e in reg.items() if isinstance(e, dict) and not e.get("legacy")
            and str(e.get("version", "")).count(".") == 2]


def write_origin(dst, tag, sha, date, what):
    ver = tag.lstrip("v")
    body = ["# VoxelCore %s — %s (for agents)" % (ver, what), "",
            "From https://github.com/%s `%s` (commit %s, %s). License: LICENSE (GPL-3.0). Read-only reference, served by"
            % (UPSTREAM, tag, sha, date),
            "the MCP `voxelcore` tools `vc_docs_search` / `vc_docs_read` / `vc_docs_list` / `vc_docs_symbol` /",
            "`vc_docs_diff` (vclab/mcp/engine_docs.py; version `%s`)." % ver, ""]
    if what.startswith("docs"):
        body += ["- `doc/ru`, `doc/en` — official documentation (Lua API: `doc/*/scripting/builtins/lib*.md`, UI:",
                 "  `xml-ui-layouts.md`, `scripting/ui.md`, projects: `projects.md`, resources, generators…).",
                 "- `src/logic/scripting/lua/libs/*.cpp` — C++ bindings: the exact list of Lua functions",
                 "  (`{\"name\", lua::wrap<...>}`) and their behaviour, when the docs are silent.",
                 "- `res/scripts`, `res/layouts`, `res/project` — the engine's own Lua (stdlib, menus) as shipped.",
                 "- The whole C++ tree is in `engines/src/%s` (not in git; MCP uses it when present)." % ver]
    else:
        body += ["The whole text tree of the engine: `src/` (all C++: voxels, content, coders, audio, graphics, objects…),",
                 "`res/` (Lua, shaders, layouts, presets), `doc/`, CMake. Not in git (engines/src/ is ignored); the small",
                 "git copy is `engines/docs/%s`." % ver]
    body += ["", "Update: `python3 bin/fetch_engine_docs.py %s` (all versions of the registry + main: `--all`)." % tag]
    with open(os.path.join(dst, "ORIGIN.md"), "w", encoding="utf8") as f:
        f.write("\n".join(body) + "\n")


def fetch(tag, docs=True, full=True):
    ref = tag
    info = gh("repos/%s/commits/%s" % (UPSTREAM, ref), "--jq", ".sha + \" \" + .commit.committer.date").decode().split()
    sha, date = info[0], info[1]
    data = gh("repos/%s/tarball/%s" % (UPSTREAM, ref))
    name = tag.lstrip("v")
    outs = {}
    if docs and tag != "main":
        outs["docs"] = (os.path.join(REPO, "engines", "docs", name), lambda r: r.startswith(KEEP_DOCS))
    if full:
        outs["src"] = (os.path.join(REPO, "engines", "src", name),
                       lambda r: r == "LICENSE" or r.endswith(TEXT_EXT) or os.path.basename(r) == "CMakeLists.txt")
    for dst, _ in outs.values():
        if os.path.isdir(dst):
            shutil.rmtree(dst)
    counts = {k: 0 for k in outs}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for m in tar.getmembers():
            rel = m.name.split("/", 1)[1] if "/" in m.name else ""
            if not m.isfile() or not rel or ".." in rel:
                continue
            blob = None
            for k, (dst, keep) in outs.items():
                if keep(rel):
                    if blob is None:
                        blob = tar.extractfile(m).read()
                    out = os.path.join(dst, rel)
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    with open(out, "wb") as f:
                        f.write(blob)
                    counts[k] += 1
    for k, (dst, _) in outs.items():
        write_origin(dst, tag, sha[:12], date, "docs + Lua API sources" if k == "docs" else "full text source tree")
        print("%s %s: %d files -> %s (commit %s, %s)" % (tag, k, counts[k], dst, sha[:12], date))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    docs_only = "--docs-only" in sys.argv
    tags = registry_versions() + ["main"] if "--all" in sys.argv else (args or ["v0.32.7"])
    for t in tags:
        fetch(t, docs=True, full=not docs_only)


if __name__ == "__main__":
    main()
