-- Olife client main menu (UX B, olife_menu): glue only — the model is olife_client:menu, the application script
-- (scripts/app/olife.lua) runs the login and the game.
local MN = require "olife_client:menu"

function on_open() MN.page_opened("menu", document) end
function on_close() MN.S.docs.menu = nil end
function ui_mn_login() MN.ui_login() end
function ui_mn_submit() MN.ui_login() end
function ui_mn_recent(i) MN.ui_recent(i) end
function ui_mn_quit() MN.ui_quit() end
