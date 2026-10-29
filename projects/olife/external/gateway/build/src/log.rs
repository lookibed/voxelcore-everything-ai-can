//! Structured logs: every event is one stdout line `[olife_gateway] <kind> <json>` (the lab waits for
//! `[olife_gateway] ready`, as with gateway_dev.py) and one JSON line in `--log` {ts, level, event, ...fields}.
use serde_json::{Map, Value};
use std::fs::File;
use std::io::Write;
use std::sync::Mutex;

pub struct Log {
    file: Mutex<Option<std::io::BufWriter<File>>>,
    pub stdout: bool,
}

impl Log {
    pub fn open(path: Option<&str>) -> std::io::Result<Log> {
        let file = match path {
            Some(p) => Some(std::io::BufWriter::new(std::fs::OpenOptions::new().create(true).append(true).open(p)?)),
            None => None,
        };
        Ok(Log { file: Mutex::new(file), stdout: true })
    }

    pub fn event(&self, level: &str, kind: &str, fields: Value) {
        if self.stdout {
            let mut o = std::io::stdout().lock();
            let _ = writeln!(o, "[olife_gateway] {} {}", kind, fields);
            let _ = o.flush();
        }
        let mut g = self.file.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(f) = g.as_mut() {
            let mut m = Map::new();
            m.insert("ts".into(), Value::from((crate::util::now_ms()).round() / 1000.0));
            m.insert("level".into(), Value::from(level));
            m.insert("event".into(), Value::from(kind));
            if let Value::Object(o) = fields {
                for (k, v) in o {
                    m.insert(k, v);
                }
            }
            let _ = writeln!(f, "{}", Value::Object(m));
            let _ = f.flush();
        }
    }

    /// plain line (startup banner) on stdout, also logged
    pub fn line(&self, text: &str) {
        println!("[olife_gateway] {}", text);
        let mut g = self.file.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(f) = g.as_mut() {
            let _ = writeln!(f, "{}", serde_json::json!({"ts": crate::util::now_s(), "level": "info", "event": "line", "text": text}));
            let _ = f.flush();
        }
    }
}
