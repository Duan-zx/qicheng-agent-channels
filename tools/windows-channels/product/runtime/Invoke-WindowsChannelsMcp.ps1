[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [string]$ConfigPath,
    [string]$PythonPath,
    [string]$BrokerUrl,
    [string]$BrokerTokenFile,
    [string]$BrokerChannelId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$installRoot = Resolve-QichengLocalPath -Path $PSScriptRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
$dataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $dataRoot 'channels.json' }
$config = Read-QichengConfig -ConfigPath $ConfigPath
if ($config.ProjectNames -notcontains $Project) { throw "配置中没有 project：$Project" }
$pythonCandidate = if(-not [string]::IsNullOrWhiteSpace($PythonPath)){$PythonPath}elseif($record -and $record.pythonPath){[string]$record.pythonPath}else{$null}
if ([string]::IsNullOrWhiteSpace($pythonCandidate)) { throw '安装记录中没有已验证的 Python 路径；请重新安装或显式传入 -PythonPath。' }
$python = Resolve-QichengLocalPath -Path $pythonCandidate -Label 'PythonPath'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw '已配置的 Python 不存在；请重新安装或更新 Python 路径。' }
Set-Location -LiteralPath $installRoot
$brokerOptions = @($BrokerUrl,$BrokerTokenFile,$BrokerChannelId)
if (@($brokerOptions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -notin @(0,3)) {
    throw 'BrokerUrl, BrokerTokenFile and BrokerChannelId must be supplied together.'
}
$arguments = @('-B','-m','host.mcp','--config',$config.Path,'--project',$Project)
if (-not [string]::IsNullOrWhiteSpace($BrokerUrl)) {
    $arguments += @('--broker-url',$BrokerUrl,'--broker-token-file',$BrokerTokenFile,'--broker-channel-id',$BrokerChannelId)
}
& $python @arguments
exit $LASTEXITCODE
