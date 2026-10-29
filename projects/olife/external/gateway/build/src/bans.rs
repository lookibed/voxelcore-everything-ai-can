//! Bans: accounts / IPs from a JSON file (gateway_dev.py format `{"accounts": [...], "ips": [...]}`, re-read on
//! mtime change, written by /ban), plus temporary IP bans (flood, repeated auth failures) in memory.
//! Antifraud (16.10, olife_antifraud; VC agents/research/OLIFE_ANTIFRAUD.md): IP bans are addresses or CIDR (file and
//! supervisor), the supervisor sync (`olife.gw_sync`) brings them with until/reason plus the limits cfg (sessions per
//! IP, connections per subnet, exempt networks); refusals of these limits are queued as events for the next sync.
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Instant, SystemTime};
use crate::util::{now_s, Bucket};

/// an IP network (address + prefix); IPv4-mapped IPv6 addresses are matched as IPv4
#[derive(Debug, Clone, PartialEq)]
pub struct Net {
    pub addr: IpAddr,
    pub prefix: u8,
}

pub fn canon(ip: &IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(*ip),
        _ => *ip,
    }
}

impl Net {
    pub fn parse(s: &str) -> Option<Net> {
        let s = s.trim();
        let (a, p) = match s.split_once('/') {
            Some((a, p)) => (a, Some(p.parse::<u8>().ok()?)),
            None => (s, None),
        };
        let addr = canon(&a.parse::<IpAddr>().ok()?);
        let max = if addr.is_ipv4() { 32 } else { 128 };
        let prefix = p.unwrap_or(max);
        if prefix > max {
            return None;
        }
        Some(Net { addr, prefix })
    }
    pub fn of(ip: &IpAddr, prefix: u8) -> Net {
        Net { addr: canon(ip), prefix }
    }
    fn bits(ip: &IpAddr) -> (u128, u8) {
        match ip {
            IpAddr::V4(v) => (u32::from(*v) as u128, 32),
            IpAddr::V6(v) => (u128::from(*v), 128),
        }
    }
    pub fn contains(&self, ip: &IpAddr) -> bool {
        let ip = canon(ip);
        if ip.is_ipv4() != self.addr.is_ipv4() {
            return false;
        }
        let (a, w) = Self::bits(&self.addr);
        let (b, _) = Self::bits(&ip);
        let p = self.prefix.min(w) as u32;
        if p == 0 {
            return true;
        }
        let shift = w as u32 - p;
        (a >> shift) == (b >> shift)
    }
    /// canonical text: the network address (host bits cleared) + "/prefix" (a single address: no prefix)
    pub fn key(&self) -> String {
        let (a, w) = Self::bits(&self.addr);
        if self.prefix == w {
            return self.addr.to_string();
        }
        let shift = (w - self.prefix) as u32;
        let n = if shift >= 128 { 0 } else { (a >> shift) << shift };
        let ip: IpAddr = if w == 32 { IpAddr::V4((n as u32).into()) } else { IpAddr::V6(n.into()) };
        format!("{}/{}", ip, self.prefix)
    }
}

/// limits cfg from the supervisor (defaults = olife_fraud.py DEFAULTS)
#[derive(Debug, Clone)]
pub struct FraudCfg {
    pub enabled: bool,
    pub sessions_per_ip: usize,
    pub conn_rate_net: f64,
    pub net_prefix: u8,
    pub net_prefix6: u8,
    pub exempt: Vec<Net>,
}

impl Default for FraudCfg {
    fn default() -> Self {
        FraudCfg { enabled: true, sessions_per_ip: 3, conn_rate_net: 60.0, net_prefix: 24, net_prefix6: 64,
                   exempt: vec![Net::parse("127.0.0.1/32").unwrap()] }
    }
}

#[derive(Default)]
pub struct Fraud {
    pub cfg: FraudCfg,
    /// supervisor IP bans: (net, text as in the DB, until unix s, reason)
    pub nets: Vec<(Net, String, Option<f64>, String)>,
    pub net_buckets: HashMap<String, Bucket>,
    pub events: HashMap<(String, String), u64>,
    pub counts: HashMap<String, u64>,
    pub sync_ok: Option<bool>,
    pub sync_err: Option<String>,
}

#[derive(Default)]
struct St {
    mtime: Option<SystemTime>,
    accounts: HashSet<String>,
    ips: HashSet<String>,
    raw: Value,
}

pub struct Bans {
    pub path: Option<String>,
    st: Mutex<St>,
    /// lists from the supervisor DB (stage 6 `GET /bans`), checked together with the file
    sup: Mutex<(HashSet<String>, HashSet<String>)>,
    temp: Mutex<HashMap<IpAddr, (Instant, String)>>,
    pub fraud: Mutex<Fraud>,
}

impl Bans {
    pub fn new(path: Option<String>) -> Bans {
        let b = Bans { path, st: Mutex::new(St::default()), sup: Mutex::new(Default::default()), temp: Mutex::new(HashMap::new()),
                       fraud: Mutex::new(Fraud::default()) };
        b.reload();
        b
    }

    pub fn reload(&self) {
        let Some(p) = &self.path else { return };
        let mt = std::fs::metadata(p).and_then(|m| m.modified()).ok();
        let mut st = self.st.lock().unwrap();
        if mt.is_some() && mt == st.mtime {
            return;
        }
        st.mtime = mt;
        let v: Value = std::fs::read_to_string(p).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(json!({}));
        let list = |k: &str| -> HashSet<String> {
            v.get(k).and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect())
                .unwrap_or_default()
        };
        st.accounts = list("accounts");
        st.ips = list("ips");
        st.raw = v;
    }

    pub fn is_banned(&self, account: Option<&str>, ip: &IpAddr) -> bool {
        self.account_banned(account) || self.ip_ban(ip).is_some()
    }

    pub fn account_banned(&self, account: Option<&str>) -> bool {
        let Some(a) = account else { return false };
        if self.st.lock().unwrap().accounts.contains(a) {
            return true;
        }
        self.sup.lock().unwrap().0.contains(a)
    }

    /// antifraud: the reason text of an IP/CIDR ban covering `ip` (supervisor sync with until/reason, the old
    /// supervisor list, the file) | None
    pub fn ip_ban(&self, ip: &IpAddr) -> Option<String> {
        let now = now_s();
        for (n, text, until, why) in self.fraud.lock().unwrap().nets.iter() {
            if n.contains(ip) && until.map_or(true, |u| u > now) {
                let until = match until {
                    Some(u) => fmt_time(*u),
                    None => "permanent".into(),
                };
                return Some(format!("banned by IP {} until {}: {}", text, until, why));
            }
        }
        let hit = |l: &HashSet<String>| l.iter().find(|x| Net::parse(x).map_or(false, |n| n.contains(ip))).cloned();
        if let Some(x) = hit(&self.st.lock().unwrap().ips) {
            return Some(format!("banned by IP {}", x));
        }
        if let Some(x) = hit(&self.sup.lock().unwrap().1) {
            return Some(format!("banned by IP {}", x));
        }
        None
    }

    pub fn exempt(&self, ip: &IpAddr) -> bool {
        self.fraud.lock().unwrap().cfg.exempt.iter().any(|n| n.contains(ip))
    }

    pub fn fcfg(&self) -> FraudCfg {
        self.fraud.lock().unwrap().cfg.clone()
    }

    pub fn count(&self, k: &str) {
        *self.fraud.lock().unwrap().counts.entry(k.to_string()).or_insert(0) += 1;
    }

    /// a refusal of a supervisor limit (reported to the supervisor at the next sync; it autobans)
    pub fn note_limit(&self, ip: &IpAddr, kind: &str) {
        let mut f = self.fraud.lock().unwrap();
        *f.events.entry((canon(ip).to_string(), kind.to_string())).or_insert(0) += 1;
        *f.counts.entry(format!("limit_{}", kind)).or_insert(0) += 1;
    }

    /// new connection from the subnet of `ip` (bucket conn_rate_net, burst x3); false = over the rate
    pub fn net_take(&self, ip: &IpAddr) -> bool {
        let mut f = self.fraud.lock().unwrap();
        let ip = canon(ip);
        let pfx = if ip.is_ipv4() { f.cfg.net_prefix } else { f.cfg.net_prefix6 };
        let key = Net::of(&ip, pfx).key();
        let rate = f.cfg.conn_rate_net.max(0.1);
        let b = f.net_buckets.entry(key).or_insert_with(|| Bucket::new(rate, rate * 3.0));
        if b.rate != rate {
            *b = Bucket::new(rate, rate * 3.0);
        }
        let ok = b.take(1.0);
        if f.net_buckets.len() > 10000 {
            f.net_buckets.clear();
        }
        ok
    }

    pub fn take_events(&self) -> Vec<Value> {
        let mut f = self.fraud.lock().unwrap();
        f.events.drain().map(|((ip, kind), n)| json!({"ip": ip, "kind": kind, "n": n})).collect()
    }

    pub fn restore_events(&self, ev: &[Value]) {
        let mut f = self.fraud.lock().unwrap();
        for e in ev {
            if let (Some(ip), Some(k)) = (e["ip"].as_str(), e["kind"].as_str()) {
                *f.events.entry((ip.to_string(), k.to_string())).or_insert(0) += e["n"].as_u64().unwrap_or(1);
            }
        }
    }

    /// apply the reply of olife.gw_sync {accounts, ips: [{net, until, reason}], cfg}
    pub fn apply_sync(&self, v: &Value) {
        let accounts: Vec<String> = v["accounts"].as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let mut nets = Vec::new();
        for b in v["ips"].as_array().cloned().unwrap_or_default() {
            if let Some(n) = b["net"].as_str().and_then(Net::parse) {
                nets.push((n, b["net"].as_str().unwrap_or("").to_string(), b["until"].as_f64(),
                           b["reason"].as_str().unwrap_or("").to_string()));
            }
        }
        *self.sup.lock().unwrap() = (accounts.into_iter().collect(), HashSet::new());
        let mut f = self.fraud.lock().unwrap();
        f.nets = nets;
        let c = &v["cfg"];
        if c.is_object() {
            let d = FraudCfg::default();
            f.cfg = FraudCfg {
                enabled: c["enabled"].as_i64().map_or(d.enabled, |x| x != 0),
                sessions_per_ip: c["sessions_per_ip"].as_u64().map_or(d.sessions_per_ip, |x| x as usize),
                conn_rate_net: c["conn_rate_net"].as_f64().unwrap_or(d.conn_rate_net),
                net_prefix: c["net_prefix"].as_u64().map_or(d.net_prefix, |x| x.min(32) as u8),
                net_prefix6: c["net_prefix6"].as_u64().map_or(d.net_prefix6, |x| x.min(128) as u8),
                exempt: c["exempt"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().and_then(Net::parse)).collect())
                    .unwrap_or(d.exempt),
            };
        }
        f.sync_ok = Some(true);
        f.sync_err = None;
        *f.counts.entry("sync".into()).or_insert(0) += 1;
    }

    /// lab/supervisor push (F2F kick_ip {ban}): IP bans into the list before the next sync replaces it
    pub fn add_nets(&self, v: &[Value]) {
        let mut f = self.fraud.lock().unwrap();
        for b in v {
            if let Some(n) = b["net"].as_str().and_then(Net::parse) {
                let text = b["net"].as_str().unwrap_or("").to_string();
                if !f.nets.iter().any(|x| x.1 == text) {
                    f.nets.push((n, text, b["until"].as_f64(), b["reason"].as_str().unwrap_or("").to_string()));
                }
            }
        }
    }

    pub fn sync_failed(&self, e: String) {
        let mut f = self.fraud.lock().unwrap();
        f.sync_ok = Some(false);
        f.sync_err = Some(e);
        *f.counts.entry("sync_error".into()).or_insert(0) += 1;
    }

    pub fn fraud_json(&self) -> Value {
        let f = self.fraud.lock().unwrap();
        json!({"counts": f.counts, "sync_ok": f.sync_ok, "sync_err": f.sync_err,
               "cfg": {"enabled": f.cfg.enabled, "sessions_per_ip": f.cfg.sessions_per_ip, "conn_rate_net": f.cfg.conn_rate_net,
                       "net_prefix": f.cfg.net_prefix, "net_prefix6": f.cfg.net_prefix6,
                       "exempt": f.cfg.exempt.iter().map(|n| n.key()).collect::<Vec<_>>()},
               "ip_bans": f.nets.iter().map(|(_, t, u, r)| json!([t, u, r])).collect::<Vec<_>>(),
               "pending_events": f.events.len()})
    }

    pub fn set_supervisor(&self, accounts: Vec<String>, ips: Vec<String>) {
        *self.sup.lock().unwrap() = (accounts.into_iter().collect(), ips.into_iter().collect());
    }

    /// add to the file (kept as gateway_dev.py does: append to the lists, then reload)
    pub fn add(&self, account: Option<&str>, ip: Option<&str>) -> Result<Value, String> {
        let p = self.path.clone().ok_or("no --bans file")?;
        let mut v: Value = std::fs::read_to_string(&p).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(json!({}));
        if !v.is_object() {
            v = json!({});
        }
        for (k, x) in [("accounts", account), ("ips", ip)] {
            if let Some(x) = x {
                let a = v.as_object_mut().unwrap().entry(k).or_insert(json!([]));
                if !a.is_array() {
                    *a = json!([]);
                }
                a.as_array_mut().unwrap().push(Value::from(x));
            }
        }
        let tmp = format!("{}.tmp", p);
        std::fs::write(&tmp, serde_json::to_string_pretty(&v).unwrap()).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &p).map_err(|e| e.to_string())?;
        self.st.lock().unwrap().mtime = None;
        self.reload();
        Ok(self.snapshot())
    }

    pub fn snapshot(&self) -> Value {
        let st = self.st.lock().unwrap();
        let mut a: Vec<_> = st.accounts.iter().cloned().collect();
        let mut i: Vec<_> = st.ips.iter().cloned().collect();
        a.sort();
        i.sort();
        let sup = self.sup.lock().unwrap();
        let mut sa: Vec<_> = sup.0.iter().cloned().collect();
        let mut si: Vec<_> = sup.1.iter().cloned().collect();
        sa.sort();
        si.sort();
        json!({"accounts": a, "ips": i, "supervisor": {"accounts": sa, "ips": si}})
    }

    pub fn temp_ban(&self, ip: IpAddr, dur: std::time::Duration, why: &str) {
        self.temp.lock().unwrap().insert(ip, (Instant::now() + dur, why.to_string()));
    }

    pub fn temp_banned(&self, ip: &IpAddr) -> Option<String> {
        let mut t = self.temp.lock().unwrap();
        match t.get(ip) {
            Some((until, why)) if *until > Instant::now() => Some(why.clone()),
            Some(_) => {
                t.remove(ip);
                None
            }
            None => None,
        }
    }

    pub fn temp_snapshot(&self) -> Value {
        let now = Instant::now();
        let mut t = self.temp.lock().unwrap();
        t.retain(|_, (u, _)| *u > now);
        let mut m = serde_json::Map::new();
        for (ip, (u, _)) in t.iter() {
            m.insert(ip.to_string(), Value::from(((u.duration_since(now).as_secs_f64()) * 10.0).round() / 10.0));
        }
        Value::Object(m)
    }
}

/// local time "YYYY-MM-DD HH:MM:SS" is not available without a time crate: UTC with the suffix
pub fn fmt_time(t: f64) -> String {
    let secs = t.max(0.0) as i64;
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    // civil from days (Howard Hinnant)
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02} UTC", y, m, d, rem / 3600, rem % 3600 / 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nets() {
        let n = Net::parse("127.0.0.70/26").unwrap();
        assert_eq!(n.key(), "127.0.0.64/26");
        assert!(n.contains(&"127.0.0.64".parse().unwrap()) && n.contains(&"127.0.0.127".parse().unwrap()));
        assert!(!n.contains(&"127.0.0.128".parse().unwrap()) && !n.contains(&"127.0.0.1".parse().unwrap()));
        assert!(Net::parse("127.0.0.2").unwrap().contains(&"::ffff:127.0.0.2".parse().unwrap()));
        assert_eq!(Net::parse("127.0.0.2").unwrap().key(), "127.0.0.2");
        assert!(Net::parse("2001:db8::/32").unwrap().contains(&"2001:db8:1::5".parse().unwrap()));
        assert!(Net::parse("0.0.0.0/0").unwrap().contains(&"10.1.2.3".parse().unwrap()));
        assert!(Net::parse("1.2.3.4/33").is_none() && Net::parse("x").is_none());
        assert_eq!(fmt_time(0.0), "1970-01-01 00:00:00 UTC");
        assert_eq!(fmt_time(1792138475.0), "2026-10-16 08:14:35 UTC");
    }
}
