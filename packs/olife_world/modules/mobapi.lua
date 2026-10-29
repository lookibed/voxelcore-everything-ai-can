-- olife_world:mobapi — UX A3 (03.10, agent olife_a3): the world side of the mob script API (sandbox prelude
-- <olife-src>/sandboxd/lua-wasm/prelude.lua: block.*, self:set_scale/set_texture/set_model/skeleton/play_anim/
-- play_sound/text3d/set_visible/nearby/look_at, memory.*).
-- * Actions arrive in the TickResult (op beyond set_pos/rot/vel, block.set, say/print): validated here (shape,
--   bounds, whitelists or owner assets, reach, rates), permission-checked (A1 rights when the module is there, else
--   the stub below: allow, except `olife.api_deny` for tests), billed by the sandbox price table (api_credits).
-- * Queries (block.get/get_area/raycast/replaceable/find, entity.nearby, skeleton.bones, memory.load) are answered
--   here at once; the answers go with the NEXT TickInput (bin: an `Answers` frame before it; jsonl: ent.answers).
-- * Appearance (scale, visible, model, textures, bones, text line) is entity state: persisted in the registry,
--   replicated as EntityAppearance (s2c 130) to sessions that see the entity, on change and on entering the view;
--   the animation state (EntityAnim 131) is replicated but not persisted; a sound (EntitySound 132) is an event.
-- * memory.* — the mob's KV store: A4's olife_world:store (kv_*: quota, store credits, snapshot/fork) when it is
--   there, else a fallback table in the registry (mem_* below are the only accessors).
local net = require "olife_world:net"
local ED = require "olife_world:editor"        -- registry writes (ED.ST.dirty -> editor.tick saves it)
local MA = require "olife_proto:mobassets"
local LOOKS = require "olife_proto:looks"

local M = {}
local server, sandbox, S
local floor, sqrt, abs, min, max = math.floor, math.sqrt, math.abs, math.min, math.max

local cfg = {
    scale_min = 0.1, scale_max = 4.0,       -- set_scale per axis
    bone_off = 4.0, bone_scale_min = 0.05, bone_scale_max = 4.0, bones_max = 16,
    area_max = 4096,                        -- blocks of get_area / fill_area
    area_reach = 24,                        -- every corner of a read box within this of the entity
    fill_reach = 12,                        -- every corner of a fill box within this of the entity
    fill_per_tick = 32, fill_global = 128,  -- blocks placed per job / for all jobs per world tick
    get_reach = 24, ray_origin = 4, ray_max = 32, find_r = 8, find_max = 64,
    nearby_r = 16, nearby_max = 32,
    queries_per_result = 8,                 -- more queries of one entity in one result -> answered "flood"
    mem_quota = 16384, mem_value = 4096, mem_key = 64,
    sound_every = 4,                        -- ticks between two sounds of one entity (5/s)
    sound_reach = 16,
    anim_speed_min = 0.05, anim_speed_max = 8.0,
    text_max = 128,
}
M.cfg = cfg

local ST = {deny = {}, applied = {}, rejected = {}, queries = {}, answers = 0, answer_bytes = 0, fills = 0,
            fill_blocks = 0, fill_skipped = 0, sounds = 0, sound_msgs = 0, app_msgs = 0, anim_msgs = 0, perm_refused = 0,
            mem_sets = 0}
M.ST = ST
local sounds = {}                           -- sounds of this tick: {eid, sound, volume, pitch, pos, tick}
local answers = {}                          -- eid -> {qid -> value} for the next TickInput
local rights = nil                          -- A1's olife_world:perms when it offers script_allowed(e, action)
local store = nil                           -- A4's olife_world:store (has(sha, owner), kv_*, snapshot_hooks)

local function log(fmt, ...) print("[olife_world] mobapi: " .. string.format(fmt, ...)) end
local finite = function(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

function M.init(srv, sb)
    server, sandbox, S = srv, sb, srv.S
    local ok, R = pcall(require, "olife_world:perms")
    if ok and type(R) == "table" and type(R.script_allowed) == "function" then rights = R end
    local ok2, ST4 = pcall(require, "olife_world:store")
    if ok2 and type(ST4) == "table" and type(ST4.has) == "function" then
        store = ST4
        -- the Spammer's snapshot of an entity carries its appearance (A4's restore puts it on the new bench)
        if type(ST4.snapshot_hooks) == "table" then
            ST4.snapshot_hooks.a3_appearance = {
                save = function(e) local r = {}; M.save_fields(e, r); return r.app end,
                load = function(e, t) M.load_fields(e, {app = t}) end,
            }
        end
    end
    log("ready rights=%s store=%s", rights and "A1" or "stub", store and "A4" or "stub")
end

-- ------------------------------------------------------------------------------------------ permissions / assets
-- action classes: appearance (scale/visible/texture/model/bones/text), anim, sound, blocks, memory, query
local function allowed(e, action)
    -- admin/test switch (olife.api_deny) first, then A1's account settings (perms.script_allowed) when present
    local d = ST.deny[e.owner_acct or ""] or ST.deny["*"]
    if d and (d[action] or d["*"]) then return false end
    if rights then
        local ok, r = pcall(rights.script_allowed, e, action)
        return ok and r ~= false
    end
    return true
end
M.allowed = allowed

-- a name from the lists, "" (reset) where allowed, or an asset of the entity owner's store
local function ref_ok(e, ref, list_ok, empty_ok)
    if type(ref) ~= "string" then return false end
    if ref == "" then return empty_ok end
    local id = MA.asset_id(ref)
    if id then
        if not store then return true end                 -- no store module: accepted (stub)
        local acct = (e.owner_acct and e.owner_acct ~= "") and e.owner_acct or "_world"
        local ok, r = pcall(store.has, id, acct)         -- A4: has(sha, owner) — in the owner's library / slots
        return ok and r == true
    end
    return list_ok(ref)
end

-- ------------------------------------------------------------------------------------------ appearance state
local function app_of(e)
    local a = e.app
    if not a then
        a = {ver = 0, scale = {1, 1, 1}, visible = true, model = "", tex = {}, bones = {}, text = "", color = 0xFFFFFFFF}
        e.app = a
    end
    return a
end

local function app_changed(e)
    local a = app_of(e)
    a.ver = a.ver + 1
    e.app_dirty = true                        -- fields for the sandbox (scale/visible) next TickInput
    ED.ST.dirty = true
end

local function vec3(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v[1] or v.x, v[2] or v.y, v[3] or v.z
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    return x, y, z
end

local function color_u32(c)
    if c == nil then return 0xFFFFFFFF end
    if type(c) == "string" then
        local h = c:match("^#(%x+)$")
        if not h or (#h ~= 6 and #h ~= 8) then return nil end
        if #h == 6 then h = h .. "ff" end
        return tonumber(h, 16)
    end
    if type(c) == "table" then
        local r, g, b, a = c[1] or c.r, c[2] or c.g, c[3] or c.b, c[4] or c.a or 1
        if not (finite(r) and finite(g) and finite(b) and finite(a)) then return nil end
        local q = function(v) return floor(min(1, max(0, v)) * 255 + 0.5) end
        return ((q(r) * 256 + q(g)) * 256 + q(b)) * 256 + q(a)
    end
    return nil
end

local function dist2(e, x, y, z)
    return (x - e.pos.x) ^ 2 + (y - e.pos.y) ^ 2 + (z - e.pos.z) ^ 2
end

-- every corner of the box within r of the entity
local function box_in_reach(e, a, b, r)
    local r2 = r * r
    for _, x in ipairs({a[1], b[1] + 1}) do
        for _, y in ipairs({a[2], b[2] + 1}) do
            for _, z in ipairs({a[3], b[3] + 1}) do
                if dist2(e, x, y, z) > r2 then return false end
            end
        end
    end
    return true
end

local function box_of(v)
    if type(v.from) ~= "table" or type(v.to) ~= "table" then return nil end
    local x0, y0, z0 = vec3(v.from)
    local x1, y1, z1 = vec3(v.to)
    if not (x0 and x1) then return nil end
    x0, y0, z0, x1, y1, z1 = floor(x0), floor(y0), floor(z0), floor(x1), floor(y1), floor(z1)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    if z1 < z0 then z0, z1 = z1, z0 end
    local vol = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
    return {x0, y0, z0}, {x1, y1, z1}, vol
end

local function block_id(name)
    local ok, id = pcall(block.index, tostring(name))
    if ok and type(id) == "number" and id >= 0 then return id end
    return nil
end

local function block_name(id)
    if id == nil or id < 0 then return nil end
    local ok, n = pcall(block.name, id)
    return ok and n or tostring(id)
end

-- ------------------------------------------------------------------------------------------ memory (KV per mob)
-- The store of a mob until A4's store takes it over: e.mem (key -> JSON-able value), e.mem_bytes; in the registry.
local function value_bytes(v)
    local ok, s = pcall(json.tostring, {v = v})     -- wrapped: a bare number/string is not a JSON document here
    if not ok or type(s) ~= "string" then return nil end
    return #s - 6
end

-- UX A4: when olife_world:store is there, the KV lives in it (world:olife_store/kv/<eid>.json: quota, store credits,
-- snapshot/fork/restore); e.mem of older registries is moved into it once
local function a4_kv(e)
    if not store or not store.kv_set then return nil end
    if e.mem and next(e.mem) ~= nil then
        for k, v in pairs(e.mem) do store.kv_set(e.eid, k, v) end
        e.mem, e.mem_bytes = nil, nil
        ED.ST.dirty = true
    end
    return store
end
local A4_REASON = {[42] = "quota", [44] = "tariff", [45] = "value too large", [49] = "bad value", [40] = "no entity"}

function M.mem_all(e)
    local st4 = a4_kv(e)
    if st4 then return st4.kv_all(e.eid) end
    return e.mem or {}
end

function M.mem_info(e)       -- UX A4: {quota, bytes} for memory.load
    local st4 = a4_kv(e)
    if st4 then
        local used, quota = st4.kv_usage(e.eid)
        return quota, used
    end
    return cfg.mem_quota, e.mem_bytes or 0
end

function M.mem_set(e, key, value)
    local st4 = a4_kv(e)
    if st4 then
        local code = st4.kv_set(e.eid, key, value)
        if code == 0 then ST.mem_sets = ST.mem_sets + 1; return nil end
        return A4_REASON[code] or ("store code " .. tostring(code))
    end
    e.mem = e.mem or {}
    local old = e.mem[key]
    local ob = old ~= nil and (#key + (value_bytes(old) or 0)) or 0
    local nb = value ~= nil and (#key + (value_bytes(value) or 0)) or 0
    local total = (e.mem_bytes or 0) - ob + nb
    if total > cfg.mem_quota then return "quota" end
    e.mem[key], e.mem_bytes = value, total
    ST.mem_sets = ST.mem_sets + 1
    ED.ST.dirty = true
    return nil
end

-- ------------------------------------------------------------------------------------------ actions
local A = {}

function A.set_scale(e, a)
    local x, y, z = vec3(a.scale)
    if not x then return "bad vec" end
    for _, v in ipairs({x, y, z}) do
        if v < cfg.scale_min or v > cfg.scale_max then return "bounds" end
    end
    if not allowed(e, "appearance") then return "forbidden" end
    local ap = app_of(e)
    ap.scale = {x, y, z}
    app_changed(e)
end

function A.set_visible(e, a)
    if type(a.visible) ~= "boolean" then return "bad value" end
    if not allowed(e, "appearance") then return "forbidden" end
    app_of(e).visible = a.visible
    app_changed(e)
end

function A.set_texture(e, a)
    local slot = a.slot
    if type(slot) ~= "string" or not MA.SLOTS[slot] then return "bad slot" end
    if not ref_ok(e, a.texture, MA.texture, true) then return "bad texture" end
    if not allowed(e, "appearance") then return "forbidden" end
    local ap = app_of(e)
    if slot == "*" then ap.tex = {} end
    ap.tex[slot] = a.texture ~= "" and a.texture or nil
    app_changed(e)
end

function A.set_model(e, a)
    if not ref_ok(e, a.model, MA.model, true) then return "bad model" end
    if not allowed(e, "appearance") then return "forbidden" end
    app_of(e).model = a.model
    app_changed(e)
end

local function bone_rec(e, name)
    if type(name) ~= "string" or not MA.bone(e.def, name) then return nil, "bad bone" end
    local ap = app_of(e)
    local b = ap.bones[name]
    if not b then
        local n = 0
        for _ in pairs(ap.bones) do n = n + 1 end
        if n >= cfg.bones_max then return nil, "bones" end
        b = {flags = 0, pos = {0, 0, 0}, rot = {0, 0, 0}, scale = {1, 1, 1}, model = ""}
        ap.bones[name] = b
    end
    return b
end

A["bone.set"] = function(e, a)
    if not MA.bone(e.def, a.bone) then return "bad bone" end
    local p, r, s = {0, 0, 0}, {0, 0, 0}, {1, 1, 1}
    if a.pos ~= nil then
        local x, y, z = vec3(a.pos)
        if not x then return "bad vec" end
        if abs(x) > cfg.bone_off or abs(y) > cfg.bone_off or abs(z) > cfg.bone_off then return "bounds" end
        p = {x, y, z}
    end
    if a.rot ~= nil then
        local x, y, z = vec3(a.rot)
        if not x then return "bad vec" end
        r = {x % 360, y % 360, z % 360}
    end
    if a.scale ~= nil then
        local x, y, z = vec3(a.scale)
        if not x then return "bad vec" end
        for _, v in ipairs({x, y, z}) do
            if v < cfg.bone_scale_min or v > cfg.bone_scale_max then return "bounds" end
        end
        s = {x, y, z}
    end
    if not allowed(e, "appearance") then return "forbidden" end
    local b, why = bone_rec(e, a.bone)
    if not b then return why end
    b.pos, b.rot, b.scale = p, r, s
    b.flags = bit.bor(b.flags, 1)
    app_changed(e)
end

A["bone.model"] = function(e, a)
    if not MA.bone(e.def, a.bone) then return "bad bone" end
    if not ref_ok(e, a.model, MA.model, true) then return "bad model" end
    if not allowed(e, "appearance") then return "forbidden" end
    local b, why = bone_rec(e, a.bone)
    if not b then return why end
    b.model = a.model
    b.flags = a.model ~= "" and bit.bor(b.flags, 2) or bit.band(b.flags, 1)
    app_changed(e)
end

A["skeleton.reset"] = function(e, a)
    if a.bone ~= nil and not MA.bone(e.def, a.bone) then return "bad bone" end
    if not allowed(e, "appearance") then return "forbidden" end
    local ap = app_of(e)
    if a.bone then ap.bones[a.bone] = nil else ap.bones = {} end
    app_changed(e)
end

A.text3d = function(e, a)
    local t = a.text
    if type(t) ~= "string" or #t > cfg.text_max or t:find("[%z\1-\31\127]") then return "bad text" end
    local c = color_u32(a.color)
    if not c then return "bad color" end
    if not allowed(e, "appearance") then return "forbidden" end
    local ap = app_of(e)
    ap.text, ap.color = t, c
    app_changed(e)
end

A["anim.play"] = function(e, a, tick)
    if not ref_ok(e, a.name, MA.anim, false) then return "bad anim" end
    local sp = a.speed
    if not finite(sp) or sp < cfg.anim_speed_min or sp > cfg.anim_speed_max then return "bounds" end
    if not allowed(e, "anim") then return "forbidden" end
    local v = (e.anim and e.anim.ver or 0) + 1
    e.anim = {name = a.name, speed = sp, loop = a.loop == true, start = tick, ver = v}
    e.app_dirty = true
end

A["anim.stop"] = function(e, a, tick)
    if not allowed(e, "anim") then return "forbidden" end
    local v = (e.anim and e.anim.ver or 0) + 1
    e.anim = {name = "", speed = 1, loop = false, start = tick, ver = v}
    e.app_dirty = true
end

A["sound.play"] = function(e, a, tick)
    if not ref_ok(e, a.sound, MA.sound, false) then return "bad sound" end
    local vol, pit = a.volume, a.pitch
    if not finite(vol) or vol < 0 or vol > 1 or not finite(pit) or pit < 0.25 or pit > 4 then return "bounds" end
    local px, py, pz = e.pos.x, e.pos.y, e.pos.z
    if a.pos ~= nil then
        px, py, pz = vec3(a.pos)
        if not px then return "bad vec" end
        if dist2(e, px, py, pz) > cfg.sound_reach ^ 2 then return "reach" end
    end
    if (e.next_sound_tick or 0) > tick then return "rate" end
    if not allowed(e, "sound") then return "forbidden" end
    e.next_sound_tick = tick + cfg.sound_every
    sounds[#sounds + 1] = {eid = e.eid, sound = a.sound, volume = vol, pitch = pit, pos = {x = px, y = py, z = pz},
                           tick = S.tick}
    ST.sounds = ST.sounds + 1
end

A["block.fill"] = function(e, a, tick)
    local lo, hi, vol = box_of(a)
    if not lo then return "bad box" end
    if vol > cfg.area_max then return "volume" end
    if not box_in_reach(e, lo, hi, cfg.fill_reach) then return "reach" end
    local id = block_id(a.id)
    if not id then return "bad block" end
    local st = a.state ~= nil and floor(tonumber(a.state) or -1) or 0
    if st < 0 or st > 65535 then return "bad state" end
    if e.fill then return "busy" end
    if not allowed(e, "blocks") then return "forbidden" end
    e.fill = {lo = lo, hi = hi, vol = vol, id = id, st = st, i = 0, placed = 0, skipped = 0, at = tick}
    ST.fills = ST.fills + 1
end

A["memory.set"] = function(e, a)
    local k = a.key
    if type(k) ~= "string" or #k < 1 or #k > cfg.mem_key then return "bad key" end
    local v = a.value
    if a.del then v = nil end
    if v ~= nil then
        local n = value_bytes(v)
        if not n then return "bad value" end
        if n > cfg.mem_value then return "value too large" end
    end
    if not allowed(e, "memory") then return "forbidden" end
    return M.mem_set(e, k, v)
end

M.OPS = A

-- called from olife_world:sandbox apply_action for every op it does not know itself: nil = applied, else reason
function M.apply(e, a, tick)
    local f = A[a.op]
    if not f then return "not allowed" end
    local why = f(e, a, tick)
    if why then
        ST.rejected[why] = (ST.rejected[why] or 0) + 1
        if why == "forbidden" then ST.perm_refused = ST.perm_refused + 1 end
    else
        ST.applied[a.op] = (ST.applied[a.op] or 0) + 1
    end
    return why
end

-- block.set with permission + state (sandbox.lua keeps reach/rate/load checks)
function M.block_set_allowed(e) return allowed(e, "blocks") end

-- ------------------------------------------------------------------------------------------ queries
local Q = {}

Q["block.get"] = function(e, q)
    local x, y, z = vec3(q.pos)
    if not x then return nil, "bad pos" end
    x, y, z = floor(x), floor(y), floor(z)
    if dist2(e, x + 0.5, y + 0.5, z + 0.5) > cfg.get_reach ^ 2 then return nil, "reach" end
    local id = block.get(x, y, z)
    if id == -1 then return nil, "not loaded" end
    return {id = block_name(id), state = block.get_states(x, y, z)}
end

Q["block.get_area"] = function(e, q)
    local lo, hi, vol = box_of(q)
    if not lo then return nil, "bad box" end
    if vol > cfg.area_max then return nil, "volume" end
    if not box_in_reach(e, lo, hi, cfg.area_reach) then return nil, "reach" end
    local pal, idx, d = {}, {}, {}
    local n = 0
    for z = lo[3], hi[3] do
        for y = lo[2], hi[2] do
            for x = lo[1], hi[1] do
                local id = block.get(x, y, z)
                local k = idx[id]
                if not k then
                    pal[#pal + 1] = id == -1 and "?" or block_name(id)
                    k = #pal
                    idx[id] = k
                end
                n = n + 1
                d[n] = k
            end
        end
    end
    return {o = lo, s = {hi[1] - lo[1] + 1, hi[2] - lo[2] + 1, hi[3] - lo[3] + 1}, p = pal, d = d}
end

Q["block.raycast"] = function(e, q)
    local ox, oy, oz = vec3(q.origin)
    local dx, dy, dz = vec3(q.dir)
    if not ox or not dx then return nil, "bad vec" end
    if dist2(e, ox, oy, oz) > cfg.ray_origin ^ 2 then return nil, "reach" end
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-9 then return nil, "bad dir" end
    local maxlen = tonumber(q.maxlen) or 16
    if not finite(maxlen) or maxlen <= 0 then return nil, "bad length" end
    maxlen = min(maxlen, cfg.ray_max)
    local ok, r = pcall(block.raycast, {ox, oy, oz}, {dx / len, dy / len, dz / len}, maxlen)
    if not ok then return nil, "raycast failed" end
    if not r then return {miss = true} end
    return {pos = {r.iendpoint[1], r.iendpoint[2], r.iendpoint[3]}, id = block_name(r.block),
            normal = {r.normal[1], r.normal[2], r.normal[3]}, point = {r.endpoint[1], r.endpoint[2], r.endpoint[3]},
            dist = r.length}
end

Q["block.replaceable"] = function(e, q)
    local x, y, z = vec3(q.pos)
    if not x then return nil, "bad pos" end
    x, y, z = floor(x), floor(y), floor(z)
    if dist2(e, x + 0.5, y + 0.5, z + 0.5) > cfg.get_reach ^ 2 then return nil, "reach" end
    if block.get(x, y, z) == -1 then return nil, "not loaded" end
    return block.is_replaceable_at(x, y, z) and true or false
end

Q["block.find"] = function(e, q)
    local id = block_id(q.id)
    if not id then return nil, "bad block" end
    local r = tonumber(q.radius) or 4
    if not finite(r) or r < 0 or r > cfg.find_r then return nil, "radius" end
    local cx, cy, cz = floor(e.pos.x), floor(e.pos.y), floor(e.pos.z)
    local ri = math.ceil(r)
    local out = {}
    for z = cz - ri, cz + ri do
        for y = cy - ri, cy + ri do
            for x = cx - ri, cx + ri do
                if block.get(x, y, z) == id then
                    local d = (x + 0.5 - e.pos.x) ^ 2 + (y + 0.5 - e.pos.y) ^ 2 + (z + 0.5 - e.pos.z) ^ 2
                    if d <= r * r then out[#out + 1] = {x, y, z, d} end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a[4] < b[4] end)
    local res = {}
    for i = 1, min(#out, cfg.find_max) do res[i] = {out[i][1], out[i][2], out[i][3]} end
    return res
end

Q["entity.nearby"] = function(e, q)
    local r = tonumber(q.radius) or 8
    if not finite(r) or r < 0 then return nil, "radius" end
    r = min(r, cfg.nearby_r)
    local l = {}
    for eid, o in pairs(S.ents) do
        if eid ~= e.eid then
            local d = dist2(e, o.pos.x, o.pos.y, o.pos.z)
            if d <= r * r then l[#l + 1] = {o, d} end
        end
    end
    table.sort(l, function(a, b) return a[2] < b[2] end)
    local res = {}
    for i = 1, min(#l, cfg.nearby_max) do
        local o = l[i][1]
        res[i] = {eid = o.eid, kind = o.kind, name = o.name or "", owner = o.owner_acct or "",
                  pos = {o.pos.x, o.pos.y, o.pos.z}, dist = sqrt(l[i][2])}
    end
    return res
end

Q["skeleton.bones"] = function(e, q) return MA.bones(e.def) end

Q["memory.load"] = function(e, q)
    if not allowed(e, "memory") then return nil, "forbidden" end
    local quota, bytes = M.mem_info(e)                  -- UX A4: the store's quota when present
    return {data = M.mem_all(e), quota = quota, bytes = bytes}
end

-- world.raycast of the old API (wave 3a prelude): {op="raycast", origin, dir, maxlen} -> same as block.raycast
Q["raycast"] = function(e, q) return Q["block.raycast"](e, q) end

M.QUERIES = Q

local function answer(eid, qid, v)
    local m = answers[eid]
    if not m then m = {}; answers[eid] = m end
    m[qid] = v
end

-- queries of one entity result (jsonl: tables; bin: JSON strings) -> answers for the next TickInput
function M.queries(e, er)
    local list = er.queries or er.queries_json
    if not list or #list == 0 then return end
    local n = 0
    for _, q in ipairs(list) do
        if type(q) == "string" then
            local ok, t = pcall(json.parse, q)
            q = ok and t or nil
        end
        local qid = type(q) == "table" and tonumber(q.qid)
        if qid then
            n = n + 1
            local op = tostring(q.op)
            ST.queries[op] = (ST.queries[op] or 0) + 1
            local f = Q[op]
            if n > cfg.queries_per_result then
                answer(e.eid, qid, {ok = false, err = "flood"})
            elseif not f then
                answer(e.eid, qid, {ok = false, err = "unknown query"})
            elseif op ~= "skeleton.bones" and op ~= "memory.load" and op ~= "raycast" and not allowed(e, "query") then
                ST.perm_refused = ST.perm_refused + 1
                answer(e.eid, qid, {ok = false, err = "forbidden"})
            else
                local ok, v, err = pcall(f, e, q)
                if not ok then answer(e.eid, qid, {ok = false, err = "error"}); log("query %s eid=%d: %s", op, e.eid, tostring(v))
                elseif v == nil then answer(e.eid, qid, {ok = false, err = err or "refused"})
                else answer(e.eid, qid, {ok = true, v = v}) end
            end
        end
    end
end

-- for send_input: the answers of entity e (removed), {qid -> value} or nil
function M.take_answers(eid)
    local m = answers[eid]
    if m then answers[eid] = nil end
    return m
end

-- fields the sandbox sees as self.fields (scale, visible, model, anim) when they changed since the last input
function M.take_fields(e)
    if not e.app_dirty then return nil end
    e.app_dirty = nil
    local ap = e.app
    return {scale = ap and ap.scale or {1, 1, 1}, visible = not ap or ap.visible ~= false,
            model = ap and ap.model or "", anim = e.anim and e.anim.name or ""}
end

-- the entity was (re)loaded into the sandbox: its memory cache / bone list there is stale, fields must go again
function M.on_load(e)
    e.app_dirty = true
    sandbox.event(e.eid, {type = "__sys", reset_mem = true, reset_bones = true})
end

-- ------------------------------------------------------------------------------------------ tick (phase 3)
function M.tick()
    -- fill jobs: a few blocks per job and tick, a global cap
    local budget = cfg.fill_global
    for _, e in pairs(S.ents) do
        local f = e.fill
        if f and budget > 0 then
            local sx, sy = f.hi[1] - f.lo[1] + 1, f.hi[2] - f.lo[2] + 1
            local n = min(cfg.fill_per_tick, budget, f.vol - f.i)
            for _ = 1, n do
                local i = f.i
                local x = f.lo[1] + i % sx
                local y = f.lo[2] + floor(i / sx) % sy
                local z = f.lo[3] + floor(i / (sx * sy))
                f.i = i + 1
                local cur = block.get(x, y, z)
                if cur == -1 then
                    f.skipped = f.skipped + 1
                elseif cur ~= f.id or block.get_states(x, y, z) ~= f.st then
                    server.apply_block(x, y, z, f.id, f.st, e.eid)
                    f.placed = f.placed + 1
                end
            end
            budget = budget - n
            ST.fill_blocks = ST.fill_blocks + n
            if f.i >= f.vol then
                ST.fill_skipped = ST.fill_skipped + f.skipped
                sandbox.event(e.eid, {type = "fill_done", placed = f.placed, skipped = f.skipped,
                                           ticks = S.tick - f.at})
                e.fill = nil
            end
        end
    end
    -- sounds older than this tick were replicated already
    if #sounds > 0 and sounds[1].tick < S.tick then
        local keep = {}
        for _, s in ipairs(sounds) do if s.tick >= S.tick then keep[#keep + 1] = s end end
        sounds = keep
    end
end

-- ------------------------------------------------------------------------------------------ replication (phase 4)
local function app_msg(e)
    local ap = e.app
    local tex = {}
    for slot, t in pairs(ap.tex) do tex[#tex + 1] = {slot = slot, texture = t} end
    table.sort(tex, function(a, b) return a.slot < b.slot end)
    local bones = {}
    for name, b in pairs(ap.bones) do
        bones[#bones + 1] = {name = name, flags = b.flags, pos = {x = b.pos[1], y = b.pos[2], z = b.pos[3]},
                             rot = {x = b.rot[1], y = b.rot[2], z = b.rot[3]},
                             scale = {x = b.scale[1], y = b.scale[2], z = b.scale[3]}, model = b.model}
    end
    table.sort(bones, function(a, b) return a.name < b.name end)
    return {eid = e.eid, ver = ap.ver, scale = {x = ap.scale[1], y = ap.scale[2], z = ap.scale[3]},
            visible = ap.visible ~= false, model = ap.model or "", textures = tex, bones = bones, text = ap.text or "",
            color = ap.color or 0xFFFFFFFF}
end

local function anim_msg(e)
    local a = e.anim
    local t = (S.tick - a.start) * 0.05 * a.speed
    return {eid = e.eid, ver = a.ver, name = a.name, speed = a.speed, loop = a.loop, t = t}
end

-- per session after its snapshot (server.replicate): appearance / animation of entities in its view, sounds
function M.replicate(sess)
    local view = sess.view
    if not view then return end
    local aseen = sess.app_seen
    if not aseen then aseen = {}; sess.app_seen = aseen end
    local nseen = sess.anim_seen
    if not nseen then nseen = {}; sess.anim_seen = nseen end
    for eid in pairs(view) do
        local e = S.ents[eid]
        if e then
            local ap = e.app
            if ap and ap.ver > 0 and aseen[eid] ~= ap.ver then
                aseen[eid] = ap.ver
                net.send_client(sess.gw, sess.sid, "EntityAppearance", app_msg(e))
                ST.app_msgs = ST.app_msgs + 1
            end
            local an = e.anim
            if an and nseen[eid] ~= an.ver then
                -- a stopped animation is not news for a session that never saw it play
                local news = an.name ~= "" or nseen[eid] ~= nil
                nseen[eid] = an.ver
                if news then
                    net.send_client(sess.gw, sess.sid, "EntityAnim", anim_msg(e))
                    ST.anim_msgs = ST.anim_msgs + 1
                end
            end
        end
    end
    for eid in pairs(aseen) do if not view[eid] then aseen[eid] = nil end end
    for eid in pairs(nseen) do if not view[eid] then nseen[eid] = nil end end
    for _, s in ipairs(sounds) do
        if s.tick == S.tick and view[s.eid] then
            net.send_client(sess.gw, sess.sid, "EntitySound", {eid = s.eid, sound = s.sound, volume = s.volume,
                                                               pitch = s.pitch, pos = s.pos, tick = s.tick})
            ST.sound_msgs = ST.sound_msgs + 1
        end
    end
end

-- ------------------------------------------------------------------------------------------ registry
function M.save_fields(e, rec)
    local ap = e.app
    if ap and ap.ver > 0 then
        local bones = {}
        for name, b in pairs(ap.bones) do
            bones[name] = {b.flags, b.pos, b.rot, b.scale, b.model}
        end
        local tex = {}
        for slot, t in pairs(ap.tex) do tex[slot] = t end
        rec.app = {scale = ap.scale, visible = ap.visible, model = ap.model, tex = tex, bones = bones, text = ap.text,
                   color = ap.color}
    end
    if e.mem and next(e.mem) then rec.mem = e.mem end
end

function M.load_fields(e, r)
    local a = r.app
    if type(a) == "table" then
        local ap = app_of(e)
        ap.scale = type(a.scale) == "table" and a.scale or {1, 1, 1}
        ap.visible = a.visible ~= false
        ap.model = a.model or ""
        ap.tex = type(a.tex) == "table" and a.tex or {}
        ap.bones = {}
        for name, b in pairs(type(a.bones) == "table" and a.bones or {}) do
            ap.bones[name] = {flags = b[1] or 0, pos = b[2] or {0, 0, 0}, rot = b[3] or {0, 0, 0},
                              scale = b[4] or {1, 1, 1}, model = b[5] or ""}
        end
        ap.text, ap.color = a.text or "", a.color or 0xFFFFFFFF
        ap.ver = 1
        e.app_dirty = true
    end
    if type(r.mem) == "table" then
        e.mem = r.mem
        local n = 0
        for k, v in pairs(e.mem) do n = n + #k + (value_bytes(v) or 0) end
        e.mem_bytes = n
    end
end

-- ------------------------------------------------------------------------------------------ admin / tests
function M.describe(eid)
    local e = S.ents[eid]
    if not e then return "[olife_world] mob_api: no entity eid=" .. tostring(eid) end
    local ap = e.app or {}
    local bones, tex = {}, {}
    for n, b in pairs(ap.bones or {}) do
        bones[#bones + 1] = string.format("%s:%d:%.2f,%.2f,%.2f:%.1f,%.1f,%.1f:%.2f:%s", n, b.flags, b.pos[1], b.pos[2],
            b.pos[3], b.rot[1], b.rot[2], b.rot[3], b.scale[1], b.model ~= "" and b.model or "-")
    end
    table.sort(bones)
    for s, t in pairs(ap.tex or {}) do tex[#tex + 1] = s .. "=" .. t end
    table.sort(tex)
    local all = M.mem_all(e)
    local keys = {}
    for k in pairs(all) do keys[#keys + 1] = k end
    table.sort(keys)
    local an = e.anim
    local mem = {}
    for _, k in ipairs(keys) do
        local ok, s = pcall(json.tostring, {all[k]})
        mem[#mem + 1] = k .. "=" .. ((ok and s or "?"):gsub(" ", "\\u0020"):gsub(";", "\\u003b"))
    end
    return string.format("[olife_world] mob_api eid=%d owner=%d ver=%d scale=%.3f,%.3f,%.3f visible=%s model=%s tex=%s " ..
        "bones=%s text=%s color=%08x anim=%s anim_speed=%.2f anim_loop=%s rot=%.2f,%.2f,%.2f fill=%s mem_bytes=%d " ..
        "mem=%s", e.eid, e.owner or 0, ap.ver or 0, (ap.scale or {1})[1] or 1, (ap.scale or {1, 1})[2] or 1,
        (ap.scale or {1, 1, 1})[3] or 1, tostring(ap.visible ~= false), ap.model ~= "" and ap.model or "-",
        #tex > 0 and table.concat(tex, ",") or "-", #bones > 0 and table.concat(bones, ";") or "-",
        ((ap.text or ""):gsub(" ", "_")), ap.color or 0xFFFFFFFF, an and (an.name ~= "" and an.name or "stopped") or "-",
        an and an.speed or 0, tostring(an and an.loop or false), e.rot.x, e.rot.y, e.rot.z,
        e.fill and (e.fill.i .. "/" .. e.fill.vol) or "-", select(2, M.mem_info(e)) or 0,
        #mem > 0 and table.concat(mem, ";") or "-")
end

function M.status()
    local function kv(t)
        local l = {}
        for k, v in pairs(t) do l[#l + 1] = k .. ":" .. v end
        table.sort(l)
        return table.concat(l, ",")
    end
    local deny = {}
    for a, d in pairs(ST.deny) do for x in pairs(d) do deny[#deny + 1] = a .. "/" .. x end end
    table.sort(deny)
    return string.format("[olife_world] mobapi(rights=%s,store=%s,applied={%s},rejected={%s},queries={%s},answers=%d," ..
        "fills=%d,fill_blocks=%d,fill_skipped=%d,sounds=%d,sound_msgs=%d,app_msgs=%d,anim_msgs=%d," ..
        "perm_refused=%d,mem_sets=%d,deny={%s})", rights and "A1" or "stub", store and "A4" or "stub", kv(ST.applied),
        kv(ST.rejected), kv(ST.queries), ST.answers, ST.fills, ST.fill_blocks, ST.fill_skipped,
        ST.sounds, ST.sound_msgs, ST.app_msgs, ST.anim_msgs, ST.perm_refused, ST.mem_sets, table.concat(deny, ","))
end

-- permission stub (until A1's rights): deny <action class> of scripts of <account> ("*" = every account / class)
function M.set_deny(account, action, on)
    local d = ST.deny[account]
    if on then
        if not d then d = {}; ST.deny[account] = d end
        d[action] = true
    elseif d then
        d[action] = nil
        if not next(d) then ST.deny[account] = nil end
    end
    return M.status()
end

-- tests / admin: a bench runs the code of olife_world:sandbox/<code>.lua (like spawn_sample, for an existing bench)
function M.bench_code(eid, code)
    local e = S.ents[eid]
    if not ED.is_bench(e) then return "[olife_world] bench_code: no bench eid=" .. tostring(eid) end
    if type(code) ~= "string" or not code:match("^[%w_]+$") then return "[olife_world] bench_code: bad code name" end
    local ok, src = pcall(file.read, "olife_world:sandbox/" .. code .. ".lua")
    if not ok or type(src) ~= "string" or src == "" then return "[olife_world] bench_code: no sandbox/" .. code .. ".lua" end
    if e.status == "run" and sandbox.connected() then pcall(sandbox.unload_entity, e) end
    e.code, e.status, e.error = src, "run", nil
    e.owner = ED.owner_id(e.owner_acct ~= "" and e.owner_acct or "_world")
    local loaded = sandbox.connected() and sandbox.load_entity(e)
    ED.console_add(e, 2, "code " .. code .. " (admin)")
    ED.ST.dirty = true
    pcall(ED.push_state, e)
    return string.format("[olife_world] bench_code eid=%d code=%s owner=%d loaded=%s", eid, code, e.owner, tostring(loaded))
end

function M.console_tail(eid, n)
    local e = S.ents[eid]
    if not e then return "[olife_world] bench_console: no entity eid=" .. tostring(eid) end
    local c = e.console or {}
    local out = {}
    for i = math.max(1, #c - (n or 10) + 1), #c do
        local l = c[i]
        out[#out + 1] = string.format("[olife_world] console eid=%d seq=%d tick=%d kind=%d %s", eid, l.seq or 0,
                                      l.tick or 0, l.kind or 0, tostring(l.text))
    end
    return #out > 0 and table.concat(out, "\n") or ("[olife_world] console eid=" .. eid .. " empty")
end

function M.register_commands()
    console.add_command("bench_code eid:int code:str", "UX A3 (tests/admin): bench <eid> runs olife_world:sandbox/<code>.lua",
        function(args) return M.bench_code(args[1], args[2]) end)
    console.add_command("bench_console eid:int n:int=10", "UX A3: last n console lines of a bench",
        function(args) return M.console_tail(args[1], args[2]) end)
    console.add_command("mob_api eid:int", "UX A3: script API state of an entity (appearance, anim, fill, memory)",
        function(args) return M.describe(args[1]) end)
    console.add_command("mobapi_status", "UX A3: script API counters", function() return M.status() end)
    console.add_command("olife.api_deny account:str action:str",
        "UX A3 permission stub (until A1): refuse <action> (appearance|anim|sound|blocks|memory|query|*) to scripts of <account>",
        function(args) return M.set_deny(args[1], args[2], true) end)
    console.add_command("olife.api_allow account:str action:str", "UX A3: undo olife.api_deny",
        function(args) return M.set_deny(args[1], args[2], false) end)
end

M.stats = ST
return M
