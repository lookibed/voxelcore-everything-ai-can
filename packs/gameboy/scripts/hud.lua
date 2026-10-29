-- В мире с включённым паком эмулятор открывается HUD-оверлеем.
function on_hud_open()
    hud.show_overlay("gameboy:emulator", false)
end
