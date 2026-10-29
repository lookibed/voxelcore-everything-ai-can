-- Переключение видео с разным разрешением: test-h264bsd (1280x720) -> ricroll (432x240)
-- -> снова test. Экран должен пересоздаваться под новый размер. Маркеры: [video_switch] step N.
app.config_packs({"videoplayer"})
app.load_content()
app.tick()
menu.page = "player"
app.sleep(0.5)
local STEPS = {
    "config:videoplayer/videos/test-h264bsd.mp4",
    "config:videoplayer/videos/ricroll-h264bsd.mp4",
    "config:videoplayer/videos/test-h264bsd.mp4",
    "videoplayer:videos/sample.mp4",
}
for i, path in ipairs(STEPS) do
    events.emit("videoplayer:open_video", path, true)
    app.sleep(6)
    debug.log(("[video_switch] step %d %s"):format(i, path))
    app.sleep(4)
end
debug.log("[video_switch] done")
