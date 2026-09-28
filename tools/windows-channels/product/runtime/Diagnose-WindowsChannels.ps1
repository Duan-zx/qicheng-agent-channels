[CmdletBinding()]
param([string]$ConfigPath, [string]$PythonPath, [string]$InstallRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $PSScriptRoot }
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
            if ($match.Count -eq 1) {
                $running = ([string]$match[0].State -eq 'Running')
                Add-Check "vm-running:$name" $running $(if ($running) { 'Running' } else { "当前为 $($match[0].State)；频道不可连接" })
                if ($running -and $python) {
                    $state = $null
                    try {
                        Push-Location -LiteralPath $installRoot
                        try {
                            $stateText = & $python -B -m host.client --config $config.Path --project $name state 2>$null | Out-String
                            if ($LASTEXITCODE -eq 0) { $state = $stateText | ConvertFrom-Json -ErrorAction Stop }
                        } finally { Pop-Location }
                    } catch { $state = $null }
                    $connected = ($null -ne $state -and $state.ok -eq $true -and $state.result.input_target -eq 'private-windows-guest' -and $state.result.host_input_supported -eq $false)
                    Add-Check "guest-connected:$name" $connected $(if ($connected) { '客体身份和隔离输入目标已验证' } else { '客体代理无响应或身份校验失败' })
                    if ($connected) {
                        Add-Check "desktop-ready:$name" ($state.result.desktop_ready -eq $true) $(if ($state.result.desktop_ready -eq $true) { '交互桌面可用' } else { "交互桌面不可用：$($state.result.desktop_status)" })
                    }
                }
            }
        }
    } catch { Add-Check 'vm-inventory' $false $_.Exception.Message }
}
$checkArray = $checks.ToArray()
$failed = @($checkArray | Where-Object { -not $_.ok }).Count
[ordered]@{ schemaVersion=1; readOnly=$true; checkedAt=(Get-Date).ToUniversalTime().ToString('o'); passed=($failed -eq 0); failedChecks=$failed; checks=$checkArray } | ConvertTo-Json -Depth 6
if ($failed -gt 0) { exit 1 }
