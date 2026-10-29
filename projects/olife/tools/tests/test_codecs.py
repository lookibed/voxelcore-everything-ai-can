"""Python codec tests (no engine): vectors round trip, strict decoding, framing errors, fuzz.
  python3 -m pytest -q tools/olife/tests/test_codecs.py      (or: python3 tools/olife/tests/test_codecs.py)"""
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from olife_proto import client, internal, sandbox, wire  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402

CODECS = {"client": client, "internal": internal, "sandbox": sandbox}
VEC = os.path.join(os.path.dirname(HERE), "protocol", "vectors")


def from_json(v):
    if isinstance(v, dict):
        if set(v) == {"$bytes"}:
            return bytes.fromhex(v["$bytes"])
        return {k: from_json(x) for k, x in v.items()}
    if isinstance(v, list):
        return [from_json(x) for x in v]
    return v


def norm(v):
    """decoded -> comparable: absent optional keys of dicts equal None"""
    if isinstance(v, dict):
        return {k: norm(x) for k, x in v.items() if x is not None}
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v


def load(c):
    with open(os.path.join(VEC, c + ".json"), encoding="utf-8") as f:
        return json.load(f)["vectors"]


def test_vectors_roundtrip():
    n = 0
    for c, mod in CODECS.items():
        for v in load(c):
            fr = bytes.fromhex(v["frame"])
            val = from_json(v["value"])
            assert mod.frame(v["name"], val) == fr, (c, v["name"])
            f = mod.framer()
            f.feed(fr)
            mid, body = f.next()
            assert mid == v["id"]
            dec = mod.decode_body(mid, body)
            assert norm(dec) == norm(val), (c, v["name"], dec, val)
            assert mod.frame(mid, dec) == fr
            n += 1
    assert n >= 100


def test_every_message_has_vectors():
    for c, mod in CODECS.items():
        names = {v["name"] for v in load(c)}
        assert names == set(mod.IDS), c


def expect_err(fn, needle):
    try:
        fn()
    except ProtoError as e:
        assert needle in str(e), (needle, str(e))
        return
    raise AssertionError("no ProtoError (%s)" % needle)


def test_encode_checks():
    ok = {"proto": 1, "name": "a", "token": "t", "engine": "0.32"}
    client.frame("Hello", ok)
    expect_err(lambda: client.frame("Hello", dict(ok, proto=70000)), "Hello.proto")
    expect_err(lambda: client.frame("Hello", dict(ok, proto=1.5)), "Hello.proto")
    expect_err(lambda: client.frame("Hello", dict(ok, proto=None)), "Hello.proto")
    expect_err(lambda: client.frame("Hello", dict(ok, name="x" * 33)), "string too long")
    expect_err(lambda: client.frame("Hello", dict(ok, name=5)), "expected str")
    pin = {"seq": 1, "pos": {"x": 0, "y": 0, "z": 0}, "rot": {"x": 0, "y": 0, "z": 0}}
    client.frame("PlayerInput", pin)
    expect_err(lambda: client.frame("PlayerInput", dict(pin, pos={"x": math.nan, "y": 0, "z": 0})), "Vec3f.x")
    expect_err(lambda: client.frame("PlayerInput", dict(pin, pos={"x": 1e39, "y": 0, "z": 0})), "Vec3f.x")
    expect_err(lambda: client.frame("PlayerInput", dict(pin, pos=[1, 2, 3])), "expected dict")
    expect_err(lambda: client.frame("Nope", {}), "unknown message")
    expect_err(lambda: sandbox.frame("TickResult", {"tick": 1, "wall_us": 0, "entities": [
        {"eid": 1, "owner": 1, "status": "ok", "error": None, "queries_json": [],
         "meter": {"fuel": 0, "api_calls": 0, "api_credits": 0, "credits": 0, "alloc_bytes": 0, "actions_dropped": 0},
         "actions": [{"kind": "Teleport"}]}]}), "unknown variant")


def body_of(mod, name, val):
    return mod.body(name, val)


def test_decode_strict():
    b = client.body("ChatSend", {"text": "hi"})
    assert client.decode_body(5, b) == {"text": "hi"}
    expect_err(lambda: client.decode_body(5, b[:-1]), "truncated")
    expect_err(lambda: client.decode_body(5, b + b"\x00"), "trailing bytes")
    expect_err(lambda: client.decode_body(5, b"\x00\x02\xff\xfe"), "invalid utf-8")
    expect_err(lambda: client.decode_body(5, b"\x01\x01" + b"x" * 257), "string too long")
    expect_err(lambda: client.decode_body(99, b), "unknown type")
    # bad bool / opt flag / union tag
    lr = sandbox.body("LoadResult", {"owner": 1, "eid": 2, "ok": True, "error": None})
    bad = bytearray(lr); bad[8] = 2
    expect_err(lambda: sandbox.decode_body(3, bytes(bad)), "bad bool")
    bad = bytearray(lr); bad[9] = 7
    expect_err(lambda: sandbox.decode_body(3, bytes(bad)), "bad opt flag")
    # f32 NaN on the wire
    pin = client.body("PlayerInput", {"seq": 1, "pos": {"x": 0, "y": 0, "z": 0}, "rot": {"x": 0, "y": 0, "z": 0}})
    bad = bytearray(pin); bad[4:8] = b"\x7f\xc0\x00\x00"
    expect_err(lambda: client.decode_body(3, bytes(bad)), "non-finite")
    # array count over max
    bu = bytearray(client.body("BlockUpdate", {"tick": 1, "changes": []}))
    bu[4:6] = (9000).to_bytes(2, "big")
    expect_err(lambda: client.decode_body(69, bytes(bu)), "too many elements")


def test_framer_errors():
    good = client.frame("ChatSend", {"text": "x"})
    for mutate, needle in [
        (lambda f: b"XX" + f[2:], "bad magic"),
        (lambda f: f[:2] + b"\x09" + f[3:], "wrong version"),
        (lambda f: f[:3] + b"\x01\x00" + f[5:], "unknown type"),
        (lambda f: f[:5] + (2 ** 20 + 1).to_bytes(4, "big") + f[9:], "frame too large"),
    ]:
        fr = client.framer()
        fr.feed(mutate(good))
        expect_err(fr.next, needle)
    # partial delivery byte by byte
    fr = client.framer()
    stream = good * 3
    got = []
    for i in range(len(stream)):
        fr.feed(stream[i:i + 1])
        while True:
            x = fr.next()
            if x is None:
                break
            got.append(x)
    assert len(got) == 3 and all(client.decode_body(m, b) == {"text": "x"} for m, b in got)


def test_fuzz_never_crashes():
    rng = random.Random(7)
    vecs = [(c, v) for c in CODECS for v in load(c)]
    errors = 0
    for _ in range(3000):
        c, v = rng.choice(vecs)
        mod = CODECS[c]
        b = bytearray(bytes.fromhex(v["frame"])[9:])
        for _ in range(rng.randint(1, 4)):
            op = rng.random()
            if op < 0.5 and b:
                b[rng.randrange(len(b))] = rng.randrange(256)
            elif op < 0.75 and b:
                del b[rng.randrange(len(b)):]
            else:
                b += bytes(rng.randrange(256) for _ in range(rng.randint(1, 8)))
        try:
            mod.decode_body(v["id"], bytes(b))
        except ProtoError:
            errors += 1
    assert errors > 1000


def test_fround_fnv():
    assert wire.fround(0.1) != 0.1 and abs(wire.fround(0.1) - 0.1) < 1e-8
    assert wire.fnv1a(b"") == 2166136261 and wire.fnv1a(b"a") == 0xE40C292C


if __name__ == "__main__":
    for k, f in list(globals().items()):
        if k.startswith("test_"):
            f()
            print("ok", k)
