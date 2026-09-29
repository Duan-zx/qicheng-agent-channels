[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$PythonPath,
    [string]$CodexPath,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')

function Resolve-Executable {
    param([string]$Value, [string[]]$CommandNames, [string]$Label)
    if (-not $Value) {
        $found = Get-Command $CommandNames -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -and (Test-Path -LiteralPath $_.Source -PathType Leaf) } |
            Select-Object -First 1
        if (-not $found) { throw "$Label 未找到；请安装后重试，或传入其绝对路径。" }
        $Value = $found.Source
    }
    $resolved = Resolve-QichengLiteRegularFile -Path $Value -Label $Label
    return $resolved
}

function Test-PythonVersion {
    param([string]$Executable)
    $ErrorActionPreference = 'Continue'
    & $Executable -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-Python {
    param([string]$Value)
    if ($Value) {
        $path = Resolve-Executable -Value $Value -Label 'PythonPath'
        if ([IO.Path]::GetFileName($path) -ieq 'py.exe') {
            $ErrorActionPreference = 'Continue'
            $candidate = @(& $path -3 -c 'import sys; print(sys.executable)' 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $candidate) { throw 'py.exe 未找到可用的 Python 3。' }
            $path = Resolve-Executable -Value ([string]$candidate[0]) -Label 'PythonPath'
        }
        if (-not (Test-PythonVersion -Executable $path)) { throw "需要 Python 3.10+：$path" }
        return $path
    }
    foreach ($commandName in @('python.exe', 'py.exe')) {
        foreach ($command in @(Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue)) {
            try { $path = Resolve-Python -Value $command.Source; return $path } catch { continue }
        }
    }
    throw '未找到 Python 3.10+；请安装后重试，或用 -PythonPath 传入绝对路径。'
}

function Read-CodexServers {
    param([string]$Executable)
    $ErrorActionPreference = 'Continue'
    $json = & $Executable mcp list --json 2>$null
    if ($LASTEXITCODE -ne 0) { throw '无法读取 Codex MCP 配置；未修改配置。' }
    try {
        $decoded = ConvertFrom-Json -InputObject ($json -join "`n") -ErrorAction Stop
        if ($decoded -isnot [array]) { throw 'Not an array' }
        foreach ($server in $decoded) { Write-Output $server }
    }
    catch { throw 'Codex MCP 列表不是可识别的 JSON；未修改配置。' }
}

if (-not $InstallRoot) { $InstallRoot = Get-QichengLiteInstallRoot }
$root = Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$record = Read-QichengLiteInstallRecord -InstallRoot $root
if (-not $record -or [string]$record.product -cne 'Qicheng Lite') { throw '未找到可信的启程轻量版安装记录；请先安装产品。' }
$count = Get-QichengLiteChannelCount -Record $record
$bridge = Resolve-QichengLiteRegularFile -Path (Join-Path $root 'bridge.py') -Label 'bridge.py'
$null = Resolve-QichengLiteRegularFile -Path (Join-Path $root 'broker_client.py') -Label 'broker_client.py'
$null = Resolve-QichengLiteRegularFile -Path (Join-Path $root '.local\channel.token') -Label 'channel.token'
if (Test-Path -LiteralPath (Join-Path $root '.local\broker.token') -PathType Leaf) {
    throw '检测到 Task Lease broker.token。直连注册会绕过任务租约；请按 Task Lease 文档配置 broker 参数。'
}
$python = Resolve-Python -Value $PythonPath
$codex = Resolve-Executable -Value $CodexPath -CommandNames @('codex.exe', 'codex.cmd') -Label 'CodexPath'

$servers = Read-CodexServers -Executable $codex
$plan = @()
for ($channel = 1; $channel -le $count; $channel++) {
    $name = "qicheng_lite_$channel"
    $args = @($bridge, '--channel', [string]$channel)
    $matches = @($servers | Where-Object { $_.name -ceq $name })
    if ($matches.Count -gt 1) { throw "Codex 中存在多个同名服务 $name；未修改配置。" }
    $action = 'add'
    if ($matches.Count -eq 1) {
        $transport = $matches[0].transport
        $same = ($matches[0].enabled -eq $true -and $transport.type -ceq 'stdio' -and
            [string]$transport.command -ceq $python -and @($transport.args).Count -eq $args.Count -and
            [string]$transport.args[0] -ceq $args[0] -and [string]$transport.args[1] -ceq $args[1] -and
            [string]$transport.args[2] -ceq $args[2] -and -not $transport.env -and
            (-not $transport.env_vars -or @($transport.env_vars).Count -eq 0))
        if (-not $same) { throw "同名服务 $name 已存在且配置不同或已禁用；请人工核对后处理，未覆盖。" }
        $action = 'unchanged'
    }
    $plan += [pscustomobject]@{ name=$name; action=$action; command=$python; args=$args }
}
if ($count -eq 1 -and @($servers | Where-Object { $_.name -ceq 'qicheng_lite_2' }).Count -gt 0) {
    Write-Warning '当前安装只启用频道 1，但 Codex 仍有 qicheng_lite_2 注册。请人工核对是否移除；本脚本不会删除已有服务。'
}

foreach ($item in $plan) {
    Write-Output ([pscustomobject]@{ name=$item.name; action=if ($Apply) { $item.action } else { "preview-$($item.action)" }; command=$item.command; args=$item.args })
}
if (-not $Apply) { return }
foreach ($item in $plan | Where-Object { $_.action -eq 'add' }) {
    # Re-read immediately before writing; another client may have changed this name.
    if (@(Read-CodexServers -Executable $codex | Where-Object { $_.name -ceq $item.name }).Count -ne 0) {
        throw "注册前发现 $($item.name) 已出现；停止，未覆盖。"
    }
    $ErrorActionPreference = 'Continue'
    & $codex mcp add $item.name -- $item.command @($item.args) 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "注册 $($item.name) 失败；请检查 Codex CLI 和配置权限。" }
    $registered = @(Read-CodexServers -Executable $codex | Where-Object { $_.name -ceq $item.name })
    if ($registered.Count -ne 1) { throw "注册 $($item.name) 后未能读回；请人工核对 Codex 配置。" }
}
