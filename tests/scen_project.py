"""Временный проект «scen» для тестов интерпретатора и golden: вид fake (fake_f2f.py, кадр 4x2), сценарии, входы golden,
плагин с хуками (wait, expect, translate, info, server_step, finish, шаг alt для шума regen)."""
import json
import os
import textwrap

from conftest import FAKE, PY, toml_str

PLUGIN = '''
PLUGIN_VERSION = 1
STATE = {"alt": 0}


def wait(sx, args, step):
    n = 0
    while True:
        r = sx.raw("wait_check", {"tick_at": args["tick_at"]})
        if r["result"]["done"]:
            return {"ok": True, "result": {"frames": n, "tick": r["result"]["tick"]}}
        sx.raw("step", {"ticks": 1, "frames": 1})
        n += 1
        if n > 100:
            return {"ok": False, "error": "timeout"}


def alt(sx, args, step):
    """Шум эталона: 1, 2, 1, 2... такта по вызовам (между прогонами regen)."""
    STATE["alt"] += 1
    return sx.raw("step", {"ticks": 1 if STATE["alt"] % 2 else 2, "frames": 1})


def expect(sx, e):
    st = sx.raw("state").get("result") or {}
    return [] if st["tick"] == e.get("tick", st["tick"]) else ["tick %s != %s" % (st["tick"], e["tick"])]


def translate(sx, cmd, args):
    if cmd == "input" and args.get("keys"):
        args = dict(args, keys={("K" + k if k.isdigit() else k): v for k, v in args["keys"].items()})
    return args


def info(scn):
    return {"world": (scn.setup or {}).get("world", "w1")}


def server_step(sx, tick):
    sx.data["server_steps"] = sx.data.get("server_steps", 0) + 1


def lockstep_tick(sx, t):
    """Весь такт lockstep в плагине (этап 3б): счётчик, такт клиента, server_step; gui — событие + такт."""
    sx.data.setdefault("ticks", []).append(t.get("cmd"))
    if t.get("cmd") == "gui":
        sx.raw("gui", t.get("gui") or {})
    r = sx.raw("step", dict(t.get("args") or {}, ticks=1))
    server_step(sx, t)
    return r


def lockstep_run(sx, cmd, args, step):
    if cmd == "input":
        sx.data.setdefault("ls_inputs", []).append(args)
        return sx.raw("input", translate(sx, cmd, args))
    return None


def finish(sx):
    out = {"server_steps": sx.data.get("server_steps", 0)}
    if sx.data.get("ticks"):
        out["ticks"] = sx.data["ticks"]
    if sx.data.get("ls_inputs"):
        out["ls_inputs"] = len(sx.data["ls_inputs"])
    return out


def register(api):
    api.scenario(translate=translate, expect=expect, info=info, server_step=server_step, finish=finish,
                 lockstep_tick=lockstep_tick, lockstep_run=lockstep_run, steps={"wait": wait, "alt": alt})
'''

SCENARIOS = {
    "base": {"setup": {"world": "w1"}, "steps": [
        {"cmd": "step", "args": {"ticks": 2, "frames": 1}},
        {"cmd": "mode", "args": {"seed": 7}},
        {"cmd": "shot", "name": "base_only"}]},
    "child": {"base": "base", "steps": [
        {"cmd": "mode", "args": {"seed": 7}},
        {"cmd": "step", "args": {"ticks": 3, "frames": 1}, "expect": {"tick": 3}},
        {"cmd": "shot", "name": "s3"},
        {"cmd": "wait", "args": {"tick_at": 5}},
        {"cmd": "state"},
        {"cmd": "shot", "name": "s5"},
        {"cmd": "input", "args": {"keys": {"3": True}}},
        {"cmd": "state"},
        {"cmd": "bogus", "optional": True},
        {"cmd": "step"},
        {"cmd": "shot", "name": "s6k"}]},
    "bad_expect": {"steps": [{"cmd": "step", "args": {"ticks": 1}, "expect": {"tick": 99}},
                             {"cmd": "shot", "name": "never"}]},
    "wide": {"size": "8x8", "steps": [{"cmd": "step"}, {"cmd": "shot", "name": "w"}]},
    "lock": {"server": {"f2f": True}, "steps": [{"cmd": "step", "args": {"ticks": 3, "frames": 1}},
                                                {"cmd": "shot", "name": "l3"}]},
    "lock_in": {"server": {"f2f": True}, "steps": [{"cmd": "input", "args": {"keys": {"3": True}}},
                                                   {"cmd": "step", "args": {"ticks": 2, "frames": 1}},
                                                   {"cmd": "state"}]},
    "tl_lock": {"server": {"f2f": True}, "ticks": 10, "keyframes": [3, 10], "state_every": 5, "state_radius": 1,
                "timeline": [{"tick": 0, "input": {"keys": {"W": True}}}, {"tick": 6, "gui": {"key": "E"}}]},
    "tl": {"ticks": 10, "pace_ms": 0, "keyframes": [3, 10], "state_every": 5, "state_radius": 1,
           "setup": {"steps": [{"cmd": "step", "args": {"ticks": 2}}]},
           "timeline": [{"tick": 0, "input": {"keys": {"W": True}}}, {"tick": 4, "chat": "hi"},
                        {"tick": 6, "gui": {"key": "E"}}]},
    "noisy": {"steps": [{"cmd": "mode", "args": {"seed": 1}}, {"cmd": "step"}, {"cmd": "shot", "name": "a"},
                        {"cmd": "alt"}, {"cmd": "shot", "name": "b"}]},
    "legacy1": {"steps": [{"cmd": "mode", "args": {"seed": 5}}, {"cmd": "step"}, {"cmd": "shot", "name": "x"}]},
    "legacy2": {"steps": [{"cmd": "mode", "args": {"seed": 5}}, {"cmd": "step"}, {"cmd": "shot", "name": "x"}]},
}


def write_scen_project(tmp):
    proj = os.path.join(tmp, "projects", "scen")
    scen = os.path.join(tmp, "scenarios")
    for d in (proj, scen, os.path.join(tmp, "inputs"), os.path.join(tmp, "worlds", "w1", "region"),
              os.path.join(tmp, "golden")):
        os.makedirs(d, exist_ok=True)
    with open(os.path.join(tmp, "inputs", "patch.txt"), "w") as f:
        f.write("patch v1\n")
    with open(os.path.join(tmp, "worlds", "w1", "region", "r.0.0.mcr"), "wb") as f:
        f.write(b"\x01" * 100)
    with open(os.path.join(tmp, "worlds", "w1", "session.lock"), "wb") as f:
        f.write(b"\x00")
    for n, s in SCENARIOS.items():
        with open(os.path.join(scen, n + ".json"), "w", encoding="utf-8") as f:
            json.dump(s, f, indent=1)
    w = lambda p: toml_str(os.path.join(tmp, p))
    with open(os.path.join(proj, "project.toml"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [project]
        name = "scen"
        scenarios_dir = %(scen)s
        golden_dir = %(golden)s
        golden_store = %(store)s
        runs_dir = %(runs)s
        plugin = "plugin.py"

        [scenario]
        impls = { a = "fake", b = "fake" }
        default_size = "4x2"
        timeline_mode = { fixed = true, seed = 7 }

        [compare]
        tol = 0
        series_tol = 3

        [golden]
        inputs = [
          { name = "patch", file = %(patch)s },
          { name = "world", tree = %(world)s },
          { name = "opt", file = %(opt)s, optional = true },
          { name = "only_b", file = %(patch)s, impls = ["b"] },
        ]

        [kinds.fake]
        exe = %(py)s
        ports = ["f2f"]
        f2f = "f2f"
        size = "4x2"
        args = [%(fake)s, "{port.f2f}"]
        default_log = "stdout"
        ready = [ { f2f = "hello", timeout = 20 } ]
        stop = [ { f2f = "quit", wait_exit = 5 } ]
        """) % {"scen": toml_str(scen), "golden": w("golden"), "store": w("store"), "runs": w("runs"),
                "patch": w("inputs\\patch.txt"), "world": toml_str(os.path.join(tmp, "worlds") + "\\{info.world}"),
                "opt": w("inputs\\none.txt"), "py": toml_str(PY), "fake": toml_str(FAKE)})
    with open(os.path.join(proj, "plugin.py"), "w", encoding="utf-8") as f:
        f.write(PLUGIN)
    return os.path.join(tmp, "projects")
