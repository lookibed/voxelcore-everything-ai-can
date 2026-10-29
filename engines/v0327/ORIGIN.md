# v0327 — VoxelCore 0.32.7 (release) + F2F `f2f-0327`

- **Стоковый релиз**: https://github.com/MihailRis/VoxelCore/releases/download/v0.32.7/voxelcore-0.32.7_win64.zip
  (опубликован 2026-10-21), sha256 zip `23ec6612b6cc1b23376b9c05439c5d24384bf5d936020a1abb4da33077bf3cba`.
  Тег `v0.32.7` = объект `aa2d13f0` → коммит `8eff080f` («Merge branch 'main' into release-0.32»).
  CI: workflow «Release» run 39632239452. `VoxelCore.exe` sha256 `51851a0b…`, `vctest.exe` `887e5c3e…`.
- **Рецепт**: MSYS2 CLANG64 (clang 22.1.8), vcpkg `a2f9862d` (master на шаге «Set up vcpkg», 2026-10-21 16:11:28Z), манифест
  `builtin-baseline 802d61d7` + override `entt 3.16.0` (shallow clone `--shallow-since=2026-09-01` достаточно),
  `-DVC_BUILD_NAME="0.32.7"` (release.yml передаёт версию), выход `build-mingw\VoxelCore.exe`.
  Первая конфигурация 3619 с (медленная сеть), сток 97–102 с, F2F 59 с (22.10).
- **F2F**: ветка `f2f-0327` = `8eff080f` + `7bd2eac4` (cherry-pick `a5031869`) + `6630b801` (cherry-pick `11909814`) +
  `0220606e` (`hello.version` = `0.32.7-f2f` через `F2F_ENGINE_RELEASE`). Один конфликт — `LevelScreen::draw`.
  Патч `f2f/patches/f2f-0327.patch` (`git diff v0.32.7 f2f-0327`, 35 файлов, +2686/−40). Сборка `VoxelCoreF2F-0327.exe`
  sha256 `e3b6592f…`, `hello.build.commit` = `0220606e65`.
- Эталоны: меню F2F `02a16804b3c0dae9…` (= 0.32.0), Canvas `canvas_shot` `927b36b5…` (= 0.32.0); upstream `dev/tests` 16/17 ok
  (`filesystem` падает из-за `write-to-user` проекта лаборатории — так же на v032).
