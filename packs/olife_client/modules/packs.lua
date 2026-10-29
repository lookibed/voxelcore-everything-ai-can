-- olife_client:packs — wave 4b: pack hot reload. The gateway sends client.PacksChanged{version, url, files} after
-- Welcome and whenever the supervisor's pack manifest changes. The client:
--   1. GET <url>/manifest.json; for every client/both file compare sha256 with the file the engine has loaded now
--      ("<pack>:<path>" = the pack's current location) -> list of changed / new files;
--   2. GET <url>/files/<pack>/<path> for each changed file, sha256 checked against the manifest;
--   3. materializes the WHOLE changed pack in world:content/<pack>/ (changed files from the server, the rest copied
--      from the current location) — world:content has the highest content-source priority in 0.32, a partial
--      directory there would shadow the pack;
--   4. applies what can be applied live, and asks for a world reopen for the rest.
-- What is live (checked in 0.32, tools/olife/probes/probe_packs.lua): data files and "hot" Lua modules that the pack
-- reads through M.live(pack, path) — `modules/hot/*.lua` (re-`load`ed from world:content, `load` is available) and
-- `config/*.json` (re-read). Everything else — scripts/*.lua (world/components events), other modules (require
-- caches them; the start script holds references), content definitions (blocks/items/entities json: indices!),
-- textures/models/skeletons/layouts, package.json/content.json — needs app.reopen_world(): the engine re-scans the
-- content sources on open and takes the pack from world:content (pack.get_info().path becomes
-- "world:content/<pack>"). The client does that itself (client_start.lua): Bye, reopen, fresh modules, new ticket,
-- reconnect; the replica is rebuilt from the server like after a reconnect. New blocks additionally need the world
-- server to have the same pack set (Welcome.blocks).
-- UX B (16.10, olife_menu): the same steps are also used by the login BEFORE the replica world exists (the status
-- screen shows them): M.check (manifest + sha256 diff against the loaded packs), M.fetch (downloads with progress and
-- a sha256 check per file; S.progress), M.stage (materialize into world:content once the world is open). Errors are
-- structured: S.last_err = {phase = manifest|download|verify, code = HTTP status | "sha256", text}.
local M = {}

local S = {version = nil, busy = false, url = nil, applied = 0, downloaded = 0, bytes = 0, live = 0, reopen = false,
           reopen_paths = {}, last = nil, errors = 0, last_error = nil, notified = 0, last_ms = nil, hot = {}}
M.S = S

local function log(fmt, ...) print("[olife_client] packs: " .. string.format(fmt, ...)) end

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- Bytearray (file.read_bytes, network.get_binary) -> Lua string (crypto.* takes strings only: "string expected")
local function bstr(b)
    if type(b) == "string" then return b end
    local parts, n = {}, #b
    for i = 1, n, 4096 do
        local t = {}
        for j = i, math.min(n, i + 4095) do t[#t + 1] = b[j] end
        parts[#parts + 1] = string.char(unpack(t))
    end
    return table.concat(parts)
end
local function sha_hex(b) return hex(crypto.sha256(bstr(b))) end

-- HTTP GET through network.request: in 0.32 (dc62ccfb) res/scripts/classes.lua network.get_binary and network.post
-- test `response.code` (nil -> "attempt to perform arithmetic on field 'code'" inside the stdlib callback, the
-- caller's callbacks never run) and network.get takes only status == 200 exactly (status / 100 == 2 is a float test)
local function http_get(url, ok, err)
    network.request(url, {method = "GET", timeout_ms = 10000, on_response = function(r)
        local st = r and r.status or 0
        if st >= 200 and st < 300 then return ok(r.body or "") end
        return err(st, r and r.body)
    end})
end

-- the client's current copy of a pack file: world:content/<pack>/ once it was materialized (complete copy), else the
-- location the engine loaded the pack from
local function cur(pack, rel)
    -- in the menu (UX B login) there is no world: entry point yet -> the pack's location
    local ok, isd = pcall(file.isdir, "world:content/" .. pack)
    if ok and isd then return "world:content/" .. pack .. "/" .. rel end
    return pack .. ":" .. rel
end

local function local_sha(pack, rel)
    local p = cur(pack, rel)
    if not file.exists(p) then return nil end
    local ok, b = pcall(file.read_bytes, p)
    if not ok then return nil end
    return sha_hex(b)
end

local function is_live(rel)
    return rel:match("^modules/hot/[%w_]+%.lua$") ~= nil or rel:match("^config/[%w_%-]+%.json$") ~= nil
end

local function parent(p) return p:match("^(.*)/[^/]+$") end

local function fail(why, phase, code)
    S.errors = S.errors + 1
    S.last_error = why
    S.last_err = {phase = phase or "download", code = code, text = why}
    S.busy = false
    log("error: %s", why)
end

-- live module: the newest version (world:content if staged there, else the pack) -> table; cached until changed
function M.live(pack, rel)
    local key = pack .. ":" .. rel
    local h = S.hot[key]
    if h and not h.dirty then return h.value end
    local path = file.exists("world:content/" .. pack .. "/" .. rel) and ("world:content/" .. pack .. "/" .. rel)
                 or key
    local v
    if rel:sub(-5) == ".json" then
        v = json.parse(file.read(path))
    else
        local fn, err = load(file.read(path), "@" .. key)
        if not fn then error(err) end
        v = fn()
    end
    S.hot[key] = {value = v, dirty = false, path = path}
    return v
end

local function materialize(base, m, changed, data, t0)
    -- per pack with changes: copy the current files + write the downloaded ones into world:content/<pack>/
    local packs = {}
    for _, c in ipairs(changed) do packs[c.pack] = true end
    for pk in pairs(packs) do
        local root = "world:content/" .. pk .. "/"
        if not file.isdir("world:content/" .. pk) then S.copied_from = pack.get_info(pk).path end
        for _, e in ipairs(m.packs[pk].files) do
            if e.side == "client" or e.side == "both" then
                local dst = root .. e.path
                local d = parent(dst)
                if d then pcall(file.mkdirs, d) end
                local b = data[pk .. "/" .. e.path]
                if b then
                    file.write_bytes(dst, Bytearray(b))
                elseif not file.exists(dst) then
                    file.write_bytes(dst, file.read_bytes(pk .. ":" .. e.path))
                end
            end
        end
    end
    local live, reopen = 0, {}
    for _, c in ipairs(changed) do
        if is_live(c.path) then
            local h = S.hot[c.pack .. ":" .. c.path]
            if h then h.dirty = true end
            live = live + 1
        else
            reopen[#reopen + 1] = c.pack .. "/" .. c.path
        end
    end
    S.live = S.live + live
    S.applied = S.applied + 1
    S.version = m.version
    S.busy = false
    S.last_ms = (time.uptime() - t0) * 1000
    S.last = {version = m.version, changed = #changed, live = live, reopen = #reopen, ms = S.last_ms}
    if #reopen > 0 then
        S.reopen = true
        for _, p in ipairs(reopen) do S.reopen_paths[#S.reopen_paths + 1] = p end
    end
    log("applied version=%s changed=%d live=%d reopen=%d (%s) in %.0f ms", m.version:sub(1, 12), #changed, live,
        #reopen, table.concat(reopen, ","):sub(1, 200), S.last_ms)
    if M.on_applied then M.on_applied(S.last) end
end

-- client.PacksChanged handler: only queues — client.tick runs in the start-script coroutine, and network callbacks
-- created there stay bound to it (they kill it when called between frames); M.pump runs in on_world_tick (main state)
function M.on_changed(msg)
    S.notified = S.notified + 1
    S.pending = msg
end

function M.pump()
    local msg = S.pending
    if not msg or S.busy then return end
    S.pending = nil
    M.process(msg)
end

-- manifest + diff: ok_cb(m, changed, n_files) | err_cb(why, phase, code)
function M.check(url, ok_cb, err_cb)
    http_get(url .. "/manifest.json", function(text)
        local ok, m = pcall(json.parse, text)
        if not ok or type(m) ~= "table" or type(m.packs) ~= "table" then
            return err_cb("bad manifest json", "manifest", "json")
        end
        local changed, n = {}, 0
        local okd, errd = pcall(function()
            for pk, info in pairs(m.packs) do
                for _, e in ipairs(info.files or {}) do
                    if e.side == "client" or e.side == "both" then
                        n = n + 1
                        if local_sha(pk, e.path) ~= e.sha256 then
                            changed[#changed + 1] = {pack = pk, path = e.path, sha = e.sha256, size = e.size}
                        end
                    end
                end
            end
        end)
        if not okd then return err_cb("diff: " .. tostring(errd), "manifest", "diff") end
        table.sort(changed, function(a, b) return a.pack .. "/" .. a.path < b.pack .. "/" .. b.path end)
        ok_cb(m, changed, n)
    end, function(code, body)
        err_cb("GET " .. url .. "/manifest.json -> " .. tostring(code) .. (body and body ~= "" and
            (" " .. tostring(body):sub(1, 80)) or ""), "manifest", code)
    end)
end

-- downloads (up to 4 at once), sha256 per file; progress in S.progress and on_progress(S.progress);
-- ok_cb(data: {"pack/path" = bytes}) | err_cb(why, phase download|verify, code)
function M.fetch(url, changed, on_progress, ok_cb, err_cb)
    local pr = {done = 0, total = #changed, bytes = 0, bytes_total = 0, verified = 0, verify_total = #changed}
    for _, c in ipairs(changed) do pr.bytes_total = pr.bytes_total + (tonumber(c.size) or 0) end
    S.progress = pr
    local data, next_i, active, dead = {}, 1, 0, false
    local function report() if on_progress then pcall(on_progress, pr) end end
    local function start_next()
        while not dead and active < 4 and next_i <= #changed do
            local c = changed[next_i]
            next_i = next_i + 1
            active = active + 1
            pr.pack, pr.file = c.pack, c.path
            report()
            http_get(url .. "/files/" .. c.pack .. "/" .. c.path, function(b)
                if dead then return end
                active = active - 1
                pr.done, pr.bytes = pr.done + 1, pr.bytes + #b
                local sh = sha_hex(b)
                if sh ~= c.sha then
                    dead = true
                    report()
                    return err_cb(string.format("%s/%s: в манифесте %s, получено %s (%d байт)", c.pack, c.path,
                        c.sha:sub(1, 16), sh:sub(1, 16), #b), "verify", "sha256")
                end
                pr.verified = pr.verified + 1
                data[c.pack .. "/" .. c.path] = b
                S.downloaded = S.downloaded + 1
                S.bytes = S.bytes + #b
                report()
                if pr.done == pr.total then return ok_cb(data) end
                start_next()
            end, function(code, body)
                if dead then return end
                dead = true
                active = active - 1
                err_cb(string.format("GET %s/%s -> %s %s", c.pack, c.path, tostring(code),
                    tostring(body or ""):sub(1, 60)), "download", code)
            end)
        end
    end
    if #changed == 0 then return ok_cb(data) end
    start_next()
end

-- the world is open: write the changed packs into world:content (whole packs) -> {live, reopen}; the caller reopens
function M.stage(m, changed, data)
    local t0 = time.uptime()
    S.busy = true
    local okm, err = pcall(materialize, nil, m, changed, data, t0)
    S.busy = false
    if not okm then
        fail("materialize: " .. tostring(err), "world", "write")
        return nil, err
    end
    return S.last
end

function M.process(msg)
    if msg.version == S.version or msg.url == "" then return end
    S.busy, S.url = true, msg.url
    S.phase = "manifest"
    local t0 = time.uptime()
    M.check(msg.url, function(m, changed, n)
        if #changed == 0 then
            S.version, S.busy, S.phase = m.version, false, nil
            S.last = {version = m.version, changed = 0, ms = (time.uptime() - t0) * 1000}
            log("version=%s: nothing changed (%d files)", m.version:sub(1, 12), msg.files)
            return
        end
        S.phase = "download"
        M.fetch(msg.url, changed, nil, function(data)
            if not S.busy then return end
            S.phase = nil
            local okm, err = pcall(materialize, nil, m, changed, data, t0)
            if not okm then fail("materialize: " .. tostring(err), "world", "write") end
        end, function(why, phase, code)
            S.phase = nil
            if S.busy then fail(why, phase, code) end
        end)
    end, function(why, phase, code)
        S.phase = nil
        fail(why, phase, code)
    end)
end

-- UX B: the new instance after app.reopen_world() takes over the state (version, counters); live modules reload
function M.adopt(t)
    if t == nil or t == S then return end
    t.hot = {}
    S = t
    M.S = t
end

function M.reopen_pending() return S.reopen end

function M.status()
    local rev = "-"
    local ok, r = pcall(M.live, "olife_client", "modules/hot/rev.lua")
    if ok and type(r) == "table" then rev = tostring(r.rev) end
    local info = pack.get_info("olife_client") or {}
    return string.format("packs_version=%s packs_applied=%d packs_live=%d packs_reopen=%s packs_dl=%d packs_errors=%d " ..
        "packs_rev=%s packs_path=%s packs_notified=%d", tostring(S.version):sub(1, 12), S.applied, S.live,
        tostring(S.reopen), S.downloaded, S.errors, rev, tostring(info.path), S.notified)
end

return M
