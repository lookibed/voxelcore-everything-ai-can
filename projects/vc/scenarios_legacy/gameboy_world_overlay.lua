-- Проба HUD-оверлея: открывает мир "gameboy" (пак включён), оверлей должен появиться сам.
app.config_packs({"gameboy"})
app.load_content()
debug.log("[gameboy_world] opening world")
app.open_world("gameboy")
app.sleep(3)
debug.log("[gameboy_world] ready")
