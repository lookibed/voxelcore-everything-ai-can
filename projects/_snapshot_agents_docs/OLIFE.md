# Olife на VoxelCore 0.32 — состояние проекта

Olife — «Garry's Mod для VoxelCore»: сервер мира на headless VoxelCore, игроки через шлюз, программируемые сущности
в отдельной песочнице с тарификацией. Решения и обоснования — `agents/research/OLIFE_ASSESSMENT.md` (что было не так
в прототипе 0.30.6), `OLIFE_ARCHITECTURE.md` (компоненты, потоки, «VoxelCore как чистый симулятор» §4),
`OLIFE_SANDBOX.md` (рантайм песочницы, мост TickInput/TickResult). Прототип песочницы — `/root/olife/sandboxd`
(Rust + wasmtime + Lua 5.1 в wasm, отдельный агент).

## Где что
| часть | путь | README |
|---|---|---|
| схема протокола (3 контракта) | `tools/olife/protocol/*.yaml` | `tools/olife/README.md` |
| генератор кодеков Lua + Python | `tools/olife/gen_codecs.py` → `content/olife_proto/modules`, `tools/olife/olife_proto` | там же |
| мир (сервер) | `content/olife_world` (+ `server_start.lua`) | `content/olife_world/README.md` |
| клиент / бот | `content/olife_client` (+ `client_start.lua`) | `content/olife_client/README.md` |
| dev-шлюз (эталон поведения) | `tools/olife/gateway_dev.py` | `tools/olife/README.md` |
| **шлюз прод (Rust, волна 3c)** | `/root/olife/gateway` (исходники, кодеки — `gen_codecs.py --lang rust`) → `D:\Prog\Olife\gateway\olife-gateway.exe`; вид лаборатории `gateway_rs`, `lab run olife <сценарий> --impl rs` | `/root/olife/gateway/README.md` = `D:\Prog\Olife\gateway\README.md`; безопасность — `agents/research/OLIFE_GATEWAY_SECURITY.md` |
| **песочница (настоящая, волна 3a)** | `/root/olife/sandboxd` (исходники) → `D:\Prog\Olife\sandboxd\olife-sandboxd.exe` (Windows) | `/root/olife/sandboxd/README.md`, `D:\Prog\Olife\sandboxd\README.md` |
| скрипты сущностей (код песочницы) | `content/olife_world/sandbox/*.lua` (orbit, typical, neg_*) | `content/olife_world/README.md` |
| песочница-заглушка (бинарный контракт) | `tools/olife/sandbox_stub.py` (вид `sandbox_stub`) | `tools/olife/README.md` |
| негативные тесты протокола | `tools/olife/negative.py` | там же |
| **слой игрока (волна 4a)**: редактор кода сущности, консоль, Injector/GravityGun | мир `content/olife_world/modules/editor.lua`; клиент `content/olife_client/modules/olife.lua`, `layouts/editor.xml(.lua)`, предметы `injector`/`gravity_gun`, сущность `bench`; тесты `tools/lab/projects/olife/editor_w4a.py`, `tools/olife/editor_neg.py`; сценарии `olife_editor`, `olife_gravity`, `olife_restart_editor` | READMEs паков, `tools/olife/README.md` |
| **билеты (волна 4b)** | `tools/olife/olife_ticket.py` (спецификация), `auth_service.py` (сервис, вид `auth`), `ticket_check.py`; клиент `content/olife_client/modules/auth.lua`; Rust `/root/olife/gateway/src/ticket.rs` | `agents/research/OLIFE_GATEWAY_SECURITY.md` §7 |
| **паки на лету (волна 4b)** | `content/olife_client/modules/packs.lua`, `PacksChanged` (client.yaml id 75), шлюзы `--packs-manifest` | `content/olife_client/README.md` «Волна 4b» |
| **тарифы → песочница (волна 4b)** | `tools/lab/projects/olife/olife_w4b.py` (`limits.*` → ctl `set_limits` sandboxd) | `tools/lab/README.md` «Olife, волна 4b» |
| **сетевой код (волна 4c)**: предсказание движения, дельты снимков, инвентарь | общее `content/olife_proto/modules/{movement,items}.lua` (предмет `olife_proto:coin` убран в UX round 1); мир `content/olife_world/modules/{move_auth,snapdelta,inventory}.lua`; клиент `content/olife_client/modules/{predict,entdelta,invmirror}.lua`; инжектор задержки `gateway_dev.py` (`--rtt-ms`, ctl `latency`); лаборатория `tools/lab/projects/olife/netcode.py`, сценарии `olife_prediction`, `olife_delta`, `olife_inventory`, `olife_load_legacy` | READMEs паков, `tools/olife/README.md` |
| **UX round 1 (02.10, olife_ux1)**: замечания пользователя 1–6 | редактор `content/olife_client/{layouts/editor.xml(.lua),layouts/olife_hud.xml,modules/olife.lua}`, ассеты пользователя `content/olife_client/{models,textures,sounds,fonts}`, `content/olife_proto/modules/looks.lua`; мир `editor.lua` (`EntityEdit`, `EntityLook`, `ScriptProfile`, `sample_reset`, `bench_place`), `server_start.lua` (миграция `indices.json`); схема `client.yaml` 22/93/94; шаг `olife_play_ux` (`olife_play.py`) | READMEs паков, `D:\Prog\Olife\README-play.md` |
| **UX A1 (03.10, olife_a1)**: права «как у репозитория», друзья, форк | мир `content/olife_world/modules/perms.lua` (+ хуки в `editor.lua`, `server.lua`); клиент `modules/olife.lua` (панель прав, форк, друзья), `layouts/editor.xml` (Настройки), `layouts/friends.xml(.lua)`; схема `client.yaml` c2s 40–43 / s2c 110–112; БД supervisor `friends`, `account_settings` (`labcore/supervise.py`, миграция 3), `lab olife friend|settings`; лаборатория `tools/lab/projects/olife/olife_a1.py`, `tools/olife/perms_neg.py`, сценарии `olife_perms`, `olife_fork` | READMEs паков, `tools/olife/README.md`, `tools/lab/README.md` «Olife: UX A1» |
| лаборатория | `tools/lab/projects/olife` (виды world/gateway/sandbox/client/bot/vctest, плагин v3, 7 сценариев) | `tools/lab/README.md` «Этап 4» |
| **UX A3 (03.10, olife_a3)**: API скриптов моба (block / вид, скелет, анимация, звук, 3D-текст / memory) | мир `content/olife_world/modules/mobapi.lua` (+ мост `sandbox.lua`: Ext/Answers/LoadKeep, хуки `server.lua`, `sbmeter.lua` поле `api`), общий `olife_proto:mobassets`; клиент `modules/mobview.lua`, `animation/*.vca`; песочница `/root/olife/sandboxd` (`prelude.lua`, `service.rs` LoadKeep + `--state-dir`, `binproto.rs`, цены `protocol.rs`); схема `sandbox.yaml` Ext/Answer(s)/LoadKeep, `client.yaml` s2c 130–132; лаборатория `olife_a3.py`, сценарий `olife_script_api` | `/root/olife/sandboxd/README.md` «UX A3» (справочник), READMEs паков, ниже «UX A3» |
| **UX A4 (03.10, olife_a4)**: KV моба, активы владельца (CAS), раздача, canvas, снимки | мир `content/olife_world/modules/{store,storenet}.lua`; клиент `content/olife_client/modules/assets.lua`; песочница canvas; шлюзы `--assets-dir`; лаборатория `store_a4.py`, сценарий `olife_store` | READMEs паков, ниже «UX A4» |
| **путь игрока (02.10, olife_play)**: `lab play olife --user`, `--dry-run`, `lab olife play-up/down`, меню «Сценарии» -> olife | лаборатория `tools/lab/projects/olife/{olife_play.py,play_stack.py}`, виды `world_play/play_stack/runtime/play_client/menu_client`, `[play]`, сценарий `olife_play_dry`; клиент `content/olife_client/{modules/play.lua,scripts/app/olife.lua}`; мир `spawn_sample`, `content/olife_world/sandbox/samples/*.lua`; `D:\Prog\Olife\play.bat`, `D:\Prog\Olife\play\` | `D:\Prog\Olife\README-play.md` (пользователю), `tools/lab/README.md` «Olife: путь игрока» |
| **UX B (16.10, olife_menu)**: меню клиента (3D-сценка, ip:port + ник), экран статуса входа, вайтлист по нику | клиент `content/olife_client/{scripts/app/olife.lua, layouts/pages/olife_menu.xml(.lua), layouts/pages/olife_status.xml(.lua), layouts/olife_status.xml(.lua), modules/{menu,status,status_view,login}.lua, models/olife_menu_scene.vcm}` (+ `client.lua` prelude/adopt, `packs.lua` check/fetch/stage, `auth.lua` ник, `play.lua` run_world); генератор сценки `tools/olife/gen_menu_scene.py`; сервис билетов `tools/olife/auth_service.py` (вход по нику); мир `ops.lua` `/whitelist`; лаборатория `tools/lab/projects/olife/olife_menu.py`, виды `menu_app`, сценарии `olife_menu_status`, `olife_menu_whitelist`, CLI `lab olife whitelist` (`labcore/cli_sup.py`), панель (`labcore/supervise.py`, после upgrade) | README пака «UX B», `tools/lab/README.md` «Olife: UX B», ниже «UX B» |
| **Антифрод и бан по IP (16.10, olife_antifraud)** | плагин `tools/lab/projects/olife/olife_fraud.py` (`_fraud()` в plugin.py; `olife.ip_check`, `olife.gw_sync`, `olife.fraud`, `olife.ban --ip`); сервис билетов `auth_service.py`; шлюзы `gateway_dev.py`, Rust `src/{bans,auth,gateway,admin}.rs`; мир `content/olife_world/modules/fraud.lua` (+ `ops.lua` `/ban ip`, `/unban ip`, `/bans`, `/players`, `/fraud`); клиент `login.lua`, `status.lua`, `chat.lua`, `fx.lua`, `client.lua`; пробы `tools/olife/fraud_check.py`; CLI `lab olife fraud|bans|ban --ip`; панель (секция Antifraud, после upgrade); сценарии `olife_ipban`, `olife_antifraud` | `agents/research/OLIFE_ANTIFRAUD.md`, ниже «Антифрод и бан по IP» |
| **UX A2 (03.10, olife_a2)**: чат, команды оператора, аудио-визуальная обратная связь | мир `content/olife_world/modules/ops.lua` (+ хуки `server.lua`, `editor.lua` `shown_status/delete_entity`, `sandbox.lua`); клиент `modules/{chat,fx}.lua`, `layouts/chat.xml(.lua)`, `chat_feed.xml(.lua)`, звуки `sounds/olife/fx_*.wav` (`tools/olife/gen_sounds.py`); схема `client.yaml` s2c 120–123; лаборатория `olife_a2.py` (`olife.op`, `olife.mobs`), CLI `lab olife op|mobs|freeze|…` (`cli_sup.py`), панель `labcore/supervise.py` (секция Operator), `tools/olife/chat_probe.py`, сценарии `olife_chat`, `olife_op` | READMEs паков, `tools/olife/README.md`, `tools/lab/README.md` «Olife: UX A2» |
| **игра с друзьями по сети (16.10)** | публичный режим `play_up {public}` + `tools/lab/projects/olife/olife_public.py` (`lab olife ip`, `invite`, `bundle`), клиент `content/olife_client/modules/serverinfo.lua`, `D:\Prog\Olife\play.bat` (`public`, `friend`, `ip`, `bundle`) | `agents/research/OLIFE_PUBLIC_PLAY.md`, `D:\Prog\Olife\README-play.md` «Игра с друзьями по сети» |

## Что работает (волна 2, 02.10, агент olife_w2)
- **Протокол из схемы**: кадр `magic|version|type|len`, big-endian, жёсткий лимит, без эвристик; три контракта с
  версиями и своими magic; кодеки — сгенерированный прямой код (Lua: Bytearray; Python: struct), строгие проверки в обе
  стороны. Векторы Python ↔ Lua побайтно совпадают (132 вектора, 815 проверок в движке 0.32).
- **Мир авторитетен**: игроки (позиция проверяется, поправка `PlayerCorrect`), блоки (досягаемость, частота, загрузка,
  видимость → `BlockReject` с откатом; рассылка после применения и чтения назад), сущности с серверными eid (единственное
  пространство id), чат с лимитом. Свой планировщик 20 Гц в `on_world_tick`, порядок фаз из ARCHITECTURE §4,
  время фаз в `status`. Шлюзу мир не доверяет (повторный разбор тела, секрет, версии).
- **Репликация**: чанки — байты `world.get_chunk_data` по интересу (радиус 3 чанка, ≤ 4 за такт), кэш 256; изменения
  блоков — `BlockUpdate` держателям (общий `Multicast`); сущности — снимки с dirty-полями по интересу; `TickSync` с
  hash вида каждой сессии. Изменения мира самим сервером (без события в движке) — перехеширование чанков по кругу +
  повторный `ChunkData`; сущности движка (падающий песок) — `on_entity_spawn/despawn`.
- **Шлюз** (dev): рукопожатие, статические токены, баны, лимиты, keepalive с challenge, мультиплекс сессий в одно
  соединение с миром, `Multicast`, метрики, кик/бан по порту управления, переподключение к миру.
- **Песочница**: мост в мире (оба транспорта: jsonl `sandboxd` и бинарный контракт), проверка действий, отставание,
  переподключение; заглушка на Windows; формат запросов мира проверен на **настоящем** `olife-sandboxd` (повтор 128
  запросов: 2/2 load ok, 125 тактов, 250 `ok`, шаги set_pos ≤ 0.2).
- **Клиент**: бот (headless) и оконный F2F 0.32 одним сценарием; чанки с чтением назад, блоки, сущности с
  интерполяцией, ввод 20 Гц по часам, F2F `state`.
- **Админ** `--stdin-cmd`: `status`, `players`, `kick <eid>`, `save`, `journal [n]` (кольцо 256 входящих кадров),
  `olife.dump_blocks`, `olife.stop`. Реестр сущностей и позиции игроков переживают рестарт мира.

## Цифры (02.10, стоковый 0.32 headless, ПК свободен по `lab sysload`; сценарии лаборатории)
| сценарий | состав | тактов мира | сравнено тактов | расхождений | задержка TickSync p50/p95, мс | байт вниз / вверх (шлюз) |
|---|---|---|---|---|---|---|
| `olife_consistency` | мир + шлюз + песочница + 2 бота | 340 | 520 | **0** | 23.4 / 40.2 | 200 606 / 20 226 |
| `olife_load` | 6 ботов, блоки раз в 20 тактов, песочница | 620 | 2 729 | **0** | 16.1 / 48.3 | 996 841 / 109 110 |
| `olife_blocks` | 3 бота, блоки раз в 5 тактов | 480 | 1 138 | **0** | 33.9 / 46.2 | 354 552 / 49 302 |
| `olife_sandbox_bin` | 2 бота, песочница по бинарному контракту | 300 | 440 | **0** | 41.5 / 47.2 | 181 843 / 17 203 |
| `olife_clients_f2f` | 2 оконных клиента F2F 0.32 | 240 | 317 | **0** | 4.4 / 7.4 | 166 296 / 12 823 |
| `olife_negative_proto` | 1 бот + 25 негативных случаев | 310 | 250 | **0** | 22.1 / 49.7 | 96 255 / 36 486 |

- Задержка TickSync = приём клиентом − отправка миром (одни часы). У бота это в основном фаза двух циклов 20 Гц (бот
  читает сокет раз в свой такт): 0–50 мс; оконный клиент читает каждый кадр — p50 4.4 мс. Мир → шлюз: p50 0.2–0.5 мс,
  p95 < 1 мс. RTT keepalive у бота p50 ≈ 25 мс (та же фаза), у оконного 3.6 мс.
- Такт мира (6 ботов, 11 сущностей): avg 1.08 мс, p95 1.47, max 2.32 мс при бюджете 50; по фазам avg
  0.10 / 0.07 / 0.49 / 0.30 / 0.08 мс (вход / песочница / мир / репликация / отправка; «мир» — в основном FNV чанков в Lua).
  tps 19.7. Старт: мир 2.23 с до `ready`, бот 2.24, шлюз и песочница ≈ 0.53, оконный клиент 0.9–1.1 с.
- Байты мира (6 ботов, 30.6 с): 1.0 МБ вниз, из них снимки сущностей 549 КБ, чанки 289 КБ (327 чанков, ≈ 0.9 КБ/чанк
  сжатыми данными `base:demo`), TickSync 54 КБ, блоки 2.5 КБ. Вверх 109 КБ (≈ 20 PlayerInput/с на бота).
- Блоки: 186 принято, 10 отказов «досягаемость» (`blocks_rej={1:10}`); после `olife.quiet` все 3 бота сверили 160
  изменённых миром позиций со своими мирами — 160/160 совпало, 0 незагруженных. Чтение назад: 525 изменений у ботов —
  0 несовпадений; чанки 180/180 побайтно равны присланным.
- Песочница: jsonl — 610 входов, 609 результатов, 0 опозданий, 2448 действий применено, 0 отказов; bin — 1192/0.
- Негативные: 25/25 (таблица в `tools/olife/README.md`), мир, шлюз и бот живы, законный вход после всего проходит;
  затем `players`, `journal 5`, `save` (реестр записан), `kick 6` (бот получил Disconnect), `status` → `sessions=0`.
- Кодеки: `EntitySnapshot` из 100 обновлений (3019 Б) — 0.058 мс кодирование, 0.159 мс декодирование (Lua, 0.32).
- Тесты лаборатории без движка: 89 passed / 15 skipped (весь `tools/lab/tests`), с движком `test_vctest_engine` 3/3.

## Supervisor (волна 3b, 02.10, olife_w3v) — `tools/lab/README.md` «Этап 6»
- Ядро `tools/lab/labcore/supervise.py` (общее): службы поверх аренд, health (stdin+шаблон, F2F, LISTEN-порт), перезапуск
  той же аренды с бэкоффом и пределом, инциденты `<data>\incidents\`, БД `supervisor.sqlite` (аккаунты, баны, счётчики,
  тарифы, инциденты, события, входы; миграции), `/sup/auth`, `/sup/bans`, `/sup/state`, `/sup/panel`, манифест паков.
- Olife в плагине: `lab olife up|down|status|players|kick|ban|unban|tariff|incidents|packs manifest|restart|kill`; порядок
  мир → песочница → шлюз; песочница перезапущена → миру `sandbox_reconnect`; мир упал → шлюз закрывает сессии кодом 9
  «world restarting (supervisor)» → боты (`--reconnect S`) возвращаются со свежей репликой; снимок мира раз в секунду
  (`--journal-every 20`) даёт инциденту последние 256 входящих кадров и последний TickResult; учёт байт/пакетов/действий/
  топлива/сущностей и кредиты по тарифу (меняется без рестарта); шлюз берёт токены и баны из БД (файлы — запасной путь),
  отдаёт манифест и файлы паков по HTTP.
- `olife_restart` (стоковый 0.32 headless, 2 бота, заглушка песочницы): убит мир → готов через 3.32 с (бэкофф 1.0, старт
  2.23), мир со своего сохранения, оба бота `reconnects=1 self_div=0`; инцидент — 256 кадров (последний: такт 300, Data/
  PlayerInput 38 Б, снимку 1.0 с), последний TickResult такт 299; убита песочница → готова через 1.73 с, мир `connected`;
  бан в БД → разрыв ≤ 2 с, без переподключения. Тесты без движка 9/9.
- Не сделано: сообщение протокола «мир перезапускается, держитесь» (сейчас разрыв с причиной), уведомление клиентов о
  смене манифеста и загрузка паков клиентом, хранилище по аккаунтам (сейчас только размер сохранения мира `_world`),
  сущности по аккаунту (мир знает числовой `owner`, счётчики — `owner:<n>`), группы не переживают рестарт демона
  (аренды умирают с ним; БД и инциденты остаются).

## Волна 3a: настоящая песочница в сессии (02.10, агент olife_w3s)
- **Windows-сборка `olife-sandboxd`**: кросс-сборка из WSL `x86_64-pc-windows-gnu` (mingw-w64 из apt) в общий
  `/root/olife/sandboxd/target`, раскладка `scripts/deploy_windows.sh` → `D:\Prog\Olife\sandboxd` (exe со strip ≈ 16 МБ,
  wasm 221 КБ, тесты, `driver.py`, README). `cargo test` под Windows 15/15, `driver.py all` из `C:\Python313` PASS
  (negative 11/11; нагрузка 50×10 через протокол 3.99 мс/такт сервиса, p99 5.73). Хэши памяти владельцев в determinism
  совпадают с Linux-сборкой байт в байт. Под Windows нашли и исправили грабля: wasmtime без CoW-образа памяти
  списывает топливо за инициализацию данных при `instantiate`, при нуле топлива — trap (LESSONS).
- **Лаборатория**: вид `olife.sandbox` = настоящий сервис (JSON-строки по TCP на порту `sb` — это общий язык мира и
  `sandboxd` без доработок; бинарный контракт остался за заглушкой `sandbox_stub` и сценарием `olife_sandbox_bin`).
  Здоровье — `hello` на порту управления `--ctl` (протокол F2F), счётчики — `lab call olife.sandbox_meters
  '{"session":…, "entities":true}'` (время такта сервиса; по владельцам и сущностям: такты, топливо, кредиты, действия,
  отброшенные, статусы, kills). Код — `tools/lab/projects/olife/sandbox_real.py` (подключён к plugin.py тремя строками).
- **Мир** (`content/olife_world`): админ-команды `spawn_scripted <code> [owner count owners]` (скрипт
  `sandbox/<code>.lua`, сущности по сетке шагом 4 в 3 слоя, загрузка в песочницу сразу) и `olife.sandbox_dump`
  (`export/sandbox_entities.json`: по владельцам и сущностям — статусы, топливо, кредиты, применено/отклонено миром,
  последний текст/ошибка, kills); строки по тактам `export/sandbox_ticks.jsonl` (на каждый применённый TickResult — по
  владельцам n/статусы/топливо/кредиты/сдвинуто/применено/отклонено + время такта и фазы мира; пишутся после такта).
  Новые проверки моста: не больше 16 действий на сущность за результат (`flood`), set_pos/rot/vel — по одному (`dup`;
  иначе 64 set_pos по 2 блока = телепорт на 128 блоков). Вид песочнице — 3D-радиус 6, не больше 8, через сетку
  (был перебор всех пар O(n²) по XZ). TickInput кодируется вручную (`sbmeter.encode_tick`): `json.tostring` стоил
  20–21 мс на такт при 500 сущностях (351 КБ), ручной — 2.95 мс (303 КБ), замер `tools/olife/tests/bench_tickinput.lua`.
- **Сервис** (правки в `/root/olife/sandboxd`): многосоединительный TCP + `--ctl`, накопленные `Totals`, текст
  `print/oprint/say` режется до 1024 байт, не больше 4096 байт текста на сущность за такт (поток 64×1 КБ `oprint` стоил
  миру до 16 мс на такт), загрузка в замороженного владельца откладывается (раньше: «owner is frozen» → мир терял
  сущность), топливо до инстанцирования (Windows).

| сценарий (02.10, ПК занят: другие агенты и пользователь — **не чистый замер**) | итог |
|---|---|
| `olife_sandbox_real`: мир + шлюз + sandboxd + 2 бота; orbit×2 (owner 1), `spawn_scripted` orbit×2 (2), typical×3 (3, 4) | ok за 24 с: 450 TickResult, контрольные владельцы 1–4 обновлены в **каждой** строке после прогрева (429/228/226/226, 0 плохих), 5784 действий применено, 0 отказов; счётчики мира и сервиса — 10 сущностей / 4 владельца с обеих сторон; такт мира p50 0.95 / p95 1.72 / max 3.59 мс, сервиса p50 0.27 / p95 0.37 / max 1.07 мс; топливо на сущность-такт 67–84 тыс. (orbit / typical), 16–30 кредитов на такт владельца; согласованность 725 тактов, 0 расхождений |
| `olife_negative` (ниже) | ok за 30 с, 16/16 ожиданий, мир/шлюз/песочница/бот живы |
| `olife_sandbox_load`: 500 typical (50 владельцев × 10) + 2 бота, 25 с | ok: такт мира mean 13.2 / p50 13.3 / p95 17.4 / max 23.5 мс (до ручного кодировщика — 32.3 / 38.4 / 53.3); фазы mean: разбор TickResult и применение 5.8 (`json.parse` 139 КБ ≈ 3.1 мс), TickInput 5.0, репликация ≈ 1.7, мир 0.45; сервис mean 4.76 / p95 5.55 / max 6.4 мс (4 потока); tps 19.7; 496 978 действий применено, 0 отказов; late 1, skipped 3 из 496; топливо на сущность-такт p50 145.5 тыс. (130–147 тыс.), кредиты на такт владельца p50 160 (145–162); контрольные владельцы 1/25/50 — 0 плохих строк |
| регресс на настоящей песочнице: `olife_consistency`, `olife_load`, `olife_blocks`, `olife_negative_proto`; `olife_sandbox_bin` (заглушка) | все ok; consistency 340 тактов / 520 сравнено / 0 расхождений, load 620 / 2729 / 0 |

**Негативные тесты на настоящем рантайме** (`olife_negative`, 20 с ≈ 400 тактов; у каждого нарушителя свой владелец, у
большинства ещё сосед-orbit того же владельца; контроль — владельцы 1 и 2):
| случай | владелец | статусы сущности за прогон | итог | соседи / другие владельцы |
|---|---|---|---|---|
| `while true do end` | 10 | throttled ×410 (ни одного ok) | вытеснена каждый такт ровно на свою долю бюджета (822 М топлива ≈ 2 М/такт) | сосед ok ×409 |
| бесконечный цикл в `pcall` | 11 | killed ×1, далее dead | «cpu budget exceeded in non-preemptible code» | сосед ok ×407 |
| `string.rep("x", 2^30)` | 12 | error ×1 («not enough memory»), далее dead | VM владельца жива | сосед ok ×404 |
| бомба памяти (таблица строк по 1 МБ) | 13 | throttled 1, frozen 16, killed (жёсткий потолок 10 тактов / 81 М топлива), restored | склейка 1 МБ — C-код без точек хука: заморозка → kill → откат VM | сосед frozen 8 → restored → ok ×393 |
| `string.find` с бэктрекингом в C | 14 | frozen 17 → killed, restored, kills=1 | откат VM владельца к чекпойнту | сосед frozen 8 → ok ×391 |
| `os/io/debug/require/load/dofile/loadfile/getfenv/setfenv/newproxy/string.dump/module/package`, байткод через `loadstring`, запись в `string`, `rawset`, метатаблица строк, `os.execute`, `io.open`, `loadstring("return os.execute")` | 15 | ok ×398 | `ESCAPE_BLOCKED checks=20` (0 утечек), канарейка не создана | — |
| 100 действий за такт (70 set_pos-цепочкой + 30 print) | 16 | ok ×397 | сервис отбросил 14 292 (36 за такт), мир отклонил 25 011 (`dup` 5955, `flood` 19 056) — сущность двигается не больше чем на шаг за такт | — |
| поток `oprint` 100 × 4000 Б за такт | 17 | ok 64, throttled 332 | текст ≤ 1024 Б, сервис отбросил 6189, мир — 240 (`rate`) | сосед ok ×395 |
| **контроль** orbit×2 / typical×2 | 1 / 2 | ok ×1092 / ×822 | обновлены в **каждой** из 526 / 391 строк после прогрева (0 плохих) | — |

Такт мира за прогон: p50 1.34, p95 2.33, **max 3.33 мс** (< 5 мс), TickInput p95 0.35 мс; сервис p50 0.80, p95 1.08,
max 10.4 мс (такт заморозки/отката); 547 TickResult, late 0, skipped 0. До лимита текста на сущность поток `oprint`
поднимал такт мира до 16.3 мс (такты, где 64 текста по 1 КБ доходили до мира: +1.4 мс в среднем) — лимит
`max_text_bytes` (4096) снял пик до 3.5 мс.

**Перф-замер на свободном ПК** (`lab perf olife sandbox_load --param tag='"w3s"'`, ворота простоя) — **не выполнен,
ПК занят**: 30 мин ожидания простоя (чужие процессы движка, аренды и soak-прогон шлюза другого агента, ввод пользователя),
задание отменено 06:23 по указанию координатора. Повторить, когда ПК свободен. Все числа выше сняты при занятом ПК (другие агенты держали аренды, GPU 16–50 %,
пользователь работал) и чистыми не являются.

## Волна 3c: прод-шлюз `sockets_auth` на Rust (02.10, агент olife_w3g)
- **Кодеки из той же схемы**: `gen_codecs.py --lang rust` → `/root/olife/gateway/src/proto` (`wire.rs` + модуль на контракт:
  типизированные структуры, `enum Msg`, строгие проверки как в Python/Lua). 132 вектора побайтно (кодирование из JSON,
  разбор, перекодирование) — Linux и Windows; фазз-паритет Python↔Rust на 30 000 мутированных телах — 0 расхождений
  (4808 приняты, 25 192 отвергнуты одинаково).
- **Сервис (tokio)**: рукопожатие/токены (`AuthProvider`: файл — в памяти только SHA-256; supervisor этапа 6 —
  `GET /sup/auth?token_sha=`, `GET /sup/bans`, запасной — файл), баны (файл + supervisor + временные IP), лимиты сессии
  как у эталона, keepalive с CSPRNG-challenge, один мультиплексный канал к миру (Data/Multicast без перекодирования),
  медленный клиент (16 МиБ или запись > 15 с) отключается и не тормозит мир; новое: лимиты соединений на IP/шлюз, неудачи
  входа → бан IP, админ HTTP 127.0.0.1 (`/status /sessions /kick /ban /drain`, `X-Admin-Token`), порт управления лаборатории,
  журнал JSONL, плавная остановка (код 1 всем, Detach миру, ≤ 1.5 с). Коды `Disconnect` 1–12 те же, 13 — новые лимиты.
- **Сценарии `--impl rs` (02.10, ПК занят другими агентами)**: `olife_consistency` 340 тактов / 520 сравнено / 0 расхождений,
  `olife_load` 620 / 2724 / 0, `olife_blocks` 162/162 блока у 3 ботов, 1137 / 0, `olife_negative_proto` 25/25 — **таблица кодов
  совпадает с gateway_dev.py по всем 25 случаям**, байты сценария те же (96 117 вниз / 36 486 вверх). Мир→шлюз (TickSync)
  p50 0.11–0.29 мс у Rust против 0.19–0.45 мс у эталона в тех же прогонах.
- **Пропускная способность** (`olife_gw_throughput`: мир-заглушка `world_fake.py`, боты `gw_load.py` 55 PlayerInput/с при лимите
  60 + чат каждые 20 сообщений с рассылкой всем; ПК занят — ориентир, чистый замер — `lab perf olife gateway_load` ниже):

  | ботов | вверх, сообщ/с | вниз, сообщ/с | шлюз | CPU (% ядра) avg / p95 | private, МБ max | потоков | TickSync до бота p50 / p95 / p99, мс | мир→шлюз p50, мс |
  |---|---|---|---|---|---|---|---|---|
  | 50 | 2 726 | 7 672 | Rust | 2.9 / 6.2 | 11.7 | 9 | 0.15 / 0.63 / 0.90 | 0.026 |
  | 50 | 2 726 | 7 675 | gateway_dev.py | 34.3 / 48.3 | 29.8 | 113 | 1.02 / 1.89 / 2.57 | 0.40 |
  | 100 | 5 354 | 28 021 | Rust | 14.6 / 26.5 | 20.5 | 6 | 0.41 / 1.93 / 3.11 | 0.022 |
  | 100 | 5 347 | 27 988 | gateway_dev.py | 129.8 / 154.0 | 42.0 | 213 | 2.44 / 4.67 / 5.96 | 0.85 |
  Ничего не отброшено у обоих: все боты закончили `Bye`, отказов нет, отправлено 102–104 % плана.
- **Замер на свободном ПК** (`lab perf olife gateway_load --param impl=rs|py --param bots=100 --param seconds=30 --param
  chat_every=20`): Rust — **не contended**: 5 349 вверх / 28 016 вниз сообщ/с, CPU 8.0 % ядра (p95 18.7), private max 20.6 МБ,
  9 потоков, TickSync до бота p50 0.34 / p95 1.76 / p99 2.76 мс, мир→шлюз p50 0.022 мс. gateway_dev.py — оба прогона
  **contended** (посторонние процессы 18.9 %, в основном vmmem/WSL ≥ порога 15 %), поэтому только ориентир: 5 355–5 358 /
  28 058–28 081 сообщ/с, CPU 126–138 % ядра (p95 156–176), private max 41.7–41.8 МБ, 213 потоков, TickSync p50 2.35–2.62 /
  p95 4.60–4.95 мс, мир→шлюз p50 0.69–0.70 мс. Те же цифры, что в прогонах сценария выше (разброс ≤ 10 %).
- **Выдержка 10 мин** (`olife_gw_soak`: настоящий мир + 6 ботов + 20 протокольных ботов по 20/с, 26 сессий): Rust — private
  8.45 → 8.62 МБ (медианы первых/последних 10 % после прогрева, +2.1 %, наклон 0.0085 МБ/мин; первый прогон +3.1 %),
  RSS 9.8 → 10.0 МБ, CPU 0.66 %, 9 потоков, TickSync до бота p50 0.83 / p95 1.34 мс (235 176 замеров), согласованность мира
  и 6 ботов 72 630 тактов / 0 расхождений; gateway_dev.py — private 25.7 → 25.8 МБ, RSS 31.8 → 32.1 МБ, CPU 5.95 %,
  65 потоков, TickSync p50 1.87 / p95 2.88 мс, согласованность 72 710 / 0.
  Память стабильна у обоих. Шаг `olife_status` после 10 мин падает у обоих — ошибка ядра лаборатории (`lab stdin` на логе
  > 512 КиБ, LESSONS), шаг сделан `optional`.
- Безопасность рукопожатия (повтор, тайминги, хранение токенов) и путь к TLS/QUIC — `agents/research/OLIFE_GATEWAY_SECURITY.md`.
  Главное: токен в `Hello` — открытый bearer, повтор возможен; у клиента 0.32 есть HTTPS, но игровые сокеты без TLS →
  следующий шаг — короткий одноразовый билет через HTTPS вместо токена (схема не меняется), затем Noise в паке.

## Волна 4a: слой игрока — редактор, консоль, Injector/GravityGun (02.10, агент olife_w4a)
Всё решает мир (`content/olife_world/modules/editor.lua`), клиент только просит и показывает. Схема `client.yaml` —
**аддитивно в v1** (как PacksChanged волны 4b): c2s 16–21 (`ScriptOpen{seq,eid,edit}`, `ScriptSave{code ≤ 16 КиБ}`,
`ScriptRun`, `ScriptStop`, `ScriptLockRelease{close}`, `ToolUse{tool 1 injector|2 gravity, action 1 use|2 grab|3 release|4 aim,
target, origin, dir}`), s2c 88–92 (`ScriptState` — код, статус STOP/RUN/ERROR, ошибка, владелец, держатель лока, can_edit,
editing, хвост консоли ≤ 64, `ScriptMeters`; `ConsoleDelta` — только подписанным, ≤ 16 строк и 4 КиБ, не чаще раза в 5 тактов,
`dropped`; `RequestReply{seq, op, code, reason}`; `EntityOwnership`; `EntityMeta` — бирка владелец/статус). Диапазоны 16–31 / 88–103
оставлены за 4a. Кодеки Lua/Python/Rust перегенерированы, `--check` зелёный; шлюзы (Python и Rust) пропускают новые
сообщения по типу после проверки схемой (Rust-кодеки и `olife-gateway.exe` пересобраны параллельной волной в 06:57/07:01 уже
с этой схемой; сам я Rust не собирал — работу через него доказывают прогоны `--impl rs`).
- **Бенч** (`spawn_bench <account> [name] [count]`): сущность вида 3, def `olife_client:bench` (коробка модели `block`, текстура
  по статусу: доски / зелёная / красная лампа), свой код (по умолчанию — вращение), статус, консоль (кольцо 64, `cseq`
  монотонный), владелец-аккаунт; всё в `world:olife_registry.json` (запись при изменении, не чаще раза в секунду + `save`) —
  переживает рестарт, работавший код грузится в песочницу при подключении. Старые `orbit`/`neg_*` без кода работают как прежде.
- **Права**: редактировать/запускать/останавливать — владелец (аккаунт) или админ (`Attach.perms` бит 1 или `olife.admins <csv>`),
  остальные — только чтение. **Лок** — один редактор на сущность, держатель — сессия; отпускается `ScriptLockRelease`, Esc/Close,
  уходом сессии, тишиной 60 с (клиент шлёт `ScriptOpen` раз в 20 с). Запросы — ведро 10/с (20), aim — 20/с, учёт в
  `acct_actions` (счётчик supervisor). Коды отказов `RequestReply`: 1 нет сущности, 2 не скриптовая, 3 не владелец/админ,
  4 занято другим редактором, 5 не держатель лока, 6 далеко, 7 луч мимо, 8 держит другой, 9 частота, 10 код, 11 не держишь,
  12 песочница недоступна, 13 инструмент/действие, 14 origin/dir.
- **Консоль**: `print/oprint/say` бенча → кольцо + подписчикам; ведро 5 строк/с (запас 10) на бенч, остальное — отказ `rate`
  (для старых сущностей правило «1 строка в 20 тактов» не тронуто). Ошибка загрузки/исполнения → статус ERROR + строка.
  `ScriptMeters`: кредиты сущности за такт и минуту, топливо, применено/отклонено миром, кредиты владельца за минуту.
- **Инструменты**: луч считает мир от `origin` клиента (не дальше 3 блоков от позиции игрока у мира) по коробкам скриптовых
  сущностей, досягаемость 8. Injector → `ScriptOpen` (edit, если можно). GravityGun: один держатель; пока держат, мир каждый
  такт ведёт сущность к `глаз + dir·dist` (шаг ≤ 1 блок/такт, зона 48), `set_pos/set_vel` песочницы отклоняются (`held`);
  отпускание — ЛКМ, уход, отрыв > 16. Репликация — обычные снимки.
- **Клиент**: hud-игрок = игрок клиента («режим камеры» при `--walk 0`: его позиция/взгляд уходят `PlayerInput`, поправки
  мира ставят его); Injector — слот 1 (ПКМ, `on_use` предмета, выбор движка `player.get_selected_entity`), GravityGun —
  слот 2 (ЛКМ `input.add_callback("player.attack")`, ПКМ тоже). Редактор — оверлей `olife_client:editor` (нативный XML 0.32:
  `textbox` multiline + line-numbers + `syntax="lua"`, консоль — нередактируемый textbox с `onrightclick` очистки, `select
  mode="button"` шаблонов, кнопки Run/Stop/Save/Edit/Clear/Close, файлы `config:olife/scripts/<имя>.lua`). Run = Save (если
  правили) + Run. Бирки — `gfx.text3d` над репликой. F2F `olife {op: gui|state|aim|look|place|tool|send|ui|eval}`.

| сценарий (02.10, F2F 0.32 hidden/realtime, ПК занят другими агентами) | итог |
|---|---|
| `olife_editor` (alice — владелец, bob — админ, настоящая песочница) | ok 28 с (и `--impl rs`): Injector → редактор за 0.46 с; набор 8 строк (`input.chars` + Enter) = 251 Б, хэш кода у мира тот же; Run кнопкой → RUN; путь бенча за 4 с мир 8.68 / B 8.69 блока, расхождение p50 0, max 0.12 (интерполяция); у A 9 `ConsoleDelta` («tick 1..4»), у B **0 дельт и 0 ScriptState** до открытия; B: только чтение, `RequestReply` 4, Save в обход UI → 5; Esc у A → лок свободен; B Edit → лок, Save → 0, Close → свободен; счётчики 5 кредитов/такт, 526/мин, топливо 4.67 М/мин; согласованность 510 тактов / 850 сравнено / **0** |
| `olife_editor_neg` (в том же сценарии, протокол `editor_neg.py`, carol — чужая) | 14/14: open(edit) 3 (+ ScriptState только чтение), save/run/stop 3, release 5, нет сущности 1, не скриптовая 2, dir 0 → 14, инструмент 13, injector+grab 13, origin далеко 14, луч мимо 7, release без захвата 11, 40 open подряд → 25 × код 9; мир и шлюз живы |
| `olife_editor_extras` (там же, A на новом бенче) | шаблон Orbit из `select mode="button"` (клик по кнопке, затем по пункту) → Run → RUN; имя файла, Save file, Clear, Load file → тот же код (`config:olife/scripts/w4a_test.lua`); код с синтаксической ошибкой → Run → ERROR, «! [load] e7:3: unexpected symbol near 'end'» в консоли и в строке статуса, бирка B «… ERROR»; Stop → STOP; Close → лок свободен |
| флуд консоли (carol, 100 × 1000 Б за такт, 6 с) | 22 дельты (3.6/с, с обновлением счётчиков раз в секунду), ≤ 7 строк и ≤ 4043 Б текста на дельту; мир отклонил 117 строк (`rate`), кольцо 44 ≤ 64 |
| `olife_gravity` (и `--impl rs`) | ok 17 с: A (слот 2, ЛКМ) держит; B видит держателя, ЛКМ B → 8; поворот взгляда A на 60° и шаги — бенч сдвинут миром на 6.0 блока, B отстаёт ≤ 0.001; отпускание — итоговые позиции A и B = мир (до f32); затем B хватает (0) и отпускает; согласованность 290 / 420 / 0 |
| `olife_restart_editor` (supervisor, настоящая песочница) | ok 24 с: убит мир → поднят за 3.5 с; бенч carol RUN с тем же хэшем кода, снова движется, консоль 5 → 15 строк; бенч alice STOP с кодом |
| прогоны (`artifacts\lab\runs\`) | `20261002_071804_olife_olife_editor_vc` (всё вместе с extras, 31 с; согласованность 610 / 1059 / 0), `…071930_olife_olife_editor_rs`, `…071847_olife_olife_gravity_vc`, `…070845_olife_olife_gravity_rs`, `…071905_olife_olife_restart_editor_vc` — все ok |
| регресс после правок мира/клиента | `olife_consistency`, `olife_clients_f2f`, `olife_restart`, `olife_negative` (настоящий рантайм), `olife_negative_proto` — ok; векторы кодеков: Python 7/7, Lua в движке 204 вектора / 1247 проверок / 0 отказов |

Не сделано: подсветка ошибок в строке редактора (ошибка — в консоли и в строке статуса), список файлов в `select` (опции
задаются только XML; открыть — по имени из поля), «держать» для не-скриптовых сущностей, предсказание движения удерживаемой
сущности на клиенте (видно с задержкой снимков), права на захват (сейчас любой, но по одному держателю).

## Волна 4b: билеты, бинарный мост песочницы, тарифы вживую, паки на лету (02.10, агент olife_w4b)
Ядро демона лаборатории не трогали (только CLI `cli_sup.py`: `tariff set <k> delete`); код лаборатории — `tools/lab/projects/
olife/olife_w4b.py`. Движок не менялся. Числа ниже — `lab sysload` перед прогонами «не занят», но рядом работали агенты 4a/4c
(сборки rustc, их сценарии) — это ориентиры, не чистые замеры.

**1. Вход по билету** (`agents/research/OLIFE_GATEWAY_SECURITY.md` §7). Сервис билетов `tools/olife/auth_service.py` (отдельный
процесс, вид лаборатории `auth`; HTTPS, самоподписанный сертификат генерирует сам) берёт аккаунты и баны из БД supervisor
(`/sup/auth` демона) и выдаёт билет `T1.…` (HMAC-SHA256/128 ключом шлюза, выведенным из мастер-ключа; аккаунт, nonce 96 бит,
срок ≤ 60 с, аудитория — id шлюза; 59 символов, максимум 127 — влезает в `Hello.token str<128>`, схема не менялась). Клиент
(`olife_client:auth`) перед каждым соединением идёт за билетом по HTTPS из 0.32 (`network.request`): curl в 0.32 со schannel
без параметра CA → для самоподписанного сертификата только `verify_ssl=false` (проверено в движке: `true` → status 0), поэтому
запрос **запечатан** к закреплённому x25519-ключу сервиса (HKDF + ChaCha20-Poly1305 из `crypto` 0.32; подмена → 400).
Шлюзы (`gateway_dev.py` и Rust) проверяют билет офлайн; новые коды `Disconnect`: 14 просрочен, 15 повтор, 16 подпись, 17 чужой
шлюз; режим `--auth-mode tickets` выключает статические токены.

| `olife_auth_ticket` (2 бота по билетам + `ticket_check.py`) | Python-шлюз | Rust-шлюз (`--impl rs`) |
|---|---|---|
| случаи | 11/11 | 11/11 |
| good / replayed / expired / wrong gw / bad sig / malformed | Welcome / 15 / 14 / 17 / 16 / 4 | те же коды и причины |
| забаненный: сервис / выпущенный в обход билет | `banned` / 5 | `banned` / 5 |
| согласованность (мир против 2 ботов) | 340 тактов, 468 сравнено, 0 расхождений | 0 расхождений |

Выдача билета сервисом p50 14.6 мс / p95 28 мс (запечатанный, с проверкой в БД); бот получает первый билет за 152–153 мс по
часам движка (3 такта цикла 20 Гц), повторный — 51 мс. Тесты без движка: `tools/olife/tests/test_tickets.py` 4/4 (WSL и Windows
Python), Rust `cargo test` 22/22 (векторы `protocol/vectors/tickets.json`, чеканка байт в байт как Python), `negative.py` 25/25 у
Rust-шлюза и с билетами, и без; кросс-проверка 23/23 случая у обоих шлюзов (`/root/olife/gateway/tools/ticket_packs_check.py`).

**2. Бинарный контракт у настоящей песочницы.** `olife-sandboxd` (`src/binproto.rs`, кодек — `gen_codecs.py --lang rust
--rust-out /root/olife/sandboxd/src/proto`) говорит `sandbox.yaml` на том же порту, транспорт — по первому байту (`{` — JSON);
мост мира по умолчанию `bin` (параметр мира `sandbox_proto`, JSON — запасной путь). Вид в TickInput склеивается вручную
(`sbmeter.encode_view`): с `json.tostring` бинарный TickInput стоил 19.4 мс, а такт мира p50 вырос до 23 мс. 500 typical
(50 владельцев × 10) + 2 orbit + 2 бота, двойники сценариев подряд:

| на такт (мир) | JSON-строки (`olife_sandbox_binary_json`) | бинарный (`olife_sandbox_binary`) |
|---|---|---|
| TickInput, байт | 211 790 | 204 566 |
| TickResult, байт | 99 129 | 37 116 (×2.7 меньше) |
| сборка+кодирование TickInput p50, мс | 6.29 | 5.00 |
| разбор TickResult + применение p50, мс | 4.77 | 2.19 |
| такт мира p50 / p95, мс | 14.04 / 19.23 | 9.65 / 17.42 |
| такт сервиса p50, мс | 4.39 | 4.28 |
| согласованность / контрольные владельцы | 0 расхождений / ок | 0 расхождений (1000 сравнено) / ок |

В движке без сети (`tools/olife/tests/bench_sandbox_bin.lua`, 500 сущностей, 3819 элементов вида): TickInput JSON 2.41 мс /
303 КБ, BIN 4.66 мс / 290 КБ (кодек из них 0.55 мс); TickResult разбор JSON 3.87 мс / 139 КБ против BIN 1.84 мс / 53.5 КБ.
Сторона сервиса (Rust `bench_codec`, медиана 300, ПК под нагрузкой): TickInput JSON 353 КБ разбор 4.29 мс (как `Request`;
напрямую в `TickInput` — 2.62), BIN кодек 0.067 мс, но с разбором JSON видов 2.90 мс (вид — 287 КБ из 334 КБ кадра, остаётся
JSON-строкой); TickResult JSON 142 КБ кодирование 0.17 мс против BIN 54 КБ 0.016 мс (+ преобразование 0.069). Через бинарный
контракт не приходят метры владельцев (`TickResult.owners`) и ответы на запросы (их нет и в JSON-мосте).

**3. Тарифы вживую.** Ключи БД supervisor `limits.default.<поле>` / `limits.owner.<n>.<поле>` (fuel_per_tick, bucket_max,
tick_cap, entity_budget, max_actions, max_text_bytes, mem_max, hard_cap_*) → `set_limits` на порт управления `olife-sandboxd`
(новые команды `set_limits {owner|"*", limits}` — слияние, `limits {owner?}` с `applied_tick`). Доставка: `lab olife tariff set
<k> <v|delete>` — БД и сразу всем песочницам групп supervisor и своим арендам (проверено CLI: 2 песочницы, 0.1–0.2 мс на
отправку); опрос групп supervisor досылает новому процессу. Всё, кроме `mem_max`, действует со следующего такта; `mem_max` — со
следующего роста памяти (уже выросшая не сжимается). `olife_tariff_live` (2 orbit владельца 9101 + 2 orbit 9102): лимит 9101
20 000 топлива/такт, tick_cap 20 000, bucket 0 → `applied_tick` 219 = первый `throttled` 219 (следующий такт сервиса после
доставки за 2.6–4.4 мс); у 9101 throttled в 36 % строк, сдвигов на строку 2.0 → 1.3, топлива 117 → 92 тыс. (фиксированная цена
вызова ~60 тыс. больше порога); у 9102 — 0 throttled из 59 строк; ключи удалены → 9101 снова `ok` (лимиты применены с такта 278).
*(03.10, B3: «следующий такт» тогда держался на фазе count-хука и после волны A сломался; теперь гарантирован проверкой бюджета
в конце прогона, числа строк `throttled` другие — см. «B3: тарифы вживую после волны A».)*

**4. Паки на лету.** `client.PacksChanged{version, url, files}` (id 75, добавлено в v1): шлюз (оба) смотрит манифест раз в 1 с,
шлёт после `Welcome` и всем при смене. Клиент (`olife_client:packs`) сверяет sha256, скачивает изменённое (`network.request`:
`get_binary`/`post` 0.32 сломаны — LESSONS), пишет пак **целиком** в `world:content/<пак>` и: `modules/hot/*.lua`,
`config/*.json` — вживую (`load()` из world:content); остальное (scripts/, прочие модули, определения контента, ассеты,
package.json) — `app.reopen_world()` (движок берёт пак из world:content) + сброс реплики + новый билет + вход. `olife_packs_reload`
(2 бота): правка `modules/hot/rev.lua` → применено вживую через 0.75–1.37 с от правки (опрос шлюза 1 с), без переподключения;
правка `scripts/world.lua` → reopen + вход заново через 0.69–0.75 с, путь пака `world:content/olife_client`, `reconnects=1`;
согласованность через перезагрузку 430 тактов / 661 сравнено / 0 расхождений.

**Регресс** (мост по умолчанию `bin`, тот же день): `olife_sandbox_real` (725 / 0), `olife_negative` 16/16, `olife_consistency`
(520 / 0), `olife_load` (2750 / 0), `olife_blocks` (1142 / 0), `olife_negative_proto` 25/25, `olife_sandbox_bin` (заглушка),
`olife_clients_f2f` (330 / 0), `olife_sandbox_load` (500 сущностей по `bin`: такт мира p50 13.5 мс, сервис 4.4 мс) — ok;
`olife_restart` — ok после правки гонки в шаге `olife_ban` (бот без переподключения успевал выйти за `hold_s` — плагин теперь
считает это успехом по логу; первый прогон упал на этом). Rust-шлюз (`--impl rs`): `olife_auth_ticket` 11/11 (586 сравнено / 0),
`olife_negative_proto` 25/25, `olife_consistency` 520 / 0, `olife_packs_reload` (вживую 0.69–0.76 с, reopen 1.36–1.43 с,
656 / 0) — ok. `olife_tariff_live` повторно — ok.

## Волна 4c: сетевой код — предсказание движения, дельты снимков, инвентарь (02.10, агент olife_w4c)
Сообщения (client.yaml, аддитивно в v1, id вне диапазонов 4a/4b): c2s `MoveInput{seq, keys, yaw, pitch, hash}` (32),
`InvAction{seq, op, slot, slot2, count}` (33); s2c `PlayerState{ack, tick, pos, vel, flags}` (104), `EntityDelta` (105),
`InventoryState{rev, ack, selected, full, items, items_hash, slots[], hash}` (106), `InvReject` (107), `PlayerAck{ack, tick}`
(108); `BlockReject` получил причину 7 (нет предмета). Кодеки Lua/Python/Rust перегенерированы, Rust-шлюз пересобран
(`win_build.sh test`: тесты 7+6+1+8 ok, константы схемы в `tests/codecs.rs` — 36 сообщений, 208 векторов); векторы Lua в
движке — 1271 проверка / 0. Умолчания теперь новые: мир `snap=delta, inv=1`, боты/клиенты `move=predict`; прежнее поведение —
`--opts` (мир `snap=full,inv=0`, бот `move=legacy`; сценарий `olife_load_legacy`).
- **Движение** (`olife_proto:movement`): модель — физика игрока самого движка 0.32 (`core:player` + `core:mob`: 27 ед. скорости,
  бег ×1.5, присед ×0.35, полёт ×2, прыжок 8; `PhysicsSolver`: гравитация 22.6, затухание 10 по x/z, ступенька 0.5, хитбокс
  0.6×1.8), но фиксированным шагом 0.05 с на ввод: решатель движка шагает по кадровой дельте (60 к/с ≠ 20 т/с) и не
  вызывается из Lua для переигровки. Столкновения — по осям (Y, X, Z), хитбоксы блоков `block.get_hitbox` по повороту,
  `obstacle: false` пропускаются, незагруженный чанк — твёрдый (подход AlphaMine `physics.lua`). После каждого шага позиция и
  скорость округляются до f32 → сервер шлёт f32 и клиент принимает его состояние бит-в-бит. Тест в движке
  (`tools/olife/tests/movement_test.lua`): шаг 2.63 бл/с (бег 3.95), прыжок 1.42 бл, остановка у стены, перепрыгивание ступени,
  полёт, два прогона и переигровка из «сетевого» состояния — один hash; шаг 0.0015 мс.
- **Клиент** (`predict.lua`): ввод такта → шаг локально → `MoveInput` с hash предсказанного состояния; мир шагает тем же
  кодом на вводе (фаза 1), сравнивает hash: совпал — `PlayerAck` не чаще раза в 4 такта, не совпал/ввод отброшен/сброс —
  `PlayerState` в том же такте; клиент принимает состояние сервера для `ack` и переигрывает неподтверждённые вводы, разницу
  показывает затухающим смещением (τ 100 мс; > 4 бл или флаг сброса — сразу). Античит: ведро вводов 20/с **реального
  времени** (запас 10), seq только растёт, лишние биты клавиш срезаются, шаг > 3 бл откатывается с флагом сброса, позицию
  клиент не присылает вовсе. Оконный клиент в режиме камеры волны 4a (`walk=0`) остаётся на старом вводе позиции.
- **Снимки** (`snapdelta.lua` / `entdelta.lua`): база = то, что этой сессии уже отправлено (TCP — без подтверждений), позиции
  в 1/256 блока (i8/i16 дельта или i32 абсолют), углы 1/65536 оборота, каждый компонент — только если изменился; u16-слоты
  вместо eid; неизменное не шлётся; ключевой кадр раз в 100 тактов (со сдвигом по сессии); приоритет (возраст+1)/(1+(d/16)²),
  бюджет байт на сессию и такт (1200), дальние сущности — каждый 2-й (> 24 бл) / 4-й (> 48 бл) такт; hash вида считается от
  деквантованных значений на обеих сторонах. В режиме delta `sess.view` = `sess.dview` (редактор 4a смотрит только ключи).
  `olife.snap full|delta` переключает на ходу (вид каждой сессии снимается и выдаётся заново — hash сходится).
- **Инвентарь** (`inventory.lua` / `invmirror.lua`): инвентарь — движковый инвентарь игрока мира (`player.get_inventory`,
  40 слотов, хотбар 0–9); набор при первом входе (32 камня, 16 досок; 10 `olife_proto:coin` — до UX round 1), сохраняется в реестре мира
  по имени предмета; ломание → предмет `picking-item` блока (переполнение — на землю), постановка — только предметом
  выбранного слота с этим `placing-block` (иначе `BlockReject 7` + `InvReject 5`) и не в хитбокс игрока; выброс → сущность
  вида 4 (`olife_client:drop`), подбор любым игроком в 1.5 бл (через 1 с, выбросившим — через 2 с), исчезает через 60 с;
  `InventoryState` — изменённые слоты, hash всего инвентаря и проверка таблицы предметов (первые `items` определений
  клиента — тот же hash имён: `olife_client` добавляет свои предметы после общих). Клиент зеркалит в инвентарь своего
  игрока движка (виден в UI движка). Ведро 10/с (запас 20), проверки слотов/количеств. Баланс мира: создано = в
  инвентарях + на земле + поставлено + истекло.

| замер (02.10, ПК не простаивал: другие волны гоняли сценарии) | итог |
|---|---|
| `olife_prediction` (dev-шлюз; A = bot1 с задержкой; стена 2 бл в 0.9 бл перед каждым идущим игроком раз в секунду на 0.5 с — `olife.disturb 10`; оба бота ломают/ставят блоки) | RTT 0 (фактически p50 25 мс — фаза цикла бота): 0 поправок, ошибка предсказания 0. RTT +50: A — 10 поправок за 20 с (29.6/мин), скачок p50 0.15 / p95 0.29 / max 0.29 бл, переигровка 1 ввод. RTT +150 (RTT шлюза max 198 мс): A — 10 поправок (29.6/мин), скачок p50 0.52 / p95 1.88 / max 1.88 бл, переигровка 3–4, неподтверждённых до 8; жёстких скачков 0. B (без задержки) — 0–1 поправка за фазу. Ошибка в `ack` p50 = 0 во всех фазах (остальные вводы — бит-в-бит). В конце hash состояния движения каждого бота = hash мира, ack = seq; согласованность 0 расхождений (≈ 3000 сравнений). Спидхак: 150 вводов за 3 с → мир смоделировал 69 (≈ 20/с + запас), 81 отброшено |
| `olife_delta` (состав `olife_load`: 6 ботов, песочница, 11 сущностей) | снимки: full 1659 → delta 803 Б/такт (−52 %; 276 → 134 Б/такт на сессию), весь трафик вниз 2023 → 1146 Б/такт (−43 %; 6.7 → 3.8 КБ/с на сессию); 98 % ходов — i8-дельты; бюджет 60 Б: 305 Б/такт (51 на сессию), отложено 5857, прорежено 2505; 0 расхождений на 6453 сравнениях. С Rust-шлюзом то же: 1651 → 796, 0 расхождений |
| `olife_load` до/после (тот же ПК подряд; до = `olife_load_legacy`) | вниз 995 338 → 755 201 Б (−24 %; запись волны 2 — 996 841), снимки 550 034 → 319 461 Б (−42 %; запись 549 КБ), вверх 108 999 → 80 946 Б (−26 %: `MoveInput` 23 Б против `PlayerInput` 35), согласованность 2724 / 0. Цена: такт мира avg 1.0 → 1.45–2.3 мс, p95 1.5 → 2.3–6.5 (фаза репликации 0.3 → 0.65–1.0; `snapdelta` 0.4–0.55 мс/такт в живом мире против 0.04 мс в стенде `bench_snapdelta.lua` — не GC: с кучей 49 МБ стенд 0.044 мс) |
| `olife_inventory` | 20 с, 2 бота рядом: выброшено 46, подобрано 36 (15 — другим ботом), поставлено 72, сломано 101; зеркала обоих = миру (hash, слоты, выбранный), расхождений hash 0 за ~200 состояний; баланс 0; блоки 113/113; негатив 7/7 (слот, пустой слот, количество, op, постановка без предмета → BlockReject 7 + InvReject 5, поток 40 → отказ по частоте) |
| регресс (новые умолчания) | `olife_consistency`, `olife_load`, `olife_blocks`, `olife_negative_proto` 25/25, `olife_sandbox_bin`, `olife_clients_f2f`, `olife_sandbox_real`, `olife_negative`, `olife_restart`, `olife_gw_throughput`, `olife_sandbox_load` (такт p50 11.2 / p95 20.3 мс; запись 13.3 / 17.4), сценарии 4a/4b (`olife_editor`, `olife_gravity`, `olife_restart_editor`, `olife_packs_reload`, `olife_auth_ticket`, `olife_sandbox_binary(_json)`, `olife_tariff_live`) — ok; `--impl rs`: consistency, load, blocks, negative_proto, delta, inventory — ok |

## Волна 5p: производительность такта мира (02.10, агент olife_w5p) — `agents/research/OLIFE_WORLD_PERF.md`
Движок не менялся. Код мира **компилируется JIT-ом** (`jit=off` — такт 125 мс вместо 11 под `olife_sandbox_load`), но со
стоковыми лимитами LuaJIT (`maxtrace=1000`) кэш трасс мира + base-пака переполнялся: 17–18 полных сбросов за 25 с,
~20 000 перезаписанных трасс — отсюда max 71–86 мс и «snapdelta в 10× дороже стенда» (стенд со сбросом раз в 28 тактов —
0.95 мс против 0.03). Вторая причина всплесков — GC внутри такта (3.3 МБ мусора за такт).
- **Новые умолчания мира** (`server_start.lua`, `--opts`): `jit=tuned` (`maxtrace=8000, maxmcode=65536, hotexit=200,
  maxside=400, maxsnap=1000`; прежнее — `jit=on`), `gc=tick` (автоматический GC остановлен, цикл после такта при росте
  кучи на 1 МБ / 25 %, ≤ `gcbudget`=6 мс за такт; прежнее — `gc=auto`). Ещё `jit=off|wasm`, `jitopt=k=v;k=v`,
  `gcpause/gcstepmul/gcmax`.
- **Код**: TickInput (bin) — вид JSON-текстом из фрагментов, построенных раз на сущность за такт (`sbmeter.view_json_index`,
  плоский обход 27 клеток; текст байт-в-байт прежний), пул записей `EntityInput`; TickResult — действия на месте без копий;
  ключ чанка ≥ 2^31 (массивная часть таблиц рвала трассы); `fnv_step` без ветки (`util.lua`, то же значение). Мусор
  3.3 → 1.7 МБ/такт.
- **Профиль** (`--opts prof=1,jitlog=1`; `modules/prof.lua`): CSV на такт `export/world_prof.csv` (5 фаз, 35 подшагов, рост
  кучи по фазам, GC, события, время между тактами), сводка трасс `olife.jit` → `export/world_jit.txt`. Лаборатория: шаги
  `olife_prof_mark`/`olife_prof` (`olife_w5p.py`), сценарии `olife_w5p_*`, перф `sandbox_load` с `world_opts` собирает то же.

| такт мира, мс (p50 / p95 / max, mean; сценарии подряд, ПК простаивал по `sysload`, не ворота `lab perf`) | до (сток) | после |
|---|---|---|
| `olife_sandbox_load` (500 typical, 2 бота) | 10.97 / 26.03 / 71.04, 13.89 | **6.08 / 6.71 / 9.98, 6.14** (+ GC 2.9 мс после такта) |
| `olife_load` (6 ботов, 11 сущностей) | 1.24 / 2.59 / 12.04, 1.55 | **1.03 / 1.29 / 1.72, 1.04** (GC 0.08 мс) |

**Чистый замер** `lab perf olife sandbox_load` (ворота простоя, `contended: false`): до (13:43) такт мира p50 / p95 / max
11.56 / 29.27 / 87.55, mean 15.56 → после (14:57, `20261002_145714_olife_sandbox_load_w5p`) **5.92 / 6.70 / 8.19, 6.00**;
сервис песочницы 4.3 мс — без изменений. Регресс с новыми умолчаниями: **29 / 29 ok** (23 сценария `--impl vc` + 6 `--impl rs`).
Фазы `olife_sandbox_load` (mean до → после): разбор TickResult 2.76 → 1.34, виды TickInput 5.64 → 1.15, snapdelta 1.60 →
0.84, термы сущностей 0.91 → 0.58, перехеш чанков 0.41 (это `world.get_chunk_data`, а не FNV). Бэклог — §6 исследования.

## Путь игрока: `lab play olife` (02.10, агент olife_play)
Движок не менялся, ядро лаборатории не менялось (клиентский CLI: `lab play --dry-run/--wait`, `lab olife play-up|play-down|
play-status|sync`, `accounts add` без токена). Стоковый рантайм агент не запускал: путь проверен сухим прогоном на F2F 0.32.
- **Сеанс** — `[play]` проекта olife: вид `play_stack` («коляска» `play_stack.py`: через HTTP демона `olife.play_up`, статус
  стека раз в 10 с и события вход/выход/инцидент/перезапуск в свой stdout = «сервер» отчёта; на `stop` — `olife.play_down`) →
  вид `runtime` (СТОКОВЫЙ `voxelcore-0.32_dc62ccfb\VoxelCore.exe`, обычное окно, `--dir` = корень 0.32, `--script
  content\olife_client\scripts\app\olife.lua`, аренда `vc032-main`, `exclusive_exe`). Выход окна = конец: коляска делает
  сводку и снимает группу, `play_report.md` пишет ядро по `[play.report]` (строки `[olife_play] status fps ...` клиента через
  `debug.log`, события, ошибки). Коляска убита без stop → хук опроса группы (`PlayHooks`) снимает стек через ≤ 30 с
  (проверено: taskkill коляски → 4 аренды освобождены за ~25 с).
- **Стек** (`olife_play.py`, группа supervisor `olife-play-<сессия>`): мир `world_play` (стоковый 0.32 headless, `worlds\` —
  junction на постоянный `D:\Prog\Olife\play\worlds`; сухой прогон — копия), настоящий `olife-sandboxd`, сервис билетов
  `auth` (ключи постоянные `D:\Prog\Olife\play\keys`, `require_sealed=1`), Rust-шлюз `gateway_rs` (`auth_mode=tickets`,
  `gw_id=gw-olife-play`, раздача паков по манифесту), health всех четырёх, тарифы по умолчанию, аккаунт `user` (роль admin в
  БД, токен `D:\Prog\Olife\play\user_token.txt`), `olife.admins user`, примеры `demo_orbit/demo_follow/demo_blink`
  (`spawn_sample user <имя> <код> 1`: бенч с кодом `sandbox/samples/<код>.lua`, запущен, на кольце радиуса 3 вокруг спавна;
  только недостающие), `save`. Файл подключения `export\olife_server.txt` (gateway, auth, gw_id, auth_pub, token) — в корень
  0.32 (обычный режим) и в базу. Паки клиента в `<0.32>\content` — junction на `VC_ROOT\content` (sync при каждом подъёме).
- **Клиент**: `olife_client:play` (общий для меню, `--script` рантайма и сухого прогона): читает файл подключения, реплика
  `olife_replica` заново, билет, вход, режим камеры с Injector/GravityGun, `reconnect=3`, `export=false`; строки статуса раз
  в 5 с. Грабли 0.32: модули пака видны только после загрузки контента (мир открывает app-скрипт до `require`), у модуля пака
  нет `app` (передаётся из скрипта), длинного тире нет в шрифте движка (LESSONS).

| проверка (02.10; ПК свободен по `lab sysload`; аренды владельца olife_play) | итог |
|---|---|
| `lab play olife --dry-run` = сценарий `olife_play_dry` (последний `20261002_153231_olife_olife_play_dry_vc`; до него ещё 3 зелёных подряд) | **ok за 41 с**: мир — копия постоянного `D:\Prog\Olife\play\worlds` (примеры уже там — не спавнятся), стек готов за 4.3 с (мир 2.24, песочница 0.65, билеты 0.55, шлюз 0.53), клиент F2F 0.32 в игре за 1.15 с по билету (`tickets=1`), слоты 1/2 = Injector/GravityGun, 3 примера видны с биркой «demo_* [user] RUN»; за 4 с orbit: мир 7.12 / клиент 7.12 блока, blink 4.7 / 6.9 (выборка 0.35 с против периода 0.5 с); follow: игрок отошёл шагами по 0.25 бл → дистанция 4.61 → 2.21; Injector ПКМ → редактор за 0.45 с, Clear + 11 строк + Run → мир `status=run`, fnv кода = набранному, путь 6.9 бл, «square 2/4» в консоли, Close → лок свободен; GravityGun ЛКМ → держит (`holder=user`), поворот взгляда на 70° → мир сдвинул бенч (3.4–6.3 бл по прогонам), ЛКМ → отпущен, клиент = мир (0.002); строки статуса 6, fps 123.6–144 (скрытое окно F2F без vsync — не fps пользователя); после стопа: `olife_session.md`, `play_report.md` + `play_fps.svg` (код `labcore.play`; 1 ошибка движка — `sockets recv` при закрытии клиента), 4 аренды стека `exit 0` без принудительного убийства |
| `lab olife play-up` (режим play, постоянный мир) ×2 + `play-down` | 4.6 / 4.2 с; первый раз создан мир и 3 примера, второй — `samples_spawned: []`, бенчи те же (eid 1–3, RUN); `<0.32>\export\olife_server.txt` пишется при подъёме и удаляется при `play-down` |
| меню «Сценарии» → `olife [olife_client]` (вид `menu_client`, F2F input по кадру) | в мире за ~0.1 с после клика, вход по билету; Esc → «Сохранить и выйти в меню» → `world closed by the player`, шлюз: `bye: player left`, снова главное меню; без файла подключения — окно `gui.alert` с подсказкой |
| `lab olife play-up --dry` / `play-status` / `play-down` | 4.6 с; статус; 4 аренды `exit 0` |
| политика | `lab play olife --final-check` от агента — отказ `policy`; `--user` с `LAB_OWNER=olife_play` — отказ CLI |
| регресс после правок клиента/мира | `olife_editor`, `olife_consistency` — ok |

Не проверено (запрещено агенту): сам стоковый `VoxelCore.exe` 0.32 в обычном окне — это `lab play olife --user` пользователя
или `--final-check --reason` главной сессии. Отличие от проверенного: тот же скрипт и те же паки, но стоковая сборка и окно
пользователя (vsync, его `settings.toml` в корне 0.32).

## UX round 1: первые замечания пользователя (02.10, агент olife_ux1)
Движок не менялся, ядро лаборатории не менялось, демон не перезапускался. Протокол — аддитивно в v1: c2s 22 `EntityEdit`, s2c
93 `EntityLook`, 94 `ScriptProfile`, `RequestReply` op 7 / код 15; кодеки Lua/Python/Rust перегенерированы, **Rust-шлюз
пересобран** (`D:\Prog\Olife\gateway\olife-gateway.exe`, sha256 `bfe9d153…`, тесты 7+6+1+8 ok).
1. **Редактор** — раскладка оригинала пользователя (`Olife/layouts/console.xml`) на нативном XML 0.32: весь кадр, splitbox,
   код (самый большой) над консолью, справа панель СКРИПТЫ (новый / код с сервера / файлы `config:olife/scripts` с удалением /
   шаблоны), ряд ЗАКРЫТЬ · RUN/STOP · имя · СОХРАНИТЬ · ПРАВИТЬ, вкладки Код/Профайлер/Настройки и одна строка статуса; код и
   консоль — векторный моноширинный шрифт 16 px (DejaVu Sans Mono через `preload.json` 0.32). Открывается ещё и клавишей `
   глядя на бенч. Профайлер: ScriptMeters + ScriptProfile + график 60 с; Настройки: имя, владелец, модель/текстура
   (`olife_proto:looks`), права-заглушки, удаление.
2. **Модели/иконки/звуки пользователя** из прототипа 0.30.6 (бенч `cmd`, bone, Injector `gtool`, GravityGun, значки,
   звуки `hit/hrom/hrum/explosion/slap`) — `content/olife_client` (атрибуция — README пака); 0.32 потребовал только
   переименования (имена моделей/текстур глобальны). `sounds/` в паке `Olife` прототипа пуст — звуки взяты из
   `engine_client/config/olife/sounds`.
3. **Монеты нет**: предмет удалён из `olife_proto`, набор — камень/доски; мир с монетой в `indices.json` мигрирует при старте
   (`indices.json.ux1.bak`). Тестовый предмет по флагу не понадобился: тесты инвентаря на камне/досках.
4. **Гравипушка/Injector**: нажатие = одно действие (фронт привязок `player.build`/`player.attack`, повторы `on_use` до
   отпускания отброшены, ≥ 150 мс), звук по ответу мира.
5. **Бирки** только с Injector'ом в руке, масштаб 0.02 (вдвое меньше), гаснут 6→24 бл.
6. **Shift+ЛКМ** — удалить последнюю открытую (сервер, владелец/админ, звук + сообщение), **Shift+ПКМ** — открыть её редактор
   не глядя.

| проверка (02.10, F2F 0.32 hidden/realtime, 854×480; ПК свободен по `lab sysload`) | итог |
|---|---|
| `olife_play_dry` (`20261002_211420_olife_olife_play_dry_vc`), шаг `olife_play_ux`, итоги — `shots\olife_play_dry\olife_ux.json` | **ok за 60 с**: корень 854×480, код 681×276 = 187 956 px² (следующий — панель скриптов 169×480 = 81 024), перекрытий 0; строка статуса одна; файл `ux1_test` сохранён → в панели → удалён «x»; шаблон hello + RUN → кнопка STOP/значок pause; Профайлер: 3 профиля, кредиты 3.0/такт, 99/мин, топливо 1.0M/мин, ошибок 0, память VM «н/д» (бинарный контракт песочницы её не шлёт); Настройки: владелец `user (#6)`, мир: имя `ux_bench_r`, модель `olife_bone`, текстура `blocks:planks`, клиент применил; ` → редактор; монеты: `coin_defined=false`, инвентарь — только Injector/GravityGun; бирок с GravityGun 0, с Injector 4; ЛКМ зажата 1 с (20 тактов) → 1 переключение (захват, держатель `user`), ПКМ зажата 1 с → 1 переключение (отпущен), 7 повторов `on_use` отброшено, звуки grab/release; Shift+ПКМ взглядом в небо (`selected_eid=0`) → редактор #6; Shift+ЛКМ → `RequestReply` op 7 код 0 «deleted», мир — бенча нет, звук `delete`, сообщение «Сущность #6 удалена». Снимки: `ux_editor`, `ux_editor_scripts`, `ux_profiler`, `ux_settings`, `ux_tags_injector`, `ux_tags_gravity_gun`, `ux_bench_bone_look`, `ux_after_delete_toast` |
| `olife_editor` (`20261002_210016_olife_olife_editor_vc`) | ok: редактор оригинала (новый/шаблон/файл из панели скриптов, RUN/STOP), `olife_editor_neg` **22/22** (+8: удаление/имя/вид чужой сущности → 3, плохие значения → 15, нет сущности → 1), согласованность 0 |
| регресс | `olife_consistency, blocks, negative, negative_proto, clients_f2f, delta, prediction, inventory, gravity, restart, restart_editor, packs_reload, auth_ticket, sandbox_bin, sandbox_binary, sandbox_binary_json, sandbox_real, tariff_live, load, load_legacy` и `--impl rs`: `editor, gravity, consistency, negative_proto, inventory` — все ok (25/25); векторы Lua в движке 1343/0, Python 7/7, `movement_test` ok |

Сухой прогон теперь нормализует копию мира: игроки — на спавн, примеры — `sample_reset` (код из файла, RUN, на кольцо);
до этого `olife_play_dry` падал на копии мира пользователя (он остановил `demo_blink` и улетел на 12 бл).
Не сделано: настоящие права (страница — заглушки), память VM в бинарном контракте песочницы, проверка раскладки на других
размерах окна (тесты — только 854×480), стоковый 0.32 в окне пользователя (это `lab play olife --user`).


## UX A2: чат, команды оператора, обратная связь (03.10, агент olife_a2)
Движок не менялся. Демон не перезапускался. Протокол — аддитивно в v1: тип `ChatEntry`, s2c 120 `ChatLine`, 121 `ChatHistory`,
122 `OpResult`, 123 `Notice`; `EntityMeta.status` += 3 THROTTLED / 4 FROZEN; нового c2s нет (команды — `ChatSend` «/…»).
Кодеки Lua/Python/Rust перегенерированы (`--check --lang all` зелёный); Rust-шлюз пересобран параллельной волной в 01:02 уже со
схемой A2 (s2c шлюзы пропускают без перекодирования, поэтому для A2 сборка не обязательна; `--impl rs` прогоны ниже).
- **Чат**: ведро сессии 2/с (запас 5) → `ChatLine{id, tick, ms, kind, role, from}`; сверх лимита — `Notice 8` (код 20);
  100 строк истории в реестре → `ChatHistory` после `Welcome`; системные строки входа/выхода, op-строки. Клиент: окно на T
  (через два `post_runnable` поверх консоли движка) или Enter, 14 строк с цветами, прокрутка ^/v, история ввода ↑/↓, лента HUD.
- **Команды** (чат «/…» админа = `lab olife op …` = кнопки панели, один исполнитель `ops.execute`): `help, mobs, who, kill,
  killall, freeze, unfreeze, limits, kick, ban, unban, tp, say, audit`; таблица — `content/olife_world/README.md` «UX A2».
  Отказы: 16 не админ, 17 нет команды, 18 аргументы, 19 нет цели, 9 частота. `/limits` игрока/моба → `set_limits` владельцу в
  sandboxd прямо из мира (`--opts sbctl=<порт>`), `actions`/`text` на мобе — лимит мира на этот моб. Бан/заморозка/лимиты/
  история — в реестре. Аудит — `world:olife_audit.jsonl` + `user:export/audit.jsonl` (by, role, via chat|cli|panel, цель, код).
- **Обратная связь**: `fx.lua` — каталог событий (inject, run, stop, save, grab, release, spawn, delete, fork, deny, throttle,
  frozen, unfrozen, killed, limits, kicked, banned, restarting, chat, op) → звук + тост цвета события; звуки пользователя
  (6 ogg) + 11 синтезированных `fx_*.wav`; цвет бирки по статусу RUN/STOP/ERROR/THROTTLED/FROZEN. F2F `fx`, `chat`.

| проверка (03.10, F2F 0.32 hidden/realtime 854×480; ПК занят параллельными агентами — не замеры) | итог |
|---|---|
| `olife_chat` (`20261003_005820_olife_olife_chat_vc`; `--impl rs` — `20261003_011217_olife_olife_chat_rs`) | **18/18**: T открывает окно, набор + Enter → у B строка от client1 role 1 (admin), время; Enter у B → ответ; у A событие `chat` (звук `fx_chat`), строка в ленте; carol 12 строк подряд → принято 5, `Notice 8` код 20 (1 раз), у B ровно 5; опоздавший dev: `ChatHistory` 9 строк в порядке, «dev joined» всем; `/help` игрока без админских; ^ сдвигает окно 18 → 14, «v ещё 4»; мир chat=12, throttled=7, history_sent=4; согласованность 330 тактов / 480 / **0** |
| `olife_op` (`20261003_010457_olife_olife_op_vc`) | **38/38**: bob `/kill` из окна → 16 + звук `refuse`; carol `/freeze` 16, `/blah` 17, `/mobs` — только своё; `/mobs bob` — 2; freeze моба → мир 0.0 бл за 1 с, бирка B = FROZEN, `Notice 9` + `fx_freeze`; unfreeze → движется, RUN; `/limits bob fuel 20000` + `bucket 0` → sandboxd владелец 1000: fuel_per_tick 20000, tick_cap 20000, bucket_max 0 (ответ ctl ok, version 3), бирка THROTTLED, `Notice 4` (`fx_op`); defaults → RUN; `/limits #4 actions 0` → моб стоит, default → снова идёт; CLI `olife.op` (via cli) и `POST /call/olife.op` (via panel) → 0, у carol `Notice 9`; `/tp bob` → камера B 81 → 87; `/kill`, `/killall bob` (1); `/kick bob` → `fx kicked sound=fx_kick`, Disconnect 10; `/ban carol 1` → Disconnect 5, повторный вход отклонён 5, `/unban` → вход; audit.jsonl 18 записей, есть 16, via chat/cli/panel; op-строк в чате 16 |
| регресс после правок (`20261003_0106…0113`) | ok: `olife_consistency`, `olife_editor`, `olife_gravity`, `olife_negative_proto`, `olife_clients_f2f`, `olife_restart`, `olife_tariff_live`, `olife_sandbox_real`, `olife_negative`, `olife_load`, **`olife_play_dry`**; `--impl rs`: `olife_chat`, `olife_editor`, `olife_consistency`, `olife_negative_proto`. Векторы Lua в движке 1847 проверок / 0, Python 7/7 |
| не зелёные / не проверены | `olife_restart_editor` — упал из-за меня (`lab olife down` чужой по времени группы — LESSONS), не перепрогнан; `olife_blocks` — ошибка лаборатории `PermissionError leases.json.tmp` (не сценарий), не перепрогнан; `olife_inventory` — расхождение зеркала бота (слот 0: 10 против 11), инвентарь A2 не трогал, вероятно гонка — не перепрогнан; `olife_perms`/`olife_fork` — сценарии A1, остановлены по указанию координатора |

Панель `/sup/panel`: секция Operator (игроки/мобы/баны/аудит с кнопками) в шаблоне `labcore/supervise.py`; демон помечает файл
`stale`, но страница уже отдаётся с секцией (проверено из Windows-Python); кнопка = `POST /call/olife.op` (проверено шагом).
Не сделано: окно чата не проверено на размерах кроме 854×480; «мир перезапускается» — по `Disconnect` 9/1 шлюза (отдельного
сообщения мира перед падением нет); per-mob топливо/память невозможно в sandboxd (VM на владельца) — уходят владельцу.

## UX A4: хранилище моба и процедурные активы (03.10, агент olife_a4)
Движок не менялся, ядро/демон лаборатории не трогались (только файлы проекта olife). Код: мир
`content/olife_world/modules/store.lua` (стабильный API, им пользуются A1 `store.fork`, A3 `memory.*`, будущий Спамер),
`storenet.lua` (протокол, команды `store_*`, `sup_state.store`), клиент `content/olife_client/modules/assets.lua`, песочница
`/root/olife/sandboxd` (canvas: `lua-wasm/sandbox.c` + `prelude.lua`, `binproto.rs`, цена в `protocol.rs`), шлюзы
(`--assets-dir`, `GET /assets/<sha>` у `gateway_dev.py` и Rust), лаборатория `tools/lab/projects/olife/store_a4.py` + сценарий
`olife_store`, пример `content/olife_world/sandbox/samples/demo_paint.lua`, пробы `tools/olife/probes/probe_store_*.lua`.
- **Хранилище** (всё на мире, в сохранении мира `world:olife_store/`): `index.json` (библиотеки владельцев, слоты сущностей,
  таблица файлов), `kv/<eid>.json`, `cas/<aa>/<sha256>` (файл без расширения). Пишется при изменении не чаще раза в секунду
  (`flush_ticks` 20) и сразу на `save`/выходе. Владелец — аккаунт (`_world` у сущностей без аккаунта). Для игрока (`lab play
  olife`) `worlds\olife\olife_store` — junction на `D:\Prog\Olife\play\store` (первый запуск переносит каталог туда;
  сухой прогон копирует содержимое вместе с миром), в тестах — каталог мира аренды.
- **KV моба** (`STORE.kv_get/kv_set/kv_all/kv_keys/kv_usage`): значения JSON (строки, числа, bool, таблицы до глубины 4),
  размер записи = ключ + JSON; память скрипта A3 (`memory.get/set/keys/size`) теперь лежит здесь (`mobapi.mem_set` ->
  `STORE.kv_set`, старый `e.mem` из реестра переносится один раз). Переживает рестарт мира и снимок/восстановление/форк.
- **Активы** (`STORE.put/get/has/info/list/quota/release/share/attach/detach/entity_assets`, ссылка везде `asset:<sha256>`):
  виды png / vcm / ogg / wav / lua / vca, проверка сигнатуры, CAS — один файл на содержимое, сколько бы владельцев и слотов
  его ни держали. Слоты сущности: `tex:*` (все шесть `$0..$5`), `tex:$i`, `model:<кость>`, `sound:<имя>`, `anim:<имя>`, `lib:*`.
  GC: файл без ссылок (ни в библиотеке, ни в слоте) живёт `gc_grace_s` 600 с, пул таких — до 16 МиБ, проход раз в 200 тактов
  и `store_gc`.
- **Квоты и тарифы** (живые: ключи БД supervisor `store.<имя>` -> миру `store_tariff`, без рестарта):

  | что | умолчание | что | умолчание (кредиты хранилища) |
  |---|---|---|---|
  | KV на моба | 64 КиБ, 256 ключей, ключ ≤ 64 Б, значение ≤ 4 КиБ | запись KV | 1 + 4 за КиБ |
  | активы владельца | 8 МиБ, 256 файлов | новый файл в CAS | 10 + 1 за КиБ (повтор — 10) |
  | файл | ≤ 1 МиБ (png/vca ≤ 512 КиБ, vcm ≤ 256 КиБ, lua ≤ 64 КиБ) | canvas commit | 2 + 1 за 1024 px (+ PNG как файл) |
  | canvas | сторона ≤ 256, коммит не чаще 1 раз в 5 тактов | share / attach / snapshot / restore | 5 / 1 / 10 / 20 |
  | ведро кредитов | 100/с, запас 1000 | загрузки игрока | 2 запроса/с на сессию (запас 4), файл ≤ 60 000 Б |

  Кредиты хранилища идут в счётчики supervisor (`store_credits`, × `credits.per_store_credit` 0.1 в общие кредиты), плюс
  `storage` (занято байт), `store_assets`, `store_writes`, `store_bytes` по аккаунту. Коды отказов (протокол и событие
  `rejected` скрипту): 40 нет сущности, 41 нельзя, 42 квота KV, 43 квота активов, 44 тариф (кредиты кончились), 45 велико,
  46 вид/формат, 47 нет файла, 48 частота, 49 ключ/значение/аргумент. Права слотов — A1 `storage_write`.
- **Протокол** (аддитивно в v1; c2s 55–59, s2c 140–149; sandbox Action tag 10): `AssetUpload{seq, kind, name, eid, slot,
  data ≤ 60 000}` (кадр клиента у обоих шлюзов ≤ 64 КиБ — большие файлы рождаются на мире: canvas, скрипты; кусочная загрузка
  — дальше), `AssetOp{seq, op 1 attach | 2 detach | 3 share | 4 release | 5 list | 6 manifest}`, `EntityAssets{eid, rev,
  assets[{slot, sha, kind, size}] ≤ 32}` (тем, кто видит сущность, при изменении и при входе в вид), `AssetList`, `AssetReply`;
  `sandbox.CanvasCommit{slot, w, h, rgba}` (сырые RGBA, строка 0 сверху). Кодеки Lua/Python/Rust перегенерированы, Rust-шлюз
  пересобран (`win_build.sh test`: 7+6+1+8 ok, константы тестов — 58 сообщений client, 10 sandbox, 304 вектора).
- **Раздача**: клиент берёт базовый URL из `PacksChanged.url` (тот же HTTP, что у паков), качает `GET <url>/assets/<sha>`
  (шлюз перехеширует файл: 409 при расхождении), сверяет sha256, кладёт в `world:content/olife_assets/<sha>.<ext>` (повтор
  того же sha не качается), регистрирует в движке. В сессии лаборатории без supervisor манифест даётся шлюзу по
  `"assets_http": true` (свой на сессию: `artifacts\lab\olife\manifests\<sid>.json`).
- **Что применяется на лету в 0.32 (без переоткрытия мира)** — проверено пробами в окне (`probe_store_window.lua`,
  `probe_store_model.lua`) и сценарием:

  | актив | как | на лету |
  |---|---|---|
  | текстура PNG | `Canvas.decode` -> `canvas:create_texture(name)` (или `assets.load_texture(bytes, name)`) -> `skeleton:set_texture("$i", name)` | да; RGBA текстуры движка (`assets.to_canvas`) = RGBA мира |
  | модель VCM (и XML) | `assets.parse_model("vcm", text, name)` -> `skeleton:set_model(i, name)`; повторный parse того же имени принимается | да (виден в кадре) |
  | звук OGG / WAV | файл в `world:` -> `audio.play_stream(path, x, y, z, vol, pitch, channel, loop)` (`play_stream_2d`) | да; `audio.play_sound` — только звуки, зарегистрированные при загрузке контента (путь -> 0) |
  | анимация VCA | `assets.parse_animation` (есть в API 0.32; трек применяет A3 `mobview`) | файл раздаётся; сам вызов в A4 обёрнут в pcall и мной не проверялся |
  | новые сущности/скелеты/блоки/предметы, регион атласа под новую текстуру блока, шрифты, layout, шейдеры, звук как именованный ассет | — | **нет**: только `app.reopen_world()` (путь паков волны 4b) или переписать уже существующий регион атласа `assets.to_canvas` |

  Грабля 0.32: `skeleton:get_model(i)` возвращает имя замены, только пока она не разрешена рендером, потом — модель кости
  из скелета (`lib__skeleton.cpp l_get_model`), поэтому модель не проверяется чтением назад (LESSONS).
- **Canvas в песочнице**: `canvas.new(w, h)` (≤ 256), `cv:set/get/fill/clear/rect/line/blit/size/hash`, `cv:commit(slot)`,
  `canvas.rgba(r, g, b[, a])` -> 0xRRGGBBAA. Поверхность — userdata в памяти wasm (в куче Lua владельца), рисование — C,
  оплачивается топливом как любой код; коммит — одно действие (base64 RGBA через свой буфер, не 64 КиБ общий), не больше
  одного на сущность за такт (лишние — `actions_dropped`), цена песочницы 2 + px/1024. PNG кодирует мир (`Canvas:encode`,
  256×256 ≈ 3 мс в пробе headless), кладёт в CAS владельца и в слот (`lib=false`: кадры не засоряют библиотеку), скрипту —
  событие `{type = "canvas", slot, sha}` или `rejected` с кодом.
- **Передача**: `STORE.share(sha, from, to)`; `STORE.fork(src, dst, owner)` — KV копией, слоты — те же файлы CAS (A1
  `EntityFork` зовёт его); `STORE.snapshot(eid) -> blob` (JSON: сущность — код/настройки/вид/статус, KV, слоты с sha/видом/
  размером, `ext` — хуки модулей `STORE.snapshot_hooks`, у A1 — права; файлы закрепляются в библиотеке владельца) и
  `STORE.restore(blob, {owner, name, pos, run}) -> eid` (нет файла в CAS — 47, квоты и кредиты нового владельца).

| проверка (03.10, F2F 0.32 hidden/realtime 854×480, настоящий `olife-sandboxd`; ПК занят другими агентами — GPU 68 % по `lab sysload`) | итог |
|---|---|
| `olife_store` (`20261003_011829_olife_olife_store_vc`; `--impl rs` — `20261003_011729_olife_olife_store_rs`) | **ok за 46 с / 45 с** |
| KV | запись/чтение/удаление; отказы 49 (ключ 65 Б), 42 (квота 64 Б), 44 (ведро 0), после возврата тарифа — 0; `demo_memory_counter` (A3 `memory.*`) пишет в то же хранилище |
| canvas `demo_paint` 32×32 раз в 10 тактов | слот у мира через 0.43 с после Run; B увидел 8 разных кадров за 7 с, каждый скачан за 6.9–9.3 мс; PNG кадра 273–385 Б; для 4 кадров sha256 RGBA мира (`store_rgba`) = декодированного на B = текстуры движка B (`assets.to_canvas`); `$0..$5` скелета = `olife_assets/<sha>`; после цикла из 8 кадров CAS не растёт: 8 файлов / 2 555 Б, `dedup` 8; шлюз отдал 16 файлов / 5 110 Б, 0 промахов |
| загрузка A (alice) | PNG 16×16 (405 Б) на свой бенч -> B за 8 мс, RGBA мир = B = движок; VCM-модель на кость `rody` — применена (снимок кадра: «башня» с текстурой), OGG 5 122 Б и WAV 7 100 Б — `play_stream` на B вернул поток; отказы: чужой бенч 41, не PNG 46, вид 99 -> 46, квота 100 Б -> 43, повтор того же файла 0 (дедуп), очередь из 6 без пауз -> 0,0,0,0,48,48; share alice -> bob: в библиотеке bob 1 файл / 405 Б |
| снимок / восстановление / форк | снимок бенча alice 815–1 175 Б (код 172 Б, 2 ключа KV, слот `tex:*` (+ модель, звуки), `ext.perms`); `store_restore` -> новый бенч, снимок копии = снимок оригинала (без eid/такта/позиции), KV и слоты равны; форк A1 — KV и слоты равны |
| рестарт мира (та же аренда) | 2.65 с; KV, слоты, библиотека, файлы CAS — те же; счётчик `demo_memory_counter` продолжился (песочница держит VM через рестарт мира — `LoadKeep`, поэтому `runs` не растёт) |
| регресс (после правок мира/клиента/песочницы/шлюзов, тот же ПК) | `olife_consistency`, `olife_editor`, `olife_negative_proto`, `olife_sandbox_real`, `olife_negative`, `olife_restart_editor`, `olife_packs_reload`, `olife_restart`, сухой прогон `olife_play_dry` (`20261003_012302`) — ok; `--impl rs`: `olife_store`, `olife_consistency`, `olife_packs_reload` — ok; векторы кодеков в движке 0.32 — 1 847 проверок / 0 отказов; Python `test_codecs.py` ok; `cargo test` sandboxd и шлюза (Linux) и шлюза (Windows, `win_build.sh test`) ok |

Не сделано: кусочная загрузка файлов > 60 000 Б от игрока (кадр клиента у шлюзов ≤ 64 КиБ), UI библиотеки/загрузки в клиенте
(есть протокол и F2F `assets {op=upload|op|state|play}`), подпись/TLS раздачи (sha256 сверяется, сама раздача — HTTP 127.0.0.1),
сам инструмент «Спамер» (хранение снимков игрока — его задача; API снимка/восстановления готов).

## UX A1: права «как у репозитория», друзья, форк (03.10, агент olife_a1)
Движок не менялся; демон лаборатории не перезапускался (ядро `supervise.py` получило миграцию 3 — действует после
`lab daemon upgrade`, до того плагин создаёт таблицы и берёт методы из свежей копии файла). Протокол — аддитивно в v1:
c2s 40 `EntityPermsSet`, 41 `EntityFork`, 42 `FriendRequest`, 43 `PermsCheck`; s2c 110 `EntityPerms`, 111 `FriendList`,
112 `EntityForked`; `RequestReply` op 8–11, коды 16–18. Кодеки Lua/Python/Rust перегенерированы (`--lang all --check`
зелёный), Rust-шлюз пересобран с общей схемой A1–A4 на 01:02 (`olife-gateway.exe` sha256 `a16a59c3…`, тесты 7+6+1+8 ok).
- **Модель** (`content/olife_world/modules/perms.lua`): 9 действий — `move, read_code, edit_code, run, appearance, clone,
  destroy, storage_read, storage_write` × аудитории `owner / friends / list (≤ 32 аккаунта) / everyone`; владелец и админ
  проходят всегда. Умолчания: `read_code = everyone` (код публичен, редактор и раньше открывался всем для чтения),
  остальное — `owner`; у аккаунта свои умолчания (`account_settings perms.default`). Правила хранятся с сущностью в
  `world:olife_registry.json`, форк копирует их. Изменение поведения: гравипушка теперь по праву `move` (было — любой),
  `olife_gravity` ставит `move=everyone` явно. Run/Stop — по праву `run` без лока (но не при чужом локе — 4).
- **Проверки**: ScriptOpen (read/edit), Save, Run/Stop, EntityEdit (destroy / appearance), ToolUse grab (move), Fork
  (clone), PermsCheck (любое, для UI/Спамера/хранилища); отказ 3 с `forbidden: <action> is for <audience>`. Для волн:
  `perms.allowed` (A4 storenet — storage_*), `perms.script_allowed` (A3 mobapi; `script.deny` из настроек аккаунта),
  `store.snapshot_hooks.perms` (снимок Спамера хранит правила), `store.fork` при форке (KV и активы A4).
- **Друзья**: запрос / принять / отклонить-отменить / удалить / список; встречный запрос = дружба; уведомления обеим
  сторонам, «в сети». Мир хранит граф и кольцо событий (`wid` сохранения); БД supervisor (`friends`) — долговременная
  копия: события -> БД (`poll` групп по `sup_state.friends_ev`, `lab olife friend sync` для сессий), БД -> мир при старте
  мира группы (`olife.friends "<spec>"` + `olife.acct_settings`) и при правке оператором (`lab olife friend add|remove|
  request|cancel`, `lab olife settings`).
- **UI** (нативный XML 0.32): страница «Настройки» — слева сущность (+ «Форк», «Друзья»), справа панель прав (9 строк:
  сегменты влад/друз/спис/все, поле списка + OK; не владельцу — только чтение «вам: …»); страница «Друзья»
  (`layouts/friends.xml`, Shift+` или кнопка); звук + тост на каждый ответ (`modules/fx.lua`, общий с A2).

| проверка (03.10, F2F 0.32 hidden/realtime 854×480; рядом работали агенты A2–A4) | итог |
|---|---|
| `olife_perms` (`20261003_010009_olife_olife_perms_vc`, 88 с; `--impl rs` — `20261003_011749_olife_olife_perms_rs`, ok) | **ok**. Друзья через UI: bob (Injector -> Настройки -> «Друзья» -> alice -> «Добавить») `requested`, тост; alice — тост «Запрос в друзья от bob», Shift+` -> страница, «Принять» -> оба списка «в сети»; carol просит, alice «Отклоняет» -> исходящих 0; отказы carol 16/16/17/17/15 со звуком refuse. Панель прав кликами alice: move/clone -> друзья, run -> список [carol]: ответы 0,0,0, мир `move=friends clone=friends run=list[carol]`, тост «Права: запуск — владелец и список»; bob — только чтение, `mine` = двигать/читать/форк, «Форк» вкл.; carol — читать/запуск, «Форк» выкл. **Матрица 108/108** (41 с), админ dev 9/9 = 0, негатив 25/25, БД: sync 4 события -> alice+bob, add/remove/request/cancel оператором доходят до мира и клиента; согласованность 1640 тактов / 4590 / 0 |
| `olife_fork` (`20261003_010252_olife_olife_fork_vc`, 18 с; `--impl rs` ok) | **ok**: bob «Форк» -> #5 bob, код fnv = источнику, модель/текстура `olife_bone / blocks:planks`, правила = источнику, `forked_from=4`, STOP, тост «Форк #4 -> #5 …» + звук `fx_fork`; Shift+ПКМ -> редактор форка, Run -> RUN; carol: кнопка выключена, запрос -> 3 «нет прав: форк — владелец и друзья» + refuse; форк форка: alice 0, carol 3 |
| регресс olife (31 прогон + повторы; таблица — `artifacts\lab\runs\20261003_010009_olife_olife_perms_vc\regress.tsv`) | ok: editor, gravity, consistency, blocks, negative, negative_proto, clients_f2f, delta, prediction, inventory (повтор; 1-й — расхождение зеркала бота 10/11 в слоте 0, без A1), restart, restart_editor, packs_reload, auth_ticket, sandbox_bin/binary/binary_json/real, load, load_legacy, play_dry (3-й прогон: 1-й — песочница стека не ответила ни на один TickInput, 2-й — луч гравипушки мимо мигающего `demo_blink`, код 7), `--impl rs`: editor, gravity, consistency, negative_proto, inventory, perms (повтор; 1-й — WinError 32 на `leases.json` демона), fork. **Не зелёный: `olife_tariff_live`** — 3 из 3 «throttled на 1 такт позже applied_tick» (песочница/тарифы); A1 в этом прогоне: 0 проверок прав, 1 FriendList; у olife_a2 тот же сценарий зелёный в 01:08 уже с A1 — смотреть волны, правящие sandbox/sandboxd/статусы (A2/A3) |

## UX A3: API скриптов моба (03.10, агент olife_a3)
Движок не менялся, ядро лаборатории не менялось, демон не перезапускался. Протокол — аддитивно: `sandbox.yaml` — вариант
действия `Ext{op, json}` (tag 9), тип `Answer`, сообщения `Answers` (9, мир → сервис) и `LoadKeep` (10); `Hello.proto` сервиса
= 2 (мир шлёт новое только ему и грузит скрипты после ответа Hello); `client.yaml` s2c 130 `EntityAppearance`, 131 `EntityAnim`,
132 `EntitySound` (c2s 50–54 не понадобились). Кодеки Lua/Python/Rust перегенерированы (`--check` зелёный для пакетов,
шлюза и sandboxd); **Rust-шлюз не пересобирался** — s2c он пропускает без разбора (`frame_raw`), проверено `olife_play_dry`
(gateway_rs). `olife-sandboxd` пересобран и выложен (`D:\Prog\Olife\sandboxd`, `cargo test` 6 + 15 + 5 новых `script_api`).
Вызовы — действия (мир применяет в следующем такте, отказ — событие `rejected`) или запросы (ответ в следующем TickInput,
вызов ждёт сам; без ответа 100 тактов — `nil, "timeout"`). Цены — `api_price_action` песочницы; справочник со всеми
ограничениями — `/root/olife/sandboxd/README.md` «UX A3». Права — `perms.script_allowed` (A1) + выключатель `olife.api_deny`;
активы `asset:<sha>` — `store.has` (A4); память — KV хранилища A4; вид — в реестре и в снимке Спамера (хук A4).
Переменные Lua: рестарт мира — `LoadKeep` (VM в сервисе жива); рестарт/падение сервиса — `--state-dir` (образы владельцев
на диск раз в N тактов, восстановление при создании владельца). Тест-скрипты `sandbox/a3_api_test.lua`, `a3_cost_probe.lua`;
примеры `sandbox/samples/demo_{spin_scale,texture_swap,sound_collision,block_painter,memory_counter}.lua` — в списке
`EXTRA_SAMPLES` пути игрока, в постоянный мир сами не ставятся (`spawn_sample user <имя> <имя> 1`).

| вызов (цена API, кредитов; топливо такта вызова в `olife_script_api`, простой такт ≈ 25.8 тыс.) | | вызов | |
|---|---|---|---|
| `set_scale` 1 (39.2 тыс.) | `set_rot` 1 (37.4) | `set_visible` 1 (31.1) | `set_texture` 10 (36.5) |
| `set_model` 10 (32.8) | `skeleton:set_bone` 2 (46.9) | `skeleton:set_bone_model` 10 (35.5) | `skeleton:reset` 2 (36.3) |
| `play_anim` 5 (39.9) | `stop_anim` 1 (33.1) | `play_sound` 20 (41.0) | `text3d` 2 (259.7*) |
| `block.set` 50 (51.2) | `block.fill_area` 4×1×4: 50+2·16 = 82 (64.7) | `block.get` 2 (48.2) | `block.get_area` 8×4×8: 5+256/64 = 9 (61.8) |
| `block.raycast` 20 (52.0) | `block.is_replaceable` 2 (48.3) | `block.find` r4: 20+729/64 = 31 (39.2) | `nearby` 20 (40.5) |
| `skeleton:bones` 2 (36.4) | `memory` первый доступ (`memory.load`) 5 (38.9) | `memory.set` 2+байт/64 = 2 (69.9) | `look_at` → `set_rot` 1 |

\* `text3d` — 259.7 тыс. топлива в обоих прогонах подряд (детерминированно; вероятно, шаг сборщика Lua пришёлся на этот такт) —
не разбирался. Цена кредитов = топливо/10 000 + API; столбец «кредиты» в отчёте прогона.

| проверка (03.10; F2F 0.32 hidden/realtime, 854×480; рядом работали аренды A1/A2/A4 — не замер производительности) | итог |
|---|---|
| `olife_script_api` (`20261003_012011_olife_olife_script_api_vc`; `…011907…` и после правки документации `…013521…` тоже ok) | **ok за 63 с**. Скрипт alice: запросы — луч вниз `base:grass_block@78`, `block.get` = тот же блок, `get_area` 3×1×3, над землёй заменяемо, `find` 10, `nearby` 2 игрока, кости `body,rody,body1,rody1,body2,rody2`, блок за 100 бл → `nil/reach`; `fill_area` 3×1×3 → `fill_done` 9/0, чтение назад 9/9; `block.set` с state → `base:planks`. Отказы мира событиями: scale 10 → `bounds`, `nope:texture` → `bad texture`, `nope/sound` → `bad sound`, кость `nobone` → `bad bone`, текст с \1 → `bad text`, 5000 Б в память → `value too large`. Мир: масштаб 1.5/2/1.5, rot y 45, текстура `*`=`blocks:stone`, кость body pos 0.25 / rot z 30 / ×1.2, rody1 = `olife_bone`, `olife_wave` ×1.5 цикл, текст «A3 api» `ffcc00ff`. У **B и A** (движок): `transform:get_size` = 1.5/2/1.5, матрица поворота cos45 = 0.7071, 6 текстур `blocks:stone`, матрица body ≠ единичной (0.25 смещение, 30°, 1.2), модель rody1 `olife_bone`, анимация идёт (881/1119 кадров, время меняется между опросами), 3D-текст прикреплён к сущности, видимость false/true увидена. Звуки: у B 2 `EntitySound` за 4.5 с (`olife/ok`, `audio.play_sound` вернул спикер); `olife.api_deny alice sound` → у скрипта `rejected forbidden`, у B 0 звуков за 3 с; `api_allow` → снова 2. Цены 23 вызовов — таблица выше, все совпали с таблицей. Примеры: spin_scale 1.5 + кость, texture_swap (у B `blocks:metal` в момент проверки), sound_collision (2 звука у B), block_painter («fill_done placed=16, read back 16/16»), memory_counter (count 8, runs 1). Согласованность 960 тактов / 1750 сравнено / **0**. Рестарт мира (stop/start аренды, 2.45 с): переменная 39 → 43, память 39 → 43, `loads`=1 (не перезагружен: `loads_kept` 7), вид снова у B в новой сессии, анимации нет (не хранится). Убийство песочницы (TerminateProcess) + старт 0.53 с: переменная 46 → 46, 47, 48, 49 (образ с диска, `restored_owners` 2), память 46 → 49, `loads` = 1 |
| регресс (тот же код) | `olife_sandbox_bin` (заглушка: старый proto 1 — загрузка после Hello, Load), `olife_sandbox_real`, `olife_negative`, `olife_consistency`, `olife_editor`, `olife_restart_editor`, `olife_restart`, `olife_gravity`, `olife_sandbox_binary_json` (JSON-строки), `olife_play_dry` (сухой прогон пути игрока, Rust-шлюз) — **все ok** (`20261003_0121…–0125…`) |
| `cargo test --release` sandboxd (Linux) | binary 6, sandbox 15, script_api 5 — ok |

Не сделано: Luau-рантайм API не получил; ответ на запрос не тарифицируется по размеру (цена — по запросу); «отклонённое — 50 %
цены» не введено; анимации/звуки активов (`asset:<sha>`) проверены только кодом (резолвер A4), прогоном — паковые.

## B3: тарифы вживую после волны A (03.10, агент olife_b3)
Движок не менялся, ядро лаборатории и демон не трогались, Rust `sandboxd` не менялся (exe тот же, sha256 `2854f9ab…`);
правка — только шим `lua-wasm/sandbox.c` (новый `olife_lua.wasm`, sha256 `f4207466…`, выложен в `D:\Prog\Olife\sandboxd`
с `.bak` прежних файлов, README раскладки не трогался).

**Факт.** `olife_tariff_live` после волны A — красный 5 из 5 (`…011308`, `…011955`, `…012440`, `…013740`, мой `…033929`):
шаг 4 `owner 9101 throttled from tick 221, limits applied at tick 220`. Строки `olife_tariff_rows_0.jsonl`: такт 220 (первый
с новыми лимитами по `applied_tick` сервиса) — `ok`, 103 736 топлива на 2 сущности (как до смены), 221 — `throttled` 51 808.
Доставка `set_limits` — 3 команды ctl за 3 мс между тактами 219 и 220 мира (`service_ticks` 62 в метке = `changed_after_ticks`
62 сервиса), т. е. порядок «ctl → TickInput» и `applied_tick` верны: сервис действительно считал такт 220 с лимитами
20 000 / 20 000 / 0.

**Причина — не волна A как таковая, а фаза count-хука.** Бюджет сущности проверяется только в count-хуке Lua (каждые
`hook_count` = 250 VM-операций); счётчик — у корутины сущности и переносится между тиками; `on_tick` orbit ≈ 100–125 операций,
так что хук срабатывает в нём раз в 2–3 тика. Доказательство сервисом без мира (`target/release/olife-sandboxd`, JSON-строки +
ctl, те же 2 orbit 9101 + 2 orbit 9102, 62 тика до `set_limits`): такт 220 — `fuel_available` 20 000, `bucket` 0, бюджет 10 000 на
сущность, обе `ok` по ~49 тыс.; счётчик вызовов `host_fuel_used` на сущность (временная трассировка) — **0 в такте 220, 1 в 221**
(`max_used` 22 758 > 10 000 → yield). Число тиков до `set_limits` 60/61/62/63/64/65 → первый тик с лимитами
`ok/throttled/ok/throttled/ok/throttled`. До волны A сценарий попадал на «тик с хуком» (`applied_tick` 221 = первый `throttled`
221, `…211013`), A3 изменил пролог (`prelude.lua`: `M.input`, методы `self`) → число VM-операций на тик orbit, фаза на 62-м тике
сдвинулась на «пустой» тик. Вернуть «прежний порядок» нечего — порядка не было, была удача фазы.

**Правка.** `lua-wasm/sandbox.c` `tick_impl`: после завершения `on_tick` (yield TICK_END) проверка `host_fuel_used() > budget` →
статус `throttled`, действия остаются в carry, в записи сущности флаг `held`; следующий тик сущность не выполняется, отдаёт
накопленное со статусом `ok`. Наблюдаемо — как вытеснение на последней инструкции, но детерминированно: перерасход виден в том
такте, где случился. Для `wait/sleep` проверки нет. Тест `tests/sandbox.rs::over_budget_short_run_is_throttled_in_the_same_tick_
whatever_the_hook_phase` (фазы 1..6): `cargo test --release` — binary 6, sandbox 16, script_api 5 ok. Сервис без мира после правки:
60..65 тиков до `set_limits` → первый тик с лимитами всегда `throttled` 2/2. Справочник — `/root/olife/sandboxd/README.md`
«Как устроено» п. 1 и раздел «B3».

| `olife_tariff_live` после правки | svc_ticks при смене | первый `throttled` = `applied_tick` | `throttled` строк 9101 | ход/строку, топливо/строку | 9102 | ключи удалены → `ok` |
|---|---|---|---|---|---|---|
| `20261003_035434_…_vc` | 61 | 219 = 219 | 36/58 (62 %) | 2.0 → 0.77, 125 → 82 тыс. | 0 | 277 (applied 278) |
| `20261003_035509_…_vc` | 62 | 220 = 220 | 36/58 (62 %) | 2.0 → 0.77, 125 → 82 тыс. | 0 | 280 = 280 |
| `20261003_035528_…_vc` | 62 | 219 = 219 | 36/59 (61 %) | 2.0 → 0.79, 125 → 81 тыс. | 0 | 279 = 279 |
| `20261003_035547_…_rs` (`--impl rs`) | 61 | 218 = 218 | 36/59 (61 %) | 2.0 → 0.79, 125 → 82 тыс. | 0 | 278 = 278 |

Рисунок статусов 9101 после смены — `oToTToToTToTTo…`: T после T — вытеснение хуком посреди кода, затем дорезанный тик снова
дороже бюджета → `held`. **Что изменилось для игрока:** моб, чей тик дороже тарифа, но короче периода хука, раньше работал
«бесплатно» до случайного срабатывания хука (волна 4b: `throttled` 36 % строк, ход 2.0 → 1.3, топливо 117 → 92 тыс.), теперь
каждый такой тик — `throttled`, результат приходит тактом (50 мс) позже: `throttled` 61–62 % строк, ход 2.0 → 0.78, топливо
125 → 82 тыс. Сам момент начала троттлинга не сдвинулся — он теперь гарантированно `applied_tick` (следующий такт сервиса после
доставки, 2.6–3.3 мс), сценарий и `within: 1` не менялись. Бюджет остаётся мягким: перерасход одного прогона не списывается
с последующих тиков (orbit под тарифом 20 тыс. всё ещё жжёт ~82 тыс./строку на 2 сущности); честный долг — отдельное решение.

Регресс на выложенном wasm (тот же код мира): `olife_sandbox_real`, `olife_sandbox_bin`, `olife_script_api`, `olife_store`,
`olife_negative`, `olife_restart`, `olife_consistency` — **все ok** (`20261003_0356…–0400…`, пути в отчёте агента).

## UX B: меню клиента, экран статуса, вайтлист (16.10, olife_menu)
Постановка — `agents/OLIFE_UX.md` §8 (пп. 1–3). **Движок не менялся** (стоковый 0.32 + F2F-сборка для тестов), протокол не
менялся (новых сообщений нет; Rust-шлюз не пересобирался), Rust-шлюз проверен `--impl rs`. Ядро демона не перезапускалось;
правлены `labcore/cli_sup.py` (клиентский CLI — действует сразу) и `labcore/supervise.py` (секция Whitelist панели — у живого
демона после `lab daemon upgrade` главной сессией; `lab daemon status`: `stale`, restart_only). lab.toml не менялся — каталог
стокового 0.32 переименован пользователем (`voxelcore-0.32.0_dc62ccfb`), olife перекрывает `[engines.v032]` в своём
project.toml (07.10 `lab play olife` из-за этого падал «exe not found»).

**П.1 — экран загрузки и статуса входа (сделано).** Страница `layouts/pages/olife_status.xml` (меню) и тот же макет
`layouts/olife_status.xml` (постоянный элемент HUD в игре). Источник — `olife_client:status` (фазы, прогресс, ошибка,
баннер, журнал; подписка/`seq`), рисует только `status_view`; публикуют `login` (вход из меню), `play.run_world` (паки на лету,
переподключение), `packs` (прогресс, структурные ошибки). Вход теперь в порядке постановки: билет -> TCP+Hello -> Welcome ->
манифест -> файлы (файлы/байты/полоса/текущий файл, до 4 параллельно) -> sha256 каждого -> **мир-реплика открывается после
паков** (изменённые — в `world:content`, `save_world` + `reopen_world`) -> первые чанки -> игра. До мира сокет живёт в режиме
«пролога»: KeepAlive отвечает, Welcome/PacksChanged откладывает, остальное копит и проигрывает по порядку после открытия мира
(согласованность реплики та же). Ошибки — строка `[kind code]` + причина как пришла, «Повторить» / «Назад».

| `olife_menu_status` (F2F 0.32 hidden/realtime 854×480; ПК свободен по `lab sysload`) | итог |
|---|---|
| `20261016_021147_olife_olife_menu_status_vc` (до него ещё 4 зелёных подряд), `--impl rs`: `20261016_021329_olife_olife_menu_status_rs` | **ok 21/21 проверок** (оба шлюза), ≈65 с |
| меню движка -> «Сценарии» -> olife -> меню клиента (автозаполнение) -> «Выход» -> меню движка | ok |
| меню: VCM-сценка (`olife_menu_scene`, ~3.6 тыс. треуг.), камера 35° -> 40.8° за 0.8 с (8°/с), автозаполнение; плохой ник -> подсказка, вспышка, звук `refuse`, входа нет | ok |
| вход: 10 фаз, все «ok»/«пропуск» по строкам страницы; правка раздачи до входа -> скачан 1 файл, sha256 1/1, мир с паками из `world:content`, `rev = 5` в игре | **1.54 с** от «Войти» до игры: билет 48 мс, TCP 13, Welcome 49, манифест (124 файла, сверка sha256 с паками клиента) 62, файлы 14, мир (new_world + reopen + игрок HUD) 1384, чанки 0 (8 уже в накопленном) |
| в игре: паки вживую (`rev = 6`) — HUD: манифест -> файлы -> sha256 -> «вживую», баннер «Паки обновлены на лету», без переподключения | 1.2 с от правки (опрос шлюза 1 с) |
| в игре: `scripts/world.lua` (не вживую) — переоткрытие мира, вход заново (билет -> шлюз -> Welcome), «Снова в игре» | 2.1 с |
| в игре: мир стоп/старт — «Мир перезапускается, держитесь (вход через 3 с)», фазы переподключения, «Снова в игре (сессия 3)» | 5.5 с (мир лежит ~3 с) |
| ошибки (9) на экране статуса, код и причина | нет сервера `[no_server tcp]` WSA 10061 (2.0 с); шлюз молчит `[timeout welcome]` (10 с); сервис билетов лежит `[auth_down http 0]` -> поднят -> «Повторить» -> игра; чужой токен `[ticket auth] bad token`; бан (`lab olife ban`-путь, БД) `[banned banned] banned until … reason` -> unban -> «Повторить» -> игра; вайтлист `[whitelist whitelist]` -> add -> «Повторить» -> игра; ник аккаунта с токеном `[ticket nick_reserved]`; файл изменён после манифеста `[download 409]`; подмена файла в пути (посредник) `[sha256 sha256] olife_client/modules/hot/rev.lua: в манифесте e40a…, получено 40f5…` |

**П.2 — главное меню клиента (сделано).** «Сценарии» -> `olife` (и `--script` рантайма `lab play olife`) открывает
`layouts/pages/olife_menu.xml`: `<modelviewer src="olife_menu_scene">` — VCM из моделей пользователя (бенч `cmd`, кость, Injector,
GravityGun, Спамер, шар на полу из досок; `tools/olife/gen_menu_scene.py`), медленное вращение камеры (пересоздание узла:
Lua видит только `src`); поля ip:port и ник, «Войти», последние серверы (6, с данными сервиса билетов), «Выход»;
`config:olife_client/menu.json` (без токена). `export:olife_server.txt` — автозаполнение (адрес, ник = аккаунт файла, сервис
билетов, токен — только для ника аккаунта файла), перечитывается на каждом «Войти». Обратная связь §1: вспышка кнопки + звук
(`fx`). Сухой прогон: `--autologin 1` (вид `play_client`); `olife_play_dry` — ok (`20261016_021021_olife_olife_play_dry_vc`,
те же шаги и числа, что раньше: билет 1, примеры RUN, редактор, гравипушка, UX round 1). Стоковый `VoxelCore.exe` агент не
запускал: пользователю — `play.bat` (окно откроется на меню клиента, поля заполнены, «Войти»); `D:\Prog\Olife\README-play.md`
обновлён.

**П.3 — авторизация, минимум: вайтлист по нику (сделано).** Сервис билетов принимает `{name, gateway}` без токена и спрашивает
supervisor (`POST /call/olife.auth_name`): синтаксис ника (`bad_name`), ник аккаунта с токеном занят (`nick_reserved`), бан
(`banned`), вайтлист сервера (scope = id шлюза билетов, `*` — все) -> `whitelist`; иначе аккаунт создаётся/обновляется. Токен в
игровой сокет по-прежнему не идёт (в Hello — билет). Управление: `/whitelist list|add|remove|on|off` админа в чате (мир -> HTTP
демона, ответ OpResult, op-строка в чате, аудит мира) = `lab olife whitelist …` = кнопки панели (секция Whitelist, после
upgrade) = `lab olife op whitelist …`; журнал `artifacts\lab\olife\whitelist_audit.jsonl`.
`olife_menu_whitelist` — **ok 20/20** (`20261016_020956_olife_olife_menu_whitelist_vc`, `--impl rs`:
`20261016_021303_olife_olife_menu_whitelist_rs`): чат `/whitelist on|add|list` (0), игрок -> 16, op-строки 2, CLI, панель
(POST via=panel), op лаборатории, аудит chat/cli/panel; меню: ник в списке -> игра; не в списке -> «нет в вайтлисте» -> add ->
«Повторить» -> игра; вайтлист выключен -> любой свободный ник.

**Варианты авторизации (для решения пользователя):**
| | (а) ник + вайтлист (сделано) | (б) ник + пароль, регистрация | (в) инвайт от опа |
|---|---|---|---|
| вход | ip:port + ник | ник + пароль; регистрация в меню | одноразовый код от опа -> ник закреплён |
| безопасность | ник никто не защищает: кто знает ник из вайтлиста, тот войдёт под ним (в своей сети/с друзьями — норм) | хэш (scrypt/argon2) в БД supervisor, лимиты попыток и баны уже есть в сервисе билетов; без TLS к сервису — только запечатанный запрос (есть) | код одноразовый и короткоживущий; после — нужен (б) или токен аккаунта на машине игрока |
| работа опа | `/whitelist add <ник>` | ничего (самостоятельная регистрация) или модерация | выдать код каждому новому игроку |
| в коде | 1 возможность + поле `name` в билете | + таблица паролей, `/ticket {name, password}`, смена/сброс пароля, поле в меню | + таблица инвайтов, `/redeem`, привязка ника, затем вход как (б) или по токену |
Рекомендация: (а) уже закрывает «пустить друзей»; если сервер станет публичным — (в) как регистрация + (б) как вход.

**Доработка по кадру координатора (16.10, 02:20–02:33):** после входа с переоткрытием мира поверх игры висела пустая панель
(заголовок «Olife», серая полоса, «Назад»). Причины: корень постоянного HUD-элемента движок каждый кадр делает видимым
(прятать надо вложенную `st_panel`), и макет HUD после reopen мог зарегистрироваться в экземпляре модуля вида с чужой
таблицей. Исправлено: реестр документов — в общей таблице статуса, панель скрыта до отрисовки из состояния, после «В игре»
показывает заполненные строки 1 с и скрывается. В `olife_menu_login` добавлен гейт: через 1 с и 3 с после входа — если
панель статуса (HUD или страница) видна, в ней есть строки фаз и не заголовок по умолчанию; через 3 с без баннера HUD-панель
скрыта; снимки `*_login_normal_1s/_3s`. Прогоны: `20261016_023001_olife_olife_menu_status_vc` и
`20261016_023118_olife_olife_menu_status_rs` — 21/21 (1 с и 3 с: панель скрыта, в состоянии 10 строк), `olife_play_dry` —
`20261016_023236_olife_olife_play_dry_vc` ok (промежуточный прогон 02:28 на недоделанной версии упал на захвате гравипушкой,
на итоговой не повторился).

Прогоны регресса после правок (тот же день): `olife_play_dry`, `olife_auth_ticket` (+ rs), `olife_chat` (+ rs),
`olife_packs_reload`, `olife_op`, `olife_editor`, `olife_consistency`, `olife_restart` — ok.
Не сделано / замечено: проверка раскладки только на 854×480; модели сценки — то, что есть в паке (своих новых нет);
тестовые входы по нику оставляют строки аккаунтов `nick login (UX B whitelist) gw-s…` в общей БД supervisor (удаления
аккаунтов через демон нет); в каталоге `voxelcore-0.32_dc62ccfb\content` остались junction'ы от неудачного запуска 07.10
(не моё — не трогал); экран статуса в игре закрывает обзор на время баннера (2.5–3 с) — можно сделать компактный вариант.

## Каретка редактора (16.10, olife_caret)
Постановка — `OLIFE_UX.md` §9 п.1 (скриншот пользователя 16.10: курсор в конце строки `-- Пример Olife: облёт по кругу.
on_tick(dt) вызывается 20 раз в секунду в песочнице.` стоит под словом «секунду»). **Движок не менялся**, ядро лаборатории
и серверный стек не трогались; одна аренда F2F-клиента `olife menu_app` (владелец `olife_caret`, без шлюза), освобождена.

**Причина (по исходникам 0.32 `voxelcore-032`, коммит 11909814 = `hello.build.commit` F2F-сборки, и доказано запуском).**
`TextBox` считает x каретки, выделения и индекс под мышью через `FontMetrics::calcWidth`; у шрифта с флагом FreeType
`FIXED_WIDTH` (DejaVu Sans Mono — моноширинный) это `символы × glyphInterval`, а `glyphInterval = size/2` = **8 px**. Рисует же
`draw_text` каждый видимый символ с шагом `glyph->xAdvance` = FreeType advance = **10 px** (0.602 em × 16, хинтинг), пробел —
8 px. Итог: каретка левее на 2 px × число непробельных символов до неё — одинаково для ASCII, кириллицы и смеси (гипотеза (а)
«кириллица/байты UTF-8» не подтвердилась: индекс — кодовые точки, сдвиг тот же на чистом ASCII), номера строк сдвигают текст и
каретку вместе (гипотеза (б) — нет), padding тоже (в) — нет. Стоковый шрифт (битмап 8 px) — сдвиг 0.

**Обход паком.** `content/olife_client/fonts/olife_mono.ttf` заменён (sha256 `19d85aa6…`, было `39c29931…`; исходник —
`artifacts/olife_caret_bak/olife_mono.ttf.orig_dejavu_sans_mono`): DejaVu Sans Mono, контуры сжаты по x в 1024/1233, advance всех
глифов 1024/2048 = ровно 0.5 em (8 px при `size` 16 = `glyphInterval`), `fpgm/prep/cvt`/программы глифов и GPOS удалены, имя
«Olife Mono»; в каждый простой глиф добавлен нулевой контур (3 совпадающие точки) в x = 0 — 0.32 кладёт битмап глифа в позицию
пера без `bitmap_left`, и без якоря все буквы прижаты к левому краю ячейки (`on_tick( dt)` с дырой); с якорем буква стоит, как
задумана шрифтом. Имя шрифта в XML, `size` 16 и `preload.json` не менялись. Заодно `editor.xml`: `onclick` поля кода —
`if not document.code.focused then … end` (в 0.32 `focused = true` у уже сфокусированного узла **снимает** фокус).
Отвергнуто: `post.isFixedPitch = 0` (немоноширинная ветка `calcWidth` суммирует advance) — каретка верна, но выделение, клик и
горизонтальная прокрутка 0.32 меряют от начала **всего текста**, а не строки (`calcWidth(labelText, 0, n)`): на строках 2–3 конец
выделения −10/−8 px, клик — на символ правее (вариант 5/6 ниже).

**Проверка** (F2F 0.32 hidden/realtime; проба `tools/scenarios/olife_caret_probe.lua` — app-скрипт аренды `menu_app` грузит паки
клиента + тестовый `content/olife_caret_probe` (варианты шрифтов, страница `caret_editor` с `<iframe src="olife_client:editor">`),
текстовые поля как в редакторе (multiline, syntax lua, text-wrap false, padding 6, `keep-line-selection`) с тремя строками:
ASCII / кириллица / смесь (строка пользователя); раннер `tools/scenarios/olife_caret_run.py`: каретка — столбец чисто белых
пикселей ≥ 14, выделение (Shift+End через F2F `input`) — столбцы с аддитивной синевой, «перо» — x конца строки по правилу
`draw_text` (пробел 8 px, прочие — advance шрифта), клик ЛКМ в середину 21-го символа → `caret` из лога пробы.
Отклонение каретки и конца выделения от пера, px (строки 1/2/3), и индекс после клика (надо start+21):

| вариант | 854×480 | 1920×1080 | клик |
|---|---|---|---|
| 1/2: `olife_mono` как было (DejaVu, с номерами / без) | **−82 / −80 / −90**, выделение то же | **−148 / −144 / −144** | +3…+4 символа |
| 3/4: стоковый шрифт | 0 / 0 / 0 | — | точно |
| 5/6: DejaVu `isFixedPitch=0` | каретка 0; выделение 0 / **−10 / −8** | — | 2–3 строки: +1 |
| 7/8: сжатый 0.5 em | 0 / 0 / 0 | — | точно |
| 9/10: сжатый + якорь (= новый `olife_mono`) | 0 / 0 / 0 | 0 / 0 / 0 | точно |
| 1/2 **после замены** `olife_mono` | 0 / 0 / 0 | 0 / 0 / 0 | точно |
| 11: настоящий документ `olife_client:editor`, до → после | −82/−80/−90 → **0/0/0** | — | +3…+4 → точно |

Кадры (`artifacts/olife_caret/`): до — `variants_854/v1_l3_caret.png` (повтор скриншота пользователя: каретка в «секунду»),
`before_1920/v1_l3_caret.png` (полная строка пользователя), `before_854_editor/v11_l*_{caret,sel}.png` (настоящий редактор);
после — `after_854/`, `after_1920/`, `after_854_editor/v11_l3_sel.png` (выделение точно по строке); варианты — `variants_854/`
(все 10), цифры — `measure.json` в каждой папке. Манифест паков (`artifacts/lab/olife/packs_manifest.json`) пересобран
`lab call olife.packs` (в старом был sha прежнего шрифта — клиент с загрузкой паков отверг бы новый файл).
Не сделано / открыто: (1) буквы стали уже (8 px вместо 10 при той же высоте); шире без потери совпадения — только вместе с
высотой строки (`size` 18/20 в `preload.json` → ячейка 9/10 px, строка 27/30 px) — решение за пользователем; (2) в 2 из ~11
запусков пробы F2F-клиент 0.32 падал `0xC0000005` при переключении полей/клавишах Shift+End (вариант 6 и 2; причина не найдена,
повтор тех же шагов — без сбоя); (3) правка движка, которая убрала бы обход (предложение, не делалась): `Font::getMetrics()` и
`FontMetrics::calcWidth` — брать advance глифов и для моноширинного TTF (или `glyphInterval` = advance), а в `TextBox`
считать выделение/клик/прокрутку от начала строки (`labelText.substr(lineStart)`), как уже сделано для каретки.

## Антифрод и бан по IP (16.10, olife_antifraud) — `agents/research/OLIFE_ANTIFRAUD.md`
Постановка пользователя 16.10: «авторизация по нику, нужен бан по ip и антифрод система» (вход по нику без пароля — §8 п.3
`OLIFE_UX.md`; кредо §9 — лимиты и автоматика, а не запреты). **Движок не менялся.** Протокол — без новых сообщений: новые
значения `Disconnect.code` 18 и `Notice.event` 13/14 (код 22) только в комментариях `client.yaml`, `gen_codecs.py --check
--lang all` — «up to date». **Rust-шлюз изменён и пересобран** (`cargo test` 23/23 в WSL, `tools/win_build.sh test` 22/22 на
Windows), exe разложен в `D:\Prog\Olife\gateway\` (sha256 `2d5aa79d…`; старый — `artifacts/olife_antifraud_bak/
olife-gateway.exe.20261003`, sha256 `f4036585…`). В `tests/codecs.rs` число векторов 304 → 376 (поздние волны не обновили).

**П.1 — бан по IP везде.** Один источник — таблица `bans` супервизора (kind `ip`, значение — адрес или CIDR в каноническом
виде `127.0.0.64/26`, срок, причина, by). Применяется: сервис билетов (вход по нику — внутри `olife.auth_name`, по токену —
`POST /call/olife.ip_check`; код `ip_banned`, причина «бан по IP <сеть> до <время>: <причина>», поле `until`); оба шлюза —
при приёме TCP **до Hello** (Disconnect 5 «banned by IP … until …») и на живых сессиях; список шлюзы берут вызовом
`POST /call/olife.gw_sync` раз в 2 с (сессии и события лимитов — вверх, баны с причиной/сроком и настройки — вниз; запасной
путь — прежний `GET /sup/bans`, теперь с CIDR). Выдача бана — немедленный kick: мир выбивает свои сессии с адреса, плагин
шлёт F2F `kick_ip {nets, ban}` всем живым шлюзам olife (выбить и сразу внести в список, не ждать сводки). Управление:
`/ban ip <addr|cidr> [мин] [причина]`, `/unban ip <addr|cidr>`, `/bans` админа в чате = `lab olife ban --ip <addr|cidr> <мин>
<причина> [--force]`, `lab olife unban --ip`, `lab olife bans` = кнопки панели (Ban IP/CIDR…, Unban). Бан сети, накрывающей
`exempt` (127.0.0.1 — локальный игрок и боты), без `force` отвергается (`exempt`). Аудит: `artifacts/lab/olife/
fraud_audit.jsonl` (via chat|cli|panel|auto) + аудит мира. IP мир знал и раньше (`Attach.addr` — «ip:port»): новая `/players`
показывает его админу полностью, игроку — маской `127.0.x.x`; IP игроков — и в `sup_state.ops.players[].ip` для панели.

**П.2 — антифрод.** Настройки — `account_settings` `_fraud:cfg` (живые: `lab olife fraud set <k> <v|default>`, `/fraud set`,
кнопки панели); умолчания:

| группа | ключи и умолчания |
|---|---|
| общее | `enabled` 1, `exempt` `127.0.0.1/32` (лимиты, автобаны и санкции скоринга их не трогают; ручные баны — да) |
| вход | `ticket_rate_ip` 20 / `ticket_rate_net` 60 за `rate_window_s` 60 (подсеть `net_prefix` 24, IPv6 `net_prefix6` 64), `nicks_per_ip` 4 за `nicks_window_s` 600, `sessions_per_ip` 3, `nick_grace_s` 300 |
| шлюзы | `conn_rate_net` 60/с (всплеск ×3), `gw_limit_events` 5 отказов с IP за сводку → автобан |
| автобан IP | `autoban_base_s` 60 × `autoban_factor` 2^(страйк−1), не больше `autoban_max_s` 86 400; страйки забываются через `strike_forget_s` 86 400 |
| скоринг (мир) | веса `w_chat` 1, `w_cmd` 1, `w_action` 1, `w_req` 1, `w_spawn` 2, `w_reconnect` 3 (входы сверх `reconnect_free` 3 за `reconnect_window_s` 60); полураспад `score_half_life_s` 30; пороги × доверие: `warn` 10, `throttle` 20 (на `throttle_s` 15 чат/блоки/запросы отбрасываются и тоже дают очки), `kick` 35, `ban` 50 (`ban_base_min` 5 мин × 2^(страйк−1); со страйка `ip_after_bans` 2 — и бан IP) |
| доверие | `fraud clear` умножает на `trust_step` 2 (до `trust_max` 8) |

- **Защита ника:** зарезервированные (`admin, op, operator, server, root, system, console, world, olife, moderator, mod, owner,
  support, null, guest, fraud, supervisor`) → `nick_reserved`; «скелет» (регистр, кириллица/греческий → латиница, `0→o 1→l 3→e
  4→a 5→s…`, без `_ . -`) совпал с чужим аккаунтом → `nick_similar` («ник «c4rol» слишком похож на существующий «carol»»);
  ник в игре с другого IP → `nick_in_use` (билет) и Disconnect **18** (шлюз; с того же IP новый вход по-прежнему заменяет
  старый, 12); после выхода ник закреплён за IP на grace → `nick_in_use`, снимается `fraud clear nick:<ник>`; имя в Hello —
  только ASCII `[A-Za-z0-9_.-]` (оба шлюза; `аdmin` → 4).
- **Лимиты входа:** `rate_ip`, `rate_net`, `multi_account`, `sessions_ip` (сервис билетов), 13 (шлюз: сессии с IP, соединения
  с /24); превышение → страйк и автобан IP 60 с → 120 с → …, запись `bans` by `fraud` «автобан: <правило> (страйк n, N с)».
- **Скоринг в игре** (`fraud.lua`, на аккаунт): события — строка чата сверх ведра, команда сверх частоты, блок сверх ведра,
  запрос редактора/инструмента сверх ведра (`editor.bucket req_b`), спавн сверх `spawn_per_min`, переподключения в цикле;
  пороги → Notice 13 (тост + `fx_throttle`) → Notice 14 + throttle → kick 10 «antifraud: N points (…)» → автобан (бан мира +
  `olife.fraud report` → бан аккаунта в БД со сроком по страйкам; второй — ещё и IP). Мир раз в 5 с берёт настройки, доверие
  и снятия (`olife.fraud cfg`) и отдаёт свои очки (для панели и `fraud status`).
- **Прозрачность:** `/fraud [status|events|clear|set|trust]` (админ; игрок — 16), `lab olife fraud status|events|set|clear|trust`,
  секция Antifraud панели (очки миров, автобаны и баны IP с кнопкой «Снять»/Unban, ручки, события) — **в живом демоне после
  `lab daemon upgrade`** (шаблон в `labcore/supervise.py`; проверен отрисовкой в node на настоящем ответе `olife.fraud status`).
  `fraud clear <аккаунт>` снимает автобаны аккаунта и его IP, страйки, обнуляет очки в мире, доверие ×2.

| проверка (16.10, F2F 0.32 hidden/realtime 854×480; рядом работал агент olife_caret со своей арендой) | итог |
|---|---|
| `olife_ipban` (`20261016_131144_olife_olife_ipban_vc`, `…_131225_…_rs`) | **26/26** оба: `/players` админ/игрок, `/ban ip` → жертва выбита за 0.15–0.2 с (Disconnect 5 «бан по IP … до …»), строка БД (+5 мин), билет по нику и по токену → `ip_banned`, Disconnect 5 до Hello, CLI CIDR `127.0.0.70/26` → `127.0.0.64/26`, 127.0.0.100 отказ / 127.0.0.130 билет, бан `127.0.0.0/24` → `exempt`, `/bans`, Unban панелью, игрок `/ban ip` → 16, `/unban ip` → вход, аудит chat/cli/panel, аудит мира; меню-клиент через проброс с 127.0.0.77: `[banned ip_banned]` → unban → «Повторить» → игра → бан в игре → `[banned 5] бан по IP …` |
| `olife_antifraud` (`20261016_130050_olife_olife_antifraud_vc`, `…_130140_…_rs`) | **50/50** оба: ник 15/15, лимиты 14/14 (автобан 60 → 120 с), скоринг 15/15 (13 → 14 → kick 10 → автобан 5 «страйк 1»; 2-й — «страйк 2» + IP; `/fraud`, 16; `fraud status`; clear → доверие ×2 → тот же флуд без предупреждения; переподключения 3, блоки 13 в очках), обход 5/5 |
| регресс (тот же день, после последней правки) | ok vc и rs: `olife_auth_ticket`, `olife_menu_whitelist`, `olife_menu_status`, `olife_op`, `olife_chat`, `olife_negative_proto`, `olife_play_dry`; ещё `olife_consistency`, `olife_editor` (vc) |

`olife_menu_status`: случай `nick_reserved` теперь вида `nick` («ник недоступен»), а не `ticket` (ожидание в `olife_menu.py`
обновлено). `olife_spammer` падает в коде лаборатории (`olife_b2.py:413` `W()._kv` — у `editor_w4a` нет `_kv`; падал и 03.10),
к антифроду не относится, не правился. Тестовые записи сняты (`olife_fraud_cleanup` + страховка в `sc_finish`; 30 аккаунтов
моих прогонов `olife_menu_*` удалены `reset_test`).

## Игра с друзьями (16.10, olife_friends) — `agents/research/OLIFE_PUBLIC_PLAY.md`
Постановка пользователя 16.10: «я может и с кентами хочу». **Движок 0.32 не менялся.** Протокол — аддитивно: `client.InfoRequest`
(c2s 7) / `client.ServerInfo` (s2c 76), Disconnect 19 «server info sent»; кодеки Lua/Python/Rust перегенерированы
(`gen_codecs.py --lang all`, векторов 376 -> 384, `--check` — up to date). **Rust-шлюз изменён и пересобран** (`--public` флагом
или значением, `--packs-public`, `--info`, `InfoRequest`; `cargo test` 24/24 в WSL и на Windows, exe
`D:\Prog\Olife\gateway\olife-gateway.exe` sha256 `76f55001…`, прежний — `artifacts/olife_friends_bak/olife-gateway.exe.before_friends`).
Ядро демона не менялось (правки `labcore/cli_sup.py`, `labcore/cli2b.py` — клиентский CLI, действуют сразу; `lab daemon upgrade`
не нужен); `lab.toml` не менялся.

**П.1 — публичный режим.** `play.bat public` = `lab play olife --user --public` (= `--opt public`, `[play.options.public]`);
без окна — `play.bat server public` = `lab olife play-up --public`. Шлюз (`gateway_rs_public`), сервис билетов (`auth_public`,
`auth_service.py --public 1`) и раздача паков — `0.0.0.0` на **фиксированных 27750 / 27751 / 27752** (`[play.public]` проекта,
перекрытие `D:\Prog\Olife\play\server.toml [public]`; 25700–25702 из постановки заняты демоном, диапазон выбран вне демона,
пула, тестовых и изолированных демонов и их аренд). Перед подъёмом — проверка портов (диапазоны лаборатории, `netstat`, `bind`).
admin/f2f всех служб и демон — 127.0.0.1 (проверено netstat). Внутренний порт мира — 0.0.0.0 у самого движка (`network.tcp_open`
без адреса): пак мира закрывает не-loopback соединение сразу (`olife_world:net`). Локальный режим без флага — как был.

**П.2 — друг знает только ip:port и ник.** Меню клиента для адреса не из файла автозаполнения спрашивает шлюз:
`InfoRequest` -> `ServerInfo{name, gw_id, auth_port, auth_scheme, auth_pub, packs_port, public, whitelist, motd}` (файл
`server_info.json` пишет `play_up`, шлюз перечитывает его на каждый запрос) -> адреса билетов и паков = набранный хост + порты;
`PacksChanged.url` с петлёй клиент переписывает на хост шлюза. Ключ: отпечаток в строке приглашения (`ip:27750#` + 12 символов
ключа) -> `[server_key fingerprint]`; без него — TOFU (ключ в «последних серверах», смена -> `[server_key key_changed]`,
«Повторить» = принять); токен из файла не уходит к чужому ключу (`token_pin`). Сертификат сервиса билетов по-прежнему
самоподписанный, `verify_ssl=false`, доверие — запечатанный запрос к ключу. Старый шлюз (Disconnect 3/молчание) -> откат на
прежние данные; нет данных -> `[no_info]`. Модель угроз — `OLIFE_PUBLIC_PLAY.md` §3–4 (игровой канал и манифест паков без
шифрования/подписи: через интернет — VPN).

**П.3 — приглашение без токена.** `play.bat friend НИК` = `lab olife invite НИК`: ник в вайтлист `gw-olife-play` + строки
`LAN:27750#fp`, `внешний:27750#fp` (`lab olife ip`: LAN — `Get-NetIPAddress`, VPN 26.x/100.64/10 подписаны, внешний — echo-сервис
`api.ipify.org`/`ifconfig.me`/`icanhazip.com`, «НЕ УДАЛОСЬ УЗНАТЬ», если ни один не ответил). Вайтлист включается в публичном
режиме. `sessions_per_ip` = 3 оставлен (друзья за одним NAT — `lab olife fraud set sessions_per_ip 6`), `127.0.0.1` в `exempt`.
Старый способ (аккаунт с токеном) — `play.bat friend-token ИМЯ`.

**П.4 — сборка другу.** `lab olife bundle [--out D:\Prog\Olife\dist] [--invite ip:port#fp]` = `play.bat bundle`: стоковый
`VoxelCore.exe` 0.32 + `res` (в нём `base`) + `ORIGIN.txt`, **копии** `content\olife_client`, `content\olife_proto` (без
`.bak`/`__pycache__`/проб; шрифт `olife_mono.ttf` есть), `settings.toml`, `OLIFE.bat` (`VoxelCore.exe --dir "%~dp0." --script
"%~dp0content\olife_client\scripts\app\olife.lua"`), `ПРОЧТИ.txt` (10 строк), `olife_bundle_manifest.json` (sha256 паков =
раздаче сервера). Итог — ниже.

**П.5 — инструкция хосту** — `D:\Prog\Olife\README-play.md` «Игра с друзьями по сети» (порты, брандмауэр `netsh advfirewall`
— команда для пользователя, агент правило не добавлял; проброс TCP 27750–27752 или Radmin VPN/ZeroTier/Tailscale; CGNAT; что
сказать другу; `/players`, панель; бан; логи).

| проверка (16.10, F2F 0.32 hidden/realtime 854×480; LAN-адрес хоста 172.30.205.71 — Wi-Fi, вход на него с этого же ПК) | итог |
|---|---|
| `olife_public` (`20261016_134742_olife_olife_public_vc`; до него зелёный `…_133848_…`) | **ok 32/32 + 8 проверок меню**, 46 с: netstat — шлюз 0.0.0.0:27750/27752, билеты 0.0.0.0:27751, admin/f2f/песочница/демон 127.0.0.1, порт мира 0.0.0.0 (движок) закрывает соединение с LAN-адреса за 1 мс; ServerInfo на `172.30.205.71:27750` (gw_id, порты, ключ = ключу сервиса, public, whitelist) + Disconnect 19, манифест и `/health` по LAN; друг без файла автозаполнения: `172.30.205.71:27750#fp` + ник из вайтлиста -> игра за 0.76 с (10 фаз ok, «сервер «Olife», билеты :27751, паки :27752»); `/players` админа: `kent1 … 172.30.205.71`; повтор без отпечатка (TOFU) -> игра; не в вайтлисте -> `[whitelist]`; сервис билетов остановлен -> `[auth_down http 0]` -> поднят -> «Повторить» -> игра; чужой отпечаток -> `[server_key fingerprint]`; второй клиент тем же ником с того же адреса -> игра, первому Disconnect 12 «дубликат входа» |
| `olife_bundle` (`20261016_135607_olife_olife_bundle_vc`) | **ok 15/15 + вход**: zip -> распаковка в `artifacts`, нет junction/ссылок, `.bak`, `__pycache__`, проб; exe = стоковый 0.32 (sha256), `res\content\base`, оба пака, `olife_mono.ttf`, `OLIFE.bat`, `ПРОЧТИ.txt` (10 строк), `vctest.exe` нет; манифест паков распакованной копии = раздаче сервера (`packs_manifest.json`); F2F 0.32 с `--dir` распакованного каталога и `--script` из `OLIFE.bat` (latest.log: user files folder = распакованный каталог) -> меню без автозаполнения -> вход по `LAN:27750#fp` -> игра -> меню |
| регресс после последней правки клиента (vc / `--impl rs`) | ok: `olife_menu_status` 21/21 (`…_134621_…_vc`, `…_134830_…_rs`; «нет сервера» 3.95 с, «шлюз молчит» 15 с — +3 с на запрос сведений до отката), `olife_menu_whitelist` (`…_135001`, `…_135036`), `olife_ipban` (`…_135111`, `…_135151`), `olife_antifraud` (`…_135323`, `…_135413`), `olife_auth_ticket` (`…_135232`, `…_135252`), `olife_play_dry` (`…_135505_…_vc`, с первого раза), кодеки в движке `codec_vectors.lua` 2327/0 (`…_135628`) |
| `cargo test` Rust-шлюза | 24/24 (WSL и Windows `tools/win_build.sh test`), новый тест `public_flags_and_server_info` |
| **zip другу** | `D:\Prog\Olife\dist\olife_client_20261016.zip`, 10 565 883 байт, sha256 `82e2cc80b0b9d711a34bbca8cd11517ee9453de58925fdbde2a20ebc7ea76157`, 577 файлов, манифест паков `3733a6668d26…` = раздаче сервера |

Не сделано / ограничения: стоковый `VoxelCore.exe` (`play.bat public`, `OLIFE.bat` из zip) агент не запускал — проверено тем же
скриптом в F2F-сборке; `lab play olife --user --public` (стоковый рантайм) не запускался — путь `--opt public` -> `play_stack.public`
проверен сухим стеком (те же параметры); вход «друга» шёл с этого же ПК на его LAN-адрес — настоящая вторая машина, брандмауэр и
роутер не проверены; TOFU «ключ сменился» и `token_pin` не покрыты сценарием (код в `login.lua`); игровой канал без шифрования,
манифест паков без подписи (`OLIFE_PUBLIC_PLAY.md` §3); ник — не секрет (пароль/инвайт — решение пользователя, UX B (б)/(в)).

## Движок 0.32.7 (22.10, агент v0327) — `D:\Prog\AlphaMine\engine\0327\README.md`
Рантайм — стоковый релиз `D:\Prog\VoxelCore\voxelcore-0.32.7_win64` (тег `v0.32.7` = коммит `8eff080f`); тестовая сборка —
`engine\0327\VoxelCoreF2F-0327.exe` (`hello.version 0.32.7-f2f`, ветка `f2f-0327`; от `v0.32.7` отличается только F2F). Движок
лаборатории `v0327` (`artifacts\v0327\lab.toml.patch`), проект olife — `artifacts\v0327\make_olife_v0327.py`: **умолчание `v0327`**,
`v032` — легаси (`--param engine=v032`). Применяет главная сессия (`lab daemon upgrade`); до этого основной демон гоняет olife на 0.32.0.
**Регресс** (изолированный демон :25827, копия проекта с правкой, прогоны `artifacts\lab\isolated\25827\runs\`, журнал
`artifacts\v0327\regress.log`): v032 — последний прогон из истории (`lab history`), не перегонялся.

| сценарий | v032 (последний / ok из 10 последних) | v0327 |
|---|---|---|
| olife_auth_ticket vc / rs | ok 9/9 / ok 5/5 | ok / ok |
| olife_menu_status vc / rs | ok 5/10 / ok 7/10 | ok / ok (rs — со 2-й попытки: у изолированного демона кончились 10 портов аренд; с 40 — ok) |
| olife_menu_whitelist vc / rs | ok 9/10 / ok 6/6 | ok / ok |
| olife_editor | ok 7/10 | ok (дважды) |
| olife_clients_f2f | ok 9/10 | ok |
| olife_play_dry vc / rs | ok 9/10 / ok 2/4 | ok / ok (флейк «grab failed» не встретился) |
| olife_gravity | ok 9/10 | ok (дважды) |
| olife_mobs | **fail 0/2** (03.10, шаг 7 `olife_b1_rescue`) | **fail** — тот же шаг и та же причина (`bad or expired confirmation token`, моб не спасён): не регрессия 0.32.7 |
| olife_chat | ok 5/8 | ok (дважды) |
| olife_blocks / inventory / prediction / delta / perms / op | ok 10/10 / 7/10 / 8/10 / 7/7 / 2/8 / 5/10 | ok все |
| olife_store | ok 4/10 | ok (первый прогон fail — из-за моей глушилки `[audio] enabled=false`, см. звук ниже) |
| olife_script_api / packs_reload / sandbox_real / restart | ok 6/10 / 7/9 / 10/10 / 10/10 | ok все |
| olife_ipban / antifraud / public / bundle | ok 3/5 / 4/6 / 2/4 / 2/2 | ok все |
Тесты движка: `lab run vc world|canvas_shot` (headless и окно) ok, `canvas_shot` `927b36b5…` = 0.32.0; upstream `dev/tests` 0.32.7 —
16/17 (`filesystem` ждёт, что `user:` не пишется, а проект лаборатории даёт `write-to-user`). Меню движка в F2F 854×480 —
**байт в байт** как на 0.32.0 (`02a16804…`).
- **res-диффы 0.32.0→0.32.7** (стоковый `stdmin.lua`: `reload_module` теперь исполняет модуль в окружении пака — у нас
  `reload_module` не используется, горячие модули `packs.lua` грузятся своим `load`; `stdcomp` `is_culled`/`__native_rig`;
  анимации vca/animator; шейдеры облаков и deferred; `project.toml`/`project_client.lua` → `res/project/`) — на клиент
  (меню с modelviewer, экран статуса, билет по HTTPS, переопределённые модули) и мир (`mobapi`/`mobview`, raycast) не повлияли:
  сценарии выше зелёные. Видимое отличие: фон `<modelviewer>` меню **прозрачный** (0.32.7 чистит FBO с alpha 0) — под сценкой
  цвет страницы, а не серый прямоугольник (`D:\Prog\Olife\golden\v0327\olife_menu_status\menu_main.png`).
- **Каретка.** 0.32.3+ исправил в движке ровно то, что обходили 16.10: для моноширинного TTF `glyphInterval` = advance `'0'`,
  `calcWidth` суммирует advance, выделение/клик/прокрутка — от начала строки, глиф ставится с `bitmap_left`. Замер
  (`tools/scenarios/olife_caret_run.py`, `CARET_PEN=0327`, кадры `artifacts/olife_caret/v0327_854`, `v0327_854_orig`):
  текущий `olife_mono` (сжатый) и стоковый шрифт — каретка/выделение 0 px от пера, клик точен; **исходный DejaVu Sans Mono**
  (варианты 12/13 пробы, `content/olife_caret_probe/fonts/caret_orig.ttf`) — тоже 0 px и клик точен, буквы стоят на местах.
  То есть на 0.32.7 обход шрифтом можно снять (вернуть `artifacts/olife_caret_bak/olife_mono.ttf.orig_dejavu_sans_mono`,
  буквы снова 10 px); пока основной демон и игрок на 0.32.0 — оставить. Охрану `if not document.code.focused` в `editor.xml`
  0.32.7 не меняет (не проверялась отдельно; безвредна). Вариант 11 (настоящий документ редактора) в общем проходе после 1–4
  сбивает пробу (кадры `v11` с `text_end=800`) — его гонять отдельно, как 16.10.
- **Golden** (впервые у olife): `D:\Prog\Olife\golden\v0327\{olife_menu_status (27), olife_menu_whitelist (11)}` + CAS `..\store`,
  `lab golden import` (провенанс `unknown`; `promote` — только admin). База по версии движка — каталогом.
- **Перф** волны 5p: `lab perf olife sandbox_load` на изолированном демоне — **отказ `not-idle`** за 541 с (ввод пользователя,
  GPU 18–42 %). **Снят 23.10 главной сессией на основном демоне** (`20261023_101932_olife_sandbox_load_v0327`, ворота простоя,
  `contended: false`, host load clean): такт мира p50 / p95 / max **5.99 / 6.68 / 8.95**, mean 6.06 мс; сервис 4.44 / 5.01 / 7.29,
  mean 4.48 мс; 505 сущностей, 50 владельцев, топливо на сущность-такт p50 146.5 тыс., кредиты на такт p50 160.7. Против чистого
  замера 02.10 на 0.32.0 (5.92 / 6.70 / 8.19, 6.00) — в пределах шума: 0.32.7 такт мира не изменил. `olife_w5p_*` не перегонялись.
- **Звук.** Виды F2F-клиентов не писали `settings.toml`, и движок играл звуки меню/эффектов на устройство по умолчанию —
  пользователь слышал прогоны (22.10). Правка в `make_olife_v0327.py`: `[audio] enabled = true`, `volume-master = 0`
  (+ `bundle_client` — в тестовой копии распакованного zip).

## Чего нет / дальше
0. **Плавающий сбой `olife_play_dry` на шаге `olife_play_gravity`** («grab failed: holding False, reply None»): виден
   03.10 (`20261003_012155`) и 16.10 (`022829`, `113327`, `113446` — 3 из 8 прогонов за день); оба варианта `vc`/`rs`
   сценария поднимают один и тот же Rust-шлюз (`play_up` → `gateway_kind=gateway_rs`), так что шлюз ни при чём — гонка
   захвата между клиентом и миром. Не разобрано; кандидат в отдельную задачу (главная сессия, 16.10).
1. ~~Шлюз прод-уровня~~ — Rust `olife-gateway` (волна 3c, выше); ~~билеты вместо токенов, раздача паков по HTTP у Rust~~ —
   волна 4b; осталось: шифрование игрового канала (Noise, `OLIFE_GATEWAY_SECURITY.md` §6 п.2), регионы, ротация ключей
   билетов (ключ шлюза читается при старте). Было: **Шлюз прод-уровня** (Go/Rust, регионы, БД аккаунтов/банов через supervisor, подпись/шифрование канала шлюз↔мир
   кроме общего секрета, лимиты соединений на IP). `gateway_dev.py` — эталон поведения и тестов.
2. ~~Настоящая песочница в сессии~~ — волна 3a; ~~бинарный контракт у `sandboxd`, `set_limits` по тарифу~~ — волна 4b.
   Осталось: типизированный вид в `sandbox.yaml` (сейчас JSON-строка — 287 КБ из 334 КБ кадра и разбор JSON у сервиса),
   метры владельцев и ответы на запросы в бинарном контракте, `spawn` из скрипта (мир отклоняет); ~~чистый перф-замер~~ —
   волна 5p (такт p50 5.92 / p95 6.70 / max 8.19).
3. ~~Инвентарь, предсказание движения, дельты снимков~~ — волна 4c. Осталось: UDP для трансформ; крафт/сундуки/
   прочность (`uses`), предсказание инвентаря на клиенте (сейчас ответ приходит в фазе 4 того же такта мира); инжектор
   задержки у Rust-шлюза (есть только в `gateway_dev.py`); ввод клавиш оконного клиента в режиме камеры 4a; ~~чистый
   перф-замер стоимости `snapdelta` (в живом мире 10× дороже стенда — проверить JIT)~~ — волна 5p: сбросы кэша трасс; TickSync (20 Б/такт на сессию —
   теперь заметная доля трафика).
4. Клиент: локальные случайные обновления блоков (`base`) идут сами — нет способа выключить из пака (README клиента).
5. ~~Supervisor, раздача паков по манифесту~~ — волна 3b (выше); ~~Injector/редактор/консоль Olife~~ — волна 4a (выше).
6. Метрика задержки бота включает фазу циклов 20 Гц; для сетевой метрики — клиент с опросом чаще такта (как оконный).
7. Паки на лету (волна 4b): вживую — только `modules/hot/*` и `config/*`; остальное — переоткрытие мира клиента (реплика
   строится заново). Нет: удаления лишних файлов из `world:content`, подписи манифеста (раздача по HTTP без TLS — шлюз
   сверяет sha256, клиент тоже, но сам манифест не подписан), синхронизации набора паков мира (новые блоки).
8. Путь игрока (olife_play): окно — режим камеры (полёт, noclip) без ходьбы с физикой; ломать/ставить блоки и чат из окна
   не доходят до сервера; ~~игра по сети~~ — «Игра с друзьями» (16.10, выше: `play.bat public`, `play.bat friend НИК`, zip
   другу); осталось: шифрование игрового канала и подпись манифеста паков (через интернет — пока VPN), проверка на второй
   машине через роутер, пароль/инвайт вместо ника; UX-волна — `agents/OLIFE_UX.md`.
9. ~~**Меню клиента (ВАЖНО, постановка пользователя 03.10, `agents/OLIFE_UX.md` §8)**: экран загрузки/статуса входа с
   прогрессом паков и ошибками (самое важное), главное меню с 3D-сценкой `<modelviewer>` по VCM и простым входом
   ip/ник, вопрос авторизации (пароль? регистрация? минимум — вайтлист по нику у сервиса билетов).~~ — UX B (16.10, выше):
   экран статуса (меню + HUD), меню с VCM-сценкой, вход по нику + вайтлист. Открыто: решение пользователя по (б)/(в),
   компактный HUD-баннер, другие размеры окна.
10. **Кредо и 16 требований пользователя (03.10)** — `agents/OLIFE_UX.md` §9: on_stop/on_attacked/despawn/спавн и
    управление чужими с иерархией владения, старый API 1:1, внешний API мира минуя песочницу, локальные мобы, динамические
    квоты, админ-панель с ручками, лимит перемещения выше, fragment.place, баг отображения редактора (шрифт).
11. **Антифрод (16.10, выше)** — не сделано: пароль/инвайт (вариант (б)/(в) UX B ждёт решения пользователя) — ник по-прежнему не
    секрет, антифрод только ограничивает злоупотребления; IPv6 в мире (`/ban ip` выбивает локально только IPv4, шлюзы — оба);
    живое состояние антифрода (окна частот, привязки ников, присутствие) — в памяти демона, рестарт его обнуляет; секция панели —
    после `lab daemon upgrade`; IP за NAT/прокси — все игроки за одним адресом упрутся в `sessions_per_ip` (поднять ручкой
    или `exempt`); `Hello.name` ≠ аккаунт для токенов лаборатории (отображаемое имя бота) не проверяется на похожесть.
12. **Движок 0.32.7 (22.10)** — готов к переключению (выше): применить `lab.toml.patch` + `make_olife_v0327.py` (главная
    сессия, `lab daemon upgrade`); путь игрока и `play.bat bundle` переключатся вместе с умолчанием (движок вида `runtime`).
    Pending: перф `sandbox_load`/`olife_w5p_*` на 0.32.7 на свободном ПК; снять обход шрифтом каретки после переключения;
    `olife_mobs` красный на обеих версиях (шаг `olife_b1_rescue`).
