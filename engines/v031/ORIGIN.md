# v031 — VoxelCore 0.31 (CI build of main @ 454aa205) + F2F `f2f-454aa205`

- **Стоковый рантайм**: CI-сборка `main` от 2026-02-26 (PE link time 15:23:22Z), исходный коммит `454aa205` (последний коммит
  `main` до времени линковки). Это не релиз: zip-а и URL нет; на исходной машине лежал в рабочем каталоге движка.
  `VoxelCore.exe` sha256 `6591dfc32aba8899…`, `--version` = `0.31`, лог `build: ` (пустой `VC_BUILD_NAME`).
- **Тулчейн рецепта**: MSYS2 CLANG64 (clang 22.1.8), vcpkg `29f10019` (master на 2026-02-26 14:45Z; `ports/luajit` `1c3b5a4d`
  → LuaJIT 2.1.1771261233, без overlay), `x64-mingw-static`, MinGW Makefiles, Release, `-DVC_BUILD_NAME=""`.
- **F2F**: ветка `f2f-454aa205` = `454aa205` + `a8e7ece5` (F2F) + `a049afc4` (слои рендера) + `ec07d0d1` (perf/trace, `mode`,
  `hello.gl/build`) + `527e3084` (`--f2f-clock realtime`, `--f2f-window hidden`, безусловная изоляция ввода, `hello.flags`).
  Патч — `f2f/patches/f2f-454aa205.patch` (`git diff 454aa205 527e3084`, 35 файлов). `f2f/patches/f2f-031.patch` — тот же
  F2F на `main` @ `1fbf16e3` (дерево `f2f` пользователя; отличается базой). Сборка `VoxelCoreF2F.exe` sha256 `1c03a0c3…`,
  `hello.version` = `0.31-f2f`, `hello.build.commit` = `527e3084d1`.
- Ветки F2F запушены в приватный `lookibed/voxelcore-f2f` (`f2f`, `f2f-454aa205`, `f2f-032`, `f2f-0327`).
- Эталон меню F2F 854×480 на этой сборке — см. README лаборатории рабочего каталога (этап 3а, `86feac94…` для `vc.dev`).
- **29.10 (волна 4)**: ветка `f2f-454aa205` → `a57c8df3` (только комментарии); F2F на `main` — новая ветка `f2f-nopaths` =
  `f2f` (`99a4c210`) + `41507cdc` (ветка `f2f` не тронута: её worktree с незакоммиченным F2F пользователя). Рецепт — `lab f2f
  build v031` (`build_*` в реестре, выход `VoxelEngine.exe`, дамп `env_dump_031.lua`); не собрана: vcpkg `29f10019` на диске нет.
