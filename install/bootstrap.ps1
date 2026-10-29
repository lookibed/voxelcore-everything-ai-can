# bootstrap.ps1 — подготовка Windows-стороны машины «с нуля» (волна 7). Повторный запуск идемпотентен: готовое
# проверяется по sha256 и пропускается. Из WSL — install/bootstrap.sh (обёртка: gh из WSL, затем этот скрипт).
#
#   powershell -ExecutionPolicy Bypass -File install\bootstrap.ps1 [-Python C:\Python313\python.exe] [-Engine v0327]
#                                       [-ReleaseRepo lookibed/voxelcore-everything-ai-can] [-NoPip] [-NoDoctor]
#
# Шаги:
#  1. Python 3.13 для Windows (-Python, иначе py -3.13, C:\Python313, %LOCALAPPDATA%\Programs\Python\Python313) и модули
#     pywin32 psutil fastapi uvicorn numpy Pillow jinja2 pytest (pip — только если чего-то нет; -NoPip — не ставить).
#  2. gh (GitHub CLI, вошедший в аккаунт с доступом к релизам репозитория) — нужен для exe F2F из нашего релиза.
#  3. machine.toml — если его нет: из machine.toml.example, корни внутри репозитория (engines_root = <repo>\engines,
#     builds_root = <repo>\builds, work_root = <repo>\work), python_win — найденный, без vc_root. Есть — не трогается.
#  4. Сток версии по умолчанию (engines/registry.toml: release_url, zip_sha256) -> {engines_root}\<install_dir>,
#     сверка zip и VoxelCore.exe (stock_sha256), ORIGIN.txt. Версии с legacy = true не ставятся.
#  5. Тестовая сборка F2F: gh release download <f2f_release> (наш репозиторий) -> {builds_root}\<f2f_exe>, сверка f2f_sha256.
#  6. bin\lab.py doctor.
# Пути берутся из реестра через vclab.engines.resolve — та же раскладка, что у демона (перекрытия machine.toml учтены).
param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot),
    [string]$Python = "",
    [string]$Engine = "",
    [string]$ReleaseRepo = "lookibed/voxelcore-everything-ai-can",
    [switch]$NoPip,
    [switch]$NoDoctor
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Repo = (Resolve-Path $Repo).Path
$t0 = Get-Date
function Step($msg) { Write-Host ("[bootstrap {0,5:N1}s] {1}" -f ((Get-Date) - $t0).TotalSeconds, $msg) }
function Fail($msg) { Write-Host "bootstrap: FAIL: $msg" -ForegroundColor Red; exit 1 }
function Sha($path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }
function WriteUtf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }

function Download($url, $dst) {
    # интернет нестабильный: 5 попыток; curl.exe (Windows 10+) быстрее Invoke-WebRequest
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    for ($i = 1; $i -le 5; $i++) {
        try {
            if (Test-Path $curl) {
                $ErrorActionPreference = "Continue"
                & $curl -fsSL --retry 3 --connect-timeout 30 -o $dst $url
                $rc = $LASTEXITCODE; $ErrorActionPreference = "Stop"
                if ($rc -eq 0) { return }
                Write-Host "  curl exit $LASTEXITCODE (attempt $i)"
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dst; return
            }
        } catch { Write-Host "  download failed (attempt $i): $_" }
        Start-Sleep -Seconds (5 * $i)
    }
    Fail "cannot download $url"
}

# ------------------------------------------------------------------------------------------------ 1. Python
Step "repo $Repo"
$cands = @()
if ($Python) { $cands += $Python }
try { $p = & py -3.13 -c "import sys; print(sys.executable)" 2>$null; if ($LASTEXITCODE -eq 0 -and $p) { $cands += $p.Trim() } } catch {}
$cands += "C:\Python313\python.exe", (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe")
$py = $null
foreach ($c in $cands) {
    if ($c -and (Test-Path $c)) {
        $v = ""
        try { $v = & $c -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null } catch {}
        if ($LASTEXITCODE -eq 0 -and $v.Trim() -eq "3.13") { $py = (Resolve-Path $c).Path; break }
        Write-Host "  skip $c (Python $v, need 3.13)"
    }
}
if (-not $py) { Fail "Python 3.13 for Windows not found: winget install Python.Python.3.13 (or -Python <python.exe>)" }
Step "python $py"
$mods = "win32api,win32job,psutil,fastapi,uvicorn,numpy,PIL,jinja2,pytest"
$miss = & $py -c "import importlib.util as u; print(','.join(m for m in '$mods'.split(',') if u.find_spec(m) is None))"
if ($miss) {
    if ($NoPip) { Fail "python modules missing: $miss (run without -NoPip or pip install them)" }
    Step "pip install (missing: $miss)"
    $ErrorActionPreference = "Continue"
    & $py -m pip install --disable-pip-version-check pywin32 psutil fastapi uvicorn numpy Pillow jinja2 pytest
    $rc = $LASTEXITCODE; $ErrorActionPreference = "Stop"
    if ($rc -ne 0) { Fail "pip install failed" }
} else { Step "python modules ok" }

# ------------------------------------------------------------------------------------------------ 2. gh
$gh = (Get-Command gh -ErrorAction SilentlyContinue)
if ($gh) {
    $rc = 1
    try { $ErrorActionPreference = "Continue"; & $gh.Source auth status *> $null; $rc = $LASTEXITCODE } catch {} finally { $ErrorActionPreference = "Stop" }
    if ($rc -ne 0) { Write-Host "  gh is not logged in: gh auth login (needed for the F2F release download)" }
    Step "gh $($gh.Source)"
} else {
    Write-Host "  gh (GitHub CLI) not found: winget install GitHub.cli; gh auth login. From WSL install/bootstrap.sh uses WSL gh."
}

# ------------------------------------------------------------------------------------------------ 3. machine.toml
$machine = Join-Path $Repo "machine.toml"
if (Test-Path $machine) {
    Step "machine.toml exists, not changed: $machine"
} else {
    $text = [IO.File]::ReadAllText((Join-Path $Repo "machine.toml.example"))
    $set = @{
        engines_root = (Join-Path $Repo "engines"); builds_root = (Join-Path $Repo "builds");
        work_root = (Join-Path $Repo "work"); python_win = $py
    }
    foreach ($k in $set.Keys) {
        $text = [regex]::Replace($text, "(?m)^" + $k + "\s*=\s*'[^']*'", ("{0} = '{1}'" -f $k, $set[$k]).Replace('$', '$$'))
    }
    if (-not (Test-Path "C:\msys64\usr\bin\bash.exe")) {
        $text = [regex]::Replace($text, "(?m)^msys2(\s*=)", "# msys2`$1")          # нужен только для сборки F2F
    }
    $text = "# created by install/bootstrap.ps1 $(Get-Date -Format 'yyyy-MM-dd HH:mm') - roots inside the repository, no vc_root`r`n" + $text
    WriteUtf8 $machine $text
    Step "machine.toml created: $machine"
}
New-Item -ItemType Directory -Force -Path (Join-Path $Repo "work") | Out-Null

# ------------------------------------------------------------------------------------------------ 4–5. движок
$resolve = @'
import json, sys
sys.path.insert(0, sys.argv[1])
from vclab import engines, machine
reg = engines.load_registry()
res = engines.resolve(reg, machine.load())
eid = sys.argv[2] or res.get("default")
e = res.get(eid)
if not e:
    sys.exit("engine %r is not in engines/registry.toml" % eid)
print(json.dumps({"id": eid, "root": e["root"], "stock": e["stock"], "f2f": (e.get("builds") or {}).get("f2f", ""),
                  "release_url": e.get("release_url", ""), "zip_sha256": e.get("zip_sha256", ""),
                  "stock_sha256": e.get("stock_sha256", ""), "f2f_sha256": e.get("f2f_sha256", ""),
                  "f2f_release": e.get("f2f_release", ""), "legacy": bool(e.get("legacy")),
                  "version": e.get("version", "")}))
'@
$tmpPy = Join-Path $env:TEMP "vc_bootstrap_resolve.py"
WriteUtf8 $tmpPy $resolve
$json = & $py -X utf8 -B $tmpPy $Repo $Engine
if ($LASTEXITCODE -ne 0) { Fail "registry: $json" }
$e = $json | ConvertFrom-Json
Step "engine $($e.id) $($e.version): root $($e.root); f2f $($e.f2f)"
if ($e.legacy) { Fail "engine $($e.id) is legacy (CI artifact, not downloadable): pick a release engine (-Engine)" }

# 4. сток
if ((Test-Path $e.stock) -and ((Sha $e.stock) -eq $e.stock_sha256)) {
    Step "stock ok: $($e.stock) (sha $($e.stock_sha256.Substring(0,12)))"
} else {
    if (-not $e.release_url) { Fail "no release_url for $($e.id) in engines/registry.toml" }
    $dl = Join-Path $env:TEMP "vc_bootstrap"
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $zip = Join-Path $dl ([IO.Path]::GetFileName($e.release_url))
    if (-not ((Test-Path $zip) -and ((Sha $zip) -eq $e.zip_sha256))) {
        Step "download $($e.release_url)"
        Download $e.release_url $zip
    }
    $zs = Sha $zip
    if ($e.zip_sha256 -and $zs -ne $e.zip_sha256) { Remove-Item -Force $zip; Fail "zip sha256 $zs != registry $($e.zip_sha256)" }
    Step "zip sha256 ok ($($zs.Substring(0,12)))"
    $ex = Join-Path $dl ("x_" + $e.id)
    if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
    Expand-Archive -LiteralPath $zip -DestinationPath $ex
    $top = @(Get-ChildItem -LiteralPath $ex)
    $src = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $ex }   # zip с каталогом верхнего уровня
    New-Item -ItemType Directory -Force -Path $e.root | Out-Null
    Get-ChildItem -LiteralPath $src -Force | ForEach-Object { Copy-Item -Recurse -Force -LiteralPath $_.FullName -Destination $e.root }
    Remove-Item -Recurse -Force $ex
    if (-not (Test-Path $e.stock)) { Fail "no $($e.stock) after unpacking $zip" }
    $ss = Sha $e.stock
    if ($e.stock_sha256 -and $ss -ne $e.stock_sha256) { Fail "stock sha256 $ss != registry $($e.stock_sha256)" }
    WriteUtf8 (Join-Path $e.root "ORIGIN.txt") ("VoxelCore {0} win64 (stock), engine {1}`r`nsource: {2}`r`nsha256(zip): {3}`r`nsha256(VoxelCore.exe): {4}`r`ndownloaded: {5} by install/bootstrap.ps1`r`n" -f `
        $e.version, $e.id, $e.release_url, $zs, $ss, (Get-Date -Format "yyyy-MM-dd HH:mm"))
    Step "stock installed: $($e.stock) (sha $($ss.Substring(0,12)))"
}

# 5. тестовая сборка F2F
if ((Test-Path $e.f2f) -and ((Sha $e.f2f) -eq $e.f2f_sha256)) {
    Step "f2f ok: $($e.f2f) (sha $($e.f2f_sha256.Substring(0,12)))"
} else {
    if (-not $e.f2f_release) { Fail "no f2f_release for $($e.id): build it (f2f/README.md) or put the exe to $($e.f2f)" }
    if (-not $gh) { Fail "gh is required for the F2F release (or run install/bootstrap.sh from WSL, or download $($e.f2f_release) manually to $($e.f2f))" }
    $dir = Split-Path -Parent $e.f2f
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $name = Split-Path -Leaf $e.f2f
    $ok = $false
    for ($i = 1; $i -le 5 -and -not $ok; $i++) {
        Step "gh release download $($e.f2f_release) --repo $ReleaseRepo --pattern $name (attempt $i)"
        try {
            $ErrorActionPreference = "Continue"
            & $gh.Source release download $e.f2f_release --repo $ReleaseRepo --pattern $name --dir $dir --clobber
            $ok = ($LASTEXITCODE -eq 0)
        } catch { Write-Host "  $_" } finally { $ErrorActionPreference = "Stop" }
        if (-not $ok) { Start-Sleep -Seconds (5 * $i) }
    }
    if (-not $ok) { Fail "gh release download failed (gh auth status; access to $ReleaseRepo)" }
    $fs = Sha $e.f2f
    if ($fs -ne $e.f2f_sha256) { Fail "f2f sha256 $fs != registry $($e.f2f_sha256)" }
    Step "f2f installed: $($e.f2f) (sha $($fs.Substring(0,12)))"
}
Remove-Item -Force $tmpPy -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------------------------ 6. doctor
if ($NoDoctor) { Step "done (doctor skipped)"; exit 0 }
Step "lab doctor"
Push-Location C:\
$ErrorActionPreference = "Continue"
try { & $py -X utf8 -B (Join-Path $Repo "bin\lab.py") doctor; $rc = $LASTEXITCODE } finally { Pop-Location }
Step ("done, doctor exit {0}" -f $rc)
exit $rc
