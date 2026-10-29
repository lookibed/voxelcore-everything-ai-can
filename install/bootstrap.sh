#!/bin/sh
# bootstrap.sh — подготовка машины из WSL (волна 7): обёртка над install/bootstrap.ps1. Идемпотентна.
#   install/bootstrap.sh [--python 'C:\Python313\python.exe'] [--engine v0327] [--no-pip] [--no-doctor]
# 1. WSL: python3 >= 3.10 (MCP voxelcore), git core.autocrlf=input, gh (вошедший: релизы репозитория приватные).
# 2. Тестовая сборка F2F движка по умолчанию — `gh release download` из WSL (если её ещё нет или sha другой): на Windows
#    gh может не стоять; bootstrap.ps1 увидит готовый exe по sha256 и пропустит шаг.
# 3. Windows: powershell.exe -File install\bootstrap.ps1 — Python 3.13, machine.toml (корни в репозитории),
#    сток с GitHub Releases upstream (sha256 из реестра), lab doctor.
# Репозиторий должен лежать на диске Windows (/mnt/<диск>/...): демон и движок — Windows-процессы.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_WIN="$(wslpath -w "$ROOT")"
RELEASE_REPO="${RELEASE_REPO:-lookibed/voxelcore-everything-ai-can}"
PS_ARGS=""
ENGINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --python) PS_ARGS="$PS_ARGS -Python $2"; shift 2;;
    --engine) ENGINE="$2"; PS_ARGS="$PS_ARGS -Engine $2"; shift 2;;
    --no-pip) PS_ARGS="$PS_ARGS -NoPip"; shift;;
    --no-doctor) PS_ARGS="$PS_ARGS -NoDoctor"; shift;;
    *) echo "bootstrap.sh: unknown option $1" >&2; exit 2;;
  esac
done
case "$ROOT" in /mnt/[a-z]/*) ;; *) echo "bootstrap.sh: FAIL: $ROOT is not on a Windows drive (/mnt/<drive>/...): clone the repository there" >&2; exit 1;; esac
say() { echo "[bootstrap.sh] $*"; }

# 1. WSL-сторона
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
  say "python3 $(python3 -c 'import sys; print(sys.version.split()[0])') ok"
else
  say "python3 >= 3.10 is missing in WSL (MCP voxelcore): sudo apt install python3"
fi
[ "$(git -C "$ROOT" config core.autocrlf || true)" = "input" ] || { git -C "$ROOT" config core.autocrlf input; say "git core.autocrlf=input (repo)"; }
GH=""
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then GH=gh; say "gh $(gh --version | head -1 | cut -d' ' -f3) logged in"
  else say "gh auth status failed (not logged in or GitHub unreachable): gh auth login; bootstrap.ps1 will try Windows gh"; fi
else
  say "gh is missing in WSL (https://cli.github.com); bootstrap.ps1 will try Windows gh"
fi

# 2. F2F из релиза — пути из реестра (vclab.engines: та же раскладка, что у демона). Нужен machine.toml: если его нет,
#    сначала bootstrap.ps1 -NoDoctor создаст его (и поставит сток), потом докачаем F2F и запустим ещё раз.
PS="$(command -v powershell.exe || echo /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)"
RC_FILE="$(mktemp)"
trap 'rm -f "$RC_FILE"' EXIT
run_ps() {   # код выхода powershell.exe (вывод без \r)
  { (cd /mnt/c && "$PS" -NoProfile -ExecutionPolicy Bypass -File "$REPO_WIN\\install\\bootstrap.ps1" $PS_ARGS "$@"); echo $? > "$RC_FILE"; } | tr -d '\r'
  return "$(cat "$RC_FILE")"
}
f2f_info() {
  python3 - "$ROOT" "$ENGINE" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from vclab import engines, machine
from vclab.config import win_to_wsl
res = engines.resolve(engines.load_registry(), machine.load())
eid = sys.argv[2] or res.get("default")
e = res.get(eid) or {}
f2f = (e.get("builds") or {}).get("f2f") or ""
print(win_to_wsl(f2f) if f2f else "", e.get("f2f_sha256", ""), e.get("f2f_release", ""))
EOF
}
if [ ! -f "$ROOT/machine.toml" ]; then
  say "no machine.toml: bootstrap.ps1 creates it (stock first, F2F next)"
  case " $PS_ARGS " in *" -NoDoctor "*) run_ps ;; *) run_ps -NoDoctor ;; esac || true
  [ -f "$ROOT/machine.toml" ] || { echo "bootstrap.sh: FAIL: machine.toml was not created" >&2; exit 1; }
fi
set -- $(f2f_info)
F2F="${1:-}"; WANT="${2:-}"; TAG="${3:-}"
if [ -n "$F2F" ] && [ -f "$F2F" ] && [ "$(sha256sum "$F2F" | cut -d' ' -f1)" = "$WANT" ]; then
  say "f2f ok: $F2F"
elif [ -n "$GH" ] && [ -n "$TAG" ] && [ -n "$F2F" ]; then
  mkdir -p "$(dirname "$F2F")"
  i=1
  until gh release download "$TAG" --repo "$RELEASE_REPO" --pattern "$(basename "$F2F")" --dir "$(dirname "$F2F")" --clobber; do
    [ $i -ge 5 ] && { echo "bootstrap.sh: FAIL: gh release download $TAG" >&2; exit 1; }
    i=$((i + 1)); say "retry $i"; sleep $((i * 5))
  done
  GOT="$(sha256sum "$F2F" | cut -d' ' -f1)"
  [ "$GOT" = "$WANT" ] || { echo "bootstrap.sh: FAIL: f2f sha256 $GOT != registry $WANT" >&2; exit 1; }
  say "f2f downloaded: $F2F (sha ${GOT%"${GOT#????????????}"})"
fi

# 3. Windows-сторона (сток, проверки, doctor)
run_ps
