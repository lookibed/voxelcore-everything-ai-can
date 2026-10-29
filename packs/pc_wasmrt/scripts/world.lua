-- Выход из мира: остановить программу компьютера (wasmrt возвращает настройки JIT) и встать из-за него.
function on_world_quit()
    local ok, pc_os = pcall(require, "pc_wasmrt:pc_os")
    if ok then pc_os.shutdown() end
end

-- Тестовая сборка F2F (лаборатория): обработчик команды "pc" (состояние, проекция точки экрана в окно,
-- запуск программ) регистрируется из главного состояния Lua — из корутины сценария нельзя (см. alphamine:f2f).
-- В стоковом движке f2f нет — ничего не происходит.
function on_world_open()
    local ok, pc_os = pcall(require, "pc_wasmrt:pc_os")
    if ok then pcall(pc_os.register_f2f) end
end

function on_use_on_block(x, y, z, playerid, normal)
    local pos = vec3.add({x + 0.5,y + 1.0,z + 0.5}, normal)
    local dummy = entities.spawn("pc_wasmrt:pc", pos)
end
