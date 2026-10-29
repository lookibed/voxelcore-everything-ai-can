-- olife_world:sandbox — bridge world <-> sandbox service (OLIFE_SANDBOX.md §7; <olife-src>/sandboxd).
-- Pipeline per tick: phase 2 apply(TickResult of tick N-1, validated) ... phase 4 send_input(TickInput N).
-- The world never blocks on the service: a result is applied when it arrives (late ones are counted); more than
-- `max_behind` ticks in flight -> inputs are skipped (backpressure). Service down -> scripted entities freeze,
-- the world keeps ticking, reconnect every 2 s.
-- Transports: "jsonl" — JSON lines exactly as sandboxd speaks today ({"type":"tick",...}); "bin" — the generated
-- binary contract olife_proto:sandbox (same shapes). Actions are validated here (finite, step, home radius, reach,
-- rate) — the sandbox is not trusted either.
local SB = require "olife_proto:sandbox"
local U = require "olife_proto:util"
local MT = require "olife_world:sbmeter"      -- wave 3a: meters, flood guard, view index, dump (real sandboxd)
local ED = require "olife_world:editor"       -- wave 4a: bench code/status/console (src, runnable, text, results)
local PF = require "olife_world:prof"         -- wave 5p profiler
local API = require "olife_world:mobapi"      -- UX A3: mob script API (actions beyond the core ops, queries, fields)

local M = {}
local cfg, server
local st = {state = "off", sock = nil, retry_at = 0, buf = "", fr = nil, out = nil, sent = 0, results = 0, late = 0,
            skipped = 0, last_result_tick = 0, last_sent_tick = 0, bytes_out = 0, bytes_in = 0, loaded = {},
            load_errors = 0, applied = {}, rejected = {}, pending = {}, feedback = {}, fuel = 0, errors = 0,
            last_error = nil, connects = 0, said = {}, prints = 0,
            -- stage 6 (supervisor): last TickResult summary and per-owner meter (written to the supervisor state file)
            last_result = nil, owners = {}, reconnect_req = false}
M.st = st
local MAX_BEHIND = 3
local NO_EVENTS = {}                          -- wave 5p: shared empty events_json (read-only for the encoder)
local finite = function(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function log(fmt, ...) print("[olife_world] sandbox: " .. string.format(fmt, ...)) end

-- wave 4a: a bench runs its own code (ED.src), legacy scripted entities the pack script sandbox/<script>.lua
local function script_src(e) return ED.src(e) end

local function send_line(t)
    local line = json.tostring(t) .. "\n"
    st.out[#st.out + 1] = line
end

local function send_bin(name, msg)
    SB.append_frame(st.out, name, msg)
end

local function scripted()
    local l = {}
    for _, e in pairs(server.S.ents) do
        if ED.runnable(e) then l[#l + 1] = e end      -- wave 4a: stopped/errored benches get no TickInput
    end
    table.sort(l, function(a, b) return a.eid < b.eid end)
    return l
end

local function on_connected()
    st.state = "connected"
    st.connects = st.connects + 1
    st.sock:set_nodelay(true)
    st.buf, st.fr = "", SB.framer()
    st.out = cfg.sandbox_proto == "bin" and Bytearray() or {}
    st.loaded = {}
    if cfg.sandbox_proto == "bin" then
        send_bin("Hello", {proto = SB.version, runtime = "world"})
    else
        send_line({type = "hello", proto = 1})
    end
    -- UX A3: the scripts are loaded when the service's Hello reply arrives: a service with proto >= 2 gets LoadKeep
    -- (an entity it already runs with the same source keeps its Lua state: the world restarted, the service did not)
    st.svc_proto, st.await_hello, st.hello_deadline = nil, true, server.S.tick + 40
    for _, e in ipairs(scripted()) do st.loaded[e.eid] = "pending" end
    log("connected to 127.0.0.1:%d (%s), %d scripts to load after hello", cfg.sandbox_port, cfg.sandbox_proto,
        #scripted())
end

-- UX A3: load every runnable script (after the Hello reply, or 2 s without one: plain Load)
local function load_all()
    st.await_hello = false
    local keep = (st.svc_proto or 1) >= 2
    local n = 0
    for _, e in ipairs(scripted()) do
        if cfg.sandbox_proto == "bin" then
            send_bin(keep and "LoadKeep" or "Load", {owner = e.owner, eid = e.eid, src = script_src(e)})
        else
            send_line({type = "load", owner = e.owner, eid = e.eid, src = script_src(e), keep = keep or nil})
        end
        st.loaded[e.eid] = "pending"
        API.on_load(e)
        n = n + 1
    end
    log("loading %d scripts (%s)", n, keep and "LoadKeep" or "Load")
end

local function connect()
    st.state = "connecting"
    st.sock = network.tcp_connect("127.0.0.1", cfg.sandbox_port, function(s)
        on_connected()
    end, function(s, err)
        st.state = "down"
        st.last_error = tostring(err)
        st.retry_at = server.S.tick + 40
    end)
end

function M.init(c, srv)
    cfg, server = c, srv
    cfg.sandbox_proto = cfg.sandbox_proto or "jsonl"
    if (cfg.sandbox_port or 0) > 0 then connect() end
end

local function reject(eid, op, reason, code)
    st.rejected[reason] = (st.rejected[reason] or 0) + 1
    server.S.stats.sandbox_rejected = server.S.stats.sandbox_rejected + 1
    local fb = st.feedback[eid]
    if not fb then fb = {}; st.feedback[eid] = fb end
    if #fb < 16 then fb[#fb + 1] = {type = "rejected", op = op, reason = reason, code = code} end   -- code: UX A4 store codes
end

-- UX A4: an event for the entity's script in its next TickInput (bounded like the rejections: 16 per tick)
function M.event(eid, ev)
    local fb = st.feedback[eid]
    if not fb then fb = {}; st.feedback[eid] = fb end
    if #fb < 16 then fb[#fb + 1] = ev; return true end
    return false
end

local function ok_applied(op)
    st.applied[op] = (st.applied[op] or 0) + 1
    server.S.stats.sandbox_applied = server.S.stats.sandbox_applied + 1
end

local function vec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v[1] or v.x, v[2] or v.y, v[3] or v.z
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    return x, y, z
end

-- validate and apply one action of entity e (phase 2)
local function apply_action(e, a, tick, rtick)
    local op = a.op
    local why = MT.guard(e, op, rtick or tick)   -- <= MT.MAX_ACTS per entity and result; set_pos/rot/vel once
    if why then return reject(e.eid, tostring(op), why) end
    if e.op_lim then                             -- UX A2: per-mob limits of an operator (/limits <mob> actions|text)
        why = require("olife_world:ops").check_action(e, op, a, rtick or tick)
        if why then return reject(e.eid, tostring(op), why) end
    end
    if (op == "set_pos" or op == "set_vel") and ED.is_held(e) then return reject(e.eid, op, "held") end
    if op == "set_pos" then
        local x, y, z = vec(a.pos)
        if not x then return reject(e.eid, op, "bad vec") end
        local dx, dy, dz = x - e.pos.x, y - e.pos.y, z - e.pos.z
        if dx * dx + dy * dy + dz * dz > 4 then return reject(e.eid, op, "step > 2") end
        local sp = server.S.spawn
        if (x - sp.x) ^ 2 + (z - sp.z) ^ 2 > 48 * 48 or y < 0 or y > 255 then return reject(e.eid, op, "out of area") end
        e.pos.x, e.pos.y, e.pos.z = x, y, z
        return ok_applied(op)
    elseif op == "set_rot" then
        local x, y, z = vec(a.rot)
        if not x then return reject(e.eid, op, "bad vec") end
        e.rot.x, e.rot.y, e.rot.z = x, y, z
        return ok_applied(op)
    elseif op == "set_vel" then
        local x, y, z = vec(a.vel)
        if not x then return reject(e.eid, op, "bad vec") end
        e.vel.x, e.vel.y, e.vel.z = x, y, z
        return ok_applied(op)
    elseif op == "block.set" then
        local x, y, z = vec(a.pos)
        if not x then return reject(e.eid, op, "bad vec") end
        local bst = a.state ~= nil and math.floor(tonumber(a.state) or -1) or 0      -- UX A3: block.set(..., state)
        if bst < 0 or bst > 65535 then return reject(e.eid, op, "bad state") end
        if not API.block_set_allowed(e) then return reject(e.eid, op, "forbidden") end
        x, y, z = math.floor(x), math.floor(y), math.floor(z)
        if (x + 0.5 - e.pos.x) ^ 2 + (y + 0.5 - e.pos.y) ^ 2 + (z + 0.5 - e.pos.z) ^ 2 > 36 then
            return reject(e.eid, op, "reach")
        end
        if (e.next_block_tick or 0) > tick then return reject(e.eid, op, "rate") end
        local okid, id = pcall(block.index, tostring(a.id))
        if not okid or type(id) ~= "number" or id < 0 then return reject(e.eid, op, "bad block") end
        if block.get(x, y, z) == -1 then return reject(e.eid, op, "not loaded") end
        e.next_block_tick = tick + 10
        server.apply_block(x, y, z, id, bst, e.eid)
        return ok_applied(op)
    elseif op == "say" or op == "print" or op == "oprint" then
        local txt = tostring(a.text or "")
        if ED.is_bench(e) then
            -- wave 4a: bench console (bucket 5/s, burst 10) -> ring + subscribers' ConsoleDelta
            if not ED.text_allowed(e) then return reject(e.eid, op, "rate") end
            ED.console_add(e, 0, txt)
        else
            if (st.said[e.eid] or 0) > tick then return reject(e.eid, op, "rate") end
            st.said[e.eid] = tick + 20
        end
        st.prints = st.prints + 1
        MT.text(e, txt)
        if st.prints <= 50 then log("%s eid=%d: %s", op, e.eid, txt:sub(1, 160)) end
        return ok_applied(op)
    elseif op == "canvas.commit" then
        -- UX A4: the script's canvas (raw RGBA) -> PNG in the owner's store -> entity slot (EntityAssets to viewers)
        local code, reason, sha = require("olife_world:storenet").canvas_action(e, a)
        if code ~= 0 then return reject(e.eid, op, reason or ("store code " .. tostring(code)), code) end
        M.event(e.eid, {type = "canvas", slot = tostring(a.slot or ""), sha = sha, code = 0})
        return ok_applied(op)
    else
        -- UX A3: the mob script API (appearance, skeleton, animation, sound, text3d, block.fill, memory.set)
        local why2 = API.apply(e, a, tick)
        if why2 then return reject(e.eid, tostring(op), why2) end
        return ok_applied(op)
    end
end

local function handle_result(r)
    st.results = st.results + 1
    if r.tick and r.tick < server.S.tick - 1 then st.late = st.late + 1; if PF.on then PF.inc("late") end end
    if PF.on then PF.inc("results") end
    st.last_result_tick = r.tick or st.last_result_tick
    local sum = {tick = r.tick, at_world_tick = server.S.tick, entities = 0, actions = 0, applied = 0, rejected = 0,
                 fuel = 0, statuses = {}}
    local SS = server.S.stats
    MT.result_begin(r, server.S.tick)
    for _, er in ipairs(r.entities or {}) do
        local e = server.S.ents[er.eid]
        if e and e.kind == 3 then
            e.sb_status = er.status
            local fuel = (er.meter and er.meter.fuel) or 0
            if fuel ~= 0 then st.fuel = st.fuel + fuel end
            if er.status == "error" or er.status == "killed" then
                st.errors = st.errors + 1
                if st.errors <= 20 then log("eid=%d %s: %s", er.eid, er.status, tostring(er.error)) end
            end
            local a0, r0 = SS.sandbox_applied, SS.sandbox_rejected
            local px, py, pz = e.pos.x, e.pos.y, e.pos.z
            for _, a in ipairs(er.actions or {}) do apply_action(e, a, server.S.tick, r.tick) end
            API.queries(e, er)                       -- UX A3: queries -> answers in the next TickInput
            MT.entity(e, er, px, py, pz, SS.sandbox_applied - a0, SS.sandbox_rejected - r0)
            ED.on_result(e, er, SS.sandbox_applied - a0, SS.sandbox_rejected - r0)
            local ow = st.owners[e.owner or 0]
            if not ow then ow = {fuel = 0, actions = 0, rejected = 0}; st.owners[e.owner or 0] = ow end
            ow.fuel = ow.fuel + fuel
            ow.actions = ow.actions + (SS.sandbox_applied - a0)
            ow.rejected = ow.rejected + (SS.sandbox_rejected - r0)
            sum.entities = sum.entities + 1
            sum.actions = sum.actions + #(er.actions or {})
            sum.applied = sum.applied + (SS.sandbox_applied - a0)
            sum.rejected = sum.rejected + (SS.sandbox_rejected - r0)
            sum.fuel = sum.fuel + fuel
            local k = tostring(er.status or "?")
            sum.statuses[k] = (sum.statuses[k] or 0) + 1
        end
    end
    st.last_result = sum
    MT.result_end(r)
end

-- binary TickResult action union kind -> the jsonl op (the decoded action is used in place, see M.apply)
local BIN_OPS = {SetPos = "set_pos", SetRot = "set_rot", SetVel = "set_vel", BlockSet = "block.set", Spawn = "spawn",
                 Say = "say", Print = "print", OPrint = "oprint", CanvasCommit = "canvas.commit"}   -- + UX A4

local function handle_msg(t)
    local ty = t.type
    if ty == "tick_result" then
        handle_result(t)
    elseif ty == "load_result" then
        st.loaded[t.eid] = t.ok and "ok" or "error"
        if not t.ok then st.load_errors = st.load_errors + 1; log("load eid=%s failed: %s", tostring(t.eid), tostring(t.error)) end
        ED.on_load_result(t.eid, t.ok, t.error)
    elseif ty == "hello" then
        log("service hello: proto=%s runtime=%s", tostring(t.proto), tostring(t.runtime))
        st.runtime = t.runtime
        st.svc_proto = tonumber(t.proto) or 1
        if st.await_hello then load_all() end
    elseif ty == "error" then
        st.errors = st.errors + 1
        st.last_error = t.message
        if st.errors <= 20 then log("service error: %s", tostring(t.message)) end
    end
end

-- phase 2
function M.apply(tick)
    if st.reconnect_req then
        -- supervisor: the service was restarted (same port) -> drop the old socket, connect now, not in 2 s
        st.reconnect_req = false
        if cfg.sandbox_port > 0 then
            if st.sock and st.state ~= "down" then pcall(function() st.sock:close() end) end
            st.state, st.retry_at = "down", tick
            log("reconnect requested (supervisor)")
        end
    end
    if st.state == "down" and cfg.sandbox_port > 0 and tick >= st.retry_at then connect() end
    if st.state ~= "connected" then return end
    if st.await_hello and tick >= (st.hello_deadline or 0) then load_all() end    -- UX A3: no Hello reply in 2 s
    local pf = PF.on
    local pt = pf and PF.now()
    local data = st.sock:recv(1048576)
    if data == nil then
        st.state = "down"
        st.retry_at = tick + 40
        log("connection lost; scripted entities frozen")
        return
    end
    if #data > 0 then st.bytes_in = st.bytes_in + #data end
    if cfg.sandbox_proto == "bin" then
        st.fr:feed(data)
        if pf then local x = PF.now(); PF.add("sb_recv", x - pt); pt = x end
        while true do
            local name, m = SB.read(st.fr)
            if pf then local x = PF.now(); PF.add("sb_decode", x - pt); pt = x end
            if name == nil then break end
            if name == false then
                log("bad frame from service: %s", tostring(m))
                st.sock:close()
                st.state = "down"
                st.retry_at = tick + 40
                return
            end
            if name == "TickResult" then
                -- wave 5p: the decoded actions are reused in place (apply_action reads op, pos/rot/vel as x/y/z or
                -- [1..3], id, text): a converted copy of every action cost 2 tables per action per tick
                for _, er in ipairs(m.entities) do
                    for _, a in ipairs(er.actions) do
                        local k = a.kind
                        if k == "Ext" then
                            -- UX A3: script API action = op + the whole action as JSON (a.op is already the op)
                            local okj, t = pcall(json.parse, a.json)
                            if okj and type(t) == "table" then
                                for kk, vv in pairs(t) do if kk ~= "op" then a[kk] = vv end end
                            end
                        else
                            a.op = BIN_OPS[k] or k
                        end
                        if k == "BlockSet" then a.pos = a end
                    end
                end
                if pf then local x = PF.now(); PF.add("sb_conv", x - pt); pt = x end
                handle_result(m)
                if pf then local x = PF.now(); PF.add("sb_apply", x - pt); pt = x end
            elseif name == "LoadResult" then
                handle_msg({type = "load_result", eid = m.eid, ok = m.ok, error = m.error})
            elseif name == "Hello" then
                handle_msg({type = "hello", proto = m.proto, runtime = m.runtime})
            elseif name == "Error" then
                handle_msg({type = "error", message = m.message})
            end
        end
        return
    end
    if #data > 0 then st.buf = st.buf .. utf8.tostring(data) end
    while true do
        local i = st.buf:find("\n", 1, true)
        if not i then break end
        local line = st.buf:sub(1, i - 1)
        st.buf = st.buf:sub(i + 1)
        local ok, t = pcall(json.parse, line)
        if ok and type(t) == "table" then handle_msg(t) else st.errors = st.errors + 1 end
    end
    if #st.buf > 4194304 then
        log("service line too long; dropping connection")
        st.sock:close()
        st.state = "down"
    end
end

-- phase 4
function M.send_input(tick, ents)
    if st.state ~= "connected" then return end
    if st.last_sent_tick - st.last_result_tick >= MAX_BEHIND and st.sent > 0 then
        st.skipped = st.skipped + 1
        if PF.on then PF.inc("skipped") end
        return
    end
    local list = {}
    local pf = PF.on
    local pt = pf and PF.now()
    local bin = cfg.sandbox_proto == "bin"
    -- grid, 3D radius MT.VIEW_R, at most MT.VIEW_MAX (was all-pairs XZ, O(n^2)); bin: view JSON text directly
    local view_of = bin and MT.view_json_index(ents, tick) or MT.view_index(ents)
    if pf then local x = PF.now(); PF.add("si_index", x - pt); pt = x end
    local sl = scripted()
    if pf then local x = PF.now(); PF.add("si_list", x - pt); pt = x end
    local items = bin and {} or nil          -- UX A3: answers of this TickInput (bin: one Answers frame before it)
    for _, e in ipairs(sl) do
        local ls = st.loaded[e.eid]
        if ls ~= nil and ls ~= "error" then      -- UX A3: nil = not sent to the service yet (waiting for Hello)
            local view = view_of(e)          -- bin: JSON text or nil; jsonl: list of view tables
            local fields = API.take_fields(e)
            local ans = API.take_answers(e.eid)
            local ev = st.feedback[e.eid]
            st.feedback[e.eid] = nil
            if bin then
                -- wave 5p: one pooled record per entity (encoded right away into st.out by send_bin below), pos/rot/vel
                -- are the entity's own {x,y,z} tables, the view JSON is joined from per-entity fragments cached for
                -- this tick (sbmeter.view_json_index: the same text as encode_view(view_of(e)), 2 MB/tick less garbage)
                local rec = e.si_rec
                if not rec then rec = {}; e.si_rec = rec end
                rec.eid, rec.owner, rec.pos, rec.rot, rec.vel = e.eid, e.owner, e.pos, e.rot, e.vel
                if ev and #ev > 0 then
                    if pf then local x = PF.now(); PF.add("si_view", x - pt); pt = x end
                    local evj = {}
                    for i, x in ipairs(ev) do evj[i] = json.tostring(x) end
                    rec.events_json = evj
                    if pf then local x = PF.now(); PF.add("si_events", x - pt); pt = x end
                else
                    rec.events_json = NO_EVENTS
                end
                rec.view_json = view
                rec.fields_json = fields and json.tostring(fields) or nil
                if ans then
                    for qid, v in pairs(ans) do
                        local okj, txt = pcall(json.tostring, v)
                        if not okj or #txt > 65536 then txt = '{"ok":false,"err":"answer too large"}' end
                        items[#items + 1] = {eid = e.eid, qid = qid, json = txt}
                    end
                end
                list[#list + 1] = rec
            else
                local ent = {eid = e.eid, owner = e.owner, pos = {e.pos.x, e.pos.y, e.pos.z},
                             rot = {e.rot.x, e.rot.y, e.rot.z}, vel = {e.vel.x, e.vel.y, e.vel.z}}
                if ev and #ev > 0 then ent.events = ev end
                if #view > 0 then ent.view = view end
                if fields then ent.fields = fields end
                if ans then
                    local am = {}
                    for qid, v in pairs(ans) do am[tostring(qid)] = v end
                    ent.answers = am
                end
                list[#list + 1] = ent
            end
        end
    end
    if pf then local x = PF.now(); PF.add("si_view", x - pt); pt = x end
    if #list == 0 then return end
    if cfg.sandbox_proto == "bin" then
        if #items > 0 then
            if (st.svc_proto or 1) >= 2 then
                -- frames of <= ~1 MiB of answers (each answer <= 64 KiB)
                local chunk, bytes = {}, 0
                for _, it in ipairs(items) do
                    chunk[#chunk + 1] = it
                    bytes = bytes + #it.json + 16
                    if bytes > 1048576 then send_bin("Answers", {tick = tick, items = chunk}); chunk, bytes = {}, 0 end
                end
                if #chunk > 0 then send_bin("Answers", {tick = tick, items = chunk}) end
                API.ST.answers = API.ST.answers + #items
            else
                API.ST.answers_dropped = (API.ST.answers_dropped or 0) + #items
            end
        end
        send_bin("TickInput", {tick = tick, seed = tick, dt = 0.05, entities = list})
    else
        st.out[#st.out + 1] = MT.encode_tick(tick, tick, 0.05, list)   -- = send_line({type = "tick", ...}), 7x faster
    end
    if pf then PF.add("si_encode", PF.now() - pt) end
    st.sent = st.sent + 1
    st.last_sent_tick = tick
end

-- phase 5
function M.flush()
    if st.state ~= "connected" or st.out == nil then return end
    local payload
    if cfg.sandbox_proto == "bin" then
        if #st.out == 0 then return end
        payload = st.out
    else
        if #st.out == 0 then return end
        payload = table.concat(st.out)
    end
    local ok = pcall(st.sock.send, st.sock, payload)
    if ok then
        st.bytes_out = st.bytes_out + #payload
    end
    if cfg.sandbox_proto == "bin" then st.out:clear() else st.out = {} end
end

function M.status()
    if (cfg.sandbox_port or 0) == 0 then return "off" end
    local ap, rj = 0, 0
    for _, n in pairs(st.applied) do ap = ap + n end
    for _, n in pairs(st.rejected) do rj = rj + n end
    -- wave 4b: bytes_out/bytes_in = world -> service / service -> world on the wire (TickInput/TickResult sizes)
    return string.format("%s/%s(sent=%d,results=%d,late=%d,skipped=%d,applied=%d,rejected=%d,errors=%d,fuel=%.0f," ..
        "bytes_out=%d,bytes_in=%d,%s)", st.state, cfg.sandbox_proto, st.sent, st.results, st.late, st.skipped, ap, rj,
        st.errors, st.fuel, st.bytes_out, st.bytes_in, MT.summary())
end

-- wave 3a: one scripted entity spawned at runtime (admin spawn_scripted); on (re)connect all are loaded anyway
function M.load_entity(e)
    if st.state ~= "connected" then return false end
    API.on_load(e)                               -- UX A3: memory cache / bones in the VM are stale, fields again
    if st.await_hello then st.loaded[e.eid] = "pending"; return true end   -- loaded with the rest after Hello
    if cfg.sandbox_proto == "bin" then
        send_bin("Load", {owner = e.owner, eid = e.eid, src = script_src(e)})
    else
        send_line({type = "load", owner = e.owner, eid = e.eid, src = script_src(e)})
    end
    st.loaded[e.eid] = "pending"
    return true
end

-- wave 4a: a bench was stopped -> unload it in the service (it also gets no TickInput any more)
function M.unload_entity(e)
    st.loaded[e.eid] = nil
    st.feedback[e.eid] = nil
    if st.state ~= "connected" then return false end
    if cfg.sandbox_proto == "bin" then
        send_bin("Unload", {owner = e.owner, eid = e.eid})
    else
        send_line({type = "unload", owner = e.owner, eid = e.eid})
    end
    return true
end

function M.connected() return st.state == "connected" end

function M.script_exists(name)
    return type(name) == "string" and name:match("^[%w_]+$") ~= nil and file.exists("olife_world:sandbox/" .. name .. ".lua")
end

M.meter = MT
function M.dump_meters(path)
    local rj = {}
    for k, v in pairs(st.rejected) do rj[k] = v end
    return MT.dump(path, server.S, {state = st.state, runtime = st.runtime, sent = st.sent, late = st.late,
                                    skipped = st.skipped, load_errors = st.load_errors, rejected_by_reason = rj})
end

-- admin `sandbox_reconnect` (console callback: only a flag; the socket work happens in phase 2)
function M.request_reconnect()
    st.reconnect_req = true
    return "[olife_world] sandbox_reconnect queued (state " .. st.state .. ")"
end

-- supervisor state file: bridge state, last TickResult summary, per-owner meter
function M.summary()
    local ap, rj = 0, 0
    for _, n in pairs(st.applied) do ap = ap + n end
    for _, n in pairs(st.rejected) do rj = rj + n end
    local owners = {}
    for o, m in pairs(st.owners) do owners[tostring(o)] = m end
    return {state = st.state, proto = cfg.sandbox_proto, port = cfg.sandbox_port, connects = st.connects,
            sent = st.sent, results = st.results, late = st.late, skipped = st.skipped, applied = ap, rejected = rj,
            errors = st.errors, fuel = st.fuel, last_error = st.last_error, last_result_tick = st.last_result_tick,
            last_sent_tick = st.last_sent_tick, last_result = st.last_result, owners = owners}
end

function M.shutdown()
    if st.sock and st.state == "connected" then pcall(function() st.sock:close() end) end
    st.state = "off"
end

-- wave 3a: time of building + encoding the TickInput (part of phase 4 "replication") -> MT.summary (in_ms_avg/max)
do
    local inner = M.send_input
    M.send_input = function(tick, ents)
        local t0 = U.now_ms()
        inner(tick, ents)
        MT.input_time(U.now_ms() - t0)
    end
end

return M
