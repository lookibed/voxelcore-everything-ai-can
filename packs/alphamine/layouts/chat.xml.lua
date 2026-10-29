-- GuiChat: построение и модель — modules/chat_gui.lua
function on_open()
    require("alphamine:chat_gui").attach(document)
end

function on_close()
    require("alphamine:chat_gui").detach()
end

-- Enter в поле ввода движка (TextBox: defocus + consumer)
function on_submit(text)
    require("alphamine:chat_gui").on_submit(text)
end
