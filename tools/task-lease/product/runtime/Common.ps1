$ErrorActionPreference = 'Stop'
function Get-TaskLeaseDefaults {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($local)) { throw 'LocalApplicationData is unavailable.' }
    return @{ InstallRoot=(Join-Path $local 'Programs\QichengTaskLease'); DataRoot=(Join-Path $local 'Qicheng\TaskLease') }
}
function Assert-TaskLeasePath([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw "$Name must be absolute." }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Get-TaskLeaseSha256([string]$Path) {
    # Scheduled tasks run without a user profile; use .NET rather than relying
    # on Get-FileHash command discovery in a background PowerShell session.
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Test-TaskLeasePackage([string]$Root) {
    $manifestPath = Join-Path $Root 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'package-manifest.json is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.component -ne 'qicheng-task-lease') { throw 'Unsupported package manifest.' }
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $manifest.files) {
        $relative = [string]$file.path
        $parts = @($relative -split '[\\/]')
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '[:*?"<>|]' -or @($parts | Where-Object { $_ -in @('','.', '..') }).Count) { throw "Unsafe package path: $relative" }
        if (-not $expected.Add($relative.Replace('/','\'))) { throw "Duplicate package path: $relative" }
        $actual = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $actual -PathType Leaf)) { throw "Missing package file: $relative" }
        $hash = Get-TaskLeaseSha256 $actual
        if ($hash -ne ([string]$file.sha256).ToLowerInvariant()) { throw "Package hash mismatch: $relative" }
    }
    $all = @(Get-ChildItem -LiteralPath $Root -File -Recurse | ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\') } | Where-Object { $_ -ine 'package-manifest.json' -and $_ -ine 'install.json' })
    foreach ($relative in $all) { if (-not $expected.Contains($relative)) { throw "Unexpected package file: $relative" } }
    if ($all.Count -ne $expected.Count) { throw 'Package file count mismatch.' }
    return $manifest
}
function Resolve-TaskLeasePython([string]$PythonPath) {
    if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
        $path = Assert-TaskLeasePath $PythonPath 'PythonPath'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'PythonPath does not exist.' }
        $candidate = $path
    } else {
        $command = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { throw 'Python 3.10+ is required. Supply -PythonPath.' }
        $candidate = $command.Source
    }
    # Windows PowerShell 5.1 strips embedded double quotes when passing -c to
    # native executables. Keep the probe quote-free so an explicit PythonPath
    # works in the packaged installer on the target host.
    $version = & $candidate -c 'import sys; print(str(sys.version_info[0]) + chr(46) + str(sys.version_info[1]))'
    if ($LASTEXITCODE -ne 0) { throw 'Python could not run.' }
    $parts = @($version.Trim().Split('.'))
    if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 10)) { throw 'Python 3.10+ is required.' }
    return $candidate
}
function Set-TaskLeasePrivateDirectory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-TaskLeaseRecord([string]$InstallRoot) {
    $path = Join-Path $InstallRoot 'install.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.component -ne 'qicheng-task-lease' -or $record.schemaVersion -ne 1) { throw 'Invalid install record.' }
    return $record
}
