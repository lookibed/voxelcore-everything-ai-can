#!/bin/sh
# bootstrap.sh — подготовка WSL-стороны. КАРКАС ВОЛНЫ 1: НЕ ЗАПУСКАТЬ, шаги — TODO (волна 7).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "bootstrap.sh: repo $ROOT (skeleton; nothing is executed in wave 1)"
# TODO 1. machine.toml: если нет — cp machine.toml.example machine.toml и поправить пути (python_win, корни).
# TODO 2. python3 (WSL) >= 3.10 для MCP voxelcore; tomli не нужен (vclab/machine.py разбирает простое подмножество TOML).
# TODO 3. .mcp.json: из install/mcp.json.example подставить python_win и путь репозитория (wslpath -w).
# TODO 4. gh auth status (приватные релизы F2F), git config core.autocrlf=input.
# TODO 5. Проверка: bin/lab doctor.
