# AlphaMine: нативный клиент Minecraft Alpha 1.0.16 на VoxelCore (план)

Цель пользователя (30.09): с нуля написать **клиент** Minecraft Alpha 1.0.16 как нативный пак VoxelCore
(блоки, мир, свет, HUD, сущности — средствами движка, без wasm-трансляции), с **1:1 совпадением скриншотов**
с оригиналом. Сервер — **оригинальный Java** (Alpha SMP 0.1.1, протокол 14). Проверка соответствия обязательна:
тот же мир, те же условия → скриншот Java-клиента, затем скриншот нашего порта, попиксельное сравнение.
Для этого в **обе** стороны встраивается frame-to-frame API (F2F): детерминированный шаг, ввод, снимок, дамп.
Запуск — как пак с пунктом в «Сценариях» (как `quake`, `eaglercraft`, `html`).

Ограничение пользователя: движок VoxelCore можно пересобирать из исходников, но менять в нём **только**
средства F2F/pixel-to-pixel тестирования и автоматизации. Всё игровое — паком.

## 1. Что есть (разведано 30.09, отчёты агентов в этой сессии)

### Эталон (Java)
- `D:\Backups\alphamine_dec` — рабочее пространство RetroMCP 1.2 (бэкап, **не трогать**). Рабочая копия —
  `D:\Prog\AlphaMine\ref` (105 МБ, скопирована 30.09; `options.cfg` → `workingDir` исправлен).
  Внутри: `minecraft/src` (клиент, 391 java), `minecraft_server/src` (сервер, 246), `src_original` (чистая
  декомпиляция — эталон для diff), `conf/mappings.tiny`, `jars/minecraft.jar` (stock a1.0.16, sha1 совпадает),
  `jars/minecraft_server.jar` (a0.1.1-1707), `jars/assets` (индекс a1.0.14: 143 звука, музыки нет),
  `libraries/` (LWJGL 2.9.4 nightly, natives только Windows), `minecraft/game` (options.txt, saves World1/World2,
  resources/), `minecraft_server/game` (server.properties: offline, порт 25565, world/).
- **Сборка и запуск проверены** (JDK 8 `C:\Program Files\Java\jdk1.8.0_481`, из PowerShell):
  ```
  cd D:\Prog\AlphaMine\ref
  java -jar RetroMCP-Java-CLI.jar recompile      # клиент + сервер, ~1 мин, «Finished successfully»
  java -jar RetroMCP-Java-CLI.jar start server   # окно «Minecraft server», Done! через ~15 с, порт 25565
  java -jar RetroMCP-Java-CLI.jar start client   # окно «Minecraft Alpha v1.0.16», 854×480
  ```
  Клиент **пропатчен**: `GuiMainMenu.updateScreen` сразу подключается к `localhost:25565` (без сервера —
  «Failed to connect»), кнопка «bebra228»; `BlockFire` без частиц/звука, огонь в прозрачном проходе.
  Сервер пропатчен: команды `/tp`, `/gamemode` (op), creative (мгновенная ломка), при входе выдаются огниво,
  64 бревна, 64 земли (`NetLoginHandler`). Протокол и пакеты не менялись.
  Скриншоты: `D:\Prog\AlphaMine\shots\java_first_run.png` (без сервера), `java_world.png` (в мире).
  Снимок чужого окна — тот же `tools/mcp/vc_screenshot.ps1 -ProcessId <pid>` (PrintWindow, окно с рамкой;
  клиентская область 854×480 вырезается по `vc_geom.ps1`). Логи запуска — `D:\Prog\AlphaMine\logs\`
  (cp866). Запускать `Start-Process` с редиректом (см. AGENTS «Ожидания»).
- Ключевые факты клиента (пути `minecraft/src/net/minecraft/src/`, `client/Minecraft.java` = `MC`):
  - цикл `MC.run` (406-513): `Timer(20)` по `currentTimeMillis`+`nanoTime`; за кадр `elapsedTicks` тиков
    `runTick()`, затем **вся очередь света** (`while world.updatingLighting()`), рендер с `partialTicks`,
    `Display.update`; `runTick` (789-958): GUI, ввод LWJGL, `TextureFX` **раз в тик**, `world.tick`.
  - рендер `EntityRenderer.renderWorld` (292-404): FOV 70, near 0.05, far `256>>renderDistance`, туман LINEAR
    `0.25·far…far` (в воде EXP 0.1), цвет тумана — смесь sky/fog по яркости; `RenderGlobal`: чанки 16³,
    display lists, бюджет перестройки 3+1 за кадр, occlusion queries, небо y=±16, солнце 30, луна 20,
    звёзды `Random(10842)`, облака fast/fancy; `RenderEngine`: `GL_NEAREST`, без mipmap.
  - свет: таблица `World.h[l] = (1−f)/(3f+1)·0.95+0.05`, `f = 1−l/15`; уровень = `max(sky−d, block)`;
    грани 1.0 / 0.5 / 0.8 (Z) / 0.6 (X) × яркость **соседа**; **сглаженного света и AO нет**; сущности —
    два направленных источника (`RenderHelper`); GUI масштаб `ScaledResolution` (854×480 → ×2, 427×240);
    шрифт `default.png` с шириной по альфе; HUD `GuiIngame` (сердца дрожат от `rand.setSeed(tick·312871)`).
  - мультиплеер: `WorldClient.tick()` **не** зовёт `super.tick()` → время мира всегда 0 (небо фиксировано,
    угол ≈0.7845), снега и случайных тиков нет, паузы нет; `ChunkProviderClient` без генерации; локальные
    правки блоков откатываются, если сервер не подтвердил.
  - сеть (`Packet.java`): кадр `[u8 id][payload]`, big-endian, без длины; вход Handshake → `"-"` →
    Login(user, "Password", **14**) → Login → Flying/PlayerLookMove (клиент отвечает тем же); чанки PreChunk(50)
    + MapChunk(51, zlib, `blocks[x][z][y]` + nibble meta/blocklight/skylight, чанк целиком 16×128×16), радиус
    ±10 чанков; сущности только игроки/предметы/вагонетки (мобов в SMP нет, времени/здоровья нет); KeepAlive
    раз в 20 тиков; полный список 29 пакетов — в отчёте агента (продублировать в `agents/ALPHA_PROTOCOL.md`
    в фазе 1).
  - недетерминизм: `Timer`, `currentTimeMillis` (сброс мыши >200 мс, автопауза >500 мс, пульсация трещин
    и splash), `new Random()` в `Entity`, `EffectRenderer`, `GuiIngame`, `EntityRenderer` (дождь), `World`;
    `Math.random()` во **всех** `TextureFX` (вода, лава, огонь), частицах, `EntityLiving`; потоки сети и
    загрузки ресурсов. Зависят от кадра: поворот мыши, бюджет чанков, occlusion, `getMouseOver`.
  - ошибки маппинга в `World.java`: `lightingToUpdate` = сущности, `loadedEntityList` = тайл-сущности,
    `skylightSubtracted` = состояние LCG (вычитание света — поле `d`), `b` = время, `q` = сид.
- Старая попытка `voxelcore.0.29.0_win64_alphamine`: пак `content/alphamine` — только текстуры (часть не
  альфовские) и звуки (12 из 75 оригинальные); кода нет; скрипты — пропорциональный шрифт из
  `spritefont.png` в Canvas (`ASCII.lua`, `save_font.py`, `char_regions.json`), `alpha.png` — эталон меню.
  Ассеты извлекать заново из `jars/minecraft.jar` и `jars/assets`.

### VoxelCore 0.31 (что даёт движок; исходники `D:\Prog\VoxelCore\voxelcore-0.31.0_src_pre\voxelcore`,
MSVC + vcpkg, `CMakePresets.json` `default-vs-msvc-windows`, `build/` уже конфигурирован)
- Мир из сети: `world.set_chunk_data(cx, cz, Bytearray)` для **уже загруженного** чанка (`on_chunk_present`);
  формат: флаги, `int32 LE` длина, `gzip(extrle16(65536×u16 id, 65536×u16 state))`, индекс `(y·16+z)·16+x`,
  высота 256 (альфа 0..127). Пример: `voxelcore-0.34_pre roman_donw/content/Neutron-Client/modules/net/handlers/in_game.lua`,
  `D:\Prog\VoxelCore\multiplayer\cli\scripts\world.lua`. Генератор — свой `generators/void.toml` со слоем
  воздуха (проверить). Свет движок считает сам (частичной непрозрачности нет — вода/листва только да/нет).
  MapChunk сжат zlib, `compression.decode` умеет gzip: трюк с обёрткой (CRC игнорируется) или inflate на Lua.
- Свет и тени граней: движок даёт `0.7+0.3·dot(N, sun)` и AO (`graphics.soft-lighting`); коэффициенты
  Minecraft и таблицу яркости альфы — подменой `shaders/main.glslv` / `lib/lighting.glsl` из пака (паки
  `blocks_waves`, `SphereShader` так делают). Туман/небо: `gfx.weather.change`, `world.set_day_time`, свои
  `skybox_gen.glslf`, `fog.glsl`, `sky.glsl`. Блоки: JSON (`texture-faces`, `model`, `state-based` варианты,
  `emission`, `light-passing`, `draw-group`), до 65535 id.
- Камера `cameras.get(...)`: `set_fov`, `set_pos`, `set_rot`; игрок `player.set_pos/rot/vel/noclip/flight/suspended`,
  `set_loading_chunks`; сущности `entities.spawn` + скелеты; HUD XML + `<canvas>`; шрифт движка
  моноширинный → шрифт альфы через Canvas/`<image>`; сеть `network.tcp_connect` + `recv(available())`
  (приём в отдельном потоке, не блокирует), `byteutil.pack('>...')`, `data_buffer`.
- **Нет:** снимка экрана из Lua (только F2 → `screenshots/`), фиксированного шага в оконном режиме
  (только `--headless --test` без рендера), синтеза ввода из Lua, изменения размера окна на лету
  (`display.width/height` в `settings.toml`). Это ровно то, что разрешено добавить в движок для F2F.

## 2. Архитектура решения

```
D:\Prog\AlphaMine\                       (вне каталога движка; станет git-репозиторием → приватный GitHub по просьбе)
  ref\        RetroMCP-пространство: клиент+сервер Java, наши правки F2F (patches\f2f-client.patch от src_original)
  assets\     извлечённые текстуры/звуки из minecraft.jar + assets (скрипт extract_assets.py)
  golden\     эталонные снимки и дампы Java по сценариям (имя сценария/шаг → png + state.json)
  engine\     патч движка для F2F (f2f.patch к voxelcore-0.31.0_src_pre) + собранный VoxelCore.exe (f2f-сборка)
  logs\ shots\
VC_ROOT (движок, рантайм)
  content\alphamine\                     пак: блоки/предметы (генерируются из Block.java/Item.java), текстуры,
                                          modules\{net,chunks,render,hud,player,f2f}.lua, generators\void.toml,
                                          shaders\{main.glslv,...}, scripts\app\alphamine.lua (пункт «Сценарии»)
  tools\mcp\alpha_tools.py               MCP `am_*`: сервер/клиент Java, F2F к Java и к VoxelCore, снимки, сравнение
  tools\scenarios\alpha\*.json           сценарии MCP (как eag/*.json): один и тот же сценарий гоняется на обеих сторонах
  tools\reference\compare.py             попиксельное сравнение (есть), + маски и отчёт по регионам
```

### Изоляция от Windows (требование пользователя 30.09)
ПК используется во время тестов: снимок — только из кадрового буфера внутри приложения (FBO фиксированного
размера, `glReadPixels`), ввод — только по протоколу F2F (реальные клавиатура/мышь/фокус игнорируются в
F2F-режиме), курсор не захватывается, время только виртуальное. `vc_screenshot`/`vc_keys`/`vc_click` —
только для ручной разведки, результат через них тестом не считается. Подробно — `agents/F2F.md` §0.

### F2F API (одинаковый на обеих сторонах)
Транспорт: TCP localhost, строка JSON на команду, ответ — строка JSON (Java: порт 25570, VoxelCore: 25571;
если у Lua нет `network.tcp_open` — сторона VoxelCore сама подключается к харнессу, направление
запросов то же). Реализация Java — класс `F2FAgent` (по образцу `VcDebug.java` из порта Eaglercraft:
хук в `MC.run` после тиков и после рендера, фасад ввода `F2FInput` вместо прямых вызовов LWJGL `Mouse`/`Keyboard`
в `MC:827-918`, `GuiScreen:81-113`, `MouseHelper:43`, `EntityRenderer:268`).
| Команда | Что делает |
|---|---|
| `hello` | `{impl:"java"|"vc", version, w, h, tick_ms:50}` |
| `mode {fixed:true, seed:N}` | виртуальное время (Java: `Timer` не читает часы, `currentTimeMillis` подменён в 6 местах; VoxelCore: патч движка — `time.update` от F2F), сиды всех `Random`/`Math.random` (Java через reflection), occlusion выкл., окно «активно», бюджет перестройки чанков — «до пустой очереди» |
| `step {ticks:N, frames:M, partial:p}` | выполнить N тиков и M кадров (последний с partial p); ответ после `Display.update` |
| `input {keys:{W:true,...}, mouse:{dx,dy,buttons,wheel}, chars:"..."}` | состояние ввода на следующие тики (события генерируются фасадом) |
| `state` | игрок (pos, motion, yaw/pitch, onGround, health, инвентарь, выбранный слот), экран GUI и кнопки, время мира, число чанков, `hash` блоков в радиусе R вокруг игрока (FNV по id+meta), список сущностей |
| `shot {path}` | Java: кадр из своего FBO 854×480 → PNG (окно, фокус и перекрытие не влияют); VoxelCore: чтение кадра движком после рендера (патч) |
| `tp {x,y,z,yaw,pitch}` / `chat "/tp ..."` | позиция (через сервер `/tp` для обоих одинаково) |
| `gui {click:[x,y] | key:...}` | клики/клавиши в экраны GUI (координаты экрана 854×480) |
| `wait {screen|world|chunks:N}` | ждать условия по кадрам (как `eag_wait`) |
Сценарий парности = список шагов F2F + точки снимков; харнесс гоняет его на Java (пишет `golden/`), затем на
VoxelCore, сравнивает `compare.py` с масками (по умолчанию без масок: HUD и рука тоже должны совпасть; строка
fps в отладочной надписи фиксируется в F2F-режиме). Порог: 0 расхождений для статики, отчёт по регионам.

### Порядок фаз (после фазы 0)
1. **Эталон + F2F Java** (1–2 дня): `F2FAgent`, фасад ввода, детерминизм; MCP `am_server/am_client/am_f2f/am_shot`;
   первые golden-снимки (спавн `world`, 4 направления, время 0). Критерий: два прогона Java дают 0 расхождений.
2. **Каркас пака + сеть** (2–4 дня): пак `alphamine`, void-генератор, TCP-клиент протокола 14 (login, KeepAlive,
   PreChunk/MapChunk → `set_chunk_data`, BlockChange, позиция игрока), блоки по `Block.java` с текстурами из
   `terrain.png`; пункт в «Сценариях»; F2F в Lua + патч движка (шаг, снимок, ввод). Критерий: мир сервера виден.
3. **Паритет рендера** (самая долгая): шейдеры (грани, таблица яркости, sky−d, туман, небо/солнце/луна/звёзды,
   облака), текстуры (NEAREST, анимации воды/лавы/огня по тику с сидом), рука и вид от первого лица (FOV 70,
   bobbing), HUD (хотбар, сердца, прицел с инверсией, шрифт, отладочная строка), GUI-экраны. Сравнение по
   сценариям после каждого шага.
4. **Игра**: физика игрока (константы `EntityLiving.moveEntityWithHeading`), ломание/установка с откатом,
   инвентарь/крафт/печь/сундук, предметы, сущности (игроки, предметы, вагонетки/лодки), звуки, чат.
5. **Набор парности как регрессия**: сценарии в `verify.sh full`, отчёт, порог по регионам; репозиторий.

## 3. Фаза 0 — подготовка

### Сделано 30.09
- [x] Разведка исходников клиента/сервера и API движка (отчёты — в разделе 1).
- [x] Рабочая копия `D:\Prog\AlphaMine\ref`, пересборка RetroMCP JDK 8 — успешно.
- [x] Сервер + клиент запущены, вход в мир, снимок `shots\java_world.png`; `vc_screenshot.ps1` снимает чужое окно.
- [x] Правила: движок — только F2F-правки (AGENTS.md, память).
- [x] Спецификация F2F с изоляцией от Windows (`agents/F2F.md`); первый обязательный тест — Java против Java при разных состояниях окна.

### Осталось в фазе 0 (порядок выполнения)
1. **Ассеты и таблицы** — ГОТОВО (30.09). `tools/alphamine/extract_assets.py` → `D:\Prog\AlphaMine\assets\`
   (не в git, пересоздаётся за ~5 с): 60 ресурсов jar по исходным путям, 143 звука `sound/<имя из индекса>`
   (13 записей `custom` индекса — музыка `calm1-3`, `piano1-3`, `creeper1-4`, `bow`, `door_open/close` — объектов нет;
   у Java-клиента в `game/resources` на их месте HTML «301 Moved», т. е. в эталоне этих звуков нет), тайлы
   `tiles/terrain/0..255.png`, `tiles/items/0..255.png`, по таблицам `named/blocks/*.png` (98) и `named/items/*.png` (91),
   `manifest.json` (904 записи: path, size, sha1, source). `tools/alphamine/gen_tables.py` → `D:\Prog\AlphaMine\tables\`
   (в git): `blocks.json` (69 блоков: id 1-20, 35, 37-84), `items.json` (91 предмет Item.java + 69 ItemBlock),
   `textures_by_block.json` (98 тайлов terrain.png → имя и (блок, грань, meta, источник)), `NOTES.md`. Значения
   не выдираются регэкспами, а **исполняются** мини-интерпретатором Java (`tools/alphamine/minijava.py`: конструкторы,
   инициализаторы полей, static-init Block↔Item, виртуальные вызовы); неразобранных случаев 0, сверка с известными id
   42/42, грань травы 0/2/3. Мировые текстуры (трава под снегом 68, двойной сундук 41/42/57/58, фронт печи по meta)
   считаются в мок-мире. Классы `F2F*` интерпретатор считает внешними — таблицы из рабочего дерева с F2F и из бэкапа
   совпадают побайтно. Раскладка для пака (`content/alphamine/textures/blocks/<name>.png`, JSON блоков) — в фазе 2
   из этих таблиц; порядок X/Z в `texture-faces` VoxelCore проверить запуском.
2. **Спецификация F2F** — черновик написан (`agents/F2F.md`: изоляция от Windows, транспорт, команды, точки в
   кадре, детерминизм, сценарии); уточняется по ходу реализации п. 3.
3. **F2F в Java-клиенте** — ГОТОВО (30.09). `ref/minecraft/src/net/minecraft/src/`: `F2F` (конфиг из свойств
   `f2f.port/size/server`), `F2FLaunch` (main: `--f2f PORT --f2f-size WxH --server HOST:PORT` → свойства, остальное —
   launchwrapper), `F2FAgent` (TCP 127.0.0.1, JSON-строки, команды на главном потоке вместо кадра `Minecraft.run`),
   `F2FFrame` (FBO 854×480 + depth24, `glReadPixels` → PNG, окно — только копия), `F2FKeyboard`/`F2FMouse` (фасады
   LWJGL в `runTick`, `GuiScreen`, `MouseHelper`, `EntityRenderer`; курсор не захватывается, потеря фокуса не
   паузит), `F2FClock` (виртуальное время), `F2FRandom` (все `new Random()` клиента и 48 `Math.random()`), `F2FJson`;
   хуки в 40 файлах (`Timer` не тронут — в F2F-цикле не вызывается, тики и `partial` задаёт `step`). Автоподключение
   меню — к `--server` (по умолчанию localhost:25565), в F2F-режиме только командой `connect`. Без `--f2f` поведение
   прежнее (проверено: автоподключение, окно, `options.txt`). Запуск — `ref/start_client.ps1`, `ref/start_server.ps1`
   (WMI, без наследования дескрипторов). Патчи: `ref/patches/f2f-client.patch` (всё от `src_original`, включая старые
   правки огня/меню) и `f2f-only.patch`; оба проверены `patch -p1`. Уточнения протокола — `agents/F2F.md` §6.
   **Проверка изоляции:** сценарий `alpha_spawn` (свежая копия `golden/world_a`, два `/tp` до 104.5 67 104.5, `mode`
   seed 20260930, 100 тиков, 4 снимка через `input dx 600`): эталон `D:\Prog\AlphaMine\golden\alpha_spawn\` и три
   прогона — обычное окно (`runs\20260930_052404_java_normal`), перекрыто развёрнутым блокнотом
   (`runs\20260930_052748_java_covered`), свёрнуто, `IsIconic=True` (`runs\20260930_053053_java_minimized`) —
   **0 отличающихся пикселей во всех 4 снимках**, sha256 совпали. Чувствительность: другой сид — 16 368 пикселей,
   лишний тик — 9 968, повтор в той же сессии после `mode` — 0.
4. **MCP `am_*`** — ГОТОВО (30.09). `tools/mcp/alpha_tools.py` (зарегистрирован в `voxelcore_mcp.py`, все вызовы в
   журнале; `am_*` не снимают окно VoxelCore): `am_server(start|stop|status, world, port)` (robocopy мира в
   `D:\Prog\AlphaMine\run\server`, ~3 с до «Done!»), `am_client(start|stop|status, impl, f2f_port, size, server)`
   (~22–40 с до F2F hello, из них ~20 с — проверка ресурсов launchwrapper), `am_f2f`, `am_step`, `am_input`,
   `am_state`, `am_shot` (→ `D:\Prog\AlphaMine\shots\`, картинкой), `am_compare(a, b, tol)` (число пикселей,
   bbox, diff-картинка), `am_scenario(name, impl, golden, window=normal|covered|minimized, keep)` (сценарии
   `tools/scenarios/alpha/*.json`, снимки в `golden\<имя>\` или `runs\<время>_<impl>_<window>\<имя>\` + `report.json`
   и сравнение с golden). Клиент без MCP — `tools/alphamine/f2f_client.py` (из WSL через `f2f_relay.ps1`).
   `impl="vc"` пока отвечает «фаза 2». Прогон `alpha_spawn` — 2.5–3.5 мин (ожидание чанков в реальном времени).
5. **Движок** — ГОТОВО (30.09), релизный рецепт (`windows-clang.yml`: MSYS2 CLANG64, vcpkg `x64-mingw-static`, статика).
   `D:\Prog\AlphaMine\engine\` (README там же): **`VoxelCoreF2F.exe`** = `454aa205` (коммит `main` перед сборкой рантайма
   26.02) + патч F2F (ветка `f2f-454aa205`); `VoxelCore-454aa205.exe` (сток той же ревизии), `VoxelCore-stock.exe`
   (`main` как есть), `VoxelCoreF2F-main.exe` (ветка `f2f`). vcpkg `29f10019` (26.02) даёт LuaJIT `2.1.1771261233`
   (как в рантайме, overlay не нужен), libpng 1.6.55, GLFW 3.4, те же системные DLL. Lua-окружение (`tests/env_dump.lua`,
   `jit_profile_probe.lua`) рантайм ≡ 454aa205 ≡ F2F (плюс глобал `f2f`); у `main` лишний `file.__seek_descriptor`.
   Побайтно exe не совпадают: другой clang (22.1.8 против 21.x) и CRT с отладочными секциями в рантайме.
   F2F: `--f2f 25571 [--f2f-size 854x480]`, `hello/mode/step/input/shot/quit` + Lua-обработчик `f2f.set_handler`;
   кадр в офскрин-FBO; снимок меню одинаков (sha256 `86feac94…`) при обычном, перекрытом, свёрнутом окне и в повторном
   процессе; клик по «Настройки» и ESC работают (`tools/alphamine/f2f_probe_vc.py`, Windows-питон). Не сделано:
   детерминизм мира (`wait`, `state`) — через обработчик пака; рантайм `VC_ROOT\VoxelCore.exe` не подменялся.
   **Дополнение (30.09): слои рендера §7** — команда `render {all, layers, clear}` в движке (`src/devtools/f2f_render.*`
   + ворота в `WorldRenderer`, `ChunksRenderer`, `BlocksRenderer`, `Hud`, `gui::Container`, `MenuScreen`), имена как у
   Java `F2FRender`, `hello` отдаёт `layers` и `render`. `VoxelCoreF2F.exe` пересобран (прежний — `VoxelCoreF2F-prev.exe`),
   `VoxelCoreF2F-main.exe` тоже (прежний — `-main-prev`), патчи `f2f-454aa205.patch`/`f2f.patch` обновлены (правки не
   закоммичены). Проверка `f2f_probe_vc.py --cases layers_menu,layers_world` (мир `engine/tests/f2fworld`, `base:demo`):
   меню `all:false` → 100 % пикселей = `clear` (и `[0,0,0]`, и `[40,80,120]`), `gui` → меню как без патча (`86feac94…`);
   в мире только terrain — 12.5 % фона, lighting вкл/выкл — 86.9 % разницы и повторяемо побайтно, fog — 85.4 %, hud выкл —
   хотбар и прицел (7.2 %), hand выкл — рука (4.6 %), all→слои→all — побайтно тот же кадр. Таблица ворот и что не
   гасится — `engine/README.md` «Render layers».
6. **Пробы движка запуском** — ГОТОВО (30.09). Скрипты `tools/scenarios/alpha_probes/` (`p1_void`, `p2_chunk`,
   `p3_zlib`, `p4_shader` + `p4_analyze.py` + `shaders/`, `p5_tcp` + `tools/alphamine/tcp_echo_server.py`, `p7_camera`),
   числа — раздел «Результаты проб движка (30.09)» ниже, грабли — `agents/LESSONS.md` «AlphaMine».
7. **Каркас пака** (прямой запуск: `vc_start(script="user:tools/scenarios/alphamine_world.lua", wait_for="\\[alphamine_app\\] ready")`, ≈8 с до мира; логика в `alphamine:launch`) — ГОТОВО (30.09). `content/alphamine`: `package.json` (зависимость `base` — игрок, рука, HUD
   движка; убрать, когда появятся свои), `icon.png` (заглушка 128×128), `generators/void.toml`, `scripts/world.lua`
   (события → модули), `scripts/hud.lua`, `modules/chunk_codec.lua` (рабочий кодек, см. пробы 2–3),
   `modules/{chunks,net,render,hud,player,f2f}.lua` (заглушки с точками входа), `scripts/app/alphamine.lua` (пункт
   «Сценарии» → мир `AlphaMine` на `alphamine:void`, создаётся при первом запуске, маркер `[alphamine_app] ready`),
   `README.md`. Проверено кликом по «Сценарии» → `alphamine`: `artifacts/screens/alpha_scenarios.png`,
   `alphamine_app_world.png` (пустой мир, небо, хотбар), в логе `[alphamine] world open, generator alphamine:void`.
8. **git** — ГОТОВО (30.09). `D:\Prog\AlphaMine` — репозиторий (ветка `main`, автор из глобального git), первый коммит
   `AlphaMine: initial import`: `ref/` (исходники клиента/сервера, `src_original`, `conf/`, `md5/`, конфиги; 1349
   файлов, `.git` 1.8 МБ), `tables/`, `README.md` (что это, восстановление RetroMCP из бэкапа/`setup`, `recompile`,
   запуск скриптов), `.gitignore` (bin/output/reobf/jars, `ref/jars`, `ref/libraries`, `ref/build`, RetroMCP jar,
   сохранения/ресурсы Java, мир сервера, `assets/`, `logs/`, `shots/`, `runs/`, бинарники `engine/`), `.gitattributes`
   `* -text`. Исходники в коммите побайтно равны бэкапу `D:\Backups\alphamine_dec` (правки пользователя есть, F2F — нет):
   параллельная работа F2F (`F2F*.java`, правки `Minecraft.java` и др., `golden/`, `run/`, `ref/start_*.ps1`,
   `engine/`) оставлена незакоммиченной. GitHub не создавался.

### Результаты проб движка (30.09, рантайм `VC_ROOT\VoxelCore.exe`, окно 1390×855, 120 fps)
Запуск: `python3 tools/mcp/run_tool.py vc_start '{"script":"user:tools/scenarios/alpha_probes/<проба>.lua","wait_for":"\\[alpha_pN\\] done","restart":true}'`
(p3 — headless: `"script":"none","args":["--headless","--script","tools/scenarios/alpha_probes/p3_zlib.lua"]`).
Общий мир проб `AlphaProbe` пересоздаётся каждым запуском (после проб удалён).

1. **Пустой генератор работает.** `generators/void.toml` + `void.files/biomes.toml` со слоями `{height=-1, block="core:air"}`
   (и в `layers`, и в `sea-layers`), без скрипта. `p1_void`: `world.get_generator()` = `alphamine:void`, 9 чанков
   (-1..1)² полным обходом `block.get` — `nonair=0 unloaded=0`, точки (0,0,0), (5,10,5), (-7,1,3), (15,255,15),
   (8,64,8) = 0 `core:air`. Грабля: точку спавна движок ищет спуском до первого препятствия (`Player::attemptToChooseSpawnpoint`)
   и в пустоте ставит игрока на y≈0 поверх `set_pos` (было 20.5, −0.03, 7.5) — нужны `player.set_spawnpoint` +
   `set_flight`/`set_noclip` (так делает `scripts/app/alphamine.lua`).
2. **`world.set_chunk_data` + кодек на Lua** (`modules/chunk_codec.lua`, `p2_chunk`). raw = 65536×u16 id + 65536×u16
   state = **262144 байта**; наш extrle16 **побайтно совпал** с тем, что кодирует сам движок (`world.get_chunk_data`
   → gzip → 193 Б, identical=true); проверка всех 65536 вокселей `block.get` — 0 расхождений. Среднее из 200:
   заполнение raw узором 0.105 мс, extrle16 0.150 мс, encode (extrle16+gzip+заголовок) 0.160 мс, `set_chunk_data`
   0.110 мс (данные 96 Б — простой узор; реальный чанк альфы даст больше серий). Свет/меш: после одного чанка —
   один кадр 11 мс, дальше 8 мс; после 9×9 = 81 чанка (заполнение+encode+set 33 мс, 0.41 мс/чанк) ~16 кадров по
   18–31 мс (≈0.35 с), затем 8 мс. Блоки видны сразу, тени от «крыши» есть: `artifacts/screens/alpha_p2_shot1.png`,
   9×9 — `alpha_p2_shot2.png`. `on_chunk_present` пака срабатывает (101–103 раза при load-distance 7).
   При `chunks.load-distance=4` грузится круг из **45** чанков (углов 9×9 нет); у альфы радиус ±10 чанков (441) —
   дальность придётся поднять (проба временно ставила 7 и возвращала). Блоков с id > 255 (широкая ветка extrle16)
   в пробе не было — не проверено.
3. **zlib → gzip работает** (`p3_zlib`, headless). Обёртка `chunk_codec.zlib_to_gzip`: 10 байт заголовка gzip +
   deflate без 2 байт zlib-заголовка и 4 байт Adler + CRC=0 + верный ISIZE → `compression.decode` возвращает данные
   **побайтно** (81920 Б «как чанк альфы», zlib 4161 Б; и 81920 случайных, zlib 81951 Б). Время (среднее 200):
   0.10 мс и 0.53 мс с обёрткой (копирование в Lua), сам `decode` 0.06–0.11 мс. Буфер результата = ISIZE (40000 →
   40000 Б, 100000 → 100000 Б с нулями в хвосте). **Нельзя** подавать zlib без обёртки: движок берёт размер из
   последних 4 байт и выделяет мусорный объём (585 962 135 и 990 104 846 Б!). Inflate на Lua не нужен (не писался).
4. **Шейдеры мира из пака** (`p4_shader`, `p4_analyze.py`). `content/<пак>/shaders/main.glslv` и `main.glslf`
   подменяют движковые (мир стал цветом-отладкой, `alpha_p4_shader.png`). **Подмена `shaders/lib/lighting.glsl` из
   пака НЕ действует** (заголовок закэширован движком до загрузки паков, `GLSLExtension::loadHeader` + `hasHeader`),
   а заголовок **с новым именем** (`shaders/lib/am_lighting.glsl`, `#include <am_lighting>`) подключается. При
   `graphics.soft-lighting=false` (и `backlight=false`) уровень света вершины восстанавливается точно:
   `L = round(v_light * 15 / d)`, `d = 0.7 + 0.3·dot(N, SUN)`, SUN = (0.528265, 0.833149, −0.163704): 658 678 пикселей
   мира, 100% значений кратны 17; открытый верх травы = 15, под крышей 14/13/12, свет лампы 15…1. «Наивный»
   `round(v_light*15)` неверен (верх 14 вместо 15) в 623 544 пикселях — делить на `d` обязательно (движок домножает
   свет на `d` и отбрасывает дробь при упаковке в u8). `graphics.backlight=true` поднимает минимум до 1 — выключать.
   Каналы: `v_light.rgb` — блочный свет (RGB), `v_light.a` — небо.
5. **TCP.** В этой сборке есть и `network.tcp_connect`, и `network.tcp_open` (+UDP). Приём из WSL (режим сети
   **NAT**) работает по `127.0.0.1`, `localhost` и IP WSL `172.25.147.0` (сервер `tcp_echo_server.py` слушает
   0.0.0.0:25580): 8 МБ приходят целиком (выборочная проверка содержимого — 0 ошибок) за ≤0.06 с от вызова
   `tcp_connect`, за 2–4 кадра `recv(available())` (куски до 7.4 МБ, время в `recv` 8–10 мс на все 8 МБ); эхо 64 КБ
   туда-обратно 6–9 мс. Приём идёт в отдельном потоке движка (по байту в `std::vector`; `recv` стирает начало вектора —
   читать всё `available()` разом, а не мелкими кусками). `tcp_open` запуском **не проверялся**: сервер слушает
   `INADDR_ANY`, а у этого exe нет правила брандмауэра → всплыло бы окно Windows при занятом пользователе; для
   F2F безопаснее, чтобы движок сам подключался к харнессу (или флаг `--f2f` собранного `VoxelCoreF2F.exe`).
6. **F2 через `vc_keys "f2"`** пишет `VC_ROOT\screenshots\screenshot-<дата_время>.png` (1390×855 — клиентская
   область, RGB), в логе `[window-control] saved screenshot as user:screenshots/...`; обрабатывается в `Engine.cpp`
   всегда (не только в мире). Требует фокуса окна — для F2F не годится (там свой снимок).
7. **Камера/настройки** (`p7_camera`). `cameras.get("core:first-person"):set_fov(70)` держится один кадр: `get_fov`
   сразу 70, через 1 с снова 90 — `CameraControl::update` каждый кадр ставит встроенной камере `camera.fov` из
   настроек. Варианты для FOV 70: `app.set_setting("camera.fov", 70)` (меняет настройку пользователя — возвращать при
   выходе), `set_fov` каждый кадр после обновления контроллера (порядок не проверен) или своя камера через
   `player.set_camera` (не встроенная — движок её FOV не трогает; не проверено). Настройки камеры: `camera.fov`
   (10…120, по умолчанию 90), `camera.fov-effects` (изменение FOV при беге), `camera.shaking` (покачивание = bobbing),
   `camera.inertia`, `camera.sensitivity`. Рука — `res/scripts/hud.lua`: скелет `hand`, `hud.hand_controller`
   (если задан, заменяет `update_hand`) — скрыть/заменить руку можно из HUD-скрипта пака (не проверено запуском).
   Прочее из проб: `time.uptime()` внутри кадра сценария не меняется (замерять `os.clock()`, шаг 1 мс на Windows,
   повторами); в окружении пака нет глобального `ffi`, но `Bytearray.bytes` — указатель, запись `b.bytes[i]` быстрая;
   `Bytearray(n)` — `malloc` без обнуления; Lua-функции чтения света блока нет (`block.*` без `get_light`).

**Не подтверждено запуском:** `tcp_open`; ширина серий id > 255; скорость на реальных MapChunk (чанки 16×128×16 с
рудами/пещерами); FOV через свою камеру / `set_fov` каждый кадр; скрытие руки; прирост времени света при массовой
загрузке 441 чанка. Ошибка `[gl-framebuffer] framebuffer is not complete!` (2 раза при открытии мира) есть и без
шейдеров пака — к пробам не относится.

Правила работы по проекту: движок — один агент; сервер Java (`Minecraft server`, порт 25565) и клиенты Java
останавливать после прогона — только свои: `am_server stop port=<порт>` / `am_client stop f2f_port=<порт>` (сервер
помечен `-Dalphamine.dir=<каталог>`, у каждого порта свой `run\server[_<порт>]` и лог; `Get-Process java | Stop-Process`
убьёт и чужой сервер другого агента — нельзя); эталонные снимки только в F2F-режиме
(фиксированные время/сиды/ввод), иначе они не воспроизводимы; изменения в `ref/` — только через патчи от
`src_original`.

## 4. Фаза 1 — слои рендера и метрика в процентах (Java-сторона, 30.09)
Требование и уточнения по факту — `agents/F2F.md` §7 и §7.1. Сделано:
- **`render` в Java-клиенте** (`F2FRender.java` + ворота в `EntityRenderer`, `RenderGlobal`, `WorldRenderer`,
  `Tessellator`): слои `sky clouds terrain water entities particles weather selection hand hud gui`, модификаторы `fog`,
  `lighting` (выкл = цвет вершин чанка 1.0 через `Tessellator` при компиляции чанка, текстуры не тронуты), `clear`,
  `all`. Без `--f2f` все ворота пропускают (`!F2F.enabled`), по умолчанию всё включено: `alpha_spawn` после правок —
  те же sha256, 100 % против golden. `mode` ещё обнуляет `age`/`hoverStart` у `EntityItem`. Патчи
  `ref/patches/f2f-client.patch`, `f2f-only.patch` пересобраны и проверены `patch -p1` (результат = `minecraft/src`).
  Клиент без пересборки сервера: `ref/compile_client.ps1 <файлы>` (javac в `minecraft\bin`; RetroMCP `recompile`
  пересобирает и сервер, `--side` игнорирует — нельзя, пока у другого агента работает сервер).
- **Метрика**: `tools/reference/compare.py` — `metrics()` и режим `--f2f a b [--tol --clear --out --heat --json]`
  (старый CLI с `--ox/--oy/--rect` не менялся); MCP `am_compare(a, b, tol, clear, out, heat, show)` — таблица + JSON.
- **Сценарии слоёв** `tools/scenarios/alpha/layer_<слой>.json` (`"base": "alpha_spawn"`, шаг харнесса `look`, имена
  снимков) и **`am_layers(impl, golden, layers?, window?, tol?, world?)`** — все слои в одной сессии (≈85 с на 12 слоёв).
  Golden Java — `D:\Prog\AlphaMine\golden\layer_<слой>\` (покрытие кадра, % пикселей ≠ clear):

  | слой | снимки | покрытие, % | что в кадре |
  |---|---|---|---|
  | sky (+fog) | 4 стороны | 100 ×4 | купол с градиентом, нижняя плоскость |
  | terrain_flat | 4 стороны | 72.16 / 87.30 / 63.96 / 46.94 | земля без света и тумана, небо чёрное |
  | terrain_lit | 4 стороны | те же | + свет (дно под водой тёмное) |
  | terrain_fog | 4 стороны | те же | + туман цвета неба |
  | water | 4 стороны | 9.95 / 5.91 / 11.51 / 22.71 | только вода |
  | clouds | 4 стороны | 15.02 / 18.63 / 7.50 / 20.99 | облака fancy |
  | hand | 4 стороны | 5.33 ×4 | огниво в руке |
  | hud | 4 стороны | 4.35 ×4 | хотбар, сердца, прицел, строка версии |
  | entities | 4 стороны | 0.24 / 0 / 0 / 0 | выброшенное бревно (только в yaw 0) |
  | particles | 4 по времени | 0.25 / 0.39 / 0.45 / 0.21 | частицы копания травы |
  | selection (clear белый) | 4 стороны pitch 60 + трещины | 0.65 ×4, 6.22 | рамка блока, трещины |
  | gui | меню, наведение | 98.72 ×2 | GuiIngameMenu |

  **Повторяемость**: три прогона всех слоёв против golden (обычное окно, ещё раз, свёрнутое) и отдельные
  `am_scenario layer_entities`, `layer_terrain_lit` — **100.000 % идентичных во всех снимках**. Исключительность:
  в `sky` 0 пикселей не-неба (B ≤ R или B ≤ G); в `terrain_flat` (yaw 270) 0 пикселей в строке версии и прицеле (в `hud` — 1756 и
  68), верх кадра yaw 270 пуст (чёрное небо).
- **Мир `golden\world_b`** — `world_a` после одного прогона и `/stop` (подробно — F2F.md §7.1): убрал недетерминизм света
  дальних чанков (12 пикселей в 1 из 2 прогонов на `world_a`) и генерацию на сервере; `alpha_spawn` переведён на него,
  его golden не менялся (снимки на `world_b` побайтно те же).
- **Время** (`alpha_spawn`, до → после): клиент 22–40 с → **2.1–2.7 с** (индекс ассетов `a1.0.14-local`: 13 записей
  `custom` берутся из `file:` — те же 536-байтные «301 Moved», что раньше каждый старт перекачивались по https ~20 с;
  `am_client assets=remote` — старый путь); сервер с копией мира 2–7 с (копия robocopy 1.1 с — не узкое место);
  ожидание чанков 145–165 с → **43–58 с** (`world_b`); весь `alpha_spawn` 141–171 с → **57 с**; 12 слоёв —
  **80–91 с** за сессию (раньше было бы 12 × ~2.8 мин).
- **Процессы**: `am_server`/`am_client` останавливают только своё (метка `-Dalphamine.dir`, точный F2F-порт); у порта
  ≠ 25565 свой каталог `run\server_<порт>` и лог `server_<порт>`.

## 5. Фаза 2 — пак `alphamine`: мир сервера в VoxelCore (сторона VoxelCore, 30.09)
Критерий фазы («мир сервера виден») выполнен; первые проценты слоёв против golden Java — ниже. Устройство пака, запуск —
`content/alphamine/README.md`; грабли — `agents/LESSONS.md` «AlphaMine — пак и сеть».

**Сделано**
- **Блоки** — `tools/alphamine/gen_pack_blocks.py` (из `tables/` и `assets/tiles/terrain`): 69 блоков `alphamine:<name_snake>`,
  131 текстура `am_*` (префикс обязателен: атлас общий с `base`, см. LESSONS), варианты `state-based` по meta (всходы,
  пашня, фронт печей, рельсы, редстоун), `emission` = свет альфы, `light-passing` по `light_opacity`, `obstacle` по коробкам
  столкновений альфы, `breakable:false` (мир принадлежит серверу); заглушки рендер-типов — `content/alphamine/BLOCKS_TODO.md`
  (27 пунктов: жидкости без уровней, факелы, огонь, двери, лестницы, ступени, рельсы, кактус, знаки...). Meta хранится
  в userbits у **всех** блоков → обратное отображение движок → (id, meta) точное (`modules/blocks.lua`).
- **Порядок граней проверен запуском** (`tools/scenarios/alpha_probes/p8_faces.lua`, снимки `artifacts/screens/alpha_p8_*.png`):
  печи meta 2..5 (фронт на −Z, +Z, −X, +X альфы), камера пака с 4 сторон — фронт виден ровно у ожидаемой печи.
  `texture-faces` = [−X, +X, −Y, +Y, −Z, +Z] (как в исходнике `BlocksRenderer`), альфа → VoxelCore `[4,5,0,1,2,3]`.
  UV: 5 граней совпадают с `RenderBlocks.render*Face`, у нижней «верх» картинки противоположный → отражённая текстура.
- **Сеть** (`modules/net.lua`): протокол 14 целиком по разбору (29 пакетов, размеры из `Packet*.java`), вход,
  эхо позиции, KeepAlive, PreChunk/MapChunk (zlib→gzip обёртка), BlockChange/MultiBlockChange, чат, AddToInventory,
  Kick; сущности разбираются и пропускаются. **Чанки** (`modules/chunks.lua`): хранилище в раскладке `Chunk`,
  `World/Chunk.setChunkData` для частичных MapChunk, запись в движок по `on_chunk_present`. **Игрок** (`modules/player.lua`):
  физика стоящего игрока с float-константами Java — приземление после `/tp` совпадает с Java до бита
  (`near … 0.01`, `y = 68.62000000476837`, `my = -0.0784000015258789`), урон от падения, `sendMotionUpdates` (дважды за
  такт, как `runTick`), камера пака `alphamine:view` (FOV 70, −0.1 по взгляду, без покачивания).
- **F2F пака** (`modules/f2f.lua`) + харнесс: `am_client(impl="vc")`/`am_f2f(impl="vc")` (`tools/mcp/alpha_vc.py`, в
  `alpha_tools.py` — три вставки в ветки vc), exe-копия `VoxelCoreF2F-v.exe` (обновляется, когда оригинал новее), свой
  `--dir` `D:\Prog\AlphaMine\run\vc_f2f` (settings, junction на пак, стартовый `alphamine_f2f.lua`), `wait` = цикл
  `step{1,1}` + `wait_check` с темпом 50 мс, поток keepalive в простое. Свой сервер — `tools/alphamine/server_v.py`
  (:25566, `run\server_v` + `run\world_v`, PID в `run\server_v.pid`, чужие java не трогает). Прогон сценариев —
  `tools/alphamine/run_vc_scenario.py` (мир из `setup` сценария — `world_b`; после `render` с перестройкой света —
  `ceil(чанков/4)+10` кадров без тактов).
- **Хэш блоков** `state.hash` (радиус 8 вокруг (104, 68, 104), FNV-1a 64, обход x,z,y): VoxelCore из движка
  `blocks dd51957fc0712864 / meta 294b25d03cd40070` = Java golden, то же из хранилища пака.

**Числа** (прогон `D:\Prog\AlphaMine\runs\20260930_100028_vc_p2\`, мир `world_b`, 854×480)
- Подготовка `alpha_spawn` (все expect прошли, в т.ч. `near 0.01`, `health 20`, yaw 0/90/180/270): вход за 5 тактов (Java 3),
  441 чанк — 312 кадров / 15.6 с (Java 262 / 12.0 с), после двух `/tp` всего 793 MapChunk (791 целых + 2 частичных,
  Java 807–808), вся подготовка 51 с (Java 48–58 с), весь прогон 11 сценариев — 86 с. До исправления такта (пакеты
  через кадр) 441 чанк шли 27 с. Сеть: 3.06 МБ принято, 11.6 КБ отправлено. Распаковка MapChunk 0.12 мс/чанк
  (94 мс на 793), перекодирование в `set_chunk_data` ≈ 0.9 мс/чанк.
- Рантайм `VoxelCore.exe` (разработка, `alphamine_world.lua`, окно 1390×855): вход → 441 чанк за **12.5 с**, во время
  загрузки 44 fps, дальше **124 fps** (лимит 120 в настройках), 793 чанка движка.
- **Слои против golden Java** (`identical` — % всех пикселей кадра, 4 снимка; покрытие golden / VoxelCore):

  | слой | identical, % | покрытие, % | что не так |
  |---|---|---|---|
  | **terrain_flat** | **99.22 / 99.31 / 99.46 / 99.39** | 72.16/72.16, 87.30/87.31, 63.96/63.96, 46.94/46.94 | границы текселей (у альфы U,V до 15.99 тексела), края граней |
  | terrain_lit | 27.83 / 12.68 / 36.03 / 53.05 | как flat | свет движка вместо таблицы альфы и граней 0.5/0.8/0.6 |
  | terrain_fog | 27.83 / 12.68 / 36.03 / 53.05 | как flat | туман альфы не сделан; туман движка на этих кадрах пикселей не меняет (проценты = lit) — разобрать в фазе 3 |
  | water | 89.73 / 93.77 / 88.04 / 76.78 | 9.95/9.72 … 22.71/22.10 | вода полным блоком, без уровней и анимации |
  | sky | 0.00 ×4 | 100/100 | небо движка |
  | clouds | 84.98 / 81.37 / 92.50 / 79.01 | 15.02 / 0 | облаков нет (`clouds-quality 0` в настройках F2F-каталога) |
  | hand | 94.67 ×4 | 5.33 / 0 | руки нет |
  | hud | 91.78 ×4 | 4.35 / 7.17 | HUD движка (хотбар base) |
  | particles | 99.75 / 99.61 / 99.55 / 99.79 | 0.2–0.45 / 0 | копания нет |
  | selection | 99.22 ×4, трещины 93.66 | 0.65/0.65, 6.22/0.65 | рамка движка, трещин нет |
  | alpha_spawn (всё вместе) | 0.00 ×4 | 99.46 / 100 | небо, свет, туман, HUD, рука |

  Сравнение-картинка golden | VoxelCore | diff: `artifacts/screens/alphamine_p2_golden_vc_diff.png`.

**Не сделано в фазе 2** (дальше — фаза 3 по слоям, начиная с terrain_lit): свет и туман альфы (шейдер пака), небо,
облака, вода/лава по уровням и анимации, рендер-типы из `BLOCKS_TODO.md`, сжатие UV на 0.01 тексела, HUD/рука/GUI альфы
(`gui` в F2F не реализован), сущности (`state.world.entities` пуст), ввод движения/прыжки/вода в физике,
ломание/установка; `layer_entities` и `layer_gui` на VoxelCore не гонялись. Мышь в рантайме (обзор реальной мышью через
`input.get_mouse_pos`) запуском не проверена — проверен только F2F-ввод (`dx 600` → yaw 90).

## 6. Фаза 3 — HUD, рука, частицы, GUI (агент U, 30.09)
Правила пользователя: весь UI — нативными XML-документами движка; рука/предмет — `gfx.skeletons` + `hud.hand_controller`
(скелет `hand`) с VCM-моделями; частицы — `gfx.particles.emit`. Изоляция: свой exe `engine\VoxelCoreF2F-u.exe`, F2F :25573,
`--dir engine\userdir_u`, свой сервер :25568 (`run\server_u` + `run\world_u`), всё это — `tools/alphamine/run_u.py`
(`run_u.py layer_hud layer_gui [--prefix quick] [--size WxH] [--keep|--attach]`, `--stop`; останавливает только свои PID).

**Сделано**
- **Ассеты** — `tools/alphamine/gen_ui_assets.py` (≈1 с, из `D:\Prog\AlphaMine\assets` и `tables\`): текстуры с alpha-test Java
  (`GL_GREATER 0.1`: альфа ≤ 25 → 0) `textures/gui/am_{gui,icons,items,terrain,char,particles,menu_bg,vignette}.png`,
  `textures/font/am_default.png`, 3D-иконки блоков (46 шт., рендер-типы 0/10/13) программной растеризацией
  `RenderItem.renderItemIntoGUI` (орто, свет RenderHelper, GL_MODULATE) в атласы `am_icons3d_s{1..4}.png` под масштаб GUI,
  прицел `textures/gui/crosshair.png` (замена движкового), частицы `textures/particles/am_p<тайл>.png` (тайл × 0.6) и
  `am_fx_*.png`, модели руки `models/am_hand/{item,arm,b<id>}.vcm`, таблица `modules/ui_tables.lua` (ширины шрифта, иконки,
  частицы, нормали классов света руки).
- **HUD** (`modules/hud.lua`, `layouts/hud.xml`, `hud.open_permanent` → слой `hud`): хотбар/рамка слота из gui.png, сердца
  (половинки, мигание `heartsLife`, дрожание `JRandom.setSeed(updateCounter*312871)` при health ≤ 4 — `modules/jrandom.lua`),
  броня/воздух, предметы хотбара (3D-иконки блоков, плоские из items/terrain), числа стаков и полоска износа, строка
  «Minecraft Alpha v1.0.16» (F3: «(0 fps, 0 chunk updates)» в F2F, как `Minecraft.f2fReset`), строки чата с фоном и затуханием
  (200 тиков), виньетка (fancy) — чёрная картинка с альфой = яркость × prevVignetteBrightness. Шрифт — `modules/font.lua`:
  каждый глиф — `<image region>` из default.png, ширины — альфа-скан FontRenderer (синий канал `getRGB`), тень +1,+1, цвет /4,
  коды `§`. Хотбар движка (`hud.hotbar`) переносится в скрытый контейнер документа (`moveInto`). Масштаб —
  `ScaledResolution` вручную (854×480 → ×2, 1390×855 → ×3; в 0.31 у GUI нет своего масштаба, 1 единица = 1 пиксель).
- **Прицел**: инверсия (`ONE_MINUS_DST_COLOR`) в XML невозможна (у элементов нет режимов смешивания). Использован прицел
  движка (`Hud::draw`, `BlendMode::inversion` = `ONE_MINUS_DST_COLOR, ONE_MINUS_SRC_ALPHA`) с подменённой текстурой: при
  бинарной альфе и RGB 0 под прозрачным это ровно Java-смешивание; текстура 34×36 с иконкой в (2,4) — центрирование движка
  `(854−34)/2, (480−36)/2` ставит её в (412, 226) = (w/2−7, h/2−7)·2. Под открытым меню движок прицел прячет (Java — нет).
- **GUI** (`modules/gui.lua`, `layouts/ingame_menu.xml`, `hud.show_overlay` → слой `gui`): GuiIngameMenu — «Game menu»,
  «Back to game» (y h/4+24), «Disconnect» (MP; «Save and quit to title» в SP, y h/4+48), «Options...» (y h/4+96), кнопки 200×20
  из gui.png (состояния 1/2, цвет текста E0E0E0 / FFFFA0), фон `drawDefaultBackground` = градиент C0101010→D0101010
  (столбец 1×480; GPU округляет альфу строки как a(y−0.5), переход 12→13 на строке 226 — измерено), «Saving level..»
  первые 20 тиков. Наведение — по позиции курсора кадра, как `drawScreen(mouseX, mouseY)`. F2F `gui {key|click}` — обработчик
  пака (`f2f.lua` → `gui.handle`), шаг `step{1,1}` делает харнесс (`run_u.py`; `alpha_vc.py`/`alpha_tools.py am_f2f` —
  тем же хунком); `state.buttons` как у Java. В рантайме Esc перехватывается `input.add_callback("key:escape")` пака (меню
  альфы вместо паузы движка), клик по документу — `onclick` → кнопка под курсором.
- **Рука** (`modules/hand.lua`, `skeletons/hand.json` = `alphamine:hand` через `config/defaults.toml hand-skeleton`, кости
  `arm`/`item`): матрица = поворот камеры · S(k,k,1) · матрица Java из `ItemRenderer.renderItemInFirstPerson` (+`renderItem`
  для плоского предмета, `renderBlockOnInventory` для блока, `drawFirstPersonHand` для пустой руки: bipedRightArm, точка
  (−5,2,0)/16, rotateZ 0.1), k = tan(0.45)/tan(35°) переводит проекцию руки движка (FOV 0.9 рад) в gluPerspective(70) альфы.
  Экипировка `updateEquippedItem` по тикам, взмах — из `player.swing_progress` (когда появится у P). Свет: грани `shading off`
  (пиксель = тексел × tint), свет альфы (RenderHelper в системе Rx(pitch)·Ry(yaw), ×яркость мира) запекается в canvas-текстуры
  16×16 по классам граней ($f $b $x $u $d; $0..$5), пересчёт при смене вида. Рука рисуется движком только при текущей камере
  `core:first-person`: пак делает её текущей и каждый кадр копирует в неё камеру вида `alphamine:view` (player.lua P) — в
  обёртке `stdcomp.render` (единственный Lua между `CameraControl::update` и `renderFrame`) после компонентов (там
  `alphamine:am_frame` P крутит взгляд). `terrain_flat` с этой камерой — 99.96/99.89/99.88/99.95 %.
- **Частицы** (`modules/particles.lua`): `addBlockHitEffects` → EntityDiggingFX раз в тик при зажатой ЛКМ (луч по
  `getMouseOver`, досягаемость 4, сторона по нормали `block.raycast`); частица моделируется на Lua от тика рождения
  (гравитация 0.04·blockParticleGravity, сопротивление 0.98, трение 0.7) и отдаётся движку `gfx.particles.emit` в позиции
  prevPos (partial 0) со скоростью ×20, остатком жизни, размером 0.2·scale, `random_sub_uv 0.25`, ускорением −16; цвет 0.6 ×
  свет — затемнённые тайлы и `lighting = true`. Пресеты дыма/огня/пузырей/брызг (`particles.spawn`) без вызовов из мира.

**Проценты** (`runs\20260930_111718_vc_u_final1`, мир `world_b`, 854×480, identical % всех пикселей кадра; до фазы 3 — фаза 2):

| слой | снимки | identical, % | было | что осталось |
|---|---|---|---|---|
| **hud** | 4 стороны | **100.00 ×4** | 91.78 ×4 | — |
| **gui** | меню, наведение | **100.00 ×2** | не гонялся | — |
| **hand** | 4 стороны | **100.00** (2 пикс.) / **97.72** / **100.00** (2 пикс.) / **97.72** | 94.67 ×4 | yaw 90/270: одна грань (видимая большая) на +1 уровень: свет GPU 0.7250, модель 0.7298 (9353 пикс.) |
| particles | 4 момента копания | 99.46 / 99.11 / 99.00 / 99.59 | 99.75…99.55 (частиц не было) | покрытие golden/vc 0.25/0.28, 0.39/0.56, 0.45/0.65, 0.21/0.21 % (повтор `final2`: 0.17, 0.41, 0.38, 0.21; identical 99.58/99.21/99.18/99.57); средний цвет [80.6 58.1 40.5]/[75.1 60.9 38.5] … — позиции случайные по построению |
| alpha_spawn (всё) | 4 стороны | 83.40 / 91.28 / 88.55 / 55.18 | 0.00 ×4 | в области HUD 0–3 разных пикселя, рука — как слой; остальное — мир (агент R) |

Частицы между прогонами отличаются (под-UV движок берёт от ГСЧ с сидом = адрес эмиттера); остальные повторяемы: hud 100 % в
3 прогонах, gui 100 % в 2 (после правки градиента), hand — те же числа в 4 прогонах (`runs\*_vc_u_*`).

**Не сделано / открыто**
- Свет руки на yaw 90/270 (и грани ±X 3D-иконок: 0.50447 на GPU против 0.50503 модели — взято измеренное значение): модель
  RenderHelper (нормали байтами Tessellator с его ошибками знака, нормировка) даёт верно yaw 0/180 и полоски, но не эту грань;
  перебор гипотез декодирования нормалей и направлений света не сошёлся.
- Пустая рука и блок в руке проверены только глазом (`u_hand_items`, эталона Java нет); взмах руки при копании — нет
  (`swingItem` у игрока — фаза 4, P); пиксели прицела под открытым меню; F3 строки 2–4; «pop» предметов хотбара
  (animationsToGo); GuiOptions и прочие экраны (инвентарь, чат-ввод, сундук...); ломание блока и трещины — фаза 4.
- F2F `input.keys` в движке: `"3"` — клавиша «3», а не код LWJGL (у Java `"3"` = KEY_2) — сценарии слотов на двух сторонах
  расходятся (видно в `u_hand_items`).

### 6a. Дополнение 01.10 (агент U): инвентарь, взмах и экипировка, покачивание вида, окно 1390×855
Замечания пользователя после ручной сессии (окно 1390×855): (4) нет инвентаря, (5) нет покачивания, (6) рука «уходит за край»,
(7) нет анимаций руки. Движок не менялся; всё — пак (Lua, XML, шейдеры не трогались) и харнесс.

**Сделано**
- **Взмах и экипировка** (`modules/fpview.lua`, `hand.lua`): `EntityPlayer.swingItem` по клику ЛКМ (`Minecraft.clickMouse(0)`,
  Packet18), `updateEntityActionState` 8 тиков, `prevSwingProgress`; цикл кликов `runTick` (нажатие, удержание раз в 5 тиков —
  `mouseTicksRan`, `leftClickCounter` 10 после клика в воздух), хук `fpview.on_click(button, hit)` — его занял `interact.lua` (P).
  Матрицы `renderItemInFirstPerson` во float (таблица `MathHelper.sin`, `sqrt_float`); `updateEquippedItem` во float;
  `ItemRenderer.resetEquippedProgress` — по `interact.equip_reset_tick` (P).
- **Покачивание вида** (`GameSettings.viewBobbing`, по умолчанию вкл.): `distanceWalkedModified` (physics.lua) + prev,
  `cameraYaw`/`cameraPitch` (`EntityPlayer.onLivingUpdate`), `setupViewBobbing` и для камеры, и для руки (`renderHand`:
  Bob·E, свет руки от покачивания не меняется). Камера пака теперь строится `fpview.camera()` (вызов из `player.update_view`):
  R = Ry(180−yaw)·Rx(−pitch)·Bobᵀ, позиция = глаз + 0.1 назад − R·t, **глаз интерполирован prevPos→pos** по partial
  (`orientCamera`; при partial 0 кадр показывает prevPos — на ходьбе камера на тик позади, как у Java). `mode` обнуляет
  состояние (как `F2FAgent.mode`), `mode {options:{viewBobbing:false}}` выключает. Хуки в `game.run_tick`: `pre_tick` →
  `action_tick` → физика P → `post_tick`; `fpview.teleport()` в `handleFlying` (prevPos = pos). Там же `limbYaw/limbSwing`
  и `ticksExisted` локального игрока (для превью в инвентаре).
- **Рука при другом аспекте**: ошибки нет. F2F `--f2f-size 1390x855` / Java `-Size 1390x855` (`u_hand_wide`): 100 % при yaw 0/180,
  пустая рука 100 %. На 1390×855 огниво **и у Java** частично за правым краем: рука стоит в координатах глаза, а при аспекте
  1.626 (против 1.779) правый край ближе. Коррекция K = tan(0.45)/tan(35°) масштабирует только x/y — от аспекта не зависит.
- **GuiInventory** (`modules/inventory_gui.lua`, `layouts/inventory.xml`, `modules/inv_preview.lua`): клавиша инвентаря альфы —
  **I** (`keyBindInventory` = 23; E — дополнительная, у пользователя в options.txt), Esc/I/E закрывают. Фон
  `drawDefaultBackground` + `gui/inventory.png` (`textures/gui/am_inventory.png`), слоты в порядке конструктора (результат,
  крафт 2×2, броня 39..36 с иконками-подложками items.png 15+16·тип, 27 + 9), предметы как в хотбаре (3D-иконки, числа, износ),
  подсветка 0x80FFFFFF, стак у курсора (мышь − 8), «Crafting» 0x404040 без тени поверх всего. **Модель** — слоты в порядке
  `GuiInventory`, стак курсора, сетка 2×2 с результатом `CraftingManager` (93 рецепта `interact_table.lua`) и
  `GuiContainer.mouseClicked` (ЛКМ/ПКМ, выброс вне окна по ошибке Java `y >= top + xSize`; shift-клика в Alpha 1.0.16 нет) —
  `inventory.lua` P (`gui_slots`, `cursor`, `craft_result`, `click_at`, `open_screen/close_screen`, `report_screen`);
  `inventory_gui.lua` только рисует и маршрутизирует ввод (моя первая версия с собственной логикой совпадала с golden так же
  и заменена, чтобы не было двух моделей). Инвентарь клиентский (в протоколе 14 оконных пакетов нет); сетка крафта живёт в
  инвентаре и после закрытия; закрытие с предметом в руке — `dropPlayerItem` (Packet21). F2F: `gui {click, button, key}` →
  `inventory_gui.handle`, `state.screen = "GuiInventory"`.
- **Превью игрока** (`inv_preview.lua`): XML не умеет 3D — модель растеризуется в Lua как это делал бы OpenGL 1.x и
  выкладывается canvas-текстурой 1:1 на пиксели кадра. Матрицы `GuiInventory` + `RenderLiving.doRenderLiving` +
  `ModelRenderer.render` (углы — `entities.biped_angles` P), предмет в руке (`renderSpecials`: блок / isFull3D / плоский с
  полосками `ItemRenderer.renderItem`), свет `enableStandardItemLighting` под зеркальной матрицей, GL_FLAT, альфа-тест,
  depth LEQUAL, центры пикселей. Взгляд модели — мышь **предыдущего** кадра (`xSize_lo` сохраняется после отрисовки), 0,0
  в первом кадре. Геометрия ModelBiped — `gen_ui_assets.py` (порядок вершин `TexturedQuad`, нормали байтами).
- **Нормали Tessellator** (`gen_ui_assets.gl_normal`): декодирование байтов по правилу OpenGL 1.x/2.x **(2b+1)/255** (0 → 1/255,
  −127 → −0.99216) без перенормировки (`GL_RESCALE_NORMAL`). Доказано превью: грани −Z были на 1 уровень светлее при b/127
  (u_inventory 99.2 → 99.9 %); пустая рука 97.88 → 100 %, блок в руке 92.49 → 99.09 %. Противоречие: предмет на pitch −60
  (`u_swing 4_equip1`) даёт 100 % при «0 → 0» и 99.21 % при (2b+1)/255; `AM_NORMAL_RULE=b127|b128|h` — для опытов.
- **Масштаб GUI при 1390×855**: Java растягивает `glOrtho(0, 463, 285, 0)` на кадр → единица GUI = 3.00216 × 3 пикселя, а не 3.
  `UINode::calcPos` движка **обрезает позицию до int** (`glm::ivec2`), размеры float. Поэтому `ui.quad`: элемент ставится на
  пиксели, центры которых покрыл бы GL (`ceil(a−0.5)` … `ceil(b−0.5)−1`), а region текстуры сдвигается/растягивается так,
  чтобы центр каждого пикселя брал тот же тексель, что Java. Фон меню для высоты ≠ 480 — canvas-столбец. 3D-иконки при дробной
  единице и при «прыжке» хотбара растеризуются на лету (`inv_preview.icon_xml`, те же формулы, что атлас; кэш по позиции).
- **Прицел** 64×64 (`textures/gui/crosshair.png`): для 854×480 сгенерирован, для других размеров `hud.lua` перерисовывает
  текстуру через `assets.to_canvas("gui/crosshair")` (при 1390×855 иконка 48 px, а не 32).
- «Прыжок» предметов хотбара (`animationsToGo`, поле `anim` P): масштаб 1/k × (k+1)/2 вокруг (x+8, y+12). Частицы: копание
  теперь рождается в такте P (`particles.block_hit_tick`), разрушение блока — `particles.block_destroy` (4×4×4
  EntityDiggingFX), `Math.random` частиц — общий поток `texfx.random()` (иначе расходится анимация воды).
- **Харнесс**: размер кадра берётся из сценария (поле `"size"`, иначе `setup.client.size` базового, по умолчанию 854×480;
  F2F.md §8) в `run_u.py` и `run_vc_scenario.py`; сессия с разными размерами и сравнение golden/прогона разных размеров
  отклоняются. `run_u.py` переводит цифровые клавиши LWJGL (`"3"` → «2»), как `run_vc_scenario.py` — раньше `u_hand_items`
  выбирал не тот слот.

**Проценты** (identical % всех пикселей; golden Java — `D:\Prog\AlphaMine\golden\<сценарий>\`; прогоны
`runs\20261001_021500_vc_u_final854`, `…_021334_vc_u_wide5`, `…_020517_vc_u_wide4`):

| сценарий (854×480) | снимки | identical, % |
|---|---|---|
| u_swing: взмах (prevSwing 1/8, 2/8, 4/8, 6/8) | 0–3 | 100 / 100 / 100 / 99.94 |
| u_swing: экипировка 0→1 (eq 0.6, 0.2, 0, 0.4), блок в руке | 4–8 | 99.21 / 100 / 100 / 99.99 / 97.87 |
| u_walk_bob: W 5/10/15/20 тиков, terrain_flat + hand (весь кадр) | 0–3 | 99.77 / 99.90 / 99.90 / 99.79 |
| u_walk_bob: S 5/10/15/20, только hand | 4–7 | 100 ×4 |
| u_hand_items: бревно, пустая рука, огниво (golden впервые) | 0–2 | 99.09 / 100 / 100 (было 92.49 / 97.88 / 90.78) |
| u_inventory: открыт, наведение, стак у курсора, ПКМ, крафт, результат, положено | 0–6 | 99.87 / 99.88 / 99.99 / 99.93 / 99.93 / 99.97 / 99.98 |
| регрессия: layer_hud / layer_gui / layer_hand | 4 / 2 / 4 | 100 ×4 / 100 ×2 / 100, 97.72, 100, 97.72 |
| регрессия: layer_terrain_flat / layer_entities / layer_particles | 4 / 4 / 4 | 99.95 99.96 99.88 99.95 / 99.88 100 100 100 / 99.57 99.22 99.14 99.57 |

| сценарий (1390×855, поле `"size"`) | снимки | identical, % |
|---|---|---|
| u_hand_wide: огниво yaw 0/90/180, бревно, пустая рука | 0–4 | 100 / 98.08 / 100 / 99.02 / 100 |
| u_inventory_wide: открыт, наведение, стак у курсора | 0–2 | 99.99 / 99.99 / 100 (до `ui.quad` 99.39–99.47) |
| u_hud_wide: HUD, слот 1, меню | 0–2 | 100 / 100 / 99.99 (до: 99.61, меню — 90 пикселей шва кнопки) |
Остатки: превью инвентаря ±1 уровень на части граней (свет), рука yaw 90/270 (прежняя грань), блок в руке ±1, шов половинок
кнопки меню на x = 693 при 1390 (Java закрашивает пиксель левой половиной, по float-геометрии он правой).

**Не сделано / открыто (01.10)**
- Рамка выделения и трещины (`selection`): рамка движка берётся из его луча (`player.selection` по камере движка — после
  поворота указывает на другой блок) и рисуется без смешивания (альфа 0.4 не применяется); опыт с `shaders/lines.glsl*`
  (подтяжка углов к сетке 1/16 на 0.002, альфа 0.4) дал точную геометрию на yaw 0, но не цвет и не блок — откатан. Трещины
  альфы — умножение `DST_COLOR·SRC_COLOR` (2·s·d, тексели 127/61/155: осветляют и затемняют), альфа-смешиванием блок-обёрток
  не выражается; путь — `main.glslf` (цель и стадия через регион атласа, как свет) — общий шейдер V, не делал.
- Свет руки yaw 90/270 (97.72 %) и противоречие правил нормалей (выше); 3D-иконки ±X — по-прежнему измеренный 0.50447.
- Покачивание в обычном запуске глазом не смотрел (ввод ОС запрещён); в F2F — `u_walk_bob`.

### 6a. Дополнение 01.10 (агент C): чат — GuiChat, привязка движка, падение на Enter
Изоляция: `engine\VoxelCoreF2F-c.exe` (копия VoxelCoreF2F.exe 30.09 09:21), F2F :25576, `engine\userdir_c` (копия userdir_p),
сервер `server_v.py --name c --port 25578`, Java-клиент F2F :25583. Движок не менялся.

**Падение движка на Enter (E2E такт 298) — не чат.** `launch.lua` перед `app.new_world` звал `app.delete_world`, а вне
headless это `guiutil::confirm`: скрытая страница меню `<confirm>` и **глобальный** колбэк Enter, живой весь мир. Первый Enter
подтверждал удаление открытого мира → `fs::remove_all` → `filesystem_error` с текстом Windows в cp1251 («Процесс не может
получить доступ к файлу…», файлы регионов открыты; папка удалилась частично: blocksdata/client/content/data) → F2F-обработчик
кладёт `what()` в JSON → `util::escape` → `utf8 decode error` из `catch` → «uncaught exception». Доказательство: F2F **без T и
без набора**, только `input {keys:{RETURN}}` в мире — тот же лог (`deleting user:worlds/AlphaMine`, `uncaught exception: utf8
decode error`), движок умер. После правки — Enter в мире ничего не удаляет, движок жив (`userdir_c`, 03:21). Мир при этом и раньше
не пересоздавался (диалог не подтверждался): пак теперь открывает `new_world` поверх папки; удалить её паку нечем (`user:` без
`write-to-user` не пишется, `world:` есть только с открытым миром, файлы уже заняты — проверено `file.remove_tree`), старые
чанки пак и так перезаписывает (`on_chunk_present loaded`). Для F2F-патча (правка только для тестов, не делалась): ответ
ошибки надо экранировать байтово (не-UTF-8 `what()` роняет весь процесс).

**GuiChat** (`modules/chat_gui.lua`, `layouts/chat.xml`): T (`keyBindChat` 20, только MP) в такте после пакета движения, как ключевой
цикл `runTick`; `keyTyped`: Esc закрывает, Enter шлёт `message.trim()` (Packet3Chat через `game.send_chat`, если не пусто) и
закрывает, Backspace, символ — если он в строке GuiChat (таблица FontRenderer, «`» → «'», без «§») и длина < 100; `updateCounter`
+1 за такт (такт открытия не считается); `drawScreen`: `drawRect(2, h−14, w−2, h−2, 0x80000000)` + `"> " + msg + "_"` (курсор при
`updateCounter/6 % 2 == 0`) в (4, h−12) цветом E0E0E0 с тенью; фона нет. События ввода разбираются в такте (`chat_gui.tick` из
`game.run_tick`), как `currentScreen.handleInput()`.
- **Ввод текста — нативно, без API кодовых точек** (в 0.31 его у Lua нет): невидимый `<textbox>` документа держит фокус GUI;
  `GUI::act` (в кадре до тактов) кладёт в него символы клавиатуры (раскладка, повтор) и F2F `input.chars`, Backspace и Enter
  (`consumer`). Текст поля всегда равен стражу `##########`: дописанное = набор, стёртое = Backspace. Esc — колбэк пака
  `key:escape` (gui.lua). F2F `gui {chars|char|key}` при открытом чате — `chat_gui.handle`, `gui {key:T}` в мире открывает чат.
- **Документ — `hud.open_permanent`, не оверлей**: под оверлеем движок прячет прицел, а Java рисует его и под GuiChat (E2E 292–296:
  область crosshair 0 отличий). Следствия: курсор остаётся захвачен, F2F относит документ к слою `hud` (у Java — `gui`), клавиши
  игрока глушит `input.lua` (`text_input`), на время чата выключены привязки движка `devtools.console` (`) и `chunks.reload` (F5);
  при потере фокуса окна (обычный запуск) движок каждый кадр открывал бы страницу «pause» — документ тогда переводится в оверлей
  (`gui.focus_lost_check`), чат остаётся, игра идёт (как Java: `displayInGameMenu` ничего не делает при открытом экране).
- **Привязка движка `hud.chat`** (T → страница `core:console` с вкладками Chat/Console/Debug, `stdlib.lua`) — в
  `ENGINE_BINDINGS_OFF` (`game.lua`), как `hud.inventory`.
- Попутно найдено и исправлено: (1) возраст строк чата рос в конце такта, а у Java — первым в `runTick` (`GuiIngame.updateTick`),
  строка из пакета такта N рисуется с возрастом 0 — затухание шло на такт раньше; (2) `GuiIngame.addChatMessage` режет строки шире
  320 — у пака не резались (`game.lua add_chat_line`); (3) цифры движок обрабатывает под любым экраном (`Hud::updateHotbarControl`) —
  «1» в чате переключал слот; под экранами пака слот движка возвращается (`inventory.follow_engine(pid, hold)`); (4) клавиша,
  нажатая в чате и не отпущенная, после закрытия не даёт «нажатия» (`input.swallow_held`: у Java событие ушло экрану), кнопки мыши —
  состояние, их это не касается.
- Харнесс: шаг `chat_age {match, age}` в `run_vc_scenario.py` — шагает так, чтобы строка чата имела ровно этот возраст (эхо сервера
  приходит по настенным часам).

**`u_chat`** (golden Java `D:\Prog\AlphaMine\golden\u_chat\`, прогон `runs\20261001_031418_vc_chat1`; слои hud + gui на чёрном):
открыт / «hel» / «hello» с погасшим курсором (counter 6) / снова виден (12) / Backspace + «`§» (отброшены) + «o» / строка эха при
возрасте 5, 150, 185, 195 (затухание) и 205 (нет) / повторное открытие (история с полной альфой) / Esc — **12 из 12 кадров 100.000 %**.

**E2E `e2e_walk1` на VoxelCore после правки** (`runs\20261001_032207_e2e_vc_chat\e2e_walk1\vs_golden\e2e_report.md`): 600 тактов из 600
(было 298 и падение), 73 кадра, среднее 90.12 %. State: `player`, `inventory`, `blocks`, `screen`, `chat` — равны во всех 157 дампах
(в т.ч. `screen = GuiChat` на 292–296 и эхо «<Player> hello» в дампе 300, как у Java); `entities` ≠ на 155–175 — шум сервера
(у Java/Java тоже). Первое расхождение кадра — такт 1 (рендер мира, как раньше). Такты 281–600:

| такт | 281 | 292 | 294 | 296 | 299 | 300 | 305 | 311 | 320 | 340 | 360 | 361 | 380 | 381 | 400 | 420 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| identical % | 81.23 | 92.15 | 92.17 | 92.15 | 89.87 | 89.26 | 88.44 | 91.41 | 85.36 | 90.85 | 81.22 | 84.52 | 86.63 | 90.01 | 83.41 | 84.04 |

| такт | 440 | 451 | 460 | 480 | 481 | 500 | 520 | 521 | 540 | 560 | 561 | 580 | 600 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| identical % | 94.47 | 98.06 | 95.30 | 98.45 | 96.56 | 95.51 | 93.21 | 78.93 | 79.13 | 79.41 | 90.12 | 87.37 | 89.59 |

J/J (эталон против себя) на всех этих кадрах 100 %. Чат в кадрах: пиксели текста строки ввода (цвет E0E0E0/белый в полосе
y 452–476) совпали 1:1 — 48 («> _», 292), 268 («> hello_», 294/296); строка эха (y 380–402) появляется в одном такте (300) и совпадает,
572 пикселя текста; остальные отличия в этих полосах — мир/рука под полупрозрачным фоном (в 292 было 0.57 % — затемнённая консоль
движка). Остальной остаток 281–600 — известный рендер мира, рука при ходьбе, движковая рамка выделения (агенты R/U).

## 7. Фаза 3 — паритет слоёв мира: terrain, свет, туман, небо, вода (30.09–01.10)
Всё — паком (шейдеры, Lua, ассеты), движок не менялся. Прогоны `tools/alphamine/run_vc_scenario.py` (свой сервер :25566,
`VoxelCoreF2F-v.exe` на :25571), снимки и тепловые карты — `D:\Prog\AlphaMine\runs\<время>_vc_p2\<слой>\`; разбор остатков —
`tools/alphamine/am_residual.py <run>/<слой>` (edge = пиксель VC равен соседнему пикселю golden, other = реальная разница) и
`tools/alphamine/am_crop.py` (golden | VC | тепловая карта, увеличение).

**Таблица (identical %, 4 снимка yaw 0/90/180/270; «до» — прогон фазы 2 `20260930_100028_vc_p2`, «после» — `20261001_001903_vc_p2`,
вода `20261001_002300_vc_p2`, alpha_spawn `20261001_002450_vc_p2`)**

| слой | до | после | что осталось |
|---|---|---|---|
| terrain_flat | 99.22 / 99.31 / 99.46 / 99.39 | **99.95 / 99.96 / 99.88 / 99.95** | 76–89 % остатка — границы текселей/граней, сдвинутые на доли пикселя (edge); прочее — 1-пиксельные щели самой альфы (в golden виден чёрный фон в шве граней), ребром стоящие грани листвы на швах |
| terrain_lit | 27.83 / 12.68 / 36.03 / 53.05 | **99.95 / 99.96 / 99.88 / 99.94** | то же, что flat (свет совпадает везде, включая дно под водой и под деревьями) |
| terrain_fog | 27.83 / 12.68 / 36.03 / 53.05 | **99.95 / 99.96 / 99.87 / 99.94** | то же |
| sky | 0.00 ×4 | **95.84 / 95.84 / 95.88 / 95.84** | max\|Δ\| = 1: округление в градиенте тумана верхней плоскости (модель подтверждена, см. ниже) |
| water | 89.73 / 93.77 / 88.04 / 76.78 | **99.87 / 99.43 / 99.67 / 99.57** | подземная вода: верх под твёрдым блоком движок не строит (альфа рисует), неплоский верх текущей воды — другая диагональ треугольников |
| clouds | 84.98 / 81.37 / 92.50 / 79.01 | без изменений | облака не сделаны (см. «Не сделано») |
| alpha_spawn (всё) | 0.00 ×4 | **87.98 / 91.35 / 93.14 / 74.55** | 4–21 % кадра — облака; 1.3–4.5 % — остальное (±1 неба, рука 97.7 % у агента U, края) |

Прочие слои (hud 100, hand 100/97.72, particles 99.2–99.6, selection 98.8–99.2, трещины 93.66) после моих шейдеров не изменились.

**Что сделано**
1. *Тексели.* `RenderBlocks` кладёт грань на [x0, x0+15.99] текселя (`maxX*16 − 0.01`), движок — на весь тайл. `shaders/main.glslf`
   (`lib/am_world.glsl`, `face_texel`) находит тайл по мировой позиции (ось и знак — производные `dFdx/dFdy`), локальную координату
   — по координате атласа (она в ~20 раз точнее мировой ~100 блоков), тексел = `floor(local·15.99/16)`; у нижней грани копия тайла
   отражена. Излом `fract` на шве блока исправляется по координате атласа. Строки атласа снизу вверх (`png.cpp` читает строки
   обратно). Опробовано и отвергнуто: округление координаты до 1/256 тексела (стало хуже: 99.7 %).
2. *Проекция.* `main.glslv`/`translucent.glslv`: вершина относительно камеры (происхождение чанка − камера + локальная), своя
   матрица GLU (`cot = 1.428147793`, far 256 — как `gluPerspective(70, ar, 0.05, 256)` во float). Константы glm и GLU совпадают
   до 1e-7; остаточные сдвиги границ (у VC луч пикселя на ~0.002 px в стороне, это ниже шага привязки вершин GPU 1/256 px)
   объяснены как субпиксельные.
3. *Свет — точный свет сервера* (выбран вариант (b) после замера (a)). (a) свет движка + восстановление уровня
   `round(v_light·15/d)` + таблица альфы: 80.9 / 84.9 / 95.7 / 80.8 % — суша точная, но вода (непрозрачность 3) и места под
   листвой — свет движка другой. (b) `modules/lightmap.lua`: регион атласа `blocks` (`textures/blocks/am_lightmap.png`
   2688×1346, пишется через `assets.to_canvas("blocks:am_lightmap")` + `canvas:set_data/update`): 21×21 слот чанка (cx mod 21)
   по 64×64 текселя, полубайт на клетку = `max(sky, block)` из MapChunk (World.d = 0), правило полублоков/пашни (max соседей),
   справа те же слоты с кодами жидкостей, строка заголовка (координаты чанка слота) и маркер «AMLM». Шейдер берёт уровень
   клетки-соседа грани (у утопленных граней — своей, у нижней — всегда y−1), множители 1.0/0.5/0.8/0.6 и `(int)(f·h[l]·255)`
   во float Java. Регион — самая высокая текстура атласа: LMPacker сортирует по `h²·1000` и ставит её в (0,0)+2 (граблю с
   переполнением int — см. LESSONS). Без маркера шейдер падает обратно на вариант (a).
4. *Туман* — линейный 64…256 по радиальному расстоянию **на вершине** с интерполяцией (GPU эталона — NVIDIA RTX 3050, есть
   `GL_NV_fog_distance`); цвет = `updateFogColor` при времени 0, partial 0 (float Java, яркость тумана сходится к 0.99999976):
   байты (164, 194, 238), совпадает с golden. Включение — `u_fogFactor > 0` (F2F `fog:false` ставит 0).
5. *Небо* — `shaders/background.glsl{v,f}` (движок рисует этот полноэкранный проход первым): очистка цветом тумана, плоскость
   y=+16 из квадов 64×64 (±384) с туманом 0…204.8 на вершине, интерполированным по треугольникам (0,1,2),(0,2,3), отсечение
   по глубине 256, солнце 32×32 (±30 на 100, аддитивно) и луна (±20 на −100) под углом `glRotatef(282.43°,1,0,0)`, тёмная
   плоскость y=−16. Константы — `shaders/lib/am_sky.glsl` из `tools/alphamine/gen_sky.py` (float Java, таблица синусов
   MathHelper; звёзд нет: яркость 0 при времени 0). Спрайты солнца/луны движка погашены прозрачными `textures/misc/*.png`,
   звёзды движка при дневном времени пака 0.5 имеют NaN-прозрачность и не рисуются. Проверка модели численно
   (numpy-копия шейдера против golden): интерполяция расстояния на вершинах — 91.8 % верхней половины, другая диагональ — 39 %,
   туман на фрагменте — 25 %, по плоскости — 12 %, интерполяция уже зажатого множителя — хуже; квантизация цветов/множителя —
   хуже. Остаток ±1 — точность интерполяции.
6. *Кресты* (`renderCrossedSquares`: саженцы, цветы, грибы, тростник) — модель `models/amblk_cross.vcm` (две диагонали ±0.45F от
   центра, обе стороны, как Tessellator), генерируется `gen_pack_blocks.py`; тексел с тем же сдвигом 15.99 (ширина тайла на 0.9
   блока), свет — своей клетки без множителя. Кластер тростника на yaw 270: 69 → 4 пикселя.
7. *Вода* — `shaders/translucent.glsl{v,f}`, `lib/am_fluid.glsl`: высоты углов `getFluidHeight` из карты кодов (вершинный
   шейдер узнаёт угол грани по `gl_VertexID % 6`: прозрачный проход — списки треугольников по 6 вершин на грань), направление
   течения `getFlowVector`/`atan2` и повёрнутая выборка 2×2 текстуры течения, стороны с v от `(1−h)·16` по треугольникам альфы,
   свет `max(своя, над)` с множителями, туман; «ближайший фрагмент» (глубинный предпроход fancy-воды) — отбрасывание фрагмента,
   если луч к глазу пересекает отрисовываемую альфой грань воды (DDA по карте кодов). Анимация — `modules/texfx.lua`:
   общий поток `Math.random` (`F2FRandom.mix(seed, "Math.random", 0)`, Java Random из `modules/jmath.lua` агента P), порядок
   `RenderEngine.textureList` (лава 256, вода 256, течение 256, течение лавы 256, огонь 2×64 вызовов на такт), float Java,
   сброс при `mode`; картинки — в регион `am_fx` (64×1024, вторая по высоте текстура → атлас (2694, 2), маркер «AMFX»),
   один `canvas:update` за такт. Совпадение с golden подтверждает и генератор, и число такт-в-такт: вода 76.8–93.8 → 99.4–99.9 %.
   Хуки в общем `game.lua`: `texfx.tick()` в такте, `texfx.reset(seed)` в `mode`.

**Стоимость** (прогон alpha_spawn): texfx 1.95 мс на такт (979 тактов — 1.9 с); lightmap 2.5 мс на запись чанка вместе с
загрузкой региона (2011 записей / 393 загрузки, всего 5.1 с за загрузку мира) — кандидат на оптимизацию (загрузка 14 МБ
региона целиком при каждом кадре с изменениями, `glGenerateMipmap` всего атласа).

**Не сделано / дальше**
- *Облака* (4–21 % полного кадра). Облака движка — шумовые воксели на y≈250 по сегментам с отсечением, и в F2F выключены
  (`clouds-quality 0`); фоновый проход пака не видит ворота F2F `clouds` (при `sky:true, clouds:false` облака были бы лишними).
  План: fancy-облака альфы (`renderCloudsFancy`: clouds.png ×12, высота 4 на y = 108.33, смещение `cloudTickCounter·0.03`,
  цвет `getCloudColor` = (239, 239, 240)·0.7/0.8/0.9/1.0 по граням, предпроход глубины, туман на вершинах) — моделью/сущностью
  пака, видимость которой пак переключает сам по команде `render`.
- Лава: текстуры считаются, но `main.glslf` их не применяет; высоты лавы. Огонь (`TextureFlamesFX` — только расход случайных).
- Свет при изменении блоков (BlockChange) не пересчитывается (альфа пересчитывает на клиенте); вода в пещерах под потолком.
- Рендер-типы из `BLOCKS_TODO.md` (факелы, лестницы, двери, рельсы, кактус…) в golden-видах слоёв не встречаются —
  не делались.
- `alpha_spawn` в одной сессии после `layer_selection` падает на expect (тело alpha_spawn не делает `look`, а selection
  оставляет pitch 60) — гонять отдельно.

## 7. Фаза 3 — игрок, обзор мышью, столкновения, сущности, предметы (агент P, 30.09–01.10)
Изоляция: `engine\VoxelCoreF2F-p.exe` (копия, `am_client {exe}`), F2F :25572, `--dir engine\userdir_p`, сервер :25567
(`server_v.py --name p --port 25567` → `run\server_p`, `run\world_p`), Java-клиент A :25574, второй Java-клиент B :25580.
Всё запускается `tools/alphamine/run_vc_scenario.py <сценарии> [--impl java [--golden]] --exe VoxelCoreF2F-p.exe --f2f-port 25572
--dir /mnt/d/Prog/AlphaMine/engine/userdir_p --server-port 25567 --server-name p [--collision engine]` (параметры добавлены
в `run_vc_scenario.py`, `alpha_vc.py` (`exe`), `server_v.py` (`--name`, `--op`); по умолчанию поведение прежнее).

**Сделано**
- **Java-математика** `modules/jmath.lua`: `(float)`-округление, таблица `MathHelper.sin/cos`, `java.util.Random` (48 бит на
  двух 24-битных половинах), `F2FRandom.mix`/`entitySeed` (64 бит на 16-битных «лимбах», без ffi). Сверено с JDK 8
  (`mix`, `nextInt(1000)`, `nextFloat`, `nextDouble`, `sin/cos`) — все значения совпали.
- **Физика** `modules/physics.lua`: `Entity.moveEntity` (Y→X→Z, подъём на 0.5, ySize, fallDistance), коробки блоков по id+meta
  (лестницы, двери, лесенки, кактус, снег), коробки лодок/вагонеток, вода/лава (без толчка течением), яркость
  `World.getBrightness` из света чанков сервера.
- **Игрок** `modules/player.lua` (переписан): `EntityPlayerSP.onUpdate` целиком — `rand.nextInt(1000)` каждый тик (держит
  `Entity.rand` в фазе с Java), `MovementInputFromOptions` (W/S/A/D/пробел; **в Alpha 1.0.16 нет приседания** — ни клавиши,
  ни `sneak` в `GameSettings`/`Entity*`, поэтому не сделано), прыжок 0.42F, `moveEntityWithHeading` (moveFlying, трение
  0.546F / скольжение·0.91F, лёд 0.98, лесенка, вода/лава), урон от падения, `setAngles` во float, выброс (Q) = `Packet21`
  c мотором из `Entity.rand`. Столкновения — выбор `collision`: `lua` (по умолчанию) или `engine` (тело игрока движка:
  хитбокс 0.6×1.8, dynamic, гравитация 1e-6, без затухания, шаг 0.5; F2F-команда `collision {mode}`).
- **Ввод** `modules/input.lua`: клавиши — состояние и фронты на каждом такте (+ выборка в кадре, чтобы быстрое нажатие
  между тактами не терялось); мышь — **нативная `input.get_mouse_delta()` раз в кадр** в хуке `alphamine:am_frame`
  (`on_render` компонента — до отрисовки мира, как `updateCameraAndRender`), только пока нет GUI (захват курсора делает
  сам движок: `Engine::renderFrame` держит курсор захваченным, когда нет активного фрейма — в игре захвачен, в меню/инвентаре
  отпущен); dy экрана вниз → знак как у LWJGL; `input.invert` = invertMouse. Привязки движка, которые действовали бы на его
  игрока/инвентарь (`player.drop` выбрасывал `base:drop` из зеркала инвентаря, `player.build`, движение, `camera.mode`…),
  выключаются `input.set_enabled` в первом кадре.
- **Такты в кадре**: `game.frame` вызывает `game.update()` — `on_world_tick` при шаге 50 мс срабатывает через кадр, и такт
  F2F `step{1,1}` выполнялся кадром позже Java: клавиша слота и Q попадали в один такт, `Entity.rand` сдвигался на один
  `nextInt` и выброшенное бревно летело иначе. После правки пакет 21 совпал с Java побайтно (motion 0, 15, 37).
- **Инвентарь** `modules/inventory.lua`: `InventoryPlayer` (36 слотов, addItemStackToInventory, decrStackSize), слоты 1–9,
  `Packet16` из `syncCurrentPlayItem` каждый такт, зеркало в инвентарь движка (слоты 0–8 → 0–8, 9–35 → 10–36; блоки →
  `alphamine:<блок>.item`, прочее → `alphamine:item_<имя>`, `items/item_*.json` + `textures/items/am_*.png` генерирует
  `tools/alphamine/gen_pack_items.py`; имена `item_` — имена блоков и предметов общие: `alphamine:brick` занят блоком).
  `state.player.{slot, inventory}` как у Java — после подготовки `[259×1, 17×64, 3×64]`, как golden.
- **Сущности** `modules/entities.lua` + `entities/am_{player,item,cart,boat,tag,frame}.json`, `skeletons/am_*.json`,
  модели `models/am_*.vcm` — **генерирует `tools/alphamine/gen_models.py`, исполняя конструкторы `ModelBiped`,
  `ModelMinecart`, `ModelBoat` интерпретатором `minijava.py`** с записывающим `ModelRenderer` (коробки, UV, mirror,
  inflate, точки вращения), квадраты — как `addBox`+`TexturedQuad` (вставки UV 0.0015625/0.003125); блоки-предметы —
  `renderBlockOnInventory` (типы 0/10/13), плоские предметы, шрифт `default.png` глифами (ширины FontRenderer) — одним
  VCM с именованными костями (`am_items.i<id>`, `am_font.c<код>`; в `preload.json` дописаны модели и текстуры). Пакеты
  20/21/22/23/29/30–34/16/18 разбираются полностью (`net.lua`), позиции /32 со сдвигами байтами, интерполяция на 3 такта
  (`setPositionAndRotation(...,3)`) у игроков и вагонеток; другой игрок — `renderYawOffset`, ноги, покачивание рук по
  `ticksExisted`, взмах, предмет в руке (`renderSpecials`), табличка имени шрифтом альфы; предмет — физика
  `EntityItem.onUpdate` на клиенте + поправки сервера, покачивание/вращение по `age`/`hoverStart`, копии стака по
  `Random(187)`. Свет сущностей — `shaders/entity.glsl*` пака: `C·(0.4 + 0.6·max(0,n·L0) + 0.6·max(0,n·L1))`,
  C = `World.getBrightness` (Lua, из света чанков) через цвет скелета, `texelFetch` уровня 0, альфа-тест > 0.1.
  `state.world.entities` — локальный игрок первым, дальше в порядке появления (`EntityItem`, `EntityOtherPlayerMP`, ...).
- **Java F2F**: `mode` обнуляет `ticksExisted` у всех сущностей (`F2FAgent.java`, `ref/patches/*.patch` пересобраны и
  проверены `patch -p1`) — иначе покачивание рук чужого игрока зависело от момента прихода пакета; сторона VoxelCore — так же.
- **Сценарий `layer_entities_player`** (golden `D:\Prog\AlphaMine\golden\layer_entities_player\`): до клиента A подключается
  Java-клиент B (`client_b` в JSON: имя AlphaMineB, оператор своего сервера через `server_v.py --op`), проходит подготовку
  alpha_spawn, встаёт на 104.5 67 108.5 (4 блока перед A), пустой слот, взгляд yaw 180 (поворот мыши применяется в кадре,
  поэтому после него ещё шаг с тактами — иначе Packet12 не уходит) и простаивает. A — как `layer_entities`, но без выброса.
  `am_layers` сценарии с `client_b` без явного списка пропускает (`alpha_tools.py`).
- Служебные сценарии: `p3_drop_probe` (выброс + state), `p3_walk` (эксперимент столкновений).

**Столкновения: движок против Lua** (`p3_walk`, мир `world_b`, одинаковые шаги на трёх клиентах;
`runs\20260930_112834_p3w_java`, `…_p3w_vclua`, `20260930_113049_p3w_vceng`; `state.player.exact` — %.17g):

| момент | Java | VoxelCore `lua` | VoxelCore `engine` |
|---|---|---|---|
| приземление после /tp 104.5 67 104.5, y глаз | 68.62000000476837 | 68.62000000476837 (бит в бит) | 68.62000153064730 (+1.5e-6, центр тела во float32) |
| W 10 тактов к уступу (yaw 90), x | 102.60039980493045 | 102.60039980493045 | 103.51992797851599 (отстаёт на 0.92: такт позже + своё интегрирование) |
| W 60 тактов, упор в стену x=100 | 100.30000001192093 | 100.30000001192093 | 100.28269958496099 (въезжает на 0.017) |
| прыжок у стены, 6-й такт, y | 69.64442409298206, в воздухе | 69.64442409298206 | 68.62000153064730 — не прыгнул (тело упирается в уступ) |
| после прыжка +26 тактов | x 100.3000…, y 68.6200… | те же, бит в бит | x 100.3837, y 68.6200015 |
Во всех 6 точках Lua-вариант совпал с Java **до бита** (x, y, z, motion). Движковый вариант даёт float32-позиции, зазор
`E = 0.03` у стен, задержку на такт и не прыгает у стены — паритет недостижим; пиксели при стоянии не страдают
(`layer_terrain_flat` c `--collision engine` — те же 99.96/99.89/99.88/99.95 %, что и `lua`). **Оставлен `lua` по умолчанию,
`engine` — выбором** (`collision {mode:"engine"}`, `run_vc_scenario.py --collision engine`); стоимость Lua-физики — единицы
коробок на такт, в профиле не видна.

**Обзор мышью** — проверен через F2F (путь кода тот же: `input {mouse}` движка → `Input` → `input.get_mouse_delta` пака):
dx 600 → yaw 90; меню (`gui {key:ESCAPE}`) открыто → dx 600 не поворачивает, `in_game_focus false`; меню закрыто → dx 600,
dy 1000 → yaw 180, pitch −90 (упор). Проба с реальной мышью в обычном запуске прекращена по требованию (ввод ОС запрещён,
пользователь работает за ПК): в обычном запуске тот же `input.get_mouse_delta`, захват курсора — движковый; в журнале
dev-запуска строки `[alphamine] look dx … -> yaw …` (не F2F) — для проверки пользователем.

**Проценты слоя entities** (`runs\20261001_002702_p3_final_vc`, `…_002831_p3_final_vc`; identical % всех пикселей):

| сценарий | yaw 0 | 90 | 180 | 270 | покрытие golden/vc yaw 0 | в допуске |
|---|---|---|---|---|---|---|
| layer_entities (бревно на земле) | **99.88** | 100 | 100 | 100 | 0.24 / 0.24 | tol 1: **100.000** (472 пикс. на ±1) |
| layer_entities_player (игрок B + имя) | **98.33** | 100 | 100 | 100 | 2.18 / 2.18 | tol 3: **99.993** (max Δ 35) |
Java против Java (`runs\20261001_003022_p3_final_java`): layer_entities_player 100 % ×4 — golden повторяем.
Позиция бревна после выброса: Java и VoxelCore — (104.5, 67.125, 107.9375). alpha_spawn целиком в том же прогоне —
87.98 / 91.35 / 93.14 / 74.55 % (мир — агент R).

**Не сделано**: тень `Render.renderShadow` (нужна смесь с альфой по блокам; на чёрном фоне слоя не видна), толчок течением
воды, рельсы у вагонеток (`getPos` — наклон по рельсу) и полная физика лодки, выдавленный 3D-предмет в руке чужого игрока
(сейчас плоский спрайт), первая «сквозь стены» проходка таблички и её фон 25 %, покачивание камеры при ходьбе (view bobbing),
взмах своей руки (`swingItem`) — фаза 4; вагонетки/лодки проверены только разбором пакетов, эталона нет. В обычном запуске
движок ставит паузу при потере фокуса окна — такты альфы стоят, сервер через 60 с рвёт соединение (Java в MP не паузит).

## 8. Фаза 4 — взаимодействие с миром: ломание, установка, подбор, модель инвентаря (агент P, 01.10)
Изоляция как в §7 (агент P): `VoxelCoreF2F-p.exe`, F2F :25572, `engine\userdir_p`, сервер `server_v.py --name p --port 25567`
(`world_b`), Java-клиент эталона на F2F :25574. Прогон: `python3 tools/alphamine/run_vc_scenario.py p4_dig p4_place p4_pickup
--exe VoxelCoreF2F-p.exe --f2f-port 25572 --dir /mnt/d/Prog/AlphaMine/engine/userdir_p --server-port 25567 --server-name p`
(`--impl java --golden --f2f-port 25574` — эталон в `golden\p4_*`); повторное сравнение готового прогона —
`python3 tools/alphamine/am_cmp_run.py <run> p4_dig ...`. Движок не менялся.

**Что сделано** (всё паком; модули `interact.lua`, `relight.lua`, `interact_table.lua`, правки `entities.lua`, `inventory.lua`,
`net.lua`, `f2f.lua`, 6 строк-хуков в `game.lua`)
- **Протокол копания Alpha 1.0.16** (по коду, а не по поздним версиям): `Packet14BlockDig` status **0** = `clickBlock` (нажатие и
  повтор clickMouse каждые 5 тактов удержания), **1** = каждый такт удержания (`sendBlockRemoving`), **2** = `resetBlockRemoving`
  (координаты 0), **3** = `sendBlockRemoved` (клиент сломал; сервер в ответ шлёт только BlockChange — свой урон он считает сам
  по пакетам 0/1 в `ItemInWorldManager`, с проверкой луча 4.0 и стороны; `/gamemode 1` пропатченного сервера ломает на status 0,
  клиент об этом не знает — как и Java). Сервер разрешает копать/ставить только дальше 16 блоков от спавна (−101, −5) или оператору
  (ставить — никому ближе 16).
- **`getMouseOver`** — `World.rayTraceBlocks_do` (DDA 20 шагов, стартовая клетка не проверяется) + `Block.collisionRayTrace` по
  границам блоков (таблица `bounds`, состояния дверей/кнопок/рычагов/рельсов/плит/настенных табличек, свой луч факела), жидкости
  и огонь не цепляются; досягаемость 4.0 (`PlayerControllerMP`); затем игроки/вагонетки/лодки (`expand(0.1).calculateIntercept`
  до min(дист., 3)). В такте (partial 1) — `game.mouse_over`; в кадре (partial кадра) — `game.frame_over`. F2F `state.mouse_over`
  = Java `objectMouseOver` (поле добавлено в `F2FAgent.state` — это инструментирование эталона, не логика игры).
- **`PlayerControllerMP`** целиком: `curBlockDamageMP += Block.blockStrength` (float; `hardness`, `canHarvestBlock` по материалу
  rock/iron/snow и спискам кирок, `getStrVsBlock` инструмента, /5 в воде у глаз и /5 не на земле), звук шага каждый 4-й удар,
  `blockHitDelay` 5, `onBlockClicked`/`blockActivated` (двери, рычаги, кнопки — локально с откатом; верстак/сундук/печь — их GUI
  нет), износ инструмента `onBlockDestroyed` (кирки/лопаты/топоры 1, меч 2), `destroyCurrentEquippedItem`; `setPartialTime` ->
  **`game.dig = {x, y, z, stage, damage}`** для трещин (`stage = (int)(damagePartialTime·10)`, блок — под курсором кадра, как в
  `RenderGlobal.drawBlockBreaking`); рисует их агент U. Цикл кликов, взмах и `leftClickCounter` — `fpview.lua` агента U, он зовёт
  `interact.on_click(button)`; `sendClickBlockToController` — `interact.click_block_tick` сразу после его цикла.
- **Установка**: `Packet15Place(held id, x, y, z, side)` + `ItemBlock.onItemUse` (сдвиг по стороне, снег, `canBlockBePlacedAt`:
  замещаемые жидкость/огонь/снег, правила растений/факелов/лестниц/кнопок/рельсов/кактуса/тростника, коробка без игроков и
  вагонеток), `onBlockPlaced` (meta факела/лестницы/кнопки/рычага), звук, стак −1, `resetEquippedProgress` (`interact.equip_reset_tick`
  для U); `ItemSeeds`/`ItemReed`/`ItemRedstone`/`ItemHoe`; еда (`ItemFood`/`ItemSoup`: локально, пакета нет — здоровье в протоколе 14
  клиентское). Прочие предметы (двери, таблички, вёдра...) — только пакет, сервер отвечает BlockChange.
- **`WorldClient`-откат**: каждое изменение блока клиентом хранит старый блок 80 тактов (`WorldBlockPositionType`) и возвращает
  его, если BlockChange/MultiBlockChange/MapChunk сервера не покрыли клетку (проверено: без пакетов на сервер яма закрылась ровно
  через 80 тактов). Соседи, которым нужна опора (цветы, факел сверху, снег, рельсы...), снимаются локально тоже с откатом.
- **Пересвет клиентом** (`relight.lua`): правило `MetadataChunkBlock.updateLight` (непрозрачность, небо по карте высот, свет
  блоков) рабочим списком по хранилищу чанков, после локальных изменений и после BlockChange сервера; регион света для шейдеров
  (`lightmap.mark`). Без него яма была бы чёрной. Слой `terrain` со светом после ямы совпал с Java до пикселя (тепловая карта —
  только рамка выделения).
- **Подбор** (что было «неадекватно»: клиент по Collect(22) сразу удалял предмет — без полёта и звука; `hoverStart` брался из
  Lua-`math.random`, а не из общего потока `Math.random`): `handleCollect` — звук `random.pop` (0.2, тон из `NetClientHandler.rand`),
  `EntityPickupFX` 3 такта (живёт кадры тактов 1–2, путь `((age+partial)/3)^2` к глазам −0.5 по lastTickPos собирателя,
  яркость мира в точке, 5 чисел из общего потока `Math.random`), сам предмет `setEntityDead`, но до следующего `updateEntities`
  остаётся в списке и рисуется на месте (как Java). Эффект — частица (`EffectRenderer`, слой F2F `particles`): движок не пересылает
  `render` паку, поэтому `run_vc_scenario.py` передаёт состояние слоёв командой пака `layers`. Инвентарь — только `AddToInventory`
  от сервера (подбор решает сервер: `EntityItem.onCollideWithPlayer`, `delayBeforeCanPickup` 10 у выброшенного/выпавшего,
  `expand(1, 0, 1)`), плюс `animationsToGo = 5` у стака (поле `anim`, «подпрыгивание» иконки хотбара — для U).
- **Звуки**: `tools/alphamine/gen_interact.py` копирует `sound/newsound/{step,random}` в `sounds/am/...` (варианты `_0.._N`) и
  дописывает `preload.json`; `interact.play_sound("step.grass", ...)` -> `audio.play_sound("am/step/grass", ...)`; последние 24 —
  в F2F `state.sounds`.
- **Модель инвентаря (экран E)**: в SMP 1.0.16 нет пакетов окон — инвентарь целиком клиентский (сервер знает только предмет в
  руке, Packet16, и выброшенное, Packet21), крафт — на клиенте (`CraftingManager`: 93 рецепта, сняты **запуском** классов эталона
  в `gen_interact.py`, порядок после `RecipeSorter`), shift-клика в этой версии нет. `inventory.lua`: `armor[0..3]` (слоты 36–39),
  `craft[0..3]` (сетка 2×2 остаётся в игроке между открытиями), индексы 0..43 (`get_slot/set_slot/decr_slot` — их использует экран
  U `inventory_gui.lua`), `find_recipe`, `update_craft`, и полная `GuiContainer.mouseClicked` (`click(n, button)`, `click_at`,
  выброс вне окна, `open_screen/close_screen` с выбросом курсора) — для тестов без документа. Клавиша: в F2F Java не читает
  `options.txt` -> код 23 (I); у пользователя `key_Inventory:18` (E).

**Проценты** (identical %, 854×480, `golden\p4_*` с Java, прогон VC `runs\20261001_015114_p4_vc6`; слои: dig — terrain+selection+
entities без света/тумана, 7_lit — со светом; place — terrain+selection+hud; pickup — terrain+entities+hud):

| снимок | % | что в остатке |
|---|---|---|
| dig 0_before | 99.67 | рамка выделения движка вместо альфы (агент U) + края текселей terrain |
| dig 1..4 (стадии 0/3/6/8) | 97.11 ×4 | трещин нет (слой selection — агент U); `state.dig` совпал с Java побайтно |
| dig 5_broken | 99.52 | только рамка: яма, пересвет, звук, пакеты совпали |
| dig 6_drop / 7_lit | 99.50 / 99.47 | + позиция выпавшего предмета (случайный бросок сервера `World.rand`: x 104.125 у VC, 104.875 у Java) |
| place 0/1/2 | 99.61 / 99.13 / 99.13 | только рамка (блок, стак 63, отсутствие отката через 100 тактов совпали) |
| pickup 0_dropped | 100.00 | — |
| pickup 1_fly1 | 98.87 | поворот лежащего предмета (`hoverStart` из потока `Math.random` в такт прихода пакета спавна — зависит от сети), «прыжок» иконки хотбара (U) |
| pickup 2_fly2 | 99.84 | иконка хотбара (U); эффект полёта скрыт, как в Java (слой `particles` выключен) |
| pickup 3_done | 99.84 | иконка хотбара (U) |

`state` на обеих сторонах совпал во всех 15 точках: `mouse_over`, `dig` (урон 0.0555555559694767 → 0.94444465637207, `hit_delay`),
хэши блоков радиусов 2/3 до/после ломания и установки, инвентарь (63 земли, 63→64 бревна), список сущностей (подобранный
предмет виден ровно в такте Collect), такт подбора (12). Стадия 9 трещин травы рукой при partial 0 недостижима ни в Java, ни у
нас (17-й удар 0.944 рисуется только в такте 19, когда блок уже сломан) — снимок на стадии 8.

**Не сделано**: GUI верстака/сундука/печи (`blockActivated` возвращает «занято», как Java, но экранов нет), атака сущностей
только изнашивает инструмент (в протоколе 14 нет пакета атаки), клиентское семя мотыги (`World.l`), `onBlockAdded`/ориентация
лестниц/печей при установке (сервер исправляет BlockChange'ем), частицы разрушения `addBlockDestroyEffects` (хук
`particles.block_destroy` для U), свет факелов при установке считается, но цвет факела — нет (только уровень).

## 9. Производительность: набор замеров, причины просадок, исправления (агент V, 01.10)
Повод: сессия пользователя 01.10 00:51–00:56 (обычный запуск, ~520 блоков ходьбы, 4437 MapChunk) — fps по 5-секундным
окнам мин 6.5 / медиана 32 / макс 120, провалы там, где MapChunk приходили по 25–30 в секунду (много частичных MapChunk
от догенерации мира сервером). Строки `status` той сессии сохранены в `D:\Prog\AlphaMine\runs\20261001_0051_user_session\
status_lines.txt` (сам `latest.log` перезаписан первым же запуском движка этого агента — логи сессий пользователя
копировать до запуска).

### Набор `tools/alphamine/perf/`
| Файл | Что |
|---|---|
| `content/alphamine/modules/perf.lua` | профилировщик пака: секции (исключающее время: вложенные вычитаются), счётчики, кольцевой буфер 65536 кадров, CSV; граница кадра — начало `game.frame` |
| `content/alphamine/modules/autowalk.lua` | сценарий ходьбы пака (без ввода ОС): после 441 чанка стоит 100 тактов, идёт 1200 (W, зигзаг ±30° каждые 10 с, прыжок при упоре/в воде, обход ямы: < 2 блоков за 40 тактов → курс +60°), стоит 300; фаза в CSV (0 загрузка, 1 стоит, 2 идёт, 3 стоит, 4 конец) |
| `perf_normal.py [--tag T] [--switch k=v] [--end disconnect\|lost]` | **обычный запуск рантайма** (MCP `vc_start`, `alphamine_world.lua`, окно из `settings.toml` пользователя 1390×855, лимит 120 fps) — воспроизводит кривую fps пользователя; свой сервер `server_v.py` (world_b); управляющие файлы `export/alphamine_perf.txt` (профилировщик, части CSV каждые 5 с) и `export/alphamine_autowalk.txt` пишет и удаляет сам; ≈ 115 с |
| `perf_walk.py [--tag T] [--switch k=v] [--frames 2]` | F2F-сценарий `perf_walk` (`VoxelCoreF2F-v.exe`, :25571, 854×480, `step {1, F}` в темпе 50 мс стены): тот же autowalk командой `perf {start, reset, autowalk, opts, dump}`; frame_ms тут включает темп харнесса — стоимость = секции пака + проход мира |
| `perf_report.py <run>` / `perflib.py` | `perf_report.md` (топ-3, fps по окнам 1 с и 5 с, таблица секций, стоимость на событие, разбор кадров > 33 мс, GC), `perf_summary.json`, `perf_chart.png` (fps и стек стоимости по секундам; matplotlib из Windows-питона, если в WSL его нет) |
| `perf_compare.py A B [--phase walk\|all] [--md out.md]` | таблицы «до/после» с процентами |
| `test_extrle16.lua` | обычный luajit: новый `extrle16` побайтно равен старому |

Колонки CSV: `frame_ms` (стена между кадрами), `engine_ms` (`time.delta`), `world_ms` (от конца хука `stdcomp.render` до
`on_hud_render` — проход мира движка: заливка мешей, отрисовка), `lua_ms`, `other_ms` = остальное (обновление движка со
светом чанков, UI, swap и ожидание лимитера 120 fps), секции `tick net inflate store physics texfx fx_upload ents_tick
lm_write lm_setdata lm_upload encode setdata frame ents_frame hand particles hud gui dump`, счётчики. Часы — `os.clock()`
(шаг 1 мс: `ffi` пакам недоступен, `stdlib.lua` делает `ffi = nil`; суммы по тысячам кадров несмещённые, p99 секций
квантованы). Переключатели для атрибуции (`--switch`, только замеры): `lm_upload=off`, `fx_upload=off`, `max_per_frame`,
`budget_ms`, `lm_interval`, `preload_mark=on`, `zero_rle=off` (поведение до исправлений).

### Атрибуция (обычный запуск, 1390×855, walk heading 180, прогоны `D:\Prog\AlphaMine\runs\20261001_*_perf_normal_*`)
Кадры > 33 мс «до» (`014948_before`): **проход мира движка 52 %**, загрузка региона света 22 %, логика кадра (перестройка
HUD/GUI) 8 %, прочее движка 8 %, такт (texfx) 5 %, перекодирование чанков 4 %, сеть < 1 %. Стоимость на событие:
`world.set_chunk_data` в Lua 0.17 мс + перекодирование 0.44 мс, но **движку ~8 мс в следующих проходах мира** (свет +
перестройка мешей чанка и соседей: `integrate_chunk_client` помечает 4 соседей, `LightSolver` — все чанки с изменённым
светом); загрузка региона света 12 мс (`set_data` 1.7 + `update` = `glTexSubImage2D` 14 МБ + `glGenerateMipmap` атласа
10.4); texfx 1.8 мс/такт (3.5 % времени постоянно, загрузка 0.24); физика Lua 0.05–0.1 мс/такт (0.1–0.2 %); inflate
0.11 мс/MapChunk; GC ~27 КБ/кадр, без пауз в профиле. Каждый новый чанк писался в движок **трижды** (PreChunk load —
пустой, MapChunk, PreChunk unload — очистка). Физика не причина → нативные столкновения (`--collision engine`) по
производительности не нужны; по паритету они и так хуже (§7).

| прогон (изменение) | fps 5 с мин / p5 / медиана | fps 1 с мин / p5 | загрузка 441, fps | кадров > 33 мс | p99 / max мс | загрузок света |
|---|---|---|---|---|---|---|
| before (как было) | 17.6 / 21.0 / 105.3 | 13 / 19.0 | 20.4 | 350 | 56 / 190 | 379 |
| exp_all0 (п.1 ниже + всё сразу каждый кадр, свет каждый кадр) | 17.4 / 20.1 / 110.7 | 12 / 19.6 | 20.3 | 322 | 53 / 126 | 399 |
| exp_nofx (texfx не грузится) | 17.8 / 20.9 / 104.4 | 12 / 20.0 | 20.7 | 356 | 56 / 142 | 378 |
| exp_nolm (свет не грузится) | 25.2 / 28.3 / 107.7 | 16 / 27.5 | 29.7 | 283 | 45 / 157 | 0 |
| after1 (≤ 2 чанка за кадр, свет раз в 0.25 с) | 19.6 / 22.8 / 110.4 | 10 / 22.0 | 22.4 | 298 | 46 / 149 | 153 |
| exp_b250 (пачка после загрузки света, 0.25 с) | 36.6 / 44.2 / 112.3 | 13 / 37.0 | 48.1 | 233 | 51 / 131 | 157 |
| exp_b500 (то же, 0.5 с) | 38.2 / 50.4 / 109.6 | 17 / 39.6 | 53.3 | 199 | 47 / 176 | 100 |
| after2 (b500 по умолчанию + RLE) | 34.0 / 41.5 / 112.2 | 16 / 39.0 | 46.0 | 179 | 45 / 164 | 102 |
| **after3_1** (+ чат/меню без перестройки) | **42.2 / 65.5 / 114.2** | **40 / 55.6** | **59.9** | **162** | **41 / 138** | 98 |
| **after3_2** (повтор) | **43.4 / 58.7 / 102.4** | 19 / 43.2 | **59.4** | 262 | 50 / 133 | 133 |
Разброс между прогонами одного кода заметный (точка спавна сервера случайна в пределах ±10 блоков → другая местность
пути; на ПК работают другие агенты). Распределение после (after3_1, кадры > 33 мс): проход мира 73 %, прочее движка 9 %,
перекодирование 7 %, свет 7 %, такт 4 %, логика кадра 0.4 %. **Главное оставшееся — движок** (свет + меши на каждый
`set_chunk_data`), пак влияет только числом и группировкой записей.

Сравнение с сессией пользователя: у нас ходьба даёт ~3 MapChunk/с (мир world_b вокруг спавна уже сгенерирован), нагрузка
как у пользователя (25–40/с) — только фаза загрузки 441 чанка; её fps 20 → 60. Ходьбу через догенерируемый мир (частичные
MapChunk) набор пока не воспроизводит — нужен маршрут дальше 160 блоков от спавна (`--walk 3000+`).

**F2F `perf_walk`** (`20261001_021133_perf_walk_before` с `preload_mark=on zero_rle=off` против `20261001_020931_perf_walk_after`;
маршруты разные — случайный спавн, 1007 и 671 MapChunk): Lua пака за прогон −32 %, max кадра Lua 274 → 149 мс, проход мира
−35 %, записей региона света на MapChunk 3.8 → 1.5, загрузок 858 → 378, перекодирование на чанк 0.36 → 0.28 мс.

### Исправления (всё паком)
1. `chunks.pre_chunk`: PreChunk load больше не помечает чанк (пустое хранилище = воздух, чанк движка уже воздух) — минус
   одна запись в движок на чанк (было 3, стало 2: MapChunk + очистка при выгрузке).
2. Обычный запуск: регион света грузится не чаще раза в `chunks.lm_interval` = 0.5 с (`lightmap.flush(stores, interval)`,
   `lightmap.unsent`), чанки движка пишутся **пачкой сразу после загрузки, несущей их свет** (чанк не показывается без
   света), ближние первыми, очистки выгруженных — последними; предел `max_per_frame`/`flush_budget_ms` (1000 / 50 мс).
   Проверено, что «≤ 2 за кадр» хуже: соседи, записанные в разных кадрах, перестраиваются движком повторно (~16 мс на
   чанк против ~8). Запись идёт каждый кадр из `game.frame`, а не только в кадрах с тактами. F2F — всё сразу, как раньше.
3. `chunk_codec.extrle16(raw, zeros)`: известные нулевые диапазоны (y 128..255) считаются сразу (побайтно то же),
   лишняя запись нуля в `encode` убрана: перекодирование 0.44 → 0.35 мс на чанк.
4. Меню: «Saving level..» (мигает каждый кадр 20 тактов) — отдельный контейнер `am_saving` в `layouts/ingame_menu.xml`,
   перестраивается только он (было: всё меню каждый кадр, ~16 мс). Чат HUD: затухание строки меняет цвета элементов на
   месте (`hud.lua part_fade`), без перестройки XML (было ~21 мс на такт весь последний 1 с жизни строки).
5. Шумные логи: `look dx …` и `[alphamine_hand] light …` — только в F2F или при `export:alphamine_debug.txt`.

### Сессия: выход, обрыв, потеря фокуса
- **Disconnect** (`GuiIngameMenu`): Packet255 «Quitting», сокет закрыт, `time.post_runnable(__vc_app.close_world(false))`
  — мир закрывается в главное меню движка, `launch.restore_on_close` возвращает `chunks.load-distance`. В F2F мир остаётся
  (экран `GuiMainMenu`, как раньше).
- **Кик / обрыв / ошибка такта**: `GuiConnectFailed` альфы оверлеем (заголовок «Disconnected by server» / «Connection lost»
  / «Failed to connect to the server», причина как у Java: «End of stream» при закрытии сокета сервером, «Internal
  exception: …»; кнопка «Back to title screen» → выход в меню; Esc ничего не делает, как `keyTyped` Java).
- Проверено запуском без ввода ОС (`perf_normal.py --end disconnect|lost`: кнопки нажимаются обработчиком клика пака
  `gui.handle`): `20261001_020738_perf_normal_end_disconnect` — «leaving the world: Disconnect» → «load-distance restored»;
  `20261001_020825_perf_normal_end_lost` — сервер остановлен → «GuiConnectFailed: Connection lost» → кнопка → мир закрыт.
- **Потеря фокуса**: движок в `Hud::processInput` ставил паузу → `on_world_tick` и покадровый хук стоят → нет тактов и
  пакетов → сервер рвёт соединение через 60 с. Решение паком: `hud.set_allow_pause(false)` в обычном запуске (в F2F не
  трогается). Движок всё равно открывает свою страницу «pause» (без паузы) — `gui.focus_lost_check` заменяет её на
  `GuiIngameMenu` альфы (как `EntityRenderer.updateCameraAndRender`: неактивное окно → `displayInGameMenu`; у Java через
  500 мс, у нас сразу), мир и сеть продолжают идти (альфа-SMP не паузится). Подтверждено во всех прогонах набора: окно
  без фокуса (пользователь работал) → «engine pause page -> GuiIngameMenu», такты и ходьба шли дальше. Ограничение:
  Lua не видит фокус напрямую — признак только страница «pause» движка.

### Паритет после изменений (`runs\20261001_021338_perf_parity`, `…_021611_perf_parity2`, `VoxelCoreF2F-v.exe`, 854×480)
terrain_flat 99.95 / 99.96 / 99.88 / 99.95 и terrain_lit 99.95 / 99.96 / 99.88 / 99.94 — как в §7 бит в бит; hud 100 ×4;
gui 100 ×2 (снимок меню с «Saving level..»); alpha_spawn 87.98 / 91.33 / 93.14–93.16 / 74.55 (в §7: 87.98 / 91.35 /
93.14 / 74.55) — отличие 0.02 в дальней листве в тумане, и между двумя прогонами одного кода оно тоже плавает (93.14 и
93.16): недетерминизм появился вместе с клиентским пересветом `relight.lua` агента P / листопадом сервера, не от записи
чанков (terrain_lit совпадает).

### Дальше (по убыванию выигрыша)
- Свет движка не нужен шейдерам пака (свет — из региона `am_lightmap`), но движок считает его и перестраивает меши соседей
  при каждом изменении света. Если блокам пака дать `light-passing`/`sky-light-passing` всем (свет движка везде 15),
  `LightSolver` перестанет трогать соседей — ожидаемо в разы меньше работы прохода мира. Меняет свет частиц
  (`lighting = true` у пресетов) и запасной вариант шейдера без маркера — решение пользователя.
- Регион света целиком 14 МБ на загрузку: раскладка на 21 регион-строку (по одной строке слотов) дала бы загрузку 0.7 МБ,
  но позиции регионов в атласе определяет `LMPacker` (первый подходящий, сортировка по h²·1000) — шейдеру пришлось бы
  повторять упаковку по `textureSize` атласа.
- texfx 1.8 мс/такт (3.5 % всегда): вычисления во float Java по пикселю; оптимизировать с проверкой `layer_water`.
- Ходьба через догенерируемый сервером мир (частичные MapChunk, как у пользователя) — длинный маршрут в наборе.

### 9.1 Потоковая нагрузка `perf_stream`, отложенные изменения блоков, свет движка (агент V, 01.10 15:00–17:20)
**Загрузка ПК.** Правило пользователя (01.10): замер валиден только на свободном ПК. **Все прогоны этого раздела —
contended** (по решению координатора: шли при чужих процессах — сборки `clang` в WSL, F2F других агентов — или при
активном пользователе; обычный запуск рантайма к тому же реагировал на мышь пользователя и захватывал курсор —
координатор остановил `final_def`, pid 19564). Выводы ниже — предварительные, чистый замер будет сделан лабораторией на
тестовой сборке в реальном времени без ввода. До 17:05 набор загрузку не писал (в 16:55–17:10 в WSL шли чужие сборки `clang`, 2 ядра:
прогоны `after4b`/`after4c` с загрузкой 441 чанка при 23–25 fps вместо 59 — заведомо contended, не использовать).
С 17:05 `perf_normal.py`/`perf_walk.py` перед стартом ждут простоя (`--wait-idle`, по умолчанию 600 с) через
`tools/alphamine/perf/hostload.py` = `tools/lab/labcore/sysload.py` (Windows-питон) и каждые 20 с проверяют загрузку
во время прогона; итог — `host_load` в `perf_summary.json` и строка `host load: clean|CONTENDED (причины)` в отчёте.

**Сценарий `perf_stream.py`** (обычный запуск рантайма через MCP `vc_start`, окно 1390×855 пользователя, `load-distance`
16 как в `alphamine_world.lua`; `--f2f` — `VoxelCoreF2F-v.exe` :25571, 854×480; `--variant lp` — пак с блоками
`--engine-light off` в отдельном `--dir`). Свежая копия `golden/world_b` (сгенерировано x −27..175, z −20..61 чанков,
спавн −101,−5); `autowalk` с `line=1, glide=1`: игрок идёт по прямой x = −100.5 на −Z со скоростью ходьбы 0.2158
блока/такт поверх рельефа (без физики: холмы и вода не останавливают; сервер альфы это принимает —
`NetServerHandler.handleFlying` не проверяет dy и полёт), 3000 тактов = 648 блоков, через ~150 блоков сервер
генерирует и заселяет чанки на ходу: **18–21 MapChunk/с медиана, 33–41 макс по окнам 5 с** (у пользователя 20–50).
Маршрут и скорость одинаковы в каждом прогоне (случайный спавн ±10 сходится к линии за ~30 блоков). Первая попытка
физической ходьбой (`stream_base1`) застряла у холма на z≈−250 (2-блочные уступы), поэтому glide. Отчёт добавляет
(`perflib.stream_stats`): MapChunk/с и fps по окнам 5 с, fps по корзинам нагрузки, задержку MapChunk →
`world.set_chunk_data` (p50/p95, `samples.csv` из `perf.sample`).

**Где время** (F2F, профилировщик движка `perf` тестовой сборки `ec07d0d1`; пак теперь отвечает на `am_perf`, а `perf` —
движок): за 3000 тактов `render_world` 70.9 с из 140 — почти всё `mesh_sync` (**63 206 перестроек меша** на 4 493 записи
чанков, ~1 мс каждая), `light_chunk` 3.8 с (0.86 мс/чанк), `light_block` 47 260 вызовов. Причина: заселение сервером
новых чанков шлёт ~16 BlockChange на MapChunk (47 тыс. за прогон), каждое `block.set` в далёком чанке → пересвет и
перестройка этого чанка (и соседей на границе) в следующем кадре, кадр за кадром.

**Исправления (всё паком, движок не менялся):**
1. **Отложенные дальние изменения блоков** (`chunks.lua`, обычный запуск; **по умолчанию выключено** `bc_defer = 0`,
   включается `--switch bc_defer=2` до чистого замера): BlockChange в чанках на расстоянии ≥ `bc_defer`
   = 2 (Чебышёв, в чанках) от игрока копятся по чанку и применяются через `bc_age` = 1.0 с после первого, не больше
   `bc_max` = 4 чанков за кадр; значение берётся из хранилища в момент применения (всегда новейшее); чанк, ставший
   dirty, пропускается (перезапись несёт изменения). Ближние (свои ломание/установка) — сразу. F2F — без изменений.
   F2F-профиль: `mesh_sync` 63 206 → 47 618 (по 4 за кадр) / 41 023 (все сразу), `render_world` 70.9 → 53.6 / 43.9 с.
2. **HUD при открытом меню** (`game.lua`): `inventory.decrement_animations` вызывался только в игре/GuiInventory —
   при GuiIngameMenu (окно без фокуса!) «подскок» предметов хотбара замирал и `am_items` перестраивался каждый кадр:
   **hud 15–17 мс/кадр** весь прогон (`stream_base2`: fps 6–10). Java (`EntityPlayer.onLivingUpdate`) уменьшает
   счётчик под любым экраном — теперь так же; заодно паритет «подскока» под меню.
3. Мелкое: `perf.lua` — часы `f2f.now_us()` в F2F-сборке (мкс вместо 1 мс), `perf.sample`, секция `bc_flush`, счётчики
   `bc_deferred`/`bc_applied`; бюджет записи чанков считает только записи (без загрузки региона света), переключатель
   `lm_skip`; `perf.opts.f2f_budget` — пакетная запись и в F2F (только для замеров).

**Бюджет записи чанков на кадр (задача 2) — отвергнут замером** (с отложенными изменениями, `bc_age` 1):
| прогон | fps 5 с мин / p5 / медиана | fps 1 с p5 | fps при 20–35/с | кадров > 33 мс | p99 мс | задержка p50 / p95 мс |
|---|---|---|---|---|---|---|
| пачка ≤ 50 мс (как было, `bc2_a1`) | 47.4 / 49.8 / 73.7 | 31.4 | 65.3 | 771 | 68 | 266 / 452 |
| 3 мс/кадр (`bc2_a1_b3`) | 35.4 / 41.7 / 71.6 | 25.4 | 58.8 | 886 | 74 | 351 / **1000** |
| 6 мс/кадр (`bc2_a1_b6`) | 36.2 / 45.9 / 71.9 | 27.0 | 64.5 | 811 | 71 | 313 / 697 |
Как и в §9 («≤ 2 за кадр хуже»): соседи, записанные в разных кадрах, перестраиваются повторно; задержка появления
растёт в 1.5–2 раза. Остаётся пачка после загрузки света (50 мс, `max_per_frame` 1000).

**Все блоки light-passing (задача 3)** — `gen_pack_blocks.py --engine-light off [--blocks-only]` (все блоки
`light-passing` + `sky-light-passing`, без `emission`; генератор с `on` воспроизводит текущие `blocks/*.json` побайтно),
вариант пака `run\alphamine_lp` (`perf/make_variant.py`: подкаталоги — junction на пак, `blocks/` свой), свои `--dir`
`run\vc_rt_lp` / `run\vc_f2f_lp`; общий пак не тронут. F2F-профиль (бюджет 50, без отложенных): `light_chunk`
0.86 → 0.63 мс/чанк, `light_block` 106 → 28 мс, `mesh_sync` 63 206 → 57 090, `render_world` 70.9 → 62.4 с (−12 %).
**Потребители света движка в паке: никто, кроме запасного пути шейдера без маркера региона** (`main.glslv`
`a_alphaLight` до первой загрузки региона; в обычном запуске чанк пишется только после загрузки его света).
Сущности, рука и **частицы** рисуются шейдером пака `entity.glsl*` (движок рисует частицы сразу после сущностей тем же
шейдером): он берёт цвет из `v_color` (оттенок скелета = яркость из `physics.lua`; у частиц оттенок 1) и `v_light` не
читает; `translucent.glslf` без маркера — 1.0. Значит переделывать свет частиц не нужно (комментарий в `particles.lua`
«движок умножает на свой свет» устарел; частицы в темноте сейчас не затемняются ни так, ни так — отдельное расхождение
с Java, не связанное с этим вариантом).
Паритет (`runs\20261001_163313_par_base` и `…_163459_par_lp`, 7 сценариев × 4 кадра): **все проценты совпадают**
(terrain_flat 99.95/99.95/99.88/99.95, terrain_lit 99.95/99.95/99.88/99.94, water 99.87/99.50/99.72/99.57,
particles 99.57/99.21/99.14/99.57, hand 100/97.72/100/97.72, entities 99.88/100/100/100, alpha_spawn
87.98/91.35→91.32/93.15/74.55 — 0.03 в дальней листве, тот же недетерминизм, что 91.33–91.35 в §9).

**Итог, обычный запуск, `perf_stream` (фаза ходьбы; ВСЕ строки contended — предварительно):**
| прогон | fps 5 с мин / p5 / медиана | fps 1 с p5 | fps при 8–20/с | при 20–35/с | > 33 мс | p99 мс | проход мира мс/кадр |
|---|---|---|---|---|---|---|---|
| base3 (как было) | 7.6 / 8.2 / 31.2 | 8.0 | 42.5 | 19.7 | 1245 | 146 | 14.4 |
| base4 (повтор) | 9.4 / 11.2 / 37.8 | 9.0 | 49.5 | 22.4 | 1200 | 128 | 12.1 |
| lp1 (только light-passing) | 10.2 / 11.5 / 44.6 | 9.0 | 57.0 | 31.7 | 1155 | 115 | 10.8 |
| lp_base5 (повтор) | 14.8 / 17.0 / 44.2 | 11.0 | 57.8 | 34.6 | 1205 | 107 | 10.1 |
| bc2_a1 (отложенные, по умолчанию) | 47.4 / 49.8 / 73.7 | 31.4 | 80.4 | 65.3 | 771 | 68 | 6.0 |
| def_2 (повтор умолчания) | 32.8 / 42.0 / 72.3 | 29.4 | 82.7 | 63.4 | 786 | 71 | 5.9 |
| lp_def_2 (отложенные + light-passing) | **54.0 / 57.3 / 79.0** | 39.4 | 86.2 | 71.6 | 653 | 64 | 5.2 |
| lp_bc2_m4 (то же, `bc_age` 0.5) | 53.4 / 54.6 / 76.0 | 34.8 | 78.8 | 66.7 | 668 | 64 | 5.9 |
Задержка MapChunk → запись: p50 250–280 мс (5 тактов), p95 450–465 мс во всех вариантах с пачкой.
Сверка с записями: прежние таблицы §9 — ходьба по сгенерированному миру (~3 MapChunk/с), здесь — догенерация 20–40/с;
это другой режим, не регрессия. Сессия пользователя 10:10–10:27 (`runs\20261001_1010_user_session`, логи сохранены до
первого запуска): fps 37.9 в среднем при 20–35 MapChunk/с, 16.9 при ≥ 35/с — порядок как `base3/4` (19.7–22.4 при
20–35/с; у пользователя в начале была ходьба, не glide, и часть окон без нагрузки).
Пара `final_base` (17:06, загрузку не проверял — до встраивания проверки; 5.4 / 6.1 / 23.4, при 20–35/с 16.7) и
`final_def` (17:10, `host load: clean` по sysload в 17 проверках, но пользователь работал — прогон оборван координатором
на середине: 35.2 / 49.1 / 97.0 по неполной ходьбе) — обе contended, для выводов не годятся.

**Прочее (задача 4):** GC — в кадрах, где закончился цикл LuaJIT, Lua +0.7 мс в среднем (p99 9 против 5 мс, max 25
против 29 мс без цикла), 83–96 КБ/кадр; пауз нет — шаг `collectgarbage` не трогали. `net` 0.19–0.25 мс/кадр (1.0–1.2 %
времени при 4.5 МБ за 150 с, вместе с разбором 48 тыс. BlockChange) — не узкое место. Загрузка региона света: 1.6 +
10.0 мс на загрузку, ~260 загрузок за прогон (2 % времени, пики 12 мс); частичная загрузка API не позволяет:
`canvas:update()` грузит весь регион + перестраивает mipmap атласа (`LuaCanvas::update` → `reloadPartial` с экструзией),
дешевле только разбиение региона на несколько холстов (позиции в атласе определяет `LMPacker`) — не делали.
Выброс 6.7 с в `after4` — стоп движка в «other» при чужой нагрузке, не воспроизводится.

**Рекомендация по умолчанию:** отложенные дальние изменения блоков — включить (`bc_defer` 2, `bc_age` 1.0, `bc_max`
4; по contended-прогонам ×2 медиана и ×5 минимум fps при 20–35 MapChunk/с; F2F-профиль движка −35 % перестроек меша;
паритет F2F не затронут — путь только обычного запуска), **но умолчание оставлено 0 до чистого замера лабораторией**. Бюджет
3 мс/кадр — **не включать**. Light-passing всех блоков — **паритет не изменился ни в одном слое, +10–20 % fps поверх**;
включить можно перегенерацией общего пака `gen_pack_blocks.py --engine-light off` (не сделано, чтобы не менять блоки
под идущими прогонами других агентов) — решение за координатором/пользователем.

### 9.2 Чистый замер лабораторией и новые умолчания (агент perf_clean, 01.10 17:50–19:47)
**Как мерили.** `python3 tools/alphamine/perf/perf_stream.py [--variant lp] [--switch ...] --tag ...` = `lab perf alphamine
perf_normal` (тестовая сборка `VoxelCoreF2F-1c03a0c39b39.exe`, `--f2f-clock realtime`, окно hidden, ввод изолирован,
кадр 1390×855, сервер `world_b` свежей копией, autowalk `line=1 glide=1` x = −100.5 на −Z, 3600 тактов, 20–42 MapChunk/с
по окнам 5 с). Владелец аренд `perf_clean`. Во время каждого прогона — профилировщик движка `lab f2f <rt> perf
{start:true}` сразу после ready и снимок `perf {}` каждые 30 с (последний снимок ≈ 197 с из 214; профилировщик включён
во всех прогонах одинаково). `am_perf` пака через `lab f2f` не ответил — секции пака взяты из CSV профилировщика
пака (`perf.csv`). Таблица — фаза ходьбы; «fps при ≥ 20/с» — среднее fps окон 5 с с ≥ 20 MapChunk/с.
Варианты: (a) как было — `bc_defer=0`, свет движка; (b) `--switch bc_defer=2 bc_age=1.0 bc_max=4`; (c) `--variant lp`
(пак `run\alphamine_lp`, перед замером пересобран `make_variant.py`); (d) оба.

**Чистые прогоны (`host load: clean`, 111–112 снимков, ни одного занятого):**
| вар. | прогон | fps 5 с мин / p5 / медиана | fps при ≥20/с | при 20–35/с | кадров > 33 мс | p99 мс | задержка p50 / p95 мс | проход мира мс/кадр |
|---|---|---|---|---|---|---|---|---|
| a | `stream_clean_base2` | 8.2 / 9.1 / 26.2 | 23.3 | 27.7 | 1615 | 145 | 279 / 460 | 17.1 |
| a | `stream_clean_base3` | 8.4 / 10.0 / 29.2 | 21.3 | 24.5 | 1545 | 143 | 266 / 467 | 16.0 |
| b | `stream_clean_bc2_1` | 35.4 / 40.8 / 67.4 | 55.8 | 57.4 | 1090 | 74 | 275 / 462 | 7.7 |
| b | `stream_clean_bc2_2` | 32.6 / 37.2 / 63.2 | 54.0 | 57.5 | 1113 | 74 | 286 / 465 | 7.9 |
| c | `stream_lp_clean_2` | 10.2 / 13.2 / 38.8 | 26.7 | 30.6 | 1547 | 132 | 286 / 464 | 13.5 |
| c | `stream_lp_clean_3` | 10.0 / 14.4 / 35.4 | 26.1 | 28.0 | 1604 | 126 | 250 / 462 | 13.6 |
| **d** | `stream_lp_clean_bc2_3` | **49.2 / 51.4 / 75.0** | 63.2 | 65.6 | 848 | 68 | 254 / 455 | 6.2 |
| **d** | `stream_lp_clean_bc2_4` | **49.8 / 55.7 / 78.4** | 65.7 | 69.2 | 858 | 69 | 281 / 465 | 6.0 |

**Профилировщик движка (`perf` тестовой сборки, весь прогон после ready, ≈ 197 с стены):**
| вар. | кадров | mesh_sync шт / с | light_chunk (чанков, мс/чанк) | light_block с (вызовов) | render с | render_world с | lua с |
|---|---|---|---|---|---|---|---|
| a2 | 8365 | 81 674 / 113.4 | 5.4 (6354, 0.85) | 0.1 (63 199) | 145.7 | 128.8 | 27.3 |
| a3 | 8783 | 82 353 / 112.0 | 5.1 (6246, 0.82) | 0.1 (63 206) | 141.5 | 126.9 | 26.0 |
| b1 | 13 608 | 58 993 / 81.9 | 5.3 (6398, 0.83) | 0.1 (58 767) | 121.7 | 103.5 | 30.8 |
| b2 | 13 425 | 58 877 / 82.4 | 5.4 (6386, 0.85) | 0.1 (58 408) | 122.6 | 103.9 | 31.5 |
| c2 | 9741 | 73 495 / 104.0 | 4.2 (6385, 0.65) | 0.0 (61 079) | 138.2 | 121.9 | 27.5 |
| c3 | 9850 | 76 145 / 105.0 | 4.1 (6443, 0.64) | 0.0 (63 686) | 140.3 | 122.2 | 27.2 |
| d3 | 15 286 | 51 922 / 70.6 | 4.1 (6495, 0.63) | 0.0 (59 324) | 111.5 | 92.3 | 31.8 |
| d4 | 15 565 | 50 453 / 68.3 | 4.0 (6386, 0.63) | 0.0 (56 429) | 108.6 | 90.2 | 31.0 |
Перестройки меша: −28 % (b), −8 % (c), −38 % (d) при почти вдвое большем числе кадров у (b)/(d); `light_chunk`
0.85 → 0.63 мс/чанк у light-passing (как в F2F-профиле §9.1: 0.86 → 0.63). Узкое место по-прежнему `mesh_sync`
(≈ 1.4 мс на перестройку), Lua пака 26–32 с на 200 с.

**Отброшены (contended, в выводах не участвуют):** `stream_clean_base1` (a, 1 из 110 снимков: msedge 9 % + vmmem 7 % =
19.4 %), `stream_lp_clean_1` (c, 1/111, 16.8 %), `stream_lp_clean_bc2_1` (d, 1/112, 15.4 %), `stream_lp_clean_bc2_2`
(d, 5/111: vmmem до 58 % — сборка `clang++` в WSL чужой сессии), `stream_clean_final1/2` (новые умолчания, 73–79 %
снимков: параллельно шли `lab run det_dig*` агента `agent_3b`), `clean_final3` — отказ после 600 с ожидания (19:17–19:27:
GPU 24–50 %, ввод пользователя 0–111 с назад, аренды и задания `agent_3b`). Их цифры (для порядка: d1/d2 и final1/2 —
те же 61–66 fps при ≥ 20/с) лежат в своих каталогах.

**Сверка с записями §9.1** (все те строки contended, обычный запуск стокового рантайма, окно с фокусом): base3/base4
7.6–9.4 / 8.2–11.2 / 31–38 и lp_def_2 54.0 / 57.3 / 79.0 — тот же порядок, что чистые (a) 8.2–8.4 / 9.1–10.0 / 26–29 и
(d) 49–50 / 51–56 / 75–78. Немного ниже, чем в §9.1: другой хост (тестовая сборка, часы realtime, скрытое окно,
включённый профилировщик движка), маршрут тот же; при 20–35/с base 19.7–22.4 (§9.1) против 24.5–27.7, d 71.6 против
65.6–69.2. Утверждение «(d) ≈ ×2.5–3 к fps при потоковой нагрузке, ×6 к минимуму окна 5 с, −47 % кадров > 33 мс,
p99 145 → 69 мс» опирается только на чистые строки; задержка появления чанка не изменилась (p50 250–290, p95 455–467 мс).

**`perf_compare.py` (a) `clean_base2` против (d) `lp_clean_bc2_4`, фаза ходьбы, обе стороны clean (112 снимков)** —
полностью: `D:\Prog\AlphaMine\lab\runs\20261001_183439_alphamine_perf_normal_stream_lp_clean_bc2_4\compare_vs_clean_base2.md`:
| metric | A | B | change |
|---|---|---|---|
| frames / duration s | 7085 / 179.9 | 14063 / 179.9 | |
| fps 1s windows min / p5 / median | 7.0 / 8.0 / 27.0 | 22.0 / 37.0 / 81.0 | +214 / +363 / +200 % |
| fps 5s windows min / p5 / median | 8.2 / 9.1 / 26.2 | 49.8 / 55.7 / 78.4 | +507 / +512 / +199 % |
| frame ms median / p95 / p99 / max | 8.9 / 102.4 / 144.9 / 248.6 | 8.7 / 39.5 / 68.8 / 149.9 | −2 / −62 / −53 / −40 % |
| frames > 33 ms | 1615 | 858 | −46.9 % |
| pack Lua ms/frame p95 / p99 | 16.02 / 35.03 | 6.74 / 22.34 | −58 / −36 % |
| pack + world pass ms p99 | 139.60 | 64.54 | −53.8 % |
| world_ms total (ms/frame) | 121 148 (17.10) | 84 199 (5.99) | −30.5 % |
| bc_deferred / bc_applied | 0 / 0 | 58 914 / 55 311 | |
Сравнение `clean_base2` против `clean_final1` скрипт отклоняет (`REFUSED: ... B CONTENDED`) — так и должно быть.

**Паритет (после применения умолчаний, общий пак, `lab run ... --impl vc --golden`):**
| сценарий | сейчас (по кадрам) | история | вывод |
|---|---|---|---|
| layer_terrain_flat (`20261001_184849_..._layer_terrain_flat_3_vc`) | 99.951 / 99.951 / 99.884 / 99.945 | 17:45 — то же, **sha всех 4 кадров совпали** | без изменений |
| alpha_spawn (`20261001_184955_..._alpha_spawn_vc`) | 87.977 / 91.325 / 93.151 / 74.548 (mean 86.750) | 15:57–16:34: mean 86.750–86.751 | без изменений: кадры 0/3 совпали побайтно, 2_yaw180 — те же 14 px (y 246–252), что различают и прогоны 15:57 и 15:59 между собой (известный недетерминизм §9) |
| layer_entities (`20261001_185204_..._layer_entities_vc`) | 99.885 / 100 / 100 / 100 | 30.09–01.10 — то же, **sha совпали** | без изменений |
| layer_particles (`..._185113_`, `..._185513_`) | 99.569 / 99.213 / 99.142 / 99.568 и 99.569 / 99.113 / 98.822 / 99.06 | 02:15 — 99.142 min, mean 99.374 | без изменений: сценарий недетерминирован от прогона к прогону (две прогонки «off» расходятся на 577–3060 px); контрольный прогон со старыми блоками (`..._185430_`, свет движка вкл.) — 99.569 / 99.111 / 98.822 / 99.06, т.е. в пределах того же разброса |
Первая попытка (`lab run alphamine layer_terrain_flat alpha_spawn ...` одним прогоном) упала на `alpha_spawn: expect yaw
270 != 0` — сценарии в одном прогоне делят сеанс и `alpha_spawn` ждёт yaw 0 после поворотов `layer_terrain_flat`;
это свойство цепочки, не паритета; по одному — зелёные.

**Применено (умолчания с 01.10 18:53):**
1. `content/alphamine/modules/chunks.lua`: `M.bc_defer = 2` (`bc_age` 1.0, `bc_max` 4 — как были). Назад: `M.bc_defer = 0`
   или для замера `--switch bc_defer=0`. Путь только обычного запуска (`M.batching`), F2F не затронут.
2. `content/alphamine/blocks/*.json` перегенерированы `gen_pack_blocks.py --blocks-only --engine-light off` (все блоки
   `light-passing` + `sky-light-passing`, без `emission`; маркер `blocks/.engine_light_off`); результат побайтно равен
   `run\alphamine_lp\blocks`. У генератора умолчание теперь `--engine-light off` (иначе полная перегенерация пака молча
   вернула бы свет движка). **Назад:** `python3 tools/alphamine/gen_pack_blocks.py --blocks-only --engine-light on` —
   проверено, что воспроизводит прежние `blocks/*.json` побайтно (и удалить `blocks/.engine_light_off`, генератор с
   `on` его не создаёт, а `rmtree` каталога его убирает).
3. Прогоны с умолчаниями без ключей (`stream_clean_final1/2`, contended) подтверждают, что включено: `switches: none`,
   `bc_deferred` 59 514 / 61 799. Вариант `--variant lp` теперь совпадает с общим паком; (a) с новыми блоками
   воспроизвести можно только через `--engine-light on` в отдельном варианте пака.

**Простой ПК (лента ожидания):** 17:50 — 55 с до 30 с простоя; 17:55–18:43 — каждый прогон стартовал через 30–76 с
(18:10 — 18 с «busy»: msedge 9 % + vmmem 7 %); одиночные всплески msedge/vmmem в ходе прогонов дали 4 contended
(1–5 снимков из 111); 18:56–19:00 — 4 мин ожидания (аренды и задания `agent_3b`, GPU 21–50 %), затем final1/2 —
contended теми же заданиями; 19:17–19:27 — отказ (пользователь за ПК, GPU 24–50 %, `agent_3b`); 19:36–19:46 — третья, последняя
попытка — отказ (ввод пользователя, GPU 18–47 %, `cl.exe`/`link.exe` — сборка MSVC до 90 % CPU, аренды `agent_3b`).
Чистого прогона с умолчаниями без ключей нет; конфигурация (d) та же (блоки побайтно = `run\alphamine_lp\blocks`,
`bc_defer` 2 = ключ прогонов d3/d4), поэтому итог — строки d3/d4.
История: все прогоны в `artifacts\lab\history.sqlite` (`lab history alphamine --kind perf`), панель
`artifacts\lab\dashboard\alphamine.html` (спарклайн fps семейства `stream`), `artifacts\lab\SUMMARY.md`.

## 10. Мир разработчика `devworld` и слои на нём (агент D, 01.10)
Изоляция: `engine\VoxelCoreF2F-d.exe` (копия `VoxelCoreF2F.exe`), F2F :25574, `--dir engine\userdir_d`, сервер `server_v.py --name d
--port 25569 --world devworld` (`run\server_d`, `run\world_d`), Java-клиент F2F :25581. Движок не менялся.

**Мир** — `D:\Prog\AlphaMine\golden\devworld` (отслеживается git; 729 чанков, 731 файл, 346 КБ), генератор
`tools/alphamine/gen_devworld.py` (только stdlib): пишет формат сохранения альфы напрямую — `level.dat` (gzip NBT `Data{RandomSeed,
SpawnX/Y/Z, Time, SizeOnDisk, SnowCovered, LastPlayed}`) и `<b36(x&63)>/<b36(z&63)>/c.<b36 x>.<b36 z>.dat` (`Level{xPos, zPos, LastUpdate,
Blocks, Data, SkyLight, BlockLight, HeightMap, TerrainPopulated, Entities, TileEntities}`), плюс `devworld_layout.json` (все клетки
экспонатов с id/meta, группы, видовые точки; сервер его не читает). Действия: `gen` → `scenarios` (пишет `tools/scenarios/alpha/
{dev_base,dev_settle,layer_*_dev,dev_full}.json`) → `dev_settle` на Java → `finalize` (копия сохранённого сервером мира обратно, Time
сброшен) → `checklight`; ещё `diff A B` (блоки/meta/свет/TE двух сохранений), `dump x y z`.
- Плоский мир: бедрок y=0, камень 1..63, трава y=64; площадка экспонатов — камень y=64 на x 12..68, z 12..58; экспонаты стоят на y=65
  через клетку. Группы: **G1** кубы (x 16.., ряды z 18/20/22/24/26: все id rt 0 по одному, печи idle/active meta 2..5, сундук и двойной
  сундук, бревно+листва, дерево, плита на плите, стекло рядом, снег-слой), **G2** формы (z 40 факелы: пилон с 4 настенными + стоячий,
  то же красными, «НЕ»-вентиль 76→блок→75; лестницы 2..5 на пилоне; z 43 ступени дерево/камень 0..3, рычаги на пилоне; z 46 двери
  дерево 0..7 и железо 0..3 (две половины); z 49 рельсы 0..9, рычаги на полу 5/6/13/14; z 52 кнопки 1..4, нажимные плиты, таблички
  стоячие 0/4/8/12 и настенные 2..5 с TileEntity Sign, провод: точка, линия 15..9, крест), **G3** жидкости (x 44..: бассейны 3×3 вода/лава,
  канал воды уровни 0..7 (z 23), канал лавы 0/2/4/6, водяная лестница в жёлобе z 27, лёд у воды), **G4** растения (z 40: посевы 0..7 на
  мокрой пашне (вода x 48), 0 и 7 на сухой; z 44: саженец/цветы на траве, грибы на камне, кактус ×3 на песке; тростник ×3 у воды
  (64,65..67,48)). Башни (камень y 65..70, стоять на y=71): x 27/55 × z 11/33/59. Яма для предметов (27,64,8). Спавн (0,64,0).
- **Видовые точки** (`/tp` на башню, взгляд, pitch 45): `g1_n` (27.5 71 11.5, yaw 0), `g1_s` (27.5 71 33.5, 180), `g2_n` (27.5 71 33.5, 0),
  `g2_s` (27.5 71 59.5, 180), `g3_n` (55.5 71 11.5, 0), `g3_s` (55.5 71 33.5, 180), `g4_n` (55.5 71 33.5, 0), `g4_s` (55.5 71 59.5, 180).
- **Свет** считает генератор: HeightMap и неподвижная точка `MetadataChunkBlock.updateLight` (`L = max(источник, max соседей − max(1,
  непрозрачность))`, небо 15 при y ≥ HeightMap). Сервер при загрузке **не пересчитывает** свет (`ChunkLoader`: только отсутствующий
  SkyLight → `generateHeightMap`, отсутствующий BlockLight остаётся 0). Проверка: после оседания жидкостей сервер сам пересветил
  изменённые места, `checklight` пересчитал всё заново — 0 расхождений из 555 тыс. клеток (и до, и после сервера).
- **Стабильность** (случайные такты сервера в ±9 чанках от игрока): Time = 13100 — на сервере ночь (`skylightSubtracted` ≥ 7 до ~22850, ≈ 8 мин
  сервера): посевы/саженцы не растут, грибы (свет ≤ 13) не осыпаются; клиент SMP время не получает. SnowCovered = 0. Экспонаты на камне
  (трава не соседствует с землёй), кактус/тростник по 3 (не растут), листва с осевшей meta (`settle_leaves`), 75 погашен 76 под блоком,
  спавнер `EntityId "None"`, огня и светящейся руды (74 → 73) нет, чанки −12..14 сохранены и `TerrainPopulated` (случайная точка спавна
  ±10 блоков → сервер шлёт до чанка −11; на −10..14 сервер сгенерировал и заселил крайние чанки). Жидкости пишутся источниками,
  сервер растекает их сам (`dev_settle`: 150 с на башне G3 + 30 с тишины + `/stop`), `finalize` возвращает мир. Повторная сессия по
  готовому миру: `diff` = **none** (ни блока, ни meta, ни света за 3 мин случайных тактов). Сессия сценариев должна укладываться в ~8 мин.
- **Находки по Java-клиенту**: (1) клиент сам создаёт отсутствующие TileEntity при первой сборке чанка (`Chunk.getChunkBlockTileEntity` →
  `onBlockAdded`): `BlockFurnace.onBlockAdded` → `setDefaultDirection` **переписывает meta печи на клиенте** по непрозрачным соседям (у
  одиночной печи всегда 3) — в golden все печи смотрят на +Z, meta сервера не видна; (2) клиентский `TileEntityMobSpawner` (моб «Pig» по
  умолчанию) спавнит **свиней на клиенте** на траве в ±4 от спавнера — в первом golden свиньи бродили по кадру (трава убрана от
  спавнера); (3) таблички рисует `TileEntitySignRenderer` в проходе сущностей — в слоях terrain их нет вовсе (у VC — заглушка в terrain).
- `/give` есть (оператор → консольная `give`), предмет вылетает по взгляду: перед `/give` смотреть вниз (pitch 90) в яме 1×1, ждать
  реальное время (`wait {chat:"^never$", max_frames:N}, optional`), а не `net_idle` (он уже выполнен). Поворот `look` применяется в кадре
  после тактов шага: перед нажатием Q нужен ещё шаг, иначе бросок идёт по старому взгляду.

**Атрибуция по экспонатам** — `tools/alphamine/am_rows.py <run> [сценарии] [--labels]`: каждый пиксель снимка видовой точки
размечается лучом через сохранённый мир (камера альфы: `glTranslatef(0,0,−0.1)`, pitch, yaw+180, gluPerspective 70, DDA по клеткам;
terrain-слои пропускают воду/лёд, water — только они), различия — по экспонату (`edge`/`other` как в `am_residual.py`), сводка по всем
снимкам; `rows.json`, `<shot>_labels.png`. Таблицы прогона ниже — `runs\20261001_032620_dev_vc_final\rows_{flat,lit,water,full}.txt`.

**Таблица** (identical %, 854×480; golden — Java `golden\<сценарий>\`; «до» — пак до моделей `runs\20261001_031027_dev_vc_base`,
«после» — `runs\20261001_032620_dev_vc_final`; повтор `…_032220_dev_vc_m2` совпал до 0.01):

| слой | g1_n | g1_s | g2_n | g2_s | g3_n | g3_s | g4_n | g4_s |
|---|---|---|---|---|---|---|---|---|
| terrain_flat до | 98.18 | 99.04 | 90.94 | 91.61 | 96.29 | 99.05 | 97.06 | 97.77 |
| **terrain_flat** | **99.55** | **99.04** | **99.28** | **98.43** | **97.76** | **99.05** | **99.53** | **99.55** |
| terrain_lit до | 98.11 | 99.04 | 90.83 | 91.55 | 96.25 | 99.05 | 96.81 | 97.60 |
| **terrain_lit** | **99.19** | **99.04** | **98.47** | **97.89** | **97.38** | **99.05** | **98.03** | **98.84** |
| water | 99.80 | 99.69 | 100 | 99.86 | 99.97 | 99.91 | 99.94 | 99.95 |
| dev_full до | 98.10 | 98.62 | 90.69 | 91.21 | 96.25 | 99.05 | 96.74 | 97.69 |
| **dev_full** | **99.14** | **98.62** | **98.32** | **97.55** | **97.37** | **99.04** | **97.96** | **98.93** |
entities (`layer_entities_dev`: 4 `/give` + 5 бросков Q веером): `items_near` (только сущности) 99.81, `items_terrain` 99.29 (до: 99.90 / 99.12
на дальней точке). dev_full с pitch 45 почти без неба — облака не попадают в кадр.

**Что сделано в блоках** (`tools/alphamine/gen_pack_blocks.py`, только модели/варианты, шейдеры не трогал): геометрия `RenderBlocks` как
VCM на каждое состояние — факелы (`renderTorchAtAngle`, meta 1..5, вкл. красные), лестницы (плоскость 0.05 у стены, 2..5), рельсы
(`renderBlockMinecartTrack`: углы по meta, уклоны 2..5, обе стороны), ступени (две коробки по meta), двери (коробка 3/16 по
`BlockDoor.getState`, зеркальные тайлы как `flipTexture` — перестановкой u, верхняя половина — тайл 81/82), рычаги (основание-булыжник +
ручка через `Vec3D.rotateAroundX/Y` с таблицей `MathHelper`), кнопки (коробки по meta, нажатые тоньше), кактус (боковины внутрь на 1/16,
верх/низ полные), посевы (4 плоскости `#` на y−1/16). Вершины в порядке Tessellator (нормаль наружу), UV в текселях тайла.
Две ловушки рантайма 0.31 (`454aa205`, = релиз пользователя), обойдены паком: (а) `ModelsGenerator::prepare` разрешает `"$i"` только у
варианта по умолчанию → в моделях вариантов имена текстур атласа вписаны прямо (`texture "blocks:am_door_wood"`), модели на блок и meta
(`amblk_<блок>_m<meta>.vcm`, одинаковые склеены, 105 файлов); (б) `ContentGfxCache::refresh` идёт до `variants.size() − 1` и **никогда не
готовит вариант 15** (вектор фиксированный на 16; 17-й вариант — «stack vector capacity exceeded»): у state-based блока meta 15 нет UV
(по коду рантайма — провод с мощностью 15 без UV, так было и до моделей; в devworld это одна клетка линии провода), а кастомная модель кидала «model not found» каждый кадр → вариант 15 =
`model none`, у кактуса вариантов нет совсем (meta — счётчик роста до 15).

**Блоки, которые неверны в порте** (по `rows_*.txt`, identical % экспоната по всем снимкам, flat / lit):
- лава (бассейн 64.9 / 64.9, канал 77.3): текстуры `TextureLavaFX` и высоты лавы не применены в `main.glslf` — шейдеры (агент R);
- посевы 97–99.6 / 60–98, лестницы 99.9 / 80–91, факелы 98.7–99.8 / 96.5–98.7: геометрия точна, в lit пак умножает вертикальные
  осевые плоскости на 0.6/0.8 и берёт свет клетки; альфа рисует их без множителя граней, а блоки со светом > 0 (факелы) — яркостью 1.0 — шейдер;
- таблички 68–89: в альфе это TileEntity в проходе сущностей, у порта — заглушка в terrain; нужен рендер таблички сущностью пака;
- печи 81–92: на Java meta печи переписана клиентом (`setDefaultDirection`, см. выше), порт показывает meta сервера — нужна та же
  подмена в паке при записи чанка (Lua, не генерация блоков);
- плита на плите 82.3, одиночная плита 88.6: грани между плитами/верх плиты (`BlockStep.shouldSideBeRendered`) — не разбиралось;
- провод 94–98: тайл по соединениям и цвет по мощности не сделаны (заглушка-aabb), meta 15 — мусор (вариант 15);
- двойной сундук 93.7: текстуры сундука по соседу (`BlockChest.getBlockTexture`) не сделаны; спавнер 91: клетка-сетка двусторонняя
  (вид сквозь) и TileEntity-моб;
- нажимные плиты 92–94, снег-слой 97.2: коробки движка (`aabb`) — грани/UV расходятся по краям, не разбиралось;
- дверь m7 верх (meta 15) 88: не рисуется (вариант 15);
- вода: лёд на воде 91.1, бассейн 93.8, вода у пашни 79.5 (вода — шейдеры агента R); стекло 99.2–99.9, листва/дерево 99.9+, все кубы rt 0 99.5–100.

**Запуск**
```
python3 tools/alphamine/gen_devworld.py gen && python3 tools/alphamine/gen_devworld.py scenarios
R="python3 tools/alphamine/run_vc_scenario.py --server-port 25569 --server-name d"
$R dev_settle --impl java --f2f-port 25581 && python3 tools/alphamine/gen_devworld.py finalize && python3 tools/alphamine/gen_devworld.py checklight
$R layer_terrain_flat_dev layer_terrain_lit_dev layer_water_dev dev_full layer_entities_dev --impl java --golden --f2f-port 25581
$R layer_terrain_flat_dev layer_terrain_lit_dev layer_water_dev dev_full layer_entities_dev --exe VoxelCoreF2F-d.exe --f2f-port 25574 \
   --dir /mnt/d/Prog/AlphaMine/engine/userdir_d
python3 tools/alphamine/am_rows.py /mnt/d/Prog/AlphaMine/runs/<run> layer_terrain_flat_dev --labels
```
Golden-сессия Java ≈ 150 с, VoxelCore ≈ 200 с.

## 11. E2E — финальный сквозной тест серией (агент E, 01.10)
Формат, правила и метрика — `agents/F2F.md` §8.1. Код: `tools/alphamine/e2e/e2e_run.py`, `e2e_compare.py`, MCP `am_e2e`;
сценарии `tools/scenarios/alpha/e2e_walk1.json` (world_b), `e2e_dev1.json` (devworld, ещё не записан).
Изоляция: `engine\VoxelCoreF2F-e.exe` (копия VoxelCoreF2F.exe от 30.09 09:21) F2F :25575, `engine\userdir_e` (копия userdir_p
без junction — `prepare_dir` создаёт свой), Java-клиент F2F :25582, сервер `server_v.py --name e --port 25570`
(`run\server_e`, `run\world_e`).
```
python3 tools/alphamine/e2e/e2e_run.py e2e_walk1 --impl java --golden          # эталон -> golden\e2e_walk1\
python3 tools/alphamine/e2e/e2e_run.py e2e_walk1 --impl java --tag e2e_java3 --compare   # шум эталона -> reference_noise.json
python3 tools/alphamine/e2e/e2e_run.py e2e_walk1 --impl vc --compare           # VoxelCore + отчёт vs_golden\e2e_report.md
```
**`e2e_walk1`** (600 тактов, темп 50 мс/такт, 73 ключевых кадра: каждые 20 + после действий; state каждые 5, радиус 8):
стоит 20 → W 100 (поворот +45° на 50, обратно на 85, прыжки на 60 и 100) → взгляд вниз 48° → ЛКМ 19 тактов (трава 99,67,122
сломана на такте 154) → W в яму (подбор земли, слот 3) → прыжок вперёд → разворот 180 → слот 2 → ПКМ (земля в яму, стак 63)
→ I (инвентарь, наведение на 5 слотов) → `gui {key:I}` → T, «hello», Enter → W 140 обратно (поворот, прыжок, упор в блок)
→ осмотр по 90°. Прогон ≈ 90 с (сервер 4 с, клиент 3–10 с, подготовка alpha_spawn 45 с, таймлайн 33 с).

**Java против Java** (обязательный шаг перед VoxelCore; `runs\20261001_024048_e2e_java1`, `…_024218_e2e_java2`,
`…_024935_e2e_java3`): после исправления виньетки (ниже) java2 и java3 — **70 из 73 кадров 100 %**, `player`, `blocks`,
`inventory`, `screen`, `chat` равны во всех 157 дампах; отличаются только кадры 158/160/161 (99.63/99.37/99.43 %) и `entities`
на тактах 155–175 — позиция выпавшего предмета (`World.rand` сервера). java1 подобрал предмет на такт сервера раньше
(инвентарь на такте 170 уже 4 стака) — после этого поток `Math.random` сдвинут на 5 чисел (`EntityPickupFX`), и вода
(TextureFX) отличается на кадрах 206–320 (до 98.1 %). Golden = java2 (типичный исход, 2 из 3; `run.json.promoted_from`),
`reference_noise.json` = golden против java3.
Исправлено для детерминизма (обе стороны): `mode` ставит `GuiIngame.prevVignetteBrightness` в неподвижную точку
`clamp(1 − thePlayer.getBrightness(1))` — Java `F2FAgent.java` (пересобран `ref\compile_client.ps1`, секция F2FAgent в
`ref\patches\f2f-client.patch` и `f2f-only.patch` обновлена; `patch -p1` к `src_original` даёт ровно `src`), пак —
`hud.vignette_reset()` из `game.mode`. До этого виньетка зависела от числа кадров сетевых ожиданий до `mode` и Java/Java
расходились на ±1 по всему кадру с такта 51. На прежние golden слоёв это влияет только на округление (после долгих ожиданий
значение и так было в неподвижной точке ±3e-4).

**VoxelCore против golden** (`runs\20261001_025402_e2e_vc\e2e_walk1\vs_golden\e2e_report.md`, `drift.png`):
| такт | 1–21 | 40–61 | 80–101 | 120–121 | 131–154 (копание) | 155–175 (предмет, подбор) | 180–231 (установка) | 242–280 (инвентарь) | 281 | 292–296 (чат) |
|---|---|---|---|---|---|---|---|---|---|---|
| identical % | 87.96 | 88.3–88.7 | 89.6–91.7 | 83.1–83.5 | 86.8–95.6 | 87.1–98.4 | 91.1–98.2 | 86.4–87.6 | 81.2 | **0.57** |
| J/J % | 100 | 100 | 100 | 100 | 100 | 99.4–100 | 100 | 100 | 100 | 100 |
- **Первое расхождение — такт 1** (87.96 %, как `alpha_spawn` yaw 0: 87.98 %): рендер мира (область world 71.6 %, HUD 100 %,
  рука 100 %) — известный остаток слоёв terrain/sky/fog, не E2E-причина.
- **State**: позиция/движение игрока **бит в бит** на всех 88 дампах (до такта 296) (ходьба, два поворота, прыжки, падение в
  яму, выпрыгивание, упор в блок); блоки (хэш куба 17³) — равны (яма, установка, подтверждения сервера); инвентарь равен (в т.ч.
  подбор на том же такте, что у golden); `entities` ≠ с 155 — позиция предмета = шум сервера (как Java/Java);
  **`screen` ≠ с 292**: T у пака не открывает GuiChat — открывается движковый чат/консоль (вкладки Chat/Console/Debug, «hello»
  набирается туда, кадр затемнён — 0.57 %).
- **Такт 298: VoxelCore падает** на Enter в этом чате: `latest.log` — `deleting user:worlds/AlphaMine`, затем
  `[main] uncaught exception: utf8 decode error`; воспроизводится (2 прогона из 2). Серия VoxelCore — 298 тактов из 600.
  Нужно: GuiChat в паке (T, набор, Enter → `Packet3Chat`) и выключение привязки движка `hud.chat`; причину `utf8 decode error`
  (ввод символов F2F или сам движок) не выясняли.
  **Решено 01.10 (агент C, §6a «чат»)**: падение — оставленный `app.delete_world` диалог (Enter подтверждал удаление открытого
  мира), GuiChat сделан паком; повторный прогон — 600/600 тактов, state равен, кроме шума сервера.
- Прочее по кадрам: рамка выделения (толстая чёрная движковая — агент U), рука/предмет при ходьбе (hand 80–98 %), GUI-фон
  инвентаря (world 72 % при открытом экране).

## 12. Пошаговый (lockstep) сервер и барьеры клиентов (01.10)
Спецификация, команды, результаты — `agents/F2F.md` §9; исследование — `agents/research/DETERMINISM.md` §1. Кратко:
- Сервер `--f2f <порт>` (`server_v.py start --f2f 25593`, `ref\start_server.ps1 -F2F`) тикает только по `step {ticks, barriers}` харнесса;
  `mode {seed}` сидирует и канонизирует сервер; `freeze`, `state` (хэш загруженных чанков, сущности, ГСЧ), CRC потоков в ответе `step`.
  Патчи `ref\patches\f2f-server.patch` (1863 строки, весь сервер от `src_original`) и `f2f-server-only.patch`; сборка `ref\compile_server.ps1`.
- Java-клиент: `step/gui {rx_bytes}`, `tx_total` в ответах, `sync`, `wait_check`, блокирующий `connect`, `keepalive:false` (`F2FNet.java`,
  `F2FAgent`, `NetworkManager`; `f2f-client.patch`/`f2f-only.patch` обновлены и проверены `patch -p1`).
- Пак: команда `sync` (`f2f.lua`), счётчики соединения (`net.lua` `conn_out/conn_in`, `rx_avail`), **≤ 101 пакета за вызов
  `processReadPackets` как у Java** (`game.lua`: в `updateScreen` экранов входа и в `WorldClient.tick`; было до 490 пакетов за такт).
- Харнесс: `tools/alphamine/f2f_server.py` (`Lockstep`), сценарий `"server": {"f2f": true}` или `--lockstep` в `run_vc_scenario.py` /
  `e2e_run.py`; сценарий `e2e_walk1_ls` + `golden\e2e_walk1_ls\`.
- Итог: Java/Java 73/73 кадров и 157/157 дампов равны; VoxelCore/Java — все категории state равны во всех дампах, поток сервера
  побайтно одинаков для обоих клиентов, кадры 90.11 % в среднем (это рендер порта); VoxelCore/VoxelCore — 59/73 кадров побайтно (такты
  136–185, копание: частицы — недетерминизм на стороне VoxelCore, следующий кандидат на разбор). Golden `alpha_spawn`,
  `layer_terrain_flat` перезаписывать не нужно (lockstep и реальное время дают 100.00 % к ним).
- Изоляция этого агента: Java-сервер :25590 (`--name s`, F2F :25593), Java F2F :25584, `engine\VoxelCoreF2F-s.exe` :25577,
  `engine\userdir_s` (копия userdir_p + junction на пак).

### 12.1 Этап 3б лаборатории (01.10, agent_3b): lockstep — путь по умолчанию, golden заново, частицы детерминированы
- `lab run alphamine <сценарий>` идёт на пошаговом сервере (`[scenario].server_f2f = true`; `layer_entities_player` — `f2f:false`,
  второй клиент). Реальное время — `--realtime` (дымовой прогон DETERMINISM §5). Подробности, приёмка — `tools/lab/README.md` «Этап 3б»,
  `agents/F2F.md` §9. Java/Java на `e2e_walk1_ls` через демон — 73/73 и 157/157, VoxelCore — те же 59/73 к старому раннеру, что и
  старые vc1/vc2 между собой.
- Java `F2FAgent.flags()` → `hello.flags {clock, input, window, grabbed}` (пересобран `compile_client.ps1 F2FAgent.java`; секция
  F2FAgent в `ref\patches\f2f-client.patch` и `f2f-only.patch` обновлена, `patch -p1` к `src_original` = `src`, `f2f-only` туда-обратно = `src`).
  Демон проверяет `flags.input = isolated`, `flags.clock = virtual` у `ref_app`.
- Все 32 golden сняты заново: `lab golden regen` (3 прогона Java, lockstep) — **32/32 3/3 идентичны**, `golden status` — 32 fresh.
  Пиксели прежних golden те же, кроме кадров с выпавшими предметами (`p4_pickup`, `p4_place`, `p4_dig` 6_drop/7_lit, `layer_entities_dev`,
  `dev_full` 1 кадр, `e2e_walk1` 158/160/161).
- Пак: окно текстуры частиц копания выбирает `particles.lua` (`sub_texture`: джиттер EntityFX → Canvas 4×4 `am_psub_<tile>_<ox>_<oy>`,
  `random_sub_uv = 1`): генератор эмиттера движка сидируется адресом в куче. VoxelCore/VoxelCore на `e2e_walk1_ls` — 73/73 (было 59/73).
  `game.mode {fx_probe = nosub|nolight|none|engine_sub}` — диагностика для проб `det_*` (без поля поведение обычное).
- Набор vc против новых golden записан в историю как кандидат в основание (не принят): таблица — README «Этап 3б».
