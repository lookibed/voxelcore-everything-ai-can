param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    # Последовательность через пробел: "enter", "up:1500" (удержание в мс), "wait:500",
    # "ctrl+z" (одновременное нажатие), "text:iddqd" (набор строки буквами).
    [Parameter(Mandatory = $true)][string]$Sequence,
    [int]$TapMs = 60
)

# Нажатия клавиш в окно VoxelCore. GLFW определяет клавишу по скан-коду,
# поэтому скан-код берётся из MapVirtualKey, а не оставляется нулём.

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class VcKeys {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@
# отдельный класс: в живом PowerShell (PSWorker) VcKeys уже определён, изменённое определение Add-Type не примет
if (-not ("VcWheel" -as [type])) {
    Add-Type 'using System; using System.Runtime.InteropServices; public static class VcWheel { [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra); }'
}

$named = @{
    "esc" = 0x1B; "escape" = 0x1B; "enter" = 0x0D; "tab" = 0x09; "space" = 0x20; "backspace" = 0x08;
    "left" = 0x25; "up" = 0x26; "right" = 0x27; "down" = 0x28;
    "ctrl" = 0xA2; "lctrl" = 0xA2; "rctrl" = 0xA3; "shift" = 0xA0; "lshift" = 0xA0; "rshift" = 0xA1;
    "alt" = 0xA4; "lalt" = 0xA4; "ralt" = 0xA5;
    "minus" = 0xBD; "equal" = 0xBB; "comma" = 0xBC; "period" = 0xBE; "grave" = 0xC0; "slash" = 0xBF;
    "home" = 0x24; "end" = 0x23; "pageup" = 0x21; "pagedown" = 0x22; "insert" = 0x2D; "delete" = 0x2E
}
# клавиши, которым нужен флаг KEYEVENTF_EXTENDEDKEY
$extended = @(0x25, 0x26, 0x27, 0x28, 0xA3, 0xA5, 0x24, 0x23, 0x21, 0x22, 0x2D, 0x2E)

function Get-Vk([string]$name) {
    $n = $name.ToLower()
    if ($named.ContainsKey($n)) { return [int]$named[$n] }
    if ($n -match '^f([0-9]{1,2})$') { return 0x6F + [int]$Matches[1] }
    if ($n.Length -eq 1 -and $n -match '[a-z0-9]') { return [int][char]$n.ToUpper() }
    throw "unknown key: $name"
}

function Send-Key([int]$vk, [bool]$down) {
    $scan = [byte][VcKeys]::MapVirtualKey([uint32]$vk, 0)
    $flags = 0
    if ($extended -contains $vk) { $flags = $flags -bor 1 }
    if (-not $down) { $flags = $flags -bor 2 }
    [VcKeys]::keybd_event([byte]$vk, $scan, [uint32]$flags, [UIntPtr]::Zero)
}

$proc = Get-Process -Id $ProcessId
$hwnd = $proc.MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) { throw "process $ProcessId has no main window" }

# вывести окно вперёд (с привязкой потока ввода, иначе Windows может не отдать фокус)
$foreground = [VcKeys]::GetForegroundWindow()
$fgThread = [VcKeys]::GetWindowThreadProcessId($foreground, [IntPtr]::Zero)
$myThread = [VcKeys]::GetCurrentThreadId()
[VcKeys]::AttachThreadInput($myThread, $fgThread, $true) | Out-Null
[VcKeys]::ShowWindow($hwnd, 9) | Out-Null
[VcKeys]::SetForegroundWindow($hwnd) | Out-Null
[VcKeys]::AttachThreadInput($myThread, $fgThread, $false) | Out-Null
Start-Sleep -Milliseconds 150

$done = @()
foreach ($token in ($Sequence -split '\s+' | Where-Object { $_ -ne '' })) {
    if ($token -match '^wait:(\d+)$') {
        Start-Sleep -Milliseconds ([int]$Matches[1])
        $done += $token
        continue
    }
    # колесо мыши над курсором: wheelup / wheeldown, wheelup:3 — три щелчка
    if ($token -match '^wheel(up|down)(?::(\d+))?$') {
        $n = 1
        if ($Matches[2]) { $n = [int]$Matches[2] }
        $delta = 120
        if ($Matches[1] -eq 'down') { $delta = -120 }
        for ($i = 0; $i -lt $n; $i++) { [VcWheel]::mouse_event(0x0800, 0, 0, $delta, [UIntPtr]::Zero); Start-Sleep -Milliseconds $TapMs }
        $done += $token
        continue
    }
    if ($token -match '^text:(.+)$') {
        foreach ($ch in $Matches[1].ToCharArray()) {
            $vk = Get-Vk ([string]$ch)
            Send-Key $vk $true; Start-Sleep -Milliseconds $TapMs; Send-Key $vk $false; Start-Sleep -Milliseconds $TapMs
        }
        $done += $token
        continue
    }
    $hold = $TapMs
    $keysPart = $token
    if ($token -match '^(.+):(\d+)$') { $keysPart = $Matches[1]; $hold = [int]$Matches[2] }
    $vks = @($keysPart -split '\+' | ForEach-Object { Get-Vk $_ })
    foreach ($vk in $vks) { Send-Key $vk $true }
    Start-Sleep -Milliseconds $hold
    [array]::Reverse($vks)
    foreach ($vk in $vks) { Send-Key $vk $false }
    Start-Sleep -Milliseconds $TapMs
    $done += $token
}
Write-Output ("sent: " + ($done -join ' '))
