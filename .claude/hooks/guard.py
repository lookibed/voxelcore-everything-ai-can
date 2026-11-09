#!/usr/bin/env python3
"""PreToolUse guard for agents in this repo (docs/RULES.md). Reads the hook JSON on stdin, prints a decision:
  deny — never allowed (OS input, the stock engine started by an agent, secrets/local files into git, a project into
         the lab repo);
  ask  — allowed only with the user's yes in the prompt (restart/stop of a daemon the user uses, play stack down/up,
         git push, killing processes);
  nothing — normal flow.
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


def out(decision, reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision,
                                             "permissionDecisionReason": reason}}, ensure_ascii=False))
    sys.exit(0)


DENY = [
    (r"(user32|windll|DllImport|Add-Type|pyautogui|pynput)[\s\S]*\b(SendInput|keybd_event|mouse_event|SetForegroundWindow"
     r"|SetCursorPos|press|click|moveTo)\b",
     "RULES 1.1: OS input is forbidden; use F2F input"),
    (r"(^|[;&|(]\s*|Start-Process\s+|start\s+)[^\s;&|]*VoxelCore\.exe\b(?![^;&|]*--(f2f|headless))",
     "RULES 1.2: the stock VoxelCore.exe is the user's; agents use a Lab lease (F2F)"),
    (r"\bgit\s+add\b[^;&|]*(\.mcp\.json|log-\d{4}-[^\s]*\.txt|this-session-is-being-continued)",
     "local files (.mcp.json, export logs, conversation exports) never go into git"),
    (r"\bgit\s+add\b[^;&|]*\s(-f|--force)\b[^;&|]*\b(packs|projects)/",
     "RULES 5.7: packs/projects are separate repos, never force-added to the lab repo"),
    (r"\bgit\s+push\b[^;&|]*\s(-f|--force)\b", "RULES 4.6: no force push"),
]


def check_bash(cmd):
    for rx, why in DENY:
        if re.search(rx, cmd, re.I):
            out("deny", why)
    ports = user_ports()
    for m in re.finditer(r"\bbin/lab\b([^;&|]*)", cmd):
        seg = m.group(1)
        pm = re.search(r"--daemon\s+(\d+)", seg)
        port = int(pm.group(1)) if pm else 25700
        if re.search(r"\bdaemon\s+(restart|stop|upgrade)\b", seg) and port in ports:
            out("ask", "daemon %s on :%d which the user uses (RULES 2.2): only with the user's yes" % (
                re.search(r"\bdaemon\s+(\w+)", seg).group(1), port))
        if re.search(r"\bplay-(down|up)\b|\brelease\s+--all\b", seg):
            out("ask", "stops/starts the user's play stack or all leases: only with the user's yes")
    if re.search(r"\bgit\s+push\b", cmd):
        out("ask", "RULES 4.6: push only when the user asked")
    if re.search(r"\b(taskkill|Stop-Process|pkill|killall)\b|\bkill\s+-9\b|TerminateProcess", cmd, re.I):
        out("ask", "RULES 2.4: nothing is killed without the user knowing")


def check_mcp(name, args):
    n = name.split("__")[-1]
    act = str((args or {}).get("action", "")).lower()
    if n.endswith("_restart") or n == "lab_stop":
        out("ask", "%s restarts/stops a running role: only with the user's yes" % n)
    if n == "lab_daemon" and act in ("restart", "stop", "upgrade"):
        out("ask", "daemon %s: only with the user's yes" % act)
    if n == "lab_release" and (args or {}).get("all"):
        out("ask", "releases all leases: only with the user's yes")


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
