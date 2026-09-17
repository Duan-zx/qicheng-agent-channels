[CmdletBinding()]
param([string]$ConfigPath, [string]$PythonPath, [switch]$Show)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')

$installRoot = Resolve-QichengLocalPath -Path $PSScriptRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
$dataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $dataRoot 'channels.json' }
function Start-SetupWizard([string]$Reason) {
    $setup = Join-Path $installRoot 'Setup-WindowsChannels.ps1'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "首次设置向导缺失：$setup。请重新安装完整发布包。" }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $setup + '"') -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
    [pscustomobject]@{ status='setup-start-requested'; reason=$Reason; config=$ConfigPath; setup=$setup; channelsAvailable=$false }
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Start-SetupWizard -Reason 'configuration-missing'
    return
}
try { $config = Read-QichengConfig -ConfigPath $ConfigPath }
catch {
    Start-SetupWizard -Reason 'configuration-invalid'
    return
}
$python = Resolve-QichengPython -PythonPath $(if(-not [string]::IsNullOrWhiteSpace($PythonPath)){$PythonPath}elseif($record -and $record.pythonPath){[string]$record.pythonPath}else{$null})
$viewer = Join-Path $installRoot 'viewer\dist\WindowsChannelsViewer.exe'
if (-not (Test-Path -LiteralPath $viewer -PathType Leaf)) { throw "查看器缺失：$viewer。请重新安装发布包。" }
$workingDirectory = $installRoot
$arguments = '--config "{0}" --python "{1}"' -f $config.Path.Replace('"','\"'), $python.Replace('"','\"')
if ($Show) { $arguments += ' --show' }
Start-Process -FilePath $viewer -ArgumentList $arguments -WorkingDirectory $workingDirectory | Out-Null
[pscustomobject]@{ status = 'viewer-start-requested'; config = $config.Path; python = $python; projects = $config.ProjectNames; showRequested = [bool]$Show }
