-- Загрузка модулей Spider (lua-no-ffi / lua-bytearray) и настройки LuaJIT для них.
-- Память модуля — только через экспорт __host (API Spider, не зависит от бэкенда памяти).

local M = {}

-- Сгенерированный код делает require("bit"); в VoxelCore bit уже в _G, а глобальный
-- require ищет только pack:modules, поэтому модулю подсовывается своё окружение.
local generated_env = setmetatable({
    require = function(name)
        if name == "bit" then
            return bit
        end
        error("generated module requested unknown module: " .. tostring(name))
    end,
}, { __index = _G })

local chunks = setmetatable({}, { __mode = "k" })
local cache = {}

-- Загрузчик модуля: loader(imports) -> экспорты, и host API Spider (второе значение
-- модуля; есть у модулей новых версий Spider: new_memory для картриджей, импортирующих
-- память). Загрузчики кешируются по пути.
function M.load(path)
    local cached = cache[path]
    if cached then
        return cached[1], cached[2]
    end
    assert(file.isfile(path), "wasm module is missing: " .. path)
    local chunk = assert(loadstring(file.read(path), "=" .. path))
    setfenv(chunk, generated_env)
    local loader, api = chunk()
    assert(type(loader) == "function", "not a Spider module (no loader): " .. path)
    chunks[loader] = chunk
    cache[path] = { loader, api }
    return loader, api
end

-- Убрать модуль из кеша загрузчиков (массовые прогоны).
function M.forget(path)
    cache[path] = nil
end

-- Экземпляр: сбрасывает трассы JIT (трассы прошлого экземпляра специализированы
-- на его замыкания) и проверяет, что модуль собран с __host.
function M.instantiate(loader, imports)
    M.flush_jit()
    local exports = loader(imports)
    assert(exports.__host, "module has no __host export: rebuild it with a current Spider")
    return exports
end

-- Настройка LuaJIT под код Spider (глобальная для движка; см. OPTIMIZATION.md паков):
-- большой кеш трасс и -loop. hotexit=200 (по умолчанию 10): у огромных модулей (Eaglercraft)
-- побочные трассы из выходов с сотнями живых значений раз за разом падают с
-- «register coalescing too complex», и компилятор съедал ~половину времени загрузки;
-- редкая перекомпиляция выходов результат не меняет, только время (замер в stock LuaJIT:
-- загрузка до кадра 3 20 → 9.5 с, кадр меню 175 → 42 мс).
local JIT_TUNED = { "-loop", "maxtrace=8000", "maxmcode=65536", "hotexit=200" }
local JIT_DEFAULT = { "+loop", "maxtrace=1000", "maxmcode=2048", "hotexit=10" }

-- extra — параметры jit.opt.start из манифеста ("jit_opt": ["+loop", ...]) поверх набора tuned/default;
-- действуют, пока работает программа (stop возвращает стоковые). Пример: smollm — "+loop" (LICM в матвеке).
function M.set_jit_tuned(enabled, extra)
    if jit and jit.opt and jit.opt.start then
        jit.opt.start(unpack(enabled and JIT_TUNED or JIT_DEFAULT))
        if enabled and type(extra) == "table" and #extra > 0 then
            jit.opt.start(unpack(extra))
        end
    end
end

function M.flush_jit()
    if jit and jit.flush then
        jit.flush()
    end
end

-- Перебросок JIT: сбросить трассы и снять чёрный список со всех прототипов модуля.
function M.reroll_jit(loader)
    local chunk = chunks[loader]
    if chunk and jit and jit.flush and jit.on then
        jit.flush()
        jit.on(chunk, true)
        return true
    end
    return false
end

return M
