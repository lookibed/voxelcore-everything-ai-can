//! Authentication of a Hello token. `AuthProvider` is the seam between the gateway and the account store:
//! `TokenFile` (now: JSON file, tokens kept only as SHA-256 digests in memory) and `HttpAuth` (the supervisor
//! endpoint, when it exists: the gateway sends the token digest, never the token). Both are hot-reload/cached.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

pub type BoxFut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Debug, Clone, PartialEq)]
pub struct Identity {
    pub account: String,
    pub perms: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AuthError {
    BadToken,
    /// supervisor refusal with its own reason code ("auth" | "banned") and text
    Denied { code: String, reason: String },
    Unavailable(String),
}

/// what the gateway knows about the attempt (for the supervisor's audit / risk checks)
#[derive(Debug, Clone)]
pub struct AuthCtx {
    pub ip: String,
    pub name: String,
    pub gateway: String,
    pub engine: String,
}

pub trait AuthProvider: Send + Sync {
    fn authenticate<'a>(&'a self, token: &'a str, ctx: &'a AuthCtx) -> BoxFut<'a, Result<Identity, AuthError>>;
    fn describe(&self) -> Value;
    /// the supervisor provider (ban polling), if this is one
    fn as_http(&self) -> Option<&HttpAuth> {
        None
    }
}

pub fn sha256_hex(s: &str) -> String {
    crate::proto::wire::hex(&Sha256::digest(s.as_bytes()))
}

fn digest(s: &str) -> [u8; 32] {
    Sha256::digest(s.as_bytes()).into()
}

/// constant-time equality of two equal-length byte strings
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut d = 0u8;
    for (x, y) in a.iter().zip(b) {
        d |= x ^ y;
    }
    d == 0
}

// ------------------------------------------------------------------------------------------ TokenFile
/// `{"tokens": {"<token>": "<account>"}, "token_sha256": {"<hex>": "<account>" | {"account": a, "perms": n}}}`.
/// `tokens` is the dev format of gateway_dev.py (plain text in the file); production files carry only
/// `token_sha256` (`olife-gateway --hash-token <t>`). In memory both become digest -> identity; lookup hashes the
/// presented token, so neither the file nor the process holds plain tokens after load.
pub struct TokenFile {
    path: String,
    st: Mutex<(Option<SystemTime>, HashMap<[u8; 32], Identity>, usize, usize)>,
    last_check: Mutex<Instant>,
}

impl TokenFile {
    pub fn load(path: &str) -> Result<TokenFile, String> {
        let t = TokenFile {
            path: path.to_string(),
            st: Mutex::new((None, HashMap::new(), 0, 0)),
            last_check: Mutex::new(Instant::now() - Duration::from_secs(10)),
        };
        t.reload(true)?;
        Ok(t)
    }

    pub fn parse(text: &str) -> Result<(HashMap<[u8; 32], Identity>, usize, usize), String> {
        let v: Value = serde_json::from_str(text).map_err(|e| format!("tokens: {}", e))?;
        let mut m = HashMap::new();
        let mut plain = 0;
        if let Some(o) = v.get("tokens").and_then(|x| x.as_object()) {
            for (tok, acc) in o {
                if let Some(a) = acc.as_str() {
                    m.insert(digest(tok), Identity { account: a.to_string(), perms: 0 });
                    plain += 1;
                }
            }
        }
        let mut hashed = 0;
        if let Some(o) = v.get("token_sha256").and_then(|x| x.as_object()) {
            for (hx, acc) in o {
                let d = crate::proto::wire::unhex(hx).filter(|d| d.len() == 32).ok_or(format!("bad sha256 {}", hx))?;
                let id = match acc {
                    Value::String(a) => Identity { account: a.clone(), perms: 0 },
                    Value::Object(_) => Identity {
                        account: acc["account"].as_str().ok_or("token_sha256: account")?.to_string(),
                        perms: acc.get("perms").and_then(|p| p.as_u64()).unwrap_or(0) as u32,
                    },
                    _ => return Err(format!("token_sha256 {}: bad value", hx)),
                };
                let mut k = [0u8; 32];
                k.copy_from_slice(&d);
                m.insert(k, id);
                hashed += 1;
            }
        }
        Ok((m, plain, hashed))
    }

    /// re-read when the file's mtime changed (checked at most once a second)
    pub fn reload(&self, force: bool) -> Result<bool, String> {
        {
            let mut lc = self.last_check.lock().unwrap();
            if !force && lc.elapsed() < Duration::from_secs(1) {
                return Ok(false);
            }
            *lc = Instant::now();
        }
        let mt = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok();
        let mut st = self.st.lock().unwrap();
        if !force && mt == st.0 {
            return Ok(false);
        }
        let text = std::fs::read_to_string(&self.path).map_err(|e| format!("tokens {}: {}", self.path, e))?;
        let (m, p, h) = Self::parse(&text)?;
        *st = (mt, m, p, h);
        Ok(true)
    }

    pub fn lookup(&self, token: &str) -> Option<Identity> {
        let _ = self.reload(false);
        let d = digest(token);
        let st = self.st.lock().unwrap();
        // HashMap probe on a SHA-256 digest: the attacker controls the token, not the digest bytes, so the probe's
        // timing cannot be steered byte by byte; the final key comparison is constant-time anyway
        st.1.get_key_value(&d).filter(|(k, _)| ct_eq(&k[..], &d[..])).map(|(_, v)| v.clone())
    }
}

impl AuthProvider for TokenFile {
    fn authenticate<'a>(&'a self, token: &'a str, _ctx: &'a AuthCtx) -> BoxFut<'a, Result<Identity, AuthError>> {
        Box::pin(async move { self.lookup(token).ok_or(AuthError::BadToken) })
    }
    fn describe(&self) -> Value {
        let st = self.st.lock().unwrap();
        json!({"kind": "token_file", "path": self.path, "entries": st.1.len(), "plain": st.2, "hashed": st.3})
    }
}

/// `--auth-mode tickets` without a token file: static tokens are never looked up (the gateway rejects them first)
pub struct NoTokens;

impl AuthProvider for NoTokens {
    fn authenticate<'a>(&'a self, _token: &'a str, _ctx: &'a AuthCtx) -> BoxFut<'a, Result<Identity, AuthError>> {
        Box::pin(async move { Err(AuthError::BadToken) })
    }
    fn describe(&self) -> Value {
        json!({"kind": "none"})
    }
}

// ------------------------------------------------------------------------------------------ HttpAuth
/// Supervisor state DB (lab stage 6, tools/lab/labcore/supervise.py, the same contract gateway_dev.py uses):
/// `GET <base>/auth?token_sha=<sha256 hex>&ip=&gateway=` -> `{"ok": true, "account", "role"}` |
/// `{"ok": false, "code": "auth"|"banned", "reason"}`; `GET <base>/bans?gateway=` -> `{"accounts", "ips"}` (polled
/// every keepalive period; banned sessions are disconnected). The token itself never leaves the gateway. Transport
/// failure -> `fallback` (the token file) and event `auth_fallback`, as gateway_dev.py. Plain HTTP/1.1 on the internal
/// network only; positive answers are cached for `ttl` (a supervisor restart does not stop logins).
pub struct HttpAuth {
    pub host: String,
    pub base: String,
    pub gateway: String,
    pub timeout: Duration,
    pub ttl: Duration,
    pub fallback: Option<TokenFile>,
    cache: Mutex<HashMap<[u8; 32], (Instant, Identity)>>,
    pub calls: std::sync::atomic::AtomicU64,
    pub fallbacks: std::sync::atomic::AtomicU64,
}

pub fn urlencode(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => o.push(b as char),
            _ => o.push_str(&format!("%{:02X}", b)),
        }
    }
    o
}

/// minimal HTTP/1.1 GET (Connection: close) -> (status, body); for the internal supervisor only
pub async fn http_get(host: &str, path: &str) -> Result<(u16, String), String> {
    http_req(host, "GET", path, None).await
}

/// minimal HTTP/1.1 request with an optional JSON body (antifraud: POST /call/olife.gw_sync)
pub async fn http_req(host: &str, method: &str, path: &str, body: Option<&str>) -> Result<(u16, String), String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = tokio::net::TcpStream::connect(host).await.map_err(|e| e.to_string())?;
    let req = match body {
        None => format!("{} {} HTTP/1.1\r\nHost: {}\r\nAccept: application/json\r\nConnection: close\r\n\r\n", method, path, host),
        Some(b) => format!("{} {} HTTP/1.1\r\nHost: {}\r\nAccept: application/json\r\nContent-Type: application/json\r\n\
                            Content-Length: {}\r\nConnection: close\r\n\r\n{}", method, path, host, b.len(), b),
    };
    s.write_all(req.as_bytes()).await.map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let n = s.read(&mut chunk).await.map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.len() > 1 << 20 {
            return Err("reply too large".into());
        }
    }
    let text = String::from_utf8_lossy(&buf).to_string();
    let (head, body) = text.split_once("\r\n\r\n").ok_or("bad HTTP reply")?;
    let status: u16 = head.split(' ').nth(1).and_then(|c| c.parse().ok()).ok_or("bad HTTP status")?;
    let body = if head.to_ascii_lowercase().contains("transfer-encoding: chunked") { dechunk(body) } else { body.to_string() };
    Ok((status, body))
}

fn dechunk(b: &str) -> String {
    let mut out = String::new();
    let mut rest = b;
    while let Some((len, tail)) = rest.split_once("\r\n") {
        let n = usize::from_str_radix(len.trim(), 16).unwrap_or(0);
        if n == 0 || tail.len() < n {
            break;
        }
        out.push_str(&tail[..n]);
        rest = tail[n..].trim_start_matches("\r\n");
    }
    out
}

impl HttpAuth {
    pub fn new(url: &str, gateway: &str, fallback: Option<TokenFile>) -> Result<HttpAuth, String> {
        let rest = url.strip_prefix("http://").ok_or("--auth-url: only http:// (internal network)")?;
        let (host, path) = match rest.find('/') {
            Some(i) => (&rest[..i], rest[i..].trim_end_matches('/')),
            None => (rest, ""),
        };
        Ok(HttpAuth {
            host: host.to_string(),
            base: path.to_string(),
            gateway: gateway.to_string(),
            timeout: Duration::from_secs(2),
            ttl: Duration::from_secs(60),
            fallback,
            cache: Mutex::new(HashMap::new()),
            calls: std::sync::atomic::AtomicU64::new(0),
            fallbacks: std::sync::atomic::AtomicU64::new(0),
        })
    }

    pub async fn get(&self, path: &str) -> Result<Value, String> {
        let r = tokio::time::timeout(self.timeout, http_get(&self.host, &format!("{}{}", self.base, path))).await;
        let (status, text) = r.map_err(|_| "timeout".to_string())??;
        if status != 200 {
            return Err(format!("HTTP {}", status));
        }
        serde_json::from_str(&text).map_err(|e| format!("json: {}", e))
    }

    /// antifraud (16.10): POST <daemon>/call/olife.gw_sync {gateway, gw_id, sessions, events} -> the feature result
    /// {accounts, ips: [{net, until, reason}], cfg}; Err = not available (daemon down / plugin without the feature)
    pub async fn sync(&self, args: Value) -> Result<Value, String> {
        let base = self.base.strip_suffix("/sup").unwrap_or(&self.base).to_string();
        let body = json!({"args": args, "owner": "olife-gateway"}).to_string();
        let r = tokio::time::timeout(self.timeout, http_req(&self.host, "POST", &format!("{}/call/olife.gw_sync", base),
                                                             Some(&body))).await;
        let (status, text) = r.map_err(|_| "timeout".to_string())??;
        if status != 200 {
            return Err(format!("HTTP {}", status));
        }
        let v: Value = serde_json::from_str(&text).map_err(|e| format!("json: {}", e))?;
        if v["ok"].as_bool() != Some(true) || !v["result"].is_object() {
            return Err(format!("gw_sync: {}", v.get("message").or(v.get("error")).cloned().unwrap_or(Value::Null)));
        }
        Ok(v["result"].clone())
    }

    /// supervisor ban lists (None = supervisor not answering: keep the previous lists)
    pub async fn bans(&self) -> Option<(Vec<String>, Vec<String>)> {
        let v = self.get(&format!("/bans?gateway={}", urlencode(&self.gateway))).await.ok()?;
        let list = |k: &str| -> Vec<String> {
            v.get(k).and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect())
                .unwrap_or_default()
        };
        Some((list("accounts"), list("ips")))
    }
}

impl AuthProvider for HttpAuth {
    fn authenticate<'a>(&'a self, token: &'a str, ctx: &'a AuthCtx) -> BoxFut<'a, Result<Identity, AuthError>> {
        Box::pin(async move {
            let d = digest(token);
            self.calls.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let q = format!("/auth?token_sha={}&ip={}&gateway={}", crate::proto::wire::hex(&d), urlencode(&ctx.ip),
                            urlencode(&ctx.gateway));
            match self.get(&q).await {
                Ok(v) => {
                    if v.get("ok").and_then(|x| x.as_bool()) == Some(true) {
                        let account = v["account"].as_str().ok_or(AuthError::Unavailable("no account".into()))?;
                        let id = Identity { account: account.to_string(), perms: v["perms"].as_u64().unwrap_or(0) as u32 };
                        let mut c = self.cache.lock().unwrap();
                        if c.len() > 100_000 {
                            c.clear();
                        }
                        c.insert(d, (Instant::now(), id.clone()));
                        return Ok(id);
                    }
                    let code = v.get("code").and_then(|x| x.as_str()).unwrap_or("auth").to_string();
                    let reason = v.get("reason").and_then(|x| x.as_str()).unwrap_or("bad token").to_string();
                    if code == "auth" && reason == "bad token" {
                        return Err(AuthError::BadToken);
                    }
                    Err(AuthError::Denied { code, reason })
                }
                Err(e) => {
                    // supervisor down: recent positive answer, then the static file (gateway_dev.py: auth_fallback)
                    self.fallbacks.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if let Some((t, id)) = self.cache.lock().unwrap().get(&d) {
                        if t.elapsed() < self.ttl {
                            return Ok(id.clone());
                        }
                    }
                    match &self.fallback {
                        Some(f) => f.lookup(token).ok_or(AuthError::BadToken),
                        None => Err(AuthError::Unavailable(e)),
                    }
                }
            }
        })
    }
    fn describe(&self) -> Value {
        json!({"kind": "supervisor", "url": format!("http://{}{}", self.host, self.base),
               "calls": self.calls.load(std::sync::atomic::Ordering::Relaxed),
               "fallbacks": self.fallbacks.load(std::sync::atomic::Ordering::Relaxed),
               "cached": self.cache.lock().unwrap().len(),
               "fallback": self.fallback.as_ref().map(|f| f.describe())})
    }
    fn as_http(&self) -> Option<&HttpAuth> {
        Some(self)
    }
}
