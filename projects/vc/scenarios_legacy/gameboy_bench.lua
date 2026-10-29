-- Сценарий-бенчмарк binjgb: старая трансляция (backups/) против новой (пак).
-- Одинаковый ROM и пресет, N кадров через host_step_frame, сверка framebuffer.
-- Результат в latest.log с меткой [gameboy_bench].

app.config_packs({"gameboy"})
app.load_content()

local ROM = "gameboy:roms/cgb-acid2.gbc"
local FRAMES = 300
local PRESET_ACID2 = 1

local CASES = {
    { "new", "gameboy:modules/binjgb/binjgb.lua" },
    { "old", "user:backups/2026-09-25/gameboy/binjgb.lua" },
    { "new", "gameboy:modules/binjgb/binjgb.lua" },
}

local function log(message)
    debug.log("[gameboy_bench] " .. message)
end

local env = setmetatable({ require = function(name)
    if name == "bit" then
        return bit
    end
    error("module not found: " .. tostring(name))
end }, { __index = _G })

local function load_generated(path)
    local chunk = assert(loadstring(file.read(path), "=" .. path))
    setfenv(chunk, env)
    return chunk()
end

local rom = file.read_bytes(ROM, true)
local sums = {}

log("start")
for _, case in ipairs(CASES) do
    local label, path = case[1], case[2]
    local ok, err = pcall(function()
        local t0 = os.clock()
        local wasm = load_generated(path)()
        local mem = wasm.memory[1]
        log(("%s instantiate %.2fs"):format(label, os.clock() - t0))

        assert(wasm.binjgb_host_reset() == 1)
        local ptr = wasm.binjgb_host_alloc(#rom)
        for i = 1, #rom do
            mem[ptr + i] = rom[i]
        end
        assert(wasm.binjgb_host_load_rom(ptr, #rom) == 1)
        assert(wasm.binjgb_host_set_input_preset(PRESET_ACID2) == 1)
        assert(wasm.binjgb_host_start() == 1)

        t0 = os.clock()
        for _ = 1, FRAMES do
            assert(wasm.binjgb_host_step_frame() == 1)
        end
        local elapsed = os.clock() - t0

        local fb, size = wasm.binjgb_host_get_framebuffer_ptr(), wasm.binjgb_host_get_framebuffer_size()
        local sum = 0
        for i = 1, size do
            sum = (sum * 31 + mem[fb + i]) % 2147483647
        end
        sums[label] = sum
        log(("%s %d frames %.2fs (%.1f fps) frame=%d fb_sum=%d"):format(
            label, FRAMES, elapsed, FRAMES / elapsed, wasm.binjgb_host_get_frame_index(), sum))
    end)
    if not ok then
        log(label .. " FAIL: " .. tostring(err))
    end
    collectgarbage("collect")
end
log("match=" .. tostring(sums.old ~= nil and sums.old == sums.new))
log("done")
