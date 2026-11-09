---
name: lab-engine-test
description: How to run and look at VoxelCore in this repo — any time you need to start the engine, take a frame, check a pack/project/world "in the engine", reproduce a user's screenshot or bug, or measure fps. Lab lease + F2F only (hidden window, 854x480, virtual clock, isolated input). Read BEFORE the first engine launch of a session and before using vc_start.
---

# Engine test via Lab

The user works at this PC while you test. An engine window on their desktop, a stolen cursor, or a sound is a
failure even if the test "worked". Full rules and why: `docs/RULES.md` §1, §3, §5.5. This skill is the procedure;
daemons, owners and running scenarios — skill `lab-cli`.

## 0. Before the first launch
1. `lab_ps` — which daemon you are on (own isolated `:258xx`, owner `claude`), what leases exist. Others' leases and
   daemons (another agent's isolated daemon, the shared `:25700`) — never touch.
2. Pick the kind. Do not improvise with `vc_start` / kind `vc.dev` pointed at random dirs.

| what to check | kind |
|---|---|
| engine itself, main menu, F2F probe | `lab_lease project=vc kind=engine` |
| a downloaded/foreign project (folder with `project.toml`, `start.lua`, `content\`) | `lab_lease project=vc kind=user_project params={"src": "<Windows path>"}` |
| a project shipped as a user dir (`project\` + `worlds\` …, levels read from `user:worlds`) | `lab_lease project=vc kind=user_dir params={"src": "<Windows path laid out like the install>"}` |
| a pack/project of this repo | its own kinds in `projects/<p>/project.toml` (`lab_ps`/`lab projects` lists them). No fitting kind → add one there (prepare: copytree/packs/settings.toml; sound 0 is enforced by the core for every F2F engine since 09.11 — all channels, the menu included) |
| fps / perf | the project's perf kind + `lab perf` only on an idle PC (RULES §3.1) |

Sources for `user_project` must be on a Windows-visible path (`D:\…`), not WSL `/tmp`. Copy into `work\<name>-src`;
never point a lease at the user's installation or originals.

## 1. Start and VERIFY before saying anything
`lab_lease … start=true` returns `start.ready[0].result` (= `hello`) and `start.isolation`. Check and only then report:
- `flags.window == "hidden"` — if it says `normal`, release immediately: a window is on the user's desktop;
- `flags.input == "isolated"`, `version` = the expected `0.32.x-f2f`;
- `w × h == 854 × 480` unless the user asked for another size;
- `flags.clock` — `virtual` by default.

Never write "hidden window" / "isolated" from memory or from a tool description — quote the `hello` you got.

## 2. Drive it deterministically
- Virtual clock: nothing moves until `lab_f2f cmd=step args={"ticks":N,"frames":M}`. Frame 0 is black — step first.
- Wait with `step` or with conditions (`wait` steps of scenarios, `vc_wait_log`), never `sleep`/realtime polling.
- Input: `lab_f2f cmd=input args={"mouse":{"x":427,"y":200}}`, `{"keys":{"space":true}}` … then `{"space":false}`.
  Click: `{"mouse":{"x":X,"y":Y,"buttons":[true,false,false]}}` (left, right, middle — list of booleans), `step` 2 frames,
  then the same with `[false,false,false]`, then `step` again. `{"left":true}` / `["left"]` → type error.
  The F2F mouse starts at **(0,0)** — RTS/edge-pan cameras will scroll away. First input: put the mouse at the centre.
- Frame: `lab_f2f cmd=shot` (framebuffer, not the window). Logs: `lab_logs lease=… stream=latest|stdout`
  (`print()` goes to **stdout**, engine messages to latest).
- Repeatable path → scenario (`lab_run`, `scenario_save/run`), not a hand-typed sequence again.

## 3. Debug order
State first, theories second: `lab_logs` (errors, your debug prints), F2F `state` / pack commands, input state
(cursor!), then code. Compare against the user's report only at the same version/size. Debug edits go into the lease
copy (`work\…-src`), never into the user's installation.

## 4. Finish
`lab_release` every lease you took; say what you verified (hello flags, run dir, shot path) and what you did not.
Stock `VoxelCore.exe` is the user's: you never start it (RULES §1.2). A version without an F2F build (e.g. a just
released 0.32.8) → test on the nearest F2F build and say so, or ask the user to run it and send `latest.log`.

## Known traps (each happened)
- `vc_start` = kind `vc.dev`; until 2026-11-02 it showed a **visible** window (`window=normal`). Now hidden; still prefer
  `lab_lease`. A tool description saying "без фокуса" does not mean hidden.
- 1280×720 "for a better look" breaks comparisons — 854×480.
- Realtime + `sleep` + screenshots at random moments = unreproducible frames.
- Guessing engine internals (`look_at`, camera vs player) before checking the F2F cursor position wasted a round trip.
- Lease inputs in WSL `/tmp` are invisible to the Windows daemon — keep them under `D:\…\work\`.
