param([string]$Email = 'admin@example.test')
$ErrorActionPreference = 'Stop'
if ($Email -notmatch '^[a-z0-9._+-]+@example\.test$') { throw 'Use a synthetic example.test identity' }
$secure = Read-Host 'Local fixture key' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    $headers = @{ 'X-Local-Fixture-Key' = $key }
    $payload = @{ email = $Email } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8787/_local/admin' -Headers $headers -ContentType 'application/json' -Body $payload
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    $key = $null
    $headers = $null
}
