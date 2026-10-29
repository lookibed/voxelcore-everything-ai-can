-- Проба: средняя яркость кадров видео (чтобы отличить затемнение от поломки декодера).
app.config_packs({"videoplayer"})
app.load_content()
local decoder = require "videoplayer:decoder"
local session = decoder.create_session("config:videoplayer/videos/ricroll-h264bsd.mp4")
for _, index in ipairs({ 0, 10, 20, 29 }) do
    local frame = session:decode_frame(index)
    local p, sum = frame.rgba.bytes, 0
    local n = frame.width * frame.height
    for i = 0, n - 1 do
        sum = sum + p[i * 4] + p[i * 4 + 1] + p[i * 4 + 2]
    end
    debug.log(("[brightness] frame %d %dx%d mean=%.1f"):format(index, frame.width, frame.height, sum / (n * 3)))
end
debug.log("[brightness] done")
