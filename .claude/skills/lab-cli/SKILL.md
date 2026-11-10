---
name: lab-cli
description: Using the Lab from the shell or MCP correctly — which daemon, owner identity (LAB_OWNER), leases, running scenarios through `heavy`, restarting your own daemon after plugin edits, reading run reports, calling plugin features, cleaning up. Use whenever you run `bin/lab`, `lab_*` MCP tools, a scenario, or a test batch, and when a lab command "does nothing".
---

# Lab CLI and daemons

Reference: `docs/ONBOARDING.md` §1–8 (commands, symptoms table). This skill is the working procedure and the traps that
actually cost time.

## 1. Which daemon, which identity
- Shared daemon `:25700` — never stop/restart/upgrade (RULES 2.2). Other agents' isolated daemons — never touch.
- Your own isolated daemon (`bin/lab daemon start --isolated` → port P) — for tests and core edits; you may restart it
  when **it has no leases** (`bin/lab --daemon P ps`).
- A daemon the user plays on (a project's live stack) — read-only for you; restart/stop/`play-down|up` only after the
  user's explicit "yes" (the `.claude/hooks/guard.py` hook asks).
- Identity: `LAB_OWNER=<owner> bin/lab --daemon P …`. Leases belong to an owner; `stdin`, `op`, `call` on leases of owner
  X **silently do nothing or are refused** without `LAB_OWNER=X`. The daemon: `--daemon P` before the command (or
  `LAB_PORT=P`); without either the shared daemon is used. From WSL into Windows Python add `WSLENV=LAB_OWNER` when a tool spawns Windows Python.
- MCP `lab_*` tools talk to the daemon configured for the session; plugin features with `mcp=True` appear as
  `lab_<project>_<feature>` after `/mcp` reconnect.

## 2. Running things
- Every scenario/test batch/build: `heavy --label <what> -- timeout 900 bin/lab --daemon P run <project> <scenario>`.
  Timing runs: `heavy --exclusive` (see the box's CLAUDE.md).
- Many scenarios: ONE command, `heavy --label X -- bin/lab --daemon P run <project> a b c ... [--detach]`. Scenarios
  with the same preparation share a session; different preparations become a suite of sessions run one after another
  by the daemon (one job, one summary `suite: N/M sessions ok`, every session its own run/report). Long batches:
  `--detach` and follow `lab jobs` / `lab job <id>`; no shell loops over scenarios, no `sleep` polling.
- A plugin/step edit (`projects/<p>/*.py`, `project.toml`) is loaded at daemon start: restart **your** daemon (no
  leases on it) before the run, otherwise the new step "is unknown" or the old code runs.
- Plugin features directly: `bin/lab --daemon P call <project>.<feature> '{json}'`; a project's own CLI:
  `bin/lab --daemon P <project> …`.

## 3. Reading results
- `runs/<id>/report.json` (steps with results, shots with sha, verdict) and `journal.jsonl` — the evidence. Console
  output is truncated; quote the report.
- Lease logs: `bin/lab --daemon P logs <lease> --stream latest|stdout|stderr --grep RX`; `print()` of engine Lua goes to
  stdout, engine messages to latest.
- `bin/lab --daemon P ps` prints JSON: lease `dir` (Windows path) — the lease's `user:` / `config:` root. Files for a
  running process (code, assets) go there as files, not escaped into a stdin line.

## 4. Finish
- `release` your leases, tear down groups you brought up, stop your isolated daemon if you started it for this task.
- Report: run ids / report paths, verdicts, what was not run.

## Traps that happened
- `bin/lab stdin` without `LAB_OWNER` → no output, looked like "the world ignores the command".
- "Daemon not running" for your own isolated port after a reboot: `lab daemon start --isolated --port P`.
- New scenario step not found → the daemon still had the old plugin loaded.
- A test batch started bare (without `heavy`) competed with another agent's build.
- "Verified" from console tail while the report said FAIL on a later step.
