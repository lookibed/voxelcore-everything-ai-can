-- Pong поверх мира через wasmrt. Графика — постэффект (wasm.json); вариант на canvas —
-- wasm_canvas.json. Управление: стрелки вверх/вниз — ракетка, Enter — подача.
function on_hud_open()
    require("wasmrt:app").show_overlay("pong:wasm.json")
end
