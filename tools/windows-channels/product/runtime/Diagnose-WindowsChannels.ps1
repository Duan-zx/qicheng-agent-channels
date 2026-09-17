[CmdletBinding()]
param([string]$ConfigPath, [string]$PythonPath, [string]$InstallRoot = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$installRoot = Resolve-QichengLocalPath -Path $InstallRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
$dataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $dataRoot 'channels.json' }
$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) { $checks.Add([ordered]@{ name=$Name; ok=$Ok; detail=$Detail }) }

Add-Check 'windows' ($env:OS -eq 'Windows_NT') ([Environment]::OSVersion.VersionString)
$viewer = Join-Path $installRoot 'viewer\dist\WindowsChannelsViewer.exe'
Add-Check 'viewer' (Test-Path -LiteralPath $viewer -PathType Leaf) $viewer
try { $python = Resolve-QichengPython -PythonPath $(if(-not [string]::IsNullOrWhiteSpace($PythonPath)){$PythonPath}elseif($record -and $record.pythonPath){[string]$record.pythonPath}else{$null}); Add-Check 'python' $true $python } catch { $python=$null; Add-Check 'python' $false $_.Exception.Message }
try {
    $config = Read-QichengConfig -ConfigPath $ConfigPath
    Add-Check 'config' $true $config.Path
    foreach ($name in $config.ProjectNames) {
        $binding = $config.Value.projects.$name
        $token = if ($binding.token_file -and -not [System.IO.Path]::IsPathRooted([string]$binding.token_file)) { Join-Path (Split-Path -Parent $config.Path) ([string]$binding.token_file) } else { [string]$binding.token_file }
        $tokenOk = -not [string]::IsNullOrWhiteSpace($token) -and (Test-Path -LiteralPath $token -PathType Leaf)
        Add-Check "token:$name" $tokenOk $(if ($tokenOk) { 'present (content not displayed)' } else { 'missing or unsafe token_file' })
    }
} catch { $config=$null; Add-Check 'config' $false $_.Exception.Message }
$getVm = Get-Command Get-VM -ErrorAction SilentlyContinue
Add-Check 'hyperv-cmdlet' ([bool]$getVm) $(if ($getVm) { $getVm.Source } else { 'Get-VM unavailable' })
try { $service = Get-Service vmms -ErrorAction Stop; Add-Check 'hyperv-service' ($service.Status -eq 'Running') $service.Status.ToString() } catch { Add-Check 'hyperv-service' $false $_.Exception.Message }
if ($getVm -and $config) {
    try {
        $inventory = @(Get-VM -ErrorAction Stop)
        foreach ($name in $config.ProjectNames) {
            $binding = $config.Value.projects.$name
            $match = @($inventory | Where-Object { $_.Id.ToString() -ieq [string]$binding.vm_id })
            Add-Check "vm:$name" ($match.Count -eq 1) $(if ($match.Count -eq 1) { "$($match[0].Name) / $($match[0].State)" } else { 'exact configured VM ID not found' })
        }
    } catch { Add-Check 'vm-inventory' $false $_.Exception.Message }
}
$checkArray = $checks.ToArray()
$failed = @($checkArray | Where-Object { -not $_.ok }).Count
[ordered]@{ schemaVersion=1; readOnly=$true; checkedAt=(Get-Date).ToUniversalTime().ToString('o'); passed=($failed -eq 0); failedChecks=$failed; checks=$checkArray } | ConvertTo-Json -Depth 6
if ($failed -gt 0) { exit 1 }
