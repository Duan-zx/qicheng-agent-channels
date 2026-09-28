[CmdletBinding()]
param([string]$InstallRoot,[Parameter(Mandatory=$true)][string]$SourceHostConfig,[switch]$Apply,[switch]$BrokerStopped)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $InstallRoot) { $InstallRoot=(Get-TaskLeaseDefaults).InstallRoot }
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
$SourceHostConfig=Assert-TaskLeasePath $SourceHostConfig 'SourceHostConfig'
$record=Get-TaskLeaseRecord $InstallRoot
if (-not $record) { throw 'Task Lease is not installed.' }
$null=Test-TaskLeasePackage $InstallRoot
$dataRoot=Assert-TaskLeasePath $record.dataRoot 'DataRoot'
if ($Apply -and -not $BrokerStopped) { throw 'Stop the broker and specify -BrokerStopped for migration.' }
if ($Apply) { Set-TaskLeasePrivateDirectory $dataRoot }
$arguments=@('-B',(Join-Path $InstallRoot 'product\runtime\Migrate-GuestTokens.py'),'--data-root',$dataRoot,'--source-host-config',$SourceHostConfig)
if ($Apply) { $arguments+='--apply' }
if ($BrokerStopped) { $arguments+='--broker-stopped' }
& $record.python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Guest token migration was rejected; see the redacted result above.' }
