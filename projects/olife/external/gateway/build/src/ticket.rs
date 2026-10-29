//! Auth tickets (wave 4b): the Rust twin of tools/olife/olife_ticket.py (THE spec; checked against
//! tools/olife/protocol/vectors/tickets.json). Short-lived, one-time, signed tickets in `client.Hello.token`.
//!
//! Text: "T1." + base64url(bin) without padding (<= 127 chars). bin (big-endian):
//! `ver u8 = 1 | exp u32 | nonce 12 B | gw u32 (SHA-256(gateway id)[..4]) | alen u8 (1..55) | account | tag 16 B`,
//! tag = HMAC-SHA256(K_gw, b"olife-ticket-v1" + bin[..-16])[..16], K_gw = HMAC-SHA256(master, b"olife-gw-key-v1|" + id).
//! The gateway holds only K_gw. Verification is offline, order: malformed -> wrong_gateway -> bad_signature (constant
//! time) -> expired (now > exp + skew or exp > now + ttl_max + skew) -> replayed (nonce cache until exp + skew) -> ok.
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};

pub const PREFIX: &str = "T1.";
pub const VERSION: u8 = 1;
pub const TTL_MAX: f64 = 60.0;
pub const SKEW: f64 = 2.0;
pub const ACCOUNT_MAX: usize = 55;
pub const TAG_LEN: usize = 16;
pub const NONCE_LEN: usize = 12;

/// verify result names = olife_ticket.py (CODES / REASONS keys, + "busy" = nonce cache full)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Ok,
    Malformed,
    WrongGateway,
    BadSignature,
    Expired,
    Replayed,
    Busy,
}

impl Verdict {
    pub fn name(self) -> &'static str {
        match self {
            Verdict::Ok => "ok",
            Verdict::Malformed => "malformed",
            Verdict::WrongGateway => "wrong_gateway",
            Verdict::BadSignature => "bad_signature",
            Verdict::Expired => "expired",
            Verdict::Replayed => "replayed",
            Verdict::Busy => "busy",
        }
    }
    /// Disconnect code (olife_ticket.CODES; busy = 13 like the other gateway limits)
    pub fn code(self) -> u16 {
        match self {
            Verdict::Ok => 0,
            Verdict::Malformed => 4,
            Verdict::Expired => 14,
            Verdict::Replayed => 15,
            Verdict::BadSignature => 16,
            Verdict::WrongGateway => 17,
            Verdict::Busy => 13,
        }
    }
    /// Disconnect reason (olife_ticket.REASONS, exactly)
    pub fn reason(self) -> &'static str {
        match self {
            Verdict::Ok => "ok",
            Verdict::Malformed => "bad ticket",
            Verdict::Expired => "ticket expired",
            Verdict::Replayed => "ticket replayed",
            Verdict::BadSignature => "bad ticket signature",
            Verdict::WrongGateway => "ticket for another gateway",
            Verdict::Busy => "ticket cache full",
        }
    }
}

pub fn hmac_sha256(key: &[u8], msg: &[&[u8]]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    inner.update(k.map(|b| b ^ 0x36));
    for m in msg {
        inner.update(m);
    }
    let ih = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(k.map(|b| b ^ 0x5c));
    outer.update(ih);
    outer.finalize().into()
}

pub fn gw_hash(gateway_id: &str) -> u32 {
    let d = Sha256::digest(gateway_id.as_bytes());
    u32::from_be_bytes([d[0], d[1], d[2], d[3]])
}

/// K_gw = HMAC-SHA256(master, b"olife-gw-key-v1|" + gateway id)
pub fn gateway_key(master: &[u8], gateway_id: &str) -> [u8; 32] {
    hmac_sha256(master, &[b"olife-gw-key-v1|", gateway_id.as_bytes()])
}

/// constant-time equality (length is public)
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut d = 0u8;
    for (x, y) in a.iter().zip(b) {
        d |= x ^ y;
    }
    std::hint::black_box(d) == 0
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub fn b64u(b: &[u8]) -> String {
    let mut o = String::with_capacity(b.len() * 4 / 3 + 3);
    for ch in b.chunks(3) {
        let n = (ch[0] as u32) << 16 | (*ch.get(1).unwrap_or(&0) as u32) << 8 | *ch.get(2).unwrap_or(&0) as u32;
        for i in 0..(ch.len() + 1) {
            o.push(B64[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    o
}

/// Python `base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))` exactly (non-validating CPython a2b_base64): ASCII only,
/// both alphabets accepted, other characters skipped, a complete pad sequence ends the input, leftover data
/// characters -> error. Same accept/reject set as the reference, so the same tickets are "malformed" in both gateways.
pub fn unb64u_py(s: &str) -> Option<Vec<u8>> {
    if !s.is_ascii() {
        return None;
    }
    let pad = (4 - s.len() % 4) % 4;
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut quad, mut pads, mut left) = (0u8, 0u8, 0u32);
    for ch in s.bytes().chain(std::iter::repeat(b'=').take(pad)) {
        if ch == b'=' {
            if quad >= 2 {
                pads += 1;
                if quad + pads >= 4 {
                    return Some(out);
                }
            }
            continue;
        }
        let v = match ch {
            b'A'..=b'Z' => ch - b'A',
            b'a'..=b'z' => ch - b'a' + 26,
            b'0'..=b'9' => ch - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            _ => continue,
        } as u32;
        pads = 0;
        match quad {
            0 => {
                quad = 1;
                left = v;
            }
            1 => {
                quad = 2;
                out.push(((left << 2) | (v >> 4)) as u8);
                left = v & 0x0f;
            }
            2 => {
                quad = 3;
                out.push(((left << 4) | (v >> 2)) as u8);
                left = v & 0x03;
            }
            _ => {
                quad = 0;
                out.push(((left << 6) | v) as u8);
                left = 0;
            }
        }
    }
    if quad != 0 {
        return None;
    }
    Some(out)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Ticket {
    pub exp: u32,
    pub nonce: [u8; NONCE_LEN],
    pub gw: u32,
    pub account: String,
    pub body: Vec<u8>,
    pub tag: [u8; TAG_LEN],
}

/// = olife_ticket.parse (None = malformed)
pub fn parse(text: &str) -> Option<Ticket> {
    if !text.starts_with(PREFIX) || text.chars().count() > 127 {
        return None;
    }
    let b = unb64u_py(&text[PREFIX.len()..])?;
    if b.len() < 22 + 1 + TAG_LEN {
        return None;
    }
    let ver = b[0];
    let exp = u32::from_be_bytes([b[1], b[2], b[3], b[4]]);
    let gw = u32::from_be_bytes([b[17], b[18], b[19], b[20]]);
    let alen = b[21] as usize;
    if ver != VERSION || !(1..=ACCOUNT_MAX).contains(&alen) || b.len() != 22 + alen + TAG_LEN {
        return None;
    }
    let account = std::str::from_utf8(&b[22..22 + alen]).ok()?.to_string();
    let mut nonce = [0u8; NONCE_LEN];
    nonce.copy_from_slice(&b[5..17]);
    let mut tag = [0u8; TAG_LEN];
    tag.copy_from_slice(&b[22 + alen..]);
    Some(Ticket { exp, nonce, gw, account, body: b[..22 + alen].to_vec(), tag })
}

/// = olife_ticket.mint (tests, tools): -> (text, exp)
pub fn mint(key_gw: &[u8], gateway_id: &str, account: &str, ttl: u32, now: u32, nonce: [u8; NONCE_LEN]) -> (String, u32) {
    let exp = now + ttl;
    let a = account.as_bytes();
    let mut body = vec![VERSION];
    body.extend_from_slice(&exp.to_be_bytes());
    body.extend_from_slice(&nonce);
    body.extend_from_slice(&gw_hash(gateway_id).to_be_bytes());
    body.push(a.len() as u8);
    body.extend_from_slice(a);
    let tag = hmac_sha256(key_gw, &[b"olife-ticket-v1", &body]);
    body.extend_from_slice(&tag[..TAG_LEN]);
    (format!("{}{}", PREFIX, b64u(&body)), exp)
}

/// Used nonces until exp + skew (= olife_ticket.NonceCache): map + insertion-order queue, bounded.
pub struct NonceCache {
    pub cap: usize,
    seen: HashMap<[u8; NONCE_LEN], u32>,
    order: VecDeque<(u32, [u8; NONCE_LEN])>,
}

impl NonceCache {
    pub fn new(cap: usize) -> Self {
        NonceCache { cap, seen: HashMap::new(), order: VecDeque::new() }
    }
    pub fn prune(&mut self, now: f64) {
        while let Some(&(exp, n)) = self.order.front() {
            if exp as f64 + SKEW >= now {
                break;
            }
            self.order.pop_front();
            if self.seen.get(&n) == Some(&exp) {
                self.seen.remove(&n);
            }
        }
    }
    /// Some(true) first use (remembered), Some(false) replay, None cache full
    pub fn use_nonce(&mut self, nonce: [u8; NONCE_LEN], exp: u32, now: f64) -> Option<bool> {
        self.prune(now);
        if self.seen.contains_key(&nonce) {
            return Some(false);
        }
        if self.seen.len() >= self.cap {
            return None;
        }
        self.seen.insert(nonce, exp);
        self.order.push_back((exp, nonce));
        Some(true)
    }
    pub fn len(&self) -> usize {
        self.seen.len()
    }
    pub fn is_empty(&self) -> bool {
        self.seen.is_empty()
    }
}

#[derive(Debug, Default, Clone)]
pub struct Counts {
    pub ok: u64,
    pub malformed: u64,
    pub expired: u64,
    pub replayed: u64,
    pub bad_signature: u64,
    pub wrong_gateway: u64,
    pub busy: u64,
}

/// = olife_ticket.Verifier (one per gateway; callers serialize it with a mutex)
pub struct Verifier {
    key: [u8; 32],
    pub gw_id: String,
    pub gw: u32,
    pub cache: NonceCache,
    pub ttl_max: f64,
    pub skew: f64,
    pub counts: Counts,
}

impl Verifier {
    pub fn new(key_gw: [u8; 32], gateway_id: &str, cache_cap: usize) -> Self {
        Verifier { key: key_gw, gw_id: gateway_id.to_string(), gw: gw_hash(gateway_id), cache: NonceCache::new(cache_cap),
                   ttl_max: TTL_MAX, skew: SKEW, counts: Counts::default() }
    }

    /// now: unix seconds (float, as time.time()). -> (verdict, account on Ok)
    pub fn verify(&mut self, text: &str, now: f64) -> (Verdict, Option<String>) {
        let mut acct = None;
        let r = match parse(text) {
            None => Verdict::Malformed,
            Some(p) if p.gw != self.gw => Verdict::WrongGateway,
            Some(p) => {
                let want = hmac_sha256(&self.key, &[b"olife-ticket-v1", &p.body]);
                if !ct_eq(&want[..TAG_LEN], &p.tag) {
                    Verdict::BadSignature
                } else if now > p.exp as f64 + self.skew || p.exp as f64 > now + self.ttl_max + self.skew {
                    Verdict::Expired
                } else {
                    match self.cache.use_nonce(p.nonce, p.exp, now) {
                        Some(true) => {
                            acct = Some(p.account);
                            Verdict::Ok
                        }
                        Some(false) => Verdict::Replayed,
                        None => Verdict::Busy,
                    }
                }
            }
        };
        let c = &mut self.counts;
        *match r {
            Verdict::Ok => &mut c.ok,
            Verdict::Malformed => &mut c.malformed,
            Verdict::Expired => &mut c.expired,
            Verdict::Replayed => &mut c.replayed,
            Verdict::BadSignature => &mut c.bad_signature,
            Verdict::WrongGateway => &mut c.wrong_gateway,
            Verdict::Busy => &mut c.busy,
        } += 1;
        (r, acct)
    }
}

/// key file: 64 hex chars, or JSON {"key": hex, "gateway": id} -> (K_gw, gateway id from the file)
pub fn load_key_file(path: &str) -> Result<([u8; 32], Option<String>), String> {
    let s = std::fs::read_to_string(path).map_err(|e| format!("--ticket-key {}: {}", path, e))?;
    let s = s.trim();
    let (hx, gw) = if s.starts_with('{') {
        let v: serde_json::Value = serde_json::from_str(s).map_err(|e| format!("--ticket-key: json: {}", e))?;
        let k = v.get("key").and_then(|k| k.as_str()).ok_or("--ticket-key: no \"key\"")?.to_string();
        (k, v.get("gateway").and_then(|g| g.as_str()).map(String::from))
    } else {
        (s.to_string(), None)
    };
    let b = crate::proto::wire::unhex(hx.trim()).filter(|b| b.len() == 32).ok_or("--ticket-key: key must be 64 hex chars")?;
    let mut k = [0u8; 32];
    k.copy_from_slice(&b);
    Ok((k, gw))
}
