-- Quake в мире: подключает пак quake, открывает мир "Quake" (создаёт, если его нет).
-- Картинка игры — HUD-оверлей wasmrt:screen, canvas + палитра на GPU (quake:wasm.json, 320x240).
app.config_packs({"base", "quake"})
app.load_content()
if file.isfile("user:worlds/Quake/world.json") then
    debug.log("[quake_world] opening world")
    app.open_world("Quake")
else
    debug.log("[quake_world] creating world")
    app.new_world("Quake", "1", "base:demo")
end
app.sleep(3)
debug.log("[quake_world] ready")
