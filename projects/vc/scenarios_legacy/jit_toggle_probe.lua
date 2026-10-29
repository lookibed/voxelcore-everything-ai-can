-- Проверка кнопки JIT tuning: статус оптимизаций LuaJIT до открытия страницы, после
-- открытия (по умолчанию -loop и большой кеш трасс; jit.status показывает только
-- флаги, поэтому виден -loop), после клика по кнопке и после Back. Метка: [jit_toggle].
local PACK, PAGE = "doom", "doom"
local function status()
    local flags = { select(2, jit.status()) }
    local has_loop = false
    for _, f in ipairs(flags) do if tostring(f):lower() == "loop" then has_loop = true end end
    return (has_loop and "loop ON" or "loop OFF") .. "  [" .. table.concat(flags, " ") .. "]"
end
debug.log("[jit_toggle] before page: " .. status())
app.config_packs({PACK}); app.load_content(); app.tick()
menu.page = PAGE
app.sleep(0.5)
debug.log("[jit_toggle] page open: " .. status())
debug.log("[jit_toggle] click now")
app.sleep(4)
debug.log("[jit_toggle] after click: " .. status())
debug.log("[jit_toggle] press Back now")
app.sleep(4)
debug.log("[jit_toggle] after back (menu.page=" .. tostring(menu.page) .. "): " .. status())
debug.log("[jit_toggle] done")
