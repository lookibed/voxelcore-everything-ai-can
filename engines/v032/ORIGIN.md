# v032 — VoxelCore 0.32 (release-0.32 @ dc62ccfb, CI artifact) + F2F `f2f-032`

- **Стоковый рантайм**: артефакт CI `Windows Build (CLang)` run 36266877824, artifact `Windows-Build`,
  https://github.com/MihailRis/voxelcore ветка `release-0.32`, коммит `dc62ccfbc` («update CHANGELOG.md», 2026-09-26T19:40:17Z),
  LuaJIT 2.1.1788856981. `VoxelCore.exe` sha256 `f5aa0ea3f875…`, `vctest.exe` `723d169627a6…`. Релизного zip нет.
- **Рецепт**: MSYS2 CLANG64 (clang 22.1.8), vcpkg `ee6a47da` (master на старте CI-задания, 2026-09-26 19:40Z; tool 2026-07-27),
  23 порта (glfw3 3.5.1, libpng 1.6.58, luajit 2026-09-08, openssl 3.6.4, curl 8.22.0, freetype 2.14.3…), `-DVC_BUILD_NAME=""`.
  Первая конфигурация 2229 с, полная сборка 112 с, F2F 64 с (02.10). Сток по рецепту = артефакт по env dump, строкам и импорту.
- **F2F**: ветка `f2f-032` = `dc62ccfb` + `a5031869` (перенос F2F) + `11909814` (ориентация shot: без flipY).
  Патч `f2f/patches/f2f-032.patch` (`git diff dc62ccfb f2f-032`, 35 файлов, +2680/−40). Сборка `VoxelCoreF2F-032.exe`
  sha256 `e110f91b…`, `hello.version` = `0.32-f2f`, `hello.build.commit` = `1190981496`.
- **29.10 (волна 4)**: ветка `f2f-032` → `6c3a39c6` (только комментарии). Рецепт — `lab f2f build v032` (`build_*` в реестре);
  не собрана: vcpkg `ee6a47da` на диске нет (новый checkout ≈2.3 ГБ + первая конфигурация ≈40 мин).
- Эталоны: меню F2F 854×480 `mode{fixed, seed 12345}` + `step{40,40}` → `02a16804b3c0dae9…`; Canvas `canvas_shot` → `927b36b5…`.
