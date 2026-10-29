# tools/olife — протокол Olife, генератор кодеков, dev-шлюз, заглушка песочницы, негативные тесты

Волна 2 перестройки Olife (02.10, `agents/OLIFE.md`). Паки — в `content/` (рантайм):
`olife_proto` (сгенерированные кодеки), `olife_world` (авторитетный мир), `olife_client` (клиент/бот).
Здесь — то, что не является рантаймом движка: схема, генератор, Python-сервисы и тесты.

| файл | что |
|---|---|
| `protocol/{client,internal,sandbox}.yaml` | схема трёх контрактов (версии, magic, лимиты, типы, сообщения) |
| `gen_codecs.py` | генератор: схема → Lua (`content/olife_proto/modules/*.lua`) + Python (`olife_proto/*.py`) + векторы |
| `templates/wire.{lua,py,rs}` | рантайм кодеков (копируется генератором с пометкой GENERATED; `.rs` — для Rust-шлюза) |
| `protocol/vectors/*.json` | кросс-языковые векторы (Python кодирует → Lua декодирует/кодирует побайтно) |
| `gateway_dev.py` | dev-шлюз `sockets_auth`: рукопожатие, токены, баны, лимиты, keepalive, мультиплекс в мир |
| `gateway_tokens.json`, `gateway_bans.json` | статические токены (token → account) и баны dev-шлюза |
| `sandbox_stub.py` | заглушка песочницы с протоколом `sandboxd` (jsonl) и бинарным контрактом `sandbox`; код не исполняет. С волны 3a в лаборатории это вид `sandbox_stub` (сценарий `olife_sandbox_bin`), а вид `sandbox` — настоящий `olife-sandboxd` (`<repo>\projects\olife\external\sandboxd`) |
| `negative.py` | негативные тесты протокола шлюза и мира (25 случаев) |
| `editor_neg.py` | волна 4a: протокольный клиент слоя редактора (Hello, KeepAlive, PlayerInput 10/с, запросы `Script*`/`ToolUse`): `run` — 14 негативных случаев чужого аккаунта (коды `RequestReply`), `flood` — флуд консоли (границы `ConsoleDelta`), `set_code` — владелец ставит код (рестарт-тест) |
| `world_fake.py` | мир-заглушка контракта `internal` без движка (Welcome, TickSync 20 Гц на сессию, Multicast чата, `burst:N`) — замеры шлюза (вид лаборатории `world_fake`) |
| `gw_load.py` | нагрузка на шлюз: N протокольных ботов (Hello, keepalive, PlayerInput с частотой под лимитом, чат), итог JSON (вид `gw_load`, шаги `olife_gw_load`/`olife_soak`) |
| `tests/test_codecs.py` | Python: векторы, строгий разбор, ошибки кадров, фазз 3000 мутаций |
| `tests/codec_vectors.lua` | Lua в движке 0.32: векторы Python, побайтное перекодирование, ошибки, float-края, замер |
| `probes/probe_api.lua` | проба API 0.32 (Bytearray, view, byteutil, игроки/чанки, сущности) |
| `tests/bench_tickinput.lua` | замер в движке: TickInput на 500 сущностей — `json.tostring` 20–21 мс против ручной склейки 2.95 мс; `json.parse` TickResult 139 КБ — 3.1 мс |
| `olife_ticket.py` | волна 4b: билеты для `Hello.token` — спецификация, чеканка, проверка (подпись/срок/аудитория/повтор), векторы `protocol/vectors/tickets.json` (Rust-близнец `<olife-src>/gateway/src/ticket.rs`) |
| `auth_service.py` | волна 4b: сервис билетов (HTTPS с самоподписанным сертификатом или HTTP, запечатанные запросы x25519+ChaCha20-Poly1305, аккаунты/баны из БД supervisor; вид лаборатории `auth`) + `client_ticket()` для тестов |
| `ticket_check.py` | волна 4b: 11 случаев билетов против живого шлюза (good/replayed/expired/wrong_gateway/bad_signature/malformed/static/banned/bad token) — шаг `olife_ticket_auth` |
| `tests/test_tickets.py` | волна 4b: векторы билетов + сквозной прогон world_fake + gateway_dev + auth_service без движка (4 теста) |
| `tests/bench_sandbox_bin.lua` | волна 4b: в движке — TickInput/TickResult на 500 сущностей, JSON против бинарного контракта (байты, кодирование, разбор) |
| `probes/probe_https.lua`, `probes/probe_packs.lua` | волна 4b: пробы 0.32 — HTTPS (verify_ssl), `crypto`, запечатанный запрос; запись в `world:content`, `reopen_world`, `load()` |

## Схема (`protocol/*.yaml`)
```yaml
contract: client          # имя контракта = имя файла = имя модуля кодека
version: 1                # u8 в заголовке каждого кадра; любое изменение схемы -> +1
magic: 0x4F43             # u16; у каждого контракта свой ("OC", "OI", "OS"): кадр не того канала отвергается
max_frame: 1048576        # максимум тела кадра, байт
types:
  Vec3f: {fields: {x: f32, y: f32, z: f32}}
  Action:                 # union: u8 tag + поля варианта; значение {kind = "SetPos", pos = ...}
    union:
      SetPos: {tag: 1, fields: {pos: Vec3d}}
messages:
  - {id: 3, name: PlayerInput, dir: c2s, fields: {seq: u32, pos: Vec3f, rot: Vec3f}}
```
Типы полей: `u8 u16 u32 i8 i16 i32 f32 f64 bool`, `str<N>` (u16 длина в байтах + UTF-8, ≤ N), `bytes<N>` (u32 длина),
`array<T, N>` (u16 число, ≤ N ≤ 65535), `opt<T>` (u8 0|1), имя типа. 64-битных целых нет намеренно (Lua — double).
**Кадр:** `magic u16 | version u8 | type u16 | length u32 | тело`, big-endian, `length ≤ max_frame`; эвристик и
ресинхронизации нет — плохой заголовок или тело = разрыв соединения. Строгость: целые — целые в диапазоне, float —
конечные (NaN/Inf отвергаются в обе стороны), bool/opt — только 0/1, неизвестный tag/тип — ошибка, лишние байты в
конце тела — ошибка; Python ещё проверяет UTF-8 (Lua — нет: строки там байтовые).

Контракты:
- `client` v1 (клиент ⇄ шлюз; тела c2s/s2c после шлюза едут миру внутри `internal.Data`): `Hello` (proto, name, token,
  engine), `KeepAliveReply`, `PlayerInput`, `BlockAction`, `ChatSend`, `Bye`; `Welcome` (session, player_eid, tick, spawn,
  view_radius, world, blocks), `KeepAlive` (challenge), `Disconnect` (code, reason), `ChunkData` (cx, cz, data = байты
  `world.get_chunk_data`, FNV-1a), `ChunkUnload`, `BlockUpdate`, `BlockReject` (откат к `actual`), `EntitySnapshot`
  (spawns/updates с `opt` dirty-полями/despawns), `TickSync` (такт, server_ms, view_hash), `PlayerCorrect`, `ChatMessage`.
- `internal` v1 (шлюз ⇄ мир, одно соединение на шлюз): `GatewayHello` (секрет), `WorldHello`, `Attach`/`Detach`,
  `Data{session, type, payload}`, `Multicast{sessions[], type, payload}` (одно тело многим сессиям), `Ping`/`Pong`.
- `sandbox` v1 (мир ⇄ песочница): формы `sandboxd/src/protocol.rs` — `Hello`, `Load`/`LoadResult`, `Unload`,
  `TickInput{tick, seed, dt, entities[EntityInput]}`, `TickResult{tick, entities[EntityResult{actions[Action]}]}`,
  `Backpressure`, `Error`; свободные JSON-значения (`fields`, `events`, `view`, `queries`) — строкой JSON.

Волна 4a (аддитивно в v1, диапазоны c2s 16–31 / s2c 88–103): `ScriptOpen{seq, eid, edit}`, `ScriptSave{seq, eid, code ≤ 16 КиБ}`,
`ScriptRun`, `ScriptStop`, `ScriptLockRelease{seq, eid, close}`, `ToolUse{seq, tool, action, target, origin, dir}`;
`ScriptState` (код, статус, ошибка, владелец, лок, can_edit/editing, консоль ≤ 64 `ConsoleLine`, `ScriptMeters`), `ConsoleDelta`
(≤ 16 строк, `dropped`), `RequestReply{seq, op, eid, code, reason}` (коды 0–14 — `agents/OLIFE.md` «Волна 4a»),
`EntityOwnership`, `EntityMeta`. Типы `ConsoleLine`, `ScriptMeters`. Шлюзы пропускают их как любые c2s/s2c после проверки схемой.

Коды `Disconnect` (шлюз): 1 остановка, 2 нет Hello за 5 с, 3 протокол/схема, 4 авторизация, 5 бан, 6 keepalive,
7 флуд, 8 таймаут, 9 мир недоступен, 10 кик миром (или код мира), 11 медленный потребитель, 12 вход с другого соединения,
13 лимит шлюза (Rust-шлюз: соединений с IP / их частота / сессий на шлюз / шлюз полон; оба шлюза — кэш билетов полон),
волна 4b — отказ билета: 14 просрочен, 15 повтор, 16 подпись, 17 чужой шлюз (неразбираемый билет — 4).

## Генератор
```bash
python3 tools/olife/gen_codecs.py           # перегенерировать Lua + Python + векторы (нужен PyYAML, WSL)
python3 tools/olife/gen_codecs.py --check   # 1, если сгенерированное устарело
python3 tools/olife/gen_codecs.py --lang rust [--check]   # Rust-кодеки шлюза -> <olife-src>/gateway/src/proto (+ копия векторов)
python3 tools/olife/gen_codecs.py --lang all              # всё сразу
```
Rust (`--lang rust`, волна 3c): `wire.rs` (Reader/writers/Framer — заголовок проверяется до тела) + модуль на контракт:
структура на тип/сообщение (serde — для JSON-векторов; `bytes` как `{"$bytes": hex}`), `enum` на union (`kind`), `enum Msg`
с `id/name/dir/encode_body/body/frame/decode_body/from_json`, `ids::*`, `frame_raw`, `framer(max)`. Тесты Rust проходят
все 132 вектора побайтно (кодирование из JSON, разбор, перекодирование); фазз-паритет Python↔Rust
(`<olife-src>/gateway/tools/fuzz_parity.py`): 30 000 мутированных тел — одинаково приняты/отвергнуты, 0 расхождений.
Lua-кодек (`require "olife_proto:client"`): `C.append_frame(buf, "ChatSend", msg)` — кадр в Bytearray отправки
(при ошибке типа буфер не меняется), `C.body(name, msg)` → Bytearray тела, `C.decode_body(id, bytes, s, e)`,
`C.framer()` + `fr:feed(data)` + `C.read(fr)` → `name, msg, id` | `nil` (ждать) | `false, причина` (рвать соединение),
`C.read_raw(fr)`, `C.append_raw(buf, id, body)`; `C.ids/names/dirs`. Функции на сообщение сгенерированы прямым кодом
(не интерпретатор схемы). Python (`from olife_proto import client as C`): `C.frame`, `C.body`, `C.decode_body`,
`C.framer()` (`next()` → `(id, body)` | `None`, ошибки — `ProtoError`), `C.frame_raw`.
**Float конвертируются арифметически** (`frexp/ldexp`, округление half-even как `struct.pack`), не через `FLTview` над
байтами: LuaJIT в скомпилированной трассе читал устаревшее значение после байтовых записей в ту же память (LESSONS «Olife»).
`olife_proto:util` (рукописный, не генерируется): FNV-1a по u32, термы hash сущности/блока, JSONL, кольцо, `now_ms`.

Замер (движок 0.32, headless): `EntitySnapshot` со 100 обновлениями (3019 Б) — кодирование 0.058 мс, декодирование 0.159 мс.

## Тесты кодеков
```bash
python3 tools/olife/tests/test_codecs.py                              # WSL python 3.10
/mnt/c/Python313/python.exe -B 'D:\...\tools\olife\tests\test_codecs.py'   # Windows python (им работает шлюз)
LAB_OWNER=<имя> tools/lab/lab run olife '<repo>\tools\olife\tests\codec_vectors.lua'
```
Итог 02.10: Python 7/7 (132 вектора, фазз 3000 мутаций без падений), Lua в движке — 815 проверок, 0 отказов
(132 вектора: декодирование, побайтное перекодирование, кодирование из JSON, усечение/хвост отвергнуты; ошибки кадров;
побайтовая подача; float: 1.5, −0, min subnormal, f32 max, 0.1, half-even 2^24+1/+3; 20 000 случайных f64/f32).

## Dev-шлюз `gateway_dev.py`
`python gateway_dev.py --listen <порт клиентов> --upstream 127.0.0.1:<порт мира> [--f2f <порт управления>]
[--metrics <json>] [--tokens gateway_tokens.json] [--bans <json>] [--secret S] [--name gw1]` — stdlib Python 3.10+.
Клиент: первый кадр — `Hello` за 5 с; токен → аккаунт; бан аккаунта/IP (файл перечитывается при изменении); имя
`[A-Za-z0-9_-]`; кадр клиента ≤ 64 КиБ; тело проверяется схемой и направлением (c2s) **до** пересылки; лимиты на сессию
60 сообщений/с (запас 120) и 64 КиБ/с (запас 256 КиБ) → флуд = `Disconnect 7` + бан IP на 30 с; keepalive раз в 2 с со
случайным `challenge`, без ответа 10 с — `Disconnect 6`; очередь отправки на клиента ≤ 16 МиБ (иначе 11). Мир: одно
соединение, `GatewayHello` с секретом, переподключение раз в 1 с (после рестарта мира сессии рвутся, игроки входят
заново — позиция восстанавливается миром). Закрытие соединения — полузакрытие и дочитывание до 1 с (иначе RST и клиент
теряет только что отправленный `Disconnect`). Порт управления (протокол F2F лаборатории): `hello`, `metrics` (байты,
сессии, RTT keepalive, задержка мир→шлюз по `TickSync`, отказы по кодам, события), `sessions`, `kick {session}`,
`ban {account|ip}`, `quit`. Прод-версия — Rust `olife-gateway` (ниже); этот файл остаётся эталоном поведения.
Этап 6 (supervisor, `tools/lab/README.md` «Этап 6»): `--auth-url http://127.0.0.1:<демон лаборатории>/sup` — токен
(sha256) проверяется в БД supervisor (`GET /sup/auth`), бан-лист — `GET /sup/bans` раз в 2 с (забаненные сессии
рвутся кодом 5); демон не отвечает — файлы выше (событие `auth_fallback`). `world_status {supervised, note}` (порт
управления): под supervisor потеря мира закрывает сессии кодом 9 с причиной `world restarting (supervisor...)`.
`--packs-http <порт> --packs-manifest <json>`: `GET /manifest.json`, `GET /files/<пак>/<путь>` (только файлы манифеста
стороны client/both, sha256 сверяется), смена манифеста → `packs.version` в `metrics` (клиентам сообщить нечем — шаг протокола).

## Прод-шлюз `olife-gateway` (Rust, волна 3c)
Исходники `<olife-src>/gateway` (локальный git, без коммитов), бинарник `<repo>\projects\olife\external\gateway\olife-gateway.exe`
(нативная сборка MSVC: `<olife-src>/gateway/tools/win_build.sh`), README там же. Те же флаги, что у `gateway_dev.py`
(`--listen --upstream --f2f --metrics --tokens --bans --secret --name --auth-url`) + `--admin <порт>` (HTTP 127.0.0.1:
`GET /status /sessions /health`, `POST /kick /ban /drain`, `--admin-token`), `--log <jsonl>`, `--public` (иначе 127.0.0.1),
лимиты (`--max-sessions --max-conns --max-conns-per-ip --conn-rate-ip --conn-burst-ip --rate-msgs ...`), `--hash-token`.
Поведение, тексты причин и коды `Disconnect` — как у эталона (проверено `negative.py`: 25/25, таблица кодов совпадает);
порт управления — тот же протокол (`hello metrics sessions kick ban quit world_status` + `drain`). Отличия: токены в памяти
только как SHA-256 (файл может содержать `token_sha256`), challenge из CSPRNG, лимиты соединений на IP и неудачных входов
(код 13 / временный бан), медленный клиент ещё и по застрявшей записи (> 15 с), `quit` = плавная остановка (код 1 всем).
Лаборатория: вид `gateway_rs`, `lab run olife <сценарий> --impl rs`; нагрузка — `world_fake.py` + `gw_load.py`
(сценарии `olife_gw_throughput`, `olife_gw_soak`, перф `lab perf olife gateway_load --param impl=rs|py`). Цифры —
`agents/OLIFE.md` «Волна 3c». Безопасность — `agents/research/OLIFE_GATEWAY_SECURITY.md`.

## Заглушка песочницы `sandbox_stub.py`
`python sandbox_stub.py --listen <порт> [--f2f <порт>] [--dir <каталог>]`. Один порт, транспорт по первому байту:
`{` — JSON-строки ровно как `<olife-src>/sandboxd` сегодня (`hello`, `set_limits`, `load`, `unload`, `tick`, `meters`,
`quit`), иначе — бинарный контракт `sandbox`. Пользовательский код **не исполняется**: каждой загруженной сущности —
встроенное «orbit» (set_pos по окружности через текущую точку, set_rot, print раз в 100 тактов). Первые 200 строк
jsonl-запросов пишутся в `<dir>/requests.jsonl` — их можно подать в настоящий `sandboxd`:
```bash
(cat requests.jsonl; echo '{"type":"quit"}') | <olife-src>/sandboxd/target/release/olife-sandboxd --runtime wasm --threads 1
```
Проверено 02.10: 128 запросов мира → 2/2 `load_result ok`, 125 `tick_result`, 250 сущность-тактов `ok`, set_pos шаг
≤ 0.2 (проходит валидацию мира), топливо ≈ 63 тыс. на сущность за такт. Порт управления: `hello`, `stats`, `exec` (всегда
отказ — обвязка сценария `olife_negative`).

## Негативные тесты `negative.py`
`python negative.py --gateway <порт> [--world <порт>]` (или шаг `olife_negative_proto` лаборатории). 25 случаев: плохой
magic, версия, кадр больше лимита (только заголовок) и больше `max_frame`, неизвестный тип, усечённая/слишком длинная
строка, неверный UTF-8, хвост в теле, 4 КиБ мусора, не-Hello первым, сообщение сервера от клиента, плохой токен, версия
клиента, плохое имя, забаненный аккаунт, тайм-аут рукопожатия, второй Hello, неверный challenge, прямой мусор в порт мира
(плохой magic, плохой секрет, Data до GatewayHello, кадр > 4 МиБ — мир рвёт соединение и живёт), законный вход (Welcome),
флуд 600 сообщений → 7, повторный вход с того же IP → 5 (бан 30 с; поэтому флуд — последним).

## Запуск всего вместе
Через лабораторию (аренды, порты из пула): `tools/lab/lab run olife olife_consistency|olife_load|olife_blocks|
olife_negative_proto|olife_sandbox_bin|olife_clients_f2f|olife_negative`, ручная сессия — `tools/lab/lab call
olife.session '{"clients":2,"client_kind":"bot"}'` → `lab stdin olife-world-1 status`, `lab f2f olife-client-1 state`,
`lab call olife.release '{"session":"..."}'`. Подробно — `tools/lab/README.md` «Этап 4 / волна 2» и `agents/OLIFE.md`.

## Волна 4b (02.10, olife_w4b): билеты, паки на лету, бинарный мост песочницы
- **Билеты** (`olife_ticket.py`, `auth_service.py`; подробно — `agents/research/OLIFE_GATEWAY_SECURITY.md` §7). Шлюзы:
  `--ticket-key <файл: hex | {"key","gateway"}>` (ключ шлюза K_gw), `--gw-id <аудитория>`, `--auth-mode tokens|tickets|both`
  (по умолчанию `both` при ключе), `--ticket-cache N`; пустое значение флага = флага нет (так передаёт лаборатория). Сервис:
  `python auth_service.py --listen P --f2f C --master <файл> [--tls 1] [--seal-key <x25519 hex>] [--auth-url .../sup]
  [--gateways gw1,gw2] [--ttl 30] [--require-sealed 0|1]`; `POST /ticket` (открытый `{token, gateway}` или запечатанный
  `{v, epk, ct}`), `GET /health`, `/pubkey`; порт управления: `metrics`, `mint` (только негативные тесты).
- **`PacksChanged{version, url, files}`** (client.yaml id 75, s2c, добавлено в v1): шлюз (оба) следит за `--packs-manifest`
  раз в 1 с и шлёт сессии сразу после её `Welcome` и всем при смене; `--packs-url` (по умолчанию `http://127.0.0.1:<packs-http>`).
  Клиент — `content/olife_client/README.md` «Волна 4b».
- **Бинарный контракт песочницы** теперь у настоящего `olife-sandboxd` (тот же порт, транспорт по первому байту) и мост мира
  по умолчанию `bin` (`--sandbox-proto jsonl` — запасной путь). Вид мира в TickInput — `sbmeter.encode_view` (ручная
  склейка JSON; `json.tostring` на сущность стоил 4×). Замер в движке (`tests/bench_sandbox_bin.lua`, 500 сущностей,
  3819 элементов вида, среднее 20 повторов): TickInput JSON (`encode_tick`) 2.41 мс / 303 469 Б; BIN с `json.tostring`
  видов 19.41 мс / 327 485 Б; BIN с `encode_view` 4.66 мс / 289 979 Б (из них кодек 0.55 мс, без видов 0.28 мс / 42 518 Б);
  TickResult (500 × set_pos+set_rot) JSON `json.parse` 3.87 мс / 138 971 Б против BIN-разбора 1.84 мс / 53 514 Б.

## Волна 4c: сетевой код
Схема `client.yaml` (аддитивно в v1): `MoveInput` (32), `InvAction` (33), `PlayerState` (104), `EntityDelta` (105),
`InventoryState` (106), `InvReject` (107), `PlayerAck` (108); типы `Vec3b/Vec3s/Vec3i/RotQ/EntSpawnQ/EntMoveQ/ItemSlot`;
`BlockReject.reason` 7 — нет предмета. Поведение — `content/olife_world/README.md`, `content/olife_client/README.md`
«Волна 4c», цифры — `agents/OLIFE.md`.
- **Инжектор задержки** `gateway_dev.py`: `--rtt-ms N` (всем сессиям) или порт управления `latency {rtt_ms, name?|session?}`
  — половина RTT задерживает каждое направление (клиенту — очередь записи с отметкой времени, миру — очередь сессии;
  порядок сохраняется, keepalive-ответ тоже задерживается, поэтому RTT шлюза показывает введённое). У Rust-шлюза нет.
- Тесты: `tests/movement_test.lua` (движение в движке), `tests/bench_snapdelta.lua` (стоимость `snapdelta`: 6 сессий × 11
  сущностей — 0.037 мс/такт с кодированием).

## UX round 1 (02.10, olife_ux1): настройки и удаление сущности, профайлер
Схема `client.yaml` (аддитивно в v1, 39 сообщений, 156 векторов client / 220 всего): c2s `EntityEdit{seq, eid, op 1 удалить |
2 переименовать | 3 вид, name, model, texture}` (22) → `RequestReply` op 7 (коды 1/2/3/9 как у 4a, 15 — плохое
имя/модель/текстура/op); s2c `EntityLook{eid, model, texture}` (93) — вид всем, кто видит сущность; `ScriptProfile{eid, tick,
ticks, errors, text_dropped, rejected_total, vm_heap, vm_peak, vm_state}` (94) — раз в секунду открывшим редактор (память VM
владельца — когда песочница её сообщает, иначе −1). Кодеки Lua/Python/Rust перегенерированы, `--check` зелёный; Rust-шлюз
пересобран (`<olife-src>/gateway/tools/win_build.sh test`: тесты 7+6+1+8 ok; в `tests/codecs.rs` 39 сообщений, 220 векторов).
`editor_neg.py`: +8 случаев (`delete/rename/look_not_owner` → 3, `look_bad_model/texture`, `rename_bad_name`, `edit_bad_op` → 15,
`delete_unknown_eid` → 1) — 22/22; `Client.edit()` (поле `name` сообщения конфликтует с первым аргументом `req`).
Векторы в движке: `tests/codec_vectors.lua` — 1343 проверки / 0. `tests/movement_test.lua` проверяет, что монеты больше нет.

## UX A1 (03.10, olife_a1): права, друзья, форк
- Схема `client.yaml` аддитивно в v1, диапазоны A1: c2s 40–45 (`EntityPermsSet` 40, `EntityFork` 41, `FriendRequest` 42,
  `PermsCheck` 43), s2c 110–119 (`EntityPerms` 110, `FriendList` 111, `EntityForked` 112); типы `PermRule`,
  `FriendEntry`; `RequestReply` op 8–11, коды 16–18. Остальные волны: A2 120–129/46–49, A3 130–139/50–54, A4 140–149/55–59.
  Кодеки Lua/Python/Rust перегенерированы, `--lang all --check` зелёный; Rust-шлюз пересобран (01:02, sha256 `a16a59c3…`).
- `perms_neg.py` — протокольные тесты без UI (тот же `Client`, что `editor_neg.py`): `admin_matrix` (админ при правилах
  «owner» проходит все 9 действий) и `negative` (25 случаев: чужой ставит права 3, плохие action/audience/имя в списке 15,
  нет сущности 1, не бенч 2, PermsCheck 15/3/0, форк чужого 3, нет сущности 1, друзья: сам/неизвестный/пусто/плохое
  имя 16, принять/отклонить/удалить без запроса 17, плохой op 15, список 0, лимит форков 11/мин -> 18). Шаги
  лаборатории `olife_perms_admin`, `olife_perms_neg` (`tools/lab/projects/olife/olife_a1.py`).

## UX A2 (03.10, olife_a2): чат, команды оператора
- Схема `client.yaml` (аддитивно в v1): тип `ChatEntry`; s2c 120 `ChatLine`, 121 `ChatHistory`, 122 `OpResult`, 123 `Notice`;
  `EntityMeta.status` += 3 throttled, 4 frozen (значения). Нового c2s нет: команды идут `ChatSend` «/…» (оба шлюза его уже
  пропускают). Резерв A2: c2s 46–49, s2c 120–129. Кодеки Lua/Python/Rust перегенерированы (`--check --lang all` зелёный).
- `chat_probe.py` — протокольный клиент чата (Hello, KeepAlive, вводы; `background()` держит сессию из потока; `command("/x")`
  → `OpResult`, `history()`, `lines()`, `of("Notice")`, `disconnect_code()`); шаги `olife_a2_chat`/`olife_a2_op`.
- `gen_sounds.py` — синтез `content/olife_client/sounds/olife/fx_*.wav` (детерминированно).

## UX A4 (03.10, olife_a4): хранилище — активы, KV, canvas
Схема (аддитивно в v1; A4: c2s 55–59, s2c 140–149): `AssetUpload` (≤ 60 000 Б: кадр клиента у шлюзов ≤ 64 КиБ),
`AssetOp` (attach/detach/share/release/list/manifest), `EntityAssets`, `AssetList`, `AssetReply`; типы `AssetRef`, `AssetInfo`;
`sandbox.yaml` Action `CanvasCommit` (tag 10, сырые RGBA ≤ 256×256). Коды 0, 40–49 — `agents/OLIFE.md` «UX A4».
Шлюзы: `--assets-dir <мир>\olife_store\cas` -> `GET /assets/<sha256>` на порту паков (только 64 hex, файл перехешируется,
409 при расхождении; метрики `assets {served, bytes, missing, bad, dir}`). Пробы 0.32: `probes/probe_store_headless.lua`
(Canvas/PNG/sha256/base64/запись в `world:` без окна), `probe_store_window.lua` (текстура/модель/звук на лету),
`probe_store_model.lua` (`skeleton:get_model` после разрешения модели возвращает модель кости — не сверять чтением).

## UX A3 (03.10, olife_a3): API скриптов моба — протокол
`sandbox.yaml` (аддитивно в v1): `Action.Ext{op: str<32>, json: str<8192>}` (tag 9) — любое действие API без своего варианта
(вид, скелет, анимация, звук, text3d, block.fill, memory.set, block.set со state), `Answer{eid, qid, json}`, сообщения
`Answers{tick, items}` (id 9, мир → сервис перед TickInput) и `LoadKeep` (id 10). Сервис с ними отвечает `Hello.proto = 2`;
заглушка `sandbox_stub.py` остаётся proto 1 (мир шлёт ей прежние Load). `client.yaml` s2c 130 `EntityAppearance`
(типы `MobBone`, `MobTexture`), 131 `EntityAnim`, 132 `EntitySound`; c2s 50–54 зарезервированы, не используются.
Справочник вызовов и цен — `<olife-src>/sandboxd/README.md` «UX A3», мир — `content/olife_world/README.md` «UX A3».

## Антифрод и бан по IP (16.10, olife_antifraud) — `agents/research/OLIFE_ANTIFRAUD.md`
- **Сервис билетов** (`auth_service.py`): вход по токену — `POST <демон>/call/olife.ip_check {ip, gateway}`, по нику — то же
  внутри `olife.auth_name`; новые `code`: `ip_banned` (+ `until`), `rate_ip`, `rate_net`, `multi_account`, `sessions_ip`,
  `nick_in_use`, `nick_similar` (и `nick_reserved` для служебных имён). Демон лежит — только файл банов (адреса и CIDR).
- **Шлюзы** (`gateway_dev.py` = Rust): бан по IP/CIDR при приёме TCP (Disconnect 5 до Hello), на сессиях; `POST
  /call/olife.gw_sync` раз в 2 с вместо `GET /sup/bans` (он — запасной); лимиты из настроек супервизора: сессий с IP (13),
  соединений с подсети /24 (13); **новый Disconnect 18 `nick_in_use`** (аккаунт в игре с другого адреса); имя Hello —
  только ASCII `[A-Za-z0-9_.-]` (4); порт управления: `kick_ip {nets, reason, code, ban}`; метрики `antifraud`.
- **Пробы** `fraud_check.py`: `ticket(url, gw, name|token, src)` (HTTPS с адреса источника 127.0.0.x), `login`, `connect`,
  `pre_hello(gw, src)` (вердикт шлюза без Hello), `Forward(target, src)` (TCP-проброс с исходящим адресом — для движка);
  `chat_probe.ChatClient(..., src=)`. Шаги — `tools/lab/projects/olife/olife_fraud.py`, сценарии `olife_ipban`,
  `olife_antifraud`.
- Таблица кодов `Disconnect`: 1–17 как выше, **18 nick_in_use**; `Notice.event` 13 предупреждение антифрода, 14 throttle
  (код 22) — `client.yaml` (только комментарии, кодеки не менялись).

## Игра с друзьями по сети (16.10, olife_friends) — `agents/research/OLIFE_PUBLIC_PLAY.md`
- **Протокол (аддитивно):** `client.InfoRequest{proto, engine}` (c2s, id 7) первым кадром вместо `Hello` -> шлюз отвечает
  `client.ServerInfo{proto, name, gw_id, auth_port, auth_scheme, auth_pub, packs_port, public, whitelist, motd}` (s2c, id 76)
  и закрывает **Disconnect 19** «server info sent» (не ошибка). Кодеки Lua/Python/Rust перегенерированы (`gen_codecs.py --lang
  all`): сообщений client 76 -> 78, векторов 376 -> 384.
- **Шлюзы** (`gateway_dev.py` = Rust): `--public 1` — клиентский порт на 0.0.0.0, `--packs-public 1` — порт паков на 0.0.0.0,
  `--info <json>` — данные ServerInfo (перечитываются на каждый запрос); порт управления — всегда 127.0.0.1.
- **Сервис билетов:** `--public 1` -> HTTPS на 0.0.0.0 (порт управления 127.0.0.1); сертификат по-прежнему самоподписанный —
  доверие держится на запечатанном запросе к ключу из ServerInfo, сверенному с отпечатком приглашения / запомненным (TOFU).
- Таблица кодов `Disconnect`: 1–18 как выше, **19 info**.
