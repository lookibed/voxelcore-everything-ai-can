-- HUD пака: хотбар, сердца, предметы, строка версии, чат (modules/hud.lua, документ layouts/hud.xml),
-- рука от первого лица (modules/hand.lua), экраны GUI (modules/gui.lua).
local hud_mod = require "alphamine:hud"

function on_hud_open(playerid)
    hud_mod.on_hud_open(playerid)
end

function on_hud_render()
    hud_mod.on_hud_render()
end
