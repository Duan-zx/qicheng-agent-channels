[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$PackageRoot = $PSScriptRoot,
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$StartMenuRoot,
    [string]$DesktopRoot,
    [string]$StartupRoot,
    [ValidateSet('Enabled','Disabled')][string]$AutoStart = 'Enabled',
    [string]$PythonPath,
    [string]$ImportConfigPath,
    [switch]$ReplaceConfig,
    [switch]$LaunchAfterInstall,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Get-QichengDefaultInstallRoot }
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Get-QichengDefaultDataRoot }
if ([string]::IsNullOrWhiteSpace($StartMenuRoot)) { $StartMenuRoot = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\启程 Windows 频道' }
if ([string]::IsNullOrWhiteSpace($DesktopRoot)) { $DesktopRoot = [Environment]::GetFolderPath('DesktopDirectory') }
if ([string]::IsNullOrWhiteSpace($StartupRoot)) { $StartupRoot = [Environment]::GetFolderPath('Startup') }
$packageRoot = Resolve-QichengLocalPath -Path $PackageRoot -Label 'PackageRoot'
$installRoot = Resolve-QichengLocalPath -Path $InstallRoot -Label 'InstallRoot'
$dataRoot = Resolve-QichengLocalPath -Path $DataRoot -Label 'DataRoot'
$startMenuRoot = Resolve-QichengLocalPath -Path $StartMenuRoot -Label 'StartMenuRoot'
$desktopRoot = Resolve-QichengLocalPath -Path $DesktopRoot -Label 'DesktopRoot'
$startupRoot = Resolve-QichengLocalPath -Path $StartupRoot -Label 'StartupRoot'
if ($installRoot.TrimEnd('\') -ieq $dataRoot.TrimEnd('\')) { throw 'InstallRoot and DataRoot must be separate.' }
$resolvedPython = Resolve-QichengPython -PythonPath $PythonPath
$importMaterial = $null
if (-not [string]::IsNullOrWhiteSpace($ImportConfigPath)) { $importMaterial = Get-QichengConfigImportMaterial -ConfigPath $ImportConfigPath }
$manifestPath = Join-Path $packageRoot 'package-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'package-manifest.json is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if ($manifest.schemaVersion -ne 1 -or -not $manifest.files) { throw 'Unsupported package manifest.' }
$expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.files) {
    $relative = [string]$entry.path
    $segments = @($relative -split '[\\/]')
    if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match '[:*?"<>|]' -or $segments.Count -lt 1 -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) { throw "Unsafe package path: $relative" }
    [void]$expected.Add($relative.Replace('/','\'))
    $source = Join-Path $packageRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Package file missing: $relative" }
    if ((Get-QichengSha256 -Path $source) -ine [string]$entry.sha256) { throw "Package hash mismatch: $relative" }
}
$actual = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse | ForEach-Object { $_.FullName.Substring($packageRoot.Length).TrimStart('\') } | Where-Object { $_ -ine 'package-manifest.json' })
foreach ($relative in $actual) { if (-not $expected.Contains($relative)) { throw "Unexpected file outside package allowlist: $relative" } }
if ($actual.Count -ne $expected.Count) { throw 'Package allowlist count does not match package contents.' }
$existingRecord = Get-QichengInstallRecord -InstallRoot $installRoot
if ((Test-Path -LiteralPath $installRoot) -and -not $existingRecord) { throw 'InstallRoot already exists without a Qicheng install record; refusing to overwrite it.' }
$plan = [ordered]@{ schemaVersion=1; status='not-installed'; packageVersion=$manifest.version; packageRoot=$packageRoot; installRoot=$installRoot; dataRoot=$dataRoot; python=$resolvedPython; importConfig=if($importMaterial){$importMaterial.SourcePath}else{$null}; autoStart=$AutoStart; launchAfterInstall=[bool]$LaunchAfterInstall; files=$expected.Count; shortcuts=@('启程 Windows 频道','管理 Windows 频道','设置 Windows 频道','导入已有频道配置','启程 Windows 频道诊断','启程 Windows 频道快速说明','卸载启程 Windows 频道'); preservesUserData=$true; applyRequested=[bool]$Apply; hostChangesMade=$false }
if (-not $Apply) { $plan | ConvertTo-Json -Depth 5; return }

function Get-QichengRunningProductProcesses([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $rootPrefix = $Root.TrimEnd('\') + '\'
    $viewerPath = Join-Path $Root 'viewer\dist\WindowsChannelsViewer.exe'
    $launcherName = 'Invoke-WindowsChannelsMcp.ps1'
    $matches = New-Object 'System.Collections.Generic.List[object]'
    try { $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { $processes = @() }
    foreach ($process in $processes) {
        $executablePath = [string]$process.ExecutablePath
        $commandLine = [string]$process.CommandLine
        $role = $null
        if (-not [string]::IsNullOrWhiteSpace($executablePath) -and $executablePath.Equals($viewerPath,[StringComparison]::OrdinalIgnoreCase)) {
            $role = 'viewer'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($commandLine) -and
                $commandLine.IndexOf($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $commandLine.IndexOf($launcherName,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $role = 'mcp-launcher'
        }
        if ($role) {
            $matches.Add([pscustomobject][ordered]@{ processId=[int]$process.ProcessId; name=[string]$process.Name; role=$role })
        }
    }
    return $matches.ToArray()
}

$runningProductProcesses = @(Get-QichengRunningProductProcesses -Root $installRoot)
if ($runningProductProcesses.Count -gt 0) {
    [ordered]@{
        schemaVersion = 1
        status = 'blocked-process-in-use'
        reason = 'installed-product-running'
        message = '检测到启程 Windows 频道仍在运行。请关闭频道工作台及正在使用该频道的 AI/Codex 客户端后重试；当前已安装版本保持不变。'
        retryAction = '关闭频道客户端后重试'
        installRoot = $installRoot
        existingVersion = [string]$existingRecord.version
        existingVersionPreserved = $true
        processes = $runningProductProcesses
        applyRequested = $true
        hostChangesMade = $false
    } | ConvertTo-Json -Depth 5
    return
}
if (-not $PSCmdlet.ShouldProcess($installRoot, 'Install or upgrade the per-user Windows Channels package')) { $plan | ConvertTo-Json -Depth 5; return }
$parent = Split-Path -Parent $installRoot
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$stage = Join-Path $parent ('.QichengWindowsChannels.stage.' + [guid]::NewGuid().ToString('N'))
$backup = $null
$activated = $false
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($entry in $manifest.files) {
        $relative = ([string]$entry.path).Replace('/','\')
        $source = Join-Path $packageRoot $relative
        $destination = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stage 'package-manifest.json')
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    $desktopLink = Join-Path $desktopRoot '启程 Windows 频道.lnk'
    $startupLink = Join-Path $startupRoot '启程 Windows 频道.lnk'
    $record = [ordered]@{ schemaVersion=1; version=$manifest.version; installedAt=(Get-Date).ToUniversalTime().ToString('o'); dataRoot=$dataRoot; pythonPath=$resolvedPython; startMenuRoot=$startMenuRoot; desktopLink=$desktopLink; startupLink=$startupLink; autoStart=$AutoStart; packageManifestSha256=(Get-QichengSha256 -Path $manifestPath) }
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage '.qicheng-product-install.json') -Encoding UTF8
    if (Test-Path -LiteralPath $installRoot) {
        $backup = Join-Path $parent ('.QichengWindowsChannels.backup.' + [guid]::NewGuid().ToString('N'))
        try { Move-Item -LiteralPath $installRoot -Destination $backup }
        catch [System.IO.IOException] {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            [ordered]@{
                schemaVersion = 1
                status = 'blocked-process-in-use'
                reason = 'install-root-in-use'
                message = '安装目录仍被占用。请关闭频道工作台及正在使用该频道的 AI/Codex 客户端后重试；当前已安装版本保持不变。'
                retryAction = '关闭频道客户端后重试'
                installRoot = $installRoot
                existingVersion = [string]$existingRecord.version
                existingVersionPreserved = $true
                processes = @()
                applyRequested = $true
                hostChangesMade = $false
            } | ConvertTo-Json -Depth 5
            return
        }
    }
    Move-Item -LiteralPath $stage -Destination $installRoot
    $activated = $true
    if ($importMaterial) { [void](Import-QichengConfig -Material $importMaterial -DataRoot $dataRoot -Replace:$ReplaceConfig) }
    New-Item -ItemType Directory -Path $startMenuRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $desktopRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $startupRoot -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    function New-Link([string]$Path,[string]$Target,[string]$Arguments,[string]$WorkingDirectory) {
        $temporaryPath = Join-Path (Split-Path -Parent $Path) ('.qicheng-shortcut-' + [guid]::NewGuid().ToString('N') + '.lnk')
        $link = $null
        try {
            # WScript.Shell can ANSI-mangle a non-ASCII link filename on an English locale.
            # Save under an ASCII basename, release the COM object, then let .NET move it.
            $link = $shell.CreateShortcut($temporaryPath)
            $link.TargetPath = $Target
            $link.Arguments = $Arguments
            $link.WorkingDirectory = $WorkingDirectory
            $link.Save()
        } finally {
            if ($null -ne $link -and [Runtime.InteropServices.Marshal]::IsComObject($link)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        }
        try {
            if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) { throw '快捷方式临时文件创建失败。' }
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        } finally {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    New-Link (Join-Path $startMenuRoot '启程 Windows 频道.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Start-WindowsChannels.ps1') + '"') $installRoot
    New-Link $desktopLink $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Start-WindowsChannels.ps1') + '"') $installRoot
    if ($AutoStart -eq 'Enabled') { New-Link $startupLink $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Start-WindowsChannels.ps1') + '"') $installRoot }
    elseif (Test-Path -LiteralPath $startupLink -PathType Leaf) { Remove-Item -LiteralPath $startupLink -Force }
    New-Link (Join-Path $startMenuRoot '管理 Windows 频道.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Start-WindowsChannels.ps1') + '" -Show') $installRoot
    New-Link (Join-Path $startMenuRoot '设置 Windows 频道.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Setup-WindowsChannels.ps1') + '"') $installRoot
    New-Link (Join-Path $startMenuRoot '启程 Windows 频道诊断.lnk') $powershell ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Diagnose-WindowsChannels.ps1') + '"') $installRoot
    New-Link (Join-Path $startMenuRoot '导入已有频道配置.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Import-WindowsChannelsConfig.ps1') + '"') $installRoot
    New-Link (Join-Path $startMenuRoot '启程 Windows 频道快速说明.lnk') (Join-Path $installRoot 'QUICKSTART.zh-CN.md') '' $installRoot
    New-Link (Join-Path $startMenuRoot '卸载启程 Windows 频道.lnk') $powershell ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Uninstall-WindowsChannels.ps1') + '"') $installRoot
    $launched = $null
    if ($LaunchAfterInstall) {
        if (Test-Path -LiteralPath (Join-Path $dataRoot 'channels.json') -PathType Leaf) {
            Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Start-WindowsChannels.ps1') + '"') -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
            $launched = 'viewer'
        } else {
            Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Setup-WindowsChannels.ps1') + '"') -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
            $launched = 'setup'
        }
    }
    if ($backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    [ordered]@{ schemaVersion=1; status='installed'; version=$manifest.version; installRoot=$installRoot; dataRoot=$dataRoot; python=$resolvedPython; autoStart=$AutoStart; startupLinkCreated=(Test-Path -LiteralPath $startupLink -PathType Leaf); configImported=[bool]$importMaterial; configExists=(Test-Path -LiteralPath (Join-Path $dataRoot 'channels.json')); launched=$launched; hostChangesMade=$true } | ConvertTo-Json -Depth 4
} catch {
    if ($activated -and (Test-Path -LiteralPath $installRoot)) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
    if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $installRoot }
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    throw
}
