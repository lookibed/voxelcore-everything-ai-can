"""CLI проекта olife (`lab olife ...`): вынесено из ядра лаборатории (labcore/cli_sup.py рабочего каталога) в волне 1
нового репозитория. Проект olife (project.toml, plugin.py, паки) переезжает сюда в волне 6; до этого файл —
только перенос кода, ядро вызывает его как CLI проекта: `lab olife <...>` -> run(c, argv, opt).

  lab olife up [--clients N] [--no-sandbox] [--sandbox-kind sandbox|sandbox_stub] [--client-kind bot|client]
               [--poll S] [--autosave S] [--ttl S] [--auth-files]
               [--policy '{"backoff_s":1,"max_restarts":5}']     сессия под supervisor: мир -> песочница -> шлюз -> боты
  lab olife down [--group G]                         снять наблюдение, освободить (боты -> шлюз -> песочница -> мир)
  lab olife status [--group G]                       службы (здоровье, перезапуски, uptime), мир, игроки, счётчики, панель
  lab olife incidents [--last N] | lab olife incident <id>
  lab olife players [--group G]  |  lab olife kick <eid> [--group G]
  lab olife ban <account> <minutes> <reason...> [--ip]   (0 минут — навсегда)  |  lab olife unban <account> [--ip]
               --ip: адрес или CIDR (127.0.0.64/26), срок, причина; сразу kick сессий с этих адресов на всех шлюзах;
               сеть, покрывающая exempt (127.0.0.1 — локальный игрок), — только с --force
  lab olife bans                                     активные баны (аккаунты, IP/CIDR; by=fraud — автобаны)
  lab olife fraud [status] | fraud events [N] | fraud set <ключ> <значение|default> | fraud clear <аккаунт|ip:A|nick:N>
               | fraud trust <аккаунт> <x>      антифрод (16.10): очки, события, автобаны, живые ручки; clear = ложное
                                                   срабатывание (снять автобаны, доверие ×2); = `/fraud` в чате = панель
  lab olife tariff [list] | lab olife tariff set <key> <value|delete> (кредиты — со следующего опроса; limits.default.<поле>,
                                                                   limits.owner.<n>.<поле> — set_limits песочницам сразу)
  lab olife accounts | lab olife accounts add <name> [<token>] [--role R]   (без токена — новый случайный, в ответе)
  lab olife packs manifest                           манифест content/olife_client + olife_proto (path, sha256, size, side)
  lab olife restart <role> [--group G]  |  lab olife kill <role> [--how proc|tree] [--group G]   (тест: «падение»)
  lab olife panel                                    путь файла панели и URL живой панели демона
  lab olife play-up [--dry]                         стек игрока без окна (мир D:/Prog/Olife/play, песочница, билеты, Rust-шлюз,
                                                   аккаунт user, примеры бенчей) + export/olife_server.txt клиента 0.32:
                                                   дальше VoxelCore 0.32 -> «Сценарии» -> olife
  lab olife play-up --public                        то же для друзей (16.10, olife_friends): шлюз/билеты/паки на 0.0.0.0, порты
                                                   [play.public] 27750/27751/27752, вайтлист включён (OLIFE_PUBLIC_PLAY.md)
  lab olife ip [--no-external]                      адреса ПК (LAN, VPN, внешний IP через echo-сервис) и строки приглашения
  lab olife invite [<ник>]                          ник -> вайтлист сервера игры + строка для друга ip:27750#отпечаток
  lab olife bundle [--out D:\\Prog\\Olife\\dist] [--invite ip:port#fp]   zip клиента другу (стоковый 0.32 + копии паков)
  lab olife play-down [--group G] | play-status [--group G] | sync     снять стек игрока | статус | паки в 0.32/content
  lab olife friend list [<account>] | friend add|remove|request|cancel <a> <b> [--session S] | friend sync [--session S]
                                                   друзья в БД supervisor (UX A1): правка уходит в миры ваших групп/сессии
  lab olife settings [<account>] | settings <account> <key> <value|delete>   настройки аккаунта: perms.default=
                                                   move:friends,clone:everyone; friends.requests=open|closed
  lab olife op <команда чата без «/»...> [--group G|--session S]   UX A2: команда оператора в мире (как «/…» админа в чате):
               kill <моб> | killall [игрок] | freeze|unfreeze <моб|игрок> | limits <моб|игрок> [fuel|bucket|memory|actions|text
               <v|default>] | kick <игрок> [причина] | ban <игрок> <мин> <причина> | unban <игрок> | tp <кто> <x y z|куда> |
               mobs [игрок] | who | say <текст> | audit [n]      (аудит мира: via=cli; моб = #eid | имя | mob:имя)
  lab olife mobs [игрок] | lab olife killall|freeze|unfreeze|limits|tp|say|audit ...   то же, что `lab olife op <...>`
  lab olife whitelist [list] | whitelist add|remove <ник> | whitelist on|off  [--gw <id шлюза>|--session S|--all]
                                                   UX B: вайтлист по нику (вход по нику без токена); по умолчанию — сервер
                                                   игры gw-olife-play; --session S — gw-<S>; --all — «*» (все шлюзы).
                                                   = `/whitelist ...` админа в чате = кнопки панели /sup/panel
"""
import json


def _call(c, feature, args, timeout=600.0):
    r = c.post("/call/%s" % feature, {"args": args}, timeout=timeout)
    return r, (r.get("result") if r.get("ok") else None)


def _out(r, res):
    print(json.dumps(res if res is not None else r, ensure_ascii=False, indent=1, default=str))
    return 0 if res is not None else 1


def run(c, argv, opt):
    if not argv:
        print(__doc__)
        return 2
    sub = argv.pop(0)
    grp = opt(argv, "--group")
    base = {"group": grp} if grp else {}
    if sub == "up":
        a = {"clients": int(opt(argv, "--clients", 2)), "client_kind": opt(argv, "--client-kind", "bot"),
             "sandbox": not opt(argv, "--no-sandbox", flag=True), "poll_s": float(opt(argv, "--poll", 5)),
             "autosave_s": float(opt(argv, "--autosave", 30))}
        if opt(argv, "--ttl"):
            a["ttl"] = int(opt(argv, "--ttl"))
        sk = opt(argv, "--sandbox-kind")
        if sk:
            a["sandbox_kind"] = sk                  # sandbox (настоящий sandboxd) | sandbox_stub
        pol = opt(argv, "--policy")
        if pol:
            a["policy"] = json.loads(pol)
        if opt(argv, "--auth-files", flag=True):
            a["auth"] = "files"
        return _out(*_call(c, "olife.up", a, timeout=900))
    if sub == "play-up":
        a = {"mode": "dry" if opt(argv, "--dry", flag=True) else "play"}
        if opt(argv, "--public", flag=True):         # olife_friends 16.10
            a["public"] = 1
        r, res = _call(c, "olife.play_up", a, timeout=900)
        if res is not None and res.get("public"):
            try:
                _r2, ip = _call(c, "olife.ip", {"auth_pub": res.get("auth_pub")}, timeout=60)
                res["invite_text"] = (ip or {}).get("text")
            except Exception as exc:                 # noqa: BLE001
                res["invite_text"] = str(exc)
        rc = _out(r, res)
        if res is not None and res.get("invite_text"):
            print(res["invite_text"])
        return rc
    if sub in ("ip", "invite", "bundle"):           # olife_friends 16.10 (olife_public.py)
        if sub == "ip":
            a = {"no_external": opt(argv, "--no-external", flag=True)}
        elif sub == "invite":
            a = {"name": argv[0]} if argv else {}
        else:
            a = {k[2:]: v for k, v in (("--out", opt(argv, "--out")), ("--invite", opt(argv, "--invite"))) if v}
        r, res = _call(c, "olife.%s" % sub, a, timeout=900)
        if res is not None and res.get("text"):
            print(res["text"])
            return 0 if res.get("ok", True) else 1
        return _out(r, res)
    if sub == "play-down":
        return _out(*_call(c, "olife.play_down", dict(base, reason="operator"), timeout=300))
    if sub == "play-status":
        return _out(*_call(c, "olife.play_status", base))
    if sub == "sync":
        return _out(*_call(c, "olife.sync", {}))
    if sub == "down":
        return _out(*_call(c, "olife.down", base, timeout=300))
    if sub in ("status", "panel"):
        return _out(*_call(c, "olife.sup_status", base))
    if sub == "incidents":
        return _out(*_call(c, "olife.incidents", {"last": int(opt(argv, "--last", 20))}))
    if sub == "incident":
        return _out(*_call(c, "olife.incidents", {"id": argv[0]}))
    if sub == "players":
        return _out(*_call(c, "olife.players", base))
    if sub == "kick":
        return _out(*_call(c, "olife.kick", dict(base, eid=int(argv[0]))))
    if sub == "ban":
        ip = opt(argv, "--ip", flag=True)
        force = opt(argv, "--force", flag=True)
        a = {"ip" if ip else "account": argv[0], "minutes": float(argv[1]) if len(argv) > 1 else 0,
             "reason": " ".join(argv[2:]) or "operator"}
        if force:
            a["force"] = True
        return _out(*_call(c, "olife.ban", a))
    if sub == "bans":                                # antifraud 16.10
        return _out(*_call(c, "olife.fraud", {"action": "bans"}))
    if sub == "fraud":                               # antifraud 16.10 (olife_fraud.py)
        act = argv.pop(0) if argv else "status"
        a = {"action": act, "via": "cli"}
        if act == "events":
            a["last"] = int(argv[0]) if argv else 30
        elif act == "set":
            a["key"], a["value"] = argv[0], argv[1]
        elif act == "clear":
            a["target"] = argv[0]
        elif act == "trust":
            a["account"], a["value"] = argv[0], float(argv[1])
        r, res = _call(c, "olife.fraud", a)
        if res is not None and isinstance(res, dict) and res.get("text") and act in ("status", "events"):
            print(res["text"])
            return 0
        return _out(r, res)
    if sub == "unban":
        ip = opt(argv, "--ip", flag=True)
        return _out(*_call(c, "olife.unban", {"ip" if ip else "account": argv[0]}))
    if sub == "tariff":
        if argv and argv[0] == "set":
            # волна 4b: `delete` убирает ключ (limits.* -> поле песочницы возвращается к умолчанию)
            v = argv[2] if argv[2] == "delete" else float(argv[2])
            return _out(*_call(c, "olife.tariff", {"action": "set", "key": argv[1], "value": v}))
        return _out(*_call(c, "olife.tariff", {"action": "list"}))
    if sub == "accounts":
        if argv and argv[0] == "add":
            role = opt(argv, "--role", "player")
            tok = argv[2] if len(argv) > 2 else None        # нет токена — сгенерирует плагин (ответ: token)
            return _out(*_call(c, "olife.accounts", {"action": "add", "name": argv[1], "token": tok, "role": role}))
        return _out(*_call(c, "olife.accounts", {}))
    if sub in ("op", "mobs", "killall", "freeze", "unfreeze", "limits", "tp", "say", "audit", "who"):
        # UX A2: команды оператора в мире (olife_a2.py); убить моба — `lab olife op kill #5` (`lab olife kill <роль>` —
        # прежнее «падение» службы для тестов)
        ses = opt(argv, "--session")
        a = dict(base)
        if ses:
            a["session"] = ses
        text = " ".join(argv) if sub == "op" else " ".join([sub] + argv)
        a["text"] = text
        return _out(*_call(c, "olife.op", a, timeout=60))
    if sub == "packs":
        return _out(*_call(c, "olife.packs", {}))
    if sub == "friend":                              # UX A1
        act = argv.pop(0) if argv else "list"
        a = {"action": act}
        sess = opt(argv, "--session")
        if sess:
            a["session"] = sess
        if argv:
            a["a"] = argv[0]
        if len(argv) > 1:
            a["b"] = argv[1]
        return _out(*_call(c, "olife.friend", a))
    if sub == "settings":                            # UX A1
        a = {"account": argv[0]} if argv else {}
        if len(argv) > 2:
            a["key"], a["value"] = argv[1], argv[2]
        return _out(*_call(c, "olife.settings", a))
    if sub == "whitelist":                           # UX B (olife_menu)
        a = {}
        gw, ses = opt(argv, "--gw"), opt(argv, "--session")
        if opt(argv, "--all", flag=True):
            a["scope"] = "*"
        elif gw:
            a["scope"] = gw
        elif ses:
            a["session"] = ses
        a["op"] = argv[0] if argv else "list"
        if len(argv) > 1:
            a["name"] = argv[1]
        return _out(*_call(c, "olife.whitelist", a))
    if sub == "restart":
        return _out(*_call(c, "olife.restart", dict(base, role=argv[0]), timeout=300))
    if sub == "kill":
        return _out(*_call(c, "olife.kill", dict(base, role=argv[0], how=opt(argv, "--how", "proc"))))
    print(__doc__)
    return 2
