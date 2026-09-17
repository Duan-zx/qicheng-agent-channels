[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Project, [string]$ConfigPath, [string]$PythonPath)

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
& $python -m host.mcp --config $config.Path --project $Project
exit $LASTEXITCODE
