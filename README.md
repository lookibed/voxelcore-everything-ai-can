# voxelcore-everything-ai-can

Экосистема «VoxelCore для ИИ-агентов»: агенты (Claude Code в WSL или другие) запускают движок VoxelCore, шагают его кадр
за кадром, снимают кадры из буфера, сравнивают с эталоном и гоняют ворота — **не трогая ввод и экран пользователя** и не
мешая друг другу. Дайте агенту ссылку на этот репозиторий — с `docs/ONBOARDING.md` он продолжит работу с теми же
возможностями.

- **Демон лаборатории** `labd` (Windows) владеет всеми процессами: экземпляры живут в Job Object, порты — из пула, журнал,
  прогоны, история, ворота, панель — у него.
- **Аренды**: агент берёт экземпляр вида проекта (`lab lease <проект> <вид>`), работает с ним по имени и отдаёт.
- **Тестовая сборка F2F вместо ввода ОС**: движок агентов — только сборка с `--f2f` (шаг кадра, снимок FBO, синтетический
  ввод, изоляция от ОС); демон проверяет `hello` и убивает неизолированное. Стоковое окно — только пользователю.
- **Версия движка — измерение**: `engines/registry.toml` (0.31, 0.32, 0.32.7), сверка `hello.version`, история и ворота по
  версиям.
- **MCP-мост** `lab` и MCP-сервер `voxelcore` — те же возможности из Claude Code.
- **Проекты — плагины**: игры и службы описаны в `projects/<имя>/` (виды, сценарии, golden, ворота); ядро их не знает.

```
            ┌───────────── WSL ─────────────┐        ┌──────────────────── Windows ─────────────────────┐
 агент ───→ │ bin/lab   MCP voxelcore (vc_*)│──────→ │ labd (vclab.daemon)  127.0.0.1:25700 / 25800–49  │
            │           MCP lab (мост)      │ interop│  аренды ── Job Object ──→ VoxelCoreF2F.exe --f2f │
            └───────────────────────────────┘        │  F2F-пул (TCP) ── hello/mode/step/input/shot     │
                                                     │  сценарии → прогоны → golden → ворота → панель   │
  machine.toml (корни ПК)                            │  policy: сток только пользователю; ввод изолирован│
  engines/registry.toml (v031, v032, v0327)  ──────→ │  projects/<p>: project.toml + plugin.py (+cli,   │
  f2f/patches (тестовая сборка движка)               │               mcp_tools, sup_panel)              │
                                                     └──────────────────────────────────────────────────┘
```

## За час с нуля
Подробно — [docs/ONBOARDING.md](docs/ONBOARDING.md); что делать, если `lab doctor` не «ok», — [install/doctor.md](install/doctor.md).
1. Windows: Python 3.11+ и `pip install pywin32 psutil fastapi uvicorn numpy Pillow jinja2 pytest`; WSL: `python3`.
2. Стоковые релизы VoxelCore — в `engines_root` (`engines/<id>/ORIGIN.md`: откуда, sha256); тестовые сборки F2F — в
   `builds_root` (приватный `lookibed/voxelcore-f2f` или `f2f/README.md` — сборка).
3. `cp machine.toml.example machine.toml`, поправить корни. `bin/lab doctor` — всё «ok» (что нет — `install/doctor.md`).
4. `export LAB_OWNER=<имя>`; `bin/lab daemon start --isolated` → порт `P`.
5. `bin/lab --daemon P doctor --probe` — `hello.version` каждой F2F-сборки арендой (ввод изолирован, окно hidden).
6. `bin/lab --daemon P run vc canvas_shot --engine v0327` (headless) и `--window` (F2F) — кадр `927b36b5…` в обоих.
7. `cd /mnt/c && <python_win> -X utf8 -B -m pytest -q <repo>\tests` — тесты ядра.
8. MCP: `install/mcp.json.example` → `.mcp.json`. Новый проект: `cp -r projects/_template projects/<имя>`.
9. В конце: `bin/lab --daemon P daemon stop`.

## Документы
| документ | о чём |
|---|---|
| [docs/RULES.md](docs/RULES.md) | **обязательные правила пользователя** с причинами — читать первым |
| [docs/ONBOARDING.md](docs/ONBOARDING.md) | первые 15 минут, начало сессии, MCP, где искать при затыке |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | потоки, модули `vclab/*`, порты и роли, форматы на диске |
| [docs/PROJECTS.md](docs/PROJECTS.md) | пак / композиция / проект / проект лаборатории; как устроен проект лаборатории, сценарии, golden/ворота, `lab play`, перенос |
| [docs/PACKS.md](docs/PACKS.md) | каталог паков по слоям: что это, чем интересен, последняя зелёная версия, где доказательства |
| [catalog/packs.toml](catalog/packs.toml) | тот же каталог машинно: слой, путь, происхождение, зависимости, `last_green_engine`, тесты, размер |
| [docs/PORTING.md](docs/PORTING.md) | как перенести пак на самую свежую версию движка: шаги, изменения движка по релизам, поломки, golden |
| [docs/LESSONS.md](docs/LESSONS.md) | грабли: симптом → причина → что делать |
| [docs/GLOSSARY.md](docs/GLOSSARY.md) | словарь |
| [docs/ENGINE_VERSIONS.md](docs/ENGINE_VERSIONS.md) | версии движка |
| [docs/adr/](docs/adr/README.md) | решения: контекст → решение → последствия |
| [f2f/PROTOCOL.md](f2f/PROTOCOL.md), [f2f/README.md](f2f/README.md) | протокол тестовой сборки; патчи и сборка |

## Что внутри
| каталог | что |
|---|---|
| `vclab/` | ядро: `daemon/`, `leases/`, `scenario/`, `quality/`, `cli/`, `mcp/`, `policy.py`, `engines.py`, `machine.py`, `projects.py`, `play.py`, `supervise.py`… (`docs/ARCHITECTURE.md` §5) |
| `bin/` | точки входа: `lab` (sh из WSL), `lab.py`, `labd.py`, `labctl.py`, `labpipe.py`, `mcp_bridge.py`, `voxelcore_mcp.py`, `run_tool.py` |
| `engines/` | `registry.toml` (происхождение, sha256, F2F-патч, `f2f_version`) + `<id>/ORIGIN.md` |
| `f2f/` | протокол, патчи тестовой сборки, рецепт сборки, Lua-пробы |
| `projects/` | проекты лаборатории: `vc` (тесты движка, запуски паков), `wasmrt`, `olife`, `alphamine`, `_template` (новый проект), `_parked` |
| `packs/` | паки, композиции и паки проектов — каталог `docs/PACKS.md`, `catalog/packs.toml` |
| `catalog/` | `packs.toml` — машинно-читаемый каталог паков |
| `tests/` | pytest ядра (Windows-Python; `LAB_SKIP_ENGINE=1` — без движка) |
| `install/` | `doctor.md`, `mcp.json.example`, bootstrap (каркас) |

## Монолитный каталог
С 29.10 агент заходит в один каталог и видит всё: `engines/<id>/` (установленные стоковые движки; `v031`, `v032` — ссылки
на старые каталоги), `builds/` (exe F2F 0.31/0.32/0.32.7, патчи и скрипты сборки), `packs/<имя>/` (все паки и
композиции), `projects/<p>/` (проекты лаборатории `vc`, `wasmrt`, `olife`, `alphamine` + их `tools/` и `external/` —
эталоны, golden, шлюз, песочница; `vc/scenarios_legacy` — старые сценарии; `_snapshot_agents_docs` — журналы агентов).
Снаружи — только чужие репозитории (Spider, clang/wasi-sdk, vcpkg). **В git** — код (`vclab`, `bin`, проекты), паки
(Lua, шейдеры, ассеты), документы, реестр движков, патчи F2F. **Только на диске** (`.gitignore`) — сами движки и exe
(`engines/v*/`, `builds/`), веса моделей и большие сгенерированные модули, данные игр (`*.wad`, `*.pak`, `*.epk`),
эталонные клиенты/серверы, golden и миры проектов (`projects/*/external/…`). Где взять недостающее — снимок
`lookibed/voxelcore-workbench-snapshot-2026-10`, свои репозитории паков (`catalog/packs.toml` → `origin`), пересборка.

## Правила (кратко)
Ввод ОС запрещён и не нужен: движок агентами — только арендой тестовой сборки `--f2f`; стоковое окно — только `lab play
--user` пользователя или разовый `--final-check` главной сессии. Замеры — только на простаивающем ПК (`lab perf`). Кадр
тестов — 854×480. Общий демон перезапускает только admin (`lab daemon upgrade`); правки ядра — на изолированном демоне.
Движком владеет один агент; «стоп» — остановить всё сразу. Коммит и пуш — только по просьбе. Полностью — `docs/RULES.md`.

## Статус переноса
| волна | что | состояние |
|---|---|---|
| 1 | ядро `vclab`, `machine.toml`, реестр движков, `projects/vc` и `_template`, `lab doctor`, CI | готово (29.10.2026) |
| 4 | рецепт сборки F2F, чистка путей машины в F2F | идёт |
| 5 | документы с нуля (`docs/`, этот README) | идёт |
| 6 | перенос проектов: wasmrt → olife → alphamine (по проекту на волну) | впереди |
| 7 | exe F2F в GitHub Releases, bootstrap, исходники служб (Rust-шлюз, песочница) | впереди |

## Откуда что
Репозиторий вырос из рабочего каталога движка; его полный снимок — приватный
`lookibed/voxelcore-workbench-snapshot-2026-10` (лаборатория `tools/lab`, MCP `tools/mcp`, паки, документы агентов
`agents/*.md`). Ветки тестовой сборки F2F (`f2f-454aa205`, `f2f-032`, `f2f-0327`) — приватный `lookibed/voxelcore-f2f`.
| было (`<снимок>/tools/...`) | стало |
|---|---|
| `lab/labcore/{admin,api,client,service}.py`, `lab/labd.py` | `vclab/daemon/` |
| `lab/labcore/{procs,ports,logwatch}.py` | `vclab/leases/` |
| `lab/labcore/{scenario,journal,runs,decode}.py` | `vclab/scenario/` |
| `lab/labcore/{golden,compare,gate,history,perf,sysload}.py`, `reference/compare.py` | `vclab/quality/` (+ `metrics.py`) |
| `lab/labcore/{config,policy,f2f,play,supervise,projects,dashboard}.py` | `vclab/` (+ `machine.py`, `engines.py`) |
| `lab/{lab,labctl,labpipe}.py`, `lab/labcore/{cli2b,cli_sup}.py`, `lab/schedule/` | `vclab/cli/` (+ `doctor.py`) |
| `lab/mcp_bridge.py`, `mcp/{voxelcore_mcp,vc_lab,journal,run_tool,pixel_debug}.py`, `mcp/*.ps1` | `vclab/mcp/` |
| `lab/lab.toml` (пути, `[engines.*]`) | `lab.toml` (без путей) + `machine.toml` + `engines/registry.toml` |
| `lab/projects/vc` | `projects/vc` |
| `labcore/cli_sup.py` (`lab olife`), панель olife в `supervise.py`, тесты olife | `projects/olife/{cli.py,sup_panel.js,tests/}` |
| `mcp/{eagler_tools,alpha_tools,alpha_vc}.py`, `lab/projects/{alphamine,olife,wasmrt}` | не перенесены (волна 6) |
