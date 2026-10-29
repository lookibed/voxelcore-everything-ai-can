-- olife_client:login — UX B (16.10, olife_menu): one login attempt from the menu, step by step, every step published to
-- olife_client:status (the status screen draws it): ticket at the service -> TCP to the gateway + Hello -> Welcome ->
-- pack manifest -> downloads (files, bytes, current pack/file) -> sha256 -> the replica world (+ world:content and a
-- reopen when packs changed) -> first chunks -> play. Any error stops on the status screen with its code and reason.
-- Runs in the application script's coroutine (app.tick between waits); network callbacks of 0.32 are dispatched by
-- the stdlib from the main state, so they may be created here (checked in the engine: LESSONS «Olife — меню клиента»).
local ST = require "olife_client:status"
local MN = require "olife_client:menu"

local M = {}
M.WORLD = "olife_replica"
M.T_TICKET = 8          -- s
M.T_CONNECT = 8
M.T_WELCOME = 10
M.T_PACKS_NOTE = 2.0    -- s to wait for PacksChanged after Welcome (the gateway sends it right after Welcome)
M.T_MANIFEST = 15
M.T_DOWNLOAD = 60
M.T_HUD = 6
M.T_CHUNKS = 10
M.MIN_CHUNKS = 4
M.T_INFO = 3            -- s: InfoRequest -> ServerInfo (olife_friends)

local function log(fmt, ...)
    local s = "[olife_play] login " .. string.format(fmt, ...)
    if debug and debug.log then debug.log(s) else print(s) end
end

-- wait until pred() is truthy, ticking the engine; a «Назад»/«Отмена» request aborts. -> value | nil, "timeout"|"cancel"
local function wait(app, pred, timeout, on_tick)
    local t0 = time.uptime()
    while true do
        local v = pred()
        if v then return v end
        local r = MN.S.requests[1]
        if r and (r.what == "back" or r.what == "quit") then return nil, "cancel" end
        if time.uptime() - t0 > timeout then return nil, "timeout" end
        app.tick()
        if on_tick then on_tick() end
        require("olife_client:status_view").render_all()
        pcall(MN.flash_tick)
    end
end
M.wait = wait

-- after app.reopen_world() the pack's modules are new instances (possibly from world:content): give them the state
-- of the old ones. Status and menu share the app script's tables (bind); client and packs adopt. -> new refs
function M.carry(old)
    local new = {}
    new.cl = require "olife_client:client"
    if old.cl and new.cl ~= old.cl then new.cl.adopt(old.cl.S) end
    new.P = require "olife_client:packs"
    if old.P and new.P ~= old.P then new.P.adopt(old.P.S) end
    -- old.ST / old.MN: the instances of the caller BEFORE the reopen (this module may itself be a new instance)
    local oST, oMN = old.ST or ST, old.MN or MN
    local ST2 = require "olife_client:status"
    if ST2 ~= oST then ST2.bind(oST.S) end
    local MN2 = require "olife_client:menu"
    if MN2 ~= oMN then MN2.bind(oMN.S) end
    new.ST, new.MN = ST2, MN2
    new.changed = new.cl ~= old.cl
    return new
end

local function disconnect_kind(code)
    if code == 5 then return "banned" end
    if code == 9 or code == 1 then return "restart" end
    if code == 8 or code == 2 or code == 6 then return "timeout" end
    if code == 4 or (code and code >= 14 and code <= 17) then return "ticket" end
    if code == 18 then return "nick" end                -- antifraud: the nick plays from another address
    return "refused"
end
M.disconnect_kind = disconnect_kind

local function auth_kind(rep)
    rep = rep or {}
    if rep.kind == "network" then return "auth_down" end
    if rep.code == "banned" or rep.code == "ip_banned" then return "banned" end
    -- antifraud 16.10 (agents/research/OLIFE_ANTIFRAUD.md)
    if rep.code == "nick_in_use" or rep.code == "nick_similar" or rep.code == "nick_reserved" then return "nick" end
    if rep.code == "rate_ip" or rep.code == "rate_net" or rep.code == "multi_account" or rep.code == "sessions_ip" then
        return "antifraud"
    end
    if rep.code == "whitelist" then return "whitelist" end
    if rep.kind == "http" and rep.code == nil then return "auth_http" end
    return "ticket"
end
M.auth_kind = auth_kind

local function close_client(cl, why)
    pcall(cl.bye, why or "login aborted")
    cl.S.prelude = false
    cl.S.retry_at = nil
end

-- olife_friends (16.10): ask the gateway "what is this server?" (olife_client:serverinfo) and take the ticket service /
-- key / gateway id from its answer. -> true (go on: t updated or the old data kept) | false (error published) | "back"
local function discover(app, t)
    local SI = require "olife_client:serverinfo"
    local MN2 = require "olife_client:menu"
    ST.phase("config", string.format("сведения о сервере у шлюза %s:%d", t.host, t.port))
    local q = SI.start(t.host, t.port)
    local ok, why = wait(app, function() return SI.poll(q) end, M.T_INFO)
    SI.close(q)
    if why == "cancel" then return "back" end
    local have = t.auth ~= nil                          -- fallback data (recent entry / the autofill's service)
    if not q.info then
        local what
        if not ok then what = string.format("нет ответа за %d с", M.T_INFO)
        elseif q.kind == "connect" then what = "нет соединения: " .. tostring(q.err)
        elseif q.kind == "disconnect" then what = string.format("Disconnect %s %s", tostring(q.code), tostring(q.reason))
        else what = tostring(q.kind) .. " " .. tostring(q.err or "") end
        log("server info: none (%s), fallback %s", what, have and "yes" or "no")
        t.info_error = what
        -- the same host:port as the game socket: no TCP at all -> the gateway is down, say so now (no second wait)
        if have and q.kind ~= "connect" then return true end    -- old gateway / relay: the login goes on as before
        if q.kind == "connect" or (q.kind == "disconnect" and (q.code == 5 or q.code == 13)) then
            ST.ok("config", string.format("%s @ %s:%d, по нику", t.nick, t.host, t.port))
        end
        if q.kind == "connect" then
            ST.fail("connect", "no_server", "tcp", tostring(q.err))
        elseif q.kind == "disconnect" and q.code == 5 then
            ST.fail("connect", "banned", 5, tostring(q.reason))
        elseif q.kind == "disconnect" and q.code == 13 then
            ST.fail("connect", "antifraud", 13, tostring(q.reason))
        else
            ST.fail("config", "no_info", q.kind == "disconnect" and q.code or "info",
                "шлюз " .. t.addr .. " не сообщил адрес сервиса билетов (" .. what .. "): это сервер Olife? старая версия?")
        end
        return false
    end
    local si = q.info
    local key = si.auth_pub or ""
    if key == "" or (si.auth_port or 0) == 0 then
        -- the gateway answers but does not know its ticket service (no --info: a lab session gateway) -> keep our data
        t.server = {name = si.name, gw_id = si.gw_id, auth_port = 0, packs_port = si.packs_port, key = "-"}
        log("server info: no ticket service in ServerInfo (name=%s), fallback %s", tostring(si.name), have and "yes" or "no")
        if have then return true end
        ST.fail("config", "no_info", "info", "шлюз " .. t.addr .. " не сообщил адрес сервиса билетов (ServerInfo без auth_port)")
        return false
    end
    -- the key check: the invite fingerprint wins; otherwise the key remembered for this address (TOFU)
    if t.fp and key:sub(1, #t.fp) ~= t.fp then
        ST.fail("config", "server_key", "fingerprint", string.format("ключ сервера %s... не совпал с приглашением #%s: " ..
            "адрес подменён или приглашение устарело (спросите у хоста новое)", key:sub(1, 12), t.fp))
        return false
    end
    -- an account token (only from the lab's file) is never sealed to a key that came from an unauthenticated ServerInfo:
    -- the key must be the file's one, else the login stops (an active man-in-the-middle would get the token)
    if t.token and (t.auth_pub or "") ~= "" and t.auth_pub ~= key then
        ST.fail("config", "server_key", "token_pin", string.format("ключ сервера %s... не совпал с ключом из файла " ..
            "export:olife_server.txt (%s...): токен аккаунта туда не отправлю", key:sub(1, 12), t.auth_pub:sub(1, 12)))
        return false
    end
    if not t.fp and t.pin and t.pin ~= key then
        local acc = MN2.S.accept_key or {}
        MN2.S.accept_key = acc
        if acc[t.addr] ~= key then
            acc[t.addr] = key
            ST.fail("config", "server_key", "key_changed", string.format("ключ сервиса билетов %s изменился: был %s..., " ..
                "стал %s... Если хост пересоздал сервер - нажмите «Повторить», чтобы принять новый ключ", t.addr,
                t.pin:sub(1, 12), key:sub(1, 12)))
            return false
        end
        log("server info: new key of %s accepted by Повторить", t.addr)
    end
    if (si.auth_port or 0) > 0 then
        t.auth = string.format("%s://%s:%d", si.auth_scheme ~= "" and si.auth_scheme or "https", t.host, si.auth_port)
        t.gw_id, t.auth_pub, t.auth_verify = si.gw_id, key, "0"
    end
    t.server = {name = si.name, gw_id = si.gw_id, auth_port = si.auth_port, packs_port = si.packs_port,
                public = si.public, whitelist = si.whitelist, motd = si.motd, key = key:sub(1, 12)}
    log("server info: name=%s gw_id=%s auth=%s packs=%d public=%s whitelist=%s key=%s", tostring(si.name),
        tostring(si.gw_id), tostring(t.auth), si.packs_port or 0, tostring(si.public), tostring(si.whitelist),
        key:sub(1, 12))
    return true
end
M.discover = discover

-- t: target of olife_client:menu (addr, host, port, nick, auth, gw_id, auth_pub, auth_verify, token, reconnect,
-- discover/fp/pin — olife_friends); opts.app — the `app` library. -> "play" | "error" | "back"
function M.run(t, opts)
    local app = opts.app
    local cl = require "olife_client:client"
    local AUTH = require "olife_client:auth"
    local P = require "olife_client:packs"
    local function tick() cl.tick() end
    ST.reset({nick = t.nick, host = t.host, port = t.port, auth = t.auth, account = t.token and "token" or "nick"}, "login")
    if t.discover then
        local d = discover(app, t)
        if d == "back" then return "back" end
        if not d then return "error" end
        ST.S.target.auth = t.auth
    end
    ST.ok("config", string.format("%s @ %s:%d%s%s", t.nick, t.host, t.port, t.token and ", токен из файла" or ", по нику",
        t.server and string.format(", сервер «%s», билеты :%d, паки :%d, ключ %s...", tostring(t.server.name),
        t.server.auth_port or 0, t.server.packs_port or 0, tostring(t.server.key)) or ""))
    log("start nick=%s gateway=%s:%d auth=%s token=%s", t.nick, t.host, t.port, tostring(t.auth), t.token and "yes" or "no")

    -- 1. ticket
    local hello
    if t.auth then
        ST.phase("ticket", t.auth)
        local got = {}
        local t0 = time.uptime()
        AUTH.fetch({url = t.auth, token = t.token, name = t.nick, gateway = t.gw_id or "", pub = t.auth_pub,
                    verify = t.auth_verify == "1" or t.auth_verify == true}, function(ticket, err, rep)
            got.ticket, got.err, got.rep, got.done = ticket, err, rep, true
        end)
        local ok, why = wait(app, function() return got.done end, M.T_TICKET)
        if why == "cancel" then return "back" end
        if not ok then
            ST.fail("ticket", "timeout", "ticket", string.format("сервис билетов %s не ответил за %d с", t.auth, M.T_TICKET))
            return "error"
        end
        if not got.ticket then
            local rep = got.rep or {}
            local code = rep.code or (rep.http and ("http " .. tostring(rep.http))) or rep.kind
            if rep.kind == "network" then code = "http 0" end
            ST.fail("ticket", auth_kind(rep), code, tostring(rep.reason or got.err))
            return "error"
        end
        hello = got.ticket
        cl.S.tickets = (cl.S.tickets or 0) + 1
        ST.ok("ticket", string.format("аккаунт %s, билет %s..., %.0f мс", tostring(got.rep and got.rep.account),
            got.ticket:sub(1, 8), (time.uptime() - t0) * 1000))
    else
        if not t.token then
            ST.fail("ticket", "no_config", "auth", "у этого шлюза нет сервиса билетов, а токена аккаунта нет " ..
                "(нужен export:olife_server.txt)")
            return "error"
        end
        hello = t.token
        ST.skip("ticket", "без сервиса билетов: токен в Hello")
    end

    -- 2. TCP + Hello
    ST.phase("connect", string.format("%s:%d", t.host, t.port))
    local copts = {reconnect = t.reconnect or 3, host = t.host, export = false, auth = t.auth, gw_id = t.gw_id or "",
                   auth_pub = t.auth_pub or "", auth_verify = t.auth_verify == "1" or t.auth_verify == true,
                   nick = t.nick}
    cl.prelude_connect(t.host, t.port, t.nick, hello, t.token or "", copts)
    local ok, why = wait(app, function()
        local s = cl.S.state
        return (s == "hello" or s == "closed") and s or nil
    end, M.T_CONNECT, tick)
    if why == "cancel" then close_client(cl); return "back" end
    if not ok then
        close_client(cl)
        ST.fail("connect", "timeout", "tcp", string.format("нет ответа от %s:%d за %d с", t.host, t.port, M.T_CONNECT))
        return "error"
    end
    if ok == "closed" then
        if cl.S.connected_at and cl.S.last_code then
            -- TCP was up and Hello sent: the gateway refused at once (ban list of the gateway, ticket codes 14..17)
            ST.ok("connect", string.format("%s:%d, Hello отправлен", t.host, t.port))
            local code = cl.S.last_code
            ST.fail("welcome", disconnect_kind(code), code, string.format("%s: %s", ST.DISCONNECT[code] or "отказ",
                tostring(cl.S.disconnect_reason or cl.S.stats.disconnect)))
        else
            ST.fail("connect", "no_server", "tcp", tostring(cl.S.stats.disconnect))
        end
        return "error"
    end
    ST.ok("connect", string.format("%s:%d, Hello отправлен", t.host, t.port))

    -- 3. Welcome
    ST.phase("welcome")
    ok, why = wait(app, function()
        if cl.S.pre_welcome then return "welcome" end
        if cl.S.state == "closed" then return "closed" end
    end, M.T_WELCOME, tick)
    if why == "cancel" then close_client(cl); return "back" end
    if not ok then
        close_client(cl, "welcome timeout")
        ST.fail("welcome", "timeout", "welcome", string.format("шлюз %s:%d не прислал Welcome за %d с", t.host, t.port,
            M.T_WELCOME))
        return "error"
    end
    if ok == "closed" then
        local code = cl.S.last_code
        if code then
            ST.fail("welcome", disconnect_kind(code), code, string.format("%s: %s", ST.DISCONNECT[code] or "отказ",
                tostring(cl.S.disconnect_reason or cl.S.stats.disconnect)))
        else
            ST.fail("welcome", "lost", "socket", tostring(cl.S.stats.disconnect or "соединение закрыто"))
        end
        return "error"
    end
    local w = cl.S.pre_welcome
    ST.ok("welcome", string.format("сессия %d, мир %s, такт %d", w.session, tostring(w.world), w.tick))

    -- 4. pack manifest (PacksChanged comes right after Welcome when the server distributes packs)
    wait(app, function() return cl.S.pre_packs or cl.S.state == "closed" end, M.T_PACKS_NOTE, tick)
    local pk = cl.S.pre_packs
    local m, changed, data
    if not pk or (pk.url or "") == "" then
        ST.skip("manifest", "сервер не раздаёт паки")
        ST.skip("download", "-")
        ST.skip("verify", "-")
    else
        ST.phase("manifest", pk.url .. "/manifest.json")
        local got = {}
        P.check(pk.url, function(mm, ch, n) got.m, got.changed, got.n, got.done = mm, ch, n, true end,
            function(why2, phase, code) got.err, got.code, got.done = why2, code, true end)
        ok, why = wait(app, function() return got.done end, M.T_MANIFEST, tick)
        if why == "cancel" then close_client(cl); return "back" end
        if not ok or got.err then
            close_client(cl, "manifest")
            ST.fail("manifest", ok and "manifest" or "timeout", got.code or "manifest", got.err or
                string.format("манифест не пришёл за %d с", M.T_MANIFEST))
            return "error"
        end
        m, changed = got.m, got.changed
        ST.ok("manifest", string.format("файлов %d, изменено %d, версия %s", got.n, #changed, tostring(m.version):sub(1, 12)))
        if #changed == 0 then
            ST.skip("download", "всё совпадает с паками клиента")
            ST.skip("verify", "-")
            P.S.version = m.version
        else
            ST.phase("download", string.format("%d файлов", #changed))
            ST.phase("verify", "sha256 каждого файла")
            ST.S.phases.download.state = "run"          -- both run together (each file is checked when it arrives)
            local dl = {}
            P.fetch(pk.url, changed, function(pr)
                ST.progress({done = pr.done, total = pr.total, bytes = pr.bytes, bytes_total = pr.bytes_total,
                             pack = pr.pack, file = pr.file, verified = pr.verified, verify_total = pr.verify_total})
            end, function(d) dl.data, dl.done = d, true end,
            function(why2, phase, code) dl.err, dl.phase, dl.code, dl.done = why2, phase, code, true end)
            ok, why = wait(app, function() return dl.done end, M.T_DOWNLOAD, tick)
            if why == "cancel" then close_client(cl); return "back" end
            if not ok or dl.err then
                close_client(cl, "packs")
                if not ok then
                    ST.fail("download", "timeout", "download", string.format("файлы не скачаны за %d с", M.T_DOWNLOAD))
                elseif dl.phase == "verify" then
                    ST.S.phases.download.state = "ok"
                    ST.fail("verify", "sha256", "sha256", dl.err)
                else
                    ST.fail("download", "download", dl.code, dl.err)
                end
                return "error"
            end
            data = dl.data
            local pr = P.S.progress or {}
            ST.ok("download", string.format("%d файлов, %.1f КБ", pr.done or #changed, (pr.bytes or 0) / 1024))
            ST.ok("verify", string.format("%d/%d совпали с манифестом", pr.verified or #changed, #changed))
        end
    end

    -- 5. the replica world (packs that changed go to world:content and the world is reopened with them)
    ST.phase("world", M.WORLD)
    cl.S.camera_pid = nil                               -- set again by olife_client:olife on_hud_open of this world
    local okw, errw = pcall(function()
        if world.is_open() then app.close_world(false) end
        if world.exists(M.WORLD) then app.delete_world(M.WORLD) end
        app.new_world(M.WORLD, "1", "core:default")
    end)
    if not okw then
        close_client(cl, "world")
        ST.fail("world", "world", "open", tostring(errw))
        return "error"
    end
    debug.log("[olife_play] world open " .. M.WORLD)      -- the play report's world_open event (lab play olife)
    if changed and #changed > 0 then
        local last, err = P.stage(m, changed, data)
        if not last then
            close_client(cl, "world")
            ST.fail("world", "world", "write", "world:content: " .. tostring(err))
            return "error"
        end
        P.S.reopen, P.S.reopen_paths = false, {}
        ST.detail("world", string.format("%s, паки из world:content (%d файлов), переоткрытие", M.WORLD, #changed))
        cl.S.camera_pid = nil
        local okr, errr = pcall(function()
            app.save_world()                -- a fresh world has no world.json until saved: reopen needs it
            app.reopen_world()
        end)
        if not okr then
            close_client(cl, "world")
            ST.fail("world", "world", "reopen", tostring(errr))
            return "error"
        end
        local n = M.carry({cl = cl, P = P, ST = ST, MN = MN})
        cl, P = n.cl, n.P
        log("world reopened with packs (%d files) path=%s, modules reloaded %s", #changed,
            tostring((pack.get_info("olife_client") or {}).path), tostring(n.changed))
    end
    if m then P.S.version = m.version end
    -- the hud player becomes the client's camera (olife_client:olife on_hud_open) — wait for it, then apply Welcome
    ok, why = wait(app, function() return cl.S.camera_pid ~= nil end, M.T_HUD, tick)
    if why == "cancel" then close_client(cl); return "back" end
    if cl.S.state == "closed" then
        ST.fail("world", "lost", cl.S.last_code or "socket", tostring(cl.S.stats.disconnect))
        return "error"
    end
    local n = cl.enter_world()
    ST.ok("world", string.format("%s%s, отложено %d сообщ.", M.WORLD, changed and #changed > 0 and
        ", паки обновлены" or "", n))

    -- 6. first chunks
    ST.phase("chunks")
    ok, why = wait(app, function()
        ST.detail("chunks", string.format("%d", cl.S.nchunks or 0))
        if cl.S.state == "closed" then return "closed" end
        return (cl.S.nchunks or 0) >= M.MIN_CHUNKS and "ok" or nil
    end, M.T_CHUNKS, tick)
    if why == "cancel" then close_client(cl); return "back" end
    if ok == "closed" then
        local code = cl.S.last_code
        ST.fail("chunks", code and disconnect_kind(code) or "lost", code or "socket",
            tostring(cl.S.disconnect_reason or cl.S.stats.disconnect))
        return "error"
    end
    ST.ok("chunks", string.format("%d чанков%s", cl.S.nchunks or 0, ok and "" or " (меньше ожидаемого за " ..
        M.T_CHUNKS .. " с)"))
    ST.ok("play", string.format("сессия %s, eid %s", tostring(cl.S.session), tostring(cl.S.eid)))
    ST.finish()
    MN.remember(t)
    log("done in %.2f s", time.precise_utc_time() - (ST.S.t0 or time.precise_utc_time()))
    return "play"
end

return M
