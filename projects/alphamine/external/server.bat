@echo off
rem AlphaMine: сервер Minecraft Alpha 1.0.16 для пака alphamine (порт 25565).
rem Запусти этот файл, затем VoxelCore -> Сценарии -> alphamine. Закрыть сервер: команда stop в этом окне.
setlocal
set REF=%~dp0ref
set PLAY=%~dp0play
set JAVA="C:\Program Files\Java\jdk1.8.0_481\bin\java.exe"
if not exist "%PLAY%\world" (
  echo Первый запуск: копирую мир из golden\world_b в play\world ...
  robocopy "%~dp0golden\world_b" "%PLAY%\world" /E /MT:16 /NFL /NDL /NJH /NJS >nul
)
if not exist "%PLAY%\server.properties" (
  (
    echo online-mode=false
    echo server-ip=127.0.0.1
    echo server-port=25565
    echo level-name=world
  ) > "%PLAY%\server.properties"
)
if not exist "%PLAY%\ops.txt" echo Player> "%PLAY%\ops.txt"
cd /d "%PLAY%"
echo Сервер AlphaMine на 127.0.0.1:25565, мир %PLAY%\world. Команды: /tp, /gamemode 1, stop.
%JAVA% -Xms1024M -Xmx1024M -cp "%REF%\minecraft_server\bin;%REF%\minecraft_server\jars\deobfuscated.jar" net.minecraft.server.MinecraftServer nogui
pause
