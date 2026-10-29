# Онбординг агента

Для нового агента (Claude Code или другого) на новом ПК. Цель первого часа — машина проходит `lab doctor`, изолированный
демон выдаёт аренду тестовой сборки движка, сценарий `vc canvas_shot` даёт известный кадр, MCP подключён.
Коротко: `install/bootstrap.sh` → `bin/lab doctor` → `bin/lab daemon start --isolated` → `lease vc engine --start` →
`f2f hello` → `lab run vc canvas_shot` (`927b36b5…`) → `daemon stop` (§2).

## 0. Что прочитать (в таком порядке)
1. `docs/RULES.md` — обязательные правила пользователя. Нарушение части из них демон сам отклонит; остальное — на тебе.
2. Этот файл.
3. `docs/ARCHITECTURE.md` — как устроено; `docs/GLOSSARY.md` — слова.
4. `f2f/PROTOCOL.md` — протокол тестовой сборки; `docs/ENGINE_VERSIONS.md` — версии движка.
5. `docs/PROJECTS.md` — когда пишешь или переносишь проект; `docs/LESSONS.md` — прежде чем «чинить» что-то странное.

## 1. Начало сессии (каждый раз, до любой работы)
Прошлая сессия могла оборваться: агентов не возобновить, недоделанное лежит на диске.
1. `git status --short` и `git log --oneline -3` репозитория (и других, где работаешь) — что не закоммичено. Незнакомые
   правки не собирать и не «доделывать» вслепую: найти описание (файл прогресса, отчёт), при сомнении спросить пользователя.
2. Файл прогресса прошлой задачи (`WAVE*_PROGRESS.md`, свой `*_PROGRESS.md`) — на чём остановились.
3. `bin/lab ps --table` (общий демон) и `bin/lab daemon list` (изолированные): свои мёртвые аренды — `lab release`; чужие и
   `foreign` — не трогать (`docs/RULES.md` 2.4).
4. `bin/lab daemon status` — `stale: true` значит, что демон исполняет не тот код, что на диске; применяет только admin
   (`lab daemon upgrade`), агент — сообщает.
5. Кто ещё работает (список агентов), занят ли ПК (`bin/lab sysload`), если собираешься мерить.

## 2. Первые 15 минут на новом ПК
Нужно только: Windows 10/11, WSL, интернет, аккаунт GitHub с доступом к этому (приватному) репозиторию. Старый рабочий
каталог (`voxelcore-0.31.0_pre_gemini`), `D:\Prog\AlphaMine`, сборка F2F и легаси-версии `v031`/`v032` **не нужны**.
Проверено имитацией чистого ПК 29.10 (волна 7): от клона до кадра `canvas_shot` — около минуты, bootstrap — 13–45 с.

### 2.1. Клон и bootstrap
```bash
cd /mnt/c/<каталог>                       # диск Windows: демон и движок — Windows-процессы (bootstrap.sh вне /mnt/<диск> откажет)
git clone https://github.com/lookibed/voxelcore-everything-ai-can.git && cd voxelcore-everything-ai-can
#   паки (packs/, ~110 МБ) не нужны лаборатории: git clone --no-checkout ... && git sparse-checkout set --no-cone '/*' '!/packs/' && git checkout main
install/bootstrap.sh                      # из WSL; на Windows: powershell -ExecutionPolicy Bypass -File install\bootstrap.ps1
```
Что делает (`install/bootstrap.ps1`, `bootstrap.sh` — обёртка; повторный запуск идемпотентен, готовое сверяется по sha256):
1. Находит Windows-Python 3.13 (`--python`/`-Python`, `py -3.13`, `C:\Python313`, `%LOCALAPPDATA%\Programs\Python\Python313`;
   нет — `winget install Python.Python.3.13`), ставит недостающие `pywin32 psutil fastapi uvicorn numpy Pillow jinja2 pytest`.
2. Проверяет `gh` (WSL и/или Windows; `gh auth login` — релизы приватного репозитория) и `python3` в WSL.
3. Создаёт `machine.toml` из `machine.toml.example`, если его нет: `engines_root = <repo>\engines`,
   `builds_root = <repo>\builds`, `work_root = <repo>\work`, `python_win` — найденный. Есть — не трогает.
4. Скачивает сток версии по умолчанию с GitHub Releases upstream (`engines/registry.toml`: `release_url`, `zip_sha256`;
   0.32.7 — zip `23ec6612…`) в `engines\v0327\`, сверяет `VoxelCore.exe` (`51851a0b…`), пишет `ORIGIN.txt`.
5. Скачивает тестовую сборку F2F из нашего релиза: `gh release download f2f-v0327-767234c5 --repo
   lookibed/voxelcore-everything-ai-can` -> `builds\0327\VoxelCoreF2F-0327-767234c5.exe`, сверяет `4ce9fde3…`.
6. Запускает `lab doctor`.

Пути шагов 4–5 bootstrap берёт из реестра через `vclab.engines.resolve` — ровно там их будет искать демон. Сток уже лежит
в другом месте — до bootstrap создать `machine.toml` с `[engines.v0327] root = '...'`, и он скачивать не будет.
WSL: `python3` (3.10 хватает: MCP `voxelcore`, `bin/run_tool.py`), `git` с `core.autocrlf=input` (bootstrap ставит в репозитории).

### 2.2. Движки
- Версия по умолчанию — `[engines] default` реестра (`v0327`): сток в `{engines_root}\<install_dir>` (`engines\v0327`),
  F2F в `{builds_root}\<f2f_exe>` (`builds\0327\…`). Её ставит bootstrap; обязательна только она.
- `v031`, `v032` — `legacy = true`: сток — CI-артефакты без публичной ссылки, exe F2F не опубликованы. Нужны только
  снимку машины-источника; `lab doctor` пишет о них `info`. Если понадобятся — архив у пользователя, пути —
  `[engines.<id>] root/f2f` в `machine.toml`.
- Новая версия движка — `f2f/README.md` «Перенос патча на новый релиз», `docs/PORTING.md`.

### 2.3. `machine.toml`
Создаёт bootstrap (2.1, шаг 3). Ключи и смысл — `vclab/machine.py` (`KEYS`), образец — `machine.toml.example`; строки —
в одинарных кавычках (литералы TOML). Файл в `.gitignore`: путей машины в git нет.
Репозиторий **самодостаточен**: ни symlink'ов, ни путей к другим установкам (`tests/test_self_contained.py`). Паки —
`{repo_root}\packs`, данные проектов — `projects/<p>/external/`, движки — `{engine.*}`. MCP `vc_start` (вид `vc dev`)
работает в `<work_root>\vc_dev`, паки подключаются `--param packs=a,b` (junction из `packs\`, снимаются при release);
стоковый `vc runtime` (`lab play vc --user`) — в `<work_root>\vc_runtime` (`install/doctor.md#self-contained`).

### 2.4. `lab doctor`
`bin/lab doctor` — таблица «ok / warn / FAIL / info» с подсказкой; `FAIL` — дальше нельзя, `info` — необязательного нет (это
нормально). Ожидаемый вывод на чистом ПК и что делать по каждой строке — `install/doctor.md`. Без `--probe` движок не
запускается вовсе (сток — `--version` без окна, F2F — по образу exe).

### 2.5. Свой изолированный демон
```bash
export LAB_OWNER=<твоё_имя>                 # владелец аренд; субагенту главной сессии ещё LAB_ROLE=agent
bin/lab daemon start --isolated             # печатает порт P (25800–25849), свой каталог <work_root>\lab\isolated\<P>
bin/lab --daemon P ps --table               # первая строка: "# ISOLATED daemon :P (starter <имя>)"
bin/lab --daemon P doctor --probe           # настоящий hello.version каждой F2F-сборки арендой (--f2f, окно hidden)
```
Изолированный демон — для проверок и правок ядра: у него свои аренды, порты (25850 + 10·(P − 25800) … +9), данные; права
уровня демона — у тебя (`starter`). Общий демон (25700) не перезапускать. Если на 25700 живёт демон другой установки
(например, рабочего каталога) — с этим репозиторием работать только через изолированные демоны (`install/doctor.md`
«daemon»).

### 2.6. Первая аренда и `hello`
```bash
bin/lab --daemon P lease vc engine --param engine=v0327 --start      # -> аренда vc-engine-1, порт F2F из пула
bin/lab --daemon P f2f vc-engine-1 hello                              # version 0.32.7-f2f, flags {clock: virtual, input: isolated, window: hidden}
bin/lab --daemon P f2f vc-engine-1 mode '{"fixed": true, "seed": 12345}'
bin/lab --daemon P f2f vc-engine-1 step '{"ticks": 40, "frames": 40}'
bin/lab --daemon P f2f vc-engine-1 shot                               # PNG в shots\ прогона аренды, w/h/sha256
bin/lab --daemon P logs vc-engine-1 --tail 20
bin/lab --daemon P release vc-engine-1                                # quit -> при надобности TerminateJobObject -> логи в прогон
```
Ожидаемое: `ready` за единицы секунд; без `isolated` в `hello.flags` демон сам убил бы экземпляр (`isolation-failed`).
Эталон меню 0.32 после `mode{seed 12345}` + `step{40,40}` — `02a16804…` (`f2f/README.md`, шаг 5).

### 2.7. Первый сценарий
```bash
bin/lab --daemon P run vc canvas_shot            # движок по умолчанию (v0327): стоковый 0.32.7 --headless --test (без окна)
bin/lab --daemon P run vc canvas_shot --window   # тестовая сборка F2F, часы virtual; другая версия — --engine <id>
```
В обоих — `cross.png` 64×32 с sha256 `927b36b5…` (`f2f/README.md`, приёмка волны 1). Вывод печатает каталог прогона,
вердикт, версию движка, код выхода, логи и снимки.

### 2.8. Как читать прогон и журнал
- `bin/lab --daemon P runs --table` — прогоны (id, состояние, вердикт, снимков, каталог).
- Каталог прогона: `report.json` (поле `scenario`: шаги с длительностью и результатом, снимки с `sha256_rgb`, версия и sha
  exe, вердикт), `journal.jsonl` (все вызовы прогона), `logs\<аренда>_<поток>_start<N>.log`, `shots\<сценарий>\`.
- `bin/lab --daemon P journal --table --last 30` — общий журнал демона (`--lease`, `--inner` — вложенные вызовы плагинов).
- Доказательства для отчёта брать из `report.json`, а не из обрезанного вывода консоли.

### 2.9. Тесты ядра и уборка
```bash
cd /mnt/c && <python_win в WSL-пути> -X utf8 -B -m pytest -q '<repo Windows-путь>\tests'
LAB_SKIP_ENGINE=1 WSLENV=LAB_SKIP_ENGINE ...      # без движка (ПК занят); без WSLENV переменная до Windows-Python не дойдёт
bin/lab --daemon P daemon stop                     # в конце — свой изолированный демон
```

## 3. MCP
`install/mcp.json.example` → `.mcp.json` в каталоге, где работает Claude Code; подставить путь к `python_win` (WSL-путь),
путь репозитория (Windows-путь для моста, WSL-путь для `voxelcore`) и `LAB_OWNER`.
- `lab` — мост на Windows-Python (`bin/mcp_bridge.py`): `lab_ps`, `lab_lease`, `lab_release`, `lab_start`, `lab_stop`,
  `lab_f2f` (shot — картинкой), `lab_logs`, `lab_stdin`, `lab_runs`, `lab_run`, `lab_compare`, `lab_golden`, `lab_history`,
  `lab_gate`, `lab_play`, `lab_perf`, `lab_call`, `lab_daemon` (только чтение) + `lab_<проект>_<имя>` возможностей плагинов.
  Мост поднимает только общий демон (25700).
- `voxelcore` — WSL-Python (`bin/voxelcore_mcp.py`): `vc_start` (аренда `vc.dev`: F2F-сборка, часы realtime), `vc_stop`,
  `vc_status`, `vc_screenshot` (F2F `shot`), `vc_input` (ввод через F2F), `vc_log`, `vc_wait_log`, `vc_pixels`,
  `vc_shader_cells`, `journal_report`, `journal_set`, `scenario_save/run/list` + инструменты проектов (`mcp_tools.py`).
  `vc_keys`/`vc_click` отключены (ввод ОС).
- Мост общий для главной сессии и субагентов: субагент передаёт `owner=<имя>, as_agent=true` в каждом вызове.
- После правки `vclab/mcp/*.py` или `mcp_tools.py` — переподключить (`/mcp`); до этого — из консоли:
  `python3 bin/run_tool.py <инструмент> '<json>'` (попадает в тот же журнал).

## 4. Каждый день
```bash
bin/lab ps --table | projects | engines --table
bin/lab lease <проект> <вид> [--param k=v] [--ttl S] --start  |  renew  |  release <аренда>
bin/lab f2f <аренда> <cmd> ['{json}']  |  logs <аренда> [--grep RX]  |  stdin <аренда> "<команда>"
bin/lab run <проект> <сценарий…> [--impl vc|java] [--golden] [--detach]  |  jobs  |  cancel <id>
bin/lab compare <runA> <runB|golden>  |  golden status <проект>  |  history <проект>  |  gate <проект>
bin/lab perf <проект> <сценарий>        # только так мерить: ждёт простоя, иначе отказ (код 4)
bin/lab call <проект>.<возможность> '{json}'  |  lab <проект> …  (CLI проекта)
```
`--daemon P` перед командой — изолированный демон; без него — общий (поднимается сам при первом вызове).

## 5. Сценарии
Формат, шаги ядра и плагина, таймлайн, тесты движка — `docs/PROJECTS.md` §4 «Сценарии (справочник)». Повторяемый путь —
сценарий (`lab run`), а не ручные вызовы.

## 6. lab play
Игра пользователя на стоковом движке — только `lab play <проект> --user` из его терминала; главная сессия — разово
`--final-check --reason "..."`; агентам — `lab play <проект> --dry-run` (тот же стек без стокового окна). Дескриптор
`[play]` и отчёт — `docs/PROJECTS.md` §6. Ночные ворота (`lab schedule install`) ставит только пользователь.

## 7. Где искать при затыке
| симптом | куда смотреть |
|---|---|
| `lab` молчит / `labd is not running on P` | изолированный демон сам не поднимается: `lab daemon start --isolated --port P`; лог — `<data>\labd.log` |
| аренда `failed` / `start-failed` | `lab --daemon P logs <аренда> --stream stdout|stderr|latest`, поле `ready` в ответе `lease --start` |
| `isolation-failed` | сборка без `--f2f`/флагов или не та сборка; `lab engines --table` (ключи F2F образа, последний `hello`) |
| `engine-mismatch` | `hello.version` не равен `f2f_version` движка аренды: `--param engine=<id>` или исправить `machine.toml` |
| `policy` 403 | стоковый exe в тестовом виде, нет `--f2f`/`--headless`; `docs/RULES.md` 1.1–1.2 |
| `admin-required`, `foreign-leases`, `live-leases` | операция уровня демона — к главной сессии; `lab audit --table` |
| `instance-dead` | процесс умер: код выхода (NTSTATUS) и хвост лога — в ответе; `0xC0000409` у 0.32 — непойманная ошибка Lua |
| `draining` 503 | общий демон ждёт конца аренд для upgrade: подождать |
| ожидание «зависло» | шаблон не совпадает: проверить на существующем логе (`lab logs --grep`), кодировка cp866/cp1251 |
| `plugin_error` / шаг ушёл «как F2F-команда» | `lab projects`, `lab journal` (`lab.plugin_load_failed`), `touch plugin.py` |
| числа замера странные | `lab sysload`, `lab ps` (чужие аренды), `contended` в отчёте; сверка с записями (`docs/RULES.md` 3.2) |
| `lab doctor` FAIL | `install/doctor.md#<строка>` |

## 8. Ожидания
Ждать условием, не `sleep`: готовность аренды (`ready` в дескрипторе), шаги сценария, `lab run` (сам ждёт задание),
MCP `vc_wait_log`, `scenario_run`. Фоновая команда Bash живёт не дольше 10 минут — долгую Windows-задачу запускать
отдельным процессом с логом и ждать по логу. Шаблон ожидания сначала проверить на уже существующем логе. После серии
MCP-действий — `journal_report(last=30)`: пометки `slow`, `idle`, `no_change` показывают, где был затык.
