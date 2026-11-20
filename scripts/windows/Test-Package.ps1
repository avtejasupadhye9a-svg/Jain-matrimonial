param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$ReleaseExe
)
$ErrorActionPreference = 'Stop'
$build = (Resolve-Path -LiteralPath $PackageDirectory).Path
$exe = (Resolve-Path -LiteralPath $ReleaseExe).Path
function Digest($path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
$assembly = [Reflection.Assembly]::LoadFile($exe)
$stream = $assembly.GetManifestResourceStream('admin.msi')
if (!$stream) { throw 'Embedded MSI is missing' }
try {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $embedded = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') } finally { $hash.Dispose() }
} finally { $stream.Dispose() }
if ($embedded -ne (Digest (Join-Path $build 'admin.msi'))) { throw 'Embedded MSI differs from build output' }
$checksum = (Get-Content (Join-Path (Split-Path -Parent $exe) 'SHA256SUMS.txt') -Raw).Split(' ')[0]
if ((Digest $exe) -ne $checksum) { throw 'Release checksum mismatch' }
$preflight = $assembly.GetType('Setup').GetMethod('RequireVolume', [Reflection.BindingFlags]'NonPublic,Static')
$preflight.Invoke($null, @([IO.DriveType]::Fixed,'NTFS',[long](700MB)))
foreach ($invalid in @(
    @{type=[IO.DriveType]::Removable; format='NTFS'; free=1GB},
    @{type=[IO.DriveType]::Fixed; format='exFAT'; free=1GB},
    @{type=[IO.DriveType]::Fixed; format='NTFS'; free=128MB}
)) {
    $rejected=$false
    try { $preflight.Invoke($null,@($invalid.type,$invalid.format,[long]$invalid.free)) }
    catch { if ($_.Exception.GetBaseException() -isnot [IO.IOException]) { throw }; $rejected=$true }
    if (!$rejected) { throw 'Unsafe drive passed preflight' }
}
# Decompile with WiX dark.exe -x <build>\inspect <build>\admin.msi <build>\inspect.wxs first.
[xml]$wix = Get-Content (Join-Path $build 'product.wxs') -Raw
$files = @($wix.SelectNodes("//*[local-name()='File']"))
$extracted = Join-Path $build 'inspect\File'
if (@(Get-ChildItem -LiteralPath $extracted -File).Count -ne $files.Count) { throw 'Payload count differs' }
foreach ($file in $files) {
    if ((Digest $file.Source) -ne (Digest (Join-Path $extracted $file.Id))) {
        throw ('Payload mismatch for ' + $file.Name)
    }
}
if ((Digest (Join-Path $build 'JainMatrimonialAdmin.exe')) -ne (Digest (Join-Path $build 'inspect\Binary\Manager'))) { throw 'SCM action payload differs' }
[xml]$actual = Get-Content (Join-Path $build 'inspect.wxs') -Raw
if (@($actual.SelectNodes("//*[local-name()='Shortcut']")).Count -ne 2) { throw 'Expected desktop and Start shortcuts' }
foreach ($id in 'StopOrigin','RestartOrigin','RecoverOrigin','StopForRemoval','UnregisterOrigin') {
    if (!$actual.SelectSingleNode("//*[local-name()='Custom' and @Action='$id']")) { throw ('Missing service action ' + $id) }
}
Write-Output ("PASS. Embedded MSI, volume gates, shortcuts, service actions, release checksum and {0} extracted payload files verified." -f $files.Count)

