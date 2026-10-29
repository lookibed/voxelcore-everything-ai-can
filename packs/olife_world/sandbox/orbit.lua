-- Olife scripted entity (runs in the SANDBOX service, not in VoxelCore): circles around its home point,
-- turns, and prints every 100 ticks. Script API of <olife-src>/sandboxd (self, world, on_tick, print).
local t = 0
local home = nil
function on_tick(dt)
    t = t + dt
    local p = self.pos
    local r = 2 + (self.id % 3)
    if home == nil then home = {p[1] - r, p[2], p[3]} end   -- the circle passes through the start (no teleport)
    self:move_to({home[1] + math.cos(t) * r, home[2], home[3] + math.sin(t) * r})
    self:set_rot(0, (t * 45) % 360, 0)
    self.state.n = (self.state.n or 0) + 1
    if self.state.n % 100 == 0 then print("alive", self.id, self.state.n) end
end
