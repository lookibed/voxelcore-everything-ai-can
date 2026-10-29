-- Сценарий меню «Сценарии»: Quake на странице меню wasmrt (без мира), манифест quake:wasm.json.
-- Тот же путь, что tools/scenarios/wasmrt_page.lua: wasmrt:app.set_pending + страница wasmrt_app.
-- Кнопка «Управление: …» на странице — из расширения пака (modules/qg_host.lua).
-- Маркеры в логе: [wasmrt] quake:wasm.json started, [quake_app] ready.
app.config_packs({ "wasmrt", "quake" })
app.load_content()
app.tick()
require("wasmrt:app").set_pending("quake:wasm.json")
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
debug.log("[quake_app] ready")
