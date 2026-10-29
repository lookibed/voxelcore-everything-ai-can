-- Автотест плеера: страница player, открытие видео с воспроизведением через событие
-- videoplayer:open_video(path, true), несколько секунд игры. Маркеры: [video_autotest], [videoplayer] opened.
-- Видео можно подменить через export:video_autotest.txt (путь одной строкой).
local VIDEO = "videoplayer:videos/sample.mp4"
if file.isfile("export:video_autotest.txt") then
    VIDEO = file.read("export:video_autotest.txt"):gsub("%s+$", "")
end
local PLAY_SECONDS = 8

app.config_packs({"videoplayer"})
app.load_content()
app.tick()
menu.page = "player"
app.sleep(0.5)

debug.log("[video_autotest] open " .. VIDEO)
events.emit("videoplayer:open_video", VIDEO, true)
app.sleep(PLAY_SECONDS)
debug.log("[video_autotest] ready")
