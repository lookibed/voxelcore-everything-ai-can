-- Olife editor overlay (layouts/editor.xml): only glue — the editor model is olife_client:olife (ui_* functions).
local O = require "olife_client:olife"

function on_open()
    O.ui_opened(document)
end

function on_close()
    O.ui_closed()
end

function on_code_edit(text) O.ui_code_edited(text) end
function on_control_key(cp)
    if cp == input.keycode("s") then O.ui_save() end
    if cp == input.keycode("r") then O.ui_run_toggle() end
end
function is_valid_name(t) return t == "" or t:match("^[%w_%-]+$") ~= nil end
function console_clear() O.ui_console_clear() end
function ui_close() O.ui_close() end
function ui_run_toggle() O.ui_run_toggle() end
function ui_save() O.ui_save() end
function ui_edit() O.ui_edit() end
function ui_tab(t) O.ui_tab(t) end
function ui_script_open(i) O.ui_script_open(i) end
function ui_script_del(i) O.ui_script_del(i) end
function ui_rename() O.ui_rename() end
function ui_pick_model(v) O.ui_pick_model(v) end
function ui_pick_texture(v) O.ui_pick_texture(v) end
function ui_apply_look() O.ui_apply_look() end
function ui_delete() O.ui_delete() end
-- UX A1: rights panel, fork, friends page
function ui_perm(i, k) O.ui_perm(i, k) end
function ui_perm_list(i) O.ui_perm_list(i) end
function ui_fork() O.ui_fork() end
function ui_friends() O.ui_friends() end
-- UX B1: profile tab — code versions
function ui_ver_open(n) require("olife_client:mobs").ui_ver_open(n) end
function ui_ver_restore(n) require("olife_client:mobs").ui_ver_restore(n) end
