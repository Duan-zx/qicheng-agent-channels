[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$moduleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repoRoot = [IO.Path]::GetFullPath((Join-Path $moduleRoot '..\..'))

if ($OutputDirectory -notmatch '^[A-Za-z]:[\\/]') { throw 'OutputDirectory must be a fully qualified local-drive path.' }
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if ($output.Equals($repoRoot,[StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($repoRoot.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Public source export must be outside the private repository.'
}
if (-not (Test-Path -LiteralPath $output -PathType Container)) { throw 'OutputDirectory must already exist as an empty directory.' }

# A junction can make an apparently external path point into private source.
$pathPart = $output
while ($pathPart) {
    $item = Get-Item -LiteralPath $pathPart -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'OutputDirectory path must not contain a junction or symbolic link.' }
    $parent = Split-Path -Parent $pathPart
    if (-not $parent -or $parent -eq $pathPart) { break }
    $pathPart = $parent
}
if (@(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) { throw 'OutputDirectory must be empty.' }

$taskFiles = @(
    'LICENSE', 'README.md', 'broker.py', 'lease.py', 'attempt_workspace.py', 'bounded_action.py', 'reconcile_action_dirty.py', 'guest_bridge.py', 'lite_client.py',
    'tests/test_lease.py', 'tests/test_broker.py', 'tests/test_attempt_workspace.py', 'tests/test_bounded_action.py',
    'product/README.zh-CN.md', 'product/Build-Package.ps1', 'product/Export-PublicSource.ps1',
    'product/runtime/Common.ps1', 'product/runtime/Install-TaskLease.ps1',
    'product/runtime/Start-TaskLease.ps1', 'product/runtime/Diagnose-TaskLease.ps1',
    'product/runtime/Uninstall-TaskLease.ps1',
    'product/runtime/Install-TaskLeaseAutostart.ps1',
    'product/runtime/Run-TaskLeaseAutostart.ps1',
    'product/runtime/Uninstall-TaskLeaseAutostart.ps1',
    'product/runtime/Migrate-GuestTokens.ps1',
    'product/runtime/Migrate-GuestTokens.py',
    'product/tests/Test-ProductPackage.ps1',
    'product/tests/Test-PublicSourceExport.ps1',
    'product/tests/test_guest_token_migration.py'
)
$hostFiles = @('host/__init__.py', 'host/client.py', 'host/lease_client.py')
$copies = @([pscustomobject]@{ Source=(Join-Path $moduleRoot 'LICENSE'); Destination='LICENSE'; Kind='repository-license' })
foreach ($relative in $taskFiles) {
    $copies += [pscustomobject]@{ Source=(Join-Path $moduleRoot $relative); Destination=('tools/task-lease/' + $relative); Kind='source' }
}
foreach ($relative in $hostFiles) {
    $copies += [pscustomobject]@{ Source=(Join-Path $repoRoot ('tools/windows-channels/' + $relative)); Destination=('tools/windows-channels/' + $relative); Kind='source-dependency' }
}

# Validate the complete fixed list before writing any output.
foreach ($copy in $copies) {
    if (-not (Test-Path -LiteralPath $copy.Source -PathType Leaf)) { throw "Allowlisted source is missing: $($copy.Source)" }
    $item = Get-Item -LiteralPath $copy.Source -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Allowlisted source must be a regular file: $($copy.Source)" }
}

$manifestFiles = @()
foreach ($copy in $copies) {
    $destination = Join-Path $output $copy.Destination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $copy.Source -Destination $destination
    $item = Get-Item -LiteralPath $destination
    $manifestFiles += [ordered]@{
        path=$copy.Destination; kind=$copy.Kind; bytes=$item.Length
        sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$manifest = [ordered]@{
    schemaVersion=1
    component='task-lease-public-source'
    policy='Explicit source allowlist; separate from the install package manifest and private Git identity.'
    excluded=@('private config and accounts','credentials and keys','databases','task evidence','internal project memory','Git metadata')
    files=$manifestFiles
}
$manifestPath = Join-Path $output 'PUBLIC-SOURCE-MANIFEST.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
[ordered]@{
    schemaVersion=1; status='exported'; outputDirectory=$output; fileCount=$manifestFiles.Count
    moduleRoot=(Join-Path $output 'tools/task-lease'); manifest=$manifestPath
} | ConvertTo-Json -Depth 4
