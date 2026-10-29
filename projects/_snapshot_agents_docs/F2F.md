# F2F: frame-to-frame API для тестов паритета (спецификация, черновик 30.09)

Одна и та же спецификация реализуется дважды: в Java-клиенте Alpha 1.0.16 (`F2FAgent`, `F2FInput`, `F2FFrame`)
и в VoxelCore (пак `alphamine`, модуль `f2f.lua` + минимальный патч движка `src/devtools/f2f.*`). Харнесс
(Python в `tools/mcp/alpha_tools.py`) не знает, с кем говорит: ответ на `hello` одинаков по форме.

## 0. Требование пользователя: изоляция от Windows
ПК используется во время тестов. Значит: **ни один результат теста не должен зависеть от фокуса, положения
и перекрытия окон, курсора, реальных нажатий и движений мыши пользователя.** Отсюда четыре правила:

1. **Снимок — только из кадрового буфера внутри приложения**, никогда через захват окна.
   - Java: в F2F-режиме кадр рисуется в свой FBO фиксированного размера (854×480 по умолчанию,
     `GL_EXT_framebuffer_object` + depth renderbuffer), после рендера `glReadPixels` из этого FBO → PNG
     (`javax.imageio`, без сжатия-потерь), затем блит в окно только для глаз. Размер окна, его свёрнутость,
     перекрытие и DWM на содержимое FBO не влияют. `ScaledResolution`, `displayWidth/Height` и
     `glViewport` в F2F-режиме берутся из размера FBO, а не из `Display`.
   - VoxelCore (патч движка, разрешён): та же схема — команда `shot` читает пиксели кадра после
     `Engine::renderFrame` до swap (`glReadPixels` с framebuffer движка) и пишет PNG через имеющийся
     `imageio`; размер кадра в F2F-режиме фиксируется в движке (`--f2f-size 854x480`), а не через
     `settings.toml`/перемещение окон.
   - Проверка обязательна: снимок при активном окне, при окне под другим окном, свёрнутом и на другом
     виртуальном рабочем столе должен быть побайтно одинаков. Если свёрнутое окно перестаёт рендерить
     (GLFW/LWJGL дают нулевой размер), приложение в F2F-режиме запрещает сворачивание себе само
     (Java: `Display.setResizable(false)` + игнор `isVisible`; движок: не реагировать на iconify).
2. **Ввод — только по протоколу.** В F2F-режиме фасад ввода не читает `Keyboard`/`Mouse` (Java) и GLFW-колбэки
   (движок): очередь событий и состояния клавиш/кнопок/дельт наполняются командой `input`. Курсор никогда
   не захватывается (`Mouse.setGrabbed`/`glfwSetInputMode` отключены), окно не перехватывает фокус, потеря
   фокуса не даёт автопаузу (Java: `EntityRenderer:243`, `MC:461`) и не сбрасывает мышь (`MC:896`).
3. **Время — только виртуальное.** `step` продвигает часы; ни один путь кода не читает реальные часы
   (перечень мест — ниже).
4. **Инструменты ОС (`vc_keys`, `vc_click`, `vc_screenshot`, PrintWindow) — только для ручной разведки.**
   Результат, полученный через них, не считается результатом теста.

Дополнительно (по желанию, не обязательно): окна обоих приложений можно уводить на отдельный виртуальный
рабочий стол Windows (`IVirtualDesktopManager.MoveWindowToDesktop`), чтобы не мешать пользователю;
на результат это по правилу 1 влиять не должно.

## 1. Транспорт
- TCP `127.0.0.1`, одна строка JSON = один запрос, одна строка JSON = один ответ, UTF-8, `\n`-терминированы.
- Java слушает `25570`; VoxelCore — `25571` (если в Lua нет `network.tcp_open`, движковый патч поднимает
  сервер в C++; направление запросов от этого не меняется).
- Запрос: `{"id": 17, "cmd": "step", "args": {...}}`. Ответ: `{"id": 17, "ok": true, "result": {...}}` или
  `{"id": 17, "ok": false, "error": "...", "where": "..."}`. Команда выполняется в игровом потоке в точке
  кадра (см. §3), ответ уходит после её завершения. Незнакомая команда → `error: unknown-command`.
- Приложение запускается с флагом: Java `--f2f 25570 [--f2f-size 854x480]`, движок `--f2f 25571`.
  Без флага ничего из F2F не активно — поведение идентично оригиналу (это проверяется теми же снимками).
- Движок (тестовая сборка `527e3084`, 01.10): `--f2f-clock virtual|realtime` (по умолчанию `virtual` — кадры только по `step`)
  и `--f2f-window normal|hidden` (по умолчанию `normal`). **`realtime`** — главный цикл стокового движка по настенным часам
  (`glfwGetTime`, настройки framerate/vsync, адаптивный fps меню), команды обрабатываются между кадрами; `step` отвечает ошибкой
  `clock-realtime`, остальные команды (`hello/mode/render/shot/perf/input/quit`, обработчик Lua) работают. Это режим **замеров
  производительности с теми же таймингами, что у сессии пользователя**, но с изоляцией ввода. **`hidden`** — окно не показывается
  вообще; кадр рисуется в тот же FBO, `shot` побайтно равен `normal`.
- **Изоляция ввода движка безусловна под `--f2f` (оба режима часов)** — требование пользователя после замера на стоковом exe,
  окно которого реагировало на мышь, захватывало курсор и открывало паузу при смене фокуса: GLFW-колбэки клавиатуры, символов,
  кнопок мыши, курсора, колеса, размера и iconify не устанавливаются (`GLFWWindow.cpp setup_callbacks`), запрос закрытия окна
  (крестик, Alt+F4) отменяется — выход только по `quit`; курсор не захватывается и не меняет форму; `isFocused()`=true,
  `isIconified()`=false (нет автопаузы `Hud::processInput`); `app.focus()` — no-op; буфер обмена свой, системный не читается и не
  пишется. Окно создаётся невидимым (`GLFW_FOCUSED/FOCUS_ON_SHOW/AUTO_ICONIFY=false`), получает `WS_EX_NOACTIVATE` (клик по нему не
  делает его активным) и показывается `ShowWindow(SW_SHOWNOACTIVATE)`. **Агенты запускают движок для замеров только так** (F2F-сборка,
  `--f2f-clock realtime`), не стоковым `VoxelCore.exe`. Перетаскивание заголовка окна `normal` по-прежнему останавливает цикл на время
  перетаскивания (модальный цикл Windows) — для замеров, которые не должна трогать даже мышь пользователя, `--f2f-window hidden`.

## 2. Команды
| cmd | args | result |
|---|---|---|
| `hello` | — | `{impl:"java"|"vc", version:"a1.0.16"|"0.31.0-f2f", w, h, tick_ms:50, fixed:bool}` |
| `mode` | `{fixed:true, seed:int, occlusion:false, chunk_budget:"all"}` | фиксирует время, сидирует все ГСЧ (§4), отключает occlusion queries, перестраивает все чанки за кадр |
| `step` | `{ticks:N, frames:M, partial:float}` | выполняет N тиков, затем M кадров (последний с `partial`); `{tick:absolute, frame:absolute}` |
| `input` | `{keys:{"W":true,"LSHIFT":false}, mouse:{dx:0, dy:0, buttons:[true,false,false], wheel:0, x:427, y:240}, chars:"..."}` | состояние на **следующий** шаг; отличия от текущего превращаются в события (нажатие/отпускание) в порядке ключей; имена клавиш — LWJGL (`W`, `SPACE`, `ESCAPE`, `LSHIFT`...) |
| `state` | `{radius:int}` | `{player:{x,y,z,mx,my,mz,yaw,pitch,onGround,health,slot,inventory:[{id,count,meta}]}, screen:"GuiIngameMenu"|null, buttons:[{id,text,x,y,enabled}], texts:[...], world:{time, chunks:N, entities:[{id,type,x,y,z}]}, hash:{blocks:"fnv64", meta:"fnv64"}}` — хэш по кубу `radius` вокруг игрока, порядок обхода x,z,y |
| `shot` | `{path:"...png"}` | `{w,h,sha256}` — кадр последнего `step` из FBO |
| `chat` | `{text:"/tp Player 10 70 10"}` | отправить в чат (позиция через сервер, одинаково для обеих сторон) |
| `gui` | `{click:[x,y], button:0}` или `{key:"ESCAPE"}` | клик/клавиша в GUI в координатах кадра 854×480 (пересчёт в масштаб GUI внутри) |
| `wait` | `{screen:"regex", world:true, chunks:N, max_frames:K}` | делает `step` по одному кадру, пока условие не выполнится; `{frames:used}` |
| `quit` | — | корректный выход |

Дополнения стороны VoxelCore (тестовая сборка `VoxelCoreF2F.exe`, коммиты `ec07d0d1` и `527e3084`, 01.10; подробности —
`D:\Prog\AlphaMine\engine\README.md` «Protocol»):

| cmd | args | result |
|---|---|---|
| `hello` (режим) | — | `fixed` = (`clock`=="virtual"), `flags:{clock:"virtual"|"realtime", input:"isolated", window:"normal"|"hidden"}`, `time` (часы движка: виртуальные или `glfwGetTime`). Демон лаборатории проверяет `flags` перед прогоном |
| `step` (realtime) | — | ошибка `clock-realtime`: кадры идут сами; ждать по `hello.frame`/`time` |
| `input` (realtime) | как выше | события применяются в `pollEvents` следующего кадра (той же очередью, что в virtual) |
| `hello` (+поля) | — | `gl:{renderer, vendor, version, glsl}` (`glGetString`; класть в `meta` прогона — на ноутбуке GPU выбирается по пути exe), `build:{commit, dirty, flags:{compiler, ndebug, optimize, target, stdlib, recipe}}`, `time_epoch` |
| `mode` (+сброс) | `{seed}` | `time_epoch`++ → в следующем кадре обнуляются `u_timer` движка (шейдеры мира, облака, deferred/постобработка), прокрутка осадков, анимации текстур (кадр 0). Кадр после `mode` больше не зависит от числа кадров до него: тот же sha в трёх процессах; без сброса облака давали 0.13–0.46 % между `mode` и между процессами |
| `perf` | `{start:true, trace:bool}` / `{stop:true}` / `{dump:"путь.json"}` / `{}` | фазы кадра по часам движка (µs): `frame, input, app_tick, update, world_update, chunks_load, light_chunk, light_block, render, render_world, mesh_upload, mesh_sync, mesh_worker, hud, gui, post_update, present, lua` → `summary.phases.<фаза>:{count, items, sum_ms, idle_ms, frames, mean_ms, p50_ms, p99_ms, max_ms}`; `dump` — Chrome trace-event JSON (`{"traceEvents":[...]}`, ui.perfetto.dev): дорожки main / lua / f2f-команды (`step` — глобальные instant) / потоки мешей. Время CPU (GL асинхронен). Выключен — один атомарный load на точку |
| `selftest` | `{throw:bool}` | заведомо невалидный UTF-8 в ответе и в пути ошибки (cp1251, смесь, обрыв, управляющие, эмодзи, ключ) — проверка санитайзера |

Все строки ответов движка (значения и ключи, `what()` исключений, результаты Lua-обработчика) проходят санитайзер:
валидный UTF-8 как есть, невалидные участки — из ANSI-кодовой страницы (cp1251) или `\xNN`; сериализация ответа не бросает
исключений (раньше cp1251-текст ошибки Windows валил процесс, LESSONS «utf8 decode error»). Lua: `f2f.now_us()`,
`f2f.trace_active()`, `f2f.trace_event(name, ph, args, ts_us, dur_us)` (`B/E/X/i/C`, дорожка `lua` той же трассы, часы движка).

## 3. Точки в кадре
- Java `Minecraft.run`: `F2FAgent.poll()` в начале кадра (принимает команды до `step`); `step` управляет
  `Timer` напрямую (`elapsedTicks = N`, `renderPartialTicks = p`), после тиков и `updatingLighting` вызывает
  `renderGlobal.updateRenderers(player, true)` до пустой очереди, затем рендер в FBO, `shot` — до
  `Display.update()`.
- VoxelCore: патч в `Engine::run`/`Mainloop`: при `--f2f` цикл ждёт команду; `step` вызывает
  `time.update(virtual)` и один проход `Engine::updateFrontend/renderFrame` на кадр; `input` пишет в `Input`
  (состояния и очередь событий) в обход GLFW; `shot` — чтение пикселей после рендера.

## 4. Детерминизм (Java; список из разведки 30.09)
- Часы: `Timer` (`currentTimeMillis`, `nanoTime`), `MC:418/498` (fps), `MC:896-897` (сброс мыши >200 мс),
  `MC:957`, `EntityRenderer:244` (автопауза), `RenderGlobal:853/888` (пульсация трещин), `GuiMainMenu:120`
  (splash), `LoadingScreenRenderer:67`. Все → `F2FClock.millis()`.
- `new Random()`: `Entity:49`, `EffectRenderer:12`, `GuiIngame:14`, `EntityRenderer:21`, `World` (99/115/120/1655),
  `RenderItem:9`, `RenderPainting:8`, `NetClientHandler:19`, `Item:6`, `BlockChest:6`, `WorldGenBigTree:7` → `new Random(seed ^ константа класса)`.
- `Math.random()`: все `TextureFX` (вода, лава, огонь), частицы `EntityFX`, `EntityItem`, `EntityLiving`,
  `BlockDoor`, `BlockFluid`, `EntityTNTPrimed` → `F2FRandom.next()` (сидированный), либо `setSeed` через
  reflection на `Math$RandomNumberGeneratorHolder` при `mode`.
- Зависящее от кадра: occlusion queries → выкл; бюджет перестройки чанков → «до пустой очереди»;
  `getMouseOver(partial)` и поворот мыши — от `input`, а не от `Mouse.getDX`.
- Сеть: приход пакетов относительно тиков не детерминирован по природе; сценарии ждут `wait{chunks:N}` /
  `state.hash` перед снимком, а сервер для обеих сторон — одна и та же копия мира, свежезапущенная.
- Что детерминизм не покрывает и решается масками только если иначе нельзя: ничего заранее; маски —
  исключение, каждая с причиной в сценарии.

## 5. Сценарий паритета
JSON (как `tools/scenarios/eag/*.json`): шаги F2F с `expect`, точки `shot`. Харнесс прогоняет его на Java →
`D:\Prog\AlphaMine\golden\<сценарий>\NN.png + state.json`, затем на VoxelCore → `runs\<дата>\...`, сравнивает
(`compare.py`: число отличающихся пикселей, bbox, тепловая карта), отчёт с картинками. Первый обязательный
тест — **Java против Java** (два прогона, разные условия окон: активное / перекрытое / свёрнутое): 0 отличий.

## 6. Реализация Java (30.09, уточнения спецификации по факту)
Код: `D:\Prog\AlphaMine\ref\minecraft\src\net\minecraft\src\F2F*.java` (+ хуки в 40 файлах), патчи
`ref\patches\f2f-client.patch` (всё от `src_original`) и `f2f-only.patch` (только F2F); запуск и подробности —
`D:\Prog\AlphaMine\README.md` «F2F client». Харнесс: `tools/alphamine/f2f_client.py`, MCP `am_*`, сценарии
`tools/scenarios/alpha/`. Эти уточнения обязательны и для стороны VoxelCore (ответы одинаковы по форме).
- **Транспорт из WSL.** WSL в режиме NAT не достаёт до `127.0.0.1` Windows, а IP хоста закрыт брандмауэром.
  Java слушает строго `127.0.0.1`; `f2f_client.py` в WSL ходит через `tools/alphamine/f2f_relay.ps1`
  (powershell.exe: строка stdin → TCP → строка stdout; первая строка `@@F2F connected`). ~1 с на подъём реле,
  дальше миллисекунды.
- **Время всегда виртуальное** (`fixed:false` → ошибка). Без команд игра стоит; раз в секунду простоя клиент
  шлёт KeepAlive (иначе сервер через 60 с рвёт соединение), состояние игры это не меняет.
- **`mode {seed, clear_chat?, options?}`** — сиды всех ГСЧ **и сброс тиковых счётчиков**: tick/frame = 0,
  виртуальные часы = 0, `ticksRan`, счётчики `GuiIngame` (чат — при `clear_chat:true`), облака, позиция сортировки
  чанков, `rendererUpdateCount`, массивы TextureFX (вода/лава/огонь) в ноль, частицы, покачивание игрока
  (distanceWalked, cameraYaw/Pitch), ГСЧ сущностей = f(seed, entityId). После `mode` кадр зависит только от мира,
  позиции/взгляда, сида и тиков/ввода после `mode` — не от того, сколько шла загрузка. `options` — поля
  `GameSettings` по имени (`renderDistance`, `fancyGraphics`, `viewBobbing`...); в F2F `options.txt` не читается
  и не пишется (значения по умолчанию: FAR, fancy, bobbing). Occlusion выключены с запуска, бюджет чанков — все
  грязные в пирамиде видимости за кадр. Ответ: `{tick:0, frame:0, seed, options:[...], occlusion:false, chunk_budget:"all"}`.
- **`step {ticks=1, frames=1, partial=0}`**: N тиков, затем M кадров, все с `partial`. Ответ `{tick, frame}`
  (счёт от последнего `mode`).
- **`input`**: `mouse.x/y` — пиксели кадра, начало слева **сверху**; `dx` — как LWJGL (yaw += dx·0.15°, dx 600 = 90°),
  `dy > 0` — взгляд вверх; дельты копятся до ближайшего кадра (поворот применяется в кадре, не в тике).
  Клавиши — имена LWJGL (`Keyboard.getKeyIndex`) или коды. События клавиш/кнопок — только при изменении состояния.
- **`gui {click:[x,y], button?, key?, char?, chars?, ticks=1, frames=1}`** — ставит события в очередь фасада и сразу
  делает `step` (по умолчанию 1 тик + 1 кадр); ответ `{tick, frame, screen}`.
- **`connect {host?, port?}`** — новая команда: в F2F-режиме меню само не подключается; по умолчанию адрес из `--server`.
- **`wait`** — условия (все заданные должны выполниться): `screen` (regex по имени класса GuiScreen; без экрана в
  мире — `ingame`, без мира — `none`), `world`, `chunks` (всего MapChunk), `new_chunks` (MapChunk с начала этого
  wait), `net_idle` (тиков без пакетов мира 50–53), `still` (позиция и взгляд игрока не менялись K тиков), `near`
  `[x,y,z,r]` (posY — глаза, т.е. ноги + 1.62), `on_ground`, `chat` (regex по строкам чата); `max_frames` (2000),
  `settle` (доп. тиков после), `realtime` (по умолчанию **true**: тик не быстрее 50 мс настенных часов — сервер и
  сеть живут в реальном времени; без этого 40 «тиков тишины» проходили за 80 мс). Ответ `{tick, frame, frames,
  screen, map_chunks, new_chunks}`; таймаут → `ok:false`, в `error` — экран, чанки, позиция.
- **`shot {path}`** → `{path, w, h, sha256, tick, frame}`; sha256 — от RGB-байт кадра построчно сверху вниз (не от PNG).
- **`state {radius=8}`** → `tick, frame, screen, buttons[{id,text,x,y,w,h,enabled,visible}]` (центр в пикселях кадра),
  `chat[{text,age}]`, `player{x,y,z,mx,my,mz,yaw,pitch,onGround,health,slot,entity_id,inventory[{slot,id,count,meta}]}`,
  `world{time,multiplayer,map_chunks,world_packets,last_world_packet_tick,entities[{id,type,x,y,z}]}`,
  `hash{radius,center,blocks,meta}` (FNV-1a 64 по кубу, обход x,z,y), `input{keys_down,mouse,in_game_focus}`.
- **Грабли сценария.** Телепорт в незагруженный чанк: клиент падает сквозь пустой чанк и получает урон (здоровье в
  протоколе 14 считает клиент) — телепортироваться только в уже загруженный радиус (сценарий `alpha_spawn` делает
  два прыжка). Сервер сам меняет мир по настенным часам (огонь, рост растений) — в кадре не должно быть таких мест.

## 7. Слои рендера и метрика в процентах (требование пользователя, 30.09, фазы 1–2)
Паритет доказывается **серией промежуточных тестов**: на обеих сторонах выключено всё, кроме одного слоя,
снимки сравниваются попиксельно, результат — **в процентах**.
- Команда **`render {layers:{...}, clear:[r,g,b]}`** — на обеих сторонах одинаковые имена слоёв:
  `sky` (градиент неба, плоскости, солнце, луна, звёзды), `clouds`, `terrain` (непрозрачный проход чанков),
  `water` (полупрозрачный проход: вода, лёд, стекло — то, что рисуется во втором проходе), `entities`,
  `particles`, `weather` (дождь/снег), `selection` (рамка блока и трещины), `hand` (рука/предмет от первого лица),
  `hud` (хотбар, сердца, прицел, отладочная строка, чат), `gui` (экраны `GuiScreen`), модификаторы `fog`
  (туман на слоях мира) и `lighting` (запечённый свет/тени граней; выкл = полная яркость). Незаданные слои
  не меняются; `render {all:false}` — выключить всё, `all:true` — включить всё. Ответ — текущее состояние.
- **`clear`** — цвет очистки кадра, когда слой неба выключен (по умолчанию `[0,0,0]`); обе стороны обязаны
  очищать кадр ровно этим цветом, чтобы фон в сравнении совпадал.
- Java: ворота в `EntityRenderer.renderWorld` (небо, `sortAndRender` проход 0/1, сущности, частицы, дождь,
  облака, рамка/трещины, `renderHand`), `GuiIngame.renderGameOverlay`, `currentScreen.drawScreen`; `fog` —
  `glDisable(GL_FOG)` на слоях мира; `lighting` — цвет вершин 1.0 в `RenderBlocks`/`Tessellator` при выкл.
- VoxelCore: те же ворота в патче движка (`src/devtools/f2f*` → `WorldRenderer`/`Hud`: скайбокс, чанки
  opaque/translucent, сущности, частицы, рука (`hand_controller`), HUD/GUI-документы; туман — uniform,
  свет — uniform-множитель) плюс, где возможно, средствами пака.
- **`am_compare(a, b, tol=0)`** → `{pixels, identical, identical_pct, within_tol_pct (|Δканал| ≤ tol),
  coverage_a_pct, coverage_b_pct (пиксели ≠ clear), bbox, diff_png, heat_png}`; отчёт сценария — таблица
  «слой → % идентичных, % в допуске, покрытие A/B». Целевой порог — 100 % идентичных; всё ниже —
  разбирается по тепловой карте, маски не применяются.
- Сценарии слоёв: `tools/scenarios/alpha/layer_<слой>.json` — общая подготовка `alpha_spawn` (тот же мир,
  точка, `mode`), затем `render {all:false, layers:{<слой>:true}}`, снимки в 4 направлениях; golden с Java —
  `D:\Prog\AlphaMine\golden\layer_<слой>\`, прогон VoxelCore — `runs\<дата>_vc_layer_<слой>\`.
  Порядок работы над рендером порта — слой за слоем по этой таблице: `sky` → `terrain` (без `lighting`,
  без `fog`) → `terrain+lighting` → `terrain+fog` → `water` → `clouds` → `hand` → `hud` → `entities` →
  `particles` → `selection` → `gui`.

### 7.1 Реализация Java (30.09, уточнения §7 по факту — обязательны и для VoxelCore)
Код: `ref/minecraft/src/net/minecraft/src/F2FRender.java` + ворота в `EntityRenderer`, `RenderGlobal`, `WorldRenderer`,
`Tessellator`; патчи `ref/patches/f2f-client.patch`, `f2f-only.patch` обновлены (оба проверены `patch -p1`).
- **Ответ `render`**: `{layers:{sky,clouds,terrain,water,entities,particles,weather,selection,hand,hud,gui,fog,lighting: bool},
  clear:[r,g,b], rebuilt:bool}` (`rebuilt` — был ли перестроен свет чанков). `state` тоже отдаёт `render` (без `rebuilt`).
  Незнакомое имя слоя → ошибка `render: unknown layer X (known: [...])`. Порядок в команде: сначала `all`, потом
  `layers`, потом `clear`. **`all` действует и на модификаторы** `fog`/`lighting` (`all:false` = плоский свет без
  тумана); сценарии всё равно задают модификаторы явно. `clear` — байты 0..255. `mode` состояние слоёв не трогает;
  по умолчанию (и без `--f2f`) всё включено, `clear [0,0,0]`.
- **Выключенный слой не рисуется совсем — ни цвета, ни глубины.** Поэтому при `terrain:false` облака/рамка не
  закрываются землёй, а вода видна «сквозь» отсутствующее дно. Сортировка и списки чанков строятся как обычно
  (`sortAndRender` вызывается, пропускается только `renderAllRenderLists` своего прохода), т.е. у ворот нет побочных
  эффектов на другие слои.
- **`sky`** = `RenderGlobal.renderSky` целиком: купол (`glSkyList`), солнце/луна/звёзды и нижняя тёмная плоскость
  (`glSkyList2`). Цвет очистки при включённом небе — как в оригинале (цвет тумана из `updateFogColor`); `clear`
  подставляется **только при `sky:false`** (сразу после `updateFogColor`). Градиент неба у горизонта — это GL-туман
  на куполе (`setupFog(-1)`), поэтому `layer_sky` снимается с `fog:true`; при `fog:false` купол однотонный.
- **`fog`** — все `glEnable(GL_FOG)` мирового прохода (`EntityRenderer`: 3 места, `RenderGlobal`: небо ×2, occlusion)
  идут через `F2FRender.enableFog()`; при `fog:false` туман не включается нигде (цвет тумана всё равно считается —
  он нужен `clear` неба и `terrain_fog`).
- **`lighting:false`** — пока `WorldRenderer.updateRenderer` компилирует чанк, `Tessellator.setColorRGBA` заменяет RGB на
  255 (альфа сохраняется): нет ни таблицы яркости, ни множителей граней 0.5/0.8/0.6, для всех блоков и жидкостей; текстуры
  не трогаются; сущности, рука, облака, небо — как были. Переключение `lighting` помечает **все** чанки грязными
  (`RenderGlobal.f2fMarkAllDirty`, не `loadRenderers`: тот через `renderEntitiesStartupCounter` прячет сущности на 2
  кадра, а `updateAllRenderers` пропускает чанки без неба), перестройка — в ближайшем кадре (бюджет F2F «все в пирамиде»).
- **`hud:false`** — `renderGameOverlay` не зовётся, но проекция для GUI ставится (`setupOverlayRendering`), иначе экран
  рисовался бы в матрицах мира. **`gui`** — `currentScreen.drawScreen` (и в мире, и в меню без мира).
- **`selection`** — `drawSelectionBox` + `drawBlockBreaking` (обе ветки: над водой и под водой). Рамка альфы **чёрная**
  (`glColor4f(0,0,0,0.4)`) — на чёрном `clear` её не видно, поэтому `layer_selection` снимается с `clear [255,255,255]`
  (рамка 153/153/153, трещины — `DST_COLOR·SRC_COLOR` по белому).
- **`weather`** — `renderSnow` и дождь; в мультиплеере альфы дождя/снега нет (`WorldClient` не тикает погоду), сценария нет.
- **`mode`** дополнительно обнуляет у `EntityItem` `age` и `hoverStart` (покачивание и поворот лежащего предмета зависели
  от того, в какой тик пакет предмета пришёл по сети). Стороне VoxelCore — то же: фаза 0, возраст 0 от `mode`.
- **`mode` обнуляет `ticksExisted`** у всех сущностей (с 01.10, фаза 3): покачивание рук `ModelBiped` чужого игрока
  зависело от момента прихода его пакета. Сторона VoxelCore — так же; там же `wait {net_idle, still}` считаются от `mode`.
- **`input.keys`**: строка из цифр — это **код** LWJGL, а не имя (на движке — имя клавиши; `run_vc_scenario.py` переводит): `"3"` = код 3 = `KEY_2` (слот 1), `"2"` = `KEY_1` (слот 0).
- **Харнесс**: шаг `look {yaw, pitch}` (не команда F2F) — читает `state` и шлёт `input.mouse {dx, dy}` так, чтобы в кадре
  следующего `step` взгляд стал ровно заданным (`yaw += dx·0.15`, `pitch −= dy·0.15`; 270 − 1800·0.15 = 0 точно).
  Сценарий `"base": "alpha_spawn"` наследует `setup` и шаги до первого `mode`. `am_layers` гоняет все `layer_*.json` в
  одной сессии: подготовка один раз, затем тело каждого слоя (`look` → `mode` → `render` → снимки); отдельный прогон
  `am_scenario layer_<слой>` даёт побайтно те же снимки (проверено на `entities`, `terrain_lit`).
- **Метрика** (`tools/reference/compare.py metrics`, MCP `am_compare`): `identical` — пиксели, равные во всех трёх
  каналах; `within_tol` — `max|Δканал| ≤ tol`; `coverage_*` — пиксели ≠ `clear`; `bbox [x0,y0,x1,y1]` — рамка неравных
  пикселей (включительно), `null` при 100 %; ещё `max_delta`, `mean_delta`, `diff_pixels`. diff png: серый A, жёлтый —
  0 < Δ ≤ tol, пурпурный — Δ > tol; heat png: `max|Δ|` синий → красный → жёлтый → белый, равные — чёрные.
- **Мир `golden\world_b`** (с 30.09 — мир `alpha_spawn` и всех слоёв) = `world_a` после одного прогона `alpha_spawn` и
  `/stop` оператором (сервер сохранил всё). На `world_a` сервер во время прогона догенерировал 11 и **заселял** соседние
  чанки (деревья/руды меняют свет у уже отправленных чанков); что клиент получал — данные чанка или пакеты блоков —
  зависело от сетевого тайминга: 12 пикселей света на дальнем подводном склоне в 1 из 2 прогонов `terrain_lit`. На
  `world_b` генерации/заселения нет: 3 прогона всех слоёв — 100 %, и ожидание чанков втрое короче. Снимки `alpha_spawn`
  на `world_b` побайтно равны прежнему golden (`world_a`). Огонь мира (x −263…−113) продолжает гореть и сохраняться — он
  вне радиуса чанков клиента.
- Golden слоёв (Java): `D:\Prog\AlphaMine\golden\layer_<слой>\` для `sky terrain_flat terrain_lit terrain_fog water clouds
  hand hud entities particles selection gui`; сценарии — `tools/scenarios/alpha/layer_*.json` (что в каждом — в его
  `description`). Не «4 стороны» только у трёх: `particles` — 4 снимка по времени при копании (частицы есть только у
  блока), `selection` — 4 стороны при pitch 60 + `4_cracks`, `gui` — `0_menu` и `1_hover` (курсор на «Back to game»).

## 8. Стандарт размера кадра и финальный E2E-тест (требование пользователя, 01.10)
- **Один стандарт размера для всех агентов и сценариев: 854×480** (`--f2f-size 854x480` у движка, `-Size 854x480` у
  Java). Второй фиксированный профиль **1390×855** (окно пользователя) допустим только в сценариях, где это явно
  записано в поле `"size"` сценария, и обязателен для обеих сторон сразу. Размер задаётся в файле сценария, а не в
  личном лаунчере агента; golden и прогон с разными размерами не сравниваются (харнесс отказывает).
  Реализовано (01.10, U) в `tools/alphamine/run_u.py` и `run_vc_scenario.py`: размер = `"size"` сценария, иначе
  `setup.client.size` базового, иначе 854×480; `--size` — только проверка; сессия со сценариями разных размеров и
  сравнение снимков разного размера отклоняются. Сценарии 1390×855: `u_hand_wide`, `u_inventory_wide`, `u_hud_wide`.
- **Мир разработчика** `devworld`: генерируется скриптом в Java-сервере (или как сохранение) и содержит все блоки
  альфы по id и meta (ряды с подписями), жидкости с уровнями, растения, факелы/двери/лестницы/рельсы, сущности
  (предметы, вагонетки, лодка, второй игрок) — площадка для послойных тестов «всё сразу».
  Сделано 01.10 (агент D): `golden\devworld` из `tools/alphamine/gen_devworld.py` (формат сохранения напрямую, свет посчитан и сверен
  с сервером), сценарии `layer_{terrain_flat,terrain_lit,water,entities}_dev` и `dev_full` (база `dev_base`, 8 видовых точек с башен),
  разбор по экспонатам `tools/alphamine/am_rows.py`; раскладка, таблица и список неверных блоков — `agents/ALPHAMINE.md` §10.
  Вагонеток, лодки и второго игрока в мире нет (сущности протокола 14 появляются только действиями).
- **Финальный E2E-тест** `e2e_<имя>`: мир с предзаписанными действиями — последовательность F2F `input` по тикам
  (ходьба, повороты, прыжки, копание, установка, инвентарь, чат) с ключевыми кадрами; прогоняется на Java и на
  VoxelCore после завершения работы всех агентов фазы. Метрика — **серия**, а не один кадр: % идентичных на
  каждом ключевом кадре, хэши `state` (позиция, инвентарь, блоки) на каждом тике, кривая расхождения и **первый
  тик расхождения** с его снимками и дампами. Отчёт `e2e_report.md` с кривой; порог — 100 % на статике, дрейф
  позиции 0 до бита.

### 8.1 Реализация E2E (01.10, агент E) — формат и правила по факту
> **С 01.10 (лаборатория, этап 2а)** сценарии всех форматов (шаговые и таймлайны e2e_*) исполняет интерпретатор демона
> `tools/lab/labcore/scenario.py` (`lab run alphamine <сценарий> --impl vc|java [--golden]`, MCP `lab_run`); сравнение серий —
> `labcore/compare.py` (`lab compare`), golden с манифестом и CAS — `lab golden status|promote|regen`. Формат сценария —
> сводный справочник в `tools/lab/README.md` «Сценарии». Старые раннеры ниже — тонкие обёртки над демоном (`--legacy` — прежний путь).
Код: `tools/alphamine/e2e/e2e_run.py` (прогон), `e2e_compare.py` (сравнение серий), MCP `am_e2e`; сценарии
`tools/scenarios/alpha/e2e_<имя>.json`. Изоляция по умолчанию: `VoxelCoreF2F-e.exe` F2F :25575, `--dir engine\userdir_e`,
Java-клиент F2F :25582, сервер `server_v.py --name e --port 25570` (свежая копия `golden\<world>` на каждый прогон).
- **Сценарий**: `size` (854x480); `setup {world, base, steps, tp, look, mode, render}` — `base`: шаги сценария (alpha_spawn,
  dev_base…) до его первого `mode`; `steps` — доп. шаги формата run_vc_scenario (с `expect`); `tp [x,y,z]` — /tp + wait near /
  new_chunks+net_idle / on_ground+still; `look {yaw,pitch}` + `step{1,1}` (поворот мыши применяется в кадре); `mode {seed,
  clear_chat, options}` — такт 0; `render` — слои (по умолчанию всё). `ticks`, `pace_ms` (50), `timeline` — `{tick, input:{keys,
  mouse{dx,dy,buttons,wheel,x,y}, chars}}`, `{tick, chat:"..."}`, `{tick, gui:{click|key|chars}}`, `comment`; `keyframes [N…]` +
  `keyframes_every K`; `state_every K`, `state_radius R`; `regions {имя: [x0,y0,x1,y1)}` для разбивки (по умолчанию hotbar
  [245,400,609,480], crosshair [411,224,443,256], chat [0,190,660,480], hand [500,240,854,480], остальное — world; первая
  подходящая).
- **Такт N** (0…ticks−1): записи такта N применяются **перед** шагом N→N+1, затем `step {ticks:1, frames:1}`; запись `gui` сама
  является этим шагом (Java `F2FAgent.gui` и `alpha_vc.gui` делают step{1,1}). После шага: снимок `kf_<N+1>.png`, если N+1 —
  ключевой кадр; `state {radius}` → строка `states.jsonl` `{tick, kf, wall_s, lag_ms, state}` каждые K тактов и на каждом
  ключевом кадре. Клавиши-цифры в `input.keys` — коды LWJGL (для vc харнесс переводит, как run_vc_scenario).
- **Ожидание только в setup.** Внутри таймлайна нет `wait`: шаг виртуальный на обеих сторонах (без `realtime`), но харнесс
  **выдерживает стену 50 мс на такт** (`pace_ms`): сервер живёт по настенным часам, и без темпа Java прошёл бы 600 тактов за
  3 с, VoxelCore за 20 с — ответы сервера (подтверждение копания, спавн предмета, подбор, эхо чата) пришли бы на разных тактах.
  Если сторона не успевает (снимок, GC), расписание **сдвигается** (`schedule_shift_ms`), а не догоняется пачкой тактов.
  Приход пакетов всё равно дрожит на ±1 такт сервера: в каждом дампе `world.world_packets` / `last_world_packet_tick` (счётчик
  от connect, не от mode — сравнивать приращения).
- **Выход**: `golden\<имя>\` или `runs\<время>_e2e_<impl>\<имя>\`: `kf_NNNN.png`, `states.jsonl`, `scenario.json`, `run.json`
  (setup-шаги, события таймлайна с ответами, `lags_ms`, `shots` с sha256, ошибки, `timeline.last_tick`). Если клиент умер
  посреди таймлайна — серия сохраняется до этого такта, сравнение идёт по тому, что есть.
- **Сравнение** `e2e_compare.py A B [--tol 3] [--baseline compare.json]`: по ключевым кадрам identical % / tol % / покрытие / max Δ
  + отличающиеся пиксели по областям; по дампам — `player` (x,y,z,mx,my,mz бит в бит: у VoxelCore строки `exact` %.17g, у
  Java double; yaw/pitch как float32; onGround/health/slot), `inventory`, `blocks` (FNV-хэш куба + центр), `entities` (тип и
  позиция в порядке списка, |Δ| ≤ 1e-9 — JSON движка держит ~15 знаков; id сущностей — счётчик сервера, только в деталях),
  `screen`, `chat`. Первый такт расхождения — минимум из первого кадра < 100 % и первых расхождений категорий; с `--baseline`
  (compare.json пары Java/Java) — ещё «вне шума эталона». Выход `vs_golden\`: `e2e_report.md`, `compare.json`, `drift.png`
  (matplotlib Windows-питона `C:\Python313`, иначе растр numpy), `kf_NNNN_diff/heat.png` для кадров < 100 %.
  `e2e_run.py --compare`: java → compare.json копируется в `golden\<имя>\reference_noise.json`; vc → сравнение с `--baseline` им.
- **Детерминизм эталона (Java против Java, `e2e_walk1`, 3 прогона).** Найдено и исправлено: `mode` не сбрасывал
  `GuiIngame.prevVignetteBrightness` (сглаживание 1 %/кадр) — его значение зависело от числа кадров сетевых ожиданий до mode,
  виньетка расходилась на ±1 по всему кадру с такта 51. Теперь `mode` ставит его в неподвижную точку `clamp(1 − getBrightness)`
  (Java `F2FAgent.mode`, пак `hud.vignette_reset` из `game.mode`). Остаются **события сервера**, которые эталон не повторяет:
  (1) позиция и id выпавшего из блока предмета — `World.rand` сервера (не сидируется, расходуется случайными тактами блоков);
  (2) такт подбора (`Packet22`, ±1 такт сервера относительно клиента) — а `EntityPickupFX` берёт 5 чисел из общего потока
  `Math.random`, и после этого анимация воды (TextureFX) идёт по другой последовательности до конца. Лечится только сервером
  в lockstep (шаг сервера командой харнесса) — **сделано 01.10, §9** (`e2e_walk1_ls`: J/J 73/73, все дампы равны). Поэтому в отчёте VoxelCore есть колонка «J/J %» и «первое
  расхождение вне шума эталона».

## 9. Пошаговый сервер (lockstep, 01.10) — тестовый режим эталонного сервера
Исследование и источники недетерминизма — `agents/research/DETERMINISM.md` §1–2. Сделано: сервер Alpha 0.1.1 с флагом
`--f2f <порт>` не тикает сам — харнесс шагает его такт в такт с клиентом. Без флага сервер прежний (проверено golden, ниже).

**Код.** Сервер: `D:\Prog\AlphaMine\ref\minecraft_server\src\net\minecraft\src\F2FServer.java` (команды, барьер, сброс очередей,
канонизация), `F2FRandom.java` (копия клиентского, сид 0 с запуска), `F2FJson.java` (копия); хуки ~140 строк в `MinecraftServer`
(`main`: `F2FServer.configure`, `run`: вместо цикла по часам — `F2FServer.run`, `f2fTick`), `NetworkManager` (счётчики, CRC,
`f2fFlush`, писатель из очереди байт), `NetworkListenThread` (приём через `F2FServer.onAccept`), `World` (`rand`, `updateLCG`,
`positionsToUpdate`, freeze), `Entity.rand = f(seed, id)`, `Math.random` → `F2FRandom.random()` в `EntityItem`, `EntityLiving`,
`EntityTNTPrimed`, `BlockDoor`, `BlockFluid`, `NetServerHandler` (`/away`), `Item.rand`, `BlockChest.rand`. Патчи: `ref\patches\
f2f-server.patch` (весь сервер от `src_original`, вместе с `/tp`, `/gamemode`, стартовым инвентарём; 1863 строки, 69 КБ, +1358/−35) и
`f2f-server-only.patch` (только F2F поверх тех правок, 1641 строка); оба проверены `patch -p1` (результат = `src`). Сборка —
`ref\compile_server.ps1 <файлы>` (javac 8 в `minecraft_server\bin`, как `compile_client.ps1`). Запуск — `start_server.ps1 -F2F 25593`,
`server_v.py start --f2f 25593`. Клиент протокола — `tools/alphamine/f2f_server.py` (`F2FServer`, `Lockstep`; из WSL через реле).

**Команды сервера** (TCP 127.0.0.1, строка JSON = запрос/ответ, как у клиентов):
| cmd | args | что делает |
|---|---|---|
| `hello` | — | `{impl:"server", version:"0.1.1-f2f", port, tick, total_ticks, seed, freeze}` |
| `mode` | `{seed}` | пересев `World.rand`, `updateLCG`, `soundCounter`, `Item.rand`, `BlockChest.rand`, замены `Math.random`, `Entity.rand` всех сущностей по id; `nextEntityID` = следующее кратное 1000 после max живого id; запланированные такты перенумерованы в порядке (время, x, z, y, блок); `updateCounter` трекера и фаза KeepAlive (`playerInAirTime`) = 0; `tick` = 0; ошибка, если в очередях отправки что-то есть |
| `step` | `{ticks=1, barriers:{<user>: K}, timeout_ms=30000}` | ждёт, пока соединение пользователя прочитает (и поставит в очередь) ≥ K байт — K = `tx_total` клиента; затем N тактов; в конце каждого такта очереди всех соединений сериализуются синхронно: сначала очередь данных, потом очередь чанков (MapChunk/MultiBlockChange), байты уходят писателю одним блоком. Ответ `{tick, total_ticks, clients:{user:{tx_total, rx_total, tx_packets, rx_packets, rx_crc, tx_crc}}, wait_ms, tick_ms}`; `rx_crc`/`tx_crc` — CRC32 потоков с начала соединения: первый такт, где они расходятся между прогонами, — первое расхождение поведения (rx — клиент, tx — сервер) |
| `freeze` | `{random_ticks, plants, fluids, scheduled, autosave}` | `random_ticks` — нет случайных тактов (и снега/пещерного звука); `plants` (2, 6, 18, 37–40, 59, 60, 81, 83) и `fluids` (8–11) — эти id не получают ни случайных, ни запланированных тактов (запланированные остаются в очереди); `scheduled` — нет запланированных; `autosave:false` — нет сохранения каждые 4 такта |
| `state` | — | такт, `world_time`, игроки (позиция, взгляд, инвентарь, чанков к отправке), сущности по id (позиция, скорость, предмет, возраст), `next_entity_id`, `world {loaded_chunks, blocks, meta}` (FNV-1a 64 по блокам/meta всех загруженных чанков, порядок x,z), `rng {world_rand, lcg, sound_counter}`, `freeze`, `clients` |
| `quit` | — | штатная остановка (мир сохраняется) |

Вход: принятое соединение держится вне списков сервера, пока его Handshake не прочитан; `step` пропускает в `pendingConnections`
соединения с известным именем (из `barriers`, по имени). Барьер по имени пользователя (`Player` у обоих клиентов). Консольные команды
сервера (stdin) по-прежнему выполняются в конце такта — в lockstep их не использовать; чат-команды (`/tp`) детерминированы.

**Клиенты (барьеры).**
- Java (`F2FNet.java` + `NetworkManager`, `F2FAgent`): `tx` считается при постановке пакета в очередь (размер сериализацией, как пишет
  поток-писатель), `rx` — байты полностью прочитанных пакетов. `step`/`gui` принимают `rx_bytes` (ждать, пока прочитано K, потом такт),
  ответ содержит `user, tx_total, tx_bytes (за команду), rx_total, rx_packets`. Новые команды: `sync {rx_bytes?, keepalive?}` (барьер
  без шага + счётчики), `wait_check {условия wait, begin?}` (условие без шага; `{done, describe, fatal?}`). `connect` ждёт, пока поток
  подключения поставит Handshake (до 10 с) — иначе такт входа плавал. Простойный KeepAlive выключается `mode {keepalive:false}` или
  `sync {keepalive:false}`.
- VoxelCore (пак): `step` отвечает движок, поэтому барьер и счётчики — командой пака `sync {rx_bytes?, keepalive?, timeout_ms?}`
  (`f2f.lua`; ждёт `net.rx_avail() ≥ K` — приём идёт в потоке движка, ожидание в Lua его не блокирует, проверено), ответ `{user,
  tx_total = net.conn_out, rx_total, rx_avail, net_state, keepalive}`. `keepalive` пака (поток `alpha_vc.py`) не шлёт пакет после
  `mode/sync {keepalive:false}`. Порядок такта: `sync{rx}` → `step` → `sync{}` → сервер. Мышь: движок съедает дельты в каждом проходе
  `step`, а пак применяет взгляд только в отрисованном кадре — `Lockstep` копит `input.mouse dx/dy` для VoxelCore до ближайшего шага
  с кадром (как Java: дельты до кадра).
- **Пакеты за такт (паритет, найдено и исправлено):** Java обрабатывает ≤ 101 пакета за вызов `processReadPackets` — в
  `GuiConnecting/GuiDownloadTerrain.updateScreen` и ещё раз в `WorldClient.tick` (с миром), пак — всё сразу: до 448 пакетов за такт при
  входе и 490 после `/tp`. Теперь `game.lua`: `net.poll(101)` в обоих местах (`net.stats.max_poll` = 101, `polls_capped` 8–10 за
  подготовку). Это и обычный запуск: как у Java, всплеск PreChunk разбирается за несколько тактов.

**Харнесс.** `tools/alphamine/f2f_server.py`: `Lockstep(server, call, impl, user)` — `tick(frames, gui=None)` (такт клиента с барьером,
затем `server.step{1, {user: tx}}`), `step(N, M)` (N тактов, кадры только на последнем, как `F2FAgent.step`), `wait(cond)` (`wait_check`
+ такты; `realtime` и темп не нужны и игнорируются), `connect` (VoxelCore: проходы `step{0,0}` до отправки Handshake), `mode`
(клиент + сервер в одной точке, keepalive выкл.), `run(cmd, args)`. Включение: в сценарии `"server": {"f2f": true}` (верхний уровень,
`setup.server` или база) либо `--lockstep`; порт команд `--server-f2f` (по умолчанию порт сервера + 3).
- `run_vc_scenario.py`: `step/wait/gui/connect/mode/input` идут через `Lockstep`; в `session.json` — `server_mode`, `lockstep`,
  `server_state`. `client_b` (второй клиент) в lockstep пока не поддержан (ошибка).
- `e2e_run.py`: подготовка через `Lockstep`, такт таймлайна = `Lockstep.tick(1)` (или `gui`), **без темпа** (`pace_ms` игнорируется);
  в дампах `server_tick`, `net {tx, rx}`; в `run.json` — `lockstep`, `server_state0`, `server_state`; `--golden-dir`.
- Сценарий `tools/scenarios/alpha/e2e_walk1_ls.json` = `e2e_walk1` + `"server": {"f2f": true}`; golden — `golden\e2e_walk1_ls\`.
- **Реальное время сохранено**: без поля/флага всё как раньше (сервер по часам, `wait.realtime`, темп 50 мс). Дымовой прогон
  «в реальном времени» (DETERMINISM §5) остаётся обязательным: lockstep — идеализированный порядок «такт клиента → такт сервера», он
  не покажет ошибок, зависящих от задержки.
- MCP `am_scenario`/`am_layers`/`am_e2e` в lockstep не переведены (ходят через `run_vc_scenario`/`e2e_run`).
- **Лаборатория (этап 3б, 01.10): `lab run` в lockstep — путь по умолчанию.** `[scenario].server_f2f = true` проекта alphamine: каждый
  сценарий без своего `server.f2f` идёт на пошаговом сервере; `layer_entities_player` — `f2f:false` (второй клиент `client_b` в lockstep
  не поддержан). Дымовой прогон в реальном времени — `lab run ... --realtime` (MCP `lab_run realtime=true`): сервер по часам, темп,
  `wait.realtime`. Ключ golden получил поле `server = lockstep | realtime`. Реализация: вид `server` с портом `f2f` (ключ `--f2f <порт
  аренды>` добавляет плагин параметром `f2f_args`), хуки ядра `lockstep_tick`/`lockstep_run`/`server_step` в `projects/alphamine/
  plugin.py` поверх того же `f2f_server.Lockstep` (транспорт — аренды демона), простойный keepalive демона выключен параметром
  `f2f_idle=false`, стоп сервера — F2F `quit`. Приёмка: Java/Java 73/73 кадров и 157/157 дампов (`lab\runs\20261001_185415_…_java`,
  `…185507_…_java`), ожидания подготовки и счётчики tx/rx — как у старого раннера; VoxelCore — 59/73 sha256 равны старому
  `runs\20261001_155027_ls2_vc1` (и `…155211_ls2_vc2`): отличаются ровно те 14 кадров копания, которыми vc1 и vc2 отличались между собой.
- **Java `hello.flags`** (этап 3б, тестовая инструментовка `F2FAgent.flags()`): `{clock: "virtual", input: "isolated", window: "normal",
  grabbed: false}` по живому состоянию (часы F2FClock, фасады ввода, `Mouse.isGrabbed`, `Display.isVisible`). Демон сверяет
  `flags.input`/`flags.clock` у вида `ref_app` так же, как у движка (несовпадение — дерево убивается, `isolation-failed`).
- **Недетерминизм VoxelCore на копании найден и снят паком** (этап 3б): генератор эмиттера частиц движка сидируется адресом объекта в
  куче (`Emitter.cpp: random.setSeed(this)`), `random_sub_uv` брал окно текстуры из него. Пак выбирает окно сам (джиттер EntityFX из
  своего `Entity.rand`, Canvas-текстура 4×4), `random_sub_uv = 1`. VoxelCore/VoxelCore на `e2e_walk1_ls` — **73/73** (`…190626_…_vc` /
  `…190716_…_vc`), state 157/157. Остаток в движке: `particle.random` (тот же генератор) умножает свет частицы на 0.9…0.999 — на
  дневном свету пикселей не меняет (проверено `det_dig_nolight`/`det_dig_nosub`), при блочном свете может; вариант только для тестовой
  сборки — сид эмиттера из счётчика эмиттеров с момента `mode` (не адрес) при `--f2f` (не сделано: движок не меняем без решения).

**Найденный недетерминизм самого сервера:** `ChunkCoordIntPair.hashCode = x<<8 | z` — при отрицательном z все пары схлопываются в
несколько значений; Java 8 превращает такие корзины `HashSet` в деревья с разбором ничьих по `System.identityHashCode`, и порядок
обхода `World.positionsToUpdate` (какой чанк берёт какие числа LCG случайных тактов) менялся от запуска JVM к запуску — лишний
`Packet53` в 1 из 3 прогонов (найдено по `tx_crc` при равном `rx_crc`). В F2F-режиме это `LinkedHashSet` (порядок цикла
игрок → x → z). В обычном режиме оригинал так и недетерминирован.

**Доказательство (01.10, 854×480, мир `world_b`, Java :25584, VoxelCoreF2F-s.exe :25577 `userdir_s`, сервер :25590/F2F :25593).**
| пара | ключевые кадры | дампы state (157) | поток сервера | прогоны |
|---|---|---|---|---|
| Java / Java | **73/73 sha256 равны** (100 %) | **157/157 равны целиком** (player бит в бит, inventory, blocks, entities, world_packets) | `server_state` до и после таймлайна равны; 1341 такт, tx 17 866 / rx 3 221 307 Б в обоих | `runs\20261001_154829_ls2_j1` / `…154906_ls2_j2` (до правки HashSet — тоже 73/73, 157/157: `…152753_ls_j1` / `…152835_ls_j2`) |
| VoxelCore / Java | 0/73 на 100 %; мин. 78.93 %, среднее 90.11 % (рендер порта) | **все категории равны во всех 157** (player, inventory, blocks, entities, screen, chat) | сервер→клиент **побайтно равен** Java: 3 221 307 Б, 2195 пакетов, `tx_crc dcf2a804`; клиент→сервер 2716 пакетов, у VoxelCore +8 байт (пароль в Packet1Login) | `…155027_ls2_vc1` |
| VoxelCore / VoxelCore | 59/73 sha256 равны; мин. 98.27 %, среднее 99.88 % | 157/157 | равны | `…155027_ls2_vc1` / `…155211_ls2_vc2`: отличия только на тактах 136–185 (копание: частицы в областях chat/world, такт 175 — hotbar) — недетерминизм рендера движка/пака, не сервера. **Снято этапом 3б: 73/73** (окно текстуры частиц — паком, ниже) |
Подготовка `e2e_walk1_ls`: ожидания `[3, 262, 2, 201, 0, 2, 271, 0]` тактов — одинаково во всех пяти прогонах обеих сторон (вход за 3
такта у обоих; раньше 3 и 5). Время: Java — таймлайн 9.4–9.6 с (было 33 с с темпом), подготовка 11.6 с, весь прогон 37 с; VoxelCore —
таймлайн 9.2 с, подготовка 25 с, прогон 60–62 с. Такт lockstep: Java ~7 мс клиент + ~7 мс сервер (из них ~3.5 мс сервер ждёт
байты — поток-писатель Java-клиента спит 10 мс в простое), VoxelCore ~20 мс клиент (3 команды).
- **Golden в реальном времени остаются верными**: `alpha_spawn` + `layer_terrain_flat` на Java в lockstep — 8/8 снимков 100.00 %
  к старым golden (`runs\20261001_155510_ls_goldcheck`), в реальном времени на новом сервере — тоже 8/8 100.00 % (`…155545_rt_goldcheck`,
  без флага поведение прежнее); перезаписывать не нужно: после `/tp` и `mode` кадр зависит только от мира, позиции, сида клиента и
  тактов после `mode`. VoxelCore на тех же сценариях: lockstep = реальное время до сотых (87.98/91.32/93.15/74.55 и
  99.95/99.95/99.88/99.95 %, `…155940_ls_vc_gold2` / `…155737_rt_vc_gold`), в пределах записей ALPHAMINE §7.
- В отчёте E2E колонка «J/J %» и `reference_noise.json` для lockstep-сценариев больше не нужны (J/J = 100 %); `world_packets` в
  lockstep детерминирован.

## 10. Тестовые сборки VoxelCore с F2F (список, 22.10)
| `hello.version` | exe | ветка (`voxelcore-0.31.0_src_pre`) | README |
|---|---|---|---|
| `0.31-f2f` | `D:\Prog\AlphaMine\engine\VoxelCoreF2F.exe` | `f2f-454aa205` | `engine\README.md` |
| `0.32-f2f` | `D:\Prog\AlphaMine\engine\032\VoxelCoreF2F-032.exe` (0.32.0 dc62ccfb) | `f2f-032` | `engine\032\README.md` |
| `0.32.7-f2f` | `D:\Prog\AlphaMine\engine\0327\VoxelCoreF2F-0327.exe` (релиз 0.32.7) | `f2f-0327` | `engine\0327\README.md` |
Протокол и ключи у всех одинаковые (§1–§2, `--f2f-clock/-window/-size`); лаборатория сверяет `hello.version` с движком аренды
(`[engines.*].f2f_version`, `engine-mismatch`). Звук F2F не глушит: тихий режим — `settings.toml` экземпляра
(`[audio] volume-master = 0`), см. `tools/lab/README.md` «v0327».
