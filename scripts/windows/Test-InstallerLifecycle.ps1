#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$SetupExe,
    [Parameter(Mandatory)][string]$SetupSha256,
    [Parameter(Mandatory)][string]$UpgradeExe,
    [Parameter(Mandatory)][string]$UpgradeSha256
)
$ErrorActionPreference='Stop'
# Run on an isolated, interactive Windows VM with an existing E: volume.
if ($env:JAIN_DISPOSABLE_WINDOWS_VM -ne '1' -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {throw 'A disposable VM with an interactive elevated desktop is required.'}
$root='E:\JainMatrimonialAdmin'
$data='E:\JainMatrimonialStorage'
$registry='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
function Product { Get-ChildItem $registry | Get-ItemProperty | Where-Object {$_.DisplayName -eq 'Jain Matrimonial Admin'} }
if ((Test-Path $root) -or (Test-Path $data) -or (Get-Service JainStorageServer,cloudflared -ErrorAction SilentlyContinue) -or (Product)) {throw 'A fresh VM without a storage or Admin installation is required.'}
if ($SetupSha256 -eq $UpgradeSha256) {throw 'Supply separate reviewed releases to exercise upgrade.'}
foreach ($item in @(@($SetupExe,$SetupSha256),@($UpgradeExe,$UpgradeSha256))) {
    if ($item[1] -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $item[0]).Hash -ne $item[1]) {throw 'Installer checksum mismatch.'}
}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
function RunSetup([string]$file) {
    $p=Start-Process -FilePath (Resolve-Path -LiteralPath $file).Path -WindowStyle Normal -PassThru
    try {
        $deadline=[DateTime]::UtcNow.AddMinutes(4)
        $confirm=0
        while (!$p.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            $windows=[Windows.Automation.AutomationElement]::RootElement.FindAll(
                [Windows.Automation.TreeScope]::Children,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$p.Id))
            foreach ($window in $windows) {
                $msg=$window.FindAll([Windows.Automation.TreeScope]::Descendants,
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Text))
                $text=($msg | ForEach-Object {$_.Current.Name}) -join ' '
                if (($confirm -eq 0 -and $text -like '*Install or repair Jain Matrimonial Admin*') -or ($confirm -eq 1 -and $text -like '*Installation complete*')) {
                    $button=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,
                        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'1'))
                    if ($button) { $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();$confirm++ }
                }
            }
            Start-Sleep -Milliseconds 300
        }
        if (!$p.HasExited -or $p.ExitCode -ne 0 -or $confirm -ne 2) {throw 'GUI setup did not confirm both expected dialogs.'}
    } finally { if (!$p.HasExited) {Stop-Process -InputObject $p} }
}
RunSetup $SetupExe
$first=@(Product)
if ($first.Count -ne 1 -or !(Test-Path "$root\Runtime\jain_admin.exe") -or !(Test-Path "$root\StorageServer\JainStorageServer.exe") -or (Get-Service JainStorageServer -ErrorAction SilentlyContinue)) {throw 'Standard installation mismatch.'}
$setting=(Get-FileHash "$root\Config\admin.json").Hash
New-Item -ItemType Directory -Path $data | Out-Null
$canary=Join-Path $data ('qa-'+[guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($canary,'disposable acceptance fixture')
$canaryHash=(Get-FileHash $canary).Hash
RunSetup $SetupExe
if ((Get-FileHash "$root\Config\admin.json").Hash -ne $setting) {throw 'Repair changed the configuration.'}
RunSetup $UpgradeExe
$second=@(Product)
if ($second.Count -ne 1 -or $second[0].PSChildName -eq $first[0].PSChildName) {throw 'Major upgrade did not replace the test product.'}
if ((Get-FileHash $canary).Hash -ne $canaryHash -or (Get-FileHash "$root\Config\admin.json").Hash -ne $setting) {throw 'Upgrade changed stored data or configuration.'}
$id=$second[0].PSChildName
if ($id -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {throw 'Unexpected Windows Installer product code.'}
$p=Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'msiexec.exe') -ArgumentList @('/x',$id,'/qn','REBOOT=ReallySuppress') -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -ne 0 -or (Product) -or (Test-Path "$root\Runtime\jain_admin.exe") -or (Get-FileHash $canary).Hash -ne $canaryHash -or (Get-FileHash "$root\Config\admin.json").Hash -ne $setting) {throw 'Safe uninstall acceptance failed.'}
'PASS. Standard GUI install, repair, major upgrade, retained configuration and safe uninstall.'

