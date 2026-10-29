# F2F relay for WSL (NAT networking: WSL cannot reach Windows 127.0.0.1, the firewall blocks the host IP).
# stdin line -> TCP 127.0.0.1:<Port> (Windows side) -> reply line -> stdout. First output line:
# "@@F2F connected" or "@@F2F error <message>". Used by f2f_client.py when it runs inside WSL.
param([int]$Port = 25570, [double]$ConnectTimeout = 0)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$deadline = (Get-Date).AddSeconds($ConnectTimeout)
$client = $null
while ($true) {
    try { $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port); break }
    catch {
        if ((Get-Date) -ge $deadline) { [Console]::Out.WriteLine("@@F2F error " + $_.Exception.InnerException.Message); [Console]::Out.Flush(); return }
        Start-Sleep -Milliseconds 250
    }
}
$client.NoDelay = $true
$stream = $client.GetStream()
$enc = New-Object System.Text.UTF8Encoding($false)
$reader = New-Object System.IO.StreamReader($stream, $enc)
$writer = New-Object System.IO.StreamWriter($stream, $enc)
$writer.AutoFlush = $true
[Console]::Out.WriteLine("@@F2F connected")
[Console]::Out.Flush()
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($line -eq $null) { break }
    $writer.WriteLine($line)
    $resp = $reader.ReadLine()
    if ($resp -eq $null) { break }
    [Console]::Out.WriteLine($resp)
    [Console]::Out.Flush()
}
$client.Close()
