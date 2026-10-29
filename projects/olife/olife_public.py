"""olife: игра с друзьями по сети (16.10, агент olife_friends; agents/research/OLIFE_PUBLIC_PLAY.md).

Публичный режим стека игрока (`lab play olife --user --public`, `lab olife play-up --public`, `play.bat public`):
шлюз (Rust `--public --packs-public`), сервис билетов (`--public 1`) и раздача паков слушают 0.0.0.0 на ФИКСИРОВАННЫХ
портах `[play.public]` проекта (перекрытие — `<repo>\\projects\\olife\\external\\play\\server.toml`, секция `[public]`); admin/f2f-порты
шлюза, сервиса билетов, мира, песочницы и демон — только 127.0.0.1. Друг знает одну строку `ip:port` (+ необязательный
отпечаток ключа `#xxxx`): клиент спрашивает шлюз `InfoRequest` -> `ServerInfo` (порты билетов/паков, ключ запечатывания,
id шлюза) — файл `server_info.json` пишет play_up, шлюз перечитывает его на каждый запрос.

Здесь: конфиг портов и их проверка (пересечения с лабораторией, занятость), адреса хоста (LAN через Get-NetIPAddress,
внешний — echo-сервис), строка приглашения (`lab olife ip`, `lab olife invite [НИК]`), сборка клиента другу
(`lab olife bundle`), шаги сценариев `olife_public` и `olife_bundle`. Подключается из plugin.py (`_pub()`, перезагрузка
по mtime)."""
import hashlib
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import time
import zipfile

P = {}

PLAY_DIR = os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")), "projects", "olife", "external", "play")
SERVER_TOML = os.path.join(PLAY_DIR, "server.toml")
DIST = os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")), "projects", "olife", "external", "dist")
DEFAULTS = {"gateway": 27750, "auth": 27751, "packs": 27752, "whitelist": True, "name": "Olife", "motd": ""}
ECHO = ("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")
PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
VIRTUAL = ("vethernet", "wsl", "virtualbox", "vmware", "hyper-v", "loopback")
CREATE_NO_WINDOW = 0x08000000


def bind(g):
    P.update(g)


def _play():
    return P["_play"]()


def _menu():
    return P["_menu"]()


# ============================================================================================== порты
def public_cfg(lab):
    """[play.public] проекта, поверх — [public] из <repo>\\projects\\olife\\external\\play\\server.toml (если есть)"""
    c = dict(DEFAULTS)
    proj = lab.projects.get("olife")
    c.update(((proj.raw or {}).get("play") or {}).get("public") or {})
    src = ["project.toml [play.public]"]
    if os.path.exists(SERVER_TOML):
        import tomllib
        with open(SERVER_TOML, "rb") as f:
            d = tomllib.load(f)
        c.update(d.get("public") or {})
        src.append(SERVER_TOML + " [public]")
    for k in ("gateway", "auth", "packs"):
        c[k] = int(c[k])
        if not 1024 <= c[k] <= 65535:
            raise ValueError("[play.public] %s = %s: port 1024..65535" % (k, c[k]))
    c["whitelist"] = bool(c.get("whitelist", True))
    c["source"] = src
    return c


def reserved(lab):
    """диапазоны портов лаборатории: публичные порты Olife не должны в них попадать"""
    from labcore import admin
    d = int(lab.cfg["daemon"]["port"])
    out = [(d, d, "демон лаборатории"), (int(lab.cfg["ports"]["first"]), int(lab.cfg["ports"]["last"]), "пул аренд"),
           (25599, 25599, "лаунчер Eaglercraft"), (25791, 25793, "тестовые демоны лаборатории"),
           (admin.ISOLATED_PORTS[0], admin.ISOLATED_PORTS[1], "изолированные демоны"),
           (admin.ISOLATED_LEASE_BASE, admin.ISOLATED_LEASE_BASE + 10 * (admin.ISOLATED_PORTS[1] - admin.ISOLATED_PORTS[0])
            + 9, "аренды изолированных демонов")]
    return out


def netstat_listen():
    """[(addr, port, pid)] слушающих TCP-сокетов (netstat -ano, Windows)"""
    try:
        r = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, timeout=15,
                           creationflags=CREATE_NO_WINDOW)
        text = r.stdout.decode("cp866", "replace")
    except Exception:                                   # noqa: BLE001
        return []
    out = []
    for line in text.splitlines():
        p = line.split()
        if len(p) >= 5 and p[0].upper() == "TCP" and p[3].upper() in ("LISTENING", "ПРОСЛУШИВАНИЕ"):
            addr, _, port = p[1].rpartition(":")
            try:
                out.append((addr.strip("[]"), int(port), int(p[4])))
            except ValueError:
                pass
    return out


def check_ports(lab, pub):
    """публичные порты: разные, вне диапазонов лаборатории, свободны (никто не слушает, bind 0.0.0.0 проходит)"""
    ports = {"gateway": pub["gateway"], "auth": pub["auth"], "packs": pub["packs"]}
    if len(set(ports.values())) != 3:
        raise RuntimeError("[play.public]: ports must differ: %s" % ports)
    for role, p in ports.items():
        for a, b, what in reserved(lab):
            if a <= p <= b:
                raise RuntimeError("[play.public] %s = %d: inside %d..%d (%s) — choose another port in %s" % (
                    role, p, a, b, what, " / ".join(pub["source"])))
    lis = netstat_listen()
    busy = []
    for role, p in ports.items():
        who = [(a, pid) for a, port, pid in lis if port == p]
        if who:
            busy.append("%s %d: listened by pid %s on %s" % (role, p, ",".join(str(x[1]) for x in who),
                                                              ",".join(x[0] for x in who)))
            continue
        s = socket.socket()
        try:
            if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
                s.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            s.bind(("0.0.0.0", p))
        except OSError as exc:
            busy.append("%s %d: %s" % (role, p, exc))
        finally:
            s.close()
    if busy:
        raise RuntimeError("public ports busy (another Olife server? `lab olife play-status`, `play.bat down`): "
                           + "; ".join(busy))
    return {"ports": ports, "free": True, "checked": len(lis)}


def write_server_info(base, pub, auth_pub):
    """файл ServerInfo для шлюза (--info): перечитывается на каждый InfoRequest"""
    p = os.path.join(base, "server_info.json")
    d = {"name": str(pub.get("name") or "Olife")[:64], "auth_port": pub["auth"], "auth_scheme": "https",
         "auth_pub": auth_pub, "packs_port": pub["packs"], "public": True, "whitelist": bool(pub["whitelist"]),
         "motd": str(pub.get("motd") or "")[:256]}
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    return p


def public_whitelist(lab, pub, gw_id):
    """вайтлист сервера включается в публичном режиме ([play.public] whitelist = true): вход по нику — только друзьям"""
    if not pub.get("whitelist"):
        st = _menu().wl_state(lab, gw_id)
        return {"enabled": st["enabled"], "names": st["names"], "forced": False}
    st = _menu().wl_op(lab, "on", gw_id, by="play_up", via="public")
    return {"enabled": st["enabled"], "names": st["names"], "forced": True}


def listeners(lab, info):
    """слушающие сокеты процессов стека: роль -> [адрес:порт] (проверка: наружу только шлюз, билеты, паки)"""
    pids = {}
    for role, name in (info.get("leases") or {}).items():
        l = lab.leases.get(name)
        if l is not None and l.proc is not None:
            pids[l.proc.pid] = role
            for jp in (l.job.pids() if getattr(l, "job", None) else []):
                pids.setdefault(jp, role)
    out = {}
    for a, port, pid in netstat_listen():
        if pid in pids:
            out.setdefault(pids[pid], []).append("%s:%d" % (a, port))
    for r in out:
        out[r] = sorted(set(out[r]))
    return out


# ============================================================================================== адреса и приглашение
def _primary_ip():
    """адрес интерфейса маршрута по умолчанию (UDP connect: пакеты не уходят)"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def lan_ips():
    """IPv4-адреса хоста: [{ip, alias, kind: lan|vpn|virtual, primary}] без loopback и 169.254"""
    rows = []
    try:
        cmd = ("[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-NetIPAddress -AddressFamily IPv4 | "
               "Select-Object IPAddress,InterfaceAlias,PrefixOrigin | ConvertTo-Json -Compress")
        r = subprocess.run([PS, "-NoProfile", "-Command", cmd], capture_output=True, timeout=20,
                           creationflags=CREATE_NO_WINDOW)
        d = json.loads(r.stdout.decode("utf-8", "replace") or "[]")
        rows = d if isinstance(d, list) else [d]
    except Exception:                                   # noqa: BLE001
        rows = [{"IPAddress": a, "InterfaceAlias": "?", "PrefixOrigin": "?"}
                for a in sorted({x[4][0] for x in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)})]
    prim = _primary_ip()
    out = []
    for x in rows:
        ip = str(x.get("IPAddress") or "")
        try:
            a = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if a.is_loopback or a.is_link_local:
            continue
        alias = str(x.get("InterfaceAlias") or "")
        kind = "lan"
        if any(v in alias.lower() for v in VIRTUAL):
            kind = "virtual"
        elif a in ipaddress.ip_network("26.0.0.0/8") or a in ipaddress.ip_network("100.64.0.0/10") or \
                any(v in alias.lower() for v in ("radmin", "zerotier", "tailscale", "hamachi")):
            kind = "vpn"                             # Radmin VPN 26.x, Tailscale/CGNAT 100.64/10, ZeroTier
        out.append({"ip": ip, "alias": alias, "kind": kind, "primary": ip == prim})
    out.sort(key=lambda r: (not r["primary"], r["kind"] != "lan", r["ip"]))
    return out


def external_ip(timeout=4.0):
    """внешний адрес через публичный echo-сервис -> {ip, source} | {ip: None, error}"""
    import urllib.request
    errs = []
    for url in ECHO:
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "curl/8"}),
                                        timeout=timeout) as r:
                t = r.read(64).decode("ascii", "replace").strip()
            ipaddress.ip_address(t)
            return {"ip": t, "source": url}
        except Exception as exc:                        # noqa: BLE001
            errs.append("%s: %s" % (url, str(exc)[:80]))
    return {"ip": None, "error": "; ".join(errs)}


def play_pub_key(base=PLAY_DIR):
    """ключ запечатывания постоянного сервера (<repo>\\projects\\olife\\external\\play\\keys) -> b64url | None (сервер ещё не поднимался)"""
    p = os.path.join(base, "keys", "auth_seal_x25519.key")
    if not os.path.exists(p):
        return None
    _play()._tools()
    import olife_ticket as T
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization as S
    with open(p, encoding="utf-8") as f:
        sk = X25519PrivateKey.from_private_bytes(bytes.fromhex(f.read().strip()))
    return T.b64u(sk.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw))


def fingerprint(pub):
    return (pub or "")[:12]


def invite_text(lab, pub, auth_pub, external=True):
    ips = lan_ips()
    fp = fingerprint(auth_pub)
    suf = ("#" + fp) if fp else ""
    lan = next((r["ip"] for r in ips if r["kind"] == "lan"), None)
    vpn = [r["ip"] for r in ips if r["kind"] == "vpn"]
    ext = external_ip() if external else {"ip": None, "error": "not asked"}
    return {"lan": ("%s:%d%s" % (lan, pub["gateway"], suf)) if lan else None,
            "vpn": ["%s:%d%s" % (v, pub["gateway"], suf) for v in vpn],
            "external": ("%s:%d%s" % (ext["ip"], pub["gateway"], suf)) if ext.get("ip") else None,
            "external_ip": ext, "fingerprint": fp, "lan_ips": ips, "port": pub["gateway"]}


def f_ip(ctx, args):
    pub = public_cfg(ctx.lab)
    # ключ: стека, который его попросил (play_up/коляска передают свой), иначе — постоянного сервера игры
    inv = invite_text(ctx.lab, pub, args.get("auth_pub") or play_pub_key(), external=not args.get("no_external"))
    L = ["Адреса этого ПК (Olife, публичный режим: шлюз %d, билеты %d, паки %d — TCP):" % (
        pub["gateway"], pub["auth"], pub["packs"])]
    for r in inv["lan_ips"]:
        L.append("  %-16s %-8s %s%s" % (r["ip"], {"lan": "LAN", "vpn": "VPN", "virtual": "вирт."}[r["kind"]], r["alias"],
                                        "  <- маршрут по умолчанию" if r["primary"] else ""))
    e = inv["external_ip"]
    L.append("  внешний IP: %s" % (("%s (по %s; если на роутере WAN-адрес другой — провайдер за CGNAT, проброс не "
                                    "поможет, нужен VPN)" % (e["ip"], e["source"])) if e.get("ip") else
                                   "не спрашивали (--no-external)" if e.get("error") == "not asked" else
                                   "НЕ УДАЛОСЬ УЗНАТЬ (%s)" % (e.get("error") or "")[:160]))
    L.append("Строка для друга: в своей сети — %s; через интернет — %s%s" % (
        inv["lan"] or "-", inv["external"] or "-",
        "; через VPN — " + ", ".join(inv["vpn"]) if inv["vpn"] else ""))
    if not inv["fingerprint"]:
        L.append("(ключа сервера ещё нет: поднимите сервер один раз — `play.bat public` — тогда в строке будет #отпечаток)")
    return dict(inv, text="\n".join(L), ports={k: pub[k] for k in ("gateway", "auth", "packs")})


def f_invite(ctx, args):
    """play.bat friend НИК: ник в вайтлист сервера игры + строка приглашения"""
    lab = ctx.lab
    pub = public_cfg(lab)
    out = {}
    name = args.get("name")
    scope = args.get("scope") or _play().GW_ID
    if name:
        out["whitelist"] = _menu().wl_op(lab, "add", scope, name, by=args.get("by") or ctx.owner,
                                         via=args.get("via") or "cli")
        if not out["whitelist"].get("ok"):
            return dict(out, ok=False, text="ник %r не подходит: %s" % (name, out["whitelist"].get("reason")))
    ip = f_ip(ctx, args)
    st = _menu().wl_state(lab, scope)
    fc = P["_fraud"]().cfg(lab)
    L = []
    if name:
        L.append("Ник %s добавлен в вайтлист сервера (%s; всего %d: %s)." % (name, "включён" if st["enabled"] else
                 "ВЫКЛЮЧЕН — сейчас пустят любой свободный ник; включится при `play.bat public`", len(st["names"]),
                 ", ".join(st["names"])))
    L.append(ip["text"])
    L.append("Другу: распакуйте olife_client_<дата>.zip (lab olife bundle), запустите OLIFE.bat, в поле «Шлюз» введите "
             "строку выше, ник — %s, «Войти»." % (name or "<его ник>"))
    L.append("Друзья за одним роутером (один внешний IP) — не больше %s сессий с адреса: `lab olife fraud set "
             "sessions_per_ip 6`." % fc.get("sessions_per_ip"))
    return dict(out, ok=True, invite=ip, text="\n".join(L))


# ============================================================================================== сборка клиента другу
SETTINGS = """# Olife: настройки VoxelCore 0.32 для друга (lab olife bundle). Остальное — умолчания движка.
[display]
width = 1280
height = 720
framerate = -1

[chunks]
load-distance = 12
load-speed = 4

[ui]
language = "ru_RU"

[audio]
enabled = true
"""

BAT = r"""@echo off
rem Olife: клиент на VoxelCore 0.32 (сборка lab olife bundle). Подробно - ПРОЧТИ.txt рядом.
cd /d "%~dp0"
start "" "%~dp0VoxelCore.exe" --dir "%~dp0." --script "%~dp0content\olife_client\scripts\app\olife.lua"
"""

README = """Olife — клиент для игры у друга (VoxelCore 0.32, сборка {date})
1. Распакуйте архив целиком в любую папку (путь лучше без русских букв), ничего не устанавливается.
2. Запустите OLIFE.bat — откроется меню Olife (VoxelCore 0.32; Windows может спросить про незнакомую программу — «Подробнее» → «Выполнить в любом случае»).
3. В поле «Шлюз (ip:port)» введите строку от хоста, например 203.0.113.7:27750#AbCdEf123456 (часть после # — отпечаток ключа сервера, можно без неё).
4. В поле «Ник» — ник, который хост добавил в вайтлист (латиница, цифры, _ . -), «Войти».
5. Экран статуса показывает шаги: сведения о сервере, билет, шлюз, паки, мир. Ошибка — с кодом и причиной; «Повторить» / «Назад».
   «нет соединения со шлюзом» — неверный адрес, сервер выключен или порты не проброшены; «нет в вайтлисте» — попросите хоста: play.bat friend <ваш ник>;
   «сервис билетов недоступен» — у хоста не открыт второй порт (27751); «ключ сервера не совпал» — спросите у хоста свежую строку; «бан» — к хосту.
6. Выход: Esc → «Сохранить и выйти в меню», затем «Выход». Журнал движка — latest.log в этой папке (пришлите хосту, если что-то сломалось).
Сборка: {files} файлов паков, манифест {version}…; VoxelCore 0.32 {origin}.
"""


def _skip(name):
    return name.endswith(".bak") or ".bak." in name or name.endswith(".pyc") or name.startswith("olife_caret_probe")


def _copytree(src, dst):
    """копия без junction/ссылок (их содержимое копируется настоящими файлами), без .bak/__pycache__/проб"""
    from labcore import supervise
    n = 0
    for dp, dns, fns in os.walk(src):
        dns[:] = sorted(d for d in dns if d not in supervise.SKIP_DIRS and not _skip(d))
        rel = os.path.relpath(dp, src)
        od = os.path.join(dst, rel) if rel != "." else dst
        os.makedirs(od, exist_ok=True)
        for fn in sorted(fns):
            if _skip(fn):
                continue
            shutil.copyfile(os.path.join(dp, fn), os.path.join(od, fn))
            n += 1
    return n


def bundle(lab, out=None, invite=None, keep_stage=False):
    """zip другу: стоковый VoxelCore 0.32 (exe, res, ORIGIN.txt) + КОПИИ паков olife_client, olife_proto + settings.toml +
    OLIFE.bat + ПРОЧТИ.txt (+ config\\olife_client\\menu.json с адресом, если --invite). -> отчёт (путь, sha256, размер,
    манифест паков = раздаче сервера)"""
    from labcore import config, supervise
    t0 = time.time()
    eng = _play().engine_v032(lab)
    root = eng["root"]
    out = out or DIST
    date = time.strftime("%Y%m%d")
    name = "olife_client_%s" % date
    os.makedirs(out, exist_ok=True)
    stage = os.path.join(out, "_stage_" + name)
    if os.path.exists(stage):
        shutil.rmtree(stage)
    top = os.path.join(stage, name)
    os.makedirs(top)
    shutil.copyfile(os.path.join(root, "VoxelCore.exe"), os.path.join(top, "VoxelCore.exe"))
    if os.path.exists(os.path.join(root, "ORIGIN.txt")):
        shutil.copyfile(os.path.join(root, "ORIGIN.txt"), os.path.join(top, "ORIGIN.txt"))
    nres = _copytree(eng["res"], os.path.join(top, "res"))
    packs = P["CLIENT_PACKS"]
    npk = {pk: _copytree(os.path.join(config.PACKS_DIR, pk), os.path.join(top, "content", pk)) for pk in packs}
    font = os.path.join(top, "content", "olife_client", "fonts", "olife_mono.ttf")
    with open(os.path.join(top, "settings.toml"), "w", encoding="utf-8", newline="\r\n") as f:
        f.write(SETTINGS)
    with open(os.path.join(top, "OLIFE.bat"), "w", encoding="cp866", newline="\r\n") as f:
        f.write(BAT)
    mine = supervise.pack_manifest(os.path.join(top, "content"), packs)
    server = supervise.pack_manifest(config.PACKS_DIR, packs)
    origin = ""
    try:
        with open(os.path.join(root, "ORIGIN.txt"), encoding="utf-8") as f:
            origin = " ".join(l.strip() for l in f.read().splitlines() if l.startswith("commit:"))[:80]
    except OSError:
        pass
    with open(os.path.join(top, "ПРОЧТИ.txt"), "w", encoding="utf-8-sig", newline="\r\n") as f:
        f.write(README.format(date=time.strftime("%d.%m.%Y"), files=mine["files"], version=mine["version"][:12],
                              origin=origin))
    with open(os.path.join(top, "olife_bundle_manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"version": mine["version"], "files": mine["files"], "server_version": server["version"],
                   "built": time.strftime("%Y-%m-%d %H:%M:%S"), "engine": origin,
                   "packs": {pk: [{"path": x["path"], "sha256": x["sha256"], "size": x["size"]} for x in v["files"]]
                             for pk, v in mine["packs"].items()}}, f, ensure_ascii=False, indent=1)
    if invite:
        d = os.path.join(top, "config", "olife_client")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "menu.json"), "w", encoding="utf-8") as f:
            json.dump({"last_addr": invite, "last_nick": "", "recent": []}, f)
    zpath = os.path.join(out, name + ".zip")
    tmp = zpath + ".tmp"
    nzip = 0
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for dp, dns, fns in os.walk(stage):
            dns.sort()
            for fn in sorted(fns):
                fp = os.path.join(dp, fn)
                z.write(fp, os.path.relpath(fp, stage).replace(os.sep, "/"))
                nzip += 1
    os.replace(tmp, zpath)
    h = hashlib.sha256()
    with open(zpath, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if not keep_stage:
        shutil.rmtree(stage, ignore_errors=True)
    return {"ok": True, "zip": zpath, "sha256": h.hexdigest(), "size": os.path.getsize(zpath), "files": nzip,
            "res_files": nres, "pack_files": npk, "font": os.path.exists(font) or None, "invite": invite,
            "manifest_version": mine["version"], "server_manifest_version": server["version"],
            "manifest_equal": mine["version"] == server["version"], "s": round(time.time() - t0, 2),
            "stage": stage if keep_stage else None}


def f_bundle(ctx, args):
    r = bundle(ctx.lab, args.get("out"), args.get("invite"))
    r["text"] = "zip: %s\nsha256 %s, %.1f МБ, %d файлов; паки: манифест %s (%s раздаче сервера)" % (
        r["zip"], r["sha256"], r["size"] / 1048576, r["files"], r["manifest_version"][:12],
        "=" if r["manifest_equal"] else "НЕ РАВЕН")
    return r


def register(api):
    obj = {"type": "object"}
    api.feature("ip", lambda ctx, a: P["_pub"]().f_ip(ctx, a),
                "olife_friends: host addresses (LAN via Get-NetIPAddress, external via an echo service) + invite "
                "strings ip:port#fingerprint for the public play ports {no_external?}", obj)
    api.feature("invite", lambda ctx, a: P["_pub"]().f_invite(ctx, a),
                "olife_friends: whitelist add <name> on the play server (gw-olife-play) + invite strings {name?}", obj)
    api.feature("bundle", lambda ctx, a: P["_pub"]().f_bundle(ctx, a),
                "olife_friends: client zip for a friend (stock VoxelCore 0.32 + copies of olife_client/olife_proto + "
                "OLIFE.bat + ПРОЧТИ.txt) {out? (D:\\\\Prog\\\\Olife\\\\dist), invite?}", obj)


# ============================================================================================== сценарии
def sc_start(sx, args):
    """olife_public / olife_bundle: коляска play_stack в сухом публичном режиме (копия мира, свои ключи, scope вайтлиста
    gw-olife-pubtest) — тот же код, что у `play.bat public`; клиенты — шаги"""
    gw_id = args.get("gw_id") or "gw-olife-pubtest"
    stack = sx.lease("play_stack", role="stack", params={"mode": "dry", "public": 1,
                                                          "daemon_port": sx.lab.cfg["daemon"]["port"]})
    sdir = sx.lab.lease_info(stack)["dir"]
    with open(os.path.join(sdir, "play_stack.json"), encoding="utf-8") as f:
        up = json.load(f)
    if up.get("gw_id") != gw_id:
        sx.log("note: stack gw_id %s (scenario asked %s)" % (up.get("gw_id"), gw_id))
    sx.data["public"] = up
    sx.data["play"] = up
    roles = dict(up["leases"])
    roles["stack"] = stack
    sx.data["session"] = {"session": up["session"], "group": up["group"], "leases": roles, "timing": up["timing"],
                          "gateway_port": up["gateway_port"],
                          "w4b": {"auth_url": "https://127.0.0.1:%d" % up["auth_port"], "gw_id": up["gw_id"],
                                  "auth_pub": up["auth_pub"], "auth_lease": roles.get("auth")}}
    sx.data["metrics"] = {"play_up": {k: up.get(k) for k in ("up_s", "timing", "public_cfg", "ports_check", "listen",
                                                              "whitelist", "invite", "server_info", "gw_id")}}
    sx.client = roles.get("world")


def sc_stop(sx):
    """клиенты -> коляска (play_down), тестовые записи (вайтлист scope теста, аккаунты ников, антифрод) — убрать"""
    pd = _pd(sx)
    m = sx.data.setdefault("metrics", {})
    rel = {}
    for r in [x for x in list(sx.leases) if x.startswith("client")] + ["stack"]:
        if r not in sx.leases:
            continue
        try:
            x = sx.lab.release(sx.leases[r], owner=sx.owner, reason="scenario-end")
            rel[sx.leases[r]] = {"exit": x.get("exit"), "forced_kill": x.get("forced_kill")}
        except Exception as exc:                        # noqa: BLE001
            rel[sx.leases[r]] = {"error": str(exc)}
        sx.leases.pop(r, None)
    m["release"] = rel
    grp = (sx.data.get("public") or {}).get("group")
    g = sx.lab.sup.groups.get(grp) if grp else None
    if g is not None and g.state != "down":
        m["group_down_fallback"] = True
        _play()._down_quiet(sx.lab.sup, grp, sx.owner)
    m["cleanup"] = cleanup(sx)
    m["public"] = {"checks": len(pd["checks"]), "ok": sum(1 for c in pd["checks"] if c["ok"]),
                   "failed": [c["name"] for c in pd["checks"] if not c["ok"]]}


def cleanup(sx):
    pd = _pd(sx)
    up = sx.data.get("public") or {}
    out = {}
    scope = up.get("gw_id")
    try:
        if scope and scope != _play().GW_ID:
            for n in list(_menu().wl_state(sx.lab, scope)["names"]):
                _menu().wl_op(sx.lab, "remove", scope, n, by=sx.owner, via="scenario")
            _menu().wl_op(sx.lab, "off", scope, by=sx.owner, via="scenario")
            out["whitelist"] = _menu().wl_state(sx.lab, scope)
        ips = sorted({x for x in pd["ips"]})
        out["fraud"] = P["_fraud"]().reset_test(sx.lab, ips, sorted(set(pd["accounts"])), [])
    except Exception as exc:                            # noqa: BLE001
        out["error"] = "%s: %s" % (type(exc).__name__, exc)
    return out


def _pd(sx):
    return sx.data.setdefault("pub", {"checks": [], "ips": [], "accounts": [], "details": {}})


def _ck(sx, name, ok, **detail):
    _pd(sx)["checks"].append({"name": name, "ok": bool(ok), "detail": detail or None})
    return bool(ok)


def _result(sx, name, rep, n0):
    d = _pd(sx)
    mine = d["checks"][n0:]
    bad = [x["name"] for x in mine if not x["ok"]]
    d["details"][name] = rep
    det = "; ".join("%s: %s" % (x["name"], json.dumps(x["detail"], ensure_ascii=False, default=str)[:300])
                    for x in mine if not x["ok"])
    return {"ok": not bad, "result": {"checks": len(mine), "ok": len(mine) - len(bad), "failed": bad, **rep},
            "error": ("failed: %s" % det) if bad else None}


def _lan(sx):
    up = sx.data["public"]
    if _pd(sx).get("lan"):
        return _pd(sx)["lan"], up["public_cfg"]["gateway"]
    ip = next((r["ip"] for r in lan_ips() if r["kind"] == "lan" and r["primary"]), None) or \
        next((r["ip"] for r in lan_ips() if r["kind"] == "lan"), None)
    if not ip:
        raise RuntimeError("no LAN address on this machine (Get-NetIPAddress): %s" % lan_ips())
    _pd(sx)["lan"] = ip
    if ip not in _pd(sx)["ips"]:
        _pd(sx)["ips"].append(ip)
    return ip, up["public_cfg"]["gateway"]


def _proto():
    _play()._tools()
    import importlib
    return importlib.import_module("olife_proto.client")


def info_request(host, port, src=None, timeout=4.0):
    """InfoRequest -> {"info": ServerInfo dict, "disconnect": (code, reason)} (как клиент olife_client:serverinfo)"""
    C = _proto()
    s = socket.create_connection((host, port), timeout=timeout, source_address=(src, 0) if src else None)
    out = {"local": s.getsockname()[0]}
    try:
        s.sendall(C.frame("InfoRequest", {"proto": C.VERSION, "engine": "lab"}))
        fr = C.framer()
        end = time.time() + timeout
        s.settimeout(0.2)
        while time.time() < end:
            try:
                d = s.recv(65536)
            except socket.timeout:
                continue
            if not d:
                break
            fr.feed(d)
            while True:
                x = fr.next()
                if x is None:
                    break
                n = C.NAMES[x[0]]
                m = C.decode_body(*x)
                if n == "ServerInfo":
                    out["info"] = m
                elif n == "Disconnect":
                    out["disconnect"] = (m["code"], m["reason"])
            if "disconnect" in out:
                break
    finally:
        s.close()
    return out


def st_ports(sx, args, step):
    """что слушает что: шлюз/билеты/паки — 0.0.0.0 на фиксированных портах; admin/f2f всех служб и демон — 127.0.0.1"""
    n0 = len(_pd(sx)["checks"])
    up = sx.data["public"]
    pub = up["public_cfg"]
    lis = listeners(sx.lab, up)
    rep = {"listen": lis, "cfg": {k: pub[k] for k in ("gateway", "auth", "packs")}, "source": pub.get("source")}
    gw, au = lis.get("gateway") or [], lis.get("auth") or []
    _ck(sx, "gateway client port 0.0.0.0:%d" % pub["gateway"], "0.0.0.0:%d" % pub["gateway"] in gw, gateway=gw)
    _ck(sx, "gateway packs port 0.0.0.0:%d" % pub["packs"], "0.0.0.0:%d" % pub["packs"] in gw, gateway=gw)
    _ck(sx, "auth service 0.0.0.0:%d" % pub["auth"], "0.0.0.0:%d" % pub["auth"] in au, auth=au)
    public = {"0.0.0.0:%d" % pub[k] for k in ("gateway", "auth", "packs")}
    game = up.get("game_port")
    # the world's internal port: network.tcp_open of 0.32 binds all interfaces (no host argument; the engine is not
    # changed) -> the world pack closes non-loopback peers at once (olife_world:net); checked below from the LAN address
    engine_wild = {"0.0.0.0:%d" % game, ":::%d" % game, ":%d" % game} if game else set()
    wild = sorted(a for r, xs in lis.items() for a in xs if (a.startswith("0.0.0.0:") or a.startswith(":"))
                  and a not in public and a not in engine_wild)
    rep["engine_wild"] = sorted(a for xs in lis.values() for a in xs if a in engine_wild)
    _ck(sx, "nothing else of the stack on 0.0.0.0 / :: (admin, f2f, sandbox, auth control)", not wild, extra=wild,
        listen=lis)
    adm = up.get("admin_port")
    _ck(sx, "gateway admin port %s on 127.0.0.1 only" % adm, adm and "127.0.0.1:%d" % adm in gw
        and "0.0.0.0:%d" % adm not in gw, gateway=gw)
    allp = netstat_listen()
    dp = int(sx.lab.cfg["daemon"]["port"])
    dl = sorted("%s:%d" % (a, p) for a, p, _ in allp if p == dp)
    _ck(sx, "lab daemon %d on 127.0.0.1 only" % dp, dl == ["127.0.0.1:%d" % dp], daemon=dl)
    xs = lis.get("sandbox") or []
    _ck(sx, "sandbox listens on 127.0.0.1 only", xs and all(a.startswith("127.0.0.1:") for a in xs), addrs=xs)
    xs = [a for a in (lis.get("world") or []) if a not in engine_wild]
    _ck(sx, "world: no other listener than its internal port", not xs, addrs=lis.get("world"))
    if rep["engine_wild"]:
        host, _ = _lan(sx)
        t0 = time.time()
        verdict = None
        try:
            c = socket.create_connection((host, game), timeout=3, source_address=(host, 0))
            c.settimeout(3)
            try:
                d = c.recv(64)
                verdict = "closed" if d == b"" else "data %r" % d[:16]
            except socket.timeout:
                verdict = "open (no close in 3 s)"
            except OSError as exc:
                verdict = "closed (%s)" % exc.__class__.__name__
            c.close()
        except OSError as exc:
            verdict = "refused (%s)" % exc
        rep["world_lan_probe"] = {"from": host, "port": game, "verdict": verdict, "ms": round((time.time() - t0) * 1000)}
        _ck(sx, "world internal port %d (0.0.0.0 by the engine) closes a peer from the LAN address %s" % (game, host),
            verdict.startswith("closed") or verdict.startswith("refused"), probe=rep["world_lan_probe"])
        wl = sx.lab.logs(up["leases"]["world"], stream="stdout", tail=200, grep="refused non-loopback")
        _ck(sx, "world log: refused non-loopback gateway connection", bool(wl.get("lines")) or
            verdict.startswith("refused"), lines=(wl.get("lines") or [])[-2:])
    lab_lo, lab_hi = int(sx.lab.cfg["ports"]["first"]), int(sx.lab.cfg["ports"]["last"])
    _ck(sx, "public ports outside the lab pool %d..%d and the daemon" % (lab_lo, lab_hi),
        all(not lab_lo <= pub[k] <= lab_hi and pub[k] != dp for k in ("gateway", "auth", "packs")))
    return _result(sx, "ports", rep, n0)


def st_info(sx, args, step):
    """InfoRequest на LAN-адрес хоста -> ServerInfo (id шлюза, порты, ключ) + Disconnect 19"""
    n0 = len(_pd(sx)["checks"])
    up = sx.data["public"]
    host, port = _lan(sx)
    r = info_request(host, port)
    si = r.get("info") or {}
    rep = {"host": host, "port": port, "reply": r}
    _ck(sx, "ServerInfo from %s:%d" % (host, port), bool(si), reply=r)
    _ck(sx, "ServerInfo: gw_id, auth/packs ports, sealing key, public, whitelist",
        si.get("gw_id") == up["gw_id"] and si.get("auth_port") == up["public_cfg"]["auth"] and
        si.get("packs_port") == up["public_cfg"]["packs"] and si.get("auth_pub") == up["auth_pub"] and
        si.get("public") is True and si.get("whitelist") == bool(up["public_cfg"]["whitelist"]), info=si)
    _ck(sx, "then Disconnect 19 'server info sent'", (r.get("disconnect") or (None,))[0] == 19, disconnect=r.get("disconnect"))
    # the pack server and the auth service answer on the LAN address too
    import urllib.request
    import ssl
    try:
        with urllib.request.urlopen("http://%s:%d/manifest.json" % (host, si.get("packs_port") or 0), timeout=5) as f:
            man = json.loads(f.read().decode("utf-8"))
        rep["manifest"] = {"version": man.get("version"), "files": man.get("files")}
    except Exception as exc:                            # noqa: BLE001
        rep["manifest"] = {"error": str(exc)}
    _ck(sx, "packs manifest over the LAN address", bool((rep["manifest"] or {}).get("version")), m=rep["manifest"])
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        with urllib.request.urlopen("https://%s:%d/health" % (host, si.get("auth_port") or 0), timeout=5,
                                    context=ctx) as f:
            h = json.loads(f.read().decode("utf-8"))
        rep["auth_health"] = {"ok": h.get("ok"), "sealed_pub": h.get("sealed_pub"), "gateways": h.get("gateways")}
    except Exception as exc:                            # noqa: BLE001
        rep["auth_health"] = {"error": str(exc)}
    _ck(sx, "auth service /health over the LAN address (same key as ServerInfo)",
        (rep["auth_health"] or {}).get("sealed_pub") == si.get("auth_pub"), h=rep["auth_health"])
    # a client from 127.0.0.1 gets the same answer (the host's own menu)
    r2 = info_request("127.0.0.1", port)
    _ck(sx, "ServerInfo on 127.0.0.1 too", (r2.get("info") or {}).get("gw_id") == up["gw_id"], reply=r2)
    return _result(sx, "info", rep, n0)


def _menu_lease(sx, role, params, kind="menu_app"):
    lease = sx.lease(kind, role=role, params=params)
    md = _menu()._md(sx)
    md["lease"] = lease
    md["lease_dir"] = sx.lab.lease_info(lease)["dir"]
    return lease


def _use(sx, role):
    """следующие шаги меню (olife_menu._login и т.д.) — на клиенте этой роли"""
    _menu()._md(sx)["lease"] = sx.leases[role]
    _menu()._md(sx)["lease_dir"] = sx.lab.lease_info(sx.leases[role])["dir"]


def _wait_menu(sx, timeout=40):
    W = _menu()._w()
    return W.wait_for(lambda: (lambda r: r if r.get("page") == "menu" and r.get("menu_doc_ok") else None)(
        _menu()._try(lambda: _menu().mstate(sx))), timeout)


def st_menu(sx, args, step):
    """клиент друга: F2F 0.32 с app-скриптом пака, БЕЗ файла автозаполнения (у друга его нет) -> меню"""
    n0 = len(_pd(sx)["checks"])
    role = args.get("role", "client1")
    t0 = time.time()
    _menu_lease(sx, role, {"autologin": 0})        # config = scripts\olife_server_empty.txt (умолчание вида)
    st = _wait_menu(sx)
    rep = {"start_s": round(time.time() - t0, 2), "texts": (st or {}).get("texts"), "autofill": (st or {}).get("autofill")}
    _ck(sx, "%s: client menu without autofill" % role, st and not st.get("autofill"), texts=rep["texts"])
    return _result(sx, "menu_" + role, rep, n0)


def _wl(sx, op, name):
    up = sx.data["public"]
    r = _menu().wl_op(sx.lab, op, up["gw_id"], name, by=sx.owner, via="scenario")
    if name and name not in _pd(sx)["accounts"]:
        _pd(sx)["accounts"].append(name)
    return r


def _login(sx, args, name):
    return _menu()._login(sx, args, name)


def st_login(sx, args, step):
    """вход другом: одна строка «LAN-ip:порт» (+ #отпечаток) и ник -> ожидание (игра / ошибка на экране статуса)"""
    n0 = len(_pd(sx)["checks"])
    up = sx.data["public"]
    if args.get("role"):
        _use(sx, args["role"])
    host, port = _lan(sx)
    addr = "%s:%d" % (host, port)
    if args.get("fp") == "good":
        addr += "#" + fingerprint(up["auth_pub"])
    elif args.get("fp") == "bad":
        addr += "#AAAAAAAAAAAA"
    nick = args.get("nick") or ("pf%s" % up["session"][-5:])
    if args.get("whitelist") == "add":
        _wl(sx, "add", nick)
    elif args.get("whitelist") == "remove":
        _wl(sx, "remove", nick)
    if nick not in _pd(sx)["accounts"]:
        _pd(sx)["accounts"].append(nick)
    la = dict(args.get("login") or {})
    la.setdefault("addr", addr)
    la.setdefault("nick", nick)
    if args.get("auth_down"):
        sx.lab.stop(up["leases"]["auth"], owner=sx.owner)
    try:
        r = _login(sx, la, args.get("name") or "login")
    finally:
        if args.get("auth_down"):
            sx.lab.start(up["leases"]["auth"], owner=sx.owner)
            time.sleep(1.0)
    res = r.get("result") or {}
    _ck(sx, args.get("name") or "login", r.get("ok"), error=r.get("error"), phases=res.get("phases"))
    if la.get("expect", "play") == "play" and r.get("ok"):
        st = _menu().mstate(sx)
        lines = ((st.get("status") or {}).get("lines") or [])
        cfgl = next((l for l in lines if "сервер «" in l), None)
        _ck(sx, "%s: status shows the server info (ServerInfo) in the first phase" % (args.get("name") or "login"),
            cfgl is not None, line=cfgl, lines=lines[:3])
        rec = (st.get("recent") or [{}])[0]
        _ck(sx, "%s: recent server remembers the key (TOFU pin) and the ticket service on the LAN host" % (
            args.get("name") or "login"), rec.get("auth_pub") == up["auth_pub"] and
            (rec.get("auth") or "").startswith("https://%s:" % host), recent=rec)
        res["status_config_line"] = cfgl
    if args.get("auth_down") and r.get("ok") and args.get("retry_after"):
        r2 = _login(sx, {"button": "retry", "expect": "play", "then": args.get("then_retry", "leave")},
                    (args.get("name") or "login") + "_retry")
        _ck(sx, "%s: auth back -> Повторить -> play" % args.get("name"), r2.get("ok"), error=r2.get("error"))
        res["retry"] = r2.get("result", {}).get("phases")
    return _result(sx, args.get("name") or "login", res, n0)


def _admin_cmd(sx, text):
    """команда админа в чате от аккаунта user (токен — как у хоста; билет запечатанным запросом с 127.0.0.1)"""
    up = sx.data["public"]
    _play()._tools()
    import importlib
    A = importlib.import_module("auth_service")
    F = importlib.import_module("chat_probe")
    tok, _ = _play().user_token()
    rep = A.client_ticket("https://127.0.0.1:%d" % up["auth_port"], tok, up["gw_id"], sealed_pub=up["auth_pub"])
    if not rep.get("ok"):
        return {"error": "ticket: %s" % rep}
    c = F.ChatClient(up["gateway_port"], rep["ticket"], "user").background()
    try:
        return c.command(text, timeout=4)
    finally:
        c.close()


def st_players(sx, args, step):
    """`/players` админа: игрок-друг виден с LAN-адресом, не 127.0.0.1"""
    n0 = len(_pd(sx)["checks"])
    host, _ = _lan(sx)
    r = _admin_cmd(sx, "/players")
    txt = (r or {}).get("text") or ""
    nick = args.get("nick")
    rep = {"reply": r}
    line = next((l for l in txt.splitlines() if nick and nick in l), txt[:300])
    _ck(sx, "/players: %s from %s (not 127.0.0.1)" % (nick, host), host in line and "127.0.0.1" not in line,
        line=line, text=txt[:400])
    return _result(sx, "players", rep, n0)


def st_dup(sx, args, step):
    """второй клиент тем же ником с того же адреса: по антифроду новый вход заменяет старый (Disconnect 12 первому)"""
    n0 = len(_pd(sx)["checks"])
    nick = args["nick"]
    first = args.get("first", "client1")
    second = args.get("second", "client2")
    _wl(sx, "add", nick)
    if second not in sx.leases:
        _menu_lease(sx, second, {"autologin": 0})
        _wait_menu(sx)
    up = sx.data["public"]
    host, port = _lan(sx)
    _use(sx, first)
    st0 = _menu()._try(lambda: _menu().mstate(sx))
    if (st0.get("client") or {}).get("state") != "play":
        r1 = _login(sx, {"addr": "%s:%d" % (host, port), "nick": nick, "expect": "play", "then": "stay",
                         "after_shots": False}, "dup_first")
        _ck(sx, "first client, nick %s -> play" % nick, r1.get("ok"), error=r1.get("error"))
    _use(sx, second)
    r = _login(sx, {"addr": "%s:%d" % (host, port), "nick": nick, "expect": "play", "then": "stay"}, "dup_second")
    _ck(sx, "second client, same nick, same address -> play", r.get("ok"), error=r.get("error"))
    _use(sx, first)
    W = _menu()._w()
    st = W.wait_for(lambda: (lambda s: s if (s.get("client") or {}).get("last_code") == 12 or
                             ((s.get("status") or {}).get("error") or {}).get("code") == 12 else None)(
        _menu()._try(lambda: _menu().mstate(sx))), 12)
    st = st or _menu()._try(lambda: _menu().mstate(sx))
    rep = {"first_client": st.get("client"), "first_error": (st.get("status") or {}).get("error"),
           "first_page": st.get("page")}
    _ck(sx, "first client got Disconnect 12 (duplicate login replaced)", (st.get("client") or {}).get("last_code") == 12
        or ((st.get("status") or {}).get("error") or {}).get("code") == 12, **rep)
    sh = _menu()._shot(sx, "dup_first_after")
    rep["shot"] = sh
    _use(sx, second)
    _menu().leave(sx)
    return _result(sx, "dup", rep, n0)


# ---------------------------------------------------------------------------------------------- olife_bundle
def st_bundle(sx, args, step):
    """собрать zip (в artifacts), распаковать в artifacts; состав: exe, res, паки КОПИЯМИ (нет junction/ссылок), нет .bak/
    __pycache__/проб, шрифт olife_mono.ttf, OLIFE.bat, ПРОЧТИ.txt, settings.toml; манифест паков = раздача сервера"""
    n0 = len(_pd(sx)["checks"])
    base = os.path.join(sx.lab.data, "olife", "bundle_test", sx.data["public"]["session"])
    if os.path.exists(base):
        shutil.rmtree(base)
    os.makedirs(base)
    r = bundle(sx.lab, os.path.join(base, "zip"))
    unp = os.path.join(base, "unpacked")
    with zipfile.ZipFile(r["zip"]) as z:
        names = z.namelist()
        z.extractall(unp)
    top = os.path.join(unp, os.path.splitext(os.path.basename(r["zip"]))[0])
    rep = {"bundle": r, "unpacked": top, "entries": len(names)}
    links, baks, pyc, probes = [], [], [], []
    for dp, dns, fns in os.walk(top):
        for x in dns + fns:
            p = os.path.join(dp, x)
            if os.path.islink(p) or (hasattr(os.path, "isjunction") and os.path.isjunction(p)):
                links.append(p)
            if _skip(x) and x.endswith((".bak", ".pyc")) or ".bak" in x:
                baks.append(p)
            if x == "__pycache__":
                pyc.append(p)
            if "probe" in x.lower():
                probes.append(p)
    _ck(sx, "zip: no junctions / symlinks", not links, links=links[:5])
    _ck(sx, "zip: no .bak", not baks, baks=baks[:5])
    _ck(sx, "zip: no __pycache__", not pyc, pyc=pyc[:5])
    _ck(sx, "zip: no probe packs/files (olife_caret_probe)", not probes, probes=probes[:5])
    need = ["VoxelCore.exe", "res\\content\\base\\package.json", "content\\olife_client\\package.json",
            "content\\olife_proto\\package.json", "content\\olife_client\\fonts\\olife_mono.ttf",
            "content\\olife_client\\scripts\\app\\olife.lua", "OLIFE.bat", "ПРОЧТИ.txt", "settings.toml",
            "olife_bundle_manifest.json"]
    miss = [x for x in need if not os.path.exists(os.path.join(top, x))]
    _ck(sx, "zip: exe, res (base), both packs, font olife_mono.ttf, app script, OLIFE.bat, ПРОЧТИ.txt, settings.toml",
        not miss, missing=miss)
    _ck(sx, "zip: no vctest.exe", not os.path.exists(os.path.join(top, "vctest.exe")))
    from labcore import config, supervise
    mine = supervise.pack_manifest(os.path.join(top, "content"), P["CLIENT_PACKS"])
    srv = supervise.pack_manifest(config.PACKS_DIR, P["CLIENT_PACKS"])
    _ck(sx, "unpacked packs: sha256 manifest == server distribution", mine["version"] == srv["version"] and
        mine["files"] == srv["files"], mine=mine["version"][:16], server=srv["version"][:16], files=mine["files"])
    try:
        with open(os.path.join(sx.lab.data, "olife", "packs_manifest.json"), encoding="utf-8") as f:
            live = json.load(f)
        _ck(sx, "unpacked packs == the manifest the gateway serves (packs_manifest.json)",
            live.get("version") == mine["version"], live=(live.get("version") or "")[:16])
    except OSError as exc:
        rep["live_manifest"] = str(exc)
    with open(os.path.join(top, "OLIFE.bat"), "rb") as f:
        bat = f.read().decode("cp866")
    _ck(sx, "OLIFE.bat: VoxelCore.exe --dir <here> --script content\\olife_client\\scripts\\app\\olife.lua",
        "VoxelCore.exe\" --dir \"%~dp0.\" --script \"%~dp0content\\olife_client\\scripts\\app\\olife.lua\"" in bat,
        bat=bat[-200:])
    with open(os.path.join(top, "ПРОЧТИ.txt"), encoding="utf-8-sig") as f:
        rd = f.read()
    rep["readme_lines"] = len(rd.splitlines())
    _ck(sx, "ПРОЧТИ.txt: ~10 lines (unpack, OLIFE.bat, ip:port + nick, status errors)", 6 <= len(rd.splitlines()) <= 14
        and "OLIFE.bat" in rd and "ip:port" in rd, lines=len(rd.splitlines()))
    with open(os.path.join(top, "VoxelCore.exe"), "rb") as f:
        exe_sha = hashlib.sha256(f.read()).hexdigest()
    eng = _play().engine_v032(sx.lab)
    with open(eng["stock"], "rb") as f:
        stock_sha = hashlib.sha256(f.read()).hexdigest()
    _ck(sx, "VoxelCore.exe = stock 0.32 (not the F2F build)", exe_sha == stock_sha, exe=exe_sha[:16])
    sx.data["bundle"] = {"top": top, "zip": r["zip"]}
    return _result(sx, "bundle", rep, n0)


def st_bundle_client(sx, args, step):
    """F2F-сборка 0.32 (НЕ стоковый exe из zip) с --dir распакованного каталога и тем же --script, что в OLIFE.bat ->
    меню клиента (без автозаполнения) -> вход по LAN-адресу хоста"""
    n0 = len(_pd(sx)["checks"])
    top = sx.data["bundle"]["top"]
    role = args.get("role", "client_bundle")
    t0 = time.time()
    try:    # 22.10: тестовая копия без звука (zip уже собран; другу звук остаётся)
        with open(os.path.join(top, "settings.toml"), "a", encoding="utf-8", newline="\r\n") as f:
            f.write("\n# lab: F2F test copy, silent\n[audio]\nenabled = true\nvolume-master = 0\n")
    except OSError:
        pass
    _menu_lease(sx, role, {"root": top}, kind="bundle_client")
    st = _wait_menu(sx, 60)
    rep = {"start_s": round(time.time() - t0, 2), "texts": (st or {}).get("texts")}
    _ck(sx, "bundle: client menu opened from the unpacked dir", bool(st), texts=rep["texts"])
    if st:
        r = st_login(sx, {"nick": args.get("nick"), "whitelist": "add", "name": "bundle_login", "fp": "good",
                          "login": {"then": "leave"}}, step)
        rep["login"] = r.get("result")
    return _result(sx, "bundle_client", rep, n0)


def st_report(sx, args, step):
    pd = _pd(sx)
    bad = [c for c in pd["checks"] if not c["ok"]]
    md = _menu()._md(sx)
    rep = {"checks": len(pd["checks"]), "ok": len(pd["checks"]) - len(bad), "failed": [c["name"] for c in bad],
           "menu_checks": len(md["checks"]), "menu_ok": sum(1 for c in md["checks"] if c["ok"]),
           "lan": pd.get("lan"), "cases": md.get("cases")}
    try:
        with open(os.path.join(sx.run["dir"], "public_checks.json"), "w", encoding="utf-8") as f:
            json.dump({"checks": pd["checks"], "menu": md["checks"], "details": pd["details"]}, f, ensure_ascii=False,
                      indent=1, default=str)
    except Exception:                                   # noqa: BLE001
        pass
    return {"ok": not bad, "result": rep, "error": ("failed: %s" % rep["failed"]) if bad else None}


NAMES = {"olife_pub_ports": "st_ports", "olife_pub_info": "st_info", "olife_pub_menu": "st_menu",
         "olife_pub_login": "st_login", "olife_pub_players": "st_players", "olife_pub_dup": "st_dup",
         "olife_pub_bundle": "st_bundle", "olife_pub_bundle_client": "st_bundle_client",
         "olife_pub_report": "st_report"}


def selftest():
    assert fingerprint("abcdefghijklmnop") == "abcdefghijkl"
    assert _skip("x.lua.bak") and _skip("a.bak") and _skip("olife_caret_probe") and not _skip("olife_mono.ttf")
    assert "%~dp0content\\olife_client\\scripts\\app\\olife.lua" in BAT
    assert len(README.splitlines()) <= 14
