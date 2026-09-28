[CmdletBinding()]
param([string]$InstallRoot,[switch]$Apply)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $InstallRoot) { $InstallRoot=(Get-TaskLeaseDefaults).InstallRoot }
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
Import-Module ScheduledTasks -ErrorAction Stop
$taskName='QichengTaskLease'
$task=Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) { throw "Scheduled task is absent: $taskName" }
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action=@($task.Actions)
$matchesInstall=$false
foreach ($scriptName in @('Run-TaskLeaseAutostart.ps1','Start-TaskLease.ps1')) {
    $start=Join-Path $InstallRoot ('product\runtime\' + $scriptName)
    $argumentPattern='^-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        [regex]::Escape($start) + '" -InstallRoot "' + [regex]::Escape($InstallRoot) + '" -Port ([1-9][0-9]{0,4})$'
    if ($action.Count -eq 1 -and $action[0].Arguments -match $argumentPattern) { $matchesInstall=$true }
}
if ($task.Description -ine ('Qicheng Task Lease user logon broker: ' + $InstallRoot) -or
    $action.Count -ne 1 -or $action[0].Execute -ine $exe -or
    -not $matchesInstall) {
    throw 'Scheduled task does not match this Task Lease install; refusing to remove it.'
}
$plan=[ordered]@{ status='autostart-uninstall-plan'; taskName=$taskName; installRoot=$InstallRoot; stopsRunningBroker=$false; applyRequested=[bool]$Apply }
if (-not $Apply) { $plan | ConvertTo-Json; return }
Unregister-ScheduledTask -TaskPath '\' -TaskName $taskName -Confirm:$false -ErrorAction Stop
$plan.status='autostart-uninstalled'
$plan | ConvertTo-Json
