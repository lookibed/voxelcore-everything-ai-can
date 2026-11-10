---
name: engine-source
description: Answering "how does VoxelCore do X / why does the engine behave like this / what changed between versions" from the docs and the FULL source of the exact engine version (MCP vc_docs_search|read|list|symbol|diff; default = the lab's engine 0.32.7, also 0.32.8 and upstream main). Use before claiming "the engine can't", before working around engine behaviour, when docs and behaviour disagree, and before relying on a newer engine.
---

# Engine docs and source, right version

The projects run on the lab's default engine (`engines/registry.toml` `default`, now 0.32.7). Reading another version
gave wrong conclusions (a 0.31-based dev checkout was taken for 0.32.7; a scratchpad clone vanished overnight).

## Tools (MCP `voxelcore`; offline; every answer starts with version + commit)
- `vc_docs_list {versions: true}` — available versions, commits, which is default, whether the full tree is there.
- `vc_docs_search {query, scope, path?, version?, regex?}` — scope `docs` (doc/<lang>), `api` (C++ Lua bindings = the
  exact list of Lua functions), `lua` (engine `res/`: stdlib, menus, shaders, components), `src` (all C++), `all`;
  `path: "src/voxels"` narrows.
- `vc_docs_symbol {name}` — definitions (C++ class/function/method, Lua function, binding entry `{"name", lua::wrap}`)
  and references. `Pathfinding::perform`, `make_route`, `resetContent`, `require`.
- `vc_docs_read {path, start, lines}` — any file (`src/voxels/Pathfinding.cpp`, `doc/ru/scripting/builtins/libaudio.md`).
- `vc_docs_diff {from, to, path?, query?}` — changed files between versions (default: lab version → main) or a file's
  unified diff. Use before saying "fixed upstream" or planning an engine upgrade.
- No `version` = the lab's default. Pass `version: "main"` / `"0.32.8"` explicitly when asking about those.

Files: `engines/docs/<v>` (git: docs + bindings) and `engines/src/<v>` (full tree, disk only). Missing / stale:
`python3 bin/fetch_engine_docs.py v<ver> | main | --all`. Do not clone into temp dirs, do not read other local
checkouts unless `git describe` proves the same version.

## How to answer
1. Find the binding (`scope: api`) → the C++ it calls (`vc_docs_symbol`) → the behaviour; quote `file:line` + version.
2. Confirm by running when it matters (RULES 3.4): a lease + F2F probe or a scenario step.
3. Say what differs in newer versions if relevant (`vc_docs_diff`).

## Examples that paid off
- Menu sounds at full volume although `volume-master = 0`: master is only the listener gain set by the world screen.
- An OBJ model invisible: the parser skips a file without `usemtl`.
- Unknown `@configure` keys in VCA are ignored — a safe place for extra metadata.
- `require` cache survives until `reset_content`: switching the content source needs a double load.
- Pathfinding agent: height 2, jump 1, `maxVisitedBlocks` 1000, route returned target-first; rewritten in main.
