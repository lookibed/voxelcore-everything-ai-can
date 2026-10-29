-- Olife status in the game (UX B, olife_menu): HUD element, glue only (olife_client:status / status_view / menu).
local V = require "olife_client:status_view"
local MN = require "olife_client:menu"

function on_open() V.attach("hud", document, "hud") end
function on_close() V.detach("hud") end
function ui_st_retry() MN.request("retry") end
function ui_st_back() MN.request("back") end
