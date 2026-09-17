[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputDirectory, [string]$Version)

$ErrorActionPreference = 'Stop'
$productRoot = $PSScriptRoot
$windowsRoot = Split-Path -Parent $productRoot
if ($OutputDirectory -notmatch '^[A-Za-z]:[\\/]') { throw 'OutputDirectory must be a fully qualified local-drive path.' }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory already exists; choose a new directory.' }
if ($output.StartsWith($windowsRoot + '\',[StringComparison]::OrdinalIgnoreCase) -and -not $output.StartsWith((Join-Path $productRoot 'dist') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory may not overlap source directories.' }
if ([string]::IsNullOrWhiteSpace($Version)) {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $windowsRoot '..\..'))
    $sha = (& git -C $repoRoot rev-parse --short=12 HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) { $sha = 'unknown' }
    $Version = '0.1.0-dev+' + $sha.Trim()
}
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$') { throw 'Version contains unsupported characters.' }
New-Item -ItemType Directory -Path $output | Out-Null
$privateBuild = Join-Path $output '.build'
New-Item -ItemType Directory -Path $privateBuild | Out-Null
$viewerExe = Join-Path $privateBuild 'WindowsChannelsViewer.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw '.NET Framework C# compiler missing.' }
& $compiler /nologo /target:winexe /optimize+ /platform:x64 `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    "/win32manifest:$(Join-Path $windowsRoot 'viewer\app.manifest')" `
    "/out:$viewerExe" (Join-Path $windowsRoot 'viewer\Viewer.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $viewerExe -PathType Leaf)) { throw 'Viewer compilation failed.' }

$allowlist = @(
    @{ source=(Join-Path $windowsRoot 'LICENSE'); destination='LICENSE'; kind='license' },
    @{ source=(Join-Path $windowsRoot 'host\__init__.py'); destination='host\__init__.py'; kind='source-runtime' },
    @{ source=(Join-Path $windowsRoot 'host\client.py'); destination='host\client.py'; kind='source-runtime' },
    @{ source=(Join-Path $windowsRoot 'host\mcp.py'); destination='host\mcp.py'; kind='source-runtime' },
    @{ source=$viewerExe; destination='viewer\dist\WindowsChannelsViewer.exe'; kind='built-executable' },
    @{ source=(Join-Path $windowsRoot 'host\__init__.py'); destination='source\host\__init__.py'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'host\client.py'); destination='source\host\client.py'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'host\mcp.py'); destination='source\host\mcp.py'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'host\README.md'); destination='source\host\README.md'; kind='documentation' },
    @{ source=(Join-Path $windowsRoot 'guest\__init__.py'); destination='source\guest\__init__.py'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'guest\agent.py'); destination='source\guest\agent.py'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'guest\protocol.py'); destination='source\guest\protocol.py'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'guest\windows.py'); destination='source\guest\windows.py'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'guest\README.md'); destination='source\guest\README.md'; kind='documentation' },
    @{ source=(Join-Path $windowsRoot 'viewer\Viewer.cs'); destination='source\viewer\Viewer.cs'; kind='source' },
    @{ source=(Join-Path $windowsRoot 'viewer\Build.ps1'); destination='source\viewer\Build.ps1'; kind='build-script' },
    @{ source=(Join-Path $windowsRoot 'viewer\app.manifest'); destination='source\viewer\app.manifest'; kind='build-source' },
    @{ source=(Join-Path $windowsRoot 'viewer\README.md'); destination='source\viewer\README.md'; kind='documentation' },
    @{ source=(Join-Path $windowsRoot 'ARCHITECTURE.md'); destination='source\ARCHITECTURE.md'; kind='documentation' },
    @{ source=(Join-Path $windowsRoot 'README.md'); destination='source\README.md'; kind='documentation' },
    @{ source=(Join-Path $windowsRoot 'LICENSE'); destination='source\LICENSE'; kind='license' },
    @{ source=(Join-Path $windowsRoot 'Test-Host.ps1'); destination='source\Test-Host.ps1'; kind='deployment-script' },
    @{ source=(Join-Path $windowsRoot 'Prepare-Channels.ps1'); destination='source\Prepare-Channels.ps1'; kind='deployment-script' },
    @{ source=(Join-Path $windowsRoot 'New-ChannelVMs.ps1'); destination='source\New-ChannelVMs.ps1'; kind='deployment-script' },
    @{ source=(Join-Path $windowsRoot 'Register-HostService.ps1'); destination='source\Register-HostService.ps1'; kind='deployment-script' },
    @{ source=(Join-Path $windowsRoot 'Build-GuestPayload.ps1'); destination='source\Build-GuestPayload.ps1'; kind='deployment-script' },
    @{ source=(Join-Path $windowsRoot 'Install-GuestPayloadDirect.ps1'); destination='source\Install-GuestPayloadDirect.ps1'; kind='deployment-script' },
    @{ source=(Join-Path $windowsRoot 'tests\test_contract.py'); destination='source\tests\test_contract.py'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\test_guest_agent.py'); destination='source\tests\test_guest_agent.py'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\test_guest_protocol.py'); destination='source\tests\test_guest_protocol.py'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\test_guest_windows.py'); destination='source\tests\test_guest_windows.py'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\test_host.py'); destination='source\tests\test_host.py'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\test_host_mcp.py'); destination='source\tests\test_host_mcp.py'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\Test-PlanSafety.ps1'); destination='source\tests\Test-PlanSafety.ps1'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\Test-ProvisionSafety.ps1'); destination='source\tests\Test-ProvisionSafety.ps1'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\PayloadSafety.Tests.ps1'); destination='source\tests\PayloadSafety.Tests.ps1'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\InstallGuestPayloadDirect.Tests.ps1'); destination='source\tests\InstallGuestPayloadDirect.Tests.ps1'; kind='test-source' },
    @{ source=(Join-Path $windowsRoot 'tests\HostServiceSafety.Tests.ps1'); destination='source\tests\HostServiceSafety.Tests.ps1'; kind='test-source' },
    @{ source=(Join-Path $productRoot 'README.md'); destination='source\product\README.md'; kind='documentation' },
    @{ source=(Join-Path $productRoot 'QUICKSTART.zh-CN.md'); destination='source\product\QUICKSTART.zh-CN.md'; kind='documentation' },
    @{ source=(Join-Path $productRoot 'Build-Package.ps1'); destination='source\product\Build-Package.ps1'; kind='build-script' },
    @{ source=(Join-Path $productRoot 'Export-PublicSource.ps1'); destination='source\product\Export-PublicSource.ps1'; kind='build-script' },
    @{ source=(Join-Path $productRoot 'runtime\Product.Common.ps1'); destination='source\product\runtime\Product.Common.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Install-WindowsChannels.ps1'); destination='source\product\runtime\Install-WindowsChannels.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Start-WindowsChannels.ps1'); destination='source\product\runtime\Start-WindowsChannels.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Setup-WindowsChannels.ps1'); destination='source\product\runtime\Setup-WindowsChannels.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Diagnose-WindowsChannels.ps1'); destination='source\product\runtime\Diagnose-WindowsChannels.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Get-AISetup.ps1'); destination='source\product\runtime\Get-AISetup.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Invoke-WindowsChannelsMcp.ps1'); destination='source\product\runtime\Invoke-WindowsChannelsMcp.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Add-CodexMcp.ps1'); destination='source\product\runtime\Add-CodexMcp.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Import-WindowsChannelsConfig.ps1'); destination='source\product\runtime\Import-WindowsChannelsConfig.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Uninstall-WindowsChannels.ps1'); destination='source\product\runtime\Uninstall-WindowsChannels.ps1'; kind='source' },
    @{ source=(Join-Path $productRoot 'runtime\Install-Qicheng-Windows-Channels.cmd'); destination='source\product\runtime\Install-Qicheng-Windows-Channels.cmd'; kind='source' },
    @{ source=(Join-Path $productRoot 'tests\Test-ProductPackage.ps1'); destination='source\product\tests\Test-ProductPackage.ps1'; kind='test-source' },
    @{ source=(Join-Path $productRoot 'runtime\Product.Common.ps1'); destination='Product.Common.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Install-WindowsChannels.ps1'); destination='Install-WindowsChannels.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Start-WindowsChannels.ps1'); destination='Start-WindowsChannels.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Setup-WindowsChannels.ps1'); destination='Setup-WindowsChannels.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Diagnose-WindowsChannels.ps1'); destination='Diagnose-WindowsChannels.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Get-AISetup.ps1'); destination='Get-AISetup.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Invoke-WindowsChannelsMcp.ps1'); destination='Invoke-WindowsChannelsMcp.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Add-CodexMcp.ps1'); destination='Add-CodexMcp.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Import-WindowsChannelsConfig.ps1'); destination='Import-WindowsChannelsConfig.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Uninstall-WindowsChannels.ps1'); destination='Uninstall-WindowsChannels.ps1'; kind='installer-runtime' },
    @{ source=(Join-Path $productRoot 'runtime\Install-Qicheng-Windows-Channels.cmd'); destination='Install-Qicheng-Windows-Channels.cmd'; kind='installer-entry' },
    @{ source=(Join-Path $productRoot 'QUICKSTART.zh-CN.md'); destination='QUICKSTART.zh-CN.md'; kind='documentation' }
)
$themeAllowlist = @('ai-space.png','Set-WorkspaceTheme.ps1','README.md')
foreach ($themeName in $themeAllowlist) {
    $themeSource = Join-Path (Join-Path $windowsRoot 'theme') $themeName
    if (Test-Path -LiteralPath $themeSource -PathType Leaf) {
        $allowlist += @{ source=$themeSource; destination=('theme\' + $themeName); kind='theme-resource' }
        $allowlist += @{ source=$themeSource; destination=('source\theme\' + $themeName); kind='source' }
    }
}
$files = @()
foreach ($entry in $allowlist) {
    if (-not (Test-Path -LiteralPath $entry.source -PathType Leaf)) { throw "Allowlisted source missing: $($entry.source)" }
    $destination = Join-Path $output $entry.destination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $entry.source -Destination $destination
    if ($destination.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
        $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
        $utf8Bom = [System.Text.UTF8Encoding]::new($true)
        $scriptText = [System.IO.File]::ReadAllText($destination, $utf8Strict)
        [System.IO.File]::WriteAllText($destination, $scriptText, $utf8Bom)
    }
    $item = Get-Item -LiteralPath $destination
    $files += [ordered]@{ path=$entry.destination.Replace('\','/'); kind=$entry.kind; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }
}
Remove-Item -LiteralPath $privateBuild -Recurse -Force
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $windowsRoot '..\..'))
$commit = (& git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
$trackedStatus = (& git -C $repoRoot status --porcelain -- tools/windows-channels/host tools/windows-channels/viewer tools/windows-channels/product 2>$null)
$sourceManifest = [ordered]@{ schemaVersion=1; version=$Version; repositoryCommit=$commit; selectedSourceDirty=[bool]$trackedStatus; policy='Explicit source allowlist; no discovery of machine-local or private files.'; exclusions=@('tokens','accounts','VM disks','ISO files','.local','project memory','Git history','logs'); files=@($files | Where-Object { $_.kind -ne 'built-executable' }) }
$sourceManifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $output 'SOURCE-MANIFEST.json') -Encoding UTF8
$sourceItem = Get-Item -LiteralPath (Join-Path $output 'SOURCE-MANIFEST.json')
$files += [ordered]@{ path='SOURCE-MANIFEST.json'; kind='manifest'; bytes=$sourceItem.Length; sha256=(Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
$packageManifest = [ordered]@{ schemaVersion=1; product='Qicheng Windows Channels'; version=$Version; repositoryCommit=$commit; builtAt=(Get-Date).ToUniversalTime().ToString('o'); files=$files }
$packageManifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $output 'package-manifest.json') -Encoding UTF8
$zip = $output.TrimEnd('\') + '.zip'
if (Test-Path -LiteralPath $zip) { throw "Archive already exists: $zip" }
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal
[ordered]@{ schemaVersion=1; status='built'; version=$Version; packageDirectory=$output; archive=$zip; fileCount=$files.Count; manifestSha256=(Get-FileHash -LiteralPath (Join-Path $output 'package-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant(); sourceDirty=[bool]$trackedStatus } | ConvertTo-Json -Depth 4
