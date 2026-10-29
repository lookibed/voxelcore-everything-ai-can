-- Olife "typical" scripted entity (sandboxd workload::TYPICAL, world-friendly): moves on a circle through its start
-- point, turns, reads its view (world.entities_near), keeps state, reacts to events. Runs in the SANDBOX service.
local t = 0
local home = nil
on("touched", function(ev) self.state.touches = (self.state.touches or 0) + 1 end)
function on_tick(dt)
    t = t + dt
    local p = self.pos
    local r = 2 + (self.id % 3)
    if home == nil then home = {p[1] - r, p[2], p[3]} end
    self:move_to({home[1] + math.cos(t) * r, home[2], home[3] + math.sin(t) * r})
    self:set_rot(0, (t * 45) % 360, 0)
    local near = world.entities_near(6)
    local cx, cz = 0, 0
    for i = 1, #near do cx = cx + near[i].pos[1]; cz = cz + near[i].pos[3] end
    self.state.n = (self.state.n or 0) + 1
    if self.state.n % 100 == 0 then print("alive", self.id, self.state.n, #near) end
end
