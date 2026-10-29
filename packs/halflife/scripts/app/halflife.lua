-- Сценарий меню «Сценарии»: Half-Life (Uplink) на странице меню wasmrt, манифест halflife:wasm.json.
-- Маркеры в логе: [wasmrt] halflife:wasm.json started, [halflife_app] ready.
app.config_packs({ "wasmrt", "halflife" })
app.load_content()
app.tick()
require("wasmrt:app").set_pending("halflife:wasm.json")
menu.page = "wasmrt_app"

events.on("wasmrt:leave_to_menu", function()
    time.post_runnable(function()
        app.reset_content()
        menu:reset()
        menu.page = "main"
    end)
end)
app.sleep(1)
debug.log("[halflife_app] ready")
