[CmdletBinding()]
param([string]$InstallRoot,[switch]$Apply)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $InstallRoot) { $InstallRoot=(Get-TaskLeaseDefaults).InstallRoot }
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
$record=Get-TaskLeaseRecord $InstallRoot
if (-not $record) { throw 'No Task Lease install record at InstallRoot.' }
$plan=[ordered]@{ installRoot=$InstallRoot; dataRoot=$record.dataRoot; preservesData=$true; applyRequested=[bool]$Apply; status='uninstall-plan' }
if (-not $Apply) { $plan | ConvertTo-Json; return }
Import-Module ScheduledTasks -ErrorAction Stop
$autostart=Get-ScheduledTask -TaskPath '\' -TaskName 'QichengTaskLease' -ErrorAction SilentlyContinue
if ($autostart -and $autostart.Description -ieq ('Qicheng Task Lease user logon broker: ' + $InstallRoot)) {
    throw 'Remove the QichengTaskLease scheduled task with Uninstall-TaskLeaseAutostart.ps1 before uninstalling.'
}
$running=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Join-Path $InstallRoot 'broker.py')) })
if ($running.Count) { throw 'Broker appears to be running from this install; stop it before uninstalling.' }
$null=Test-TaskLeasePackage $InstallRoot
Remove-Item -LiteralPath $InstallRoot -Recurse -Force
$plan.status='uninstalled'; $plan | ConvertTo-Json
