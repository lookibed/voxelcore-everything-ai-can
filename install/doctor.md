# lab doctor — что делать, если не «ok»

`bin/lab doctor [--json] [--probe --daemon P] [--engine ID]`. Строка `FAIL` — дальше работать нельзя, `warn` — можно,
но что-то не так. Без `--probe` движок не запускается (сток — `--version` без окна; F2F — по образу exe и последнему
`hello` из данных демона); `--probe` — аренда `vc engine` на демоне `P` для каждой версии (тестовая сборка, `--f2f`, hidden).

## machine-toml
Нет `machine.toml` или обязательного ключа. `cp machine.toml.example machine.toml`, поправить `engines_root`, `builds_root`,
`work_root`, `python_win`. Строки — в одинарных кавычках (литералы TOML, `\` без экранирования).

## roots
Каталог не существует. `work_root` демон создаст сам (warn); остальные — создать/исправить путь. `vc_root` — рабочий
рантайм паков (`{vc_root}`), по умолчанию — корень движка `default` из реестра.

## engines
`engines/registry.toml` не читается — проверить синтаксис TOML (`python -c "import tomllib; tomllib.load(open(..., 'rb'))"`).

## engine-stock
Нет стокового релиза версии: скачать `release_url` из реестра, сверить `zip_sha256`, распаковать в
`{engines_root}\<install_dir>` (или указать `[engines.<id>] root = '...'` в machine.toml). `sha ... (registry ...)` — другой
файл, чем записан в реестре: выяснить, откуда он (перекачать). `--version failed` — exe битый или блокируется антивирусом.

## engine-f2f
Нет тестовой сборки: взять из приватного релиза `lookibed/voxelcore-f2f` или собрать (`f2f/README.md`), положить в
`{builds_root}\<f2f_exe>` или указать `[engines.<id>] f2f = '...'`. `not an F2F build` — в образе нет ключа `--f2f`.
`hello.version != f2f_version` — сборка другой версии: аренды будут убиты (`engine-mismatch`).

## python
Нужен Windows-Python 3.11+ с `pywin32 psutil fastapi uvicorn numpy Pillow jinja2` (+ `pytest` для тестов):
`<python_win> -m pip install ...`. `doctor runs on X, machine.toml says Y` — `bin/lab` взял другой python (LAB_PYTHON_WIN).

## msys2
Только для сборки F2F: MSYS2 в `{msys2}`, затем `f2f\build\msys_setup.ps1 -Msys <путь> -LogDir <каталог>`.

## cargo
Только проектам с Rust-службами; ядру не нужен.

## disk
Меньше 5 ГБ — warn, меньше 1 ГБ — FAIL. Копии exe аренд (`builds\`, ~20 МБ на сборку) и прогоны лежат в `{work_root}\lab`.

## daemon
`busy` — порт демона занят не labd: сменить `[daemon] port` в lab.toml. `another installation's daemon on this port` —
на порту общий демон другой установки (например, рабочего каталога): этот репозиторий тогда работает только с
изолированными демонами (`bin/lab daemon start --isolated`, `bin/lab --daemon <P> ...`) или с другим портом.
