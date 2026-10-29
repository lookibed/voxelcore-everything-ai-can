# Архитектура

Экосистема — это демон лаборатории `labd` на Windows, который владеет всеми процессами движка и вспомогательных служб,
и тонкие клиенты к нему (CLI `lab`, MCP-мост `lab`, MCP-сервер `voxelcore`). Код — пакет `vclab/`; ядро не знает ни игр
(они в `projects/`), ни путей конкретного ПК (они в `machine.toml`), ни версий движка (они в `engines/registry.toml`).

## 1. Почему демон на Windows
- WSL2 в режиме NAT не видит `127.0.0.1` Windows: TCP к F2F-порту движка из WSL не дойдёт. Клиенты из WSL запускают
  Windows-Python через interop (`bin/lab` → `python_win`), он и ходит на `127.0.0.1`.
- Владеть деревом процессов (движок → его дети) может только тот, кто их создал на Windows. Демон создаёт каждый процесс
  в своём Job Object с `KILL_ON_JOB_CLOSE`: остановка — `TerminateJobObject` всего дерева, смерть демона — смерть всех
  тестовых экземпляров (сирот нет). Отсюда правило «демон общий» и drain-upgrade (`docs/adr/0005-roles-drain-upgrade.md`).
- Демон слушает только `127.0.0.1` (assert в коде): ни брандмауэра, ни доступа из сети.

## 2. Поток вызова: агент → кадр

```
 агент (Claude Code, WSL)
   │  bin/lab <cmd>            MCP lab_* (stdio)              MCP vc_* (stdio, WSL-Python)
   ▼  (sh → python_win)        bin/mcp_bridge.py (python_win) bin/voxelcore_mcp.py ─→ bin/labpipe.py (python_win)
 ┌──────────────────────────────── HTTP 127.0.0.1:25700 (X-Lab-Owner, X-Lab-Role) ───────────────────────────────┐
 │ labd  vclab/daemon/{labd,api,service,admin}.py                                                                 │
 │   POST /leases {project, kind, params}  ── policy: сток? --f2f? headless? ──→ отказ 403 policy                │
 │        │ порт из пула 25600–25699, каталог inst\<аренда>, prepare, копия exe builds\<имя>-<sha12>.exe          │
 │        ▼                                                                                                       │
 │   procs: CreateProcess(SUSPENDED) → AssignProcessToJobObject → resume                                          │
 │        ▼                                                                                                       │
 │   VoxelCoreF2F.exe --f2f <порт> --f2f-size 854x480 --f2f-clock virtual --f2f-window hidden --res … --dir …    │
 │        ▼  ready: f2f hello  → проверка hello.flags.input == isolated, flags.clock, hello.version               │
 │        │                     (нет → TerminateJobObject, isolation-failed / engine-mismatch)                    │
 │   POST /f2f/<аренда> {cmd: mode|step|input|shot|…}  ── пул TCP (vclab/f2f.py) ──→ движок                        │
 │        ▼                                                                                                       │
 │   shot → PNG в shots\ прогона, sha256; журнал journal.jsonl (общий + прогона); report.json                     │
 └────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```
Время вызова (замер рабочего каталога, `tools/lab/README.md` «Замеры», 01.10): `lab f2f --repeat 100` — медиана 1.01 мс
(F2F внутри демона 0.10 мс); MCP `lab_f2f hello` через мост — медиана 1.48 мс; холодный процесс CLI из WSL — 0.14–0.18 с.
Поэтому частые вызовы (клики, двойной клик) — через постоянный процесс (`labpipe`, мост), не через CLI на каждый вызов.

## 3. Проект → плагин → виды, сценарии, ворота

```
 projects/<p>/project.toml ──────────────┐  демон перечитывает раз в 1 с (mtime project.toml и plugin.py)
   [project] runs_dir scenarios_dir     │
             golden_dir plugin          ▼
   [kinds.<вид>] exe args ports    vclab/projects.py ── Project ── виды ─→ аренды (service)
     prepare ready stop role         │                 └─ plugin.py: register(api)
     engine by_engine.<id>           │                       api.feature(...)   → lab call <p>.<имя>, MCP lab_<p>_<имя>
   [scenario] impls default_size     │                       api.scenario(...)  → хуки и шаги интерпретатора
   [compare] [golden] [gate]         │                       api.perf(...)      → lab perf <p> <имя>
   [history] [play]                  ▼
 projects/<p>/scenarios/*.json ─→ vclab/scenario/scenario.py (интерпретатор в демоне, задание = прогон)
                                     │  shots\<сценарий>\*.png, states.jsonl, report.json, journal.jsonl
                                     ▼
                         quality/compare.py ←→ quality/golden.py (golden.json + CAS)
                                     ▼
                         quality/history.py (history.sqlite) → quality/gate.py (храповик) → dashboard.py
 projects/<p>/cli.py       → `lab <p> ...`                 (vclab/cli/lab.py, точка расширения)
 projects/<p>/mcp_tools.py → инструменты MCP voxelcore      (vclab/mcp/voxelcore_mcp.py, после /mcp)
 projects/<p>/sup_panel.js → секции /sup/panel              (vclab/supervise.py)
```
Подробно — `docs/PROJECTS.md`.

## 4. Версии движка — измерение

```
 engines/registry.toml          machine.toml                       аренда
  [engines.v0327]                engines_root = 'C:\…\engines'      --param engine=v0327
   install_dir, stock_exe   ─┐   builds_root  = 'C:\…\f2f-builds'   или kind.engine = "v0327"
   f2f_exe, f2f_version     ─┼─→ vclab/engines.resolve ─→ [engines.*] ядра: root res stock exe builds{f2f,stock,vctest}
   sha256, патч, ветка      ─┘   [engines.<id>] root/f2f = '…'      ↓ подстановки {engine.*} в project.toml
                                 (перекрытие на этой машине)        ↓ hello.version == f2f_version, иначе engine-mismatch
                                                                    ↓ история/ворота/панель: столбец engine_version
```
Вид выбирает движок `engine = "<id>"`, аренда — `--param engine=<id>`, тест движка — `lab run … --engine <id>`; без них —
`[engines] default` (реестр, перекрывается `lab.toml` и `[engines]` проекта). `[kinds.<вид>.by_engine.<id>]` — перекрытия
вида для другой версии. Ворота сравнивают прогон только с основанием **той же версии**; сравнение версий между собой — в
истории и на панели, не в храповике. Таблица версий — `docs/ENGINE_VERSIONS.md`; протокол — `f2f/PROTOCOL.md`.

## 5. Модули `vclab/`
| модуль | назначение |
|---|---|
| `__init__.py` | версия пакета (`VERSION`) |
| `config.py` | загрузка `lab.toml` + реестра + `machine.toml`, переопределения окружения (`LAB_PORT`, `LAB_DATA`, `LAB_ISOLATED`...), `{work_root}`/`{repo_root}` (= `{repo}`), `PACKS_DIR`, проект по умолчанию |
| `machine.py` | `machine.toml`: ключи (`KEYS`), чтение без `tomllib` (WSL-Python 3.10), `{machine.<ключ>}` |
| `engines.py` | реестр версий движка → раскладка файлов под корнями машины, перекрытия `[engines.<id>]` |
| `policy.py` | принуждение: сток только `runtime`/`headless`, `--f2f` для exe движка, проверка `hello`, окна headless, сторож `foreign` |
| `projects.py` | дескрипторы проектов, подстановки `{…}`, шаги `prepare`, загрузка и горячая перезагрузка `plugin.py`, `PluginApi` |
| `f2f.py` | пул постоянных TCP-соединений F2F по имени аренды, переподключение, простойная команда (`f2f_idle`) |
| `play.py` | `lab play`: сеанс пользователя из `[play]` проекта, наблюдение, `play_report.md/json`, запись в историю |
| `supervise.py` | supervisor: группы служб поверх аренд, health, перезапуск с бэкоффом, инциденты, `supervisor.sqlite`, `/sup/*`, панель |
| `dashboard.py` | статическая панель истории `index.html`, `dashboard\<проект>.html`, `SUMMARY.md` |
| `daemon/labd.py` | процесс демона (uvicorn), мьютекс `Local\voxelcore_labd_<порт>`, `--isolated`, `--after-pid` |
| `daemon/service.py` | `Lab`: аренды, старт/стоп/готовность, F2F, stdin, логи, прогоны, журнал, возможности ядра `core.*` |
| `daemon/api.py` | HTTP API (FastAPI): маршруты и коды ошибок |
| `daemon/admin.py` | роли admin/agent, эвристика чужих аренд, drain, upgrade, `reload-core`, аудит, версия кода |
| `daemon/client.py` | HTTP-клиент (stdlib) для CLI, моста, labpipe; `LAB_OWNER`, `LAB_ROLE`, `LAB_PORT` |
| `leases/procs.py` | процессы под Job Object, коды выхода (NTSTATUS), «тычок» консоли для `--stdin-cmd` |
| `leases/ports.py` | пул портов аренд (реестр + проверка `bind`) |
| `leases/logwatch.py` | зеркало перезаписываемых логов (`latest.log`) в архив по сессиям |
| `scenario/scenario.py` | интерпретатор сценариев (шаговые, таймлайн, `base`, lockstep-хуки, вид `vctest`) |
| `scenario/journal.py` | журнал действий JSONL (один писатель — демон), вложенные вызовы через `parent` |
| `scenario/runs.py` | каталоги прогонов и индекс `runs_index.jsonl` |
| `scenario/decode.py` | построчное декодирование логов (UTF-8 / cp866 / cp1251) |
| `quality/metrics.py` | метрики кадра: identical %, within tol %, покрытие, bbox, Δ, diff/heat PNG |
| `quality/compare.py` | сравнение прогонов и golden: одиночные снимки и серии таймлайна, отчёт `compare.json` + `report.md` |
| `quality/golden.py` | golden: манифест `golden.json`, CAS, свежесть (`fresh`/`stale`/`unverified`), import/promote/regen |
| `quality/history.py` | история прогонов в SQLite (один писатель — демон), адаптеры форматов отчётов |
| `quality/gate.py` | ворота-храповик: основание, ε (шум эталона), регрессии, перф-вердикт, коды выхода |
| `quality/perf.py` | `lab perf`: ожидание простоя, замер загрузки, `contended` |
| `quality/sysload.py` | снимок загрузки ПК (CPU, GPU, ввод пользователя — только чтение, чужие движки) |
| `cli/lab.py` | CLI `lab` (все команды; `lab <проект> …` → `projects/<p>/cli.py`) |
| `cli/labctl.py` | старт демона через WMI, `lab daemon …`, изолированные демоны, аудит |
| `cli/labpipe.py` | постоянный канал WSL → демон (строки JSON) для MCP `voxelcore` |
| `cli/cli2b.py` | `history`, `gate`, `dashboard`, `play`, `perf`, `sysload`, `schedule`, `nightly` |
| `cli/cli_sup.py` | `lab sup …` (ядро supervisor) |
| `cli/doctor.py` | `lab doctor`: машина, корни, движки, Python, MSYS2, диск, порт |
| `cli/schedule/nightly_gate.xml` | шаблон задачи Планировщика для ночных ворот (ставит пользователь) |
| `mcp/mcp_bridge.py` | MCP-мост `lab` (stdio JSON-RPC без пакета `mcp`): `lab_*` + `lab_<проект>_<имя>` |
| `mcp/voxelcore_mcp.py` | MCP-сервер `voxelcore` (WSL): `vc_*`, журнал, сценарии, инструменты проектов |
| `mcp/vc_lab.py` | `vc_start/vc_stop/vc_input` через демон (аренда `vc.dev`) |
| `mcp/journal.py` | журнал MCP-вызовов со снимками, `journal_report`, `scenario_save/run/list` |
| `mcp/run_tool.py` | вызов инструмента `voxelcore` из консоли (без переподключения MCP) |
| `mcp/pixel_debug.py` | декодирование чисел, которые шейдер рисует в пикселях |
| `mcp/ps/*.ps1` | PowerShell-помощники (снимок окна, геометрия; `vc_keys`/`vc_click` — отключены) |

`bin/` — только точки входа: `lab` (sh из WSL), `lab.py`, `labd.py`, `labctl.py`, `labpipe.py`, `mcp_bridge.py`
(Windows-Python), `voxelcore_mcp.py`, `run_tool.py` (WSL-Python).

## 6. Порты и роли
| что | порт / диапазон | откуда |
|---|---|---|
| общий демон | 25700 | `lab.toml [daemon] port`, `LAB_PORT`, `--daemon` |
| аренды общего демона | 25600–25699 | `lab.toml [ports]` |
| изолированные демоны | 25800–25849 | `vclab/daemon/admin.py ISOLATED_PORTS` |
| аренды изолированного демона P | 25850 + 10·(P − 25800) … +9 | `admin.isolated_lease_ports` |

Порты аренд выдаёт только пул: агент их не выбирает. Тестам pytest нужны свои диапазоны — смотреть в самих тестах.

Роли (`vclab/daemon/admin.py`): владелец — заголовок `X-Lab-Owner` (`LAB_OWNER`, `--owner`); из `[roles] admins` (по
умолчанию `user`, `claude`) — `admin`, остальные — `agent`. `X-Lab-Role: agent` (`LAB_ROLE=agent`, `--as-agent`,
`as_agent=true` в мосте) только понижает. Только admin: `lab daemon stop|restart|upgrade|drain|undrain|reload-core`,
`lab release --all --force`, `lab gate accept`, `lab golden promote`. На изолированном демоне права уровня демона есть ещё у
того, кто его поднял (`starter`), кроме `golden promote` (golden общие). Немедленная операция при аренде другого владельца —
409 `foreign-leases` при любой роли; при живых арендах `stop/restart` — 409 `live-leases`. Мост MCP общий для главной сессии
и субагентов, поэтому операций уровня демона в нём нет (только чтение `lab_daemon`).

Коды ошибок API (`LabError.STATUS`): 404 `not-found`; 403 `not-owner`, `policy`, `admin-required`; 409 `busy`,
`not-running`, `instance-dead`, `no-stdin`, `foreign-leases`, `live-leases`; 503 `draining`; 504 `f2f-timeout`; 502
`f2f-unreachable`; 500 `start-failed`, `feature-error`, `isolation-failed`, `engine-mismatch`. Схема API — `/docs` демона.

## 7. Форматы на диске
`work_root` (из `machine.toml`) → данные демона `<work_root>\lab` (`lab.toml [daemon] data`):
| путь | что |
|---|---|
| `state\leases.json` | аренды: рестарт демона восстанавливает их и порты; процесс признаётся своим только по `pid + create_time` |
| `state\daemon.json` | история стартов демона (`via` start/restart/upgrade, кем, `prev_hash`) |
| `state\engine_hello.json` | последний `hello` каждой сборки по sha256 (`lab engines`, `lab doctor` без `--probe`) |
| `state\watch_<имя>.json` | позиция зеркала лога |
| `inst\<аренда>\` | каталог экземпляра (`--dir`): `logs\<вид>.out.log/.err.log` (сырые байты), файлы `prepare` |
| `builds\<имя>-<sha12>.exe` | копия exe по содержимому: оригинал можно пересобирать во время прогонов |
| `journal\journal.jsonl` | журнал: `idx t ts tool args session parent dur result error flags` + `instance run agent plugin` |
| `logs\<имя>\<время>.log` | архив зеркала (`[watch]`: новая первая строка — новая сессия) |
| `runs\`, `runs_index.jsonl` | прогоны по умолчанию (`runs_dir` проекта может указать другое) и индекс всех прогонов |
| `history.sqlite` | `runs`, `shots`, `series`, `perf`, `gates`, `ratchet` (+ `engine_version`) |
| `gates\<время>_<проект>_<набор>.json/.md` | отчёты ворот |
| `index.html`, `dashboard\<проект>.html`, `SUMMARY.md` | панель (статично, Jinja2 + SVG) |
| `supervisor.sqlite` | accounts, bans, counters, tariffs, incidents, service_events, logins (миграции по номеру схемы) |
| `incidents\<время>_<группа>_<роль>\` | `incident.json/.md`, хвосты логов, то, что дал хук `capture` |
| `audit.jsonl` | действия уровня демона и отказы: кто, роль, итог, снимок аренд, `code_hash` |
| `labd.log` | лог процесса демона |
| `schedule\`, `nightly\` | XML задачи Планировщика и журналы `lab nightly` |
| `isolated\<P>\` | та же раскладка для изолированного демона P (без зеркала лога и сторожа) |

Прогон: `<runs_dir>\<YYYYmmdd_HHMMSS>_<проект>_<сценарий>[_…]\` — `journal.jsonl`, `logs\<аренда>_<поток>_start<N>.log`,
`shots\<сценарий>\*.png`, `shots\<сценарий>\states.jsonl`, `report.json` (аренды, exe + sha256 + версия движка, снимки с
`sha256`/`sha256_rgb`/`file_sha256`, шаги, тайминги, входы golden, вердикт), `vs_golden\` (сравнение).
Внимание: `sha256` ответа F2F у движка — sha PNG-файла, у других реализаций может быть sha RGB; одинаковый смысл у всех —
`sha256_rgb` (считает интерпретатор по PNG).

Golden: `<golden_dir>\<сценарий>\golden.json` + PNG рядом + CAS `<golden_store>\sha256\ab\<sha файла>.png` (по умолчанию
`<родитель golden_dir>\lab\store`) + `golden.history.jsonl`. Манифест: `key` (сценарий и цепочка `base` по sha256, размер,
сид, impl, harness, `[golden].inputs` проекта), `provenance` (`recorded` / `backfilled` / `unknown: почему`), `produced`,
`shots` (`sha256_file`, `sha256_rgb`, `approved`), `noise` (шум эталона).

MCP (WSL-сторона): `<work_root>/mcp/journal/journal.jsonl` и снимки `<work_root>/mcp/journal/<дата>/`, сценарии MCP
`<work_root>/mcp/scenarios/*.json`, снимки `vc_screenshot` — `<work_root>/mcp/screens/`.

## 8. Чего демон не делает
- Не выбирает за агента, что запускать: виды описывает проект.
- Не поднимает храповик ворот и не трогает golden сам (только `lab gate accept`, `lab golden promote|regen`).
- Не убивает чужие процессы (сторож показывает `foreign`).
- Не переживает свой рестарт для живых экземпляров: аренды остаются в `state`, процессы умирают с Job (`dead`).
- Не применяет правки своего кода сам: `lab daemon status` показывает `stale`; применяет admin (`upgrade`), безопасные
  модули (`sysload compare gate dashboard history golden`) — `reload-core`. Правки `vclab/cli`, `vclab/mcp`,
  `daemon/client.py` — клиентские (MCP — после `/mcp`).
