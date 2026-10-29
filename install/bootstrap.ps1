# bootstrap.ps1 — подготовка Windows-стороны машины «с нуля». КАРКАС ВОЛНЫ 1: НЕ ЗАПУСКАТЬ, шаги — TODO (волна 7).
# Порядок (каждый шаг идемпотентен, проверка — `bin/lab doctor`):
param([string]$Repo = (Split-Path -Parent $PSScriptRoot), [switch]$WhatIf = $true)
$ErrorActionPreference = "Stop"
Write-Host "bootstrap: repo $Repo (skeleton; nothing is executed in wave 1)"
# TODO 1. machine.toml: если нет — скопировать machine.toml.example и попросить пользователя поправить корни.
# TODO 2. Python 3.11+ для Windows (python_win): winget install Python.Python.3.13 или каталог пользователя; затем
#         & $python -m pip install pywin32 psutil fastapi uvicorn numpy Pillow jinja2 pytest   (НЕ venv на заполненном диске)
# TODO 3. Стоковые релизы из engines/registry.toml: для каждой версии с release_url — скачать zip в %TEMP%, сверить
#         zip_sha256, распаковать в {engines_root}\<install_dir>, сверить stock_sha256 (CI-артефакты v031/v032 — вручную).
# TODO 4. Тестовые сборки F2F: скачать готовые exe из приватного релиза lookibed/voxelcore-f2f (gh release download) в
#         {builds_root}\<f2f_exe> и сверить f2f_sha256; либо собрать (f2f/build, MSYS2 — шаг 5).
# TODO 5. (необязательно) MSYS2 CLANG64: msys2-base sfx -> {msys2}; f2f\build\msys_setup.ps1 -Msys {msys2} -LogDir ...
# TODO 6. Проверка: bin\lab.py doctor; bin\lab.py daemon start --isolated; lease vc engine --start; release; daemon stop.
