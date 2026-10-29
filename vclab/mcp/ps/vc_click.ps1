param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    # координаты в пикселях скриншота vc_screenshot (прямоугольник окна, включая рамку)
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [string]$Button = "left",
    # 2 — двойной клик (второй через 90 мс; GUI движка считает двойным клик в пределах задержки)
    [int]$Count = 1
)

$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class VcClick {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
"@
[VcClick]::SetProcessDPIAware() | Out-Null
$hwnd = (Get-Process -Id $ProcessId).MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) { throw "process $ProcessId has no main window" }
[VcClick]::ShowWindow($hwnd, 9) | Out-Null
[VcClick]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 150
$r = New-Object VcClick+RECT
[VcClick]::GetWindowRect($hwnd, [ref]$r) | Out-Null
$sx = $r.Left + $X; $sy = $r.Top + $Y
[VcClick]::SetCursorPos($sx, $sy) | Out-Null
Start-Sleep -Milliseconds 80
$down, $up = 0x02, 0x04
if ($Button -eq "right") { $down, $up = 0x08, 0x10 }
for ($i = 0; $i -lt $Count; $i++) {
    if ($i -gt 0) { Start-Sleep -Milliseconds 90 }
    [VcClick]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [VcClick]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
}
Write-Output "clicked $Button x$Count at window ($X,$Y) = screen ($sx,$sy)"
