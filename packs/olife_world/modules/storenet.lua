-- olife_world:storenet — UX A4 (03.10, olife_a4): the wire side of olife_world:store.
--   client.AssetUpload / AssetOp -> AssetReply (+ AssetList); EntityAssets (asset manifest of an entity) to the sessions
--   that see it, on change and when it enters their view; sandbox action `canvas.commit` (script canvas -> PNG -> slot);
--   admin commands (store_*); supervisor state (sup_state.store). Rights: an owner's own library is the owner's; slots
--   of an entity need A1's `storage_write` (owner / admin / whoever the owner allowed), reading a library is private.
local STORE = require "olife_world:store"
local net = require "olife_world:net"

local M = {}
local server, S
local C = STORE.CODE
local floor, min = math.floor, math.min

local ST = {q = {}, stats = {uploads = 0, upload_bytes = 0, ops = 0, lists = 0, manifests = 0, manifest_refs = 0,
                             canvas_ok = 0, canvas_refused = 0, replies = {}}}
M.ST = ST

local function log(fmt, ...) print("[olife_world] store: " .. string.format(fmt, ...)) end

function M.init(srv)
    server, S = srv, srv.S
    STORE.init(srv)
end

local function editor() return require "olife_world:editor" end

local function is_admin(sess) return editor().is_admin(sess) end

-- A1 rights when present (perms.allowed), else owner / admin
local function may(sess, e, action)
    if is_admin(sess) then return true end
    local okp, P = pcall(require, "olife_world:perms")
    if okp and P and P.allowed then
        local ok, r = pcall(P.allowed, sess, e, action)
        if ok then return r and true or false end
    end
    return e.owner_acct ~= nil and e.owner_acct ~= "" and e.owner_acct == sess.account
end

local function reply(sess, seq, op, code, sha, reason)
    ST.stats.replies[code] = (ST.stats.replies[code] or 0) + 1
    net.send_client(sess.gw, sess.sid, "AssetReply", {seq = seq, op = op, code = code, sha = (sha or ""):sub(1, 64),
                                                      reason = tostring(reason or STORE.REASON[code] or ""):sub(1, 128)})
end

local function rate_ok(sess)
    local now = time.uptime()
    local r, burst = STORE.T.upload_rate, STORE.T.upload_rate * 2
    local b = sess.store_bucket
    if not b then b = {tokens = burst, at = now}; sess.store_bucket = b end
    b.tokens = min(burst, b.tokens + (now - b.at) * r)
    b.at = now
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

local function list_msg(sess, seq)
    local q = STORE.quota(sess.account)
    local l = STORE.list(sess.account)
    local assets = {}
    for i = 1, min(#l, 256) do
        local a = l[i]
        assets[i] = {sha = a.sha, kind = STORE.KINDS[a.kind] or 0, size = a.size, name = (a.name or ""):sub(1, 32),
                     refs = min(a.refs or 0, 65535)}
    end
    ST.stats.lists = ST.stats.lists + 1
    net.send_client(sess.gw, sess.sid, "AssetList", {seq = seq, account = sess.account:sub(1, 64), used = q.used,
        quota = q.quota, count = min(q.count, 65535), max_count = min(q.max_count, 65535), credits = q.credits,
        assets = assets})
end

local function bill(sess)
    S.acct_actions[sess.account] = (S.acct_actions[sess.account] or 0) + 1
end

function M.AssetUpload(sess, m)
    bill(sess)
    if not rate_ok(sess) then return reply(sess, m.seq, 1, C.rate) end
    local kind = STORE.KIND_NAME[m.kind]
    if not kind then return reply(sess, m.seq, 1, C.bad_kind) end
    local e
    if m.eid ~= 0 then
        e = S.ents[m.eid]
        if not e or e.kind ~= 3 then return reply(sess, m.seq, 1, C.no_entity) end
        if not may(sess, e, "storage_write") then return reply(sess, m.seq, 1, C.forbidden) end
        if not STORE.valid_slot(m.slot) then return reply(sess, m.seq, 1, C.bad_arg) end
    end
    ST.stats.uploads = ST.stats.uploads + 1
    ST.stats.upload_bytes = ST.stats.upload_bytes + #m.data
    local sha, code, reason = STORE.put(sess.account, kind, m.data, {name = m.name})
    if sha and code == C.ok and e then
        code, reason = STORE.attach(e.eid, m.slot, sha, sess.account)
    end
    log("upload %s by %s: %s %d B -> %s code=%d", tostring(m.name), sess.account, kind, #m.data, tostring(sha), code)
    reply(sess, m.seq, 1, code, sha, reason)
    if code == C.ok then list_msg(sess, m.seq) end
end

function M.AssetOp(sess, m)
    bill(sess)
    local op = m.op + 1
    if m.op ~= 5 and m.op ~= 6 and not rate_ok(sess) then return reply(sess, m.seq, op, C.rate, m.sha) end
    ST.stats.ops = ST.stats.ops + 1
    if m.op == 1 or m.op == 2 then
        local e = S.ents[m.eid]
        if not e or e.kind ~= 3 then return reply(sess, m.seq, op, C.no_entity, m.sha) end
        if not may(sess, e, "storage_write") then return reply(sess, m.seq, op, C.forbidden, m.sha) end
        if m.op == 1 then
            local code, reason = STORE.attach(e.eid, m.slot, m.sha, sess.account)
            return reply(sess, m.seq, op, code, m.sha, reason)
        end
        return reply(sess, m.seq, op, STORE.detach(e.eid, m.slot), m.sha)
    elseif m.op == 3 then
        local code, reason = STORE.share(m.sha, sess.account, m.account)
        return reply(sess, m.seq, op, code, m.sha, reason)
    elseif m.op == 4 then
        return reply(sess, m.seq, op, STORE.release(sess.account, m.sha), m.sha)
    elseif m.op == 5 then
        reply(sess, m.seq, op, C.ok)
        return list_msg(sess, m.seq)
    elseif m.op == 6 then
        local e = S.ents[m.eid]
        if not e then return reply(sess, m.seq, op, C.no_entity) end
        reply(sess, m.seq, op, C.ok)
        sess.assets_seen = sess.assets_seen or {}
        sess.assets_seen[m.eid] = nil               -- next replicate sends it
        return
    end
    return reply(sess, m.seq, op, C.bad_arg, m.sha)
end

-- phase 4, per session (after its snapshot): EntityAssets of entities it sees, when their store rev changed
local function manifest(eid, rev)
    local out = {}
    for slot, sha in pairs(STORE.entity_assets(eid)) do
        local i = STORE.info(sha) or {}
        out[#out + 1] = {slot = slot:sub(1, 32), sha = sha, kind = STORE.KINDS[i.kind] or 0, size = i.size or 0}
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    while #out > 32 do out[#out] = nil end
    return {eid = eid, rev = rev, assets = out}
end
M.manifest = manifest

function M.replicate(sess)
    local seen = sess.assets_seen
    if not seen then seen = {}; sess.assets_seen = seen end
    for eid in pairs(sess.view) do
        local rev = STORE.entity_rev(eid)
        if rev > 0 and seen[eid] ~= rev then
            seen[eid] = rev
            local msg = manifest(eid, rev)
            net.send_client(sess.gw, sess.sid, "EntityAssets", msg)
            ST.stats.manifests = ST.stats.manifests + 1
            ST.stats.manifest_refs = ST.stats.manifest_refs + #msg.assets
        end
    end
    for eid in pairs(seen) do if not sess.view[eid] then seen[eid] = nil end end
end

-- sandbox action canvas.commit {slot, w, h, rgba (Bytearray, binary contract) | rgba_b64 (JSON lines)}
-- -> code, reason, sha (sandbox.lua turns a refusal into a `rejected` event for the script)
function M.canvas_action(e, a)
    local rgba = a.rgba
    if rgba == nil and type(a.rgba_b64) == "string" then
        local ok, b = pcall(base64.decode, a.rgba_b64)
        if ok then rgba = b end
    end
    local code, reason, sha = STORE.canvas_commit(e, a.slot, a.w, a.h, rgba)
    if code == C.ok then ST.stats.canvas_ok = ST.stats.canvas_ok + 1
    else ST.stats.canvas_refused = ST.stats.canvas_refused + 1 end
    return code, reason, sha
end

-- ------------------------------------------------------------------------------------------ admin / tests
local function qpush(a) ST.q[#ST.q + 1] = a end

function M.tick()
    STORE.tick()
    if #ST.q == 0 then return end
    local q = ST.q
    ST.q = {}
    for _, a in ipairs(q) do
        if a.op == "restore" then
            local okr, blob = pcall(file.read, a.path)
            if not okr then log("restore: cannot read %s", a.path)
            else
                local eid, code, reason = STORE.restore(blob, {owner = a.owner ~= "" and a.owner or nil})
                log("restored eid=%s code=%d %s from %s", tostring(eid), code or -1, tostring(reason or ""), a.path)
            end
        elseif a.op == "kv_set" then
            local v = a.value
            if v == "nil" then v = nil elseif tonumber(v) then v = tonumber(v) end
            local code = STORE.kv_set(a.eid, a.key, v)
            log("kv_set eid=%d key=%s code=%d", a.eid, a.key, code)
        elseif a.op == "canvas_test" then
            local w, h = a.w, a.h
            local b = Bytearray(w * h * 4)
            for i = 1, w * h do
                local x, y = (i - 1) % w, floor((i - 1) / w)
                b[i * 4 - 3], b[i * 4 - 2], b[i * 4 - 1], b[i * 4] = (x * 8 + a.seed) % 256, (y * 8) % 256, a.seed % 256, 255
            end
            local code, reason, sha = STORE.canvas_commit(S.ents[a.eid], a.slot, w, h, b)
            log("canvas_test eid=%d code=%d sha=%s", a.eid, code, tostring(sha))
        end
    end
end

local function js(t) return json.tostring(t) end

function M.register_commands()
    console.add_command("store_status", "UX A4: store counters, files, CAS bytes, per-owner usage", function()
        return "[olife_world] " .. STORE.status() .. " " .. js(STORE.summary().owners)
    end)
    console.add_command("store_quota account:str", "UX A4: quota/credits of an account", function(args)
        return "[olife_world] store_quota " .. args[1] .. " " .. js(STORE.quota(args[1]))
    end)
    console.add_command("store_list account:str", "UX A4: library of an account", function(args)
        return "[olife_world] store_list " .. args[1] .. " " .. js(STORE.list(args[1]))
    end)
    console.add_command("store_kv eid:int", "UX A4: KV of an entity", function(args)
        local used, q, n, mk = STORE.kv_usage(args[1])
        return string.format("[olife_world] store_kv eid=%d used=%d quota=%d keys=%d max_keys=%d kv=%s", args[1], used, q,
            n, mk, js(STORE.kv_all(args[1])))
    end)
    console.add_command("store_kv_set eid:int key:str value:str", "UX A4 (tests): KV write as the entity's owner " ..
        "(\"nil\" deletes; numbers stay numbers)", function(args)
        qpush({op = "kv_set", eid = args[1], key = args[2], value = args[3]})
        return "[olife_world] store_kv_set queued"
    end)
    console.add_command("store_entity eid:int", "UX A4: asset slots of an entity", function(args)
        return string.format("[olife_world] store_entity eid=%d rev=%d assets=%s", args[1], STORE.entity_rev(args[1]),
            js(STORE.entity_assets(args[1])))
    end)
    console.add_command("store_snapshot eid:int", "UX A4: snapshot an entity into user:export/snap_<eid>.json",
        function(args)
        local path = "user:export/snap_" .. args[1] .. ".json"
        local blob, n, reason = STORE.snapshot(args[1], {charge = false})
        if not blob then return "[olife_world] store_snapshot failed code=" .. tostring(n) .. " " .. tostring(reason) end
        file.write(path, blob)
        return string.format("[olife_world] store_snapshot eid=%d bytes=%d sha=%s path=%s", args[1], n,
            STORE.sha_of(blob), path)
    end)
    console.add_command("store_restore src:int account:str=''", "UX A4: restore user:export/snap_<src>.json (written by " ..
        "store_snapshot) as a new bench of <account> (default: the snapshot's owner; queued into the tick)", function(args)
        local path = "user:export/snap_" .. args[1] .. ".json"
        qpush({op = "restore", path = path, owner = args[2]})
        return "[olife_world] store_restore queued " .. path
    end)
    console.add_command("store_gc grace:int=-1", "UX A4: GC unreferenced files now (grace seconds, -1 = tariff)",
        function(args)
            local n, b, left = STORE.gc(args[1] >= 0 and args[1] or nil)
            return string.format("[olife_world] store_gc removed=%d bytes=%d unreferenced_left=%d", n, b, left)
        end)
    console.add_command("store_tariff key:str value:str", "UX A4: set a store tariff/quota live (store.<key> of " ..
        "the supervisor DB)", function(args)
        local ok = STORE.set_tariff(args[1], args[2])
        return string.format("[olife_world] store_tariff %s=%s %s", args[1], tostring(args[2]), ok and "ok" or "unknown")
    end)
    console.add_command("store_tariffs", "UX A4: current store tariffs", function()
        return "[olife_world] store_tariffs " .. js(STORE.T)
    end)
    console.add_command("store_canvas_test eid:int w:int h:int seed:int=0 slot:str=''",
        "UX A4 (tests): commit a generated canvas to an entity as its owner (queued into the tick)", function(args)
        qpush({op = "canvas_test", eid = args[1], w = args[2], h = args[3], seed = args[4], slot = args[5] ~= "" and args[5] or "tex:*"})
        return "[olife_world] store_canvas_test queued"
    end)
    console.add_command("store_rgba ref:str", "UX A4 (tests): sha256 of the RGBA of a stored PNG (what a client " ..
        "texture must hold); ref = asset:<sha> (a bare sha that starts with a digit is not a str for the console)",
        function(args)
        args[1] = STORE.parse_ref(args[1]) or args[1]
        local b = STORE.get(args[1])
        if not b then return "[olife_world] store_rgba missing " .. args[1] end
        local ok, cv = pcall(Canvas.decode, Bytearray(b), "png")
        if not ok then return "[olife_world] store_rgba bad png " .. tostring(cv) end
        return string.format("[olife_world] store_rgba sha=%s w=%d h=%d rgba_sha=%s png_bytes=%d", args[1], cv.width,
            cv.height, STORE.sha_of(cv:get_data()), #b)
    end)
    console.add_command("store_flush", "UX A4: write the store index and dirty KV now", function()
        STORE.flush(true)
        return "[olife_world] store_flush ok"
    end)
end

function M.status()
    local s = ST.stats
    return STORE.status() .. string.format(" storenet(uploads=%d,upload_bytes=%d,ops=%d,lists=%d,manifests=%d," ..
        "canvas_ok=%d,canvas_refused=%d)", s.uploads, s.upload_bytes, s.ops, s.lists, s.manifests, s.canvas_ok,
        s.canvas_refused)
end

function M.sup_state() return STORE.summary() end

return M
