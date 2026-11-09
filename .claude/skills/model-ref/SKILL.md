---
name: model-ref
description: Models and animations from Blender for VoxelCore — exporting any .blend to VCM/PNG/VCA (bones, bezier curves, crossfade time) and proving the engine shows the same thing by frame-by-frame pixel comparison in F2F. Use when making or fixing a model/animation, when a model looks wrong in the engine, or when asked "does it look right".
---

# model_ref: Blender → engine, judged by pixels

Full reference: `vclab/model_ref/README.md`. The user judges models by what is SEEN: pose matrices can agree while UVs,
shading, culling or scale are wrong ("тупорылое недопонимание качества" — 07.11). So the evidence is a pixel compare,
plus you looking at the worst frames.

## Procedure
1. Source of truth is a `.blend` (or a bpy script that builds it — preferred: the fixture is rebuilt by one command).
   Blender is a Windows program: inputs and outputs under `D:\…` (the work root), not WSL `/tmp`.
2. Export: MCP `vc_model_export {blend, anims?}` or
   `python3 -m vclab.model_ref.model_ref --blend X.blend --export-only` → `X.vcm`, PNGs, `<anim>.vca`, `export.json`
   (per animation: channels carried as curves vs baked, error between frames, `fade`).
3. Compare: MCP `vc_model_ref {blend, anims?}` (runs through `heavy`, on your own daemon) or the CLI without
   `--export-only`. Exit 0 = all frames within thresholds, 1 = failures, 2 = the run itself failed.
4. Open the report: verdict, worst frame image, diff map; look at every failing frame yourself before explaining it.
5. State changes / crossfades: `--states 'idle:1, walk:2/0.25'`; in-between frames: `--sub 2`.

## Rules of thumb
- Animation channels: prefer Blender's own bezier keys (`--curves auto`); baked channels must stay under the error
  printed in `export.json`.
- Crossfade into an animation comes from Blender (action property `fade`, NLA `blend_in`, scene `fade_<anim>`) and is
  written as `@configure … fade <s>`; the engine ignores the key, a game client may use it.
- Render bytes vary between Blender runs: keep reference renders unless the model changed.
- Do not report "the model is fine" from a screenshot in a game world — that is a smoke check, not the proof.
