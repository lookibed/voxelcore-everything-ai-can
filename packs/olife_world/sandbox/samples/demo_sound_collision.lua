-- Пример Olife (UX A3): ходит туда-сюда и издаёт звук при «столкновении».
-- block.raycast(откуда, направление, длина) — запрос к миру (ответ в следующем такте, вызов ждёт);
-- self:play_sound(звук, громкость, высота) — olife/ok, olife/refuse, ... или "asset:<sha>";
-- self:nearby(r) — сущности и игроки в радиусе r (запрос).
local dir, step = 1, 0.15
local home, n = nil, 0
function on_tick(dt)
    n = n + 1
    local p = self.pos
    home = home or {p[1], p[2], p[3]}
    -- стена впереди (луч на 0.8 блока) или отошли на 4 блока — звук и разворот
    local hit = block.raycast({p[1], p[2], p[3]}, {dir, 0, 0}, 0.8)
    if hit or math.abs(p[1] + dir * step - home[1]) > 4 then
        self:play_sound(hit and "olife/refuse" or "olife/ok", 0.8, hit and 0.8 or 1.2)
        dir = -dir
    else
        self:move_to({p[1] + dir * step, p[2], p[3]})
    end
    -- игрок вплотную — «столкновение» с игроком (запрос раз в 10 тактов: каждый запрос стоит 20 кредитов)
    if n % 10 == 0 then
        for _, e in ipairs(self:nearby(1.5) or {}) do
            if e.kind == 1 then self:play_sound("olife/grab", 1.0, 1.0); break end
        end
    end
end
