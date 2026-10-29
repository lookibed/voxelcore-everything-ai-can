"""Старые раннеры AlphaMine -> лаборатория (этап 2а): run_vc_scenario.py, run_u.py, e2e/e2e_run.py и MCP am_scenario /
am_layers по умолчанию не запускают процессы сами, а отдают прогон интерпретатору демона labd (tools/lab): аренды
(порты 25600–25699, Job Object), каталог прогона D:\\Prog\\AlphaMine\\lab\\runs\\<id>, журнал демона.
Старый путь (свои exe/порты/серверы, lockstep через f2f_server.py, --collision, --attach, окна) — только с --legacy
(или автоматически там, где у лаборатории пока нет нужного: lockstep-сервер, collision, quick-префикс, attach).

  delegate(["alpha_spawn"], impl="vc", golden="compare")   # прогон + сравнение с golden
  delegate(["e2e_walk1"], impl="java", golden="promote", reason="...")   # прогон + promote в golden с манифестом
Владелец аренд — LAB_OWNER (по умолчанию <раннер>@<user>)."""
import getpass
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VC_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
LAB = os.path.join(VC_ROOT, "tools", "lab", "lab")


def note(runner, why=None):
    msg = "[%s] deprecated as a process launcher: delegating to labd (tools/lab: lab run / compare / golden)" % runner
    if why:
        msg = "[%s] legacy path: %s" % (runner, why)
    print(msg, flush=True)


def lab(args, owner, capture=False):
    env = dict(os.environ, LAB_OWNER=owner)
    if capture:
        p = subprocess.run([LAB] + list(args), env=env, capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr
    p = subprocess.Popen([LAB] + list(args), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         bufsize=1)
    out = []
    for line in p.stdout:
        out.append(line)
        sys.stdout.write(line)
        sys.stdout.flush()
    return p.wait(), "".join(out)


def delegate(scenarios, impl="vc", golden="compare", reason=None, runner="runner", owner=None):
    """golden: "compare" — сравнить прогон с golden; "promote" — записать прогон в golden (манифест, CAS, история);
    None — только прогон. -> код выхода."""
    owner = owner or os.environ.get("LAB_OWNER") or "%s@%s" % (runner, getpass.getuser())
    note(runner)
    args = ["run", "alphamine"] + list(scenarios) + ["--impl", impl]
    if golden == "compare":
        args.append("--golden")
    rc, out = lab(args, owner)
    m = re.search(r"^job (\S+) -> ", out, re.M)
    if golden == "promote" and m:
        if rc != 0:
            print("[%s] run failed: golden NOT promoted" % runner, flush=True)
            return rc
        rc2, out2 = lab(["golden", "promote", m.group(1), "--reason", reason or "%s --golden" % runner], owner,
                        capture=True)
        print(out2, flush=True)
        rc = rc or rc2
    return rc
