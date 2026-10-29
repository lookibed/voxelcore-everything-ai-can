-- Замер памяти Spider: binjgb с памятью в таблице слов (--memory table, *_tbl.lua) против Bytearray
-- (--memory bytearray, *_ba.lua). Модули — export:membench/binjgb_{tbl,ba}.lua (Spider:
-- Hosts/VoxelCore/pipeline/membench.sh translate gameboy && membench.sh install gameboy).
-- Метка в логе: [membench_gameboy]; конец — "[membench_gameboy] done".
--
-- Порядок вариантов — export:membench/gameboy_run.txt (например "ba tbl ba tbl"; по умолчанию
-- "tbl ba tbl ba"), ROM-ы — cgb-acid2 из пака и игры из config:gameboy/roms, если есть.
-- Каждый прогон: jit.flush + снятие чёрного списка с модуля (как калибровка пака), новый экземпляр,
-- ROM с начала, WARM кадров прогрева, затем MEASURE кадров: отдельно эмуляция (step_frame) и
-- перевод кадра RGB555 -> RGBA (как session:get_frame пака: у таблицы — по словам __w, у Bytearray —
-- по байтам __p). Сумма кадра в конце должна совпасть у обоих вариантов. JIT — как кнопка
-- JIT tuning пака (-loop, большой кеш трасс), в конце возвращаются значения по умолчанию.
-- Из-за «лотереи» LuaJIT (content/gameboy/OPTIMIZATION.md) смотреть на все прогоны, а не на один.

app.config_packs({ "gameboy" })
app.load_content()

local WARM, MEASURE = 30, 600
local PRESETS = { ["cgb-acid2"] = 1, tetris = 2 }
local ROMS = { "gameboy:roms/cgb-acid2.gbc" }
for _, name in ipairs({ "Super Mario Land (World).gb", "Tetris (World) (Rev 1).gb" }) do
    if file.isfile("config:gameboy/roms/" .. name) then ROMS[#ROMS + 1] = "config:gameboy/roms/" .. name end
end

local variants = { "tbl", "ba", "tbl", "ba" }
if file.isfile("export:membench/gameboy_run.txt") then
    variants = {}
    for v in file.read("export:membench/gameboy_run.txt"):gmatch("%S+") do variants[#variants + 1] = v end
end

local function log(message) debug.log("[membench_gameboy] " .. message) end

local band, rshift = bit.band, bit.rshift
local env = setmetatable({ require = function(name)
    if name == "bit" then return bit end
    error("module not found: " .. tostring(name))
end }, { __index = _G })

local chunks = {}
local function loader_of(variant)
    local path = "export:membench/binjgb_" .. variant .. ".lua"
    if not chunks[variant] then
        local chunk = assert(loadstring(file.read(path), "=" .. path))
        setfenv(chunk, env)
        chunks[variant] = { chunk = chunk, loader = chunk() }
    end
    return chunks[variant]
end

local EXPAND5 = {}
for i = 0, 31 do EXPAND5[i] = math.floor(i * 255 / 31 + 0.5) end

-- RGB555 -> RGBA: у таблицы слов — как convert_rgb555 пака; у Bytearray — байты через указатель.
local function convert(memory, ptr, pixel_count, p)
    local o = 0
    local words, bytes = rawget(memory, "__w"), rawget(memory, "__p")
    if words then
        local slot = rshift(ptr, 2) + 1
        for _ = 1, pixel_count / 2 do
            local word = words[slot]
            slot = slot + 1
            for half = 0, 1 do
                local pixel = half == 0 and band(word, 0xFFFF) or band(rshift(word, 16), 0xFFFF)
                p[o] = EXPAND5[band(rshift(pixel, 10), 31)]
                p[o + 1] = EXPAND5[band(rshift(pixel, 5), 31)]
                p[o + 2] = EXPAND5[band(pixel, 31)]
                p[o + 3] = 255
                o = o + 4
            end
        end
    else
        assert(bytes, "unknown memory layout")
        for index = ptr, ptr + pixel_count * 2 - 1, 2 do
            local pixel = bytes[index] + bytes[index + 1] * 256
            p[o] = EXPAND5[band(rshift(pixel, 10), 31)]
            p[o + 1] = EXPAND5[band(rshift(pixel, 5), 31)]
            p[o + 2] = EXPAND5[band(pixel, 31)]
            p[o + 3] = 255
            o = o + 4
        end
    end
end

local function preset_of(rom)
    local name = rom:match("([^/:]+)%.[^.]+$"):lower()
    for prefix, id in pairs(PRESETS) do
        if name:sub(1, #prefix) == prefix then return id end
    end
    return 0
end

local function run(variant, rom_path, rom)
    local m = loader_of(variant)
    jit.flush()
    jit.on(m.chunk, true)
    local wasm = m.loader()
    local memory = wasm.memory[1]
    assert(wasm.binjgb_host_reset() == 1)
    local ptr = wasm.binjgb_host_alloc(#rom)
    for i = 1, #rom do memory[ptr + i] = rom[i] end
    assert(wasm.binjgb_host_load_rom(ptr, #rom) == 1)
    assert(wasm.binjgb_host_set_input_preset(preset_of(rom_path)) == 1)
    assert(wasm.binjgb_host_start() == 1)
    local w, h = wasm.binjgb_host_get_width(), wasm.binjgb_host_get_height()
    local rgba = Bytearray(w * h * 4)
    local fb = wasm.binjgb_host_get_framebuffer_ptr()
    for _ = 1, WARM do
        assert(wasm.binjgb_host_step_frame() == 1)
        convert(memory, fb, w * h, rgba.bytes)
    end
    local emu, conv = 0, 0
    for _ = 1, MEASURE do
        local t0 = os.clock()
        assert(wasm.binjgb_host_step_frame() == 1)
        local t1 = os.clock()
        convert(memory, fb, w * h, rgba.bytes)
        emu, conv = emu + (t1 - t0), conv + (os.clock() - t1)
    end
    local sum = 0
    for i = 0, w * h * 4 - 1 do sum = (sum * 31 + rgba.bytes[i]) % 2147483647 end
    return emu, conv, sum
end

jit.opt.start("-loop", "maxtrace=8000", "maxmcode=65536")
log(("start: variants %s, %d ROM(s), warm %d, measure %d"):format(table.concat(variants, " "), #ROMS, WARM, MEASURE))
for _, rom_path in ipairs(ROMS) do
    local rom = file.read_bytes(rom_path, true)
    local sums = {}
    for _, variant in ipairs(variants) do
        local ok, emu, conv, sum = pcall(run, variant, rom_path, rom)
        if ok then
            sums[variant] = sums[variant] or sum
            log(("%s %s: emulation %.1f fps (%.2f ms/frame), convert %.2f ms/frame, total %.1f fps, sum %d%s"):format(
                rom_path:match("([^/:]+)$"), variant, MEASURE / emu, emu * 1000 / MEASURE, conv * 1000 / MEASURE,
                MEASURE / (emu + conv), sum, sums[variant] ~= sum and " (differs from the first run!)" or ""))
        else
            log(("%s %s FAIL: %s"):format(rom_path:match("([^/:]+)$"), variant, tostring(emu)))
        end
        collectgarbage("collect")
    end
    if sums.tbl and sums.ba then
        log(("%s: frames match: %s"):format(rom_path:match("([^/:]+)$"), tostring(sums.tbl == sums.ba)))
    end
end
jit.opt.start("+loop", "maxtrace=1000", "maxmcode=2048")
log("done")
