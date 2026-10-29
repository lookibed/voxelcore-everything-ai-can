-- Сценарий меню "Сценарии": запускает видеоплеер без открытия мира.
app.config_packs({"videoplayer"})
app.load_content()
app.tick()
menu.page = "player"

-- Событие приходит, когда корутина сценария уже завершилась, а перезагружать контент
-- можно только из неё или из post_runnable (stdlib: call_in_app_script_co).
events.on("videoplayer:leave_to_menu", function()
    time.post_runnable(function()
        app.reset_content()
        menu:reset()
        menu.page = "main"
    end)
end)
