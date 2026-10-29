-- Проба звука эмулятора: сессия с audio_enabled, 120 кадров, сколько байт PCM ушло в поток.
app.config_packs({"gameboy"})
app.load_content()
local function log(m) debug.log("[gameboy_audio] " .. m) end

local emulator = require "gameboy:emulator"
local ok, err = pcall(function()
    local session = emulator.create_session("config:gameboy/roms/Tetris (World) (Rev 1).gb", { audio_enabled = true })
    session:start()
    log(("audio_active=%s speaker=%s"):format(tostring(session.audio_active), tostring(session.audio_speaker)))
    -- pump_audio вызывается внутри step_frame; оборачиваем, чтобы посчитать байты
    local pump = session.pump_audio
    local total = 0
    session.pump_audio = function(self)
        local size = pump(self)
        total = total + size
        return size
    end
    for _ = 1, 120 do
        session:step_frame()
    end
    log(("120 frames, pcm bytes fed=%d (~%.2fs of 44.1kHz stereo s16)"):format(total, total / (44100 * 4)))
    session:set_audio_enabled(false)
    log("audio disabled ok, active=" .. tostring(session.audio_active))
end)
log(ok and "done" or ("FAIL: " .. tostring(err)))
