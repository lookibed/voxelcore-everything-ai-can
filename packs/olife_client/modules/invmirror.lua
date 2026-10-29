-- olife_client:invmirror — wave 4c: mirror of the server-authoritative inventory (olife_world:inventory).
-- InventoryState -> own table {[slot] = {item, count}} + the engine inventory of the client's olife player (so the
-- engine's inventory UI shows it) + the selected hotbar slot; the hash of the whole mirror is compared with the
-- world's (`div` counts differences). The item table is checked once: the client's first `items` item defs must hash
-- like the world's (client-only items, e.g. olife_client tools, may follow them). Requests go out as InvAction; the
-- client never changes its mirror on its own (no inventory prediction: the answer comes in the same tick's phase 4).
local IT = require "olife_proto:items"

local M = {}
local I = {slots = {}, size = 40, selected = 0, rev = 0, ack = 0, items_ok = nil, hash = 0, seq = 0}
M.I = I
M.stats = {states = 0, full = 0, slots = 0, div = 0, rejects = {}, items_mismatch = 0, sent = 0}

function M.reset()
    I.slots, I.selected, I.rev, I.ack, I.hash = {}, 0, 0, 0, 0
end

local function engine_inv(S)
    if not S.pid then return nil end
    local ok, inv = pcall(player.get_inventory, S.pid)
    if ok and inv and inv ~= 0 then return inv end
end

function M.on_state(S, m)
    local st = M.stats
    st.states = st.states + 1
    if I.items_ok == nil then
        I.items_ok = item.defs_count() >= m.items and IT.table_hash(m.items) == m.items_hash
        if not I.items_ok then
            st.items_mismatch = st.items_mismatch + 1
            print(string.format("[olife_client] WARNING: item table differs from the world (world %d defs, here %d)",
                m.items, item.defs_count()))
        end
    end
    local inv = engine_inv(S)
    if inv then I.size = inventory.size(inv) end
    if m.full then
        st.full = st.full + 1
        for i = 0, I.size - 1 do
            local s = I.slots[i]
            if s then s[1], s[2] = 0, 0 end
            if inv and I.items_ok then inventory.set(inv, i, 0, 0) end
        end
    end
    for _, sl in ipairs(m.slots) do
        local s = I.slots[sl.slot]
        if not s then s = {0, 0}; I.slots[sl.slot] = s end
        s[1], s[2] = sl.item, sl.count
        st.slots = st.slots + 1
        if inv and I.items_ok and sl.slot < I.size then inventory.set(inv, sl.slot, sl.item, sl.count) end
    end
    I.selected, I.rev, I.ack = m.selected, m.rev, m.ack
    if S.pid then pcall(player.set_selected_slot, S.pid, m.selected) end
    I.hash = IT.inv_hash(I.selected, I.slots, I.size)
    if I.hash ~= m.hash then
        st.div = st.div + 1
        if st.div <= 5 then
            print(string.format("[olife_client] inventory hash %d != world %d at rev %d", I.hash, m.hash, m.rev))
        end
    end
end

function M.on_reject(m)
    M.stats.rejects[m.reason] = (M.stats.rejects[m.reason] or 0) + 1
end

-- requests (send = client.send)
function M.request(send, op, slot, slot2, count)
    I.seq = I.seq + 1
    M.stats.sent = M.stats.sent + 1
    send("InvAction", {seq = I.seq, op = op, slot = slot, slot2 = slot2 or 0, count = count or 0})
end
function M.select(send, slot) M.request(send, 1, slot) end
function M.move(send, a, b, count) M.request(send, 2, a, b, count) end
function M.drop(send, slot, count) M.request(send, 3, slot, 0, count or 1) end

-- slot with an item placing a block (selected first, then the hotbar, then the rest) -> slot, item, block | nil
function M.find_placeable()
    local function ok(i)
        local s = I.slots[i]
        if s and s[1] ~= 0 and s[2] > 0 then
            local b = item.placing_block(s[1])
            if b and b > 0 then return s[1], b end
        end
    end
    local it, b = ok(I.selected)
    if it then return I.selected, it, b end
    for i = 0, I.size - 1 do
        it, b = ok(i)
        if it then return i, it, b end
    end
end

-- first non-empty slot from `from` -> slot, item, count
function M.find_nonempty(from)
    for k = 0, I.size - 1 do
        local i = ((from or 0) + k) % I.size
        local s = I.slots[i]
        if s and s[1] ~= 0 and s[2] > 0 then return i, s[1], s[2] end
    end
end

function M.total()
    local n = 0
    for _, s in pairs(I.slots) do n = n + s[2] end
    return n
end

-- olife_inventory: compare with the world's dump (user:export/inventory_check.json) -> user:export/inventory_bot.json
function M.check(S)
    local ok, d = pcall(function() return json.parse(file.read("user:export/inventory_check.json")) end)
    if not ok or type(d) ~= "table" then return "[olife_client] check_inventory: no user:export/inventory_check.json" end
    local w = (d.players or {})[tostring(S.eid)]
    local r = {eid = S.eid, rev = I.rev, hash = I.hash, selected = I.selected, total = M.total(), match = false,
               world = w and {hash = w.hash, rev = w.rev, selected = w.selected} or nil, diff = {},
               div = M.stats.div, items_ok = I.items_ok}
    if w then
        local want = {}
        for _, s in ipairs(w.slots or {}) do want[s[1]] = {s[2], s[3]} end
        for i = 0, I.size - 1 do
            local a, b = I.slots[i] or {0, 0}, want[i] or {0, 0}
            if a[1] ~= b[1] or a[2] ~= b[2] then r.diff[#r.diff + 1] = {i, a[1], a[2], b[1], b[2]} end
        end
        r.match = #r.diff == 0 and w.selected == I.selected and w.hash == I.hash
    end
    file.write("user:export/inventory_bot.json", json.tostring(r))
    return string.format("[olife_client] check_inventory eid=%s match=%s diff=%d rev=%d world_rev=%s total=%d div=%d",
        tostring(S.eid), tostring(r.match), #r.diff, I.rev, tostring(w and w.rev), r.total, M.stats.div)
end

function M.status()
    local s = M.stats
    local rj = {}
    for k, v in pairs(s.rejects) do rj[#rj + 1] = k .. ":" .. v end
    return string.format("inv_rev=%d inv_states=%d inv_div=%d inv_total=%d inv_sel=%d inv_sent=%d inv_rej={%s} inv_items_ok=%s",
        I.rev, s.states, s.div, M.total(), I.selected, s.sent, table.concat(rj, ","), tostring(I.items_ok))
end

return M
