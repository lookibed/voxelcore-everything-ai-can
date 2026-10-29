-- olife_client:assets — UX A4 (03.10, olife_a4): store assets on the client.
-- The world sends EntityAssets{eid, rev, assets[{slot, sha, kind, size}]} for entities in view; files come over the
-- gateway HTTP like packs (base = PacksChanged.url): GET <base>/assets/<sha>, sha256 checked, cached in
-- world:content/olife_assets/<sha>.<ext> (a later EntityAssets with the same sha is not downloaded again), then
-- registered with the engine AT RUNTIME (0.32, checked in tools/olife/probes/probe_store_window.lua):
--   png -> Canvas.decode -> canvas:create_texture("olife_assets/<sha>")   -> rig:set_texture("$i", name)
--   vcm -> assets.parse_model("vcm", text, "olife_assets:<sha>")          -> rig:set_model(bone, name)
--   ogg/wav -> the file itself: audio.play_stream("world:content/olife_assets/<sha>.ogg", ...)
--   vca -> assets.parse_animation (if it accepts the text) else file only; lua -> file only.
-- Nothing here needs a world reopen. Slots applied to the entity's skeleton: "tex:*" (all six $0..$5), "tex:$<i>",
-- "model:<bone>"; others ("sound:*", "anim:*", "lib:*") are only prefetched — A3's EntityAppearance / EntitySound
-- refer to them as "asset:<sha>" and resolve them through M.texture / M.model / M.sound_path (nil = not ready yet,
-- the download is started; M.on_ready(cb) fires when any file becomes ready).
-- PUBLIC API: M.ensure(sha, kind) -> state; M.texture(ref) / M.model(ref) / M.sound_path(ref) -> name | nil;
--             M.play(ref, x, y, z, volume, pitch) -> stream id | nil; M.parse_ref(ref) -> sha | nil; M.state(eid).
local M = {}

local KIND = {[1] = "png", [2] = "vcm", [3] = "ogg", [4] = "wav", [5] = "lua", [6] = "vca"}
M.KIND = KIND
local DIR = "world:content/olife_assets/"
local MAX_INFLIGHT = 4

local S = {base = nil, ents = {}, files = {}, queue = {}, inflight = 0, ready_cbs = {},
           stats = {manifests = 0, downloads = 0, bytes = 0, cached = 0, errors = 0, applied = 0, sha_bad = 0,
                    replies = 0, lists = 0, last_error = nil},
           replies = {}, list = nil}
M.S = S

local function log(fmt, ...) print("[olife_client] assets: " .. string.format(fmt, ...)) end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function bstr(b) if type(b) == "string" then return b end; return utf8.tostring(b) end
local function sha_hex(b) return hex(crypto.sha256(bstr(b))) end
M.sha_hex = sha_hex

function M.parse_ref(r)
    if type(r) ~= "string" then return nil end
    local s = r:match("^asset:([0-9a-f]+)$") or (#r == 64 and r:match("^([0-9a-f]+)$"))
    if s and #s == 64 then return s end
    return nil
end

function M.set_base(url)
    if type(url) == "string" and url ~= "" then S.base = url end
end

local function file_rec(sha, kind)
    local f = S.files[sha]
    if not f then
        f = {sha = sha, kind = kind or "png", state = "new", tries = 0}
        S.files[sha] = f
    elseif kind and f.kind ~= kind and f.state == "new" then
        f.kind = kind
    end
    return f
end

-- register the downloaded/cached file with the engine
local function register(f, bytes)
    local k = f.kind
    f.path = DIR .. f.sha .. "." .. k
    if k == "png" then
        local cv = Canvas.decode(bytes, "png")
        f.name = "olife_assets/" .. f.sha
        if vc.is_headless() then f.name = nil else cv:create_texture(f.name) end   -- bots: no GL, file + hash only
        f.w, f.h = cv.width, cv.height
        local okd, data = pcall(function() return cv:get_data() end)
        if okd and data then f.rgba_sha = sha_hex(data) end
    elseif k == "vcm" and not vc.is_headless() then
        f.name = "olife_assets:" .. f.sha
        assets.parse_model("vcm", bstr(bytes), f.name)
    elseif k == "vca" and not vc.is_headless() then
        f.name = "olife_assets:" .. f.sha
        local ok, err = pcall(assets.parse_animation, "vca", bstr(bytes), f.name)
        if not ok then f.note = tostring(err) end
    end
    f.state = "ready"
    for _, cb in ipairs(S.ready_cbs) do pcall(cb, f.sha, f) end
end

local function fail(f, why)
    f.state, f.error = "error", tostring(why)
    S.stats.errors = S.stats.errors + 1
    S.stats.last_error = f.error
    log("error %s: %s", f.sha:sub(1, 12), f.error)
end

local function http_get(url, ok, err)
    network.request(url, {method = "GET", timeout_ms = 10000, on_response = function(r)
        local st = r and r.status or 0
        if st >= 200 and st < 300 then return ok(r.body or "") end
        return err(st, r and r.body)
    end})
end

local function start(f)
    local cached = DIR .. f.sha .. "." .. f.kind
    if file.exists(cached) then
        local okr, b = pcall(file.read_bytes, cached)
        if okr and sha_hex(b) == f.sha then
            S.stats.cached = S.stats.cached + 1
            local okg, err = pcall(register, f, b)
            if not okg then fail(f, "register: " .. tostring(err)) end
            return
        end
    end
    if not S.base then f.state = "new"; return false end       -- no gateway URL yet: retried by pump
    f.state = "loading"
    f.tries = f.tries + 1
    S.inflight = S.inflight + 1
    local t0 = time.uptime()
    http_get(S.base .. "/assets/" .. f.sha, function(body)
        S.inflight = S.inflight - 1
        if sha_hex(body) ~= f.sha then S.stats.sha_bad = S.stats.sha_bad + 1; return fail(f, "sha mismatch") end
        S.stats.downloads = S.stats.downloads + 1
        S.stats.bytes = S.stats.bytes + #body
        f.ms = (time.uptime() - t0) * 1000
        pcall(file.mkdirs, DIR:sub(1, -2))
        pcall(file.write_bytes, cached, type(body) == "string" and Bytearray(body) or body)
        local okg, err = pcall(register, f, body)
        if not okg then fail(f, "register: " .. tostring(err)) end
    end, function(code)
        S.inflight = S.inflight - 1
        if f.tries < 3 then f.state = "new" else fail(f, "http " .. tostring(code)) end
    end)
    return true
end

-- -> "new" | "loading" | "ready" | "error"
function M.ensure(sha, kind)
    if not M.parse_ref(sha) then return "error" end
    sha = M.parse_ref(sha)
    local f = file_rec(sha, kind)
    if f.state == "new" and not f.queued then f.queued = true; S.queue[#S.queue + 1] = sha end
    return f.state
end

-- main Lua state, every world tick (client.maybe_connect): start queued downloads (network callbacks created here)
function M.pump()
    if #S.queue == 0 then return end
    local q = S.queue
    S.queue = {}
    for _, sha in ipairs(q) do
        local f = S.files[sha]
        f.queued = false
        if f.state == "new" then
            if S.inflight >= MAX_INFLIGHT or start(f) == false then
                f.queued = true
                S.queue[#S.queue + 1] = sha
            end
        end
    end
end

local function ready_name(ref, kind)
    local sha = M.parse_ref(ref)
    if not sha then return nil end
    local f = S.files[sha]
    if f and f.state == "ready" then return f end
    M.ensure(sha, kind)
    return nil
end
function M.texture(ref) local f = ready_name(ref, "png"); return f and f.name end
function M.model(ref) local f = ready_name(ref, "vcm"); return f and f.name end
function M.animation(ref) local f = ready_name(ref, "vca"); return f and f.name end
function M.sound_path(ref)
    local sha = M.parse_ref(ref)
    local f = sha and S.files[sha]
    if f and f.state == "ready" then return f.path end
    if sha then M.ensure(sha, f and f.kind or "ogg") end
    return nil
end
function M.play(ref, x, y, z, volume, pitch)
    local p = M.sound_path(ref)
    if not p then return nil end
    local ok, id = pcall(audio.play_stream, p, x, y, z, volume or 1, pitch or 1, "regular", false)
    return ok and id or nil
end
function M.on_ready(cb) S.ready_cbs[#S.ready_cbs + 1] = cb end

-- ------------------------------------------------------------------ messages
local H = {}
function H.EntityAssets(m)
    S.stats.manifests = S.stats.manifests + 1
    local slots = {}
    for _, a in ipairs(m.assets) do
        local kind = KIND[a.kind] or "png"
        slots[a.slot] = {sha = a.sha, kind = kind, size = a.size}
        M.ensure(a.sha, kind)
    end
    local e = S.ents[m.eid]
    S.ents[m.eid] = {rev = m.rev, slots = slots, applied = e and e.applied or {}, at = time.uptime()}
end
function H.AssetReply(m)
    S.stats.replies = S.stats.replies + 1
    S.replies[#S.replies + 1] = {seq = m.seq, op = m.op, code = m.code, sha = m.sha, reason = m.reason}
    while #S.replies > 32 do table.remove(S.replies, 1) end
end
function H.AssetList(m)
    S.stats.lists = S.stats.lists + 1
    S.list = m
end
M.handled = {EntityAssets = true, AssetReply = true, AssetList = true}
function M.on_msg(name, m) local h = H[name]; if h then h(m) end end

-- ------------------------------------------------------------------ apply to the replica (every tick)
local function cl() return require "olife_client:client" end

-- A3's mobview re-applies the whole look (base model first) when a mob's appearance changes: its applied record
-- (a new table each time) tells us to put the store model back on top
local function mobview_applied(eid)
    local ok, mv = pcall(require, "olife_client:mobview")    -- (package.loaded keys are "pack:modules/x.lua")
    if ok and type(mv) == "table" and mv.S and mv.S.applied then return mv.S.applied[eid] end
    return nil
end

local function apply_ent(eid, er)
    local e = cl().S.ents[eid]
    if not e or not e.uid then return end
    local ent = entities.get(e.uid)
    if not ent or not ent.skeleton then return end
    local rig = ent.skeleton
    for slot, a in pairs(er.slots) do
        local f = S.files[a.sha]
        if f and f.state == "ready" then
            local kind, arg = slot:match("^(%w+):(.+)$")
            if kind == "tex" and f.name then
                local list = arg == "*" and {"$0", "$1", "$2", "$3", "$4", "$5"} or {arg}
                for _, k in ipairs(list) do
                    -- re-checked every tick: EntityLook / A3 appearance may set the slot after us
                    local okg, cur = pcall(rig.get_texture, rig, k)
                    if not okg or cur ~= f.name then
                        if pcall(rig.set_texture, rig, k, f.name) then S.stats.applied = S.stats.applied + 1 end
                    end
                end
                er.applied[slot] = a.sha
            elseif kind == "model" and f.name then
                -- 0.32: skeleton:get_model(i) returns the override name only while it is NOT resolved yet; once the
                -- renderer resolved the model it returns the skeleton's own bone model again (lib__skeleton.cpp
                -- l_get_model) -> no read-back: re-applied when the entity, the file or A3's look application changes
                local okx, idx = pcall(rig.index, rig, arg)
                if okx and idx then
                    local key = e.uid .. ":" .. a.sha .. ":" .. tostring(mobview_applied(eid))
                    er.model_keys = er.model_keys or {}
                    if er.model_keys[slot] ~= key then
                        local oks, err = pcall(rig.set_model, rig, idx, f.name)
                        if oks then
                            S.stats.applied = S.stats.applied + 1
                            er.model_keys[slot] = key
                        else
                            er.err = tostring(err)
                        end
                    end
                    er.applied[slot] = a.sha
                end
            end
        end
    end
end

function M.tick()
    M.pump()
    for eid, er in pairs(S.ents) do
        if not cl().S.ents[eid] then S.ents[eid] = nil else apply_ent(eid, er) end
    end
end

-- ------------------------------------------------------------------ requests (UI / tests)
local seq = 900000
local function next_seq() seq = seq + 1; return seq end
function M.upload(kind_id, name, data, eid, slot)
    local s = next_seq()
    cl().send("AssetUpload", {seq = s, kind = kind_id, name = name or "", eid = eid or 0, slot = slot or "", data = data})
    return s
end
function M.op(op, sha, eid, slot, account)
    local s = next_seq()
    cl().send("AssetOp", {seq = s, op = op, sha = sha or "", eid = eid or 0, slot = slot or "", account = account or ""})
    return s
end

-- F2F / tests: what this client has for an entity: manifest, files (state, rgba sha256 of the decoded texture and
-- of the texture read back from the engine), what is applied on the skeleton now
function M.state(eid)
    local out = {base = S.base, stats = S.stats, inflight = S.inflight, queue = #S.queue, replies = S.replies}
    local function finfo(sha)
        local f = S.files[sha]
        if not f then return nil end
        local r = {state = f.state, kind = f.kind, name = f.name, path = f.path, rgba_sha = f.rgba_sha, w = f.w, h = f.h,
                   ms = f.ms, error = f.error, note = f.note}
        if f.state == "ready" and f.kind == "png" and f.name then
            local okc, cv = pcall(assets.to_canvas, f.name)
            if okc and cv then
                local okd, d = pcall(function() return cv:get_data() end)
                if okd and d then r.engine_rgba_sha = sha_hex(d) end
            end
        end
        return r
    end
    if eid then
        local er = S.ents[eid]
        if er then
            local slots, files = {}, {}
            for slot, a in pairs(er.slots) do slots[slot] = a.sha; files[a.sha] = finfo(a.sha) end
            local skel = {}
            local e = cl().S.ents[eid]
            local ent = e and e.uid and entities.get(e.uid)
            if ent and ent.skeleton then
                for i = 0, 5 do
                    local ok, t = pcall(ent.skeleton.get_texture, ent.skeleton, "$" .. i)
                    skel["$" .. i] = ok and t or nil
                end
                local okx, idx = pcall(ent.skeleton.index, ent.skeleton, "rody")
                if okx and idx then skel.rody_model = ent.skeleton:get_model(idx) end
            end
            out.entity = {eid = eid, rev = er.rev, slots = slots, files = files, applied = er.applied, skeleton = skel,
                          err = er.err}
        end
    end
    local n = {}
    for _, f in pairs(S.files) do n[f.state] = (n[f.state] or 0) + 1 end
    out.files = n
    if S.list then
        out.list = {used = S.list.used, quota = S.list.quota, count = S.list.count, credits = S.list.credits,
                    n = #S.list.assets}
    end
    return out
end

-- F2F `assets {op = state|upload|op|play, ...}` (scripts/world.lua)
function M.f2f(args)
    local op = args.op or "state"
    if op == "state" then return M.state(args.eid) end
    if op == "upload" then
        local data = args.b64 and base64.decode(args.b64) or (args.path and file.read_bytes(args.path)) or ""
        local s = M.upload(args.kind or 1, args.name, data, args.eid, args.slot)
        cl().flush()
        return {seq = s, bytes = #data}
    end
    if op == "op" then
        local s = M.op(args.aop, args.sha, args.eid, args.slot, args.account)
        cl().flush()
        return {seq = s}
    end
    if op == "play" then return {id = M.play(args.ref, args.x or 0, args.y or 0, args.z or 0, 1, 1)} end
    error("assets: unknown op " .. tostring(op))
end

function M.status()
    local n = {}
    for _, f in pairs(S.files) do n[f.state] = (n[f.state] or 0) + 1 end
    return string.format("assets(manifests=%d,ready=%d,loading=%d,errors=%d,dl=%d,bytes=%d,cached=%d,applied=%d)",
        S.stats.manifests, n.ready or 0, n.loading or 0, S.stats.errors, S.stats.downloads, S.stats.bytes,
        S.stats.cached, S.stats.applied)
end

return M
