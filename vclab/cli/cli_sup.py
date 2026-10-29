"""Команды CLI этапа 6 (supervisor, ядро). Вызывается из lab.py; только клиент (демон не нужно перезапускать).

  lab sup state|incidents|events|accounts|bans|counters|tariffs [--group G] [--last N]    общее ядро (core.sup)

Команды проектов поверх supervisor (`lab <проект> ...`) — в projects/<проект>/cli.py (точка расширения CLI, lab.py).
"""
import json


def _call(c, feature, args, timeout=600.0):
    r = c.post("/call/%s" % feature, {"args": args}, timeout=timeout)
    return r, (r.get("result") if r.get("ok") else None)


def _out(r, res):
    print(json.dumps(res if res is not None else r, ensure_ascii=False, indent=1, default=str))
    return 0 if res is not None else 1


def run(c, cmd, argv, opt):
    if cmd == "sup":
        act = argv[0] if argv else "state"
        a = {"action": act}
        for k in ("--group", "--last", "--prefix", "--id"):
            v = opt(argv, k)
            if v is not None:
                a[k[2:]] = int(v) if k == "--last" else v
        return _out(*_call(c, "core.sup", a))
    print(__doc__)
    return 2
