"""Job Object: дерево cmd.exe -> python (внук) целиком в Job; TerminateJobObject убивает обоих; смерть видна сразу."""
import os
import time

import psutil

from conftest import PY
from vclab.leases import procs


def _tree(tmp, job, name="tree"):
    marker = os.path.join(tmp, "child.pid")
    code = "import os,time; open(r'%s','w').write(str(os.getpid())); time.sleep(120)" % marker
    p = procs.spawn(job, name, ["cmd.exe", "/c", PY, "-c", code], tmp,
                    os.path.join(tmp, "logs", name + ".out"), os.path.join(tmp, "logs", name + ".err"))
    end = time.time() + 20
    while not os.path.exists(marker) and time.time() < end:
        time.sleep(0.05)
    with open(marker) as f:
        child = int(f.read())
    return p, child


def test_job_kills_process_tree(tmpdir_win):
    job = procs.Job("t1")
    p, child = _tree(tmpdir_win, job)
    assert psutil.pid_exists(p.pid) and psutil.pid_exists(child)
    assert {p.pid, child} <= set(job.pids()), (p.pid, child, job.pids())
    t0 = time.time()
    job.terminate()
    assert p.wait(5)
    end = time.time() + 5
    while psutil.pid_exists(child) and time.time() < end:
        time.sleep(0.05)
    assert not psutil.pid_exists(child)
    assert procs.describe_exit(p.exit_code) == "killed by lab (TerminateJobObject)"
    print("tree killed in %.3f s" % (time.time() - t0))
    job.close()


def test_kill_on_close(tmpdir_win):
    job = procs.Job("t2")
    p, child = _tree(tmpdir_win, job)
    job.close()  # дескриптор закрыт (как при падении демона) -> ОС убивает дерево
    end = time.time() + 5
    while (psutil.pid_exists(child) or p.alive()) and time.time() < end:
        time.sleep(0.05)
    assert not psutil.pid_exists(child) and not p.alive()


def test_exit_code_and_callback(tmpdir_win):
    job = procs.Job("t3")
    seen = []
    p = procs.spawn(job, "exit7", [PY, "-c", "import sys; print('hi'); sys.exit(7)"], tmpdir_win,
                    os.path.join(tmpdir_win, "o.log"), os.path.join(tmpdir_win, "e.log"))
    p.on_exit.append(lambda pr: seen.append(pr.exit_code))
    assert p.wait(10)
    end = time.time() + 2
    while not seen and time.time() < end:
        time.sleep(0.02)
    assert seen == [7] and p.info()["exit"] == "exit 7"
    with open(os.path.join(tmpdir_win, "o.log"), "rb") as f:
        assert f.read().strip() == b"hi"
    assert procs.describe_exit(0xC0000005 - (1 << 32)) == "0xC0000005 access violation"
    job.close()
