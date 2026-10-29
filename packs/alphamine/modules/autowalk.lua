-- Scripted walk of the performance suite (tools/alphamine/perf/): the pack itself drives the Alpha player, no OS
-- input. Enabled in a normal launch by export:alphamine_autowalk.txt (key=value lines, see DEFAULTS), in F2F by
-- `perf {autowalk:{...}}`. Timeline in Alpha ticks (20 per second), counted from the moment the world is ready
-- (ingame and >= `chunks` MapChunks, or `wait` ticks after login at most):
--   stand  ticks standing still (baseline)          phase 1
--   walk   ticks with W held; every `period` ticks the yaw turns by +-`turn` degrees (alternating, 1.5 deg per
--          tick, so the heading zig-zags around `yaw`); jump when blocked horizontally or in water   phase 2
--   settle ticks standing still (the last chunks arrive and are converted)   phase 3
--   line=1 (perf_stream): instead of drifting with the detours, the heading follows the straight line through the
--          anchor (ax, az) in the direction `yaw` (steer to the point `ahead` blocks further along the line): the
--          random spawn offset (EntityPlayerMP: spawn +-10) converges to the same route in the first ~30 blocks
--   glide=1 (perf_stream, load test only): no player physics in the walk; the player moves `speed` blocks per
--          tick along the line (0.2158 = Alpha walking speed on the ground) at the height of the highest block
--          under its box (+1 block ahead), so hills, trees and water never stop it: the same route and speed in
--          every run. The Alpha server accepts it (NetServerHandler.handleFlying ignores dy and has no flying
--          check; moveEntity X/Z through air does not collide). Not Alpha behaviour: never used for parity.
-- then phase 4 (done): logs "[alphamine_perf] autowalk done", the normal launch writes the last CSV part.
-- The movement goes through the same path as the keyboard (alphamine:input movement -> player.tick_physics).
local M = {active = false, phase = 0, t = 0}

local DEFAULTS = {stand = 100, walk = 1200, settle = 300, period = 200, turn = 30, yaw = 90, chunks = 441,
                  wait = 1200, pitch = 10, line = 0, ax = 0, az = 0, ahead = 16, glide = 0, speed = 0.2158}

-- line following: yaw (degrees, Alpha: forward = (-sin, cos)) towards the point `ahead` blocks along the line
local function line_yaw(o, x, z)
    local r = math.rad(o.yaw)
    local dx, dz = -math.sin(r), math.cos(r)
    local t = (x - o.ax) * dx + (z - o.az) * dz          -- position along the line
    local tx, tz = o.ax + (t + o.ahead) * dx, o.az + (t + o.ahead) * dz
    return math.deg(math.atan2(-(tx - x), tz - z))
end

local function log(m) debug.log("[alphamine_perf] " .. m) end

-- highest non-air cell (y + 1) of the columns under the player's box at (x, z) and 1 block ahead
local function ground(x, z, dx, dz)
    local chunks = require "alphamine:chunks"
    local top = nil
    for _, a in ipairs({0, 1}) do
        for _, ox in ipairs({-0.3, 0.3}) do
            for _, oz in ipairs({-0.3, 0.3}) do
                local bx, bz = math.floor(x + ox + dx * a), math.floor(z + oz + dz * a)
                for y = 127, 0, -1 do
                    local id, _, ok = chunks.get(bx, y, bz)
                    if not ok then break end
                    if id ~= 0 then
                        if not top or y + 1 > top then top = y + 1 end
                        break
                    end
                end
            end
        end
    end
    return top
end

local function glide_tick(o, pl, tick)
    local r = math.rad(o.yaw)
    local dx, dz = -math.sin(r), math.cos(r)
    -- back onto the line (the spawn is +-10 off): lateral correction at most `speed` per tick
    local lat = (pl.x - o.ax) * dz - (pl.z - o.az) * (-dx)
    local c = math.max(-o.speed, math.min(o.speed, -lat))
    local nx, nz = pl.x + dx * o.speed + dz * c, pl.z + dz * o.speed - dx * c
    local top = ground(nx, nz, dx, dz)
    local ny = top and (top + 0.001) or pl.bb[2]
    pl.physics = false
    pl.mx, pl.my, pl.mz = 0, 0, 0
    pl.on_ground = true
    pl.yaw, pl.pitch = o.yaw, o.pitch
    -- set_position takes the eye-level y (posY = minY + yOffset 1.62)
    pl.set_position(nx, ny + (pl.y - pl.bb[2]), nz)
    pl.last_move_tick = tick
end

function M.configure(opts)
    M.opts = {}
    for k, v in pairs(DEFAULTS) do M.opts[k] = v end
    for k, v in pairs(opts or {}) do M.opts[k] = tonumber(v) or v end
    M.active, M.phase, M.t, M.ready_tick = true, 0, 0, nil
    M.turn_left, M.turn_sign, M.aimed = 0, 1, false
    M.jump_next = false
    M.stats = {jumps = 0, blocked = 0, start = nil}
    log(("autowalk configured: stand %d walk %d settle %d ticks, yaw %s turn +-%s every %d"):format(M.opts.stand,
        M.opts.walk, M.opts.settle, tostring(M.opts.yaw), tostring(M.opts.turn), M.opts.period))
end

function M.config_normal()
    if not file.isfile("export:alphamine_autowalk.txt") then return false end
    local opts = {}
    for k, v in (file.read("export:alphamine_autowalk.txt") or ""):gmatch("([%w_]+)%s*=%s*([%-%w_%.]+)") do
        opts[k] = v
    end
    M.configure(opts)
    return true
end

-- per Alpha tick, before player physics: returns strafe, forward, jump overrides (nil = keyboard)
-- game: alphamine:game, pl: alphamine:player
function M.tick(game, pl, perf)
    if not M.active then return nil end
    local o = M.opts
    if M.phase == 0 then
        -- in the world: also with GuiIngameMenu open (a normal launch opens it when the window loses focus; Alpha
        -- SMP keeps running then)
        local ingame = (game.screen == "ingame" or game.screen == "GuiIngameMenu") and pl.has_pos
        local login = game.stats.login_tick
        if ingame and (game.map_chunks >= o.chunks or (login and game.tick - login >= o.wait)) then
            M.phase, M.t = 1, 0
            M.stats.start = {tick = game.tick, x = pl.x, z = pl.z, map_chunks = game.map_chunks}
            log(("autowalk start at tick %d, map_chunks %d, player %.2f %.2f"):format(game.tick, game.map_chunks,
                pl.x, pl.z))
            if tonumber(o.menu) == 1 then
                -- menu=1: GuiIngameMenu open for the whole run, as when the window loses focus (perf diagnostics)
                local g = require "alphamine:gui"
                if g.screen ~= "GuiIngameMenu" then g.open_menu() end
                log("autowalk: GuiIngameMenu opened (menu=1)")
            end
        end
        if perf then perf.phase = M.phase end
        return nil
    end
    M.t = M.t + 1
    local strafe, forward, jump = 0, 0, false
    if M.phase == 1 then
        if M.t >= o.stand then M.phase, M.t = 2, 0 end
    end
    if M.phase == 2 and tonumber(o.glide) == 1 then
        -- World.updateEntity: no move while the chunks around are missing (the walk then waits for the server)
        if pl.can_update() then glide_tick(o, pl, game.tick) else M.stats.waits = (M.stats.waits or 0) + 1 end
        if M.t % 100 == 0 then
            log(("autowalk t %d glide at %.1f %.1f %.1f"):format(M.t, pl.x, pl.y, pl.z))
        end
        if M.t >= o.walk then M.phase, M.t = 3, 0 end
        if perf then perf.phase = M.phase end
        return 0, 0, false
    end
    if M.phase == 2 then
        if not M.aimed then
            -- initial heading: turn to `yaw`/`pitch` at once (like a mouse flick)
            pl.yaw, pl.pitch = o.yaw, o.pitch
            M.aimed = true
            M.base = o.yaw
            M.zig = 0
            M.check = {x = pl.x, z = pl.z, t = M.t}
            M.free = 0
        end
        forward = 1
        -- heading: base (the walk direction, detours rotate it) + zig-zag +-turn every `period` ticks
        if M.t % o.period == 0 then
            M.turn_sign = -M.turn_sign
            M.zig = o.turn * M.turn_sign
        end
        -- progress check every 40 ticks: < 2 blocks moved = stuck (2-block wall, pit) -> rotate the base by 60
        -- degrees (repeated detours sweep around); after 200 free ticks the base drifts back to `yaw`
        if M.t - M.check.t >= 40 then
            local d = math.sqrt((pl.x - M.check.x) ^ 2 + (pl.z - M.check.z) ^ 2)
            if d < 2 then
                M.base = M.base + 60
                M.free = 0
                M.stats.detours = (M.stats.detours or 0) + 1
            else
                M.free = M.free + 40
            end
            M.check = {x = pl.x, z = pl.z, t = M.t}
        end
        if M.free >= 200 and M.base ~= o.yaw then
            local back = ((o.yaw - M.base + 180) % 360) - 180
            if math.abs(back) <= 0.5 then M.base = o.yaw else M.base = M.base + (back > 0 and 0.5 or -0.5) end
        end
        local want = M.base + M.zig
        if tonumber(o.line) == 1 then
            -- detours (M.base - o.yaw) still rotate the heading while stuck; otherwise steer back onto the line
            want = line_yaw(o, pl.x, pl.z) + (M.base - o.yaw) + M.zig
        end
        local diff = ((want - pl.yaw + 180) % 360) - 180
        if diff ~= 0 then
            local step = math.max(-3, math.min(3, diff))
            pl.yaw = pl.yaw + step
        end
        if pl.collided_h or pl.in_water or pl.in_lava or M.jump_next then
            jump = true
            if pl.collided_h then M.stats.blocked = M.stats.blocked + 1 end
        end
        M.jump_next = pl.collided_h and true or false
        if M.t % 100 == 0 then
            log(("autowalk t %d at %.1f %.1f %.1f yaw %.1f base %.0f %s%s"):format(M.t, pl.x, pl.y, pl.z, pl.yaw,
                M.base, pl.in_water and "water " or "", pl.collided_h and "blocked" or ""))
        end
        if M.t >= o.walk then M.phase, M.t = 3, 0 end
    elseif M.phase == 3 then
        if M.t >= o.settle then
            M.phase = 4
            M.done_tick = game.tick
            local s = M.stats.start or {x = pl.x, z = pl.z, map_chunks = 0}
            local dist = math.sqrt((pl.x - s.x) ^ 2 + (pl.z - s.z) ^ 2)
            log(("autowalk done at tick %d: %.1f blocks from start, map_chunks %d (+%d), blocked %d ticks, detours %d"):format(
                game.tick, dist, game.map_chunks, game.map_chunks - s.map_chunks, M.stats.blocked, M.stats.detours or 0))
        end
    end
    if perf then perf.phase = M.phase end
    return strafe, forward, jump
end

-- after the walk (phase 4), optional `end` action — the menu buttons pressed through the pack's own click handler
-- (alphamine:gui.handle, the path of a real click on the document; no OS input):
--   end=disconnect  GuiIngameMenu -> "Disconnect" (the world must close to the engine menu)
--   end=lost        wait for GuiConnectFailed (the harness stops the server) -> "Back to title screen"
function M.after(game)
    local o = M.opts
    if not o or M.phase ~= 4 or not o["end"] or M.end_done then return end
    local g = require "alphamine:gui"
    local function press(text)
        for _, b in ipairs(g.buttons()) do
            if b.text == text then
                log(("end: pressing \"%s\" at %d,%d"):format(text, b.x, b.y))
                g.handle({click = {b.x, b.y}, button = 0})
                M.end_done = true
                return true
            end
        end
        return false
    end
    M.end_t = (M.end_t or 0) + 1
    if o["end"] == "disconnect" then
        if M.end_t == 20 then
            if g.screen ~= "GuiIngameMenu" then g.open_menu() end
        elseif M.end_t >= 40 then
            press("Disconnect")
        end
    elseif o["end"] == "lost" then
        if game.screen == "GuiConnectFailed" then
            M.lost_t = (M.lost_t or 0) + 1
            if M.lost_t >= 40 then press("Back to title screen") end
        end
    end
end

function M.report()
    return {active = M.active, phase = M.phase, t = M.t, opts = M.opts, stats = M.stats, done_tick = M.done_tick}
end

return M
