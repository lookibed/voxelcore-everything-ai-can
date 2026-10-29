-- Olife Spammer library page (layouts/spammer.xml): glue only — the model is olife_client:spammer (UX B2).
local SP = require "olife_client:spammer"

function on_open() SP.ui_opened(document) end
function on_close() SP.ui_closed() end
function ui_sp_select(i) SP.ui_select(i) end
function ui_sp_rename(i) SP.ui_rename(i) end
function ui_sp_delete(i) SP.ui_delete(i) end
function ui_sp_rename_ok() SP.ui_rename_ok() end
function ui_sp_refresh() SP.ui_refresh() end
function ui_sp_close() SP.ui_close() end
function is_valid_snap_name(t) return t == "" or t:match("^[%w_ %-]+$") ~= nil end
