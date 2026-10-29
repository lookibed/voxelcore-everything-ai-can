# projects/_template — шаблон проекта лаборатории

Скопировать в `projects/<имя>/` (имя без `_` в начале: каталоги с `_` демон пропускает) и поправить `name`.

| файл | что | кто читает |
|---|---|---|
| `project.toml` | виды экземпляров (`[kinds.*]`: exe, аргументы, порты, готовность, остановка, prepare), каталоги, сравнение | демон (`vclab/projects.py`), горячо |
| `plugin.py` | возможности (`api.feature`, `lab call <проект>.<имя>`, MCP `lab_<проект>_<имя>` при `mcp=True`), хуки и шаги сценариев (`api.scenario`), перф-сценарии (`api.perf`) | демон, горячо |
| `scenarios/*.json` | сценарии `lab run <проект> <имя>` (шаговые / таймлайн; справочник — docs/ONBOARDING.md) | интерпретатор демона |
| `vcproject/project.toml` | проект движка 0.32+ для `--project` (права `write-to-user` для тестов) | движок |
| `cli.py` | `lab <проект> ...` — свои команды поверх возможностей плагина | CLI (`vclab/cli/lab.py`) |
| `mcp_tools.py` | свои инструменты MCP-сервера `voxelcore` (WSL), расширение журнала, поставщик состояния для `scenario_run` | `vclab/mcp/voxelcore_mcp.py` (после `/mcp`) |
| `sup_panel.js` (нет в шаблоне) | секции панели supervisor `/sup/panel` | `vclab/supervise.py` |

Проверка: `bin/lab --daemon <P> projects` (ошибки — в `errors`/`plugin_error`), `bin/lab --daemon <P> lease template engine --start`,
`bin/lab --daemon <P> run template menu_shot`.
