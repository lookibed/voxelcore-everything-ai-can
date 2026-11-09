---
name: engine-source
description: Answering "how does VoxelCore do X / why does the engine behave like this" from the source code of the exact engine version in use (0.32.7 by default) — Lua API semantics, content sources, parsers (OBJ, VCM, VCA), audio, pathfinding, entities. Use before claiming "the engine can't", before working around engine behaviour, and when docs and behaviour disagree.
---

# Engine source of the right version

The projects run on a specific engine (`engines/registry.toml`; default 0.32.7). Behaviour differs between versions —
reading 0.31 code for a 0.32.7 question produced wrong conclusions.

## Where to read
1. MCP `vc_docs_search {query, version: "0.32.7", scope: "all"}` and `vc_docs_read {path, version, start, lines}` —
   offline docs **and** sources (`src/...`, `res/scripts/...`, `doc/ru|en/...`) of that version.
2. Full tree when grep across files is needed: sparse clone into the scratchpad (it is wiped between days):
   ```bash
   cd <scratchpad> && git clone -q --depth 1 --branch v0.32.7 --filter=blob:none --sparse \
     https://github.com/MihailRis/VoxelCore vc0327 && cd vc0327 && git sparse-checkout set src res doc
   ```
3. Any other local checkout: first `git -C <dir> describe --tags` — use it only if it is the same version.

## How to answer
- Quote file:line of that version; say which version you read.
- Then confirm by running (RULES 3.4): a lease + F2F probe or a scenario step, not only reading.
- Typical places: `src/logic/scripting/lua/libs/lib*.cpp` (Lua API), `res/scripts/stdlib.lua|stdmin.lua` (require,
  module cache), `src/content/ContentControl.cpp` (content sources), `src/coders/*.cpp` (OBJ/VCM/VCA/PNG/OGG),
  `src/voxels/Pathfinding.cpp`, `src/audio/`.

## Examples that paid off
- Menu sounds at full volume although `volume-master = 0`: master is only the listener gain set by the world screen.
- A model invisible: the OBJ parser skips a file without `usemtl`.
- Unknown `@configure` keys in VCA are ignored — a safe place for extra metadata.
- `require` cache survives until `reset_content`: switching the content source needs a double load.
