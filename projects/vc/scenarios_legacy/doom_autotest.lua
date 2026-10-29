-- Автотест пака doom: страница doom, запуск shareware-IWAD через событие doom:open_wad.
-- Маркеры: [doom] started ..., [doom_autotest] ready. Дальше можно слать клавиши через MCP vc_keys.
local WAD = "doom:wads/doom1.wad"

app.config_packs({"doom"})
app.load_content()
app.tick()
menu.page = "doom"
app.sleep(0.5)

debug.log("[doom_autotest] open " .. WAD)
events.emit("doom:open_wad", WAD)
app.sleep(4)
debug.log("[doom_autotest] ready")
