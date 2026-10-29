//! Pack hot reload (wave 4b), the twin of gateway_dev.py check_manifest / serve_packs:
//! * `--packs-manifest <path>`: JSON written by the lab supervisor `{version, root, packs: {name: {side, files: [{path,
//!   sha256, size, side}]}}}`, watched every 1 s by content SHA-256; a change bumps `packs.version` (load counter),
//!   logs `manifest_loaded` / `manifest_changed` and sends `client.PacksChanged{version, url, files}` to every session
//!   that already got its `Welcome` (new sessions get it right after their `Welcome`).
//! * `--packs-http <port>` (127.0.0.1): `GET /manifest.json` (the raw file) and `GET /files/<pack>/<path>` — only files
//!   the manifest lists with side client|both (no path traversal), SHA-256 re-checked (409 if changed since the manifest).
use crate::gateway::Gateway;
use crate::proto::client as C;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

#[derive(Debug, Clone)]
pub struct PackFile {
    pub sha256: String,
    pub size: u64,
}

#[derive(Debug, Default)]
pub struct Packs {
    pub path: Option<String>,
    pub url: String,
    pub version: u64,
    pub sha: Option<[u8; 32]>,
    bad_sha: Option<[u8; 32]>,
    pub manifest_version: Value,
    pub root: Option<String>,
    pub files: HashMap<String, PackFile>,
    pub raw: Option<Arc<Vec<u8>>>,
    pub served: u64,
    pub notified: u64,
    pub errors: u64,
}

#[derive(Debug, PartialEq)]
pub enum Check {
    Unchanged,
    Loaded,
    Changed,
}

pub fn version_str(v: &Value) -> String {
    let s = match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    };
    clip(&s, 64)
}

fn clip(s: &str, n: usize) -> String {
    if s.len() <= n {
        return s.to_string();
    }
    let mut i = n;
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    s[..i].to_string()
}

impl Packs {
    pub fn new(path: Option<String>, url: String) -> Packs {
        Packs { path, url, ..Default::default() }
    }

    /// parse a manifest -> (version field, root, client/both files by "<pack>/<path>")
    pub fn parse(raw: &[u8]) -> Result<(Value, Option<String>, HashMap<String, PackFile>), String> {
        let d: Value = serde_json::from_slice(raw).map_err(|e| format!("manifest json: {}", e))?;
        let mut files = HashMap::new();
        if let Some(p) = d.get("packs").and_then(|p| p.as_object()) {
            for (pk, info) in p {
                for e in info.get("files").and_then(|f| f.as_array()).map(|a| a.as_slice()).unwrap_or(&[]) {
                    let side = e.get("side").and_then(|s| s.as_str()).unwrap_or("");
                    if side != "client" && side != "both" {
                        continue;
                    }
                    let path = e.get("path").and_then(|s| s.as_str()).ok_or("manifest: file without path")?;
                    let sha = e.get("sha256").and_then(|s| s.as_str()).unwrap_or("").to_ascii_lowercase();
                    files.insert(format!("{}/{}", pk, path),
                                 PackFile { sha256: sha, size: e.get("size").and_then(|s| s.as_u64()).unwrap_or(0) });
                }
            }
        }
        Ok((d.get("version").cloned().unwrap_or(Value::Null), d.get("root").and_then(|r| r.as_str()).map(String::from), files))
    }

    /// re-read the manifest; changed content (SHA-256) -> new state. A broken file keeps the previous state.
    pub fn check(&mut self) -> Result<Check, String> {
        let Some(p) = self.path.clone() else { return Ok(Check::Unchanged) };
        let Ok(raw) = std::fs::read(&p) else { return Ok(Check::Unchanged) };
        let sha: [u8; 32] = Sha256::digest(&raw).into();
        if Some(sha) == self.sha || Some(sha) == self.bad_sha {
            return Ok(Check::Unchanged);
        }
        let (ver, root, files) = match Self::parse(&raw) {
            Ok(x) => x,
            Err(e) => {
                self.bad_sha = Some(sha);
                self.errors += 1;
                return Err(e);
            }
        };
        let first = self.sha.is_none();
        self.version += 1;
        self.sha = Some(sha);
        self.bad_sha = None;
        self.manifest_version = ver;
        self.root = root;
        self.files = files;
        self.raw = Some(Arc::new(raw));
        Ok(if first { Check::Loaded } else { Check::Changed })
    }

    /// the client message for the current manifest (None = no manifest loaded)
    pub fn message(&self) -> Option<C::PacksChanged> {
        self.sha?;
        Some(C::PacksChanged { version: version_str(&self.manifest_version), url: clip(&self.url, 256),
                               files: self.files.len().min(65535) as u16 })
    }

    pub fn metrics(&self) -> Value {
        json!({"version": self.version, "manifest_version": self.manifest_version, "files": self.files.len(),
               "served": self.served, "notified": self.notified, "path": self.path, "url": self.url,
               "sha": self.sha.map(|s| crate::proto::wire::hex(&s)), "root": self.root, "errors": self.errors})
    }
}

fn unquote(s: &str) -> String {
    let b = s.as_bytes();
    let mut o = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hx = |c: u8| (c as char).to_digit(16);
            if let (Some(h), Some(l)) = (hx(b[i + 1]), hx(b[i + 2])) {
                o.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        o.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&o).into_owned()
}

pub async fn http_serve(gw: Arc<Gateway>, port: u16) -> std::io::Result<()> {
    // public play (olife_friends): `--packs-public` -> all interfaces (only listed client files and CAS assets are served)
    let host = if gw.cfg.packs_public { "0.0.0.0" } else { "127.0.0.1" };
    let l = TcpListener::bind((host, port)).await?;
    gw.log.line(&format!("packs http={} host={} manifest={}", port, host, gw.cfg.packs_manifest.clone().unwrap_or_default()));
    tokio::spawn(async move {
        loop {
            if let Ok((s, _)) = l.accept().await {
                let g = gw.clone();
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(60), http_client(g, s)).await;
                });
            }
        }
    });
    Ok(())
}

async fn http_client(gw: Arc<Gateway>, mut s: TcpStream) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(2048);
    let mut tmp = [0u8; 2048];
    loop {
        let n = s.read(&mut tmp).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 16384 {
            return reply(&mut s, 431, b"headers too large", "text/plain").await;
        }
    }
    let head = String::from_utf8_lossy(&buf).to_string();
    let rl: Vec<&str> = head.split("\r\n").next().unwrap_or("").split(' ').collect();
    let (method, raw_path) = (rl.first().copied().unwrap_or(""), rl.get(1).copied().unwrap_or("/"));
    if method != "GET" {
        return reply(&mut s, 405, b"GET only", "text/plain").await;
    }
    gw.check_manifest();
    let path = unquote(raw_path.split('?').next().unwrap_or("/"));
    if path == "/manifest.json" {
        let raw = gw.packs.lock().unwrap().raw.clone();
        if let Some(raw) = raw {
            return reply(&mut s, 200, &raw, "application/json").await;
        }
    } else if let (Some(sha), Some(dir)) = (path.strip_prefix("/assets/"), gw.cfg.assets_dir.clone()) {
        // UX A4: store files of the world (sha256 CAS): <dir>/<sha[..2]>/<sha>, re-hashed; only 64 lowercase hex chars
        if sha.len() != 64 || !sha.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) {
            return reply(&mut s, 404, b"not found", "text/plain").await;
        }
        let mut fp = std::path::PathBuf::from(dir);
        fp.push(&sha[..2]);
        fp.push(sha);
        let data = match tokio::task::spawn_blocking(move || std::fs::read(&fp)).await {
            Ok(Ok(d)) => d,
            _ => {
                gw.assets_stats(|a| a.missing += 1);
                return reply(&mut s, 404, b"missing", "text/plain").await;
            }
        };
        if crate::proto::wire::hex(&Sha256::digest(&data)) != sha {
            gw.assets_stats(|a| a.bad += 1);
            return reply(&mut s, 409, b"changed", "text/plain").await;
        }
        let n = data.len() as u64;
        gw.assets_stats(|a| {
            a.served += 1;
            a.bytes += n;
        });
        return reply(&mut s, 200, &data, "application/octet-stream").await;
    } else if let Some(key) = path.strip_prefix("/files/") {
        // only files listed in the manifest (client side): no path traversal
        let entry = {
            let p = gw.packs.lock().unwrap();
            p.files.get(key).cloned().map(|e| (e, p.root.clone().unwrap_or_default()))
        };
        if let Some((e, root)) = entry {
            let (pk, rel) = key.split_once('/').unwrap_or((key, ""));
            let mut fp = std::path::PathBuf::from(root);
            fp.push(pk);
            for part in rel.split('/') {
                fp.push(part);
            }
            let data = match tokio::task::spawn_blocking(move || std::fs::read(&fp)).await {
                Ok(Ok(d)) => d,
                _ => return reply(&mut s, 404, b"missing", "text/plain").await,
            };
            if crate::proto::wire::hex(&Sha256::digest(&data)) != e.sha256 {
                return reply(&mut s, 409, b"changed since the manifest", "text/plain").await;
            }
            gw.packs.lock().unwrap().served += 1;
            return reply(&mut s, 200, &data, "application/octet-stream").await;
        }
    }
    reply(&mut s, 404, b"not found", "text/plain").await
}

async fn reply(s: &mut TcpStream, code: u16, body: &[u8], ctype: &str) -> std::io::Result<()> {
    let reason = match code {
        200 => "OK",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        431 => "Request Header Fields Too Large",
        _ => "Error",
    };
    let head = format!("HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                       code, reason, ctype, body.len());
    s.write_all(head.as_bytes()).await?;
    s.write_all(body).await?;
    s.shutdown().await
}
