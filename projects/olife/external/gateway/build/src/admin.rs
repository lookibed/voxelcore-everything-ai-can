//! Operator surfaces, both on 127.0.0.1 only:
//! * `--admin <port>`: HTTP/1.1 JSON — GET /status, GET /sessions, GET /health, POST /kick {session, reason?},
//!   POST /ban {account?|ip?}, POST /drain {budget_s?} (then the process exits). `--admin-token T` requires the
//!   header `X-Admin-Token: T` (constant-time compare).
//! * `--f2f <port>`: the lab control protocol (JSON lines {id, cmd, args} -> {id, ok, result|error}, as
//!   tools/lab/projects/olife/ctlport.py): hello, metrics, sessions, kick, ban, drain, quit.
use crate::gateway::Gateway;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

fn arg_u32(a: &Value, k: &str) -> Option<u32> {
    match a.get(k) {
        Some(Value::Number(n)) => n.as_u64().map(|x| x as u32),
        Some(Value::String(s)) => s.parse().ok(),
        _ => None,
    }
}

/// shared command set of both surfaces; Err = error text
pub async fn command(gw: &Arc<Gateway>, cmd: &str, a: &Value) -> Result<Value, String> {
    match cmd {
        "hello" => Ok(json!({"impl": "olife-gateway", "pid": std::process::id(), "version": env!("CARGO_PKG_VERSION"),
                             "flags": {"input": "none", "window": "none"}})),
        "metrics" | "status" => Ok(gw.metrics()),
        "sessions" => Ok(gw.sessions_json()),
        "world_status" => Ok(gw.world_status(a)),
        "kick" => {
            let sid = arg_u32(a, "session").ok_or("KeyError: 'session'")?;
            gw.kick(sid, a.get("reason").and_then(|r| r.as_str()))
        }
        "ban" => gw.ban(a.get("account").and_then(|x| x.as_str()), a.get("ip").and_then(|x| x.as_str())),
        "kick_ip" => {
            let nets: Vec<String> = a["nets"].as_array().map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                .unwrap_or_default();
            // ban: [{net, until, reason}] -> into the list at once (refused before Hello now, not after the next sync)
            if let Some(b) = a["ban"].as_array() {
                gw.bans.add_nets(b);
            }
            Ok(gw.kick_ip(&nets, a["reason"].as_str().unwrap_or("banned by IP"), a["code"].as_u64().unwrap_or(5) as u16))
        }
        "drain" => {
            let b = a.get("budget_s").and_then(|x| x.as_f64()).map(Duration::from_secs_f64).unwrap_or(gw.cfg.limits.drain);
            let r = gw.drain(b).await;
            let g = gw.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(100)).await;
                g.exit.notify_one();
            });
            Ok(r)
        }
        _ => Err(format!("KeyError: unknown cmd {:?} (have: hello, quit, metrics, sessions, world_status, kick, ban, kick_ip, drain)", cmd)),
    }
}

// ------------------------------------------------------------------------------ lab control port
pub async fn ctl_serve(gw: Arc<Gateway>, port: u16) -> std::io::Result<()> {
    let l = TcpListener::bind(("127.0.0.1", port)).await?;
    gw.log.line(&format!("control port {}", port));
    tokio::spawn(async move {
        loop {
            if let Ok((s, _)) = l.accept().await {
                tokio::spawn(ctl_client(gw.clone(), s));
            }
        }
    });
    Ok(())
}

async fn ctl_client(gw: Arc<Gateway>, s: TcpStream) {
    let (rd, mut wr) = s.into_split();
    let mut lines = BufReader::new(rd).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(req) = serde_json::from_str::<Value>(&line) else { continue };
        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let cmd = req.get("cmd").and_then(|c| c.as_str()).unwrap_or("").to_string();
        let args = req.get("args").cloned().unwrap_or(json!({}));
        if cmd == "quit" {
            let _ = wr.write_all(format!("{}\n", json!({"id": id, "ok": true, "result": "bye"})).as_bytes()).await;
            let _ = wr.flush().await;
            let _ = gw.drain(gw.cfg.limits.drain).await;
            gw.exit.notify_one();
            return;
        }
        let rep = match command(&gw, &cmd, &args).await {
            Ok(r) => json!({"id": id, "ok": true, "result": r}),
            Err(e) => json!({"id": id, "ok": false, "error": e}),
        };
        if wr.write_all(format!("{}\n", rep).as_bytes()).await.is_err() {
            return;
        }
    }
}

// ------------------------------------------------------------------------------ admin HTTP
pub async fn http_serve(gw: Arc<Gateway>, port: u16) -> std::io::Result<()> {
    let l = TcpListener::bind(("127.0.0.1", port)).await?;
    gw.log.line(&format!("admin http://127.0.0.1:{}/status", port));
    tokio::spawn(async move {
        loop {
            if let Ok((s, _)) = l.accept().await {
                let g = gw.clone();
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(10), http_client(g, s)).await;
                });
            }
        }
    });
    Ok(())
}

async fn http_client(gw: Arc<Gateway>, mut s: TcpStream) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];
    let head_end = loop {
        let n = s.read(&mut tmp).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if buf.len() > 16384 {
            return reply(&mut s, 431, &json!({"error": "headers too large"})).await;
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut it = head.split("\r\n");
    let rl: Vec<&str> = it.next().unwrap_or("").split(' ').collect();
    let (method, path) = (rl.first().copied().unwrap_or(""), rl.get(1).copied().unwrap_or("/"));
    let mut clen = 0usize;
    let mut token = None;
    for h in it {
        if let Some((k, v)) = h.split_once(':') {
            match k.trim().to_ascii_lowercase().as_str() {
                "content-length" => clen = v.trim().parse().unwrap_or(0),
                "x-admin-token" => token = Some(v.trim().to_string()),
                _ => {}
            }
        }
    }
    if clen > 65536 {
        return reply(&mut s, 413, &json!({"error": "body too large"})).await;
    }
    while buf.len() < head_end + clen {
        let n = s.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
    }
    if let Some(want) = &gw.cfg.admin_token {
        let ok = token.map_or(false, |t| crate::auth::ct_eq(t.as_bytes(), want.as_bytes()));
        if !ok {
            return reply(&mut s, 401, &json!({"error": "X-Admin-Token required"})).await;
        }
    }
    let body: Value = if clen > 0 {
        match serde_json::from_slice(&buf[head_end..(head_end + clen).min(buf.len())]) {
            Ok(v) => v,
            Err(e) => return reply(&mut s, 400, &json!({"error": format!("json: {}", e)})).await,
        }
    } else {
        json!({})
    };
    let path = path.split('?').next().unwrap_or("/");
    let cmd = match (method, path) {
        ("GET", "/health") => return reply(&mut s, 200, &json!({"ok": true, "draining": gw.draining.load(std::sync::atomic::Ordering::Relaxed)})).await,
        ("GET", "/status") | ("GET", "/metrics") => "metrics",
        ("GET", "/sessions") => "sessions",
        ("POST", "/kick") => "kick",
        ("POST", "/ban") => "ban",
        ("POST", "/drain") => "drain",
        _ => return reply(&mut s, 404, &json!({"error": "not found", "routes": ["GET /status", "GET /sessions",
                         "GET /health", "POST /kick", "POST /ban", "POST /drain"]})).await,
    };
    gw.log.event("info", "admin", json!({"method": method, "path": path, "body": body}));
    match command(&gw, cmd, &body).await {
        Ok(v) => reply(&mut s, 200, &v).await,
        Err(e) => reply(&mut s, 400, &json!({"error": e})).await,
    }
}

async fn reply(s: &mut TcpStream, code: u16, v: &Value) -> std::io::Result<()> {
    let body = serde_json::to_vec_pretty(v).unwrap_or_default();
    let reason = match code {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        413 => "Payload Too Large",
        _ => "Error",
    };
    let head = format!("HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                       code, reason, body.len());
    s.write_all(head.as_bytes()).await?;
    s.write_all(&body).await?;
    s.shutdown().await
}
