-- Olife chat overlay glue (layouts/chat.xml): the model is olife_client:chat
local CH = require "olife_client:chat"
function on_open() CH.ui_opened(document) end
function on_close() CH.ui_closed() end
function on_submit(text) CH.ui_submit(text) end
function ui_history(d) CH.ui_history(d) end
function ui_scroll(d) CH.ui_scroll(d) end
function ui_close() CH.ui_close() end
function on_key(cp)
    if cp == input.keycode("pageup") then CH.ui_scroll(-5) end
    if cp == input.keycode("pagedown") then CH.ui_scroll(5) end
end
