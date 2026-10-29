-- The Alpha client state machine (Minecraft.runTick + NetClientHandler subset, phase 2).
-- Alpha ticks (20 per second) are counted from the engine clock (time.uptime(): virtual in F2F mode, where
-- `step {ticks:N}` advances it by N*50 ms) and run inside on_world_tick: the engine runs at most one world tick
-- per frame (and clamps the level delta to 0.2 s), so a frame may carry 0..N alpha ticks, like Java's Timer.
-- Per alpha tick: mouse look, network packets (processReadPackets), player physics + sendMotionUpdates (only
-- when the chunks around the player exist, World.updateEntity), chat ages. After the ticks: dirty chunks are
-- written to the engine, the view camera follows the player.
local net = require "alphamine:net"
local chunks = require "alphamine:chunks"
local texfx = require "alphamine:texfx"
local blocks = require "alphamine:blocks"
local pl = require "alphamine:player"
local items = require "alphamine:items_table"
-- phase 3: input (keys per tick, mouse look per frame), inventory (packets 16/17, hotbar, drop), entities
local input_mod = require "alphamine:input"
local inv = require "alphamine:inventory"
local ents = require "alphamine:entities"
-- phase 3 (U): swing, clicks, view bobbing, camera interpolation (EntityPlayer / EntityRenderer state)
local fpv = require "alphamine:fpview"
-- performance suite: per-frame profiler (modules/perf.lua) and the scripted walk (modules/autowalk.lua)
local perf = require "alphamine:perf"
local autowalk = require "alphamine:autowalk"
-- phase 4 (P): world interaction — getMouseOver, PlayerControllerMP (dig/place), WorldClient rollback, relight,
-- pickup effect, inventory screen keys (modules/interact.lua; it wraps the packet handlers on the first tick)
local interact = require "alphamine:interact"

local M = {
    tick = 0,             -- alpha ticks since world open
    tick_base = 0,        -- tick of the last F2F `mode` (reported ticks are relative to it)
    t0 = nil,
    screen = "none",      -- Java screen names: none, GuiConnecting, GuiDownloadTerrain, ingame, GuiConnectFailed
    logged_in = false,
    chat = {},            -- newest first, {text, age}
    inventory = inv.main, -- [slot 0..35] = {id, count, meta} (alphamine:inventory)
    map_chunks = 0, world_packets = 0, last_world_packet_tick = 0,
    entities = 0,
    kick = nil,
    f2f = false,          -- F2F mode: no tick cap, mouse dy has Java sign
    user = "Player",
    last_mouse = nil,
    stats = {ticks_run = 0, max_ticks_frame = 0, tick_ms = 0, frames = 0, first_chunk_tick = nil,
             login_tick = nil, first_pos_tick = nil},
}

local function log(m) debug.log("[alphamine] " .. m) end
M.log = log

-- normal launch: time budget (ms) of chunk conversions (encode + world.set_chunk_data) per frame; the count
-- budget (chunks.max_per_frame) and the lightmap upload interval are in alphamine:chunks
M.flush_budget_ms = 50

perf.info = function()
    local _, np = chunks.pending_count()
    return np, world.count_chunks(), pl.x or 0, pl.z or 0
end

-- ------------------------------------------------------------------ packet handlers
local H = net.handler

function H.connected()
    M.screen = "GuiConnecting"
    log(("connected to %s:%d in %.1f ms"):format(net.host, net.port, net.stats.connect_ms))
end

function H.handshake(s)
    if s == "-" then
        net.send_login(M.user, "Password", 14)
    else
        net.close()
        M.screen = "GuiConnectFailed"
        M.kick = "online-mode server (hash " .. s .. ") is not supported"
    end
end

function H.login(proto, user, pass)
    M.logged_in = true
    net.state = "play"
    M.screen = "GuiDownloadTerrain"
    M.stats.login_tick = M.tick
    M.stats.login_clock = os.clock()
    log(("login ok (entity %d) at tick %d"):format(proto, M.tick))
end

function H.flying(id, x, y, stance, z, yaw, pitch, on_ground)
    -- NetClientHandler.handleFlying: position = packet (yPosition = eyes), motion 0, echo the same packet
    -- with x, minY, posY, z of the player
    local px, minY, py, pz, pyaw, ppitch, first = pl.on_server_position(x, y, z, yaw, pitch, M.tick)
    fpv.teleport()   -- setPositionAndRotation: prevPos = pos (U)
    if id == 10 then
        net.send_flying(on_ground)
    elseif id == 11 then
        net.send_position(px, minY, py, pz, on_ground)
    elseif id == 12 then
        net.send_look(yaw, pitch, on_ground)
    else
        net.send_look_move(px, minY, py, pz, yaw, pitch, on_ground)
    end
    if first then
        M.screen = "ingame"
        M.stats.first_pos_tick = M.tick
        log(("first position %.3f %.3f %.3f at tick %d"):format(px, py, pz, M.tick))
    end
end

local function world_packet()
    M.world_packets = M.world_packets + 1
    M.last_world_packet_tick = M.tick
end

function H.pre_chunk(cx, cz, load)
    world_packet()
    chunks.pre_chunk(cx, cz, load)
end

function H.map_chunk(x, y, z, sx, sy, sz, zlib)
    world_packet()
    M.map_chunks = M.map_chunks + 1
    if M.map_chunks == 441 then
        M.stats.chunks441_tick = M.tick
        log(("441 map chunks at tick %d (%.1f s after login, %.1f s wall)"):format(M.tick,
            (M.tick - (M.stats.login_tick or 0)) * 0.05, os.clock() - (M.stats.login_clock or os.clock())))
    end
    if not M.stats.first_chunk_tick then M.stats.first_chunk_tick = M.tick end
    chunks.map_chunk(x, y, z, sx, sy, sz, zlib)
end

function H.block_change(x, y, z, id, meta)
    world_packet()
    chunks.block_change(x, y, z, id, meta)
end

function H.multi_block_change(cx, cz, n, coords, types, metas)
    world_packet()
    chunks.stats.multi_changes = chunks.stats.multi_changes + 1
    for k = 1, n do
        local c = coords[k]
        local lx, lz, y = bit.band(bit.rshift(c, 12), 15), bit.band(bit.rshift(c, 8), 15), bit.band(c, 255)
        chunks.block_change(cx * 16 + lx, y, cz * 16 + lz, types[k], metas[k])
    end
end

-- GuiIngame.addChatMessage: a line wider than 320 (FontRenderer.getStringWidth) is split; each part goes in first
local function add_chat_line(s)
    local font = require "alphamine:font"
    if font.width(s) > 320 then
        local cs = {}
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do cs[#cs + 1] = ch end
        while font.width(table.concat(cs)) > 320 do
            local n = 1
            while n < #cs and font.width(table.concat(cs, "", 1, n + 1)) <= 320 do n = n + 1 end
            add_chat_line(table.concat(cs, "", 1, n))
            local rest = {}
            for k = n + 1, #cs do rest[#rest + 1] = cs[k] end
            cs = rest
        end
        s = table.concat(cs)
    end
    table.insert(M.chat, 1, {text = s, age = 0})
    while #M.chat > 50 do M.chat[#M.chat] = nil end
end

function H.chat(s)
    add_chat_line(s)
    log("chat: " .. s)
end

-- InventoryPlayer.addItemStackToInventory
function H.add_to_inventory(id, count, dmg)
    inv.add(id, count, dmg)
    M.inventory = inv.main
end

function H.entity(id)
    M.entities = M.entities + 1
end
-- phase 3: entity packets -> alphamine:entities (NetClientHandler.handle*)
function H.destroy_entity(eid) ents.destroy(eid) end
function H.named_entity_spawn(...) ents.named_spawn(...) end
function H.pickup_spawn(...) ents.pickup_spawn(...) end
function H.vehicle_spawn(...) ents.vehicle_spawn(...) end
function H.entity_move(...) ents.move(...) end
function H.entity_teleport(...) ents.teleport(...) end
function H.item_switch(...) ents.item_switch(...) end
function H.arm_animation(...) ents.arm_animation(...) end
function H.collect(item_eid, collector) ents.destroy(item_eid) end
function H.keepalive() end

-- NetClientHandler.handleKickDisconnect / handleErrorMessage: GuiConnectFailed(title, reason) with "Back to title
-- screen" (modules/gui.lua); its button leaves the world to the engine menu (M.leave_to_menu)
function M.connection_failed(title, reason)
    if M.screen == "GuiMainMenu" then return end   -- we left ourselves (Disconnect)
    M.kick = reason
    M.screen = "GuiConnectFailed"
    local ok, err = pcall(function() require("alphamine:gui").show_failed(title, reason) end)
    if not ok then log("GuiConnectFailed: " .. tostring(err)) end
end

function H.kick(reason)
    log("kicked: " .. reason)
    net.close()
    M.connection_failed("Disconnected by server", reason)
end

function H.disconnected(reason)
    if M.screen ~= "GuiConnectFailed" and M.screen ~= "GuiMainMenu" then
        log("disconnected: " .. tostring(reason))
        reason = tostring(reason)
        if reason:find("^connect error") then
            -- ThreadConnectToServer: GuiConnectFailed("Failed to connect to the server", exception message)
            M.connection_failed("Failed to connect to the server", (reason:gsub("^connect error:%s*", "")))
        else
            -- NetworkManager: socket closed by the server = "End of stream"
            M.connection_failed("Connection lost", reason == "connection closed" and "End of stream" or reason)
        end
    end
end

-- GuiIngameMenu "Disconnect" (and "Back to title screen" of GuiConnectFailed): Packet255 "Quitting" when still
-- connected, close the socket, changeWorld1(null) + GuiMainMenu -> in a normal launch the world is closed and the
-- engine main menu opens (app.close_world from a post_runnable: the world must not close inside its own callbacks).
-- F2F keeps the world (the test harness owns the session) and only reports screen GuiMainMenu.
function M.leave_to_menu(why)
    if net.sock and net.state == "play" then pcall(net.send_disconnect, "Quitting") end
    net.close()
    M.screen = "GuiMainMenu"
    log("leaving the world: " .. tostring(why or "disconnect"))
    if M.f2f then return end
    time.post_runnable(function()
        if world.is_open() then __vc_app.close_world(false) end
    end)
end
M.disconnect = function() M.leave_to_menu("Disconnect") end

-- ------------------------------------------------------------------ control
function M.connect(host, port, user)
    M.user = user or M.user
    blocks.init()
    M.logged_in, M.kick = false, nil
    M.screen = "GuiConnecting"
    net.connect(host, port, M.user)
end

-- from an app-script coroutine (launch.lua): connect on the next world tick, in the main Lua state —
-- network callbacks created inside a coroutine die with it
function M.request_connect(host, port, user)
    M.pending_connect = {host, port, user}
end

function M.send_chat(text)
    net.send_chat(text)
end

-- phase 2 mouse look (per tick, from cursor positions) — replaced by M.frame (per frame, native delta)
local function mouse_look()
    local ok, pos = pcall(input.get_mouse_pos)
    if not ok or type(pos) ~= "table" then return end
    local x, y = pos[1], pos[2]
    local last = M.last_mouse
    M.last_mouse = {x, y}
    if not last then return end
    local dx, dy = x - last[1], y - last[2]
    if dx == 0 and dy == 0 then return end
    -- a GUI screen is open (GuiIngameMenu...): the cursor belongs to the screen, the player does not turn
    if M.screen ~= "ingame" then return end
    if not M.f2f then
        -- real mouse: only while the game has the cursor (no pause menu), screen y grows down
        if hud and hud.is_paused and hud.is_paused() then return end
        dy = -dy
    end
    pl.look(dx, dy, M.tick)
end

-- Minecraft.runTick order: thePlayer.onPlayerUpdate() (sendMotionUpdates, always) ... GUI screen update ...
-- world.updateEntities() (player onUpdate = physics + sendMotionUpdates, only when the chunks around exist)
-- ... world.tick() (WorldClient: processReadPackets). The server streams one MapChunk per received movement
-- packet (EntityPlayerMP.onUpdateEntity), so the two sends per tick matter for the chunk rate.
local function chunk_ok(x, z) -- World.updateEntity: chunks within 16 blocks exist
    local bx, bz = math.floor(x), math.floor(z)
    for cx = math.floor((bx - 16) / 16), math.floor((bx + 16) / 16) do
        for cz = math.floor((bz - 16) / 16), math.floor((bz + 16) / 16) do
            if not chunks.has_chunk(cx, cz) then return false end
        end
    end
    return true
end

local function run_tick()
    M.tick = M.tick + 1
    perf.count("ticks")
    -- GuiIngame.updateTick (first in runTick): chat lines age; a line added by this tick's packets stays at 0 until the
    -- next tick (was aged at the end of the tick: one tick ahead of Java in the 200-tick fade, E2E 01.10)
    for _, c in ipairs(M.chat) do c.age = c.age + 1 end
    local _, edges = input_mod.tick()
    interact.tick_begin(M)   -- getMouseOver(1.0); PlayerControllerMP.onUpdate: prev damage (P)
    if pl.has_pos then pl.send_motion(net) end
    local ingame = M.screen == "ingame"
    -- PlayerControllerMP.onUpdate -> syncCurrentPlayItem (Packet16 when the held item changed)
    if ingame then inv.sync_current(net) end
    if M.screen == "GuiDownloadTerrain" and M.tick % 20 == 0 then
        net.send_keepalive()  -- GuiDownloadTerrain.updateScreen
    end
    -- currentScreen.updateScreen() of GuiConnecting / GuiDownloadTerrain: NetClientHandler.processReadPackets, at
    -- most 101 packets per call (NetworkManager: `var1 = 100; while(... && var1-- >= 0)`); WorldClient.tick below
    -- is the second call of the same tick (Java: 2 x 101 while the terrain downloads; lockstep E2E 01.10)
    if M.screen == "GuiConnecting" or M.screen == "GuiDownloadTerrain" then
        perf.push("net")
        net.poll(101)
        perf.pop()
    end
    -- currentScreen.handleInput() + updateScreen(): GuiChat (typed chars, Backspace, Enter -> Packet3Chat, Esc)
    local chat_gui = require "alphamine:chat_gui"
    if chat_gui.is_open() then
        chat_gui.tick()
        ingame = M.screen == "ingame"   -- closed by Enter/Esc: the rest of the tick runs without a screen
    end
    -- Minecraft.runTick key events (currentScreen == null): hotbar 1..9, drop (Q)
    if ingame then
        for i = 1, 9 do
            if edges["slot" .. i] then inv.set_current(i - 1) end
        end
        if edges.inventory or edges.inventory_e then   -- keyBindInventory (I; E alias): GuiInventory (U)
            require("alphamine:inventory_gui").open_screen()
        end
        if edges.drop then
            local pkt = pl.drop(inv.decr(inv.current, 1), net)
            if pkt then inv.stats.drops = inv.stats.drops + 1; M.last_drop = pkt end
        end
        -- isMultiplayerWorld() && keyBindChat (T): GuiChat (E2E 01.10; the engine's hud.chat binding is off)
        if edges.chat and M.multiplayer ~= false and M.screen == "ingame" then chat_gui.open_screen() end
    end
    -- runTick mouse: clickMouse on presses / held every 5 ticks, leftClickCounter (U: fpview.lua)
    fpv.mouse_tick(M.tick, edges, input_mod.state, not ingame, net)
    -- Minecraft.sendClickBlockToController: dig while the left button is held (PlayerControllerMP, P)
    if ingame or M.screen == "GuiInventory" then
        interact.click_block_tick(input_mod.state.attack, ingame)
    else
        -- EntityPlayer.onLivingUpdate -> inventory.decrementAnimations runs under any screen (Alpha SMP keeps ticking
        -- with GuiIngameMenu / GuiChat open). Was skipped: the hotbar "pop" froze while a menu was open, and the
        -- HUD rebuilt its item icons every frame (key = anim - partial): ~16 ms per frame whenever the window lost
        -- focus (perf_stream 01.10)
        inv.decrement_animations()
    end
    perf.push("texfx")
    texfx.tick()   -- RenderEngine.updateDynamicTextures (Math.random stream, animated water/lava; phase 3 render)
    perf.pop()
    if pl.can_update() then
        local strafe, forward, jump = input_mod.movement()
        if autowalk.active then
            local s2, f2, j2 = autowalk.tick(M, pl, perf)
            if s2 then strafe, forward, jump = s2, f2, j2 end
        end
        perf.push("physics")
        fpv.pre_tick()      -- prevPos / prevDistanceWalked / prevSwing / prevCamera* (U)
        fpv.action_tick()   -- EntityPlayer.updateEntityActionState: swing (U)
        pl.tick_physics(M.tick, strafe, forward, jump)
        fpv.post_tick()     -- EntityPlayer.onLivingUpdate: cameraYaw / cameraPitch (U)
        perf.pop()
        pl.send_motion(net)
    elseif autowalk.active then
        autowalk.tick(M, pl, perf)
    end
    if autowalk.active and autowalk.phase == 4 then autowalk.after(M) end
    perf.push("ents_tick")
    ents.tick(chunk_ok)
    perf.pop()
    -- WorldClient.tick (only with a world, i.e. after Packet1Login): processReadPackets, at most 101 packets; the rest
    -- stays buffered for the next tick (was: everything at once - up to 490 packets in one tick after /tp)
    if M.logged_in then
        perf.push("net")
        net.poll(101)
        perf.pop()
    end
    interact.world_tick()    -- WorldClient.tick after the packets: rollback countdown (P)
    ents.update_effects()    -- EffectRenderer.updateEffects: pickup effects (P)
end

-- called from on_world_tick
function M.update()
    if M.pending_connect then
        local c = M.pending_connect
        M.pending_connect = nil
        M.connect(c[1], c[2], c[3])
    end
    local now = time.uptime()
    if not M.t0 then
        M.t0 = now
        M.ticks_done = 0
    end
    local due = math.floor((now - M.t0) / 0.05 + 1e-6) - M.ticks_done
    if due <= 0 then return end
    if not M.f2f and due > 10 then
        -- Java Timer: at most 10 ticks per frame, the rest is dropped
        M.ticks_done = M.ticks_done + (due - 10)
        due = 10
    end
    local c0 = perf.clock()
    perf.push("tick")
    for _ = 1, due do
        run_tick()
        M.ticks_done = M.ticks_done + 1
    end
    -- F2F: all dirty chunks now (parity); normal launch: M.frame_body flushes a budget every rendered frame
    -- (perf.opts.f2f_budget: F2F perf runs with the normal launch's batching, to read the engine profiler; never parity)
    if M.f2f and not perf.opts.f2f_budget then chunks.flush(nil) end
    pl.update_view()
    -- the engine switches its slot on digit keys even under a pack screen (Hud::updateHotbarControl): followed only
    -- in game; under GuiChat/GuiInventory the engine slot is put back (typing "1" in the chat must not switch)
    inv.follow_engine(pl.PID, M.screen ~= "ingame")
    inv.mirror(pl.PID)
    M.ensure_frame_entity()
    perf.pop()
    local ms = (perf.clock() - c0) * 1e3
    if not M.f2f and M.logged_in and math.floor(M.tick / 100) ~= math.floor((M.tick - due) / 100) then
        -- dev runs: one status line per 5 s (fps = frames counted by the HUD script / wall time)
        local now_c = os.clock()
        local st = M.stats
        if st.log_clock then
            local fps = (st.frames - st.log_frames) / math.max(1e-3, now_c - st.log_clock)
            local n, np = chunks.pending_count()
            log(("player %.4f %.4f %.4f yaw %.2f pitch %.2f %s collision %s look_dx %d look_dy %d"):format(pl.x, pl.y,
                pl.z, pl.yaw, pl.pitch, pl.on_ground and "ground" or "air", pl.collision, input_mod.look_dx, input_mod.look_dy))
            log(("status tick %d fps %.1f map_chunks %d stored %d engine %d dirty %d/%d net in %d KB, ticks %.2f ms/tick, encode %.0f ms, inflate %.0f ms"):format(
                M.tick, fps, M.map_chunks, chunks.count(), world.count_chunks(), np, n, net.stats.bytes_in / 1024,
                st.tick_ms / math.max(1, st.ticks_run), chunks.stats.encode_ms, chunks.stats.inflate_ms))
        end
        if perf.on then
            local hm = package.loaded["alphamine:modules/hud.lua"] or package.loaded["alphamine:hud"]
            if hm and hm.rebuilds and next(hm.rebuilds) then
                local t = {}
                for id, n in pairs(hm.rebuilds) do t[#t + 1] = id .. "=" .. n end
                table.sort(t)
                log("hud rebuilds " .. table.concat(t, " "))
                hm.rebuilds = {}
            end
        end
        st.log_clock, st.log_frames = now_c, st.frames
    end
    M.stats.ticks_run = M.stats.ticks_run + due
    M.stats.tick_ms = M.stats.tick_ms + ms
    if due > M.stats.max_ticks_frame then M.stats.max_ticks_frame = due end
end

-- F2F `mode`: tick counter restarts at 0, optional chat clear
function M.mode(args)
    M.tick_base = M.tick
    if args and args.clear_chat then M.chat = {} end
    -- phase 3: Entity.rand of the player and entities = entitySeed(seed, id), EntityItem age/hoverStart = 0
    local seed = args and tonumber(args.seed) or 0
    -- Java F2FAgent.mode: lastWorldPacketTick = lastMoveTick = 0 (tick counter restarts): `wait {net_idle,
    -- still}` after mode counts from mode (layer_entities waits net_idle 60 for the dropped item to land)
    M.last_world_packet_tick = M.tick
    pl.last_move_tick = M.tick
    pl.mode(seed)
    ents.mode(seed)
    texfx.reset(seed)   -- F2FRandom.reseed (Math.random) + F2FAgent.resetTextureFX
    interact.mode(seed)  -- NetClientHandler.rand (pickup sound pitch) reseeded (P)
    M.mode_options = fpv.mode(args)   -- bobbing state = 0, options.viewBobbing (U)
    -- determinism probe (lab stage 3b): mode {fx_probe = "nosub"|"nolight"|"none"} switches off the engine-random
    -- parts of the particle emitters (random_sub_uv / lighting); absent = normal particles
    local okp, parts = pcall(require, "alphamine:particles")
    if okp and parts then parts.probe = args and args.fx_probe or nil end
    local hud_m = package.loaded["alphamine:modules/hud.lua"]   -- vignette smoothing at its fixed point (E2E)
    if hud_m and hud_m.vignette_reset then hud_m.vignette_reset() end
end

-- ------------------------------------------------------------------ per rendered frame (phase 3)
-- alphamine:am_frame entity (scripts/components/am_frame.lua) calls M.frame from on_render: before the world
-- is drawn, like EntityRenderer.updateCameraAndRender (mouse look -> setAngles, then camera and entities with
-- renderPartialTicks).
M.frame_uid = nil
function M.ensure_frame_entity()
    if not pl.has_pos then return end
    if M.frame_uid and entities.exists(M.frame_uid) then
        local e = entities.get(M.frame_uid)
        if e then e.transform:set_pos({pl.x, pl.y, pl.z}) end
        return
    end
    local ok, e = pcall(entities.spawn, "alphamine:am_frame", {pl.x, pl.y, pl.z})
    if ok and e then
        M.frame_uid = e:get_uid()
        pcall(function() e.rigidbody:set_enabled(false) end)
    end
end

function M.partial()
    if not M.t0 then return 0 end
    local p = (time.uptime() - M.t0) / 0.05 - M.ticks_done
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    return p
end

-- engine bindings that would act on the engine player / engine inventory (drop spawns base:drop from the
-- mirrored inventory, build places engine blocks, F4 switches the engine camera...). Alpha does all of this
-- itself (keys in run_tick, packets); disabled once the HUD exists (its rules re-enable some on hud open).
local ENGINE_BINDINGS_OFF = {"player.drop", "player.build", "player.attack", "player.destroy", "player.pick",
    "player.noclip", "player.flight", "player.fast_interaction", "movement.forward", "movement.back",
    "movement.left", "movement.right", "movement.jump", "movement.sprint", "movement.crouch", "movement.cheat",
    "camera.zoom", "camera.mode", "hud.inventory",   -- hud.inventory (Tab): engine inventory; Alpha has GuiInventory (U)
    "hud.chat"}   -- T: the engine's chat/console page (stdlib.lua); Alpha has GuiChat (chat_gui.lua)
function M.disable_engine_bindings()
    for _, b in ipairs(ENGINE_BINDINGS_OFF) do pcall(input.set_enabled, b, false) end
    M.bindings_off = true
end

function M.frame(delta)
    perf.frame_boundary()
    if not M.perf_configured then
        M.perf_configured = true
        if not M.f2f then
            -- normal launch: suite control files (tools/alphamine/perf/perf_normal.py writes and removes them)
            perf.config_normal()
            autowalk.config_normal()
            M.debug_log = file.isfile("export:alphamine_debug.txt")
        end
    end
    perf.push("frame")
    local ok, err = pcall(M.frame_body, delta)
    perf.pop()
    if not M.f2f and perf.on then
        perf.periodic(false)
        if autowalk.phase == 4 and not M.perf_finished then
            M.perf_finished = true
            local path, n = perf.periodic(true)
            log(("perf finished: %d rows, last part %s"):format(perf.rows, tostring(path)))
            debug.log("[alphamine_perf] finished")
        end
    end
    if not ok then error(err, 0) end
end

function M.frame_body(delta)
    if not M.bindings_off then M.disable_engine_bindings() end
    if not M.f2f then
        local ok_g, g = pcall(require, "alphamine:gui")
        if ok_g then pcall(g.focus_lost_check) end
    end
    input_mod.f2f = M.f2f
    -- the ticks due by the clock run here too: on_world_tick fires only on every other 50 ms frame (engine
    -- Clock: timer > 1/20 strictly), so a tick of F2F `step {ticks:1}` would otherwise run one frame later
    -- than in Java (Minecraft.run: ticks, then the frame) — seen as the drop (Q) landing in the tick of the
    -- slot key: the Entity.rand sequence and the dropped item's motion differed.
    M.update()
    M.stats.frames_hooked = (M.stats.frames_hooked or 0) + 1
    local dx, dy = input_mod.frame()
    if M.screen == "ingame" and pl.has_pos then pl.look(dx, dy, M.tick) end
    if (dx ~= 0 or dy ~= 0) and not M.f2f and M.debug_log then
        -- dev runs: mouse look trace (at most one line per 0.25 s of wall clock)
        local c = os.clock()
        if not M.look_log or c - M.look_log > 0.25 then
            M.look_log = c
            log(("look dx %d dy %d -> yaw %.2f pitch %.2f (total dx %d dy %d)"):format(dx, dy, pl.yaw, pl.pitch,
                input_mod.look_dx, input_mod.look_dy))
        end
    end
    pl.update_view()
    interact.frame(M.partial())   -- setPartialTime + getMouseOver(partial) -> game.dig, game.frame_over (P)
    perf.push("ents_frame")
    ents.frame(M.partial(), {view_y = pl.yaw, view_x = pl.pitch, x = pl.x, y = pl.y, z = pl.z})
    perf.pop()
    if not M.f2f or perf.opts.f2f_budget then
        perf.push("tick")
        if pl.has_pos then chunks.center = {pl.x, pl.z} end
        chunks.flush(M.f2f and tonumber(perf.opts.f2f_budget) or M.flush_budget_ms)
        perf.pop()
    end
end

function M.rel_tick()
    return M.tick - M.tick_base
end

function M.in_world()
    return M.logged_in and pl.has_pos and M.screen == "ingame"
end

function M.close()
    net.close()
end

return M
