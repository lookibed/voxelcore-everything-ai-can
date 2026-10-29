-- Pong в мире: подключает пак pong, открывает мир "Pong" (создаёт, если его нет).
-- Картинка игры — постэффект pong:screen. Маркер: [pong_world] ready.
app.config_packs({"base", "pong"})
app.load_content()
if file.isfile("user:worlds/Pong/world.json") then
    debug.log("[pong_world] opening world")
    app.open_world("Pong")
else
    debug.log("[pong_world] creating world")
    app.new_world("Pong", "1", "base:demo")
end
app.sleep(3)
debug.log("[pong_world] ready")
