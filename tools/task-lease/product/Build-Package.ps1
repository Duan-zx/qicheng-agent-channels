[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory, [string]$Version='0.1.0')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$') { throw 'Invalid version.' }
$sourceRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Split-Path -Parent $sourceRoot
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory already exists.' }
if ($output.StartsWith($sourceRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory cannot be inside task-lease source.' }
$files = @(
    'LICENSE','README.md','broker.py','lease.py','attempt_workspace.py','bounded_action.py','reconcile_action_dirty.py','guest_bridge.py','lite_client.py',
    'windows-channels\host\__init__.py',
    'windows-channels\host\client.py',
    'windows-channels\host\lease_client.py',
    'product\README.zh-CN.md','product\Build-Package.ps1',
    'product\runtime\Common.ps1','product\runtime\Install-TaskLease.ps1',
    'product\runtime\Start-TaskLease.ps1','product\runtime\Diagnose-TaskLease.ps1',
    'product\runtime\Uninstall-TaskLease.ps1',
    'product\runtime\Install-TaskLeaseAutostart.ps1',
    'product\runtime\Run-TaskLeaseAutostart.ps1',
    'product\runtime\Uninstall-TaskLeaseAutostart.ps1',
    'product\runtime\Migrate-GuestTokens.ps1',
    'product\runtime\Migrate-GuestTokens.py'
)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$manifestFiles = foreach ($relative in $files) {
    $source = if ($relative.StartsWith('windows-channels\host\',[StringComparison]::Ordinal)) {
        Join-Path $toolsRoot $relative
    } else {
        Join-Path $sourceRoot $relative
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing allowlisted file: $relative" }
    $destination = Join-Path $output $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
    [ordered]@{ path=$relative.Replace('\','/'); sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$manifest = [ordered]@{ schemaVersion=1; component='qicheng-task-lease'; version=$Version; files=@($manifestFiles) }
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'package-manifest.json') -Encoding UTF8
$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) { throw 'Output zip already exists.' }
Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip -CompressionLevel Optimal
[pscustomobject]@{ packageRoot=$output; zip=$zip; version=$Version; files=$files.Count } | ConvertTo-Json
