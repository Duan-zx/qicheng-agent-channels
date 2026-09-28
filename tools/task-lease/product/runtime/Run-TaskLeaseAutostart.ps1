[CmdletBinding()]
param([string]$InstallRoot,[int]$Port=18770)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $InstallRoot) { $InstallRoot=(Get-TaskLeaseDefaults).InstallRoot }
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
$record=Get-TaskLeaseRecord $InstallRoot
if (-not $record) { throw 'Task Lease is not installed.' }
$dataRoot=Assert-TaskLeasePath $record.dataRoot 'DataRoot'
if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) { throw 'Task Lease private data directory is missing.' }
$log=Join-Path $dataRoot 'broker-autostart.log'
$start=Join-Path $InstallRoot 'product\runtime\Start-TaskLease.ps1'
# Keep one private log per attempt even when Task Scheduler has no operational log.
Set-Content -LiteralPath $log -Value ('Task Lease autostart at ' + [DateTime]::UtcNow.ToString('o') + ' UTC') -Encoding UTF8
try {
    & $start -InstallRoot $InstallRoot -Port $Port -Autostart
} catch {
    Add-Content -LiteralPath $log -Value ('Startup failed: ' + $_.Exception.ToString()) -Encoding UTF8
    throw
}
