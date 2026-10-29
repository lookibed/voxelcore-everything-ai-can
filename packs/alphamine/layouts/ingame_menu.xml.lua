-- GuiIngameMenu: построение — modules/gui.lua
function on_open()
    require("alphamine:gui").attach(document)
end

function on_close()
    require("alphamine:gui").detach()
end
