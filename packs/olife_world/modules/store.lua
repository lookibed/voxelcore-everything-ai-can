-- olife_world:store — UX A4 (03.10, olife_a4): the per-mob KV and the per-owner asset store of the world.
-- Everything here is server-side and authoritative; scripts (sandbox actions / A3's mob API), the editor, A1's fork and
-- the future Spammer call the API below. STABLE API (other modules depend on it — extend, never change signatures):
--
--   KV per entity (mob) — memory of the script, survives restart and respawn-from-snapshot:
--     STORE.kv_get(eid, key)            -> value | nil
--     STORE.kv_set(eid, key, value)     -> code, reason      (value nil = delete; JSON-able: string/number/boolean,
--                                                             tables of them up to depth 4; size = #key + #JSON)
--     STORE.kv_all(eid)                 -> {key = value}      (a copy)
--     STORE.kv_keys(eid)                -> {key, ...} (sorted)
--     STORE.kv_usage(eid)               -> used_bytes, quota_bytes, keys, max_keys
--   assets per owner (account string; "_world" for entities without an account) in a sha256 CAS:
--     STORE.put(owner, kind, bytes, meta)   -> sha | nil, code, reason   (kind "png"|"vcm"|"ogg"|"wav"|"lua"|"vca";
--                                              bytes = Lua string or Bytearray; meta = {name=, eid=, slot=, lib=false})
--     STORE.get(sha)                    -> string | nil       (file bytes)
--     STORE.has(sha [, owner])          -> bool               (in the CAS / in the owner's library or own slots)
--     STORE.info(sha)                   -> {kind, size, ext, t} | nil
--     STORE.list(owner)                 -> {{sha, kind, size, name, refs}, ...}
--     STORE.quota(owner)                -> {used, quota, count, max_count, credits, credits_max}
--     STORE.release(owner, sha)         -> code               (drop from the library; GC removes unreferenced files)
--     STORE.share(sha, from, to)        -> code, reason       (to: account; the file stays one copy in the CAS)
--     STORE.attach(eid, slot, sha [, by]) -> code, reason     (entity asset slot; by = account asking, nil = system)
--     STORE.detach(eid, slot)           -> code
--     STORE.entity_assets(eid)          -> {slot = sha}       (a copy)
--     STORE.ref(sha)                    -> "asset:<sha>"; STORE.parse_ref("asset:<sha>") -> sha | nil
--   canvas (script procedural texture): STORE.canvas_commit(e, slot, w, h, rgba) -> code, reason, sha
--   transfer: STORE.fork(src_eid, dst_eid, owner) -> code (KV copied, asset slots shared through the CAS)
--             STORE.snapshot(eid) -> blob (JSON text), size | nil, code, reason
--             STORE.restore(blob, {owner=, name=, pos={x,y,z}, run=}) -> eid | nil, code, reason
--   STORE.CODE (store codes, also on the wire: client.yaml «UX A4»), STORE.T (tariffs/quotas, live: set_tariff)
--   UX B2 (olife_b2, Spammer) — snapshot library per owner (blobs of M.snapshot kept on the world):
--     STORE.snap_put(owner, blob, meta)  -> id | nil, code, reason   (meta = {name, src_eid, src_name, src_owner, model,
--                                            texture, status, code_fnv}; quota snap_max / snap_quota; files pinned)
--     STORE.snap_get(owner, id)         -> rec | nil  (rec.blob loaded from world:olife_store/snaps/<owner>/<id>.json)
--     STORE.snap_list(owner)            -> {rec, ...} by id (without blobs)
--     STORE.snap_rename(owner, id, name) / STORE.snap_delete(owner, id) / STORE.snap_bump(owner, id) -> code | n
--     STORE.snap_quota(owner)           -> {count, max_count, used, quota}
--     STORE.snap_can_restore(owner, blob) -> code, reason   (files present, asset quota, credits — no side effects)
--
-- Files (all under the world save, `world:olife_store/`): index.json (owners' libraries, entity slots, blob table,
-- counters), kv/<eid>.json, cas/<aa>/<sha> (the file itself, no extension; the gateway serves
-- GET /assets/<sha> from <world>\olife_store\cas). Written when dirty, at most every `flush_ticks`, at once on `save`.
-- Billing: every write costs store credits from the owner's bucket (refill `credits_per_s`, burst `credits_burst`);
-- an empty bucket refuses with 44. Counters per owner -> supervisor state (sup_state.store) -> supervisor DB.
local M = {}
local server, S
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

M.CODE = {ok = 0, no_entity = 40, forbidden = 41, kv_quota = 42, asset_quota = 43, tariff = 44, too_large = 45,
          bad_kind = 46, no_asset = 47, rate = 48, bad_arg = 49}
local C = M.CODE
M.REASON = {[0] = "ok", [40] = "no such entity / not a scripted bench", [41] = "forbidden", [42] = "KV quota",
            [43] = "asset quota", [44] = "store credits exhausted (tariff)", [45] = "too large",
            [46] = "bad kind / format", [47] = "no such asset", [48] = "rate", [49] = "bad key / value / argument"}

-- tariffs / quotas (supervisor DB keys `store.<name>`, pushed live: console `store_tariff <name> <value>`)
M.T = {
    kv_quota = 65536, kv_keys = 256, kv_key_max = 64, kv_value_max = 4096,
    owner_quota = 8388608, owner_assets = 256, asset_max = 1048576,
    credits_per_s = 100, credits_burst = 1000,
    price_kv_base = 1, price_kv_per_kb = 4,             -- KV write: 1 + 4 per KiB of key+value
    price_put_base = 10, price_put_per_kb = 1,          -- new file in the CAS: 10 + 1 per KiB (dedup hit: base only)
    price_canvas_base = 2, price_canvas_per_kpx = 1,    -- canvas commit: 2 + 1 per 1024 pixels (+ put of the PNG)
    price_share = 5, price_attach = 1, price_snapshot = 10, price_restore = 20,
    canvas_max = 256, canvas_min_ticks = 5,             -- side <= 256 px; one commit per entity per 5 ticks
    upload_rate = 2,                                    -- AssetUpload/AssetOp per second per session (burst 2x)
    gc_grace_s = 600, gc_pool = 16777216,               -- unreferenced files: kept 10 min / up to 16 MiB, then removed
    flush_ticks = 20,
    -- UX B2 (Spammer): snapshot library per owner and spawn limits (capture = price_snapshot, throw = price_restore)
    snap_max = 32, snap_quota = 262144,                 -- snapshots per owner: count, bytes of blobs
    spawn_per_min = 10, mobs_max = 32,                  -- throws per minute per owner; benches an owner may have
}
local T = M.T

local KINDS = {png = 1, vcm = 2, ogg = 3, wav = 4, lua = 5, vca = 6}
local KIND_NAME = {}
for k, v in pairs(KINDS) do KIND_NAME[v] = k end
M.KINDS, M.KIND_NAME = KINDS, KIND_NAME
local MAX_SIZE = {png = 262144 * 2, vcm = 262144, ogg = 1048576, wav = 1048576, lua = 65536, vca = 262144}

local ROOT = "world:olife_store/"
local ST = {
    loaded = false, dirty = false, written_tick = 0,
    owners = {},      -- account -> {lib = {sha -> {name, t}}}
    blobs = {},       -- sha -> {kind, size, t, unref = ms | nil}
    ents = {},        -- eid -> {owner = acct, rev, slots = {slot -> sha}}
    kv = {},          -- eid -> {data = {}, used, n, dirty}   (lazy: loaded on first touch)
    kv_dirty = {},
    bucket = {},      -- owner -> {tokens, at}
    acct = {},        -- owner -> counters since start {writes, bytes, credits, refused, kv_writes, canvas, puts, dedup}
    stats = {puts = 0, dedup = 0, kv_writes = 0, canvas = 0, refused = {}, gc_removed = 0, gc_bytes = 0, snapshots = 0,
             restores = 0, forks = 0, shares = 0, served = 0, upload_bytes = 0},
    sess_rev = {},    -- unused (sessions keep their own seen table)
    snaps = {},       -- UX B2: owner -> {next_id, items = {id -> {name, size, tick, ms, ver, spawned, status, model,
                      --   texture, code_fnv, src_eid, src_name, src_owner, assets = {sha...}, blob (lazy)}}}
}
M.ST = ST

local function log(fmt, ...) print("[olife_world] store: " .. string.format(fmt, ...)) end
local function now_ms() return time.uptime() * 1000 end
-- UX B2: wall clock for snapshot stamps (unix ms; the engine's precise UTC clock when present)
local function now_ms_wall()
    local ok, v = pcall(function() return time.precise_utc_time() * 1000 end)
    if ok and type(v) == "number" then return v end
    local ok2, t = pcall(os.time)
    return ok2 and t * 1000 or 0
end
M.now_ms_wall = now_ms_wall

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function bstr(b)
    if type(b) == "string" then return b end
    return utf8.tostring(b)            -- Bytearray -> byte-exact Lua string (checked in 0.32: PNG 102 B -> 102)
end
M.bstr = bstr
local function sha_of(s) return hex(crypto.sha256(s)) end
M.sha_of = function(b) return sha_of(bstr(b)) end
local function is_sha(s) return type(s) == "string" and #s == 64 and s:match("^[0-9a-f]+$") ~= nil end
M.is_sha = is_sha
function M.ref(sha) return "asset:" .. sha end
function M.parse_ref(r)
    if type(r) ~= "string" then return nil end
    local s = r:match("^asset:([0-9a-f]+)$")
    if s and #s == 64 then return s end
    return nil
end
local function cas_path(sha) return ROOT .. "cas/" .. sha:sub(1, 2) .. "/" .. sha end

local function acct_of(e)
    if not e then return "_world" end
    local a = e.owner_acct
    if a == nil or a == "" then return "_world" end
    return a
end
M.acct_of = acct_of

local function counters(owner)
    local c = ST.acct[owner]
    if not c then
        c = {writes = 0, bytes = 0, credits = 0, refused = 0, kv_writes = 0, canvas = 0, puts = 0, dedup = 0}
        ST.acct[owner] = c
    end
    return c
end

local function refuse(owner, code)
    ST.stats.refused[code] = (ST.stats.refused[code] or 0) + 1
    if owner then counters(owner).refused = counters(owner).refused + 1 end
    return code, M.REASON[code]
end

-- ------------------------------------------------------------------------------------------ credits (tariff)
local function bucket(owner)
    local b = ST.bucket[owner]
    local t = now_ms()
    if not b then b = {tokens = T.credits_burst, at = t}; ST.bucket[owner] = b end
    b.tokens = min(T.credits_burst, b.tokens + (t - b.at) / 1000 * T.credits_per_s)
    b.at = t
    return b
end
-- charge n credits: false when the bucket cannot pay (nothing is taken)
local function charge(owner, n)
    local b = bucket(owner)
    if b.tokens < n then return false end
    b.tokens = b.tokens - n
    local c = counters(owner)
    c.credits = c.credits + n
    return true
end
M.charge = charge
function M.credits(owner) return bucket(owner).tokens end

-- ------------------------------------------------------------------------------------------ index persistence
local function owner_rec(owner)
    local o = ST.owners[owner]
    if not o then o = {lib = {}}; ST.owners[owner] = o end
    return o
end

function M.load()
    ST.loaded = true
    pcall(file.mkdirs, ROOT .. "kv")
    pcall(file.mkdirs, ROOT .. "cas")
    local p = ROOT .. "index.json"
    if not file.exists(p) then return false end
    local ok, d = pcall(function() return json.parse(file.read(p)) end)
    if not ok or type(d) ~= "table" then log("index unreadable: %s", tostring(d)); return false end
    for a, o in pairs(d.owners or {}) do
        local r = owner_rec(a)
        for sha, x in pairs(o.lib or {}) do r.lib[sha] = {name = x.name or "", t = x.t or 0} end
    end
    for sha, b in pairs(d.blobs or {}) do
        ST.blobs[sha] = {kind = b.kind, size = b.size, t = b.t or 0, unref = b.unref and now_ms() or nil}
    end
    for k, e in pairs(d.ents or {}) do
        local slots = {}
        for s, sha in pairs(e.slots or {}) do slots[s] = sha end
        ST.ents[tonumber(k)] = {owner = e.owner or "_world", rev = e.rev or 1, slots = slots}
    end
    for a, sl in pairs(d.snaps or {}) do                  -- UX B2: snapshot libraries (blobs stay in their files)
        local lib = {next_id = tonumber(sl.next_id) or 1, items = {}}
        for k, r in pairs(sl.items or {}) do
            local id = tonumber(k)
            if id and type(r) == "table" then
                lib.items[id] = {name = tostring(r.name or ""), size = r.size or 0, tick = r.tick or 0, ms = r.ms or 0,
                                 ver = r.ver or 1, spawned = r.spawned or 0, status = r.status or "stop", model = r.model,
                                 texture = r.texture, code_fnv = r.code_fnv or 0, src_eid = r.src_eid or 0,
                                 src_name = r.src_name or "", src_owner = r.src_owner or "", assets = r.assets or {}}
            end
        end
        ST.snaps[a] = lib
    end
    log("index loaded: %d owners, %d files, %d entities", table.count_pairs(ST.owners), table.count_pairs(ST.blobs),
        table.count_pairs(ST.ents))
    return true
end

local function write_kv(eid)
    local k = ST.kv[eid]
    if not k then return end
    local p = ROOT .. "kv/" .. eid .. ".json"
    if next(k.data) == nil then
        if file.exists(p) then pcall(file.remove, p) end
    else
        local ok, err = pcall(file.write, p, json.tostring(k.data))
        if not ok then log("kv write %d failed: %s", eid, tostring(err)) end
    end
    k.dirty = false
end

function M.flush(force)
    if not ST.loaded then return end
    for eid in pairs(ST.kv_dirty) do write_kv(eid) end
    ST.kv_dirty = {}
    if not ST.dirty and not force then return end
    local owners, blobs, ents = {}, {}, {}
    for a, o in pairs(ST.owners) do
        if next(o.lib) then owners[a] = {lib = o.lib} end
    end
    for sha, b in pairs(ST.blobs) do blobs[sha] = {kind = b.kind, size = b.size, t = b.t, unref = b.unref and 1 or nil} end
    for eid, e in pairs(ST.ents) do
        if next(e.slots) then ents[tostring(eid)] = {owner = e.owner, rev = e.rev, slots = e.slots} end
    end
    local snaps = {}                                       -- UX B2: libraries without the blobs
    for a, sl in pairs(ST.snaps) do
        local items = {}
        for id, r in pairs(sl.items) do
            local c = {}
            for k, v in pairs(r) do if k ~= "blob" then c[k] = v end end
            items[tostring(id)] = c
        end
        if next(items) then snaps[a] = {next_id = sl.next_id, items = items} end
    end
    local ok, err = pcall(file.write, ROOT .. "index.json", json.tostring({v = 1, owners = owners, blobs = blobs,
                                                                           ents = ents, snaps = snaps}))
    if not ok then log("index write failed: %s", tostring(err)) end
    ST.dirty = false
    ST.written_tick = S and S.tick or 0
end

-- ------------------------------------------------------------------------------------------ KV
-- bytes of one entry = #key + #JSON(value) (the same measure as A3's mobapi memory and its prelude quota)
local function json_ok(v, depth)
    local t = type(v)
    if t == "string" or t == "boolean" then return true end
    if t == "number" then return v == v and v ~= math.huge and v ~= -math.huge end
    if t == "table" then
        if depth >= 4 then return false end
        for k, x in pairs(v) do
            local tk = type(k)
            if (tk ~= "string" and tk ~= "number") or not json_ok(x, depth + 1) then return false end
        end
        return true
    end
    return false
end
local function kv_size(k, v)
    if type(v) == "string" then return #k + #v + 2 end
    local ok, s = pcall(json.tostring, v)
    return #k + (ok and #s or 0)
end

local function kv_of(eid)
    local k = ST.kv[eid]
    if k then return k end
    k = {data = {}, used = 0, n = 0, dirty = false}
    local p = ROOT .. "kv/" .. eid .. ".json"
    if file.exists(p) then
        local ok, d = pcall(function() return json.parse(file.read(p)) end)
        if ok and type(d) == "table" then
            for key, v in pairs(d) do
                if type(key) == "string" and json_ok(v, 0) then
                    k.data[key] = v
                    k.used = k.used + kv_size(key, v)
                    k.n = k.n + 1
                end
            end
        end
    end
    ST.kv[eid] = k
    return k
end

function M.kv_get(eid, key)
    if type(key) ~= "string" then return nil end
    return kv_of(eid).data[key]
end

function M.kv_all(eid)
    local out = {}
    for k, v in pairs(kv_of(eid).data) do out[k] = v end
    return out
end

function M.kv_keys(eid)
    local l = {}
    for k in pairs(kv_of(eid).data) do l[#l + 1] = k end
    table.sort(l)
    return l
end

function M.kv_usage(eid)
    local k = kv_of(eid)
    return k.used, T.kv_quota, k.n, T.kv_keys
end

local function valid_key(key)
    return type(key) == "string" and #key >= 1 and #key <= T.kv_key_max and not key:find("[%z\1-\31\127]")
end

-- value nil = delete (free, never refused by quota/tariff). Charged to the entity's owner account.
function M.kv_set(eid, key, value)
    local e = S.ents[eid]
    if not e or e.kind ~= 3 then return refuse(nil, C.no_entity) end
    local owner = acct_of(e)
    if not valid_key(key) then return refuse(owner, C.bad_arg) end
    if value ~= nil and not json_ok(value, 0) then return refuse(owner, C.bad_arg) end
    if value ~= nil and kv_size(key, value) - #key > T.kv_value_max then return refuse(owner, C.too_large) end
    local k = kv_of(eid)
    local old = k.data[key]
    if value == nil then
        if old == nil then return C.ok end
        k.data[key] = nil
        k.used, k.n = k.used - kv_size(key, old), k.n - 1
        k.dirty, ST.kv_dirty[eid] = true, true
        return C.ok
    end
    local used = k.used - (old ~= nil and kv_size(key, old) or 0) + kv_size(key, value)
    if used > T.kv_quota or (old == nil and k.n + 1 > T.kv_keys) then return refuse(owner, C.kv_quota) end
    local bytes = kv_size(key, value)
    if not charge(owner, T.price_kv_base + floor(bytes * T.price_kv_per_kb / 1024)) then return refuse(owner, C.tariff) end
    k.data[key] = value
    k.used = used
    if old == nil then k.n = k.n + 1 end
    k.dirty, ST.kv_dirty[eid] = true, true
    local c = counters(owner)
    c.writes, c.kv_writes, c.bytes = c.writes + 1, c.kv_writes + 1, c.bytes + bytes
    ST.stats.kv_writes = ST.stats.kv_writes + 1
    return C.ok
end

-- replace the whole KV of an entity (restore / fork; quota checked, not charged here)
local function kv_replace(eid, data)
    local k = {data = {}, used = 0, n = 0, dirty = true}
    for key, v in pairs(data or {}) do
        if valid_key(key) and json_ok(v, 0) then
            k.data[key] = v
            k.used = k.used + kv_size(key, v)
            k.n = k.n + 1
        end
    end
    if k.used > T.kv_quota or k.n > T.kv_keys then return C.kv_quota end
    ST.kv[eid] = k
    ST.kv_dirty[eid] = true
    return C.ok
end

-- ------------------------------------------------------------------------------------------ assets
local function check_format(kind, s)
    if kind == "png" then return s:sub(1, 8) == "\137PNG\r\n\26\n" end
    if kind == "ogg" then return s:sub(1, 4) == "OggS" end
    if kind == "wav" then return s:sub(1, 4) == "RIFF" and s:sub(9, 12) == "WAVE" end
    if kind == "vcm" or kind == "vca" or kind == "lua" then return not s:find("%z") end
    return false
end
M.check_format = check_format

-- distinct files of an owner: library + slots of the owner's entities -> set {sha -> true}, bytes
local function owner_set(owner)
    local set, bytes, n = {}, 0, 0
    local o = ST.owners[owner]
    if o then
        for sha in pairs(o.lib) do
            if not set[sha] then
                set[sha] = true
                n = n + 1
                bytes = bytes + ((ST.blobs[sha] or {}).size or 0)
            end
        end
    end
    for _, er in pairs(ST.ents) do
        if er.owner == owner then
            for _, sha in pairs(er.slots) do
                if not set[sha] then
                    set[sha] = true
                    n = n + 1
                    bytes = bytes + ((ST.blobs[sha] or {}).size or 0)
                end
            end
        end
    end
    return set, bytes, n
end
M.owner_set = owner_set

function M.quota(owner)
    local _, used, n = owner_set(owner)
    return {used = used, quota = T.owner_quota, count = n, max_count = T.owner_assets, credits = bucket(owner).tokens,
            credits_max = T.credits_burst}
end

-- would adding sha (size) to the owner exceed the quota?
local function fits(owner, sha, size)
    local set, used, n = owner_set(owner)
    if set[sha] then return true end
    return used + size <= T.owner_quota and n + 1 <= T.owner_assets
end

-- the file into the CAS (no owner bookkeeping): -> sha, new (bool)
local function cas_write(kind, s)
    local sha = sha_of(s)
    local b = ST.blobs[sha]
    if b and file.exists(cas_path(sha)) then
        b.unref = nil
        return sha, false
    end
    pcall(file.mkdirs, ROOT .. "cas/" .. sha:sub(1, 2))
    local ok, err = pcall(file.write_bytes, cas_path(sha), Bytearray(s))
    if not ok then return nil, false, err end
    ST.blobs[sha] = {kind = kind, size = #s, t = S and S.tick or 0}
    ST.dirty = true
    return sha, true
end

-- meta: {name = "", eid = <entity: put also attaches slot>, slot = "", lib = true|false (default true: into the
-- owner's library; canvas frames go only to the slot)}
function M.put(owner, kind, bytes, meta)
    meta = meta or {}
    owner = owner or "_world"
    if not KINDS[kind] then return nil, refuse(owner, C.bad_kind) end
    local s = bstr(bytes)
    if #s == 0 then return nil, refuse(owner, C.bad_arg) end
    if #s > min(T.asset_max, MAX_SIZE[kind]) then return nil, refuse(owner, C.too_large) end
    if not check_format(kind, s) then return nil, refuse(owner, C.bad_kind) end
    local sha = sha_of(s)
    if not fits(owner, sha, #s) then return nil, refuse(owner, C.asset_quota) end
    local exists = ST.blobs[sha] ~= nil and file.exists(cas_path(sha))
    local price = T.price_put_base + (exists and 0 or ceil(#s * T.price_put_per_kb / 1024))
    if not charge(owner, price) then return nil, refuse(owner, C.tariff) end
    local sha2, new, err = cas_write(kind, s)
    if not sha2 then log("cas write failed: %s", tostring(err)); return nil, refuse(owner, C.bad_arg) end
    local c = counters(owner)
    c.writes, c.puts = c.writes + 1, c.puts + 1
    if new then c.bytes = c.bytes + #s; ST.stats.puts = ST.stats.puts + 1
    else c.dedup = c.dedup + 1; ST.stats.dedup = ST.stats.dedup + 1 end
    if meta.lib ~= false then
        owner_rec(owner).lib[sha] = {name = tostring(meta.name or ""):sub(1, 32), t = S and S.tick or 0}
        ST.dirty = true
    end
    if meta.eid and meta.eid ~= 0 and meta.slot and meta.slot ~= "" then
        local code = M.attach(meta.eid, meta.slot, sha)
        if code ~= C.ok then return sha, code, M.REASON[code] end
    end
    return sha, C.ok
end

function M.get(sha)
    if not is_sha(sha) or not file.exists(cas_path(sha)) then return nil end
    local ok, b = pcall(file.read_bytes, cas_path(sha))
    if not ok then return nil end
    return bstr(b)
end

function M.info(sha)
    local b = ST.blobs[sha]
    if not b then return nil end
    return {kind = b.kind, size = b.size, t = b.t}
end

function M.has(sha, owner)
    if not ST.blobs[sha] then return false end
    if owner == nil then return true end
    local set = owner_set(owner)
    return set[sha] == true
end

function M.list(owner)
    local set = owner_set(owner)
    local o = ST.owners[owner]
    local refs = {}
    for _, er in pairs(ST.ents) do
        if er.owner == owner then for _, sha in pairs(er.slots) do refs[sha] = (refs[sha] or 0) + 1 end end
    end
    local out = {}
    for sha in pairs(set) do
        local b = ST.blobs[sha] or {}
        out[#out + 1] = {sha = sha, kind = b.kind or "?", size = b.size or 0,
                         name = o and o.lib[sha] and o.lib[sha].name or "", refs = refs[sha] or 0}
    end
    table.sort(out, function(a, b) return a.sha < b.sha end)
    return out
end

function M.release(owner, sha)
    local o = ST.owners[owner]
    if not o or not o.lib[sha] then return refuse(owner, C.no_asset) end
    o.lib[sha] = nil
    ST.dirty = true
    return C.ok
end

function M.share(sha, from, to)
    if not is_sha(sha) or not ST.blobs[sha] then return refuse(from, C.no_asset) end
    if type(to) ~= "string" or to == "" or #to > 64 then return refuse(from, C.bad_arg) end
    if not M.has(sha, from) then return refuse(from, C.forbidden) end
    local b = ST.blobs[sha]
    if not fits(to, sha, b.size) then return refuse(from, C.asset_quota) end
    if not charge(from, T.price_share) then return refuse(from, C.tariff) end
    owner_rec(to).lib[sha] = {name = (ST.owners[from] and ST.owners[from].lib[sha] or {}).name or "", t = S.tick,
                              from = from}
    ST.dirty = true
    ST.stats.shares = ST.stats.shares + 1
    return C.ok
end

local function ent_rec(eid, create)
    local er = ST.ents[eid]
    if not er and create then
        er = {owner = acct_of(S.ents[eid]), rev = 0, slots = {}}
        ST.ents[eid] = er
    end
    return er
end

local function valid_slot(slot)
    return type(slot) == "string" and #slot >= 1 and #slot <= 32 and slot:match("^[%w_%$%*:%.%-]+$") ~= nil
end
M.valid_slot = valid_slot

-- by = account asking (owner of the sha's library entry needed), nil = the world / the entity's own script
function M.attach(eid, slot, sha, by)
    local e = S.ents[eid]
    if not e or e.kind ~= 3 then return refuse(by, C.no_entity) end
    local owner = acct_of(e)
    if not valid_slot(slot) then return refuse(owner, C.bad_arg) end
    if not is_sha(sha) or not ST.blobs[sha] then return refuse(owner, C.no_asset) end
    if by and not M.has(sha, by) then return refuse(by, C.forbidden) end
    if not fits(owner, sha, ST.blobs[sha].size) then return refuse(owner, C.asset_quota) end
    local er = ent_rec(eid, true)
    er.owner = owner
    if er.slots[slot] == sha then return C.ok end
    if by and not charge(by, T.price_attach) then return refuse(by, C.tariff) end
    er.slots[slot] = sha
    er.rev = er.rev + 1
    ST.blobs[sha].unref = nil
    ST.dirty = true
    return C.ok
end

function M.detach(eid, slot)
    local er = ST.ents[eid]
    if not er or not er.slots[slot] then return C.no_asset end
    er.slots[slot] = nil
    er.rev = er.rev + 1
    ST.dirty = true
    return C.ok
end

function M.entity_assets(eid)
    local out = {}
    local er = ST.ents[eid]
    if er then for s, sha in pairs(er.slots) do out[s] = sha end end
    return out
end

function M.entity_rev(eid)
    local er = ST.ents[eid]
    return er and er.rev or 0
end

-- the entity was removed from the world (delete / kill): KV and slots go (files: GC after the grace period)
function M.on_entity_removed(eid)
    if ST.ents[eid] then ST.ents[eid] = nil; ST.dirty = true end
    if ST.kv[eid] or file.exists(ROOT .. "kv/" .. eid .. ".json") then
        ST.kv[eid] = {data = {}, used = 0, n = 0, dirty = true}
        ST.kv_dirty[eid] = true
    end
end

-- the owner account of an entity changed (A1 transfer): slots follow the entity
function M.on_owner_changed(eid)
    local er = ST.ents[eid]
    if er then er.owner = acct_of(S.ents[eid]); ST.dirty = true end
end

-- ------------------------------------------------------------------------------------------ canvas (procedural texture)
-- rgba: Bytearray or string of w*h*4 bytes, row 0 = top. slot: "tex:*" (default) | "tex:$<i>" | free slot name.
function M.canvas_commit(e, slot, w, h, rgba)
    if not e or e.kind ~= 3 then return refuse(nil, C.no_entity) end
    local owner = acct_of(e)
    slot = (slot == nil or slot == "") and "tex:*" or tostring(slot)
    if not slot:find(":") then slot = "tex:" .. slot end
    if not valid_slot(slot) then return refuse(owner, C.bad_arg) end
    w, h = tonumber(w) or 0, tonumber(h) or 0
    if w < 1 or h < 1 or w ~= floor(w) or h ~= floor(h) then return refuse(owner, C.bad_arg) end
    if w > T.canvas_max or h > T.canvas_max then return refuse(owner, C.too_large) end
    if rgba == nil or #rgba ~= w * h * 4 then return refuse(owner, C.bad_arg) end
    if (e.canvas_next or 0) > S.tick then return refuse(owner, C.rate) end
    if not charge(owner, T.price_canvas_base + ceil(w * h * T.price_canvas_per_kpx / 1024)) then
        return refuse(owner, C.tariff)
    end
    e.canvas_next = S.tick + T.canvas_min_ticks
    local cv = Canvas({w, h})
    cv:set_data(type(rgba) == "string" and Bytearray(rgba) or rgba)
    local png = cv:encode("png")
    local sha, code, reason = M.put(owner, "png", png, {name = "canvas", eid = e.eid, slot = slot, lib = false})
    if not sha or code ~= C.ok then return code, reason end
    local c = counters(owner)
    c.canvas = c.canvas + 1
    ST.stats.canvas = ST.stats.canvas + 1
    e.canvas_px = (e.canvas_px or 0) + w * h
    return C.ok, nil, sha
end

-- ------------------------------------------------------------------------------------------ transfer
-- copy-on-fork: KV copied (independent from then on), asset slots shared (same files in the CAS, quota of `owner`)
function M.fork(src, dst, owner)
    local se, de = S.ents[src], S.ents[dst]
    if not se or not de then return refuse(owner, C.no_entity) end
    owner = owner or acct_of(de)
    local code = kv_replace(dst, M.kv_all(src))
    if code ~= C.ok then return refuse(owner, code) end
    local er = ST.ents[src]
    if er then
        for slot, sha in pairs(er.slots) do
            local c2 = M.attach(dst, slot, sha)
            if c2 ~= C.ok then return c2, M.REASON[c2] end
        end
    end
    ST.stats.forks = ST.stats.forks + 1
    return C.ok
end

-- other modules add their own entity state to snapshots: M.snapshot_hooks[name] = {save = fn(e) -> table|nil,
-- load = fn(e, t)} (A1 perms, A3 appearance, ...). Kept as opaque JSON in the snapshot.
M.snapshot_hooks = {}

local ENT_FIELDS = {"def", "name", "kind", "code", "status", "error", "owner_acct", "owner_name", "model", "texture",
                    "script"}

-- -> blob (JSON text), bytes | nil, code, reason. The snapshot pins the entity's files into the owner's library (they
-- survive the entity; the Spammer keeps the blob, the files stay in the CAS while the library holds them).
function M.snapshot(eid, opts)
    opts = opts or {}
    local e = S.ents[eid]
    if not e or e.kind ~= 3 then return nil, refuse(nil, C.no_entity) end
    local owner = acct_of(e)
    if opts.charge ~= false and not charge(owner, T.price_snapshot) then return nil, refuse(owner, C.tariff) end
    local ent = {}
    for _, k in ipairs(ENT_FIELDS) do ent[k] = e[k] end
    ent.rot = {e.rot.x, e.rot.y, e.rot.z}
    ent.pos = {e.pos.x, e.pos.y, e.pos.z}
    local assets = {}
    for slot, sha in pairs(M.entity_assets(eid)) do
        local b = ST.blobs[sha] or {}
        assets[slot] = {sha = sha, kind = b.kind, size = b.size}
        if opts.pin ~= false then
            local lib = owner_rec(owner).lib
            if not lib[sha] then lib[sha] = {name = "snapshot", t = S.tick}; ST.dirty = true end
        end
    end
    local ext = {}
    for name, h in pairs(M.snapshot_hooks) do
        local ok, t = pcall(h.save, e)
        if ok and t ~= nil then ext[name] = t end
    end
    local snap = {v = 1, kind = "olife.entity", src_eid = eid, tick = S.tick, entity = ent, kv = M.kv_all(eid),
                  assets = assets, ext = ext}
    local blob = json.tostring(snap)
    ST.stats.snapshots = ST.stats.snapshots + 1
    return blob, #blob
end

-- blob -> a new bench of opts.owner (default: the snapshot's owner) at opts.pos (default: next to the source
-- position). Files must still be in the CAS (47 otherwise); quota and credits of the new owner.
function M.restore(blob, opts)
    opts = opts or {}
    local ok, snap = pcall(json.parse, blob)
    if not ok or type(snap) ~= "table" or snap.kind ~= "olife.entity" or type(snap.entity) ~= "table" then
        return nil, refuse(opts.owner, C.bad_arg)
    end
    local ent = snap.entity
    local owner = opts.owner or ((ent.owner_acct and ent.owner_acct ~= "") and ent.owner_acct or "_world")
    local need, add, n = 0, {}, 0
    for slot, a in pairs(snap.assets or {}) do
        if not is_sha(a.sha) or not ST.blobs[a.sha] or not file.exists(cas_path(a.sha)) then
            return nil, refuse(owner, C.no_asset)
        end
        if not add[a.sha] then add[a.sha] = true; need = need + ST.blobs[a.sha].size; n = n + 1 end
    end
    local set, used, cnt = owner_set(owner)
    for sha in pairs(add) do if set[sha] then need = need - ST.blobs[sha].size; n = n - 1 end end
    if used + need > T.owner_quota or cnt + n > T.owner_assets then return nil, refuse(owner, C.asset_quota) end
    if opts.charge ~= false and not charge(owner, T.price_restore) then return nil, refuse(owner, C.tariff) end
    local ED = require "olife_world:editor"
    local l = ED.spawn_bench(owner ~= "_world" and owner or "", opts.name or ent.name, 1,
                             ent.code or ED.DEFAULT_CODE)
    local e = S.ents[l[1]]
    if not e then return nil, refuse(owner, C.no_entity) end
    e.def = ent.def or e.def
    e.model, e.texture = ent.model, ent.texture
    if e.model or e.texture then e.look_ver = (e.look_ver or 0) + 1 end
    if ent.owner_name and owner == ent.owner_acct then e.owner_name = ent.owner_name end
    local p = opts.pos or (ent.pos and {x = ent.pos[1] + 1.5, y = ent.pos[2], z = ent.pos[3]})
    if p then e.pos.x, e.pos.y, e.pos.z = p.x or p[1], p.y or p[2], p.z or p[3] end
    if ent.rot then e.rot.x, e.rot.y, e.rot.z = ent.rot[1], ent.rot[2], ent.rot[3] end
    local code = kv_replace(e.eid, snap.kv or {})
    if code ~= C.ok then log("restore eid=%d: kv refused (%d)", e.eid, code) end
    for slot, a in pairs(snap.assets or {}) do M.attach(e.eid, slot, a.sha) end
    for name, t in pairs(snap.ext or {}) do
        local h = M.snapshot_hooks[name]
        if h and h.load then
            local okh, err = pcall(h.load, e, t)
            if not okh then log("restore hook %s: %s", name, tostring(err)) end
        end
    end
    ED.ST.dirty = true
    if (opts.run == nil and ent.status == "run") or opts.run == true then
        e.status, e.error = "run", nil
        local sb = require "olife_world:sandbox"
        if sb.connected() then sb.load_entity(e) end
    end
    ST.stats.restores = ST.stats.restores + 1
    return e.eid, C.ok
end

-- ------------------------------------------------------------------------------------------ UX B2: snapshot library
-- The Spammer keeps M.snapshot blobs per owner (the capturer's account): world:olife_store/snaps/<owner>/<id>.json,
-- index.json `snaps` holds the metadata. The files a snapshot refers to are pinned into the owner's library (they stay
-- in the CAS while the snapshot exists); delete releases what no other snapshot / slot of the owner uses.
local function snap_lib(owner)
    local sl = ST.snaps[owner]
    if not sl then sl = {next_id = 1, items = {}}; ST.snaps[owner] = sl end
    return sl
end
local function snap_path(owner, id) return ROOT .. "snaps/" .. owner .. "/" .. id .. ".json" end
local function snap_usage(owner)
    local sl = ST.snaps[owner]
    local n, bytes = 0, 0
    if sl then for _, r in pairs(sl.items) do n = n + 1; bytes = bytes + (r.size or 0) end end
    return n, bytes
end

function M.snap_quota(owner)
    local n, bytes = snap_usage(owner)
    return {count = n, max_count = T.snap_max, used = bytes, quota = T.snap_quota}
end

-- parse a snapshot blob -> table | nil
local function snap_parse(blob)
    local ok, snap = pcall(json.parse, blob)
    if not ok or type(snap) ~= "table" or snap.kind ~= "olife.entity" or type(snap.entity) ~= "table" then return nil end
    return snap
end
M.snap_parse = snap_parse

function M.snap_put(owner, blob, meta)
    meta = meta or {}
    if type(owner) ~= "string" or owner == "" or type(blob) ~= "string" then return nil, refuse(owner, C.bad_arg) end
    local snap = snap_parse(blob)
    if not snap then return nil, refuse(owner, C.bad_arg) end
    local n, bytes = snap_usage(owner)
    if n + 1 > T.snap_max or bytes + #blob > T.snap_quota then return nil, refuse(owner, C.asset_quota) end
    local sl = snap_lib(owner)
    local id = sl.next_id
    pcall(file.mkdirs, ROOT .. "snaps/" .. owner)
    local okw, err = pcall(file.write, snap_path(owner, id), blob)
    if not okw then log("snapshot write failed: %s", tostring(err)); return nil, refuse(owner, C.bad_arg) end
    sl.next_id = id + 1
    local assets, lib = {}, owner_rec(owner).lib
    for _, a in pairs(snap.assets or {}) do
        if is_sha(a.sha) and ST.blobs[a.sha] then
            assets[#assets + 1] = a.sha
            if not lib[a.sha] then lib[a.sha] = {name = "snapshot", t = S and S.tick or 0} end
            ST.blobs[a.sha].unref = nil
        end
    end
    local ent = snap.entity
    local rec = {name = tostring(meta.name or ent.name or ("snap" .. id)):sub(1, 32), size = #blob,
                 tick = S and S.tick or 0, ms = now_ms_wall(), ver = 1, spawned = 0,
                 status = ent.status == "run" and "run" or "stop", model = ent.model, texture = ent.texture,
                 code_fnv = meta.code_fnv or 0, src_eid = meta.src_eid or snap.src_eid or 0,
                 src_name = tostring(meta.src_name or ent.name or ""):sub(1, 32),
                 src_owner = tostring(meta.src_owner or ent.owner_acct or ""):sub(1, 64), assets = assets, blob = blob}
    sl.items[id] = rec
    ST.dirty = true
    ST.stats.snap_puts = (ST.stats.snap_puts or 0) + 1
    return id, C.ok
end

function M.snap_get(owner, id)
    local sl = ST.snaps[owner]
    local r = sl and sl.items[id]
    if not r then return nil end
    if not r.blob then
        local ok, b = pcall(file.read, snap_path(owner, id))
        if ok and type(b) == "string" then r.blob = b end
    end
    return r
end

function M.snap_list(owner)
    local out = {}
    local sl = ST.snaps[owner]
    if sl then
        for id, r in pairs(sl.items) do
            local c = {id = id}
            for k, v in pairs(r) do if k ~= "blob" then c[k] = v end end
            out[#out + 1] = c
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.snap_rename(owner, id, name)
    local sl = ST.snaps[owner]
    local r = sl and sl.items[id]
    if not r then return C.no_asset end
    if type(name) ~= "string" or name == "" or #name > 32 then return C.bad_arg end
    r.name, r.ver = name, (r.ver or 1) + 1
    ST.dirty = true
    return C.ok
end

function M.snap_bump(owner, id)
    local sl = ST.snaps[owner]
    local r = sl and sl.items[id]
    if not r then return 0 end
    r.spawned = (r.spawned or 0) + 1
    ST.dirty = true
    return r.spawned
end

function M.snap_delete(owner, id)
    local sl = ST.snaps[owner]
    local r = sl and sl.items[id]
    if not r then return C.no_asset end
    sl.items[id] = nil
    pcall(file.remove, snap_path(owner, id))
    -- unpin: files pinned by snapshots ("snapshot" entries) that no other snapshot / own slot still needs
    local still = {}
    for _, o in pairs(sl.items) do for _, sha in ipairs(o.assets or {}) do still[sha] = true end end
    for _, er in pairs(ST.ents) do
        if er.owner == owner then for _, sha in pairs(er.slots) do still[sha] = true end end
    end
    local lib = owner_rec(owner).lib
    for _, sha in ipairs(r.assets or {}) do
        if not still[sha] and lib[sha] and lib[sha].name == "snapshot" then lib[sha] = nil end
    end
    ST.dirty = true
    ST.stats.snap_deletes = (ST.stats.snap_deletes or 0) + 1
    return C.ok
end

-- could M.restore(blob, {owner}) succeed now? (files in the CAS, the owner's asset quota, restore credits)
function M.snap_can_restore(owner, blob)
    local snap = snap_parse(blob)
    if not snap then return C.bad_arg, M.REASON[C.bad_arg] end
    local need, add, n = 0, {}, 0
    for _, a in pairs(snap.assets or {}) do
        if not is_sha(a.sha) or not ST.blobs[a.sha] or not file.exists(cas_path(a.sha)) then return C.no_asset, M.REASON[C.no_asset] end
        if not add[a.sha] then add[a.sha] = true; need = need + ST.blobs[a.sha].size; n = n + 1 end
    end
    local set, used, cnt = owner_set(owner)
    for sha in pairs(add) do if set[sha] then need = need - ST.blobs[sha].size; n = n - 1 end end
    if used + need > T.owner_quota or cnt + n > T.owner_assets then return C.asset_quota, M.REASON[C.asset_quota] end
    if bucket(owner).tokens < T.price_restore then return C.tariff, M.REASON[C.tariff] end
    return C.ok
end

-- ------------------------------------------------------------------------------------------ GC
-- unreferenced = in no library, no entity slot. Kept `gc_grace_s` (clients may still fetch the last frames, a fork
-- may come back), and the pool of unreferenced files is capped at `gc_pool` bytes (oldest first).
function M.gc(grace_s)
    grace_s = grace_s or T.gc_grace_s
    local refd = {}
    for _, o in pairs(ST.owners) do for sha in pairs(o.lib) do refd[sha] = true end end
    for _, er in pairs(ST.ents) do for _, sha in pairs(er.slots) do refd[sha] = true end end
    for _, sl in pairs(ST.snaps) do                       -- UX B2: files of stored snapshots
        for _, r in pairs(sl.items) do for _, sha in ipairs(r.assets or {}) do refd[sha] = true end end
    end
    local t = now_ms()
    local pool, cand = 0, {}
    for sha, b in pairs(ST.blobs) do
        if refd[sha] then b.unref = nil
        else
            b.unref = b.unref or t
            pool = pool + (b.size or 0)
            cand[#cand + 1] = {sha = sha, at = b.unref, size = b.size or 0}
        end
    end
    table.sort(cand, function(a, b) return a.at < b.at end)
    local removed, bytes = 0, 0
    for _, c in ipairs(cand) do
        if t - c.at >= grace_s * 1000 or pool > T.gc_pool then
            pcall(file.remove, cas_path(c.sha))
            ST.blobs[c.sha] = nil
            pool = pool - c.size
            removed, bytes = removed + 1, bytes + c.size
        end
    end
    if removed > 0 then
        ST.dirty = true
        ST.stats.gc_removed = ST.stats.gc_removed + removed
        ST.stats.gc_bytes = ST.stats.gc_bytes + bytes
    end
    return removed, bytes, #cand - removed
end

-- ------------------------------------------------------------------------------------------ lifecycle (server.lua)
function M.init(srv)
    server, S = srv, srv.S
    if not ST.loaded then M.load() end
end

-- the registry is loaded: forget slots/KV of entities that no longer exist (deleted while the store was not saved)
function M.after_load()
    for eid in pairs(ST.ents) do
        if not S.ents[eid] then ST.ents[eid] = nil; ST.dirty = true end
    end
end

function M.tick()
    if not ST.loaded then return end
    if S.save_req or S.tick - ST.written_tick >= T.flush_ticks then
        if ST.dirty or next(ST.kv_dirty) then M.flush() end
    end
    if S.tick % 200 == 0 then M.gc() end
end

function M.set_tariff(k, v)
    if T[k] == nil then return false end
    v = tonumber(v)
    if not v or v < 0 then return false end
    T[k] = v
    return true
end

function M.summary()
    local owners = {}
    local all = {}
    for a in pairs(ST.owners) do all[a] = true end
    for _, er in pairs(ST.ents) do all[er.owner] = true end
    for a in pairs(ST.acct) do all[a] = true end
    for a in pairs(all) do
        local _, used, n = owner_set(a)
        local c = counters(a)
        owners[a] = {bytes = used, assets = n, writes = c.writes, written = c.bytes, credits = c.credits,
                     refused = c.refused, canvas = c.canvas, kv_writes = c.kv_writes, dedup = c.dedup}
    end
    local kvb, kvn = 0, 0
    for _, k in pairs(ST.kv) do kvb, kvn = kvb + k.used, kvn + 1 end
    local cas = 0
    for _, b in pairs(ST.blobs) do cas = cas + (b.size or 0) end
    return {owners = owners, files = table.count_pairs(ST.blobs), cas_bytes = cas, kv_entities = kvn, kv_bytes = kvb,
            stats = ST.stats}
end

function M.status()
    local s = ST.stats
    local r = {}
    for c, n in pairs(s.refused) do r[#r + 1] = c .. ":" .. n end
    table.sort(r)
    local cas = 0
    for _, b in pairs(ST.blobs) do cas = cas + (b.size or 0) end
    local sn, sb = 0, 0                                    -- UX B2: stored snapshots (all owners)
    for _, sl in pairs(ST.snaps) do for _, x in pairs(sl.items) do sn = sn + 1; sb = sb + (x.size or 0) end end
    return string.format("store(files=%d,cas_bytes=%d,puts=%d,dedup=%d,kv_writes=%d,canvas=%d,snapshots=%d," ..
        "restores=%d,forks=%d,shares=%d,gc_removed=%d,snap_lib=%d/%dB,refused={%s})", table.count_pairs(ST.blobs), cas, s.puts, s.dedup,
        s.kv_writes, s.canvas, s.snapshots, s.restores, s.forks, s.shares, s.gc_removed, sn, sb, table.concat(r, ","))
end

return M
