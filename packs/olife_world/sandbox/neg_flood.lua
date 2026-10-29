-- negative: 100 actions per tick (set_pos chain of 1.9-block steps = a 120-block teleport if all were applied,
-- plus prints) -> the service keeps 64 (36 dropped), the world applies one set_pos per entity and tick
-- ("dup"/"flood" rejects), so the entity moves at most one step per tick
local dir = 1
function on_tick()
    local p = self.pos
    dir = -dir
    for i = 1, 70 do self:move_to({p[1] + dir * 1.9 * i, p[2], p[3]}) end
    for i = 1, 30 do print("flood", i) end
end
