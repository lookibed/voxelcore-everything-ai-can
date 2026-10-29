//! Gateway unit tests (no sockets except a local fake supervisor): framing helpers equal the generated encoder,
//! Disconnect codes equal gateway_dev.py, token file hashing, supervisor auth contract, buckets.
use olife_gateway::auth::{self, AuthCtx, AuthError, AuthProvider, HttpAuth, TokenFile};
use olife_gateway::gateway::{code_of, data_frame};
use olife_gateway::proto::{client as C, internal as I, wire};
use olife_gateway::util::Bucket;

#[test]
fn data_frame_equals_generated() {
    for body in [vec![], vec![1u8, 2, 3], vec![7u8; 70000]] {
        let g = I::Msg::Data(I::Data { session: 77, r#type: 5, payload: wire::Bytes(body.clone()) }).frame().unwrap();
        assert_eq!(data_frame(77, 5, &body), g);
    }
}

#[test]
fn codes_equal_gateway_dev() {
    // CODES of tools/olife/gateway_dev.py; unknown reason codes ("closed") -> 3 like CODES.get(rc, 3)
    let py = [("shutdown", 1), ("handshake_timeout", 2), ("protocol", 3), ("auth", 4), ("banned", 5), ("keepalive", 6),
              ("flood", 7), ("timeout", 8), ("world_unavailable", 9), ("kicked", 10), ("slow_consumer", 11),
              ("duplicate", 12), ("closed", 3)];
    for (k, v) in py {
        assert_eq!(code_of(k), v, "{}", k);
    }
    assert_eq!(code_of("limit"), 13);
}

fn ctx() -> AuthCtx {
    AuthCtx { ip: "127.0.0.1".into(), name: "n".into(), gateway: "gw".into(), engine: "e".into() }
}

#[tokio::test]
async fn token_file_plain_and_hashed() {
    let dir = std::env::temp_dir().join(format!("olife_gw_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("tokens.json");
    let h = auth::sha256_hex("secret-token");
    std::fs::write(&p, format!(r#"{{"tokens": {{"olife-dev": "dev"}}, "token_sha256": {{"{}": {{"account": "ops", "perms": 3}}}}}}"#, h)).unwrap();
    let t = TokenFile::load(p.to_str().unwrap()).unwrap();
    assert_eq!(t.authenticate("olife-dev", &ctx()).await.unwrap().account, "dev");
    let id = t.authenticate("secret-token", &ctx()).await.unwrap();
    assert_eq!((id.account.as_str(), id.perms), ("ops", 3));
    assert_eq!(t.authenticate("nope", &ctx()).await, Err(AuthError::BadToken));
    assert_eq!(t.describe()["hashed"], 1);
    assert!(auth::ct_eq(b"abc", b"abc") && !auth::ct_eq(b"abc", b"abd") && !auth::ct_eq(b"ab", b"abc"));
}

/// fake supervisor (stage 6 contract): /sup/auth?token_sha=..., /sup/bans
async fn fake_sup() -> (u16, tokio::task::JoinHandle<()>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let good = auth::sha256_hex("good");
    let banned = auth::sha256_hex("banned");
    let h = tokio::spawn(async move {
        loop {
            let (mut s, _) = l.accept().await.unwrap();
            let mut b = vec![0u8; 4096];
            let n = s.read(&mut b).await.unwrap();
            let req = String::from_utf8_lossy(&b[..n]).to_string();
            let path = req.split(' ').nth(1).unwrap_or("").to_string();
            let body = if path.starts_with("/sup/bans") {
                r#"{"ok": true, "accounts": ["evil"], "ips": ["10.0.0.1"]}"#.to_string()
            } else if path.contains(&good) {
                assert!(path.contains("gateway=gw") && path.contains("ip=127.0.0.1"), "{}", path);
                r#"{"ok": true, "account": "alice", "role": "player"}"#.to_string()
            } else if path.contains(&banned) {
                r#"{"ok": false, "code": "banned", "reason": "banned: cheating"}"#.to_string()
            } else {
                r#"{"ok": false, "code": "auth", "reason": "bad token"}"#.to_string()
            };
            let _ = s.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).as_bytes()).await;
        }
    });
    (port, h)
}

#[tokio::test]
async fn supervisor_contract() {
    let (port, h) = fake_sup().await;
    let a = HttpAuth::new(&format!("http://127.0.0.1:{}/sup", port), "gw", None).unwrap();
    assert_eq!(a.authenticate("good", &ctx()).await.unwrap().account, "alice");
    assert_eq!(a.authenticate("bad", &ctx()).await, Err(AuthError::BadToken));
    match a.authenticate("banned", &ctx()).await {
        Err(AuthError::Denied { code, reason }) => assert_eq!((code.as_str(), reason.as_str()), ("banned", "banned: cheating")),
        x => panic!("{:?}", x),
    }
    let (acc, ips) = a.bans().await.unwrap();
    assert_eq!((acc, ips), (vec!["evil".to_string()], vec!["10.0.0.1".to_string()]));
    h.abort();
    // supervisor gone: cached positive answer still works, unknown -> Unavailable (no fallback file)
    let _ = h.await;
    assert_eq!(a.authenticate("good", &ctx()).await.unwrap().account, "alice");
    assert!(matches!(a.authenticate("other", &ctx()).await, Err(AuthError::Unavailable(_))));
    assert!(a.bans().await.is_none());
}

#[test]
fn bucket_like_python() {
    let mut b = Bucket::new(60.0, 120.0);
    let n = (0..600).filter(|_| b.take(1.0)).count();
    assert!((120..=122).contains(&n), "{}", n);   // burst of 600 -> ~120 accepted, the rest is the flood
}

#[test]
fn client_frame_limits() {
    // the gateway reads clients with max 64 KiB: a 1 MiB header is refused before the body arrives
    let mut f = C::framer(Some(65536));
    f.feed(&wire::header(C::MAGIC, C::VERSION, 5, 1 << 20));
    assert!(f.next().unwrap_err().0.contains("frame too large 1048576 > 65536"));
}

/// olife_friends 16.10: public flags (flag or "1"), ServerInfo from the --info file + what the gateway knows, code 19
#[test]
fn public_flags_and_server_info() {
    use olife_gateway::config::Config;
    use olife_gateway::{bans::Bans, gateway::Gateway, log::Log};
    let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let c = Config::parse(&a(&["--listen", "27750", "--upstream", "127.0.0.1:1", "--public", "--packs-public"])).unwrap();
    assert!(c.public && c.packs_public && c.listen.ip().is_unspecified());
    let c = Config::parse(&a(&["--listen", "27750", "--upstream", "127.0.0.1:1", "--public", "1", "--packs-public", "0"])).unwrap();
    assert!(c.public && !c.packs_public && c.listen.ip().is_unspecified());
    let c = Config::parse(&a(&["--listen", "27750", "--upstream", "127.0.0.1:1", "--public", ""])).unwrap();
    assert!(!c.public && c.listen.ip().is_loopback());
    assert_eq!(code_of("info"), 19);
    let dir = std::env::temp_dir().join(format!("olife_gw_info_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("info.json");
    std::fs::write(&p, r#"{"name": "Kent server", "auth_port": 27751, "auth_scheme": "https", "auth_pub": "AAAA", "packs_port": 27752, "public": true, "whitelist": true, "motd": "hi"}"#).unwrap();
    let cfg = Config::parse(&a(&["--listen", "27750", "--upstream", "127.0.0.1:1", "--gw-id", "gw-x", "--info", p.to_str().unwrap(), "--packs-http", "1234"])).unwrap();
    let gw = Gateway::new(cfg, Log::open(None).unwrap(), Box::new(auth::NoTokens), Bans::new(None));
    let si = gw.server_info();
    assert_eq!((si.name.as_str(), si.gw_id.as_str(), si.auth_port, si.packs_port), ("Kent server", "gw-x", 27751, 27752));
    assert!(si.public && si.whitelist && si.auth_pub == "AAAA" && si.auth_scheme == "https" && si.motd == "hi");
    // no file: defaults from the gateway itself
    std::fs::remove_file(&p).unwrap();
    let si = gw.server_info();
    assert_eq!((si.auth_port, si.packs_port, si.auth_scheme.as_str(), si.public), (0, 1234, "https", false));
    let f = C::Msg::ServerInfo(si).frame().unwrap();
    assert!(f.len() > 9);
}
