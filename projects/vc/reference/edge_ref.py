#!/usr/bin/env python3
"""Эталон Eaglercraft в headless Edge (Windows) — обёртка из WSL.

  edge_ref.py serve      — раздать upstream/javascript на :8765 (фон)
  edge_ref.py start      — запустить headless Edge с CDP на 127.0.0.1:9222 (профиль D:\\Prog\\VoxelCore\\edge_ref_profile)
  edge_ref.py run <сценарий.json>  — выполнить сценарий Windows-node (tools/reference/edge_ref.js)
  edge_ref.py stop       — закрыть Edge headless

Порт 9222 доступен только внутри Windows (брандмауэр), поэтому CDP-клиент — Windows-node.
"""
import os, subprocess, sys, time

VC_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JS_DIR = "/root/Spider/tests/manual/real-world-eaglercraft/upstream/javascript"
PS = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
PROFILE = r"D:\Prog\VoxelCore\edge_ref_profile"
NODE = r"C:\Program Files\nodejs\node.exe"


def win_path(p):
    p = os.path.abspath(p)
    assert p.startswith("/mnt/"), p
    drive = p[5]
    return drive.upper() + ":" + p[6:].replace("/", "\\")


def ps(cmd, timeout=120):
    r = subprocess.run([PS, "-NoProfile", "-Command", cmd], capture_output=True, text=True, errors="replace", timeout=timeout,
                       cwd=VC_ROOT)
    return (r.stdout + r.stderr).replace("\r", "")


def serve():
    subprocess.Popen([sys.executable, "-m", "http.server", "8765", "--bind", "0.0.0.0"], cwd=JS_DIR,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    time.sleep(1)
    print("serving", JS_DIR, "on :8765")


def start(fresh=False):
    args = ["--headless=new", "--remote-debugging-port=9222", "--window-size=854,480",
            "--force-device-scale-factor=1", "--no-first-run", "--disable-gpu-vsync",
            "--user-data-dir=" + PROFILE, "about:blank"]
    if fresh:
        ps(f"Remove-Item -Recurse -Force '{PROFILE}' -ErrorAction SilentlyContinue")
    arg_list = ",".join("'" + a + "'" for a in args)
    print(ps(f"(Start-Process -FilePath '{EDGE}' -ArgumentList {arg_list} -PassThru).Id").strip())
    for _ in range(20):
        out = ps("try { (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:9222/json/version -TimeoutSec 3).Content } catch { '' }")
        if "webSocketDebuggerUrl" in out:
            print("cdp ok")
            return
        time.sleep(0.5)
    print("cdp: нет ответа")


def run(script):
    js = win_path(os.path.join(VC_ROOT, "tools", "reference", "edge_ref.js"))
    out = ps(f"& '{NODE}' '{js}' '{win_path(script)}'", timeout=600)
    print(out)


def stop():
    print(ps("Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { $_.CommandLine -like '*edge_ref_profile*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; 'stopped'").strip())


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "serve": serve()
    elif cmd == "start": start("--fresh" in sys.argv)
    elif cmd == "run": run(sys.argv[2])
    elif cmd == "stop": stop()
    else: print(__doc__)
