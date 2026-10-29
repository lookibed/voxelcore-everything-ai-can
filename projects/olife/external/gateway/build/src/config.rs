//! Command line (same flags as tools/olife/gateway_dev.py + production ones). `--key value` pairs, like ctlport.argmap.
use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::Duration;

/// Limits and timings. Defaults equal gateway_dev.py where it has the same knob (its behaviour is the reference).
#[derive(Debug, Clone)]
pub struct Limits {
    pub max_c2s_frame: u32,      // client frames: body <= 64 KiB (MAX_C2S)
    pub handshake: Duration,     // Hello within 5 s
    pub keepalive_every: Duration,
    pub keepalive_timeout: Duration,
    pub rate_msgs: f64,          // per session, token bucket (60/s, burst 120)
    pub burst_msgs: f64,
    pub rate_bytes: f64,         // per session (64 KiB/s, burst 256 KiB)
    pub burst_bytes: f64,
    pub flood_ban: Duration,     // flood -> IP temp ban 30 s
    pub out_queue_max: usize,    // per-client send queue (16 MiB) -> Disconnect 11
    pub write_stall: Duration,   // one write blocked longer than this -> slow consumer
    pub world_queue_max: usize,  // gateway -> world queue (bytes); over -> the sending session is dropped (9)
    pub max_sessions: usize,     // authenticated sessions per gateway
    pub max_conns: usize,        // open TCP connections per gateway (pre-auth included)
    pub max_conns_per_ip: usize, // concurrent connections from one IP
    pub conn_rate_ip: f64,       // new connections per second from one IP (bucket)
    pub conn_burst_ip: f64,
    pub auth_fail_ip: f64,       // failed handshakes per minute from one IP before a temp ban
    pub world_wait: Duration,    // Hello waits for the world link this long
    pub drain: Duration,         // graceful drain budget (quit / SIGINT / POST /drain)
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_c2s_frame: 65536,
            handshake: Duration::from_secs(5),
            keepalive_every: Duration::from_secs(2),
            keepalive_timeout: Duration::from_secs(10),
            rate_msgs: 60.0,
            burst_msgs: 120.0,
            rate_bytes: 65536.0,
            burst_bytes: 262144.0,
            flood_ban: Duration::from_secs(30),
            out_queue_max: 16 * 1024 * 1024,
            write_stall: Duration::from_secs(15),
            world_queue_max: 64 * 1024 * 1024,
            max_sessions: 1000,
            max_conns: 4096,
            max_conns_per_ip: 64,
            conn_rate_ip: 20.0,
            conn_burst_ip: 60.0,
            auth_fail_ip: 20.0,
            world_wait: Duration::from_secs(5),
            drain: Duration::from_millis(1500),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub listen: SocketAddr,
    pub upstream: String,
    pub name: String,
    pub secret: String,
    pub tokens: Option<String>,
    pub auth_url: Option<String>,
    pub bans: Option<String>,
    pub f2f: Option<u16>,
    pub admin: Option<u16>,
    pub admin_token: Option<String>,
    pub metrics: Option<String>,
    pub log: Option<String>,
    pub threads: usize,
    pub limits: Limits,
    /// wave 4b tickets: K_gw key file, audience id, mode ("tokens" | "tickets" | "both"), nonce cache cap
    pub ticket_key: Option<String>,
    pub gw_id: Option<String>,
    pub auth_mode: String,
    pub ticket_cache: usize,
    /// wave 4b pack hot reload: manifest (lab supervisor), dev HTTP port, advertised base url
    pub packs_manifest: Option<String>,
    pub packs_http: Option<u16>,
    pub packs_url: Option<String>,
    /// UX A4: the world store CAS (<world>\olife_store\cas): GET /assets/<sha256 hex> on the packs HTTP port
    pub assets_dir: Option<String>,
    /// public play (16.10, olife_friends): the packs HTTP port binds 0.0.0.0 too (`--packs-public`); ServerInfo data
    /// (`--info file.json`: name, auth_port, auth_scheme, auth_pub, packs_port, public, whitelist, motd), re-read on
    /// every InfoRequest
    pub public: bool,
    pub packs_public: bool,
    pub info: Option<String>,
}

pub const USAGE: &str = "olife-gateway --listen <port> --upstream <host:port> [--public] [--name gw1] [--secret S]
  [--tokens tokens.json | --auth-url http://127.0.0.1:<p>] [--bans bans.json] [--f2f <ctl port>] [--admin <http port>]
  [--admin-token T] [--metrics file.json] [--log file.jsonl] [--threads N]
  [--max-sessions N] [--max-conns N] [--max-conns-per-ip N] [--conn-rate-ip R] [--rate-msgs R] [--burst-msgs B]
  [--rate-bytes R] [--burst-bytes B] [--out-queue-max BYTES] [--handshake-s S] [--keepalive-s S]
  [--keepalive-timeout-s S] [--flood-ban-s S] [--drain-s S]
  [--ticket-key key.json] [--gw-id ID] [--auth-mode tokens|tickets|both] [--ticket-cache N]
  [--packs-manifest manifest.json] [--packs-http <port>] [--packs-url http://host:port] [--assets-dir <cas dir>]
  [--public] [--packs-public] [--info server_info.json]   (public play: client / packs port on 0.0.0.0, ServerInfo)
olife-gateway --hash-token <token>      (sha256 for the token_sha256 table of the tokens file)";

pub fn argmap(argv: &[String]) -> (HashMap<String, String>, Vec<String>) {
    let (mut kv, mut flags) = (HashMap::new(), Vec::new());
    let mut i = 0;
    while i < argv.len() {
        let a = &argv[i];
        if let Some(k) = a.strip_prefix("--") {
            if i + 1 < argv.len() && !argv[i + 1].starts_with("--") {
                kv.insert(k.to_string(), argv[i + 1].clone());
                i += 2;
                continue;
            }
            flags.push(k.to_string());
        }
        i += 1;
    }
    (kv, flags)
}

fn num<T: std::str::FromStr>(kv: &HashMap<String, String>, k: &str, d: T) -> Result<T, String> {
    match kv.get(k).filter(|v| !v.is_empty()) {
        // the lab passes every flag, empty when unused: empty = absent
        None => Ok(d),
        Some(v) => v.parse().map_err(|_| format!("--{}: bad number {:?}", k, v)),
    }
}

fn secs(kv: &HashMap<String, String>, k: &str, d: Duration) -> Result<Duration, String> {
    let v: f64 = num(kv, k, d.as_secs_f64())?;
    if !(v >= 0.0 && v < 1e7) {
        return Err(format!("--{}: out of range", k));
    }
    Ok(Duration::from_secs_f64(v))
}

impl Config {
    pub fn parse(argv: &[String]) -> Result<Config, String> {
        let (kv, flags) = argmap(argv);
        let port: u16 = kv.get("listen").ok_or("--listen is required")?.parse().map_err(|_| "--listen: port")?;
        // `--public` as a flag or `--public 1` (the lab passes every flag with a value; "" / "0" = off)
        let on = |k: &str| flags.iter().any(|f| f == k) || kv.get(k).map_or(false, |v| !matches!(v.as_str(), "" | "0" | "false"));
        let public = on("public");
        let packs_public = on("packs-public");
        let host = if public { "0.0.0.0" } else { "127.0.0.1" };
        let d = Limits::default();
        let limits = Limits {
            max_c2s_frame: d.max_c2s_frame,
            handshake: secs(&kv, "handshake-s", d.handshake)?,
            keepalive_every: secs(&kv, "keepalive-s", d.keepalive_every)?,
            keepalive_timeout: secs(&kv, "keepalive-timeout-s", d.keepalive_timeout)?,
            rate_msgs: num(&kv, "rate-msgs", d.rate_msgs)?,
            burst_msgs: num(&kv, "burst-msgs", d.burst_msgs)?,
            rate_bytes: num(&kv, "rate-bytes", d.rate_bytes)?,
            burst_bytes: num(&kv, "burst-bytes", d.burst_bytes)?,
            flood_ban: secs(&kv, "flood-ban-s", d.flood_ban)?,
            out_queue_max: num(&kv, "out-queue-max", d.out_queue_max)?,
            write_stall: secs(&kv, "write-stall-s", d.write_stall)?,
            world_queue_max: num(&kv, "world-queue-max", d.world_queue_max)?,
            max_sessions: num(&kv, "max-sessions", d.max_sessions)?,
            max_conns: num(&kv, "max-conns", d.max_conns)?,
            max_conns_per_ip: num(&kv, "max-conns-per-ip", d.max_conns_per_ip)?,
            conn_rate_ip: num(&kv, "conn-rate-ip", d.conn_rate_ip)?,
            conn_burst_ip: num(&kv, "conn-burst-ip", d.conn_burst_ip)?,
            auth_fail_ip: num(&kv, "auth-fail-ip", d.auth_fail_ip)?,
            world_wait: secs(&kv, "world-wait-s", d.world_wait)?,
            drain: secs(&kv, "drain-s", d.drain)?,
        };
        let opt_port = |k: &str| -> Result<Option<u16>, String> {
            kv.get(k).map(|v| v.parse::<u16>().map_err(|_| format!("--{}: port", k))).transpose()
        };
        Ok(Config {
            listen: format!("{}:{}", host, port).parse().map_err(|e| format!("--listen: {}", e))?,
            upstream: kv.get("upstream").cloned().ok_or("--upstream host:port is required")?,
            name: kv.get("name").cloned().unwrap_or_else(|| "gw1".into()),
            secret: kv.get("secret").cloned().unwrap_or_default(),
            tokens: kv.get("tokens").cloned(),
            auth_url: kv.get("auth-url").cloned(),
            bans: kv.get("bans").cloned(),
            f2f: opt_port("f2f")?,
            admin: opt_port("admin")?,
            admin_token: kv.get("admin-token").cloned(),
            metrics: kv.get("metrics").cloned(),
            log: kv.get("log").cloned(),
            threads: num(&kv, "threads", 4usize)?.clamp(1, 64),
            limits,
            ticket_key: kv.get("ticket-key").cloned().filter(|s| !s.is_empty()),
            gw_id: kv.get("gw-id").cloned().filter(|s| !s.is_empty()),
            auth_mode: {
                let d = if kv.get("ticket-key").map_or(false, |s| !s.is_empty()) { "both" } else { "tokens" };
                let mut m = kv.get("auth-mode").cloned().filter(|s| !s.is_empty()).unwrap_or_else(|| d.into());
                if !matches!(m.as_str(), "tokens" | "tickets" | "both") {
                    return Err(format!("--auth-mode: tokens|tickets|both, not {:?}", m));
                }
                if d == "tokens" {
                    // no key: "both" degrades to static tokens; "tickets" alone could never admit anyone
                    if m == "tickets" {
                        return Err("--auth-mode tickets needs --ticket-key".into());
                    }
                    m = "tokens".into();
                }
                m
            },
            ticket_cache: num(&kv, "ticket-cache", 1_000_000usize)?.max(1),
            packs_manifest: kv.get("packs-manifest").cloned().filter(|s| !s.is_empty()),
            packs_http: match kv.get("packs-http").map(|s| s.as_str()) {
                None | Some("0") | Some("") => None,
                Some(v) => Some(v.parse::<u16>().map_err(|_| "--packs-http: port")?),
            },
            packs_url: kv.get("packs-url").cloned().filter(|s| !s.is_empty()),
            assets_dir: kv.get("assets-dir").cloned().filter(|s| !s.is_empty()),
            public,
            packs_public,
            info: kv.get("info").cloned().filter(|s| !s.is_empty()),
        })
    }
}
