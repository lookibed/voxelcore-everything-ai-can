//! Ticket tests (wave 4b): tools/olife/protocol/vectors/tickets.json with ONE verifier in order (replayed follows good),
//! key derivation, mint/parse round trip, nonce cache pruning and cap, constant-time compare, Python-compatible base64.
//! Vectors: $OLIFE_TICKET_VECTORS, else VC_ROOT's file (if this machine has it), else the copy tests/vectors/tickets.json.
use olife_gateway::ticket::{self, NonceCache, Verdict, Verifier};
use serde_json::Value;

fn vectors() -> Value {
    let vc = "/mnt/d/Prog/VoxelCore/voxelcore-0.31.0_pre_gemini/tools/olife/protocol/vectors/tickets.json";
    let p = std::env::var("OLIFE_TICKET_VECTORS").ok()
        .or_else(|| std::path::Path::new(vc).exists().then(|| vc.to_string()))
        .unwrap_or_else(|| concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors/tickets.json").to_string());
    serde_json::from_str(&std::fs::read_to_string(&p).expect("tickets.json")).unwrap()
}

fn unhex(s: &str) -> Vec<u8> {
    olife_gateway::proto::wire::unhex(s).unwrap()
}

#[test]
fn vectors_in_order_one_verifier() {
    let v = vectors();
    let master = unhex(v["master_hex"].as_str().unwrap());
    let gid = v["gateway"].as_str().unwrap();
    let k = ticket::gateway_key(&master, gid);
    assert_eq!(k.to_vec(), unhex(v["gateway_key_hex"].as_str().unwrap()), "K_gw derivation");
    assert_eq!(ticket::gw_hash(gid) as u64, v["gw_hash"].as_u64().unwrap());
    assert_eq!(v["ttl_max"].as_f64().unwrap(), ticket::TTL_MAX);
    assert_eq!(v["skew"].as_f64().unwrap(), ticket::SKEW);
    let mut ver = Verifier::new(k, gid, 1_000_000);
    let cases = v["cases"].as_array().unwrap();
    assert!(cases.len() >= 9);
    for c in cases {
        let (r, acct) = ver.verify(c["ticket"].as_str().unwrap(), c["now"].as_f64().unwrap());
        assert_eq!(r.name(), c["want"].as_str().unwrap(), "case {}", c["name"]);
        assert_eq!(acct.as_deref(), c.get("account").and_then(|a| a.as_str()), "case {}", c["name"]);
    }
    let n = |s: &str| cases.iter().filter(|c| c["want"] == s).count() as u64;
    assert_eq!((ver.counts.ok, ver.counts.replayed, ver.counts.expired, ver.counts.malformed),
               (n("ok"), n("replayed"), n("expired"), n("malformed")));
    assert_eq!(ver.cache.len(), 1); // "good" (exp now+30) pruned by the last ok case at now+59, as in Python
}

#[test]
fn reasons_and_codes_equal_olife_ticket() {
    // olife_ticket.CODES / REASONS
    for (v, code, reason) in [(Verdict::Malformed, 4, "bad ticket"), (Verdict::Expired, 14, "ticket expired"),
                              (Verdict::Replayed, 15, "ticket replayed"), (Verdict::BadSignature, 16, "bad ticket signature"),
                              (Verdict::WrongGateway, 17, "ticket for another gateway"), (Verdict::Busy, 13, "ticket cache full")] {
        assert_eq!((v.code(), v.reason()), (code, reason), "{:?}", v);
    }
}

#[test]
fn mint_matches_vector_and_round_trips() {
    let v = vectors();
    let master = unhex(v["master_hex"].as_str().unwrap());
    let gid = v["gateway"].as_str().unwrap();
    let k = ticket::gateway_key(&master, gid);
    let mut nonce = [0u8; 12];
    for (i, b) in nonce.iter_mut().enumerate() {
        *b = 100 + i as u8;
    }
    let (t, exp) = ticket::mint(&k, gid, "bot1", 30, 1_790_000_000, nonce);
    assert_eq!(t, v["cases"][0]["ticket"].as_str().unwrap(), "mint = olife_ticket.mint byte for byte");
    let p = ticket::parse(&t).unwrap();
    assert_eq!((p.exp, p.account.as_str(), p.nonce), (exp, "bot1", nonce));
    let (long, _) = ticket::mint(&k, gid, &"x".repeat(55), 60, 1_790_000_000, [1; 12]);
    assert!(long.len() <= 127, "{}", long.len());
}

#[test]
fn malformed_variants() {
    let k = ticket::gateway_key(b"m", "g");
    let (t, _) = ticket::mint(&k, "g", "acc", 30, 1000, [3; 12]);
    let mut v = Verifier::new(k, "g", 10);
    for bad in ["", "T1.", "T2.AAAA", "T1.A", &t[..t.len() - 1], &format!("{}AAAA", t), &format!("{}{}", t, "A".repeat(80)),
                "T1.\u{00e9}\u{00e9}\u{00e9}\u{00e9}"] {
        assert_eq!(v.verify(bad, 1001.0).0, Verdict::Malformed, "{:?}", bad);
    }
    // olife_ticket.unb64u (CPython 3.10 non-validating a2b_base64) on edge inputs: same accept/reject, same bytes
    assert_eq!(v.verify(&format!("{}!", t), 1001.0).0, Verdict::Malformed); // python: malformed too (pad count)
    assert_eq!(v.verify(&t, 1001.0).0, Verdict::Ok);
    assert_eq!(v.verify(&t, 1001.0).0, Verdict::Replayed);
    assert_eq!(ticket::unb64u_py("-_+/"), Some(vec![0xfb, 0xff, 0xbf]));
    assert_eq!(ticket::unb64u_py("QQ"), Some(b"A".to_vec()));
    assert_eq!(ticket::unb64u_py("QUI"), Some(b"AB".to_vec()));
    assert_eq!(ticket::unb64u_py("Q"), None);
    for (s, want) in [("QUI!=", Some(&b"AB"[..])), ("QU!I", None), ("Q!UI", None), ("QUJD!", Some(b"ABC")),
                      ("QUJDRA", Some(b"ABCD")), ("QQ==QUJD", Some(b"A")), ("QQ=QUJD", None), ("Q=Q", None),
                      ("QUJD=", Some(b"ABC")), ("!QUJD", Some(b"ABC")), ("", Some(b"")), ("====", Some(b"")),
                      ("QUJ$D", Some(b"ABC"))] {
        assert_eq!(ticket::unb64u_py(s).as_deref(), want, "{:?}", s);
    }
    assert_eq!(ticket::b64u(b"AB"), "QUI");
}

#[test]
fn expiry_window_edges() {
    let k = ticket::gateway_key(b"m", "g");
    let mut v = Verifier::new(k, "g", 100);
    let mint = |n: u8, ttl: u32, now: u32| ticket::mint(&k, "g", "a", ttl, now, [n; 12]).0;
    assert_eq!(v.verify(&mint(1, 10, 1000), 1012.0).0, Verdict::Ok); // now == exp + skew
    assert_eq!(v.verify(&mint(2, 10, 1000), 1012.001).0, Verdict::Expired);
    assert_eq!(v.verify(&mint(3, 60, 1002), 1000.0).0, Verdict::Ok); // exp == now + 60 + 2
    assert_eq!(v.verify(&mint(4, 60, 1003), 1000.0).0, Verdict::Expired);
    // bad signature is reported before expiry; wrong gateway before signature
    let other = ticket::gateway_key(b"m2", "g");
    assert_eq!(v.verify(&ticket::mint(&other, "g", "a", 10, 0, [5; 12]).0, 1000.0).0, Verdict::BadSignature);
    assert_eq!(v.verify(&ticket::mint(&other, "h", "a", 10, 0, [5; 12]).0, 1000.0).0, Verdict::WrongGateway);
}

#[test]
fn nonce_cache_pruning_and_cap() {
    // = olife_ticket.selftest
    let mut c = NonceCache::new(2);
    assert_eq!(c.use_nonce([b'a'; 12], 10, 0.0), Some(true));
    assert_eq!(c.use_nonce([b'b'; 12], 10, 0.0), Some(true));
    assert_eq!(c.use_nonce([b'c'; 12], 10, 0.0), None);
    assert_eq!(c.use_nonce([b'a'; 12], 10, 12.0), Some(false)); // still remembered at exp + skew
    assert_eq!(c.use_nonce([b'c'; 12], 20, 13.0), Some(true)); // a, b pruned after exp + skew
    assert_eq!(c.len(), 1);
    // a full cache fails closed ("busy"), the verifier counts it
    let k = ticket::gateway_key(b"m", "g");
    let mut v = Verifier::new(k, "g", 1);
    assert_eq!(v.verify(&ticket::mint(&k, "g", "a", 30, 1000, [1; 12]).0, 1000.0).0, Verdict::Ok);
    assert_eq!(v.verify(&ticket::mint(&k, "g", "a", 30, 1000, [2; 12]).0, 1000.0).0, Verdict::Busy);
    assert_eq!(v.verify(&ticket::mint(&k, "g", "a", 30, 1030, [2; 12]).0, 1033.0).0, Verdict::Ok); // first pruned
    assert_eq!(v.counts.busy, 1);
    // many entries: the queue drains in order, memory follows
    let mut c = NonceCache::new(1_000_000);
    for i in 0..100_000u32 {
        let mut n = [0u8; 12];
        n[..4].copy_from_slice(&i.to_be_bytes());
        assert_eq!(c.use_nonce(n, 1000 + i / 1000, 0.0), Some(true));
    }
    c.prune(1000.0 + 50.0 + 2.0 + 0.5);
    assert_eq!(c.len(), 100_000 - 51_000);
}

#[test]
fn constant_time_compare() {
    assert!(ticket::ct_eq(b"abcdefgh", b"abcdefgh"));
    assert!(!ticket::ct_eq(b"abcdefgh", b"abcdefgi"));
    assert!(!ticket::ct_eq(b"xbcdefgh", b"abcdefgh"));
    assert!(!ticket::ct_eq(b"abc", b"abcd"));
    // timing: a mismatch in the first byte and in the last byte take the same time (no early exit). Coarse smoke
    // check robust to a busy machine / parallel tests: interleaved samples, minimum per side, up to 5 attempts.
    let a = [7u8; 16];
    let mut first = a;
    first[0] ^= 1;
    let mut last = a;
    last[15] ^= 1;
    let run = |b: &[u8; 16]| {
        let t = std::time::Instant::now();
        for _ in 0..100_000 {
            std::hint::black_box(ticket::ct_eq(std::hint::black_box(&a), std::hint::black_box(b)));
        }
        t.elapsed().as_nanos() as f64
    };
    let mut ratios = Vec::new();
    for _ in 0..5 {
        let (mut tf, mut tl) = (f64::MAX, f64::MAX);
        for _ in 0..21 {
            tf = tf.min(run(&first));
            tl = tl.min(run(&last));
        }
        let r = tf.max(tl) / tf.min(tl);
        ratios.push(r);
        if r < 1.5 {
            return;
        }
    }
    panic!("first-byte vs last-byte mismatch timing ratios {:?}", ratios);
}

#[test]
fn hmac_rfc4231_case2() {
    let d = ticket::hmac_sha256(b"Jefe", &[b"what do ya want ", b"for nothing?"]);
    assert_eq!(olife_gateway::proto::wire::hex(&d), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    let long = [0xaau8; 131];
    let d = ticket::hmac_sha256(&long, &[b"Test Using Larger Than Block-Size Key - Hash Key First"]);
    assert_eq!(olife_gateway::proto::wire::hex(&d), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
}
