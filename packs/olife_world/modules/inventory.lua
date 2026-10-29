-- olife_world:inventory — wave 4c: server-authoritative inventory.
-- The inventory IS the engine inventory of the session's engine player (player.get_inventory, 40 slots, hotbar 0..9);
-- the client only mirrors it. Requests: InvAction(select | move | drop) and BlockAction (place consumes one item of
-- the selected slot whose placing-block is the requested block; break gives the block's picking item, the rest of a
-- full inventory is dropped). Dropped items are world entities of kind 4 (def olife_client:drop, name = item name)
-- that any player picks up by walking within `pick_radius` (after 1 s; the dropper after 2 s); they expire after 60 s.
-- Replication: InventoryState to the owning session with the changed slots (all on join), the selected slot, the
-- item table check and the hash of the whole inventory (olife_proto:items.inv_hash) — the client compares.
-- Validation: rate bucket (`inv_rate`/s, burst `inv_burst`), slot ranges, counts, item present; refusals ->
-- InvReject{seq, op, reason}. A ledger keeps the item balance of the world: created (kit, breaks) = in inventories +
-- on the ground + placed + expired (olife_inventory checks it).
local IT = require "olife_proto:items"
local U = require "olife_proto:util"
local Mv = require "olife_proto:movement"
local net = require "olife_world:net"

local M = {}
local srv, S, cfg
local floor, sqrt, min = math.floor, math.sqrt, math.min

M.stats = {actions = 0, rejects = {}, states = 0, state_bytes = 0, drops = 0, picks = 0, picks_cross = 0,
           placed = 0, place_rejects = 0, broken = 0, overflow = 0, expired = 0}
M.ledger = {created = 0, placed = 0, expired = 0}
local saved = {}            -- "account/name" -> {selected, slots = {{slot, item name, count}}}
local items_count, items_hash

function M.init(server)
    srv, S, cfg = server, server.S, server.cfg
    cfg.inv_rate = cfg.inv_rate or 10
    cfg.inv_burst = cfg.inv_burst or 20
    cfg.pick_radius = cfg.pick_radius or 1.5
    cfg.drop_ttl = cfg.drop_ttl or 1200
    -- UX round 1: no coins (the user: «нахуя монетки»); the kit is real blocks, more come from breaking them
    cfg.kit = cfg.kit or {{"base:stone.item", 32}, {"base:planks.item", 16}}
end

local function tables()
    if not items_count then
        items_count = item.defs_count()
        items_hash = IT.table_hash(items_count)
    end
    return items_count, items_hash
end

local function reject(sess, seq, op, reason)
    M.stats.rejects[reason] = (M.stats.rejects[reason] or 0) + 1
    net.send_client(sess.gw, sess.sid, "InvReject", {seq = seq, op = op, reason = reason})
end

local function slot_count(sess)
    return sess.inv_size or 0
end

-- attach: restore the saved inventory of the account/name, else the starting kit
function M.on_attach(sess)
    local inv = player.get_inventory(sess.pid)
    sess.inv, sess.inv_size = inv, inventory.size(inv)
    sess.inv_sel, sess.inv_rev, sess.inv_ack, sess.inv_tokens = 0, 0, 0, cfg.inv_burst
    sess.inv_full, sess.inv_dirty, sess.inv_shadow = true, true, {}
    for i = 0, sess.inv_size - 1 do inventory.set(inv, i, 0, 0) end
    local sv = saved[sess.account .. "/" .. sess.name]
    if sv then
        for _, r in ipairs(sv.slots or {}) do
            local ok, id = pcall(item.index, r[2])
            if ok and id and id > 0 and r[1] >= 0 and r[1] < sess.inv_size then inventory.set(inv, r[1], id, r[3]) end
        end
        sess.inv_sel = sv.selected or 0
    else
        for i, k in ipairs(cfg.kit) do
            local ok, id = pcall(item.index, k[1])
            if ok and id and id > 0 then
                inventory.set(inv, i - 1, id, k[2])
                M.ledger.created = M.ledger.created + k[2]
            end
        end
    end
    player.set_selected_slot(sess.pid, sess.inv_sel)
end

local function snapshot(sess)
    local out = {}
    local inv = sess.inv
    for i = 0, sess.inv_size - 1 do
        local id, c = inventory.get(inv, i)
        if id ~= 0 and c > 0 then out[#out + 1] = {i, item.name(id), c} end
    end
    return {selected = sess.inv_sel, slots = out}
end

function M.on_leave(sess)
    if not sess.inv then return end
    saved[sess.account .. "/" .. sess.name] = snapshot(sess)
end

function M.save()
    local out = {}
    for k, v in pairs(saved) do out[k] = v end
    for _, s in pairs(S.sessions) do
        if s.inv then out[s.account .. "/" .. s.name] = snapshot(s) end
    end
    return out
end

function M.load(t)
    for k, v in pairs(t or {}) do saved[k] = v end
end

-- ------------------------------------------------------------------ requests
local function take_token(sess, seq, op)
    if sess.inv_tokens < 1 then
        reject(sess, seq, op, 1)
        return false
    end
    sess.inv_tokens = sess.inv_tokens - 1
    return true
end

local function front_pos(sess)
    local a = math.rad(sess.rot.x or 0)
    return {x = sess.pos.x - math.sin(a) * 1.2, y = sess.pos.y + 0.5, z = sess.pos.z - math.cos(a) * 1.2}
end

local function spawn_drop(itemid, count, pos, dropper)
    local e = srv.new_entity(4, "olife_client:drop", item.name(itemid), dropper or 0, pos)
    e.item, e.count, e.dropper = itemid, count, dropper or 0
    e.pick_at = S.tick + 20
    e.owner_pick_at = S.tick + 40
    e.expire = S.tick + cfg.drop_ttl
    M.stats.drops = M.stats.drops + 1
    return e
end

function M.on_action(sess, m)
    if not sess.inv then return end
    M.stats.actions = M.stats.actions + 1
    sess.actions = sess.actions + 1
    S.acct_actions[sess.account] = (S.acct_actions[sess.account] or 0) + 1
    if m.seq > sess.inv_ack then sess.inv_ack = m.seq end
    sess.inv_dirty = true                                    -- the ack goes back even on a refusal
    if not take_token(sess, m.seq, m.op) then return end
    local inv, n = sess.inv, sess.inv_size
    if m.op == 1 then                                        -- select hotbar slot
        if m.slot >= IT.HOTBAR then return reject(sess, m.seq, m.op, 2) end
        sess.inv_sel = m.slot
        player.set_selected_slot(sess.pid, m.slot)
    elseif m.op == 2 then                                    -- move slot -> slot2 (count 0 = all)
        if m.slot >= n or m.slot2 >= n or m.slot == m.slot2 then return reject(sess, m.seq, m.op, 2) end
        local a, ca = inventory.get(inv, m.slot)
        if a == 0 or ca <= 0 then return reject(sess, m.seq, m.op, 3) end
        local cnt = m.count == 0 and ca or m.count
        if cnt > ca then return reject(sess, m.seq, m.op, 4) end
        local b, cb = inventory.get(inv, m.slot2)
        if b == 0 or cb <= 0 then
            inventory.set(inv, m.slot2, a, cnt)
            if cnt == ca then inventory.set(inv, m.slot, 0, 0) else inventory.set_count(inv, m.slot, ca - cnt) end
        elseif b == a then
            local mv = min(item.stack_size(a) - cb, cnt)
            if mv <= 0 then return reject(sess, m.seq, m.op, 4) end
            inventory.set_count(inv, m.slot2, cb + mv)
            if mv == ca then inventory.set(inv, m.slot, 0, 0) else inventory.set_count(inv, m.slot, ca - mv) end
        elseif cnt == ca then                                 -- swap whole stacks
            inventory.set(inv, m.slot2, a, ca)
            inventory.set(inv, m.slot, b, cb)
        else
            return reject(sess, m.seq, m.op, 4)
        end
    elseif m.op == 3 then                                    -- drop
        if m.slot >= n then return reject(sess, m.seq, m.op, 2) end
        local a, ca = inventory.get(inv, m.slot)
        if a == 0 or ca <= 0 then return reject(sess, m.seq, m.op, 3) end
        if m.count < 1 or m.count > ca then return reject(sess, m.seq, m.op, 4) end
        if m.count == ca then inventory.set(inv, m.slot, 0, 0) else inventory.set_count(inv, m.slot, ca - m.count) end
        spawn_drop(a, m.count, front_pos(sess), sess.eid)
    else
        return reject(sess, m.seq, m.op, 4)
    end
end

-- BlockAction place: the selected slot must hold an item placing this block -> true (consume after apply)
function M.check_place(sess, m)
    if not sess.inv then return true end
    local a, ca = inventory.get(sess.inv, sess.inv_sel)
    if a ~= 0 and ca > 0 and item.placing_block(a) == m.block then return true end
    M.stats.place_rejects = M.stats.place_rejects + 1
    reject(sess, m.seq, 0, 5)
    return false
end

function M.on_placed(sess)
    if not sess.inv then return end
    inventory.decrement(sess.inv, sess.inv_sel, 1)
    M.stats.placed = M.stats.placed + 1
    M.ledger.placed = M.ledger.placed + 1
    sess.inv_dirty = true
end

-- BlockAction break applied: the block's picking item into the inventory, the rest dropped at the block
function M.on_broken(sess, old_id, x, y, z)
    if not sess.inv or old_id <= 0 then return end
    local it = block.get_picking_item(old_id)
    if not it or it <= 0 then return end
    M.stats.broken = M.stats.broken + 1
    M.ledger.created = M.ledger.created + 1
    local rest = inventory.add(sess.inv, it, 1)
    if rest > 0 then
        M.stats.overflow = M.stats.overflow + 1
        spawn_drop(it, rest, {x = x + 0.5, y = y + 0.25, z = z + 0.5}, 0)
    end
    sess.inv_dirty = true
end

-- a player box would overlap the cell (placing into a player is refused)
function M.cell_has_player(x, y, z)
    for _, s in pairs(S.sessions) do
        if s.mv and Mv.overlaps_cell(s.mv, x, y, z) then return true end
    end
    return false
end

-- ------------------------------------------------------------------ world phase: buckets, pickups, expiry
function M.step_world()
    for _, s in pairs(S.sessions) do
        if s.inv then s.inv_tokens = min(cfg.inv_burst, s.inv_tokens + cfg.inv_rate / 20) end
    end
    local r2 = cfg.pick_radius * cfg.pick_radius
    for eid, e in pairs(S.ents) do
        if e.kind == 4 and e.item then
            if S.tick >= e.expire then
                M.ledger.expired = M.ledger.expired + e.count
                M.stats.expired = M.stats.expired + 1
                srv.remove_entity(eid)
            else
                -- deterministic order: sessions by eid
                local best
                for _, s in pairs(S.sessions) do
                    if s.inv and S.tick >= (s.eid == e.dropper and e.owner_pick_at or e.pick_at) then
                        local dx, dy, dz = s.pos.x - e.pos.x, s.pos.y + 0.5 - e.pos.y, s.pos.z - e.pos.z
                        if dx * dx + dy * dy + dz * dz <= r2 and (not best or s.eid < best.eid) then best = s end
                    end
                end
                if best then
                    local rest = inventory.add(best.inv, e.item, e.count)
                    local got = e.count - rest
                    if got > 0 then
                        M.stats.picks = M.stats.picks + 1
                        if best.eid ~= e.dropper then M.stats.picks_cross = M.stats.picks_cross + 1 end
                        best.inv_dirty = true
                    end
                    if rest <= 0 then srv.remove_entity(eid) else e.count = rest end
                end
            end
        end
    end
end

-- ------------------------------------------------------------------ replication (phase 4)
local send
function M.send(sess)
    if not sess.inv or not sess.inv_dirty then return end
    local t0 = U.now_ms()
    send(sess)
    M.stats.ms = (M.stats.ms or 0) + U.now_ms() - t0
end
function send(sess)
    local cnt, th = tables()
    local slots, sh = {}, sess.inv_shadow
    local inv = sess.inv
    for i = 0, sess.inv_size - 1 do
        local id, c = inventory.get(inv, i)
        if id == 0 or c <= 0 then id, c = 0, 0 end
        local o = sh[i]
        if sess.inv_full or not o or o[1] ~= id or o[2] ~= c then
            if not o then o = {0, 0}; sh[i] = o end
            o[1], o[2] = id, c
            if sess.inv_full and id == 0 then
                -- full state: empty slots are implied
            else
                slots[#slots + 1] = {slot = i, item = id, count = c}
            end
        end
    end
    sess.inv_rev = sess.inv_rev + 1
    local h = IT.inv_hash(sess.inv_sel, sh, sess.inv_size)
    local n = net.send_client(sess.gw, sess.sid, "InventoryState", {rev = sess.inv_rev, ack = sess.inv_ack,
        selected = sess.inv_sel, full = sess.inv_full, items = cnt, items_hash = th, slots = slots, hash = h})
    sess.inv_full, sess.inv_dirty, sess.inv_hash = false, false, h
    M.stats.states = M.stats.states + 1
    M.stats.state_bytes = M.stats.state_bytes + n
    sess.bytes = sess.bytes + n
end

-- ------------------------------------------------------------------ admin / checks
function M.dump(path)
    local players, total = {}, 0
    for _, s in pairs(S.sessions) do
        if s.inv then
            local sl, sh = {}, {}
            for i = 0, s.inv_size - 1 do
                local id, c = inventory.get(s.inv, i)
                if id ~= 0 and c > 0 then
                    sl[#sl + 1] = {i, id, c}
                    sh[i] = {id, c}
                    total = total + c
                end
            end
            players[tostring(s.eid)] = {name = s.name, selected = s.inv_sel, slots = sl, rev = s.inv_rev,
                                        hash = IT.inv_hash(s.inv_sel, sh, s.inv_size)}
        end
    end
    local drops, on_ground = {}, 0
    for eid, e in pairs(S.ents) do
        if e.kind == 4 and e.item then
            drops[#drops + 1] = {eid, e.item, e.count}
            on_ground = on_ground + e.count
        end
    end
    table.sort(drops, function(a, b) return a[1] < b[1] end)
    local L = M.ledger
    local balance = L.created - L.placed - L.expired - total - on_ground
    file.write(path or "user:export/inventory_world.json", json.tostring({tick = S.tick, players = players,
        drops = drops, ledger = L, in_inventories = total, on_ground = on_ground, balance = balance,
        stats = {actions = M.stats.actions, drops = M.stats.drops, picks = M.stats.picks,
                 picks_cross = M.stats.picks_cross, placed = M.stats.placed, broken = M.stats.broken,
                 place_rejects = M.stats.place_rejects, overflow = M.stats.overflow, expired = M.stats.expired}}))
    return string.format("[olife_world] dump_inventory players=%d in_inventories=%d on_ground=%d created=%d placed=%d " ..
        "expired=%d balance=%d tick=%d", table.count_pairs(players), total, on_ground, L.created, L.placed, L.expired,
        balance, S.tick)
end

function M.status()
    local s = M.stats
    local rj = {}
    for r, c in pairs(s.rejects) do rj[#rj + 1] = r .. ":" .. c end
    return string.format("inv_actions=%d inv_rej={%s} inv_states=%d inv_bytes=%d inv_drops=%d inv_picks=%d " ..
        "inv_picks_cross=%d inv_placed=%d inv_place_rej=%d inv_broken=%d inv_ms=%.1f", s.actions, table.concat(rj, ","), s.states,
        s.state_bytes, s.drops, s.picks, s.picks_cross, s.placed, s.place_rejects, s.broken, s.ms or 0)
end

return M
