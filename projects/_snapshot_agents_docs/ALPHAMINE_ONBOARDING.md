# AlphaMine: онбординг нулевого агента (что это, как устроено, как тестируется, какие инструменты)

Этот документ для агента, который ничего не знает о проекте. Прочитай его целиком, потом `AGENTS.md`
(правила), потом по ссылкам по мере надобности. Все пути ниже: `VC_ROOT` =
`D:\Prog\VoxelCore\voxelcore-0.31.0_pre_gemini` = `/mnt/d/Prog/VoxelCore/voxelcore-0.31.0_pre_gemini`
(каталог движка, работаем из WSL), `AM` = `D:\Prog\AlphaMine` = `/mnt/d/Prog/AlphaMine` (всё, что не рантайм).

---

## 0. Что мы делаем в одном абзаце
Мы переписываем **клиент** Minecraft Alpha 1.0.16 как **нативный пак** движка VoxelCore 0.31 (Lua, JSON-блоки,
XML-интерфейс, шейдеры пака), который играет на **оригинальном Java-сервере** альфы (протокол 14). Критерий
качества один: **попиксельное совпадение кадра с оригинальным Java-клиентом** в тех же условиях. Для этого в обе
стороны (Java-клиент, Java-сервер, тестовая сборка движка) встроен тестовый протокол **F2F** (frame-to-frame):
виртуальное время, ввод только по протоколу, снимок кадра из внутреннего буфера. Всё это гоняет **лаборатория**
(`tools/lab`): демон на Windows, аренды экземпляров, сценарии, golden-эталоны, история, ворота, панель.

Правила пользователя (обязательные, подробно в `AGENTS.md`): движок менять только для тестирования; ввод ОС
(клавиатура/мышь/фокус) агентам запрещён, это обеспечено софтом; стоковый `VoxelCore.exe` агенты не запускают
никогда; замеры производительности только на простаивающем ПК (лаборатория сама ждёт); один стандарт кадра
854×480; UI только нативным XML, рука и частицы через `gfx`; коммиты и пуши только по просьбе; инфраструктура
общая для всех проектов, не только для Minecraft.

---

## 1. Карта каталогов

| Путь | Что там |
|---|---|
| `VC_ROOT\content\alphamine\` | **пак порта** (рантайм): `modules/*.lua`, `blocks/*.json`, `layouts/*.xml`, `shaders/`, `textures/`, `models/`, `skeletons/`, `generators/void.toml`, `scripts/app/alphamine.lua` (пункт меню «Сценарии»), `README.md`, `BLOCKS_TODO.md` |
| `VC_ROOT\tools\lab\` | **лаборатория**: `labd.py` (демон), `lab` (CLI-обёртка для WSL), `lab.py`, `mcp_bridge.py` (MCP-мост), `labcore/*.py` (ядро), `projects/<проект>/{project.toml,plugin.py}`, `tests/`, `README.md` (главный справочник инструментов) |
| `VC_ROOT\tools\scenarios\alpha\*.json` | сценарии паритета (слои `layer_*`, игровые `p4_*`, интерфейс `u_*`, мир разработчика `dev_*`, E2E `e2e_*`, пробы `det_*`, `p3_*`) |
| `VC_ROOT\tools\alphamine\` | генераторы пака и вспомогательные скрипты: `gen_pack_blocks.py`, `gen_pack_items.py`, `gen_models.py`, `gen_ui_assets.py`, `gen_interact.py`, `gen_sky.py`, `gen_tables.py`+`minijava.py`, `extract_assets.py`, `gen_devworld.py`, `f2f_server.py` (lockstep), `f2f_client.py`, `am_rows.py`/`am_residual.py` (разбор остатка пикселей), `perf/` (perf-набор), `e2e/` (старый E2E-раннер), `run_vc_scenario.py`/`run_u.py`/`server_v.py` (старые раннеры, теперь обёртки над демоном) |
| `VC_ROOT\tools\mcp\` | старый MCP-сервер `voxelcore` (`vc_*`, `eag_*`, `am_*`), `run_tool.py` (вызов инструмента из консоли без MCP), `README.md` |
| `VC_ROOT\tools\reference\compare.py` | метрики сравнения картинок (identical %, tol, покрытие, bbox, diff/heat PNG) |
| `VC_ROOT\agents\` | документы: `ALPHAMINE.md` (план, результаты, числа по фазам §1–12), `F2F.md` (протокол §0–9), `LESSONS.md` (грабли), `STATUS.md`, `research/*.md` (исследования инфраструктуры) |
| `VC_ROOT\artifacts\lab\` | данные демона: `history.sqlite`, `index.html` (панель), `dashboard/alphamine.html`, `SUMMARY.md`, `gates/*.md`, `state/leases.json`, `builds/` (копии exe по sha), `inst/` (каталоги аренд) |
| `AM\ref\` | **эталон**: RetroMCP-пространство с декомпилированными исходниками Java-клиента (`minecraft/src`) и сервера (`minecraft_server/src`), скомпилированные классы (`*/bin`), `patches/` (`f2f-client.patch`, `f2f-only.patch`, `f2f-server.patch`, `f2f-server-only.patch` — от `src_original`), `compile_client.ps1`, `compile_server.ps1`, `start_client.ps1`, `start_server.ps1`, `jars/` (stock jar, ассеты) |
| `AM\engine\` | **тестовые сборки движка**: `VoxelCoreF2F.exe` (актуальная, по релизному рецепту MSYS2 clang64 + vcpkg `x64-mingw-static`, коммит 454aa205 + патч F2F), `f2f-454aa205.patch`, `build_mingw.sh`, `README.md` (как собрать, протокол, список правок), `vcpkg/`, `tests/` (тестовые миры), `userdir_*` (приватные каталоги) |
| `AM\golden\` | эталоны: `<сценарий>\*.png` + `golden.json` (паспорт) + `golden.history.jsonl`; миры `world_a`, `world_b` (эталонный сохранённый мир), `devworld` (мир со всеми блоками) |
| `AM\lab\runs\`, `AM\runs\` | прогоны лаборатории (новые) и старых раннеров (история) |
| `AM\tables\`, `AM\assets\` | таблицы блоков/предметов/рецептов, извлечённые из Java; текстуры и звуки из jar (регенерируются) |
| `AM\play\`, `AM\server.bat` | мир и запуск сервера для игры пользователя (не для агентов) |
| `D:\Prog\VoxelCore\voxelcore-0.31.0_src_pre\voxelcore-454aa205` | worktree исходников движка, ветка `f2f-454aa205` с патчем F2F |

---

## 2. Как устроен порт (пак `alphamine`)

Поток данных: **Java-сервер** → TCP (`network.tcp_connect`) → `net.lua` (разбор протокола 14 по индексам байтов) →
`game.lua` (такт альфы 20 раз/с, порядок как `Minecraft.runTick`) → `chunks.lua` (хранилище чанков альфы 16×128×16
+ перекодирование в формат движка `world.set_chunk_data`, отложенные изменения далёких чанков) → движок строит меши
и рисует их **шейдерами пака** (`shaders/main.*`, `translucent.*`, `background.*`, `entity.*`): тексели альфы, таблица
яркости и тени граней, туман, небо, вода; точный свет с сервера лежит в регионе атласа (`lightmap.lua`), свет движка
не используется (все блоки `light-passing`). Анимации воды/лавы (`texfx.lua`) воспроизводят тот же поток
`Math.random`, что у Java.

Игрок: `player.lua` + `physics.lua` + `jmath.lua` — физика альфы на Lua во float Java (совпадает до бита; тело движка
в режиме noclip лишь следует за позицией, чтобы грузились чанки), `input.lua` (WASD, прыжок, слоты, Q, I/E, T),
`fpview.lua` (камера пака: покачивание, интерполяция, взмах). Взаимодействие: `interact.lua` (луч альфы, копание
по статусам 0/1/2/3, установка с откатом, рецепты из `interact_table.lua`), `inventory.lua` (36+4+4 слота, крафт
2×2 на клиенте, как в альфе), `entities.lua` (другие игроки, предметы, вагонетки, лодки — нативные сущности со
скелетами из `gen_models.py`), `particles.lua` (`gfx.particles`, частицы копания с окном текстуры от пака).

Интерфейс только XML-документами движка: `hud.lua`+`layouts/hud.xml` (хотбар, сердца, прицел движковый с
подменённой текстурой, строка версии, чат), `gui.lua` (меню паузы с Disconnect → выход в меню движка),
`inventory_gui.lua` (экран I/E с превью игрока), `chat_gui.lua` (T, невидимый `<textbox>` как источник символов),
`font.lua`/`ui.lua` (шрифт альфы глифами-картинками, масштаб `ScaledResolution`), `hand.lua`+`skeletons/hand.json`
(рука и предмет через `gfx.skeletons` и `hud.hand_controller`).

Запуск пака: `launch.lua` (мир `AlphaMine` на `generators/void.toml`, `load-distance` 16, подключение к серверу).
Пути запуска: меню «Сценарии» → `alphamine` (для пользователя), прямой `tools/scenarios/alphamine_world.lua`
(разработка), `tools/scenarios/alphamine_f2f.lua` (F2F под лабораторией). Диагностика: `modules/f2f.lua`
(обработчик команд F2F на стороне пака: `connect`, `chat`, `state`, `wait_check`, `sync`, `layers`, `am_perf`,
`mode`), `perf.lua` (профиль подсистем в CSV), `autowalk.lua` (скриптовая ходьба без ввода ОС).

Что **генерируется**, а не правится руками: `blocks/*.json`, `textures/blocks/am_*`, `blocks_table.lua`,
`items_table.lua`, `models/amblk_*`, `BLOCKS_TODO.md` (`gen_pack_blocks.py`, умолчание `--engine-light off`);
`items/*.json` (`gen_pack_items.py`); `models/am_*`, `skeletons/am_*` (`gen_models.py`, исполняет Java-классы
моделей интерпретатором `minijava.py`); `textures/gui`, `textures/font`, `textures/particles`, `models/am_hand`,
`ui_tables.lua` (`gen_ui_assets.py`); `interact_table.lua` (`gen_interact.py`, снимает рецепты запуском классов
эталона); константы неба (`gen_sky.py`). Правишь генератор, перегенерируешь, не правишь выход.

Подробная таблица модулей — `content/alphamine/README.md`; история решений и числа — `agents/ALPHAMINE.md`.

---

## 3. Эталон (Java) и тестовый протокол F2F

**Java-клиент и сервер** лежат в `AM\ref` как декомпилированные исходники (RetroMCP). В них добавлена тестовая
инструментация (не игровая логика): в клиенте `F2FAgent`, `F2FInput`, `F2FRender`, `F2FRandom` (виртуальное время,
FBO 854×480, ввод только по протоколу, сиды всех генераторов, слои рендера, `hello.flags`), в сервере `F2FServer`
(пошаговый режим `--f2f <порт>`: `step` с барьерами по байтам клиентов, сиды, `freeze`, детерминированный порядок
отправки). Всё это — патчи `AM\ref\patches\*.patch` от `src_original`. Пересборка: `compile_client.ps1`,
`compile_server.ps1` (javac 8). Запуск руками не нужен: это делает лаборатория по дескриптору проекта.

**F2F** (`agents/F2F.md`): TCP 127.0.0.1, строка JSON = запрос, строка JSON = ответ. Команды одинаковы у Java-клиента
и у тестовой сборки движка: `hello` (impl, размер, `flags {clock, input:"isolated", window}`, `gl`, `build`),
`mode {seed}` (виртуальные часы в 0, сиды, сброс таймеров), `step {ticks, frames, partial}`, `input {keys, mouse,
chars}`, `state` (игрок, инвентарь, экран, кнопки, чат, сущности, хэш блоков), `shot {path}` (кадр из FBO → PNG,
sha256), `render {layers:{sky,clouds,terrain,water,entities,particles,weather,selection,hand,hud,gui}, fog,
lighting, clear}` (включить/выключить слои рендера на обеих сторонах), `chat`, `gui {click|key|chars}`, `wait`,
`perf` (у движка: фазы кадра, трасса для Perfetto), `quit`. У сервера: `hello`, `mode`, `step {ticks, barriers}`,
`freeze`, `state`, `quit`. Команды, которых движок не знает, уходят Lua-обработчику пака (`f2f.set_handler`).

**Тестовая сборка движка** `AM\engine\VoxelCoreF2F.exe`: стоковый движок коммита 454aa205 (тот же LuaJIT и
окружение Lua, что у рантайма пользователя; проверено дампом) плюс патч `src/devtools/f2f*` (список правок в
`AM\engine\README.md`). Флаги: `--f2f <порт>`, `--f2f-size 854x480`, `--f2f-clock virtual|realtime`,
`--f2f-window hidden|normal`, `--res`, `--dir`. Под `--f2f` колбэки клавиатуры и мыши не регистрируются вовсе,
курсор не захватывается, окно не забирает фокус. Пересборка: `AM\engine\build_mingw.sh` (MSYS2 clang64 в
`C:\msys64`, vcpkg `x64-mingw-static`, ≈50 с инкрементально).

---

## 4. Лаборатория `tools/lab` — как всё запускается

**Демон `labd`** (Windows-Python `C:\Python313`, HTTP 127.0.0.1:25700, поднимается сам при первом вызове `lab`)
владеет всеми процессами: создаёт их в Job Object (умирают вместе с арендой), выделяет порты 25600–25699,
каталоги `artifacts\lab\inst\<аренда>`, держит постоянные соединения F2F, пишет журнал и каталоги прогонов,
историю SQLite, панель. Из WSL: `tools/lab/lab <команда>` (обёртка над Windows-питоном). Из Claude Code: MCP-мост
`lab` (`.mcp.json`, инструменты `lab_ps`, `lab_lease`, `lab_release`, `lab_start`, `lab_stop`, `lab_f2f`, `lab_logs`,
`lab_runs`, `lab_run`, `lab_compare`, `lab_golden`, `lab_history`, `lab_gate`, `lab_play`, `lab_call`).

**Проект** = `tools/lab/projects/<имя>/project.toml` (виды экземпляров: `engine` — тестовая сборка с паком и
стартовым скриптом, `ref_app` — Java-клиент, `server` — Java-сервер с копией мира, `rt` — движок на реальных часах
для замеров; каталоги сценариев/golden/прогонов; настройки сравнения) + `plugin.py` (проектные команды и хуки
сценариев: `wait`, `look`, `chat_age`, `gui`, `expect`, lockstep, `session`). Зарегистрированы `alphamine`,
`wasmrt`, `vc` (универсальный dev-запуск любого пака). Ядро `labcore` ничего про Minecraft не знает.

**Аренда** (`lease`): `lab lease alphamine engine --owner X --ttl 900 --start` → `alphamine-engine-1`, порт F2F,
`lab f2f alphamine-engine-1 hello`, `lab logs ...`, `lab release ...`. `lab ps --table` показывает все аренды всех
агентов и **чужие процессы** движка/Java вне аренд (`foreign`). Чужую аренду трогать нельзя (403), снять всё разом —
только `lab release --all --force` (стоп пользователя). Экземпляр без `hello.flags.input == "isolated"` демон убивает.

**Правила, исполняемые кодом**: стоковый `VoxelCore.exe` только `lab play alphamine --user` (терминал пользователя)
или `--final-check --reason` от главной сессии; `vc_start` старого MCP теперь тоже аренда тестовой сборки в
`realtime`; `vc_keys`/`vc_click` отключены, вместо них `vc_input` (F2F). `lab perf` ждёт простоя ПК
(`lab sysload`: чужие процессы, CPU, GPU, ввод пользователя) и помечает занятые прогоны `contended`.

---

## 5. Как тестируется: сценарии, golden, сравнение, ворота

**Сценарий** — JSON в `tools/scenarios/alpha/`. Два вида. Шаговый: `base` (наследование подготовки: сервер с
копией мира, `connect`, ожидание чанков, `/tp`, `mode`), `steps` из команд F2F плюс шаги ядра (`shot`, `compare`,
`sleep`) и плагина (`look`, `wait`, `gui`, `chat_age`), `expect` после шага, `size` (854×480 по умолчанию; другой —
только явно и для обеих сторон). Таймлайн (`ticks`, `timeline` с вводом по тактам, `keyframes`, `state_every`) —
для E2E-серий. Формат целиком: `tools/lab/README.md` «Формат сценария».

**Один и тот же сценарий прогоняется на двух реализациях**: `--impl java` (эталон) и `--impl vc` (порт).
Сервер по умолчанию в **lockstep** (`server: {f2f: true}`): такт клиента → `step` сервера с барьером → без
настенных часов и случайности; `--realtime` — старый путь по часам (нужен один дымовой прогон).

```bash
tools/lab/lab run alphamine layer_terrain_flat --impl java --golden   # эталон (лучше lab golden regen)
tools/lab/lab run alphamine layer_terrain_flat --impl vc              # порт; сравнение с golden в vs_golden\
tools/lab/lab compare <runA> <runB|golden>                            # identical %, tol %, покрытие, bbox, heat
tools/lab/lab golden status alphamine                                 # fresh / stale / unverified с причинами
tools/lab/lab golden regen layer_terrain_flat                         # 3 прогона Java, обязательно идентичные → promote
tools/lab/lab history alphamine --last 30                             # таблица прогонов и процентов
tools/lab/lab gate alphamine --suite all                              # храповик: регрессии к принятому основанию
tools/lab/lab gate accept alphamine <run-id>                          # принять текущее состояние основанием (решение пользователя)
tools/lab/lab dashboard --refresh                                     # artifacts\lab\index.html
tools/lab/lab perf alphamine perf_normal --wait-idle 600              # замер только на простаивающем ПК
```
Идентификатор прогона в истории: `<каталог>/<сценарий>` (например `20261001_200334_alphamine_layer_terrain_flat_vc/layer_terrain_flat`).

**Golden** лежат в `AM\golden\<сценарий>\` с паспортом `golden.json` (ключ: хэши файла сценария и цепочки `base`,
патчей Java, jar сервера, мира, сид, размер, режим сервера, exe). Изменился ключ → `stale`/`unverified` → `regen`.
Эталон принимается только если 3 прогона Java дали побайтно одинаковые кадры. Хранилище по содержимому в
`AM\lab\store`.

**Метрика**: процент идентичных пикселей (sha RGB кадра), с допуском, покрытие (пиксели ≠ цвет очистки), разбивка
по областям (HUD, рука, мир), тепловая карта. Для серий: процент на каждом ключевом кадре, равенство `state`
(позиция бит в бит, инвентарь, хэш блоков, сущности, экран, чат) на каждом дампе, первый такт расхождения,
кривая дрейфа `drift.png`. Порог: 100 % цель; **ворота** (`lab gate`) требуют не хуже принятого основания ± ε
(ε из шума Java/Java), сами планку не поднимают. Все прогоны пишутся в историю и видны на панели.

**Методика**: паритет доказывается **послойно** — сценарии `layer_<слой>` выключают всё, кроме одного слоя
(`render {all:false, layers:{terrain:true}}`), и доводятся по очереди: terrain_flat → lighting → fog → sky → water →
clouds → hand → hud → entities → particles → selection → gui. Потом игровые (`p4_dig/place/pickup`), интерфейс
(`u_*`), мир разработчика со всеми блоками (`dev_*`, `golden\devworld`), и финальный E2E с предзаписанными
действиями по тактам (`e2e_walk1`, `e2e_dev1`). Текущие числа — `agents/ALPHAMINE.md` и панель.

---

## 6. Производительность
`lab perf alphamine <сценарий>`: экземпляр вида `rt` (тестовая сборка, реальные часы, скрытое окно), автопрогулка
пака (`autowalk.lua`, маршрут `perf_stream` через новую местность с потоком 20–50 чанков/с), профиль подсистем пака
(`perf.lua` → CSV), фазы кадра движка (`perf` F2F, трасса для Perfetto), кривая fps, сравнение прогонов
(`tools/alphamine/perf/perf_compare.py`), спарклайн на панели. Запускается только на простаивающем ПК, иначе
ждёт (до 600 с) и отказывает. Прогон с меткой `contended` в выводы не идёт. Числа «до/после» и что включено по
умолчанию — `agents/ALPHAMINE.md` §9–9.2.

---

## 7. Рабочий цикл агента (пошагово)

1. Прочитай `AGENTS.md`, этот файл, нужные разделы `ALPHAMINE.md`/`F2F.md`/`LESSONS.md`, `tools/lab/README.md`.
2. Начало: `git -C /root/Spider status --short` не нужен для AlphaMine; вместо этого `tools/lab/lab ps --table`
   (кто что держит), `tools/lab/lab golden status alphamine`, `tools/lab/lab history alphamine --last 20`.
3. Возьми владельца `export LAB_OWNER=<твоё_имя>`; все экземпляры — только через аренды/`lab run`. Никаких своих
   копий exe, портов, `Start-Process`, `Stop-Process -Name`, ввода ОС, PrintWindow для чисел.
4. Правишь пак → `lab run alphamine <сценарии слоя> --impl vc` → смотри `vs_golden\report.md` и тепловые карты →
   остаток пикселей объясняй (`am_rows.py`, `am_residual.py`), не маскируй.
5. Менял Java-эталон (только инструментация!) → перегенерируй патчи, `compile_*.ps1`, `lab golden regen` затронутых
   сценариев (3/3 идентичны обязательно), объясни отличия от прежних golden.
6. Перед отчётом: `lab gate alphamine --suite all` без регрессий; замеры — только `lab perf` и только clean.
7. Отчёт: таблица «сценарий × кадр → %», пути прогонов, что не сделано; записи в `ALPHAMINE.md` (числа),
   `LESSONS.md` (грабли), `STATUS.md`; `lab release` всего своего. Коммитов и пушей без просьбы нет.

---

## 8. Где что читать дальше
- `agents/ALPHAMINE.md` — план, фазы, таблицы процентов по слоям, решения (свет с сервера, lockstep, перф).
- `agents/F2F.md` — протокол F2F целиком (§0 изоляция, §2 команды, §6 Java, §7 слои и проценты, §8 размер и E2E,
  §9 пошаговый сервер).
- `tools/lab/README.md` — справочник лаборатории: аренды, дескрипторы, API, формат сценариев, golden, история,
  ворота, панель, play, perf, политика.
- `content/alphamine/README.md` — модули пака и как запускать.
- `AM\engine\README.md` — сборка движка и список тестовых правок.
- `AM\README.md` — эталон: как восстановить RetroMCP-пространство, собрать и запустить Java-клиент/сервер, патчи.
- `agents/LESSONS.md` — грабли по разделам AlphaMine (чего не делать второй раз).
- `agents/research/RECOMMENDATION.md` — почему инфраструктура устроена именно так.
