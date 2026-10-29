# Проекты лаборатории

Проект — всё, что ядро не знает: какие процессы запускать (движок с паком, сервер, эталонный клиент, служба), как их
готовить и останавливать, какие сценарии, эталоны и ворота. Ядро (`vclab/`) одинаково для всех проектов; проект живёт в
`projects/<имя>/` и подхватывается демоном без рестарта.

## 1. Состав каталога
| файл | обязателен | кто читает | что |
|---|---|---|---|
| `project.toml` | да | демон (`vclab/projects.py`), горячо | виды экземпляров, каталоги, сценарии, сравнение, golden, ворота, история, `lab play` |
| `plugin.py` | нет | демон, горячо | возможности (`lab call`), хуки и шаги сценариев, перф-сценарии, supervisor |
| `scenarios/*.json` (или свой `scenarios_dir`) | нет | интерпретатор демона | сценарии `lab run <проект> <имя>` |
| `vcproject/project.toml` | для `--test` 0.32+ | движок | проект движка с правом `write-to-user` (иначе `file.write("user:…")` — access denied) |
| `cli.py` | нет | `vclab/cli/lab.py` | `lab <проект> …` — свои команды поверх возможностей плагина |
| `mcp_tools.py` | нет | `vclab/mcp/voxelcore_mcp.py` (после `/mcp`) | свои инструменты MCP `voxelcore`, наборы журнала, поставщик состояния `scenario_run` |
| `sup_panel.js` | нет | `vclab/supervise.py` | секции панели `/sup/panel` |
| `tests/` | нет | pytest | тесты проекта (фейки процессов, без движка) |

Каталоги с `_` в начале (`_template`, `_parked`) демон пропускает. Проверка загрузки: `lab projects` — ошибки дескриптора в
`errors`, плагина — в `plugin_error` (при ошибке плагина остаётся прежняя рабочая версия).

## 2. `project.toml`
### `[project]`
`name`, `description`, `runs_dir` (по умолчанию `<data>\runs`), `scenarios_dir`, `golden_dir`, `golden_store` (CAS; по
умолчанию `<родитель golden_dir>\lab\store`), `plugin = "plugin.py"`.

### `[kinds.<вид>]` — вид экземпляра
| ключ | смысл |
|---|---|
| `exe` (обязателен), `copy_exe` | что запускать; `copy_exe = true` — копия по содержимому `builds\<имя>-<sha12>.exe` (оригинал можно пересобирать во время прогонов; чужой exe, который сейчас собирают, без копии не запускать) |
| `args`, `cwd`, `env`, `params` | шаблон командной строки; `params` — умолчания, перекрываются `--param k=v` (значение — JSON или строка) |
| `ports`, `f2f` | имена портов из пула → `{port.<имя>}`; `f2f` — какой из них F2F (иначе `lab f2f` недоступен) |
| `size`, `clock`, `window` | кадр (`854x480`), часы `virtual` (кадры только по `step`) / `realtime`, окно `hidden` / `normal` — ядро добавит `--f2f-clock/--f2f-window` до `--`, если сборка их знает |
| `role` | `test` (умолчание), `headless` (без окна: сток разрешён, обязателен `--headless`), `runtime` (стоковое окно: только `lab play`) |
| `engine`, `by_engine` | версия движка вида (`v0327`; `none` — не движок); `[kinds.<вид>.by_engine.<id>]` — перекрытия для другой версии |
| `prepare` | подготовка каталога экземпляра при каждом старте (ниже) |
| `ready` | готовность по порядку; процесс умер — сразу `instance-dead` |
| `stop` | мягкий стоп, потом `TerminateJobObject` |
| `logs`, `default_log` | именованные логи (+ всегда `stdout`, `stderr`) — `lab logs <аренда> --stream` |
| `stdin`, `stdin_poke` | канал stdin (`lab stdin`); `stdin_poke = "console"` — для VoxelCore `--stdin-cmd` на Windows |
| `console`, `kill_on_close` | консоль (запрещена для headless); `false` — процесс переживает демон (только рантайм пользователя) |
| `f2f_idle` | команда в простое (`{cmd, every_s}`) — keepalive игр, которые рвут связь без трафика; параметр аренды `f2f_idle=false` выключает |
| `isolation` | для не-движков (эталонный клиент): `{argv = "--f2f", hello = {"flags.input" = "isolated"}}` |
| `window_check_s`, `shots` | сколько секунд после готовности проверять отсутствие окон (headless); каталог снимков |

Шаги `prepare` (`action`): `mkdir {path}`, `write {path, text|json}`, `template {src, dst}` (подстановки в файле), `copy {src,
dst}`, `copytree {src, dst, exclude, fresh}` (robocopy /MT:16; только внутрь каталога экземпляра), `junction {link,
target}`, `packs {packs, content, into}` (junction паков из `{vc_root}\content`), `append {path, lines}`, `properties {src,
dst, set}`. Относительные `dst/path` — от каталога экземпляра, `src` — от каталога проекта.

`ready`: `{f2f = "hello", timeout}` (подключиться и проверить изоляцию), `{log = "RX", stream, timeout}`, `{pump_log = "RX",
stream, max_frames}` (шагать кадры F2F до строки — только часы `virtual`), `{pump_f2f = {cmd, field, value}, max_frames}`.
`stop`: `{f2f = "quit", wait_exit}`, `{stdin = "stop\n", wait_exit}`, `if_param` — шаг только при непустом параметре.

Подстановки (`{ключ}` или `{ключ|умолчание}`; строка, целиком равная подстановке, получает значение как есть — список,
число): `{vc_root} {work_root} {repo_root} {lab_data} {lab_dir} {project_dir} {dir} {lease} {owner} {kind} {project} {exe}
{size} {size_w} {size_h} {port.<имя>} {param.<имя>} {run_dir} {python}`, `{engine.id|version|root|res|exe|stock}`,
`{engine.builds.f2f|stock|vctest}`, `{machine.<ключ machine.toml>}`. **Путей машины в дескрипторе нет** — только
подстановки.

### Остальные секции
- `[engines]` — свой `default` проекта и дополнительные/перекрытые `[engines.<id>]` (лучше — реестр + `machine.toml`).
- `[scenario]` — `impls = {vc = "engine", java = "ref_app"}` (вид клиента по `--impl`), `default_size`, `timeline_mode`
  (`mode` такта 0 таймлайна), `server_f2f` (lockstep по умолчанию), `vctest = {headless, window}` (виды тестов движка).
- `[compare]` — `size`, `tol`, `clear`, `metric`, `series_tol`, `regions = {имя = [x0, y0, x1, y1]}`.
- `[golden]` — `inputs = [{name, file | tree, hash = "sha1"?, impls = ["vc"]?, optional?}]`: от чего зависит эталон (мир,
  патчи эталона, exe движка, пак). Изменился вход — `lab golden status` скажет `stale` с причиной.
- `[gate]` — `eps`, `eps_by_scenario`, `perf_metric` (`all.fps_5s.p5`), `perf_rel_tol` (0.25), `perf_fail`, `perf_families`,
  `exclude_tags`, `suites`.
- `[history]` — `import = [каталоги]`: откуда `lab history import` берёт старые прогоны (кроме `runs_dir`).
- `[play]` — сеанс пользователя (раздел 6).

## 3. `plugin.py`
```python
PLUGIN_VERSION = 1
def register(api):
    api.feature("status", fn, "описание", {"type": "object", ...}, mcp=True)   # lab call <p>.status, MCP lab_<p>_status
    api.scenario(steps={"frames": step_fn}, start=..., expect=..., info=...)  # хуки интерпретатора
    api.perf("walk", perf_fn)                                                 # lab perf <p> walk
def selftest(): ...          # упал — плагин не подменяется
```
- Возможность: `fn(ctx, args) -> dict`. `ctx`: `f2f(lease, cmd, args)` (журналируется вложенным вызовом), `call(...)` (result
  или исключение), `lease(kind, params=..., start=...)`, `start/stop/release`, `info`, `log_tail`, `run_dir`, `project`,
  `owner`, `lab` (сервис; supervisor — `ctx.lab.sup`).
- Хуки сценария (`SCENARIO_HOOKS`): `start, step, translate, after_step, expect, timeline_setup, info, finish, server_step,
  lockstep_tick, lockstep_run, compare_state, stop`; шаги — `steps={имя: fn(sx, args, step) -> {ok, result|error}}`.
  `sx`: `lease(kind, role, params)`, `f2f/raw/call(cmd, args, timeout, lease)`, `kind_of()`, `port(lease, name)`, `log()`,
  `scn`, `impl`, `size`, `lockstep`, `ctx`. Описание каждого хука — docstring `PluginApi.scenario` в `vclab/projects.py`.
- Перф: `fn(px, args)`; `px.lease(kind, params, clock="realtime")`, `px.out_dir`, `px.progress()`, `px.cancelled()`; вернуть
  `{"ok", "summary_json": путь perf_summary.json}`. Ожидание простоя и `contended` делает ядро.

Горячая перезагрузка — по mtime `project.toml` и `plugin.py` раз в 1 с. Грабли (`docs/LESSONS.md` «Плагины»): модули,
которые грузит плагин, перечитываются только с `plugin.py` (`touch plugin.py`); функции регистрировать обёртками, берущими
функцию из свежего модуля в момент вызова; новый файл модуля создавать до строки, которая его грузит.

`cli.py`: `run(c, argv, opt) -> код выхода` (`c` — `LabClient`: `c.get/c.post("/call/<p>.<имя>", {"args": …})`).
`mcp_tools.py`: `register(tools, vc, text)` — добавить инструменты в `tools`, расширить наборы журнала
(`vclab.mcp.journal.extend(no_shot=…, actions=…, wait=…, …)`), поставить `vc.STATE` (поставщик состояния для `scenario_run`;
без него `scenario_run` отвечает ошибкой). Образцы — `projects/_template/`.

## 4. Сценарии (справочник)
Сценарий — JSON в `scenarios_dir` (или Lua-файл — тест движка). Шаговый:
```json
{"description": "...", "size": "854x480", "base": "<сценарий>", "base_until": "mode", "setup": {...},
 "params": {"engine": {"extra": []}}, "clear": [0,0,0], "server": {"f2f": true},
 "steps": [{"cmd": "mode", "args": {"fixed": true, "seed": 12345}},
           {"cmd": "step", "args": {"ticks": 40, "frames": 40}},
           {"cmd": "shot", "name": "menu"}]}
```
- Шаг: `{cmd, args, name, expect, optional, limit}`. Команда F2F (`hello mode step input shot render perf` движка + команды пака)
  уходит экземпляру после хука `translate`; `ok:false` останавливает сценарий (кроме `optional`), смерть экземпляра — всегда.
- Шаги ядра: `shot` (→ `shots\<сценарий>\<name>.png`, sha256, проверка размера), `compare {shot, against: golden|<png>, tol}`,
  `sleep {s}`, `note`. Шаги плагина — имена из `api.scenario(steps=…)`. `state` дополнительно пишется в `states.jsonl`.
- `base` — подготовка из базового сценария до первого шага `cmd == base_until`; хэши всей цепочки — в ключе golden.
- Перед снимками паритета — всегда `mode` (сбрасывает таймеры шейдеров и сидирует: кадр не зависит от числа кадров до него).

Таймлайн: `{"size", "server", "setup": {base, steps, mode, render, …}, "ticks", "pace_ms", "timeline": [{tick, input|chat|gui|cmd}],
"keyframes", "keyframes_every", "state_every", "state_radius", "regions"}` — серия кадров `kf_NNNN.png` и `states.jsonl`;
ожиданий внутри таймлайна нет. Тест движка: Lua-файл или `{"kind": "vctest", "test", "timeout", "window", "params"}` —
`lab run <p> <файл.lua> [--window] [--engine id]`, код выхода = вердикт, Canvas из `user:shots/` — в прогон.

## 5. Golden и ворота
- Снять эталон: `lab golden regen <сценарий> --project P --runs 3 [--impl …]` (N прогонов эталонной реализации, по
  умолчанию `--impl java`; все равны — promote, иначе записывается шум) или `lab golden promote <run> --reason R` (admin; ключ берётся записанный прогоном). Существующие каталоги
  — `lab golden import`. Свежесть — `lab golden status P`.
- Прогон с сравнением: `lab run P <сценарий> --golden` → `vs_golden\report.md`, тепловые карты. Метрика — identical % и
  within tol % по пикселям, покрытие, области; серии — по ключевым кадрам и категориям `state`, первый такт расхождения.
- Ворота: `lab gate P [--suite …]` — основание = принятый храповик или лучший прогон после последнего обновления golden той же
  версии движка, ε = шум эталона; коды 0 pass / 1 fail / 2 нет данных / 3 warn. Поднять храповик — только явно
  `lab gate accept P <run>` (admin, решение пользователя). Ворота сами планку не поднимают и golden не трогают.
- Golden — по версии движка (`docs/adr/0008-golden-per-engine-version.md`): отдельный `golden_dir` на версию и exe движка
  во `[golden].inputs`.

## 6. `lab play` и supervisor
`[play]`: `order = [виды]` (старт по порядку, стоп обратный), `engine = <вид из order>` (его выход — конец сеанса),
`names = {вид = "имя аренды"}`, `exclusive_exe` (такой exe уже работает — отказ), `ttl`, `params`,
`[[play.link]] {from, port, to, param, format}` (порт одного вида → параметр другого), `[play.options.<имя>]` (`files`,
`params`; `--opt <имя>`), `[play.report]` (`log_stream`, `status` regex строки статуса, `levels`, `events`, `server_kind`,
`server_stream`). Запуск: пользователь — `lab play P --user [--wait]`; главная сессия — `--final-check --reason`; агентам —
`lab play P --dry-run` (сценарий `<P>_play_dry`: тот же стек с F2F-клиентом вместо стокового окна). Итог —
`play_report.md/json` в каталоге прогона и запись в историю. Составной стек (группа служб) поднимается видом-«коляской»:
процесс в `order` перед рантаймом, который через HTTP демона вызывает возможность проекта и печатает строку готовности.

Supervisor (`vclab/supervise.py`, через `ctx.lab.sup`): `group(name, owner, hooks, poll_s)`, `add(group, role, lease, health,
policy)` (порядок `add` = порядок старта), `member` (неуправляемые клиенты), `down` (обратный порядок), `kill`, `restart`.
Health: `{stdin, pattern}`, `{f2f: "hello"}`, `{port: "<имя порта аренды>"}` (LISTEN дерева Job). Политика по умолчанию
(`DEFAULT_POLICY`): 5 перезапусков за 600 с, бэкофф 1 с ×2 до 30 с, стабильно 60 с, health раз в 5 с, 3 неудачи, grace 10 с.
Хуки группы: `started`, `died`, `capture`, `poll`. Инциденты — `<data>\incidents\`, учёт — `supervisor.sqlite`. Пример
проекта с supervisor — olife в снимке (`agents/research/OLIFE_PUBLIC_PLAY.md`, `tools/lab/README.md` «Этап 6»).

## 7. Примеры в репозитории
- `projects/vc` — запуски паков и тесты движка: `dev` (MCP `vc_start`: F2F-сборка, часы `realtime`, окно `normal`, по
  умолчанию `--dir {vc_root}`; `by_engine.v032` — каталог аренды), `engine` (голая тестовая сборка: меню, `virtual`,
  `hidden`), `runtime` (стоковое окно — только `lab play vc`), `vctest`/`vctest_window` (тесты 0.32+ под `--test`: headless
  сток или F2F). Сценарии — `vctests/*.lua` (`canvas_shot`, `world`, `world_window`, `fail_assert`).
- `projects/_template` — виды `engine` и `vctest`, плагин с возможностью `status` и шагом `frames`, сценарий
  `menu_shot`, `cli.py`, `mcp_tools.py`. Новый проект: `cp -r projects/_template projects/<имя>`, поменять `name`,
  `lab --daemon P projects`, `lab --daemon P lease <имя> engine --start`, `lab --daemon P run <имя> menu_shot`.

## 8. Перенос проекта из снимка (wasmrt, olife, alphamine)
Источник — рабочий каталог (снимок `lookibed/voxelcore-workbench-snapshot-2026-10`): `tools/lab/projects/<p>/`, паки
`content/<pack>`, сценарии `tools/scenarios/…`, инструменты `tools/<p>/`, MCP `tools/mcp/*_tools.py`, документы
`agents/*.md`. Оригиналы не трогать — копировать.

Что копировать:
1. `project.toml`, `plugin.py` и **все** `*.py`, которые он грузит; `scenarios/`, `scripts/`, `vcproject/`, `engine_settings.toml`.
   Без `__pycache__` и `*.bak`.
2. Проектное, вынесенное из ядра в волне 1: `projects/olife/{cli.py,sup_panel.js,tests/}`, `projects/_parked/tests/*`.
3. MCP-инструменты игры (`eagler_tools.py`, `alpha_tools.py`, `alpha_vc.py`) — в `projects/<p>/mcp_tools.py` с
   `journal.extend(...)` прежних имён и `vc.STATE` (TODO в `vclab/mcp/journal.py`).
4. Паки, которые нужны прогону: в `packs/` репозитория или по пути машины (`{machine.*}`/`{vc_root}`) — решает пользователь
   (размер, лицензии).

Что параметризовать:
- каждый `D:\…`, `C:\…`, `/root/…` → `{machine.<ключ>}`, `{vc_root}`, `{work_root}`, `{project_dir}`, `{engine.*}`;
  новый корень — ключ в `machine.toml.example` и `vclab/machine.py KEYS` (правка ядра — изолированный демон);
- `[engines.v032] root = …` проекта → реестр + `[engines.<id>]` в `machine.toml`; exe F2F → `{engine.builds.f2f}`;
- `golden_dir`, `runs_dir`, `golden_store` → под `{lab_data}` или `{machine.…}`; по версии движка;
- звук: шаг `write settings.toml` с `[audio] volume-master = 0` в каталоге аренды;
- то, что ядро раньше знало про проект (имя по умолчанию, панель, журнал MCP) — через точки расширения, не в `vclab/`.

Как доказать зелёный прогон (на изолированном демоне, владелец — свой `LAB_OWNER`):
1. `bin/lab doctor` — нет `FAIL`; `lab --daemon P projects` — проект без `errors`/`plugin_error`.
2. `lab --daemon P lease <p> <вид> --start` для каждого вида → `ready`, `hello.flags.input = isolated`, нужная версия; release.
3. `lab --daemon P run <p> <сценарий>` — те же sha256 снимков, что у прогона снимка на той же версии движка и сборке (или
   объяснённое расхождение); `lab --daemon P golden status <p>`; `lab --daemon P gate <p>` — без регрессий.
4. Тесты проекта: `<python_win> -X utf8 -B -m pytest -q projects\<p>\tests` (`LAB_SKIP_ENGINE=1` — без движка).
5. Таблица «сценарий → было (снимок) / стало (репозиторий)» с путями прогонов — в отчёт; демон остановлен, аренды сняты.
