-- GuiInventory: построение — modules/inventory_gui.lua
function on_open()
    require("alphamine:inventory_gui").attach(document)
end

function on_close()
    require("alphamine:inventory_gui").detach()
end
