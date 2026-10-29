import json
import os
import sys
import tempfile
import textwrap

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
sys.path.insert(0, LAB)

PY = sys.executable


@pytest.fixture
def tmpdir_win():
    with tempfile.TemporaryDirectory(prefix="labtest_") as d:
        yield d


FAKE = os.path.join(HERE, "fake_f2f.py")


def toml_str(s):
    return json.dumps(s)


def write_dummy_project(tmpdir_win):
    """Временный проект dummy (fake F2F, дерево cmd->python, stdin-сервер, переживающий демон) -> каталог проектов."""
    proj = os.path.join(tmpdir_win, "projects", "dummy")
    content = os.path.join(tmpdir_win, "content", "packx")
    os.makedirs(proj, exist_ok=True)
    os.makedirs(content, exist_ok=True)
    with open(os.path.join(content, "package.json"), "w") as f:
        f.write("{}")
    child = "import os,time; open('child.pid','w').write(str(os.getpid())); time.sleep(300)"
    stdin_srv = ("import sys; sys.stderr.write('Done!\\n'); sys.stderr.flush(); "
                 "[sys.exit(0) for line in sys.stdin if line.strip() == 'stop']")
    with open(os.path.join(proj, "project.toml"), "w", encoding="utf-8") as f:
        f.write(textwrap.dedent("""
        [project]
        name = "dummy"
        runs_dir = "{lab_data}\\\\runs_dummy"
        plugin = "plugin.py"

        [kinds.fake]
        exe = %(py)s
        ports = ["f2f"]
        f2f = "f2f"
        args = [%(fake)s, "{port.f2f}", "{param.delay}"]
        params = { delay = 0, packdir = %(content)s }
        default_log = "stdout"
        prepare = [
          { action = "write", path = "cfg.json", json = { port = "{port.f2f}", who = "{owner}" } },
          { action = "junction", link = "content\\\\packx", target = "{param.packdir}" },
        ]
        ready = [
          { f2f = "hello", timeout = 20 },
          { pump_log = "\\\\[fake\\\\] ready marker", stream = "stdout", max_frames = 20 },
        ]
        stop = [ { f2f = "quit", wait_exit = 5 } ]

        [kinds.tree]
        exe = "C:\\\\Windows\\\\System32\\\\cmd.exe"
        args = ["/c", %(py)s, "-c", %(child)s]

        [kinds.stdin]
        exe = %(py)s
        args = ["-c", %(stdin)s]
        stdin = true
        ready = [ { log = "Done!", stream = "stderr", timeout = 20 } ]
        stop = [ { stdin = "stop\\n", wait_exit = 5 } ]

        [kinds.survivor]
        exe = %(py)s
        args = ["-c", "import time; time.sleep(300)"]
        kill_on_close = false
        """) % {"py": toml_str(PY), "fake": toml_str(FAKE), "content": toml_str(content), "child": toml_str(child),
                "stdin": toml_str(stdin_srv)})
    with open(os.path.join(proj, "plugin.py"), "w", encoding="utf-8") as f:
        f.write("PLUGIN_VERSION = 1\ndef register(api):\n"
                "    api.feature('hello2', lambda ctx, a: ctx.call(a['lease'], 'hello'), 'hello via plugin')\n")
    return os.path.join(tmpdir_win, "projects")
