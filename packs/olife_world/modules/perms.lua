-- olife_world:perms — UX A1 (03.10, olife_a1): the "repository" ownership model of benches (OLIFE_UX §4).
-- Every bench has an owner account and, per ACTION, an AUDIENCE: 0 owner only, 1 owner + friends, 2 owner + a list of
-- accounts, 3 everyone. Admins (Attach.perms bit 1 or `olife.admins`) pass every check. The world decides everything:
-- editor/gravity/delete/settings/fork call M.allowed (future spammer / storage too: M.allowed(sess, e, "storage_read")).
-- Friends are per account: requests, accept/deny, remove; the world keeps them (registry) and reports every change to
-- the supervisor as an event (sup_state `friends_ev`) — the supervisor DB (friends table) is the durable copy and pushes
-- its state back at world start (`olife.friends <spec>`) and on operator changes (`olife.friend_set a b state`).
local net = require "olife_world:net"

local M = {}
local server, editor, S
local min, max = math.min, math.max

M.ACTIONS = {"move", "read_code", "edit_code", "run", "appearance", "clone", "destroy", "storage_read", "storage_write"}
local AID = {}
for i, a in ipairs(M.ACTIONS) do AID[a] = i end
M.AID = AID
M.AUDIENCES = {[0] = "owner", [1] = "friends", [2] = "list", [3] = "everyone"}
local AUD_ID = {owner = 0, friends = 1, list = 2, everyone = 3}
M.AUD_ID = AUD_ID
-- defaults (documented in content/olife_world/README.md): code is public to read (like a public repository, and the
-- editor has always opened read-only for everybody); everything that changes, moves, copies or removes the entity
-- is the owner's until the owner shares it
M.DEFAULT = {move = 0, read_code = 3, edit_code = 0, run = 0, appearance = 0, clone = 0, destroy = 0,
             storage_read = 0, storage_write = 0}

local cfg = {list_max = 32, friends_max = 256, pending_max = 64, fork_per_min = 10, ev_keep = 128}
M.cfg = cfg

local ST = {friends = {}, pending = {}, known = {}, defaults = {}, closed = {}, ev = {}, ev_id = 0, script_deny = {},
            stats = {perms_set = 0, checks = 0, denied = {}, forks = 0, friend_ops = 0, lists = 0, perms_sent = 0}}
M.ST = ST

local function log(fmt, ...) print("[olife_world] perms: " .. string.format(fmt, ...)) end

function M.init(srv, ed)
    server, editor, S = srv, ed, srv.S
    if not ST.wid then        -- identity of this world save: the supervisor keeps "last applied event" per wid
        local okt, t = pcall(os.time)
        ST.wid = string.format("w%x%04x", okt and t or 0, math.random(0, 65535))
        editor.mark_dirty()
    end
    -- A4 (olife_world:store): the Spammer snapshot keeps the rules; a restored entity gets them back
    local oks, store = pcall(require, "olife_world:store")
    if oks and type(store) == "table" and type(store.snapshot_hooks) == "table" then
        store.snapshot_hooks.perms = {
            save = function(e)
                local rec = {}
                M.save_fields(e, rec)
                return rec.perms and {perms = rec.perms} or nil
            end,
            load = function(e, t) if type(t) == "table" then M.load_fields(e, {perms = t.perms}) end end,
        }
    end
end

-- A3 (olife_world:mobapi): may the SCRIPT of entity e do an action class (appearance, anim, sound, blocks, memory,
-- query) on itself? The script is its owner's code: yes, unless the owner's account settings deny the class
-- (account_settings `script.deny=blocks,sound` -> `olife.acct_settings`). Rights of players are M.allowed.
function M.script_allowed(e, action)
    local d = ST.script_deny[e.owner_acct or ""]
    if d and (d[action] or d["*"]) then return false end
    return true
end

local function valid_acct(a)
    return type(a) == "string" and #a >= 1 and #a <= 64 and a:match("^[%w_%.%-]+$") ~= nil
end
M.valid_acct = valid_acct

-- ------------------------------------------------------------------------------------------ rules
local function copy_list(l)
    local out = {}
    for i, a in ipairs(l or {}) do out[i] = a end
    return out
end

-- the rule of `action` for entity e: {a = audience, l = list}; entities without rules use the account defaults
-- (set by the supervisor, account_settings `perms.default`) or M.DEFAULT
function M.rule(e, action)
    local p = e.perms and e.perms[action]
    if p then return p end
    local d = ST.defaults[e.owner_acct or ""]
    return {a = (d and d[action]) or M.DEFAULT[action] or 0, l = {}}
end

-- a new bench (spawn, sample, fork): its own copy of the owner's defaults
function M.init_entity(e, from)
    e.perms = {}
    for _, a in ipairs(M.ACTIONS) do
        local r = from and M.rule(from, a) or M.rule(e, a)
        e.perms[a] = {a = r.a, l = copy_list(r.l)}
    end
end

function M.are_friends(a, b)
    local f = ST.friends[a]
    return f ~= nil and f[b] == true
end

local function in_list(l, acct)
    for _, x in ipairs(l or {}) do if x == acct then return true end end
    return false
end

-- may session `sess` do `action` with entity e? -> ok, reason (for RequestReply code 3)
function M.allowed(sess, e, action)
    ST.stats.checks = ST.stats.checks + 1
    if editor.is_admin(sess) then return true end
    local owner = e.owner_acct or ""
    if owner ~= "" and sess.account == owner then return true end
    if not editor.is_bench(e) then          -- legacy scripted entities (orbit, neg_*): anyone may grab, nothing else
        if action == "move" then return true end
        return false, "forbidden: " .. action .. " (not a bench)"
    end
    local r = M.rule(e, action)
    if r.a == 3 then return true end
    if owner ~= "" then
        if r.a == 1 and M.are_friends(owner, sess.account) then return true end
        if r.a == 2 and in_list(r.l, sess.account) then return true end
    end
    ST.stats.denied[action] = (ST.stats.denied[action] or 0) + 1
    return false, ("forbidden: %s is for %s%s"):format(action, M.AUDIENCES[r.a] or "?",
        owner == "" and " (world entity: admins)" or "")
end

function M.mask(sess, e)
    local m = 0
    for i, a in ipairs(M.ACTIONS) do
        local saved = ST.stats.checks
        if M.allowed(sess, e, a) then m = m + 2 ^ (i - 1) end
        ST.stats.checks = saved
    end
    return m
end

function M.can_admin(sess, e)
    return editor.is_admin(sess) or ((e.owner_acct or "") ~= "" and e.owner_acct == sess.account)
end

local function perms_msg(sess, e, seq)
    local rules = {}
    for i, a in ipairs(M.ACTIONS) do
        local r = M.rule(e, a)
        rules[i] = {action = i, audience = r.a, list = copy_list(r.l)}
    end
    -- denied counters must not grow from building the mask
    local d = {}
    for k, v in pairs(ST.stats.denied) do d[k] = v end
    local m = M.mask(sess, e)
    ST.stats.denied = d
    return {eid = e.eid, seq = seq or 0, owner = (e.owner_acct or ""):sub(1, 64), rules = rules, mine = m,
            can_admin = M.can_admin(sess, e)}
end

function M.send_perms(sess, e, seq)
    ST.stats.perms_sent = ST.stats.perms_sent + 1
    net.send_client(sess.gw, sess.sid, "EntityPerms", perms_msg(sess, e, seq))
end

function M.push_perms(e)
    for skey in pairs(e.subs or {}) do
        local s = S.sessions[skey]
        if s then M.send_perms(s, e, 0) end
    end
end

-- after friend changes of accounts a/b: subscribers of their entities (and their own subscriptions) see new masks
local function repush_for(a, b)
    for _, e in pairs(S.ents) do
        if e.subs and editor.is_bench(e) then
            local own = e.owner_acct == a or e.owner_acct == b
            for skey in pairs(e.subs) do
                local s = S.sessions[skey]
                if s and (own or s.account == a or s.account == b) then M.send_perms(s, e, 0) end
            end
        end
    end
end

local function describe_rules(e)
    local out = {}
    for _, a in ipairs(M.ACTIONS) do
        local r = M.rule(e, a)
        out[#out + 1] = a .. "=" .. (M.AUDIENCES[r.a] or "?") .. (r.a == 2 and ("[" .. table.concat(r.l, "|") .. "]") or "")
    end
    return table.concat(out, " ")
end
M.describe_rules = describe_rules

-- ------------------------------------------------------------------------------------------ requests
-- EntityPermsSet{seq, eid, action, audience, list} -> RequestReply op 8 (owner / admin only)
function M.EntityPermsSet(sess, m)
    local e = editor.target(sess, m.seq, editor.OP.perms, m.eid, false)
    if not e then return end
    if not M.can_admin(sess, e) then
        return editor.reply(sess, m.seq, editor.OP.perms, e.eid, 3, "forbidden: only the owner or an admin changes rights")
    end
    local a = M.ACTIONS[m.action]
    if not a then return editor.reply(sess, m.seq, editor.OP.perms, e.eid, 15, "bad action") end
    if not M.AUDIENCES[m.audience] then return editor.reply(sess, m.seq, editor.OP.perms, e.eid, 15, "bad audience") end
    local l, seen = {}, {}
    for _, x in ipairs(m.list or {}) do
        if not valid_acct(x) then return editor.reply(sess, m.seq, editor.OP.perms, e.eid, 15, "bad account in list") end
        if not seen[x] then seen[x] = true; l[#l + 1] = x end
    end
    if #l > cfg.list_max then return editor.reply(sess, m.seq, editor.OP.perms, e.eid, 18, "list too long") end
    if not e.perms then M.init_entity(e) end
    local old = e.perms[a] or M.rule(e, a)
    -- a list is kept when another audience is chosen with an empty list (switching back restores it)
    if #l == 0 and m.audience ~= 2 then l = copy_list(old.l) end
    e.perms[a] = {a = m.audience, l = l}
    ST.stats.perms_set = ST.stats.perms_set + 1
    editor.mark_dirty()
    editor.console_add(e, 2, ("rights: %s -> %s%s by %s"):format(a, M.AUDIENCES[m.audience],
        m.audience == 2 and (" [" .. table.concat(l, ",") .. "]") or "", sess.name))
    log("eid=%d %s -> %s by %s (%s)", e.eid, a, M.AUDIENCES[m.audience], sess.name, sess.account)
    editor.reply(sess, m.seq, editor.OP.perms, e.eid, 0)
    if not (e.subs and e.subs[sess.key]) then M.send_perms(sess, e, m.seq) end
    M.push_perms(e)
end

-- PermsCheck{seq, eid, action} -> RequestReply op 11: 0 allowed, 3 forbidden (the reason names the rule)
function M.PermsCheck(sess, m)
    local e = editor.target(sess, m.seq, editor.OP.check, m.eid, false)
    if not e then return end
    local a = M.ACTIONS[m.action]
    if not a then return editor.reply(sess, m.seq, editor.OP.check, e.eid, 15, "bad action") end
    local ok, why = M.allowed(sess, e, a)
    return editor.reply(sess, m.seq, editor.OP.check, e.eid, ok and 0 or 3, ok and ("allowed: " .. a) or why)
end

-- EntityFork{seq, eid, name} -> a new bench of the requester: code, rights, name tag, model/texture of the source,
-- stopped, 2 blocks in front of the requester (inside the play area); RequestReply op 9 + EntityForked
function M.EntityFork(sess, m)
    local e = editor.target(sess, m.seq, editor.OP.fork, m.eid, false)
    if not e then return end
    local ok, why = M.allowed(sess, e, "clone")
    if not ok then return editor.reply(sess, m.seq, editor.OP.fork, e.eid, 3, why) end
    local name = m.name ~= "" and m.name or ((e.name or "bench"):sub(1, 27) .. "_fork")
    if not name:match("^[%w_ %-]+$") or #name > 32 or not name:match("%S") then
        return editor.reply(sess, m.seq, editor.OP.fork, e.eid, 15, "bad name")
    end
    local now = S.tick
    local fl = sess.fork_times or {}
    local keep = {}
    for _, t in ipairs(fl) do if now - t < 1200 then keep[#keep + 1] = t end end
    if #keep >= cfg.fork_per_min then
        sess.fork_times = keep
        return editor.reply(sess, m.seq, editor.OP.fork, e.eid, 18, "fork limit: " .. cfg.fork_per_min .. " a minute")
    end
    keep[#keep + 1] = now
    sess.fork_times = keep
    local l = editor.spawn_bench(sess.account, name, 1, e.code)
    local f = S.ents[l[1]]
    local yaw = math.rad(sess.rot.x or 0)
    local fx, fz = -math.sin(yaw), -math.cos(yaw)
    local px, pz = sess.pos.x + fx * 2, sess.pos.z + fz * 2
    local sp, area = S.spawn, editor.cfg.area - 1
    local dx, dz = px - sp.x, pz - sp.z
    local r = math.sqrt(dx * dx + dz * dz)
    if r > area then px, pz = sp.x + dx / r * area, sp.z + dz / r * area end
    f.pos.x, f.pos.y, f.pos.z = px, max(1, min(255, sess.pos.y + 1.0)), pz
    f.model, f.texture = e.model, e.texture
    if f.model or f.texture then f.look_ver = (f.look_ver or 0) + 1 end
    M.init_entity(f, e)
    f.forked_from = {eid = e.eid, owner = e.owner_acct or "", name = e.name or "", code_fnv = editor.fnv_str(e.code or "")}
    editor.console_add(f, 2, ("forked from #%d %s [%s] by %s"):format(e.eid, tostring(e.name), tostring(e.owner_acct),
        sess.name))
    editor.console_add(e, 2, ("forked by %s -> #%d"):format(sess.name, f.eid))
    -- A4: the entity's files (asset slots) and KV memory go along (CAS: shared files, the forker's quota)
    local okst, store = pcall(require, "olife_world:store")
    if okst and type(store) == "table" and type(store.fork) == "function" then
        local okf, code, reason = pcall(store.fork, e.eid, f.eid, sess.account)
        f.fork_assets = okf and tostring(code) or ("error " .. tostring(code))
        if not okf or (code ~= 0 and code ~= nil and code ~= true) then
            editor.console_add(f, 1, "fork: assets not copied: " .. tostring(reason or code))
        end
    end
    editor.mark_dirty()
    ST.stats.forks = ST.stats.forks + 1
    log("eid=%d forked by %s (%s) -> eid=%d %s", e.eid, sess.name, sess.account, f.eid, f.name)
    editor.reply(sess, m.seq, editor.OP.fork, e.eid, 0, "forked #" .. f.eid)
    net.send_client(sess.gw, sess.sid, "EntityForked", {seq = m.seq, src = e.eid, eid = f.eid, name = f.name:sub(1, 32)})
end

-- ------------------------------------------------------------------------------------------ friends
local function ev(op, a, b)
    ST.ev_id = ST.ev_id + 1
    ST.ev[#ST.ev + 1] = {ST.ev_id, op, a, b}
    while #ST.ev > cfg.ev_keep do table.remove(ST.ev, 1) end
    editor.mark_dirty()
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function set_friend(a, b, on)
    ST.friends[a] = ST.friends[a] or {}
    ST.friends[b] = ST.friends[b] or {}
    ST.friends[a][b] = on or nil
    ST.friends[b][a] = on or nil
    if ST.pending[a] then ST.pending[a][b] = nil end
    if ST.pending[b] then ST.pending[b][a] = nil end
end

local function set_pending(from, to, on)
    ST.pending[from] = ST.pending[from] or {}
    ST.pending[from][to] = on and (S and S.tick or 0) or nil
end

local function online(acct)
    for _, s in pairs(S.sessions) do if s.account == acct then return true end end
    return false
end

local function sorted_keys(t)
    local l = {}
    for k in pairs(t or {}) do l[#l + 1] = k end
    table.sort(l)
    return l
end

local function friend_list_msg(acct, seq)
    local fr = {}
    for _, b in ipairs(sorted_keys(ST.friends[acct])) do fr[#fr + 1] = {account = b, online = online(b)} end
    local inc = {}
    for from, tos in pairs(ST.pending) do if tos[acct] then inc[#inc + 1] = from end end
    table.sort(inc)
    local out = sorted_keys(ST.pending[acct])
    while #inc > 64 do table.remove(inc) end
    while #out > 64 do table.remove(out) end
    return {seq = seq or 0, friends = fr, incoming = inc, outgoing = out}
end
M.friend_list_msg = friend_list_msg

function M.send_friends(sess, seq)
    ST.stats.lists = ST.stats.lists + 1
    net.send_client(sess.gw, sess.sid, "FriendList", friend_list_msg(sess.account, seq))
end

local function push_friends(acct, except_key)
    for k, s in pairs(S.sessions) do
        if s.account == acct and k ~= except_key then M.send_friends(s, 0) end
    end
end

-- FriendRequest{seq, op, account} -> RequestReply op 10 (+ FriendList to both sides)
function M.FriendRequest(sess, m)
    editor.bill(sess)
    local OPF = editor.OP.friend
    if not editor.bucket(sess, "req_b", editor.cfg.req_rate, editor.cfg.req_burst) then
        return editor.reply(sess, m.seq, OPF, 0, 9)
    end
    ST.stats.friend_ops = ST.stats.friend_ops + 1
    local me, b = sess.account, m.account
    if m.op == 5 then
        M.send_friends(sess, m.seq)
        return editor.reply(sess, m.seq, OPF, 0, 0, "list")
    end
    if m.op < 1 or m.op > 4 then return editor.reply(sess, m.seq, OPF, 0, 15, "bad op") end
    if not valid_acct(b) then return editor.reply(sess, m.seq, OPF, 0, 16, "bad account name") end
    if b == me then return editor.reply(sess, m.seq, OPF, 0, 16, "that is you") end
    local why
    if m.op == 1 then
        if not ST.known[b] then return editor.reply(sess, m.seq, OPF, 0, 16, "unknown account " .. b) end
        if M.are_friends(me, b) then
            why = "already friends"
        elseif ST.pending[b] and ST.pending[b][me] then          -- the other side asked first: friends at once
            if count(ST.friends[me]) >= cfg.friends_max or count(ST.friends[b]) >= cfg.friends_max then
                return editor.reply(sess, m.seq, OPF, 0, 18, "too many friends")
            end
            set_friend(me, b, true)
            ev("friend", me, b)
            why = "friends"
        else
            if ST.closed[b] then return editor.reply(sess, m.seq, OPF, 0, 3, "forbidden: " .. b .. " does not take requests") end
            if count(ST.pending[me]) >= cfg.pending_max then return editor.reply(sess, m.seq, OPF, 0, 18, "too many requests") end
            set_pending(me, b, true)
            ev("request", me, b)
            why = "requested"
        end
    elseif m.op == 2 then
        if not (ST.pending[b] and ST.pending[b][me]) then return editor.reply(sess, m.seq, OPF, 0, 17, "no request from " .. b) end
        if count(ST.friends[me]) >= cfg.friends_max or count(ST.friends[b]) >= cfg.friends_max then
            return editor.reply(sess, m.seq, OPF, 0, 18, "too many friends")
        end
        set_friend(me, b, true)
        ev("friend", me, b)
        why = "accepted"
    elseif m.op == 3 then
        if ST.pending[b] and ST.pending[b][me] then
            set_pending(b, me, false)
            ev("cancel", b, me)
            why = "denied"
        elseif ST.pending[me] and ST.pending[me][b] then
            set_pending(me, b, false)
            ev("cancel", me, b)
            why = "cancelled"
        else
            return editor.reply(sess, m.seq, OPF, 0, 17, "no request between you and " .. b)
        end
    elseif m.op == 4 then
        if not M.are_friends(me, b) then return editor.reply(sess, m.seq, OPF, 0, 17, "not friends with " .. b) end
        set_friend(me, b, false)
        ev("unfriend", me, b)
        why = "removed"
    end
    log("friend op=%d %s -> %s: %s", m.op, me, b, why)
    editor.reply(sess, m.seq, OPF, 0, 0, why)
    M.send_friends(sess, m.seq)
    push_friends(me, sess.key)
    push_friends(b)
    repush_for(me, b)
end

-- ------------------------------------------------------------------------------------------ sessions
-- phase 4 (editor.replicate): the first tick of a session -> its FriendList, friends see it online
function M.replicate(sess)
    if sess.a1_seen then return end
    sess.a1_seen = true
    if not ST.known[sess.account] then ST.known[sess.account] = true; editor.mark_dirty() end
    M.send_friends(sess, 0)
    for b in pairs(ST.friends[sess.account] or {}) do push_friends(b) end
end

function M.on_session_removed(sess)
    local still = false
    for k, s in pairs(S.sessions) do if s.account == sess.account and k ~= sess.key then still = true end end
    if still then return end
    for b in pairs(ST.friends[sess.account] or {}) do push_friends(b) end
end

-- ------------------------------------------------------------------------------------------ registry
function M.save_fields(e, rec)
    if e.perms then
        local p = {}
        for a, r in pairs(e.perms) do p[a] = {r.a, copy_list(r.l)} end
        rec.perms = p
    end
    rec.forked_from = e.forked_from
end

function M.load_fields(e, r)
    if type(r.perms) == "table" then
        e.perms = {}
        for a, x in pairs(r.perms) do
            if AID[a] and type(x) == "table" then e.perms[a] = {a = tonumber(x[1]) or 0, l = copy_list(x[2])} end
        end
    end
    e.forked_from = r.forked_from
end

local function pairs_list()
    local fr, pend = {}, {}
    for a, t in pairs(ST.friends) do
        for b in pairs(t) do if a < b then fr[#fr + 1] = {a, b} end end
    end
    for a, t in pairs(ST.pending) do
        for b in pairs(t) do pend[#pend + 1] = {a, b} end
    end
    table.sort(fr, function(x, y) return x[1] .. "+" .. x[2] < y[1] .. "+" .. y[2] end)
    table.sort(pend, function(x, y) return x[1] .. ">" .. x[2] < y[1] .. ">" .. y[2] end)
    return fr, pend
end

function M.save_top()
    local fr, pend = pairs_list()
    return {friends = fr, pending = pend, known = sorted_keys(ST.known), defaults = ST.defaults,
            closed = sorted_keys(ST.closed), ev = ST.ev, ev_id = ST.ev_id, wid = ST.wid}
end

function M.load_top(t)
    if type(t) ~= "table" then return end
    for _, p in ipairs(t.friends or {}) do set_friend(p[1], p[2], true) end
    for _, p in ipairs(t.pending or {}) do set_pending(p[1], p[2], true) end
    for _, a in ipairs(t.known or {}) do ST.known[a] = true end
    for _, a in ipairs(t.closed or {}) do ST.closed[a] = true end
    if type(t.defaults) == "table" then ST.defaults = t.defaults end
    if type(t.ev) == "table" then ST.ev = t.ev end
    ST.ev_id = max(ST.ev_id, tonumber(t.ev_id) or 0)
    if type(t.wid) == "string" then ST.wid = t.wid end
end

-- supervisor state (server.sup_state): friend events since the world was created (ring of 128, ids keep growing)
function M.sup_events()
    return {wid = ST.wid, last = ST.ev_id, events = ST.ev}
end

-- ------------------------------------------------------------------------------------------ admin (stdin)
-- spec of the supervisor: comma separated items "a+b" friends, "a>b" request from a to b, "=a" known account
local function apply_spec(spec, replace)
    if replace then ST.friends, ST.pending = {}, {} end
    local nf, np, nk = 0, 0, 0
    for item in tostring(spec or ""):gmatch("[^,%s]+") do
        local a, b = item:match("^([%w_%.%-]+)%+([%w_%.%-]+)$")
        if a then
            set_friend(a, b, true); ST.known[a], ST.known[b] = true, true; nf = nf + 1
        else
            a, b = item:match("^([%w_%.%-]+)>([%w_%.%-]+)$")
            if a then
                if not M.are_friends(a, b) then set_pending(a, b, true) end
                ST.known[a], ST.known[b] = true, true
                np = np + 1
            else
                a = item:match("^=([%w_%.%-]+)$")
                if a then ST.known[a] = true; nk = nk + 1 end
            end
        end
    end
    editor.mark_dirty()
    return nf, np, nk
end

local function push_all()
    for _, s in pairs(S.sessions) do M.send_friends(s, 0) end
    for _, e in pairs(S.ents) do if e.subs and editor.is_bench(e) then M.push_perms(e) end end
end

function M.friends_line()
    local fr, pend = pairs_list()
    local a, b = {}, {}
    for _, p in ipairs(fr) do a[#a + 1] = p[1] .. "+" .. p[2] end
    for _, p in ipairs(pend) do b[#b + 1] = p[1] .. ">" .. p[2] end
    return ("[olife_world] friends pairs=%s pending=%s known=%d ev=%d"):format(#a > 0 and table.concat(a, ",") or "-",
        #b > 0 and table.concat(b, ",") or "-", count(ST.known), ST.ev_id)
end

function M.register_commands()
    console.add_command("bench_perms eid:int action:str='' audience:str='' list:str=''",
        "UX A1: rights of a bench; with action+audience (owner|friends|list|everyone, list = a|b|c) sets one rule (admin)",
        function(args)
            local e = S.ents[args[1]]
            if not editor.is_bench(e) then return "[olife_world] perms: no bench eid=" .. tostring(args[1]) end
            if args[2] ~= "" then
                local a, aud = args[2], AUD_ID[args[3]]
                if not AID[a] or not aud then return "[olife_world] perms: bad action/audience " .. a .. " " .. args[3] end
                if not e.perms then M.init_entity(e) end
                local l = {}
                for x in tostring(args[4]):gmatch("[^|,%s]+") do if valid_acct(x) then l[#l + 1] = x end end
                e.perms[a] = {a = aud, l = l}
                editor.mark_dirty()
                M.push_perms(e)
            end
            return ("[olife_world] perms eid=%d owner=%s %s"):format(e.eid, tostring(e.owner_acct), describe_rules(e))
        end)
    console.add_command("olife.friends spec:str=''",
        "UX A1 (supervisor): replace friends/requests/known accounts: a+b friends, a>b request, =a known (comma separated)",
        function(args)
            local nf, np, nk = apply_spec(args[1], true)
            push_all()
            return ("[olife_world] friends loaded friends=%d pending=%d known=%d"):format(nf, np, nk)
        end)
    console.add_command("olife.friend_set a:str b:str state:str",
        "UX A1 (supervisor/operator): one pair: friend | request (a asks b) | off",
        function(args)
            local a, b, st = args[1], args[2], args[3]
            if not valid_acct(a) or not valid_acct(b) or a == b then return "[olife_world] friend_set: bad accounts" end
            ST.known[a], ST.known[b] = true, true
            if st == "friend" then set_friend(a, b, true)
            elseif st == "request" then if not M.are_friends(a, b) then set_pending(a, b, true) end
            elseif st == "off" or st == "none" then        -- NB: the 0.32 console parser turns the word `none` into nil
                set_friend(a, b, false); set_pending(a, b, false); set_pending(b, a, false)
            else return "[olife_world] friend_set: state friend|request|off" end
            editor.mark_dirty()
            push_friends(a); push_friends(b); repush_for(a, b)
            return ("[olife_world] friend_set %s %s %s"):format(a, b, st)
        end)
    console.add_command("friends", "UX A1: friend pairs, pending requests, known accounts, last event id",
        function() return M.friends_line() end)
    console.add_command("friends_ev since:int=0", "UX A1: friend events after id <since> (supervisor sync)",
        function(args)
            local out = {("[olife_world] friends_ev wid=%s last=%d"):format(tostring(ST.wid), ST.ev_id)}
            for _, e in ipairs(ST.ev) do
                if e[1] > args[1] then
                    out[#out + 1] = ("[olife_world] fev id=%d op=%s a=%s b=%s"):format(e[1], e[2], e[3], e[4])
                end
            end
            return table.concat(out, "\n")
        end)
    console.add_command("olife.acct_settings account:str spec:str=''",
        "UX A1 (supervisor account_settings): perms.default=move:friends;clone:everyone and friends.requests=open|closed " ..
        "(';' separated key=value)", function(args)
            local acct = args[1]
            if not valid_acct(acct) then return "[olife_world] acct_settings: bad account" end
            local d = {}
            for kv in tostring(args[2]):gmatch("[^;]+") do
                local k, v = kv:match("^([%w_%.]+)=(.*)$")
                if k == "perms.default" then
                    for a, aud in v:gmatch("([%w_]+):([%w_]+)") do
                        if AID[a] and AUD_ID[aud] then d[a] = AUD_ID[aud] end
                    end
                elseif k == "friends.requests" then
                    ST.closed[acct] = v == "closed" or nil
                elseif k == "script.deny" then
                    local sd = {}
                    for c in v:gmatch("[%w_%*]+") do sd[c] = true end
                    ST.script_deny[acct] = next(sd) and sd or nil
                end
            end
            ST.defaults[acct] = next(d) and d or nil
            editor.mark_dirty()
            local l = {}
            for a, v in pairs(d) do l[#l + 1] = a .. ":" .. M.AUDIENCES[v] end
            table.sort(l)
            return ("[olife_world] acct_settings %s defaults=%s requests=%s"):format(acct, #l > 0 and table.concat(l, ",") or "-",
                ST.closed[acct] and "closed" or "open")
        end)
end

function M.status()
    local s = ST.stats
    local d = {}
    for a, n in pairs(s.denied) do d[#d + 1] = a .. ":" .. n end
    table.sort(d)
    return ("perms(set=%d,checks=%d,forks=%d,friend_ops=%d,lists=%d,perms_sent=%d,denied={%s})"):format(s.perms_set,
        s.checks, s.forks, s.friend_ops, s.lists, s.perms_sent, table.concat(d, ","))
end

return M
