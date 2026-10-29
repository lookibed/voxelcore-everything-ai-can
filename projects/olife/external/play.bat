@echo off
rem Olife: игра пользователя без WSL. Подробно - README-play.md рядом.
rem   play.bat            сервер Olife (мир D:\Prog\Olife\play\worlds) + окно VoxelCore 0.32, вход автоматически;
rem                       закрыли окно игры -> сервер сохраняет мир и останавливается, отчёт play_report.md
rem   play.bat public     то же, но сервер открыт друзьям по сети: порты 27750/27751/27752 на всех адресах,
rem                       вайтлист включён (README-play.md, "Игра с друзьями по сети")
rem   play.bat server     только сервер (без окна); игра вручную: VoxelCore 0.32 -> Сценарии -> olife
rem   play.bat server public   только сервер, открытый друзьям
rem   play.bat down       остановить сервер, поднятый play.bat server
rem   play.bat status     состояние сервера (игроки, такт мира, службы)
rem   play.bat stop       прервать сеанс play.bat (окно игры закроется)
rem   play.bat dry        проверка без окна игры (тестовый клиент, копия мира)
rem   play.bat token      показать токен аккаунта user
rem   play.bat friend НИК пустить друга: ник в вайтлист + строка для друга (ip:27750#отпечаток)
rem   play.bat ip         адреса этого ПК (LAN, VPN, внешний IP) и строки для друзей
rem   play.bat bundle     собрать архив клиента для друга в D:\Prog\Olife\dist
rem   play.bat friend-token ИМЯ   старый способ: аккаунт с токеном (токен - секрет, передавать лично)
setlocal
set PY=C:\Python313\python.exe
set LAB=D:\Prog\VoxelCore\voxelcore-0.31.0_pre_gemini\tools\lab\lab.py
set LAB_OWNER=user
set LAB_ROLE=
set CMD=%1
if "%CMD%"=="" goto play
if /I "%CMD%"=="public" goto public
if /I "%CMD%"=="server" goto server
if /I "%CMD%"=="down" goto down
if /I "%CMD%"=="status" goto status
if /I "%CMD%"=="stop" goto stop
if /I "%CMD%"=="dry" goto dry
if /I "%CMD%"=="token" goto token
if /I "%CMD%"=="friend" goto friend
if /I "%CMD%"=="ip" goto ip
if /I "%CMD%"=="bundle" goto bundle
if /I "%CMD%"=="friend-token" goto friendtoken
echo Неизвестная команда %CMD%. Команды: (пусто) public server [public] down status stop dry token friend НИК ip bundle friend-token ИМЯ
goto end

:play
echo Olife: поднимаю сервер и открываю VoxelCore 0.32 ... (окно этой консоли не закрывайте до конца игры)
"%PY%" -X utf8 -B "%LAB%" play olife --user --wait
goto end

:public
echo Olife: сервер ДЛЯ ДРУЗЕЙ (порты 27750 27751 27752 TCP на всех адресах) + VoxelCore 0.32 ... (консоль не закрывайте)
echo Строка для друга появится в отчёте сервера; сразу её покажет: play.bat ip  (в другом окне)
"%PY%" -X utf8 -B "%LAB%" play olife --user --public --wait
goto end

:server
if /I "%2"=="public" goto serverpublic
"%PY%" -X utf8 -B "%LAB%" olife play-up
echo Сервер запущен. Игра: D:\Prog\VoxelCore\voxelcore-0.32.0_dc62ccfb\VoxelCore.exe -^> Сценарии -^> olife. Остановить: play.bat down
goto end

:serverpublic
"%PY%" -X utf8 -B "%LAB%" olife play-up --public
echo Сервер для друзей запущен (строки для друга - выше). Друзьям: play.bat friend НИК. Остановить: play.bat down
goto end

:down
"%PY%" -X utf8 -B "%LAB%" olife play-down
goto end

:status
"%PY%" -X utf8 -B "%LAB%" olife play-status
goto end

:stop
"%PY%" -X utf8 -B "%LAB%" play olife stop
goto end

:dry
"%PY%" -X utf8 -B "%LAB%" play olife --dry-run
goto end

:token
type "%~dp0play\user_token.txt"
goto end

:friend
if "%2"=="" (
  echo Нужен ник: play.bat friend НИК   ^(латиница, цифры, _ . -^)
  goto end
)
"%PY%" -X utf8 -B "%LAB%" olife invite %2
goto end

:ip
"%PY%" -X utf8 -B "%LAB%" olife ip
goto end

:bundle
"%PY%" -X utf8 -B "%LAB%" olife bundle
echo Архив для друга - выше (zip). Передайте его другу вместе со строкой из play.bat friend НИК.
goto end

:friendtoken
if "%2"=="" (
  echo Нужно имя: play.bat friend-token ИМЯ
  goto end
)
"%PY%" -X utf8 -B "%LAB%" olife accounts add %2 --role player
echo Токен друга - поле "token" выше. Удобнее вход по нику: play.bat friend %2
goto end

:end
endlocal
pause
