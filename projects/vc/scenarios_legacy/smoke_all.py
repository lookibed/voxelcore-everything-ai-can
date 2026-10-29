#!/usr/bin/env python3
"""Smoke-проверка всего, что работает на wasmrt, в настоящем движке (через функции MCP-сервера).

    python3 tools/scenarios/smoke_all.py [wasm4] [packs] [eagler]   # по умолчанию всё

- wasm4  — все картриджи WASM-4 из export/wasm4carts (wasm4_all.lua), эталон ok 151, fail 0.
- packs  — страница wasmrt с манифестами паков: программа стартует и пишет fps, без ошибок.
- eagler — Eaglercraft: старт, профиль, главное меню, одиночная игра, экран создания мира.

Код выхода — число провалов. Движок запускается и перезапускается сам (vc_start restart).
Не запускать, пока ресурсы ПК заняты другими задачами: замеры и таймауты поплывут.
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "mcp"))
import voxelcore_mcp as vc  # noqa: E402

ROOT = vc.VC_ROOT
failed = 0


def check(what, ok, detail=""):
    global failed
    if not ok:
        failed += 1
    print("%s %s%s" % ("OK  " if ok else "FAIL", what, ("  | " + str(detail)) if detail else ""), flush=True)


def run_wasm4():
    r = vc.tool_vc_start({"script": "user:tools/scenarios/wasm4_all.lua", "restart": True,
                          "wait_for": r"\[wasm4_all\] done", "timeout": 1500})
    text = r["content"][0]["text"]
    summary = [l for l in vc.read_log().splitlines() if "[wasm4_all] summary" in l]
    line = summary[-1] if summary else text
    m = re.search(r"ok (\d+), fail (\d+)", line)
    check("wasm4_all: ok 151, fail 0", bool(m) and m.group(1) == "151" and m.group(2) == "0", line.split("] ", 1)[-1])


PACKS = ["wasmdemo:wasm.json", "pong:wasm_canvas.json", "doom:wasm.json", "quake:wasm.json"]


def run_packs():
    for manifest in PACKS:
        with open(os.path.join(ROOT, "export", "wasmrt_manifest.txt"), "w") as f:
            f.write(manifest + "\n")
        name = re.escape(manifest)
        vc.tool_vc_start({"script": "user:tools/scenarios/wasmrt_page.lua", "restart": True,
                          "wait_for": r"\[wasmrt\] %s (started|:)" % name, "timeout": 180})
        time.sleep(5)  # программа должна проработать без ошибки
        log = vc.read_log().splitlines()
        started = [l for l in log if "[wasmrt] %s started" % manifest in l]
        lines = [l for l in log if "[wasmrt] %s:" % manifest in l]
        errors = [l for l in lines if " fps" not in l]
        fps = [l for l in lines if " fps" in l]
        detail = errors[-1] if errors else (fps[-1] if fps else (started[-1] if started else "не стартовал"))
        check("pack %s: стартовал и работает без ошибок" % manifest, bool(started) and not errors,
              detail.split("] ", 1)[-1])


def run_eagler():
    T = vc.TOOLS
    r = T["eag_start"][0]({"timeout": 240})
    check("eaglercraft: старт до первого экрана", not r.get("isError"), r["content"][0]["text"].split("\n")[1:2])
    if r.get("isError"):
        return
    r = T["eag_path"][0]({"steps": ["Done", "Singleplayer", "Create New World", "Create New World"], "wait": 10})
    text = r["content"][0]["text"]
    check("eaglercraft: меню -> одиночная игра -> создание мира", "экран GuiCreateWorld" in text,
          text.replace("\n", " / ")[:300])


def main():
    parts = sys.argv[1:] or ["wasm4", "packs", "eagler"]
    if "wasm4" in parts:
        run_wasm4()
    if "packs" in parts:
        run_packs()
    if "eagler" in parts:
        run_eagler()
    vc.tool_vc_stop({})
    print("-- failed %d" % failed)
    sys.exit(failed)


if __name__ == "__main__":
    main()
