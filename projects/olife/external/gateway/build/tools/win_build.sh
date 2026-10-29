#!/bin/sh
# Native Windows build (MSVC toolchain of the user, C:\Users\Andry\.cargo): sync sources to D:\Prog\Olife\gateway\build,
# cargo build --release there (target in build\target, jobs=4 from .cargo/config.toml), copy the exe to D:\Prog\Olife\gateway.
#   tools/win_build.sh [test]     (test: also cargo test --release on Windows)
set -e
SRC=/root/olife/gateway
DST=/mnt/d/Prog/Olife/gateway/build
mkdir -p "$DST"
rsync -a --delete --exclude target --exclude .git --exclude dist "$SRC/" "$DST/"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
CMD="Set-Location 'D:\\Prog\\Olife\\gateway\\build'; \$env:CARGO_TERM_COLOR='never'; cargo build --release 2>&1 | Select-Object -Last 15"
[ "$1" = test ] && CMD="$CMD; cargo test --release 2>&1 | Select-String -Pattern 'test result|FAILED|panicked|running'"
"$PS" -NoProfile -Command "$CMD; exit \$LASTEXITCODE"
cp "$DST/target/release/olife-gateway.exe" /mnt/d/Prog/Olife/gateway/olife-gateway.exe
cp "$SRC/README.md" /mnt/d/Prog/Olife/gateway/README.md
ls -la /mnt/d/Prog/Olife/gateway/olife-gateway.exe
sha256sum /mnt/d/Prog/Olife/gateway/olife-gateway.exe
