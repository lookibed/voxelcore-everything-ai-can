//! stdin: lines "<contract> <id> <hex body>" -> stdout: "ok <re-encoded hex>" | "err <message>" (fuzz parity with Python)
use olife_gateway::proto::{client, internal, sandbox, wire};
use std::io::{BufRead, Write};

fn main() {
    let out = std::io::stdout();
    let mut o = std::io::BufWriter::new(out.lock());
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let mut p = line.split(' ');
        let (c, id, hx) = (p.next().unwrap(), p.next().unwrap().parse::<u16>().unwrap(), p.next().unwrap_or(""));
        let b = wire::unhex(hx).unwrap();
        let r = match c {
            "client" => client::Msg::decode_body(id, &b).and_then(|m| m.body()),
            "internal" => internal::Msg::decode_body(id, &b).and_then(|m| m.body()),
            _ => sandbox::Msg::decode_body(id, &b).and_then(|m| m.body()),
        };
        match r {
            Ok(x) => writeln!(o, "ok {}", wire::hex(&x)).unwrap(),
            Err(e) => writeln!(o, "err {}", e).unwrap(),
        }
    }
}
