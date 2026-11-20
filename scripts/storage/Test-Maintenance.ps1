[CmdletBinding()]
param([Parameter(Mandatory)][string]$Scratch)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PrivatePaths.ps1')
if (Test-Path -LiteralPath $Scratch) { throw 'Use a new scratch directory.' }
$source = Join-Path $Scratch 'source'
$backup = Join-Path $Scratch 'backup'
$restore = Join-Path $Scratch 'restore'
New-Item -ItemType Directory -Path $source,$backup,$restore | Out-Null
$id = [guid]::NewGuid().ToString()
[IO.File]::WriteAllText((Join-Path $source $id),'synthetic backup data')
Backup-Objects $source $backup | Out-Null
$hash = (Get-FileHash (Join-Path $backup 'manifest.json')).Hash
Restore-Objects $restore $backup $hash
Restore-Objects $restore $backup $hash
if ((Get-FileHash (Join-Path $restore $id)).Hash -ne (Get-FileHash (Join-Path $source $id)).Hash) { throw 'Restore mismatch.' }
[IO.File]::WriteAllText((Join-Path $restore $id),'existing unrelated bytes')
$blocked = $false
try { Restore-Objects $restore $backup $hash } catch { $blocked = $true }
if (!$blocked -or [IO.File]::ReadAllText((Join-Path $restore $id)) -ne 'existing unrelated bytes') { throw 'Conflict was overwritten.' }
$blocked = $false
try { Restore-Objects $restore $backup ('0' * 64) } catch { $blocked = $true }
if (!$blocked) { throw 'Bad manifest accepted.' }
$raw = New-Object byte[] 48
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($raw) } finally { $rng.Dispose() }
$fixture = ConvertTo-SecureString ([Convert]::ToBase64String($raw)) -AsPlainText -Force
try {
    $ciphertext = Protect-OriginToken $fixture
    $clear = [Security.Cryptography.ProtectedData]::Unprotect($ciphertext,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    if ([Text.Encoding]::ASCII.GetString($clear) -cne [Convert]::ToBase64String($raw)) { throw 'DPAPI provisioning mismatch.' }
} finally { $fixture.Dispose() }
'Backup, restore, conflict refusal, manifest verification and installer DPAPI provisioning passed.'

