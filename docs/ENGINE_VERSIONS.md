# Версии движка (каркас волны 1)

Источник истины — `engines/registry.toml` (происхождение, sha256, патч F2F, `f2f_version`) + `engines/<id>/ORIGIN.md`
(рецепт, равенство сборки по рецепту артефакту). Пути — `machine.toml` (`engines_root`, `builds_root`, перекрытия
`[engines.<id>]`). Ядро получает `[engines.*]` в прежнем формате (`root res stock exe builds{f2f,stock,vctest}`).

| id | версия | сток | F2F `hello.version` | патч |
|---|---|---|---|---|
| `v031` (default) | 0.31 | CI main @ 454aa205 | `0.31-f2f` | `f2f-454aa205.patch` |
| `v032` | 0.32 | CI release-0.32 @ dc62ccfb | `0.32-f2f` | `f2f-032.patch` |
| `v0327` | 0.32.7 | релиз v0.32.7 (zip `23ec6612…`) | `0.32.7-f2f` | `f2f-0327.patch` |

Вид проекта выбирает движок `engine = "<id>"`, аренда — `--param engine=<id>`, сценарий vctest — `--engine <id>`.
Новая версия: `f2f/README.md` «Перенос патча на новый релиз».
