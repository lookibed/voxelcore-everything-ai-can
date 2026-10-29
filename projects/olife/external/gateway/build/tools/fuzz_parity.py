#!/usr/bin/env python3
"""Fuzz parity Python <-> Rust codecs: the same mutated bodies must be accepted/rejected identically, and accepted
bodies must re-encode to the same bytes in both. Needs the VC_ROOT Python codecs (tools/olife/olife_proto).
  python3 tools/fuzz_parity.py [N]      (builds/runs `cargo run --release --example decode_corpus`)"""
import json, os, random, subprocess, sys
VC = os.environ.get("VC_ROOT", os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "..")))  # корень репозитория
sys.path.insert(0, os.path.join(VC, "tools", "olife"))
from olife_proto import client, internal, sandbox  # noqa: E402
from olife_proto.wire import ProtoError  # noqa: E402
CODECS = {"client": client, "internal": internal, "sandbox": sandbox}
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
rng = random.Random(11)
vecs = []
for c in CODECS:
    with open(os.path.join(VC, "tools", "olife", "protocol", "vectors", c + ".json"), encoding="utf-8") as f:
        vecs += [(c, v) for v in json.load(f)["vectors"]]
cases = []
for _ in range(N):
    c, v = rng.choice(vecs)
    b = bytearray(bytes.fromhex(v["frame"])[9:])
    for _ in range(rng.randint(1, 4)):
        op = rng.random()
        if op < 0.5 and b:
            b[rng.randrange(len(b))] = rng.randrange(256)
        elif op < 0.75 and b:
            del b[rng.randrange(len(b)):]
        else:
            b += bytes(rng.randrange(256) for _ in range(rng.randint(1, 8)))
    mid = v["id"] if rng.random() > 0.02 else rng.randrange(300)
    cases.append((c, mid, bytes(b)))
py = []
for c, mid, b in cases:
    try:
        m = CODECS[c].decode_body(mid, b)
        py.append(("ok", CODECS[c].body(mid, m).hex()))
    except ProtoError as e:
        py.append(("err", str(e)))
inp = "".join("%s %d %s\n" % (c, mid, b.hex()) for c, mid, b in cases)
r = subprocess.run(["cargo", "run", "-q", "--release", "--example", "decode_corpus"], input=inp, capture_output=True,
                   text=True, cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
rs = [ln.split(" ", 1) for ln in r.stdout.splitlines()]
assert len(rs) == len(cases), (len(rs), r.stderr[-2000:])
bad = 0
acc = 0
for i, ((pk, pv), (rk, rv)) in enumerate(zip(py, rs)):
    if pk != rk or (pk == "ok" and pv != rv):
        bad += 1
        if bad <= 10:
            print("MISMATCH", cases[i][0], cases[i][1], cases[i][2].hex()[:80], "py:", pk, pv[:80], "rs:", rk, rv[:80])
    acc += pk == "ok"
print("cases %d, accepted %d, rejected %d, mismatches %d" % (len(cases), acc, len(cases) - acc, bad))
sys.exit(1 if bad else 0)
