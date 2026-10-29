# Архитектура (каркас волны 1; полная версия — волна 5)

```
 WSL (агенты Claude Code)                              Windows, сессия пользователя (python_win из machine.toml)
 ┌──────────────────────────────┐                     ┌──────────────────────────────────────────────────────────┐
 │ bin/lab (sh) ────────────────┼── interop ────────→ │ bin/lab.py ─ vclab.cli.lab ─┐                            │
 │ MCP voxelcore (WSL-Python)   │                     │ bin/labpipe.py ─────────────┤ HTTP 127.0.0.1:25700       │
 │  vclab/mcp/voxelcore_mcp.py ─┼── labpipe ───────→  │ bin/mcp_bridge.py (MCP lab)─┤ (изолированные 25800–25849)│
 │  + projects/*/mcp_tools.py   │                     │ labctl ── WMI Win32_Process ┤                            │
 └──────────────────────────────┘                     │                             ▼                            │
                                                      │ labd (vclab.daemon): аренды ─ Job Object ─→ процессы     │
   machine.toml ── корни машины                       │   leases/ (порты 25600–25699, procs, logwatch)           │
   engines/registry.toml ── версии движка             │   f2f.py (пул TCP к тестовым сборкам)                    │
   projects/<p>/project.toml + plugin.py ──────────→  │   scenario/ (интерпретатор, журнал, прогоны)             │
                                                      │   quality/ (golden, compare, gate, history, perf)        │
                                                      │   policy.py (сток только пользователю, --f2f, headless)  │
                                                      │   supervise.py (службы, инциденты), dashboard.py         │
                                                      └──────────────────────────────────────────────────────────┘
```
- Демон живёт на Windows-Python: только он может владеть деревом процессов (Job Object `KILL_ON_JOB_CLOSE`); WSL в NAT не
  видит `127.0.0.1` Windows, поэтому клиенты WSL ходят через interop (Windows-Python) — `bin/lab`, мост MCP, labpipe.
- Ядро не знает игр: проект = дескриптор + плагин (возможности, хуки сценариев, перф) + необязательные `cli.py`,
  `mcp_tools.py`, `sup_panel.js` (точки расширения CLI, MCP voxelcore и панели supervisor).
- Движок — только тестовой сборкой F2F (`f2f/`) с проверкой `hello.flags`/`hello.version`; сток — `role = "headless"`
  или игра пользователя (`lab play --user`).
- Таблица «модуль рабочего каталога → модуль vclab» — README.md, раздел «Откуда что».
