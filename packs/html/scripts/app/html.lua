-- Сценарий меню «Сценарии»: HTML-страница (litehtml + QuickJS-NG на wasmrt) на странице меню,
-- манифест html:wasm.json (сайт — html:site, index.html 854x480). Тот же путь, что
-- tools/scenarios/wasmrt_page.lua: wasmrt:app.set_pending + страница wasmrt_app.
-- Маркеры в логе: [wasmrt] html:wasm.json started, [html_app] ready.
app.config_packs({ "wasmrt", "html" })
app.load_content()
app.tick()
require("wasmrt:app").set_pending("html:wasm.json")
menu.page = "wasmrt_app"

-- Событие приходит, когда корутина сценария уже завершилась, а перезагружать контент
-- можно только из неё или из post_runnable (stdlib: call_in_app_script_co).
events.on("wasmrt:leave_to_menu", function()
    time.post_runnable(function()
        app.reset_content()
        menu:reset()
        menu.page = "main"
    end)
end)
app.sleep(1)
debug.log("[html_app] ready")
