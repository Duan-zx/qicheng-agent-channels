[CmdletBinding()]
param([string]$PackageRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),[string]$InstallRoot,[string]$DataRoot,[string]$PythonPath,[switch]$Apply)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$defaults = Get-TaskLeaseDefaults
if (-not $InstallRoot) { $InstallRoot=$defaults.InstallRoot }
if (-not $DataRoot) { $DataRoot=$defaults.DataRoot }
$PackageRoot=Assert-TaskLeasePath $PackageRoot 'PackageRoot'
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
$DataRoot=Assert-TaskLeasePath $DataRoot 'DataRoot'
if ($InstallRoot -ieq $DataRoot -or $InstallRoot.StartsWith($DataRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $DataRoot.StartsWith($InstallRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'InstallRoot and DataRoot must be separate.' }
if ($InstallRoot.StartsWith($PackageRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $PackageRoot.StartsWith($InstallRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'PackageRoot and InstallRoot must be separate.' }
$manifest=Test-TaskLeasePackage $PackageRoot
$python=Resolve-TaskLeasePython $PythonPath
$existing=Get-TaskLeaseRecord $InstallRoot
if ((Test-Path -LiteralPath $InstallRoot) -and -not $existing) { throw 'InstallRoot exists without an install record.' }
$plan=[ordered]@{ status=if($existing){'upgrade'}else{'install'}; version=$manifest.version; installRoot=$InstallRoot; dataRoot=$DataRoot; python=$python; createsCredential= -not (Test-Path -LiteralPath (Join-Path $DataRoot 'broker.token')); preservesData=$true; applyRequested=[bool]$Apply }
if (-not $Apply) { $plan | ConvertTo-Json; return }
if ($existing) { throw 'Upgrade of an installed copy is not yet supported; uninstall the old copy while preserving data, then install the new package.' }
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
try {
    foreach ($file in $manifest.files) {
        $destination=Join-Path $InstallRoot $file.path
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PackageRoot $file.path) -Destination $destination
    }
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'package-manifest.json') -Destination (Join-Path $InstallRoot 'package-manifest.json')
    Set-TaskLeasePrivateDirectory $DataRoot
    $credential=Join-Path $DataRoot 'broker.token'
    if (-not (Test-Path -LiteralPath $credential)) {
        & $python -B (Join-Path $InstallRoot 'broker.py') --config (Join-Path $DataRoot 'config.json') --credential-file $credential --db (Join-Path $DataRoot 'leases.db') --init-credential
        if ($LASTEXITCODE -ne 0) { throw 'Credential creation failed.' }
    }
    $record=[ordered]@{ schemaVersion=1; component='qicheng-task-lease'; version=$manifest.version; dataRoot=$DataRoot; python=$python }
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot 'install.json') -Encoding UTF8
} catch {
    if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
    throw
}
$plan.status='installed'; $plan | ConvertTo-Json
