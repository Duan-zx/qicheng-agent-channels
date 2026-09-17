[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$productRoot = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $productRoot '..\..\..'))
if ($OutputDirectory -notmatch '^[A-Za-z]:[\\/]') { throw 'OutputDirectory must be a fully qualified local-drive path.' }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($output.StartsWith($repoRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Public source export must be outside the private repository.' }
if (-not (Test-Path -LiteralPath $output -PathType Container)) { throw 'OutputDirectory must already exist as an empty directory.' }
if (@(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) { throw 'OutputDirectory must be empty.' }

$module = 'tools/windows-channels'
$allowlist = @(
    'ARCHITECTURE.md',
    'LICENSE',
    'README.md',
    'Test-Host.ps1',
    'Prepare-Channels.ps1',
    'New-ChannelVMs.ps1',
    'Register-HostService.ps1',
    'Build-GuestPayload.ps1',
    'Install-GuestPayloadDirect.ps1',
    'host/__init__.py',
    'host/client.py',
    'host/mcp.py',
    'host/README.md',
    'guest/__init__.py',
    'guest/agent.py',
    'guest/protocol.py',
    'guest/windows.py',
    'guest/README.md',
    'viewer/Viewer.cs',
    'viewer/Build.ps1',
    'viewer/app.manifest',
    'viewer/README.md',
    'tests/test_contract.py',
    'tests/test_guest_agent.py',
    'tests/test_guest_protocol.py',
    'tests/test_guest_windows.py',
    'tests/test_host.py',
    'tests/test_host_mcp.py',
    'tests/Test-PlanSafety.ps1',
    'tests/Test-ProvisionSafety.ps1',
    'tests/PayloadSafety.Tests.ps1',
    'tests/InstallGuestPayloadDirect.Tests.ps1',
    'tests/HostServiceSafety.Tests.ps1',
    'product/README.md',
    'product/QUICKSTART.zh-CN.md',
    'product/Build-Package.ps1',
    'product/Export-PublicSource.ps1',
    'product/runtime/Product.Common.ps1',
    'product/runtime/Install-WindowsChannels.ps1',
    'product/runtime/Start-WindowsChannels.ps1',
    'product/runtime/Setup-WindowsChannels.ps1',
    'product/runtime/Diagnose-WindowsChannels.ps1',
    'product/runtime/Get-AISetup.ps1',
    'product/runtime/Invoke-WindowsChannelsMcp.ps1',
    'product/runtime/Add-CodexMcp.ps1',
    'product/runtime/Import-WindowsChannelsConfig.ps1',
    'product/runtime/Uninstall-WindowsChannels.ps1',
    'product/runtime/Install-Qicheng-Windows-Channels.cmd',
    'product/tests/Test-ProductPackage.ps1'
)
$themeAllowlist = @('theme/ai-space.png','theme/Set-WorkspaceTheme.ps1','theme/README.md')
foreach ($relative in $themeAllowlist) {
    if (Test-Path -LiteralPath (Join-Path (Join-Path $repoRoot $module) $relative) -PathType Leaf) { $allowlist += $relative }
}

$copies = @(
    [pscustomobject]@{ Source=(Join-Path (Split-Path -Parent $productRoot) 'LICENSE'); Destination='LICENSE'; Kind='repository-license' }
)
foreach ($relative in $allowlist) {
    $copies += [pscustomobject]@{ Source=(Join-Path (Join-Path $repoRoot $module) $relative); Destination=($module + '/' + $relative); Kind='source' }
}

$manifestFiles = @()
foreach ($copy in $copies) {
    if (-not (Test-Path -LiteralPath $copy.Source -PathType Leaf)) { throw "Allowlisted source is missing: $($copy.Source)" }
    $destination = Join-Path $output $copy.Destination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $copy.Source -Destination $destination
    $item = Get-Item -LiteralPath $destination
    $manifestFiles += [ordered]@{ path=$copy.Destination; kind=$copy.Kind; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$manifest = [ordered]@{ schemaVersion=1; policy='Explicit public source allowlist preserving tools/windows-channels relative structure; no private Git identity.'; excluded=@('Install-GuestPayloadOffline.ps1','Install-GuestPayload.ps1','.local','dist','PM memory','tokens','VM disks','ISO files','private Git metadata'); files=$manifestFiles }
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'PUBLIC-SOURCE-MANIFEST.json') -Encoding UTF8
[ordered]@{ schemaVersion=1; status='exported'; outputDirectory=$output; fileCount=$manifestFiles.Count; moduleRoot=(Join-Path $output $module); manifest=(Join-Path $output 'PUBLIC-SOURCE-MANIFEST.json') } | ConvertTo-Json -Depth 4
