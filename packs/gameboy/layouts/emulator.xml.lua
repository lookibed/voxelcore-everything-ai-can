-- HUD-оверлей использует ту же логику, что и страница меню: исполняем её скрипт
-- в окружении этого документа (document, обработчики onclick и on_open — здесь).
local path = "gameboy:layouts/pages/emulator.xml.lua"
local chunk = assert(loadstring(file.read(path), "=" .. path))
setfenv(chunk, getfenv(1))
chunk()
