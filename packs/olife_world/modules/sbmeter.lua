-- olife_world:sbmeter — meters of the real sandbox service seen from the world (olife wave 3a, agent olife_w3s):
-- cumulative per owner / per entity (status counts, fuel, credits, applied/rejected actions, last text/error),
-- one row per applied TickResult (per owner: entities, statuses, fuel, credits, moved, applied, rejected) exported
-- AFTER the tick to user:export/sandbox_ticks.jsonl (outside the measured tick time), the dump for
-- `olife.sandbox_dump`, slots for `spawn_scripted`, and the view index (grid, 3D radius, at most VIEW_MAX).
-- Kept apart from modules/sandbox.lua (the bridge) so the bridge only calls a few hooks.
local M = {}
local floor = math.floor

M.VIEW_R, M.VIEW_MAX = 6, 8
M.MAX_ACTS = 16                                       -- actions applied per entity and TickResult
M.ONCE = {set_pos = true, set_rot = true, set_vel = true}   -- each at most once per entity and TickResult

local owners, ents, svc, rows = {}, {}, {}, {}
local last_in = 0
local cur = nil
local wall_sum, wall_max, nres = 0, 0, 0
M.owners, M.ents = owners, ents
M.svc = svc                                           -- UX round 1: owner VM meters for the profiler page

local function owner_tot(o)
    local t = owners[o]
    if not t then
        t = {ticks = 0, st = {}, fuel = 0, credits = 0, api_credits = 0, applied = 0, rejected = 0, dropped = 0,
             ents = 0}
        owners[o] = t
    end
    return t
end

local function ent_tot(eid, o)
    local t = ents[eid]
    if not t then
        t = {owner = o, ticks = 0, st = {}, fuel = 0, credits = 0, applied = 0, rejected = 0, dropped = 0}
        ents[eid] = t
        owner_tot(o).ents = owner_tot(o).ents + 1
    end
    return t
end

-- flood / duplicate guard, called first in apply_action: returns a reject reason or nil
function M.guard(e, op, rtick)
    if e.sb_rtick ~= rtick then e.sb_rtick, e.sb_n, e.sb_once = rtick, 0, {} end
    e.sb_n = e.sb_n + 1
    if e.sb_n > M.MAX_ACTS then return "flood" end
    if M.ONCE[op] then
        if e.sb_once[op] then return "dup" end
        e.sb_once[op] = true
    end
    return nil
end

function M.result_begin(r, world_tick)
    local wall = tonumber(r.wall_us) or 0
    nres = nres + 1
    wall_sum = wall_sum + wall
    if wall > wall_max then wall_max = wall end
    cur = {tick = r.tick, at = world_tick, wall_us = wall, owners = {}}
end

-- after the entity's actions were applied (px,py,pz — position before them; da/dr — applied/rejected deltas)
function M.entity(e, er, px, py, pz, da, dr)
    local m = er.meter or {}
    local fuel, cr = tonumber(m.fuel) or 0, tonumber(m.credits) or 0
    local drop = tonumber(m.actions_dropped) or 0
    local o, t = owner_tot(e.owner), ent_tot(e.eid, e.owner)
    local s = tostring(er.status or "?")
    o.ticks, o.fuel, o.credits = o.ticks + 1, o.fuel + fuel, o.credits + cr
    o.api_credits = o.api_credits + (tonumber(m.api_credits) or 0)
    o.applied, o.rejected, o.dropped = o.applied + da, o.rejected + dr, o.dropped + drop
    o.st[s] = (o.st[s] or 0) + 1
    t.ticks, t.fuel, t.credits = t.ticks + 1, t.fuel + fuel, t.credits + cr
    t.applied, t.rejected, t.dropped = t.applied + da, t.rejected + dr, t.dropped + drop
    t.st[s] = (t.st[s] or 0) + 1
    t.last = s
    if er.error then t.err = tostring(er.error):sub(1, 300) end
    if cur then
        local k = tostring(e.owner)
        local row = cur.owners[k]
        if not row then
            row = {n = 0, st = {}, fuel = 0, credits = 0, moved = 0, applied = 0, rejected = 0, dropped = 0, api = 0}
            cur.owners[k] = row
        end
        row.n = row.n + 1
        row.api = row.api + (tonumber(m.api_credits) or 0)      -- UX A3: API credits (price table) of this result
        row.st[s] = (row.st[s] or 0) + 1
        row.fuel, row.credits = row.fuel + fuel, row.credits + cr
        row.applied, row.rejected, row.dropped = row.applied + da, row.rejected + dr, row.dropped + drop
        if e.pos.x ~= px or e.pos.y ~= py or e.pos.z ~= pz then row.moved = row.moved + 1 end
    end
end

function M.text(e, txt)
    ent_tot(e.eid, e.owner).text = txt:sub(1, 300)
end

function M.result_end(r)
    for _, m in ipairs(r.owners or {}) do
        if m.owner then svc[m.owner] = m end
    end
    if cur then rows[#rows + 1] = cur end
    cur = nil
end

-- after the tick (server.tick, outside the measured time): rows -> jsonl
function M.export(out, world_ms, ph)
    if #rows == 0 then return end
    for _, row in ipairs(rows) do
        row.world_ms = world_ms
        row.in_ms = last_in                                   -- TickInput build + encode of this tick
        if ph then row.ph = {ph[1], ph[2], ph[3], ph[4], ph[5]} end   -- phases of this world tick
        if out then out:write(row) end
    end
    rows = {}
    if out then out:flush(true) end
end

local in_sum, in_max, in_n = 0, 0, 0
function M.input_time(ms)
    last_in = ms
    in_n, in_sum = in_n + 1, in_sum + ms
    if ms > in_max then in_max = ms end
end

function M.summary()
    local n = 0
    for _ in pairs(owners) do n = n + 1 end
    return string.format("owners=%d,sb_ms_avg=%.2f,sb_ms_max=%.2f,in_ms_avg=%.2f,in_ms_max=%.2f", n,
        wall_sum / math.max(nres, 1) / 1000, wall_max / 1000, in_sum / math.max(in_n, 1), in_max)
end

function M.dump(path, S, extra)
    local os_, es = {}, {}
    for o, t in pairs(owners) do
        local m = svc[o] or {}
        os_[tostring(o)] = {ents = t.ents, ticks = t.ticks, st = t.st, fuel = t.fuel, credits = t.credits,
                            api_credits = t.api_credits, applied = t.applied, rejected = t.rejected, dropped = t.dropped,
                            state = m.state, kills = m.kills, traps = m.traps, mem_peak = m.mem_peak, lua_heap = m.lua_heap}
    end
    for eid, t in pairs(ents) do
        local e = S.ents[eid]
        es[#es + 1] = {eid = eid, owner = t.owner, script = e and e.script, last = t.last, err = t.err, st = t.st,
                       ticks = t.ticks, fuel = t.fuel, credits = t.credits, applied = t.applied, rejected = t.rejected,
                       dropped = t.dropped, text = t.text, pos = e and {e.pos.x, e.pos.y, e.pos.z}}
    end
    table.sort(es, function(a, b) return a.eid < b.eid end)
    local d = {tick = S.tick, results = nres, wall_us_avg = wall_sum / math.max(nres, 1), wall_us_max = wall_max,
               owners = os_, entities = es}
    for k, v in pairs(extra or {}) do d[k] = v end
    file.write(path, json.tostring(d))
    return #es
end

-- view index over all world entities: grid of VIEW_R cells, fixed scan order -> deterministic, O(n)
function M.view_index(all)
    local R = M.VIEW_R
    local cells, ids = {}, {}
    for eid in pairs(all) do ids[#ids + 1] = eid end
    table.sort(ids)
    local function key(x, y, z) return (x * 4096 + z) * 512 + y end
    for _, eid in ipairs(ids) do
        local o = all[eid]
        local k = key(floor(o.pos.x / R), floor(o.pos.y / R), floor(o.pos.z / R))
        local c = cells[k]
        if not c then c = {}; cells[k] = c end
        c[#c + 1] = o
    end
    local r2 = R * R
    return function(e)
        local view = {}
        local cx, cy, cz = floor(e.pos.x / R), floor(e.pos.y / R), floor(e.pos.z / R)
        for dx = -1, 1 do
            for dz = -1, 1 do
                for dy = -1, 1 do
                    local c = cells[key(cx + dx, cy + dy, cz + dz)]
                    if c then
                        for _, o in ipairs(c) do
                            if #view >= M.VIEW_MAX then return view end
                            if o.eid ~= e.eid and (o.pos.x - e.pos.x) ^ 2 + (o.pos.y - e.pos.y) ^ 2 +
                               (o.pos.z - e.pos.z) ^ 2 < r2 then
                                view[#view + 1] = {eid = o.eid, kind = o.kind, pos = {o.pos.x, o.pos.y, o.pos.z}}
                            end
                        end
                    end
                end
            end
        end
        return view
    end
end

-- wave 5p (OLIFE_WORLD_PERF.md): binary bridge — the view of an entity as JSON text straight from the grid, without
-- the view tables: every seen entity's fragment `{"eid":E,"kind":K,"pos":[x,y,z]}` is built once per tick (cached
-- on the entity) and joined; the text is byte-identical to encode_view(view_index(all)(e)) (same scan order, same
-- number formatting). Before: 8 view tables + ~40 strings per entity per tick (≈ 2 MB of garbage at 500 entities).
local vj_buf = {}
local VJ_OFF = {}                                     -- key(x+dx, y+dy, z+dz) - key(x, y, z), order dx, dz, dy
for dx = -1, 1 do for dz = -1, 1 do for dy = -1, 1 do VJ_OFF[#VJ_OFF + 1] = (dx * 4096 + dz) * 512 + dy end end end
local tostr_ = tostring
local function vnum(x)
    if x ~= x or x == math.huge or x == -math.huge then return "0" end
    return tostr_(x)
end
function M.view_json_index(all, tick)
    local R = M.VIEW_R
    local cells, ids = {}, {}
    for eid in pairs(all) do ids[#ids + 1] = eid end
    table.sort(ids)
    local function key(x, y, z) return (x * 4096 + z) * 512 + y end
    for _, eid in ipairs(ids) do
        local o = all[eid]
        local k = key(floor(o.pos.x / R), floor(o.pos.y / R), floor(o.pos.z / R))
        local c = cells[k]
        if not c then c = {}; cells[k] = c end
        c[#c + 1] = o
    end
    local r2, vmax = R * R, M.VIEW_MAX
    return function(e)
        local n = 0
        local ex, ey, ez = e.pos.x, e.pos.y, e.pos.z
        local k0 = key(floor(ex / R), floor(ey / R), floor(ez / R))
        local eid = e.eid
        -- the 27 neighbour cells in the order dx, dz, dy (= view_index) as one flat loop over key offsets: the
        -- 4-deep nest with 1..3-element inner loops was blacklisted by LuaJIT ("leaving loop in root trace") and the
        -- outer loops kept re-recording into it (seen live, wave 5p)
        for j = 1, 27 do
            local c = cells[k0 + VJ_OFF[j]]
            if c then
                local i, m = 1, #c
                while i <= m and n < vmax do
                    local o = c[i]
                    local p = o.pos
                    if o.eid ~= eid and (p.x - ex) ^ 2 + (p.y - ey) ^ 2 + (p.z - ez) ^ 2 < r2 then
                        if o.vj_tick ~= tick then
                            o.vj_tick = tick
                            o.vj = '{"eid":' .. vnum(o.eid) .. ',"kind":' .. vnum(o.kind) .. ',"pos":[' ..
                                vnum(p.x) .. "," .. vnum(p.y) .. "," .. vnum(p.z) .. ']}'
                        end
                        n = n + 1
                        vj_buf[n] = o.vj
                    end
                    i = i + 1
                end
            end
        end
        if n == 0 then return nil end
        return "[" .. table.concat(vj_buf, ",", 1, n) .. "]"
    end
end

-- TickInput as one JSON line built with table.concat (jsonl transport). json.tostring of the nested tables cost
-- 20-21 ms per tick at 500 entities with views (351 KB, headless 0.32, tools/olife/tests/bench_tickinput.lua);
-- this encoder: 2.95 ms with the view index (303 KB, parses back to the same 500 entities). Numbers: LuaJIT
-- tostring (%.14g); non-finite -> 0 (positions are validated finite when applied anyway).
local tostr, concat = tostring, table.concat
local function num(x)
    if x ~= x or x == math.huge or x == -math.huge then return "0" end
    return tostr(x)
end
local function vec3(v) return "[" .. num(v[1]) .. "," .. num(v[2]) .. "," .. num(v[3]) .. "]" end

-- wave 4b: one entity's view as JSON text (binary contract: EntityInput.view_json) — same shape as in encode_tick,
-- hand-built like it (json.tostring per entity cost the binary bridge ~2x)
function M.encode_view(vw)
    local b = {}
    for k = 1, #vw do
        local o = vw[k]
        b[k] = (k > 1 and ',{"eid":' or '[{"eid":') .. num(o.eid) .. ',"kind":' .. num(o.kind) .. ',"pos":' ..
            vec3(o.pos) .. '}'
    end
    b[#b + 1] = ']'
    return concat(b)
end

function M.encode_tick(tick, seed, dt, list)
    local b, n = {'{"type":"tick","tick":' .. num(tick) .. ',"seed":' .. num(seed) .. ',"dt":' .. num(dt) .. ',"entities":['}, 1
    for i = 1, #list do
        local e = list[i]
        n = n + 1
        b[n] = (i > 1 and ',{"eid":' or '{"eid":') .. num(e.eid) .. ',"owner":' .. num(e.owner) .. ',"pos":' ..
            vec3(e.pos) .. ',"rot":' .. vec3(e.rot) .. ',"vel":' .. vec3(e.vel)
        if e.events then
            n = n + 1
            b[n] = ',"events":' .. json.tostring(e.events)
        end
        if e.fields then                                    -- UX A3: self.fields (scale, visible, model, anim)
            n = n + 1
            b[n] = ',"fields":' .. json.tostring(e.fields)
        end
        if e.answers then                                   -- UX A3: answers to queries {qid: value}
            n = n + 1
            b[n] = ',"answers":' .. json.tostring(e.answers)
        end
        local vw = e.view
        if vw and #vw > 0 then
            n = n + 1
            b[n] = ',"view":['
            for k = 1, #vw do
                local o = vw[k]
                n = n + 1
                b[n] = (k > 1 and ',{"eid":' or '{"eid":') .. num(o.eid) .. ',"kind":' .. num(o.kind) .. ',"pos":' ..
                    vec3(o.pos) .. '}'
            end
            n = n + 1
            b[n] = ']'
        end
        n = n + 1
        b[n] = '}'
    end
    n = n + 1
    b[n] = ']}\n'
    return concat(b)
end

-- spawn slots for spawn_scripted: grid step 4 within radius 36 of the spawn, layers +1/+5/+9 (≈ 750 slots);
-- an orbit of radius <= 4 around a slot stays inside the world's 48-block area
function M.slots(spawn)
    local l = {}
    for _, dy in ipairs({1, 5, 9}) do
        for gx = -9, 9 do
            for gz = -9, 9 do
                local x, z = gx * 4, gz * 4
                if x * x + z * z <= 36 * 36 then l[#l + 1] = {x = spawn.x + x + 0.5, y = spawn.y + dy, z = spawn.z + z + 0.5} end
            end
        end
    end
    return l
end

return M
