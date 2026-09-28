[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')][string]$Name,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9_-]{0,39}$')][string]$Project,
    [string]$ConfigPath,
    [string]$PythonPath,
    [string]$CodexPath,
    [string]$BrokerUrl,
    [string]$BrokerTokenFile,
    [string]$BrokerChannelId,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$installRoot = Resolve-QichengLocalPath -Path $PSScriptRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
$dataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $dataRoot 'channels.json' }
$config = Read-QichengConfig -ConfigPath $ConfigPath
if ($config.ProjectNames -notcontains $Project) { throw "配置中没有 project：$Project" }
$python = Resolve-QichengPython -PythonPath $(if(-not [string]::IsNullOrWhiteSpace($PythonPath)){$PythonPath}elseif($record -and $record.pythonPath){[string]$record.pythonPath}else{$null})
$codexExecutable = $null
if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
    $codexExecutable = Resolve-QichengLocalPath -Path $CodexPath -Label 'CodexPath'
    if (-not (Test-Path -LiteralPath $codexExecutable -PathType Leaf)) { throw '指定的 Codex CLI 不存在。' }
}
else {
    $codex = Get-Command codex.exe -ErrorAction SilentlyContinue
    if (-not $codex) { $codex = Get-Command codex -ErrorAction SilentlyContinue }
    if (-not $codex) { throw '未找到 Codex CLI；普通安装与工作台使用不依赖 Codex，只有选择 AI 接入时才需要安装 CLI。' }
    $codexExecutable = $codex.Source
}
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$launcher = Join-Path $installRoot 'Invoke-WindowsChannelsMcp.ps1'
$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,'-Project',$Project,'-ConfigPath',$config.Path,'-PythonPath',$python)
$brokerOptions = @($BrokerUrl,$BrokerTokenFile,$BrokerChannelId)
if (@($brokerOptions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -notin @(0,3)) {
    throw 'BrokerUrl, BrokerTokenFile and BrokerChannelId must be supplied together.'
}
if (-not [string]::IsNullOrWhiteSpace($BrokerUrl)) {
    if ($BrokerUrl -notmatch '^http://127\.0\.0\.1:[0-9]{1,5}/?$' -or $BrokerChannelId -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'Broker endpoint or channel ID is invalid.' }
    $brokerTokenPath = Resolve-QichengLocalPath -Path $BrokerTokenFile -Label 'BrokerTokenFile'
    if (-not (Test-Path -LiteralPath $brokerTokenPath -PathType Leaf)) { throw 'Broker token file is missing.' }
    $arguments += @('-BrokerUrl',$BrokerUrl,'-BrokerTokenFile',$brokerTokenPath,'-BrokerChannelId',$BrokerChannelId)
}
$listText = (& $codexExecutable mcp list --json 2>$null | Out-String)
if ($LASTEXITCODE -ne 0) { throw '无法读取现有 Codex MCP 配置；未进行添加或覆盖。' }
try {
    $parsed = ConvertFrom-Json -InputObject $listText -ErrorAction Stop
    $servers = if ($null -eq $parsed) { @() } elseif ($parsed -is [array]) { $parsed } else { @($parsed) }
    foreach ($server in $servers) {
        if ($null -eq $server -or $null -eq $server.PSObject.Properties['name']) { throw 'missing name' }
    }
} catch { throw 'Codex MCP 列表不是有效 JSON 数组；未进行添加或覆盖。' }
$existing = @($servers | Where-Object { [string]$_.name -ceq $Name }) | Select-Object -First 1
$existingMatches = $false
if ($existing) {
    $existingArgs = @($existing.transport.args)
    $existingMatches = $existing.transport.type -eq 'stdio' -and [string]$existing.transport.command -ieq $powershell -and $existingArgs.Count -eq $arguments.Count
    if ($existingMatches) {
        for ($index = 0; $index -lt $arguments.Count; $index++) {
            if ([string]$existingArgs[$index] -cne [string]$arguments[$index]) { $existingMatches = $false; break }
        }
    }
}
$status = if ($existing -and $existingMatches) { 'already-configured' } elseif ($existing) { 'conflict' } else { 'not-added' }
$plan = [ordered]@{ schemaVersion=1; status=$status; name=$Name; project=$Project; codex=$codexExecutable; command=$powershell; args=$arguments; existingNameFound=[bool]$existing; existingMatches=[bool]$existingMatches; requiresClientReload=($status -eq 'not-added'); nativeToolsDiscovered=$false; applyRequested=[bool]$Apply }
if ($existing -and -not $existingMatches) {
    if ($Apply) { throw "Codex MCP 名称 '$Name' 已存在且 command/args 不同；拒绝覆盖，请选择其他名称或由用户先审阅并移除旧配置。" }
    $plan | ConvertTo-Json -Depth 5
    return
}
if ($existingMatches) {
    $plan | ConvertTo-Json -Depth 5
    return
}
if (-not $Apply) { $plan | ConvertTo-Json -Depth 5; return }
if (-not $PSCmdlet.ShouldProcess($Name, 'Add one explicitly selected Windows channel MCP to Codex CLI configuration')) { $plan | ConvertTo-Json -Depth 5; return }
$codexArguments = @('mcp','add',$Name,'--',$powershell) + $arguments
& $codexExecutable @codexArguments
if ($LASTEXITCODE -ne 0) { throw "codex mcp add failed with exit code $LASTEXITCODE." }
[ordered]@{ schemaVersion=1; status='codex-cli-config-added'; name=$Name; project=$Project; requiresClientReload=$true; nativeToolsDiscovered=$false; note='CLI configuration success is not proof that the current task hot-loaded MCP tools.' } | ConvertTo-Json -Depth 4
