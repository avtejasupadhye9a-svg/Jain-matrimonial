$ServiceName = 'JainStorageServer'
$InstallRoot = 'E:\JainStorageServer'
$DataRoot = 'E:\JainMatrimonialStorage'
$StateRoot = Join-Path $env:ProgramData $ServiceName

function Assert-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\') { throw 'Use a local drive.' }
    for ($item = [IO.DirectoryInfo]::new($full); $null -ne $item; $item = $item.Parent) {
        if ((Test-Path -LiteralPath $item.FullName) -and ((Get-Item -Force -LiteralPath $item.FullName).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Reparse points are unsupported.'
        }
    }
}
function Assert-PlainTree([string]$Path) {
    Assert-PlainPath $Path
    foreach ($child in (Get-ChildItem -Force -LiteralPath $Path)) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected reparse point.' }
        if ($child.PSIsContainer) { Assert-PlainTree $child.FullName }
    }
}
function Protect-Directory([string]$Path) {
    Assert-PlainPath $Path
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
    if ($drive.DriveFormat -ne 'NTFS') { throw 'Private folders require NTFS.' }
    if (!(Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
    Assert-PlainTree $Path
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($admins)
    foreach ($sid in @($admins,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    foreach ($child in (Get-ChildItem -Force -LiteralPath $Path)) {
        & icacls.exe $child.FullName /reset /T /Q | Out-Null
        if ($LASTEXITCODE) { throw 'Could not restrict child access.' }
        & icacls.exe $child.FullName /setowner '*S-1-5-32-544' /T /Q | Out-Null
        if ($LASTEXITCODE) { throw 'Could not restrict child ownership.' }
    }
}


function Protect-OriginToken([Security.SecureString]$OriginToken) {
    Add-Type -AssemblyName System.Security
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($OriginToken)
    try {
        $chars = New-Object char[] $OriginToken.Length
        [Runtime.InteropServices.Marshal]::Copy($ptr,$chars,0,$chars.Length)
        if ($chars.Length -lt 32 -or $chars.Length -gt 512) { throw 'Invalid token length.' }
        foreach ($c in $chars) { if ([int]$c -lt 33 -or [int]$c -gt 126) { throw 'Token must contain printable ASCII.' } }
        $bytes = [Text.Encoding]::ASCII.GetBytes($chars)
        return ,([Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))
    } finally {
        if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
        if ($chars) { [Array]::Clear($chars,0,$chars.Length) }
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Backup-Objects([string]$DataRoot,[string]$BackupPath) {
    $uuid = '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
    Assert-PlainTree $DataRoot
    $records = @(foreach ($file in (Get-ChildItem -LiteralPath $DataRoot -Force)) {
        if ($file.PSIsContainer -or $file.Name -cnotmatch $uuid) { throw 'Unexpected storage entry. Investigate before migration.' }
        $copy = Join-Path $BackupPath $file.Name
        [IO.File]::Copy($file.FullName,$copy,$false)
        $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
        if ((Get-FileHash -LiteralPath $copy).Hash -ne $hash) { throw 'Backup checksum mismatch.' }
        @{id=$file.Name;sha256=$hash}
    })
    $manifest = Join-Path $BackupPath 'manifest.json'
    ConvertTo-Json -InputObject $records | Set-Content -LiteralPath $manifest -Encoding UTF8
    'Keep this manifest SHA-256 separately: ' + (Get-FileHash -LiteralPath $manifest).Hash
}
function Restore-Objects([string]$DataRoot,[string]$BackupPath,[string]$ManifestSHA256) {
    $uuid = '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
    Assert-PlainTree $BackupPath
    $manifest = Join-Path $BackupPath 'manifest.json'
    if ($ManifestSHA256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $manifest).Hash -ne $ManifestSHA256) { throw 'Supply the independently retained manifest hash.' }
    $items = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    foreach ($item in $items) {
        if ($item.id -cnotmatch $uuid -or $item.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid manifest entry.' }
        $source = Join-Path $BackupPath $item.id
        $dest = Join-Path $DataRoot $item.id
        if ((Get-FileHash -LiteralPath $source).Hash -ne $item.sha256) { throw 'Backup object failed verification.' }
        if (!(Test-Path -LiteralPath $dest)) {
            $temporary = Join-Path $DataRoot ([guid]::NewGuid().ToString() + '.restoring')
            try {
                [IO.File]::Copy($source,$temporary,$false)
                if ((Get-FileHash -LiteralPath $temporary).Hash -ne $item.sha256) { throw 'Restore verification failed.' }
                [IO.File]::Move($temporary,$dest)
            } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
        }
        if ((Get-FileHash -LiteralPath $dest).Hash -ne $item.sha256) { throw 'Existing permanent file differs. Restore stopped.' }
    }
}

function Invoke-StorageMaintenance([scriptblock]$Operation) {
    $lock = [Threading.Mutex]::new($false,'Global\JainStorageServerMaintenance')
    $held = $false
    try {
        try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (!$held) { throw 'Another storage maintenance operation is active.' }
        & $Operation
    } finally {
        if ($held) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
}
