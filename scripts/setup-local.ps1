$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:WRANGLER_SEND_METRICS = 'false'
Push-Location (Join-Path $root 'worker')
try {
    npm.cmd ci
    if ($LASTEXITCODE) { throw 'Worker dependency installation failed' }
    npm.cmd run migrate:local
    if ($LASTEXITCODE) { throw 'Local D1 migrations failed' }
} finally { Pop-Location }
foreach ($app in 'customer_app','admin_app') {
    Push-Location (Join-Path $root $app)
    try {
        flutter pub get
        if ($LASTEXITCODE) { throw "Dependency installation failed for $app" }
    } finally { Pop-Location }
}
