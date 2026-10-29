-- Смена ROM без перезапуска: Tetris -> Super Mario Land. fps второго ROM должен быть как
-- при старте с нуля (перед новым экземпляром сбрасываются трассы JIT). Маркеры: [gameboy_switch] ...
app.config_packs({"gameboy"})
app.load_content()
app.tick()
menu.page = "emulator"
app.sleep(0.5)
events.emit("gameboy:open_rom", "config:gameboy/roms/Tetris (World) (Rev 1).gb")
app.sleep(12)
debug.log("[gameboy_switch] tetris")
app.sleep(3)
events.emit("gameboy:open_rom", "config:gameboy/roms/Super Mario Land (World).gb", "none")
app.sleep(12)
debug.log("[gameboy_switch] sml")
app.sleep(30)
debug.log("[gameboy_switch] done")
