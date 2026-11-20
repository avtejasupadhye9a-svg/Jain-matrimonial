#Requires -RunAsAdministrator
# Run ONLY in a disposable VM on a fresh drive with the package already extracted.
[CmdletBinding()]
param([Parameter(Mandatory)][switch]$DisposableVM)
$ErrorActionPreference = 'Stop'
if (!$DisposableVM) { throw 'Requires a disposable VM.' }
. (Join-Path $PSScriptRoot 'PrivatePaths.ps1')
if ((Get-Service $ServiceName,cloudflared -ErrorAction SilentlyContinue) -or
    (Test-Path $StateRoot) -or (Test-Path $DataRoot)) { throw 'Requires a fresh VM with no connector or storage data.' }
$bytes = New-Object byte[] 48
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$synthetic = [Convert]::ToBase64String($bytes)
$secret = ConvertTo-SecureString $synthetic -AsPlainText -Force
& (Join-Path $InstallRoot 'Install.ps1') -OriginToken $secret
$manage = Join-Path $InstallRoot 'Maintenance.ps1'
try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='JainStorageServer'"
    if ($svc.StartMode -ne 'Auto' -or $svc.State -ne 'Running') { throw 'Startup failed.' }
    $origin = (Get-Content (Join-Path $StateRoot 'designation.json') -Raw | ConvertFrom-Json).origin
    $headers = @{Authorization=('Bearer ' + $synthetic); 'X-Jain-Origin'=$origin}
    $base = 'http://127.0.0.1:8765'
    $health = Invoke-RestMethod "$base/health" -Headers $headers
    if ($health.status -ne 'ok') { throw 'DPAPI service authentication failed.' }
    $data = [Text.Encoding]::ASCII.GetBytes("%PDF-1.4 synthetic VM fixture")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($data)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $headers['X-Content-SHA256'] = $hash
    $id = [guid]::NewGuid().ToString()
    $stored = Invoke-RestMethod "$base/objects/$id" -Method Put -ContentType application/pdf -Headers $headers -Body $data
    if ($stored.sha256 -ne $hash) { throw 'Defender-scanned upload failed.' }
    Stop-Process -Id $svc.ProcessId -Force
    $limit = [DateTime]::UtcNow.AddSeconds(75)
    do {
        Start-Sleep -Seconds 2
        $current = Get-CimInstance Win32_Service -Filter "Name='JainStorageServer'"
    } until (($current.State -eq 'Running' -and $current.ProcessId -ne $svc.ProcessId) -or [DateTime]::UtcNow -ge $limit)
    if ($current.State -ne 'Running' -or $current.ProcessId -eq $svc.ProcessId) { throw 'SCM recovery failed.' }
    $backup = Join-Path $env:TEMP ('jain-storage-qa-' + [guid]::NewGuid())
    & $manage Migrate -BackupPath $backup
    if ((Test-Path (Join-Path $StateRoot 'origin.dpapi')) -or !(Test-Path (Join-Path $DataRoot $id))) { throw 'Migration did not preserve files or retire enrollment.' }
    # Move only the synthetic object on this disposable VM to exercise restoration.
    [IO.File]::Move((Join-Path $DataRoot $id),(Join-Path $backup 'original-qa-copy'))
    & $manage Restore -BackupPath $backup -ManifestSHA256 (Get-FileHash (Join-Path $backup 'manifest.json')).Hash
    if ((Get-FileHash (Join-Path $DataRoot $id)).Hash -ne $hash) { throw 'Restored bytes differ.' }
    'SCM startup, recovery, DPAPI, Defender upload, backup, retirement and restore passed.'
} finally {
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) { & $manage Uninstall }
    $secret.Dispose()
}

