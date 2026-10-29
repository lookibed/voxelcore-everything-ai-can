-- olife_proto:items — hand-written (NOT generated), wave 4c: inventory helpers shared by the world and the client.
-- Item ids travel as raw indices (like block ids). The world sends item.defs_count() and a hash of the names of its
-- item defs; the client's first `items` defs must give the same hash (client-only packs may append their own items
-- after them — olife_client does — but must not shift the shared ones). Items of the Olife pack set live in this
-- pack would live in items/ here (loaded on both sides); there are none since UX round 1 (the test coin is gone).
local U = require "olife_proto:util"

local M = {}
M.HOTBAR = 10

-- FNV over the names of item defs 0..n-1 (string bytes folded 4 at a time)
function M.table_hash(n)
    local h = 2166136261
    for id = 0, n - 1 do
        local nm = item.name(id)
        local acc = #nm
        for i = 1, #nm do acc = (acc * 31 + nm:byte(i)) % 4294967296 end
        h = U.fnv_ints(h, id, acc)
    end
    return h
end

-- hash of an inventory: selected slot + every non-empty (slot, item, count); slots = {[slot] = {item, count}}
function M.inv_hash(selected, slots, size)
    local h = U.fnv_ints(selected or 0, size or 0)
    for i = 0, (size or 0) - 1 do
        local s = slots[i]
        if s and s[1] ~= 0 and s[2] > 0 then h = U.fnv_ints(h, i, s[1], s[2]) end
    end
    return h
end

-- read an engine inventory into {[slot] = {item, count}}
function M.read(invid, out)
    out = out or {}
    local n = inventory.size(invid)
    for i = 0, n - 1 do
        local id, c = inventory.get(invid, i)
        local s = out[i]
        if not s then s = {0, 0}; out[i] = s end
        if id == 0 or c <= 0 then s[1], s[2] = 0, 0 else s[1], s[2] = id, c end
    end
    return out, n
end

return M
