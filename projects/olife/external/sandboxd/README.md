# olife-sandboxd — Windows-сборка (<repo>\projects\olife\external\sandboxd)

Каталог раскладки `scripts/deploy_windows.sh` (кросс-сборка x86_64-pc-windows-gnu из WSL, исходники `<olife-src>/sandboxd`):
`olife-sandboxd.exe` (сервис), `bench.exe`, `calibrate.exe`, `bench_codec.exe`, `olife_lua.wasm` (Lua 5.1 + prelude),
`tests\sandbox_tests.exe`, `tests\binary_tests.exe`, `driver.py`, `workload_typical.lua`. Кэш `*.cwasm` сервис создаёт сам
рядом с wasm. Лаборатория запускает копию exe (вид `olife.sandbox`, `OLIFE_LUA_WASM` = этот `olife_lua.wasm`).
Запуск вручную: `olife-sandboxd.exe --runtime wasm --threads 4 --tcp 127.0.0.1:7841 --ctl 7842 [--state-dir DIR]`.
(03.10, olife_a3: прежний краткий README этого каталога случайно перезаписан копией исходного README; ниже — он целиком.)

# olife-sandboxd: прототип песочницы скриптов Olife

Прототип из `agents/research/OLIFE_SANDBOX.md` (§5, §9), ворота «go/no-go» для рантайма песочницы.
Это Rust-сервис: внутри wasmtime 49.0.1 исполняется PUC Lua 5.1.5 + LuaBitOp (`bit`), собранный
wasi-sdk 30 в `wasm32-wasip1`. Есть топливо, вытеснение, лимиты памяти, VM на владельца, корутина
на сущность, снимки линейной памяти и пакетный мост `TickInput → TickResult`. Запасной рантайм Luau
(mlua 0.12.1) реализует тот же трейт `ScriptRuntime`/`OwnerVm` и использует тот же протокол.

Репозиторий только локальный (`<olife-src>/sandboxd`). Это не рантайм движка, поэтому он лежит вне VC_ROOT.

## Сборка
```bash
# 1. Lua -> wasm (wasi-sdk для Linux: <olife-src>/toolchain/wasi-sdk-30.0-x86_64-linux, или WASI_SDK=...)
lua-wasm/build.sh                 # -> lua-wasm/out/olife_lua.wasm (~221 КБ), OPT=-O3 при желании
# 2. сервис, бенчмарки, тесты (toolchain stable задан в rust-toolchain.toml, jobs=4 в .cargo/config.toml)
cargo build --release                       # только wasm-Lua
cargo build --release --features luau       # + запасной Luau (Luau собирается из исходников, vendored)
cargo test --release [--features luau]      # 15 тестов wasm-Lua + 6 бинарный контракт/ctl (+5 Luau)
cargo run --release --bin bench_codec        # JSON против бинарного контракта, 500 сущностей
python3 tests/driver.py all [--runtime luau] # проверки на уровне протокола (мир со стороны драйвера)
# 3. Windows (02.10): кросс-сборка x86_64-pc-windows-gnu (apt gcc-mingw-w64-x86-64, rustup target add) в тот же
#    target/ -> <repo>\projects\olife\external\sandboxd (exe со strip, wasm, тесты, driver.py, README там)
scripts/deploy_windows.sh
```
Windows-сборка статическая: из DLL нужны только системные (kernel32, ws2_32, userenv, bcryptprimitives, msvcrt).
`cargo test` (tests/sandbox.rs, собранный под Windows) проходит 15/15, `driver.py all` из `C:\Python313` даёт PASS.
Хэши памяти владельцев в determinism совпадают с Linux байт в байт. **Грабля Windows:** без CoW-образа памяти (memfd
есть только в Linux) wasmtime копирует сегменты данных при `instantiate` и списывает за них топливо. При нулевом топливе
это trap «all fuel consumed», поэтому `Inst::fresh` выдаёт топливо до инстанцирования. Это топливо не тарифицируется.
`build.sh` копирует `third_party/lua-5.1.5` в `lua-wasm/out/` и применяет `lua-wasm/patches/*.patch`,
поэтому `third_party` остаётся нетронутым. Модуль предкомпилируется в `*.cwasm` рядом с `.wasm`
(ключ — хэш wasm); при пересборке `build.sh` удаляет старые `*.cwasm`.

### setjmp/longjmp: что сработало
Основной путь заработал с первого раза: `-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false
-mexception-handling` при компиляции и `-lsetjmp` при линковке. Модуль содержит `try_table`/`throw`
(стандартизованный EH с exnref, без legacy `try`/`delegate`), а wasmtime 49 включает
`Config::wasm_exceptions(true)` по умолчанию; нужна фича `gc` (+ `gc-drc`). Работают `pcall`/`error`,
синтаксические ошибки, `not enough memory` (LUA_ERRMEM), `stack overflow` / `C stack overflow`. Запасной
вариант (`ldo.c` без longjmp на кодах возврата) не понадобился и не делался. Единственная «ошибка» —
предупреждение clang `argument unused during compilation: '-mllvm -wasm-enable-sjlj'` на шаге линковки,
оно безвредно.

Импортов WASI у модуля 11 (`fd_*`, `path_open`, `proc_exit`), все от libc. Хост определяет их как
**trap** (`define_unknown_imports_as_traps`), так что ФС, часов, случайности и выхода из процесса нет.
Своих импортов 6: `host_input/host_emit/host_query/host_log/host_fuel_used/host_end`.

### Патчи Lua (`lua-wasm/patches`)
1. `luaL_addlstring`: блочный `memcpy` вместо цикла по символу (результат тот же, ~10× меньше wasm-инструкций).
2. `str_rep`: результат выделяется сразу (как в Lua 5.2+). `string.rep("x", 2^30)` мгновенно упирается в
   лимит кучи (`not enough memory`); без патча это минуты некрючкуемого C-цикла.

## Как устроено
- **VM (Store) на владельца**, корутина на сущность. Шим `lua-wasm/sandbox.c` держит реестр сущностей;
  `sb_tick` по очереди берёт вход каждой сущности (`host_input`), декодирует MessagePack в Lua-таблицу,
  возобновляет её корутину и сообщает итог (`host_end`). Пролог `lua-wasm/prelude.lua` строит окружение
  сущности: белый список стандартной библиотеки, read-only прокси `string/math/table/bit/coroutine`,
  `self`, `world`, `on`, `sleep`, `yield`, `print/oprint`.
- **Нет** `os, io, debug, require, module, dofile, loadfile, load, getfenv, setfenv, newproxy, gcinfo,
  string.dump`. `loadstring` только для текста (байткод отклоняется), чанк получает окружение сущности.
  Метатаблица строк закрыта (`__metatable`). `rawset` по read-only прокси запрещён. `collectgarbage`
  разрешён только с `count/collect/step`.
- **Три уровня управления CPU** (все детерминированы, единица — топливо wasmtime):
  1. count-хук Lua (каждые `hook_count`=250 VM-операций) спрашивает `host_fuel_used()`. Если бюджет сущности
     превышен, корутина **уступает посреди кода** (статус `throttled`) и продолжает со следующего тика.
     Внутри C-границы (`pcall`, метаметод, вложенная корутина) уступить нельзя. Тогда при перерасходе
     `budget × doom_factor` сущность «обречена»: ошибка пробрасывается сквозь все `pcall` и `coroutine.resume`,
     итог — `killed`.
  2. wasmtime `consume_fuel` + `fuel_async_yield_interval` (50 000). Вызов владельца опрашивается порциями.
     Превышение потолка владельца на тик (C-код без точек хука: паттерны, сортировка) оставляет вызов
     **приостановленным** (`frozen`), и он продолжается в следующем тике.
  3. Если `frozen` дольше `hard_cap_ticks`/`hard_cap_fuel` или случился любой trap, будущее сбрасывается,
     VM владельца **восстанавливается из чекпойнта** (копии линейной памяти), а виновная сущность выгружается
     (`killed`). Другие владельцы ни на одном уровне не затронуты.
- **Память**: `StoreLimits` (жёсткий `mem_max`, по умолчанию 64 МБ на VM) и мягкий лимит кучи Lua
  в аллокаторе шима (`lua_heap_max` = 48 МБ, действует только пока работает код пользователя).
  После `LUA_ERRMEM` шим делает полную сборку за счёт виновника. Пик — через `ResourceLimiter`,
  `alloc_bytes` — байты, выделенные сущностью за тик.
- **Атомарность тика сущности**: действия копятся и отдаются, только когда тик сущности завершён
  (`ok/wait/sleep/done`). При `throttled` они переносятся на следующий тик, при `error/killed` — отбрасываются.
- **Снимок/восстановление**: образ = линейная память + перенос хоста (`carry`, `next_qid`, `bucket`).
  Восстановление — новый инстанс с копией памяти. Новый владелец создаётся из шаблона (образ после
  `sb_init`) с `sb_config`.

## Протокол (JSON lines; stdin/stdout или `--tcp 127.0.0.1:PORT`)
Запрос — одна строка JSON, ответ — одна строка JSON. В режиме `--tcp` у каждого соединения свой поток, а все запросы
идут в один `Service` под мьютексом. Поэтому пока мир держит тиковое соединение, второе соединение (лаборатория,
supervisor) может спросить `hello`/`meters`. `{"type":"quit"}` в любом соединении завершает процесс.
Когда сервис готов, в stdout выходит строка `[olife_sandbox] ready runtime=… tcp=… ctl=… init_ms=…`.
`--ctl PORT` — порт управления в протоколе F2F лаборатории (`{"id","cmd","args"}` → `{"id","ok","result"|"error"}`).
Команды: `hello` (`impl`, `pid`, `runtime`, `flags.input="none"`), `meters {owner?, entities?}` (накопленные `Totals`:
время такта сервиса mean/p50/p95/p99/max по последним 1200 тактам; по владельцам — такты, сущность-такты, топливо,
кредиты, api-кредиты, действия, отброшенные, счётчики статусов, kills/traps, пик памяти; по сущностям при
`entities=true`; `now` — текущие `OwnerMeter`), `stats` (то же без разбивки), `set_limits {owner|"*", limits}` (слияние
полей, действует со следующего такта), `limits {owner?}`, `quit`. Подробности и бинарный транспорт на том же `--tcp` — раздел
«Бинарный контракт и управление лимитами».
| запрос | ответ |
|---|---|
| `{"type":"hello","proto":1}` | `{"type":"hello","proto":1,"runtime":"wasm-lua5.1"}` |
| `{"type":"set_limits","owner":1,"limits":{fuel_per_tick, bucket_max, tick_cap, entity_budget, mem_max, lua_heap_max, hook_count, doom_factor, hard_cap_ticks, hard_cap_fuel, max_actions, max_text_bytes, checkpoint_every}}` | `ok` — **полная замена** лимитов владельца (не указанные поля = значения по умолчанию); слияние частичных полей — команда `set_limits` порта управления, см. ниже |
| `{"type":"load","owner":1,"eid":7,"src":"..."}` | `{"type":"load_result","ok":true}` / `{"ok":false,"error":"e7:1: ..."}` |
| `{"type":"tick","tick":N,"seed":S,"dt":0.05,"entities":[EntityInput]}` | `{"type":"tick_result","tick":N,"entities":[EntityResult],"owners":[OwnerMeter],"wall_us":..}` |
| `{"type":"snapshot","owner":1}` / `{"type":"restore","owner":1,"id":ID}` | `{"type":"snapshot","id":..,"bytes":..,"hash":"sha256 памяти"}` / `ok` |
| `{"type":"meters","owner":null}`, `{"type":"unload",...}`, `{"type":"quit"}` | |

- `EntityInput`: `eid, owner, pos[3], rot[3], vel[3], fields?, events[], answers{qid: value}, view[], budget?`.
  Внутрь VM вход идёт MessagePack-картой (`runtime::encode_input`).
- `EntityResult`: `eid, owner, status, error?, actions[], queries[], meter{fuel, api_calls, api_credits,
  credits, alloc_bytes, actions_dropped}`. Статусы: `ok` (тик завершён), `throttled` (вытеснена посреди кода,
  продолжит), `wait` (ждёт ответ на запрос), `sleep`, `done`, `error`, `killed`, `dead` (после ошибки),
  `frozen` (VM владельца приостановлена), `restored`, `unknown`.
- Действия: `{op:"set_pos",pos}`, `set_rot`, `set_vel`, `{op:"block.set",pos,id}`, `spawn`, `say`, `print`,
  `oprint` (не больше `max_actions`=64 за тик, остальные отбрасываются и считаются). Текст `print/oprint/say`
  режется до 1024 байт (`MAX_TEXT`, как `str<1024>` в бинарном контракте), а тарифицируется по полной длине.
  Текста за тик сущности — не больше `max_text_bytes`=4096, лишние действия отбрасываются. Без этого лимита поток
  64×1 КБ `oprint` за тик стоил миру +1.4 мс на такт в среднем и до 16 мс в пике на разборе строки TickResult
  (волна 3a, `olife_negative`).
- Загрузка (`load`) в замороженного владельца (`frozen`, его вызов приостановлен) откладывается и выполняется в начале
  первого такта, когда VM снова свободна: после окончания вызова или после kill и восстановления. До 02.10 такая
  загрузка возвращала «owner is frozen», и мир терял сущность насовсем (сосед `string.find`-нарушителя, заспавненный
  следующей админ-командой).
  Запросы (`world.raycast`) — `{op:"raycast",origin,dir,maxlen,qid}`; ответ приходит в `answers` следующего
  `TickInput`, скрипт получает его как возвращаемое значение (корутина ждёт со статусом `wait`).
- `OwnerMeter`: `state, fuel_used, fuel_available, bucket, mem_bytes, mem_peak, lua_heap, slices, kills,
  traps, wall_us` (`wall_us` только для мониторинга, в тариф не входит).

API скрипта: `self.pos/rot/vel/id/state/fields`, `self:move_to(v)`, `self:set_rot(x,y,z)`, `self:set_vel(v)`,
`self:set_block(x,y,z,id)`, `self:spawn(def)`, `self:say(...)`, `world.raycast(o,d,len)` (async),
`world.entities_near(r)` (по `view`), `world.tick()`, `on(event, fn)`, `on_tick(dt)`, `sleep(n)`, `yield()`,
`print/oprint`.

## Бинарный контракт и управление лимитами (волна 4b, 02.10.2026)
### Транспорт на порту `--tcp`
Тип соединения определяется по первому байту. `{` (или пробельный символ) означает JSON-строки, как раньше, без изменений.
Любой другой байт означает бинарный контракт `sandbox` v1 (`tools/olife/protocol/sandbox.yaml`). Кадр: магия `0x4F53` «OS»,
версия 1, тип u16, длина u32, big-endian, тело до 4 МиБ. Кодеки генерируются из той же схемы, что у мира и заглушки:
`python3 tools/olife/gen_codecs.py --lang rust --rust-out <olife-src>/sandboxd/src/proto`. Руками их не правят, проверка —
`--check`. Код транспорта: `src/binproto.rs`. Оба транспорта работают одновременно, на разных соединениях, в один `Service`.

| мир → сервис | ответ |
|---|---|
| `Hello{proto, runtime}` | `Hello{proto: 1, runtime: "wasm-lua5.1"}` |
| `Load{owner, eid, src}` | `LoadResult{owner, eid, ok, error?}` (ошибка `ensure_owner` тоже приходит как `ok=false`) |
| `Unload{owner, eid}` | при успехе ничего; при ошибке `Error{message}` |
| `TickInput{tick, seed, dt, entities[EntityInput]}` | `TickResult{tick, entities[EntityResult], wall_us}` |
| `Error` от мира | считается (`bad_requests`), ответа нет |
| `LoadResult`/`TickResult`/`Backpressure` от мира | `Error{"unexpected …"}` |

- Строгость та же, что у `sandbox_stub.py`. Ошибка кадра (магия, версия, размер, неизвестный тип) закрывает соединение.
  Сервис при этом продолжает работать. Тело в правильном кадре, которое не прошло строгий разбор (обрезано, лишние байты,
  не UTF-8 и т.д.), получает `Error{message}`, соединение остаётся.
- **Вход.** `fields_json`, `events_json[]`, `view_json` разбираются serde_json. Неверный JSON (и `view_json`, который
  не является массивом) считается пустым полем и попадает в счётчик `transport.bin_bad_json`. Если `budget` конечен и ≥ 0,
  он становится топливом сущности. Ответов на запросы (`answers`) в контракте нет: `world.raycast` по бинарному транспорту
  остаётся без ответа, а `queries_json` уходят миру.
- **Действия** (JSON-значения, которые выдаёт VM) превращаются в union `Action`: `set_pos{pos:[x,y,z]}` → `SetPos`,
  `set_rot` → `SetRot`, `set_vel` → `SetVel`; `block.set{pos:[x,y,z] | x,y,z, id}` → `BlockSet{x,y,z: i32 = floor, id}`;
  `spawn{def: строка|число}` → `Spawn`; `say/print/oprint{text}` → `Say/Print/OPrint` (текст режется до 1024 байт по границе
  UTF-8). Отбрасываются: неизвестная операция, нечисловые или неконечные координаты (NaN из VM приходит как `null`),
  координата вне i32, `id`/`def` длиннее 64 байт или не строка/число, действия сверх 256. Отброшенное **не валит кадр**:
  оно считается в `transport.bin_actions_dropped` и прибавляется к `meter.actions_dropped` своей сущности.
- **Лимиты схемы.** `status` ≤ 16 байт, `error` ≤ 1024 (режется), `queries_json` ≤ 64 штук по ≤ 4096 байт (лишние
  отбрасываются, `bin_queries_dropped`), сущностей ≤ 65535. Если `TickResult` не влезает в 4 МиБ, у последних сущностей
  убираются действия и запросы (`bin_entities_trimmed`). Сервис не отправляет кадр, который мир отвергнет.
- Счётчики `OwnerMeter` в контракт не входят и по бинарному транспорту не отправляются. Они доступны через `meters`
  на порту управления. `Backpressure` не используется. `EntityMeter` (u64) в кадре передаётся как f64.
- Мост мира (`content/olife_world/modules/sandbox.lua`, ветка `bin`, `from_bin_action`) совместим без правок.
  `BlockSet` приходит как `pos={x,y,z}` из целых чисел, и мир их снова округляет вниз. Проверено Python-кодеком из
  `tools/olife/olife_proto` против живого сервиса: Hello, Load, TickInput → SetPos/BlockSet/OPrint (1024 байта),
  `set_rot` с NaN отброшен.

### Порт управления: `set_limits`, `limits`, добавки в `meters`
`{"id":1,"cmd":"set_limits","args":{"owner":1,"limits":{"fuel_per_tick":500000}}}` **сливает** указанные поля с текущими
лимитами владельца. Ответ:
`{"owner":1,"live":true,"pending":false,"version":1,"limits":{…все поля…},"override":{"fuel_per_tick":500000}}`.
- Если владельца ещё нет, override хранится как отложенный (`pending: true`) и применяется при его создании
  (первый `Load`).
- `owner: "*"` — значение по умолчанию сервиса. Оно действует на всех владельцев, кроме полей, которые владелец задал сам:
  поле владельца важнее поля «*». Существующие владельцы, у которых эффективные лимиты изменились, получают их сразу.
  Ответ: `{"owner":"*","version":3,"limits":{…},"applied_to":[1,2]}`.
- Неизвестное поле, неверный тип или владелец не u32/«*» дают `{"ok":false,"error":"unknown limits field \"fuel\" (have: …)"}`.
  В этом случае ничего не меняется.
- Владелец, получивший лимиты через JSON-строки (`{"type":"set_limits"}` = полная замена), считается задавшим **все** поля,
  и «*» его больше не трогает.
- **Когда вступает в силу:** со следующего такта. В начале каждого такта читаются `fuel_per_tick`, `bucket_max`,
  `tick_cap`, `entity_budget`, `hard_cap_ticks`, `hard_cap_fuel`, `max_actions`, `max_text_bytes`, `checkpoint_every`.
  `lua_heap_max`, `hook_count` и `doom_factor` (`sb_config` шима) применяются сразу, если VM простаивает. У замороженного
  (`frozen`) владельца они применяются в начале первого такта после конца вызова, и `set_limits` больше не падает
  с «owner is frozen». После восстановления из чекпойнта `sb_config` повторяется, только если лимиты отличаются от тех,
  что записаны в образе: вызов сбрасывает счётчик хука, а безусловный вызов изменил бы повтор.
- **`mem_max` живой.** Ограничитель памяти store (`PeakLimiter`) сверяет каждый `memory.grow` с атомарным `mem_max`
  владельца. Новое значение действует с первого же роста памяти после команды, в том числе у замороженного владельца
  посреди вызова. Память, которая уже выросла, wasm не умеет уменьшать. Если новый `mem_max` меньше текущего размера,
  отказывает любой следующий рост, и Lua получает `not enough memory` (тест `mem_max_lowered_live_takes_effect_on_next_growth`).
  Восстановление образа, который больше нового `mem_max`, проходит (рост при восстановлении идёт мимо проверки), но дальше
  память не растёт. До 4b `mem_max` действовал только со следующего восстановления.
- `{"cmd":"limits","args":{"owner"?}}` возвращает `{version, changed_ms, changed_after_ticks, default:{…}, owners:[{owner,
  limits, override, state:{version, changed_ms, changed_after_ticks, applied_tick}}], pending:{"9":{"max_actions":8}}}`.
- В `meters` добавлены `limits_version`, `limits_changed_ms` (unix мс), `limits_changed_after_ticks` (сколько тактов
  сервиса прошло к моменту изменения) и `limits_owners: [{owner, fuel_per_tick, limits_version, applied_tick, changed_ms}]`.
  `applied_tick` — номер `TickInput.tick` первого такта, прошедшего с новыми лимитами. В каждой записи `owners` есть
  `fuel_per_tick`, `limits_version`, `limits_applied_tick`. Блок `transport` содержит `json_connections`, `bin_connections`,
  `bin_frames_in/out`, `bin_bad_frames`, `bin_bad_bodies`, `bin_bad_json`, `bin_actions_dropped`, `bin_queries_dropped`,
  `bin_entities_trimmed`.
- Строка готовности печатает фактические адреса: `tcp=127.0.0.1:<порт> ctl=<порт> proto=jsonl,bin`. Поэтому
  `--tcp 127.0.0.1:0 --ctl 0` годится для тестов.

### Замер кодеков (`bench_codec`, 500 сущностей = 50 × 10, вид 8 соседей, медиана 300 прогонов, мкс)
TickInput собран как в мире: вид — `{eid, kind, pos:[x,y,z]}` × 8 (`sbmeter.view_index`/`encode_tick`), событие у каждой
10-й сущности. TickResult — типичный: `set_pos` + `set_rot`, `print` у каждой 20-й, счётчики заполнены. JSON-строка
TickResult несёт ещё 50 `OwnerMeter` (9.6 КБ), бинарный кадр их не несёт. «bin + conv» — кодек вместе с переводом
в структуры сервиса и обратно. Для TickInput сюда входит разбор `view_json`/`events_json`: они и в контракте остаются
JSON-текстом. WSL, Ryzen 7 7435HS, **ПК занят** (load average 3, другие агенты), разброс между прогонами ±10–50 %.

| сообщение | транспорт | байт | кодирование, мкс | разбор, мкс |
|---|---|---|---|---|
| TickInput | JSON-строка (`Request`) | 352 546 | 492 | 4 289 |
| TickInput | JSON-строка, сразу в `TickInput` | 352 546 | — | 2 616 |
| TickInput | бинарный, только кодек | 333 875 | 23 | 67 |
| TickInput | бинарный + перевод | 333 875 | 1 574 (с видом → JSON-текст) | 2 902 (с разбором вида) |
| TickResult | JSON-строка | 142 097 | 172 | 948 (в `Value`) |
| TickResult | бинарный, только кодек | 54 023 | 16 | 72 |
| TickResult | бинарный + перевод | 54 023 | 69 | 326 (в JSON-форму действий) |

- Виды занимают 287 КБ из 334 КБ бинарного TickInput и разбираются как JSON при любом транспорте. Поэтому разбор
  входа на стороне сервиса почти не дешевеет: 2.9 мс против 4.3 мс. Чтобы получить выигрыш, вид нужно сделать типизированным
  полем схемы (массив `{eid, kind, pos}`) или декодировать лениво. Сам кодек разбирает кадр за 0.07 мс.
- Разбор JSON-строки в `Request` стоит 4.3 мс, а те же байты сразу в `TickInput` — 2.6 мс. Разница идёт на буферизацию
  внутренне-тегированного enum в serde. Это путь JSON-строк, и он сейчас на критическом пути такта: разбор идёт до мьютекса,
  но последовательно с тактом соединения.
- TickResult по бинарному транспорту в 2.6 раза меньше, и его кодирование дешевле: 0.07 мс вместе с переводом против
  0.17 мс. Мир (Lua) от этого выигрывает больше всего: сейчас `json.parse` 139 КБ ≈ 3.1 мс на такт (волна 3a).
- Windows-сборка того же замера (`bench_codec.exe`, тот же ПК): TickInput JSON 635/5 421, бин-кодек 29/90,
  бин + перевод 2 294/2 226; TickResult JSON 222/1 181, бин-кодек 19/91, бин + перевод 96/475.

## Счётчики и калибровка топлива
`cargo run --release --bin calibrate` (наклон между двумя длинами цикла, фиксированная цена тика вычтена).
wasm-Lua, AMD Ryzen 7 7435HS, WSL2:

| операция (в цикле `for`) | топливо/итерация | из них сверх пустого цикла | нс/итерация | нативный PUC 5.1 -O2 | Luau+mlua interrupt, нс |
|---|---|---|---|---|---|
| пустая итерация (FORLOOP) | 90 | 0 | 4.0 | 2.85 нс | 12.8 |
| `a = a + i*2` (2 VM-операции) | 426 | 335 | 17.9 | 6.4 нс | 23.9 |
| глобал `G = G + 1` | 483 | 392 | 31.9 | | 22.5 |
| `t.x` | 357 | 267 | 20.0 | | 18.7 |
| `t[i] = i` | 345 | 255 | 20.2 | | 18.2 |
| вызов локальной функции | 616 | 525 | 33.4 | 15 нс | 46.1 |
| вызов метода `o:m(i)` | 745 | 655 | 42.7 | | 56.3 |
| `math.sin(i)` | 752 | 662 | 83 | | 50.0 |
| `{i, i}` | 1747 | 1656 | 124 | | 52.3 |
| замыкание | 1585 | 1495 | 124 | | 36.7 |
| `'k' .. i` | 4711 | 4621 | 573 | | 266 |
| `string.format('%d', i)` | 3088 | 2998 | 333 | | 211 |
| `pcall(f)` | 1471 | 1380 | 177 | | 417 |

- Колонка Luau снята при load average 5.6. Luau вызывает interrupt на каждом обратном переходе и вызове,
  а mlua тратит на один такой вызов ~10 нс. Поэтому на простых циклах и вызовах Luau с тарификацией
  **медленнее** wasm-Lua, а выигрывает на аллокациях, строках и маршалинге входа.
- Простая VM-операция стоит ~90–170 топлива, из них ~30–45 — проверка count-хука на каждой инструкции.
  Скорость против нативного PUC Lua 5.1: ×1.4 (пустой цикл), ×2.2 (вызовы), ×2.8 (арифметика). Оценка
  исследования ×1.5–3 подтверждена.
- Топливо отключали (`OLIFE_NO_FUEL=1`), NaN-канонизацию тоже (`OLIFE_NO_NANCANON=1`) — скорость не
  меняется (в пределах шума). Цена топлива во времени — ~0, цена хука — ~10–20 %.
- Фиксированная цена тика сущности: 21 400 топлива (декодирование входа, пролог, resume); `view` из 5
  сущностей добавляет ещё 42 000. Типичная сущность (`workload::TYPICAL`) — 120 000 топлива, тяжёлая (`HEAVY`) —
  465 000.
- **1 кредит = 10 000 топлива** (`FUEL_PER_CREDIT`) ≈ 60–110 простых VM-операций ≈ 1.7–2 мкс CPU на этой
  машине (0.17–0.2 нс/топливо в нагрузке). Базовый бюджет владельца 2 000 000 топлива/тик (200 кредитов) ≈
  0.4 мс CPU; 50 владельцев × 2 М ≈ 17–20 мс на одном потоке, это и есть порог ворот.
- wasmtime 49 берёт плату за `memory.copy/fill` **побайтно** (`operator_cost.memory_copy_per_byte`): дыры
  в тарификации через bulk-memory нет. Одна большая операция может перескочить порцию yield, но её
  ограничивает `mem_max`.

## Результаты (02.10.2026, AMD Ryzen 7 7435HS 8C/16T, WSL2, 9 ГБ ОЗУ)
**Состояние CPU:** машина не была свободна. load average 1.5–3.5, чужой процесс (`daslang`/`clang++`)
держал одно ядро на 100 %. Абсолютные числа — с шумом ±20 %. Перед решением по порогу повторить на
свободном ПК (лаборатория, `lab perf`).

### Нагрузка: 500 сущностей = 50 владельцев × 10, тот же поток `TickInput` (`bench`, 300 тиков после 20 прогревочных)
| рантайм | скрипт | бюджет/владелец/тик | потоков | среднее, мс/тик | p50 | p99 | max | итог |
|---|---|---|---|---|---|---|---|---|
| wasm-Lua 5.1 | typical | 6 М | 1 | 11.91 | 11.38 | 17.94 | 23.18 | все `ok` |
| wasm-Lua 5.1 | typical | 6 М | 4 | 3.21 | 3.12 | 4.85 | 5.31 | все `ok` |
| Luau (mlua) | typical | 6 М | 1 | 7.74 | 7.55 | 11.52 | 14.69 | все `ok` |
| Luau (mlua) | typical | 6 М | 4 | 2.22 | 2.13 | 3.80 | 4.41 | все `ok` |
| wasm-Lua 5.1 | heavy | 6 М | 1 | 25.27 | 24.37 | 29.71 | 31.18 | все `ok` |
| wasm-Lua 5.1 | heavy | 6 М | 4 | 7.15 | 6.91 | 10.07 | 12.54 | все `ok` |
| Luau (mlua) | heavy | 6 М | 1 | 15.77 | 15.56 | 19.29 | 25.99 | все `ok` |
| Luau (mlua) | heavy | 6 М | 4 | 4.91 | 4.83 | 6.71 | 7.02 | все `ok` |

Более ранний прогон при меньшей загрузке: wasm typical — 9.95 мс (1 поток) / 2.73–3.03 мс (4 потока).
Через протокол (`driver.py load`, JSON по pipe, 4 потока): wasm — сервис 5.4 мс/тик (p99 7.9), Luau — p50
ниже 20 мс; сквозное время с JSON на стороне Python — 12–18 мс (прототипный кодек, не сервис).
**Порог ворот (500 типичных сущностей ≤ 20 мс сервиса на тик) пройден обоими рантаймами даже на 1 потоке.**

### Память и старт
| | wasm-Lua 5.1 | Luau |
|---|---|---|
| память VM владельца (10 typical сущностей) | 1.49 МБ линейной памяти, из них 1 МБ — резерв C-стека (`-z stack-size`), куча Lua ~180–210 КБ | 0.85–0.95 МБ (`used_memory`) |
| образ шаблона (после `sb_init`) | 18 страниц = 1.18 МБ | — |
| создание владельца | 1.9–2.4 мс (инстанс + копия шаблона 1.2 МБ + первый чекпойнт; упирается в page-fault'ы, CoW/Wizer не сделан) | 0.7–1.0 мс |
| загрузка сущности (компиляция + корутина) | 35–58 мкс | 43–56 мкс |
| размер модуля | 221 КБ wasm | — |

### Негативные тесты (`tests/driver.py negative`, на уровне протокола; те же — в `cargo test`)
| сценарий | wasm-Lua 5.1 | Luau |
|---|---|---|
| `while true do end` | `throttled` каждый тик, ровно бюджет доли (≤ бюджет + 1 период хука), соседи по владельцу и другие владельцы работают | `throttled` (yield из interrupt) |
| `while true do pcall(function() while true do end end) end` | `killed` (обречена при 4× бюджета, ошибка проходит сквозь `pcall`), соседи живы | `throttled` (Luau умеет уступать сквозь `pcall`) |
| `string.rep("x", 2^30)` | `error: not enough memory` за 220 К топлива, VM жива, следующие загрузки работают | `error: not enough memory` |
| рост таблицы до лимита (куча 8 МБ, `mem_max` 16 МБ) | `throttled` несколько тиков → `error: not enough memory`, пик ≤ 16 МБ, соседи живы | `error` |
| глубокая рекурсия Lua | `error: stack overflow` (LUAI_MAXCALLS) | `error: stack overflow` |
| рекурсия через C (`__index`) | `error: C stack overflow` (LUAI_MAXCCALLS), trap'ов 0 | `error: C stack overflow` |
| бэктрекинг паттерна в C (`string.find` с `.-`×12) | владелец `frozen` 3 тика → `killed`, VM владельца восстановлена из чекпойнта, **другой владелец каждый тик `ok`** | **сервис висит** (C-код не вызывает interrupt; драйвер убил процесс через 15 с) |
| `os/io/debug/getfenv/require/load/dofile` | все `nil` | все `nil` (белый список) |
| байткод через `loadstring("\27Lua...")` | `nil, "binary chunks are not allowed"` | `loadstring` нет |
| изменение общей stdlib (`string.rep = nil`, `rawset(string, ...)`) | ошибка read-only | ошибка readonly (`table.freeze`) |
| спам действий (100 `print`/тик) | принято 64, отброшено 36 (счётчик) | так же |
| детерминизм: два процесса, одинаковый вход (таблицы-ключи, `math.random`, `pairs`) | поток `TickResult` байт-в-байт и **хэши памяти владельцев** совпадают | **расходится**: порядок `pairs` по ключам-таблицам зависит от адресов нативной кучи (ASLR); счётчики interrupt совпадают |
| снимок → 9 тиков → восстановление → те же 9 тиков | результаты и хэш памяти совпадают (в т.ч. сущность, вытесненная посреди цикла) | не поддерживается (нет образа VM) |

## Выводы для ворот
- **wasmtime + Lua 5.1 в wasm: GO.** Сборка с sjlj работает без обходных путей. Топливо
  детерминировано вплоть до хэша памяти. Вытеснение посреди кода работает и для Lua-кода (хук → yield),
  и для C-кода (async-fuel → `frozen` → `killed` с откатом владельца). Изоляция владельцев выдержала все
  негативные сценарии. 500 типичных сущностей укладываются в 12 мс/тик на одном потоке и в 3 мс на четырёх.
- **Luau** быстрее в интеграции в 1.5–1.6 раза, но три требования не держит: C-зацикливание вешает
  сервис, `pairs` недетерминирован между процессами, снимка VM нет. Остаётся запасным за тем же трейтом
  (`--features luau`).

## Что дальше (вне прототипа)
- Шаблон через CoW/Wizer: создание владельца с ~2 мс до десятков мкс. C-стек 1 МБ → 256 КБ: −0.75 МБ на VM.
- Декодировать `view` лениво, при первом `entities_near` (сейчас 42 К из 120 К топлива типичной сущности).
- ~~Бинарный кодек протокола~~ — сделано в волне 4b (бинарный контракт на порту `--tcp`, см. выше).
- Атрибуция памяти по сущности сейчас — «выделено за тик». Для мягкого лимита на сущность нужны категории.
- ~~Сборка под Windows~~ — сделано 02.10 (windows-gnu, кросс из WSL, `scripts/deploy_windows.sh`).
- ~~Бинарный контракт на стороне сервиса~~ — сделано в волне 4b. Осталось: типизированный вид в схеме вместо `view_json`
  (см. замер кодеков) и ответы на запросы (`answers`) в контракте.
- Luau (`--features luau`) не соблюдает `max_text_bytes` и `MAX_TEXT`: это запасной рантайм, лимиты добавлены
  только в wasm-Lua.
- Учёт топлива в `frozen`-тиках приблизительный (порции × интервал). `mem_max` с волны 4b живой
  (см. «Порт управления»). Снимок — только у простаивающего владельца.

## Файлы
- `lua-wasm/build.sh`, `sandbox.c` (шим, MessagePack, аллокатор, хук), `prelude.lua` (API скрипта), `patches/`.
- `src/protocol.rs` (сообщения, лимиты, цены API), `src/runtime.rs` (трейт), `src/wasm_lua.rs` (wasmtime),
  `src/luau.rs` + `src/luau_prelude.lua` (запасной), `src/service.rs` (владельцы, пул ≤ 4 потоков),
  `src/main.rs` (stdin/stdout или TCP), `src/workload.rs`, `src/binproto.rs` (бинарный транспорт), `src/proto/` (сгенерированные кодеки),
  `src/bin/{bench,calibrate,bench_codec}.rs`, `examples/probe.rs`.
- `tests/sandbox.rs` (15), `tests/binary.rs` (6: бинарный транспорт по TCP к настоящему exe, ctl `set_limits`, живой
  `mem_max`, отображение действий, векторы `sandbox.json`), `tests/luau.rs` (5), `tests/driver.py`; `scripts/deploy_windows.sh`.
- Диагностика: `OLIFE_NO_FUEL=1`, `OLIFE_NO_NANCANON=1`, `OLIFE_LUAU_NO_INTERRUPT=1`, `hook_count < 0`
  (без хука). Это только для замеров, не для работы.

## Волна 3a: в сессии Olife (02.10.2026, агент olife_w3s)
Настоящий сервис заменил Python-заглушку в лаборатории: вид `olife.sandbox` = `<repo>\projects\olife\external\sandboxd\olife-sandboxd.exe
--tcp 127.0.0.1:<sb> --ctl <f2f> --threads 4`, мир говорит с ним по JSON-строкам. Бинарный контракт пока остаётся за
заглушкой (`sandbox_stub`). Сценарии `olife_sandbox_real`, `olife_negative`, `olife_sandbox_load`, перф
`lab perf olife sandbox_load`. Цифры и таблица негативных тестов — в `agents/OLIFE.md`, раздел «Волна 3a».
Изменения сервиса в этой волне: многосоединительный TCP и `--ctl`, `Totals` (накопленные счётчики), строка готовности,
путь к wasm рядом с exe, топливо до инстанцирования (Windows), `MAX_TEXT` и `max_text_bytes`, отложенные загрузки.

## UX A3: API скриптов моба (03.10.2026, агент olife_a3)
Скрипту бенча (`prelude.lua`) добавлены `block`, `memory`, методы `self` и `self.skeleton`. Каждый вызов — **действие**
(в TickResult; мир применяет в следующем такте, проверяет, отказ приходит событием `rejected {op, reason}`) или
**запрос** (уходит с результатом этого такта, ответ — в следующем TickInput; сущность ждёт со статусом `wait`, вызов
выглядит синхронным; ответ `{ok=true, v=...}` / `{ok=false, err=...}` → скрипт получает `v` или `nil, err`; без ответа
100 тактов → `nil, "timeout"`). Цена — `protocol.rs::api_price_action` (кредиты API; топливо — отдельно, 1 кредит =
10 000 топлива). Мировую сторону (проверки, права, хранилище, репликация) см. `content/olife_world/modules/mobapi.lua`.

| вызов | вид | цена, кредиты | мир проверяет |
|---|---|---|---|
| `block.get(x,y,z)` → `id, state` | запрос | 2 | ≤ 24 бл от моба, чанк загружен |
| `block.get_area(x0,y0,z0,x1,y1,z1)` → `{origin,size,palette,data,get(x,y,z)}` | запрос | 5 + объём/64 | объём ≤ 4096, углы ≤ 24 бл |
| `block.set(x,y,z,id[,state])` | действие | 50 | досягаемость 6, 1 раз в 10 тактов, права `blocks` |
| `block.fill_area(x0..z1,id[,state])` | действие | 50 + 2·объём | объём ≤ 4096, углы ≤ 12 бл, одна работа на моба; ставится по 32 блока за такт (128 на мир), в конце событие `fill_done {placed, skipped, ticks}` |
| `block.raycast(from,dir,max)` → `{pos,id,normal,point,dist}`/nil | запрос | 20 | начало ≤ 4 бл, длина ≤ 32 |
| `block.is_replaceable(x,y,z)` | запрос | 2 | ≤ 24 бл |
| `block.find(id, r)` → `{{x,y,z},...}` | запрос | 20 + (2⌈r⌉+1)³/64 | r ≤ 8, ≤ 64 ближайших |
| `self:get_pos/get_rot/get_scale/is_visible()` | локально | 0 | (из TickInput: `fields` scale/visible/model/anim) |
| `self:set_pos(v)` (= `move_to`) / `set_rot(x,y,z \| {yaw,pitch,roll})` | действие | 1 / 1 | шаг ≤ 2 бл, по одному за такт |
| `self:set_scale(s \| x,y,z \| {x,y,z})` | действие | 1 | 0.1..4 по оси |
| `self:set_visible(b)` | действие | 1 | |
| `self:set_texture(slot, tex)` (`"$0".."$5"`, `"*"`) / `set_model(m)` | действие | 10 / 10 | список `olife_proto:looks` или `asset:<sha>` владельца (`store.has`) |
| `self.skeleton:bones()` | запрос (кэш) | 2 | кости скелета def |
| `self.skeleton:set_bone(name,{pos,rot,scale})` | действие | 2 | кость есть, \|pos\| ≤ 4, scale 0.05..4, ≤ 16 костей |
| `self.skeleton:set_bone_model(name, m)` / `reset([name])` | действие | 10 / 2 | |
| `self:play_anim(name, speed, loop)` / `stop_anim()` | действие | 5 / 1 | VCA пака (`olife_wave/spin/bob/pulse`) или актив; speed 0.05..8 |
| `self:play_sound(snd, vol, pitch[, pos])` | действие | 20 | звук пака `olife/*` или актив; vol 0..1, pitch 0.25..4, pos ≤ 16 бл, 1 раз в 4 такта |
| `self:text3d(text, color)` | действие | 2 + байт/100 | ≤ 128 байт без управляющих, цвет `{r,g,b,a}` или `#rrggbb[aa]` |
| `self:look_at(eid \| {x,y,z})` | локально → `set_rot` | 1 | |
| `self:nearby(r)` → `{{eid,kind,name,owner,pos,dist}}` | запрос | 20 | r ≤ 16, ≤ 32 |
| `memory.get(k)` / `keys()` / `size()` | локально (первый доступ — запрос `memory.load`, 5) | 0 | |
| `memory.set(k, v)` (`nil` — удалить) | действие | 2 + байт/64 | хранилище A4 (`store.kv_set`: квота 64 КиБ, значение ≤ 4096, кредиты хранилища) |

Протокол (аддитивно, `sandbox.yaml`): действие `Ext{op, json}` (tag 9) для всех операций без своего варианта, сообщение
`Answers{tick, items[{eid,qid,json}]}` (id 9, мир → сервис перед TickInput; сервис копит их в `pending_answers` и
вливает в `EntityInput.answers`), `LoadKeep` (id 10: как Load, но сущность с тем же исходником (sha256) остаётся с
состоянием — мир переподключается после своего рестарта). JSON-строки: `{"type":"load","keep":true}`, `answers`.
`Hello.proto` = 2 (мир шлёт новое только сервису с proto ≥ 2 и грузит скрипты после ответа Hello).
**Персистентность VM**: `--state-dir DIR [--persist-every N]` — образы владельцев (`owner_<n>.img` + `owner_<n>.json` с
хэшами исходников) пишутся каждые N тактов, на ctl `persist` и `quit`; новый владелец при создании поднимается из образа
(`restored_owners`), так что после убийства сервиса переменные Lua продолжаются с последнего образа. Счётчики `meters`:
`loads_kept`, `answers`, `persisted`, `persist_ms`, `restored_owners`. Тесты `tests/script_api.rs` (5): цены и форма
каждого действия, Ext туда-обратно, запросы с ответами, бинарный Answers, LoadKeep, образ на диске, тайм-аут запроса.
Luau-рантайм эти API не получил (запасной).

## UX A4: canvas (03.10.2026, агент olife_a4)
`canvas.new(w, h)` (1..256) — RGBA-поверхность userdata в памяти wasm (в куче Lua владельца, входит в `lua_heap_max`),
методы `set/get/fill/clear/rect/line/blit/size/hash/commit`, `canvas.rgba(r, g, b[, a])` -> 0xRRGGBBAA. Рисование — C
(`lua-wasm/sandbox.c`, `c_cv_*`), оплачивается топливом wasm как любой код. `cv:commit(slot)` — одно действие
`{op = "canvas.commit", slot, w, h, rgba_b64}`, собранное в своём буфере (общий буфер действия — 64 КиБ, а 256×256×4 в base64 —
350 КБ); не больше одного коммита на сущность за такт (лишние — `actions_dropped`), цена `2 + w*h/1024` (`api_price_action`).
Бинарный контракт: `CanvasCommit{slot, w, h, rgba}` (base64 -> байты в `binproto.rs`, тест `a4_canvas_tests`). Мир кодирует
PNG и кладёт в хранилище владельца (VoxelCore `content/olife_world/modules/store.lua`). Проверка нативно: 8×4, линия/рект,
`hash`, второй коммит за такт отброшен, `canvas.new(300, 2)` — ошибка, чужой self — ошибка.
