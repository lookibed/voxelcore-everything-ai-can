
local t = 0
local home = nil
on("touched", function(ev) self.state.touches = (self.state.touches or 0) + 1 end)
function on_tick(dt)
    t = t + dt
    local p = self.pos
    if home == nil then home = {p[1], p[2], p[3]} end
    local r = 2 + (self.id % 5)
    self:move_to({home[1] + math.cos(t) * r, home[2], home[3] + math.sin(t) * r})
    self:set_rot(0, (t * 45) % 360, 0)
    local near = world.entities_near(6)
    local cx, cz = 0, 0
    for i = 1, #near do cx = cx + near[i].pos[1]; cz = cz + near[i].pos[3] end
    self.state.n = (self.state.n or 0) + 1
    if self.state.n % 100 == 0 then print("alive", self.id, self.state.n, #near) end
end
