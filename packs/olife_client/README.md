# olife_client — минимальный клиент Olife (реплика авторитетного мира)

Подключается к шлюзу (`tools/olife/gateway_dev.py`) по контракту `client` (`olife_proto`), ничего не решает сам:
мир присылает чанки, блоки, сущности, поправки. Работает и как **headless-бот** (стоковый 0.32 `--headless --script`,
нагрузка и согласованность), и как **оконный клиент F2F** (тестовая сборка `VoxelCoreF2F-032.exe`, тот же сценарий).
Состояние проекта — `agents/OLIFE.md`.

## Запуск
```
VoxelCore.exe --headless --script client_start.lua --tps 20 --stdin-cmd --dir <каталог>
  -- --gateway <порт> --name <имя> [--token olife-bot] [--ticks N] [--blocks <раз в N тактов>] [--walk 0|1]
```
Лаборатория: виды `olife.bot` (headless) и `olife.client` (F2F 0.32, ввод изолирован, окно hidden, часы realtime).
`client_start.lua` добавляет только недостающие паки (в окне меню уже загрузило `base`), открывает свой локальный мир
(генератор `core:default` — пустой и быстрый: каждый чанк всё равно приходит с сервера) и просит соединение;
соединение (колбэки `network.tcp_connect`), админ-команды и обработчик F2F создаются в главном состоянии Lua
(`scripts/world.lua`: первый такт мира / `on_world_open`), не в корутине сценария.

## Что делает
- `Hello{proto, name, token, engine}` → `Welcome`: свой `player_eid`, спавн, радиус; локальный игрок движка
  (`player.create`, полёт, без коллизий) грузит локальные чанки — `world.set_chunk_data` работает только на существующем.
- `ChunkData`: проверка FNV-1a, `world.set_chunk_data`, затем **чтение назад** `world.get_chunk_data` и сравнение байт
  (`verified`/`verify_diff`); чанк ещё не загружен локально — в ожидание до `on_chunk_present` (вместе с изменениями
  блоков для него).
- `BlockUpdate`: `block.set` + чтение назад (`ok`/`mismatch`), терм в hash; `BlockReject` — откат к `actual`.
- `EntitySnapshot`: spawn → сущность движка (`def` с сервера, если такой есть здесь, иначе `olife_client:avatar`),
  update → интерполяция показа за 3 такта (0.15 с по времени кадра), despawn.
- `TickSync`: hash реплики (те же термы, что у мира, `olife_proto:util`) против `view_hash`; строка в
  `user:export/client_states.jsonl` `{tick, t_recv, ts, hash, server_hash, eid, session, entities, chunks}`.
- `KeepAlive` → ответ с тем же challenge; `PlayerCorrect` → позиция сервера; `ChatMessage` — в лог (первые 20).
- **Логический такт — 50 мс по часам**, приём — каждый кадр: в окне кадров больше 20/с, и `PlayerInput` на каждый кадр
  превышал лимит шлюза (60/с) → `Disconnect 7` (найдено на F2F 0.32, 02.10).
- Бот (`modules/bot.lua`): случайная прогулка вокруг спавна (4 блока/с, детерминированно по имени), раз в N тактов —
  сломать верхний блок или поставить камень на него, строка чата при входе.

## Команды (`--stdin-cmd`; у оконного — F2F)
`status` · `olife.quiet` (остановить действия с блоками) · `olife.check_blocks` (сравнить `user:export/blocks_check.json`
— копию дампа мира — со своим миром → `user:export/blocks_bot.json`) · `olife.stop`. F2F (тестовая сборка): `state`
(такт, сессия, eid, игрок, сущности, `view_hash`, `ent_hash`, `blocks_hash`, чанки, последний TickSync, счётчики),
`status`.

## Волна 4a: Injector, GravityGun, редактор (`modules/olife.lua`, `layouts/editor.xml`)
- **Режим камеры** (оконный клиент, `--walk 0`): hud-игрок (`scripts/hud.lua` → `on_hud_open`) — это игрок клиента: его позиция
  и взгляд уходят `PlayerInput`, `PlayerCorrect` ставит его; полёт и noclip. В хотбар: слот 1 — `olife_client:injector`,
  слот 2 — `olife_client:gravity_gun` (с UX round 1 — иконки и модели пользователя из прототипа, см. ниже); предметы мира по умолчанию
  ложатся в хотбар после `on_hud_open`, поэтому слоты 0/1 проверяются ещё первые 10 с.
- **Injector**: ПКМ (`scripts/injector.lua`, `on_use`) → `ToolUse{1, use, target = player.get_selected_entity, origin/dir камеры}`;
  мир отвечает `ScriptState` → оверлей `olife_client:editor`.
- **Редактор** (нативный XML 0.32): код — `textbox` multiline, `line-numbers`, `syntax="lua"` (набор, Enter, Backspace, Ctrl+S —
  сохранение; редактирование многострочного кода в движке достаточно), консоль — нередактируемый textbox (ПКМ — очистить вид),
  строки владелец/статус/лок/счётчики, кнопки Run (Save, если правили, + Run), Stop, Save, Edit (взять лок), Clear, `select
  mode="button"` шаблонов (Spin/Orbit/Hello/Walk), имя файла + Save file / Load file (`config:olife/scripts/<имя>.lua`), Close.
  Только чтение (нет прав или лок у другого) — код не редактируется, кнопки выключены. Esc/Close → `ScriptLockRelease{close}`.
  Пока открыт с локом — `ScriptOpen` раз в 20 с (держать лок). Код из `ScriptState` не затирает несохранённые правки.
- **GravityGun**: ЛКМ (`input.add_callback("player.attack")`, если в руке пушка) или ПКМ → grab/release; пока держишь — `ToolUse
  aim` не чаще 10/с при изменении взгляда. Решает мир (`EntityOwnership`), сущность двигается обычными снимками.
- **Бирки**: `EntityMeta` → `gfx.text3d` над репликой («имя [владелец] RUN/STOP/ERROR», цвет по статусу, «(held by …)»),
  текстура коробки `olife_client:bench` по статусу. Тело бенча `static` (`kinematic` падал под гравитацией — реплика не
  получает позиций, пока сущность стоит).
- F2F (тестовая сборка): `olife {op}` — `gui` (документ редактора: тексты, код, консоль, прямоугольники кнопок в пикселях кадра
  854×480), `state` (бенчи, держатель, ответы, счётчики, камера и выбранная движком сущность), `aim {eid}`, `look {yaw,
  pitch}`, `place {pos}` (обвязка теста, как `look` харнесса), `tool`, `send {name, msg}` (запрос в обход UI — негативные),
  `ui {call}`, `eval` (разведка).

## Известное
- Локальный мир клиента сам выполняет случайные обновления блоков (трава ↔ земля в скриптах `base`) — без события и без
  правила, чтобы их выключить; на сервере такие изменения ловит перехеширование и присылает чанк заново, а местные
  расхождения клиента до следующего `ChunkData` не исправляются. Проверки согласованности опираются на присланное
  (термы hash, позиции изменённых миром блоков), не на весь мир.
- Переподключение (этап 6, supervisor): `--reconnect S` (по умолчанию 0 — выкл.). После `Disconnect` с кодом 1/8/9
  (shutdown, timeout, world_unavailable — мир перезапускается), закрытого сокета или ошибки соединения клиент через S с
  открывает новое соединение (из `on_world_tick`, главное состояние Lua) с чистой репликой: сущности движка удаляются,
  hash, чанки, ожидающие данные сбрасываются; файл `client_states.jsonl` не переоткрывается. Кик (2/10), бан (5),
  ошибка входа (4) — без переподключения (бот выходит, как раньше). В `status` — `reconnects=N`.

## Волна 4b (02.10, olife_w4b): билеты и горячая перезагрузка паков
**Вход по билету** (`modules/auth.lua`). Аргументы старта: `--auth https://127.0.0.1:<порт>` (сервис билетов
`tools/olife/auth_service.py`; пусто — по-старому, токен прямо в `Hello`), `--gw-id <аудитория шлюза>`, `--auth-pub <x25519
сервиса, base64url — закреплённый>`, `--auth-verify 0|1`. Перед **каждым** соединением (и переподключением) клиент шлёт
долгий токен по HTTPS (`network.request`, запечатан: эфемерный x25519 → HKDF-SHA256 → ChaCha20-Poly1305, `crypto` 0.32) и
кладёт в `Hello.token` одноразовый билет (≤ 60 с). Отказ сервиса `auth`/`banned` — окончательный (без переподключения),
сервис недоступен — как ошибка соединения. `status`: `tickets=N ticket_ms=…`. Почему `verify_ssl=false` в dev: curl 0.32 со
schannel без параметра CA — самоподписанный сертификат иначе не проходит (`status 0`, проверено); защиту даёт печать к
закреплённому ключу (`agents/research/OLIFE_GATEWAY_SECURITY.md` §7).

**Горячая перезагрузка паков** (`modules/packs.lua`). Шлюз шлёт `PacksChanged{version, url, files}` после `Welcome` и при каждой
смене манифеста supervisor. Клиент (сетевые вызовы — в `on_world_tick`, главное состояние Lua): `GET <url>/manifest.json` →
sha256 каждого файла client/both против своей текущей копии → `GET <url>/files/<пак>/<путь>` для изменённых (sha256 сверяется)
→ **весь** изменённый пак записывается в `world:content/<пак>/` (у `world:content` наивысший приоритет источников 0.32;
неполный каталог там закрыл бы пак) → применяется:
- **вживую (без переоткрытия):** `modules/hot/*.lua` и `config/*.json`, которые пак читает через `packs.live(пак, путь)` —
  исходник берётся из `world:content` и выполняется `load()` (кэш до следующей смены). Пример — `modules/hot/rev.lua`
  (`packs_rev` в `status`).
- **нужно переоткрыть мир** (всё остальное): `scripts/*.lua` (события мира/компонентов), прочие модули (`require` кэширует,
  стартовый скрипт держит ссылки), определения блоков/предметов/сущностей (индексы контента!), текстуры/модели/скелеты/макеты,
  `package.json`/`content.json`. Клиент делает это сам (`client_start.lua`): `Bye` → `app.save_world()` → `app.reopen_world()`
  (движок пересканирует источники, `pack.get_info("olife_client").path` = `world:content/olife_client`) → сброс реплики →
  новый билет → вход заново; сервер присылает чанки и сущности, как после переподключения. Новые блоки требуют ещё и того же
  набора паков у мира (`Welcome.blocks`).
Проверено в 0.32 (`tools/olife/probes/probe_packs.lua`, сценарий `olife_packs_reload`): `app.reopen_world()` **не сбрасывает**
кэш модулей стартового скрипта (`require` возвращает те же таблицы) — состояние клиента сбрасывается явно
(`client.leave_for_reopen` / `client.reset_after_reopen`); потоки файлов не переживают закрытие мира («unknown descriptor») —
`client_states.jsonl` продолжается частью `client_states_r<n>.jsonl` (лаборатория читает все части). `status`:
`packs_version packs_applied packs_live packs_reopen packs_dl packs_errors packs_rev packs_path packs_notified`.
Грабли 0.32 (`res/scripts/classes.lua` @ dc62ccfb): `network.get_binary` и `network.post` сравнивают `response.code` (поля нет →
ошибка внутри stdlib, колбэки вызывающего не вызываются), `network.get` принимает только статус ровно 200 — пак ходит через
`network.request`.

## Волна 4c: предсказание, дельты, инвентарь (`modules/predict.lua`, `entdelta.lua`, `invmirror.lua`)
`--opts "move=predict|legacy,drops=N,radius=R,sprint=0|1"` (лаборатория: параметр `opts` видов `bot`/`client`, сессия
`bot_opts`; строка или список по клиентам). Умолчание — `move=predict`.
- **Предсказание**: логический такт (50 мс) берёт клавиши и взгляд (`S.keys`, `S.yaw`, `S.pitch` — их выставляет бот),
  шагает `olife_proto:movement` локально и шлёт `MoveInput` с hash предсказания. `PlayerAck` — история до `ack`
  удаляется; `PlayerState` — сравнение с предсказанием для `ack`, при расхождении (> 1e-4) — состояние сервера и
  переигровка вводов после `ack`; показ — предсказание + затухающее смещение (τ 100 мс, > 4 бл — сразу). Режим камеры
  волны 4a (`walk=0`, игрок hud) остаётся на `PlayerInput`.
- **Бот**: в `move=predict` идёт к цели клавишами (вперёд, бег при `sprint=1`, прыжок, если упёрся), ставит блок только
  предметом из инвентаря (выбирает слот с `placing-block`), `drops=N` — выбросить 1 предмет раз в N тактов.
- **EntityDelta**: слоты → eid, позиции целыми 1/256 бл, показ и hash — от деквантованных значений (как у мира).
- **Инвентарь**: `InventoryState` зеркалится в инвентарь игрока движка клиента (`S.pid`, виден в UI движка) и в
  таблицу; hash сравнивается с миром (`inv_div`), таблица предметов — по hash имён первых `items` определений.
- Команды: `olife.halt` (стоять, вводы идут), `olife.freeze` (перестать слать вводы), `olife.walk`, `olife.move_state`,
  `olife.pred_reset`, `olife.check_inventory` (сравнить `user:export/inventory_check.json` — копию дампа мира — с
  зеркалом → `user:export/inventory_bot.json`); `status` дополнен `pred_*`, `delta_*`, `inv_*`; F2F `state` — `predict`,
  `inventory`. Сущность `olife_client:drop` — показ выброшенного предмета.

## Путь игрока (02.10, olife_play): меню «Сценарии» -> olife, `lab play olife`
*(16.10, UX B: `scripts/app/olife.lua` открывает меню клиента — см. раздел «UX B» ниже; `play.run` остался для совместимости,
приложение зовёт `login.run` + `play.run_world`.)*
- `scripts/app/olife.lua` — пункт меню «Сценарии» -> `olife` в стоковом 0.32 и он же `--script` рантайма в `lab play olife`
  и клиента F2F в сухом прогоне. ~~Нет `export:olife_server.txt` — `gui.alert` с подсказкой; иначе паки клиента -> мир
  `olife_replica` заново (он загружает контент) -> `require "olife_client:play"` -> `run({app = app})`.~~
- `modules/play.lua` — чтение `export:olife_server.txt` (`gateway=host:port`, `auth`, `gw_id`, `auth_pub`, `auth_verify`,
  `account`, `name`, `token`, `reconnect`), вход по билету, режим камеры (Injector/GravityGun), цикл до выхода из мира;
  через `debug.log` (с меткой времени — их читает отчёт `lab play`): `world open`, `connected`, `disconnected`, `status fps …`
  раз в 5 с, `leaving after`. Файл пишет лаборатория (`olife.play_up`). `client.lua`: `opts.host` — хост шлюза (по умолчанию
  127.0.0.1).
- Руководство пользователя — `<repo>\projects\olife\external\README-play.md`; лаборатория — `tools/lab/README.md` «Olife: путь игрока».

## Шрифт редактора и каретка (16.10, olife_caret)
Каретка, выделение и клик мышью в `<textbox>` 0.32 считаются как **число символов × `size/2`** (`FontMetrics::calcWidth`,
моноширинная ветка), а текст рисуется с шагом **FreeType-advance** у видимых символов и `size/2` у пробела. Исходный DejaVu Sans
Mono 16 px имеет advance 10 px (0.602 em), поэтому каретка уезжала влево на 2 px за каждый непробельный символ (строка
пользователя 85 символов — на 144 px, под словом «секунду»), выделение и клик — так же. Обход паком: `fonts/olife_mono.ttf`
пересобран (fontTools) — контуры сжаты по x в 1024/1233, advance = 1024 из 2048 (ровно 8 px при 16 px), хинтинг убран, в каждый
глиф добавлен нулевой контур в x = 0 (0.32 рисует битмап глифа с позиции пера, игнорируя `bitmap_left`; так буква стоит в
ячейке на своём месте, а не прижата влево). Имя шрифта, размер 16 и XML не менялись; шаг 8 px — как у стокового шрифта.
Исходный файл — `artifacts/olife_caret_bak/olife_mono.ttf.orig_dejavu_sans_mono`. Проба — `tools/scenarios/olife_caret_probe.lua`
+ `olife_caret_run.py`, тестовый пак со шрифтами-вариантами — `content/olife_caret_probe` (игре не нужен).
Шрифт с `isFixedPitch = 0` (немоноширинная ветка) **не годится**: каретка встаёт верно, но выделение, клик и горизонтальная
прокрутка 0.32 меряют ширину от начала **всего** текста, а не строки (`calcWidth(labelText, 0, n)`), и ошибаются на строках
с другим числом пробелов (проверено: −10/−8 px, клик на символ правее).

## UX round 1 (02.10, olife_ux1): замечания пользователя после первого захода
**Редактор** (`layouts/editor.xml` + `.xml.lua`, модель — `modules/olife.lua`) — раскладка оригинала пользователя
(прототип 0.30.6, `Olife/layouts/console.xml`) на нативном XML 0.32: на весь кадр (`size-func` от `gui.get_viewport()`),
`splitbox` как в оригинале: слева сверху — поле кода (самый большой элемент, векторный моноширинный шрифт `olife_mono`
16 px — `fonts/olife_mono.ttf` = **DejaVu Sans Mono, сжатый до ширины 0.5 em** (с 16.10, olife_caret; лицензия
`fonts/LICENSE-DejaVu.txt`; 0.32 грузит TTF из `preload.json` `{"name", "path", "size"}`), под ним — консоль тем же шрифтом, справа — панель **СКРИПТЫ** (строки собираются
`document.scripts:add(xml)`): «+ новый (пустой)», код сущности с сервера, файлы `config:olife/scripts/*.lua` (клик — открыть,
`x` — удалить), шаблоны. Ряд кнопок: ЗАКРЫТЬ, RUN/STOP (одна кнопка-переключатель оригинала со значком; RUN/ERROR без правок →
STOP, с правками → RUN = сохранить + запустить), имя файла, СОХРАНИТЬ (на сервер, если правите, и в файл, если имя задано;
Ctrl+S; Ctrl+R — RUN/STOP), ПРАВИТЬ (только когда можно взять лок). Под ним — вкладки «Код / Профайлер / Настройки» и
**одна** строка статуса (имя, владелец, статус, лок, отказ). Счётчики ушли со страницы кода:
- **Профайлер**: `ScriptMeters` (кредиты за такт/минуту, топливо, действия, отклонения, кредиты владельца) + `ScriptProfile`
  (результаты песочницы, ошибки, отброшенные строки, отклонённые действия, память VM — «н/д», пока песочница не шлёт её в
  бинарном контракте) + ошибки в консоли + график кредитов за такт за 60 с (60 полосок-контейнеров).
- **Настройки сущности**: имя (переименовать), владелец, модель и текстура из `olife_proto:looks` (выбор — `select`, «Применить
  вид»), права — заглушки (выключенные флажки), «Удалить сущность» (два нажатия за 4 с).
- Открыть: Injector ПКМ по бенчу, **`** (клавиша консоли движка) глядя на бенч — консоль движка закрывается, открывается
  редактор; **Shift+ПКМ** (с инструментом Olife в руке) — редактор последней открытой сущности откуда угодно (`ScriptOpen`
  без луча). **Shift+ЛКМ** — удалить последнюю открытую (`EntityEdit` op 1; звук `delete` и сообщение сверху экрана —
  `layouts/olife_hud.xml`, постоянный элемент HUD). «Последняя открытая» — на сеанс клиента. Shift = привязка `movement.crouch`
  или левый/правый Shift. Мышь, когда открыт любой оверлей/инвентарь (`hud.is_inventory_open()`), инструменты не трогает.
- **Нажатие инструмента = одно действие.** Причина «дребезга»: `PlayerController` 0.32 зовёт `on_use` предмета каждые 0.16 с,
  пока ПКМ зажата (`INTERACTION_RELOAD`), а гравипушка переключала захват на каждый вызов. Теперь ПКМ ловится привязкой
  `player.build` (`input.add_callback`, срабатывает на нажатие), повторы `on_use` до отпускания (`input.is_active` в кадре)
  отбрасываются, между двумя принятыми нажатиями ≥ 150 мс; ЛКМ — привязка `player.attack` (тоже по фронту). Захват/отпуск
  решает локальное намерение (`holding` или ушедший `grab`), подтверждение — звук `grab`/`release` по ответу мира, отказ —
  `refuse` + сообщение.
- **Бирки** (`gfx.text3d`) — только пока выбран Injector, масштаб 0.02 (было 0.04), прозрачность гаснет от 6 до 24 блоков.
- **Модели, текстуры, иконки, звуки — пользователя** (Andryha; прототип `voxelcore-0.30.6_win64_multiplayer`):
  `models/olife_bench.obj` + `textures/entities/olife_bench.png` (= `Olife/models/bench.obj`, `textures/entities/cmd.png`),
  скелет `skeletons/bench.json` (= `Olife/skeletons/bench.json`: body/rody с моделью, body1/body2 пустые), `olife_bone.obj` +
  `olife_bone.png` (= `bone.obj`, `entities/bone.png`), Injector: модель в руке `olife_injector.obj` + `olife_injector.png`
  (= `gtool.obj`, `items/gtool.png`), иконка `textures/items/injector.png` (= `items/injector_item.png`); GravityGun:
  `olife_gravitygun.obj` + `olife_gg_{0,1,2,3,4,7}.png` (= `GravityGun/models/gravitygun.obj`, `textures/entities/Image_N.png`),
  иконка `items/gravity_gun.png` (= `GravityGun/textures/items/gravitygun.png`); значки кнопок `textures/gui/olife_{play,pause,
  save,close}.png` (= `Olife/textures/gui/*_icon.png`); звуки `sounds/olife/{inject,grab,release,delete,refuse,ok}.ogg`
  (= `engine_client/config/olife/sounds/{hit,hrom_01,hrum_02,explosion_01,slap,hitG2SDADFF_01}.ogg`). Преобразования для 0.32:
  только имена — `usemtl` переименованы в уникальные имена текстур (`entities/olife_*`: в 0.32 имена моделей и текстур
  глобальны, `Image_0` столкнулся бы с чужим паком), файлы моделей с префиксом `olife_`; геометрия, UV и картинки — как были.
  OBJ 0.32 читает без `.mtl` (текстура = имя материала, `doc/ru/rigging.md`), формат скелета тот же. Тело бенча — модель
  пользователя с его текстурой (статус показывает бирка); владелец может сменить модель/текстуру (`EntityLook` →
  `rig:set_model(rig:index("rody"), …)`, для моделей с материалами `$0..$5` — `set_texture`).
- F2F `olife`: `gui` отдаёт вкладку, тексты профайлера/настроек, прямоугольники всех элементов (`GUI_IDS`) и строк панели
  скриптов, высоты полосок графика, список файлов; `state` — бирки (`tags`, `tags_on`), `last_opened`, звуки, сообщение,
  инвентарь по именам предметов, `coin_defined`, счётчики нажатий (`presses`, `presses_ignored`, `toggles`).

## UX A1 (03.10, olife_a1): права, друзья, форк
- **Настройки** редактора — две колонки: слева сущность (имя, владелец, модель/текстура, «Форк», «Друзья», «Удалить»),
  справа **панель прав**: строка на каждое из 9 действий (двигать, читать код, менять код, запуск, вид/имя, форк,
  удаление, хран. чт., хран. зап.) — сегменты «влад / друз / спис / все» (активный подсвечен), поле списка аккаунтов
  (`a,b`) и «OK» (= аудитория «список»). Строки строит `olife.perm_build` в `perm_box`. Менять может владелец/админ
  (`EntityPerms.can_admin`), остальным панель только для чтения с подписью «вам: …» (биты `mine`). Кнопки страницы
  включаются по правам мира: «Форк» — `clone`, «Удалить» — `destroy`, имя/вид — `appearance`; RUN доступен и с одним
  правом `run` (без лока — запускается сохранённый код).
- **Друзья** — оверлей `layouts/friends.xml` (нативный XML): «Добавить» по имени аккаунта, входящие (Принять /
  Отклонить), исходящие (Отменить), друзья с «в сети» (Удалить), «К сущности». Открывается кнопкой «Друзья» на странице
  настроек или **Shift+`** (консоль движка открывается кадром позже — `frame()` закрывает её и открывает друзей).
  Новый входящий запрос — тост «Запрос в друзья от X» + звук.
- **Форк** — «Форк» на странице настроек -> `EntityForked`: тост «Форк #src -> #new», звук `fx_fork` (A2 `fx`),
  Shift+ПКМ открывает форк.
- **Обратная связь** — `modules/fx.lua` (общий с A2: `fx.ok(msg)`, `fx.deny(msg, code)`, `fx.event(...)`): ответы op 8–11 и
  отказы 3 на open/save/run/stop — звук + тост с причиной по-русски (`olife.reply_text`: «нет прав: двигать — владелец
  и друзья»).
- F2F: `olife {op="gui"}` + `perm_rows` (прямоугольники сегментов/поля/OK), `perms`; `{op="friends_gui"}` — страница
  друзей (строки с прямоугольниками кнопок); `state` + `perms` (список), `friends`, `forks`.

## UX A2 (03.10, olife_a2): чат, команды, аудио-визуальная обратная связь
- **Чат** (`modules/chat.lua`, `layouts/chat.xml(.lua)`, `layouts/chat_feed.xml(.lua)`): окно открывается **T** (привязка движка
  `hud.chat`: его консоль в режиме чата открывается первой — наш колбэк через ДВА `time.post_runnable` закрывает её и открывает
  своё окно) или **Enter**; 14 строк журнала с цветом по виду/роли (игрок, `[admin]` оранжевый, оператор, система, op-строки,
  ответы команд, уведомления), время — локальное (`time.utc_offset`), ^/v (и PageUp/PageDown) — прокрутка на 5 строк, «v ещё N
  (новых M)», ↑/↓ в поле ввода — отправленные строки, Enter — отправить («/…» — команда), Esc/x — закрыть. Без окна последние 6
  строк — лента над хотбаром, гаснут за 8 с. Опоздавший видит историю (`ChatHistory`).
- **Обратная связь** (`modules/fx.lua`, общая для волн UX; API A1/A2: `fx.ok(msg)`, `fx.deny(msg, code)`, `fx.event(name, text,
  opts)`): событие = звук + тост цвета события (+ вспышка-флаг), журнал 64 событий (F2F `fx`), строка `[olife_client] fx <event>
  sound=… text=…` в лог. Каталог:

| событие | звук | откуда |
|---|---|---|
| inject (редактор открыт) | `inject` (польз.) | Injector / ` |
| run / stop / save | `ok` (польз.) / `fx_stop` / `fx_save` | `RequestReply` op 3/4/2 код 0 |
| grab / release | `grab` / `release` (польз.) | гравипушка |
| spawn / fork | `fx_spawn` / `fx_fork` | спавн (A3), форк (A1) |
| delete / killed | `delete` (польз.) | удаление владельцем / `/kill` оператора (`Notice 3/12`) |
| deny (права) | `refuse` (польз.) | любой отказ, код 3/16 и др. |
| throttle (лимиты/частота) | `fx_throttle` | код 9/20, `Notice 8` |
| frozen / unfrozen | `fx_freeze` / `fx_unfreeze` | `Notice 1/2/9/10` |
| limits / op | `fx_op` | `Notice 4/11`, ответы команд, op-строки чата |
| kicked / banned | `fx_kick` | `Notice 5/6`, `Disconnect` 10/5 |
| restarting | `fx_restart` | `Disconnect` 9/1 (шлюз: мир перезапускается) |
| chat | `fx_chat` (без тоста) | чужая строка чата |

  Звуки `fx_*.wav` синтезированы `tools/olife/gen_sounds.py` (22 кГц, 0.08–0.45 с), у пользователя для них звуков не было;
  `inject/grab/release/delete/refuse/ok.ogg` — его (UX round 1). Цвет бирки по статусу (`fx.tag_rgb`): RUN зелёный, STOP белый,
  ERROR красный, THROTTLED янтарный, FROZEN голубой.
- F2F: `chat {op: state|gui|send|open|close|scroll}` (строки с цветом, ответы, уведомления, прямоугольники кнопок, лента),
  `fx` (журнал событий). Консоль бота/клиента: `olife.say <текст>`, `olife.chat_state` (→ `user:export/chat_state.json`).

## UX A4 (03.10, olife_a4): активы хранилища на клиенте (`modules/assets.lua`)
`EntityAssets` -> скачивание `GET <PacksChanged.url>/assets/<sha>` (до 4 параллельно, из главного состояния Lua —
`client.maybe_connect` -> `assets.tick`), sha256, кэш `world:content/olife_assets/<sha>.<ext>`, регистрация на лету: PNG ->
`Canvas.decode` + `create_texture("olife_assets/<sha>")`, VCM -> `assets.parse_model` (`olife_assets:<sha>`), OGG/WAV — путь
для `audio.play_stream`. Слоты `tex:*` / `tex:$i` / `model:<кость>` ставятся на скелет каждый такт (текстуры — со сверкой
`get_texture`, модели — по ключу uid+sha+применение A3 `mobview`, потому что `get_model` 0.32 врёт после разрешения). API для
A3 и UI: `ensure`, `texture(ref)`, `model(ref)`, `animation(ref)`, `sound_path(ref)`, `play(ref, x, y, z)`, `on_ready(cb)`,
`upload(kind, name, data, eid, slot)`, `op(op, sha, eid, slot, account)`, `state(eid)`. F2F: `assets {op = state, eid}` (слоты,
файлы с sha256 RGBA декодированной картинки и текстуры движка, что стоит на скелете), `upload {b64, kind, eid, slot, name}`,
`op {aop, sha, eid, slot, account}`, `play {ref, x, y, z}`. Боты (headless) только скачивают и хешируют (GL нет).

## UX A3: вид моба из его скрипта (03.10, агент olife_a3)
`modules/mobview.lua`: `EntityAppearance`/`EntityAnim`/`EntitySound` (client.yaml 130–132) → каждый кадр (`hud.lua` после
`olife.frame`) через API движка 0.32: `entity.transform:set_rot` (поворот бенчей теперь виден: Ry·Rx·Rz из градусов
снимков) / `set_size`, `entity.skeleton:set_model/set_texture/set_matrix/set_visible`, анимация — `animation.get_track(name)
.func(skeleton, t)` своими часами (скорость, цикл; `animation.play` их не умеет), звук — `audio.play_sound` (актив —
`olife_client:assets.play`), строка текста — `gfx.text3d` с `set_entity` (едет с сущностью). Сначала база (EntityLook
владельца или бенч по умолчанию), затем переопределения скрипта; кости с позой скрипта переписываются после кадра анимации.
Новая сессия (переподключение, рестарт мира) сбрасывает состояние: мир пришлёт актуальное. Треки VCA — `animation/
olife_{wave,spin,bob,pulse}.vca` (preload.json `animation`). F2F `mobview {eid?}` — то, что видит движок (размер, матрица
поворота, текстуры, модели и матрицы костей, видимость, анимация, 3D-текст, принятые звуки).

## UX B (16.10, olife_menu): главное меню клиента, экран статуса входа, вход по нику
Постановка — `agents/OLIFE_UX.md` §8; итоги — `agents/OLIFE.md` «UX B». Всё на нативном XML 0.32, движок не менялся.
- **`scripts/app/olife.lua`** (= «Сценарии» -> `olife`, `--script` рантайма `lab play olife`, клиента F2F): паки клиента ->
  `app.load_content()` **в меню, без мира** (модули и страницы пака находятся только после загрузки контента) -> страница
  `menu.page = "olife_menu"` -> запросы страницы (Войти / Повторить / Назад / Выход) -> `login.run` -> `play.run_world` ->
  после выхода из мира снова меню (или экран статуса с ошибкой разрыва). Состояние меню и статуса — таблицы этого
  скрипта: закрытие мира сбрасывает контент до `base` и выгружает модули пака, после перезагрузки контента модули
  получают те же таблицы (`bind`). Всё под `xpcall` (непойманная ошибка app-скрипта = abort 0xC0000409). `--autologin 1`
  (аргумент проекта) — сразу «Войти» с автозаполнением (сухой прогон `lab play olife --dry-run`).
- **Меню** `layouts/pages/olife_menu.xml(.lua)`, модель `modules/menu.lua`: 3D-сценка — `<modelviewer src="olife_menu_scene">`,
  VCM `models/olife_menu_scene.vcm` собран из OBJ пака (бенч, кость, Injector, GravityGun, Спамер, шар на полу из досок;
  `tools/olife/gen_menu_scene.py`, ~3.6 тыс. треугольников); камера медленно вращается (8°/с): Lua видит у modelviewer
  только `src`, поэтому узел пересоздаётся с новым `cam-rotation` раз в 0.1 с. Поля «Шлюз (ip:port)», «Ник» (2..24:
  латиница, цифры, `_ . -`), «Войти», «Последние серверы» (6, с данными сервиса билетов), «Выход» (меню движка).
  Запоминание — `config:olife_client/menu.json` (адрес, ник, последние серверы; **токен туда не пишется**).
  `export:olife_server.txt` — только автозаполнение и сервис билетов (`auth`, `gw_id`, `auth_pub`); токен файла берётся,
  если ник = аккаунт файла, иначе вход **по нику** (решает вайтлист сервера). Файл перечитывается при каждом «Войти».
  Обратная связь: вспышка кнопки 0.2 с + звук (`fx`: `ok`, `stop`, `refuse` при ошибке формы, `select`).
- **Экран статуса** — страница `layouts/pages/olife_status.xml` (меню) и тот же макет `layouts/olife_status.xml` как
  постоянный элемент HUD в игре (`hud.open_permanent` в `scripts/hud.lua`, видим только когда есть что показать);
  рисует только `modules/status_view.lua` по `modules/status.lua` (фазы, прогресс, ошибка, баннер; подписка/`seq`).
  Фазы: адрес и ник -> билет у сервиса -> соединение со шлюзом -> Welcome -> манифест паков -> загрузка файлов (файлы,
  байты, полоса, текущий пак/файл) -> sha256 -> мир-реплика -> первые чанки -> в игре. Ошибка — строка с кодом
  (`[kind code]`, код протокола/HTTP/сервиса) и причиной как пришла, «Повторить» / «Назад».
- **Вход** `modules/login.lua`: билет (`auth.lua`, запечатанный запрос; `name` — ник) -> `client.prelude_connect` (сокет до
  мира: KeepAlive отвечает, Welcome/PacksChanged откладывает, остальное копит) -> манифест и скачивание
  (`packs.check`/`packs.fetch`, до 4 файлов параллельно, sha256 каждого) -> `app.new_world` + запись изменённых паков в
  `world:content` + `save_world` + `reopen_world` -> ожидание игрока HUD -> `client.enter_world()` (Welcome + накопленное
  по порядку) -> чанки. **`app.reopen_world()` выгружает модули пака** (новые экземпляры из `world:content`): `login.carry`
  передаёт новым экземплярам состояние (`client.adopt`, `packs.adopt`, `bind` статуса/меню).
- **В игре** (`play.run_world`): паки на лету — те же фазы на HUD-экране (манифест -> файлы -> sha256 -> «вживую» или
  переоткрытие мира и вход заново), «Мир перезапускается, держитесь» (Disconnect 9/1) и фазы переподключения (билет ->
  шлюз -> Welcome, попытки), окончательный разрыв (кик, бан, отказ) -> мир закрыт, экран статуса с ошибкой. Выход в меню —
  `gui.set_active_frame("core:main")` (иначе курсор остаётся захваченным и меню не принимает мышь).
- F2F (тестовая сборка): команда `menu` — страница, поля, прямоугольники кнопок, строки и ошибка статуса (из состояния
  и с самих элементов страницы/HUD), баннеры, клиент, паки, `fx`; `{op = leave}` — выйти из мира (тесты). В меню
  обработчик ставит страница (у мира — `scripts/world.lua`). Сценарии `olife_menu_status`, `olife_menu_whitelist`.

## Антифрод и бан по IP (16.10, olife_antifraud)
Экран статуса: новые виды ошибок `nick` («ник недоступен»: `nick_in_use`, `nick_similar`, `nick_reserved`, Disconnect 18) и
`antifraud` («антифрод: лимит»: `rate_ip`, `rate_net`, `multi_account`, `sessions_ip`); `ip_banned` — вид `banned` с причиной
«бан по IP … до …». Все эти отказы финальные (без автоповтора входа, `client.lua`). `Notice.event` 13/14 — события `fx`
`fraud_warn` (звук `fx_throttle`) и `fraud_throttle` (`refuse`).

## Игра у друга по сети (16.10, olife_friends) — `agents/research/OLIFE_PUBLIC_PLAY.md`
- **Одна строка:** в поле «Шлюз» — `ip:port` или `ip:port#отпечаток` (первые символы ключа сервиса билетов из приглашения
  хоста, `play.bat friend НИК`). Для любого адреса, которого нет в `export:olife_server.txt`, фаза «Адрес и ник» сначала
  спрашивает шлюз (`modules/serverinfo.lua`: `InfoRequest` -> `ServerInfo` -> Disconnect 19) и берёт оттуда порт сервиса
  билетов, порт паков, id шлюза и ключ запечатывания; адреса строятся от набранного хоста. Шлюз без `InfoRequest` (старый)
  -> прежние данные (последний сервер / файл), если их нет — ошибка `[no_info]`.
- **Ключ:** отпечаток не совпал -> `[server_key fingerprint]`; ключ этого адреса из «последних серверов» сменился ->
  `[server_key key_changed]`, «Повторить» принимает новый (TOFU); токен аккаунта из файла не уходит к ключу, отличному от
  ключа файла (`[server_key token_pin]`).
- **Паки:** `PacksChanged.url` с петлевым хостом (сервер объявляет `127.0.0.1`) заменяется хостом шлюза (`serverinfo.fix_url`,
  в `client.lua` — в меню и в игре; активы — та же база).
- Сборка другу — `lab olife bundle` (стоковый VoxelCore 0.32 + копии `olife_client`/`olife_proto`, `OLIFE.bat`, `ПРОЧТИ.txt`).
