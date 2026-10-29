-- Общая логика запуска чата smollm: пункт меню «Сценарии» (scripts/app/smollm.lua) и прямой запуск при старте
-- (tools/scenarios/smollm_chat.lua) делают одно и то же. Паки грузит вызывающий (app.config_packs + load_content
-- до require этого модуля); в модулях пака нет глобала app — он передаётся параметром.
local M = {}

M.PACKS = { "wasmrt", "smollm" }
M.PAGE = "smollm_chat"
M.DEFAULT_MANIFEST = "smollm:wasm.json"

-- Манифест можно подменить файлом export:smollm_manifest.txt (например smollm:wasm_jitdefault.json для замеров).
function M.manifest()
    if file.isfile("export:smollm_manifest.txt") then
        local m = file.read("export:smollm_manifest.txt"):gsub("%s+$", "")
        if m ~= "" then return m end
    end
    return M.DEFAULT_MANIFEST
end

-- Открыть страницу чата (паки уже загружены).
function M.open_page(menu_)
    debug.log("[smollm] manifest " .. M.manifest())
    menu_.page = M.PAGE
end

-- Возврат в главное меню по событию wasmrt:leave_to_menu (reset_content — только из app-скрипта/post_runnable).
function M.bind_leave(app, menu_)
    events.on("wasmrt:leave_to_menu", function()
        time.post_runnable(function()
            app.reset_content()
            menu_:reset()
            menu_.page = "main"
        end)
    end)
end

return M
