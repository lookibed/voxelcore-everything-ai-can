-- Проба HUD-оверлея плеера: открывает мир "New World" (пак videoplayer включён).
app.config_packs({"videoplayer"})
app.load_content()
debug.log("[video_world] opening world")
app.open_world("New World")
app.sleep(3)
debug.log("[video_world] ready")
