[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([string]$InstallRoot = $PSScriptRoot, [string]$DataRoot, [switch]$RemoveUserData, [switch]$Apply)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$installRoot = Resolve-QichengLocalPath -Path $InstallRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
if (-not $record) { throw 'Qicheng install record is missing; refusing to remove this directory.' }
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = [string]$record.dataRoot }
$dataRoot = Resolve-QichengLocalPath -Path $DataRoot -Label 'DataRoot'
if ($installRoot.TrimEnd('\') -ieq $dataRoot.TrimEnd('\')) { throw 'InstallRoot and DataRoot must be separate.' }
$startMenuRoot = if ($record.startMenuRoot) { Resolve-QichengLocalPath -Path ([string]$record.startMenuRoot) -Label 'StartMenuRoot' } else { Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\启程 Windows 频道' }
$desktopLink = if ($record.desktopLink) { Resolve-QichengLocalPath -Path ([string]$record.desktopLink) -Label 'DesktopLink' } else { Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) '启程 Windows 频道.lnk' }
$startupLink = if ($record.startupLink) { Resolve-QichengLocalPath -Path ([string]$record.startupLink) -Label 'StartupLink' } else { Join-Path ([Environment]::GetFolderPath('Startup')) '启程 Windows 频道.lnk' }
$plan = [ordered]@{ schemaVersion=1; status='not-uninstalled'; installRoot=$installRoot; dataRoot=$dataRoot; removeUserData=[bool]$RemoveUserData; applyRequested=[bool]$Apply; hostChangesMade=$false }
if (-not $Apply) { $plan | ConvertTo-Json -Depth 4; return }
if (-not $PSCmdlet.ShouldProcess($installRoot, 'Uninstall Windows Channels program files and shortcuts')) { $plan | ConvertTo-Json -Depth 4; return }
if (Test-Path -LiteralPath $startMenuRoot) { Remove-Item -LiteralPath $startMenuRoot -Recurse -Force }
if (Test-Path -LiteralPath $desktopLink -PathType Leaf) { Remove-Item -LiteralPath $desktopLink -Force }
if (Test-Path -LiteralPath $startupLink -PathType Leaf) { Remove-Item -LiteralPath $startupLink -Force }
if ($RemoveUserData -and (Test-Path -LiteralPath $dataRoot)) {
    if (-not $PSCmdlet.ShouldProcess($dataRoot, 'Remove private Windows Channels user data')) { throw 'User-data removal was not confirmed.' }
    Remove-Item -LiteralPath $dataRoot -Recurse -Force
}
$self = $MyInvocation.MyCommand.Path
$cleanup = Join-Path ([System.IO.Path]::GetTempPath()) ('qicheng-uninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
$cleanupText = "Start-Sleep -Milliseconds 500`r`nRemove-Item -LiteralPath '" + $installRoot.Replace("'", "''") + "' -Recurse -Force`r`nRemove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force`r`n"
Set-Content -LiteralPath $cleanup -Value $cleanupText -Encoding UTF8
Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $cleanup + '"') -WindowStyle Hidden | Out-Null
[ordered]@{ schemaVersion=1; status='uninstall-requested'; installRoot=$installRoot; dataRemoved=[bool]$RemoveUserData; userDataPreserved=(-not $RemoveUserData) } | ConvertTo-Json -Depth 4
