-- F2F (agents/F2F.md) on the VoxelCore side: the Lua handler of <repo>\builds\031\VoxelCoreF2F-031.exe.
-- The engine (C++) serves hello/mode/step/input/shot/quit and hands every other command to
-- f2f.set_handler(fn(cmd, args)); `mode` is forwarded too (result under "lua").
-- Commands here: connect, chat, state, wait / wait_check, render, status (+ mode).
-- `wait` cannot step frames from inside the handler (the handler runs between frames and must return), so
-- the condition check is `wait_check` and the harness (tools/mcp/alpha_tools.py, impl="vc") loops
-- `step {ticks:1, frames:1}` + `wait_check` paced to 50 ms of wall clock, like Java's F2FAgent.waitFor.
-- In the stock VoxelCore.exe `f2f` is absent or inactive: nothing is registered.
local game = require "alphamine:game"
local chunks = require "alphamine:chunks"
local blocks = require "alphamine:blocks"
local pl = require "alphamine:player"
local net = require "alphamine:net"
local inv = require "alphamine:inventory"     -- phase 3
local ents = require "alphamine:entities"     -- phase 3
local input_mod = require "alphamine:input"   -- phase 3

local M = {config = {server = "127.0.0.1:25566", user = "Player"}, registered = false, wait_start = 0,
           render = {}, keepalive = true}

local band, bxor = bit.band, bit.bxor

-- Test build with the realtime clock (`--f2f-clock realtime`, lab kind alphamine.rt, lab perf): time runs by itself,
-- input stays isolated, and the pack behaves as in a normal launch (tick cap, batching, status lines), not in the
-- lockstep parity mode. Known from f2f.clock() when the engine exposes it, else from export:alphamine_realtime.txt
-- (written by the lab into the instance dir). Cached: decided once per process.
local realtime_cache = nil
function M.realtime()
    if realtime_cache == nil then
        realtime_cache = false
        if f2f ~= nil and type(f2f.clock) == "function" then
            realtime_cache = f2f.clock() == "realtime"
        elseif file.isfile("export:alphamine_realtime.txt") then
            realtime_cache = true
        end
    end
    return realtime_cache
end

function M.active()
    return f2f ~= nil and f2f.is_active ~= nil and f2f.is_active() and not M.realtime()
end

-- ------------------------------------------------------------------ FNV-1a 64 (two 32-bit halves)
local P_LO = 0x1b3  -- prime 0x100000001b3 = 2^40 + 0x1b3
local TWO32 = 4294967296
local function fnv_new() return 0xcbf29ce4, 0x84222325 end
local function fnv_byte(hi, lo, b)
    lo = bxor(lo, b) % TWO32
    local l = lo * P_LO
    local nlo = l % TWO32
    local carry = (l - nlo) / TWO32
    local nhi = (hi * P_LO + carry + (lo % 16777216) * 256) % TWO32
    return nhi, nlo
end
local function fnv_hex(hi, lo)
    if hi == 0 then return (bit.tohex(lo, 8):gsub("^0+(.)", "%1")) end
    return (bit.tohex(hi, 8):gsub("^0+(.)", "%1")) .. bit.tohex(lo, 8)
end
M.fnv_new, M.fnv_byte, M.fnv_hex = fnv_new, fnv_byte, fnv_hex

-- Java F2FAgent.blockHash: cube of radius r around floor(player pos), order x, z, y; id/meta & 255;
-- y outside 0..127 -> 0. source "engine": VoxelCore blocks mapped back (modules/blocks.lua),
-- "store": the Lua copy of the server chunks.
local function block_hash(px, py, pz, r, source)
    local bh, bl = fnv_new()
    local mh, ml = fnv_new()
    local missing = 0
    for x = px - r, px + r do
        for z = pz - r, pz + r do
            for y = py - r, py + r do
                local id, meta = 0, 0
                if y >= 0 and y < 128 then
                    if source == "engine" then
                        id, meta = blocks.alpha_at(x, y, z)
                        if id < 0 then
                            missing = missing + 1
                            id, meta = 0, 0
                        end
                    else
                        id, meta = chunks.get(x, y, z)
                    end
                end
                bh, bl = fnv_byte(bh, bl, band(id, 255))
                mh, ml = fnv_byte(mh, ml, band(meta, 255))
            end
        end
    end
    return {radius = r, center = {px, py, pz}, blocks = fnv_hex(bh, bl), meta = fnv_hex(mh, ml),
            source = source, missing = missing}
end
M.block_hash = block_hash

-- ------------------------------------------------------------------ commands
local function counters()
    return {tick = game.rel_tick(), alpha_tick = game.tick}
end

local function state(args)
    local r = counters()
    local radius = tonumber(args.radius) or 8
    r.screen = game.screen
    r.buttons = require("alphamine:gui").buttons()
    local chat = {}
    for i, c in ipairs(game.chat) do
        if i > 20 then break end
        chat[i] = {text = c.text, age = c.age}
    end
    r.chat = chat
    local chat_gui = require "alphamine:chat_gui"   -- GuiChat input line (VoxelCore only, for debugging)
    if chat_gui.is_open() then r.gui_chat = chat_gui.report() end
    if game.logged_in then
        local ex, ey, ez = player.get_pos(pl.PID)
        local ryaw, rpitch = player.get_rot(pl.PID)
        -- phase 3: slot / inventory / entities as Java F2FAgent (entity list: the local player first)
        r.player = {x = pl.x, y = pl.y, z = pl.z, mx = pl.mx, my = pl.my, mz = pl.mz, yaw = pl.yaw,
                    pitch = pl.pitch, onGround = pl.on_ground, health = pl.health, slot = inv.current,
                    entity_id = pl.entity_id, inventory = inv.report(), collision = pl.collision,
                    -- doubles as %.17g strings: the JSON writer keeps ~15 digits (bit-exact comparison with Java)
                    exact = {x = ("%.17g"):format(pl.x), y = ("%.17g"):format(pl.y), z = ("%.17g"):format(pl.z),
                             mx = ("%.17g"):format(pl.mx), my = ("%.17g"):format(pl.my), mz = ("%.17g"):format(pl.mz)},
                    engine = {x = ex, y = ey, z = ez, yaw = ryaw, pitch = rpitch}}
        local el = {}
        if pl.has_pos then el[1] = {id = pl.entity_id, type = "EntityClientPlayerMP", x = pl.x, y = pl.y, z = pl.z} end
        for _, e in ipairs(ents.report()) do el[#el + 1] = e end
        r.world = {time = 0, multiplayer = true, map_chunks = game.map_chunks, world_packets = game.world_packets,
                   last_world_packet_tick = game.last_world_packet_tick, entities = el,
                   stored_chunks = chunks.count(), engine_chunks = world.count_chunks()}
        if pl.has_pos then
            local px, py, pz = math.floor(pl.x), math.floor(pl.y), math.floor(pl.z)
            r.hash = block_hash(px, py, pz, radius, "engine")
            r.hash_store = block_hash(px, py, pz, radius, "store")
        end
    end
    local down = {}
    for name, v in pairs(input_mod.state) do if v then down[#down + 1] = name end end
    table.sort(down)
    r.input = {keys_down = down, mouse = {input_mod.look_dx, input_mod.look_dy},
               in_game_focus = game.screen == "ingame" and input_mod.focused()}
    r.render = M.render
    -- phase 4 (P): objectMouseOver, PlayerControllerMP (like Java F2FAgent `mouse_over` / `dig`), sounds, screen model
    local ia = package.loaded["alphamine:modules/interact.lua"]
    if ia and game.logged_in then
        local rep = ia.report()
        r.mouse_over = rep.mouse_over
        r.dig = {cur = rep.cur, damage = rep.damage, prev_damage = rep.prev_damage, hit_delay = rep.hit_delay,
                 hitting = rep.hitting, pending = rep.pending, stats = rep.stats, partial = rep.damage_partial,
                 cracks = rep.cracks}
        r.sounds = rep.sounds
        if r.player then r.player.screen_inv = inv.report_screen and inv.report_screen() or nil end
    end
    return r
end

local function cond_ok(a)
    if a.screen and not tostring(game.screen):find(a.screen) then return false, "screen " .. game.screen end
    if a.world ~= nil and game.in_world() ~= a.world then return false, "world" end
    if a.chunks and game.map_chunks < a.chunks then return false, "chunks " .. game.map_chunks end
    if a.net_idle and (game.world_packets == 0 or game.tick - game.last_world_packet_tick < a.net_idle) then
        return false, "net_idle"
    end
    if a.new_chunks and game.map_chunks - M.wait_start < a.new_chunks then
        return false, "new_chunks " .. (game.map_chunks - M.wait_start)
    end
    if a.still and (not pl.has_pos or game.tick - pl.last_move_tick < a.still) then return false, "still" end
    if a.near then
        if not pl.has_pos then return false, "near: no position" end
        local n = a.near
        local dx, dy, dz = pl.x - n[1], pl.y - n[2], pl.z - n[3]
        local rr = n[4] or 1.0
        if dx * dx + dy * dy + dz * dz > rr * rr then return false, "near" end
    end
    if a.on_ground ~= nil and (not pl.has_pos or pl.on_ground ~= a.on_ground) then return false, "on_ground" end
    if a.chat then
        local found = false
        for _, c in ipairs(game.chat) do
            if c.text:find(a.chat) then found = true; break end
        end
        if not found then return false, "chat" end
    end
    -- phase 4: an item is flying to its collector (EntityPickupFX; modules/entities.lua e.fx)
    if a.pickup_fx then
        local any = false
        for _, fx in ipairs(ents.effects or {}) do if fx.fx then any = true; break end end
        if not any then return false, "pickup_fx" end
    end
    -- VoxelCore only: every received chunk is written to the engine (no dirty chunk the engine has)
    if a.synced then
        local _, np = chunks.pending_count()
        if np > 0 or net.buffered() > 0 then return false, "synced" end
    end
    return true
end

local function wait_check(args)
    if args.begin then M.wait_start = game.map_chunks end
    local ok, why = cond_ok(args)
    local r = counters()
    r.done = ok
    -- lost connection: no condition about the world can become true any more
    if not ok and game.screen == "GuiConnectFailed" and not args.screen then
        r.fatal = "GuiConnectFailed: " .. tostring(game.kick)
    end
    r.why = why
    r.screen = game.screen
    r.map_chunks = game.map_chunks
    r.new_chunks = game.map_chunks - M.wait_start
    if not ok then
        r.describe = ("screen %s, map_chunks %d, world_packets %d, last at tick %d, tick %d, player %s"):format(
            game.screen, game.map_chunks, game.world_packets, game.last_world_packet_tick, game.tick,
            pl.has_pos and ("%.3f %.3f %.3f %s"):format(pl.x, pl.y, pl.z, pl.on_ground and "on ground" or "in air")
            or "-")
    end
    return r
end

-- lockstep server (agents/F2F.md 9): `sync {rx_bytes?, keepalive?, timeout_ms?}` - wait until the engine's reader
-- thread holds the K bytes the server sent in its last step (the next alpha tick's net.poll takes exactly them), then
-- the counters: tx_total = bytes of this connection handed to the socket (the server barrier), rx_total.
local function sync(args)
    if args.keepalive ~= nil then M.keepalive = args.keepalive and true or false end
    local r = counters()
    local want = tonumber(args.rx_bytes)
    local waited = 0
    if want and want > 0 then
        local t0 = os.clock()
        local limit = (tonumber(args.timeout_ms) or 30000) / 1000
        while net.rx_avail() < want do
            if not net.sock or net.state == "closed" or net.state == "error" then
                error(("rx barrier: connection %s at %d of %d bytes"):format(tostring(net.state), net.rx_avail(), want))
            end
            if os.clock() - t0 > limit then
                error(("rx barrier timeout: %d of %d bytes"):format(net.rx_avail(), want))
            end
        end
        waited = (os.clock() - t0) * 1000
    end
    r.waited_ms = waited
    r.user = game.user
    r.tx_total = net.conn_out
    r.rx_total = net.conn_in
    r.rx_avail = net.rx_avail()
    r.net_state = net.state
    r.keepalive = M.keepalive
    r.screen = game.screen
    return r
end

local function status()
    local n, np = chunks.pending_count()
    return {tick = game.tick, screen = game.screen, net = net.stats, net_state = net.state, net_error = net.error,
            buffered = net.buffered(), chunks = chunks.stats, stored = chunks.count(), dirty = n,
            dirty_present = np, engine_chunks = world.count_chunks(), game = game.stats,
            unknown_ids = blocks.unknown, player = {x = pl.x, y = pl.y, z = pl.z, has_pos = pl.has_pos},
            phase3 = {player = pl.stats, collision = pl.collision, inventory = inv.stats, entities = ents.stats,
                      input_frames = input_mod.frames, frame_errors = game.frame_errors,
                      frames_hooked = game.stats.frames_hooked, last_drop = game.last_drop}}
end

-- `render` from the pack: only what the pack can do itself; engine layers come from the engine build
local PACK_LAYERS = {}
local function render(args)
    local unsupported = {}
    if args.layers then
        for k, v in pairs(args.layers) do
            if PACK_LAYERS[k] then M.render[k] = v else unsupported[#unsupported + 1] = k end
        end
    end
    return {layers = M.render, unsupported = unsupported,
            note = "VoxelCore render layers need the engine F2F build with `render` (agents/F2F.md 7)"}
end

local function handle(cmd, args)
    args = args or {}
    -- catch up the alpha ticks due by the virtual clock: the engine runs on_world_tick only on every other
    -- frame at 50 ms steps (Clock::update needs timer > 1/20 strictly), the harness calls a command after
    -- every step, so packets are read/sent at the Java cadence (one tick per step; the server streams one
    -- chunk per received movement packet)
    if cmd ~= "status" then pcall(game.update) end
    if cmd == "connect" then
        local host, port = M.config.server:match("^(.-):(%d+)$")
        host = args.host or host or "127.0.0.1"
        port = tonumber(args.port or port or 25566)
        game.connect(host, port, args.user or M.config.user)
        local r = counters()
        r.server = host .. ":" .. port
        return r
    elseif cmd == "chat" then
        game.send_chat(tostring(args.text or ""))
        return counters()
    elseif cmd == "state" then
        return state(args)
    elseif cmd == "wait" or cmd == "wait_check" then
        return wait_check(args)
    elseif cmd == "sync" then
        return sync(args)
    elseif cmd == "mode" then
        if args.keepalive ~= nil then M.keepalive = args.keepalive and true or false end
        game.mode(args)
        local r = counters()
        r.seed = args.seed
        r.options = {}
        return r
    elseif cmd == "render" then
        return render(args)
    elseif cmd == "layers" then
        -- phase 4: the engine answers `render` itself and does not forward it; the harness (run_vc_scenario.py)
        -- passes the resulting layer state here, for what the pack draws itself (pickup effect = `particles`)
        if type(args.layers) == "table" then M.layers = args.layers end
        return {layers = M.layers}
    elseif cmd == "gui" then
        -- phase 3: clicks/keys into the pack's GUI screens (modules/gui.lua); the harness steps ticks/frames after
        local r = require("alphamine:gui").handle(args)
        for k, v in pairs(counters()) do r[k] = v end
        return r
    elseif cmd == "status" then
        return status()
    elseif cmd == "eval" then
        -- dev probe (phase 3): run a Lua chunk in the world state, result = its return value
        local fn, err = load(tostring(args.code or ""), "f2f_eval", "t")
        if not fn then error(err) end
        local ok, res = pcall(fn)
        if not ok then error(res) end
        return {value = res}
    elseif cmd == "collision" then
        -- phase 3: player collisions "lua" (Entity.moveEntity in Lua) | "engine" (engine player body)
        return {collision = pl.set_collision(args.mode), tick = game.tick}
    elseif cmd == "perf" or cmd == "am_perf" then
        -- `am_perf`: F2F builds with the engine profiler (ec07d0d1) answer `perf` themselves and never forward it
        -- performance suite (tools/alphamine/perf/perf_walk.py): {start, stop, reset, autowalk:{...}, dump:path,
        -- flush_budget_ms} -> profiler summary + autowalk state
        local perf = require "alphamine:perf"
        local autowalk = require "alphamine:autowalk"
        local r = {}
        if args.reset then perf.reset() end
        if type(args.opts) == "table" then
            perf.opts = {}
            for k, v in pairs(args.opts) do perf.opts[k] = v end
        end
        if args.start then perf.start() end
        if args.stop then perf.stop() end
        if args.flush_budget_ms then game.flush_budget_ms = tonumber(args.flush_budget_ms) end
        if args.autowalk then autowalk.configure(type(args.autowalk) == "table" and args.autowalk or {}) end
        if args.dump then r.dumped = perf.dump(tostring(args.dump)); r.path = args.dump end
        r.perf = perf.summary()
        r.autowalk = autowalk.report()
        r.tick = game.tick
        r.map_chunks = game.map_chunks
        r.screen = game.screen
        return r
    elseif cmd == "keepalive" then
        -- idle keepalive from the harness (Java F2F sends KeepAlive once per idle second from its own
        -- thread; the VoxelCore F2F loop runs no Lua while idle and the server drops a client after 60 s silence)
        -- off after `mode`/`sync {keepalive:false}` (lockstep server: the packet would land in a random server tick)
        local sent = M.keepalive and net.sock ~= nil and net.state ~= "closed" and net.state ~= "error"
        if sent then net.send_keepalive() end
        return {sent = sent, screen = game.screen, keepalive = M.keepalive}
    end
    error("unknown-command: " .. tostring(cmd))
end
M.handle = handle

-- set_handler must be called from the main Lua state (world script, on_world_open): a handler created
-- inside the app-script coroutine is bound to that coroutine and answers null after the script ends
-- (lua::create_lambda keeps the calling lua_State). The start script only passes the config.
function M.configure(config)
    for k, v in pairs(config or {}) do M.config[k] = v end
    if M.config.collision then pl.collision = M.config.collision end
    game.f2f = M.active()
    return M.registered
end

function M.on_world_open()
    if M.active() and not M.registered then
        game.f2f = true
        M.registered = f2f.set_handler(handle)
    end
end
function M.tick() end
function M.close() end
return M
