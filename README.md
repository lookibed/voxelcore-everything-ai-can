# voxelcore-everything-ai-can

Экосистема «VoxelCore для ИИ-агентов»: агенты (Claude Code в WSL) запускают движок VoxelCore, шагают его кадр за кадром,
снимают кадры из буфера, сравнивают с эталоном и гоняют ворота — **не трогая ввод и экран пользователя** и не мешая друг
другу. Ядро не знает ни одной игры и ни одного пути конкретного ПК: игры — это проекты (`projects/<имя>/`), пути — это
`machine.toml`, версии движка — `engines/registry.toml`.

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

## Что внутри
| каталог | что |
|---|---|
| `vclab/` | ядро: `daemon/` (labd, service, admin, api, client), `leases/` (procs, ports, logwatch), `scenario/` (интерпретатор, journal, runs, decode), `quality/` (golden, compare, metrics, gate, history, perf, sysload), `policy.py`, `engines.py`, `machine.py`, `f2f.py`, `play.py`, `supervise.py`, `projects.py`, `dashboard.py`, `cli/` (lab, labctl, labpipe, cli2b, cli_sup, doctor), `mcp/` (мост `lab`, сервер `voxelcore`, журнал, run_tool) |
| `bin/` | точки входа: `lab` (sh-обёртка из WSL), `lab.py`, `labd.py`, `labctl.py`, `labpipe.py`, `mcp_bridge.py` (Windows-Python), `voxelcore_mcp.py`, `run_tool.py` (WSL-Python) |
| `engines/` | `registry.toml` (происхождение, sha256, F2F-патч и `f2f_version` каждой версии) + `<id>/ORIGIN.md` |
| `f2f/` | протокол (`PROTOCOL.md`), патчи тестовой сборки, рецепт сборки (каркас), Lua-пробы |
| `projects/` | `vc` (тесты движка и запуски паков), `_template` (новый проект), `olife` и `_parked` (вынесенное из ядра, ждёт волны 6) |
| `tests/` | pytest ядра (Windows-Python; `LAB_SKIP_ENGINE=1` — без движка) |
| `docs/`, `install/` | документы (каркас), `doctor.md`, bootstrap (каркас) |

## За час с нуля
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

## Правила (кратко; полностью — `docs/RULES.md`)
Ввод ОС запрещён и не нужен: движок агентами — только арендой тестовой сборки `--f2f` (демон проверяет `hello.flags`
и `hello.version`, иначе убивает); стоковый exe — только `lab play --user` пользователя или `--final-check` главной
сессии, без окна — `role = "headless"`. Замеры — только на простаивающем ПК (`lab perf`). Кадр тестов — 854×480. Общий
демон перезапускает только admin (`lab daemon upgrade`); правки ядра — на изолированном демоне.

## Откуда что (перенос из рабочего каталога, волна 1)
| было (`<VC_ROOT>/tools/...`) | стало |
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
