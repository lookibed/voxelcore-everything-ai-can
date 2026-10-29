# alphamine — клиент Minecraft Alpha 1.0.16 для VoxelCore 0.31 (фаза 2: мир сервера виден)

План, протокол, результаты проб и числа паритета — `agents/ALPHAMINE.md`, F2F — `agents/F2F.md` (корень VoxelCore).
Сервер — оригинальный Java Alpha SMP 0.1.1 (протокол 14, `D:\Prog\AlphaMine\ref\minecraft_server`).

## Запуск
- **Разработка (прямо при старте, без меню):** свой сервер `python3 tools/alphamine/server_v.py start` (порт 25566, свежая
  копия `golden\world_a` в `run\world_v`), затем `vc_start(script="user:tools/scenarios/alphamine_world.lua",
  wait_for="\\[alphamine_app\\] ready")`. Адрес — `export:alphamine_server.txt` (`host:port`, `none` — без сети).
  В `latest.log`: `[alphamine] connected`, `login ok`, `first position`, `441 map chunks at tick N (... s)`, раз в 5 с
  `status tick ... fps ... map_chunks ... engine ... dirty ...`.
- **Пользователю:** меню «Сценарии» → `alphamine` (`scripts/app/alphamine.lua`), сервер `localhost:25565`
  (или `export:alphamine_server.txt`).
- **F2F (тесты паритета):** `am_client(action="start", impl="vc", server="127.0.0.1:25566")` — `VoxelCoreF2F-v.exe` со
  стартовым сценарием `tools/scenarios/alphamine_f2f.lua`; дальше `am_f2f(impl="vc", cmd=connect|wait|chat|state|render|
  shot|...)`; сценарии целиком — `python3 tools/alphamine/run_vc_scenario.py alpha_spawn layer_terrain_flat`.

Мир `AlphaMine` создаётся заново (`app.new_world`) поверх папки прошлого запуска; чанки, прочитанные движком с диска, пак
перезаписывает (данные сервера или воздух). `app.delete_world` не вызывается: вне headless это диалог подтверждения с
глобальным Enter, который в мире удалял открытый мир и ронял движок (`agents/LESSONS.md`, 01.10). `chunks.load-distance` ставится 16 (сервер шлёт квадрат ±10
чанков, движок грузит круг: для углов нужно ≥ 15) и возвращается, когда мир закрыт (при убийстве процесса движок
настройку не сохраняет — остаётся прежняя).

## Устройство
| Файл | Что |
|---|---|
| `blocks/*.json`, `textures/blocks/am_*.png`, `modules/blocks_table.lua`, `modules/items_table.lua`, `BLOCKS_TODO.md` | **генерируются** `tools/alphamine/gen_pack_blocks.py` из `D:\Prog\AlphaMine\tables` и `assets\tiles\terrain`: 69 блоков `alphamine:<name_snake>`, 131 текстура (префикс `am_` — атлас `blocks` общий, у `base` есть `leaves`/`leaves_opaque`, `grass`, `dirt`...; нижняя грань — отражённая по вертикали копия), варианты по meta (`state-based`) |
| `modules/blocks.lua` | альфа id ↔ индекс блока VoxelCore; meta альфы = userbits состояния (`state = meta << 8`) у всех блоков → обратное отображение точное |
| `modules/net.lua` | TCP протокола 14: буфер приёма, разбор по индексу (размеры пакетов из `Packet*.java`), double/float BE вручную, отправка через `byteutil.pack` |
| `modules/chunks.lua` | хранилище чанков альфы (81920 байт в раскладке `Chunk`: блоки `x<<11|z<<7|y`, полубайты meta/свет), MapChunk целиком и частями (`World/Chunk.setChunkData`), PreChunk, BlockChange/MultiBlockChange (в загруженный чанк — `block.set`), перекодирование в `world.set_chunk_data` для присутствующих чанков (`on_chunk_present`) |
| `modules/player.lua` | игрок: позиция от сервера (`handleFlying` + эхо), физика стоящего игрока (гравитация, вертикальные столкновения по коробкам альфы, урон от падения; константы как во float Java), `sendMotionUpdates`, камера пака `alphamine:view` (FOV 70, глаз = posY, сдвиг −0.1 по взгляду как `orientCamera`; с 01.10 камеру строит `fpview.camera()` — покачивание и интерполяция prevPos) |
| `modules/game.lua` | такты альфы по часам движка (20/с; F2F — виртуальные), порядок `Minecraft.runTick`, обработчики пакетов, чат, инвентарь (`AddToInventory`), экраны (`GuiConnecting`, `GuiDownloadTerrain`, `ingame`, `GuiConnectFailed`) |
| `modules/f2f.lua` | обработчик F2F пака: `connect`, `chat`, `state` (форма как у Java §6, хэш FNV-1a 64 блоков из движка и из хранилища), `wait_check` (цикл `wait` — в харнессе), `keepalive`, `status`, `mode`, `render` (слои движка — в C++ F2F-сборки) |
| `modules/launch.lua` | открытие мира (общий код меню, прямого запуска и F2F) |
| `modules/chunk_codec.lua` | кодек `set_chunk_data` (extrle16 + gzip) и zlib→gzip для MapChunk (пробы 2–3) |
| `shaders/main.glsl{v,f}` | непрозрачный проход: тексели альфы (сдвиг 15.99, `GL_NEAREST`), проекция GLU, свет сервера (`lightmap`), грани 1.0/0.5/0.8/0.6, туман 64…256 радиальный на вершине |
| `shaders/translucent.glsl{v,f}`, `lib/am_fluid.glsl` | вода: высоты углов, течение, анимация (`texfx`), свет `max(своя, над)`, «ближайший фрагмент» |
| `shaders/background.glsl{v,f}`, `lib/am_sky.glsl` | небо альфы при времени 0 (плоскости ±16, туман на вершинах, солнце/луна); константы — `tools/alphamine/gen_sky.py` |
| `shaders/lib/am_world.glsl` | общее: таблицы яркости, чтение региона света/кодов, `face_texel`, туман |
| `modules/lightmap.lua` | регион атласа `am_lightmap` (2688×1346): свет сервера и коды жидкостей по слотам чанков 21×21 |
| `modules/texfx.lua` | `TextureLavaFX/WaterFX/WaterFlowFX/LavaFlowFX` (+ расход случайных огня) по такту, общий поток `Math.random` F2F, регион `am_fx` |
| `models/amblk_cross.vcm`, `textures/misc/{sun,moon,moon_flare}.png` | кресты `renderCrossedSquares`; прозрачные спрайты неба движка (генерирует `gen_pack_blocks.py` / вручную) |
| `resources.json` | камера `alphamine:view` |
| `scripts/world.lua`, `scripts/hud.lua` | события движка → модули (такты в `on_world_tick`; HUD, рука, меню — из `on_hud_open`/`on_hud_render`) |
| `generators/void.toml` | пустой мир (только воздух) |
| `textures/gui/am_*.png`, `textures/gui/crosshair.png`, `textures/font/am_default.png`, `textures/particles/am_*.png`, `models/am_hand/*.vcm`, `modules/ui_tables.lua` | **генерируются** `tools/alphamine/gen_ui_assets.py` (фаза 3): текстуры альфы с alpha-test, 3D-иконки блоков (атласы по масштабу GUI 1–4), прицел альфы вместо движкового, тайлы частиц ×0.6, модели руки (плоский предмет, рука, блоки), ширины шрифта, иконки предметов |
| `modules/hud.lua`, `layouts/hud.xml` | HUD `GuiIngame` документом `hud.open_permanent` (слой F2F `hud`): хотбар, рамка слота, сердца (+дрожание), броня/воздух, предметы с числами и износом, строка версии, чат, виньетка; хотбар движка прячется |
| `modules/ui.lua`, `modules/font.lua`, `modules/jrandom.lua` | `ScaledResolution` и XML-прямоугольники (region снизу вверх!), шрифт альфы глифами-картинками (ширины FontRenderer, тень, `§`-цвета), `java.util.Random` |
| `modules/gui.lua`, `layouts/ingame_menu.xml` | GuiIngameMenu оверлеем (`hud.show_overlay`, слой `gui`): фон-градиент, кнопки gui.png с наведением, «Saving level..»; F2F `gui {key, click}`, Esc и клик в рантайме |
| `modules/hand.lua`, `skeletons/hand.json`, `config/defaults.toml` | рука/предмет от первого лица скелетом `alphamine:hand` (матрицы `ItemRenderer` во float, взмах, экипировка, покачивание руки, свет альфы в canvas-текстурах по граням), камера `core:first-person` = копия `alphamine:view` каждый кадр (обёртка `stdcomp.render`) |
| `modules/fpview.lua` | (01.10, U) состояние вида игрока по тактам: взмах `swingItem` (Packet18), цикл кликов `runTick` (`mouseTicksRan`, `leftClickCounter`, хук `on_click` → interact.lua P), покачивание `viewBobbing` (`distanceWalkedModified`, `cameraYaw/Pitch`), prevPos; `fpview.camera()` — камера пака (`setupCameraTransform`: bob, интерполяция prevPos→pos, −0.1) |
| `modules/inventory_gui.lua`, `layouts/inventory.xml`, `modules/inv_preview.lua` | (01.10, U) GuiInventory (I; E — тоже): фон, inventory.png, слоты/иконки/числа, подсветка, стак у курсора, «Crafting»; модель и клики — `inventory.lua` (P); превью игрока — Lua-растеризатор ModelBiped + предмет в руке в canvas-текстуру; он же рисует 3D-иконки при дробном масштабе GUI и «прыжке» хотбара |
| `modules/chat_gui.lua`, `layouts/chat.xml` | (01.10, C) GuiChat: T, набор (невидимый `<textbox>` движка — источник символов, Backspace, Enter), `ChatAllowedCharacters`, 100 символов, Enter → Packet3Chat, Esc; строка «> …_» шрифтом альфы; документ `hud.open_permanent` (прицел остаётся, как у Java); привязка движка `hud.chat` выключена. Проверка: `run_vc_scenario.py u_chat` (12/12 кадров 100 %) |
| `modules/particles.lua` | частицы копания `EntityDiggingFX` через `gfx.particles.emit` (моделирование Java до передачи движку), пресеты дыма/огня/пузырей/брызг |
| `preload.json` | текстуры GUI/шрифта и модели руки; модели/текстуры сущностей (`am_items`, `am_font`, `am_shadow`, `entities/am_*`) дописывает `gen_models.py` |
| `modules/player.lua`, `modules/physics.lua`, `modules/jmath.lua`, `modules/input.lua` | (фаза 3, P) игрок `EntityPlayerSP` целиком: движение W/S/A/D, прыжок, трение, вода/лава/лесенка, `Entity.moveEntity` в Lua бит в бит с Java (или `collision engine` — тело движка); мышь — `input.get_mouse_delta` раз в кадр при захваченном курсоре; `java.util.Random`, `(float)`, MathHelper |
| `modules/inventory.lua`, `items/item_*.json`, `textures/items/am_*.png` | (фаза 3) `InventoryPlayer`, слоты 1–9, Q, пакеты 16/17/21, зеркало в инвентарь движка; предметы генерирует `tools/alphamine/gen_pack_items.py` |
| `modules/entities.lua`, `modules/mat.lua`, `modules/models_table.lua`, `entities/am_*.json`, `skeletons/am_*.json`, `models/am_*.vcm`, `textures/entities/am_*.png`, `shaders/entity.glsl*`, `scripts/components/am_frame.lua` | (фаза 3) сущности сервера нативно: другой игрок (ModelBiped, имя шрифтом альфы), предмет, вагонетки, лодка; модели — `tools/alphamine/gen_models.py` из Java-классов моделей; свет RenderHelper в шейдере сущностей; `am_frame` — покадровый хук (такты, мышь, позы) |

Грани: `texture-faces` VoxelCore = [-X, +X, -Y, +Y, -Z, +Z] (проверено пробой `alpha_probes/p8_faces.lua`), сторона
альфы `s` (0 низ, 1 верх, 2 −Z, 3 +Z, 4 −X, 5 +X) → `vc[i] = alpha[[4,5,0,1,2,3][i]]`.
Шейдеры: пак подменяет `shaders/main.glslv`/`main.glslf`, но не `shaders/lib/*.glsl` движка (свои — под новыми именами).

## Фаза 3: HUD, рука, частицы, GUI (агент U)
Проверка своим экземпляром: `python3 tools/alphamine/run_u.py layer_hud layer_gui layer_hand layer_particles alpha_spawn`
(`VoxelCoreF2F-u.exe`, F2F :25573, `engine\userdir_u`, сервер :25568; `--prefix quick` — без `/tp`, для HUD/GUI). Размер
кадра — из сценария (поле `"size"`, F2F.md §8): 854×480, а `u_hand_wide`, `u_inventory_wide`, `u_hud_wide` — 1390×855
(отдельной сессией). Числа: hud 100 % ×4, gui 100 % ×2, hand 100/97.72/100/97.72 %, частицы — покрытие и средний цвет
(таблица — `agents/ALPHAMINE.md` §6). Ассеты пересобирать `python3 tools/alphamine/gen_ui_assets.py`.
01.10 (§6a): `u_swing` (взмах 100/100/100/99.94, экипировка 99.21…100), `u_walk_bob` (ходьба с покачиванием: весь кадр
99.77–99.90, рука 100 ×4), `u_hand_items` (99.09/100/100), `u_inventory` (99.87–99.99), при 1390×855 — `u_hand_wide`
(100 при yaw 0/180), `u_inventory_wide` (99.99–100), `u_hud_wide` (100/100/99.99). Масштаб GUI при 1390×855 — 3.00216×3
пикселя на единицу (как Java), прицел перерисовывается под размер кадра.

## Фаза 3: игрок, сущности, предметы (агент P)
`python3 tools/alphamine/run_vc_scenario.py alpha_spawn layer_entities --exe VoxelCoreF2F-p.exe --f2f-port 25572 --dir
/mnt/d/Prog/AlphaMine/engine/userdir_p --server-port 25567 --server-name p` (и `layer_entities_player` — со вторым Java-клиентом;
`--impl java --golden` — эталон). Числа: entities 99.88 % (tol 1: 100 %), entities_player 98.33 % (tol 3: 99.993 %);
столкновения Lua = Java бит в бит, движок — нет (таблица — `agents/ALPHAMINE.md` §7). F2F: `collision {mode}`, `eval {code}`
(отладка), `state.player.exact`, `state.world.entities`.

## Фаза 4: взаимодействие с миром (агент P)
| Файл | Что |
|---|---|
| `modules/interact.lua` | `getMouseOver` (луч Alpha по границам блоков + сущности, досягаемость 4), `PlayerControllerMP` (Packet14 0/1/2/3, урон `blockStrength`, задержка 5, износ), установка (`Packet15` + `ItemBlock.onItemUse`, откат), `WorldClient`-откат 80 тактов, звуки `am/*`; хуки: `fpview.on_click` (клики U), обёртки обработчиков BlockChange/MultiBlockChange/MapChunk/Collect; наружу — `game.mouse_over`, `game.frame_over`, `game.dig {x,y,z,stage}` (трещины U), `game.block_id` |
| `modules/relight.lua` | пересвет клиентом после изменения блока (правило `MetadataChunkBlock.updateLight`, карта высот), регион света шейдеров |
| `modules/interact_table.lua`, `sounds/am/**`, `preload.json` `sounds` | **генерирует** `tools/alphamine/gen_interact.py`: прочность/границы/материал/звуки блоков, инструменты/еда/броня, 93 рецепта (снятых запуском классов эталона) |
| `modules/entities.lua` | `collect`: `random.pop` + `EntityPickupFX` 3 такта (слой F2F `particles`), предмет виден в такте Collect на месте |
| `modules/inventory.lua` | броня, сетка 2×2, результат крафта, `GuiContainer.mouseClicked`, индексы 0..43 для экрана U, `animationsToGo` |
Проверка: `run_vc_scenario.py p4_dig p4_place p4_pickup --exe VoxelCoreF2F-p.exe --f2f-port 25572 --dir .../userdir_p
--server-port 25567 --server-name p`; числа — `agents/ALPHAMINE.md` §8.

## Не сделано (фазы 3–4)
Слои мира (terrain/свет/туман 99.9 %, небо 95.8 %, вода 99.4–99.9 %) — `agents/ALPHAMINE.md` §7. Не сделано: облака, лава
(текстура и высоты), огонь, пересвет при изменении блоков, рендер-типы провода, табличек, огня (факелы, лестницы, двери,
рельсы, ступени, рычаги, кнопки, кактус, посевы — модели с 01.10, §10; остатки — `BLOCKS_TODO.md`), тень сущностей, течение воды,
рельсы вагонеток; из фазы 3 — свет одной грани руки на yaw 90/270, рамка выделения и трещины альфы (рамка — движковая),
экраны кроме GuiIngameMenu, GuiInventory и GuiChat, F3 строки 2–4.

## Производительность (агент V, 01.10)
Набор `tools/alphamine/perf/` (подробно, числа, причины просадок — `agents/ALPHAMINE.md` §9):
- `python3 tools/alphamine/perf/perf_normal.py --tag X` — обычный запуск рантайма (окно пользователя 1390×855, реальное
  время): пак сам проходит маршрут (`modules/autowalk.lua`) и пишет профиль (`modules/perf.lua`) → CSV, график,
  `perf_report.md` в `D:\Prog\AlphaMine\runs\<время>_perf_normal_X\`; `--end disconnect|lost` — проверка выхода в меню.
- `python3 tools/alphamine/perf/perf_walk.py --tag X` — то же в F2F (`VoxelCoreF2F-v.exe`, 854×480, F2F-команда `perf`).
- `perf_compare.py A B` — таблицы «до/после», `perf_report.py <run>` — пересобрать отчёт.
- Вручную в обычном запуске: файл `export:alphamine_perf.txt` (`run=<имя>`) включает профиль (части CSV каждые 5 с в
  `export:alphamine_perf/<имя>/`), `export:alphamine_autowalk.txt` — ходьбу; `export:alphamine_debug.txt` — отладочные
  строки (`look dx …`, свет руки). Без этих файлов пак ничего не пишет.
Запись чанков в движок в обычном запуске — пачкой раз в 0.5 с после загрузки региона света (`modules/chunks.lua`
`lm_interval`, `max_per_frame`), в F2F — всё сразу. Опция (по умолчанию выключена до чистого замера): изменения блоков в чанках дальше 1 чанка от
игрока в обычном запуске откладываются по чанку на 1 с и применяются по ≤ 4 чанка за кадр (`chunks.bc_defer = 2`,
`bc_age`, `bc_max`; заселение новых чанков сервером иначе перестраивает меши кадр за кадром), ближние и F2F — сразу.
- `perf_stream.py [--f2f] [--variant lp]` — поток 20–40 MapChunk/с (прямая по догенерируемому миру world_b, `autowalk
  glide=1`), задержка появления, профиль движка в F2F (`am_perf` — команда пака, `perf` — движка); проверка простоя ПК
  перед замером (`perf/hostload.py` = `tools/lab sysload`). `gen_pack_blocks.py --engine-light off` — вариант блоков
  без света движка (паритет слоёв тот же; `perf/make_variant.py` собирает его в отдельный каталог). Пауза движка при потере фокуса выключена (`hud.set_allow_pause`),
вместо неё — GuiIngameMenu альфы; Disconnect и «Back to title screen» (GuiConnectFailed при кике/обрыве) закрывают мир.

## Мир разработчика и модели блоков (агент D, 01.10)
- `golden\devworld` (все блоки альфы рядами, жидкости, растения, башни-видовые точки) — `python3 tools/alphamine/gen_devworld.py gen|scenarios|
  finalize|checklight|diff|dump`; сценарии `layer_terrain_flat_dev`, `layer_terrain_lit_dev`, `layer_water_dev`, `layer_entities_dev`, `dev_full`
  (база `dev_base`), разбор по экспонатам — `python3 tools/alphamine/am_rows.py <run> [сценарии] --labels`. Раскладка, команды, таблица и
  список неверных блоков — `agents/ALPHAMINE.md` §10.
- `models/amblk_<блок>_m<meta>.vcm` (**генерирует** `gen_pack_blocks.py`): геометрия `RenderBlocks` факелов, лестниц, рельсов, ступеней,
  дверей, рычагов, кнопок, кактуса, посевов по состояниям; текстуры вписаны в модель (рантайм 0.31 не разрешает `$i` у вариантов),
  вариант 15 — `none` (рантайм его не готовит). Остатки — `BLOCKS_TODO.md`.
