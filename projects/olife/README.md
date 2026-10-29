# projects/olife — вынесено из ядра лаборатории (волна 1), проект переезжает в волне 6

Нет `project.toml` — демон этот каталог не загружает. Здесь лежит то, что в рабочем каталоге было **внутри ядра**:
- `cli.py` — `lab olife ...` (было `labcore/cli_sup.py`); ядро вызывает его через точку расширения CLI (`lab <проект>`);
- `sup_panel.js` — секции панели supervisor (кнопки оператора, вайтлист, антифрод; было в `labcore/supervise.py`);
- `tests/` — тесты, которым нужен настоящий проект olife: `test_supervisor.py` (+`fake_sup.py`), `test_olife_session.py`
  (+`fake_olife.py`), части `test_vctest_engine`/`test_f2f032_engine`.
Волна 6: перенести `project.toml`, `plugin.py`, `olife_*.py`, паки и сценарии из рабочего каталога; пути — через `{machine.*}`.
