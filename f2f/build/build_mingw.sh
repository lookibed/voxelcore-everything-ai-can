#!/usr/bin/env bash
# Release recipe of VoxelCore (.github/workflows/windows-clang.yml), MSYS2 CLANG64 shell — общий для всех версий.
# Обычно вызывается из `lab f2f build <id>` (vclab/cli/f2fbuild.py: параметры из engines/registry.toml и machine.toml,
# лог, копия exe, сверка со стоком); вручную — из run_mingw.ps1 или CLANG64-shell (f2f/README.md):
#   SRC=/d/src/voxelcore-0327 VCPKG_ROOT=/d/vcpkg-0327 BUILD_NAME=0.32.7 RECIPE_NOTE="vcpkg a2f9862d (baseline 802d61d7)" \
#     build_mingw.sh configure|build
set -u
STEP=${1:-build}
: "${SRC:?SRC = worktree of the F2F branch (MSYS path, /d/...)}"
: "${VCPKG_ROOT:?VCPKG_ROOT = vcpkg checkout of the release commit (engines/<ver>/ORIGIN.md)}"
BUILD_NAME=${BUILD_NAME:-}              # 0.31/0.32.0 CI artifacts: ""; releases (0.32.7): the version
RECIPE_NOTE=${RECIPE_NOTE:-vcpkg}
export VCPKG_ROOT
export VCPKG_DEFAULT_TRIPLET=x64-mingw-static
export VCPKG_DEFAULT_HOST_TRIPLET=x64-mingw-static
export VCPKG_MAX_CONCURRENCY=${VCPKG_MAX_CONCURRENCY:-4}
export VCPKG_DISABLE_METRICS=1
B=$SRC/build-mingw
mkdir -p "$B"; cd "$B"
T0=$(date +%s)
# F2F build identity for `hello.build` (src/devtools/f2f_build_info.inc, git-ignored via
# .git/info/exclude); rewritten only when it changes, so it does not force a rebuild.
f2f_build_info() {
  local gd=""
  if [ -f "$SRC/.git" ]; then
    gd=$(sed -n 's/^gitdir: //p' "$SRC/.git")
    case "$gd" in /mnt/?/*) gd="${gd:5:1}:/${gd:7}";; esac   # worktree created from WSL
  fi
  local G="git -c safe.directory=* -c core.filemode=false -c core.autocrlf=input -C $SRC"
  [ -n "$gd" ] && G="git -c safe.directory=* -c core.filemode=false -c core.autocrlf=input --git-dir=$gd --work-tree=$SRC"
  local commit dirty
  commit=$($G rev-parse --short=10 HEAD 2>/dev/null) || return 0
  dirty=$($G status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
  [ "$dirty" = 0 ] && dirty="" || dirty="$dirty modified files"
  local f=$SRC/src/devtools/f2f_build_info.inc
  local new="#define F2F_BUILD_COMMIT \"$commit\"
#define F2F_BUILD_DIRTY \"$dirty\"
#define F2F_BUILD_RECIPE \"MSYS2 CLANG64, $RECIPE_NOTE x64-mingw-static, MinGW Makefiles, Release\""
  if [ ! -f "$f" ] || [ "$(cat "$f")" != "$new" ]; then printf '%s\n' "$new" > "$f"; fi
  echo "f2f_build_info: $commit ${dirty:-clean}"
}
f2f_build_info
if [ "$STEP" = configure ]; then
  cmake -G "MinGW Makefiles" -DVCPKG_TARGET_TRIPLET=x64-mingw-static -DVC_BUILD_NAME="$BUILD_NAME" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake ..
else
  cmake --build . --config Release -j4
fi
RC=$?
echo "EXIT $RC SECONDS $(( $(date +%s) - T0 ))"
