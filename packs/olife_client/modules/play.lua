-- olife_client:play — the player's launcher (play path, 02.10): one function for the «Сценарии» menu entry
-- (scripts/app/olife.lua) and for `lab play olife` (the same file as --script of the stock 0.32 runtime; the dry run
-- runs it in the F2F 0.32 test build). Reads the connection file export:olife_server.txt (written by the lab: `lab play
-- olife`, `lab olife play-up`), opens a fresh local replica world, takes a one-time ticket for the account and connects
-- through the gateway; the hud player is the client's camera with the Injector (slot 1) and the GravityGun (slot 2).
-- Log lines go through debug.log (timestamped, in latest.log AND stdout): `[olife_play] status fps ...` every 5 s,
-- connected / disconnected / reconnecting events — the lab's play report reads them.
local M = {}

local CONFIG = "export:olife_server.txt"
M.CONFIG = CONFIG
local STATUS_EVERY = 5.0

local function log(fmt, ...)
    local s = "[olife_play] " .. string.format(fmt, ...)
    if debug and debug.log then debug.log(s) else print(s) end
end
M.log = log

-- key=value lines, '#' comments
function M.read_config(path)
    path = path or CONFIG
    local ok, text = pcall(file.read, path)
    if not ok or type(text) ~= "string" then
        return nil, "no " .. path .. " (start the server: D:\\Prog\\Olife\\play.bat server, or play.bat)"
    end
    local c = {}
    for line in text:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then c[k] = v end
        end
    end
    local host, port = tostring(c.gateway or ""):match("^(.-):(%d+)$")
    if not port then port = tostring(c.gateway or ""):match("^(%d+)$") end
    c.port = tonumber(port)
    c.host = (host and host ~= "") and host or nil
    if not c.port then return nil, path .. ": gateway=<host:port> is missing" end
    if (c.token or "") == "" then return nil, path .. ": token=<account token> is missing" end
    c.name = (c.name and c.name ~= "") and c.name or (c.account or "player")
    return c
end

-- add only the packs that are not loaded yet: the menu already loaded the project's base packs and adding "base"
-- again aborts with "pack duplication [base]" (same as client_start.lua)
local function ensure_packs(app, ids)
    local loaded = {}
    for _, id in ipairs(app.get_content()) do loaded[id] = true end
    local add = {}
    for _, id in ipairs(ids) do
        if not loaded[id] then add[#add + 1] = id end
    end
    if #add > 0 then app.reconfig_packs(add, {}) end
end

local function alert(text)
    log("%s", text)
    if gui and gui.alert then pcall(gui.alert, "Olife: " .. text) end
end

-- run the session; returns when the player leaves the world (pause menu -> quit) or the client stops
-- opts.app: the `app` library of the calling application script (a pack module's environment has no `app`)
function M.run(opts)
    opts = opts or {}
    local app = opts.app
    assert(app, "olife_client:play.run needs opts.app (call it from an application script)")
    local cfg, err = M.read_config(opts.config)
    if not cfg then
        if world.is_open() then app.close_world(false) end
        alert(err)
        return false
    end
    -- the app script (scripts/app/olife.lua) opens the replica world BEFORE requiring this module: the pack's modules
    -- are found only after the content is loaded (the world open loads it). Fallback for other callers:
    local wname = opts.world or "olife_replica"
    if not world.is_open() then
        ensure_packs(app, {"base", "olife_client"})   -- olife_proto comes as a dependency
        -- the replica is a cache of what the server sends: start clean (old local entities/blocks would linger)
        if world.exists(wname) then pcall(app.delete_world, wname) end
        app.new_world(wname, "1", "core:default")
    end
    log("world open %s (gateway %s:%d, account %s, auth %s)", wname, cfg.host or "127.0.0.1", cfg.port,
        tostring(cfg.account or cfg.name), (cfg.auth or "") ~= "" and "ticket" or "token")

    local client = require "olife_client:client"
    local copts = {reconnect = tonumber(cfg.reconnect or "3") or 3, host = cfg.host, export = false,
                   auth = (cfg.auth or "") ~= "" and cfg.auth or nil, gw_id = cfg.gw_id or "",
                   auth_pub = cfg.auth_pub or "", auth_verify = cfg.auth_verify == "1"}
    -- camera mode (wave 4a): no bot walk; the hud player is the client player (olife_client:olife on_hud_open)
    client.request_connect(cfg.port, cfg.name, cfg.token, copts)

    local function reopen_for_packs()                    -- wave 4b, as in client_start.lua
        local P = require "olife_client:packs"
        client.leave_for_reopen("packs reload")
        app.save_world()
        app.reopen_world()
        P.S.reopen, P.S.reopen_paths, P.S.hot = false, {}, {}
        P.S.reopens = (P.S.reopens or 0) + 1
        client.reset_after_reopen(P.S.reopens)
        client.request_connect(cfg.port, cfg.name, cfg.token, copts)
        log("packs reopen #%d", P.S.reopens)
    end

    local t0 = time.uptime()
    local last_t, frames, total = t0, 0, 0
    local last_state = nil
    while not client.S.stop_requested do
        app.tick()
        if not world.is_open() then
            log("world closed by the player")
            break
        end
        client.tick()
        local P = require "olife_client:packs"
        if P.reopen_pending() and not P.S.busy then reopen_for_packs() end
        frames, total = frames + 1, total + 1
        local S = client.S
        if S.state ~= last_state then
            if S.state == "play" then
                log("connected account=%s session=%s eid=%s tickets=%d reconnects=%d", tostring(cfg.account or cfg.name),
                    tostring(S.session), tostring(S.eid), S.tickets or 0, S.reconnects or 0)
            elseif last_state == "play" or S.state == "closed" then
                log("disconnected state=%s reason=%s", tostring(S.state), tostring(S.stats.disconnect))
            end
            last_state = S.state
        end
        local now = time.uptime()
        if now - last_t >= STATUS_EVERY then
            local ls = S.last_sync
            log("status fps %.1f frames %d state %s ping %.1f entities %d chunks %d kb_in %d kb_out %d reconnects %d " ..
                "server_tick %d", frames / (now - last_t), total, tostring(S.state), ls and ls.latency or -1, S.nents or 0,
                S.nchunks or 0, math.floor((S.bytes_in or 0) / 1024), math.floor((S.bytes_out or 0) / 1024),
                S.reconnects or 0, S.server_tick or 0)
            frames, last_t = 0, now
        end
        if client.closed() and not client.will_reconnect() and total > 100 then
            alert("disconnected: " .. tostring(S.stats.disconnect))
            break
        end
    end
    local okst, st = pcall(client.status)
    log("leaving after %.0f s: %s", time.uptime() - t0, okst and st or tostring(st))
    pcall(client.bye, "player left")
    if world.is_open() then app.close_world(false) end
    return true
end


-- ============================================================================================== UX B (16.10, olife_menu)
-- After the login of the menu (olife_client:login: the replica world is open, Welcome applied): the game loop. Every
-- frame it publishes what happens to the connection into olife_client:status (the HUD element layouts/olife_status.xml
-- draws it): packs on the fly (download progress, applied live, world reopen), "the world is restarting, hold on" and
-- the reconnect phases (ticket -> gateway -> Welcome), a final disconnect (kick, ban, refused) -> back to the menu with
-- the error on the status screen. -> "quit" (the player left the world) | "error" | "stop"
local function watcher(target)
    local ST = require "olife_client:status"
    local W = {state = nil, applied = nil, errors = nil, busy = false, reopen = false}
    return function(client, P)
        local S = client.S
        local st = S.state
        if st ~= W.state then
            local prev = W.state
            if prev == "play" and st == "closed" and client.will_reconnect() then
                W.retries = 0
                local code = S.last_code
                ST.reset(target, "game")
                ST.ok("config", string.format("%s @ %s:%s", tostring(target.nick), tostring(target.host), tostring(target.port)))
                if code == 9 or code == 1 or code == nil then
                    ST.detail("config", string.format("разрыв: %s", tostring(S.disconnect_reason or S.stats.disconnect or
                        "связь потеряна")))
                    ST.banner("restarting", string.format("Мир перезапускается, держитесь (вход через %.0f с)",
                        S.reconnect_s or 0))
                else
                    ST.banner("reconnect", "Переподключение: " .. tostring(S.stats.disconnect))
                end
            elseif st == "closed" and client.will_reconnect() and ST.S.mode == "game" and not ST.S.done then
                -- another attempt failed (the world is still down): the phases start over, the banner counts
                W.retries = (W.retries or 0) + 1
                for _, id in ipairs({"ticket", "connect", "welcome"}) do
                    local ph = ST.S.phases[id]
                    if ph then ph.state, ph.detail = "wait", nil end
                end
                ST.detail("config", string.format("попытка %d: %s", W.retries + 1,
                    tostring(S.disconnect_reason or S.stats.disconnect)))
                if ST.S.banner and ST.S.banner.kind == "restarting" then
                    ST.banner("restarting", string.format("Мир перезапускается, держитесь (попытка %d)", W.retries + 1))
                end
            end
            -- reconnect phases; the engine frame may skip a short state (a ticket of 30 ms): catch up earlier phases
            -- that are still waiting, in order, so the screen and the log always show ticket -> gateway -> Welcome
            local order = {auth = 1, connecting = 2, hello = 3, play = 4}
            local ids = {"ticket", "connect", "welcome"}
            local k = order[st]
            if k and ST.S.mode == "game" and not ST.S.done then
                for i = 1, math.min(k, 4) - 1 do
                    local ph = ST.S.phases[ids[i]]
                    if ph and (ph.state == "wait" or ph.state == "run") then
                        if ph.state == "wait" then
                            if ids[i] == "ticket" and (S.tickets or 0) <= (W.tickets or 0) then
                                ST.skip("ticket", "без билета")
                            else
                                ST.phase(ids[i], ids[i] == "ticket" and "новый билет" or nil)
                            end
                        end
                        if ST.S.phases[ids[i]].state == "run" then ST.ok(ids[i]) end
                    end
                end
                if k <= 3 then
                    local ph = ST.S.phases[ids[k]]
                    if ph and ph.state == "wait" then ST.phase(ids[k], ids[k] == "ticket" and "новый билет" or nil) end
                end
            end
            if st == "play" and prev ~= nil and ST.S.mode == "game" and not ST.S.done then
                ST.detail("welcome", string.format("сессия %s", tostring(S.session)))
                for _, id in ipairs({"manifest", "download", "verify"}) do
                    local ph = ST.S.phases[id]
                    if not ph or ph.state == "wait" then ST.skip(id, "паки - после входа, на лету") end
                end
                local pw = ST.S.phases.world
                if not pw or pw.state ~= "ok" then ST.ok("world", "тот же мир-реплика") end
                ST.ok("chunks")
                ST.ok("play", string.format("сессия %s, переподключений %d", tostring(S.session), S.reconnects or 0))
                ST.finish()
                ST.banner("reconnected", string.format("Снова в игре (сессия %s, переподключений %d)",
                    tostring(S.session), S.reconnects or 0), 2.5)
            end
            W.state = st
            W.tickets = S.tickets or 0
        end
        -- packs on the fly: the same screen shows the pack phases (manifest -> files -> sha256 -> live | world reopen)
        if P.S.busy and not W.busy then
            ST.reset(target, "game")
            ST.ok("config", string.format("%s @ %s:%s", tostring(target.nick), tostring(target.host), tostring(target.port)))
            for _, id in ipairs({"ticket", "connect", "welcome"}) do ST.skip(id, "соединение то же") end
            ST.phase("manifest", tostring(P.S.url or "") .. "/manifest.json")
            ST.banner("packs_download", "Паки на лету: сервер обновил паки")
            W.dl = false
        end
        W.busy = P.S.busy
        local pr = P.S.progress
        if P.S.busy and P.S.phase == "download" and pr and pr.total then
            if not W.dl then
                W.dl = true
                ST.ok("manifest", string.format("изменено %d", pr.total))
                ST.phase("download", string.format("%d файлов", pr.total))
                ST.phase("verify", "sha256 каждого файла")
                ST.S.phases.download.state = "run"
            end
            ST.progress({done = pr.done, total = pr.total, bytes = pr.bytes, bytes_total = pr.bytes_total, pack = pr.pack,
                         file = pr.file, verified = pr.verified, verify_total = pr.verify_total})
            ST.banner("packs_download", string.format("Паки на лету: загрузка %d/%d", pr.done or 0, pr.total))
        end
        if W.applied == nil then W.applied, W.errors = P.S.applied, P.S.errors end
        if P.S.applied ~= W.applied then
            W.applied = P.S.applied
            local l = P.S.last or {}
            if ST.S.phases.manifest and ST.S.phases.manifest.state == "run" then ST.ok("manifest") end
            if pr and pr.total then
                ST.progress({done = pr.done, total = pr.total, bytes = pr.bytes, bytes_total = pr.bytes_total,
                             pack = pr.pack, file = pr.file, verified = pr.verified, verify_total = pr.verify_total})
            end
            ST.ok("download", string.format("%d файлов, %.1f КБ", (pr or {}).done or l.changed or 0, ((pr or {}).bytes or 0) / 1024))
            ST.ok("verify", string.format("%d/%d совпали", (pr or {}).verified or 0, (pr or {}).verify_total or 0))
            if (l.reopen or 0) > 0 then
                ST.phase("world", string.format("переоткрытие с новыми паками (%d файлов не вживую)", l.reopen))
                ST.banner("packs_reopen", string.format("Паки обновлены: переоткрытие мира (%d файлов)", l.changed or 0))
            else
                ST.ok("world", string.format("вживую: %d файлов, без переоткрытия", l.live or l.changed or 0))
                ST.skip("chunks", "те же")
                ST.ok("play", "соединение не прерывалось")
                ST.finish()
                ST.banner("packs_live", string.format("Паки обновлены на лету: %d файлов", l.live or l.changed or 0), 3.0)
            end
        elseif P.S.errors ~= W.errors then
            W.errors = P.S.errors
            local e = P.S.last_err or {}
            ST.fail(e.phase == "verify" and "verify" or (e.phase == "manifest" and "manifest" or "download"),
                e.phase == "verify" and "sha256" or (e.phase or "download"), e.code, tostring(e.text or P.S.last_error))
            ST.banner("packs_error", string.format("Паки: ошибка [%s %s]", tostring(e.phase), tostring(e.code)), 6.0)
        end
    end
end
M.watcher = watcher

-- opts: {app, target}; the world is open and the client is in play (olife_client:login)
function M.run_world(opts)
    local app = opts.app
    local target = opts.target or {}
    local client = require "olife_client:client"
    local ST = require "olife_client:status"
    local V = require "olife_client:status_view"
    local copts = (client.S.conn or {})[4] or {}
    local watch = watcher(target)
    local function reopen_for_packs()                    -- wave 4b, as in client_start.lua
        local P = require "olife_client:packs"
        local MN = require "olife_client:menu"
        client.leave_for_reopen("packs reload")
        app.save_world()
        client.S.camera_pid = nil                       -- the reopened world's hud registers again
        app.reopen_world()
        -- UX B: the reopen loads the pack's modules again (new instances): carry the state over
        local n = require("olife_client:login").carry({cl = client, P = P, ST = ST, MN = MN})
        client, P, ST = n.cl, n.P, n.ST
        V = require "olife_client:status_view"
        P.S.reopen, P.S.reopen_paths, P.S.hot = false, {}, {}
        P.S.reopens = (P.S.reopens or 0) + 1
        client.reset_after_reopen(P.S.reopens)
        ST.ok("world", string.format("переоткрыт с новыми паками (#%d)", P.S.reopens))
        for _, id in ipairs({"ticket", "connect", "welcome"}) do        -- the login again: new ticket, gateway, Welcome
            local ph = ST.S.phases[id]
            if ph then ph.state, ph.detail = "wait", nil end
        end
        ST.S.done = false
        ST.banner("packs_reopen", string.format("Паки обновлены: мир переоткрыт (#%d), вход заново", P.S.reopens))
        local c = client.S.conn or {}
        client.request_connect(c[1], c[2], c[3], c[4])
        log("packs reopen #%d", P.S.reopens)
    end
    log("connected account=%s session=%s eid=%s tickets=%d reconnects=%d", tostring(target.nick),
        tostring(client.S.session), tostring(client.S.eid), client.S.tickets or 0, client.S.reconnects or 0)
    local t0 = time.uptime()
    local last_t, frames, total = t0, 0, 0
    local last_state = client.S.state
    local result = "quit"
    while not client.S.stop_requested do
        app.tick()
        if not world.is_open() then
            log("world closed by the player")
            break
        end
        local MN = require "olife_client:menu"
        if MN.S.leave then                               -- F2F `menu {op = leave}` (tests) = the pause menu's quit
            MN.S.leave = nil
            log("world closed by the player (leave request)")
            break
        end
        client.tick()
        local P = require "olife_client:packs"
        watch(client, P)                                -- first: the applied packs show before the reopen
        if P.reopen_pending() and not P.S.busy then reopen_for_packs() end
        V.render_all()
        frames, total = frames + 1, total + 1
        local S = client.S
        if S.state ~= last_state then
            if S.state == "play" then
                log("connected account=%s session=%s eid=%s tickets=%d reconnects=%d", tostring(target.nick),
                    tostring(S.session), tostring(S.eid), S.tickets or 0, S.reconnects or 0)
            elseif last_state == "play" or S.state == "closed" then
                log("disconnected state=%s reason=%s", tostring(S.state), tostring(S.stats.disconnect))
            end
            last_state = S.state
        end
        local now = time.uptime()
        if now - last_t >= STATUS_EVERY then
            local ls = S.last_sync
            log("status fps %.1f frames %d state %s ping %.1f entities %d chunks %d kb_in %d kb_out %d reconnects %d " ..
                "server_tick %d", frames / (now - last_t), total, tostring(S.state), ls and ls.latency or -1, S.nents or 0,
                S.nchunks or 0, math.floor((S.bytes_in or 0) / 1024), math.floor((S.bytes_out or 0) / 1024),
                S.reconnects or 0, S.server_tick or 0)
            frames, last_t = 0, now
        end
        if client.closed() and not client.will_reconnect() then
            -- final: kicked, banned, refused ticket on a reconnect, the world never came back
            local ST2 = require "olife_client:login"
            local code = S.last_code
            local af = S.auth_fail
            ST.banner(nil)
            if af then
                ST.fail(ST.S.current or "ticket", ST2.auth_kind(af), af.code or ("http " .. tostring(af.http)),
                    tostring(af.reason))
            elseif code then
                ST.fail(ST.S.current or "play", ST2.disconnect_kind(code), code, string.format("%s: %s",
                    ST.DISCONNECT[code] or "отказ", tostring(S.disconnect_reason or S.stats.disconnect)))
            else
                ST.fail(ST.S.current or "play", "lost", "socket", tostring(S.stats.disconnect or "соединение закрыто"))
            end
            log("disconnected for good: %s", ST.error_text())
            result = "error"
            break
        end
    end
    if client.S.stop_requested then result = "stop" end
    local okst, st = pcall(client.status)
    log("leaving after %.0f s: %s", time.uptime() - t0, okst and st or tostring(st))
    pcall(client.bye, "player left")
    if world.is_open() then app.close_world(false) end
    return result
end

return M
