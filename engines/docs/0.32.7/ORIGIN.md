# VoxelCore 0.32.7 — engine docs and Lua API sources (for agents)

From https://github.com/MihailRis/voxelcore tag `v0.32.7` (tarball `MihailRis-voxelcore-aa2d13f`, commit aa2d13f0 = tag
object → 8eff080f). License: see LICENSE (GPL-3.0). Read-only reference, served by the MCP `voxelcore` tools
`vc_docs_search` / `vc_docs_read` / `vc_docs_list` (vclab/mcp/engine_docs.py).

- `doc/ru`, `doc/en` — official documentation (Lua API: `doc/*/scripting/builtins/lib*.md`, UI: `xml-ui-layouts.md`,
  `scripting/ui.md`, projects: `projects.md`, resources, generators…).
- `src/logic/scripting/lua/libs/*.cpp` — C++ bindings: the exact list of Lua functions (`{"name", lua::wrap<...>}`)
  and their behaviour, when the docs are silent.
- `res/scripts`, `res/layouts`, `res/project` — the engine's own Lua (stdlib, menus) as shipped.

Update for another engine version: `python3 bin/fetch_engine_docs.py <tag>` (writes engines/docs/<version>, e.g. engines/docs/0.32.7).
