-- Olife Spammer HUD glue (layouts/spammer_hud.xml, UX B2)
local SP = require "olife_client:spammer"
function on_open() SP.hud_opened(document) end
