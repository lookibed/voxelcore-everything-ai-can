---
name: session-recovery
description: Restoring working context after the conversation was compacted, a session crashed, or the user says "ты контекст потерял" — recover not only WHAT was done but HOW the work was being done (exact commands, order, conventions), check the state of every repo and daemon, then continue in the same order. Use at the start of a continued session and whenever you are unsure how something was done before.
---

# Recover context: what AND how

A compaction summary keeps outcomes and drops method. After one, an agent used wrong CLI variables, read the source of
another engine version and went straight to the user's live server — all of it was known earlier in the same session.

## 1. Stop and inventory (no new work yet)
- Running things: background shells/monitors you started, your leases (`bin/lab --daemon P ps` for each daemon you use),
  `heavy status`. Nothing of yours left running unnoticed; nothing of others touched.
- `git status --short` + `git log --oneline -3` in **every** repository you worked in (the lab repo and each project's
  own repo are separate). Note which uncommitted changes are yours.
- The task's progress file / plan (`PLAN.md` of the project, `*_PROGRESS.md`).

## 2. Recover HOW, from the full transcript
- Full log: `~/.claude/projects/<project-dir-slug>/<session-id>.jsonl`. An exported conversation (`/export`) shows only
  collapsed summaries — not enough.
- Extract the tool calls since the last user turns you remember (Python over the JSONL: `message.content[]` items of
  type `tool_use`; for Bash print `input.description` + `input.command`). Read them for:
  CLI form and env (`LAB_OWNER`, `--daemon P`, `heavy`), build/deploy order, how tests were run and read, where
  inputs/outputs live, what needed the user's approval.
- Extract the user's messages too, especially corrections — they are the rules of this user.

## 3. Write it down so it survives
- Repeated commands and conventions → the right skill or project doc (lab-level → this repo; project-level → the
  project's own repo, `docs/RULES.md` 5.7) and, briefly, the agent's memory.
- Remove or fix memories that the transcript shows are outdated.

## 4. Continue
- Tell the user in a few lines: state found, what was in progress, what is next — then continue the unfinished task from
  where it stopped, in the same order (own daemon and tests first; live/user-facing systems only with approval).
- If the user said "stop", do only the recovery and wait.
