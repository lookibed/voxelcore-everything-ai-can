-- Сценарий меню "Сценарии": запускает эмулятор без открытия мира.
app.config_packs({"gameboy"})
app.load_content()
app.tick()
menu.page = "emulator"

-- Событие приходит, когда корутина сценария уже завершилась, а перезагружать контент
-- можно только из неё или из post_runnable (stdlib: call_in_app_script_co).
events.on("gameboy:leave_to_menu", function()
    time.post_runnable(function()
        app.reset_content()
        menu:reset()
        menu.page = "main"
    end)
end)
