"""labd — демон лаборатории (Windows, python_win из machine.toml). Только 127.0.0.1.

  <python_win> bin\\labd.py [--port 25700]        (обычно его поднимает labctl.py start)
Один экземпляр на порт: мьютекс Local\\voxelcore_labd_<порт> + занятый порт. Лог — <data>\\labd.log.
Этап 5: --isolated --starter <владелец> — изолированный демон (lab daemon start --isolated); --after-pid N — подождать
выхода прежнего демона (перезапуск/upgrade изнутри демона: новый процесс поднимается через WMI до выхода старого)."""
import argparse
import logging
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if REPO not in sys.path:
    sys.path.insert(0, REPO)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int)
    ap.add_argument("--config")
    ap.add_argument("--data", help="data dir (tests: a temp dir)")
    ap.add_argument("--ports", help="lease port range, e.g. 25660-25669")
    ap.add_argument("--projects", help="extra project dirs (os.pathsep-separated)")
    ap.add_argument("--no-watch", action="store_true", help="do not mirror VC_ROOT\\latest.log")
    ap.add_argument("--isolated", action="store_true", help="isolated test daemon (stage 5): banner, starter rights")
    ap.add_argument("--starter", help="owner who started the isolated daemon (daemon-level rights on it)")
    ap.add_argument("--after-pid", type=int, help="wait until this pid (the previous daemon) exits")
    o = ap.parse_args()
    argv = []
    skip = False
    for a in sys.argv[1:]:                    # аргументы для перезапуска изнутри демона (без --after-pid)
        if skip:
            skip = False
            continue
        if a == "--after-pid":
            skip = True
            continue
        if a.startswith("--after-pid="):
            continue
        argv.append(a)
    if o.after_pid:
        import psutil
        try:
            psutil.Process(o.after_pid).wait(60)
        except psutil.NoSuchProcess:
            pass
        except psutil.TimeoutExpired:
            pass
    # WMI-запуск не передаёт окружение вызывающего: всё — аргументами
    for opt, env in ((o.port, "LAB_PORT"), (o.config, "LAB_CONFIG"), (o.data, "LAB_DATA"), (o.ports, "LAB_PORTS"),
                     (o.projects, "LAB_PROJECTS"), (o.no_watch or None, "LAB_NO_WATCH"),
                     (o.isolated or None, "LAB_ISOLATED"), (o.starter, "LAB_STARTER")):
        if opt:
            os.environ[env] = str(opt)
    from vclab import config
    from vclab.leases import procs
    cfg = config.load()
    cfg["daemon"]["argv"] = argv
    cfg["daemon"]["after_pid"] = o.after_pid
    host, port = cfg["daemon"]["host"], cfg["daemon"]["port"]
    assert host == "127.0.0.1", "labd listens on loopback only (no firewall prompts, no LAN access)"
    os.makedirs(cfg["daemon"]["data"], exist_ok=True)
    log_path = os.path.join(cfg["daemon"]["data"], "labd.log")
    if sys.stdout is None or not sys.stdout.isatty():
        f = open(log_path, "a", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = f
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(message)s")

    import win32api
    import win32event
    import winerror
    mutex = win32event.CreateMutex(None, False, "Local\\voxelcore_labd_%d" % port)
    if win32api.GetLastError() == winerror.ERROR_ALREADY_EXISTS:
        logging.error("labd already running on port %d", port)
        return 3
    procs.quiet_errors()
    from vclab.daemon.service import Lab
    from vclab.daemon.api import create_app
    import uvicorn
    lab = Lab(cfg)
    logging.info("labd pid %d on %s:%d, data %s%s", os.getpid(), host, port, cfg["daemon"]["data"],
                 " ISOLATED (starter %s)" % cfg["daemon"].get("starter") if cfg["daemon"].get("isolated") else "")
    app = create_app(lab)
    uvicorn.run(app, host=host, port=port, log_level="warning", access_log=False)
    lab.shutdown()
    del mutex
    return 0


if __name__ == "__main__":
    sys.exit(main())
