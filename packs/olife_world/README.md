# olife_world — авторитетный мир Olife (сервер, headless VoxelCore 0.32)

Пак сервера мира по `agents/research/OLIFE_ARCHITECTURE.md` §1/§4: VoxelCore — только симулятор; игроков принимает
шлюз (`tools/olife/gateway_dev.py`), пользовательский код исполняет песочница (`sandboxd` / `tools/olife/sandbox_stub.py`).
Зависит от `olife_proto` (сгенерированные кодеки). Состояние проекта, цифры — `agents/OLIFE.md`.

## Запуск
```
VoxelCore.exe --headless --script server_start.lua --tps 20 --stdin-cmd --dir <каталог> [--project <с network>]
  -- --port <внутренний порт> [--sandbox <порт>] [--sandbox-proto jsonl|bin] [--secret S] [--ticks N] [--view R]
     [--world olife] [--seed 2026] [--generator base:demo] [--mobs 3] [--scripted 2]
```
В лаборатории — вид `olife.world` (стартовый сценарий копируется из этого пака). `server_start.lua` проверяет
`vc.is_headless()`, добавляет только недостающие паки (`app.get_content()` — в окне повторный `base` = abort), открывает
существующий мир или создаёт новый, держит игрока-«якорь» в точке спавна (чанки грузит только игрок движка), ждёт
загрузки спавна и просит `server.request_begin()`. Сокеты, их колбэки и админ-команды создаются **первым тактом мира**
(`scripts/world.lua` → `server.maybe_begin()`, главное состояние Lua), не в корутине сценария (LESSONS «Olife»).

## Такт (20 Гц, `on_world_tick`, свой планировщик — не ECS `on_update` с 6.7 Гц)
1. **incoming** — `net.poll`: чтение всех шлюзов, не больше `max_frames` (2048) кадров за такт (остаток ждёт в буфере);
   каждый кадр — в кольцевой журнал 256 записей (такт, шлюз, сессия, тип, размер, ошибка) **до** разбора; очередь
   админ-действий (`kick`).
2. **sandbox** — применение `TickResult` прошлого такта с проверкой (конечность, шаг ≤ 2 блока за такт, зона 48 блоков от
   спавна, досягаемость 6 и частота для `block.set`, частота печати; `spawn` — не разрешён в этой волне).
3. **world** — мобы (детерминированно от такта), позиции сущностей движка (падающий песок и т. п. — `on_entity_spawn`),
   пополнение лимитов, **перехеширование чанков** (2 за такт по кругу из тех, что держит хоть одна сессия).
4. **replication** — изменения блоков такта держателям чанков (группы с одинаковым списком → один `Multicast`); новые чанки
   по интересу (квадрат радиуса `view`=3 чанка, ≤ 4 за такт на сессию, ближние первыми; выгрузка за `view+1`);
   `EntitySnapshot` с dirty-полями (только видимые сущности: в чанках, которые сессия держит; свою не шлёт);
   `TickSync{tick, server_ms, view_hash}` каждой сессии; `TickInput` песочнице.
5. **send** — один `socket:send` на шлюз (и на песочницу) за такт.

## Авторитет и проверки
- `PlayerInput`: шаг ≤ `max_speed/20 · Δтактов · 1.5 + 0.25` (12 блоков/с), высота 0..300, чанк загружен — иначе
  `PlayerCorrect` (позиция сервера). Принятая позиция ставится игроку движка (чтобы мир грузил чанки вокруг).
- `BlockAction`: ведро 10/с (запас 20), досягаемость 8 от глаз, 0 ≤ y ≤ 255, чанк загружен и есть у сессии, ломать — не
  воздух, ставить — существующий id и заменяемое место; иначе `BlockReject{reason, actual}` (клиент откатывает).
  Применение — `block.set`, затем чтение назад; в рассылку идёт то, что реально стоит в мире.
- `ChatSend`: ведро 2/с (запас 5) → `ChatMessage` всем (`Multicast`).
- Тело `Data` разбирается заново (миру шлюз не доверяет): ошибка схемы или c2s-направления → `Detach` (кик, код 4).
- Шлюз: первый кадр — `GatewayHello` с секретом и версиями, иначе соединение рвётся; любой плохой кадр — тоже.

## Изменения мира самим сервером
Движок 0.32 **не даёт события на любое изменение блока**: есть `on_block_placed/broken/replaced/interact` (только от лица
игрока), `on_block_tick`/`on_update`/`on_random_update` (скрипты конкретного блока), `on_chunk_present/remove`. Поэтому:
кэш `world.get_chunk_data` (≤ 256 чанков, FNV-1a) + перехеширование по кругу; отличие, которое не наше, — новый
`ChunkData` всем держателям (`rehash=<переотправки>/<проверок>` в `status`; в прогонах 02.10 — 1–2 на 840–1100 проверок).
Перед своим изменением чанк сверяется тоже (чужое изменение не «растворяется» в нашем). Сущности, которые создаёт сам
движок (падающий песок, дроп), ловятся `on_entity_spawn/despawn` и реплицируются как сущности вида 2.

## Состояние для проверки согласованности
`view_hash` сессии = Σ термов видимых сущностей (`fnv(eid, f32-биты pos, rot)`) + Σ термов отправленных изменений блоков
(`fnv(x, y, z, id, states)`), по модулю 2^32 (порядок не важен). Реплика считает то же из того, что приняла. Каждый такт
в `user:export/world_states.jsonl`: `{tick, ts, hash, views: {"<eid игрока>": view_hash}, sessions}`.

## Сохранение
`world:olife_registry.json` при `on_world_save`: `next_eid`, мобы и скриптовые сущности (с теми же eid), позиции
игроков по `аккаунт/имя`, спавн. При открытии существующего мира реестр загружается, вошедший игрок получает прежнюю
позицию (проверено: рестарт аренды мира → «registry loaded: 5 entities, next_eid=7», вход → `(restored)`).

## Админ-команды (`--stdin-cmd`, в лаборатории `lab stdin <аренда> "<команда>"`)
`status` (такт, tps, сессии, сущности, байты, чанки, отказы, перехеш, время такта avg/p95/max и по фазам, журнал,
песочница, `scripted=`) · `players` · `kick <eid>` (в очередь, применяется в фазе 1) · `save` · `journal [n]` · `olife.dump_blocks`
(все изменённые миром позиции → `user:export/blocks_world.json`) · `olife.stop`.
Этап 6 (supervisor, `tools/lab/labcore/supervise.py`): `journal_dump [path]` (снимок для supervisor в файл, по умолчанию
`user:export/journal_dump.json`) · `sandbox_reconnect` (песочница перезапущена — переподключиться сейчас, не через 2 с; в
очередь фазы 2). `--journal-every N` (тактов, 0 — выкл.): тот же снимок раз в N тактов в `user:export/sup_state_{a,b}.json`
попеременно — кольцо 256 входящих кадров `[tick, gw, session, type, ctype, size, ms, err]` (`ctype` — тип сообщения
клиента внутри `Data`), игроки (+`actions`), действия по аккаунтам, сущности по владельцам, мост песочницы с последним
TickResult и учётом по владельцам. Убийство процесса посреди записи портит не больше одного из двух файлов.
Волна 3a (настоящий `olife-sandboxd`): `spawn_scripted <code> [owner=1] [count=1] [owners=1]` — `count` скриптовых
сущностей (`sandbox/<code>.lua`) каждому из `owners` владельцев начиная с `owner`. Команда ставится в очередь фазы 1,
сущности раскладываются по сетке шагом 4 в радиусе 36 от спавна в 3 слоя (≈ 750 мест), загрузка в песочницу уходит
сразу; не больше 2000 за команду. `olife.sandbox_dump` → `user:export/sandbox_entities.json`: по владельцам — статусы,
топливо, кредиты, api-кредиты, применено/отклонено миром, отброшено сервисом, последний `OwnerMeter` сервиса (state,
kills, traps, mem_peak); по сущностям — то же, плюс скрипт, последняя ошибка, последний принятый текст, позиция.

`spawn_sample <account> <name> <code> [run=1]` (путь игрока, 02.10): один бенч владельца `<account>` с именем `<name>` и кодом
`sandbox/samples/<code>.lua` (`demo_orbit`, `demo_follow`, `demo_blink`), на кольце радиуса 3 вокруг спавна (в виде песочницы
игрока на спавне), `run=1` — сразу запущен; в очереди фазы 1, лог `spawned_sample account=… name=… eids=…`.

## Песочница (`modules/sandbox.lua`)
Конвейер `TickInput(N)` → `TickResult(N)` применяется в начале N+1; мир не ждёт; больше 3 тактов в полёте — входы
пропускаются (`skipped`); сервис упал — сущности замирают, переподключение каждые 2 с. Транспорты: `jsonl` (как
`sandboxd` сейчас) и `bin` (контракт `olife_proto:sandbox`). Скрипты сущностей — `sandbox/*.lua` (исполняются в
песочнице, не в движке). Отказы возвращаются сущности событием `rejected` в следующем `TickInput`.
**Волна 4b:** настоящий `olife-sandboxd` говорит оба транспорта на одном порту (по первому байту), в лаборатории мост по
умолчанию `bin` (параметр мира `sandbox_proto`, запасной — `jsonl`). Вид в `EntityInput.view_json` склеивается
`sbmeter.encode_view` (с `json.tostring` TickInput стоил 19.4 мс против 4.7). Статус моста — ещё `bytes_out`/`bytes_in`.
Сценарий `olife_sandbox_binary` (+ двойник `olife_sandbox_binary_json`): 500 typical + 2 orbit, 2 бота — на такт TickInput
204.6 КБ (bin) / 211.8 КБ (jsonl), TickResult 37.1 / 99.1 КБ, такт мира p50 9.6 / 14.0 мс (`agents/OLIFE.md` «Волна 4b»).
Через бинарный контракт не приходят метры владельцев сервиса (`TickResult.owners`; по сущностям — приходят) и ответы на
запросы (их нет и в jsonl-мосте). Тарифы (`set_limits`) идут не через мир, а с порта управления сервиса (лаборатория/supervisor).
Волна 3a (`modules/sbmeter.lua`, мост зовёт его хуками):
- На сущность за один TickResult применяется не больше 16 действий (`flood`), а `set_pos`/`set_rot`/`set_vel` — по одному
  (`dup`). Иначе 64 set_pos по 2 блока проходили бы проверку шага по одному и давали телепорт на 128 блоков.
- Вид (`view`) — сущности в 3D-радиусе 6, не больше 8, через сетку с фиксированным порядком обхода (был перебор всех
  пар по XZ, O(n²)).
- TickInput в `jsonl` собирается вручную (`sbmeter.encode_tick`, `table.concat`). `json.tostring` стоил 20–21 мс на
  такт при 500 сущностях, ручная склейка — 2.95 мс (`tools/olife/tests/bench_tickinput.lua`).
- Счётчики: по владельцам и сущностям — накопленные. На каждый применённый TickResult пишется строка в
  `user:export/sandbox_ticks.jsonl` `{tick, at, wall_us, world_ms, in_ms, ph[5], owners: {o: {n, st, fuel, credits,
  moved, applied, rejected, dropped}}}` — после такта, вне измеряемого времени. Строка `status` дополнена полями
  `owners=, sb_ms_avg/max` (время такта сервиса) и `in_ms_avg/max` (сборка TickInput).
- Скрипты: `orbit`, `typical` (как `workload::TYPICAL` sandboxd, но круг проходит через стартовую точку), негативные
  `neg_loop`, `neg_pcall`, `neg_rep`, `neg_membomb`, `neg_find`, `neg_escape`, `neg_flood`, `neg_oprint`.

## Волна 4a: бенчи, редактор, консоль, инструменты (`modules/editor.lua`)
Сущность-бенч — вид 3 с собственным кодом (`code`), статусом `stop|run|error`, консолью (кольцо 64 строки, `cseq`) и
владельцем-аккаунтом; def `olife_client:bench`. Создание — админ-команда `spawn_bench <account> [name] [count]` (в очередь
фазы 1; вывод `spawned_bench account=… eids=…`). Песочнице идёт код бенча (`ED.src`), TickInput — только работающим
(`ED.runnable`; старые `orbit`/`neg_*` без кода — всегда). Run — `load` в сервис (замена), Stop — `unload` + нет TickInput.
- Запросы клиента (`client.yaml` c2s 16–21) → `RequestReply{seq, op, code}`; состояние — `ScriptState` (на открытие и всем
  подписчикам при изменении), консоль — `ConsoleDelta` подписчикам раз в 5 тактов (≤ 16 строк / 4 КиБ, `dropped`; у
  работающего — ещё раз в секунду ради счётчиков). Бирки — `EntityMeta`, захват — `EntityOwnership` сессиям, видящим сущность
  (после её `EntitySnapshot`, до `TickSync`).
- Права: владелец или админ (`Attach.perms` бит 1 или `olife.admins <csv>`); лок — одна сессия на сущность, тайм-аут 60 с без
  запросов держателя; уход сессии снимает её локи, подписки и захваты. Ведро запросов 10/с (20), aim 20/с; каждый запрос —
  в `acct_actions` аккаунта.
- Консоль: `print/oprint/say` бенча — ведро 5 строк/с (запас 10), лишнее — отказ `rate`; ошибка загрузки/исполнения → ERROR.
- GravityGun: луч мира от `origin` клиента (≤ 3 от игрока), коробка ±0.6, досягаемость 8; держит одна сессия; в фазе 3 мир
  ведёт сущность к `глаз + dir·dist` (≤ 1 блок/такт, зона 48), `set_pos/set_vel` песочницы — отказ `held`.
- Реестр: поля бенча (`code`, `status`, `error`, `owner_acct`, `owner_name`, `cseq`, `console`) и `editor{owner_ids, admins}`;
  пишется при изменении не чаще раза в секунду (`save_registry(true)`), а не только по `save`.
- Команды: `spawn_bench`, `bench <eid>` (владелец, статус, длина и FNV-1a кода, позиция, лок, держатель, подписчики, консоль,
  кредиты/топливо/действия за минуту, бирка), `benches`, `olife.admins <csv>`, `editor_status`; `status` дополнен
  `editor(open,save,run,stop,release,tool,grabs,releases,states,deltas,…,refused={код:n})`.

## Файлы
`server_start.lua` — стартовый сценарий; `scripts/world.lua` — события движка; `modules/editor.lua` — бенчи, редактор, консоль,
инструменты (волна 4a); `modules/server.lua` — состояние, такт,
проверки, репликация, админ; `modules/net.lua` — шлюзы, кадры, журнал; `modules/sandbox.lua` — мост; `modules/sbmeter.lua` —
счётчики, проверки действий, вид, кодировщик TickInput, места `spawn_scripted`; `sandbox/*.lua` — скрипты сущностей.
**В паках olife не должно быть блоков**: id блоков в чанках и обновлениях — сырые индексы, `Welcome.blocks` сверяет число.

## Волна 4c: сетевой код (`modules/move_auth.lua`, `snapdelta.lua`, `inventory.lua`)
`--opts "k=v,..."` (`server_start.lua`; в лаборатории параметр `opts` вида `world`, сессия `world_opts`): `snap=delta|full`
(умолчание delta), `inv=1|0` (инвентарь ограничивает ломание/постановку, умолчание 1), `snap_budget=1200`, `keyframe=100`,
`snap_near=24`, `move_burst=10`, `ack_every=4`, `disturb=0`.
- **Движение**: `MoveInput{seq, keys, yaw, pitch, hash}` моделируется на вводе (фаза 1) функцией `olife_proto:movement.step`
  над состоянием сессии (`sess.mv`), позиция сессии = результат. Ответ в фазе 4: `PlayerAck{ack}` (hash клиента совпал; не
  чаще раза в `ack_every` тактов) или `PlayerState{ack, pos, vel, flags}` (не совпал, ввод отброшен, сброс). Ведро вводов —
  20/с реального времени (запас `move_burst`): мир тикает ~19.7/с, пополнение «по такту» отбрасывало честные вводы. Шаг
  длиннее `max_step` (3 бл) откатывается с флагом сброса. `PlayerInput` (позиция) работает как раньше и синхронизирует
  состояние движения. `olife.disturb <тактов>` — стена 2 бл перед каждым идущим игроком (источник неверных предсказаний
  для `olife_prediction`), `olife.move_state` — точное состояние движения каждой сессии (hash, pos, vel, ack).
- **Снимки**: `EntityDelta` по сессии (база = отправленное этой сессии; позиции 1/256 бл, i8/i16/i32; углы u16, каждый
  компонент отдельно; u16-слоты; ключевой кадр раз в `keyframe`; приоритет по возрасту и расстоянию, бюджет `snap_budget`
  байт на сессию и такт, дальние — реже). `olife.snap full|delta`, `olife.snap_budget <байт> [near]` — на ходу. В delta
  `sess.view` указывает на `sess.dview` (ключи — eid).
- **Инвентарь**: движковый инвентарь игрока мира; `InvAction` (1 выбрать слот хотбара, 2 переложить, 3 выбросить),
  постановка расходует предмет выбранного слота (`placing-block` = блок запроса; иначе `BlockReject 7` + `InvReject 5`),
  ломание даёт `picking-item`, выброшенное — сущность вида 4 (`olife_client:drop`), подбор в 1.5 бл, 60 с жизни.
  `InventoryState` — изменённые слоты + hash. Реестр мира хранит инвентари по `аккаунт/имя` (имена предметов).
  `olife.dump_inventory` → `user:export/inventory_world.json` (инвентари, предметы на земле, баланс).
- Счётчики — в `status` (`mv_*`, `snap_*`, `inv_*`) и команда `netcode`.

## Волна 5p: JIT, GC, профиль такта (`agents/research/OLIFE_WORLD_PERF.md`)
`--opts` (в лаборатории `world_opts`): `jit=tuned|on|off|wasm` (умолчание `tuned`: `maxtrace=8000, maxmcode=65536,
hotexit=200, maxside=400, maxsnap=1000` — со стоковыми 1000 трассами кэш мира + base-пака сбрасывался 17–18 раз за 25 с),
`jitopt=k=v;k=v`, `gc=tick|auto` (умолчание `tick`: автоматический GC остановлен, цикл после такта при росте кучи на
1 МБ / 25 %, ≤ `gcbudget` мс (6) за такт, `gcmax` МБ (512) — возврат к автоматическому), `gcpause`, `gcstepmul`;
`prof=1` — `export/world_prof.csv` (строка на такт: фазы и подшаги, рост кучи, GC, события, время между тактами,
`modules/prof.lua`), `jitlog=1` — события трасс LuaJIT (`jit.attach`), команда `olife.jit` → `export/world_jit.txt`.

## UX round 1 (02.10, olife_ux1): настройки, удаление, профайлер, монета
- `EntityEdit` (c2s 22) → `RequestReply` op 7, только владелец/админ (иначе 3): op 1 — удалить (держатель отпускает, лок
  снимается, песочница выгружает, подписки снимаются, `remove_entity` — следующий снимок убирает её у всех; реестр
  пишется сразу), op 2 — имя (`olife_proto:looks.valid_name`, бирка `EntityMeta` всем), op 3 — модель/текстура из
  `olife_proto:looks` (`e.model`, `e.texture`, `look_ver` → `EntityLook` s2c 93 тем, кто видит; в реестре). Плохое
  значение/op — 15. Счётчики `editor(... deleted, renamed, looks, profiles)`.
- `ScriptProfile` (s2c 94) раз в секунду подписчикам (открыт редактор), запущена сущность или нет: итоги песочницы по
  сущности (`sbmeter.ents`: результаты, ошибки, отклонённые действия), отброшенные строки консоли, память VM владельца
  (`sbmeter.svc[owner]`: `lua_heap`, `mem_peak`, `state` — когда сервис их прислал; бинарный контракт пока не шлёт → −1).
- Админ: `sample_reset <account> <name> [slot]` (сухой прогон пути игрока: пример — снова код из `sandbox/samples/<name>.lua`,
  RUN; `slot` ≥ 0 — и обратно на кольцо вокруг спавна), `bench_place <eid> x y z` (тесты / «спасти» бенч); `bench <eid>`
  дополнен `model=`/`texture=`.
- Монета `olife_proto:coin` убрана: стартовый набор — 32 камня и 16 досок. Мир, видевший монету, 0.32 не открывает
  («missing content», headless — abort): `server_start.lua` до `app.open_world` убирает её из `indices.json` текстовой
  правкой (только если она последняя в списке предметов — другие номера не сдвигаются; без пересериализации JSON, пустые
  объекты остаются объектами), исходник — `indices.json.ux1.bak` (один раз).

## UX A1 (03.10, olife_a1): права «как у репозитория», друзья, форк (`modules/perms.lua`)
- **Права сущности** (бенча): на каждое действие — аудитория. Действия: `move` (гравипушка), `read_code` (открыть
  редактор/увидеть код), `edit_code` (лок редактора, Save), `run` (Run/Stop), `appearance` (имя, модель, текстура,
  скелет), `clone` (форк, Спамер A4), `destroy` (удаление), `storage_read`, `storage_write` (хранилище A4).
  Аудитории: 0 `owner` — только владелец, 1 `friends` — владелец и его друзья, 2 `list` — владелец и список аккаунтов
  (≤ 32), 3 `everyone`. Админ (`Attach.perms` бит 1 или `olife.admins`) проходит всё; владелец — всегда.
- **Умолчания** (`perms.DEFAULT`): `read_code = everyone` (код публичен, как открытый репозиторий; редактор и раньше
  открывался всем только для чтения), всё остальное — `owner`. Аккаунт может задать свои умолчания (настройка БД
  supervisor `perms.default`, в мир — `olife.acct_settings`); новый бенч получает копию правил при создании.
  Изменение A1: гравипушка раньше хватала любой бенч — теперь `move` владельца (старые `orbit/neg_*` без кода —
  по-прежнему любой).
- **Проверки в мире** (`perms.allowed(sess, e, action)` -> ok, причина): ScriptOpen (`read_code`; edit — `edit_code`),
  ScriptSave (`edit_code` + лок), ScriptRun/Stop (`run`; лок не нужен, но не должен быть у другого — 4), EntityEdit
  (удаление — `destroy`, имя/вид — `appearance`), ToolUse grab (`move`), EntityFork (`clone`), PermsCheck (любое).
  Отказ — `RequestReply` код 3, `reason` = `forbidden: <action> is for <audience>` (клиент показывает по-русски).
  Для других волн: `perms.allowed` (A4 storenet — `storage_*`), `perms.script_allowed(e, class)` (A3 mobapi: скрипт
  своего бенча — да, кроме классов из настройки аккаунта `script.deny`), `store.snapshot_hooks.perms` (снимок
  Спамера хранит правила).
- **Сообщения** (client.yaml, A1: c2s 40–43, s2c 110–112): `EntityPermsSet` (владелец/админ -> op 8), `EntityFork`
  (op 9 + `EntityForked`), `FriendRequest` (op 10: 1 запрос — встречный превращается в дружбу, 2 принять, 3 отклонить/
  отменить, 4 удалить, 5 список), `PermsCheck` (op 11); `EntityPerms` (правила, `mine` — биты разрешённого этой
  сессии, `can_admin`) — с ScriptOpen, подписчикам при изменении и после изменений дружбы; `FriendList` — при входе,
  на запрос, обеим сторонам при изменении, друзьям при входе/выходе (online). Коды: 15 плохое значение, 16 нет такого
  аккаунта/вы сами, 17 нет такого запроса/не друзья, 18 лимит (друзей 256, исходящих запросов 64, форков 10/мин).
- **Форк**: копия кода, правил, имени (`<имя>_fork`), модели/текстуры (+ KV и активы через `store.fork`, если есть
  A4) — новый бенч запрашивающего, STOP, в 2 блоках перед ним (внутри зоны 48), `forked_from` (eid, владелец, имя,
  fnv кода) в реестре и в `bench <eid>`; строки в консолях обоих.
- **Друзья** — у мира (реестр: пары, запросы, известные аккаунты, умолчания, кольцо событий 128 с `wid` сохранения),
  долговременная копия — БД supervisor (`friends`, миграция 3): события мира `friends_ev` в `sup_state` /
  stdin `friends_ev <since>` -> БД; БД -> мир: `olife.friends <spec>` при старте мира группы, `olife.friend_set` при
  правке оператором (`lab olife friend ...`). Запрос — только к известному миру аккаунту (входил, владелец, из БД).
- **Админ-команды**: `bench_perms <eid> [action audience [a|b]]`, `friends`, `friends_ev [since]`,
  `olife.friends <a+b,c>d,=e>`, `olife.friend_set <a> <b> friend|request|off` (не `none`: консоль 0.32 превращает
  это слово в nil), `olife.acct_settings <account> perms.default=move:friends,clone:everyone;friends.requests=closed;
  script.deny=blocks`. Счётчики — хвост `editor_status` (`perms(set,checks,forks,friend_ops,lists,perms_sent,denied)`).

## UX A2 (03.10, olife_a2): чат, команды оператора, аудит (`modules/ops.lua`)
- **Чат**: `ChatSend` игрока → ведро сессии (`chat_rate` 2/с, запас 5; сверх — отказ и `Notice 8` «chat throttled», код 20, не
  чаще раза в секунду) → `ChatLine{line: ChatEntry{id, tick, ms, kind, role, from_eid, from, text}}` всем (kind 0 игрок /
  1 система (вход/выход) / 2 действие оператора / 3 ответ команды / 4 уведомление; role 0 игрок / 1 админ / 2 мир / 3 оператор).
  Последние 100 строк — в реестре (`ops.lines`, переживают рестарт), опоздавшему сразу после `Welcome` — `ChatHistory`.
  Прежний `ChatMessage` мир больше не шлёт (клиент понимает оба).
- **Команды**: `ChatSend` «/команда …» сессии или stdin `olife.op <rid> <by> <via> "<текст>"` (лаборатория: CLI, панель) — один
  исполнитель. Админ = `editor.is_admin` (бит 1 `Attach.perms` или `olife.admins`), оператор лаборатории — всегда админ.
  Ответ — `OpResult{n, code, cmd, text}` отправителю / строка `op_result rid=… code=… cmd=… text=<json>` в stdout.

| команда | кто | что делает |
|---|---|---|
| `/help` | все | список (игроку — без админских) |
| `/mobs [игрок]` | все (игрок — только свои) | мобы: `#eid имя [владелец] СТАТУС cr/min fuel/min pos` |
| `/who` | все | игроки онлайн (admin, FROZEN) |
| `/kill <моб>` | админ | despawn + забыть (тот же путь, что удаление владельцем, `editor.delete_entity`); владельцу `Notice 3` |
| `/killall [игрок]` | админ | все мобы игрока / все вообще; владельцу `Notice 12` |
| `/freeze`, `/unfreeze <моб\|игрок>` | админ | моб: без TickInput (VM и её состояние целы), бирка FROZEN, `Notice 9/10`; игрок: ввод не двигает (`MoveInput` keys=0, `PlayerInput` → `PlayerCorrect` причина 5), ToolUse/Script*/EntityEdit/BlockAction/InvAction отброшены (`Notice 1`, раз в секунду), его мобы тоже заморожены |
| `/limits <моб\|игрок> [ключ значение\|default]` | админ | `fuel` (fuel_per_tick + tick_cap), `bucket`, `memory` (МиБ, если < 1 МиБ), `actions`, `text` → `set_limits` владельцу в sandboxd (порт управления `--opts sbctl=<порт>`, слияние; после переподключения — всё заново); на МОБЕ `actions`/`text` — лимит мира на этот моб (действий / байт текста на результат, отказ `op limit …`), `fuel/bucket/memory` моба — его владельцу (VM песочницы — на владельца); без ключа — показать |
| `/kick <игрок> [причина]` | админ | `Notice 5`, затем Detach кодом 10 |
| `/ban <игрок> <мин> <причина>`, `/unban` | админ | бан мира по аккаунту (0 мин — навсегда): кик кодом 5 сейчас, вход отклоняется `Detach 5` до срока (реестр) |
| `/tp <кто> <x y z\|игрок\|моб\|here>` | админ | игрок — позиция + `PlayerCorrect` (причина 4) + сброс состояния движения; моб — позиция |
| `/say <текст>`, `/audit [n]` | админ | объявление оператора; последние записи аудита |

  Цель: `#eid`/число (моб или игрок по eid), имя игрока/аккаунт (онлайн, затем известный), имя бенча; `mob:имя`/`player:имя` —
  явно. Ведро команд 4/с (запас 8), сверх — `OpResult` код 9. Коды: 0, 9, 16 не админ, 17 нет команды, 18 аргументы, 19 нет цели,
  20 чат сверх лимита, 21 нет порта управления песочницы (лимит сохранён, не доставлен).
- **Аудит**: каждая админская команда (и отказ по правам 16) — запись `{n, ms, tick, by, account, role, via (chat|cli|panel),
  cmd, args, code, result, target, eids}` в `world:olife_audit.jsonl` (кольцо 2000, переживает рестарт) и `user:export/audit.jsonl`;
  успешное действие — op-строка в чате всем (`[op] froze #3 bmob1 [bob]`).
- **Статус бирки** (`EntityMeta.status`): 0 STOP, 1 RUN, 2 ERROR, 3 THROTTLED (работает, песочница вернула `throttled` в последние
  40 тактов; владельцу `Notice 4` код 20 не чаще раза в 10 с), 4 FROZEN. `editor.shown_status(e)` — общий для бирки и `/mobs`.
- stdin: `olife.op`, `olife.op_state` (→ `user:export/ops_state.json`: мобы, игроки, баны, лимиты, ответы sandboxd, счётчики),
  `ops_status`. Панели supervisor — `sup_state.ops`.

## UX A4 (03.10, olife_a4): хранилище — KV моба, активы владельца, canvas, снимки (`modules/store.lua`, `storenet.lua`)
`store.lua` — стабильный API (сигнатуры в шапке файла): KV `kv_get/kv_set/kv_all/kv_keys/kv_usage`, активы
`put/get/has/info/list/quota/release/share/attach/detach/entity_assets`, `canvas_commit`, `fork`, `snapshot`/`restore`,
`snapshot_hooks`, коды `CODE` (40–49), тарифы `T`. Файлы — `world:olife_store/` (`index.json`, `kv/<eid>.json`,
`cas/<aa>/<sha256>`), запись при изменении ≤ 1/с и на `save`. Память скрипта A3 (`memory.*`) хранится здесь. Действие
песочницы `canvas.commit` (sandbox `CanvasCommit` / JSON `rgba_b64`) -> PNG (`Canvas:encode`) -> CAS владельца -> слот
`tex:*`; скрипту — событие `canvas {slot, sha}` или `rejected {code}`. `storenet.lua`: `AssetUpload`/`AssetOp` ->
`AssetReply`/`AssetList`, `EntityAssets` тем, кто видит сущность, `sup_state.store`.

Команды: `store_status`, `store_quota <acct>`, `store_list <acct>`, `store_kv <eid>`, `store_kv_set <eid> <key> <value>`
(тест: от имени владельца; `nil` удаляет), `store_entity <eid>`, `store_snapshot <eid>` (-> `user:export/snap_<eid>.json`),
`store_restore <src_eid> [acct]`, `store_gc [grace]`, `store_tariff <k> <v>`, `store_tariffs`, `store_canvas_test <eid> <w>
<h> [seed] [slot]`, `store_rgba asset:<sha>` (sha256 RGBA PNG — что должно быть в текстуре клиента), `store_flush`.
Аргумент «голый sha» консоли нельзя: начинающийся с цифры он не `str` (`5a14…` — команда молча не выполняется), поэтому
`asset:<sha>`; путь с `/` — «invalid character», поэтому снимки адресуются eid. Квоты, цены и коды — `agents/OLIFE.md` «UX A4».

## UX A3: API скриптов моба (03.10, агент olife_a3)
`modules/mobapi.lua` — мировая сторона API (`block.*`, вид/скелет/анимация/звук/3D-текст `self:*`, `memory.*`; справочник
вызовов с ценами — `<olife-src>/sandboxd/README.md` «UX A3»). Мост `modules/sandbox.lua`: действия не из ядра
(`Ext{op,json}` бинарного контракта) → `mobapi.apply` (nil = применено, иначе причина → событие `rejected` скрипту);
запросы результата (`queries`/`queries_json`) → `mobapi.queries` → ответы `{ok,v|err}` уходят со следующим TickInput
(бинарно — кадр `Answers` перед ним, JSON-строки — `answers`); `self.fields` (scale/visible/model/anim) — когда менялись;
скрипты грузятся после ответа Hello: сервису с proto ≥ 2 — `LoadKeep` (переменные Lua переживают рестарт мира).
`block.set` получил `state` и право `blocks`. Проверки: масштаб 0.1..4, кости из `olife_proto:mobassets`, модели/текстуры из
`olife_proto:looks` или `asset:<sha>` владельца (`store.has`, A4), звуки `olife/*` (1 раз в 4 такта), анимации VCA пака,
текст ≤ 128 байт, `fill_area` ≤ 4096 блоков в 12 бл (по 32 за такт, 128 на мир, событие `fill_done`), чтение ≤ 24 бл,
≤ 8 запросов на результат. Права: `perms.script_allowed` (A1, настройки аккаунта) и выключатель `olife.api_deny|api_allow
<account> <appearance|anim|sound|blocks|memory|query|*>`. Память — хранилище A4 (`store.kv_*`). Вид хранится в реестре
(`rec.app`) и в снимке Спамера (`store.snapshot_hooks.a3_appearance`); анимация — только текущее состояние; звук — событие.
Репликация (`mobapi.replicate` после `editor.replicate`): `EntityAppearance` (130) при изменении и входе в вид,
`EntityAnim` (131, с временем анимации), `EntitySound` (132) — тем, кто видит сущность в этом такте.
Команды: `mob_api <eid>` (вид, анимация, заливка, память — для тестов), `mobapi_status`, `bench_code <eid> <code>`
(бенч исполняет `sandbox/<code>.lua`), `bench_console <eid> [n]`. Тестовые скрипты: `sandbox/a3_api_test.lua`,
`sandbox/a3_cost_probe.lua`; примеры `sandbox/samples/demo_{spin_scale,texture_swap,sound_collision,block_painter,
memory_counter}.lua` (в мир сами не ставятся: `spawn_sample <account> <имя> <имя> 1`). В строках `export/sandbox_ticks.jsonl`
по владельцу добавлено `api` (кредиты API результата).

## Антифрод и бан по IP (16.10, olife_antifraud) (`modules/fraud.lua`, `ops.lua`)
| команда (админ) | что делает |
|---|---|
| `/ban ip <адрес|CIDR> [минут] [причина] [force]` | бан по IP в БД супервизора (через демон, `--opts sup=`), сразу выбивает сессии с этих адресов здесь и на шлюзах |
| `/unban ip <адрес|CIDR>` | снять |
| `/bans` | баны супервизора (аккаунты, IP/CIDR, автобаны `by fraud`) и мира |
| `/players` (всем) | игроки с адресом: админу — IP полностью, игроку — `a.b.x.x` |
| `/fraud [status|events [n]|clear <игрок|ip:A|nick:N>|set <ключ> <значение|default>|trust <игрок> <x>]` | очки антифрода, события, ручки; `clear` — ложное срабатывание |

Скоринг на аккаунт: события отказа сверх ведра/квоты — чат, команды, блоки, запросы редактора/инструментов (`req_b`), спавн
(`spawn_per_min`), переподключения сверх 3 за минуту; затухание (полураспад 30 с); пороги × доверие: 10 — Notice 13 (тост +
звук), 20 — Notice 14 и throttle 15 с (чат/блоки/запросы отбрасываются и тоже считаются), 35 — kick 10 «antifraud: …», 50 —
бан аккаунта (мир + `olife.fraud report` → БД со сроком по страйкам; второй — и IP). Адреса `exempt` (127.0.0.1) — только
предупреждение. Настройки/доверие/снятия — с супервизора раз в 5 с. stdin: `olife.fraud_state` (→ `user:export/
fraud_state.json`), `fraud_status`.
