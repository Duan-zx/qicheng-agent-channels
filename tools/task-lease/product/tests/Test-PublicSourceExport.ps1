$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('TaskLeasePublicExport-' + [guid]::NewGuid().ToString('N'))))
$tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
if (-not $temp.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary test root.' }
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $output = Join-Path $temp 'public-source'
    New-Item -ItemType Directory -Path $output | Out-Null
    $result = & (Join-Path $source 'Export-PublicSource.ps1') -OutputDirectory $output | ConvertFrom-Json
    if ($result.status -ne 'exported' -or $result.fileCount -lt 20) { throw 'Export result is incomplete.' }
    $manifestPath = Join-Path $output 'PUBLIC-SOURCE-MANIFEST.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.component -ne 'task-lease-public-source' -or $manifest.files.Count -ne $result.fileCount) { throw 'Public source manifest mismatch.' }
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $manifest.files) {
        if (-not $expected.Add($file.path.Replace('/','\'))) { throw "Duplicate manifest path: $($file.path)" }
        $path = Join-Path $output $file.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing exported file: $($file.path)" }
        $actual = Get-Item -LiteralPath $path
        if ($actual.Length -ne $file.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) {
            throw "Public source hash mismatch: $($file.path)"
        }
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $output -Recurse -File | ForEach-Object { $_.FullName.Substring($output.Length).TrimStart('\') })
    foreach ($relative in $actualFiles) {
        if ($relative -ine 'PUBLIC-SOURCE-MANIFEST.json' -and -not $expected.Contains($relative)) { throw "Unexpected exported file: $relative" }
    }
    if ($actualFiles.Count -ne $expected.Count + 1) { throw 'Exported file count mismatch.' }
    foreach ($required in @('LICENSE','tools/task-lease/broker.py','tools/task-lease/attempt_workspace.py','tools/task-lease/bounded_action.py','tools/task-lease/reconcile_action_dirty.py','tools/task-lease/product/Build-Package.ps1',
            'tools/task-lease/tests/test_lease.py','tools/task-lease/tests/test_attempt_workspace.py','tools/task-lease/tests/test_bounded_action.py','tools/windows-channels/host/lease_client.py')) {
        if (-not $expected.Contains($required.Replace('/','\'))) { throw "Required source missing: $required" }
    }
    $rejected = $false
    try { & (Join-Path $source 'Export-PublicSource.ps1') -OutputDirectory $output | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'must be empty' }
    if (-not $rejected) { throw 'Nonempty output was accepted.' }
    $rejected = $false
    try { & (Join-Path $source 'Export-PublicSource.ps1') -OutputDirectory (Join-Path $source 'public-source-test') | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'outside the private repository' }
    if (-not $rejected) { throw 'Output inside private repository was accepted.' }
    $package = Join-Path $temp 'package'
    & (Join-Path $output 'tools/task-lease/product/Build-Package.ps1') -OutputDirectory $package | Out-Null
    if (-not (Test-Path -LiteralPath "$package.zip" -PathType Leaf)) { throw 'Exported tree cannot build package.' }
    $module = Join-Path $output 'tools/task-lease'
    & python.exe -B -m unittest discover -s (Join-Path $module 'tests') -p 'test_*.py'
    if ($LASTEXITCODE -ne 0) { throw 'Exported core Python tests failed.' }
    & python.exe -B -m unittest discover -s (Join-Path $module 'product/tests') -p 'test_*.py'
    if ($LASTEXITCODE -ne 0) { throw 'Exported product Python tests failed.' }
    Write-Output "PASS: $($manifest.files.Count) allowlisted files, independent SHA-256 manifest, empty/outside gates, standalone package build, exported Python tests"
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
