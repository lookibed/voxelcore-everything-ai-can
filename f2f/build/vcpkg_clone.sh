#!/usr/bin/env bash
# vcpkg для рецепта релиза: коммит master на шаге "Set up vcpkg" CI-задания релиза (engines/<ver>/ORIGIN.md).
# Каркас волны 1 — НЕ ЗАПУСКАЛСЯ. usage: D=/d/vcpkg-0327 COMMIT=a2f9862d... SINCE=2026-09-01 vcpkg_clone.sh
set -eu
: "${D:?target dir}"; : "${COMMIT:?vcpkg commit}"
SINCE=${SINCE:-}
T0=$(date +%s)
if [ -n "$SINCE" ]; then git clone --shallow-since="$SINCE" --no-tags https://github.com/microsoft/vcpkg.git "$D"
else git clone --no-tags https://github.com/microsoft/vcpkg.git "$D"; fi
cd "$D"
git checkout "$COMMIT"
cmd //c "bootstrap-vcpkg.bat -disableMetrics"
./vcpkg.exe version | head -1
echo "EXIT 0 SECONDS $(( $(date +%s) - T0 ))"
