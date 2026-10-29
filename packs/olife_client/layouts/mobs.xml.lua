-- Olife "my mobs" panel (layouts/mobs.xml): glue only — the model is olife_client:mobs (UX B1).
local MB = require "olife_client:mobs"

function on_open() MB.ui_opened(document) end
function on_close() MB.ui_closed() end
function ui_mb_select(i) MB.ui_select(i) end
function ui_mb_cam(i) MB.ui_cam(i) end
function ui_mb_act(op, eid) MB.ui_act(op, eid) end
function ui_mb_confirm() MB.ui_confirm() end
function ui_mb_cancel() MB.ui_cancel() end
function ui_mb_close() MB.ui_close() end
