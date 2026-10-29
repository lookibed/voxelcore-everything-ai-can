param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$OutPath
)

# Снимает окно VoxelCore в PNG. Сначала PrintWindow (работает, даже если окно
# перекрыто), при чёрном результате — копия области экрана под окном.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class VcWin {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
"@

[VcWin]::SetProcessDPIAware() | Out-Null

$proc = Get-Process -Id $ProcessId
$hwnd = $proc.MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) { throw "process $ProcessId has no main window" }
if ([VcWin]::IsIconic($hwnd)) { throw "window is minimized" }

$rect = New-Object VcWin+RECT
[VcWin]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) { throw "invalid window size ${width}x${height}" }

function Test-Black([System.Drawing.Bitmap]$bmp) {
    $stepX = [Math]::Max(1, [int]($bmp.Width / 16))
    $stepY = [Math]::Max(1, [int]($bmp.Height / 16))
    for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
        for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
            $c = $bmp.GetPixel($x, $y)
            if (($c.R + $c.G + $c.B) -gt 0) { return $false }
        }
    }
    return $true
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$method = "PrintWindow"
try {
    $hdc = $graphics.GetHdc()
    # 2 = PW_RENDERFULLCONTENT, нужен для OpenGL/DWM-окон
    $ok = [VcWin]::PrintWindow($hwnd, $hdc, 2)
    $graphics.ReleaseHdc($hdc)
    if (-not $ok -or (Test-Black $bitmap)) {
        $method = "CopyFromScreen"
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $width, $height))
    }
    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

Write-Output "$method ${width}x${height}"
