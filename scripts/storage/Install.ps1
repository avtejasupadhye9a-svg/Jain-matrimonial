#Requires -RunAsAdministrator
[CmdletBinding()]
param([Security.SecureString]$OriginToken)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PrivatePaths.ps1')
Invoke-StorageMaintenance {
    if ($PSScriptRoot -ne $InstallRoot) { throw "Extract the complete package into $InstallRoot first." }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { throw 'Existing service found. Use Maintenance.ps1 Status.' }
    $exe = Join-Path $InstallRoot 'runtime\JainStorageServer.exe'
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Missing executable.' }
    if ((Get-Service WinDefend).Status -ne 'Running') { throw 'Microsoft Defender Antivirus must be running.' }
    if (Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue) { throw 'Port 8765 already in use. Retire the previous origin first.' }
    foreach ($dir in $InstallRoot,$StateRoot,$DataRoot) { Protect-Directory $dir }
    $blob = Join-Path $StateRoot 'origin.dpapi'
    $designation = Join-Path $StateRoot 'designation.json'
    if ((Test-Path $blob) -or (Test-Path $designation)) { throw 'Existing enrollment found. Check service state before explicitly retiring it.' }
    if (!$OriginToken) { $OriginToken = Read-Host 'Existing Worker storage origin token (hidden)' -AsSecureString }
    $sealed = Protect-OriginToken $OriginToken
    $origin = [guid]::NewGuid().ToString()
    $machine = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    $created = $false
    try {
        [IO.File]::WriteAllBytes($blob,$sealed)
        @{origin=$origin;machine=$machine} | ConvertTo-Json | Set-Content -LiteralPath $designation -Encoding UTF8
        New-Service -Name $ServiceName -DisplayName 'Jain Matrimonial Storage Server' -BinaryPathName ('"' + $exe + '"') -StartupType Automatic | Out-Null
        $created = $true
        & sc.exe failure $ServiceName reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Null
        if ($LASTEXITCODE) { throw 'Could not configure service recovery.' }
        & sc.exe failureflag $ServiceName 1 | Out-Null
        if ($LASTEXITCODE) { throw 'Could not enable service recovery.' }
        Start-Service $ServiceName
        (Get-Service $ServiceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(45))
        Write-Output "Service running. Worker STORAGE_ORIGIN_ID = $origin"
    } catch {
        if ($created) {
            Set-Service $ServiceName -StartupType Disabled
            Stop-Service $ServiceName -ErrorAction Stop
            & sc.exe delete $ServiceName | Out-Null
            if ($LASTEXITCODE) { throw 'Installer rollback incomplete. Inspect the service before retrying.' }
        }
        foreach ($file in $blob,$designation) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
        throw
    }
}
