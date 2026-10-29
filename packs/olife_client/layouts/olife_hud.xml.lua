-- Olife HUD toast glue (layouts/olife_hud.xml)
local O = require "olife_client:olife"
function on_open()
    O.hud_opened(document)
    require("olife_client:mobs").hud_opened(document)      -- UX B1
end
function ui_mobs() require("olife_client:mobs").toggle_panel() end    -- UX B1: HUD button
