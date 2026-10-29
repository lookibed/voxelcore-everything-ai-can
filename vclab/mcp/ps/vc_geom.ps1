param([Parameter(Mandatory = $true)][int]$ProcessId)

# Геометрия окна VoxelCore: прямоугольник окна (как у скриншота vc_screenshot) и клиентская
# область (куда рисует движок) в экранных координатах. Вывод: "wl wt wr wb cl ct cw ch".

$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class VcGeom {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
}
"@
[VcGeom]::SetProcessDPIAware() | Out-Null
$hwnd = (Get-Process -Id $ProcessId).MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) { throw "process $ProcessId has no main window" }
$w = New-Object VcGeom+RECT
$c = New-Object VcGeom+RECT
$p = New-Object VcGeom+POINT
[VcGeom]::GetWindowRect($hwnd, [ref]$w) | Out-Null
[VcGeom]::GetClientRect($hwnd, [ref]$c) | Out-Null
[VcGeom]::ClientToScreen($hwnd, [ref]$p) | Out-Null
Write-Output ("{0} {1} {2} {3} {4} {5} {6} {7}" -f $w.Left, $w.Top, $w.Right, $w.Bottom, $p.X, $p.Y, $c.Right, $c.Bottom)
