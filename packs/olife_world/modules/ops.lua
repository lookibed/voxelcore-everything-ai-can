-- olife_world:ops — UX A2 (03.10, olife_a2): chat, operator commands, audit, feedback notices (OLIFE_UX §1, §5).
-- Chat: ChatSend from a player -> rate limit (the session bucket chat_rate/chat_burst of server.lua; an over-limit
-- line is refused with Notice 8 "chat throttled", at most one notice a second) -> ChatLine{sender, role, time} to
-- everybody; system lines (join/leave) and op lines (every operator action) too. The last `chat_keep` lines are
-- kept in the registry (survive a restart) and sent as ChatHistory right after Welcome (late joiners).
-- Commands: a ChatSend text "/<cmd> ..." of a session, or the stdin command `olife.op <rid> <by> <via> "<text>"`
-- of the lab (CLI `lab olife op`, supervisor panel buttons) -> the same executor. Admin = olife_world:editor.is_admin
-- (Attach.perms bit 1 or `olife.admins`); the lab operator is always admin. Every command that changes something is
-- audited (world:olife_audit.jsonl + user:export/audit.jsonl, ring of `audit_keep`) and announced as an op chat line;
-- affected players get a Notice (toast + sound on the client). Answers: OpResult to the sender (chat) or the stdin
-- line `[olife_world] op_result rid=<rid> code=<c> ...` (lab).
-- World-side state (registry key `ops`): bans by account (refused at attach, kicked at once), frozen players
-- (inputs ignored, requests refused, their mobs frozen too) and frozen mobs (no TickInput, VM state kept), per-mob
-- limits (actions per result, text bytes per result — enforced by the world bridge), per-owner sandbox limits (fuel/
-- tick, bucket, memory, actions/tick, text bytes -> `set_limits` on the sandboxd control port `--opts sbctl=<port>`,
-- the same command the tariff path of wave 4b sends; re-sent after the control connection comes back).
local net = require "olife_world:net"
local U = require "olife_proto:util"
local FR = require "olife_world:fraud"          -- antifraud 16.10: scores, /fraud, IP bans through the supervisor

local M = {}
local server, ED, SBX, S, scfg
local floor, min, max = math.floor, math.min, math.max

local cfg = {
    chat_keep = 100,         -- lines in the persisted history (ChatHistory max 100)
    audit_keep = 2000,       -- audit records kept (ring)
    cmd_rate = 4, cmd_burst = 8,     -- "/" commands per second per session
    notice_every = 20,       -- ticks between two "chat throttled" notices of one session
    throttle_hold = 40,      -- ticks a bench shows THROTTLED after its last throttled sandbox result
    save_every = 20,         -- ticks between registry writes when chat/ops state changed
}
M.cfg = cfg

local C = {ok = 0, rate = 9, forbidden = 16, unknown = 17, args = 18, target = 19, throttled = 20, noctl = 21}
M.CODE = C
local NOTICE = {frozen = 1, unfrozen = 2, mob_killed = 3, limits = 4, kicked = 5, banned = 6, restarting = 7,
                chat_throttled = 8, mob_frozen = 9, mob_unfrozen = 10, tp = 11, mobs_killed = 12}
M.NOTICE = NOTICE
local ROLE = {player = 0, admin = 1, world = 2, operator = 3}
local KIND = {player = 0, system = 1, op = 2, reply = 3, notice = 4}

-- /limits keys -> sandboxd Limits fields (per owner); "actions"/"text" on a MOB are enforced by the world per entity
local LIMIT_KEYS = {fuel = {"fuel_per_tick", "tick_cap"}, bucket = {"bucket_max"}, memory = {"mem_max"},
                    actions = {"max_actions"}, text = {"max_text_bytes"}}
local DEFAULT_LIMITS = {fuel_per_tick = 2000000, tick_cap = 10000000, bucket_max = 40000000, mem_max = 64 * 1048576,
                        max_actions = 64, max_text_bytes = 4096}   -- = Limits::default() of sandboxd (olife_w4b.py)
M.LIMIT_KEYS = LIMIT_KEYS

local ST = {
    lines = {}, total = 0, next_id = 1,        -- chat history ring (kind 0/1/2)
    audit = {}, audit_total = 0,
    bans = {},            -- account -> {until_ms (0 = permanent), reason, by, ms}
    frozen = {},          -- account -> {by, ms} (players)
    mob_frozen = {},      -- eid -> {by, ms}
    mob_lim = {},         -- eid -> {actions = n, text = n}
    owner_lim = {},       -- "<owner id>" -> {field = value} (sandbox set_limits, merged)
    dirty = false, saved_tick = 0, audit_dirty = false,
    stats = {chat = 0, chat_throttled = 0, history_sent = 0, cmds = 0, refused = {}, notices = 0, audits = 0,
             bans_refused = 0, frozen_inputs = 0, ctl_sent = 0, ctl_ok = 0, ctl_err = 0, mob_limited = 0},
    ctl = {state = "off", sock = nil, buf = "", q = {}, id = 0, retry_at = 0, replies = {}, last = nil, connects = 0},
    pending = {},         -- stdin ops queued for the tick: {rid, by, via, text}
}
M.ST = ST

local function log(fmt, ...) print("[olife_world] ops: " .. string.format(fmt, ...)) end
local function now_ms() return U.now_ms() end
local function clip(s, n)                -- byte limit without cutting a UTF-8 character (antifraud: Russian texts)
    s = tostring(s or "")
    if #s <= n then return s end
    local i = n
    while i > 0 and s:byte(i + 1) and s:byte(i + 1) >= 0x80 and s:byte(i + 1) < 0xC0 do i = i - 1 end
    return s:sub(1, i)
end

function M.init(srv, editor, sandbox, server_cfg)
    server, ED, SBX, scfg = srv, editor, sandbox, server_cfg
    S = srv.S
    for eid, r in pairs(ST.mob_frozen) do                 -- restored from the registry
        local e = S.ents[tonumber(eid)]
        if e then e.frozen = r else ST.mob_frozen[eid] = nil end
    end
    for eid, l in pairs(ST.mob_lim) do
        local e = S.ents[tonumber(eid)]
        if e then e.op_lim = l else ST.mob_lim[eid] = nil end
    end
end

-- ------------------------------------------------------------------------------------------ sessions / sending
local function sessions_of(account)
    local l = {}
    for _, s in pairs(S.sessions) do
        if s.account == account then l[#l + 1] = s end
    end
    return l
end

local function all_by_gw()
    local out = {}
    for _, s in pairs(S.sessions) do
        local l = out[s.gw.id]
        if not l then l = {}; out[s.gw.id] = l end
        l[#l + 1] = s.sid
    end
    return out
end

local function entry(kind, role, from_eid, from, text)
    local e = {id = ST.next_id, tick = S.tick, ms = now_ms(), kind = kind, role = role, from_eid = from_eid or 0,
               from = clip(from, 32), text = clip(text, 256)}
    ST.next_id = ST.next_id + 1
    return e
end

-- a public line (player / system / op): history + everybody
function M.say(kind, role, from_eid, from, text)
    local e = entry(kind, role, from_eid, from, text)
    ST.lines[#ST.lines + 1] = e
    while #ST.lines > cfg.chat_keep do table.remove(ST.lines, 1) end
    ST.total = ST.total + 1
    ST.dirty = true
    net.multicast(all_by_gw(), "ChatLine", {line = e})
    return e
end

-- a private line (command reply / notice text) to one session; not in the history
local function tell(sess, kind, text, from)
    local e = entry(kind, ROLE.world, 0, from or "world", text)
    net.send_client(sess.gw, sess.sid, "ChatLine", {line = e})
end

function M.notice(sess, event, code, eid, by, text)
    ST.stats.notices = ST.stats.notices + 1
    net.send_client(sess.gw, sess.sid, "Notice", {event = event, code = code or 0, eid = eid or 0, by = clip(by, 32),
                                                 text = clip(text, 256)})
end

local function notice_account(account, event, code, eid, by, text)
    local n = 0
    for _, s in ipairs(sessions_of(account)) do M.notice(s, event, code, eid, by, text); n = n + 1 end
    return n
end

-- ------------------------------------------------------------------------------------------ attach / leave
-- server.lua handlers.attach: a banned account is refused (-> Detach, the gateway disconnects with code 5)
function M.ban_of(account)
    local b = ST.bans[account]
    if not b then return nil end
    if b.until_ms > 0 and now_ms() >= b.until_ms then ST.bans[account] = nil; ST.dirty = true; return nil end
    return b
end

local function ban_text(b)
    local left = b.until_ms > 0 and string.format("%d min", math.ceil((b.until_ms - now_ms()) / 60000)) or "permanent"
    return string.format("banned (%s) by %s: %s", left, b.by or "?", b.reason or "")
end
M.ban_text = ban_text
M.clip = clip

function M.on_attach(sess)
    sess.ops_n = 0
    if ST.frozen[sess.account] then sess.frozen = ST.frozen[sess.account] end
    local hist = {}
    for i, l in ipairs(ST.lines) do hist[i] = l end
    net.send_client(sess.gw, sess.sid, "ChatHistory", {total = ST.total, lines = hist})
    ST.stats.history_sent = ST.stats.history_sent + 1
    M.say(KIND.system, ROLE.world, 0, "world", sess.name .. " joined")
    if sess.frozen then M.notice(sess, NOTICE.frozen, 0, 0, sess.frozen.by, "you are frozen by " .. tostring(sess.frozen.by)) end
end

function M.on_leave(sess, reason)
    if not S.running then return end
    M.say(KIND.system, ROLE.world, 0, "world", sess.name .. " left" .. (reason and (" (" .. clip(reason, 60) .. ")") or ""))
end

-- ------------------------------------------------------------------------------------------ chat
function M.on_chat(sess, text)
    text = tostring(text or ""):gsub("[%z\1-\31]", " ")
    if text:match("^%s*$") then return end
    if text:sub(1, 1) == "/" then return M.command_from_chat(sess, text) end
    if sess.ctokens < 1 then
        ST.stats.chat_throttled = ST.stats.chat_throttled + 1
        FR.event(sess, "chat")                        -- antifraud: a line over the chat bucket
        if S.tick - (sess.chat_notice_at or -1000) >= cfg.notice_every then
            sess.chat_notice_at = S.tick
            M.notice(sess, NOTICE.chat_throttled, C.throttled, 0, "world",
                     string.format("chat: not more than %d lines a second", scfg.chat_rate))
        end
        return
    end
    sess.ctokens = sess.ctokens - 1
    S.stats.chat = S.stats.chat + 1
    ST.stats.chat = ST.stats.chat + 1
    log("chat %s: %s", sess.name, text:sub(1, 120))
    M.say(KIND.player, ED.is_admin(sess) and ROLE.admin or ROLE.player, sess.eid, sess.name, text)
end

-- ------------------------------------------------------------------------------------------ audit
local function audit_write()
    local lines = {}
    for i, r in ipairs(ST.audit) do lines[i] = json.tostring(r) end
    local txt = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
    pcall(file.write, "world:olife_audit.jsonl", txt)
    if scfg.export ~= false then pcall(file.write, "user:export/audit.jsonl", txt) end
end

local function audit(ctx, cmd, args, code, text, extra)
    ST.audit_total = ST.audit_total + 1
    local r = {n = ST.audit_total, ms = now_ms(), tick = S.tick, by = ctx.by, account = ctx.account, role = ctx.role_name,
               via = ctx.via, cmd = cmd, args = args, code = code, result = clip(text, 400)}
    if extra then for k, v in pairs(extra) do r[k] = v end end
    ST.audit[#ST.audit + 1] = r
    while #ST.audit > cfg.audit_keep do table.remove(ST.audit, 1) end
    ST.stats.audits = ST.stats.audits + 1
    audit_write()
    ST.dirty = true
    return r
end

-- ------------------------------------------------------------------------------------------ targets
local function is_mob(e) return e and e.kind == 3 end

local function benches_named(name)
    local l = {}
    for _, e in pairs(S.ents) do
        if is_mob(e) and e.name == name then l[#l + 1] = e end
    end
    table.sort(l, function(a, b) return a.eid < b.eid end)
    return l
end

local function known_account(name)
    if #sessions_of(name) > 0 then return true end
    for _, e in pairs(S.ents) do if is_mob(e) and e.owner_acct == name then return true end end
    return ST.bans[name] ~= nil or ST.frozen[name] ~= nil
end

-- "<eid>" | "#<eid>" | "mob:<name>" | "player:<name>" | player name/account (online, then known) | bench name
-- -> {kind="mob", e} | {kind="player", account, name, sessions} | nil, error
local function resolve(arg, want)
    if not arg or arg == "" then return nil, "target missing" end
    local forced
    local a = arg
    if a:sub(1, 4) == "mob:" then forced, a = "mob", a:sub(5)
    elseif a:sub(1, 7) == "player:" then forced, a = "player", a:sub(8) end
    local n = tonumber((a:gsub("^#", "")))
    if n then
        local e = S.ents[n]
        if is_mob(e) and forced ~= "player" then return {kind = "mob", e = e} end
        local s = S.by_eid[n]
        if s and forced ~= "mob" then return {kind = "player", account = s.account, name = s.name, sessions = sessions_of(s.account)} end
        return nil, "no entity/player #" .. n
    end
    if forced ~= "mob" then
        for _, s in pairs(S.sessions) do
            if s.name == a or s.account == a then
                return {kind = "player", account = s.account, name = s.name, sessions = sessions_of(s.account)}
            end
        end
        if forced == "player" or want == "player" or known_account(a) then
            return {kind = "player", account = a, name = a, sessions = {}}     -- offline (ban / unfreeze / limits)
        end
    end
    if forced ~= "player" then
        local l = benches_named(a)
        if #l == 1 then return {kind = "mob", e = l[1]} end
        if #l > 1 then
            local ids = {}
            for i, e in ipairs(l) do ids[i] = "#" .. e.eid end
            return nil, "ambiguous mob name " .. a .. ": " .. table.concat(ids, " ")
        end
    end
    return nil, "no such mob or player: " .. a
end
M.resolve = resolve

local function mob_txt(e)
    return string.format("#%d %s [%s]", e.eid, tostring(e.name or ("bench" .. e.eid)), (e.owner_acct and e.owner_acct ~= "")
                         and e.owner_acct or "world")
end

local function mobs_of(account)
    local l = {}
    for _, e in pairs(S.ents) do
        if is_mob(e) and (account == nil or e.owner_acct == account) then l[#l + 1] = e end
    end
    table.sort(l, function(a, b) return a.eid < b.eid end)
    return l
end

-- ------------------------------------------------------------------------------------------ actions
local function mob_kill(ctx, e)
    local acct = e.owner_acct or ""
    ST.mob_frozen[tostring(e.eid)], ST.mob_lim[tostring(e.eid)] = nil, nil
    ED.delete_entity(e, ctx.by .. " (op " .. ctx.via .. ")")
    if acct ~= "" then
        notice_account(acct, NOTICE.mob_killed, 0, e.eid, ctx.by, string.format("your mob %s was killed by %s",
            mob_txt(e), ctx.by))
    end
end

local function set_mob_frozen(ctx, e, on)
    if on then
        e.frozen = {by = ctx.by, ms = now_ms()}
        ST.mob_frozen[tostring(e.eid)] = e.frozen
    else
        e.frozen = nil
        ST.mob_frozen[tostring(e.eid)] = nil
        -- the sandbox may have lost it meanwhile (reconnect loads only runnable entities): load again
        if ED.runnable(e) and SBX.connected() and SBX.st.loaded[e.eid] == nil then SBX.load_entity(e) end
    end
    ED.meta_changed(e)
    ED.push_state(e)
    ST.dirty = true
    if e.owner_acct and e.owner_acct ~= "" then
        notice_account(e.owner_acct, on and NOTICE.mob_frozen or NOTICE.mob_unfrozen, 0, e.eid, ctx.by,
            string.format("your mob %s was %s by %s", mob_txt(e), on and "frozen" or "unfrozen", ctx.by))
    end
end

local function set_player_frozen(ctx, account, on)
    if on then
        ST.frozen[account] = {by = ctx.by, ms = now_ms()}
    else
        ST.frozen[account] = nil
    end
    for _, s in ipairs(sessions_of(account)) do
        s.frozen = ST.frozen[account]
        M.notice(s, on and NOTICE.frozen or NOTICE.unfrozen, 0, 0, ctx.by,
                 on and ("you are frozen by " .. ctx.by) or ("you are unfrozen by " .. ctx.by))
    end
    local n = 0
    for _, e in ipairs(mobs_of(account)) do
        if (e.frozen ~= nil) ~= on then
            if on then
                e.frozen = {by = ctx.by, ms = now_ms(), with_player = true}
                ST.mob_frozen[tostring(e.eid)] = e.frozen
            elseif e.frozen.with_player then
                e.frozen = nil
                ST.mob_frozen[tostring(e.eid)] = nil
                if ED.runnable(e) and SBX.connected() and SBX.st.loaded[e.eid] == nil then SBX.load_entity(e) end
            end
            ED.meta_changed(e)
            ED.push_state(e)
            n = n + 1
        end
    end
    ST.dirty = true
    return n
end

-- ---- sandbox control port (sandboxd --ctl, lab F2F protocol: JSON lines {"id","cmd","args"})
local ctl = ST.ctl
local function ctl_connect()
    if (scfg.sbctl or 0) <= 0 then return end
    ctl.state = "connecting"
    ctl.sock = network.tcp_connect("127.0.0.1", scfg.sbctl, function()
        ctl.state, ctl.buf = "connected", ""
        ctl.connects = ctl.connects + 1
        log("sandbox control connected 127.0.0.1:%d (#%d)", scfg.sbctl, ctl.connects)
        -- everything we set, again: a restarted sandbox starts from its defaults
        for owner, f in pairs(ST.owner_lim) do
            local full = {}
            for k, v in pairs(f) do full[k] = v end
            ctl.q[#ctl.q + 1] = {cmd = "set_limits", args = {owner = tonumber(owner), limits = full}, why = "resend"}
        end
    end, function(_, err)
        ctl.state, ctl.retry_at = "down", S.tick + 40
        ctl.last_error = tostring(err)
    end)
end

local function ctl_send(owner, fields, why)
    ctl.q[#ctl.q + 1] = {cmd = "set_limits", args = {owner = owner, limits = fields}, why = why}
    if ctl.state == "off" or ctl.state == "down" then ctl_connect() end
end

local function ctl_tick()
    if (scfg.sbctl or 0) <= 0 then return end
    if ctl.state == "down" and S.tick >= ctl.retry_at and (next(ST.owner_lim) or #ctl.q > 0) then ctl_connect() end
    if ctl.state ~= "connected" then return end
    local data = ctl.sock:recv(65536)
    if data == nil then
        ctl.state, ctl.retry_at = "down", S.tick + 40
        log("sandbox control connection lost")
        return
    end
    if #data > 0 then ctl.buf = ctl.buf .. utf8.tostring(data) end
    while true do
        local i = ctl.buf:find("\n", 1, true)
        if not i then break end
        local line = ctl.buf:sub(1, i - 1)
        ctl.buf = ctl.buf:sub(i + 1)
        local ok, r = pcall(json.parse, line)
        if ok and type(r) == "table" then
            local q = ctl.waiting and ctl.waiting[r.id]
            if ctl.waiting then ctl.waiting[r.id] = nil end
            if r.ok then ST.stats.ctl_ok = ST.stats.ctl_ok + 1 else ST.stats.ctl_err = ST.stats.ctl_err + 1 end
            local res = type(r.result) == "table" and r.result or {}
            ctl.last = {id = r.id, ok = r.ok, owner = res.owner, version = res.version, live = res.live,
                        error = r.error, why = q and q.why, tick = S.tick}
            ctl.replies[#ctl.replies + 1] = ctl.last
            if #ctl.replies > 32 then table.remove(ctl.replies, 1) end
            log("sandbox set_limits id=%s ok=%s owner=%s version=%s live=%s %s", tostring(r.id), tostring(r.ok),
                tostring(res.owner), tostring(res.version), tostring(res.live), tostring(r.error or ""))
        end
    end
    if #ctl.q > 0 then
        local out = {}
        ctl.waiting = ctl.waiting or {}
        for _, q in ipairs(ctl.q) do
            ctl.id = ctl.id + 1
            ctl.waiting[ctl.id] = q
            out[#out + 1] = json.tostring({id = ctl.id, cmd = q.cmd, args = q.args}) .. "\n"
            ST.stats.ctl_sent = ST.stats.ctl_sent + 1
        end
        ctl.q = {}
        pcall(ctl.sock.send, ctl.sock, table.concat(out))
    end
end

-- world-side per-mob limits, checked by the sandbox bridge for every action (olife_world:sandbox apply_action)
function M.check_action(e, op, a, rtick)
    local l = e.op_lim
    if not l then return nil end
    if e.op_rt ~= rtick then e.op_rt, e.op_na, e.op_nt = rtick, 0, 0 end
    e.op_na = e.op_na + 1
    if l.actions and e.op_na > l.actions then ST.stats.mob_limited = ST.stats.mob_limited + 1; return "op limit actions" end
    if l.text and (op == "say" or op == "print" or op == "oprint") then
        e.op_nt = e.op_nt + #tostring(a.text or "")
        if e.op_nt > l.text then ST.stats.mob_limited = ST.stats.mob_limited + 1; return "op limit text" end
    end
    return nil
end

local function limits_show(t)
    if t.kind == "mob" then
        local e = t.e
        local l = e.op_lim or {}
        local o = ST.owner_lim[tostring(e.owner or 0)] or {}
        return string.format("%s: world actions/result=%s text bytes/result=%s; owner #%s sandbox %s", mob_txt(e),
            tostring(l.actions or "default"), tostring(l.text or "default"), tostring(e.owner),
            next(o) and json.tostring(o) or "defaults")
    end
    local owner = ED.owner_id(t.account)
    local o = ST.owner_lim[tostring(owner)] or {}
    return string.format("%s (owner #%d): sandbox %s", t.account, owner, next(o) and json.tostring(o) or "defaults")
end

local function set_limits(ctx, t, key, value)
    local fields = LIMIT_KEYS[key]
    if not fields then return C.args, "unknown key " .. tostring(key) .. " (fuel, bucket, memory, actions, text)" end
    local v
    if value == "default" or value == "reset" then v = nil
    else
        v = tonumber(value)
        if not v or v < 0 or v ~= v or v > 4e12 then return C.args, "value must be a number >= 0 or 'default'" end
        v = floor(v)
        if key == "memory" and v < 1048576 then v = v * 1048576 end     -- small numbers are MiB
    end
    local where
    if t.kind == "mob" and (key == "actions" or key == "text") then
        local e = t.e
        e.op_lim = e.op_lim or {}
        e.op_lim[key] = v
        if not next(e.op_lim) then e.op_lim = nil end
        ST.mob_lim[tostring(e.eid)] = e.op_lim
        where = string.format("%s world-side %s/result = %s", mob_txt(e), key, tostring(v or "default"))
        if e.owner_acct and e.owner_acct ~= "" then
            notice_account(e.owner_acct, NOTICE.limits, 0, e.eid, ctx.by, string.format("limits of %s: %s = %s (by %s)",
                mob_txt(e), key, tostring(v or "default"), ctx.by))
        end
        ST.dirty = true
        return C.ok, where
    end
    local owner, who, acct
    if t.kind == "mob" then
        owner, acct = t.e.owner or 0, t.e.owner_acct
        who = string.format("%s -> owner #%d (sandbox limits are per owner VM)", mob_txt(t.e), owner)
    else
        acct = t.account
        owner = ED.owner_id(t.account)
        who = string.format("%s (owner #%d)", t.account, owner)
    end
    local ok_ = tostring(owner)
    ST.owner_lim[ok_] = ST.owner_lim[ok_] or {}
    local send = {}
    for _, f in ipairs(fields) do
        ST.owner_lim[ok_][f] = v
        send[f] = v or DEFAULT_LIMITS[f]
    end
    if not next(ST.owner_lim[ok_]) then ST.owner_lim[ok_] = nil end
    ST.dirty = true
    local code = C.ok
    local note = ""
    if (scfg.sbctl or 0) > 0 then
        ctl_send(owner, send, ctx.via .. " " .. ctx.by)
    else
        code, note = C.noctl, " (no sandbox control port: kept, not delivered)"
    end
    if acct and acct ~= "" then
        notice_account(acct, NOTICE.limits, 0, t.kind == "mob" and t.e.eid or 0, ctx.by,
            string.format("limits %s = %s (by %s)", key, tostring(v or "default"), ctx.by))
    end
    return code, string.format("%s: %s = %s%s", who, key, tostring(v or "default"), note)
end

local function teleport_player(s, x, y, z)
    s.pos.x, s.pos.y, s.pos.z = x, y, z
    pcall(player.set_pos, s.pid, x, y, z)
    require("olife_world:move_auth").on_legacy(s)
    net.send_client(s.gw, s.sid, "PlayerCorrect", {seq = s.input_seq or 0, pos = U.vec_round(s.pos), reason = 4})
end

local function place_of(ctx, args, i)
    -- "here" | x y z | <player|mob>
    local a = args[i]
    if a == nil then return nil, "where? (x y z | player | mob | here)" end
    if a == "here" then
        if not ctx.sess then return nil, "'here' needs a player (chat)" end
        return {ctx.sess.pos.x, ctx.sess.pos.y, ctx.sess.pos.z}
    end
    local x, y, z = tonumber(args[i]), tonumber(args[i + 1]), tonumber(args[i + 2])
    if x and y and z then return {x, y, z} end
    local t, err = resolve(a)
    if not t then return nil, err end
    if t.kind == "mob" then return {t.e.pos.x, t.e.pos.y + 1, t.e.pos.z} end
    local s = t.sessions[1]
    if not s then return nil, t.account .. " is offline" end
    return {s.pos.x, s.pos.y, s.pos.z}
end

-- ------------------------------------------------------------------------------------------ commands
local CMDS = {}
local HELP = {
    {"help", "", "this list"},
    {"mobs", "[player]", "mobs (all / of a player; non-admins: their own) with status"},
    {"who", "", "players online (admins, frozen)"},
    {"kill", "<mob>", "kill a mob (despawn + forget)"},
    {"killall", "[player]", "kill all mobs of a player / of everybody"},
    {"freeze", "<mob|player>", "freeze a mob (no ticks) or a player (no input, no actions, his mobs too)"},
    {"unfreeze", "<mob|player>", "undo freeze"},
    {"limits", "<mob|player> [key value|default]", "fuel (per tick), bucket, memory, actions, text — live"},
    {"kick", "<player> [reason]", "disconnect"},
    {"ban", "<player> <minutes> <reason> | ip <addr|cidr> [minutes] [reason]", "ban (0 = permanent), kick now; ip: supervisor DB, all gateways"},
    {"unban", "<player> | ip <addr|cidr>", "lift a ban"},
    {"bans", "", "active bans of the supervisor (accounts, IP/CIDR) and of this world"},
    {"players", "", "players online with address (admins: full IP, players: masked)"},
    {"fraud", "[status|events [n]|clear <player|ip:addr|nick:n>|set <key> <value|default>|trust <player> <x>]",
     "antifraud: scores, events, live knobs; clear = false positive (lifts autobans, trust x2)"},
    {"tp", "<who> <x y z|player|mob|here>", "teleport a player or a mob"},
    {"say", "<text>", "operator announcement"},
    {"audit", "[n]", "last audit records"},
    {"whitelist", "list|add <nick>|remove <nick>|on|off", "whitelist by nick of this server (supervisor DB)"},
}
local ADMIN_ONLY = {kill = true, killall = true, freeze = true, unfreeze = true, limits = true, kick = true, ban = true,
                    unban = true, tp = true, say = true, audit = true, whitelist = true, bans = true, fraud = true}
M.HELP = HELP

function CMDS.help(ctx)
    local l = {}
    for _, h in ipairs(HELP) do
        if ctx.admin or not ADMIN_ONLY[h[1]] then l[#l + 1] = string.format("/%s %s - %s", h[1], h[2], h[3]) end
    end
    return C.ok, table.concat(l, "\n")
end

local SHOW = {[0] = "STOP", [1] = "RUN", [2] = "ERROR", [3] = "THROTTLED", [4] = "FROZEN"}
function CMDS.mobs(ctx, args)
    local acct = args[1]
    if acct then
        local t = resolve(acct, "player")
        acct = t and t.kind == "player" and t.account or acct
    end
    if not ctx.admin then
        if acct and acct ~= ctx.account then return C.forbidden, "only your own mobs: /mobs" end
        acct = ctx.account
    end
    local l = mobs_of(acct)
    local out = {string.format("mobs%s: %d", acct and (" of " .. acct) or "", #l)}
    for i, e in ipairs(l) do
        if i > 40 then out[#out + 1] = "..."; break end
        local mt = ED.is_bench(e) and ED.meters_of(e) or {}
        out[#out + 1] = string.format("%s %s cr/min=%.0f fuel/min=%.0f pos=%.0f,%.0f,%.0f%s", mob_txt(e),
            SHOW[ED.shown_status(e)] or "?", mt.credits_min or 0, mt.fuel_min or 0, e.pos.x, e.pos.y, e.pos.z,
            e.op_lim and (" lim=" .. json.tostring(e.op_lim)) or "")
    end
    return C.ok, table.concat(out, "\n")
end

function CMDS.who(ctx)
    local l = {}
    for _, s in pairs(S.sessions) do
        l[#l + 1] = string.format("%s (%s) #%d%s%s", s.name, s.account, s.eid, ED.is_admin(s) and " admin" or "",
                                  s.frozen and " FROZEN" or "")
    end
    table.sort(l)
    return C.ok, "players: " .. #l .. (#l > 0 and ("\n" .. table.concat(l, "\n")) or "")
end

function CMDS.kill(ctx, args)
    local t, err = resolve(args[1], "mob")
    if not t then return C.target, err end
    if t.kind ~= "mob" then return C.args, "/kill takes a mob; for all mobs of a player: /killall " .. t.account end
    local txt = mob_txt(t.e)
    mob_kill(ctx, t.e)
    return C.ok, "killed " .. txt, {target = txt, eids = {t.e.eid}}
end

function CMDS.killall(ctx, args)
    local acct
    if args[1] then
        local t, err = resolve(args[1], "player")
        if not t then return C.target, err end
        if t.kind ~= "player" then return C.args, "/killall takes a player" end
        acct = t.account
    end
    local l = mobs_of(acct)
    local eids = {}
    for i, e in ipairs(l) do eids[i] = e.eid; mob_kill({by = ctx.by, via = ctx.via}, e) end
    if acct then
        notice_account(acct, NOTICE.mobs_killed, 0, 0, ctx.by, string.format("all your mobs (%d) were killed by %s", #l, ctx.by))
    end
    return C.ok, string.format("killed %d mobs%s", #l, acct and (" of " .. acct) or " (all)"),
           {target = acct or "*", eids = eids}
end

local function freeze_cmd(on)
    return function(ctx, args)
        local t, err = resolve(args[1])
        if not t then return C.target, err end
        if t.kind == "mob" then
            local was = t.e.frozen ~= nil
            if was == on then return C.ok, mob_txt(t.e) .. (on and " is already frozen" or " is not frozen") end
            set_mob_frozen(ctx, t.e, on)
            return C.ok, string.format("%s %s", on and "froze" or "unfroze", mob_txt(t.e)), {target = mob_txt(t.e), eid = t.e.eid}
        end
        local n = set_player_frozen(ctx, t.account, on)
        return C.ok, string.format("%s player %s (%d sessions online, %d mobs)", on and "froze" or "unfroze", t.account,
                                   #t.sessions, n), {target = t.account}
    end
end
CMDS.freeze = freeze_cmd(true)
CMDS.unfreeze = freeze_cmd(false)

function CMDS.limits(ctx, args)
    local t, err = resolve(args[1])
    if not t then return C.target, err end
    if not args[2] then return C.ok, limits_show(t) end
    if not args[3] then return C.args, "/limits <mob|player> <key> <value|default>" end
    local code, txt = set_limits(ctx, t, args[2], args[3])
    return code, txt, {target = t.kind == "mob" and mob_txt(t.e) or t.account, key = args[2], value = args[3]}
end

function CMDS.kick(ctx, args)
    local t, err = resolve(args[1], "player")
    if not t then return C.target, err end
    if t.kind ~= "player" then return C.args, "/kick takes a player" end
    if #t.sessions == 0 then return C.target, t.account .. " is offline" end
    local reason = table.concat(args, " ", 2)
    if reason == "" then reason = "kicked by " .. ctx.by end
    for _, s in ipairs(t.sessions) do
        M.notice(s, NOTICE.kicked, 0, 0, ctx.by, "kicked by " .. ctx.by .. ": " .. reason)
        server.kick(s, 10, clip("kicked by " .. ctx.by .. ": " .. reason, 250))
    end
    return C.ok, string.format("kicked %s (%d sessions): %s", t.account, #t.sessions, reason), {target = t.account}
end

-- antifraud (16.10): supervisor calls answered later (ctx.reply), like /whitelist
local function sup_async(ctx, cmd, args, fargs, done)
    if (scfg.sup or 0) <= 0 then return C.noctl, cmd .. ": no supervisor (world without --opts sup=<port>)" end
    local reply = ctx.reply
    fargs.by, fargs.via = ctx.by, ctx.via
    FR.sup_post("olife.fraud", fargs, function(res, err)
        local code, text
        if not res then code, text = C.noctl, cmd .. ": " .. tostring(err)
        elseif res.ok == false then code, text = C.args, cmd .. ": " .. tostring(res.reason or res.code)
        else code, text = done(res) end
        if fargs.action ~= "status" and fargs.action ~= "events" and fargs.action ~= "bans" then
            audit(ctx, cmd, args, code, text, {target = fargs.value or fargs.target or fargs.key})
            if code == C.ok then M.say(KIND.op, ctx.role, ctx.sess and ctx.sess.eid or 0, ctx.by, "[op] " .. text) end
        end
        log("%s by=%s %s -> %d %s", cmd, tostring(ctx.by), table.concat(args, " "), code, tostring(text):sub(1, 160))
        if reply then reply(code, text) end
    end)
    return C.ok, cmd .. ": asking the supervisor...", {async = true, quiet = true}
end

-- sessions of this world whose address is in the network: kicked at once (gateways: kick_ip / gw_sync <= 2 s)
local function kick_net(netw, text)
    local n = 0
    for _, s in pairs(S.sessions) do
        if FR.in_net(FR.ip_of(s), netw) then
            M.notice(s, NOTICE.banned, 0, 0, "operator", text)
            server.kick(s, 5, clip(text, 250))
            n = n + 1
        end
    end
    return n
end

function CMDS.ban(ctx, args)
    if (args[1] or ""):lower() == "ip" then
        local v = args[2]
        if not v then return C.args, "/ban ip <addr|cidr> [minutes (0 = permanent)] [reason]" end
        local minutes = tonumber(args[3]) or 0
        local reason = table.concat(args, " ", tonumber(args[3]) and 4 or 3)
        if reason == "" then reason = "operator" end
        return sup_async(ctx, "ban", args, {action = "ipban", value = v, minutes = minutes, reason = reason,
                                             force = args[#args] == "force" or nil}, function(res)
            local n = kick_net(res.value, res.text or ("banned by IP " .. tostring(res.value)))
            return C.ok, string.format("banned IP %s %s: %s (%d sessions kicked here)", tostring(res.value),
                minutes > 0 and ("for " .. minutes .. " min") or "for ever", reason, n)
        end)
    end
    local t, err = resolve(args[1], "player")
    if not t then return C.target, err end
    if t.kind ~= "player" then return C.args, "/ban takes a player" end
    local minutes = tonumber(args[2])
    if not minutes or minutes < 0 then return C.args, "/ban <player> <minutes (0 = permanent)> <reason>" end
    local reason = table.concat(args, " ", 3)
    if reason == "" then reason = "no reason" end
    local b = {until_ms = minutes > 0 and now_ms() + minutes * 60000 or 0, reason = clip(reason, 200), by = ctx.by,
               ms = now_ms()}
    ST.bans[t.account] = b
    ST.dirty = true
    for _, s in ipairs(t.sessions) do
        M.notice(s, NOTICE.banned, 0, 0, ctx.by, ban_text(b))
        server.kick(s, 5, clip(ban_text(b), 250))
    end
    return C.ok, string.format("banned %s for %s: %s (%d sessions kicked)", t.account,
        minutes > 0 and (minutes .. " min") or "ever", reason, #t.sessions), {target = t.account, minutes = minutes}
end

function CMDS.unban(ctx, args)
    local a = args[1]
    if not a then return C.args, "/unban <player> | ip <addr|cidr>" end
    if a:lower() == "ip" then
        if not args[2] then return C.args, "/unban ip <addr|cidr>" end
        return sup_async(ctx, "unban", args, {action = "unban", value = args[2]}, function(res)
            return C.ok, string.format("unbanned IP %s (%d bans lifted)", tostring(res.value), res.lifted or 0)
        end)
    end
    a = a:gsub("^player:", "")
    if not ST.bans[a] then return C.target, a .. " is not banned" end
    ST.bans[a] = nil
    ST.dirty = true
    return C.ok, "unbanned " .. a, {target = a}
end

function CMDS.bans(ctx, args)
    local own = {}
    for a, b in pairs(ST.bans) do
        if M.ban_of(a) then own[#own + 1] = string.format("world: %s %s", a, ban_text(b)) end
    end
    if (scfg.sup or 0) <= 0 then return C.ok, "bans (this world): " .. #own .. "\n" .. table.concat(own, "\n") end
    return sup_async(ctx, "bans", args, {action = "bans"}, function(res)
        return C.ok, tostring(res.text) .. (#own > 0 and ("\n" .. table.concat(own, "\n")) or "")
    end)
end

-- players with their address: admins see the IP, players a masked one (a.b.x.x)
function CMDS.players(ctx)
    local l = {}
    for _, s in pairs(S.sessions) do
        local ip = FR.ip_of(s)
        l[#l + 1] = string.format("%s (%s) #%d %s%s%s", s.name, s.account, s.eid, ctx.admin and ip or FR.mask(ip),
                                  ED.is_admin(s) and " admin" or "", s.frozen and " FROZEN" or "")
    end
    table.sort(l)
    return C.ok, "players: " .. #l .. (#l > 0 and ("\n" .. table.concat(l, "\n")) or "")
end

function CMDS.fraud(ctx, args)
    local op = (args[1] or "status"):lower()
    if op == "status" then
        if (scfg.sup or 0) <= 0 then return C.ok, FR.status_text(10) end
        local here = FR.status_text(10)
        return sup_async(ctx, "fraud", args, {action = "status", last = 8}, function(res)
            return C.ok, here .. "\n-- supervisor --\n" .. tostring(res.text)
        end)
    elseif op == "events" then
        return C.ok, FR.events_text(tonumber(args[2]) or 10)
    elseif op == "clear" then
        local tgt = args[2]
        if not tgt then return C.args, "/fraud clear <player|ip:addr|nick:name>" end
        local t = not tgt:match("^%a+:") and resolve(tgt, "player") or nil
        if t and t.kind == "player" then tgt = t.account end
        if not tgt:match("^%a+:") then FR.clear(tgt) end           -- at once here; the supervisor sets the trust
        return sup_async(ctx, "fraud", args, {action = "clear", target = tgt}, function(res)
            if res.trust and not tgt:match("^%a+:") then FR.ST.trust[tgt] = res.trust end
            return C.ok, tostring(res.text)
        end)
    elseif op == "set" then
        if not args[2] or not args[3] then return C.args, "/fraud set <key> <value|default>" end
        return sup_async(ctx, "fraud", args, {action = "set", key = args[2], value = args[3]}, function(res)
            if FR.cfg[args[2]] ~= nil and tonumber(res.value) then FR.cfg[args[2]] = tonumber(res.value) end
            return C.ok, tostring(res.text)
        end)
    elseif op == "trust" then
        if not args[2] or not tonumber(args[3]) then return C.args, "/fraud trust <player> <x>" end
        return sup_async(ctx, "fraud", args, {action = "trust", account = args[2], value = tonumber(args[3])}, function(res)
            FR.ST.trust[args[2]] = tonumber(args[3])
            return C.ok, tostring(res.text)
        end)
    end
    return C.args, "/fraud [status|events [n]|clear <who>|set <key> <value>|trust <player> <x>]"
end

function CMDS.tp(ctx, args)
    local t, err = resolve(args[1])
    if not t then return C.target, err end
    local p, perr = place_of(ctx, args, 2)
    if not p then return C.args, perr end
    if p[2] < 1 or p[2] > 255 or math.abs(p[1]) > 1e6 or math.abs(p[3]) > 1e6 then return C.args, "bad position" end
    if t.kind == "mob" then
        local e = t.e
        e.pos.x, e.pos.y, e.pos.z = p[1], p[2], p[3]
        return C.ok, string.format("moved %s to %.1f %.1f %.1f", mob_txt(e), p[1], p[2], p[3]), {target = mob_txt(e)}
    end
    if #t.sessions == 0 then return C.target, t.account .. " is offline" end
    for _, s in ipairs(t.sessions) do
        teleport_player(s, p[1], p[2], p[3])
        M.notice(s, NOTICE.tp, 0, 0, ctx.by, string.format("teleported by %s to %.0f %.0f %.0f", ctx.by, p[1], p[2], p[3]))
    end
    return C.ok, string.format("teleported %s to %.1f %.1f %.1f", t.account, p[1], p[2], p[3]), {target = t.account}
end

function CMDS.say(ctx, args)
    local txt = table.concat(args, " ")
    if txt == "" then return C.args, "/say <text>" end
    M.say(KIND.op, ctx.role, 0, ctx.by, txt)
    return C.ok, "said", {quiet = true}
end

function CMDS.audit(ctx, args)
    local n = min(tonumber(args[1]) or 10, 40)
    local out = {string.format("audit: %d records (showing %d)", ST.audit_total, min(n, #ST.audit))}
    for i = max(1, #ST.audit - n + 1), #ST.audit do
        local r = ST.audit[i]
        out[#out + 1] = string.format("%d %s/%s %s %s -> %d %s", r.n, tostring(r.by), tostring(r.via), r.cmd,
            table.concat(r.args or {}, " "), r.code, tostring(r.result):sub(1, 80))
    end
    return C.ok, table.concat(out, "\n")
end

-- UX B (16.10, olife_menu): /whitelist — the whitelist lives in the supervisor DB (the auth service asks it on a nick
-- login); the world forwards the command to the lab daemon (--opts sup=<daemon port>,wl=<scope = gateway id>):
-- POST /call/olife.whitelist -> the reply goes back as OpResult (chat) or the op_result stdin line (lab) when it comes.
local WL_OPS = {list = true, add = true, remove = true, on = true, off = true}
function CMDS.whitelist(ctx, args)
    local op = (args[1] or "list"):lower()
    if not WL_OPS[op] then return C.args, "/whitelist list|add <nick>|remove <nick>|on|off" end
    if (op == "add" or op == "remove") and not args[2] then return C.args, "/whitelist " .. op .. " <nick>" end
    if (scfg.sup or 0) <= 0 then return C.noctl, "whitelist: no supervisor (world without --opts sup=<port>)" end
    local body = json.tostring({owner = "olife-world", args = {op = op, name = args[2], scope = scfg.wl or "*",
                                by = ctx.by, via = ctx.via == "chat" and "chat" or ctx.via}})
    local done = ctx.reply
    ST.stats.wl_req = (ST.stats.wl_req or 0) + 1
    network.request(string.format("http://127.0.0.1:%d/call/olife.whitelist", scfg.sup), {
        method = "POST", body = body, timeout_ms = 4000, headers = {"Content-Type: application/json"},
        on_response = function(r)
            local code, text = C.noctl, "whitelist: no answer from the supervisor"
            if r and (r.status or 0) >= 200 and (r.status or 0) < 300 then
                local ok, d = pcall(json.parse, r.body or "")
                local res = ok and type(d) == "table" and d.result or nil
                if type(res) == "table" and res.ok then
                    code, text = C.ok, tostring(res.text)
                elseif type(res) == "table" then
                    code, text = C.args, "whitelist: " .. tostring(res.reason or res.code)
                elseif ok and type(d) == "table" then
                    text = "whitelist: " .. tostring(d.error or d.message)
                end
            elseif r then
                text = "whitelist: supervisor http " .. tostring(r.status)
            end
            ST.stats.wl_done = (ST.stats.wl_done or 0) + 1
            if op ~= "list" then
                audit(ctx, "whitelist", args, code, text, {target = args[2]})
                if code == C.ok then M.say(KIND.op, ctx.role, ctx.sess and ctx.sess.eid or 0, ctx.by, "[op] " .. text) end
            end
            log("whitelist by=%s /%s -> %d %s", tostring(ctx.by), table.concat(args, " "), code, text:sub(1, 160))
            if done then done(code, text) end
        end})
    return C.ok, "whitelist: asking the supervisor...", {async = true, quiet = true}
end

local function split(text)
    local l = {}
    for w in text:gmatch("%S+") do l[#l + 1] = w end
    return l
end

-- ctx: {by, account, role (ROLE.*), role_name, via, admin, sess, reply?} -> code, text, cmd, args, extra
-- (extra.async: the answer comes later through ctx.reply(code, text) — /whitelist)
function M.execute(ctx, text)
    local words = split((text:gsub("^%s*/", "")))
    local cmd = (words[1] or ""):lower()
    table.remove(words, 1)
    ST.stats.cmds = ST.stats.cmds + 1
    local fn = CMDS[cmd]
    local code, out, extra
    if not fn then
        code, out = C.unknown, "unknown command /" .. cmd .. " (/help)"
    elseif ADMIN_ONLY[cmd] and not ctx.admin then
        code, out = C.forbidden, "/" .. cmd .. ": admins only"
    else
        local ok, c, o, x = pcall(fn, ctx, words)
        if ok then code, out, extra = c, o, x else code, out = C.args, "error: " .. tostring(c) end
    end
    if code ~= C.ok then ST.stats.refused[code] = (ST.stats.refused[code] or 0) + 1 end
    -- audit: every admin command (also refused ones) and every refusal by rights; read-only ones of non-admins skip
    local mutating = ADMIN_ONLY[cmd] and cmd ~= "audit" and cmd ~= "bans" and not (cmd == "fraud" and code == C.ok)
                     and not (extra and extra.async)
    if mutating or code == C.forbidden then
        audit(ctx, cmd, words, code, out, extra and {target = extra.target, eids = extra.eids} or nil)
    end
    if mutating and code == C.ok and not (extra and extra.quiet) then
        M.say(KIND.op, ctx.role, ctx.sess and ctx.sess.eid or 0, ctx.by, "[op] " .. out)
    end
    log("cmd by=%s via=%s /%s %s -> %d %s", tostring(ctx.by), ctx.via, cmd, table.concat(words, " "), code,
        tostring(out):sub(1, 160):gsub("\n", " | "))
    return code, out, cmd, words, extra
end

function M.command_from_chat(sess, text)
    sess.ops_n = (sess.ops_n or 0) + 1
    local b = sess.op_b
    if not b then b = {t = cfg.cmd_burst, at = S.tick}; sess.op_b = b end
    b.t = min(cfg.cmd_burst, b.t + (S.tick - b.at) * cfg.cmd_rate / 20)
    b.at = S.tick
    local cmd = (text:match("^%s*/(%S*)") or ""):lower()
    if b.t < 1 then
        FR.event(sess, "cmd")                         -- antifraud: a command over the rate
        net.send_client(sess.gw, sess.sid, "OpResult", {n = sess.ops_n, code = C.rate, cmd = clip(cmd, 16),
                                                        text = "too many commands"})
        return
    end
    b.t = b.t - 1
    local admin = ED.is_admin(sess)
    local ctx = {by = sess.name, account = sess.account, role = admin and ROLE.admin or ROLE.player,
                 role_name = admin and "admin" or "player", via = "chat", admin = admin, sess = sess}
    local n, cmd0 = sess.ops_n, cmd
    ctx.reply = function(code2, out2)                -- UX B: async commands (/whitelist) answer later
        pcall(net.send_client, sess.gw, sess.sid, "OpResult", {n = n, code = code2, cmd = clip(cmd0, 16),
                                                               text = clip(out2, 2048)})
    end
    local code, out, c, _, extra = M.execute(ctx, text)
    if extra and extra.async then return end
    net.send_client(sess.gw, sess.sid, "OpResult", {n = sess.ops_n, code = code, cmd = clip(c, 16), text = clip(out, 2048)})
end

-- stdin `olife.op <rid> <by> <via> "<text>"` (lab: CLI / panel); queued, executed in phase 1 of the next tick
function M.queue(rid, by, via, text)
    ST.pending[#ST.pending + 1] = {rid = rid, by = by, via = via, text = text}
    return string.format("[olife_world] op queued rid=%s", tostring(rid))
end

local function run_pending()
    if #ST.pending == 0 then return end
    local q = ST.pending
    ST.pending = {}
    for _, p in ipairs(q) do
        local by = (p.by ~= nil and p.by ~= "") and p.by or "operator"
        local ctx = {by = by, account = "", role = ROLE.operator, role_name = "operator", via = p.via or "cli", admin = true}
        local rid = p.rid
        local function emit(code, out, cmd)
            print(string.format("[olife_world] op_result rid=%s code=%d cmd=%s text=%s", tostring(rid), code, tostring(cmd),
                json.tostring(tostring(out))))
        end
        local cmd0 = ((p.text or ""):match("^%s*/?(%S+)") or "whitelist"):lower()
        ctx.reply = function(code, out) emit(code, out, cmd0) end      -- UX B: async (/whitelist, /fraud, /ban ip, /bans)
        local code, out, cmd, _, extra = M.execute(ctx, p.text)
        if not (extra and extra.async) then emit(code, out, cmd) end
    end
end

-- ------------------------------------------------------------------------------------------ hooks from server.lua
-- a frozen player: inputs do not move him, requests are refused (true = drop the message)
function M.blocked(sess, name)
    if not sess.frozen then return false end
    if name == "MoveInput" then return "keys" end
    if name == "ChatSend" or name == "Bye" or name == "ScriptOpen" or name == "ScriptLockRelease" then return false end
    ST.stats.frozen_inputs = ST.stats.frozen_inputs + 1
    if name == "PlayerInput" then return "correct" end
    if name == "ToolUse" or name == "ScriptSave" or name == "ScriptRun" or name == "ScriptStop" or name == "EntityEdit"
       or name == "BlockAction" or name == "InvAction" then
        if S.tick - (sess.frozen_notice_at or -1000) >= 20 then
            sess.frozen_notice_at = S.tick
            M.notice(sess, NOTICE.frozen, C.forbidden, 0, sess.frozen.by, "you are frozen: actions refused")
        end
        return "drop"
    end
    return false
end

-- phase 1 (after the incoming frames): stdin ops; phase 3: throttled status of benches, sandbox control, registry
function M.tick()
    run_pending()
    for _, e in pairs(S.ents) do
        if e.kind == 3 and e.code ~= nil then
            if e.sb_status == "throttled" and e.status == "run" then e.throttled_at = S.tick end
            local th = e.status == "run" and e.throttled_at ~= nil and S.tick - e.throttled_at < cfg.throttle_hold or false
            if th ~= (e.throttled or false) then
                e.throttled = th or nil
                ED.meta_changed(e)
                if th and e.owner_acct and e.owner_acct ~= "" and S.tick - (e.th_notice_at or -10000) >= 200 then
                    e.th_notice_at = S.tick
                    notice_account(e.owner_acct, NOTICE.limits, C.throttled, e.eid, "sandbox",
                        string.format("%s is throttled by its limits", mob_txt(e)))
                end
            end
        end
    end
    ctl_tick()
    if ST.dirty and S.tick - ST.saved_tick >= cfg.save_every then
        ST.dirty, ST.saved_tick = false, S.tick
        server.save_registry(true)
    end
end

-- ------------------------------------------------------------------------------------------ registry / state
function M.save()
    return {lines = ST.lines, total = ST.total, next_id = ST.next_id, bans = ST.bans, frozen = ST.frozen,
            mob_frozen = ST.mob_frozen, mob_lim = ST.mob_lim, owner_lim = ST.owner_lim, audit_total = ST.audit_total}
end

function M.load(t)
    if type(t) ~= "table" then return end
    ST.lines = t.lines or {}
    ST.total, ST.next_id = t.total or #ST.lines, t.next_id or (#ST.lines + 1)
    ST.bans, ST.frozen = t.bans or {}, t.frozen or {}
    ST.mob_frozen, ST.mob_lim, ST.owner_lim = t.mob_frozen or {}, t.mob_lim or {}, t.owner_lim or {}
    ST.audit_total = t.audit_total or 0
    local ok, txt = pcall(file.read, "world:olife_audit.jsonl")
    if ok and type(txt) == "string" then
        for line in txt:gmatch("[^\n]+") do
            local okp, r = pcall(json.parse, line)
            if okp and type(r) == "table" then ST.audit[#ST.audit + 1] = r end
        end
    end
end

-- supervisor panel (sup_state.ops): players and mobs with what the op buttons need
function M.sup_state()
    local mobs = {}
    for _, e in ipairs(mobs_of(nil)) do
        if #mobs >= 200 then break end
        local mt = ED.is_bench(e) and ED.meters_of(e) or {}
        mobs[#mobs + 1] = {eid = e.eid, name = e.name, owner = e.owner_acct or "", status = SHOW[ED.shown_status(e)],
                           frozen = e.frozen ~= nil, lim = e.op_lim, credits_min = mt.credits_min, owner_id = e.owner}
    end
    local players = {}
    for _, s in pairs(S.sessions) do
        players[#players + 1] = {eid = s.eid, name = s.name, account = s.account, admin = ED.is_admin(s),
                                 frozen = s.frozen ~= nil}
    end
    table.sort(players, function(a, b) return a.eid < b.eid end)
    local bans = {}
    for a, b in pairs(ST.bans) do bans[#bans + 1] = {account = a, until_ms = b.until_ms, reason = b.reason, by = b.by} end
    local aud = {}
    for i = max(1, #ST.audit - 9), #ST.audit do aud[#aud + 1] = ST.audit[i] end
    for _, p in ipairs(players) do
        local s = S.by_eid[p.eid]
        if s then p.ip = FR.ip_of(s) end
    end
    return {fraud = FR.sup_state(),
            mobs = mobs, players = players, bans = bans, frozen = ST.frozen, owner_lim = ST.owner_lim, audit = aud,
            audit_total = ST.audit_total, chat_total = ST.total, ctl = {state = ctl.state, port = scfg.sbctl or 0,
            last = ctl.last}}
end

function M.status()
    local r = {}
    for c, n in pairs(ST.stats.refused) do r[#r + 1] = c .. ":" .. n end
    table.sort(r)
    local s = ST.stats
    local nb, nf = 0, 0
    for _ in pairs(ST.bans) do nb = nb + 1 end
    for _ in pairs(ST.mob_frozen) do nf = nf + 1 end
    return string.format("ops chat=%d chat_throttled=%d history_sent=%d lines=%d total=%d cmds=%d refused={%s} notices=%d " ..
        "audits=%d audit_total=%d bans=%d frozen_mobs=%d frozen_inputs=%d bans_refused=%d mob_limited=%d ctl=%s/%d " ..
        "ctl_sent=%d ctl_ok=%d ctl_err=%d", s.chat, s.chat_throttled, s.history_sent, #ST.lines, ST.total, s.cmds,
        table.concat(r, ","), s.notices, s.audits, ST.audit_total, nb, nf, s.frozen_inputs, s.bans_refused,
        s.mob_limited, ctl.state, scfg.sbctl or 0, s.ctl_sent, s.ctl_ok, s.ctl_err)
end

-- stdin `olife.op_state`: everything the lab checks, as JSON (user:export/ops_state.json)
function M.dump()
    local st = M.sup_state()
    st.stats, st.lines, st.ctl_replies = ST.stats, ST.lines, ctl.replies
    st.bans_full = ST.bans
    local ok, err = pcall(file.write, "user:export/ops_state.json", json.tostring(st))
    return ok and ("[olife_world] op_state written user:export/ops_state.json " .. M.status())
              or ("[olife_world] op_state failed: " .. tostring(err))
end

return M
