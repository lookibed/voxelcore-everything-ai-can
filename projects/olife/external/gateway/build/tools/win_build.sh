#!/bin/sh
# Native Windows build (MSVC toolchain of the user, C:\Users\Andry\.cargo): sync sources to <repo>\projects\olife\external\gateway\build,
# cargo build --release there (target in build\target, jobs=4 from .cargo/config.toml), copy the exe to <repo>\projects\olife\external\gateway.
#   tools/win_build.sh [test]     (test: also cargo test --release on Windows)
set -e
SRC=<olife-src>/gateway
DST=<repo>/projects/olife/external/gateway/build
mkdir -p "$DST"
rsync -a --delete --exclude target --exclude .git --exclude dist "$SRC/" "$DST/"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
CMD="Set-Location '<repo>\\projects\\olife\\external\\gateway\\build'; \$env:CARGO_TERM_COLOR='never'; cargo build --release 2>&1 | Select-Object -Last 15"
[ "$1" = test ] && CMD="$CMD; cargo test --release 2>&1 | Select-String -Pattern 'test result|FAILED|panicked|running'"
"$PS" -NoProfile -Command "$CMD; exit \$LASTEXITCODE"
cp "$DST/target/release/olife-gateway.exe" <repo>/projects/olife/external/gateway/olife-gateway.exe
cp "$SRC/README.md" <repo>/projects/olife/external/gateway/README.md
ls -la <repo>/projects/olife/external/gateway/olife-gateway.exe
sha256sum <repo>/projects/olife/external/gateway/olife-gateway.exe
