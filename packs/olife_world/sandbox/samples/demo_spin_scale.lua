-- Пример Olife (UX A3): крутящийся увеличенный бенч с «волной» кости.
-- self:set_scale(s) — масштаб 0.1..4; self:set_rot(x, y, z) — градусы (y — рыскание);
-- self.skeleton:set_bone(имя, {pos, rot, scale}) — поза кости (кости бенча: body, rody, body1, rody1, body2, rody2).
local t = 0
self:set_scale(1.5)
print("spin_scale: bones = " .. table.concat(self.skeleton:bones(), ","))
function on_tick(dt)
    t = t + dt
    self:set_rot(0, (t * 60) % 360, 0)
    -- волна: кость body качается по z, раз в 2 такта (поза кости — действие с ценой 2 кредита)
    if math.floor(t * 20) % 2 == 0 then
        self.skeleton:set_bone("body", {rot = {0, 0, math.sin(t * 4) * 20}, pos = {0, math.abs(math.sin(t * 2)) * 0.2, 0}})
    end
end
