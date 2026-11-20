#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$Fixture)
$ErrorActionPreference='Stop'
$name='JainStorageAcceptanceQA'
if(Get-Service $name -ErrorAction SilentlyContinue){throw 'Disposable test service already exists.'}
$root='E:\JainStorageQA-'+[guid]::NewGuid().ToString('N')
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)')
[IO.Directory]::CreateDirectory($root,$acl)|Out-Null
$created=$false
try {
    foreach($child in Get-ChildItem -LiteralPath $Fixture -Force){Copy-Item -LiteralPath $child.FullName -Destination $root -Recurse}
    $exe=Join-Path $root 'QaOrigin.exe'
    New-Service $name -BinaryPathName ('"'+$exe+'"') -StartupType Automatic | Out-Null
    $created=$true
    & sc.exe failure $name reset= 86400 actions= restart/2000/restart/4000/restart/10000 | Out-Null
    if($LASTEXITCODE){throw 'SCM recovery configuration failed.'}
    Start-Service $name
    $svc=Get-CimInstance Win32_Service -Filter "Name='JainStorageAcceptanceQA'"
    if($svc.State -ne 'Running' -or $svc.StartMode -ne 'Auto'){throw 'SCM startup failed.'}
    $port=[int](Get-Content -LiteralPath (Join-Path $root 'port.txt'))
    if($port -eq 8765){throw 'Unexpected production port.'}
    try {Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port/health" -TimeoutSec 3 | Out-Null;throw 'Authentication missing'}catch{if([int]$_.Exception.Response.StatusCode -ne 401){throw}}
    Stop-Process -Id $svc.ProcessId -Force
    $limit=[DateTime]::UtcNow.AddSeconds(55)
    do { Start-Sleep -Seconds 1;$next=Get-CimInstance Win32_Service -Filter "Name='JainStorageAcceptanceQA'" }
    until(($next.State -eq 'Running' -and $next.ProcessId -ne $svc.ProcessId)-or [DateTime]::UtcNow -gt $limit)
    if($next.State -ne 'Running' -or $next.ProcessId -eq $svc.ProcessId){throw 'SCM crash recovery failed.'}
    'PASS: automatic service registration, Defender readiness, authentication, crash restart and SCM status.'
} finally {
    if($created){Stop-Service $name -ErrorAction SilentlyContinue;& sc.exe delete $name | Out-Null}
    if(([IO.Path]::GetDirectoryName($root) -eq 'E:\') -and ([IO.Path]::GetFileName($root) -match '^JainStorageQA-[0-9a-f]{32}$')){
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

