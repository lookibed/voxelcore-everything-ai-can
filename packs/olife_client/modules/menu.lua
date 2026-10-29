-- olife_client:menu — UX B (16.10, olife_menu): the client's main menu (layouts/pages/olife_menu.xml): a 3D scene
-- (<modelviewer> of the VCM models/olife_menu_scene.vcm, the camera turns slowly), the simplest login — gateway
-- ip:port and nick, «Войти», recent servers — remembered in config:olife_client/menu.json. export:olife_server.txt
-- (written by the lab: `lab play olife`, `lab olife play-up`) only pre-fills the fields and gives the ticket service
-- (auth, gw_id, auth_pub) and the account token for the nick of that account; it is not required any more.
-- Pages only put requests here (M.request); the application script (scripts/app/olife.lua) acts on them.
-- The state table is owned by the application script (the pack's modules are unloaded when the world closes).
local M = {}

M.CONFIG_DIR = "config:olife_client"
M.CONFIG = "config:olife_client/menu.json"
M.AUTOFILL = "export:olife_server.txt"
M.RECENT_MAX = 6
M.SCENE = "olife_menu_scene"
M.SCENE_CENTER = "0,0.55,0"
M.SCENE_PITCH = -24
M.SCENE_DEG_S = 8            -- the slow turn of the camera, degrees per second
M.SCENE_EVERY = 0.1          -- s between two re-creations of the viewer (the engine has no Lua setter for the camera)

local S
local function fresh(t)
    t = t or {}
    t.fields = t.fields or {addr = "", nick = ""}
    t.recent = t.recent or {}
    t.angle = t.angle or 35
    t.requests = t.requests or {}
    t.docs = t.docs or {}
    t.presses = t.presses or {}
    return t
end
function M.bind(t)
    S = fresh(t)
    M.S = S
    return S
end
M.bind({})

local function log(fmt, ...)
    local s = "[olife_menu] " .. string.format(fmt, ...)
    if debug and debug.log then debug.log(s) else print(s) end
end
M.log = log

local function fx(name, text)
    local ok, F = pcall(require, "olife_client:fx")
    if ok then pcall(F.event, name, text, {no_toast = true}) end
end

-- ------------------------------------------------------------------------------------------ config / autofill
-- export:olife_server.txt: key=value lines, '#' comments (the format of the lab's config_text)
function M.read_autofill(path)
    path = path or M.AUTOFILL
    local ok, text = pcall(file.read, path)
    if not ok or type(text) ~= "string" then return nil end
    local c = {}
    for line in text:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then c[k] = v end
        end
    end
    if (c.gateway or "") == "" then return nil end
    c.account = (c.account and c.account ~= "") and c.account or c.name
    return c
end

function M.load()
    local ok, txt = pcall(file.read, M.CONFIG)
    local cfg = {}
    if ok and type(txt) == "string" then
        local okp, t = pcall(json.parse, txt)
        if okp and type(t) == "table" then cfg = t end
    end
    S.recent = type(cfg.recent) == "table" and cfg.recent or {}
    S.autofill = M.read_autofill()
    local af = S.autofill
    S.fields.addr = (cfg.last_addr and cfg.last_addr ~= "") and cfg.last_addr or (af and af.gateway or "")
    S.fields.nick = (cfg.last_nick and cfg.last_nick ~= "") and cfg.last_nick or (af and (af.account or af.name) or "")
    -- the lab's file is newer than the remembered address (a new stack, a new port): it wins for the same host
    if af and af.gateway and cfg.last_addr and cfg.last_addr ~= af.gateway and (cfg.autofill_gateway ~= af.gateway) then
        S.fields.addr = af.gateway
    end
    S.loaded_cfg = cfg
    log("menu config: recent %d, autofill %s, addr %s, nick %s", #S.recent, af and af.gateway or "none",
        S.fields.addr, S.fields.nick)
end

function M.save()
    pcall(file.mkdirs, M.CONFIG_DIR)
    local t = {last_addr = S.fields.addr, last_nick = S.fields.nick, recent = S.recent,
               autofill_gateway = S.autofill and S.autofill.gateway or nil, saved = os.time and os.time() or nil}
    local ok, err = pcall(file.write, M.CONFIG, json.tostring(t))
    if not ok then log("config write failed: %s", tostring(err)) end
    return ok
end

-- recent servers: newest first, unique by address+nick; the ticket service data of a server is kept with it
function M.remember(t)
    local r = {addr = t.addr, nick = t.nick, auth = t.auth, gw_id = t.gw_id, auth_pub = t.auth_pub,
               auth_verify = t.auth_verify, last = os.time and os.time() or 0}
    local out = {r}
    for _, x in ipairs(S.recent) do
        if not (x.addr == r.addr and x.nick == r.nick) and #out < M.RECENT_MAX then out[#out + 1] = x end
    end
    S.recent = out
    S.fields.addr, S.fields.nick = t.addr, t.nick
    M.save()
end

-- ------------------------------------------------------------------------------------------ validation / target
-- "host:port" | "port" | "host:port#fp" (olife_friends: the invite carries the first characters of the ticket service
-- key, b64url) -> host, port, "host:port", fp | nil
function M.parse_addr(addr)
    addr = tostring(addr or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local fp
    local a0, f = addr:match("^(.-)#([%w_%-]+)$")
    if a0 then addr, fp = a0, f end
    local host, port = addr:match("^([%w%.%-]+):(%d+)$")
    if not host then
        port = addr:match("^(%d+)$")
        host = port and "127.0.0.1" or nil
    end
    port = tonumber(port)
    if not host or not port or port < 1 or port > 65535 then return nil end
    if fp and #fp < 6 then return nil end
    if not addr:find(":") then addr = host .. ":" .. tostring(port) end
    return host, port, addr, fp
end

function M.valid_nick(nick)
    nick = tostring(nick or "")
    return #nick >= 2 and #nick <= 24 and nick:match("^[%w_%.%-]+$") ~= nil
end

-- what the login needs: address, nick, ticket service (from the autofill file for that gateway, from the recent
-- entry of that address, else the autofill's service on the typed host), token only for the nick of the file's account
function M.target(addr, nick)
    local host, port, a, fp = M.parse_addr(addr)
    if not host then return nil, "bad_address", "адрес шлюза: ip:port, например 192.168.1.5:27750" end
    if not M.valid_nick(nick) then
        return nil, "bad_nick", "ник: 2..24 символа, латиница, цифры, _ . -"
    end
    local t = {addr = a, host = host, port = port, nick = nick, fp = fp}
    local af = S.autofill
    local src
    if af and af.gateway == a then src = af end
    -- olife_friends: any address that is not the lab's own autofill asks the gateway first (ServerInfo); what follows
    -- is the fallback for gateways without InfoRequest. The key remembered for this address is the pin (TOFU).
    t.discover = src == nil
    for _, x in ipairs(S.recent) do
        if x.addr == a and (x.auth_pub or "") ~= "" then t.pin = x.auth_pub; break end
    end
    if not src then
        for _, x in ipairs(S.recent) do if x.addr == a and x.auth then src = x; break end end
    end
    if not src and af and (af.auth or "") ~= "" then
        src = {auth = af.auth:gsub("^(https?://)[^:/]+", "%1" .. host), gw_id = af.gw_id, auth_pub = af.auth_pub,
               auth_verify = af.auth_verify}
        t.auth_guess = true
    end
    if src then
        t.auth = (src.auth or "") ~= "" and src.auth or nil
        t.gw_id, t.auth_pub, t.auth_verify = src.gw_id, src.auth_pub, src.auth_verify
    end
    if af and (af.token or "") ~= "" and nick == af.account and (af.gateway == a or t.auth_guess or src == af) then
        t.token = af.token                    -- the account of the file: its token (never stored in config)
    end
    t.reconnect = tonumber(af and af.reconnect or "3") or 3
    return t
end

-- ------------------------------------------------------------------------------------------ page glue
function M.page_opened(kind, doc)
    S.docs[kind] = doc
    S.page = kind
    if kind == "menu" then M.fill(doc) end
    M.set_f2f()
end

function M.fill(doc)
    doc = doc or S.docs.menu
    if not doc then return end
    pcall(function()
        doc.mn_addr.text = S.fields.addr or ""
        doc.mn_nick.text = S.fields.nick or ""
        local af = S.autofill
        doc.mn_auto.text = af and string.format("автозаполнение: %s (аккаунт %s)", af.gateway,
            tostring(af.account or "-")) or "автозаполнения нет (export:olife_server.txt)"
        doc.mn_hint.text = S.hint or ""
    end)
    pcall(function()
        doc.mn_recent:clear()
        for i, x in ipairs(S.recent) do
            doc.mn_recent:add(string.format('<button id="mn_r%d" size="300,24" color="#FFFFFF14" hover-color="#5050ff80" ' ..
                'onclick="ui_mn_recent(%d)" tooltip="%s">%s  %s</button>', i, i, x.auth and "сервис билетов: " .. x.auth or
                "без сервиса билетов", x.addr, x.nick))
        end
        if #S.recent == 0 then
            doc.mn_recent:add('<label id="mn_r0" size="300,20" color="#69707D">пока пусто</label>')
        end
    end)
    M.scene(doc, true)
end

-- the 3D scene: the engine reads `cam-rotation` only from XML (Lua sees `src` only) -> re-create the viewer node
function M.scene(doc, force)
    M.flash_tick()
    doc = doc or S.docs.menu
    if not doc then return end
    local now = time.uptime()
    if not force and now - (S.scene_t or 0) < M.SCENE_EVERY then return end
    local dt = S.scene_t and math.min(now - S.scene_t, 0.5) or 0
    S.scene_t = now
    S.angle = (S.angle + dt * M.SCENE_DEG_S) % 360
    local ok, err = pcall(function()
        local box = doc.mn_scene_box
        local sz = box.size
        box:clear()
        box:add(string.format('<modelviewer id="mn_scene" pos="0,0" size="%d,%d" src="%s" center="%s" ' ..
            'cam-rotation="%.2f,%d,0" interactive="false"/>', sz[1], sz[2], M.SCENE, M.SCENE_CENTER, S.angle, M.SCENE_PITCH))
    end)
    S.scene_n = (S.scene_n or 0) + 1
    if not ok then S.scene_err = tostring(err) end
end

-- visual feedback of a press (OLIFE_UX §1): the button flashes (brighter for 0.2 s), the sound comes from fx
local FLASH_ID = {login = {"menu", "mn_login"}, quit = {"menu", "mn_quit"}, retry = {"status", "st_retry"},
                  back = {"status", "st_back"}}
function M.flash(kind, id)
    local d = S.docs[kind]
    if not d then return end
    pcall(function()
        local c = d[id].color
        if S.flash and S.flash.id == id then return end
        S.flash = {kind = kind, id = id, color = {c[1], c[2], c[3], c[4]}, t = time.uptime()}
        d[id].color = {math.min(255, c[1] + 90), math.min(255, c[2] + 90), math.min(255, c[3] + 90), 255}
    end)
    S.flashes = (S.flashes or 0) + 1
end

function M.flash_tick()
    local f = S.flash
    if f and time.uptime() - f.t > 0.2 then
        S.flash = nil
        local d = S.docs[f.kind]
        if d then pcall(function() d[f.id].color = f.color end) end
    end
end

function M.request(what, arg)
    S.requests[#S.requests + 1] = {what = what, arg = arg, t = time.uptime()}
    S.presses[what] = (S.presses[what] or 0) + 1
    log("request %s", what)
    local fl = FLASH_ID[what]
    if fl then M.flash(fl[1], fl[2]) end
    if what == "back" or what == "quit" then fx("stop") else fx("ok") end
end

function M.pop()
    local r = table.remove(S.requests, 1)
    return r
end

local function hint(text, deny)
    S.hint = text
    local d = S.docs.menu
    if d then pcall(function()
        d.mn_hint.text = text or ""
        d.mn_hint.color = deny and {255, 140, 120, 255} or {150, 220, 160, 255}
    end) end
end
M.hint = hint

-- «Войти»: fields -> validate -> login request (the app script runs it)
function M.ui_login()
    local d = S.docs.menu
    local addr, nick = S.fields.addr, S.fields.nick
    if d then pcall(function() addr, nick = d.mn_addr.text, d.mn_nick.text end) end
    S.fields.addr, S.fields.nick = addr, nick
    S.autofill = M.read_autofill() or S.autofill   -- the lab rewrites it when the stack comes up again (new ports)
    local t, kind, why = M.target(addr, nick)
    if not t then
        hint(why, true)
        M.flash("menu", "mn_login")
        S.presses.invalid = (S.presses.invalid or 0) + 1
        fx("deny", why)
        log("login refused by the form: %s %s", kind, why)
        return
    end
    hint("вход...", false)
    M.request("login", t)
end

function M.ui_recent(i)
    local x = S.recent[tonumber(i)]
    if not x then return end
    S.fields.addr, S.fields.nick = x.addr, x.nick
    M.fill()
    fx("select")
end

function M.ui_quit() M.request("quit") end

-- ------------------------------------------------------------------------------------------ F2F (test build only)
local function rects(doc, ids)
    local V = require "olife_client:status_view"
    local vp = gui.get_viewport()
    local k = 854 / vp[1]
    local r = {}
    for _, id in ipairs(ids) do r[id] = V.rect(doc, id, k) end
    return r
end

function M.f2f(args)
    args = args or {}
    local op = args.op or "state"
    local ST = require "olife_client:status"
    if op == "leave" then                       -- tests: leave the world like «Выйти в меню» of the pause menu
        S.leave = true
        return {leave = true, world_open = world.is_open()}
    end
    if op == "ui" then                          -- call a page action like a click would (diagnostics only)
        local f = M["ui_" .. tostring(args.call)]
        if not f then error("no ui_" .. tostring(args.call)) end
        return {result = f(args.arg)}
    end
    local r = {page = S.page, menu_page = menu and menu.page or nil, world_open = world.is_open(), fields = S.fields,
               hint = S.hint, presses = S.presses, scene = {model = M.SCENE, angle = S.angle, n = S.scene_n,
               err = S.scene_err}, recent = S.recent, status = ST.snapshot(), phase_app = S.app_phase,
               autofill = S.autofill and {gateway = S.autofill.gateway, auth = S.autofill.auth, account =
               S.autofill.account, has_token = (S.autofill.token or "") ~= ""} or nil, logins = S.logins,
               results = S.results, flashes = S.flashes or 0}
    pcall(function()
        local F = require("olife_client:fx").state()
        local l = {}
        for i = math.max(1, #F.log - 7), #F.log do l[#l + 1] = {event = F.log[i].event, sound = F.log[i].sound} end
        r.fx = {n = F.n, last = l}
    end)
    local d = S.docs.menu
    if d then
        local ok = pcall(function()
            r.menu_rects = rects(d, {"root", "mn_scene_box", "mn_scene", "mn_addr", "mn_nick", "mn_login", "mn_quit",
                                     "mn_recent", "mn_hint"})
            for i = 1, #S.recent do r.menu_rects["mn_r" .. i] = rects(d, {"mn_r" .. i})["mn_r" .. i] end
            r.texts = {addr = d.mn_addr.text, nick = d.mn_nick.text, hint = d.mn_hint.text, auto = d.mn_auto.text}
            r.scene_src = d.mn_scene.src
        end)
        r.menu_doc_ok = ok
    end
    local V = require "olife_client:status_view"
    r.status_page = V.f2f("page")
    r.status_hud = V.f2f("hud")
    pcall(function()
        local cl = require "olife_client:client"
        r.client = {state = cl.S.state, prelude = cl.S.prelude, session = cl.S.session, eid = cl.S.eid,
                    chunks = cl.S.nchunks, reconnects = cl.S.reconnects, tickets = cl.S.tickets,
                    disconnect = cl.S.stats.disconnect, last_code = cl.S.last_code}
        local P = require "olife_client:packs"
        r.packs = {version = P.S.version, applied = P.S.applied, live = P.S.live, downloaded = P.S.downloaded,
                   errors = P.S.errors, last_error = P.S.last_error, reopens = P.S.reopens, notified = P.S.notified}
        local ok, rev = pcall(P.live, "olife_client", "modules/hot/rev.lua")
        r.packs.rev = ok and type(rev) == "table" and rev.rev or nil
    end)
    return r
end

-- the F2F handler of the menu (no world: scripts/world.lua's handler is not there); in the world the pack's
-- world.lua handler answers `menu` too
function M.set_f2f()
    if f2f == nil or not f2f.is_active or not f2f.is_active() or not f2f.set_handler then return end
    if world.is_open() then return end
    f2f.set_handler(function(cmd, a)
        if cmd == "menu" then return M.f2f(a or {}) end
        if cmd == "fx" then return require("olife_client:fx").state() end
        if cmd == "mode" then return {} end
        error("unknown-command: " .. tostring(cmd))
    end)
end

return M
