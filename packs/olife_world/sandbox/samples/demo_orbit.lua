-- Пример Olife: облёт по кругу. on_tick(dt) вызывается 20 раз в секунду в песочнице.
-- self.pos — позиция {x, y, z}; self:move_to({x, y, z}) — шаг не больше 2 блоков за такт.
local t, home = 0, nil
local R = 2.0          -- радиус круга, блоков
local SPEED = 1.0      -- радиан в секунду
function on_tick(dt)
    t = t + dt
    local p = self.pos
    if home == nil then home = {p[1] - R, p[2], p[3]} end   -- круг проходит через точку старта
    self:move_to({home[1] + math.cos(t * SPEED) * R, home[2], home[3] + math.sin(t * SPEED) * R})
    self:set_rot(0, (t * 45) % 360, 0)
    self.state.n = (self.state.n or 0) + 1
    if self.state.n % 100 == 0 then print("orbit: lap time " .. math.floor(t) .. " s") end
end
