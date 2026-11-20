[CmdletBinding()]
param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pythonPath = (Get-Command $Python).Source
$outputDir = [IO.Path]::GetFullPath($Output)
if (Test-Path $outputDir) { throw 'Build into a new empty destination.' }
if ([IO.Path]::GetPathRoot($outputDir) -ne 'E:\') { throw 'Build output must be on E:.' }
$cache = Join-Path $repo '.local/infra/tmp'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$env:TEMP=$cache
$env:TMP=$cache
$env:PYINSTALLER_CONFIG_DIR=Join-Path $repo '.local/infra/pyi'
$work = Join-Path $cache ('jain-storage-build-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work,$outputDir | Out-Null
& $pythonPath -m PyInstaller --onedir --noconsole --noupx --name JainStorageServer --paths $repo --hidden-import win32timezone --specpath $work --workpath (Join-Path $work 'obj') --distpath (Join-Path $work 'dist') (Join-Path $repo 'local_storage_service\windows_host.py')
if ($LASTEXITCODE) { throw 'Executable build failed.' }
Copy-Item -LiteralPath (Join-Path $work 'dist\JainStorageServer') -Destination (Join-Path $outputDir 'runtime') -Recurse
$licenses = New-Item -ItemType Directory -Path (Join-Path $outputDir 'licenses')
$base = & $pythonPath -c 'import sys; print(sys.base_prefix)'
$site = & $pythonPath -c "import sysconfig; print(sysconfig.get_path('purelib'))"
Copy-Item -LiteralPath (Join-Path $base 'LICENSE.txt') -Destination (Join-Path $licenses.FullName 'Python.txt')
Copy-Item -LiteralPath (Join-Path $site 'win32\license.txt') -Destination (Join-Path $licenses.FullName 'pywin32.txt')
Copy-Item -LiteralPath (Join-Path $site 'pyinstaller-6.16.0.dist-info\licenses\COPYING.txt') -Destination (Join-Path $licenses.FullName 'PyInstaller.txt')
$app = Start-Process -FilePath (Join-Path $outputDir 'runtime\JainStorageServer.exe') -ArgumentList '--self-test' -PassThru -Wait -WindowStyle Hidden
if ($app.ExitCode -ne 0) { throw 'Packaged DPAPI and HTTP smoke test failed.' }

