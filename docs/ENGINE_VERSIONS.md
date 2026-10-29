# Версии движка

Источник истины — `engines/registry.toml` (происхождение, sha256, патч F2F, `f2f_version`) + `engines/<id>/ORIGIN.md`
(рецепт, равенство сборки по рецепту артефакту). Пути — `machine.toml` (`engines_root`, `builds_root`, перекрытия
`[engines.<id>]`). Ядро получает `[engines.*]` в прежнем формате (`root res stock exe builds{f2f,stock,vctest}`).

| id | версия | сток | F2F `hello.version` | патч (ветка @ голова) | vcpkg рецепта | собрана рецептом репозитория |
|---|---|---|---|---|---|---|
| `v031` (legacy) | 0.31 | CI main @ 454aa205 | `0.31-f2f` | `f2f-454aa205.patch` (`f2f-454aa205` @ `a57c8df3`) | `29f10019` | нет (vcpkg нет на диске) |
| `v032` (legacy) | 0.32 | CI release-0.32 @ dc62ccfb | `0.32-f2f` | `f2f-032.patch` (`f2f-032` @ `6c3a39c6`) | `ee6a47da` | нет (vcpkg нет на диске) |
| `v0327` (default) | 0.32.7 | релиз v0.32.7 (zip `23ec6612…`) | `0.32.7-f2f` | `f2f-0327.patch` (`f2f-0327` @ `767234c5`) | `a2f9862d` | да, 29.10: `f2f/reports/v0327-2026-10-29.md` |

`legacy = true` (`v031`, `v032`): сток — CI-артефакт без публичной ссылки, exe F2F не опубликован; нужны только снимку
машины-источника, `install/bootstrap` их не ставит, `lab doctor` пишет `info`. Обязательна версия по умолчанию: `v0327` —
сток с GitHub Releases upstream в `{engines_root}\v0327` (`install_dir`), F2F — GitHub Release нашего репозитория
`f2f-v0327-767234c5` (`f2f_release`) в `{builds_root}\0327\VoxelCoreF2F-0327-767234c5.exe`.

Вид проекта выбирает движок `engine = "<id>"`, аренда — `--param engine=<id>`, сценарий vctest — `--engine <id>`.
Сборка F2F: `bin/lab f2f recipe|build|verify|release <id>` — параметры рецепта в реестре (`build_*`), пути машины в
`machine.toml` (`[engines.<id>] f2f_src`, `vcpkg`); сверка со стоком той же версии и F2F-проба — отчёт `f2f/reports/`.
Новая версия: `f2f/README.md` «Перенос патча на новый релиз» и «Добавить версию в реестр».
