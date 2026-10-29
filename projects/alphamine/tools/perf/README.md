# AlphaMine perf suite

Numbers, causes and history: `agents/ALPHAMINE.md` §9 and §9.1. All runs write to `<repo>\projects\alphamine\external\runs\<stamp>_...`.

| script | what |
|---|---|
| `perf_normal.py [--tag T] [--switch k=v] [--line ax,az] [--autowalk k=v] [--pack P] [--wait-idle S] [--allow-contended]` | **lab stage 3a**: thin wrapper (`perflab.py`) over `tools/lab/lab perf alphamine perf_normal` — waits for an idle PC, server + test build `VoxelCoreF2F.exe --f2f-clock realtime` (input isolated) as leases, frame 1390x855 (the user's window and settings.toml); never the stock exe |
| `perf_walk.py [same keys]` | same over `lab perf alphamine perf_walk`, frame 854x480 (realtime since 01.10; the former virtual-time F2F stepping is gone, its runs are another family) |
| `perf_stream.py [--tag T] [--f2f] [--variant lp] [--switch k=v] [--walk 3000]` | streaming load 20-40 MapChunk/s: straight line x=-100.5 to -Z over fresh `world_b`, `autowalk glide=1` at walking speed |
| `make_variant.py [--engine-light off]` (since 01.10 the shared pack itself is light-passing; `--engine-light on` makes the old engine-light variant) | variant pack `run\alphamine_lp` (junctions + own `blocks/` from `gen_pack_blocks.py --blocks-only --engine-light off`) and `--dir`s `run\vc_rt_lp`, `run\vc_f2f_lp`; the shared pack is untouched |
| `perflab.py` | shared wrapper: argparse keys -> `lab perf ... --param k=<json>`; exit 0 clean, 3 contended, 4 refused (PC not idle), 1 failed |
| `hostload.py` | (before stage 3a) PC load via `tools/lab/labcore/sysload.py` (Windows Python): `wait_idle` before a run, `Monitor` during it; result `host_load` in `perf_summary.json`, `clean`/`CONTENDED` in the report |
| `perf_report.py <run>`, `perf_compare.py A B [--phase walk]`, `perflib.py` | report (+ `stream_stats`: MapChunk/s per 5 s, fps by load bucket, appearance delay from `samples.csv`), comparisons |

Validity: a run is valid only when `host load: clean` and the report has no "frame/tick errors" note. Runs before
01.10 17:05 have no load record ("load not recorded"). Since stage 3a the lab enforces it: no idle PC within
`--wait-idle` -> refusal; busy during the run -> `contended` (gates ignore it, `perf_compare.py` refuses it unless
`--allow-contended`). Idle = no foreign engine/Java, others' CPU < 15 %, GPU < 15 %, user input >= 120 s ago, no other
lab work (`tools/lab/lab.toml [perf]`, `tools/lab/README.md` "Этап 3а").

Pack switches (`--switch`, measurements only): `lm_upload=off`, `fx_upload=off`, `max_per_frame`, `budget_ms`,
`lm_interval`, `lm_skip=1`, `bc_defer` (default 2 since 01.10, ALPHAMINE §9.2; 0 = block changes immediate), `bc_age`, `bc_max`, `f2f_budget=50` (F2F with
the normal launch's batching), `preload_mark=on`, `zero_rle=off`. Autowalk keys: `stand walk settle yaw turn period
pitch line ax az ahead glide speed menu` (`modules/autowalk.lua`).
