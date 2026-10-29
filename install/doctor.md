# lab doctor — что делать, если не «ok»

`bin/lab doctor [--json] [--probe --daemon P] [--engine ID]`. Строка `FAIL` — дальше работать нельзя, `warn` — можно,
но что-то не так, `info` — необязательного нет, и это нормально (легаси-версии, лишние ключи `machine.toml`).
Обязательны версия движка по умолчанию (`[engines] default` реестра, сейчас `v0327`) и версии без `legacy = true`.
Почти всё, что ниже, чинит повторный запуск `install/bootstrap.ps1` (из WSL — `install/bootstrap.sh`): он идемпотентен.

Ожидаемый вывод на чистом ПК после bootstrap (без старого каталога и без сборки F2F):
```
engine v031 legacy    info  not installed (legacy = true in registry: only the source machine snapshot needs it)
engine v032 legacy    info  not installed (legacy = true in registry: ...)
engine v0327 root     ok    <repo>\engines\v0327
engine v0327 stock    ok    <repo>\engines\v0327\VoxelCore.exe  sha 51851a0b2e43  version 0.32 (build 0.32.7)
engine v0327 vctest   ok    <repo>\engines\v0327\vctest.exe
engine v0327 f2f      ok    <repo>\builds\0327\VoxelCoreF2F-0327-767234c5.exe  sha 4ce9fde367dd  keys f2f,f2f-clock,...
total: 15 ok, 0 warn, 0 FAIL, 2 info        (+1 ok, если стоит MSYS2; daemon :25700 — ok «free»)
```
Без `--probe` движок не запускается (сток — `--version` без окна; F2F — по образу exe и последнему
`hello` из данных демона); `--probe` — аренда `vc engine` на демоне `P` для каждой версии (тестовая сборка, `--f2f`, hidden).

## machine-toml
Нет `machine.toml` или обязательного ключа. `install/bootstrap.ps1` создаёт его из `machine.toml.example` (корни внутри
репозитория: `engines_root = <repo>\engines`, `builds_root = <repo>\builds`, `work_root = <repo>\work`, найденный
`python_win`); существующий файл он не трогает. Вручную — `cp machine.toml.example machine.toml` и
поправить корни. Строки — в одинарных кавычках (литералы TOML, `\` без экранирования).

## roots
Каталог не существует. `work_root` демон создаст сам (warn); остальные — создать/исправить путь (или перезапустить bootstrap).

## self-contained
Репозиторий самодостаточен (волна 7): ни symlink'ов, ни путей к другим установкам. Паки — `{repo_root}\packs` (подстановки
`{repo_root}` = `{repo}`, `{packs}`; действие `prepare` `packs` по умолчанию берёт их оттуда), проекты — `{project_dir}`,
их данные — `{project_dir}\external\`, движки — `{engine.*}` (реестр + корни `machine.toml`). MCP `vc_start` (вид `vc dev`)
работает в `<work_root>\vc_dev`, паки — `--param packs=a,b` (junction из `packs\`); стоковый `vc runtime` — в
`<work_root>\vc_runtime`. Старый ключ `machine.toml` для моста к рабочему каталогу больше не читается (`unknown keys`,
`info`). Проверка — `tests/test_self_contained.py`.

## legacy
Версия реестра с `legacy = true` (`v031`, `v032`: сток — CI-артефакт без публичной ссылки, exe F2F не опубликован)
нужна только снимку машины-источника (на ней — копии в `engines\v031`, `engines\v032`). Нет файлов — `info`, есть — проверяется как обычно, но замечания тоже `info`.
Нужна на другом ПК — архив даёт пользователь, путь — `[engines.<id>] root = '...'`, `f2f = '...'` в machine.toml.

## links
Symlink'и и битые ссылки в `engines/` и `builds/` — `warn`: репозиторий не должен ссылаться наружу (на другом ПК таких
путей нет, Windows-Python WSL-ссылки не видит). Нужное — копировать (легаси-стоки `engines\v031`, `engines\v032` — копии).

## engine-stock
Нет стокового релиза версии: `install/bootstrap.ps1` скачивает `release_url` из реестра, сверяет `zip_sha256`,
распаковывает в `{engines_root}\<install_dir>` (`v0327` -> `<repo>\engines\v0327`), сверяет `stock_sha256` и пишет
`ORIGIN.txt`. Сток уже есть в другом месте — `[engines.<id>] root = '...'` в machine.toml. `sha ... (registry ...)` — другой
файл, чем записан в реестре: выяснить, откуда он (перекачать). `--version failed` — exe битый или блокируется антивирусом.

## engine-f2f
Нет тестовой сборки: bootstrap качает её из GitHub Release этого репозитория (`f2f_release` реестра, для `v0327` —
`gh release download f2f-v0327-767234c5 --repo lookibed/voxelcore-everything-ai-can`, нужен `gh auth login` с доступом к
приватному репозиторию) в `{builds_root}\<f2f_exe>` и сверяет `f2f_sha256`; иначе — собрать (`f2f/README.md`) или указать
`[engines.<id>] f2f = '...'`. `not an F2F build` — в образе нет ключа `--f2f`.
`hello.version != f2f_version` — сборка другой версии: аренды будут убиты (`engine-mismatch`).

## python
Нужен Windows-Python 3.13 (bootstrap ищет `-Python`, `py -3.13`, `C:\Python313`, `%LOCALAPPDATA%\Programs\Python\Python313`;
нет — `winget install Python.Python.3.13`; ядро работает и на 3.11+) с `pywin32 psutil fastapi uvicorn numpy Pillow jinja2` (+ `pytest` для тестов):
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
