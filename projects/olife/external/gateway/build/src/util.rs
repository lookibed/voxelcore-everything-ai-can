//! Small shared pieces: token bucket, bounded sample ring + percentiles, clocks, randomness, process memory.
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64() * 1000.0).unwrap_or(0.0)
}

pub fn now_s() -> f64 {
    now_ms() / 1000.0
}

/// cryptographic randomness (keepalive challenges); falls back to time mixing only if the OS RNG fails
pub fn rand_u32() -> u32 {
    let mut b = [0u8; 4];
    if getrandom::getrandom(&mut b).is_err() {
        let t = now_ms().to_bits();
        return (t ^ (t >> 29) ^ (t >> 17)) as u32;
    }
    u32::from_be_bytes(b)
}

/// token bucket (same arithmetic as gateway_dev.py Bucket)
#[derive(Debug, Clone)]
pub struct Bucket {
    pub rate: f64,
    pub burst: f64,
    v: f64,
    t: Instant,
}

impl Bucket {
    pub fn new(rate: f64, burst: f64) -> Self {
        Bucket { rate, burst, v: burst, t: Instant::now() }
    }
    pub fn take(&mut self, n: f64) -> bool {
        let t = Instant::now();
        self.v = (self.v + t.duration_since(self.t).as_secs_f64() * self.rate).min(self.burst);
        self.t = t;
        if self.v < n {
            return false;
        }
        self.v -= n;
        true
    }
}

/// bounded ring of samples
#[derive(Debug, Default)]
pub struct Ring<T> {
    pub cap: usize,
    pub v: VecDeque<T>,
}

impl<T: Clone> Ring<T> {
    pub fn new(cap: usize) -> Self {
        Ring { cap, v: VecDeque::with_capacity(cap.min(1024)) }
    }
    pub fn push(&mut self, x: T) {
        if self.v.len() >= self.cap {
            self.v.pop_front();
        }
        self.v.push_back(x);
    }
    pub fn last(&self, n: usize) -> Vec<T> {
        let s = self.v.len().saturating_sub(n);
        self.v.iter().skip(s).cloned().collect()
    }
}

fn r3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

/// {n, min, p50, p95, max, mean} like gateway_dev.py stats(); None for no samples
pub fn stats(v: &[f64]) -> Value {
    if v.is_empty() {
        return Value::Null;
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let q = |p: f64| s[((p * (s.len() - 1) as f64 + 0.5) as usize).min(s.len() - 1)];
    json!({"n": s.len(), "min": r3(s[0]), "p50": r3(q(0.5)), "p95": r3(q(0.95)), "max": r3(s[s.len() - 1]),
           "mean": r3(s.iter().sum::<f64>() / s.len() as f64)})
}

/// resident memory of this process: (working set / RSS, peak) in bytes
#[cfg(windows)]
pub fn process_memory() -> (u64, u64) {
    #[repr(C)]
    #[allow(non_snake_case)]
    struct Pmc {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> isize;
        fn K32GetProcessMemoryInfo(p: isize, pmc: *mut Pmc, cb: u32) -> i32;
    }
    let mut m: Pmc = unsafe { std::mem::zeroed() };
    m.cb = std::mem::size_of::<Pmc>() as u32;
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut m, m.cb) };
    if ok == 0 {
        return (0, 0);
    }
    (m.WorkingSetSize as u64, m.PeakWorkingSetSize as u64)
}

#[cfg(not(windows))]
pub fn process_memory() -> (u64, u64) {
    let s = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let kb = |k: &str| {
        s.lines().find(|l| l.starts_with(k)).and_then(|l| l.split_whitespace().nth(1)).and_then(|x| x.parse::<u64>().ok())
    };
    (kb("VmRSS:").unwrap_or(0) * 1024, kb("VmHWM:").unwrap_or(0) * 1024)
}
