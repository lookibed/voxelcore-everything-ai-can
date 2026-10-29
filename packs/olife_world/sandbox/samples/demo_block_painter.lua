-- Пример Olife (UX A3): рисует блоками под собой и читает результат.
-- block.fill_area(x0,y0,z0, x1,y1,z1, блок) — до 4096 блоков, мир ставит частями по тактам (событие fill_done);
-- block.get_area(...) — срез до 4096 блоков: area.get(x,y,z), area.palette; block.get(x,y,z) — один блок.
local COLORS = {"base:planks", "base:stone", "base:dirt"}
local i, n = 0, 0
on("fill_done", function(ev)
    local p = self.pos
    local x, y, z = math.floor(p[1]), math.floor(p[2]) - 2, math.floor(p[3])
    local area = block.get_area(x - 2, y, z - 2, x + 1, y, z + 1)
    local count = 0
    for dx = -2, 1 do for dz = -2, 1 do
        if area and area.get(x + dx, y, z + dz) == COLORS[i] then count = count + 1 end
    end end
    print(("painter: %s placed=%d, read back %d/16 of %s"):format(ev.type, ev.placed, count, COLORS[i]))
end)
function on_tick(dt)
    n = n + 1
    if n % 100 == 1 then                      -- раз в 5 с — новый цвет 4x4 на 2 блока ниже бенча
        i = i % #COLORS + 1
        local p = self.pos
        local x, y, z = math.floor(p[1]), math.floor(p[2]) - 2, math.floor(p[3])
        block.fill_area(x - 2, y, z - 2, x + 1, y, z + 1, COLORS[i])
    end
end
