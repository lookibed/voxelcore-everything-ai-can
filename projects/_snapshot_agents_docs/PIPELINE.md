# Конвейер: сборка → раскладка → проверка

Скрипты конвейера живут в Spider (правило: сборка не в каталоге движка):
`/root/Spider/Hosts/VoxelCore/pipeline/`.

## 1. Сборка и раскладка — `deploy.sh`
```bash
P=/root/Spider/Hosts/VoxelCore/pipeline
$P/deploy.sh spider                 # cargo build --release -p spider-cli
$P/deploy.sh quake doom             # собрать и положить модули в паки
$P/deploy.sh --no-build eaglercraft # только скопировать уже собранное
$P/deploy.sh all                    # spider wasi pong wasmdemo doom quake eaglercraft wasm4
```
| Проект | Сборка (Spider `tests/manual/`) | Результат → пак |
|---|---|---|
| `wasi` | — | `Hosts/Lua/wasi.lua` → `content/wasmrt/modules/wasi.lua` |
| `pong` | `real-world-pong/build.sh` (wasi-sdk) | `generated/pong.lua` → `content/pong/modules/pong/pong.lua` |
| `wasmdemo` | `wasmrt-demo/build.sh` | `generated/demo.lua` → `content/wasmdemo/modules/demo.lua` |
| `doom` | `real-world-doomgeneric/build_wasmrt.sh` | `generated/doom_wasmrt.lua` → `content/doom/modules/doom/doom_wasmrt.lua` |
| `quake` | `real-world-quakegeneric/build.sh` | `generated/quake.lua` → `content/quake/modules/quake.lua` |
| `eaglercraft` | `real-world-eaglercraft/build.sh` (Gradle + TeaVM + Spider, ~2.5 мин) | `generated/eaglercraft.lua` (~108 МБ) → `content/eaglercraft/modules/`, `assets.epk` → `data/` |
| `halflife` | `real-world-halflife/build.sh` (wasi-sdk C/C++ ~400 файлов, инкрементально `build.py`; Spider `--f32 number`) | `generated/halflife.lua` (~33 МБ) → `content/halflife/modules/`; данные Uplink в `content/halflife/data` (не в git, не в `all`) |
| `wasm4` | `wasm4-carts/translate.sh` | `export/wasm4carts/*.lua` (не в паках: лицензия CC BY-NC-SA) |

Требования: wasi-sdk (`CLANG`, по умолчанию `/mnt/d/Backups/WASI/wasi-sdk-30.0/bin/clang.exe`),
JDK 17 и Gradle 8 для Eaglercraft (`JAVA_BIN`, `GRADLE_BIN`, по умолчанию `/root/tools/...`).
Правки только в `content/*/modules/*.lua` хоста (`eag_host.lua`, `app.lua`, `gfx_*.lua`, шейдеры) не требуют
пересборки — достаточно перезапустить движок.

Eaglercraft дополнительно: `build.sh` сам запускает `tools/genreflect/GenReflect.java` (фабрики вместо
рефлексии). Правки upstream-исходников фиксировать в `patches/0001-vc-platform.patch`
(`git -C upstream diff > patches/0001-vc-platform.patch`). Сервер в wasm (`build_server.sh`) — не рабочий.

## 2. Проверки — `verify.sh`
```bash
$P/verify.sh quick   # Spider: build, unit, конформанс; тесты сервера Eaglercraft. Движок не нужен.
$P/verify.sh full    # + tools/scenarios/smoke_all.py в движке (движок и ПК должны быть свободны!)
```
Эталоны (что считается «зелёным»):
| Проверка | Эталон |
|---|---|
| Spider unit (`cargo test --workspace --exclude conformance`) | все зелёные |
| Конформанс `lua-no-ffi` | **280 passed / 32 failed** — 32 известных (NaN-payload: address, conversions, f64_bitwise, float_*, select × 4 режима). Больше провалов = регрессия |
| Конформанс `lua-jit` | 312/312 |
| Сервер Eaglercraft (`native_server/test/run.sh`) | `-- failed 0` (9 проверок; спавн сида 1234567890 — (−220, 64, 172)) |
| `wasm4_all` (`smoke_all.py wasm4`) | `ok 151, fail 0` |
| Паки wasmrt (`smoke_all.py packs`) | каждый манифест пишет fps без ошибок |
| Eaglercraft (`smoke_all.py eagler`) | до экрана `GuiCreateWorld` |

Отдельно по месту:
- LuaJIT вне движка: `tests/manual/*/run_luajit.lua` с `/root/tools/luajit/src/luajit`
  (Eaglercraft: `run_luajit.lua N` — N кадров главного меню без сервера).
- Кодогенерация под большие модули — смотреть, что LuaJIT парсит результат:
  `luajit -e 'assert(loadfile("generated/x.lua"))'` (ошибки `too many syntax levels`,
  `control structure too long`, `function or expression too complex`).

## 3. Порядок работы над изменением
1. Правка → сборка нужного проекта (`deploy.sh <проект>`).
2. `verify.sh quick`.
3. Проверка в движке по месту (MCP `eag_*`, `vc_start` + `vc_screenshot`), затем `verify.sh full`,
   если трогали Spider или wasmrt (WASM-4 — лучший регрессионный набор кодогенерации).
4. Замеры — только на свободной машине, с цифрами в лог/README пака.
