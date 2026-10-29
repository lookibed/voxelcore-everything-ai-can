param([string]$Exe, [string]$Dir, [string]$Script, [string]$Out, [Parameter(Mandatory=$true)][string]$Res)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$p = Start-Process -FilePath $Exe -ArgumentList "--headless","--res",$Res,"--dir",$Dir,"--script",$Script -PassThru -NoNewWindow -RedirectStandardOutput $Out -RedirectStandardError "$Out.err" -WorkingDirectory (Split-Path $Exe)
if (-not $p.WaitForExit(120000)) { $p.Kill(); "KILLED" }
"exit=$($p.ExitCode)"
