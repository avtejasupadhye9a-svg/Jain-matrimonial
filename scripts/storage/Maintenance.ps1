#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory,Position=0)][ValidateSet('Status','Backup','Restore','Migrate','Uninstall')][string]$Action,
      [string]$BackupPath, [string]$ManifestSHA256)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PrivatePaths.ps1')
Invoke-StorageMaintenance {
    $service = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($Action -eq 'Status') {
        if ($service) { $service | Select-Object Name,Status,StartType }
        $designation = Join-Path $StateRoot 'designation.json'
        if (Test-Path $designation) { 'Origin ID: ' + ((Get-Content $designation -Raw | ConvertFrom-Json).origin) }
        return
    }
    if ($Action -in 'Backup','Restore','Migrate') {
        if (!$BackupPath) { throw 'Supply -BackupPath on a private encrypted NTFS volume.' }
        $BackupPath = [IO.Path]::GetFullPath($BackupPath).TrimEnd('\')
        Assert-PlainPath $BackupPath
        foreach ($dir in $DataRoot,$InstallRoot,$StateRoot) {
            if (($BackupPath + '\').StartsWith($dir + '\','OrdinalIgnoreCase') -or ($dir + '\').StartsWith($BackupPath + '\','OrdinalIgnoreCase')) { throw 'Use a separate backup directory.' }
        }
    }
    $wasRunning = $service -and $service.Status -eq 'Running'
    if ($service) { Stop-Service $ServiceName; (Get-Service $ServiceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45)) }
    $retiring = $false
    try {
        if ($Action -in 'Backup','Migrate') {
            if (Test-Path -LiteralPath $BackupPath) { throw 'Use a fresh backup directory.' }
            Protect-Directory $BackupPath
            Backup-Objects $DataRoot $BackupPath
        }
        if ($Action -eq 'Restore') {
            Protect-Directory $DataRoot
            Restore-Objects $DataRoot $BackupPath $ManifestSHA256
        }
        if ($Action -in 'Migrate','Uninstall') {
            $retiring = $true
            if ($service) {
                Set-Service $ServiceName -StartupType Disabled
                & sc.exe delete $ServiceName | Out-Null
                if ($LASTEXITCODE) { throw 'Could not retire service.' }
            }
            foreach ($name in 'origin.dpapi','designation.json') {
                $file = Join-Path $StateRoot $name
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
            }
            'Local enrollment retired. Permanent files and logs retained.'
        }
    } finally {
        if ($wasRunning -and !$retiring) { Start-Service $ServiceName }
    }
}
