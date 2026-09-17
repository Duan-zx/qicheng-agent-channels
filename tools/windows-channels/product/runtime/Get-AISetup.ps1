[CmdletBinding()]
param([string]$ConfigPath, [string]$PythonPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$installRoot = Resolve-QichengLocalPath -Path $PSScriptRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
$dataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $dataRoot 'channels.json' }
$config = Read-QichengConfig -ConfigPath $ConfigPath
$python = Resolve-QichengPython -PythonPath $(if(-not [string]::IsNullOrWhiteSpace($PythonPath)){$PythonPath}elseif($record -and $record.pythonPath){[string]$record.pythonPath}else{$null})
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$launcher = Join-Path $installRoot 'Invoke-WindowsChannelsMcp.ps1'
$entries = foreach ($project in $config.ProjectNames) {
    [ordered]@{
        project = $project
        transport = 'stdio'
        command = $powershell
        args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,'-Project',$project,'-ConfigPath',$config.Path,'-PythonPath',$python)
        cwdRequired = $false
        codexAddExample = "& '$installRoot\Add-CodexMcp.ps1' -Name 'qicheng-$project' -Project '$project' -Apply"
        note = 'Stable launcher sets its own root. CLI configuration is not proof of current-task native tool discovery; reload and verify tools.'
    }
}
[ordered]@{ schemaVersion = 1; generatedAt = (Get-Date).ToUniversalTime().ToString('o'); connectors = @($entries) } | ConvertTo-Json -Depth 6
