-- В мире с включённым паком плеер открывается HUD-оверлеем.
function on_hud_open()
    -- с паком pc_wasmrt плеер открывается ярлыком на экране компьютера pc_wasmrt:pc, не оверлеем
    if pack.is_installed("pc_wasmrt") then return end
    hud.show_overlay("videoplayer:player", false)
end
