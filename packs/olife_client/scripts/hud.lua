-- olife_client: HUD events (windowed client only). The hud player becomes the client player (camera mode) and gets
-- the Olife tools; every frame the bench name tags follow the replica and the editor heartbeat runs.
local olife = require "olife_client:olife"

function on_hud_open(playerid)
    olife.on_hud_open(playerid)
    require("olife_client:chat").on_hud_open(playerid)     -- UX A2: chat overlay (T / Enter) and HUD feed
    require("olife_client:mobs").on_hud_open(playerid)     -- UX B1: my-mobs panel (M), mob camera (V)
    -- UX B (olife_menu): the status of the connection in the game (packs on the fly, world restarting, reconnect)
    pcall(hud.open_permanent, "olife_client:olife_status")
end

function on_hud_render()
    olife.frame()
    require("olife_client:mobview").frame()                -- UX A3: script-set look, animation, text line (after looks)
    require("olife_client:chat").frame()
    require("olife_client:mobs").frame()                   -- UX B1: selection marker/highlight, mob camera
    require("olife_client:status_view").render_all()        -- UX B: HUD status element
end
