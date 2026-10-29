# Онбординг

## Где что лежит
| Путь | Что |
|---|---|
| `D:\Prog\VoxelCore\voxelcore-0.31.0_pre_gemini` = `/mnt/d/Prog/VoxelCore/voxelcore-0.31.0_pre_gemini` (**VC_ROOT**) | движок, паки (`content/`), сценарии и MCP (`tools/`), лог `latest.log`, скриншоты `artifacts/screens/`, журнал вызовов `artifacts/journal/` |
| `content/wasmrt` | рантайм wasm-программ: хост, WASI, графика (canvas / posteffect / tris), шейдеры, режим встраивания в чужой документ (`app.start(..., embed)`) |
| `content/{pong,wasmdemo,doom,quake,eaglercraft,html}` | паки-программы на wasmrt (манифесты `wasm*.json`); `html` — litehtml + QuickJS (сайт в `content/html/site/`) |
| `content/{gameboy,videoplayer}` | паки на старом хосте `wasm_host.lua` (binjgb, h264bsd + minimp4); в `deploy.sh` их нет, свои README и `OPTIMIZATION.md` с замерами |
| `content/pc_wasmrt` | компьютер `pc_wasmrt:pc` с «Windows XP» (`modules/pc_os.lua`): ярлыки Doom / Quake / Eaglercraft / видео на экране сущности через `gui.create_frame`; тестовые миры `PC Test`, `PC Test Plain` (копии «New World 1» пользователя — его мир не трогать) |
| `export/` | данные вне паков: `wasm4carts/*.lua` (151 картридж, лицензия CC BY-NC-SA), `wasmrt_manifest.txt`, `eagler_cmd.txt`, `eaglercraft/storage/` (профиль клиента), `membench/` (README, results) |
| `minecraft/` | справочные исходники Eaglercraft 1.5.2 (положил пользователь; сборка — копия в Spider) |
| `tools/lab` | **лаборатория тестов (этап 1)**: демон `labd` на Windows-Python (аренды экземпляров в Job Object, порты 25600–25699, F2F-пул, журнал, прогоны), CLI `tools/lab/lab`, MCP-мост `lab`; проекты — `tools/lab/projects/<имя>/project.toml` (см. раздел «Лаборатория» ниже) |
| `tools/mcp` | MCP-сервер `voxelcore` (`voxelcore_mcp.py`, `eagler_tools.py`, `journal.py`), консольный запуск `run_tool.py`, декодер ячеек шейдера `pixel_debug.py` |
| `tools/scenarios` | Lua-сценарии для `vc_start`, JSON-сценарии MCP `eag/*.json`, `smoke_all.py` |
| `tools/reference` | эталон: браузерный оригинал Eaglercraft в headless Edge по CDP (`edge_ref.py`), попиксельное сравнение `compare.py`; профиль Edge — `D:\Prog\VoxelCore\edge_ref_profile` (476 МБ, можно удалять) |
| `/root/Spider` | транслятор wasm → Lua (Rust), ветка `voxelcore-bytearray-memory`; форк `lookibed/Spider` (публичный) |
| `/root/Spider/Hosts/VoxelCore/` | ABI `include/vc.h`, конвейер `pipeline/deploy.sh`, `pipeline/verify.sh`, `pipeline/membench.sh` |
| `/root/Spider/Hosts/Lua/wasi.lua` | WASI на Lua (копия — `content/wasmrt/modules/wasi.lua`, раскладывает `deploy.sh wasi`) |
| `/root/Spider/tests/manual/real-world-*` | исходники и сборка программ: `pong`, `doomgeneric`, `quakegeneric`, `eaglercraft`, `html`, `wasmrt-demo`, `wasi-hello` |
| `/root/Spider/tests/manual/wasm4-carts` | 151 публичный картридж WASM-4 (`.wasm`) + `translate.sh` |
| `/root/tools/` | JDK 17 (`jdk-17.0.20.1+1`), Gradle 8.10.2, TeaVM-артефакты, **LuaJIT того же коммита, что в движке** (`luajit/src/luajit`, 2.1.1771261233 / 1c3b5a4d) |
| `/mnt/d/Backups/WASI/wasi-sdk-30.0` | wasi-sdk (clang.exe для C → wasm32-wasip1) |
| `D:\Prog\VoxelCore\voxelcore-0.31.4_win64\content\pc_wasmrt`, `test_shader_pack` | паки пользователя с приёмами передачи данных в шейдеры (эталон подходов) |
| GitHub (приватные, `gh` под `lookibed`) | `voxelcore-wasmrt` (рантайм, Hosts, инструменты, agents/), `voxelcore-pack-{pong,wasmdemo,doom,quake,gameboy,videoplayer,pc_wasmrt,eaglercraft}` — в каждом `pack/`, `src/`, README с полным путём сборки |

Node 22 (`node`) есть в WSL; в `native_server/` установлен `fake-indexeddb`.

## Начало сессии (5 минут, до любой работы)
Прошлая сессия могла оборваться (перезапуск Claude Code, убитый агент): агентов не возобновить, на диске
остаётся недоделанное. Поэтому:
1. `git -C /root/Spider status --short` и `git -C /root/Spider log --oneline -3` — что незакоммичено и от
   чего (сверить с `agents/STATUS.md`, раздел «Незакоммичено»). Незнакомые правки не собирать вслепую:
   `git diff --stat`, найти описание в STATUS/LESSONS, при сомнении спросить пользователя.
2. Свежесть модулей: `md5sum content/<пак>/modules/<модуль>.lua /root/Spider/tests/manual/<проект>/generated/<модуль>.lua`
   и дата `target/release/spider-cli` против последних `.rs` (`find Targets IR Sources -name '*.rs' -newer target/release/spider-cli`).
   Разложенный модуль может быть собран бинарником с непроверенными правками.
3. Кто жив: `vc_status` (движок), `ps aux | grep '[l]auncher.js'` (сервер Eaglercraft на :25599 — не мешает),
   `ListAgents`. Чужих `powershell.exe` / `VoxelCore.exe` быть не должно.
4. `ls -d /root/Spider/target*` — лишние `target-*` (по 2.5–8 ГБ) удалить, см. «Диск».
5. `verify.sh quick` только если машина свободна (~1 мин; после правок Rust — пересборка, минуты).

## Лаборатория `tools/lab` (аренды вместо своих портов, exe-копий и Stop-Process)
Для всех проектов (AlphaMine, wasmrt, html, ... — `tools/lab/projects/`). Подробно — `tools/lab/README.md`.
- В задании агенту: `LAB_OWNER=<имя>` и какие виды экземпляров нужны. Порты, `--dir`, exe-копии агент **не выбирает**:
  `tools/lab/lab lease <проект> <вид> --ttl 900 --start` → имя аренды, порт из 25600–25699, каталог `artifacts\lab\inst\`.
- Дальше всё по имени аренды: `lab f2f <аренда> step|shot|state ...` (~1 мс, без реле PowerShell), `lab logs <аренда>`,
  `lab call alphamine.wait '{"lease":...,"world":true}'`, `lab release <аренда>` (логи и снимки — в каталог прогона).
- `lab ps --table` — кто чем владеет. Чужую аренду изменить нельзя (`not-owner`). «Стоп» пользователя:
  `lab release --all --force` (снимает всё, что держит демон); процессы вне демона — как раньше.
- Умер экземпляр — любой вызов сразу отвечает `instance-dead` с кодом выхода и хвостом лога (не таймаутом).
- **Демон общий (этап 5, README «Этап 5»).** Субагент **никогда** не делает `lab daemon stop|restart|upgrade|drain|
  reload-core` на 25700 — демон сам отказывает (`admin-required` / `foreign-leases`, запись в `artifacts\lab\audit.jsonl`).
  Правки `labcore`/`lab.toml` проверять на своём изолированном демоне: `lab daemon start --isolated` → `lab --daemon <порт>
  ...` → `lab --daemon <порт> daemon stop`; применение на общий — главная сессия `lab daemon upgrade` (drain: ждёт конца
  аренд). В задании субагенту: `LAB_OWNER=<имя> LAB_ROLE=agent` (CLI) и `owner=<имя>, as_agent=true` (мост MCP: процесс
  моста общий с главной сессией). Устарел ли демон: `lab daemon status` (`stale`, `stale_files`).
- Демон поднимается сам при первом вызове (`lab daemon status|stop`). Его смерть убивает все тестовые экземпляры
  (Job с kill-on-close) — сирот не бывает. Лог `VC_ROOT\latest.log` зеркалится в `artifacts\lab\logs\vc_root\` при
  каждом старте (и чужом).
- Тесты: `cd /mnt/c && /mnt/c/Python313/python.exe -X utf8 -B -m pytest -p no:cacheprovider -q 'D:\Prog\VoxelCore\voxelcore-0.31.0_pre_gemini\tools\lab\tests'`
  (`LAB_SKIP_ENGINE=1 WSLENV=LAB_SKIP_ENGINE` перед командой — без запуска движка, когда ПК занят; без `WSLENV` переменная до Windows-питона не доходит).
- **Сценарии и golden (этап 2а)**: прогон — `tools/lab/lab run alphamine <сценарий> --impl vc|java [--golden]` (аренды,
  каталог `D:\Prog\AlphaMine\lab\runs\<id>`, журнал), сравнение — `lab compare <run> golden|<run>`, эталоны —
  `lab golden status alphamine --table` (fresh/stale/unverified с причинами), обновление только `lab golden promote <run>
  --reason ...` или `lab golden regen <сценарий>` (3 прогона Java). Старые `run_vc_scenario.py`/`run_u.py`/`e2e_run.py`/
  `am_scenario` сами отдают прогон демону (`--legacy` — прежний путь; lockstep пока только им).
- История и ворота (этап 2б, README «История»/«Ворота»): перед заявлением «стало лучше/хуже» — `lab history <проект>
  [--scenario X]` (все прогоны, включая 147+ старых каталогов `D:\Prog\AlphaMine\runs`), `lab gate <проект> --suite layers`
  (сравнение с лучшим записанным ± шум Java/Java; код выхода 0/1/2/3), сводка — `artifacts\lab\SUMMARY.md`, панель —
  `artifacts\lab\index.html`. Храповик поднимается только явно: `lab gate accept <проект> <run-id>`.
- **Этап 3а — правила обеспечены софтом** (README «Этап 3а»): exe движка демон запускает только тестовой сборкой с
  `--f2f` и убивает экземпляр без `hello.flags.input == "isolated"`; стоковый `VoxelCore.exe` агенту не достаётся
  (`lab lease ... runtime` — отказ `policy`). Игра пользователя — его `lab play alphamine --user` (из своего терминала),
  разовая финальная проверка главной сессией — `lab play <проект> --final-check --reason "..."` (запись
  `runtime_session` в истории). `lab ps --table` показывает и чужие процессы движка/Java (`foreign`, не убиваются).
- **Этап 4 — версии движка, headless, Olife, тесты 0.32** (README «Этап 4»): движки — `[engines.*]` в `lab.toml`
  (`v031` — по умолчанию, `v032` — `D:\Prog\VoxelCore\voxelcore-0.32_dc62ccfb` + F2F `engine\032\VoxelCoreF2F-032.exe`),
  `lab ps --table` показывает версию, история/ворота/панель группируют по `engine_version`. Вид `role = "headless"` может
  запускать стоковый exe (нет окна → нет ввода; окна проверяются EnumWindows, нашлось — убит). Админ-команды
  `--stdin-cmd` — `lab stdin <аренда> "status"`. Olife: `lab call olife.session '{"clients":2}'`, `lab run olife
  olife_consistency|olife_load|olife_negative` (паки/шлюз/песочница — заглушки). Lua-тест движка 0.32:
  `lab run vc world` (или путь к `.lua`; `--window` — F2F 0.32).
- **Замеры — только `lab perf <проект> <сценарий>`** (alphamine: `perf_normal`, `perf_walk`; скрипты
  `tools/alphamine/perf/perf_*.py` — обёртки): ждёт простоя (30 с подряд, ≤ 600 с), не дождался — отказ (код 4), занятость
  во время прогона — `contended` (ворота и `perf_compare.py` такие не сравнивают). Простой сейчас? — `lab sysload --idle`.
  Ночные ворота ставит пользователь: `lab schedule install`.
- Старые пути (`am_*`, `run_vc_scenario.py --legacy`, `server_v.py`, `eag_*`) пока работают рядом (вне аренд — видны
  как `foreign`); `vc_*` — уже через аренды (ниже «Запуск движка»).

## Первые 15 минут (новому агенту)
1. Прочитать `AGENTS.md` (правила пользователя), `agents/STATUS.md`.
2. Убедиться, что MCP `voxelcore` подключён: `vc_status`. Нет — `/mcp` (Claude Code) или регистрация
   из `tools/mcp/README.md`.
3. `cd /root/Spider && cargo build --release -p spider-cli`.
4. `/root/Spider/Hosts/VoxelCore/pipeline/verify.sh quick` — должно быть «ВСЁ ЗЕЛЁНОЕ».
5. Посмотреть живьём: `scenario_run("eag_menu")` (или `eag_start`, затем `eag_path ["Done","Singleplayer"]`).

## Как ходить по Eaglercraft: scenario_run, journal_report
Повторяющийся путь не проходить руками (в прошлой сессии один и тот же путь «профиль → Done → Singleplayer →
Create New World → сид → мир» проходился вручную шесть раз, пока не появились сценарии).
`scenario_run("eag_world")` — сервер сам запускает движок и доводит до нового мира с сидом 1234567890 и ждёт
конца пересчёта света (≈ 60–70 с, без участия агента); `scenario_run("eag_saved_world")` — первый сохранённый
мир (≈ 30 с); `scenario_run("eag_menu")` — главное меню; `scenario_run("eag_rain")` — мир с читами и
`/toggledownfall` (дождь; см. STATUS про падение). Если движок уже где-то на пути — `from="auto"` (или имя
контрольной точки: `menu`, `worlds`, `create`, `seed`, `entered`, `world`): сервер проверит состояние и
продолжит с него, а не с запуска; `until=` — остановиться на точке. Ответ: таблица шагов со временем и
пометками затыков, итоговое состояние, скриншот последнего шага.
Ждать чего-то в игре — `eag_wait(screen=..., fps=...)`, а не повторные `eag_state` и не `sleep`: `eag_state`
при долгом кадре отвечает через 5 с отчётом «кадр идёт N с».
Все вызовы `vc_*`/`eag_*` пишутся в `artifacts/journal/journal.jsonl` со скриншотом до действия;
`journal_report(last=30)` показывает, где ушло время (долгие вызовы, таймауты, клики без эффекта, паузы
агента), а удачный ручной проход сохраняется в сценарий `scenario_save(name, last=N)`. Подробно —
`tools/mcp/README.md` («Журнал», «Сценарии»).

## Ожидание долгих процессов (чтобы не «зависать»)
Что реально случалось и сколько стоило:
- `Monitor` с шаблоном по строкам fps / «Saved:» — четыре раза истёк молча (2.5, 15, 2 и 30 минут), хотя
  событие давно произошло: шаблон не совпадал (другая строка, лог в cp866). Правило: шаблон сначала
  проверить `grep` по уже существующему логу; для Windows-логов — `iconv -f cp866`; а лучше — `vc_wait_log`
  / `eag_wait`, которые знают формат `latest.log`.
- Фоновый `Bash` с `grep`-ожиданием завершался «No matches found» через десятки минут. Заменено на `eag_wait(fps=..., fps_drop=true)`.
- Фоновый `Bash` живёт ≤ 10 минут: более долгий Windows-процесс убивается по таймауту. Долгое на Windows —
  `Start-Process -FilePath ... -RedirectStandardOutput <лог> -RedirectStandardError <лог2>` (отдельный процесс),
  затем ждать по логу.
- Пауза агента > 20 с между вызовами помечается в журнале как `idle` — это и есть «подвисание» глазами
  пользователя. Если ждёшь агента-исполнителя — скажи об этом пользователю одной строкой и не трогай движок.

## Субагенты (кто что может)
- Один владелец движка в каждый момент. В задании писать явно: «движок у тебя» / «движок НЕ запускать,
  проверки только вне движка (стоковый LuaJIT `/root/tools/luajit/src/luajit`, `run_luajit.lua`)».
  Очередь: агент отчитался → остановлен → движок следующему.
- Сборка Rust — только в общем `/root/Spider/target` (`cargo build --release -p spider-cli`). Отдельный
  бинарник для эксперимента — копировать `target/release/spider-cli` в `$CLAUDE_JOB_DIR/tmp`, а не заводить
  `CARGO_TARGET_DIR=target-<имя>`.
- Убирать за собой: `export/wasmrt_manifest.txt`, `autorun_app_script.txt`, временные модули в `export/`,
  скриншоты в `$CLAUDE_JOB_DIR/tmp`, а не в `artifacts/screens` (туда — только доказательства для отчёта).
- Отчёт агента: цифры (fps, мс, размеры), пути к изменённым файлам, что проверено в движке и чем
  (сценарий / скриншот), что не проверено. Уроки — в `agents/LESSONS.md`, состояние — в `agents/STATUS.md`.
- Пользовательские данные не менять: миры (`New World 1`), `config:`, файлы в `D:\` вне VC_ROOT. Тесты — на копиях.
- Для скриншотов в мире: полдень и остановленное время суток (`pc_world.lua` делает это в `PC Test`),
  иначе на скриншоте ночь и ничего не видно.

## Диск
- WSL лежит в `D:\Backups\wsl\ext4.vhdx`; файл только растёт и сам не сжимается: удалённое внутри WSL место
  на `D:` не возвращает. В прошлой сессии четыре `target-*` агентов (8.4 ГБ) и scratchpad (3.4 ГБ) «съели»
  десятки гигабайт на `D:`. Сжатие — только пользователем из Windows: `wsl --shutdown`, затем `diskpart`:
  `select vdisk file="D:\Backups\wsl\ext4.vhdx"`, `attach vdisk readonly`, `compact vdisk`, `detach vdisk`.
- Крупное: `/root/Spider/target` 7 ГБ (пересобирается за минуты), `artifacts/journal/<дата>` по 40–80 МБ в
  день скриншотов (старые дни можно удалять), `content/html` 41 МБ, `edge_ref_profile` 476 МБ.
- Временные файлы — в `$CLAUDE_JOB_DIR/tmp` (чистится с задачей), не в `/tmp` и не в VC_ROOT.

## Запуск движка
- Из MCP: `vc_start(script=..., wait_for=..., restart=true)` — с этапа 3а это аренда `vc.dev` демона lab: тестовая
  сборка `VoxelCoreF2F.exe --f2f <порт> --f2f-clock realtime` (время идёт само, ввод ОС изолирован, окно без фокуса),
  `--dir`/`--res` как раньше (VC_ROOT). Сценарий пишется в `autorun_app_script.txt`, его запускает
  `res/project_client.lua` при старте меню. Пути сценариев: `user:tools/scenarios/<файл>.lua`. Ввод — `vc_input`
  (F2F; `vc_keys`/`vc_click` отключены), снимок — `vc_screenshot` (F2F shot). Стоковый `VoxelCore.exe` агенты не
  запускают (`play=true` — только главная сессия, с `reason`).
- Headless (без окна): `VoxelCore.exe --headless --script <файл>` — стоковый exe, агентам не запускать (этап 3а).
- Страница wasmrt с любой программой: записать манифест (`quake:wasm.json`) в `export/wasmrt_manifest.txt`,
  затем `vc_start(script="user:tools/scenarios/wasmrt_page.lua")`. Лог программы — строки `[wasmrt]`.
- Меню «Сценарии» движка (`content/<пак>/scripts/app/*.lua`: `quake`, `eaglercraft`, `html`, `pc_wasmrt`, `doom`,
  `gameboy`, `video_player`, `alphamine`) — это вход **для пользователя при сдаче**. Во время разработки паки
  запускаются напрямую при старте зеркальным сценарием из `tools/scenarios/` (`wasmrt_page.lua` + манифест,
  `pc_world.lua`, `alphamine_world.lua`), а не кликами по меню (правило пользователя 30.09); общую логику
  держать в модуле пака (`alphamine:launch`), чтобы пункт меню и прямой запуск не расходились. В модулях
  пака нет глобала `app` — передавать его параметром из сценария.
- В мире (постэффекты работают только там): `tools/scenarios/pong_world.lua`, `quake_world.lua`,
  `pc_world.lua` (компьютер pc_wasmrt, `export:pc_enter.txt` = `1` — сразу сесть).

## Данные Eaglercraft между запусками
- Клиент (`SimpleStorage`: профиль `p`, настройки `g`, список `a`) — `export/eaglercraft/storage/`;
  удалить каталог = чистый первый запуск.
- Сервер (миры) — `/root/Spider/tests/manual/real-world-eaglercraft/native_server/data/*.idb` (снимки
  fake-indexeddb, каталог задаётся `EAGLER_DATA`). Лаунчер `launcher.js` грузит снимок при старте и пишет через
  2 с после изменений; `eag_start` поднимает лаунчер сам, если порт 25599 свободен. Остановить лаунчер —
  `kill <pid>` (не `pkill -f`: шаблон есть в командной строке своей оболочки).

## Лог и отладка
- `latest.log` перезаписывается при каждом запуске движка.
- `[wasmrt] <манифест>: N fps, ...` — раз в 5 с при `"log_fps": true`; `out:`/`err:` — stdout/stderr программы.
- `[wasmrt] crash <строки>` — стек упавшей программы (переводит `eag_crash`).
- `[wasmrt] profile N samples T ms` + строки `profile <мс> <стек>` — профиль стека при `"profile": true`
  в манифесте (переводит `eag_profile`). Сэмпл снимается в точках уступки Spider (циклы), а вес сэмпла —
  время с предыдущего сэмпла внутри корутины, поэтому код без циклов, рантайм-хелперы и импорты хоста
  засчитываются стеку следующей уступки. Время вне корутины (кадр движка, GPU, хост между квантами)
  не считается: сумма T ms за 5 с показывает, какую долю времени вообще получает программа.
  Таймерного профилировщика в VoxelCore нет: `jit.profile`, `jit.util`, `package.preload`, `debug.sethook`
  отсутствуют (проверено `tools/scenarios/jit_profile_probe.lua`).
- Шейдеры отлаживаются числами в пикселях: `vc_shader_cells`, `vc_pixels` (см. `tools/mcp/README.md`).
- Прежде чем чинить «регрессию» — проверить, не ожидаемое ли это: «сломанная» модель на экране профиля
  оказалась высокополигональным скином «Baby Charles», «отсутствующий» туман — льдом ближе начала тумана
  (нашёл числовой зонд шейдера), «69 fps вместо 120» у Doom — реальным временем вместо виртуальных часов.

## Обычный LuaJIT вне движка
`/root/tools/luajit/src/luajit` — тот же LuaJIT, что в движке. Годится для логики трансляции
(`tests/manual/*/run_luajit.lua`), но не для поведения VoxelCore (см. правила).
