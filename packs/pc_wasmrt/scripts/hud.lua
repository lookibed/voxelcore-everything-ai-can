-- Esc за компьютером pc_wasmrt:pc (modules/pc_os.lua). Обработчики клавиш вызываются от последнего
-- к первому, а движковый (res/scripts/stdlib.lua: Esc — пауза / снять активный фрейм) назначается
-- до on_hud_open паков, поэтому этот срабатывает раньше и, вернув true, не пускает его.
-- istoplevel = true: работает и при захваченном фокусе (скрытое поле ввода Eaglercraft).
-- Стикер «ПКМ — сесть за компьютер» (layouts/pc_hint.xml) — постоянный элемент HUD; оверлей с кнопками
-- (layouts/pc_overlay.xml) открывает сам pc_os при входе за ПК (hud.show_overlay).
function on_hud_open()
    input.add_callback("key:escape", function()
        return require("pc_wasmrt:pc_os").on_escape()
    end, nil, true)
    local ok, err = pcall(hud.open_permanent, "pc_wasmrt:pc_hint")
    if not ok then debug.log("[pc] hint layout not opened: " .. tostring(err)) end
end
