"""CLI проекта: `lab template <...>` (точка расширения vclab/cli/lab.py: projects/<имя>/cli.py с run(c, argv, opt)).
c — LabClient демона (c.get/c.post), opt — разбор ключей как в lab.py. Возвращает код выхода."""
import json


def run(c, argv, opt):
    sub = argv.pop(0) if argv else "status"
    if sub == "status":
        r = c.post("/call/template.status", {"args": {"lease": opt(argv, "--lease")}})
        print(json.dumps(r, ensure_ascii=False, indent=1))
        return 0 if r.get("ok") else 1
    print("lab template status [--lease L]")
    return 2
