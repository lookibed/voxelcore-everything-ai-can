-- Quake поверх мира: HUD-оверлей wasmrt:screen с canvas и палитрой на GPU (wasm.json) —
-- полное разрешение 320x240. Вариант с постэффектом (wasm_post.json) уменьшает кадр до 120x90
-- (предел uniform-массива) — только для сравнения, по умолчанию не используется.
function on_hud_open()
    -- с паком pc_wasmrt Quake запускается ярлыком на экране компьютера pc_wasmrt:pc, не оверлеем
    if pack.is_installed("pc_wasmrt") then return end
    require("wasmrt:app").show_overlay("quake:wasm.json")
end
