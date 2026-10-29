//! Gateway core: client connections (handshake, auth, bans, limits, keepalive), one multiplexed link to the world,
//! per-session counters, kick/ban/drain. Behaviour and Disconnect codes follow tools/olife/gateway_dev.py
//! (the reference); additions (connection limits, auth-failure bans, write stall, drain) are marked "rs:".
use crate::auth::{AuthCtx, AuthError, AuthProvider};
use crate::bans::Bans;
use crate::config::Config;
use crate::log::Log;
use crate::packs::{Check, Packs};
use crate::ticket::{Verdict, Verifier};
use crate::proto::{client as C, internal as I, wire};
use crate::util::{now_ms, now_s, rand_u32, stats, Bucket, Ring};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch, Notify};

/// Disconnect codes (tools/olife/README.md; identical to gateway_dev.py CODES; 13 is rs-only)
pub fn code_of(reason_code: &str) -> u16 {
    match reason_code {
        "shutdown" => 1,
        "handshake_timeout" => 2,
        "protocol" => 3,
        "auth" => 4,
        "banned" => 5,
        "keepalive" => 6,
        "flood" => 7,
        "timeout" => 8,
        "world_unavailable" => 9,
        "kicked" => 10,
        "slow_consumer" => 11,
        "duplicate" => 12,
        "limit" => 13, // rs: gateway full / too many connections from one IP / connection rate
        // wave 4b tickets (olife_ticket.CODES; a malformed ticket is "auth" = 4)
        "ticket_expired" => 14,
        "ticket_replayed" => 15,
        "ticket_bad_signature" => 16,
        "ticket_wrong_gateway" => 17,
        "nick_in_use" => 18, // antifraud 16.10: the account plays from another address
        "info" => 19,        // olife_friends 16.10: ServerInfo sent in answer to InfoRequest (not an error)
        _ => 3,        // "closed" etc. — as CODES.get(reason_code, 3) in gateway_dev.py
    }
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

pub enum Out {
    Frame(Vec<u8>),
    Shared(Arc<Vec<u8>>),
    Close,
}

impl Out {
    fn len(&self) -> usize {
        match self {
            Out::Frame(v) => v.len(),
            Out::Shared(v) => v.len(),
            Out::Close => 0,
        }
    }
}

struct Ka {
    challenge: Option<u32>,
    challenge_t: Instant,
    last_reply: Instant,
}

pub struct Conn {
    pub id: u64,
    pub ip: IpAddr,
    pub port: u16,
    pub sid: AtomicU32,
    ident: Mutex<Option<(String, String, String)>>, // name, account, engine
    tx: mpsc::UnboundedSender<Out>,
    pub out_bytes: AtomicUsize,
    pub up: AtomicU64,
    pub down: AtomicU64,
    pub up_msgs: AtomicU64,
    pub down_msgs: AtomicU64,
    closed: AtomicBool,
    aborted: AtomicBool,
    kill: Notify,
    abort: Notify,
    ka: Mutex<Ka>,
    rtt: Mutex<Ring<f64>>,
    started: Instant,
    /// the world's Welcome was delivered (PacksChanged may follow)
    welcomed: AtomicBool,
}

impl Conn {
    pub fn is_closed(&self) -> bool {
        self.closed.load(Relaxed)
    }
    fn name(&self) -> Option<String> {
        self.ident.lock().unwrap().as_ref().map(|x| x.0.clone())
    }
    fn account(&self) -> Option<String> {
        self.ident.lock().unwrap().as_ref().map(|x| x.1.clone())
    }
}

#[derive(Default)]
pub struct Counters {
    pub up_bytes: AtomicU64,
    pub down_bytes: AtomicU64,
    pub up_msgs: AtomicU64,
    pub down_msgs: AtomicU64,
    pub world_in: AtomicU64,
    pub world_out: AtomicU64,
    pub connections: AtomicU64,
    pub auth_ok: AtomicU64,
    pub world_connects: AtomicU64,
    pub multicasts: AtomicU64,
    pub world_frames: AtomicU64,
}

struct IpState {
    conns: usize,
    rate: Bucket,
    auth_fail: Bucket,
    last: Instant,
}

pub struct Gateway {
    pub cfg: Config,
    pub log: Log,
    pub auth: Box<dyn AuthProvider>,
    pub bans: Bans,
    pub sessions: Mutex<HashMap<u32, Arc<Conn>>>,
    conns: Mutex<HashMap<u64, Arc<Conn>>>,
    ips: Mutex<HashMap<IpAddr, IpState>>,
    next_sid: AtomicU32,
    next_conn: AtomicU64,
    world_tx: Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    world_q: AtomicUsize,
    world_ready: watch::Sender<bool>,
    world_info: Mutex<Value>,
    pub m: Counters,
    rejects: Mutex<BTreeMap<String, u64>>,
    events: Mutex<Ring<Value>>,
    rtt_all: Mutex<Ring<f64>>,
    sync_ms: Mutex<Ring<f64>>,
    errors: Mutex<Ring<Value>>,
    pub draining: AtomicBool,
    /// stage 6: the supervisor restarts the world -> sessions are closed with "world restarting ... reconnect"
    pub supervised: AtomicBool,
    pub world_note: Mutex<Option<String>>,
    pub stop_accept: Notify,
    pub exit: Notify,
    started: f64,
    /// wave 4b: ticket verifier (None = static tokens only) and pack manifest state
    pub tickets: Option<Mutex<Verifier>>,
    pub packs: Mutex<Packs>,
    /// UX A4: GET /assets/<sha> counters
    pub assets: Mutex<AssetStats>,
}

/// UX A4: store files served from --assets-dir
#[derive(Default, Clone)]
pub struct AssetStats {
    pub served: u64,
    pub bytes: u64,
    pub missing: u64,
    pub bad: u64,
}

impl Gateway {
    /// UX A4
    pub fn assets_stats<F: FnOnce(&mut AssetStats)>(&self, f: F) {
        f(&mut self.assets.lock().unwrap());
    }

    fn assets_json(&self) -> serde_json::Value {
        let a = self.assets.lock().unwrap().clone();
        json!({"served": a.served, "bytes": a.bytes, "missing": a.missing, "bad": a.bad,
               "dir": self.cfg.assets_dir.clone().unwrap_or_default()})
    }

    pub fn new(cfg: Config, log: Log, auth: Box<dyn AuthProvider>, bans: Bans) -> Arc<Gateway> {
        Self::with_tickets(cfg, log, auth, bans, None)
    }

    pub fn with_tickets(cfg: Config, log: Log, auth: Box<dyn AuthProvider>, bans: Bans, tickets: Option<Verifier>) -> Arc<Gateway> {
        let (ready, _) = watch::channel(false);
        let url = cfg.packs_url.clone()
            .or_else(|| cfg.packs_http.map(|p| format!("http://127.0.0.1:{}", p)))
            .unwrap_or_default();
        let packs = Mutex::new(Packs::new(cfg.packs_manifest.clone(), url));
        Arc::new(Gateway {
            tickets: tickets.map(Mutex::new),
            packs,
            assets: Mutex::new(AssetStats::default()),
            cfg,
            log,
            auth,
            bans,
            sessions: Mutex::new(HashMap::new()),
            conns: Mutex::new(HashMap::new()),
            ips: Mutex::new(HashMap::new()),
            next_sid: AtomicU32::new(0),
            next_conn: AtomicU64::new(0),
            world_tx: Mutex::new(None),
            world_q: AtomicUsize::new(0),
            world_ready: ready,
            world_info: Mutex::new(json!({})),
            m: Counters::default(),
            rejects: Mutex::new(BTreeMap::new()),
            events: Mutex::new(Ring::new(200)),
            rtt_all: Mutex::new(Ring::new(5000)),
            sync_ms: Mutex::new(Ring::new(20000)),
            errors: Mutex::new(Ring::new(20)),
            draining: AtomicBool::new(false),
            supervised: AtomicBool::new(false),
            world_note: Mutex::new(None),
            stop_accept: Notify::new(),
            exit: Notify::new(),
            started: now_s(),
        })
    }

    pub fn event(&self, kind: &str, fields: Value) {
        let level = match kind {
            "error" | "world_lost" => "warn",
            _ => "info",
        };
        if kind == "disconnect" || kind == "reject" {
            let r = fields.get("reason_code").and_then(|v| v.as_str()).unwrap_or("?").to_string();
            *self.rejects.lock().unwrap().entry(r).or_insert(0) += 1;
        }
        let mut ev = fields.clone();
        if let Value::Object(o) = &mut ev {
            o.insert("t".into(), json!((now_s() * 1000.0).round() / 1000.0));
            o.insert("kind".into(), json!(kind));
        }
        self.events.lock().unwrap().push(ev);
        self.log.event(level, kind, fields);
    }

    pub fn error(&self, what: &str, detail: String) {
        self.errors.lock().unwrap().push(json!({"t": now_s(), "what": what, "detail": detail}));
        self.event("error", json!({"what": what, "detail": detail}));
    }

    // ------------------------------------------------------------------------------ world link
    /// queue one internal frame to the world; false if there is no link or its queue is over the limit
    pub fn world_send_frame(&self, fr: Vec<u8>) -> bool {
        let g = self.world_tx.lock().unwrap();
        let Some(tx) = g.as_ref() else { return false };
        let n = fr.len();
        if self.world_q.load(Relaxed) + n > self.cfg.limits.world_queue_max {
            return false;
        }
        self.world_q.fetch_add(n, Relaxed);
        if tx.send(fr).is_err() {
            self.world_q.fetch_sub(n, Relaxed);
            return false;
        }
        true
    }

    pub fn world_send(&self, m: I::Msg) -> bool {
        match m.frame() {
            Ok(fr) => self.world_send_frame(fr),
            Err(e) => {
                self.error("encode", e.to_string());
                false
            }
        }
    }

    pub async fn world_loop(self: Arc<Self>) {
        let up = self.cfg.upstream.clone();
        loop {
            if self.draining.load(Relaxed) {
                return;
            }
            let s = match tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(&up)).await {
                Ok(Ok(s)) => s,
                Ok(Err(e)) => {
                    *self.world_info.lock().unwrap() = json!({"state": format!("connect failed: {}", e)});
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
                Err(_) => {
                    *self.world_info.lock().unwrap() = json!({"state": "connect failed: timeout"});
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
            };
            let _ = s.set_nodelay(true);
            let (mut rd, wr) = s.into_split();
            let (tx, rx) = mpsc::unbounded_channel::<Vec<u8>>();
            self.world_q.store(0, Relaxed);
            *self.world_tx.lock().unwrap() = Some(tx);
            self.m.world_connects.fetch_add(1, Relaxed);
            self.world_send(I::Msg::GatewayHello(I::GatewayHello {
                proto: I::VERSION as u16,
                gateway: self.cfg.name.clone(),
                secret: self.cfg.secret.clone(),
                client_proto: C::VERSION as u16,
            }));
            let mut wtask = tokio::spawn(world_writer(self.clone(), wr, rx));
            let mut fr = I::framer(None);
            let mut buf = vec![0u8; 262144];
            let why: String = loop {
                tokio::select! {
                    r = rd.read(&mut buf) => match r {
                        Ok(0) => break "closed".into(),
                        Err(e) => break format!("read: {}", e),
                        Ok(n) => {
                            self.m.world_in.fetch_add(n as u64, Relaxed);
                            fr.feed(&buf[..n]);
                            let mut err = None;
                            loop {
                                match fr.next_ref() {
                                    Ok(None) => break,
                                    Ok(Some((id, body))) => {
                                        self.m.world_frames.fetch_add(1, Relaxed);
                                        if let Err(e) = self.on_world(id, body) {
                                            err = Some(format!("ProtoError: {}", e));
                                            break;
                                        }
                                    }
                                    Err(e) => {
                                        err = Some(format!("ProtoError: {}", e));
                                        break;
                                    }
                                }
                            }
                            if let Some(e) = err {
                                break e;
                            }
                        }
                    },
                    _ = &mut wtask => break "write failed".into(),
                }
            };
            *self.world_tx.lock().unwrap() = None;
            wtask.abort();
            self.world_ready.send_replace(false);
            *self.world_info.lock().unwrap() = json!({"state": format!("lost: {}", why)});
            let sup = self.supervised.load(Relaxed);
            self.event("world_lost", json!({"why": why, "supervised": sup}));
            // same texts as gateway_dev.py: supervised clients (--reconnect) come back when the world is up again
            let reason = if sup {
                match self.world_note.lock().unwrap().as_deref() {
                    Some(n) => format!("world restarting (supervisor, {}): reconnect", n),
                    None => "world restarting (supervisor): reconnect".to_string(),
                }
            } else {
                "world connection lost".to_string()
            };
            let all: Vec<Arc<Conn>> = self.sessions.lock().unwrap().values().cloned().collect();
            for c in all {
                self.disconnect(&c, "world_unavailable", &reason, None, true);
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }

    /// one frame from the world. Data / Multicast are parsed in place (same strict rules as the generated decoder,
    /// payload copied once into the client frame); everything else goes through the generated codec.
    fn on_world(&self, id: u16, body: &[u8]) -> wire::R<()> {
        match id {
            I::ids::DATA => {
                let mut r = wire::Reader::new(body);
                let sid = r.u32("Data.session")?;
                let mtype = r.u16("Data.type")?;
                let n = r.u32("Data.payload")? as usize;
                if n > 1048576 {
                    return wire::fail("Data.payload", format!("bytes too long: {} > 1048576", n));
                }
                let p = r.p;
                if body.len() - p < n {
                    return wire::fail("Data.payload", "truncated");
                }
                r.p += n;
                r.finish("Data")?;
                let payload = &body[p..p + n];
                let c = self.sessions.lock().unwrap().get(&sid).cloned();
                if let Some(c) = c {
                    self.tick_sync(mtype, payload);
                    match C::frame_raw(mtype, payload) {
                        Ok(f) => self.deliver(&c, Out::Frame(f)),
                        Err(e) => self.error("world_data", e.to_string()),
                    }
                    if mtype == C::ids::WELCOME && !c.welcomed.swap(true, Relaxed) {
                        // wave 4b: the current pack manifest right after the world's Welcome
                        let msg = self.packs.lock().unwrap().message();
                        if let Some(m) = msg {
                            self.send(&c, C::Msg::PacksChanged(m));
                            self.packs.lock().unwrap().notified += 1;
                        }
                    }
                }
            }
            I::ids::MULTICAST => {
                let mut r = wire::Reader::new(body);
                let n = r.count(65535, "Multicast.sessions")?;
                let mut sids = Vec::with_capacity(n);
                for _ in 0..n {
                    sids.push(r.u32("Multicast.sessions[]")?);
                }
                let mtype = r.u16("Multicast.type")?;
                let pn = r.u32("Multicast.payload")? as usize;
                if pn > 1048576 {
                    return wire::fail("Multicast.payload", format!("bytes too long: {} > 1048576", pn));
                }
                let p = r.p;
                if body.len() - p < pn {
                    return wire::fail("Multicast.payload", "truncated");
                }
                r.p += pn;
                r.finish("Multicast")?;
                self.m.multicasts.fetch_add(1, Relaxed);
                let f = match C::frame_raw(mtype, &body[p..p + pn]) {
                    Ok(f) => Arc::new(f),
                    Err(e) => {
                        self.error("world_multicast", e.to_string());
                        return Ok(());
                    }
                };
                let targets: Vec<Arc<Conn>> = {
                    let s = self.sessions.lock().unwrap();
                    sids.iter().filter_map(|sid| s.get(sid).cloned()).collect()
                };
                for c in targets {
                    self.deliver(&c, Out::Shared(f.clone()));
                }
            }
            _ => match I::Msg::decode_body(id, body)? {
                I::Msg::WorldHello(h) => {
                    *self.world_info.lock().unwrap() = json!({"proto": h.proto, "world": h.world, "tick": h.tick,
                        "tps": h.tps, "client_proto": h.client_proto, "state": "ready"});
                    self.world_ready.send_replace(true);
                    self.event("world_ready", json!({"world": h.world, "tick": h.tick}));
                }
                I::Msg::Detach(d) => {
                    let c = self.sessions.lock().unwrap().get(&d.session).cloned();
                    if let Some(c) = c {
                        let code = if d.code != 0 { d.code } else { code_of("kicked") };
                        self.disconnect(&c, "kicked", &d.reason, Some(code), false);
                    }
                }
                I::Msg::Ping(p) => {
                    self.world_send(I::Msg::Pong(I::Pong { seq: p.seq, ms: p.ms }));
                }
                _ => {}
            },
        }
        Ok(())
    }

    fn tick_sync(&self, mtype: u16, payload: &[u8]) {
        if mtype == C::ids::TICK_SYNC {
            if let Ok(C::Msg::TickSync(t)) = C::Msg::decode_body(mtype, payload) {
                self.sync_ms.lock().unwrap().push(now_ms() - t.server_ms);
            }
        }
    }

    // ------------------------------------------------------------------------------ clients
    /// queue a frame to a client; over the queue limit -> Disconnect 11 (never blocks the caller)
    pub fn deliver(&self, c: &Arc<Conn>, f: Out) {
        if c.is_closed() {
            return;
        }
        let n = f.len();
        c.down.fetch_add(n as u64, Relaxed);
        c.down_msgs.fetch_add(1, Relaxed);
        self.m.down_bytes.fetch_add(n as u64, Relaxed);
        self.m.down_msgs.fetch_add(1, Relaxed);
        let q = c.out_bytes.fetch_add(n, Relaxed) + n;
        if q > self.cfg.limits.out_queue_max {
            self.disconnect(c, "slow_consumer", &format!("outbound queue over {} bytes", self.cfg.limits.out_queue_max), None, true);
            return;
        }
        if c.tx.send(f).is_err() {
            c.out_bytes.fetch_sub(n, Relaxed);
        }
    }

    pub fn send(&self, c: &Arc<Conn>, m: C::Msg) {
        match m.frame() {
            Ok(f) => self.deliver(c, Out::Frame(f)),
            Err(e) => self.error("encode", e.to_string()),
        }
    }

    /// close a connection with Disconnect{code, reason}: the frame is queued, the writer half-closes after it and
    /// the connection task drains the peer for up to 1 s (no RST eating the Disconnect), as gateway_dev.py does.
    pub fn disconnect(&self, c: &Arc<Conn>, reason_code: &str, reason: &str, code: Option<u16>, notify_world: bool) {
        if reason_code == "flood" {
            self.bans.temp_ban(c.ip, self.cfg.limits.flood_ban, "flood");
        }
        if c.closed.swap(true, Relaxed) {
            return;
        }
        let code = code.unwrap_or_else(|| code_of(reason_code));
        let reason = clip(reason, 250);
        if reason_code == "slow_consumer" {
            c.aborted.store(true, Relaxed);
            c.abort.notify_one();
        }
        if let Ok(f) = C::Msg::Disconnect(C::Disconnect { code, reason: reason.clone() }).frame() {
            let n = f.len();
            c.out_bytes.fetch_add(n, Relaxed);
            if c.tx.send(Out::Frame(f)).is_err() {
                c.out_bytes.fetch_sub(n, Relaxed);
            }
        }
        let _ = c.tx.send(Out::Close);
        c.kill.notify_one();
        let sid = c.sid.load(Relaxed);
        if sid != 0 {
            {
                let mut s = self.sessions.lock().unwrap();
                if s.get(&sid).map_or(false, |x| Arc::ptr_eq(x, c)) {
                    s.remove(&sid);
                }
            }
            if notify_world {
                self.world_send(I::Msg::Detach(I::Detach { session: sid, code, reason: reason.clone() }));
            }
        }
        self.event("disconnect", json!({"session": if sid != 0 { json!(sid) } else { Value::Null }, "name": c.name(),
            "ip": c.ip.to_string(), "reason_code": reason_code, "code": code, "reason": clip(&reason, 200)}));
    }

    pub async fn accept_loop(self: Arc<Self>, l: TcpListener) {
        loop {
            tokio::select! {
                _ = self.stop_accept.notified() => return,
                r = l.accept() => match r {
                    Ok((s, a)) => {
                        self.m.connections.fetch_add(1, Relaxed);
                        tokio::spawn(self.clone().serve(s, a));
                    }
                    Err(e) => {
                        self.error("accept", e.to_string());
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                }
            }
        }
    }

    /// rs: admission before the handshake — draining, gateway-wide connection cap, per-IP concurrency and rate
    fn admit(&self, ip: IpAddr) -> Result<(), (&'static str, String)> {
        if self.draining.load(Relaxed) {
            return Err(("shutdown", "gateway is draining".into()));
        }
        // antifraud: IP/CIDR ban before Hello, connections per subnet (supervisor cfg; exempt networks skip it)
        if let Some(why) = self.bans.ip_ban(&ip) {
            self.bans.count("ip_banned");
            return Err(("banned", why));
        }
        let fc = self.bans.fcfg();
        if fc.enabled && !self.bans.exempt(&ip) && !self.bans.net_take(&ip) {
            self.bans.note_limit(&ip, "conn_rate_net");
            return Err(("limit", format!("connection rate from the subnet of {} over {}/s", ip, fc.conn_rate_net)));
        }
        let lim = &self.cfg.limits;
        if self.conns.lock().unwrap().len() >= lim.max_conns {
            return Err(("limit", format!("gateway full ({} connections)", lim.max_conns)));
        }
        let mut ips = self.ips.lock().unwrap();
        let st = ips.entry(ip).or_insert_with(|| IpState {
            conns: 0,
            rate: Bucket::new(lim.conn_rate_ip, lim.conn_burst_ip),
            auth_fail: Bucket::new(lim.auth_fail_ip / 60.0, lim.auth_fail_ip),
            last: Instant::now(),
        });
        st.last = Instant::now();
        if st.conns >= lim.max_conns_per_ip {
            return Err(("limit", format!("too many connections from {} (max {})", ip, lim.max_conns_per_ip)));
        }
        if !st.rate.take(1.0) {
            return Err(("limit", format!("connection rate from {} over {}/s", ip, lim.conn_rate_ip)));
        }
        Ok(())
    }

    async fn serve(self: Arc<Self>, s: TcpStream, a: SocketAddr) {
        let _ = s.set_nodelay(true);
        let (rd, wr) = s.into_split();
        let (tx, rx) = mpsc::unbounded_channel();
        let now = Instant::now();
        let c = Arc::new(Conn {
            id: self.next_conn.fetch_add(1, Relaxed) + 1,
            ip: a.ip(),
            port: a.port(),
            sid: AtomicU32::new(0),
            ident: Mutex::new(None),
            tx,
            out_bytes: AtomicUsize::new(0),
            up: AtomicU64::new(0),
            down: AtomicU64::new(0),
            up_msgs: AtomicU64::new(0),
            down_msgs: AtomicU64::new(0),
            closed: AtomicBool::new(false),
            aborted: AtomicBool::new(false),
            kill: Notify::new(),
            abort: Notify::new(),
            ka: Mutex::new(Ka { challenge: None, challenge_t: now, last_reply: now }),
            rtt: Mutex::new(Ring::new(1000)),
            started: now,
            welcomed: AtomicBool::new(false),
        });
        let admitted = self.admit(c.ip);
        let ok = admitted.is_ok();
        if ok {
            self.ips.lock().unwrap().get_mut(&c.ip).map(|s| s.conns += 1);
        }
        self.conns.lock().unwrap().insert(c.id, c.clone());
        let w = tokio::spawn(writer(self.clone(), c.clone(), wr, rx));
        let mut rd = match admitted {
            Ok(()) => self.clone().reader(c.clone(), rd).await,
            Err((rc, why)) => {
                self.disconnect(&c, rc, &why, None, false);
                rd
            }
        };
        if !c.is_closed() {
            self.disconnect(&c, "closed", "connection ended", None, true);
        }
        let _ = w.await;
        // the writer half-closed after the Disconnect: read whatever the peer still sends (<= 1 s) before dropping,
        // otherwise unread input makes the OS reset the connection and the peer may lose the Disconnect frame
        let end = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut tmp = [0u8; 16384];
        while let Ok(Ok(n)) = tokio::time::timeout_at(end, rd.read(&mut tmp)).await {
            if n == 0 {
                break;
            }
        }
        drop(rd);
        self.conns.lock().unwrap().remove(&c.id);
        if ok {
            if let Some(s) = self.ips.lock().unwrap().get_mut(&c.ip) {
                s.conns = s.conns.saturating_sub(1);
            }
        }
    }

    async fn reader(self: Arc<Self>, c: Arc<Conn>, mut rd: OwnedReadHalf) -> OwnedReadHalf {
        let lim = self.cfg.limits.clone();
        let mut fr = C::framer(Some(lim.max_c2s_frame));
        let mut buf = vec![0u8; 65536];
        let t0 = tokio::time::Instant::now();
        let mut hello = true;
        let mut msgs = Bucket::new(lim.rate_msgs, lim.burst_msgs);
        let mut bytes = Bucket::new(lim.rate_bytes, lim.burst_bytes);
        if self.bans.temp_banned(&c.ip).is_some() {
            self.disconnect(&c, "banned", "temporarily banned (flood)", None, true);
            return rd;
        }
        let hs = lim.handshake.as_secs_f64();
        'outer: while !c.is_closed() {
            let r = if hello {
                tokio::select! {
                    _ = c.kill.notified() => break,
                    r = tokio::time::timeout_at(t0 + lim.handshake, rd.read(&mut buf)) => match r {
                        Err(_) => {
                            self.disconnect(&c, "handshake_timeout", &format!("no Hello within {:.0} s", hs), None, true);
                            break;
                        }
                        Ok(r) => r,
                    }
                }
            } else {
                tokio::select! {
                    _ = c.kill.notified() => break,
                    r = rd.read(&mut buf) => r,
                }
            };
            let n = match r {
                Ok(0) | Err(_) => {
                    if !c.is_closed() {
                        self.disconnect(&c, "closed", "client closed the connection", None, true);
                    }
                    break;
                }
                Ok(n) => n,
            };
            c.up.fetch_add(n as u64, Relaxed);
            self.m.up_bytes.fetch_add(n as u64, Relaxed);
            if !hello && !bytes.take(n as f64) {
                self.disconnect(&c, "flood", &format!("byte rate over {} B/s", lim.rate_bytes as u64), None, true);
                break;
            }
            fr.feed(&buf[..n]);
            while !c.is_closed() {
                let (mid, body) = match fr.next_ref() {
                    Err(e) => {
                        self.disconnect(&c, "protocol", &e.to_string(), None, true);
                        break 'outer;
                    }
                    Ok(None) => break,
                    Ok(Some((id, b))) => (id, b.to_vec()),
                };
                c.up_msgs.fetch_add(1, Relaxed);
                self.m.up_msgs.fetch_add(1, Relaxed);
                if !hello && !msgs.take(1.0) {
                    self.disconnect(&c, "flood", &format!("message rate over {}/s", lim.rate_msgs as u64), None, true);
                    break 'outer;
                }
                let m = match C::Msg::decode_body(mid, &body) {
                    Ok(m) => m,
                    Err(e) => {
                        self.disconnect(&c, "protocol", &e.to_string(), None, true);
                        break 'outer;
                    }
                };
                if C::dir_of(mid) != Some("c2s") {
                    self.disconnect(&c, "protocol", &format!("server message {} from a client", m.name()), None, true);
                    break 'outer;
                }
                if hello {
                    if self.on_hello(&c, m).await {
                        hello = false;
                    }
                } else {
                    self.on_play(&c, m, mid, body);
                }
            }
            if hello && t0.elapsed() > lim.handshake && !c.is_closed() {
                self.disconnect(&c, "handshake_timeout", &format!("no Hello within {:.0} s", hs), None, true);
                break;
            }
        }
        rd
    }

    fn auth_failed(&self, c: &Arc<Conn>) {
        // rs: repeated handshake failures from one IP -> temporary IP ban (the code of this attempt is unchanged)
        let mut ips = self.ips.lock().unwrap();
        if let Some(st) = ips.get_mut(&c.ip) {
            if !st.auth_fail.take(1.0) {
                drop(ips);
                self.bans.temp_ban(c.ip, self.cfg.limits.flood_ban, "auth failures");
                self.event("temp_ban", json!({"ip": c.ip.to_string(), "why": "auth failures"}));
            }
        }
    }

    /// handshake: Hello -> version, token, bans, name, world link, duplicate login, Attach. true = now playing
    async fn on_hello(&self, c: &Arc<Conn>, m: C::Msg) -> bool {
        let h = match m {
            C::Msg::Hello(h) => h,
            C::Msg::InfoRequest(q) => {
                // olife_friends 16.10: "what is this server?" before any auth -> ServerInfo, then Disconnect 19
                let si = self.server_info();
                self.event("server_info", json!({"ip": c.ip.to_string(), "proto": q.proto, "engine": clip(&q.engine, 16)}));
                self.send(c, C::Msg::ServerInfo(si));
                self.disconnect(c, "info", "server info sent", None, false);
                return false;
            }
            other => {
                self.disconnect(c, "protocol", &format!("first message must be Hello, got {}", other.name()), None, true);
                return false;
            }
        };
        if h.proto != C::VERSION as u16 {
            self.disconnect(c, "protocol", &format!("client proto {} != {}", h.proto, C::VERSION), None, true);
            return false;
        }
        let ctx = AuthCtx { ip: c.ip.to_string(), name: h.name.clone(), gateway: self.cfg.name.clone(), engine: h.engine.clone() };
        let ticket = self.tickets.is_some() && (h.token.starts_with(crate::ticket::PREFIX) || self.cfg.auth_mode == "tickets");
        let id = if ticket {
            // wave 4b: offline ticket verification (olife_ticket.py), never the supervisor's /auth
            if !h.token.starts_with(crate::ticket::PREFIX) {
                self.auth_failed(c);
                self.disconnect(c, "auth", "static tokens disabled (use a ticket)", None, true);
                return false;
            }
            let (v, acct) = self.tickets.as_ref().unwrap().lock().unwrap().verify(&h.token, now_s());
            match (v, acct) {
                (Verdict::Ok, Some(a)) => crate::auth::Identity { account: a, perms: 0 },
                (v, _) => {
                    let rc = match v {
                        Verdict::Busy => "limit",
                        Verdict::Expired => "ticket_expired",
                        Verdict::Replayed => "ticket_replayed",
                        Verdict::BadSignature => "ticket_bad_signature",
                        Verdict::WrongGateway => "ticket_wrong_gateway",
                        _ => "auth",
                    };
                    if v != Verdict::Busy {
                        self.auth_failed(c);
                    }
                    self.disconnect(c, rc, v.reason(), Some(v.code()), true);
                    return false;
                }
            }
        } else {
            match self.auth.authenticate(&h.token, &ctx).await {
                Ok(id) => id,
                Err(AuthError::BadToken) => {
                    self.auth_failed(c);
                    self.disconnect(c, "auth", "bad token", None, true);
                    return false;
                }
                Err(AuthError::Denied { code, reason }) => {
                    let rc = if code == "banned" { "banned" } else { "auth" };
                    if rc == "auth" {
                        self.auth_failed(c);
                    }
                    self.disconnect(c, rc, &reason, None, true);
                    return false;
                }
                Err(AuthError::Unavailable(e)) => {
                    self.error("auth", e.clone());
                    self.disconnect(c, "auth", &format!("auth unavailable: {}", e), None, true);
                    return false;
                }
            }
        };
        self.bans.reload();
        if self.bans.account_banned(Some(&id.account)) {
            self.disconnect(c, "banned", "banned", None, true);
            return false;
        }
        if let Some(why) = self.bans.ip_ban(&c.ip) {
            self.disconnect(c, "banned", &why, None, true);
            return false;
        }
        let nm = h.name.clone();
        // antifraud: ASCII names only (homoglyph names like "аdmin" are refused), as gateway_dev.py
        if nm.is_empty() || nm.chars().any(|ch| !(ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' || ch == '.')) {
            self.auth_failed(c);
            self.disconnect(c, "auth", "bad name", None, true);
            return false;
        }
        if c.is_closed() {
            return false;
        }
        let mut rx = self.world_ready.subscribe();
        let ready = tokio::time::timeout(self.cfg.limits.world_wait, rx.wait_for(|v| *v)).await;
        if !matches!(ready, Ok(Ok(_))) {
            self.disconnect(c, "world_unavailable", "world is not connected", None, true);
            return false;
        }
        if c.is_closed() {
            return false;
        }
        let (sid, dup) = {
            let mut s = self.sessions.lock().unwrap();
            if s.len() >= self.cfg.limits.max_sessions {
                drop(s);
                self.disconnect(c, "limit", &format!("gateway full ({} sessions)", self.cfg.limits.max_sessions), None, true);
                return false;
            }
            let dup = s.values().find(|x| x.name().as_deref() == Some(&nm) && x.account().as_deref() == Some(&id.account)).cloned();
            // antifraud: the account already plays from ANOTHER address -> refuse the new login (18); same address:
            // the old session is replaced (12) as before. Sessions per IP (supervisor cfg) -> 13.
            if s.values().any(|x| x.account().as_deref() == Some(&id.account) && x.ip != c.ip) {
                drop(s);
                self.bans.count("nick_in_use");
                self.disconnect(c, "nick_in_use", &format!("{} is already playing from another address", id.account), None, true);
                return false;
            }
            let fc = self.bans.fcfg();
            let same_ip = s.values().filter(|x| x.ip == c.ip && !(x.name().as_deref() == Some(&nm) && x.account().as_deref() == Some(&id.account))).count();
            if fc.enabled && fc.sessions_per_ip > 0 && same_ip >= fc.sessions_per_ip && !self.bans.exempt(&c.ip) {
                drop(s);
                self.bans.note_limit(&c.ip, "sessions_ip");
                self.disconnect(c, "limit", &format!("too many sessions from {} (max {})", c.ip, fc.sessions_per_ip), None, true);
                return false;
            }
            let sid = self.next_sid.fetch_add(1, Relaxed) + 1;
            c.sid.store(sid, Relaxed);
            *c.ident.lock().unwrap() = Some((nm.clone(), id.account.clone(), h.engine.clone()));
            s.insert(sid, c.clone());
            (sid, dup)
        };
        self.m.auth_ok.fetch_add(1, Relaxed);
        if let Some(d) = dup {
            self.disconnect(&d, "duplicate", "logged in from another connection", None, true);
        }
        {
            let mut k = c.ka.lock().unwrap();
            k.last_reply = Instant::now();
        }
        self.world_send(I::Msg::Attach(I::Attach {
            session: sid,
            account: clip(&id.account, 64),
            name: nm.clone(),
            addr: format!("{}:{}", c.ip, c.port),
            perms: id.perms,
        }));
        self.event("attach", json!({"session": sid, "name": nm, "account": id.account, "ip": c.ip.to_string(), "engine": h.engine,
                                    "auth": if ticket { "ticket" } else { "token" }}));
        true
    }

    fn on_play(&self, c: &Arc<Conn>, m: C::Msg, mid: u16, body: Vec<u8>) {
        let sid = c.sid.load(Relaxed);
        match m {
            C::Msg::KeepAliveReply(r) => {
                let rtt = {
                    let mut k = c.ka.lock().unwrap();
                    if k.challenge != Some(r.challenge) {
                        None
                    } else {
                        let t = Instant::now();
                        let rtt = t.duration_since(k.challenge_t).as_secs_f64() * 1000.0;
                        k.challenge = None;
                        k.last_reply = t;
                        Some(rtt)
                    }
                };
                match rtt {
                    None => self.disconnect(c, "keepalive", "wrong keepalive challenge", None, true),
                    Some(rtt) => {
                        c.rtt.lock().unwrap().push(rtt);
                        self.rtt_all.lock().unwrap().push(rtt);
                    }
                }
            }
            C::Msg::Hello(_) => self.disconnect(c, "protocol", "second Hello", None, true),
            C::Msg::Bye(b) => {
                self.world_send_frame(data_frame(sid, mid, &body));
                self.disconnect(c, "closed", &format!("bye: {}", b.reason), None, false);
            }
            _ => {
                if !self.world_send_frame(data_frame(sid, mid, &body)) {
                    self.disconnect(c, "world_unavailable", "world is not connected", None, true);
                }
            }
        }
    }

    /// every keepalive period: re-read bans, time out silent sessions, send a new challenge (gateway_dev.py loop)
    pub async fn keepalive_loop(self: Arc<Self>) {
        let lim = self.cfg.limits.clone();
        let mut iv = tokio::time::interval(lim.keepalive_every);
        iv.tick().await;
        loop {
            iv.tick().await;
            self.bans.reload();
            if let Some(h) = self.auth.as_http() {
                // antifraud: olife.gw_sync (sessions + limit events up; IP bans with reasons + cfg down); a plugin
                // without it -> stage 6 GET /bans. Not answering -> keep the last lists. Banned sessions are dropped.
                let all: Vec<Arc<Conn>> = self.sessions.lock().unwrap().values().cloned().collect();
                let sess: Vec<Value> = all.iter().filter_map(|c| {
                    let i = c.ident.lock().unwrap().clone()?;
                    Some(json!([i.1, crate::bans::canon(&c.ip).to_string(), i.0]))
                }).collect();
                let ev = self.bans.take_events();
                let gw_id = self.tickets.as_ref().map(|t| t.lock().unwrap().gw_id.clone());
                let got = match h.sync(json!({"gateway": self.cfg.name, "gw_id": gw_id, "sessions": sess, "events": ev})).await {
                    Ok(v) => {
                        self.bans.apply_sync(&v);
                        true
                    }
                    Err(e) => {
                        self.bans.restore_events(&ev);
                        self.bans.sync_failed(e);
                        match h.bans().await {
                            Some((a, i)) => {
                                self.bans.set_supervisor(a, i);
                                true
                            }
                            None => false,
                        }
                    }
                };
                if got {
                    for c in all {
                        if self.bans.account_banned(c.account().as_deref()) {
                            self.disconnect(&c, "banned", "banned by operator", None, true);
                        } else if let Some(why) = self.bans.ip_ban(&c.ip) {
                            self.disconnect(&c, "banned", &why, None, true);
                        }
                    }
                }
            }
            let all: Vec<Arc<Conn>> = self.sessions.lock().unwrap().values().cloned().collect();
            let t = Instant::now();
            for c in all {
                if c.is_closed() {
                    continue;
                }
                let send = {
                    let mut k = c.ka.lock().unwrap();
                    if k.challenge.is_some() && t.duration_since(k.last_reply) > lim.keepalive_timeout {
                        None
                    } else if k.challenge.is_none() {
                        let ch = rand_u32();
                        k.challenge = Some(ch);
                        k.challenge_t = t;
                        Some(Some(ch))
                    } else {
                        Some(None)
                    }
                };
                match send {
                    None => self.disconnect(&c, "keepalive", "keepalive timeout", None, true),
                    Some(Some(ch)) => self.send(&c, C::Msg::KeepAlive(C::KeepAlive { challenge: ch, server_ms: now_ms() })),
                    Some(None) => {}
                }
            }
            // forget idle per-IP state
            let now = Instant::now();
            self.ips.lock().unwrap().retain(|_, s| s.conns > 0 || now.duration_since(s.last) < Duration::from_secs(120));
        }
    }

    // ------------------------------------------------------------------------------ admin
    pub fn session_info(&self, c: &Arc<Conn>) -> Value {
        let ident = c.ident.lock().unwrap().clone();
        let rtt = c.rtt.lock().unwrap().last(200);
        json!({"name": ident.as_ref().map(|x| x.0.clone()), "account": ident.as_ref().map(|x| x.1.clone()),
               "engine": ident.as_ref().map(|x| x.2.clone()), "ip": c.ip.to_string(), "port": c.port,
               "up": c.up.load(Relaxed), "down": c.down.load(Relaxed), "up_msgs": c.up_msgs.load(Relaxed),
               "down_msgs": c.down_msgs.load(Relaxed), "out_queue": c.out_bytes.load(Relaxed),
               "age_s": (c.started.elapsed().as_secs_f64() * 10.0).round() / 10.0, "rtt_ms": stats(&rtt)})
    }

    pub fn sessions_json(&self) -> Value {
        let s: Vec<(u32, Arc<Conn>)> = self.sessions.lock().unwrap().iter().map(|(k, v)| (*k, v.clone())).collect();
        let mut m = serde_json::Map::new();
        for (sid, c) in s {
            m.insert(sid.to_string(), self.session_info(&c));
        }
        Value::Object(m)
    }

    /// same shape as gateway_dev.py metrics() (the lab plugin reads total/conns/rtt_ms/world_to_gateway_ms/rejects)
    pub fn metrics(&self) -> Value {
        let sess = self.sessions_json();
        let m = &self.m;
        let (rss, peak) = crate::util::process_memory();
        let rtt = self.rtt_all.lock().unwrap().last(2000);
        let sync = self.sync_ms.lock().unwrap().last(5000);
        let lim = &self.cfg.limits;
        let mut out = json!({
            "impl": "olife-gateway-rs", "version": env!("CARGO_PKG_VERSION"), "name": self.cfg.name,
            "uptime_s": ((now_s() - self.started) * 100.0).round() / 100.0,
            "world": self.world_info.lock().unwrap().clone(),
            "total": {"up": m.up_bytes.load(Relaxed), "down": m.down_bytes.load(Relaxed),
                      "up_msgs": m.up_msgs.load(Relaxed), "down_msgs": m.down_msgs.load(Relaxed),
                      "world_in": m.world_in.load(Relaxed), "world_out": m.world_out.load(Relaxed),
                      "world_frames": m.world_frames.load(Relaxed), "multicasts": m.multicasts.load(Relaxed)},
            "sessions": sess.clone(), "conns": sess,
            "open_connections": self.conns.lock().unwrap().len(),
            "connections": m.connections.load(Relaxed), "auth_ok": m.auth_ok.load(Relaxed),
            "world_connects": m.world_connects.load(Relaxed), "world_queue": self.world_q.load(Relaxed),
            "rejects": self.rejects.lock().unwrap().clone(),
            "rtt_ms": stats(&rtt), "world_to_gateway_ms": stats(&sync),
            "events": self.events.lock().unwrap().last(30), "errors": self.errors.lock().unwrap().last(20),
            "temp_bans": self.bans.temp_snapshot(), "bans": self.bans.snapshot(), "auth": self.auth.describe(),
            "process": {"rss": rss, "peak_rss": peak, "pid": std::process::id()},
            "draining": self.draining.load(Relaxed), "supervised": self.supervised.load(Relaxed),
            "world_note": self.world_note.lock().unwrap().clone(),
            "tickets": self.tickets_json(), "packs": self.packs.lock().unwrap().metrics(),
            "limits": {"max_c2s_frame": lim.max_c2s_frame, "rate_msgs": lim.rate_msgs, "burst_msgs": lim.burst_msgs,
                       "rate_bytes": lim.rate_bytes, "burst_bytes": lim.burst_bytes, "out_queue_max": lim.out_queue_max,
                       "max_sessions": lim.max_sessions, "max_conns": lim.max_conns,
                       "max_conns_per_ip": lim.max_conns_per_ip, "conn_rate_ip": lim.conn_rate_ip,
                       "handshake_s": lim.handshake.as_secs_f64(), "keepalive_s": lim.keepalive_every.as_secs_f64(),
                       "keepalive_timeout_s": lim.keepalive_timeout.as_secs_f64()},
        });
        if let Some(o) = out.as_object_mut() {
            o.insert("assets".into(), self.assets_json());      // UX A4 (outside json!: macro recursion limit)
            o.insert("antifraud".into(), self.bans.fraud_json());   // antifraud 16.10
        }
        out
    }

    /// tickets: {ok, malformed, expired, replayed, bad_signature, wrong_gateway, busy, cache_size, mode, gw_id}
    /// ServerInfo (olife_friends): `--info` file (re-read every time: the lab may rewrite it) + what the gateway knows
    pub fn server_info(&self) -> C::ServerInfo {
        let v: Value = self.cfg.info.as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(Value::Null);
        let st = |k: &str, n: usize| clip(v.get(k).and_then(|x| x.as_str()).unwrap_or(""), n);
        let port = |k: &str| v.get(k).and_then(|x| x.as_u64()).filter(|p| *p <= 65535).map(|p| p as u16);
        let gw_id = match &self.tickets {
            Some(t) => t.lock().unwrap().gw_id.clone(),
            None => self.cfg.gw_id.clone().unwrap_or_else(|| self.cfg.name.clone()),
        };
        let scheme = st("auth_scheme", 8);
        C::ServerInfo {
            proto: C::VERSION as u16,
            name: if st("name", 64).is_empty() { clip(&self.cfg.name, 64) } else { st("name", 64) },
            gw_id: clip(&gw_id, 64),
            auth_port: port("auth_port").unwrap_or(0),
            auth_scheme: if scheme.is_empty() { "https".into() } else { scheme },
            auth_pub: st("auth_pub", 64),
            packs_port: port("packs_port").or(self.cfg.packs_http).unwrap_or(0),
            public: v.get("public").and_then(|x| x.as_bool()).unwrap_or(self.cfg.public),
            whitelist: v.get("whitelist").and_then(|x| x.as_bool()).unwrap_or(false),
            motd: st("motd", 256),
        }
    }

    pub fn tickets_json(&self) -> Value {
        match &self.tickets {
            None => json!({"mode": self.cfg.auth_mode, "gw_id": Value::Null, "ok": 0, "malformed": 0, "expired": 0,
                           "replayed": 0, "bad_signature": 0, "wrong_gateway": 0, "busy": 0, "cache_size": 0}),
            Some(v) => {
                let v = v.lock().unwrap();
                let c = &v.counts;
                json!({"mode": self.cfg.auth_mode, "gw_id": v.gw_id, "gw_hash": v.gw, "ok": c.ok, "malformed": c.malformed,
                       "expired": c.expired, "replayed": c.replayed, "bad_signature": c.bad_signature,
                       "wrong_gateway": c.wrong_gateway, "busy": c.busy, "cache_size": v.cache.len(), "cache_cap": v.cache.cap})
            }
        }
    }

    /// wave 4b: re-read the pack manifest (content SHA-256); on a change notify every session that got its Welcome
    pub fn check_manifest(&self) {
        let (r, msg, ev) = {
            let mut p = self.packs.lock().unwrap();
            let r = p.check();
            let ev = json!({"version": p.version, "manifest": p.manifest_version, "files": p.files.len()});
            (r, p.message(), ev)
        };
        match r {
            Ok(Check::Unchanged) => {}
            Ok(Check::Loaded) => self.event("manifest_loaded", ev),
            Ok(Check::Changed) => {
                let mut n = 0u64;
                if let Some(m) = msg {
                    let all: Vec<Arc<Conn>> = self.sessions.lock().unwrap().values().cloned().collect();
                    for c in all.iter().filter(|c| c.welcomed.load(Relaxed) && !c.is_closed()) {
                        self.send(c, C::Msg::PacksChanged(m.clone()));
                        n += 1;
                    }
                    self.packs.lock().unwrap().notified += n;
                }
                let mut ev = ev;
                ev["notified"] = json!(n);
                self.event("manifest_changed", ev);
            }
            Err(e) => self.error("manifest", e),
        }
    }

    /// every second: the manifest watcher (only with --packs-manifest)
    pub async fn packs_loop(self: Arc<Self>) {
        let mut iv = tokio::time::interval(Duration::from_secs(1));
        loop {
            iv.tick().await;
            if self.draining.load(Relaxed) {
                return;
            }
            self.check_manifest();
        }
    }

    pub fn world_status(&self, a: &Value) -> Value {
        if let Some(v) = a.get("supervised") {
            self.supervised.store(v.as_bool().unwrap_or(false), Relaxed);
        }
        if let Some(v) = a.get("note") {
            *self.world_note.lock().unwrap() = v.as_str().filter(|s| !s.is_empty()).map(String::from);
        }
        json!({"supervised": self.supervised.load(Relaxed), "note": self.world_note.lock().unwrap().clone(),
               "world": self.world_info.lock().unwrap().clone(), "world_ready": *self.world_ready.borrow()})
    }

    pub fn kick(&self, sid: u32, reason: Option<&str>) -> Result<Value, String> {
        let c = self.sessions.lock().unwrap().get(&sid).cloned().ok_or(format!("no session {}", sid))?;
        self.disconnect(&c, "kicked", reason.unwrap_or("kicked by operator"), None, true);
        Ok(json!({"kicked": sid}))
    }

    /// antifraud: kick every connection (sessions and handshakes) from the networks (lab F2F `kick_ip`)
    pub fn kick_ip(&self, nets: &[String], reason: &str, code: u16) -> Value {
        let nets: Vec<crate::bans::Net> = nets.iter().filter_map(|x| crate::bans::Net::parse(x)).collect();
        let all: Vec<Arc<Conn>> = self.conns.lock().unwrap().values().cloned().collect();
        let mut n = 0;
        for c in all {
            if !c.is_closed() && nets.iter().any(|x| x.contains(&c.ip)) {
                self.disconnect(&c, "banned", reason, Some(code), true);
                n += 1;
            }
        }
        self.event("kick_ip", json!({"nets": nets.iter().map(|x| x.key()).collect::<Vec<_>>(), "kicked": n}));
        json!({"kicked": n})
    }

    pub fn ban(&self, account: Option<&str>, ip: Option<&str>) -> Result<Value, String> {
        if account.is_none() && ip.is_none() {
            return Err("ban: account or ip".into());
        }
        let bans = self.bans.add(account, ip)?;
        let all: Vec<Arc<Conn>> = self.sessions.lock().unwrap().values().cloned().collect();
        let mut n = 0;
        for c in all {
            if self.bans.is_banned(c.account().as_deref(), &c.ip) {
                self.disconnect(&c, "banned", "banned", None, true);
                n += 1;
            }
        }
        self.event("ban", json!({"account": account, "ip": ip, "disconnected": n}));
        Ok(json!({"bans": bans, "disconnected": n}))
    }

    /// graceful drain: stop accepting, Disconnect 1 to everyone (Detach to the world), wait for the writers and the
    /// world queue to flush (<= budget). Returns a summary; the caller exits the process.
    pub async fn drain(&self, budget: Duration) -> Value {
        let t0 = Instant::now();
        if self.draining.swap(true, Relaxed) {
            return json!({"draining": true, "already": true});
        }
        self.stop_accept.notify_one();
        let all: Vec<Arc<Conn>> = self.conns.lock().unwrap().values().cloned().collect();
        let n = all.len();
        for c in &all {
            self.disconnect(c, "shutdown", "gateway shutdown", None, true);
        }
        let end = Instant::now() + budget;
        while Instant::now() < end {
            let open = self.conns.lock().unwrap().values().filter(|c| c.out_bytes.load(Relaxed) > 0).count();
            if open == 0 && self.world_q.load(Relaxed) == 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let left = self.conns.lock().unwrap().values().filter(|c| c.out_bytes.load(Relaxed) > 0).count();
        let v = json!({"drained": n, "unflushed": left, "world_queue": self.world_q.load(Relaxed),
                       "ms": (t0.elapsed().as_secs_f64() * 1000.0).round()});
        self.event("drain", v.clone());
        v
    }
}

/// internal Data{session, type, payload} frame built in one buffer (equal to the generated encoder; see tests)
pub fn data_frame(sid: u32, mid: u16, body: &[u8]) -> Vec<u8> {
    let n = 4 + 2 + 4 + body.len();
    let mut f = Vec::with_capacity(wire::HEADER + n);
    f.extend_from_slice(&wire::header(I::MAGIC, I::VERSION, I::ids::DATA, n as u32));
    f.extend_from_slice(&sid.to_be_bytes());
    f.extend_from_slice(&mid.to_be_bytes());
    f.extend_from_slice(&(body.len() as u32).to_be_bytes());
    f.extend_from_slice(body);
    f
}

async fn world_writer(gw: Arc<Gateway>, mut wr: OwnedWriteHalf, mut rx: mpsc::UnboundedReceiver<Vec<u8>>) {
    let mut buf: Vec<u8> = Vec::with_capacity(1 << 20);
    while let Some(f) = rx.recv().await {
        gw.world_q.fetch_sub(f.len(), Relaxed);
        buf.extend_from_slice(&f);
        while buf.len() < (1 << 20) {
            match rx.try_recv() {
                Ok(f) => {
                    gw.world_q.fetch_sub(f.len(), Relaxed);
                    buf.extend_from_slice(&f);
                }
                Err(_) => break,
            }
        }
        if let Err(e) = wr.write_all(&buf).await {
            gw.error("world_write", e.to_string());
            return;
        }
        gw.m.world_out.fetch_add(buf.len() as u64, Relaxed);
        buf.clear();
    }
}

/// per-client writer: coalesces queued frames into one write (<= 256 KiB), a write stalled longer than
/// `write_stall` = slow consumer; abort (slow consumer) drops the backlog and tries the Disconnect frame for 200 ms
async fn writer(gw: Arc<Gateway>, c: Arc<Conn>, mut wr: OwnedWriteHalf, mut rx: mpsc::UnboundedReceiver<Out>) {
    let stall = gw.cfg.limits.write_stall;
    let mut buf: Vec<u8> = Vec::with_capacity(65536);
    'run: loop {
        let first = tokio::select! {
            biased;
            _ = c.abort.notified() => break 'run,
            m = rx.recv() => m,
        };
        let Some(first) = first else { break };
        let mut closing = false;
        let take = |m: Out, buf: &mut Vec<u8>| -> bool {
            match m {
                Out::Frame(v) => {
                    c.out_bytes.fetch_sub(v.len(), Relaxed);
                    buf.extend_from_slice(&v);
                    false
                }
                Out::Shared(v) => {
                    c.out_bytes.fetch_sub(v.len(), Relaxed);
                    buf.extend_from_slice(&v);
                    false
                }
                Out::Close => true,
            }
        };
        closing |= take(first, &mut buf);
        while !closing && buf.len() < 262144 {
            match rx.try_recv() {
                Ok(m) => closing |= take(m, &mut buf),
                Err(_) => break,
            }
        }
        if !buf.is_empty() {
            let r = tokio::select! {
                biased;
                _ = c.abort.notified() => break 'run,
                r = tokio::time::timeout(stall, wr.write_all(&buf)) => r,
            };
            match r {
                Err(_) => {
                    gw.disconnect(&c, "slow_consumer", &format!("write stalled over {:.0} s", stall.as_secs_f64()), None, true);
                    c.aborted.store(true, Relaxed);
                    break 'run;
                }
                Ok(Err(e)) => {
                    gw.disconnect(&c, "closed", &format!("write error: {}", e), None, true);
                    break 'run;
                }
                Ok(Ok(())) => {}
            }
            buf.clear();
        }
        if closing {
            break;
        }
    }
    if c.aborted.load(Relaxed) {
        // backlog dropped: the Disconnect is the last frame before Close in the queue
        let mut last = None;
        while let Ok(m) = rx.try_recv() {
            match m {
                Out::Close => break,
                Out::Frame(v) => {
                    c.out_bytes.fetch_sub(v.len(), Relaxed);
                    last = Some(v)
                }
                Out::Shared(v) => {
                    c.out_bytes.fetch_sub(v.len(), Relaxed);
                }
            }
        }
        if let Some(v) = last {
            let _ = tokio::time::timeout(Duration::from_millis(200), wr.write_all(&v)).await;
        }
    }
    // remaining queue (connection gone): release its byte count
    rx.close();
    while let Ok(m) = rx.try_recv() {
        c.out_bytes.fetch_sub(m.len(), Relaxed);
    }
    let _ = tokio::time::timeout(Duration::from_millis(500), wr.shutdown()).await;
}
