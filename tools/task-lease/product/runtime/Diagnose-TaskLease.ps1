[CmdletBinding()]
param([string]$InstallRoot,[int]$Port=18770)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $InstallRoot) { $InstallRoot=(Get-TaskLeaseDefaults).InstallRoot }
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
$record=Get-TaskLeaseRecord $InstallRoot
if (-not $record) { [pscustomobject]@{ installed=$false; ready=$false; reason='no install record' } | ConvertTo-Json; return }
$dataRoot=Assert-TaskLeasePath $record.dataRoot 'DataRoot'
$config=Join-Path $dataRoot 'config.json'
$credential=Join-Path $dataRoot 'broker.token'
$db=Join-Path $dataRoot 'leases.db'
$report=[ordered]@{ installed=$true; version=$record.version; installRoot=$InstallRoot; dataRoot=$dataRoot; pythonOk=$false; packageOk=$false; configPresent=(Test-Path -LiteralPath $config -PathType Leaf); credentialPresent=(Test-Path -LiteralPath $credential -PathType Leaf); databasePresent=(Test-Path -LiteralPath $db -PathType Leaf); serviceReachable=$false; serviceMatchesInstall=$false; ready=$false; detail=$null }
try { $null=Resolve-TaskLeasePython $record.python; $report.pythonOk=$true } catch { $report.detail=$_.Exception.Message }
try { $null=Test-TaskLeasePackage $InstallRoot; $report.packageOk=$true } catch { $report.detail=$_.Exception.Message }
if ($report.credentialPresent) {
    try {
        $token=(Get-Content -LiteralPath $credential -Raw -Encoding ASCII).Trim()
        $response=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/status" -Headers @{Authorization="Bearer $token"} -TimeoutSec 2
        $report.serviceReachable=($null -ne $response.channels)
    } catch { if (-not $report.detail) { $report.detail='Broker is not reachable or rejected the credential.' } }
}
if ($report.serviceReachable) {
    try {
        $listener=@(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $Port -State Listen -ErrorAction Stop)
        if ($listener.Count -ne 1) { throw 'Expected one loopback listener.' }
        $owner=Get-CimInstance Win32_Process -Filter ("ProcessId=" + $listener[0].OwningProcess) -ErrorAction Stop
        if (-not $owner -or -not $owner.ExecutablePath -or -not $owner.CommandLine) { throw 'Listener process details unavailable.' }
        $expectedScript=Join-Path $InstallRoot 'broker.py'
        $scriptPattern='(?:^|\s)"?' + [regex]::Escape($expectedScript) + '"?(?:\s|$)'
        $report.serviceMatchesInstall=([string]::Equals(
            [IO.Path]::GetFullPath($owner.ExecutablePath), [IO.Path]::GetFullPath($record.python),
            [StringComparison]::OrdinalIgnoreCase) -and
            $owner.CommandLine -match $scriptPattern)
        if (-not $report.serviceMatchesInstall) { $report.detail='Loopback Broker belongs to a different installation.' }
    } catch { $report.detail='Could not verify the loopback Broker process identity.' }
}
$report.ready=($report.pythonOk -and $report.packageOk -and $report.configPresent -and $report.credentialPresent -and $report.serviceReachable -and $report.serviceMatchesInstall)
$report | ConvertTo-Json
