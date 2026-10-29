-- olife_world:fraud — антифрод в игре (16.10, olife_antifraud; agents/research/OLIFE_ANTIFRAUD.md §1 п.9–10).
-- Очки на АККАУНТ (переживают переподключение): событие отказа сверх тарифа/квоты = вес (chat — строка чата сверх ведра,
-- cmd — «/»-команда сверх частоты, action — блок сверх ведра, req — запрос редактора/инструмента сверх ведра, spawn —
-- спавн сверх spawn_per_min, reconnect — вход сверх reconnect_free за окно), экспоненциальное затухание (полураспад
-- score_half_life_s). Пороги × доверие аккаунта (снятие ложного срабатывания опом ×2): warn -> Notice 13 (тост+звук),
-- throttle -> Notice 14 и на throttle_s чат/блоки/запросы отбрасываются (движение — нет), kick -> Detach 10
-- «antifraud: …», ban -> бан аккаунта в мире (ops, by=fraud) + kick 5 + отчёт supervisor (`olife.fraud report`:
-- срок растёт со страйками, 2-й автобан -> бан IP). Настройки/доверие/снятия — с supervisor раз в 5 с
-- (POST /call/olife.fraud {action=cfg}, --opts sup=<порт демона>); без него — умолчания ниже.
local net = require "olife_world:net"
local U = require "olife_proto:util"

local M = {}
local server, ops, S, scfg
local floor, min, max = math.floor, math.min, math.max

local D = {
    enabled = 1, score_half_life_s = 30, w_chat = 1, w_cmd = 1, w_action = 1, w_req = 1, w_spawn = 2, w_reconnect = 3,
    reconnect_free = 3, reconnect_window_s = 60, warn = 10, throttle = 20, kick = 35, ban = 50, throttle_s = 15,
    ban_base_min = 5, autoban_factor = 2,
}
local cfg = {}
for k, v in pairs(D) do cfg[k] = v end
-- exempt networks (supervisor `exempt`, default the local player / lab bots): scored and warned, never throttled,
-- kicked or banned automatically
cfg.exempt = {"127.0.0.1/32"}
M.cfg = cfg
M.CODE = 22                                   -- Notice/OpResult code of the antifraud
local EV_WARN, EV_THROTTLE = 13, 14            -- Notice.event (client chat.lua NOTICE_EV)
local KIND_RU = {chat = "чат", cmd = "команды", action = "блоки", req = "запросы", spawn = "спавн",
                 reconnect = "переподключения"}

local ST = {
    acct = {},          -- account -> {score, t, level, warned, throttle_until, kicks, bans, n = {kind = count}, last}
    events = {}, total = 0,
    trust = {}, cleared = {}, attaches = {},
    poll = {at = -1000, busy = false, ok = 0, err = 0, last = nil},
    stats = {events = 0, warns = 0, throttles = 0, kicks = 0, bans = 0, dropped = 0, reports = 0, report_err = 0},
}
M.ST = ST

local function log(fmt, ...) print("[olife_world] fraud: " .. string.format(fmt, ...)) end
local function now_ms() return U.now_ms() end
local function clip(s, n)                -- byte limit without cutting a UTF-8 character (antifraud: Russian texts)
    s = tostring(s or "")
    if #s <= n then return s end
    local i = n
    while i > 0 and s:byte(i + 1) and s:byte(i + 1) >= 0x80 and s:byte(i + 1) < 0xC0 do i = i - 1 end
    return s:sub(1, i)
end

function M.init(srv, opsmod, server_cfg)
    server, ops, scfg = srv, opsmod, server_cfg
    S = srv.S
end

-- ------------------------------------------------------------------------------------------ addresses
function M.ip_of(sess)
    local a = tostring(sess and sess.addr or "")
    local v4 = a:match("^(%d+%.%d+%.%d+%.%d+)")
    if v4 then return v4 end
    return (a:match("^%[(.-)%]") or a:match("^(.*):%d+$") or a)
end

function M.mask(ip)
    local a, b = tostring(ip):match("^(%d+)%.(%d+)%.")
    if a then return a .. "." .. b .. ".x.x" end
    return (tostring(ip):match("^([^:]*:[^:]*)") or "?") .. ":x"
end

local function v4num(ip)
    local a, b, c, d = tostring(ip):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end

-- IPv4 address in "a.b.c.d" | "a.b.c.d/n" (IPv6: only exact text)
function M.in_net(ip, netw)
    local addr, p = tostring(netw):match("^([^/]+)/(%d+)$")
    addr, p = addr or tostring(netw), tonumber(p) or 32
    local x, y = v4num(ip), v4num(addr)
    if not x or not y then return tostring(ip) == addr end
    local div = 2 ^ (32 - p)
    return floor(x / div) == floor(y / div)
end

-- ------------------------------------------------------------------------------------------ scores
local function st_of(account)
    local a = ST.acct[account]
    if not a then
        a = {score = 0, t = now_ms(), warned = -1e12, throttle_until = 0, kicks = 0, bans = 0, n = {}, level = ""}
        ST.acct[account] = a
    end
    return a
end

local function decay(a, t)
    local half = max(1, cfg.score_half_life_s) * 1000
    if t > a.t then a.score = a.score * 0.5 ^ ((t - a.t) / half) end
    a.t = t
end

function M.score(account)
    local a = ST.acct[account]
    if not a then return 0 end
    decay(a, now_ms())
    return a.score
end

local function trust_of(account) return max(1, tonumber(ST.trust[account]) or 1) end

local function reasons(a)
    local l = {}
    for k, n in pairs(a.n) do l[#l + 1] = string.format("%s %d", KIND_RU[k] or k, n) end
    table.sort(l)
    return table.concat(l, ", ")
end

local function push_event(rec)
    ST.total = ST.total + 1
    rec.n, rec.ms = ST.total, now_ms()
    ST.events[#ST.events + 1] = rec
    while #ST.events > 200 do table.remove(ST.events, 1) end
end

local function sessions_of(account)
    local l = {}
    for _, s in pairs(S.sessions) do
        if s.account == account then l[#l + 1] = s end
    end
    return l
end

-- POST <daemon>/call/<feature> {args} -> cb(result | nil, err)
function M.sup_post(feature, args, cb, timeout)
    if (scfg.sup or 0) <= 0 then if cb then cb(nil, "no supervisor (world without --opts sup=<port>)") end; return false end
    local body = json.tostring({owner = "olife-world", args = args})
    network.request(string.format("http://127.0.0.1:%d/call/%s", scfg.sup, feature), {
        method = "POST", body = body, timeout_ms = timeout or 4000, headers = {"Content-Type: application/json"},
        on_response = function(r)
            if not cb then return end
            if r and (r.status or 0) >= 200 and (r.status or 0) < 300 then
                local ok, d = pcall(json.parse, r.body or "")
                if ok and type(d) == "table" and d.ok and type(d.result) == "table" then return cb(d.result) end
                return cb(nil, ok and type(d) == "table" and tostring(d.message or d.error) or "bad reply")
            end
            cb(nil, r and ("supervisor http " .. tostring(r.status)) or "no answer")
        end})
    return true
end

local function report(account, level, a, sess, extra)
    ST.stats.reports = ST.stats.reports + 1
    local args = {action = "report", account = account, level = level, score = floor(a.score * 10) / 10,
                  reason = reasons(a), ip = sess and M.ip_of(sess) or a.ip, world = scfg.wl or scfg.world}
    M.sup_post("olife.fraud", args, function(res, err)
        if not res then ST.stats.report_err = ST.stats.report_err + 1; return end
        if extra then extra(res) end
    end)
end

local function notice_all(account, ev, text)
    for _, s in ipairs(sessions_of(account)) do ops.notice(s, ev, M.CODE, 0, "antifraud", text) end
end

local function exempt_ip(ip)
    if not ip then return false end
    for _, n in ipairs(cfg.exempt or {}) do if M.in_net(ip, n) then return true end end
    return false
end
M.exempt_ip = exempt_ip

local function act(account, a, kind, sess)
    local tr = trust_of(account)
    local sc = a.score
    local t = now_ms()
    local ex = exempt_ip(sess and M.ip_of(sess) or a.ip)
    if ex then
        if sc >= cfg.warn * tr and t - a.warned > 10000 then
            a.warned = t
            ST.stats.warns = ST.stats.warns + 1
            ST.stats.exempt = (ST.stats.exempt or 0) + 1
            push_event({kind = "warn", account = account, score = sc, why = reasons(a), exempt = true})
            log("warn %s %.1f (%s) exempt address: no sanctions", account, sc, reasons(a))
            notice_all(account, EV_WARN, string.format("антифрод: %.0f очков (%s) — предупреждение", sc, reasons(a)))
            return "warn"
        end
        return
    end
    if sc >= cfg.ban * tr and t - (a.banned_at or -1e12) > 5000 then
        a.banned_at, a.bans, a.level = t, a.bans + 1, "ban"
        ST.stats.bans = ST.stats.bans + 1
        local minutes = cfg.ban_base_min * (cfg.autoban_factor or 2) ^ (a.bans - 1)
        local why = string.format("антифрод: автобан, %.0f очков (%s)", sc, reasons(a))
        local b = {until_ms = t + minutes * 60000, reason = clip(why, 200), by = "fraud", ms = t, fraud = true}
        ops.ST.bans[account] = b
        ops.ST.dirty = true
        push_event({kind = "ban", account = account, score = sc, minutes = minutes, why = why})
        log("ban %s %.1f (%s) %g min", account, sc, reasons(a), minutes)
        for _, s in ipairs(sessions_of(account)) do
            ops.notice(s, 6, M.CODE, 0, "antifraud", why)
            server.kick(s, 5, clip(ops.ban_text(b), 250))
        end
        report(account, "ban", a, sess, function(res)
            if res["until"] and ops.ST.bans[account] == b then           -- the supervisor's term (strikes) wins
                b.until_ms = res["until"] * 1000
                b.reason = clip(res.reason or b.reason, 200)
                ops.ST.dirty = true
            end
        end)
        return "ban"
    end
    if sc >= cfg.kick * tr and t - (a.kicked_at or -1e12) > 3000 then
        a.kicked_at, a.kicks, a.level = t, a.kicks + 1, "kick"
        ST.stats.kicks = ST.stats.kicks + 1
        local why = string.format("antifraud: %.0f points (%s)", sc, reasons(a))
        push_event({kind = "kick", account = account, score = sc, why = why})
        log("kick %s %.1f (%s)", account, sc, reasons(a))
        for _, s in ipairs(sessions_of(account)) do
            ops.notice(s, 5, M.CODE, 0, "antifraud", why)
            server.kick(s, 10, clip(why, 250))
        end
        report(account, "kick", a, sess)
        return "kick"
    end
    if sc >= cfg.throttle * tr and t >= a.throttle_until then
        a.throttle_until, a.level = t + cfg.throttle_s * 1000, "throttle"
        ST.stats.throttles = ST.stats.throttles + 1
        local txt = string.format("антифрод: %.0f очков (%s) — чат и действия ограничены на %d с", sc, reasons(a),
                                  cfg.throttle_s)
        push_event({kind = "throttle", account = account, score = sc, why = reasons(a)})
        log("throttle %s %.1f (%s) %d s", account, sc, reasons(a), cfg.throttle_s)
        notice_all(account, EV_THROTTLE, txt)
        report(account, "throttle", a, sess)
        return "throttle"
    end
    if sc >= cfg.warn * tr and t - a.warned > 10000 then
        a.warned, a.level = t, a.level == "" and "warn" or a.level
        ST.stats.warns = ST.stats.warns + 1
        local txt = string.format("антифрод: %.0f очков (%s) — предупреждение; при %.0f — ограничение", sc, reasons(a),
                                  cfg.throttle * tr)
        push_event({kind = "warn", account = account, score = sc, why = reasons(a)})
        log("warn %s %.1f (%s)", account, sc, reasons(a))
        notice_all(account, EV_WARN, txt)
        report(account, "warn", a, sess)
        return "warn"
    end
end

-- an event of refusal over a tariff/quota (sess = session table or nil with account)
function M.event(sess, kind, account)
    if (cfg.enabled or 1) == 0 then return end
    account = account or (sess and sess.account)
    local w = tonumber(cfg["w_" .. kind]) or 0
    if not account or account == "" or w <= 0 then return end
    local a = st_of(account)
    decay(a, now_ms())
    a.score = a.score + w
    a.n[kind] = (a.n[kind] or 0) + 1
    a.last = kind
    if sess then a.ip = M.ip_of(sess) end
    ST.stats.events = ST.stats.events + 1
    return act(account, a, kind, sess)
end

-- reconnect loops: attaches of the account within the window beyond reconnect_free
function M.on_attach(sess)
    local t = now_ms()
    local l = ST.attaches[sess.account] or {}
    local keep = {}
    for _, x in ipairs(l) do if t - x < cfg.reconnect_window_s * 1000 then keep[#keep + 1] = x end end
    keep[#keep + 1] = t
    ST.attaches[sess.account] = keep
    if #keep > cfg.reconnect_free then M.event(sess, "reconnect") end
end

-- throttled: chat lines (not commands), blocks, editor/tool/script requests are dropped (true = drop)
local DROP = {ChatSend = true, BlockAction = true, ToolUse = true, ScriptSave = true, ScriptRun = true, ScriptStop = true,
              EntityEdit = true, EntityFork = true, InvAction = true}
function M.blocked(sess, name, m)
    local a = ST.acct[sess.account]
    if not a or a.throttle_until <= 0 or now_ms() >= a.throttle_until then return false end
    if not DROP[name] then return false end
    if name == "ChatSend" and type(m) == "table" and tostring(m.text or ""):match("^%s*/") then return false end
    ST.stats.dropped = ST.stats.dropped + 1
    -- flooding on while throttled escalates (kick, then ban): a dropped message scores like its refusal
    M.event(sess, name == "ChatSend" and "chat" or name == "BlockAction" and "action" or "req")
    return true
end

-- operator: score to 0, the world's fraud ban lifted (supervisor `clear` sets the trust)
function M.clear(account, trust, ts)
    local a = ST.acct[account]
    if a then a.score, a.n, a.level, a.throttle_until, a.warned = 0, {}, "", 0, -1e12 end
    ST.attaches[account] = nil
    local b = ops.ST.bans[account]
    -- a supervisor clear older than the ban (e.g. from a previous run) does not lift it
    if b and b.by == "fraud" and (not ts or ts * 1000 >= (b.ms or 0)) then ops.ST.bans[account] = nil; ops.ST.dirty = true end
    if trust then ST.trust[account] = trust end
    push_event({kind = "clear", account = account, trust = trust})
end

-- ------------------------------------------------------------------------------------------ supervisor poll
local function apply_cfg(res)
    for k, v in pairs(res.cfg or {}) do
        if D[k] ~= nil and tonumber(v) then cfg[k] = tonumber(v) end
    end
    if type(res.exempt) == "table" then cfg.exempt = res.exempt end
    ST.trust = res.trust or {}
    for acct, ts in pairs(res.cleared or {}) do
        ts = tonumber(ts) or 0
        if ts > (ST.cleared[acct] or 0) then
            ST.cleared[acct] = ts
            M.clear(acct, ST.trust[acct], ts)
        end
    end
end

function M.top(n)
    local l = {}
    local t = now_ms()
    for acct, a in pairs(ST.acct) do
        decay(a, t)
        if a.score >= 0.05 or a.throttle_until > t then
            l[#l + 1] = {account = acct, score = floor(a.score * 10) / 10, level = a.level, trust = trust_of(acct),
                         throttled = a.throttle_until > t, kicks = a.kicks, bans = a.bans, why = reasons(a)}
        end
    end
    table.sort(l, function(x, y) return x.score > y.score end)
    while #l > (n or 20) do table.remove(l) end
    return l
end

function M.tick()
    local p = ST.poll
    if (scfg.sup or 0) > 0 and not p.busy and S.tick - p.at >= 100 then
        p.at, p.busy = S.tick, true
        M.sup_post("olife.fraud", {action = "cfg", world = scfg.wl or scfg.world, scores = M.top(20),
                                    stats = ST.stats}, function(res, err)
            p.busy = false
            if res then p.ok = p.ok + 1; p.last = nil; apply_cfg(res)
            else p.err = p.err + 1; p.last = err end
        end, 3000)
    end
end

-- ------------------------------------------------------------------------------------------ views
function M.status_text(n)
    local l = M.top(n or 10)
    local out = {string.format("antifraud %s: events=%d warns=%d throttles=%d kicks=%d bans=%d dropped=%d (sup poll ok=%d err=%d)",
        (cfg.enabled or 1) ~= 0 and "on" or "OFF", ST.stats.events, ST.stats.warns, ST.stats.throttles, ST.stats.kicks,
        ST.stats.bans, ST.stats.dropped, ST.poll.ok, ST.poll.err),
        string.format("thresholds warn %g, throttle %g, kick %g, ban %g (x trust); half-life %g s", cfg.warn, cfg.throttle,
                      cfg.kick, cfg.ban, cfg.score_half_life_s)}
    for _, s in ipairs(l) do
        out[#out + 1] = string.format("%s %.1f%s trust x%g (%s)", s.account, s.score,
            s.throttled and " THROTTLED" or (s.level ~= "" and (" " .. s.level) or ""), s.trust, s.why)
    end
    return table.concat(out, "\n")
end

function M.events_text(n)
    n = min(n or 10, 40)
    local out = {string.format("antifraud events: %d (showing %d)", ST.total, min(n, #ST.events))}
    for i = max(1, #ST.events - n + 1), #ST.events do
        local e = ST.events[i]
        out[#out + 1] = string.format("#%d %s %s %.1f %s", e.n, e.kind, tostring(e.account), tonumber(e.score) or 0,
                                      tostring(e.why or e.trust or ""):sub(1, 100))
    end
    return table.concat(out, "\n")
end

function M.sup_state()
    return {top = M.top(20), stats = ST.stats, events = {unpack(ST.events, max(1, #ST.events - 9))},
            cfg = cfg, trust = ST.trust, poll = {ok = ST.poll.ok, err = ST.poll.err, last = ST.poll.last}}
end

function M.status()
    local s = ST.stats
    return string.format("fraud events=%d warns=%d throttles=%d kicks=%d bans=%d dropped=%d reports=%d report_err=%d poll_ok=%d poll_err=%d",
        s.events, s.warns, s.throttles, s.kicks, s.bans, s.dropped, s.reports, s.report_err, ST.poll.ok, ST.poll.err)
end

-- stdin `olife.fraud_state`: user:export/fraud_state.json (lab checks)
function M.dump()
    local st = M.sup_state()
    st.events = ST.events
    st.acct = {}
    for acct, a in pairs(ST.acct) do
        decay(a, now_ms())
        st.acct[acct] = {score = a.score, level = a.level, throttled = a.throttle_until > now_ms(), kicks = a.kicks,
                         bans = a.bans, n = a.n, trust = trust_of(acct)}
    end
    local ok, err = pcall(file.write, "user:export/fraud_state.json", json.tostring(st))
    return ok and ("[olife_world] fraud_state written user:export/fraud_state.json " .. M.status())
              or ("[olife_world] fraud_state failed: " .. tostring(err))
end

return M
