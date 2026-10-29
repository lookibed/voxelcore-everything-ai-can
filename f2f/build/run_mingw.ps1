# Обёртка Windows для build_mingw.sh (MSYS2 CLANG64) — ручной путь; `lab f2f build <id>` делает то же из реестра и machine.toml.
# Пути — параметры (значения для машины: machine.toml msys2 / builds_root; версия: engines/<ver>/ORIGIN.md):
#   powershell -ExecutionPolicy Bypass -File f2f\build\run_mingw.ps1 -Step configure -Src /d/src/voxelcore-0327 `
#     -Vcpkg /d/vcpkg-0327 -BuildName 0.32.7 -LogDir D:\builds\logs [-Msys C:\msys64] [-Tag x]
param([string]$Step = "build", [Parameter(Mandatory=$true)][string]$Src, [Parameter(Mandatory=$true)][string]$Vcpkg,
      [string]$BuildName = "", [string]$RecipeNote = "vcpkg", [Parameter(Mandatory=$true)][string]$LogDir,
      [string]$Msys = "C:\msys64", [string]$Tag = "")
$env:MSYSTEM = "CLANG64"
$env:CHERE_INVOKING = "1"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$log = Join-Path $LogDir "mingw_$Step$Tag.log"
$script = (Join-Path $PSScriptRoot "build_mingw.sh") -replace '^([A-Za-z]):', { "/" + $_.Groups[1].Value.ToLower() } -replace '\\', '/'
"START $(Get-Date)" | Out-File $log -Encoding utf8
& "$Msys\usr\bin\bash.exe" -lc "SRC='$Src' VCPKG_ROOT='$Vcpkg' BUILD_NAME='$BuildName' RECIPE_NOTE='$RecipeNote' bash '$script' $Step" *>&1 | Out-File $log -Append -Encoding utf8
"END $(Get-Date)" | Out-File $log -Append -Encoding utf8
