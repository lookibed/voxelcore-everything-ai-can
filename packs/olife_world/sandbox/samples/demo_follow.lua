-- Пример Olife: идёт за ближайшим игроком (видит на 6 блоков), держится в 2 блоках от него.
-- world.entities_near(r) — соседи из вида мира: {eid, kind, pos}; kind 1 — игрок.
local SPEED = 0.15     -- блоков за такт (3 блока в секунду)
local KEEP = 2.0       -- на каком расстоянии остановиться
local seen = false
function on_tick(dt)
    local p = self.pos
    local best, bd = nil, 1e9
    for _, e in ipairs(world.entities_near(6)) do
        if e.kind == 1 then
            local dx, dz = e.pos[1] - p[1], e.pos[3] - p[3]
            local d = dx * dx + dz * dz
            if d < bd then best, bd = e, d end
        end
    end
    if best and not seen then print("follow: player " .. best.eid .. " in sight") end
    if not best and seen then print("follow: lost the player") end
    seen = best ~= nil
    if best and bd > KEEP * KEEP then
        local d = math.sqrt(bd)
        local dx, dz = (best.pos[1] - p[1]) / d, (best.pos[3] - p[3]) / d
        local dy = math.max(-SPEED, math.min(SPEED, best.pos[2] + 1 - p[2]))
        self:move_to({p[1] + dx * SPEED, p[2] + dy, p[3] + dz * SPEED})
        self:set_rot(0, math.deg(math.atan2(dx, dz)), 0)
    end
end
