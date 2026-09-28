[CmdletBinding()]
param([string]$InstallRoot,[int]$Port=18770,[switch]$Apply)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $InstallRoot) { $InstallRoot=(Get-TaskLeaseDefaults).InstallRoot }
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port must be 1..65535.' }
$record=Get-TaskLeaseRecord $InstallRoot
if (-not $record) { throw 'Task Lease is not installed.' }
$null=Test-TaskLeasePackage $InstallRoot
$dataRoot=Assert-TaskLeasePath $record.dataRoot 'DataRoot'
if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'config.json') -PathType Leaf)) { throw 'Private config.json is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'broker.token') -PathType Leaf)) { throw 'Broker credential is missing.' }
Import-Module ScheduledTasks -ErrorAction Stop
$taskName='QichengTaskLease'
$existing=Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) { throw "Scheduled task already exists: $taskName. Inspect it before changing autostart." }
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Windows PowerShell 5.1 executable is missing.' }
$start=Join-Path $InstallRoot 'product\runtime\Run-TaskLeaseAutostart.ps1'
$arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}" -Port {2}' -f $start,$InstallRoot,$Port
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$plan=[ordered]@{ status='autostart-plan'; taskName=$taskName; trigger='current-user-logon'; user=$user; installRoot=$InstallRoot; port=$Port; startsNow=$false; applyRequested=[bool]$Apply }
if (-not $Apply) { $plan | ConvertTo-Json; return }
$action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $InstallRoot
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -StartWhenAvailable
$task=New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description ('Qicheng Task Lease user logon broker: ' + $InstallRoot)
Register-ScheduledTask -TaskPath '\' -TaskName $taskName -InputObject $task -ErrorAction Stop | Out-Null
$plan.status='autostart-installed'
$plan | ConvertTo-Json
