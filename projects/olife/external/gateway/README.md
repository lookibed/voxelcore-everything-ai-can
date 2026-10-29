# olife-gateway — production gateway `sockets_auth` of Olife (Rust, tokio)

The only entry point of players (OLIFE_ARCHITECTURE §1, §5): handshake and token auth, bans, rate limits, keepalive
with a challenge, one multiplexed connection to the world (`internal` contract, sessions in `Data{session, type,
payload}`, `Multicast` fan-out), per-session counters, admin endpoints, graceful drain. Behaviour, texts and
`Disconnect` codes follow the reference `tools/olife/gateway_dev.py` (VC_ROOT); the codecs are **generated** from the
same schema as the Lua and Python ones (`tools/olife/protocol/*.yaml`, `gen_codecs.py --lang rust`).

Sources: `/root/olife/gateway` (local git repo, nothing committed). Binary: `D:\Prog\Olife\gateway\olife-gateway.exe`
(native MSVC build, `tools/win_build.sh`). Lab: project `olife`, kind `gateway_rs`, `lab run olife <scenario> --impl rs`.

## Run
```
olife-gateway --listen <port> --upstream 127.0.0.1:<world port> [--public] [--name gw1] [--secret S]
    [--tokens tokens.json | --auth-url http://127.0.0.1:<lab>/sup] [--bans bans.json]
    [--f2f <control port>] [--admin <http port>] [--admin-token T] [--metrics m.json] [--log gw.jsonl] [--threads 4]
    [--max-sessions 1000] [--max-conns 4096] [--max-conns-per-ip 64] [--conn-rate-ip 20] [--conn-burst-ip 60]
    [--rate-msgs 60] [--burst-msgs 120] [--rate-bytes 65536] [--burst-bytes 262144] [--out-queue-max 16777216]
    [--handshake-s 5] [--keepalive-s 2] [--keepalive-timeout-s 10] [--flood-ban-s 30] [--write-stall-s 15] [--drain-s 1.5]
    [--ticket-key key.json] [--gw-id ID] [--auth-mode tokens|tickets|both] [--ticket-cache 1000000]
    [--packs-manifest manifest.json] [--packs-http <port>] [--packs-url http://host:port]
    [--public] [--packs-public] [--info server_info.json]
olife-gateway --hash-token <token>     # sha256 for the "token_sha256" table
```
The client port binds 127.0.0.1 unless `--public` (0.0.0.0); the packs port — unless `--packs-public`. Admin and control
ports are always 127.0.0.1. Both flags also take a value (`--public 1`, `--public 0`/`""` = off), as the lab passes them.

## Public play: InfoRequest -> ServerInfo (16.10, olife_friends; VC_ROOT `agents/research/OLIFE_PUBLIC_PLAY.md`)
A friend knows only `ip:port`. The client may send `client.InfoRequest{proto, engine}` (id 7) as the FIRST frame instead of
`Hello`; the gateway answers `client.ServerInfo{proto, name, gw_id, auth_port, auth_scheme, auth_pub, packs_port, public,
whitelist, motd}` (id 76) and closes with Disconnect **19** "server info sent" (event `server_info`). Fields come from the
`--info` JSON file (re-read on every request: `name, auth_port, auth_scheme, auth_pub, packs_port, public, whitelist,
motd`) and from the gateway itself (gw_id of the ticket key / `--gw-id`, `--packs-http` port, `--public`). Admission (IP
bans, connection limits) applies as for `Hello`. Code: `Gateway::server_info`, `on_hello`; test
`tests/gateway.rs::public_flags_and_server_info`. The lab's public play stack: kind `gateway_rs_public` (fixed ports
`[play.public]` 27750 client / 27752 packs).
An empty flag value (`--ticket-key ""`, as the lab passes unused params) is the same as an absent flag.

## Tickets (wave 4b; spec = VC_ROOT `tools/olife/olife_ticket.py`, same flags in gateway_dev.py)
`Hello.token` may carry a short-lived one-time ticket `"T1." + base64url(ver|exp|nonce 12|gw u32|alen|account|tag 16)`,
tag = HMAC-SHA256(K_gw, "olife-ticket-v1" + body)[..16], K_gw = HMAC-SHA256(master, "olife-gw-key-v1|" + gateway id).
The gateway holds only K_gw (`--ticket-key`: 64 hex chars or `{"key": hex, "gateway": id}`); audience id = `--gw-id`, else
the file's `gateway`, else `--name`. Verified offline (never `/sup/auth`), then the usual bans (file + supervisor list),
name check, duplicate policy, `Attach{account from the ticket, perms 0}`.
`--auth-mode`: `both` (default with a key: tokens starting `T1.` are tickets, others static), `tickets` (static token ->
4 "static tokens disabled (use a ticket)"), `tokens` (default without a key). Nonce cache: map + expiry queue until
exp + 2 s, cap `--ticket-cache` (full -> 13 "ticket cache full"). Code `src/ticket.rs`.

| check (in this order) | Disconnect |
|---|---|
| malformed (prefix, base64 as Python's non-validating decoder, length, ver, alen 1..55, UTF-8) | 4 "bad ticket" |
| gw hash != SHA-256(gateway id)[..4] | 17 "ticket for another gateway" |
| tag (constant-time) | 16 "bad ticket signature" |
| now > exp + 2 or exp > now + 60 + 2 | 14 "ticket expired" |
| nonce already used | 15 "ticket replayed" |

## Pack hot reload (wave 4b)
`--packs-manifest` (written by the lab supervisor: `{version, root, packs: {name: {side, files: [{path, sha256, size,
side}]}}}`) is re-read every 1 s by content SHA-256. `client.PacksChanged{version: manifest "version", url, files: count of
client|both files}` goes to a session right after the world's `Welcome` (if a manifest is loaded) and to every session
in play when the manifest changes (latency = the 1 s poll: 0.26–1.0 s measured). `--packs-http <port>`: `GET
/manifest.json` (raw file), `GET /files/<pack>/<path>` only for listed client|both files, SHA-256 re-checked (409 if the
file changed since the manifest). `--packs-url` = advertised base url (default `http://127.0.0.1:<packs-http>`).
Logs `manifest_loaded` / `manifest_changed`. Code `src/packs.rs`.

## Behaviour (= gateway_dev.py unless marked rs)
| what | rule | Disconnect |
|---|---|---|
| framing | `magic|version|type|len`, header checked before the body; client body <= 64 KiB; unknown type; strict body decode; direction must be c2s | 3 |
| handshake | first frame `Hello` within 5 s; `proto` = 1 | 2 / 3 |
| auth | token -> account (file: digests only in memory; supervisor: `GET <url>/auth?token_sha=&ip=&gateway=`, fallback to the file) | 4 |
| tickets | see "Tickets" above | 4, 14–17, 13 |
| info (olife_friends) | `InfoRequest` as the first frame -> `ServerInfo`, then close | 19 |
| bans | account / IP from the file (re-read on change) + supervisor `GET <url>/bans` every 2 s (banned sessions dropped) | 5 |
| name | non-empty, alphanumeric or `_-` | 4 |
| world | waits <= 5 s for the world link | 9 |
| duplicate | same name + account -> the old session is closed | 12 |
| rate | per session 60 msgs/s (burst 120), 64 KiB/s (burst 256 KiB) -> IP temp-banned 30 s | 7, then 5 |
| keepalive | `KeepAlive{challenge}` every 2 s (CSPRNG, rs), wrong answer or 10 s silence | 6 |
| slow client | send queue > 16 MiB or one write stalled > 15 s (rs) -> dropped, backlog discarded, never blocks the world | 11 |
| limits (rs) | connections per IP (64 at once, 20/s, burst 60), per gateway (4096), sessions (1000); 20 failed handshakes/min per IP -> 30 s IP ban | 13 |
| kick | world `Detach` (code from the world, else 10); operator `/kick` | 10 |
| drain (rs) | quit / Ctrl+C / `POST /drain`: stop accepting, Disconnect 1 to all, Detach to the world, flush <= 1.5 s, exit | 1 |
Closing = Disconnect frame, half-close, drain the peer <= 1 s (no RST eating the frame). Client `Bye` -> Disconnect 3 "bye: ...".
World link: one TCP connection, `GatewayHello{secret}`, reconnect every 1 s; lost -> all sessions 9 ("world restarting
(supervisor...)" when `world_status{supervised}` was set by the supervisor).

## Operator surfaces
- Admin HTTP (`--admin`, 127.0.0.1, optional `X-Admin-Token`): `GET /status` (= metrics), `GET /sessions`, `GET /health`,
  `POST /kick {session, reason?}`, `POST /ban {account?|ip?}`, `POST /drain {budget_s?}`.
- Lab control port (`--f2f`, JSON lines like `ctlport.py`): `hello` (flags input/window none), `metrics`, `sessions`,
  `world_status {supervised?, note?}`, `kick`, `ban`, `drain`, `quit`.
- Metrics (same shape as gateway_dev.py + more): totals up/down bytes and messages, per session counters (bytes/packets
  in/out, out queue, RTT), keepalive RTT, world->gateway TickSync delay, rejects by reason, events, process memory,
  limits, auth provider state, `tickets: {ok, malformed, expired, replayed, bad_signature, wrong_gateway, busy, cache_size,
  mode, gw_id}`, `packs: {version (loads), manifest_version, files, served, notified, url, sha}`. `--metrics file` every 0.5 s.
- Logs: stdout `[olife_gateway] <event> <json>`; `--log file` JSON lines `{ts, level, event, ...}` (attach, disconnect
  with reason_code/code, world_ready/world_lost, ban, drain, admin, errors).

## Code
| file | what |
|---|---|
| `src/proto/*` | GENERATED: `wire.rs` (runtime: Reader, writers, Framer with header checks), `client.rs`, `internal.rs`, `sandbox.rs` (typed structs + `Msg` enum per contract, serde for JSON vectors), `vectors/*.json` (copy) |
| `src/gateway.rs` | sessions, reader/writer tasks, handshake, limits, keepalive, world link, kick/ban/drain, metrics |
| `src/auth.rs` | `AuthProvider` trait; `TokenFile` (digests), `HttpAuth` (supervisor stage 6 contract + cache + file fallback) |
| `src/bans.rs` | file bans (mtime reload), supervisor lists, temporary IP bans |
| `src/ticket.rs` | tickets: HMAC-SHA256, key derivation, Python-compatible base64url, parse/mint, nonce cache, `Verifier` |
| `src/packs.rs` | pack manifest state (SHA-256 watch), `PacksChanged`, packs HTTP server |
| `src/admin.rs` | admin HTTP + lab control port |
| `src/config.rs`, `src/log.rs`, `src/util.rs` | flags/limits, structured logs, buckets/rings/stats/process memory |
| `tests/codecs.rs` | 204 generated vectors byte-for-byte, strict decode, framer errors, byte-by-byte feed, 30 000-mutation fuzz |
| `tests/gateway.rs` | Data frame = generated encoder, codes = gateway_dev.py, token file hashing, supervisor contract, buckets |
| `tests/tickets.rs` | `tickets.json` vectors in order with one verifier, mint = Python byte for byte, malformed/base64 edge cases = Python, expiry edges, nonce cache pruning/cap, constant-time compare (timing), HMAC RFC 4231 |
| `tests/packs.rs` | manifest load/change/broken file, client|both filter, PacksChanged fields |
| `tools/ticket_packs_check.py` | end to end vs a gateway build + `world_fake.py`: ticket codes 0/14/15/16/17/4/5, static tokens, tickets-only mode, PacksChanged after Welcome and on change (latency), packs HTTP 200/404/409, metrics. `--gw "python3 <VC>/tools/olife/gateway_dev.py"` runs the same against the reference |
| `tools/fuzz_parity.py` | Python vs Rust codecs on the same 30 000 mutated bodies: same accept/reject, same re-encoding |
| `tools/win_build.sh` | sync to `D:\Prog\Olife\gateway\build`, native `cargo build --release` (MSVC), copy the exe |

## Build and test
```bash
python3 /mnt/d/Prog/VoxelCore/voxelcore-0.31.0_pre_gemini/tools/olife/gen_codecs.py --lang rust   # after a schema change
cargo test --release            # Linux (WSL): 7 codec + 6 gateway + 8 ticket + 1 packs tests
python3 tools/fuzz_parity.py 30000
python3 tools/ticket_packs_check.py            # 23 end-to-end cases (tickets + packs), temp files in $TMPDIR
tools/win_build.sh test         # Windows exe + the same tests on Windows
```
Security review and follow-ups (tickets: done in wave 4b; next: Noise in the pack, TLS/QUIC): VC_ROOT
`agents/research/OLIFE_GATEWAY_SECURITY.md`.

## Store files (UX A4, 03.10)
`--assets-dir <dir>` (the world store CAS, `<world>\olife_store\cas`): `GET /assets/<sha256 hex>` on the packs HTTP port ->
`<dir>/<sha[..2]>/<sha>`, re-hashed (409 if it changed), only 64 lowercase hex chars (no traversal). Metrics
`assets {served, bytes, missing, bad, dir}`. Same in gateway_dev.py. Clients take the base url from `PacksChanged.url`.

## Antifraud and IP bans (16.10, olife_antifraud)
VC_ROOT `agents/research/OLIFE_ANTIFRAUD.md`. Same behaviour as `tools/olife/gateway_dev.py`:
- IP bans are addresses or CIDR (`src/bans.rs` `Net`: parse/contains/canonical key, IPv4-mapped IPv6 as IPv4), from the bans
  file, the supervisor and the lab push; checked in `admit()` when the TCP connection is accepted (Disconnect 5 "banned by IP
  <net> until <UTC time>: <reason>" before Hello) and on live sessions.
- With `--auth-url` the keepalive loop calls `POST <daemon>/call/olife.gw_sync` every 2 s (`auth.rs` `http_req`, `sync`):
  sessions `[account, ip, name]` and limit events up; account bans, IP bans with until/reason and the limits cfg
  (`enabled`, `sessions_per_ip`, `conn_rate_net`, `net_prefix(6)`, `exempt`) down. Not available -> `GET /bans` as before.
- Limits (exempt networks skip them): sessions per IP -> 13; new connections per subnet (bucket `conn_rate_net`, burst x3)
  -> 13; refusals are reported as events (the supervisor autobans).
- **Disconnect 18 `nick_in_use`**: the account already plays from another address (same address: the old session is replaced,
  12). Hello names: ASCII `[A-Za-z0-9_.-]` only.
- Control port: `kick_ip {nets, reason, code, ban: [{net, until, reason}]}` (kick + add to the list at once). Metrics
  `antifraud {counts, sync_ok, cfg, ip_bans, pending_events}`.
- Tests: `bans::tests::nets` (CIDR, canonical keys, mapped v6, UTC formatting); `tests/codecs.rs` vector count 304 -> 376.
  End to end: lab scenarios `olife_ipban`, `olife_antifraud` with `--impl rs`.

