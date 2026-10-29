-- Длинный прогон: видео из export:video_autotest.txt (по умолчанию test-h264bsd) играет
-- LONG_SECONDS, каждые 5 с в лог пишется память Lua. Маркер конца: [video_long] done.
local VIDEO = "config:videoplayer/videos/test-h264bsd.mp4"
local LONG_SECONDS = 90
app.config_packs({"videoplayer"})
app.load_content()
app.tick()
menu.page = "player"
app.sleep(0.5)
events.emit("videoplayer:open_video", VIDEO, true)
local t0 = time.uptime()
while time.uptime() - t0 < LONG_SECONDS do
    app.sleep(5)
    debug.log(("[video_long] t=%.0fs lua mem %.0f MB"):format(time.uptime() - t0, collectgarbage("count") / 1024))
end
debug.log("[video_long] done")
