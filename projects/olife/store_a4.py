"""olife, UX A4 (03.10, агент olife_a4): хранилище — KV моба, активы владельца (sha256 CAS), раздача клиентам,
canvas-текстуры, снимок/восстановление. Подключается из plugin.py (`_a4()`, перезагрузка по mtime этого файла).

Мир — stdin (`store_*`, `spawn_bench`, `bench`), клиенты — F2F 0.32 (`assets {op=state|upload|op}` в
content/olife_client/scripts/world.lua -> olife_client:assets), код бенча ставит протокольный клиент
(tools/olife/editor_neg.py set_code, аккаунт без оконного клиента — иначе код 12 «вход с другого соединения»).
Шаги:
  olife_store_kv {bench, script_bench?}   — KV через мир: запись/чтение, квота (42), тариф (44), плохой ключ (49);
        скрипт demo_memory_counter (A3 memory.*) пишет в то же хранилище
  olife_store_canvas {bench, viewer, seconds} — demo_paint: кадры canvas -> PNG в CAS -> слот tex:* -> EntityAssets ->
        клиент B скачал по HTTP шлюза, sha256 файла, RGBA декодированной текстуры = RGBA мира (store_rgba), текстура
        движка (assets.to_canvas) = то же, на скелете $0..$5 = olife_assets/<sha>; кадры меняются, CAS дедуп
  olife_store_upload {bench}               — A (alice) загружает PNG в библиотеку и на свой бенч; B видит; отказы:
        чужой бенч 41, не PNG 46, квота 43; share alice -> bob, список bob (AssetList)
  olife_store_snapshot {bench}             — store_snapshot -> store_restore -> снимок копии == снимок оригинала
        (кроме eid/такта/позиции); KV и слоты копии равны
  olife_store_restart {bench, script_bench?} — save + store_flush, перезапуск мира (та же аренда): KV, слоты, файлы
        CAS, библиотека — те же; demo_memory_counter: runs + 1, count продолжился
"""
import base64
import hashlib
import json
import os
import re
import struct
import time
import zlib

P = {}

NAMES = {"olife_store_kv": "st_kv", "olife_store_canvas": "st_canvas", "olife_store_upload": "st_upload",
         "olife_store_snapshot": "st_snapshot", "olife_store_restart": "st_restart"}


def bind(g):
    P.update(g)


def steps():
    return {n: _lazy(n) for n in NAMES}


def _lazy(n):
    def f(sx, args, step):
        return getattr(P["_a4"](), NAMES[n])(sx, args, step)
    return f


# ---------------------------------------------------------------------------------------------- общее
def _packs_root():
    from vclab import config
    return config.PACKS_DIR


def _w4a():
    return P["_w4a"]()


def _m(sx):
    return sx.data.setdefault("metrics", {}).setdefault("a4", {})


def stdin(sx, cmd, pattern, wait=4.0):
    lease = P["_roles"](sx)["world"]
    return sx.lab.stdin(lease, cmd, owner=sx.owner, wait=wait, pattern=pattern)


def stdin_line(sx, cmd, prefix, wait=4.0):
    r = stdin(sx, cmd, re.escape(prefix), wait)
    ls = [x for x in r.get("lines") or [] if prefix in x]
    return ls[-1][ls[-1].find(prefix):] if ls else ""


def json_tail(line, key):
    """'... key=<json>' -> parsed JSON (the rest of the line)"""
    i = line.find(key + "=")
    if i < 0:
        return None
    try:
        return json.JSONDecoder().raw_decode(line[i + len(key) + 1:])[0]
    except ValueError:
        return None


def kv(sx, eid):
    line = stdin_line(sx, "store_kv %d" % eid, "store_kv eid=%d" % eid)
    d = P["_kv"](line.split(" kv=")[0]) if line else {}
    d["kv"] = json_tail(line, "kv")
    return d


def ent_assets(sx, eid):
    line = stdin_line(sx, "store_entity %d" % eid, "store_entity eid=%d" % eid)
    m = re.search(r"rev=(\d+)", line)
    return {"rev": int(m.group(1)) if m else 0, "assets": json_tail(line, "assets") or {}}


def assets(sx, lease, op="state", **a):
    a["op"] = op
    r = sx.raw("assets", a, lease=lease)
    if not r.get("ok"):
        raise RuntimeError("assets %s on %s: %s" % (op, lease, r.get("error")))
    return r["result"]


def world_dir(sx):
    return sx.lab.lease_info(P["_roles"](sx)["world"])["dir"]


def eid_of(sx, args, key="bench", default="alice"):
    v = args.get(key, default)
    if isinstance(v, int):
        return v
    return _w4a()._w(sx)["benches"][v][0]


def wait_for(fn, timeout, every=0.2):
    return _w4a().wait_for(fn, timeout, every)


def png_rgba(w, h, rgba):
    """минимальный PNG (RGBA8, без фильтра) — загрузка клиентом"""
    raw = b"".join(b"\0" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def reply_of(sx, lease, seq, timeout=6.0):
    def f():
        for r in assets(sx, lease).get("replies") or []:
            if r.get("seq") == seq:
                return r
        return None
    return wait_for(f, timeout)


# ---------------------------------------------------------------------------------------------- KV
def st_kv(sx, args, step):
    eid = eid_of(sx, args)
    rep, bad = {"eid": eid}, []

    def set_(k, v, want):
        line = stdin(sx, "store_kv_set %d %s %s" % (eid, k, v), r"kv_set eid=%d key=%s code=" % (eid, re.escape(k)))
        ls = [x for x in line.get("lines") or [] if "kv_set eid=%d key=%s code=" % (eid, k) in x]
        code = int(ls[-1].split("code=")[1].split()[0]) if ls else None
        rep.setdefault("writes", []).append({"key": k, "code": code, "want": want})
        if code != want:
            bad.append("kv_set %s -> %s (want %s)" % (k, code, want))
        return code
    set_("greeting", "hello", 0)
    set_("n", "42", 0)
    d = kv(sx, eid)
    rep["after_writes"] = {k: d.get(k) for k in ("used", "quota", "keys")}
    if (d.get("kv") or {}).get("greeting") != "hello" or (d.get("kv") or {}).get("n") != 42:
        bad.append("kv read back %s" % d.get("kv"))
    set_("k" * 65, "x", 49)                              # ключ длиннее 64 байт
    # квота: kv_quota 64 байта -> длинное значение отказ 42; тариф: ведро 0 -> отказ 44; вернуть умолчания
    stdin(sx, "store_tariff kv_quota 64", r"store_tariff kv_quota")
    set_("big", "x" * 60, 42)
    stdin(sx, "store_tariff kv_quota 65536", r"store_tariff kv_quota")
    stdin(sx, "store_tariff credits_burst 0", r"store_tariff credits_burst")
    stdin(sx, "store_tariff credits_per_s 0", r"store_tariff credits_per_s")
    set_("paid", "1", 44)
    stdin(sx, "store_tariff credits_per_s 100", r"store_tariff credits_per_s")
    stdin(sx, "store_tariff credits_burst 1000", r"store_tariff credits_burst")
    time.sleep(1.2)
    set_("paid", "1", 0)
    set_("n", "nil", 0)                                   # удаление
    d = kv(sx, eid)
    rep["final"] = {k: d.get(k) for k in ("used", "quota", "keys", "kv")}
    if "n" in (d.get("kv") or {}):
        bad.append("delete failed")
    # A3 memory.* поверх хранилища: demo_memory_counter на своём бенче (код — протоколом, аккаунт без окна)
    if args.get("script_bench"):
        se = eid_of(sx, args, "script_bench")
        code = open(os.path.join(_packs_root(), "olife_world", "sandbox", "samples",
                                 "demo_memory_counter.lua"), encoding="utf-8").read()
        r = _w4a().st_bench_code(sx, {"bench": se, "code": code, "run": True, "token": args.get("token", "olife-carol"),
                                      "name": args.get("name", "carol")}, step)
        rep["script_code"] = r.get("result")
        got = wait_for(lambda: (lambda x: x if (x.get("kv") or {}).get("count", 0) >= 2 else None)(kv(sx, se)), 15, 0.5)
        rep["script_kv"] = (got or kv(sx, se)).get("kv")
        if not got:
            bad.append("memory.set of the script did not reach the store: %s" % rep["script_kv"])
        _m(sx)["script_kv_before"] = rep["script_kv"]
    st = stdin_line(sx, "store_status", "store(")
    rep["status"] = st[:400]
    _m(sx)["kv"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------------------------------------- canvas
def world_rgba(sx, sha):
    for _ in range(3):                    # a reply line may be missed by the stdin reader: ask again
        line = stdin_line(sx, "store_rgba asset:%s" % sha, "store_rgba sha=%s" % sha)
        if line:
            return P["_kv"](line)
        miss = stdin_line(sx, "store_rgba asset:%s" % sha, "store_rgba missing %s" % sha)
        if miss:
            return {"missing": True}
    return {}


def st_canvas(sx, args, step):
    roles = P["_roles"](sx)
    B = roles[args.get("viewer", "client2")]
    eid = eid_of(sx, args, default="carol")
    code = open(os.path.join(_packs_root(), "olife_world", "sandbox", "samples", "demo_paint.lua"),
                encoding="utf-8").read()
    rep, bad = {"eid": eid}, []
    r = _w4a().st_bench_code(sx, {"bench": eid, "code": code, "run": True, "token": args.get("token", "olife-carol"),
                                  "name": args.get("name", "carol")}, step)
    rep["code"] = r.get("result")
    if not r.get("ok"):
        return {"ok": False, "error": "bench code: %s" % r.get("error"), "result": rep}
    t0 = time.time()
    w = wait_for(lambda: (lambda x: x if x["assets"].get("tex:*") else None)(ent_assets(sx, eid)), 15, 0.3)
    if not w:
        return {"ok": False, "error": "no tex:* slot on the world: %s" % ent_assets(sx, eid), "result": rep}
    rep["world_first_s"] = round(time.time() - t0, 2)
    # B: файл скачан, применён на скелете
    seen_sha, frames, checks = set(), [], []
    end = time.time() + float(args.get("seconds", 6))
    while time.time() < end:
        st = assets(sx, B, eid=eid)
        en = st.get("entity") or {}
        sha = (en.get("slots") or {}).get("tex:*")
        f = (en.get("files") or {}).get(sha) if sha else None
        if sha and f and f.get("state") == "ready":
            if sha not in seen_sha:
                seen_sha.add(sha)
                frames.append({"sha": sha, "ms": f.get("ms"), "rgba_sha": f.get("rgba_sha"),
                               "engine_rgba_sha": f.get("engine_rgba_sha"), "skel0": (en.get("skeleton") or {}).get("$0"),
                               "w": f.get("w"), "h": f.get("h")})
        time.sleep(0.15)
    rep["b_distinct_frames"] = len(seen_sha)
    if len(seen_sha) < 3:
        bad.append("B saw %d distinct canvas frames (< 3)" % len(seen_sha))
    for fr in frames[:4]:
        wr = world_rgba(sx, fr["sha"])
        ok = wr.get("rgba_sha") == fr["rgba_sha"] == fr["engine_rgba_sha"]
        checks.append({"sha": fr["sha"][:16], "world_rgba": (wr.get("rgba_sha") or "")[:16],
                       "client_rgba": (fr["rgba_sha"] or "")[:16], "engine_rgba": (fr["engine_rgba_sha"] or "")[:16],
                       "size": "%sx%s" % (fr["w"], fr["h"]), "png_bytes": wr.get("png_bytes"), "download_ms": fr["ms"],
                       "equal": ok})
        if not ok:
            bad.append("frame %s: world/client/engine RGBA differ" % fr["sha"][:12])
    rep["frames"] = checks
    # на скелете B сейчас — текстура текущего кадра
    st = assets(sx, B, eid=eid)
    en = st.get("entity") or {}
    cur = (en.get("slots") or {}).get("tex:*")
    skel = en.get("skeleton") or {}
    rep["b_skeleton"] = skel
    want = "olife_assets/%s" % cur
    if not wait_for(lambda: all(((assets(sx, B, eid=eid).get("entity") or {}).get("skeleton") or {}).get("$%d" % i)
                                and (((assets(sx, B, eid=eid).get("entity") or {}).get("skeleton") or {}).get("$%d" % i)
                                     or "").startswith("olife_assets/") for i in range(6)), 3):
        bad.append("B skeleton textures not olife_assets/*: %s (want like %s)" % (skel, want))
    rep["b_stats"] = st.get("stats")
    try:                                  # look at the bench (dy: its box centre) for the evidence shot
        _w4a().ol(sx, B, "aim", eid=eid, dy=0.0)
        time.sleep(0.4)
    except Exception as exc:
        rep["aim_error"] = str(exc)
    rep["shot_b"] = _w4a().shot(sx, B, "a4_canvas_b")
    rep["shot_a"] = _w4a().shot(sx, roles["client1"], "a4_canvas_a")
    rep["world_status"] = stdin_line(sx, "store_status", "store(")[:600]
    m = re.search(r"puts=(\d+),dedup=(\d+)", rep["world_status"])
    if m:
        rep["puts"], rep["dedup"] = int(m.group(1)), int(m.group(2))
        if rep["dedup"] < 1:
            bad.append("no CAS dedup after a full 8-frame cycle (puts=%d)" % rep["puts"])
    gw = sx.lab.lease_info(roles["gateway"])
    rep["gateway_assets"] = ((sx.raw("metrics", {}, lease=roles["gateway"]) or {}).get("result") or {}).get("assets")
    _m(sx)["canvas"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------------------------------------- upload / share
def st_upload(sx, args, step):
    roles = P["_roles"](sx)
    A, B = roles["client1"], roles["client2"]
    eid = eid_of(sx, args, default="alice")
    other = eid_of(sx, args, "foreign", "carol")
    rep, bad = {"eid": eid}, []
    w, h = 16, 16
    px = bytearray()
    for y in range(h):
        for x in range(w):
            px += bytes([x * 16, y * 16, 128 if (x // 4 + y // 4) % 2 else 255, 255])
    png = png_rgba(w, h, bytes(px))
    sha = hashlib.sha256(png).hexdigest()
    rep["png"] = {"bytes": len(png), "sha": sha}

    def up(lease, data, kind=1, e=0, slot="", name="up", pace=True):
        if pace:
            time.sleep(0.55)              # store requests: 2/s per session (tariff upload_rate), burst 4
        r = assets(sx, lease, "upload", b64=base64.b64encode(data).decode(), kind=kind, eid=e, slot=slot, name=name)
        return reply_of(sx, lease, r["seq"]) or {"code": None}
    r1 = up(A, png, e=eid, slot="tex:*", name="checker")
    rep["upload"] = r1
    if r1.get("code") != 0 or r1.get("sha") != sha:
        bad.append("upload %s" % r1)
    # B видит текстуру на бенче alice
    got = wait_for(lambda: (lambda st: st if ((st.get("entity") or {}).get("files") or {}).get(sha, {}).get("state")
                            == "ready" else None)(assets(sx, B, eid=eid)), 10)
    rep["b_ready"] = bool(got)
    if not got:
        bad.append("B did not get the uploaded texture")
    else:
        f = got["entity"]["files"][sha]
        wr = world_rgba(sx, sha)
        rep["b_file"] = {k: f.get(k) for k in ("ms", "w", "h", "rgba_sha", "engine_rgba_sha")}
        rep["world_rgba"] = wr.get("rgba_sha")
        if not (wr.get("rgba_sha") == f.get("rgba_sha") == f.get("engine_rgba_sha")):
            bad.append("uploaded texture RGBA differs world/client/engine")
    # модель VCM на кость rody и звуки OGG/WAV: B скачивает и применяет без переоткрытия мира
    vcm = (b'@box from (-0.45,-0.5,-0.45) to (0.45,-0.1,0.45) texture "$0"\n'
           b'@box from (-0.2,-0.1,-0.2) to (0.2,0.5,0.2) texture "$1"\n')
    msha = hashlib.sha256(vcm).hexdigest()
    rm = up(A, vcm, kind=2, e=eid, slot="model:rody", name="tower")
    snd = {}
    for name, kind in (("ok.ogg", 3), ("fx_save.wav", 4)):
        with open(os.path.join(_packs_root(), "olife_client", "sounds", "olife", name), "rb") as f:
            data = f.read()
        r = up(A, data, kind=kind, e=eid, slot="sound:" + name.split(".")[0], name=name)
        snd[name] = {"code": r.get("code"), "sha": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    rep["model_upload"], rep["sounds_upload"] = rm.get("code"), snd

    def b_model():
        en = assets(sx, B, eid=eid).get("entity") or {}
        return en if (en.get("applied") or {}).get("model:rody") == msha and (en.get("files") or {}).get(msha, {}).get(
            "name") == "olife_assets:" + msha else None
    # 0.32 skeleton:get_model returns the bone's own model once an override is resolved (lib__skeleton.cpp), so the
    # proof is: the file is registered (assets.parse_model ok), applied on the bone, and the shot shows the new shape
    en = wait_for(b_model, 10)
    rep["b_model"] = {"applied": bool(en), "file": ((en or {}).get("files") or {}).get(msha)}
    if not en:
        bad.append("B: VCM model not applied: %s" % (assets(sx, B, eid=eid).get("entity") or {}).get("files", {}).get(msha))
    plays = {}
    for name, x in snd.items():
        ok = wait_for(lambda: ((assets(sx, B, eid=eid).get("entity") or {}).get("files") or {}).get(x["sha"], {})
                      .get("state") == "ready", 8)
        pr = assets(sx, B, "play", ref="asset:" + x["sha"], x=8.5, y=82, z=8.5)
        plays[name] = {"ready": bool(ok), "stream_id": pr.get("id")}
        if not ok or not pr.get("id"):
            bad.append("B: sound %s not playable (%s)" % (name, plays[name]))
    rep["b_sounds"] = plays
    # отказы
    neg = {}
    neg["foreign_bench_41"] = up(A, png, e=other, slot="tex:*").get("code")
    neg["not_png_46"] = up(A, b"not a png at all", kind=1).get("code")
    neg["bad_kind_46"] = up(A, png, kind=99).get("code")
    stdin(sx, "store_tariff owner_quota 100", r"store_tariff owner_quota")
    px2 = bytes((i * 7) % 256 for i in range(16 * 16 * 4))
    neg["quota_43"] = up(A, png_rgba(16, 16, px2)).get("code")
    stdin(sx, "store_tariff owner_quota 8388608", r"store_tariff owner_quota")
    neg["dedup_again_0"] = up(A, png).get("code")
    time.sleep(2.5)                       # bucket full again, then a burst of 6: the rate refuses some (48)
    b64 = base64.b64encode(png).decode()
    seqs = [assets(sx, A, "upload", b64=b64, kind=1, eid=0, slot="", name="burst")["seq"] for _ in range(6)]
    burst = [(reply_of(sx, A, q) or {}).get("code") for q in seqs]
    time.sleep(2.5)
    neg["rate_48"] = 48 if 48 in burst else burst
    rep["burst_codes"] = burst
    rep["negative"] = neg
    for k, v in neg.items():
        if v != int(k.rsplit("_", 1)[1]):
            bad.append("%s -> %s" % (k, v))
    # share alice -> bob; список bob
    r = assets(sx, A, "op", aop=3, sha=sha, account="bob")
    rs = reply_of(sx, A, r["seq"])
    rep["share"] = rs
    r = assets(sx, B, "op", aop=5)
    reply_of(sx, B, r["seq"])
    lst = wait_for(lambda: (assets(sx, B).get("list") or None), 5)
    rep["bob_list"] = lst
    blist = stdin_line(sx, "store_list bob", "store_list bob")
    if not rs or rs.get("code") != 0 or sha not in blist:
        bad.append("share to bob failed: %s / %s" % (rs, blist[:200]))
    q = stdin_line(sx, "store_quota alice", "store_quota alice")
    try:
        rep["alice_quota"] = json.JSONDecoder().raw_decode(q[len("store_quota alice "):])[0]
    except ValueError:
        rep["alice_quota"] = q[:200]
    try:
        _w4a().ol(sx, B, "aim", eid=eid, dy=0.0)
        time.sleep(0.4)
        rep["shot_b"] = _w4a().shot(sx, B, "a4_upload_b")
    except Exception as exc:
        rep["shot_error"] = str(exc)
    _m(sx)["upload"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------------------------------------- snapshot / restore
def _norm_snap(d):
    d = json.loads(json.dumps(d))
    for k in ("src_eid", "tick"):
        d.pop(k, None)
    (d.get("entity") or {}).pop("pos", None)
    (d.get("entity") or {}).pop("rot", None)
    return d


def st_snapshot(sx, args, step):
    eid = eid_of(sx, args, default="alice")
    wd = world_dir(sx)
    rep, bad = {"eid": eid}, []
    line = stdin_line(sx, "store_snapshot %d" % eid, "store_snapshot eid=%d" % eid)
    rep["snapshot"] = line[:300]
    path = os.path.join(wd, "export", "snap_%d.json" % eid)
    if not os.path.exists(path):
        return {"ok": False, "error": "no snapshot file: %s" % line, "result": rep}
    with open(path, encoding="utf-8") as f:
        snap = json.load(f)
    rep["bytes"] = os.path.getsize(path)
    rep["parts"] = {"code_len": len((snap.get("entity") or {}).get("code") or ""), "kv_keys": len(snap.get("kv") or {}),
                    "assets": list((snap.get("assets") or {}).keys()), "ext": list((snap.get("ext") or {}).keys())}
    r = stdin(sx, ("store_restore %d %s" % (eid, args.get("owner", ""))).strip(), r"restored eid=", wait=6)
    ls = [x for x in r.get("lines") or [] if "restored eid=" in x]
    m = re.search(r"restored eid=(\d+) code=(\d+)", ls[-1]) if ls else None
    if not m or m.group(2) != "0":
        return {"ok": False, "error": "restore: %s" % (ls[-1:] or r.get("lines", [])[-3:]), "result": rep}
    new = int(m.group(1))
    rep["restored_eid"] = new
    time.sleep(0.3)
    stdin_line(sx, "store_snapshot %d" % new, "store_snapshot eid=%d" % new)
    with open(os.path.join(wd, "export", "snap_%d.json" % new), encoding="utf-8") as f:
        snap2 = json.load(f)
    a, b = _norm_snap(snap), _norm_snap(snap2)
    rep["equal"] = a == b
    if a != b:
        diff = [k for k in set(a) | set(b) if a.get(k) != b.get(k)]
        ediff = [k for k in set(a.get("entity") or {}) | set(b.get("entity") or {})
                 if (a.get("entity") or {}).get(k) != (b.get("entity") or {}).get(k)]
        rep["diff"] = {"top": diff, "entity": ediff}
        bad.append("snapshot of the copy differs: %s" % rep["diff"])
    k1, k2 = kv(sx, eid), kv(sx, new)
    rep["kv_equal"] = k1.get("kv") == k2.get("kv")
    e1, e2 = ent_assets(sx, eid), ent_assets(sx, new)
    rep["assets_equal"] = e1["assets"] == e2["assets"]
    if not (rep["kv_equal"] and rep["assets_equal"]):
        bad.append("kv/assets of the copy differ")
    # copy-on-fork (A1 EntityFork -> store.fork): A forks its own bench; the fork has the same KV and asset slots
    A = P["_roles"](sx)["client1"]
    _w4a().ol(sx, A, "send", name="EntityFork", msg={"eid": eid, "name": "a4_fork"})

    def fork_eid():
        line = stdin_line(sx, "benches", "benches n=")
        m2 = re.search(r"(\d+):a4_fork:", line)
        return int(m2.group(1)) if m2 else None
    fe = wait_for(fork_eid, 6, 0.3)
    rep["fork_eid"] = fe
    if not fe:
        bad.append("fork did not appear")
    else:
        time.sleep(0.3)
        kf, ef = kv(sx, fe), ent_assets(sx, fe)
        rep["fork_kv_equal"] = kf.get("kv") == k1.get("kv")
        rep["fork_assets_equal"] = ef["assets"] == e1["assets"]
        if not (rep["fork_kv_equal"] and rep["fork_assets_equal"]):
            bad.append("fork kv/assets differ: %s / %s" % (kf.get("kv"), ef["assets"]))
    info = _w4a().bench_info(sx, new)
    rep["restored_bench"] = {k: info.get(k) for k in ("status", "owner", "code_fnv", "model", "texture")}
    _w4a()._w(sx)["benches"]["restored"] = [new]
    _m(sx)["snapshot"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------------------------------------- restart
def st_restart(sx, args, step):
    roles = P["_roles"](sx)
    lease = roles["world"]
    ids = [eid_of(sx, args, k, k) for k in (args.get("benches") or ["alice"])]
    before = {e: {"kv": kv(sx, e).get("kv"), "assets": ent_assets(sx, e)["assets"]} for e in ids}
    lib = stdin_line(sx, "store_list alice", "store_list alice")
    se = eid_of(sx, args, "script_bench") if args.get("script_bench") else None
    sk0 = kv(sx, se).get("kv") if se else None
    stdin(sx, "save", r"save requested")
    stdin(sx, "store_flush", r"store_flush ok")
    time.sleep(1.5)
    t0 = time.time()
    sx.lab.stop(lease, owner=sx.owner)
    sx.lab.start(lease, owner=sx.owner)
    rep, bad = {"restart_s": round(time.time() - t0, 2)}, []
    time.sleep(1.0)
    after = {e: {"kv": kv(sx, e).get("kv"), "assets": ent_assets(sx, e)["assets"]} for e in ids}
    rep["before"], rep["after"] = before, after
    anim = {eid_of(sx, args, k, k) for k in (args.get("animated") or [])}
    for e in ids:
        if e in anim:       # a running canvas keeps committing frames: same KV, same slot names, files in the CAS
            if before[e]["kv"] != after[e]["kv"] or set(before[e]["assets"]) != set(after[e]["assets"]):
                bad.append("animated eid %d: kv/slots changed across the restart" % e)
        elif before[e] != after[e]:
            bad.append("eid %d changed across the restart" % e)
    cas = os.path.join(world_dir(sx), "worlds", "olife", "olife_store", "cas")
    missing = [s for e in ids for s in after[e]["assets"].values() if not os.path.exists(os.path.join(cas, s[:2], s))]
    rep["cas_missing"] = missing
    if missing:
        bad.append("CAS files missing: %s" % missing)
    lib2 = stdin_line(sx, "store_list alice", "store_list alice")
    rep["library_same"] = json_tail(lib, "alice") == json_tail(lib2, "alice")
    if not rep["library_same"]:
        bad.append("alice library changed")
    if se:
        # the sandbox keeps the VM across a world restart (LoadKeep): the script does not run its top level again
        # (runs stays), the counter goes on from its value; with a fresh VM it would read count back from the store
        got = wait_for(lambda: (lambda x: x if (x.get("kv") or {}).get("runs", 0) >= (sk0 or {}).get("runs", 0) and
                                (x.get("kv") or {}).get("count", 0) > (sk0 or {}).get("count", 0) else None)(kv(sx, se)),
                       20, 0.5)
        rep["script_kv"] = {"before": sk0, "after": (got or kv(sx, se)).get("kv")}
        if not got:
            bad.append("memory counter did not continue after the restart: %s" % rep["script_kv"])
    rep["status"] = stdin_line(sx, "store_status", "store(")[:400]
    _m(sx)["restart"] = rep
    return {"ok": not bad, "result": rep, "error": "; ".join(bad) or None}


# ---------------------------------------------------------------------------------------------- supervisor
_PUSHED = {}


def poll_store(hooks, sup, g, wsvc, wl, st, add, tariffs):
    """опрос группы supervisor: sup_state.store мира -> счётчики БД по аккаунтам (storage — занято байт, store_assets,
    дельты store_writes / store_bytes / store_credits — кредиты по тарифу credits.per_store_credit); тарифы `store.<k>`
    из БД -> миру `store_tariff <k> <v>` при изменении (без рестарта)"""
    lab, db = sup.lab, sup.db
    store = (st or {}).get("store") or {}
    out = {}
    for acct, o in (store.get("owners") or {}).items():
        db.set_counters(acct, {"storage": o.get("bytes", 0), "store_assets": o.get("assets", 0)})
        dd = hooks._delta(("store", wsvc.lease, wl.starts, acct), {"store_writes": o.get("writes"),
                                                                   "store_bytes": o.get("written"),
                                                                   "store_credits": o.get("credits")})
        add(acct, **dd)
        out[acct] = {"bytes": o.get("bytes"), "assets": o.get("assets")}
    want = {k[len("store."):]: v for k, v in (tariffs or {}).items() if k.startswith("store.")}
    key = (wsvc.lease, wl.starts)
    sent = _PUSHED.setdefault(key, {})
    for k, v in sorted(want.items()):
        if sent.get(k) != v:
            r = lab.stdin(wsvc.lease, "store_tariff %s %s" % (k, v), owner=g.owner, wait=1.0,
                          pattern=r"store_tariff %s" % re.escape(k), journal=False)
            if r.get("matched"):
                sent[k] = v
    return {"owners": out, "files": store.get("files"), "cas_bytes": store.get("cas_bytes"),
            "tariffs_pushed": dict(sent)} if (out or sent) else None
