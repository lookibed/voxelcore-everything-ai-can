# f2f/ — тестовая сборка VoxelCore (frame-to-frame)

Правка движка разрешена **только** для автоматизации тестов (шаг кадра, снимок, синтетический ввод, изоляция, дампы);
игра, рендер и API — паками на стоковом движке. Протокол — [PROTOCOL.md](PROTOCOL.md); версии — `engines/registry.toml`.

| путь | что |
|---|---|
| `patches/f2f-<ver>.patch` | `git diff <база релиза> f2f-<ver>` (35 файлов): `src/devtools/f2f*` + ~24 хука вне devtools |
| `build/build_mingw.sh`, `run_mingw.ps1`, `msys_setup.ps1`, `vcpkg_clone.sh` | рецепт официального релиза (MSYS2 CLANG64, vcpkg `x64-mingw-static`, MinGW Makefiles, Release) с параметрами вместо путей; **каркас волны 1, не запускался** |
| `tests/` | `hello.lua`, `env_dump.lua` (дамп окружения Lua: сток по рецепту = артефакт), `run_headless.ps1`, проекты-пробы `f2fproj/f2fworld/f2fperf`, `native_menu_test.lua` |

## Перенос патча на новый релиз (как делали 0.32.0 → 0.32.7)
1. Стоковый релиз: скачать zip, сверить sha256, распаковать в `{machine.engines_root}\voxelcore-<ver>_win64`, записать
   `engines/<id>/ORIGIN.md` и секцию в `engines/registry.toml` (`release_url`, `zip_sha256`, `commit`, `stock_sha256`).
2. Рецепт: коммит vcpkg = master на шаге «Set up vcpkg» CI-задания релиза (или `builtin-baseline` манифеста), `VC_BUILD_NAME`
   как в `release.yml`. Сначала собрать **сток** и доказать равенство артефакту: `--version`, `jit.version`, `tests/env_dump.lua`
   (sha256 вывода), строки библиотек, список импортов DLL. Байт-в-байт не бывает (другой снимок MSYS2) — это нормально.
3. Ветка `f2f-<ver>` = тег релиза + cherry-pick коммитов F2F предыдущей ветки; конфликты разрешать, сохраняя порядок upstream,
   хуки вне `src/devtools` сверить руками с upstream-диффом; `hello.version` = `<ver>-f2f` (`F2F_ENGINE_RELEASE` в `f2f.cpp`).
4. Собрать F2F, записать sha256 и `f2f_version` в реестр, `git diff <тег> f2f-<ver> > patches/f2f-<ver>.patch`, запушить ветку.
5. Проверка в лаборатории (изолированный демон): `lab doctor --probe --engine <id>` (hello.version, флаги), аренда
   `vc engine --param engine=<id>` + `mode{seed 12345}` + `step{40,40}` + `shot` (эталон меню 0.32: `02a16804…`), `lab run vc
   world|fail_assert|canvas_shot --engine <id>` (headless) и `--window` (F2F): Canvas `927b36b5…`.
