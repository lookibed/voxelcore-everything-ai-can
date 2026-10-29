-- Бенчмарк декодера videoplayer с настройкой JIT (-loop + большой кеш трасс, wasm_host.set_jit_tuned) и без: полный предекод ролика, как в плеере
-- (decode_frame(0..N) до конца, с переводом в RGBA). Режим JIT и видео берутся из
-- export:h264bench/config.lua ({ jit = "default" | "noloop", video = путь }), если он есть.
-- Метка: [h264bench].
local config = { jit = "noloop", video = "config:videoplayer/videos/ricroll-h264bsd.mp4" }
if file.isfile("export:h264bench/config.lua") then
    config = assert(loadstring(file.read("export:h264bench/config.lua")))()
end
local function log(m) debug.log("[h264bench] " .. m) end

app.config_packs({"videoplayer"}); app.load_content()
local wasm_host = require "videoplayer:wasm_host"
wasm_host.set_jit_tuned(config.jit == "noloop")
local decoder = require "videoplayer:decoder"

local aborts, started = 0, 0
jit.attach(function(what) if what == "start" then started = started + 1 elseif what == "abort" then aborts = aborts + 1 end end, "trace")
local t0 = os.clock()
local session = decoder.create_session(config.video)
local frames, per_frame = 0, {}
while true do
    local c = os.clock()
    local frame = session:decode_frame(frames)
    if not frame then break end
    per_frame[#per_frame + 1] = os.clock() - c
    frames = frames + 1
end
local total = os.clock() - t0
log(("RESULT jit=%s video=%s frames=%d total=%.2fs first=%.3fs last=%.3fs | traces start=%d abort=%d"):format(
    config.jit, config.video:match("[^/]+$"), frames, total, per_frame[1] or 0, per_frame[#per_frame] or 0, started, aborts))
wasm_host.set_jit_tuned(false)
log("done")
