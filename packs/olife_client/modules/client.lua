-- olife_client:client — minimal Olife client (pure replica of the authoritative world).
-- Connect to the gateway (contract "client"), Hello with token, then: chunks -> world.set_chunk_data (pending until
-- the local chunk exists, applied in on_chunk_present), BlockUpdate -> block.set (+ read-back check), entities ->
-- engine entities (olife_client:avatar unless the def exists here) moved with interpolation over 3 ticks,
-- KeepAlive -> reply, PlayerCorrect -> snap, chat. Every tick: PlayerInput (position/rotation).
-- Replica hash (same definition as the world, olife_proto:util): sum of entity terms of the replica (f32 values
-- from the wire) + sum of block-change terms applied — compared with TickSync.view_hash at every tick and written
-- to user:export/client_states.jsonl for the lab (olife_consistency).
local C = require "olife_proto:client"
local W = require "olife_proto:wire"
local U = require "olife_proto:util"
local P = require "olife_client:packs"      -- wave 4b: PacksChanged -> pack hot reload
local AUTH = require "olife_client:auth"    -- wave 4b: token -> one-time ticket over HTTPS (sealed)
local OL = require "olife_client:olife"     -- wave 4a: editor / console / tools (requires this module lazily)
local PR = require "olife_client:predict"   -- wave 4c: movement prediction + reconciliation (MoveInput/PlayerState)
local ED = require "olife_client:entdelta"  -- wave 4c: EntityDelta (quantised per-session entity deltas)
local IM = require "olife_client:invmirror" -- wave 4c: mirror of the server-authoritative inventory
local CH = require "olife_client:chat"      -- UX A2: chat, operator results, notices (fx feedback)
local AS = require "olife_client:assets"    -- UX A4: store assets (EntityAssets -> HTTP -> runtime texture/model/sound)
local MV = require "olife_client:mobview"   -- UX A3: mob appearance / animation / sound on the replica
local MB = require "olife_client:mobs"      -- UX B1: my-mobs panel (MobsList / MobConfirm / MobRescued / history)
local SP = require "olife_client:spammer"   -- UX B2: Spammer (snapshot library, capture / throw, balls)
local SI = require "olife_client:serverinfo" -- olife_friends: url host fix for a friend's (remote) gateway

local M = {}
local add32 = U.add32
local floor = math.floor

local S = {
    state = "idle", sock = nil, fr = nil, out = nil, name = "bot", token = "", session = nil, eid = nil,
    tick = 0, server_tick = 0, seq = 0, pos = {x = 0, y = 80, z = 0}, rot = {x = 0, y = 0, z = 0},
    spawn = nil, view = 3, ents = {}, nents = 0, ent_hash = 0, block_hash = 0, pending = {}, chunks = {},
    nchunks = 0, pid = nil, bytes_in = 0, bytes_out = 0,
    stats = {frames = 0, chunks = 0, chunk_bytes = 0, chunk_hash_bad = 0, chunk_applied = 0, chunk_pending = 0,
             chunk_verified = 0, chunk_verify_diff = 0, blocks = 0, blocks_ok = 0, blocks_mismatch = 0,
             blocks_deferred = 0, rejects = 0, corrections = 0, snapshots = 0, spawns = 0, despawns = 0,
             syncs = 0, self_div = 0, chat = 0, keepalive = 0, inputs = 0, actions = 0, disconnect = nil,
             blocks_count_mismatch = false},
    last_sync = nil, export = nil, on_tick = nil,
    -- stage 6 (supervisor): reconnect after the world restarted. reconnect_s > 0 (`--reconnect S`): after a
    -- Disconnect with a code in RECONNECT_CODES, a closed socket or a connect error -> new connection in S seconds
    -- (fresh replica state; kick/ban/auth codes never reconnect). Off by default.
    reconnect_s = 0, reconnects = 0, retry_at = nil, last_code = nil, conn = nil,
}
M.S = S

local function log(fmt, ...) print("[olife_client] " .. string.format(fmt, ...)) end
-- Disconnect codes worth a reconnect (gateway_dev.py CODES): 1 shutdown, 9 world_unavailable, 8 timeout
local RECONNECT_CODES = {[1] = true, [8] = true, [9] = true}

local function schedule_reconnect(why)
    if (S.reconnect_s or 0) <= 0 or S.stop_requested or S.retry_at then return end
    if S.last_code ~= nil and not RECONNECT_CODES[S.last_code] then return end
    S.retry_at = time.uptime() + S.reconnect_s
    log("will reconnect in %.1f s (%s)", S.reconnect_s, tostring(why))
end

-- a new session starts from an empty replica: the world sends Welcome, chunks and full entity spawns again
local function reset_replica()
    for _, e in pairs(S.ents) do
        if e.uid then
            local ent = entities.get(e.uid)
            if ent then pcall(ent.despawn, ent) end
        end
    end
    S.ents, S.nents, S.ent_hash, S.block_hash = {}, 0, 0, 0
    S.pending, S.chunks, S.nchunks = {}, {}, 0
    S.session, S.eid, S.last_sync, S.last_time, S.acc = nil, nil, nil, nil, 0
    ED.reset(S); PR.stop(); IM.reset()          -- wave 4c
end
local function ckey(cx, cz) return cx * 65536 + cz end

local function send(name, msg)
    if S.state ~= "connecting" and S.state ~= "hello" and S.state ~= "play" then return end
    C.append_frame(S.out, name, msg)
end
M.send = send

-- the start script asks, the first world tick (main Lua state) connects: network callbacks created inside the
-- start-script coroutine stay bound to it (lua::create_lambda) — see olife_world/modules/server.lua
function M.request_connect(port, name, token, opts)
    S.connect_req = {port, name, token, opts}
end

function M.maybe_connect()
    P.pump()                                -- main Lua state: network callbacks of the pack reload live here
    AS.tick()                               -- UX A4: asset downloads (main state too) + apply to the replica
    local r = S.connect_req
    if r then
        S.connect_req = nil
        M.connect(r[1], r[2], r[3], r[4])
    end
end

-- Auth codes after which a reconnect is pointless (gateway CODES): 4 auth, 5 banned, 14..17 ticket refused
function M.connect(port, name, token, opts)
    S.name, S.token = name, token or "olife-bot"
    S.conn = {port, name, token, opts}
    if opts and opts.reconnect then S.reconnect_s = tonumber(opts.reconnect) or 0 end
    if opts and opts.host and opts.host ~= "" then S.host = opts.host end
    S.fr, S.out = C.framer(), Bytearray()
    S.state = "connecting"
    S.last_code = nil
    if S.export == nil and not (opts and opts.export == false) then
        S.export = U.jsonl("user:export/client_states.jsonl")     -- kept open over reconnects (one file per run)
    end
    if opts and opts.auth and opts.auth ~= "" then
        -- wave 4b: a fresh one-time ticket for every connection (the long token stays out of the game socket)
        S.state = "auth"
        AUTH.fetch({url = opts.auth, token = S.token, name = opts.nick or "", gateway = opts.gw_id or "",
                    pub = opts.auth_pub, verify = opts.auth_verify == true}, function(ticket, err, rep)
            if S.state ~= "auth" then return end
            if not ticket then
                S.state = "closed"
                S.stats.disconnect = "auth service: " .. tostring(err)
                S.auth_fail = rep                -- UX B: the status screen shows code/HTTP/reason
                log("ticket refused: %s", tostring(err))
                -- refused token/ban/whitelist: final; service unreachable: like a connect error (reconnect if enabled)
                local c = rep and rep.code
                S.last_code = (c == "auth" or c == "banned" or c == "whitelist" or c == "nick_reserved" or
                               c == "bad_name" or c == "ip_banned" or c == "nick_in_use" or c == "nick_similar" or
                               c == "rate_ip" or c == "rate_net" or c == "multi_account" or c == "sessions_ip")
                              and 4 or nil      -- antifraud 16.10: final, no reconnect loop
                schedule_reconnect("auth service")
                return
            end
            S.tickets = (S.tickets or 0) + 1
            M.open(port, ticket)
        end)
        return
    end
    M.open(port, S.token)
end

function M.open(port, hello_token)
    S.state = "connecting"
    -- play path (olife_play): opts.host — the gateway host (a friend's gateway; default this machine)
    S.sock = network.tcp_connect(S.host or "127.0.0.1", port, function(s)
        pcall(s.set_nodelay, s, true)
        S.state = "hello"
        S.connected_at = time.uptime()
        send("Hello", {proto = C.version, name = S.name, token = hello_token,
                       engine = table.concat({app and app.get_version and app.get_version() or 0}, ".")})
        M.flush()
        log("connected %s gateway=%d", S.name, port)
    end, function(s, err)
        S.state = "closed"
        S.stats.disconnect = "connect error: " .. tostring(err)
        log("connect error %s", tostring(err))
        schedule_reconnect("connect error")
    end)
end

-- UX B (16.10, olife_menu): login from the menu BEFORE the replica world exists. The socket is opened with the ticket
-- the login already took (olife_client:login); until M.enter_world() the client only answers KeepAlive, keeps Welcome
-- and PacksChanged aside (the status screen and the pack download use them) and queues everything else (chunks,
-- snapshots, TickSync...) to replay in order once the world is open — the replica then is exactly what a client
-- connected from inside the world would hold. opts: like M.connect (reconnect, auth, gw_id, auth_pub, nick, export).
function M.prelude_connect(host, port, name, hello_token, token, opts)
    opts = opts or {}
    S.prelude = true
    S.pre_welcome, S.pre_packs, S.backlog = nil, nil, {}
    S.name, S.token = name, token or ""
    S.conn = {port, name, token or "", opts}           -- in-game reconnects take a new ticket with these
    -- no automatic reconnect while in the menu (the status screen shows the error and offers Повторить); the
    -- in-game value comes back in M.enter_world
    S.reconnect_s, S.want_reconnect_s = 0, tonumber(opts.reconnect or 0) or 0
    S.host = (opts.host and opts.host ~= "") and opts.host or host
    S.fr, S.out = C.framer(), Bytearray()
    S.last_code, S.auth_fail, S.retry_at = nil, nil, nil
    S.stats.disconnect = nil
    S.connected_at, S.welcome_at = nil, nil
    if opts.export == false then S.export = nil end
    M.open(port, hello_token)
end

local function prelude_msg(name, m)
    if name == "Welcome" then
        S.pre_welcome = m
        S.session = m.session
        S.welcome_at = time.uptime()
    elseif name == "PacksChanged" then
        m.url = SI.fix_url(m.url, S.host)       -- olife_friends: the server advertises 127.0.0.1 -> the gateway's host
        S.pre_packs = m
        AS.set_base(m.url)
    elseif name == "KeepAlive" then
        S.stats.keepalive = S.stats.keepalive + 1
        send("KeepAliveReply", {challenge = m.challenge})
    elseif name == "Disconnect" then
        S.stats.disconnect = string.format("%d %s", m.code, m.reason)
        S.disconnect_reason = m.reason
        log("disconnected by server (menu): %d %s", m.code, m.reason)
        S.state = "closed"
        S.last_code = m.code
    else
        S.backlog[#S.backlog + 1] = {name, m}
    end
end

-- ------------------------------------------------------------------ replica: chunks and blocks
local function apply_change(ch)
    local x, y, z = ch.pos.x, ch.pos.y, ch.pos.z
    block.set(x, y, z, ch.id, ch.states)
    if block.get(x, y, z) == ch.id and (ch.id == 0 or block.get_states(x, y, z) == ch.states) then
        S.stats.blocks_ok = S.stats.blocks_ok + 1
    else
        S.stats.blocks_mismatch = S.stats.blocks_mismatch + 1
        if S.stats.blocks_mismatch <= 5 then
            log("block read-back mismatch at %d,%d,%d: want %d/%d got %d", x, y, z, ch.id, ch.states, block.get(x, y, z))
        end
    end
end

local function try_apply_chunk(k)
    local p = S.pending[k]
    if not p or not p.data then return false end
    if not world.set_chunk_data(p.cx, p.cz, p.data) then return false end
    S.stats.chunk_applied = S.stats.chunk_applied + 1
    local back = world.get_chunk_data(p.cx, p.cz)
    if back and #back == #p.data and W.fnv1a(back) == p.hash then
        S.stats.chunk_verified = S.stats.chunk_verified + 1
    else
        S.stats.chunk_verify_diff = S.stats.chunk_verify_diff + 1
    end
    for _, ch in ipairs(p.blocks or {}) do apply_change(ch) end
    S.pending[k] = nil
    return true
end

function M.on_chunk_present(cx, cz)
    local k = ckey(cx, cz)
    if S.pending[k] then try_apply_chunk(k) end
end

local H = {}

function H.Welcome(m)
    S.session, S.eid, S.server_tick, S.view = m.session, m.player_eid, m.tick, m.view_radius
    S.spawn = {x = m.spawn.x, y = m.spawn.y, z = m.spawn.z}
    S.pos = {x = m.spawn.x, y = m.spawn.y, z = m.spawn.z}
    S.state = "play"
    if m.blocks ~= block.defs_count() then
        S.stats.blocks_count_mismatch = true
        log("WARNING: world has %d block defs, here %d — block ids would not match", m.blocks, block.defs_count())
    end
    -- a local engine player loads local chunks around us (set_chunk_data needs an existing chunk)
    if S.pid == nil and S.camera_pid and not S.on_tick then
        S.pid = S.camera_pid            -- wave 4a camera mode: the hud player is the client player (olife_client:olife)
    elseif S.pid == nil then
        S.pid = player.create("olife_" .. S.name)
        pcall(player.set_flight, S.pid, true)
        pcall(player.set_noclip, S.pid, true)
        pcall(player.set_loading_chunks, S.pid, true)
    end
    player.set_pos(S.pid, S.pos.x, S.pos.y, S.pos.z)
    -- wave 4c: predicted movement (not in the wave-4a camera mode: there the hud player moves by engine input)
    IM.reset()
    if S.move == "predict" and not (S.camera_pid and S.pid == S.camera_pid) then PR.on_welcome(S.pos) else PR.stop() end
    log("welcome session=%d eid=%d world=%s tick=%d spawn=%.1f,%.1f,%.1f view=%d", m.session, m.player_eid, m.world,
        m.tick, m.spawn.x, m.spawn.y, m.spawn.z, m.view_radius)
end

function H.KeepAlive(m)
    S.stats.keepalive = S.stats.keepalive + 1
    send("KeepAliveReply", {challenge = m.challenge})
end

function H.Disconnect(m)
    S.stats.disconnect = string.format("%d %s", m.code, m.reason)
    S.disconnect_reason = m.reason
    log("disconnected by server: %d %s", m.code, m.reason)
    S.state = "closed"
    S.last_code = m.code
    pcall(CH.on_disconnect, m.code, m.reason)    -- UX A2: kicked / banned / world restarting -> sound + toast
    schedule_reconnect("code " .. m.code)
end

function H.ChunkData(m)
    S.stats.chunks = S.stats.chunks + 1
    S.stats.chunk_bytes = S.stats.chunk_bytes + #m.data
    if W.fnv1a(m.data) ~= m.hash then
        S.stats.chunk_hash_bad = S.stats.chunk_hash_bad + 1
        return
    end
    local k = ckey(m.cx, m.cz)
    S.pending[k] = {cx = m.cx, cz = m.cz, data = m.data, hash = m.hash, blocks = {}}
    if not S.chunks[k] then S.chunks[k] = true; S.nchunks = S.nchunks + 1 end
    if not try_apply_chunk(k) then S.stats.chunk_pending = S.stats.chunk_pending + 1 end
end

function H.ChunkUnload(m)
    local k = ckey(m.cx, m.cz)
    S.pending[k] = nil
    if S.chunks[k] then S.chunks[k] = nil; S.nchunks = S.nchunks - 1 end
end

function H.BlockUpdate(m)
    for _, ch in ipairs(m.changes) do
        S.stats.blocks = S.stats.blocks + 1
        S.block_hash = add32(S.block_hash, U.block_term(ch.pos.x, ch.pos.y, ch.pos.z, ch.id, ch.states))
        local k = ckey(floor(ch.pos.x / 16), floor(ch.pos.z / 16))
        local p = S.pending[k]
        if p then
            p.blocks[#p.blocks + 1] = ch
            S.stats.blocks_deferred = S.stats.blocks_deferred + 1
        else
            apply_change(ch)
        end
    end
end

function H.BlockReject(m)
    S.stats.rejects = S.stats.rejects + 1
    local a = m.actual
    if block.get(a.pos.x, a.pos.y, a.pos.z) ~= -1 then block.set(a.pos.x, a.pos.y, a.pos.z, a.id, a.states) end
end

local function engine_def(def)
    local ok, idx = pcall(entities.def_index, def)
    if ok and type(idx) == "number" and idx >= 0 then return def end
    return "olife_client:avatar"
end

function H.EntitySnapshot(m)
    S.stats.snapshots = S.stats.snapshots + 1
    for _, sp in ipairs(m.spawns) do
        local old = S.ents[sp.eid]
        if old then S.ent_hash = add32(S.ent_hash, 4294967296 - old.term) else S.nents = S.nents + 1 end
        local e = {eid = sp.eid, kind = sp.kind, def = sp.def, name = sp.name, pos = sp.pos, rot = sp.rot,
                   from = {x = sp.pos.x, y = sp.pos.y, z = sp.pos.z}, shown = {x = sp.pos.x, y = sp.pos.y, z = sp.pos.z},
                   alpha = 1, uid = old and old.uid}
        e.term = U.entity_term(e.eid, e.pos, e.rot)
        S.ent_hash = add32(S.ent_hash, e.term)
        if not e.uid then
            local ok, ent = pcall(entities.spawn, engine_def(sp.def), {sp.pos.x, sp.pos.y, sp.pos.z})
            if ok and ent then e.uid = ent:get_uid() end
        end
        S.ents[sp.eid] = e
        S.stats.spawns = S.stats.spawns + 1
    end
    for _, u in ipairs(m.updates) do
        local e = S.ents[u.eid]
        if e then
            S.ent_hash = add32(S.ent_hash, 4294967296 - e.term)
            if u.pos then
                e.from = {x = e.shown.x, y = e.shown.y, z = e.shown.z}
                e.pos = u.pos
                e.alpha = 0
            end
            if u.rot then e.rot = u.rot end
            e.term = U.entity_term(e.eid, e.pos, e.rot)
            S.ent_hash = add32(S.ent_hash, e.term)
        end
    end
    for _, eid in ipairs(m.despawns) do
        local e = S.ents[eid]
        if e then
            S.ent_hash = add32(S.ent_hash, 4294967296 - e.term)
            S.ents[eid] = nil
            S.nents = S.nents - 1
            S.stats.despawns = S.stats.despawns + 1
            if e.uid then
                local ent = entities.get(e.uid)
                if ent then pcall(ent.despawn, ent) end
            end
        end
    end
end

function H.TickSync(m)
    S.stats.syncs = S.stats.syncs + 1
    S.server_tick = m.tick
    local h = add32(S.ent_hash, S.block_hash)
    local t_recv = U.now_ms()
    if h ~= m.view_hash then
        S.stats.self_div = S.stats.self_div + 1
        if S.stats.self_div <= 5 then
            log("replica hash %d != world %d at tick %d (entities %d/%d)", h, m.view_hash, m.tick, S.nents, m.entities)
        end
    end
    S.last_sync = {tick = m.tick, hash = h, server_hash = m.view_hash, latency = t_recv - m.server_ms}
    if S.export then
        S.export:write({tick = m.tick, t_recv = t_recv, ts = m.server_ms, hash = h, server_hash = m.view_hash,
                        eid = S.eid, session = S.session, entities = S.nents, chunks = S.nchunks})
        S.export:flush()
    end
end

function H.PlayerCorrect(m)
    S.stats.corrections = S.stats.corrections + 1
    S.pos = {x = m.pos.x, y = m.pos.y, z = m.pos.z}
    if S.camera_pid and S.pid == S.camera_pid then player.set_pos(S.pid, S.pos.x, S.pos.y, S.pos.z) end
    if S.on_correct then S.on_correct(m) end
end

function H.PacksChanged(m)       -- UX A4: assets use the same HTTP base; olife_friends: loopback url -> gateway host
    m.url = SI.fix_url(m.url, S.host)
    AS.set_base(m.url)
    return P.on_changed(m)
end

-- wave 4c: netcode
function H.PlayerState(m) PR.on_state(S, m) end
function H.PlayerAck(m) PR.on_ack(S, m) end
function H.EntityDelta(m) S.stats.snapshots = S.stats.snapshots + 1; ED.apply(S, m) end
function H.InventoryState(m) IM.on_state(S, m) end
function H.InvReject(m) IM.on_reject(m) end
M.predict, M.inv = PR, IM
M.assets = AS

function H.ChatMessage(m)
    S.stats.chat = S.stats.chat + 1
    if S.stats.chat <= 20 then log("chat <%s> %s", m.name, m.text) end
    CH.on_msg("ChatMessage", m)
end

-- UX A2: ChatLine / ChatHistory / OpResult / Notice
function H.ChatLine(m)
    S.stats.chat = S.stats.chat + 1
    if S.stats.chat <= 20 then log("chat <%s> %s", m.line.from, m.line.text) end
    CH.on_msg("ChatLine", m)
end
function H.ChatHistory(m) CH.on_msg("ChatHistory", m) end
function H.OpResult(m) log("op /%s -> %d %s", m.cmd, m.code, m.text:sub(1, 120):gsub("\n", " | ")); CH.on_msg("OpResult", m) end
function H.Notice(m) log("notice %d %s", m.event, m.text); CH.on_msg("Notice", m) end

function M.dispatch(name, m)
    local h = H[name]
    if h then h(m)
    elseif OL.handled[name] then OL.on_msg(name, m)      -- wave 4a: editor / console / tools / name tags
    elseif AS.handled[name] then AS.on_msg(name, m)      -- UX A4: EntityAssets / AssetReply / AssetList
    elseif MV.handled[name] then MV.on_msg(name, m)      -- UX A3: EntityAppearance / EntityAnim / EntitySound
    elseif MB.handled[name] then MB.on_msg(name, m)      -- UX B1: MobsList / MobConfirm / MobRescued / MobRestored / ...
    elseif SP.handled[name] then SP.on_msg(name, m) end  -- UX B2: SpamList / SpamReply / SpamBall
end

-- UX B: the replica world is open (and the hud player exists): apply Welcome, then everything that came meanwhile
function M.enter_world()
    if not S.prelude then return 0 end
    S.prelude = false
    S.reconnect_s = S.want_reconnect_s or 0
    local w = S.pre_welcome
    if not w then return 0 end
    H.Welcome(w)
    local q = S.backlog or {}
    S.backlog = {}
    for _, it in ipairs(q) do
        if S.state == "closed" then break end
        M.dispatch(it[1], it[2])
    end
    S.tickets = S.tickets or 0
    return #q
end

-- ------------------------------------------------------------------ loop
local function interpolate(dt)
    for _, e in pairs(S.ents) do
        if e.alpha < 1 then
            e.alpha = math.min(1, e.alpha + dt / 0.15)       -- 3 server ticks
            local a = e.alpha
            e.shown.x = e.from.x + (e.pos.x - e.from.x) * a
            e.shown.y = e.from.y + (e.pos.y - e.from.y) * a
            e.shown.z = e.from.z + (e.pos.z - e.from.z) * a
            if e.uid then
                local ent = entities.get(e.uid)
                if ent then ent.transform:set_pos({e.shown.x, e.shown.y, e.shown.z}) end
            end
        end
    end
end

function M.flush()
    if S.out and #S.out > 0 and S.sock and S.state ~= "closed" then
        local n = #S.out
        if pcall(S.sock.send, S.sock, S.out) then S.bytes_out = S.bytes_out + n end
        S.out:clear()
    end
end

-- called every engine frame (20 Hz headless; the frame rate in a window): receive and apply everything now,
-- interpolate by elapsed time, and run the logical tick (bot driver + PlayerInput) on a fixed 50 ms clock —
-- the world and the gateway's rate limit expect 20 inputs/s, not one per rendered frame
local TICK = 0.05
function M.tick()
    if S.state == "closed" and S.retry_at and time.uptime() >= S.retry_at and not S.stop_requested then
        S.retry_at = nil
        if S.sock then pcall(S.sock.close, S.sock) end
        reset_replica()
        S.reconnects = S.reconnects + 1
        log("reconnecting #%d", S.reconnects)
        M.request_connect(S.conn[1], S.conn[2], S.conn[3], S.conn[4])  -- opened by the next world tick (main state)
        S.state = "idle"
        return
    end
    if S.state == "idle" or S.state == "closed" or S.state == "connecting" or S.state == "auth" then return end
    local now = time.uptime()
    local dt = S.last_time and math.min(now - S.last_time, 0.25) or TICK
    S.last_time = now
    S.acc = (S.acc or 0) + dt
    local data = S.sock:recv(4194304)
    if data == nil then
        if S.state ~= "closed" then
            S.state = "closed"
            S.stats.disconnect = S.stats.disconnect or "socket closed"
            log("socket closed")
            schedule_reconnect("socket closed")
        end
        return
    end
    if #data > 0 then
        S.bytes_in = S.bytes_in + #data
        S.fr:feed(data)
    end
    while true do
        local name, m = C.read(S.fr)
        if name == nil then break end
        if name == false then
            log("protocol error from gateway: %s", tostring(m))
            S.state = "closed"
            S.stats.disconnect = "protocol: " .. tostring(m)
            pcall(S.sock.close, S.sock)
            return
        end
        S.stats.frames = S.stats.frames + 1
        if S.prelude then prelude_msg(name, m) else M.dispatch(name, m) end   -- UX B: menu login queues
        if S.state == "closed" then break end
    end
    if S.prelude then M.flush(); return end
    interpolate(dt)
    local steps = 0
    while S.acc >= TICK - 1e-6 and steps < 3 do
        S.acc = S.acc - TICK
        steps = steps + 1
        S.tick = S.tick + 1
        if S.state == "play" then
            if S.on_tick then S.on_tick(S)
            elseif S.camera_pid then OL.camera_tick(S) end      -- wave 4a camera mode (hud player drives the input)
            S.seq = S.seq + 1
            if PR.active() then
                if not S.freeze_input then PR.tick(S, send) end   -- wave 4c: predict locally + MoveInput (keys, look)
            else
                send("PlayerInput", {seq = S.seq, pos = U.vec_round(S.pos), rot = U.vec_round(S.rot)})
            end
            S.stats.inputs = S.stats.inputs + 1
            if S.pid and not PR.active() then player.set_pos(S.pid, S.pos.x, S.pos.y, S.pos.z) end
        end
    end
    if PR.active() and S.pid then                 -- wave 4c: shown = predicted + decaying correction offset
        local x, y, z = PR.frame(dt)
        player.set_pos(S.pid, x, y, z)
    end
    if S.acc > TICK * 3 then S.acc = 0 end        -- after a stall: drop the backlog, do not burst inputs
    M.flush()
end

function M.block_action(action, x, y, z, id, states)
    S.stats.actions = S.stats.actions + 1
    send("BlockAction", {seq = S.seq, action = action, pos = {x = x, y = y, z = z}, block = id or 0, states = states or 0})
end

function M.chat(text) send("ChatSend", {text = text}) end

function M.bye(reason)
    if S.state == "play" then
        send("Bye", {reason = reason or "bye"})
        M.flush()
    end
    if S.sock then pcall(S.sock.close, S.sock) end
    S.state = "closed"
    if S.export then S.export:close(); S.export = nil end
end

-- wave 4b: pack reload that needs app.reopen_world(): Bye and close first; file streams do not survive the world
-- close ("unknown descriptor"), so client_states.jsonl is closed and the next part goes to client_states_r<n>.jsonl
-- (the lab reads all parts). After the reopen: M.reset_after_reopen() + request_connect.
function M.leave_for_reopen(reason)
    if S.state == "play" then
        send("Bye", {reason = reason or "packs reload"})
        M.flush()
    end
    if S.sock then pcall(S.sock.close, S.sock) end
    S.state = "closed"
    S.retry_at = nil
    if S.export then S.export:close(); S.export = nil end
end

function M.reset_after_reopen(part)
    reset_replica()
    S.pid = nil                        -- the local engine player belonged to the closed world
    S.state, S.retry_at, S.last_code = "idle", nil, nil
    S.reconnects = S.reconnects + 1
    S.export = U.jsonl(string.format("user:export/client_states_r%d.jsonl", part or S.reconnects))
end

-- UX B (olife_menu): app.reopen_world() unloads the pack's modules and loads them again (new instances; checked in
-- 0.32: "unloaded olife_client:modules/client.lua" on reopen, require then returns a new table) — the new instance takes
-- over the connection state of the old one (socket, framer, prelude, replica). The hud player of the reopened world
-- may have registered in the new instance's own table first: keep it.
function M.adopt(t)
    if t == nil or t == S then return end
    if S.camera_pid and not t.camera_pid then t.camera_pid = S.camera_pid end
    S = t
    M.S = t
end

function M.closed() return S.state == "closed" end
function M.will_reconnect() return S.retry_at ~= nil or S.state == "idle" and S.connect_req ~= nil end

function M.status()
    local st = S.stats
    local ls = S.last_sync
    return string.format("[olife_client] status name=%s state=%s session=%s eid=%s tick=%d server_tick=%d pos=%.2f,%.2f,%.2f " ..
        "entities=%d chunks=%d pending=%d frames=%d syncs=%d self_div=%d chunks_rx=%d verified=%d verify_diff=%d " ..
        "blocks=%d ok=%d mismatch=%d deferred=%d rejects=%d corrections=%d chat=%d keepalive=%d bytes_in=%d " ..
        "bytes_out=%d last_latency=%.1f reconnects=%d tickets=%d ticket_ms=%.1f %s disconnect=%s",
        S.name, S.state, tostring(S.session), tostring(S.eid), S.tick, S.server_tick, S.pos.x, S.pos.y, S.pos.z,
        S.nents, S.nchunks, (function() local n = 0 for _ in pairs(S.pending) do n = n + 1 end return n end)(),
        st.frames, st.syncs, st.self_div, st.chunks, st.chunk_verified, st.chunk_verify_diff, st.blocks,
        st.blocks_ok, st.blocks_mismatch, st.blocks_deferred, st.rejects, st.corrections, st.chat, st.keepalive,
        S.bytes_in, S.bytes_out, ls and ls.latency or -1, S.reconnects, S.tickets or 0, AUTH.stats.last_ms or -1,
        P.status() .. " " .. PR.status() .. " " .. ED.status() .. " " .. IM.status(), tostring(st.disconnect))  -- + wave 4c
end

-- wave 4c: exact prediction state (olife_prediction compares it with the world's `olife.move_state`)
function M.move_state()
    local x = PR.summary()
    return string.format("[olife_client] move eid=%s ack=%d seq=%d hash=%d pos=%.9g,%.9g,%.9g", tostring(S.eid), x.ack,
        x.seq, x.hash, x.pos and x.pos[1] or 0, x.pos and x.pos[2] or 0, x.pos and x.pos[3] or 0)
end

-- olife_blocks: compare the world's changed positions (copied by the lab into user:export/blocks_check.json)
-- with this replica's world, write user:export/blocks_bot.json
function M.check_blocks()
    local ok, d = pcall(function() return json.parse(file.read("user:export/blocks_check.json")) end)
    if not ok or type(d) ~= "table" then return "[olife_client] check_blocks: no user:export/blocks_check.json" end
    local r = {checked = 0, match = 0, mismatch = 0, unloaded = 0, first = {}, world_tick = d.tick,
               server_tick = S.server_tick}
    for _, b in ipairs(d.blocks or {}) do
        r.checked = r.checked + 1
        local id = block.get(b[1], b[2], b[3])
        if id == -1 then
            r.unloaded = r.unloaded + 1
        elseif id == b[4] and (id == 0 or block.get_states(b[1], b[2], b[3]) == b[5]) then
            r.match = r.match + 1
        else
            r.mismatch = r.mismatch + 1
            if #r.first < 10 then r.first[#r.first + 1] = {b[1], b[2], b[3], b[4], id} end
        end
    end
    file.write("user:export/blocks_bot.json", json.tostring(r))
    return string.format("[olife_client] check_blocks checked=%d match=%d mismatch=%d unloaded=%d", r.checked, r.match,
        r.mismatch, r.unloaded)
end

-- F2F `state` (test build only): same spirit as alphamine's state — what the replica holds now
function M.f2f_state()
    local ents = {}
    for eid, e in pairs(S.ents) do
        ents[#ents + 1] = {eid = eid, kind = e.kind, pos = {e.pos.x, e.pos.y, e.pos.z}}
    end
    table.sort(ents, function(a, b) return a.eid < b.eid end)
    return {tick = S.tick, server_tick = S.server_tick, state = S.state, session = S.session, eid = S.eid,
            player = {pos = {S.pos.x, S.pos.y, S.pos.z}, rot = {S.rot.x, S.rot.y, S.rot.z}},
            entities = ents, view_hash = add32(S.ent_hash, S.block_hash), ent_hash = S.ent_hash,
            blocks_hash = S.block_hash, chunks = S.nchunks, last_sync = S.last_sync, stats = S.stats,
            predict = PR.active() and PR.summary() or nil, inventory = {rev = IM.I.rev, hash = IM.I.hash,
            selected = IM.I.selected, total = IM.total(), div = IM.stats.div}}      -- wave 4c
end

return M
