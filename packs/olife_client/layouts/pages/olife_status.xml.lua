-- Olife status screen in the menu (UX B, olife_menu): glue only — the model is olife_client:status, the view
-- olife_client:status_view, requests go to olife_client:menu (the application script scripts/app/olife.lua acts).
local V = require "olife_client:status_view"
local MN = require "olife_client:menu"

function on_open()
    V.attach("page", document, "page")
    MN.page_opened("status", document)
end
function on_close() V.detach("page") end
function ui_st_retry() MN.request("retry") end
function ui_st_back() MN.request("back") end
