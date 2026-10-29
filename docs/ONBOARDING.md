# Онбординг агента (каркас волны 1; полная версия — волна 5)

1. Прочитать `README.md` (схема, «за час с нуля»), `docs/RULES.md` (обязательные правила), `f2f/PROTOCOL.md`.
2. `bin/lab doctor` — машина готова? (`--probe --daemon <P>` — настоящий `hello.version` каждой F2F-сборки арендой).
3. Своё имя владельца: `export LAB_OWNER=<агент>`; субагент главной сессии — ещё `LAB_ROLE=agent`.
4. Правки ядра — только на изолированном демоне: `bin/lab daemon start --isolated` → `bin/lab --daemon <P> ...`;
   в конце `bin/lab --daemon <P> daemon stop`. Общий демон (25700) не перезапускать: это делает только admin (`upgrade`).
5. Движок: `bin/lab --daemon <P> lease <проект> <вид> --start`, `f2f <аренда> hello|step|shot`, `release`; сценарии —
   `run <проект> <сценарий>`; тесты движка — `run vc canvas_shot [--window] [--engine v0327]`.
6. Тесты ядра: `cd /mnt/c && <python_win> -X utf8 -B -m pytest -q <repo>\tests` (`LAB_SKIP_ENGINE=1` с
   `WSLENV=LAB_SKIP_ENGINE` — без движка).
7. MCP: `install/mcp.json.example` → `.mcp.json` (пути машины); после правок `vclab/mcp/*.py` — `/mcp`.
8. Ночные ворота (`lab schedule install`) ставит только пользователь.
