[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param([string]$ConfigPath, [string]$DataRoot, [switch]$ReplaceConfig)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$record = Get-QichengInstallRecord -InstallRoot $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot } }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择已有的 Windows 频道 channels.json'
    $dialog.Filter = '频道配置 (channels.json)|channels.json|JSON 文件 (*.json)|*.json'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Write-Host '未选择配置，未进行更改。'; return }
    $ConfigPath = $dialog.FileName
}
$material = Get-QichengConfigImportMaterial -ConfigPath $ConfigPath
$destination = Join-Path (Resolve-QichengLocalPath -Path $DataRoot -Label 'DataRoot') 'channels.json'
if ($PSCmdlet.ShouldProcess($destination, 'Import normalized bindings and copy private tokens')) {
    $result = Import-QichengConfig -Material $material -DataRoot $DataRoot -Replace:$ReplaceConfig
    [ordered]@{ status='imported'; configPath=$result.ConfigPath; projects=$result.Projects; tokenValuesDisplayed=$false } | ConvertTo-Json -Depth 4
}
