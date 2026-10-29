-- Открытие мира AlphaMine: общий код для пункта меню «Сценарии» (scripts/app/alphamine.lua), прямого запуска
-- при старте движка (tools/scenarios/alphamine_world.lua) и F2F (tools/scenarios/alphamine_f2f.lua).
-- Вызывать после app.config_packs({"base", "alphamine"}) + app.load_content() из корутины сценария.
-- Мир создаётся заново (app.new_world) поверх папки прошлого запуска; сохранённые движком чанки пак при загрузке
-- перезаписывает (блоки приходят только с сервера), см. комментарий в M.open — почему не app.delete_world.
-- opts: {connect = "host:port" | nil, user = "Player", load_distance = 16}
local M = {}
M.WORLD = "AlphaMine"

local function log(m) debug.log("[alphamine_app] " .. m) end

-- chunks.load-distance: сервер альфы шлёт квадрат ±10 чанков (441), движок грузит круг радиуса
-- load-distance (+padding) -> для углов квадрата нужно >= 15 (10·√2 ≈ 14.2 + запас).
M.LOAD_DISTANCE = 16

function M.open(app, opts)  -- app-библиотека сценария: в модулях пака глобала `app` нет
    opts = opts or {}
    local ld = opts.load_distance or M.LOAD_DISTANCE
    local old_ld = app.get_setting("chunks.load-distance")
    if old_ld ~= ld then
        app.set_setting("chunks.load-distance", ld)
        log(("chunks.load-distance %s -> %d"):format(tostring(old_ld), ld))
    end
    -- НЕ app.delete_world (E2E 01.10, agents/LESSONS.md): вне headless это не удаление, а диалог подтверждения
    -- (guiutil::confirm) на скрытой странице меню "<confirm>" с глобальным колбэком Enter, который живёт весь мир.
    -- Первый Enter в мире (чат) подтверждал удаление ОТКРЫТОГО мира: remove_all падал на открытых файлах регионов
    -- (filesystem_error с текстом Windows в cp1251), F2F-ответ с этим текстом -> "utf8 decode error" -> движок падал.
    -- При запуске мир при этом никогда и не удалялся. Удалить папку иначе паку нечем: user: не пишется без
    -- разрешения проекта write-to-user, а world: появляется только с открытым миром, когда файлы регионов уже
    -- открыты (проверено: remove_tree("world:regions") сразу после new_world -> "файл занят другим процессом").
    -- Старые данные безвредны: чанк, прочитанный с диска, пак перезаписывает (данные сервера или воздух —
    -- chunks.on_chunk_present `loaded`), сущности пака не сохраняются (save: false); в логе остаётся только
    -- "could not read entity: UID #1 is already used by an entity base:player" (сохранённый игрок движка).
    log("creating world (over the previous folder, see launch.lua)")
    app.new_world(M.WORLD, "0", "alphamine:void")
    world.set_day_time(0.5)
    world.set_day_time_speed(0)
    local pid = 0
    -- в пустом мире движок ставит точку спавна на y≈0 (Player::attemptToChooseSpawnpoint) —
    -- задаём свою и держим игрока в полёте, иначе он падает в пустоту; позицию дальше ведёт alphamine:player
    player.set_spawnpoint(pid, 8, 100, 8)
    player.set_flight(pid, true)
    player.set_noclip(pid, true)
    player.set_pos(pid, 8, 100, 8)
    player.set_vel(pid, 0, 0, 0)
    if opts.connect then
        local host, port = opts.connect:match("^(.-):(%d+)$")
        require("alphamine:game").request_connect(host, tonumber(port), opts.user)
        log("connecting to " .. opts.connect)
    end
    log(("world %s generator %s chunks %d"):format(M.WORLD, tostring(world.get_generator()), world.count_chunks()))
    log("ready")
    return old_ld
end

-- вернуть настройку пользователя, когда мир закрыт (вызывать в конце сценария, корутина живёт весь мир)
function M.restore_on_close(app, old_ld)
    if old_ld == nil then return end
    app.sleep_until(function() return not world.is_open() end, 1e12)
    app.set_setting("chunks.load-distance", old_ld)
    log("chunks.load-distance restored to " .. tostring(old_ld))
end

return M
