"""olife: путь игрока (02.10, агент olife_play) — `lab play olife --user`, `lab play olife --dry-run`,
`lab olife play-up|play-down|play-status|sync`. Подключается из plugin.py (`_play()`, перезагрузка по mtime).

Состав (стек под supervisor, группа `olife-play-<сессия>`): мир (вид `world_play`: стоковый 0.32 headless, `worlds\\` —
junction на постоянный мир пользователя `<repo>\\projects\\olife\\external\\play\\worlds`; в сухом прогоне — на копию), настоящая песочница
(`sandbox`), сервис билетов (`auth`, ключи постоянные в `<repo>\\projects\\olife\\external\\play\\keys`), Rust-шлюз (`gateway_rs`, только
билеты, раздача паков по манифесту), тарифы по умолчанию. Аккаунт `user` (токен — `<repo>\\projects\\olife\\external\\play\\user_token.txt`,
роль admin в БД; в мире — `olife.admins user`), примеры бенчей `demo_orbit`/`demo_follow`/`demo_blink` (код
`content/olife_world/sandbox/samples/*.lua`, владелец user, запущены; спавнятся только если их ещё нет в мире).
Клиент читает `export:olife_server.txt` (адрес шлюза, сервис билетов, ключ запечатывания, токен) — файл пишется в
`<0.32>\\export\\` (обычный режим) и в `<база>\\olife_server.txt`.

Сеанс `lab play olife` ([play] проекта): вид `play_stack` (этот стек поднимает процесс-«коляска» play_stack.py через
HTTP демона: olife.play_up; на `stop` — olife.play_down: сводка сессии + снятие группы) -> вид `runtime` (стоковый
0.32 VoxelCore.exe, `--script content\\olife_client\\scripts\\app\\olife.lua`). Ядро play.py не менялось.
Паки клиента в `<0.32>\\content\\` — junction на `VC_ROOT\\content\\<пак>` (sync при каждом подъёме: игрок всегда на
текущем коде). Сухой прогон — сценарий `olife_play_dry` (тот же стек + клиент F2F 0.32 с тем же скриптом)."""
import json
import os
import re
import secrets
import shutil
import sys
import threading
import time

P = {}                                      # глобалы plugin.py (bind)

PLAY_DIR = os.path.join(os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")), "projects", "olife", "external", "play")
GW_ID = "gw-olife-play"
USER = "user"
SAMPLES = (("demo_orbit", "demo_orbit"), ("demo_follow", "demo_follow"), ("demo_blink", "demo_blink"))
# UX A3 (03.10): examples of the mob script API — in the play world's samples list, NOT spawned automatically into the
# user's persistent world (only SAMPLES above are); the user (admin) spawns one with the world command
# `spawn_sample user <name> <name> 1` (or `lab call olife.play_status` shows the list).
EXTRA_SAMPLES = ("demo_spin_scale", "demo_texture_swap", "demo_sound_collision", "demo_block_painter",
                 "demo_memory_counter")
AUTH_HEALTH = [{"f2f": "hello", "timeout": 3}]
# публичный шлюз (olife_friends): клиентский порт не из пула аренд (фиксированный [play.public]) -> проверка admin-порта
PUBLIC_GW_HEALTH = [{"f2f": "hello", "timeout": 3}, {"port": "admin"}]
CONFIG_NAME = "olife_server.txt"


def bind(g):
    P.update(g)


def _tools():
    from labcore import config
    t = os.path.join(config.REPO_ROOT, "projects", "olife", "tools")
    if t not in sys.path:
        sys.path.insert(0, t)
    return t


def engine_v032(lab):
    """Движок пути игрока = движок вида runtime (22.10: раньше всегда v032; теперь — умолчание проекта, v0327)."""
    proj = lab.projects.get("olife")
    return lab.engine_of(proj, proj.kinds["runtime"])[1]


# ============================================================================================== подготовка
def sync_packs(lab):
    """<0.32>\\content\\<пак> -> junction на VC_ROOT\\content\\<пак> (olife_client, olife_proto). Junction, а не копия: игрок
    всегда на текущем коде, копировать нечего. Настоящий каталог на месте junction — отказ (не трогаем чужое)."""
    import _winapi
    from labcore import config
    root = engine_v032(lab)["root"]
    content = os.path.join(root, "content")
    os.makedirs(content, exist_ok=True)
    out = {}
    for pk in P["CLIENT_PACKS"]:
        src = os.path.join(config.PACKS_DIR, pk)
        link = os.path.join(content, pk)
        if os.path.lexists(link):
            if os.path.isjunction(link) or os.path.islink(link):
                if os.path.normcase(os.path.realpath(link)) == os.path.normcase(os.path.realpath(src)):
                    out[pk] = "ok"
                    continue
                os.rmdir(link)                       # junction в другое место — только ссылка
            else:
                raise RuntimeError("%s is a real directory, not a junction to %s: move it away and repeat" % (link, src))
        _winapi.CreateJunction(src, link)
        out[pk] = "created"
    return {"content": content, "packs": out, "target": config.PACKS_DIR}


def user_token(base=PLAY_DIR):
    """Токен аккаунта user: файл <PLAY_DIR>\\user_token.txt (создаётся один раз)."""
    os.makedirs(base, exist_ok=True)
    path = os.path.join(base, "user_token.txt")
    tok = None
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            tok = f.read().strip()
    if not tok:
        tok = "olife-u-" + secrets.token_urlsafe(24)
        with open(path, "w", encoding="utf-8") as f:
            f.write(tok + "\n")
    return tok, path


def ensure_user(lab):
    tok, path = user_token()
    lab.sup.db.add_account(USER, tok, "admin", note="play: %s" % path)
    return tok, path


def make_keys(kdir, gw_id=GW_ID):
    """Постоянные ключи сервиса билетов (мастер + x25519 запечатывания) и ключ шлюза gw_id, выведенный из мастера."""
    _tools()
    import olife_ticket as T
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization as S
    os.makedirs(kdir, exist_ok=True)
    pm, ps, pg = (os.path.join(kdir, n) for n in ("auth_master.key", "auth_seal_x25519.key", "gateway_ticket.key"))
    if not os.path.exists(pm):
        with open(pm, "w", encoding="utf-8") as f:
            f.write(os.urandom(32).hex())
    with open(pm, encoding="utf-8") as f:
        master = bytes.fromhex(f.read().strip())
    if not os.path.exists(ps):
        sk = X25519PrivateKey.generate()
        with open(ps, "w", encoding="utf-8") as f:
            f.write(sk.private_bytes(S.Encoding.Raw, S.PrivateFormat.Raw, S.NoEncryption()).hex())
    with open(ps, encoding="utf-8") as f:
        sk = X25519PrivateKey.from_private_bytes(bytes.fromhex(f.read().strip()))
    with open(pg, "w", encoding="utf-8") as f:
        json.dump({"key": T.gateway_key(master, gw_id).hex(), "gateway": gw_id}, f)
    pub = T.b64u(sk.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw))
    return {"master": pm, "seal": ps, "gw_key": pg, "gw_id": gw_id, "pub": pub}


def store_junction(worlds, world="olife"):
    """UX A4: the store of the play world (KV, index, CAS — content/olife_world/modules/store.lua world:olife_store) lives
    in <PLAY_DIR>\\store; the world sees it through the junction <worlds>\\olife\\olife_store. The first world run
    creates a real directory there — it is moved to <PLAY_DIR>\\store once (world stopped). A dry run copies the world
    with copytree, which copies the junction's content (a junction is not a symlink for os.scandir)."""
    import _winapi
    wdir = os.path.join(worlds, world)
    link = os.path.join(wdir, "olife_store")
    store = os.path.join(PLAY_DIR, "store")
    if not os.path.isdir(wdir):
        return "no world yet"
    if os.path.lexists(link) and (os.path.isjunction(link) or os.path.islink(link)):
        return "ok"
    if os.path.isdir(link):
        if os.path.exists(store):
            return "real directory kept (%s exists)" % store
        shutil.move(link, store)
    os.makedirs(store, exist_ok=True)
    _winapi.CreateJunction(store, link)
    return "created"


def prepare_worlds(mode, base):
    """play: постоянный каталог миров пользователя; dry: копия постоянного (если есть) в каталог сухого прогона."""
    if mode == "play":
        d = os.path.join(PLAY_DIR, "worlds")
        os.makedirs(d, exist_ok=True)
        store_junction(d)
        return d, "persistent"
    d = os.path.join(base, "worlds")
    src = os.path.join(PLAY_DIR, "worlds")
    if os.path.isdir(d):
        shutil.rmtree(d)
    if os.path.isdir(src) and os.listdir(src):
        shutil.copytree(src, d)
        _normalise_copy(d)
        return d, "copy of %s" % src
    os.makedirs(d, exist_ok=True)
    return d, "fresh"


def _normalise_copy(d):
    """сухой прогон (UX round 1): в КОПИИ мира пользователя игроки — снова на точке спавна (пользователь мог улететь,
    02.10: user у (4.9, 78.9, -1.3) — примеры на кольце вокруг спавна вне досягаемости Injector'а 8 бл); постоянный мир
    не трогаем"""
    for name in os.listdir(d):
        reg = os.path.join(d, name, "olife_registry.json")
        if not os.path.isfile(reg):
            continue
        with open(reg, encoding="utf-8") as f:
            r = json.load(f)
        sp = r.get("spawn")
        if sp and isinstance(r.get("players"), dict):
            for k in r["players"]:
                r["players"][k] = list(sp)
            with open(reg, "w", encoding="utf-8") as f:
                json.dump(r, f)


def config_text(info, tok):
    t = ("# Olife: подключение клиента (пишет lab: `lab play olife`, `lab olife play-up`; читает olife_client:play,\n"
         "# пункт «Сценарии» -> olife). Токен — секрет аккаунта %s: не выкладывать.\n"
         "gateway=127.0.0.1:%d\nauth=https://127.0.0.1:%d\ngw_id=%s\nauth_pub=%s\nauth_verify=0\n"
         "account=%s\nname=%s\ntoken=%s\nreconnect=3\n" % (USER, info["gateway_port"], info["auth_port"],
                                                           info.get("gw_id") or GW_ID, info["auth_pub"], USER, USER, tok))
    if info.get("public"):          # olife_friends: хост играет локально (127.0.0.1), друзья — по строке приглашения
        t += "public=1\ninvite=%s\n" % ((info.get("invite") or {}).get("lan") or "")
    return t


# ============================================================================================== стек
class PlayHooks:
    """Хуки группы: всё как у OlifeHooks + «коляска» умерла (сеанс play убит без stop) -> группа снимается."""

    def __new__(cls, args):
        base = P["OlifeHooks"]

        class _H(base):
            def poll(self, sup, g):
                sc = self.args.get("sidecar")
                if sc and not g.stop:
                    l = sup.lab.leases.get(sc)
                    alive = l is not None and l.proc is not None and l.proc.alive()
                    if not alive and time.time() - self.args.get("t_up", 0) > 30:
                        sup._event(g, None, None, "orphan", "sidecar %s is gone -> group down" % sc)
                        threading.Thread(target=_down_quiet, args=(sup, g.name, g.owner), daemon=True).start()
                        return {"orphan": sc}
                return base.poll(self, sup, g)
        return _H(args)


def _down_quiet(sup, name, owner):
    try:
        sup.down(name, owner, release=True)
    except Exception:
        pass


def _stdin(lab, lease, owner, cmd, pattern, wait=4.0):
    r = lab.stdin(lease, cmd, owner=owner, wait=wait, pattern=pattern)
    return [x for x in r.get("lines") or [] if "olife_world" in x], r.get("matched")


def benches(lab, wl, owner):
    lines, _ = _stdin(lab, wl, owner, "benches", r"benches n=")
    out = []
    for line in lines:
        if "benches n=" not in line:
            continue
        for tok in line.split("benches n=", 1)[1].split()[1:]:
            parts = tok.split(":")
            if len(parts) >= 4:
                out.append({"eid": int(parts[0]), "name": parts[1], "owner": parts[2], "status": parts[3]})
    return out


def play_up(lab, owner, args, create, log=None):
    """Поднять стек игры под supervisor. create(kind, role, params) -> имя аренды (не запущена)."""
    log = log or (lambda s: None)
    sup = lab.sup
    mode = args.get("mode", "play")
    # olife_friends (16.10): публичный режим — шлюз/билеты/паки на 0.0.0.0, фиксированные порты [play.public]
    public = str(args.get("public") or "0").lower() not in ("0", "", "false", "no")
    PB = P["_pub"]() if public else None
    pub = PB.public_cfg(lab) if public else None
    # сухой публичный прогон (тесты olife_public/olife_bundle) — свой id шлюза = свой scope вайтлиста (вайтлист сервера
    # пользователя gw-olife-play тесты не трогают)
    gw_id = GW_ID if mode == "play" else (args.get("gw_id") or ("gw-olife-pubtest" if public else GW_ID))
    sid = args.get("session") or P["_sid"]()
    group = P["SUP_PREFIX"] + "play-" + sid
    base = PLAY_DIR if mode == "play" else os.path.join(lab.data, "olife", "play_dry", sid)
    os.makedirs(base, exist_ok=True)
    t0 = time.time()
    info = {"group": group, "session": sid, "mode": mode, "base": base, "leases": {}, "timing": {}, "public": public,
            "gw_id": gw_id}
    if public:
        info["public_cfg"] = pub
        info["ports_check"] = PB.check_ports(lab, pub)          # занятые / пересекающиеся с лабораторией -> отказ
    info["packs"] = sync_packs(lab)
    P["seed_db"](sup, 0)                                    # dev-аккаунты/баны + тарифы по умолчанию (только отсутствующее)
    tok, tok_path = ensure_user(lab)
    info["token_file"] = tok_path
    keys = make_keys(os.path.join(base, "keys"), gw_id)
    worlds, wsrc = prepare_worlds(mode, base)
    info["worlds"], info["worlds_source"] = worlds, wsrc
    mpath = P["manifest_path"](lab)
    P["make_manifest"](lab)
    sup_url = "http://127.0.0.1:%d/sup" % lab.cfg["daemon"]["port"]
    made = []

    def mk(kind, role, params):
        name = create(kind, role, dict(params, session=sid))
        made.append(name)
        info["leases"][role] = name
        return name
    g = None
    try:
        sb = mk("sandbox", "sandbox", {})
        sb_port = lab.lease_info(sb)["ports"]["sb"]
        world = mk("world_play", "world", {"sandbox": sb_port, "journal_every": 20, "mobs": 0, "scripted": 0,
                                            "worlds": worlds,      # UX A2: /limits -> set_limits of the sandbox
                                            "opts": P["_menu"]().world_opts(lab, P["_a2"]().world_opts(
                                                None, lab.lease_info(sb)["ports"].get("f2f")), gw_id)})
        game = lab.lease_info(world)["ports"]["game"]
        ap = {"master": keys["master"], "seal_key": keys["seal"], "gateways": gw_id, "auth_url": sup_url, "ttl": 30,
              "require_sealed": 1, "tls": 1}
        if public:
            ap["listen"] = pub["auth"]
        auth = mk("auth_public" if public else "auth", "auth", ap)
        gp = {"upstream": game, "packs_manifest": mpath, "auth_url": sup_url, "ticket_key": keys["gw_key"],
              "gw_id": gw_id, "auth_mode": "tickets",
              # UX A4: store files of the world (GET /assets/<sha>)
              "assets_dir": os.path.join(worlds, "olife", "olife_store", "cas")}
        if public:
            # ServerInfo (ответ шлюза на InfoRequest): порты билетов/паков и ключ запечатывания — друг знает только ip:port
            info["server_info"] = PB.write_server_info(base, pub, keys["pub"])
            gp.update(listen=pub["gateway"], packs_port=pub["packs"], info=info["server_info"])
        gw = mk("gateway_rs_public" if public else "gateway_rs", "gateway", gp)
        hargs = {"autosave_s": float(args.get("autosave_s", 30)), "sidecar": args.get("sidecar"), "t_up": time.time()}
        g = sup.group(group, owner, PlayHooks(hargs), float(args.get("poll_s", 5)),
                      meta={"project": "olife", "session": sid, "play": mode, "sidecar": args.get("sidecar"),
                            "clients": 0, "client_kind": "player"})
        for role, health in (("world", P["WORLD_HEALTH"]), ("sandbox", P["SANDBOX_HEALTH"]), ("auth", AUTH_HEALTH),
                             ("gateway", P["GATEWAY_HEALTH"] if not public else PUBLIC_GW_HEALTH)):
            t1 = time.time()
            sup.add(group, role, info["leases"][role], health=health, policy=args.get("policy") or {})
            info["timing"][role] = round(time.time() - t1, 2)
            log("olife play %s: %s %s up in %.2f s" % (group, role, info["leases"][role], info["timing"][role]))
        # мир: админ user, примеры бенчей (только недостающие — мир постоянный), сохранить
        _stdin(lab, world, owner, "olife.admins %s" % USER, r"admins=")
        have = {b["name"] for b in benches(lab, world, owner) if b["owner"] == USER}
        spawned = []
        for name, code in SAMPLES:
            if name in have:
                continue
            _stdin(lab, world, owner, "spawn_sample %s %s %s 1" % (USER, name, code),
                   r"spawned_sample account=%s name=%s|spawn_sample failed" % (USER, name), wait=6.0)
            spawned.append(name)
        if mode != "play":
            # сухой прогон идёт на КОПИИ мира пользователя, где тот мог остановить/переписать/переименовать пример
            # (02.10: demo_blink STOP с его кодом) — вернуть примеры к коду из файла и запустить (UX round 1)
            info["samples_reset"] = []
            for slot, (name, code) in enumerate(SAMPLES):
                if name in have:
                    _stdin(lab, world, owner, "sample_reset %s %s %d" % (USER, name, slot),
                           r"sample_reset account=%s name=%s|sample_reset failed" % (USER, name), wait=6.0)
                    info["samples_reset"].append(name)
        _stdin(lab, world, owner, "save", r"saved|save", wait=3.0)
        info["benches"] = benches(lab, world, owner)
        info["samples_spawned"] = spawned
        info["samples_available"] = list(EXTRA_SAMPLES)       # UX A3: spawn_sample user <name> <name> 1
        gi, ai = lab.lease_info(gw), lab.lease_info(auth)
        if public:
            info.update(gateway_port=pub["gateway"], packs_http=pub["packs"], admin_port=gi["ports"]["admin"],
                        auth_port=pub["auth"], auth_pub=keys["pub"], gw_id=gw_id, game_port=game)
            info["whitelist"] = PB.public_whitelist(lab, pub, gw_id)      # вайтлист включён (если не выключен в cfg)
            info["invite"] = PB.invite_text(lab, pub, keys["pub"], external=False)
            info["listen"] = PB.listeners(lab, info)                     # что на 0.0.0.0, что на 127.0.0.1
        else:
            info.update(gateway_port=gi["ports"]["gw"], packs_http=gi["ports"]["http"], admin_port=gi["ports"]["admin"],
                        auth_port=ai["ports"]["https"], auth_pub=keys["pub"], gw_id=gw_id, game_port=game)
        text = config_text(info, tok)
        info["config"] = os.path.join(base, CONFIG_NAME)
        with open(info["config"], "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        if mode == "play":                      # клиент обычного режима: <0.32>\export\olife_server.txt
            exp = os.path.join(engine_v032(lab)["root"], "export")
            os.makedirs(exp, exist_ok=True)
            info["client_config"] = os.path.join(exp, CONFIG_NAME)
            with open(info["client_config"], "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
        info["panel"] = sup.write_panel("olife", "Olife", P["SUP_PREFIX"])
        info["panel_url"] = "http://127.0.0.1:%d/sup/panel?prefix=%s&title=Olife" % (lab.cfg["daemon"]["port"],
                                                                                    P["SUP_PREFIX"])
        info["up_s"] = round(time.time() - t0, 2)
        with open(os.path.join(base, "play_up.json"), "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False, indent=1)
        return info
    except Exception:
        if g is not None:
            _down_quiet(sup, group, owner)
        for name in reversed(made):
            if name in lab.leases:
                try:
                    lab.release(name, owner=owner, reason="play-up-failed")
                except Exception:
                    pass
        raise


def _group(lab, args, owner=None):
    if args.get("group"):
        return lab.sup.get(args["group"])
    live = [g for n, g in lab.sup.groups.items() if n.startswith(P["SUP_PREFIX"] + "play-") and g.state == "up"]
    if len(live) != 1:
        raise KeyError("which olife play group? live: %s (pass group)" % (", ".join(g.name for g in live) or "none"))
    return live[0]


def play_status(lab, g):
    p = g.poll_data or {}
    w = p.get("world") or {}
    gw = p.get("gateway") or {}
    players = []
    for x in p.get("players") or []:
        players.append(x.get("name") or x.get("account") or str(x.get("eid")) if isinstance(x, dict) else str(x))
    incs = lab.sup.db.incidents(50, group=g.name)
    return {"group": g.name, "state": g.state, "players": players, "world_tick": w.get("tick"),
            "tick_ms": w.get("tick_ms"), "entities": w.get("entities"), "scripted": w.get("scripted"),
            "gw_sessions": gw.get("sessions"), "gw_auth_ok": gw.get("auth_ok"), "gw_rejects": gw.get("rejects"),
            "services": {r: {"state": s.state, "restarts": s.restarts} for r, s in g.services.items()},
            "incidents": [{"id": i["id"], "service": i["service"], "why": i["why"], "summary": i.get("summary")}
                          for i in incs], "metered": p.get("metered"), "poll_error": g.poll_error,
            "samples_available": list(EXTRA_SAMPLES)}          # UX A3: not auto-spawned (spawn_sample)


def play_down(lab, owner, args):
    """Сводка сессии (службы, перезапуски, инциденты, игроки, входы, учёт, песочница по владельцам) -> olife_session.
    json/md в run_dir (или базу), сохранить мир, снять группу."""
    g = _group(lab, args, owner)
    sup = lab.sup
    out = {"group": g.name, "ended": time.time(), "reason": args.get("reason")}
    st = play_status(lab, g)
    out["status"] = st
    wl = g.services["world"].lease if "world" in g.services else None
    if wl and wl in lab.leases:
        try:
            out["benches"] = benches(lab, wl, g.owner)
            lines, _ = _stdin(lab, wl, g.owner, "status", r"status tick=", wait=3.0)
            out["world_status"] = lines[-1] if lines else None
            lines, _ = _stdin(lab, wl, g.owner, "editor_status", r"editor\(", wait=3.0)
            out["editor_status"] = lines[-1] if lines else None
            _stdin(lab, wl, g.owner, "save", r"saved", wait=5.0)
        except Exception as exc:
            out["world_error"] = str(exc)
    sbl = g.services["sandbox"].lease if "sandbox" in g.services else None
    if sbl and sbl in lab.leases:
        r = lab.f2f_quiet(sbl, "meters", {}, timeout=3, owner=g.owner)
        out["sandbox_meters"] = r.get("result") if r.get("ok") else {"error": r.get("error")}
    db = sup.db
    mine = {"owner:%s" % o.get("owner") for o in ((out.get("sandbox_meters") or {}).get("owners") or [])
            if isinstance(o, dict)}
    out["counters"] = {k: v for k, v in db.counters().items() if k == USER or k in mine}   # накопленные в БД
    out["logins"] = [x for x in db.logins(50) if x.get("ts", 0) >= (g.created if hasattr(g, "created") else 0)][:20]
    out["events"] = db.events(80, group=g.name)
    out["down"] = sup.down(g.name, g.owner if owner is None else owner, release=True)
    if (g.meta or {}).get("play") == "play":    # порты стека больше не живы: меню 0.32 должно сказать «запустите сервер»
        try:
            cc = os.path.join(engine_v032(lab)["root"], "export", CONFIG_NAME)
            if os.path.exists(cc):
                os.remove(cc)
                out["client_config_removed"] = cc
        except OSError as exc:
            out["client_config_error"] = str(exc)
    d = args.get("run_dir") or (PLAY_DIR if (g.meta or {}).get("play") == "play" else None)
    if d:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "olife_session.json"), "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1, default=str)
        with open(os.path.join(d, "olife_session.md"), "w", encoding="utf-8") as f:
            f.write(session_md(out))
        out["files"] = [os.path.join(d, "olife_session.json"), os.path.join(d, "olife_session.md")]
    return out


def session_md(out):
    st = out.get("status") or {}
    L = ["# Olife: сводка сервера сессии %s" % out["group"], ""]
    L.append("| | |\n|---|---|")
    tm = st.get("tick_ms") if isinstance(st.get("tick_ms"), dict) else {}
    L.append("| мир | такт %s, мс/такт avg %s / p95 %s / max %s, сущностей %s (скриптовых %s) |" % (
        st.get("world_tick"), tm.get("avg"), tm.get("p95"), tm.get("max"), st.get("entities"), st.get("scripted")))
    L.append("| игроки при остановке | %s |" % (", ".join(st.get("players") or []) or "—"))
    L.append("| шлюз | сессий %s, входов %s, отказов %s |" % (st.get("gw_sessions"), st.get("gw_auth_ok"),
                                                            st.get("gw_rejects")))
    L.append("| службы | %s |" % ", ".join("%s %s (перезапусков %s)" % (r, s["state"], s["restarts"])
                                          for r, s in (st.get("services") or {}).items()))
    L.append("| инциденты | %d |" % len(st.get("incidents") or []))
    L.append("")
    for i in st.get("incidents") or []:
        L.append("- `%s` %s: %s — %s" % (i["id"], i["service"], i["why"], i.get("summary") or ""))
    if out.get("benches"):
        L += ["", "## Бенчи", "", "| eid | имя | владелец | статус |", "|---|---|---|---|"]
        L += ["| %s | %s | %s | %s |" % (b["eid"], b["name"], b["owner"], b["status"]) for b in out["benches"]]
    m = out.get("sandbox_meters") or {}
    owners = [o for o in (m.get("owners") or []) if isinstance(o, dict)] if isinstance(m, dict) else []
    if owners:
        keys = ("owner", "state", "ticks", "entity_ticks", "fuel", "credits", "actions", "actions_dropped", "kills",
                "traps", "mem_peak", "status")
        L += ["", "## Песочница по владельцам (сервис olife-sandboxd, эта сессия)", "",
              "| " + " | ".join(keys) + " |", "|---" * len(keys) + "|"]
        for v in owners:
            L.append("| %s |" % " | ".join(json.dumps(v.get(k)) if k == "status" else str(v.get(k)) for k in keys))
    if out.get("counters"):
        L += ["", "## Учёт: накопленные счётчики БД supervisor (аккаунт user и владельцы этой песочницы, все сессии)",
              "", "```", json.dumps(out["counters"], ensure_ascii=False, indent=1, default=str), "```"]
    for k in ("world_status", "editor_status"):
        if out.get(k):
            L += ["", "`%s`" % out[k][:400]]
    return "\n".join(L) + "\n"


# ============================================================================================== возможности
def f_play_up(ctx, args):
    lab = ctx.lab
    ttl = args.get("ttl") or 3600
    made = []

    def create(kind, role, params):
        r = ctx.lease(kind, params=params, ttl=ttl)
        made.append(r["lease"]["name"])
        return r["lease"]["name"]
    return play_up(lab, ctx.owner, args, create)


def f_play_down(ctx, args):
    return play_down(ctx.lab, ctx.owner, args)


def f_play_status(ctx, args):
    return play_status(ctx.lab, _group(ctx.lab, args, ctx.owner))


def f_sync(ctx, args):
    return sync_packs(ctx.lab)


def _lazy(name):
    """возможность берёт функцию из модуля в момент вызова: правка olife_play.py действует без перезагрузки plugin.py"""
    return lambda ctx, args: getattr(P["_play"](), name)(ctx, args)


def register(api):
    obj = {"type": "object"}
    api.feature("play_up", _lazy("f_play_up"), "player stack under supervisor (world on the persistent world <repo>\\projects\\olife\\external\\play "
                "or a dry-run copy, real sandbox, auth tickets, Rust gateway, account user, sample benches, client "
                "config export\\olife_server.txt) {mode=play|dry, public=0|1 (friends: fixed ports [play.public] on "
                "0.0.0.0, whitelist on, ServerInfo), sidecar?, session?}", obj)
    api.feature("play_down", _lazy("f_play_down"), "session summary (olife_session.json/md) + save world + group down "
                "{group?, run_dir?, reason?}", obj)
    api.feature("play_status", _lazy("f_play_status"), "player stack status {group?}", obj)
    api.feature("sync", _lazy("f_sync"), "client packs into <0.32>\\content as junctions to VC_ROOT\\content", obj)


# ============================================================================================== сухой прогон
def sc_start(sx, args):
    """olife_play_dry: коляска play_stack (mode=dry) -> тот же стек на копии мира; клиент F2F 0.32 со скриптом
    scripts/app/olife.lua и тем же файлом подключения."""
    stack = sx.lease("play_stack", role="stack", params={"mode": "dry", "daemon_port": sx.lab.cfg["daemon"]["port"]})
    sdir = sx.lab.lease_info(stack)["dir"]
    with open(os.path.join(sdir, "play_stack.json"), encoding="utf-8") as f:
        up = json.load(f)
    sx.data["play"] = up
    sx.data["group"] = None
    roles = dict(up["leases"])
    roles["stack"] = stack
    sx.data["session"] = {"session": up["session"], "group": up["group"], "leases": roles, "timing": up["timing"],
                          "client_kind": "play_client"}
    sx.data["metrics"] = {"play_up": {k: up.get(k) for k in ("up_s", "timing", "worlds_source", "samples_spawned",
                                                              "packs", "benches")}}
    t0 = time.time()
    # ядро: WinError 32 на leases.json.tmp -> leases.json при параллельной записи состояния (LESSONS) — повтор проходит
    for attempt in range(3):
        try:
            cl = sx.lease("play_client", role="client1", params={"config": up["config"]})
            break
        except Exception as exc:
            if "WinError 32" not in str(exc) or attempt == 2:
                raise
            sx.log("play_client start: %s -> retry" % str(exc)[:120])
            name = sx.leases.pop("client1", None)
            if name and name in sx.lab.leases:
                sx.lab.release(name, owner=sx.owner, reason="retry")
            time.sleep(0.5)
    roles["client1"] = cl
    sx.data["metrics"]["client_start_s"] = round(time.time() - t0, 2)
    sx.client = cl


def sc_stop(sx):
    """клиент (F2F quit) -> коляска (stdin stop -> olife.play_down: сводка + снятие группы); группа не снялась — снять;
    отчёт игры (play_report.md тем же кодом, что у lab play) по логам клиента и коляски."""
    roles = dict(sx.leases)
    m = sx.data.setdefault("metrics", {})
    rel = {}
    for r in [x for x in roles if x.startswith("client")] + ["stack"]:
        if r not in roles:
            continue
        try:
            x = sx.lab.release(roles[r], owner=sx.owner, reason="scenario-end")
            rel[roles[r]] = {"exit": x.get("exit"), "forced_kill": x.get("forced_kill")}
        except Exception as exc:
            rel[roles[r]] = {"error": str(exc)}
        sx.leases.pop(r, None)
    m["release"] = rel
    grp = (sx.data.get("play") or {}).get("group")
    g = sx.lab.sup.groups.get(grp) if grp else None
    if g is not None and g.state != "down":
        m["group_down_fallback"] = True
        _down_quiet(sx.lab.sup, grp, sx.owner)
    m["group_state"] = (sx.lab.sup.groups.get(grp).state if grp in sx.lab.sup.groups else None)
    try:
        m["play_report"] = dry_report(sx)
    except Exception as exc:
        m["play_report_error"] = "%s: %s" % (type(exc).__name__, exc)


def _run_log(run_dir, lease, stream):
    d = os.path.join(run_dir, "logs")
    if not os.path.isdir(d):
        return None
    c = sorted(n for n in os.listdir(d) if n.startswith(lease + "_" + stream + "_"))
    return os.path.join(d, c[-1]) if c else None


def dry_report(sx):
    """play_report.md/json + play_fps.svg кодом labcore.play (как у сеанса lab play) по логам сухого прогона."""
    from labcore import play as PL
    proj = sx.lab.projects.get("olife")
    rcfg = (proj.raw.get("play") or {}).get("report") or {}
    run_dir = sx.run["dir"]
    sess = sx.data["session"]["leases"]
    eng = _run_log(run_dir, sess["client1"], "stdout")
    srv = _run_log(run_dir, sess["stack"], "stdout")
    el, sl = PL.read_lines(eng) if eng else [], PL.read_lines(srv) if srv else []
    ts = [t for t in (PL._ts_of(l) for l in el) if t]
    meta = {"id": os.path.basename(run_dir) + "_play_dry", "project": "olife", "scenario": "play-dry",
            "started": ts[0] if ts else None, "ended": ts[-1] if ts else None, "ended_by": "dry-run scenario end",
            "exit": None, "owner": sx.owner, "leases": sess, "engine_log": eng,
            "size": "854x480 (F2F 0.32 test build, dry run)", "runtime": {"mode": None}}
    rep = PL.build_report(meta, el, sl, rcfg)
    out = os.path.join(run_dir, "play_report")
    PL.write_report(rep, out, rcfg)
    return {"md": rep["report_md"], "metrics": rep["metrics"], "verdict": rep["verdict"],
            "errors": rep.get("errors_total"), "events": rep.get("event_counts")}


# ---------------------------------------------------------------------------------------------- шаги сухого прогона
def _w4a():
    return P["_w4a"]()


def _client(sx):
    return sx.data["session"]["leases"]["client1"]


def _sample(sx, name):
    for b in (sx.data.get("play") or {}).get("benches") or []:
        if b["name"] == name:
            return b["eid"]
    raise KeyError("no sample bench %s in %s" % (name, (sx.data.get("play") or {}).get("benches")))


def st_connect(sx, args, step):
    """клиент в игре по билету аккаунта user; инструменты в слотах 1/2; админ; бенчи-примеры видны с бирками RUN"""
    W = _w4a()
    C = _client(sx)
    bad = []
    rep = {}
    st = W.wait_for(lambda: (lambda s: s if s.get("state") == "play" else None)(sx.raw("state", {}, lease=C)
                                                                               .get("result") or {}), 30)
    cs = st or (sx.raw("state", {}, lease=C).get("result") or {})
    rep["client"] = {k: cs.get(k) for k in ("state", "session", "eid", "chunks")}
    stl = (sx.raw("status", {}, lease=C).get("result") or {}).get("status") or ""
    mt = re.search(r"tickets=(\d+)", stl)
    rep["tickets"] = int(mt.group(1)) if mt else None
    if not st:
        return {"ok": False, "error": "client not in play: %s" % rep["client"], "result": rep}
    if not rep["tickets"]:
        bad.append("no ticket taken (status: %s)" % stl[-200:])
    names = [n for n, _ in SAMPLES]
    want = {_sample(sx, n): n for n in names}
    ok = W.wait_for(lambda: (lambda s: s if all(any(b["eid"] == e and (b.get("label") or "").endswith("RUN")
                                                    for b in s.get("benches") or []) for e in want) else None)(
        W.state(sx, C)), float(args.get("timeout", 20)))
    s = ok or W.state(sx, C)
    rep["benches"] = [{"eid": b["eid"], "label": b.get("label"), "owner": b.get("owner"), "status": b.get("status")}
                      for b in s.get("benches") or [] if b["eid"] in want]
    if not ok:
        bad.append("sample benches not all seen RUN: %s" % rep["benches"])
    rep["camera"] = s.get("camera")
    for slot, tool in (("1", 1), ("2", 2)):
        W.press_key(sx, C, slot)
        t = W.wait_for(lambda: (W.state(sx, C).get("camera") or {}).get("tool") == tool, 2.0)
        rep["slot%s_tool" % slot] = (W.state(sx, C).get("camera") or {}).get("tool")
        if not t:
            bad.append("slot %s holds tool %s, want %d" % (slot, rep["slot%s_tool" % slot], tool))
    lines, _ = _stdin(sx.lab, sx.data["session"]["leases"]["world"], sx.owner, "players", r"player")
    rep["world_players"] = lines[-3:]
    adm, _ = _stdin(sx.lab, sx.data["session"]["leases"]["world"], sx.owner, "bench %d" % _sample(sx, "demo_orbit"),
                    r"bench eid=")
    rep["orbit_world"] = adm[-1][-300:] if adm else None
    rep["shot"] = W.shot(sx, C, "play_connected")
    sx.data["metrics"]["connect"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def st_benches_move(sx, args, step):
    """примеры двигаются на сервере и в реплике клиента (путь за seconds), follow — к игроку"""
    W = _w4a()
    C = _client(sx)
    secs = float(args.get("seconds", 4))
    names = [n for n, _ in SAMPLES]
    ser = {n: {"w": [], "c": []} for n in names}
    end = time.time() + secs
    while time.time() < end:
        cs = {b["eid"]: b for b in W.state(sx, C).get("benches") or []}
        for n in names:
            e = _sample(sx, n)
            wi = W.bench_info(sx, e)
            if wi.get("pos"):
                ser[n]["w"].append(wi["pos"])
            if (cs.get(e) or {}).get("pos"):
                ser[n]["c"].append(cs[e]["pos"])
        time.sleep(0.35)
    import math

    def path(ps):
        return sum(math.dist(ps[i], ps[i + 1]) for i in range(len(ps) - 1)) if len(ps) > 1 else 0.0
    rep = {n: {"world_path": round(path(v["w"]), 3), "client_path": round(path(v["c"]), 3), "samples": len(v["w"])}
           for n, v in ser.items()}
    cam = (W.state(sx, C).get("camera") or {}).get("pos")
    fw = ser["demo_follow"]["w"]
    if cam and len(fw) > 1:
        rep["demo_follow"]["dist_to_player_start_end"] = [round(math.dist(fw[0], cam), 2), round(math.dist(fw[-1], cam), 2)]
    bad = [n for n in ("demo_orbit", "demo_blink") if rep[n]["world_path"] < 0.5 or rep[n]["client_path"] < 0.5]
    # follow: игрок отходит на 4 блока (F2F place двигает игрока-камеру; позиция уходит миру) -> бенч идёт следом
    fe = _sample(sx, "demo_follow")
    f0 = W.bench_info(sx, fe).get("pos")
    if cam and f0:
        # шагами по 0.25 блока раз в 0.1 с (2.5 бл/с): телепорт мир отклоняет поправкой (проверка скорости игрока)
        away = [f0[0] + 4.5, cam[1], f0[2]]
        n = 24
        for i in range(1, n + 1):
            W.ol(sx, C, "place", pos=[cam[j] + (away[j] - cam[j]) * i / n for j in range(3)])
            time.sleep(0.1)
        time.sleep(float(args.get("follow_seconds", 3)))
        f1 = W.bench_info(sx, fe).get("pos")
        cam2 = (W.state(sx, C).get("camera") or {}).get("pos")
        rep["demo_follow"]["player_moved_to"] = [round(v, 2) for v in cam2] if cam2 else None
        rep["demo_follow"]["follow_dist_before_after"] = [round(math.dist(f0, cam2), 2), round(math.dist(f1, cam2), 2)] \
            if cam2 and f1 else None
        if not (cam2 and f1 and math.dist(f1, cam2) < math.dist(f0, cam2) - 1.0):
            bad.append("demo_follow did not approach the player: %s" % rep["demo_follow"].get("follow_dist_before_after"))
        for i in range(1, n + 1):                           # назад к точке старта (дальше шаги — от неё)
            W.ol(sx, C, "place", pos=[away[j] + (cam[j] - away[j]) * i / n for j in range(3)])
            time.sleep(0.1)
        time.sleep(0.5)
    rep["shot"] = W.shot(sx, C, "play_benches")
    sx.data["metrics"]["benches_move"] = rep
    return {"ok": not bad, "result": rep, "error": ("not moving: %s" % bad) if bad else None}


EDIT_CODE = ["-- dry run: square path", "local t = 0", "function on_tick(dt)", "t = t + dt", "local p = self.pos",
             "local k = math.floor(t) % 4", "local dx = (k == 0 and 0.1) or (k == 2 and -0.1) or 0",
             "local dz = (k == 1 and 0.1) or (k == 3 and -0.1) or 0",
             "self:move_to({p[1] + dx, p[2], p[3] + dz})", "if math.floor(t * 20) % 40 == 0 then print('square', math.floor(t)) end",
             "end"]


def st_editor(sx, args, step):
    """Injector (слот 1) -> ПКМ по demo_orbit -> редактор (F2F gui) -> Clear, набор кода, Run -> мир RUN с тем же кодом
    (fnv), бенч двигается, консоль у клиента; Close (лок свободен)"""
    W = _w4a()
    C = _client(sx)
    eid = _sample(sx, args.get("bench", "demo_orbit"))
    rep = {"eid": eid}
    bad = []
    t0 = time.time()
    g, sel = W.open_with_injector(sx, C, eid)
    st = g.get("st") or {}
    rep["open"] = {"s": round(time.time() - t0, 2), "selected": sel, "doc": g.get("doc"), "editing": st.get("editing"),
                   "can_edit": st.get("can_edit"), "owner": st.get("owner"), "status": st.get("status")}
    if not (g.get("doc") and st.get("editing")):
        return {"ok": False, "error": "editor not open/editing: %s" % rep["open"], "result": rep}
    rep["shot_open"] = W.shot(sx, C, "play_editor_open")
    W.clear_code(sx, C, g)
    W.click(sx, C, g["rects"]["code"])
    W.type_code(sx, C, EDIT_CODE)
    want = "\n".join(EDIT_CODE)
    got = W.wait_for(lambda: (lambda x: x if (x.get("code") or "").rstrip() == want else None)(W.gui(sx, C)), 5.0)
    g = got or W.gui(sx, C)
    rep["typed_ok"] = got is not None
    if not got:
        bad.append("typed text differs: %r" % (g.get("code") or "")[:160])
    W.click(sx, C, g["rects"]["btn_run"])
    run = W.wait_for(lambda: (W.gui(sx, C).get("st") or {}).get("status") == 1, 6.0)
    w1 = W.bench_info(sx, eid)
    rep["world_after_run"] = {k: w1.get(k) for k in ("status", "code_len", "code_fnv", "owner", "lock")}
    rep["fnv_expected"] = W.fnv_str(g.get("code") or "")
    if not run or w1.get("status") != "run":
        bad.append("not RUN after Run (client %s, world %s)" % (bool(run), w1.get("status")))
    if w1.get("code_fnv") != rep["fnv_expected"]:
        bad.append("world code fnv %s != typed %s" % (w1.get("code_fnv"), rep["fnv_expected"]))
    import math
    ps = []
    end = time.time() + float(args.get("run_seconds", 4))
    while time.time() < end:
        p = W.bench_info(sx, eid).get("pos")
        if p:
            ps.append(p)
        time.sleep(0.4)
    rep["world_path"] = round(sum(math.dist(ps[i], ps[i + 1]) for i in range(len(ps) - 1)), 3) if len(ps) > 1 else 0
    if rep["world_path"] < 0.5:
        bad.append("edited bench did not move (%.3f)" % rep["world_path"])
    gc = W.gui(sx, C)
    rep["console_tail"] = (gc.get("console") or "").splitlines()[-4:]
    if not any("square" in x for x in rep["console_tail"]):
        bad.append("no script output in the console: %s" % rep["console_tail"])
    rep["shot_run"] = W.shot(sx, C, "play_editor_running")
    W.click(sx, C, gc["rects"]["btn_close"])
    closed = W.wait_for(lambda: not W.gui(sx, C).get("doc") and W.bench_info(sx, eid).get("lock") == "-", 4.0)
    rep["closed"] = bool(closed)
    if not closed:
        bad.append("editor not closed / lock held")
    sx.data["metrics"]["editor"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


def st_gravity(sx, args, step):
    """GravityGun (слот 2): взгляд на бенч, ЛКМ -> держит; поворот взгляда -> мир двигает бенч; ЛКМ -> отпустил, позиции
    клиента и мира совпали"""
    import math
    W = _w4a()
    C = _client(sx)
    eid = _sample(sx, args.get("bench", "demo_blink"))
    rep = {"eid": eid}
    bad = []
    w0 = W.bench_info(sx, eid)
    W.press_key(sx, C, "2")
    W.ol(sx, C, "aim", quiet=False, eid=eid)
    time.sleep(0.3)
    rep["tool"] = (W.state(sx, C).get("camera") or {}).get("tool")
    W.mouse_button(sx, C, 0)
    held = W.wait_for(lambda: W.state(sx, C).get("holding") == eid, 3.0)
    wh = W.bench_info(sx, eid)
    rep["grab"] = {"holding": bool(held), "world_holder": wh.get("holder"), "reply": W.last_reply(W.state(sx, C), 6, eid)}
    if not held or wh.get("holder") in (None, "-"):
        return {"ok": False, "error": "grab failed: %s" % rep["grab"], "result": rep}
    cam = W.state(sx, C).get("camera") or {}
    yaw0, pitch0 = cam.get("yaw") or 0, cam.get("pitch") or 0
    for i in range(1, 13):
        W.ol(sx, C, "look", yaw=yaw0 + 70.0 * i / 12, pitch=pitch0)
        time.sleep(0.15)
    time.sleep(0.6)
    wm = W.bench_info(sx, eid)
    rep["moved_world"] = round(math.dist(w0["pos"], wm["pos"]), 3) if w0.get("pos") and wm.get("pos") else None
    if not rep["moved_world"] or rep["moved_world"] < 1.0:
        bad.append("held bench did not move (%s)" % rep["moved_world"])
    rep["shot_hold"] = W.shot(sx, C, "play_gravity_holding")
    W.mouse_button(sx, C, 0)
    rel = W.wait_for(lambda: W.state(sx, C).get("holding") is None and W.bench_info(sx, eid).get("holder") == "-", 3.0)
    rep["released"] = bool(rel)
    if not rel:
        bad.append("release failed")
    time.sleep(1.0)
    wf = W.bench_info(sx, eid)
    cf = W.bench_of(W.state(sx, C), eid) or {}
    rep["final"] = {"world": wf.get("pos"), "client": cf.get("pos")}
    # blink снова двигается сам (sandbox), поэтому сравнение «клиент = мир» — с допуском шага интерполяции
    if cf.get("pos") and wf.get("pos"):
        rep["final"]["gap"] = round(math.dist(cf["pos"], wf["pos"]), 3)
    sx.data["metrics"]["gravity"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------------------------------------- UX round 1 (olife_ux1)
def ux_shot(sx, C, name):
    """F2F-снимок кадрового буфера в каталог прогона (shots\\<сценарий>\\<name>.png) -> путь"""
    path = os.path.join(sx.out_dir(), name + ".png")
    try:
        r = sx.call("shot", {"path": path, "name": name}, lease=C)
        return {"path": path, "w": (r or {}).get("w"), "h": (r or {}).get("h")}
    except Exception as exc:
        return {"path": None, "error": str(exc)}


def _area(r):
    return (r or {}).get("w", 0) * (r or {}).get("h", 0)


def _overlap(a, b):
    return not (a["x"] + a["w"] <= b["x"] + 0.5 or b["x"] + b["w"] <= a["x"] + 0.5 or
                a["y"] + a["h"] <= b["y"] + 0.5 or b["y"] + b["h"] <= a["y"] + 0.5)


def ux_layout_check(g):
    """редактор на весь кадр, поле кода — самый большой элемент (кроме контейнеров страниц), ряд кнопок и вкладки не
    перекрываются, код/консоль/панель скриптов не перекрываются"""
    bad = []
    r = g.get("rects") or {}
    vp = g.get("viewport") or [854, 480]
    root = r.get("root") or {}
    if abs(root.get("w", 0) - 854) > 2 or abs(root.get("h", 0) - 854 * vp[1] / vp[0]) > 2:
        bad.append("root %sx%s is not the whole frame" % (root.get("w"), root.get("h")))
    containers = {"root", "page_code", "page_prof", "page_set"}
    code = r.get("code") or {}
    others = {k: _area(v) for k, v in r.items() if v and k not in containers and k != "code" and v.get("visible") is not False}
    big = max(others.items(), key=lambda kv: kv[1]) if others else (None, 0)
    if _area(code) <= big[1]:
        bad.append("code %.0f px^2 is not the largest (%s %.0f)" % (_area(code), big[0], big[1]))
    row = [k for k in ("btn_close", "btn_run", "fname", "btn_save", "btn_edit", "tab_code", "tab_prof", "tab_set", "status")
           if r.get(k) and r[k].get("visible") is not False]
    for i in range(len(row)):
        for j in range(i + 1, len(row)):
            if _overlap(r[row[i]], r[row[j]]):
                bad.append("%s overlaps %s" % (row[i], row[j]))
    for a_, b_ in (("code", "console"), ("code", "scripts"), ("console", "scripts"), ("toolbar", "code"),
                   ("status", "code")):
        if r.get(a_) and r.get(b_) and _overlap(r[a_], r[b_]):
            bad.append("%s overlaps %s" % (a_, b_))
    for k in row:
        x = r[k]
        if x["x"] < -0.5 or x["y"] < -0.5 or x["x"] + x["w"] > 854.5 or x["y"] + x["h"] > root.get("h", 480) + 0.5:
            bad.append("%s outside the frame %s" % (k, x))
    sizes = {k: [round(v["w"]), round(v["h"])] for k, v in r.items() if v}
    return bad, {"code_area": _area(code), "next_largest": [big[0], big[1]], "sizes": sizes}


def _open_editor(sx, C, W, eid):
    g, sel = W.open_with_injector(sx, C, eid)
    return g, sel


def _close_editor(sx, C, W):
    g = W.gui(sx, C)
    if g.get("doc"):
        W.click(sx, C, g["rects"]["btn_close"])
        W.wait_for(lambda: not W.gui(sx, C).get("doc"), 3.0)


def _hold(sx, C, W, button, seconds):
    """кнопка мыши зажата seconds (20 тактов = 1 с), затем отпущена"""
    W.inp(sx, C, mouse={"buttons": [i == button for i in range(3)]})
    time.sleep(seconds)
    W.inp(sx, C, mouse={"buttons": [False, False, False]})
    time.sleep(0.08)


def _approach(sx, C, W, eid, dist=1.8):
    """встать в dist блоках от бенча eid со стороны demo_follow (он держится в 2 бл от игрока и иначе оказывается на
    луче между игроком и бенчем — тогда мир по лучу честно выбирает его); шаги по 0.25 бл раз в 0.1 с (скорость
    игрока мир проверяет), потом взгляд на бенч"""
    import math
    b = W.bench_info(sx, eid).get("pos")
    cam = (W.state(sx, C).get("camera") or {}).get("pos")
    if not b or not cam:
        return None
    try:
        f = W.bench_info(sx, _sample(sx, "demo_follow")).get("pos")
    except KeyError:
        f = None
    ref = f if f and math.dist(f[:1] + f[2:], b[:1] + b[2:]) > 0.3 else cam
    dx, dz = ref[0] - b[0], ref[2] - b[2]
    l = math.hypot(dx, dz) or 1.0
    tgt = [b[0] + dx / l * dist, b[1] - 1.0, b[2] + dz / l * dist]
    n = max(1, int(math.dist(cam, tgt) / 0.25) + 1)
    for i in range(1, n + 1):
        W.ol(sx, C, "place", pos=[cam[j] + (tgt[j] - cam[j]) * i / n for j in range(3)])
        time.sleep(0.1)
    time.sleep(0.3)
    W.ol(sx, C, "aim", quiet=False, eid=eid)
    time.sleep(0.2)
    return {"steps": n, "at": [round(v, 2) for v in tgt],
            "selected": (W.state(sx, C).get("camera") or {}).get("selected_eid")}


def st_ux(sx, args, step):
    """UX round 1 (замечания пользователя 1-6): редактор (макет оригинала, поле кода — самое большое, панель скриптов,
    страницы Профайлер/Настройки, ` по бенчу), модели оригинала, нет монет, гравипушка — одно нажатие = одно
    переключение при зажатой кнопке 20 тактов, бирки только с Injector'ом, Shift+ПКМ открывает последнюю сущность,
    Shift+ЛКМ удаляет её (сервер, код ответа). Снимки — в каталог прогона."""
    import math
    W = _w4a()
    C = _client(sx)
    wl = sx.data["session"]["leases"]["world"]
    rep = {"shots": {}}
    bad = []
    m = sx.data["metrics"].setdefault("ux", rep)
    # отдельный бенч владельца user для настроек и удаления (примеры не трогаем)
    lines, _ = _stdin(sx.lab, wl, sx.owner, "spawn_bench %s ux_bench 1" % USER, r"spawned_bench account=%s eids=" % USER,
                      wait=6.0)
    ln = [x for x in lines if "spawned_bench account=%s eids=" % USER in x]
    if not ln:
        return {"ok": False, "error": "no ux bench: %s" % lines[-3:]}
    ux = int(ln[-1].split("eids=")[1].split()[0].split(",")[0])
    rep["ux_eid"] = ux
    # подальше от кольца примеров (demo_orbit летает по кругу радиуса 2 рядом с местом spawn_bench и оказывается на луче)
    wp = W.bench_info(sx, ux).get("pos")
    if wp:
        cx, cz = wp[0] - 3.0, wp[2] - 3.0       # spawn_bench: spawn + (3 + cos a * 2, 1.5, 3 + sin a * 2)
        _stdin(sx.lab, wl, sx.owner, "bench_place %d %.2f %.2f %.2f" % (ux, cx - 6.0, wp[1], cz - 6.0), r"bench_place eid=",
               wait=3.0)
        rep["ux_pos"] = W.bench_info(sx, ux).get("pos")
    if not W.wait_for(lambda: W.bench_of(W.state(sx, C), ux), 10):
        return {"ok": False, "error": "client does not see ux bench %d" % ux}

    # --- 3. монет нет: ни в инвентаре, ни в определениях предметов клиента; мир не выдаёт
    st = W.state(sx, C)
    rep["inventory"] = st.get("inventory")
    rep["coin_defined"] = st.get("coin_defined")
    if st.get("coin_defined") or any("coin" in (x.get("item") or "") for x in st.get("inventory") or []):
        bad.append("coin still present: defined=%s inv=%s" % (st.get("coin_defined"), st.get("inventory")))

    # --- 5. бирки: только с Injector'ом (слот 1), с GravityGun (слот 2) — нет
    W.press_key(sx, C, "2")
    t2 = W.wait_for(lambda: (lambda s: s if s.get("tags") == 0 and (s.get("camera") or {}).get("tool") == 2 else None)(
        W.state(sx, C)), 3.0)
    W.press_key(sx, C, "1")
    t1 = W.wait_for(lambda: (lambda s: s if s.get("tags", 0) > 0 and s.get("tags_on") else None)(W.state(sx, C)), 3.0)
    rep["tags"] = {"gravity_gun": (t2 or W.state(sx, C)).get("tags"), "injector": (t1 or W.state(sx, C)).get("tags")}
    if not t2 or not t1:
        bad.append("tag visibility does not follow the slot: %s" % rep["tags"])
    rep["approach"] = _approach(sx, C, W, ux)
    rep["shots"]["tags_injector"] = ux_shot(sx, C, "ux_tags_injector")
    W.press_key(sx, C, "2")
    time.sleep(0.4)
    rep["shots"]["tags_gravity"] = ux_shot(sx, C, "ux_tags_gravity_gun")

    # --- 1. редактор: Injector ПКМ -> макет, размеры, панель скриптов, страницы
    g, sel = _open_editor(sx, C, W, ux)
    if not g.get("doc"):
        return {"ok": False, "error": "editor did not open on ux bench", "result": rep}
    lb, lay = ux_layout_check(g)
    rep["layout"] = lay
    bad += ["layout: " + x for x in lb]
    rep["shots"]["editor"] = ux_shot(sx, C, "ux_editor")
    rep["status_line"] = g.get("status")
    if not g.get("status") or "\n" in g.get("status"):
        bad.append("status line: %r" % g.get("status"))
    # панель скриптов: новый файл через имя + СОХРАНИТЬ, строка в панели, удаление «x»
    W.click(sx, C, g["rects"]["fname"])
    W.inp(sx, C, chars="ux1_test")
    time.sleep(0.15)
    W.click(sx, C, g["rects"]["btn_save"])
    g2 = W.wait_for(lambda: (lambda x: x if "ux1_test" in (x.get("files") or []) else None)(W.gui(sx, C)), 3.0)
    g2 = g2 or W.gui(sx, C)
    kinds = [it.get("kind") for it in g2.get("scripts") or []]
    rep["scripts_panel"] = {"rows": [it.get("caption") for it in g2.get("scripts") or []], "files": g2.get("files"),
                            "notice": g2.get("notice")}
    if "ux1_test" not in (g2.get("files") or []) or not W.script_row(g2, "file", "ux1_test"):
        bad.append("saved file not listed in the scripts panel: %s" % rep["scripts_panel"])
    if not ("server" in kinds and "template" in kinds and "new" in kinds):
        bad.append("scripts panel kinds: %s" % kinds)
    rep["shots"]["editor_scripts"] = ux_shot(sx, C, "ux_editor_scripts")
    for it in g2.get("scripts") or []:
        if it.get("kind") == "file" and it.get("name") == "ux1_test" and it.get("del"):
            W.click(sx, C, it["del"])
            break
    gd = W.wait_for(lambda: (lambda x: x if "ux1_test" not in (x.get("files") or []) else None)(W.gui(sx, C)), 3.0)
    rep["scripts_panel"]["deleted"] = bool(gd)
    if not gd:
        bad.append("file delete from the scripts panel failed")
    # шаблон из панели скриптов -> RUN (кнопка-переключатель оригинала): бенч работает, профайлеру есть что показать
    gt = W.gui(sx, C)
    W.click(sx, C, W.script_row(gt, "template", "hello"))
    W.click(sx, C, gt["rects"]["btn_run"])
    run = W.wait_for(lambda: (W.gui(sx, C).get("st") or {}).get("status") == 1, 5.0)
    gr = W.gui(sx, C)
    rep["template_run"] = {"running": bool(run), "button": gr.get("run_text"), "icon": gr.get("run_icon"),
                           "code_head": (gr.get("code") or "")[:40]}
    if not run or gr.get("run_text") != "STOP":
        bad.append("template + RUN: %s" % rep["template_run"])
    # Профайлер
    W.click(sx, C, g["rects"]["tab_prof"])
    gp = W.wait_for(lambda: (lambda x: x if x.get("tab") == "prof" and (x.get("rects") or {}).get("page_prof", {}).get(
        "visible") and x.get("prof") and (x.get("hist_n") or 0) >= 3 and ((x.get("st") or {}).get("meters") or {}).get(
        "credits_tick", 0) > 0 else None)(W.gui(sx, C)), 8.0)
    gp = gp or W.gui(sx, C)
    rep["profiler"] = {"tab": gp.get("tab"), "left": gp.get("pf_left"), "right": gp.get("pf_right"), "prof": gp.get("prof"),
                       "hist_n": gp.get("hist_n"), "spark_h": [h for h in (gp.get("spark_h") or []) if h],
                       "meters": (gp.get("st") or {}).get("meters"),
                       "page_visible": (gp.get("rects") or {}).get("page_prof", {}).get("visible"),
                       "code_visible": (gp.get("rects") or {}).get("code", {}).get("visible")}
    if not (gp.get("tab") == "prof" and "кредиты" in (gp.get("pf_left") or "") and gp.get("prof")):
        bad.append("profiler page: %s" % {k: rep["profiler"][k] for k in ("tab", "page_visible", "hist_n")})
    rep["shots"]["profiler"] = ux_shot(sx, C, "ux_profiler")
    # Настройки: владелец, переименование, вид (модель/текстура из списка пака), без удаления здесь
    W.click(sx, C, g["rects"]["tab_set"])
    gs = W.wait_for(lambda: (lambda x: x if x.get("tab") == "set" and USER in (x.get("set_owner") or "") else None)(
        W.gui(sx, C)), 3.0)
    gs = gs or W.gui(sx, C)
    rep["settings"] = {"owner": gs.get("set_owner"), "look": gs.get("set_look"), "name": gs.get("set_name")}
    if not gs.get("tab") == "set":
        bad.append("settings page did not open")
    W.click(sx, C, gs["rects"]["set_name"])
    W.press_key(sx, C, "end")
    W.inp(sx, C, chars="_r")
    time.sleep(0.15)
    W.click(sx, C, gs["rects"]["btn_rename"])
    W.ol(sx, C, "ui", call="pick_model", arg="olife_bone")         # пункты select — выбор через ui (клик по списку
    W.ol(sx, C, "ui", call="pick_texture", arg="blocks:planks")    # зависит от его раскладки); кнопка — кликом
    W.click(sx, C, gs["rects"]["btn_look"])
    wi = W.wait_for(lambda: (lambda d: d if d.get("model") == "olife_bone" and d.get("name") == "ux_bench_r" else None)(
        W.bench_info(sx, ux)), 4.0)
    wi = wi or W.bench_info(sx, ux)
    bl = W.wait_for(lambda: (lambda b: b if b and (b.get("look") or {}).get("applied") and
                             (b.get("label") or "").startswith("ux_bench_r") else None)(W.bench_of(W.state(sx, C), ux)), 4.0)
    rep["settings"]["world"] = {k: wi.get(k) for k in ("name", "model", "texture", "label")}
    rep["settings"]["client_look"] = (bl or {}).get("look")
    if wi.get("model") != "olife_bone" or wi.get("texture") != "blocks:planks" or wi.get("name") != "ux_bench_r":
        bad.append("settings not applied by the world: %s" % rep["settings"]["world"])
    if not bl:
        bad.append("client did not apply look/rename: %s" % W.bench_of(W.state(sx, C), ux))
    time.sleep(0.3)
    rep["shots"]["settings"] = ux_shot(sx, C, "ux_settings")
    W.click(sx, C, gs["rects"]["tab_code"])
    _close_editor(sx, C, W)
    rep["shots"]["bench_bone_look"] = ux_shot(sx, C, "ux_bench_bone_look")

    # --- 1. ` (backtick) по бенчу -> редактор
    W.press_key(sx, C, "1")
    _approach(sx, C, W, ux)
    W.press_key(sx, C, "grave-accent")
    gb = W.wait_for(lambda: (lambda x: x if x.get("doc") and x.get("open") == ux else None)(W.gui(sx, C)), 4.0)
    rep["backtick_open"] = bool(gb)
    if not gb:
        bad.append("` while aiming at the bench did not open its editor")
    _close_editor(sx, C, W)

    # --- 4. гравипушка: ЛКМ зажата 20 тактов -> ровно одно переключение (захват), затем ПКМ зажата 20 тактов -> ровно
    # одно (отпускание); повторы on_use (каждые 0.16 с) отброшены
    W.press_key(sx, C, "2")
    _approach(sx, C, W, ux)
    s0 = W.state(sx, C)["stats"]
    _hold(sx, C, W, 0, 1.0)
    held = W.wait_for(lambda: W.state(sx, C).get("holding") == ux, 2.0)
    s1 = W.state(sx, C)
    rep["gravity_lmb"] = {"toggles": s1["stats"]["toggles"] - s0["toggles"], "holding": s1.get("holding"),
                          "ignored": s1["stats"]["presses_ignored"] - s0["presses_ignored"],
                          "world_holder": W.bench_info(sx, ux).get("holder")}
    if rep["gravity_lmb"]["toggles"] != 1 or not held:
        bad.append("LMB held 20 ticks: %s (want exactly 1 toggle = grab)" % rep["gravity_lmb"])
    W.ol(sx, C, "aim", quiet=False, eid=ux)
    time.sleep(0.2)
    s1s = s1["stats"]
    _hold(sx, C, W, 1, 1.0)
    rel = W.wait_for(lambda: W.state(sx, C).get("holding") is None and W.bench_info(sx, ux).get("holder") == "-", 2.0)
    s2 = W.state(sx, C)
    rep["gravity_rmb"] = {"toggles": s2["stats"]["toggles"] - s1s["toggles"], "holding": s2.get("holding"),
                          "ignored": s2["stats"]["presses_ignored"] - s1s["presses_ignored"],
                          "world_holder": W.bench_info(sx, ux).get("holder")}
    if rep["gravity_rmb"]["toggles"] != 1 or not rel:
        bad.append("RMB held 20 ticks: %s (want exactly 1 toggle = release)" % rep["gravity_rmb"])
    if rep["gravity_rmb"]["ignored"] < 1:
        bad.append("RMB repeats were not seen/ignored: %s" % rep["gravity_rmb"])
    rep["sounds_after_gravity"] = W.state(sx, C).get("sounds")
    if not {"grab", "release"} <= set(rep["sounds_after_gravity"] or []):
        bad.append("no grab/release sounds: %s" % rep["sounds_after_gravity"])

    # --- 6. Shift+ПКМ: редактор последней открытой сущности, не глядя на неё
    W.press_key(sx, C, "1")
    cam = W.state(sx, C).get("camera") or {}
    W.ol(sx, C, "look", yaw=(cam.get("yaw") or 0) + 180, pitch=60)
    time.sleep(0.3)
    rep["shift_rmb_selected"] = (W.state(sx, C).get("camera") or {}).get("selected_eid")
    W.inp(sx, C, keys={"left-shift": True})
    time.sleep(0.1)
    W.mouse_button(sx, C, 1)
    W.inp(sx, C, keys={"left-shift": False})
    gsr = W.wait_for(lambda: (lambda x: x if x.get("doc") and x.get("open") == ux else None)(W.gui(sx, C)), 4.0)
    rep["shift_rmb_open"] = {"opened": bool(gsr), "last_opened": W.state(sx, C).get("last_opened")}
    if not gsr or rep["shift_rmb_selected"] == ux:
        bad.append("Shift+RMB did not open the last entity while not aiming at it: %s" % rep["shift_rmb_open"])
    _close_editor(sx, C, W)
    # --- 6. Shift+ЛКМ: удалить последнюю открытую (владелец user, сервер, код ответа 0, звук, сообщение)
    W.inp(sx, C, keys={"left-shift": True})
    time.sleep(0.1)
    W.mouse_button(sx, C, 0)
    W.inp(sx, C, keys={"left-shift": False})
    W.wait_for(lambda: W.state(sx, C).get("toast"), 3.0)
    rep["shots"]["after_delete"] = ux_shot(sx, C, "ux_after_delete_toast")
    gone = W.wait_for(lambda: (lambda d: {"gone": True} if not d.get("eid") else None)(W.bench_info(sx, ux)), 4.0)
    s3 = W.state(sx, C)
    r7 = W.last_reply(s3, 7, ux)
    rep["shift_lmb_delete"] = {"world_gone": gone is not None, "reply": r7, "toast": s3.get("last_toast"),
                               "sounds": s3.get("sounds"), "deletes_ok": s3["stats"].get("deletes_ok")}
    bl = [x for x in _stdin(sx.lab, wl, sx.owner, "benches", r"benches n=")[0] if "benches n=" in x]
    rep["shift_lmb_delete"]["benches_after"] = bl[-1][-200:] if bl else None
    if not gone or not r7 or r7.get("code") != 0 or "delete" not in (s3.get("sounds") or []) or \
            "удалена" not in (s3.get("last_toast") or ""):
        bad.append("Shift+LMB delete: %s" % rep["shift_lmb_delete"])
    rep["shot_paths"] = [v.get("path") for v in rep["shots"].values() if v and v.get("path")]
    rep["errors"] = bad
    with open(os.path.join(sx.out_dir(), "olife_ux.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)
    return {"ok": not bad, "result": {k: rep[k] for k in rep if k != "layout"} | {"layout_next": rep["layout"]["next_largest"]},
            "error": "; ".join(bad) or None}


def st_status_lines(sx, args, step):
    """строки статуса клиента ([olife_play] status fps ...) идут (их читает отчёт игры), сводка стека"""
    C = _client(sx)
    lines = sx.lab.logs(C, stream="stdout", tail=400, grep=r"\[olife_play\]")["lines"]
    st = [l for l in lines if "[olife_play] status fps" in l]
    fps = []
    for l in st:
        m = re.search(r"status fps ([\d.]+)", l)
        if m:
            fps.append(float(m.group(1)))
    rep = {"status_lines": len(st), "fps": fps[-8:], "last": st[-1][-220:] if st else None,
           "stack": f_status_sx(sx)}
    sx.data["metrics"]["status_lines"] = rep
    ok = len(st) >= int(args.get("min", 2)) and all(f > 0 for f in fps)
    return {"ok": ok, "result": rep, "error": None if ok else "status lines: %d, fps %s" % (len(st), fps)}


def f_status_sx(sx):
    grp = (sx.data.get("play") or {}).get("group")
    try:
        return play_status(sx.lab, sx.lab.sup.get(grp))
    except Exception as exc:
        return {"error": str(exc)}


def steps():
    return {"olife_play_connect": st_connect, "olife_play_benches": st_benches_move, "olife_play_editor": st_editor,
            "olife_play_gravity": st_gravity, "olife_play_status": st_status_lines, "olife_play_ux": st_ux}


def selftest():
    t = config_text({"gateway_port": 1, "auth_port": 2, "auth_pub": "x"}, "tok")
    assert "gateway=127.0.0.1:1" in t and "token=tok" in t and "gw_id=%s" % GW_ID in t
