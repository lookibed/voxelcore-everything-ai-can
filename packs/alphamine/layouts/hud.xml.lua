-- документ HUD альфы: построение и обновление — modules/hud.lua (on_hud_render скрипта пака)
function on_open()
    require("alphamine:hud").attach(document)
end
