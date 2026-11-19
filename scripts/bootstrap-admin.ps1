#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Remote')][switch]$Remote,
    [Parameter(ParameterSetName = 'Local')][string]$PersistTo,
    [guid]$ExistingAdminId
)
$ErrorActionPreference = 'Stop'
$worker = Join-Path (Split-Path -Parent $PSScriptRoot) 'worker'
$wrangler = Join-Path $worker 'node_modules/.bin/wrangler.cmd'
[string[]]$target = @('--local')
if ($PersistTo) { $target += @('--persist-to', [IO.Path]::GetFullPath($PersistTo)) }
if (!$Remote -and !(Test-Path -LiteralPath $wrangler -PathType Leaf)) {
    throw 'Install the Worker dependencies first with npm ci.'
}

function Read-HiddenText([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        $secure.Dispose()
    }
}

function Invoke-MainQuery([string]$Sql, [string[]]$Parameters = @()) {
    if ($Remote) {
        try {
            $response = Invoke-RestMethod -Uri $endpoint -Method Post -Authentication Bearer -Token $d1Token `
                -ContentType 'application/json' -Body (@{ sql = $Sql; params = $Parameters } | ConvertTo-Json -Compress) `
                -MaximumRedirection 0 -TimeoutSec 20
            if (!$response.success) { throw 'D1 reported a query failure.' }
            $items = @($response.result)
        } catch {
            # Do not echo a provider exception or any credential-bearing request data.
            throw 'The production D1 request failed. Check the selected binding, migration and token permissions before retrying.'
        }
    } else {
        $output = & $wrangler d1 execute DB_MAIN @target --json --command $Sql 2>$null
        if ($LASTEXITCODE) { throw 'Could not inspect local DB_MAIN. Check the local migration.' }
        $items = @(($output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    if ($items.Count -ne 1 -or !$items[0].success) { throw 'D1 did not confirm the query.' }
    return $items[0].results
}

Push-Location $worker
try {
    if ($Remote) {
        $config = Get-Content -LiteralPath (Join-Path $worker 'wrangler.toml') -Raw
        $accountMatch = [regex]::Match($config, '(?m)^account_id\s*=\s*"([a-f0-9]{32})"\s*$')
        $bindings = @([regex]::Matches($config, '(?m)^\[\[d1_databases\]\][ \t]*(?:\r?\n)([^\[]*)') |
            Where-Object { $_.Groups[1].Value -match '(?m)^binding\s*=\s*"DB_MAIN"\s*$' })
        if (!$accountMatch.Success -or $bindings.Count -ne 1) { throw 'Could not uniquely identify production DB_MAIN in wrangler.toml.' }
        $database = [regex]::Match($bindings[0].Groups[1].Value, '(?m)^database_id\s*=\s*"([a-f0-9-]{36})"\s*$')
        if (!$database.Success) { throw 'Missing production DB_MAIN database ID.' }
        $databaseId = [guid]::ParseExact($database.Groups[1].Value, 'D').ToString()
        $endpoint = "https://api.cloudflare.com/client/v4/accounts/$($accountMatch.Groups[1].Value)/d1/database/$databaseId/query"
        $d1Token = Read-Host 'Cloudflare API token with D1 Write access to the configured account' -AsSecureString
        if (!$d1Token.Length) { throw 'A scoped Cloudflare API token is required.' }
    }
    if (Invoke-MainQuery 'SELECT account_id FROM jm_admin_credentials WHERE slot=1') {
        throw 'The Admin password is already set. Use the Admin app to change it.'
    }
    $historical = @(Invoke-MainQuery "SELECT id,status FROM jm_accounts WHERE role='admin' ORDER BY id")
    if ($PSBoundParameters.ContainsKey('ExistingAdminId')) {
        $account = $ExistingAdminId.ToString()
        if (!($historical | Where-Object { $_.id -eq $account -and $_.status -eq 'active' })) {
            throw 'The supplied ID is not an existing active administrator.'
        }
    } elseif ($historical.Count -eq 1 -and $historical[0].status -eq 'active') {
        $account = ([guid]$historical[0].id).ToString()
    } elseif ($historical.Count -eq 0) {
        $account = [guid]::NewGuid().ToString()
    } else {
        throw 'Review existing Admin rows before selecting an active account with -ExistingAdminId.'
    }
    if ($Remote -and (Read-Host "Provision the existing production DB_MAIN for Admin ID $account. Type SET UP PRODUCTION ADMIN after approval") -cne 'SET UP PRODUCTION ADMIN') {
        throw 'Production setup cancelled.'
    }

    $password = Read-HiddenText 'Initial password, at least 20 characters'
    $confirmation = Read-HiddenText 'Confirm initial password'
    if ($password -cne $confirmation) { throw 'The passwords do not match.' }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try { $passwordSize = $utf8.GetByteCount($password) }
    catch { throw 'Enter a valid Unicode password.' }
    if ([string]::IsNullOrWhiteSpace($password) -or $passwordSize -gt 256 -or
        [regex]::Matches($password, '[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\uD800-\uDFFF]').Count -lt 20 -or
        $password -match '[\u0000-\u001f\u007f]') {
        throw 'Use at least 20 characters and at most 256 UTF-8 bytes, without control characters.'
    }
    $pepper = Read-HiddenText 'Matching Worker ADMIN_PASSWORD_PEPPER (64 lowercase hex characters)'
    if ($pepper -cnotmatch '^[a-f0-9]{64}$') { throw 'Enter the 64-character lowercase hex Worker pepper.' }
    $passwordBytes = $utf8.GetBytes($password)
    $pepperBytes = [Convert]::FromHexString($pepper)
    $salt = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $material = [Security.Cryptography.HMACSHA256]::HashData($pepperBytes, $passwordBytes)
    $hash = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
        $material, $salt, 100000, [Security.Cryptography.HashAlgorithmName]::SHA256, 32)
    $verifier = 'pbkdf2-sha256-100k:v1:' + [Convert]::ToHexString($salt).ToLowerInvariant() + ':' +
        [Convert]::ToHexString($hash).ToLowerInvariant()

    if ($Remote) {
        $null = Invoke-MainQuery "INSERT INTO jm_admin_credentials(slot,account_id,verifier,version,changed_at) VALUES(1,?,?,1,strftime('%Y-%m-%dT%H:%M:%fZ','now'))" @($account,$verifier)
    } else {
        # Local Wrangler requires a file to keep the verifier out of process arguments.
        $sql = "INSERT INTO jm_admin_credentials(slot,account_id,verifier,version,changed_at) VALUES(1,'$account','$verifier',1,strftime('%Y-%m-%dT%H:%M:%fZ','now'));"
        $file = Join-Path ([IO.Path]::GetTempPath()) ("jain-admin-" + [guid]::NewGuid() + ".sql")
        $writer = [IO.FileStream]::new($file, [IO.FileMode]::CreateNew)
        try {
            $content = $utf8.GetBytes($sql)
            $writer.Write($content, 0, $content.Length)
        } finally { $writer.Dispose() }
        $null = & $wrangler d1 execute DB_MAIN @target --yes --json --file $file 2>$null
        if ($LASTEXITCODE) { throw 'Local D1 did not accept initial setup. Check its credential state before retrying.' }
    }
    $saved = Invoke-MainQuery 'SELECT account_id,version FROM jm_admin_credentials WHERE slot=1'
    if (!$saved -or $saved.account_id -ne $account -or $saved.version -ne 1) {
        throw 'D1 did not confirm the expected administrator setup.'
    }
    Write-Output 'The single administrator password is set.'
} finally {
    if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) { Remove-Item -LiteralPath $file }
    if ($d1Token) { $d1Token.Dispose() }
    foreach ($bytes in $passwordBytes, $pepperBytes, $material, $hash, $content) {
        if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    $password = $confirmation = $pepper = $verifier = $sql = $null
    Pop-Location
}
