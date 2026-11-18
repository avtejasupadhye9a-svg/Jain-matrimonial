$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:WRANGLER_SEND_METRICS = 'false'
Push-Location (Join-Path $root 'worker')
try {
    foreach ($script in 'lint','test','build') {
        npm.cmd run $script
        if ($LASTEXITCODE) { throw "Worker check failed for $script" }
    }
} finally { Pop-Location }
Push-Location $root
try {
    python -m unittest local_storage_service.test_storage -v
    if ($LASTEXITCODE) { throw 'Local storage tests failed' }
} finally { Pop-Location }
foreach ($app in 'customer_app','admin_app') {
    Push-Location (Join-Path $root $app)
    try {
        flutter analyze
        if ($LASTEXITCODE) { throw "Static analysis failed for $app" }
        flutter test
        if ($LASTEXITCODE) { throw "Widget tests failed for $app" }
    } finally { Pop-Location }
}
