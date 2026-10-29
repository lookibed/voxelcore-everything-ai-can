//! Codec tests (port of tools/olife/tests/test_codecs.py): generated vectors byte-for-byte, strict decoding,
//! framing errors, byte-by-byte feeding, mutation fuzz (never panics; anything accepted re-encodes to the same bytes).
use olife_gateway::proto::{client, internal, sandbox, wire};
use serde_json::Value;
use wire::{header, ProtoError};

type FromJson = fn(&str, &Value) -> Result<Box<dyn Codec>, ProtoError>;

trait Codec {
    fn id(&self) -> u16;
    fn frame(&self) -> Result<Vec<u8>, ProtoError>;
    fn eq_dyn(&self, other: &dyn Codec) -> bool;
    fn dbg(&self) -> String;
    fn as_any(&self) -> &dyn std::any::Any;
}

macro_rules! codec {
    ($m:ident) => {
        impl Codec for $m::Msg {
            fn id(&self) -> u16 {
                $m::Msg::id(self)
            }
            fn frame(&self) -> Result<Vec<u8>, ProtoError> {
                $m::Msg::frame(self)
            }
            fn eq_dyn(&self, o: &dyn Codec) -> bool {
                o.as_any().downcast_ref::<$m::Msg>().map_or(false, |x| x == self)
            }
            fn dbg(&self) -> String {
                format!("{:?}", self)
            }
            fn as_any(&self) -> &dyn std::any::Any {
                self
            }
        }
    };
}
codec!(client);
codec!(internal);
codec!(sandbox);

struct C {
    name: &'static str,
    from_json: FromJson,
    decode: fn(u16, &[u8]) -> Result<Box<dyn Codec>, ProtoError>,
    framer: fn() -> wire::Framer,
    names: fn(u16) -> Option<&'static str>,
    count: usize,
}

fn contracts() -> Vec<C> {
    vec![
        C {
            name: "client",
            from_json: |n, v| Ok(Box::new(client::Msg::from_json(n, v)?)),
            decode: |i, b| Ok(Box::new(client::Msg::decode_body(i, b)?)),
            framer: || client::framer(None),
            names: client::name_of,
            count: 78, // 16.10 olife_friends: + InfoRequest 7 / ServerInfo 76 (76 on 03.10: UX A1..A4 + B1 + B2); recount on every schema change
        },
        C {
            name: "internal",
            from_json: |n, v| Ok(Box::new(internal::Msg::from_json(n, v)?)),
            decode: |i, b| Ok(Box::new(internal::Msg::decode_body(i, b)?)),
            framer: || internal::framer(None),
            names: internal::name_of,
            count: 8,
        },
        C {
            name: "sandbox",
            from_json: |n, v| Ok(Box::new(sandbox::Msg::from_json(n, v)?)),
            decode: |i, b| Ok(Box::new(sandbox::Msg::decode_body(i, b)?)),
            framer: || sandbox::framer(None),
            names: sandbox::name_of,
            count: 10, // 03.10 UX A3: + Answer path messages
        },
    ]
}

fn load(c: &str) -> Vec<Value> {
    let dir = std::env::var("OLIFE_VECTORS")
        .unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/src/proto/vectors").to_string());
    let s = std::fs::read_to_string(format!("{}/{}.json", dir, c)).expect("vectors file");
    let v: Value = serde_json::from_str(&s).unwrap();
    v["vectors"].as_array().unwrap().clone()
}

fn unhex(s: &str) -> Vec<u8> {
    wire::unhex(s).unwrap()
}

#[test]
fn vectors_byte_for_byte() {
    let mut n = 0;
    for c in contracts() {
        for v in load(c.name) {
            let name = v["name"].as_str().unwrap();
            let fr = unhex(v["frame"].as_str().unwrap());
            // JSON value -> encode == Python frame
            let m = (c.from_json)(name, &v["value"]).unwrap_or_else(|e| panic!("{} {}: {}", c.name, name, e));
            assert_eq!(m.frame().unwrap(), fr, "{} {} encode", c.name, name);
            assert_eq!(m.id() as u64, v["id"].as_u64().unwrap());
            // framer + decode == value; re-encode == frame
            let mut f = (c.framer)();
            f.feed(&fr);
            let (id, body) = f.next().unwrap().unwrap();
            assert!(f.next().unwrap().is_none());
            let d = (c.decode)(id, &body).unwrap();
            assert!(d.eq_dyn(m.as_ref()), "{} {}: {} != {}", c.name, name, d.dbg(), m.dbg());
            assert_eq!(d.frame().unwrap(), fr);
            n += 1;
        }
    }
    assert_eq!(n, 384, "vector count changed: regenerate and update"); // 16.10 olife_friends: + InfoRequest/ServerInfo (was 376; 304 before A1..B2)
}

#[test]
fn every_message_has_vectors() {
    for c in contracts() {
        let mut names: Vec<String> = load(c.name).iter().map(|v| v["name"].as_str().unwrap().to_string()).collect();
        names.sort();
        names.dedup();
        let mut want: Vec<String> = (0..=65535u32).filter_map(|i| (c.names)(i as u16)).map(String::from).collect();
        want.sort();
        assert_eq!(names, want, "{}", c.name);
        assert_eq!(want.len(), c.count);
    }
}

fn expect_err<T: std::fmt::Debug>(r: Result<T, ProtoError>, needle: &str) {
    match r {
        Ok(v) => panic!("no ProtoError ({}): {:?}", needle, v),
        Err(e) => assert!(e.0.contains(needle), "{:?} does not contain {:?}", e.0, needle),
    }
}

fn hello(name: &str) -> client::Msg {
    client::Msg::Hello(client::Hello { proto: 1, name: name.into(), token: "t".into(), engine: "0.32".into() })
}

fn v3(x: f32) -> client::Vec3f {
    client::Vec3f { x, y: 0.0, z: 0.0 }
}

#[test]
fn encode_checks() {
    hello("a").frame().unwrap();
    expect_err(hello(&"x".repeat(33)).frame(), "string too long");
    expect_err(hello(&"x".repeat(33)).frame(), "Hello.name");
    let pin = |x: f32| client::Msg::PlayerInput(client::PlayerInput { seq: 1, pos: v3(x), rot: v3(0.0) });
    pin(0.0).frame().unwrap();
    expect_err(pin(f32::NAN).frame(), "Vec3f.x");
    expect_err(pin(f32::INFINITY).frame(), "expected finite f32");
    // JSON forms with the Python failure cases
    let ok = serde_json::json!({"proto": 1, "name": "a", "token": "t", "engine": "0.32"});
    client::Msg::from_json("Hello", &ok).unwrap();
    expect_err(client::Msg::from_json("Hello", &serde_json::json!({"proto": 70000, "name": "a", "token": "t", "engine": "e"})), "Hello");
    expect_err(client::Msg::from_json("Hello", &serde_json::json!({"proto": 1.5, "name": "a", "token": "t", "engine": "e"})), "Hello");
    expect_err(client::Msg::from_json("Hello", &serde_json::json!({"proto": null, "name": "a", "token": "t", "engine": "e"})), "Hello");
    expect_err(client::Msg::from_json("Hello", &serde_json::json!({"proto": 1, "name": 5, "token": "t", "engine": "e"})), "Hello");
    expect_err(client::Msg::from_json("Nope", &ok), "unknown message");
    expect_err(
        sandbox::Msg::from_json(
            "TickResult",
            &serde_json::json!({"tick": 1, "wall_us": 0, "entities": [{"eid": 1, "owner": 1, "status": "ok",
            "error": null, "queries_json": [], "meter": {"fuel": 0, "api_calls": 0, "api_credits": 0, "credits": 0,
            "alloc_bytes": 0, "actions_dropped": 0}, "actions": [{"kind": "Teleport"}]}]}),
        ),
        "unknown variant",
    );
    // array over its max, bytes over max
    let bu = client::Msg::BlockUpdate(client::BlockUpdate {
        tick: 1,
        changes: vec![client::BlockChange { pos: client::BlockPos { x: 0, y: 0, z: 0 }, id: 1, states: 0 }; 8193],
    });
    expect_err(bu.frame(), "too many elements");
    let cd = client::Msg::ChunkData(client::ChunkData { cx: 0, cz: 0, data: vec![0u8; 1_000_001].into(), hash: 0 });
    expect_err(cd.frame(), "bytes too long");
}

#[test]
fn decode_strict() {
    let b = client::Msg::ChatSend(client::ChatSend { text: "hi".into() }).body().unwrap();
    assert_eq!(client::Msg::decode_body(5, &b).unwrap(), client::Msg::ChatSend(client::ChatSend { text: "hi".into() }));
    expect_err(client::Msg::decode_body(5, &b[..b.len() - 1]), "truncated");
    let mut t = b.clone();
    t.push(0);
    expect_err(client::Msg::decode_body(5, &t), "trailing bytes");
    expect_err(client::Msg::decode_body(5, b"\x00\x02\xff\xfe"), "invalid utf-8");
    let mut long = vec![1u8, 1];
    long.extend(std::iter::repeat(b'x').take(257));
    expect_err(client::Msg::decode_body(5, &long), "string too long");
    expect_err(client::Msg::decode_body(99, &b), "unknown type");
    // bad bool / opt flag (LoadResult: owner u32, eid u32, ok bool, error opt<str>)
    let lr = sandbox::Msg::LoadResult(sandbox::LoadResult { owner: 1, eid: 2, ok: true, error: None }).body().unwrap();
    let mut bad = lr.clone();
    bad[8] = 2;
    expect_err(sandbox::Msg::decode_body(3, &bad), "bad bool");
    let mut bad = lr.clone();
    bad[9] = 7;
    expect_err(sandbox::Msg::decode_body(3, &bad), "bad opt flag");
    // NaN f32 on the wire
    let pin = client::Msg::PlayerInput(client::PlayerInput { seq: 1, pos: v3(0.0), rot: v3(0.0) }).body().unwrap();
    let mut bad = pin.clone();
    bad[4..8].copy_from_slice(b"\x7f\xc0\x00\x00");
    expect_err(client::Msg::decode_body(3, &bad), "non-finite");
    // array count over max
    let mut bu = client::Msg::BlockUpdate(client::BlockUpdate { tick: 1, changes: vec![] }).body().unwrap();
    bu[4..6].copy_from_slice(&9000u16.to_be_bytes());
    expect_err(client::Msg::decode_body(69, &bu), "too many elements");
    // union tag
    let ac = sandbox::Msg::TickResult(sandbox::TickResult { tick: 1, entities: vec![], wall_us: 0.0 }).body().unwrap();
    assert!(sandbox::Msg::decode_body(6, &ac).is_ok());
}

#[test]
fn framer_errors() {
    let good = client::Msg::ChatSend(client::ChatSend { text: "x".into() }).frame().unwrap();
    let muts: Vec<(Vec<u8>, &str)> = vec![
        ([b"XX".as_slice(), &good[2..]].concat(), "bad magic"),
        ([&good[..2], b"\x09".as_slice(), &good[3..]].concat(), "wrong version"),
        ([&good[..3], b"\x01\x00".as_slice(), &good[5..]].concat(), "unknown type"),
        ([&good[..5], &((1u32 << 20) + 1).to_be_bytes()[..], &good[9..]].concat(), "frame too large"),
    ];
    for (m, needle) in muts {
        let mut f = client::framer(None);
        f.feed(&m);
        expect_err(f.next(), needle);
    }
    // header-only checks fire before the body arrives (oversized frame never buffered)
    let mut f = client::framer(Some(65536));
    f.feed(&header(client::MAGIC, client::VERSION, 5, 1 << 20));
    expect_err(f.next(), "frame too large");
    // byte by byte
    let mut f = client::framer(None);
    let stream = [good.clone(), good.clone(), good.clone()].concat();
    let mut got = vec![];
    for i in 0..stream.len() {
        f.feed(&stream[i..i + 1]);
        while let Some((id, body)) = f.next().unwrap() {
            got.push(client::Msg::decode_body(id, &body).unwrap());
        }
    }
    assert_eq!(got.len(), 3);
    assert!(got.iter().all(|m| *m == client::Msg::ChatSend(client::ChatSend { text: "x".into() })));
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

#[test]
fn fuzz_never_panics_and_accepted_reencodes() {
    let mut rng = Rng(0x9E3779B97F4A7C15);
    let cs = contracts();
    let vecs: Vec<(usize, Value)> =
        cs.iter().enumerate().flat_map(|(i, c)| load(c.name).into_iter().map(move |v| (i, v))).collect();
    let (mut errors, mut accepted) = (0, 0);
    for _ in 0..30000 {
        let (ci, v) = &vecs[rng.below(vecs.len())];
        let c = &cs[*ci];
        let fr = unhex(v["frame"].as_str().unwrap());
        let mut b = fr[9..].to_vec();
        for _ in 0..1 + rng.below(4) {
            let op = rng.below(100);
            if op < 50 && !b.is_empty() {
                let i = rng.below(b.len());
                b[i] = rng.below(256) as u8;
            } else if op < 75 && !b.is_empty() {
                let i = rng.below(b.len());
                b.truncate(i);
            } else {
                for _ in 0..1 + rng.below(8) {
                    b.push(rng.below(256) as u8);
                }
            }
        }
        let id = v["id"].as_u64().unwrap() as u16;
        match (c.decode)(id, &b) {
            Err(_) => errors += 1,
            Ok(m) => {
                accepted += 1;
                assert_eq!(m.frame().unwrap()[9..], b[..], "accepted body must re-encode identically");
            }
        }
    }
    assert!(errors > 10000, "errors {}", errors);
    assert!(accepted > 1000, "accepted {}", accepted);
}

#[test]
fn fnv() {
    assert_eq!(wire::fnv1a(b""), 2166136261);
    assert_eq!(wire::fnv1a(b"a"), 0xE40C292C);
}
