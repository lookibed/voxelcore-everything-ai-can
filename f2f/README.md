# f2f/ — тестовая сборка VoxelCore (frame-to-frame)

Правка движка разрешена **только** для автоматизации тестов (шаг кадра, снимок, синтетический ввод, изоляция, дампы);
игра, рендер и API — паками на стоковом движке. Протокол — [PROTOCOL.md](PROTOCOL.md); версии — `engines/registry.toml`.

| путь | что |
|---|---|
| `patches/f2f-<ver>.patch` | `git diff <build_base> <f2f_branch>` (35 файлов): `src/devtools/f2f*` + 24 хука вне devtools |
| `build/build_mingw.sh` | рецепт официального релиза в CLANG64-shell: `configure` / `build`, пишет `f2f_build_info.inc` (`hello.build`) |
| `build/run_mingw.ps1`, `msys_setup.ps1`, `vcpkg_clone.sh` | ручной запуск рецепта из Windows, тулчейн MSYS2 (один раз), checkout vcpkg рецепта |
| `../vclab/cli/f2fbuild.py` | `lab f2f recipe|build|verify|release <id>` — рецепт из реестра, сборка, сверка со стоком, отчёт, релиз |
| `reports/<id>-<дата>.md` | отчёты `lab f2f verify`: таблица эквивалентности со стоком и F2F-проверка |
| `tests/` | `hello.lua`, `env_dump.lua` / `env_dump_031.lua` (дамп окружения Lua), `run_headless.ps1`, пробы `f2fproj/f2fworld/f2fperf` |

Исходники F2F — ветки приватного https://github.com/lookibed/voxelcore-f2f (`f2f-454aa205`, `f2f-032`, `f2f-0327`;
`f2f` / `f2f-nopaths` — F2F на `main` 0.31). Патч в `patches/` воспроизводит дерево ветки: `git apply` на `build_base`.

## Откуда параметры
| что | где |
|---|---|
| база патча, ветка, коммит vcpkg, `VC_BUILD_NAME`, имя exe, дамп, эталон меню, `f2f_version` | `engines/registry.toml` `[engines.<id>]`: `build_base`, `f2f_branch`, `f2f_commit`, `build_vcpkg_commit`, `build_vcpkg_since`, `build_name`, `build_recipe_note`, `build_output`, `build_env_dump`, `menu_shot_sha256`, `f2f_version` |
| MSYS2, куда класть exe и логи | `machine.toml`: `msys2`, `builds_root` (exe — `{builds_root}\<каталог f2f_exe>\VoxelCoreF2F-<ver>-<sha8>.exe`, логи — `...\logs\`) |
| где worktree ветки и vcpkg на этой машине | `machine.toml` `[engines.<id>] f2f_src = '...'`, `vcpkg = '...'` (или `--src` / `--vcpkg`) |

`lab f2f recipe <id>` печатает всё это и что есть на диске (MSYS2, clang, worktree на нужной ветке и чистый ли он,
vcpkg на нужном коммите, стоковый exe).

## Собрать F2F для версии X
1. Один раз на машину: MSYS2 в `C:\msys64` (`msys2-base-x86_64-latest.sfx.exe -y -oC:\`), зеркала — рабочее первым в
   `etc\pacman.d\mirrorlist.{mingw,msys}`, затем `powershell -File f2f\build\msys_setup.ps1 -LogDir <лог>` (clang, cmake, git).
2. Исходники: `git clone https://github.com/MihailRis/voxelcore`, `git remote add private https://github.com/lookibed/voxelcore-f2f`,
   `git fetch private`, `git worktree add <src> <f2f_branch>` (или чистый checkout `build_base` + `git apply patches/f2f-<ver>.patch`
   и коммит — `hello.build.commit` берётся из `HEAD`, незакоммиченное видно как `dirty`).
3. vcpkg рецепта (`build_vcpkg_commit`): `D=/d/vcpkg-<ver> COMMIT=<sha> SINCE=<build_vcpkg_since> f2f/build/vcpkg_clone.sh`
   в CLANG64-shell (≈2.3 ГБ с кэшем сборки портов). Один vcpkg на версию; переиспользовать между версиями нельзя
   (`src/CMakeLists.txt` линкует `$VCPKG_ROOT/packages/luajit_x64-mingw-static`).
4. `machine.toml`: `[engines.<id>] f2f_src = '<src>'`, `vcpkg = '<vcpkg>'`.
5. `bin/lab f2f build <id>` — ждёт незанятый CPU (`--allow-busy` — вручную), `configure` если в `<src>\build-mingw` нет
   `CMakeCache.txt` (`--configure always|never`), `build -j4`, копия в `{builds_root}\<ver>\VoxelCoreF2F-<ver>-<sha8>.exe`
   (зарегистрированный `f2f_exe` не перезаписывается никогда), затем `verify` и отчёт `f2f/reports/<id>-<дата>.md`.
   Первая конфигурация собирает 23 порта vcpkg из исходников: 18–60 мин (медленная сеть); инкрементальная сборка ~1–2 мин.
   Фоновый Bash WSL живёт ≤10 мин: первую конфигурацию запускать из Windows
   `Start-Process -FilePath <python_win> -ArgumentList '-X','utf8','-B','bin\lab.py','f2f','build','<id>' -RedirectStandardOutput <лог>`
   и ждать по логу (`{builds_root}\<ver>\logs\f2f_build_<id>_<время>.log`).
6. `bin/lab f2f verify <id> --exe <exe> [--prev <старый F2F>]` — та же сверка отдельно (см. ниже). Код возврата 0 — всё сошлось.
7. Переключение лаборатории на новую сборку — отдельным решением: `f2f_exe` / `f2f_sha256` / `f2f_commit` в реестре (или
   `[engines.<id>] f2f = ...` в `machine.toml`), затем `lab doctor --probe`. Живой демон держит копию старого exe в арендах.

### Что сверяет `verify`
Сток той же версии (`stock`, только `--version` и `--headless --script`: окна нет), прежняя F2F-сборка (если есть) и новая:
- `--version`, строка лога `build:` (`VC_BUILD_NAME`), `jit.version`;
- дамп окружения Lua (`build_env_dump`, строки `[env]`, CRLF убраны, sha256): F2F = сток, кроме глобального `f2f` (5 функций);
- строки библиотек в exe (GLFW, libpng, OpenSSL, libcurl, LuaJIT, путь `llvm-project-<ver>`, FreeType, OpenAL) — набор и md5;
- импорт PE (DLL и функции, md5), размер и секции `.text` / `.rdata`, отсутствие `.debug*`;
- F2F-проба новой сборки: `--f2f <порт> --f2f-size 854x480 --f2f-clock virtual --f2f-window hidden`, `hello.version` =
  `f2f_version`, `hello.flags` = `{virtual, isolated, hidden}` (иначе процесс убит), `selftest` (cp1251 → «Ошибка», emoji
  сохранён, `throw` → ошибка без падения), кадр меню `mode{fixed, seed 12345}` + `step{40,40}` + `shot` = `menu_shot_sha256`.
Побайтного совпадения с артефактом CI нет и не будет (другой снимок MSYS2, путь исходников в строках CRT) — критерий
равенства именно эти таблицы.

## Перенос патча на новый релиз (как 0.32.0 → 0.32.7, 22.10)
1. **Сток.** Скачать zip релиза (`https://github.com/MihailRis/VoxelCore/releases`), сверить sha256, распаковать в
   `{engines_root}\voxelcore-<ver>_win64`. Секция `[engines.<id>]` в реестре: `version`, `release_url`, `zip_sha256`,
   `commit` (объект тега), `source_commit` (коммит тега), `install_dir`, `stock_sha256`, `ci_run`; `engines/<id>/ORIGIN.md`.
2. **Коммит vcpkg рецепта.** Релиз собирает workflow «Release» (`release.yml` → `windows-clang.yml`). Найти прогон:
   `gh run list -R MihailRis/VoxelCore -w Release`, задание `build_windows / build-windows (windows-latest, clang)`:
   `gh run view <run> -R MihailRis/VoxelCore --log` → время шага «Set up vcpkg» (`lukka/run-vcpkg` клонирует master
   vcpkg). Коммит = последний коммит master vcpkg до этого момента:
   `gh api 'repos/microsoft/vcpkg/commits?sha=master&until=<время шага>&per_page=1' --jq '.[0].sha'`.
   С 0.32.7 версии портов задаёт `vcpkg.json` (`builtin-baseline 802d61d7` + override `entt 3.16.0`), коммит vcpkg
   определяет только сам инструмент; shallow clone `--shallow-since` = дата чуть раньше baseline. `build_name` = то, что
   `release.yml` передаёт в `VC_BUILD_NAME` (у релизов — версия: в логе `build: 0.32.7`; у CI-артефактов — пусто).
   Имя выхода — по `src/CMakeLists.txt` (`VoxelEngine.exe` до 0.32.0, `VoxelCore.exe` с 0.32.7).
3. **Сток по рецепту = артефакт** (один раз на версию, до переноса F2F): собрать тег без патча (`git worktree add <src> <тег>`,
   `--src`), сравнить таблицей `verify` со стоковым exe (`lab f2f verify <id> --exe <сток по рецепту>` — F2F-проба
   у стока, естественно, не пройдёт; смотреть только раздел эквивалентности). Расхождение строк библиотек или `jit.version`
   = не тот vcpkg или baseline; расхождение дампа = не тот коммит исходников.
4. **Ветка.** `git switch -c f2f-<ver> <тег>`; `git cherry-pick <база прежней ветки>..<прежняя f2f-ветка>`. На 0.32.7 был один
   конфликт: `src/frontend/screens/LevelScreen.cpp` (`LevelScreen::draw`: upstream добавил `renderer->updateEntitiesCulling(camera)`
   и перенёс `scripting::on_frontend_render()` в блок `if (!hud->isPause())` перед `renderFrame`) — сохранить порядок
   upstream, обернуть `renderFrame` в `F2F_PERF_SCOPE(RENDER_WORLD)` как раньше.
5. **Сверить руками** авто-слитые хуки с upstream-диффом релиза (`git diff <прежняя база> <тег> -- <файл>` для каждого файла
   патча вне `src/devtools`): на 0.32.7 — `Engine.cpp` (поиск проекта по умолчанию), `MenuScreen.cpp` (`setActiveFrame`),
   `ChunksRenderer.cpp` (`MAX_CHUNKS_ENQUEUED_IN_FRAME` 4 → 64), `WorldRenderer.cpp` (`updateEntitiesCulling`), `GLFWWindow.cpp`
   (`InputCallback`, `addMouseCallback`), `lua_engine.cpp`, `lua_util.cpp`; новые глобальные множители времени
   (`Time::timeMultiplier`) — убедиться, что виртуальные часы F2F их учитывают или они равны 1. Места слоёв рендера
   (`draw_sky`, `renderOpaque`, `drawChunks`, руки, HUD) — на месте ли. Итог: `git diff --stat <тег> f2f-<ver>` — те же
   35 файлов, хуки вне devtools ≈ +345/−40.
6. **Версия.** `F2F_ENGINE_RELEASE` в `src/devtools/f2f.cpp` = `"<ver>"` → `hello.version` = `<ver>-f2f`
   (`ENGINE_VERSION_STRING` не трогать: `--version` и Lua должны совпасть со стоком). Коммит.
7. **Сборка и сверка:** `lab f2f build <id>` (пункт «Собрать»). Отчёт `f2f/reports/<id>-<дата>.md` — в git.
8. **Патч и реестр:** `git diff <тег> f2f-<ver> > f2f/patches/f2f-<ver>.patch` (проверка: `git apply --check` на теге),
   `git push private f2f-<ver>` (без `--force`; в `origin` = MihailRis — никогда). В реестр: `f2f_patch`, `f2f_branch`,
   `f2f_commit`, `f2f_exe`, `f2f_sha256`, `f2f_version`, `build_*`.
9. **Лаборатория** (изолированный демон): `lab doctor --probe` (hello.version, флаги), аренда `vc engine --param engine=<id>`,
   `lab run vc world|fail_assert|canvas_shot --engine <id>` (headless) и `--window` (F2F): Canvas `927b36b5…`; upstream
   `dev/tests/*.lua` через `lab run vc <файл> --engine <id>`.

## Добавить версию в реестр
Секция `[engines.<id>]` в `engines/registry.toml` (id — `v` + цифры версии без точек: `v0328`):
```toml
[engines.v0328]
version = "0.32.8"
description = "VoxelCore 0.32.8 release (stock) + F2F test build 0328 (branch f2f-0328 @ <sha8>)"
commit = "<объект тега>"
source_commit = "<коммит тега>"
release_url = "https://github.com/MihailRis/VoxelCore/releases/download/v0.32.8/voxelcore-0.32.8_win64.zip"
zip_sha256 = "<sha256 zip>"
ci_run = "Release <run id> (...)"
install_dir = "voxelcore-0.32.8_win64"
stock_exe = "VoxelCore.exe"
vctest_exe = "vctest.exe"
stock_sha256 = "<sha256 VoxelCore.exe из zip>"
f2f_exe = "0328\\VoxelCoreF2F-0328.exe"      # относительно builds_root
f2f_sha256 = "<sha256 сборки>"
f2f_patch = "f2f/patches/f2f-0328.patch"
f2f_branch = "f2f-0328"
f2f_commit = "<sha8 ветки>"
f2f_version = "0.32.8-f2f"
f2f_repo = "https://github.com/lookibed/voxelcore-f2f"
build_upstream = "https://github.com/MihailRis/voxelcore.git"
build_base = "v0.32.8"
build_vcpkg_commit = "<40 hex>"
build_vcpkg_since = "<YYYY-MM-DD>"
build_name = "0.32.8"
build_recipe_note = "vcpkg <sha8> (baseline <sha8>)"
build_output = "VoxelCore.exe"
build_env_dump = "f2f/tests/env_dump.lua"
menu_shot_sha256 = ""                         # заполнить после первой сверки, если меню изменилось
```
Затем `engines/<id>/ORIGIN.md`, строка в `docs/ENGINE_VERSIONS.md` и в таблице §10 `PROTOCOL.md`; `lab doctor` — «ok».
Проекты выбирают версию `engine = "<id>"` / `--param engine=<id>` / `--engine <id>`.

## Релиз сборки
`bin/lab f2f release <id>` — **dry-run** по умолчанию: тег `f2f-<id>-<sha8 ветки>`, файлы (exe
`VoxelCoreF2F-<ver>-<sha8>.exe`, последний отчёт `f2f/reports/<id>-*.md`, патч), их размер и sha256, команда
`gh release create ... --repo lookibed/voxelcore-everything-ai-can`. Публикация — только с `--publish` и только по
отдельному слову пользователя (exe ~19 МБ уходит в GitHub Release приватного репозитория).
