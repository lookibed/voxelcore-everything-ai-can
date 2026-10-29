-- Input of the Alpha client (phase 3): keyboard for MovementInputFromOptions / hotbar / drop, and mouse look.
--
-- Mouse look (EntityRenderer.updateCameraAndRender -> Entity.setAngles): once per rendered frame, from the
-- native engine delta `input.get_mouse_delta()`, only while the cursor is grabbed. The engine grabs the cursor
-- itself whenever no GUI frame is active (Engine::renderFrame: in game = grabbed, pause menu / inventory =
-- released) — the same rule as Alpha's inGameHasFocus. yaw += dx*0.15, pitch -= dy*0.15 (float, clamp +-90),
-- dy > 0 = up (LWJGL); the engine's screen y grows down -> sign flip; `invert` = Alpha invertMouse.
-- In F2F the engine feeds the same delta from `input {mouse:{dx,dy}}` (dy already in LWJGL sign).
--
-- Keys (engine names): W/S/A/D forward/back/left/right, space jump (Alpha keyBind defaults; Alpha 1.0.16 has
-- no sneak key — MovementInputFromOptions knows only forward/back/left/right/jump), 1..9 hotbar, Q drop.
-- Keys are sampled per Alpha tick (state + rising edges); the per-frame hook samples too, so a press and
-- release between two ticks (fast tap at high fps) is not lost.
local M = {
    invert = false,
    f2f = false,
    keys = {forward = "key:w", back = "key:s", left = "key:a", right = "key:d", jump = "key:space",
            drop = "key:q", inventory = "key:i", inventory_e = "key:e", chat = "key:t",   -- Alpha keyBindInventory = 23 (I); E: alias (U)
            attack = "mouse:left", use = "mouse:right"},   -- U: clickMouse(0/1) (fpview.lua)
    state = {},          -- last sampled state per name
    edges = {},          -- rising edges not yet consumed by a tick
    look_dx = 0, look_dy = 0,   -- totals (stats)
    frames = 0,
}
for i = 1, 9 do M.keys["slot" .. i] = "key:" .. i end

local function pressed(code)
    local ok, v = pcall(input.is_pressed, code)
    return ok and v or false
end

-- the game has input focus: no pause menu, inventory or other GUI frame (the engine grabs the cursor then)
function M.focused()
    if M.text_input then return false end   -- GuiChat open (chat_gui.lua): keys type text, the player stands
    if hud then
        if hud.is_paused and hud.is_paused() then return false end
        if hud.is_inventory_open and hud.is_inventory_open() then return false end
    end
    if gui and gui.get_active_frame then
        local ok, f = pcall(gui.get_active_frame)
        if ok and f and f ~= "" then return false end
    end
    return true
end

M.swallowed = {}   -- keys whose press went to a closed screen: ignored until released (swallow_held)

local function sample()
    local focus = M.focused()
    for name, code in pairs(M.keys) do
        local v = focus and pressed(code) or false
        if M.swallowed[name] then
            if not pressed(code) then M.swallowed[name] = nil end
            v = false
        end
        if v and not M.state[name] then M.edges[name] = true end
        M.state[name] = v
    end
end

-- a screen that took the keyboard closes (GuiChat): Java's key events went to the screen, so a key still held is
-- neither a new press (no drop/slot/inventory edge) nor a held movement key until it is released and pressed again
function M.swallow_held()
    for name, code in pairs(M.keys) do
        -- mouse buttons are states in Java (Mouse.isButtonDown), not events: not swallowed
        if code:sub(1, 4) == "key:" and pressed(code) then M.swallowed[name] = true end
    end
end
M.sample = sample

-- per Alpha tick: current states and the rising edges since the last tick
function M.tick()
    sample()
    local e = M.edges
    M.edges = {}
    return M.state, e
end

-- MovementInputFromOptions.updatePlayerMoveState: strafe, forward, jump
function M.movement()
    local s = M.state
    local forward, strafe = 0, 0
    if s.forward then forward = forward + 1 end
    if s.back then forward = forward - 1 end
    if s.left then strafe = strafe + 1 end
    if s.right then strafe = strafe - 1 end
    return strafe, forward, s.jump and true or false
end

-- per rendered frame: mouse delta (Alpha units: dx right, dy up) or 0, 0 when the cursor is not grabbed
function M.frame()
    M.frames = M.frames + 1
    sample()
    local ok, d = pcall(input.get_mouse_delta)
    if not ok or type(d) ~= "table" then return 0, 0 end
    local dx, dy = d[1] or 0, d[2] or 0
    if dx == 0 and dy == 0 then return 0, 0 end
    if not M.focused() then return 0, 0 end
    if not M.f2f then dy = -dy end
    if M.invert then dy = -dy end
    M.look_dx, M.look_dy = M.look_dx + dx, M.look_dy + dy
    return dx, dy
end

return M
