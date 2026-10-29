-- Пример Olife (UX A3): смена текстуры раз в N тактов.
-- self:set_texture(слот, текстура): слот "$0".."$5" или "*" (все шесть граней); текстура — из пака
-- (blocks:stone, blocks:planks, ...) или актив хранилища моба "asset:<sha>".
local N = 40                      -- тактов (2 с)
local TEX = {"blocks:planks", "blocks:stone", "blocks:green_lamp", "blocks:red_lamp", "blocks:metal"}
local i, n = 0, 0
function on_tick(dt)
    n = n + 1
    if n % N == 1 then
        i = i % #TEX + 1
        self:set_texture("*", TEX[i])
        self:text3d("texture " .. TEX[i], {1, 1, 0.6})
    end
end
