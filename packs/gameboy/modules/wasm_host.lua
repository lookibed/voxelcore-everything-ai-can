-- Хост-обвязка для wasm-модулей, оттранслированных Spider в Lua (target lua-no-ffi).
-- Одинаковая копия лежит в паках gameboy, videoplayer, doom и pong.

local band, bor, lshift, rshift, tobit = bit.band, bit.bor, bit.lshift, bit.rshift, bit.tobit

local M = {}

-- Сгенерированный код делает require("bit"). В VoxelCore bit уже лежит в _G,
-- а глобальный require ищет только pack:modules/*.lua, поэтому модулю
-- подсовывается окружение со своим require.
local generated_env = setmetatable({
    require = function(name)
        if name == "bit" then
            return bit
        end
        error("generated module requested unknown module: " .. tostring(name))
    end,
}, { __index = _G })

-- chunk каждого загруженного модуля (по его загрузчику), нужен для reroll_jit.
local chunks = setmetatable({}, { __mode = "k" })

-- Загружает сгенерированный файл и возвращает его загрузчик: loader() -> экспорты.
function M.load_generated(path)
    assert(file.isfile(path), "generated module is missing: " .. path)
    local chunk = assert(loadstring(file.read(path), "=" .. path))
    setfenv(chunk, generated_env)
    local loader = chunk()
    assert(type(loader) == "function", "generated module must return a loader function: " .. path)
    chunks[loader] = chunk
    return loader
end

-- Линейная память wasm: байты упакованы по 4 в 32-битные слова memory.__w
-- (little-endian, слово k хранит адреса 4(k-1)..4(k-1)+3). Байтовый доступ
-- memory[addr + 1] идёт через метаметоды, поэтому массовые копии — по словам.
local function words_of(memory)
    local words = rawget(memory, "__w")
    assert(words, "unsupported wasm memory layout (expected packed words)")
    return words
end

-- Копирует bytes (Bytearray или table<int>) в память по адресу offset.
function M.write_bytes(memory, offset, bytes)
    local words = words_of(memory)
    local count = #bytes
    local get
    if type(bytes) == "cdata" then
        local p = bytes.bytes
        get = function(i) return p[i - 1] end
    else
        get = function(i) return bytes[i] end
    end

    local index = 1
    while index <= count and (offset + index - 1) % 4 ~= 0 do
        memory[offset + index] = get(index)
        index = index + 1
    end
    local slot = rshift(offset + index - 1, 2) + 1
    while index + 3 <= count do
        words[slot] = tobit(bor(get(index), lshift(get(index + 1), 8), lshift(get(index + 2), 16), lshift(get(index + 3), 24)))
        slot = slot + 1
        index = index + 4
    end
    while index <= count do
        memory[offset + index] = get(index)
        index = index + 1
    end
end

-- Читает length байт с адреса offset в Bytearray (новый или переданный out нужного размера).
function M.read_bytes(memory, offset, length, out)
    local words = words_of(memory)
    out = out or Bytearray(length)
    local p = out.bytes

    local index = 0
    while index < length and (offset + index) % 4 ~= 0 do
        p[index] = memory[offset + index + 1]
        index = index + 1
    end
    local slot = rshift(offset + index, 2) + 1
    while index + 3 < length do
        local word = words[slot]
        p[index] = band(word, 255)
        p[index + 1] = band(rshift(word, 8), 255)
        p[index + 2] = band(rshift(word, 16), 255)
        p[index + 3] = rshift(word, 24)
        slot = slot + 1
        index = index + 4
    end
    while index < length do
        p[index] = memory[offset + index + 1]
        index = index + 1
    end
    return out
end

-- Слова памяти для горячих циклов конвертации (см. комментарий выше про раскладку).
M.words_of = words_of

-- Настройка LuaJIT под код Spider (глобальная для всего Lua-состояния движка,
-- поэтому страницы включают её на время работы и возвращают дефолты при закрытии):
--   * maxtrace/maxmcode: большим оттранслированным модулям нужно 5-7 тысяч трасс,
--     а по умолчанию кеш вмещает 1000 трасс и 2 МБ машинного кода. При переполнении
--     LuaJIT сбрасывает все трассы и компилирует заново, и так без конца: декодер
--     h264 проводил в компиляторе ~65% времени. С большим кешем h264 и doom
--     быстрее в 3.5-5 раз.
--   * -loop: loop-оптимизация на этом коде часто обрывает компиляцию трасс, и горячие
--     циклы уходят в интерпретатор; без неё binjgb быстрее в 3-4 раза.
local JIT_TUNED = { "-loop", "maxtrace=8000", "maxmcode=65536" }
local JIT_DEFAULT = { "+loop", "maxtrace=1000", "maxmcode=2048" }

function M.set_jit_tuned(enabled)
    if not (jit and jit.opt and jit.opt.start) then
        return false
    end
    jit.opt.start(unpack(enabled and JIT_TUNED or JIT_DEFAULT))
    return true
end

-- Сбрасывает все скомпилированные трассы LuaJIT. Вызывается перед созданием нового
-- экземпляра модуля: трассы от прошлого экземпляра проверяют его замыкания, у нового
-- они другие, и горячий код идёт по медленным боковым выходам. binjgb после смены ROM
-- без сброса работал вдвое медленнее (80 fps против 160 при старте с нуля).
function M.flush_jit()
    if jit and jit.flush then
        jit.flush()
    end
end

-- Перебросок JIT для модуля: сбрасывает все трассы и снимает чёрный список со всех
-- прототипов модуля (jit.on(chunk, true) возвращает байткод ILOOP/IFUNCF в исходный вид).
-- Какой именно цикл станет корневой трассой и попадёт ли он в чёрный список, решает
-- случайность внутри LuaJIT (ГПСЧ штрафов и общие счётчики горячести по адресу байткода),
-- поэтому после переброса главный цикл модуля может скомпилироваться заметно лучше.
function M.reroll_jit(loader)
    local chunk = chunks[loader]
    if not (chunk and jit and jit.flush and jit.on) then
        return false
    end
    jit.flush()
    jit.on(chunk, true)
    return true
end

return M
