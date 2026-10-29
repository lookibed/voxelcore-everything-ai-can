-- olife_world:move_auth — wave 4c: authoritative predicted movement.
-- The client predicts with olife_proto:movement and sends MoveInput(seq, keys, yaw, pitch) once per its tick; the
-- world runs the SAME step for every input in seq order (phase 1, on arrival) on the session's movement state; the
-- input carries the hash of the client's predicted state after it: equal -> PlayerAck(ack) at most every 4 ticks,
-- different (or dropped/reset) -> PlayerState(ack, pos, vel, flags) in phase 4 of the same tick. The client adopts
-- the server state and replays the inputs after `ack`.
-- Anti-cheat: input rate bucket (20 inputs per second of real time, burst `move_burst`) — a speed hack that sends inputs faster
-- than real time loses the excess (acked as dropped, the client gets corrected); seq must increase; unknown key bits
-- are cut and counted; a step that moves more than `max_step` blocks (the integrator cannot, so only a bug or a
-- server-side teleport) is reverted and sent with the reset flag; positions are never taken from the client.
local Mv = require "olife_proto:movement"
local U = require "olife_proto:util"
local net = require "olife_world:net"

local M = {}
local srv, S, cfg
local sqrt, abs = math.sqrt, math.abs

M.stats = {inputs = 0, simulated = 0, dropped_rate = 0, stale = 0, bad_keys = 0, teleports = 0, states_sent = 0,
           acks_sent = 0, hash_mismatch = 0, state_bytes = 0, legacy_sync = 0}

function M.init(server)
    srv, S, cfg = server, server.S, server.cfg
    cfg.move_burst = cfg.move_burst or 10
    cfg.max_step = cfg.max_step or 3.0
    cfg.ack_every = cfg.ack_every or 4
end

-- a session starts (Welcome sent): movement state at the restored/spawn position, standing (not flying)
function M.on_attach(sess)
    sess.mv = Mv.new_state(sess.pos.x, sess.pos.y, sess.pos.z, false)
    sess.mv_ack, sess.mv_tokens, sess.mv_dirty, sess.mv_reset, sess.mv_last_sent = 0, cfg.move_burst, true, false, -100
    sess.mv_inputs = 0
end

-- legacy PlayerInput accepted a position: keep the movement state in step (the session may mix both)
function M.on_legacy(sess)
    local st = sess.mv
    if not st then return end
    st.x, st.y, st.z = U.fround(sess.pos.x), U.fround(sess.pos.y), U.fround(sess.pos.z)
    st.vx, st.vy, st.vz = 0, 0, 0
    sess.mv_reset = true
    M.stats.legacy_sync = M.stats.legacy_sync + 1
end

function M.on_input(sess, m)
    local st = sess.mv
    if not st then return end
    M.stats.inputs = M.stats.inputs + 1
    if m.seq <= sess.mv_ack then
        M.stats.stale = M.stats.stale + 1
        return
    end
    sess.mv_ack, sess.mv_dirty = m.seq, true
    sess.mv_inputs = sess.mv_inputs + 1
    if sess.mv_tokens < 1 then                       -- faster than real time: drop (the client will be corrected)
        M.stats.dropped_rate = M.stats.dropped_rate + 1
        sess.mv_mismatch = true
        return
    end
    sess.mv_tokens = sess.mv_tokens - 1
    local keys = m.keys
    if bit.band(keys, bit.bnot(Mv.KEYS_MASK)) ~= 0 then
        M.stats.bad_keys = M.stats.bad_keys + 1
        keys = bit.band(keys, Mv.KEYS_MASK)
    end
    local px, py, pz = st.x, st.y, st.z
    Mv.step(st, keys, m.yaw, m.pitch)
    M.stats.simulated = M.stats.simulated + 1
    local dx, dy, dz = st.x - px, st.y - py, st.z - pz
    if dx * dx + dy * dy + dz * dz > cfg.max_step * cfg.max_step or st.y < -64 or st.y > 400 then
        M.stats.teleports = M.stats.teleports + 1
        st.x, st.y, st.z, st.vx, st.vy, st.vz = px, py, pz, 0, 0, 0
        sess.mv_reset = true
    end
    -- the client's predicted hash for this input: equal -> a PlayerAck is enough, else the full PlayerState
    if Mv.hash(st, U.fnv_ints) ~= m.hash then
        sess.mv_mismatch = true
        M.stats.hash_mismatch = M.stats.hash_mismatch + 1
    end
    sess.pos.x, sess.pos.y, sess.pos.z = st.x, st.y, st.z
    sess.rot.x, sess.rot.y, sess.rot.z = m.yaw, m.pitch, 0
    sess.last_input_tick = S.tick
    player.set_pos(sess.pid, st.x, st.y, st.z)
end

-- phase 3: refill the input buckets by REAL time (20 inputs/s): the world ticks at ~19.7/s (measured), a client at
-- its own 20/s clock — a per-tick refill drained the burst in ~30 s and dropped honest inputs (seen 02.10)
local last_refill
function M.step_world()
    local now = U.now_ms()
    local add = last_refill and (now - last_refill) / 50 or 1
    last_refill = now
    for _, s in pairs(S.sessions) do
        if s.mv then s.mv_tokens = math.min(cfg.move_burst, s.mv_tokens + add) end
    end
    M.disturb_step()
end

-- phase 4: PlayerState when the world's state differs from the client's prediction (its hash in MoveInput), was
-- reset, or inputs were dropped; otherwise a PlayerAck (ack only) at most every `ack_every` ticks — the client keeps
-- its history until then. Legacy (PlayerInput) sessions get neither.
function M.send(sess)
    if not sess.mv or sess.mv_inputs == 0 then return end
    local st = sess.mv
    local n
    if sess.mv_mismatch or sess.mv_reset then
        local flags = Mv.flags(st) + (sess.mv_reset and 4 or 0)
        n = net.send_client(sess.gw, sess.sid, "PlayerState", {ack = sess.mv_ack, tick = S.tick,
            pos = {x = st.x, y = st.y, z = st.z}, vel = {x = st.vx, y = st.vy, z = st.vz}, flags = flags})
        M.stats.states_sent = M.stats.states_sent + 1
    elseif sess.mv_dirty and S.tick - sess.mv_last_sent >= cfg.ack_every then
        n = net.send_client(sess.gw, sess.sid, "PlayerAck", {ack = sess.mv_ack, tick = S.tick})
        M.stats.acks_sent = M.stats.acks_sent + 1
    else
        return
    end
    sess.mv_dirty, sess.mv_reset, sess.mv_mismatch, sess.mv_last_sent = false, false, false, S.tick
    M.stats.state_bytes = M.stats.state_bytes + n
    sess.bytes = sess.bytes + n
end

-- olife_prediction: a controlled source of mispredictions — the world itself changes blocks in front of every
-- predicting player (a 2-high stone wall in the cell 0.9 block ahead along its velocity: contact within 0..2 ticks),
-- keeps it `disturb` ticks, removes it and puts the next one `disturb` ticks later; a client learns about it one RTT later, so with latency its prediction walks through the
-- wall and is corrected. Set by `olife.disturb <ticks>` (0 = off).
local stone_id
function M.disturb_step()
    local every = cfg.disturb or 0
    if every <= 0 then return end
    stone_id = stone_id or block.index("base:stone")
    for _, s in pairs(S.sessions) do
        local st = s.mv
        if st and s.mv_inputs > 0 then
            if s.dist_cells then
                if S.tick >= s.dist_until then                 -- remove the wall, next one after `every` ticks
                    for _, c in ipairs(s.dist_cells) do
                        if block.get(c[1], c[2], c[3]) == stone_id then srv.apply_block(c[1], c[2], c[3], 0, 0, 0) end
                    end
                    s.dist_cells, s.dist_next = nil, S.tick + every
                end
            elseif S.tick >= (s.dist_next or 0) then          -- try every tick until the player walks somewhere free
                local vx, vz = st.vx, st.vz
                local l = math.sqrt(vx * vx + vz * vz)
                if l > 0.5 then
                    local x = math.floor(st.x + vx / l * 0.9)
                    local z = math.floor(st.z + vz / l * 0.9)
                    local y = math.floor(st.y + 0.01)
                    local cells = {}
                    for dy = 0, 1 do
                        if block.get(x, y + dy, z) == 0 and not Mv.overlaps_cell(st, x, y + dy, z) then
                            cells[#cells + 1] = {x, y + dy, z}
                        end
                    end
                    if #cells == 2 then
                        for _, c in ipairs(cells) do srv.apply_block(c[1], c[2], c[3], stone_id, 0, 0) end
                        s.dist_cells, s.dist_until = cells, S.tick + every
                        M.stats.disturbs = (M.stats.disturbs or 0) + 1
                    end
                end
            end
        end
    end
end

-- exact movement state of every session (olife_prediction compares it with the client's prediction)
function M.state_line(sess)
    local st = sess.mv
    if not st then return string.format("[olife_world] move eid=%d none", sess.eid) end
    return string.format("[olife_world] move eid=%d name=%s ack=%d inputs=%d hash=%d pos=%.9g,%.9g,%.9g vel=%.9g,%.9g,%.9g flags=%d",
        sess.eid, sess.name, sess.mv_ack, sess.mv_inputs, Mv.hash(st, U.fnv_ints), st.x, st.y, st.z, st.vx, st.vy,
        st.vz, Mv.flags(st))
end

function M.status()
    local s = M.stats
    return string.format("mv_inputs=%d mv_sim=%d mv_drop=%d mv_stale=%d mv_badkeys=%d mv_teleports=%d mv_states=%d " ..
        "mv_acks=%d mv_hash_mismatch=%d mv_bytes=%d mv_disturbs=%d", s.inputs, s.simulated, s.dropped_rate, s.stale,
        s.bad_keys, s.teleports, s.states_sent, s.acks_sent, s.hash_mismatch, s.state_bytes, s.disturbs or 0)
end

return M
