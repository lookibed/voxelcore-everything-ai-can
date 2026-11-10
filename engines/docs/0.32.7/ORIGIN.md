# VoxelCore 0.32.7 — docs + Lua API sources (for agents)

From https://github.com/MihailRis/voxelcore `v0.32.7` (commit 8eff080f82f9, 2026-10-21T16:06:50Z). License: LICENSE (GPL-3.0). Read-only reference, served by
the MCP `voxelcore` tools `vc_docs_search` / `vc_docs_read` / `vc_docs_list` / `vc_docs_symbol` /
`vc_docs_diff` (vclab/mcp/engine_docs.py; version `0.32.7`).

- `doc/ru`, `doc/en` — official documentation (Lua API: `doc/*/scripting/builtins/lib*.md`, UI:
  `xml-ui-layouts.md`, `scripting/ui.md`, projects: `projects.md`, resources, generators…).
- `src/logic/scripting/lua/libs/*.cpp` — C++ bindings: the exact list of Lua functions
  (`{"name", lua::wrap<...>}`) and their behaviour, when the docs are silent.
- `res/scripts`, `res/layouts`, `res/project` — the engine's own Lua (stdlib, menus) as shipped.
- The whole C++ tree is in `engines/src/0.32.7` (not in git; MCP uses it when present).

Update: `python3 bin/fetch_engine_docs.py v0.32.7` (all versions of the registry + main: `--all`).
