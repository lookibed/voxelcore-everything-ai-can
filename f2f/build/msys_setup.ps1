# Тулчейн MSYS2 CLANG64 для сборки F2F (один раз на машину). Каркас волны 1 — НЕ ЗАПУСКАЛСЯ в этом репозитории.
# -Msys: корень MSYS2 (machine.toml msys2); -LogDir: куда писать лог.
param([string]$Msys = "C:\msys64", [Parameter(Mandatory=$true)][string]$LogDir)
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$log = Join-Path $LogDir "msys_setup.log"
$env:MSYSTEM = "CLANG64"
$env:CHERE_INVOKING = "1"
"START $(Get-Date)" | Out-File $log -Encoding utf8
for ($i = 1; $i -le 6; $i++) {
  "ATTEMPT $i $(Get-Date)" | Out-File $log -Append -Encoding utf8
  & "$Msys\usr\bin\bash.exe" -lc "pacman -S --noconfirm --needed --disable-download-timeout mingw-w64-clang-x86_64-toolchain mingw-w64-clang-x86_64-cmake git" *>&1 | Out-File $log -Append -Encoding utf8
  $code = $LASTEXITCODE
  "PACMAN EXIT $code $(Get-Date)" | Out-File $log -Append -Encoding utf8
  if ($code -eq 0) { break }
}
& "$Msys\usr\bin\bash.exe" -lc "clang --version; cmake --version; git --version; mingw32-make --version | head -1" *>&1 | Out-File $log -Append -Encoding utf8
"DONE $(Get-Date)" | Out-File $log -Append -Encoding utf8
