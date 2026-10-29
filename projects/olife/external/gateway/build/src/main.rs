use olife_gateway::{admin, auth, bans::Bans, config::Config, gateway::Gateway, log::Log};
use std::time::Duration;

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.iter().any(|a| a == "--help" || a == "-h") || argv.is_empty() {
        println!("{}", olife_gateway::config::USAGE);
        return;
    }
    if let Some(i) = argv.iter().position(|a| a == "--hash-token") {
        let t = argv.get(i + 1).cloned().unwrap_or_default();
        println!("{}", auth::sha256_hex(&t));
        return;
    }
    let cfg = match Config::parse(&argv) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("olife-gateway: {}\n{}", e, olife_gateway::config::USAGE);
            std::process::exit(2);
        }
    };
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(cfg.threads).enable_all().build().expect("runtime");
    let code = rt.block_on(run(cfg));
    rt.shutdown_timeout(Duration::from_millis(200));
    std::process::exit(code);
}

async fn run(cfg: Config) -> i32 {
    let log = match Log::open(cfg.log.as_deref()) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("olife-gateway: --log: {}", e);
            return 2;
        }
    };
    let provider: Box<dyn auth::AuthProvider> = if let Some(u) = cfg.auth_url.as_ref().filter(|u| !u.is_empty()) {
        // supervisor first; the token file (if any) is the fallback when it does not answer
        let fb = cfg.tokens.as_deref().and_then(|p| auth::TokenFile::load(p).ok());
        match auth::HttpAuth::new(u, &cfg.name, fb) {
            Ok(a) => Box::new(a),
            Err(e) => {
                eprintln!("olife-gateway: {}", e);
                return 2;
            }
        }
    } else {
        let p = cfg.tokens.clone().unwrap_or_else(|| "gateway_tokens.json".into());
        match auth::TokenFile::load(&p) {
            Ok(t) => Box::new(t),
            // tickets only: static tokens are never consulted, a missing default token file is fine
            Err(_) if cfg.auth_mode == "tickets" && cfg.tokens.is_none() => Box::new(auth::NoTokens),
            Err(e) => {
                eprintln!("olife-gateway: {}", e);
                return 2;
            }
        }
    };
    let tickets = match &cfg.ticket_key {
        None => None,
        Some(kp) => match olife_gateway::ticket::load_key_file(kp) {
            Ok((k, file_gw)) => {
                let id = cfg.gw_id.clone().or(file_gw).unwrap_or_else(|| cfg.name.clone());
                Some(olife_gateway::ticket::Verifier::new(k, &id, cfg.ticket_cache))
            }
            Err(e) => {
                eprintln!("olife-gateway: {}", e);
                return 2;
            }
        },
    };
    let bans = Bans::new(cfg.bans.clone());
    let listen = cfg.listen;
    let (f2f, admin_port, metrics) = (cfg.f2f, cfg.admin, cfg.metrics.clone());
    let (packs_http, packs_manifest) = (cfg.packs_http, cfg.packs_manifest.is_some());
    let gw = Gateway::with_tickets(cfg, log, provider, bans, tickets);
    let l = match tokio::net::TcpListener::bind(listen).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("olife-gateway: listen {}: {}", listen, e);
            return 2;
        }
    };
    if let Some(p) = f2f {
        if let Err(e) = admin::ctl_serve(gw.clone(), p).await {
            eprintln!("olife-gateway: --f2f {}: {}", p, e);
            return 2;
        }
    }
    if let Some(p) = admin_port {
        if let Err(e) = admin::http_serve(gw.clone(), p).await {
            eprintln!("olife-gateway: --admin {}: {}", p, e);
            return 2;
        }
    }
    if packs_manifest {
        gw.check_manifest();
        tokio::spawn(gw.clone().packs_loop());
    }
    if let Some(p) = packs_http {
        if let Err(e) = olife_gateway::packs::http_serve(gw.clone(), p).await {
            eprintln!("olife-gateway: --packs-http {}: {}", p, e);
            return 2;
        }
    }
    if let Some(path) = metrics {
        let g = gw.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_millis(500)).await;
                let tmp = format!("{}.tmp", path);
                if std::fs::write(&tmp, g.metrics().to_string()).is_ok() {
                    let _ = std::fs::rename(&tmp, &path);
                }
            }
        });
    }
    tokio::spawn(gw.clone().world_loop());
    tokio::spawn(gw.clone().keepalive_loop());
    tokio::spawn(gw.clone().accept_loop(l));
    gw.log.line(&format!("ready listen={} upstream={} name={} auth={} auth_mode={} tickets={}", listen.port(), gw.cfg.upstream,
                         gw.cfg.name, gw.auth.describe(), gw.cfg.auth_mode, gw.tickets_json()["gw_id"]));
    let g = gw.clone();
    tokio::select! {
        _ = gw.exit.notified() => {}
        _ = tokio::signal::ctrl_c() => {
            let r = g.drain(g.cfg.limits.drain).await;
            g.log.line(&format!("interrupted, drained {}", r));
        }
    }
    gw.log.line("exit");
    0
}
