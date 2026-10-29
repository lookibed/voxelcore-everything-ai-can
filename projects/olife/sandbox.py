"""[С 02.10 (волна 2 olife) дескриптор использует tools/olife/gateway_dev.py и sandbox_stub.py; этот файл — только для
теста лаборатории на фейковых процессах (tests/test_olife_session.py).]
Песочница Olife — ЗАГЛУШКА лаборатории (рантайм выбирается отдельно, OLIFE_SANDBOX.md): процесс-сервис под арендой с
портом управления (протокол F2F лаборатории). Пользовательский код НЕ исполняется: `exec` отвечает отказом
{denied: true, reason: "placeholder: no runtime"}. Нужна, чтобы обвязка негативных сценариев (попытки выхода из
песочницы: файл-канарейка не создан, процесс жив, ответ в бюджете) была готова до настоящего рантайма.
  python sandbox.py --f2f <порт> --dir <каталог экземпляра>
Команды: hello, exec {owner, code, fuel}, stats, quit."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ctlport  # noqa: E402

S = {"started": time.time(), "exec": 0, "denied": 0, "owners": {}}


def do_exec(args):
    S["exec"] += 1
    S["denied"] += 1
    o = str(args.get("owner") or "?")
    S["owners"][o] = S["owners"].get(o, 0) + 1
    return {"denied": True, "reason": "placeholder: no runtime", "effects": [], "fuel_used": 0,
            "code_len": len(str(args.get("code") or ""))}


def stats(args):
    return dict(S, uptime_s=round(time.time() - S["started"], 2))


def main():
    a = ctlport.argmap(sys.argv[1:])
    ctlport.serve(a["f2f"], {"exec": do_exec, "stats": stats}, "olife-sandbox")
    print("[olife_sandbox] ready (placeholder: no runtime, every exec is denied)", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
