# Портирование пака на свежую версию VoxelCore

Для агента, который берёт самый свежий релиз VoxelCore и переносит на него паки из `packs/`. Легаси здесь не чинится:
старые версии (`v031`, `v032`) остаются эталоном «как было», новая версия — отдельная строка реестра. Каталог паков и
последняя зелёная версия каждого — `catalog/packs.toml` и `docs/PACKS.md`. Правила (движок только для тестов, ввод ОС
запрещён, замеры только на свободном ПК) — `docs/RULES.md`.

## 0. Что выбрать первым
Порядок от простого к сложному — каждый следующий опирается на предыдущий:
1. `wasmrt` + `pong` (модель «кадр», posteffect и canvas) — проверяет Lua-окружение, Bytearray, `bit`, шейдер UI.
2. `wasmdemo` — WASI (fopen из `data/`, printf в лог).
3. `gpu_compute` → `gpu_worldgen` → `smollm_gpu` — фреймы в текстуру, `assets.to_canvas`, генератор мира.
4. `doom`, `quake`, `gameboy`, `videoplayer` — тяжёлые программы; сверка fps с README/OPTIMIZATION пака.
5. Композиция `pc_wasmrt` — только когда работают паки, которые она запускает.
6. Проекты `olife`, `alphamine` — свои серверы, golden и ворота (`projects/<имя>/`).

## 1. Шаги «за час»
| # | шаг | команда / файл | готово, когда |
|---|---|---|---|
| 1 | Сток в реестр | `engines/registry.toml`: новая `[engines.<id>]` (`release_url`, `zip_sha256`, `install_dir`, `stock_exe`); `engines/<id>/ORIGIN.md` | `bin/lab doctor` без FAIL по строке движка |
| 2 | Сборка F2F | `f2f/README.md`: перенести патч `f2f/patches/f2f-<пред>.patch` на тег релиза (ветка `f2f-<id>` в приватном `voxelcore-f2f`), `lab f2f build <id>` | `bin/lab doctor --probe` — `hello.version = <ver>-f2f`, `flags.input = isolated` |
| 3 | Смоук движка | `bin/lab run vc world`, `bin/lab run vc canvas_shot` (headless и окно) | ok; меню F2F 854×480 — сверить `menu_shot_sha256` (на 0.32.0→0.32.7 совпало байт в байт) |
| 4 | Пак в проекте | движок 0.32+ подхватывает паки через проект: `vcproject/project.toml` (права, напр. `write-to-user`), `--project`, `user:project` / `res:project`, сценарий `--script user:…` | пак загружается без ошибок в логе (`lab logs <аренда>`) |
| 5 | Сценарий | `projects/<проект>/scenarios/*.json`; старые Lua/py-сценарии — `projects/vc/scenarios_legacy/` (источник шагов) | `bin/lab run <проект> <сценарий> --param engine=<id>` ok |
| 6 | Golden | снимки F2F `shot` из кадрового буфера, 854×480; база — каталогом по версии движка (`golden/<id>/…`), `lab golden import`, `promote` — только admin | сравнение ок на второй серии кадров, не на одном кадре |
| 7 | Замер (если пак про скорость) | `lab perf …` ждёт простоя; `contended` — не считается | число сверено с README/OPTIMIZATION пака, расхождение объяснено |
| 8 | Запись | `catalog/packs.toml` → `last_green_engine`, README пака → строка «проверено на <ver>» с id прогона | — |

Не меняй исходники движка, кроме F2F-патча. Функции, рендер, API — только паком (Lua, шейдеры, ассеты).

## 2. Что менялось в движке с точки зрения пака
Источник: `CHANGELOG.md` и `doc/ru/**` исходников 0.32.7 (`voxelcore-0.31.0_src_pre/voxelcore-0327`), наши переходы
(`agents/STATUS.md`, `agents/OLIFE.md` «Движок 0.32.7» в `projects/_snapshot_agents_docs/`).

### 0.31 → 0.32 (0.32.0 / 0.32.1)
- **Система проектов.** `project.toml` / `start.lua` / `project_client.lua`, разрешения (`write-to-user` — без него
  `file.write("user:…")` = access denied), `--script` и `--test` для клиента, дочерние экземпляры
  (`app.start_background_instance`). Сценарии разработки запускаются как скрипт проекта, не кликом по меню.
- **Новые библиотеки**: `animation`, `crypto`, `ctypes`, `test`, `vc`, `xml`; классы `I8view/I64view/U64view/FLTview/DBLview`,
  `debug.Logger`; `Bytearray:copy/fill/move` — можно ускорить копирование памяти wasm (проверять бит в бит).
- **События**: `on_scripts_loading`, `on_content_loaded`, `on_entity_spawned/despawned`, `on_player_set`.
- **Breaking**: события документов временно убраны из библиотеки `events`; поменялся порядок компонентов
  (`fix components order`), окружение компонентов (`fix components parent environment`).
- **canvas:encode** для PNG больше не переворачивает кадр — если пак/тест компенсировал переворот, golden поменяется.
- **Зависимости паков валидируются по версии** (`validate content pack dependency versions`) — проверь `package.json`.
- **headless**: исправлены интервалы тиков — замеры такта до/после не сравнивать без пометки.
- Наш перенос 0.31 → 0.32.1 (06–07.10, STATUS «port032», `agents/research/VC032_ADAPTATION.md`): 10 паков без пересборки
  Spider; правки только у `pc_wasmrt` — `shaders/entity.glslf` по ветке 0.32.1 (`u_dithering`), убран подменный
  `entity.glslv`, `vc.get_version()` в 0.32 возвращает **два числа** (в 0.31 функции нет — `pcall`). Мир 0.31 открывается
  0.32 без миграции (сам переписывает `world.json`). `gui.create_frame` рисует фрейм, только если окно ≥ фрейма — ПК
  проверять в 1408×902. Имена предметов и сущностей в 0.32 — одно пространство («name … is already used»), `vec3.cross` нет,
  `player.get_all_in_radius` сравнивает квадрат расстояния с радиусом.
- Наши наблюдения: `audio.play_stream` в 0.32.1 не освобождает поток (обошли в `blackhole`); quake/smollm/gpu_* —
  без правок пака, числа в пределах шума (README паков).

### 0.32.0 → 0.32.7
- `stdmin.lua`: `reload_module` исполняет модуль **в окружении пака** (раньше — глобально). Паки с горячей перезагрузкой
  своим `load` не затронуты; кто вызывает `reload_module` — проверить глобалы.
- `project.toml` / `project_client.lua` движка переехали в `res/project/` (`res:project`).
- `on_hud_render` вызывается **до** кадра — пак, рисующий в текстуру по этому событию, видит кадр раньше на 1
  (по заметкам главной сессии; в `doc/ru/scripting/events.md` 0.32.7 только «вызывается каждый кадр» — проверить пробой).
- `<modelviewer>` теперь **прозрачный** (FBO очищается с alpha 0) — под сценой цвет страницы. Golden меню меняется (olife).
- textbox: метрики шрифтов исправлены (0.32.3+: advance `'0'` для моноширинных TTF, выделение/клик от начала строки) —
  обходы шрифтом можно снимать (`olife_caret_probe`).
- `network.request` — фильтр адресов; generator registry (по заметкам главной сессии; `doc/ru` 0.32.7 этого не описывает —
  проверить пробой до опоры); VCA/animator; шейдеры облаков и deferred (res-дифф 0.32.0→0.32.7, OLIFE.md).
- Итог для нас: olife — все сценарии кроме давно красного `olife_mobs` зелёные, такт мира 5.99/6.68/8.95 мс = 0.32.0.

## 3. Типичные поломки и диагностика через лабораторию
| симптом | вероятная причина | как проверить |
|---|---|---|
| пак не виден / `access denied` на запись | нет разрешения в `vcproject/project.toml`, пак не в `packs` проекта | `lab logs <аренда> --stream`, `prepare` вида в `project.toml` |
| `attempt to index nil` в модуле при старте | новое окружение пака (`stdmin.lua`), глобал больше не виден | `lab run vc` с минимальным скриптом, `require` по одному |
| чёрный/пустой кадр у GPU-пака | движок берёт `ui.glslf` одного пака; конфликт шейдеров; изменён порядок отрисовки | включить только `gpu_compute` + клиент; F2F `shot` |
| картинка перевёрнута/сдвинута | `canvas:encode`, `on_hud_render` до кадра | сравнить с golden прошлой версии кадр за кадром |
| fps «упал вдвое» | виртуальные часы против реальных, ПК занят | `clock` вида, `lab perf` (не `contended`), README пака |
| `isolation-failed` | не та сборка или без `--f2f` | `lab engines --table` |
| `engine-mismatch` | `hello.version` ≠ `f2f_version` реестра | пересобрать F2F или поправить реестр |

## 4. Правка пака или новый golden
- **Правка пака** — если поведение разошлось с эталоном (оригинальная игра/программа, нативный C, Java-клиент): логиты,
  хэш мира, кадр игры, протокол. Паритет с эталоном важнее совпадения с прошлой версией движка.
- **Новый golden** — если поменялась только оболочка движка, а не поведение пака: прозрачный modelviewer, шрифт/каретка,
  ориентация PNG, сглаживание. Старый golden не перезаписывать: новая база — каталогом `golden/<id>/`, причина — в README
  пака и в провенансе `lab golden import`.
- Сомнение — прогнать на старой версии (`--param engine=v032`) тот же сценарий: если старая тоже «красная», это не
  регрессия нового движка (так было с `olife_mobs`).
