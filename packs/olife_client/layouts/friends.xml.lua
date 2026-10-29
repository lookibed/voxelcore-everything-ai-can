-- Olife friends page (layouts/friends.xml): glue only — the model is olife_client:olife (UX A1).
local O = require "olife_client:olife"

function on_open() O.fr_opened(document) end
function on_close() O.fr_closed() end
function ui_fr_add() O.ui_fr_add() end
function ui_fr_accept(i) O.ui_fr_accept(i) end
function ui_fr_deny(i) O.ui_fr_deny(i) end
function ui_fr_remove(i) O.ui_fr_remove(i) end
function ui_fr_close() O.ui_fr_close() end
function ui_fr_back() O.ui_fr_back() end
