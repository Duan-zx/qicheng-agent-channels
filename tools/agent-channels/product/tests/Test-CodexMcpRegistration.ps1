$ErrorActionPreference = 'Stop'
$runtime = Join-Path $PSScriptRoot '..\runtime\Register-CodexMcp.ps1'
$module = Join-Path $PSScriptRoot '..\..'
$python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$codex = (Get-Command codex.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$tempRoot = Join-Path $env:LOCALAPPDATA ('qicheng mcp test ' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $tempRoot 'installed lite'
$oldCodexHome = $env:CODEX_HOME
try {
    New-Item -ItemType Directory -Path (Join-Path $install '.local'), (Join-Path $tempRoot 'codex home') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $module 'bridge.py') -Destination $install
    Copy-Item -LiteralPath (Join-Path $module 'broker_client.py') -Destination $install
    Set-Content -LiteralPath (Join-Path $install '.local\channel.token') -Value ('a' * 64) -NoNewline
    $env:CODEX_HOME = Join-Path $tempRoot 'codex home'
    @{ product='Qicheng Lite'; channelCount=1 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json')
    $options = @{ InstallRoot=$install; PythonPath=$python; CodexPath=$codex }
    $preview = @(& $runtime @options)
    if ($preview.Count -ne 1 -or $preview[0].action -ne 'preview-add') { throw 'one-channel preview failed' }
    if (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml')) { throw 'preview wrote Codex configuration' }
    $null = & $runtime @options -Apply
    $registered = ConvertFrom-Json -InputObject ((& $codex mcp list --json 2>$null) -join "`n")
    if ($registered.Count -ne 1 -or $registered[0].transport.command -cne $python -or
        $registered[0].transport.args[0] -cne (Join-Path $install 'bridge.py')) { throw 'one-channel registration failed' }
    $again = @(& $runtime @options -Apply)
    if ($again.Count -ne 1 -or $again[0].action -ne 'unchanged') { throw 'idempotence failed' }
    $launcher = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($launcher) {
        $fromLauncher = @(& $runtime -InstallRoot $install -PythonPath $launcher.Source -CodexPath $codex)
        if ($fromLauncher.Count -ne 1 -or $fromLauncher[0].action -ne 'preview-unchanged') { throw 'py.exe resolution failed' }
    }
    $codexCmd = Join-Path $tempRoot 'codex wrapper.cmd'
    Set-Content -LiteralPath $codexCmd -Value ('@echo off' + "`r`n" + '"' + $codex + '" %*') -Encoding ASCII
    $fromCmd = @(& $runtime -InstallRoot $install -PythonPath $python -CodexPath $codexCmd)
    if ($fromCmd.Count -ne 1 -or $fromCmd[0].action -ne 'preview-unchanged') { throw 'codex.cmd resolution failed' }
    $options.CodexPath = $codexCmd
    @{ product='Qicheng Lite'; channelCount=2 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json')
    $two = @(& $runtime @options -Apply)
    $listedTwo = ConvertFrom-Json -InputObject ((& $codex mcp list --json 2>$null) -join "`n")
    if ($two.Count -ne 2 -or $listedTwo.Count -ne 2) { throw "second channel registration failed: plan=$($two.Count), listed=$($listedTwo.Count)" }
    & $codex mcp remove qicheng_lite_1 2>$null | Out-Null
    & $codex mcp add qicheng_lite_1 -- $python (Join-Path $install 'bridge.py') --channel 2 2>$null | Out-Null
    $before = & $codex mcp get qicheng_lite_1 --json 2>$null
    $failed = $false
    try { $null = & $runtime @options -Apply } catch { $failed = $true }
    if (-not $failed -or (($before | Out-String) -cne ((& $codex mcp get qicheng_lite_1 --json 2>$null) | Out-String))) { throw 'conflicting registration changed' }
    New-Item -ItemType File -Path (Join-Path $install '.local\broker.token') | Out-Null
    $failed = $false
    try { $null = & $runtime @options } catch { $failed = $true }
    if (-not $failed) { throw 'broker mode was accepted as direct mode' }
    Write-Output 'Codex MCP registration isolation test passed.'
} finally {
    $env:CODEX_HOME = $oldCodexHome
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $resolvedParent = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
    if (-not $resolvedTemp.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTemp) -notmatch '^qicheng mcp test [0-9a-f]{32}$') {
        throw 'Unsafe temporary cleanup path.'
    }
    if (Test-Path -LiteralPath $resolvedTemp) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force }
}
