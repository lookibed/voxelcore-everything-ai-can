-- Пример Olife: «мигает» — раз в полсекунды подпрыгивает на блок и возвращается, поворачиваясь.
local t, base, up = 0, nil, false
local PERIOD = 0.5     -- секунд между сменами
function on_tick(dt)
    t = t + dt
    local p = self.pos
    if base == nil then base = p[2] end
    if t >= PERIOD then
        t = t - PERIOD
        up = not up
        self.state.blinks = (self.state.blinks or 0) + 1
        if self.state.blinks % 10 == 0 then print("blink #" .. self.state.blinks) end
    end
    local target = base + (up and 1.0 or 0.0)
    self:move_to({p[1], p[2] + (target - p[2]) * 0.5, p[3]})
    self:set_rot(0, up and 45 or 0, 0)
end
