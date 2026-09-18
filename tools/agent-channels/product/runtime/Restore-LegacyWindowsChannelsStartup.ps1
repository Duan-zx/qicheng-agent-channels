[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param([string]$InstallRoot,[string]$LegacyStartupRoot,[switch]$Apply)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=$PSScriptRoot}
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$record=Read-QichengLiteInstallRecord -InstallRoot $installRoot
if(-not $record){throw '启程轻量版安装记录缺失。'}
$dataRoot=Resolve-QichengLitePath -Path ([string]$record.dataRoot) -Label 'DataRoot'
$backup=Join-Path $dataRoot 'compatibility-backup\启程 Windows 频道.lnk'
if([string]::IsNullOrWhiteSpace($LegacyStartupRoot)){$LegacyStartupRoot=[Environment]::GetFolderPath('Startup')}
$legacyStartupRoot=Resolve-QichengLitePath -Path $LegacyStartupRoot -Label 'LegacyStartupRoot'
$destination=Join-Path $legacyStartupRoot '启程 Windows 频道.lnk'
$plan=[ordered]@{schemaVersion=1;status='not-restored';backup=$backup;destination=$destination;backupExists=(Test-Path -LiteralPath $backup -PathType Leaf);destinationExists=(Test-Path -LiteralPath $destination -PathType Leaf);applyRequested=[bool]$Apply;hostChangesMade=$false}
if(-not $Apply){$plan|ConvertTo-Json -Depth 4;return}
if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw '没有可恢复的旧 Windows 频道启动项备份。'}
if(Test-Path -LiteralPath $destination){throw '旧 Windows 频道启动项已存在；拒绝覆盖。'}
if(-not $PSCmdlet.ShouldProcess($destination,'恢复旧 Windows 频道当前用户启动项')){$plan|ConvertTo-Json -Depth 4;return}
Copy-Item -LiteralPath $backup -Destination $destination
[ordered]@{schemaVersion=1;status='restored';destination=$destination;backupPreserved=$true;hostChangesMade=$true}|ConvertTo-Json -Depth 4
