-- olife_client:predict — wave 4c: client-side prediction with server reconciliation.
-- Every logical client tick (50 ms): the keys and look of this tick (bot driver or input bindings) are applied
-- locally with olife_proto:movement (the same step the world runs) and sent as MoveInput(seq, keys, yaw, pitch); the
-- input and the predicted state after it are kept by seq. PlayerState(ack, pos, vel, flags) from the world is
-- compared with the prediction for `ack`: equal (both sides round to f32 after every step, so a correct prediction
-- is bit-exact) -> nothing to do; different by more than `threshold` -> adopt the server state and replay the
-- inputs after `ack` (their predicted states are rewritten). The visual position is the predicted one plus an offset
-- that takes the jump (old prediction - new) and decays exponentially (tau 100 ms); a jump over `snap_max` blocks or a
-- server reset is shown at once (hard snap). Divergence statistics are kept for the lab (olife_prediction).
local Mv = require "olife_proto:movement"
local U = require "olife_proto:util"

local M = {}
local sqrt, exp, abs, max = math.sqrt, math.exp, math.abs, math.max

local P = {
    st = nil, hist = {}, seq = 0, ack = 0, off = {x = 0, y = 0, z = 0}, blocked = false,
    threshold = 1e-4, tau = 0.1, snap_max = 4.0,
}
M.P = P

local function new_stats()
    return {inputs = 0, states = 0, unknown_ack = 0, mismatches = 0, corrections = 0, hard = 0, replayed = 0,
            err = {}, snap = {}, replay_len = {}, t0 = time.uptime(), max_unacked = 0}
end
P.stats = new_stats()

function M.reset_stats()
    P.stats = new_stats()
    return "[olife_client] predict stats reset"
end

function M.active() return P.st ~= nil end

-- Welcome: start from the spawn the world gave (it is f32 already), standing
function M.on_welcome(pos)
    P.st = Mv.new_state(pos.x, pos.y, pos.z, false)
    P.hist, P.seq, P.ack = {}, 0, 0
    P.off.x, P.off.y, P.off.z = 0, 0, 0
end

function M.stop()
    P.st = nil
end

-- one logical tick: predict + send. S.keys / S.yaw / S.pitch are this tick's input.
function M.tick(S, send)
    local st = P.st
    if not st then return end
    P.seq = P.seq + 1
    local keys = bit.band(S.keys or 0, Mv.KEYS_MASK)
    local yaw, pitch = U.fround((S.yaw or 0) % 360), U.fround(S.pitch or 0)
    local _, info = Mv.step(st, keys, yaw, pitch)
    P.blocked = info.collided_h
    P.hist[P.seq] = {keys = keys, yaw = yaw, pitch = pitch, s = Mv.copy(st)}
    send("MoveInput", {seq = P.seq, keys = keys, yaw = yaw, pitch = pitch, hash = Mv.hash(st, U.fnv_ints)})
    P.stats.inputs = P.stats.inputs + 1
    local un = P.seq - P.ack
    if un > P.stats.max_unacked then P.stats.max_unacked = un end
    S.pos.x, S.pos.y, S.pos.z = st.x, st.y, st.z
    S.rot.x, S.rot.y, S.rot.z = yaw, pitch, 0
end

local function push(list, v)
    if #list < 50000 then list[#list + 1] = v end
end

function M.on_state(S, m)
    local st = P.st
    if not st then return end
    local stats = P.stats
    stats.states = stats.states + 1
    local h = P.hist[m.ack]
    local reset = bit.band(m.flags, 4) ~= 0
    local err
    if h then
        local s = h.s
        local dx, dy, dz = s.x - m.pos.x, s.y - m.pos.y, s.z - m.pos.z
        err = sqrt(dx * dx + dy * dy + dz * dz)
        local ev = max(abs(s.vx - m.vel.x), abs(s.vy - m.vel.y), abs(s.vz - m.vel.z))
        if ev > err then err = ev end
        if Mv.flags(s) ~= bit.band(m.flags, 3) and err <= P.threshold then err = P.threshold * 2 end
        push(stats.err, err)
    elseif m.ack == 0 and P.seq == 0 then
        err = 0                                   -- periodic state before our first input
    else
        stats.unknown_ack = stats.unknown_ack + 1
        err = math.huge
    end
    for s = P.ack + 1, m.ack do P.hist[s] = nil end
    if m.ack > P.ack then P.ack = m.ack end
    if not reset and err <= P.threshold then return end
    -- mismatch: adopt the server state for `ack` and replay the unacknowledged inputs
    stats.mismatches = stats.mismatches + 1
    local px, py, pz = st.x, st.y, st.z
    Mv.from_net(m.pos, m.vel, m.flags, st)
    local n = 0
    for s = m.ack + 1, P.seq do
        local r = P.hist[s]
        if r then
            local _, info = Mv.step(st, r.keys, r.yaw, r.pitch)
            Mv.copy(st, r.s)
            P.blocked = info.collided_h
            n = n + 1
        end
    end
    local dx, dy, dz = px - st.x, py - st.y, pz - st.z
    local snap = sqrt(dx * dx + dy * dy + dz * dz)
    stats.corrections = stats.corrections + 1
    stats.replayed = stats.replayed + n
    push(stats.replay_len, n)
    push(stats.snap, snap)
    if reset or snap > P.snap_max then
        stats.hard = stats.hard + 1
        P.off.x, P.off.y, P.off.z = 0, 0, 0
    else
        P.off.x, P.off.y, P.off.z = P.off.x + dx, P.off.y + dy, P.off.z + dz
    end
    S.pos.x, S.pos.y, S.pos.z = st.x, st.y, st.z
end

-- PlayerAck: the world's state after `ack` hashed like our prediction — drop the history up to it
function M.on_ack(S, m)
    if not P.st then return end
    P.stats.acks = (P.stats.acks or 0) + 1
    push(P.stats.err, 0)                         -- an ack = the prediction at `ack` was exact
    for s = P.ack + 1, m.ack do P.hist[s] = nil end
    if m.ack > P.ack then P.ack = m.ack end
end

-- per frame: decay the visual offset, return the shown position
function M.frame(dt)
    local st = P.st
    if not st then return nil end
    local k = exp(-dt / P.tau)
    local o = P.off
    o.x, o.y, o.z = o.x * k, o.y * k, o.z * k
    if abs(o.x) + abs(o.y) + abs(o.z) < 1e-4 then o.x, o.y, o.z = 0, 0, 0 end
    return st.x + o.x, st.y + o.y, st.z + o.z
end

local function pct(list, p)
    if #list == 0 then return 0 end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    return s[math.max(1, math.min(#s, math.floor(p * (#s - 1) + 1.5)))]
end

function M.summary()
    local s = P.stats
    local minutes = math.max((time.uptime() - s.t0) / 60, 1e-6)
    local finite = {}
    for _, v in ipairs(s.err) do finite[#finite + 1] = v end
    return {inputs = s.inputs, states = s.states, mismatches = s.mismatches, corrections = s.corrections,
            hard = s.hard, unknown_ack = s.unknown_ack, replayed = s.replayed, minutes = minutes,
            corr_per_min = s.corrections / minutes,
            err_p50 = pct(finite, 0.5), err_p95 = pct(finite, 0.95), err_max = pct(finite, 1.0),
            err_nonzero = (function() local n = 0 for _, v in ipairs(finite) do if v > 0 then n = n + 1 end end return n end)(),
            snap_p50 = pct(s.snap, 0.5), snap_p95 = pct(s.snap, 0.95), snap_max = pct(s.snap, 1.0),
            replay_p50 = pct(s.replay_len, 0.5), replay_max = pct(s.replay_len, 1.0), max_unacked = s.max_unacked,
            seq = P.seq, ack = P.ack, hash = P.st and Mv.hash(P.st, U.fnv_ints) or 0,
            pos = P.st and {P.st.x, P.st.y, P.st.z} or nil}
end

function M.status()
    if not P.st then return "pred=off" end
    local x = M.summary()
    return string.format("pred=on pred_acks=%d pred_inputs=%d pred_states=%d pred_mismatch=%d pred_corr=%d pred_hard=%d " ..
        "pred_unknown_ack=%d pred_corr_min=%.2f pred_err_p50=%.6g pred_err_p95=%.6g pred_err_max=%.6g pred_err_nz=%d " ..
        "pred_snap_p50=%.4f pred_snap_p95=%.4f pred_snap_max=%.4f pred_replay_p50=%d pred_replay_max=%d " ..
        "pred_unacked_max=%d pred_seq=%d pred_ack=%d pred_hash=%d pred_pos=%.9g,%.9g,%.9g",
        P.stats.acks or 0, x.inputs, x.states, x.mismatches, x.corrections, x.hard, x.unknown_ack, x.corr_per_min, x.err_p50, x.err_p95,
        x.err_max == math.huge and -1 or x.err_max, x.err_nonzero, x.snap_p50, x.snap_p95, x.snap_max, x.replay_p50,
        x.replay_max, x.max_unacked, x.seq, x.ack, x.hash, x.pos[1], x.pos[2], x.pos[3])
end

return M
