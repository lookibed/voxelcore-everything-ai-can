-- olife_client:entdelta — wave 4c: apply EntityDelta (quantised per-session deltas, see olife_world:snapdelta).
-- Slots address entities (slot -> eid, per session); positions are 1/256 block integers (absolute `pa` or delta d8/d16
-- from what this client was last sent), rotations 1/65536 turn. The replica keeps the integers and shows/hashes the
-- dequantised values — exactly what the world hashes for this session. Entity records are the same as for
-- EntitySnapshot (client.lua): {eid, kind, def, name, pos, rot, from, shown, alpha, uid, term}.
local U = require "olife_proto:util"

local M = {}
local add32 = U.add32
local Q, RD = 256, 360 / 65536

M.stats = {msgs = 0, spawns = 0, moves = 0, despawns = 0, keyframes = 0, key_fix = 0, unknown_slot = 0}

local function engine_def(def)
    local ok, idx = pcall(entities.def_index, def)
    if ok and type(idx) == "number" and idx >= 0 then return def end
    return "olife_client:avatar"
end

local function deq(e)
    e.pos = {x = e.qx / Q, y = e.qy / Q, z = e.qz / Q}
    e.rot = {x = e.rx * RD, y = e.ry * RD, z = e.rz * RD}
end

function M.reset(S)
    S.dslots = {}
end

function M.apply(S, m)
    local st = M.stats
    st.msgs = st.msgs + 1
    if m.key then st.keyframes = st.keyframes + 1 end
    S.dslots = S.dslots or {}
    local slots = S.dslots
    for _, eid_slot in ipairs(m.despawns) do
        local eid = slots[eid_slot]
        local e = eid and S.ents[eid]
        slots[eid_slot] = nil
        if e then
            S.ent_hash = add32(S.ent_hash, 4294967296 - e.term)
            S.ents[eid] = nil
            S.nents = S.nents - 1
            st.despawns = st.despawns + 1
            S.stats.despawns = S.stats.despawns + 1
            if e.uid then
                local ent = entities.get(e.uid)
                if ent then pcall(ent.despawn, ent) end
            end
        else
            st.unknown_slot = st.unknown_slot + 1
        end
    end
    for _, sp in ipairs(m.spawns) do
        local old = S.ents[sp.eid]
        if old then S.ent_hash = add32(S.ent_hash, 4294967296 - old.term) else S.nents = S.nents + 1 end
        local e = {eid = sp.eid, kind = sp.kind, def = sp.def, name = sp.name, slot = sp.slot,
                   qx = sp.pos.x, qy = sp.pos.y, qz = sp.pos.z, rx = sp.rot.x, ry = sp.rot.y, rz = sp.rot.z,
                   alpha = 1, uid = old and old.uid}
        deq(e)
        e.from = {x = e.pos.x, y = e.pos.y, z = e.pos.z}
        e.shown = {x = e.pos.x, y = e.pos.y, z = e.pos.z}
        e.term = U.entity_term(e.eid, e.pos, e.rot)
        S.ent_hash = add32(S.ent_hash, e.term)
        if not e.uid then
            local ok, ent = pcall(entities.spawn, engine_def(sp.def), {e.pos.x, e.pos.y, e.pos.z})
            if ok and ent then e.uid = ent:get_uid() end
        end
        S.ents[sp.eid] = e
        slots[sp.slot] = sp.eid
        st.spawns = st.spawns + 1
        S.stats.spawns = S.stats.spawns + 1
    end
    for _, mv in ipairs(m.moves) do
        local eid = slots[mv.slot]
        local e = eid and S.ents[eid]
        if not e then
            st.unknown_slot = st.unknown_slot + 1
        else
            st.moves = st.moves + 1
            S.ent_hash = add32(S.ent_hash, 4294967296 - e.term)
            local moved = false
            local d = mv.d8 or mv.d16
            if mv.pa then
                moved = mv.pa.x ~= e.qx or mv.pa.y ~= e.qy or mv.pa.z ~= e.qz
                e.qx, e.qy, e.qz = mv.pa.x, mv.pa.y, mv.pa.z
            elseif d then
                e.qx, e.qy, e.qz = e.qx + d.x, e.qy + d.y, e.qz + d.z
                moved = true
            end
            if mv.rx then e.rx = mv.rx end
            if mv.ry then e.ry = mv.ry end
            if mv.rz then e.rz = mv.rz end
            local shown = e.shown
            deq(e)
            if moved then
                e.from = {x = shown.x, y = shown.y, z = shown.z}
                e.alpha = 0
            end
            e.term = U.entity_term(e.eid, e.pos, e.rot)
            S.ent_hash = add32(S.ent_hash, e.term)
        end
    end
end

function M.status()
    local s = M.stats
    return string.format("delta_msgs=%d delta_spawns=%d delta_moves=%d delta_despawns=%d delta_keyframes=%d " ..
        "delta_unknown_slot=%d", s.msgs, s.spawns, s.moves, s.despawns, s.keyframes, s.unknown_slot)
end

return M
