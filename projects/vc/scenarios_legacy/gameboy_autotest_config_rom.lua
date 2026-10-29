-- Автотест UI эмулятора: страница emulator, запуск ROM-а через событие gameboy:open_rom.
-- Маркеры в latest.log: [gameboy_autotest]. Путь ROM-а можно поменять ниже.
local ROM = "config:gameboy/roms/Tetris (World) (Rev 1).gb"
local RUN_SECONDS = 20

app.config_packs({"gameboy"})
app.load_content()
app.tick()
menu.page = "emulator"
app.sleep(0.5)

debug.log("[gameboy_autotest] start " .. ROM)
events.emit("gameboy:open_rom", ROM)
app.sleep(RUN_SECONDS)
debug.log("[gameboy_autotest] ready")
