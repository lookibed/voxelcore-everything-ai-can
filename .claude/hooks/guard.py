#!/usr/bin/env python3
"""PreToolUse guard for agents in this repo (docs/RULES.md). Never asks the user anything (11.11, user: «хук не должен
мне ебать мозги… лучше оповестит самого агента, гит вообще похрен»):
  deny  — the hard rules only (OS input, the stock engine started by an agent): the AGENT gets the refusal and why;
  note  — risky but allowed (restart/stop of a daemon the user uses, play stack down/up, killing processes): the
          command runs, the AGENT gets a reminder of the rule in its context (additionalContext);
  nothing — normal flow. Git is not watched.
Daemons the user uses: .claude/hooks/user_daemons.json {"ports": [...]} (local machine config). Commands without
`--daemon P` go to the shared daemon (25700), which counts as the user's."""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def user_ports():
    try:
        with open(os.path.join(HERE, "user_daemons.json"), encoding="utf-8") as f:
            return {int(p) for p in json.load(f).get("ports", [])}
    except Exception:
        return {25700}


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}, ensure_ascii=False))
    sys.exit(0)


def note(text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "[guard] " + text}},
                     ensure_ascii=False))
    sys.exit(0)


DENY = [
    (r"(user32|windll|DllImport|Add-Type|pyautogui|pynput)[\s\S]*\b(SendInput|keybd_event|mouse_event|SetForegroundWindow"
     r"|SetCursorPos|press|click|moveTo)\b",
     "RULES 1.1: OS input is forbidden; use F2F input"),
    (r"(^|[;&|(]\s*|Start-Process\s+|start\s+)[^\s;&|]*VoxelCore\.exe\b(?![^;&|]*--(f2f|headless))",
     "RULES 1.2: the stock VoxelCore.exe is the user's; agents use a Lab lease (F2F)"),
]


def check_bash(cmd):
    for rx, why in DENY:
        if re.search(rx, cmd, re.I):
            deny(why)
    ports = user_ports()
    for m in re.finditer(r"\bbin/lab\b([^;&|]*)", cmd):
        seg = m.group(1)
        pm = re.search(r"--daemon\s+(\d+)", seg)
        port = int(pm.group(1)) if pm else 25700
        dm = re.search(r"\bdaemon\s+(restart|stop|upgrade)\b", seg)
        if dm and port in ports:
            note("daemon %s on :%d — the user works on it (RULES 2.2): only if the user said so in THIS task; "
                 "say in the report what was restarted and why" % (dm.group(1), port))
        if re.search(r"\bplay-(down|up)\b|\brelease\s+--all\b", seg):
            note("this stops/starts the user's play stack or all leases: only if the user said so in THIS task; "
                 "check players online first and report it")
    if re.search(r"\b(taskkill|Stop-Process|pkill|killall)\b|\bkill\s+-9\b|TerminateProcess", cmd, re.I):
        note("killing a process (RULES 2.4): only your own processes; anything else — only with the user's knowledge")


def check_mcp(name, args):
    n = name.split("__")[-1]
    act = str((args or {}).get("action", "")).lower()
    if n.endswith("_restart") or n == "lab_stop":
        note("%s restarts/stops a running role — on the user's stack only if they said so in THIS task" % n)
    if n == "lab_daemon" and act in ("restart", "stop", "upgrade"):
        note("daemon %s — of a daemon the user works on only if they said so (RULES 2.2)" % act)
    if n == "lab_release" and (args or {}).get("all"):
        note("releases all leases — others' too? only your own (RULES 2.5)")


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    name = d.get("tool_name", "")
    ti = d.get("tool_input") or {}
    if name == "Bash":
        check_bash(ti.get("command", ""))
    elif name.startswith("mcp__lab__"):
        check_mcp(name, ti)


if __name__ == "__main__":
    main()
