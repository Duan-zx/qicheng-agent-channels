[CmdletBinding()]
param([string]$InstallRoot,[int]$Port=18770,[switch]$Autostart)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $InstallRoot) { $InstallRoot=(Get-TaskLeaseDefaults).InstallRoot }
$InstallRoot=Assert-TaskLeasePath $InstallRoot 'InstallRoot'
$record=Get-TaskLeaseRecord $InstallRoot
if (-not $record) { throw 'Task Lease is not installed.' }
if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port must be 1..65535.' }
Test-TaskLeasePackage $InstallRoot | Out-Null
$dataRoot=Assert-TaskLeasePath $record.dataRoot 'DataRoot'
$config=Join-Path $dataRoot 'config.json'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw "Create the private channel config first: $config" }
$credential=Join-Path $dataRoot 'broker.token'
if (-not (Test-Path -LiteralPath $credential -PathType Leaf)) { throw 'Broker credential missing.' }
if ($Autostart) {
    # In Windows PowerShell 5.1 a native stderr line becomes a terminating
    # error under Stop. Capture the complete Python traceback before checking
    # its exit code, without changing foreground behavior.
    $ErrorActionPreference='Continue'
    & $record.python -B (Join-Path $InstallRoot 'broker.py') --config $config --credential-file $credential --db (Join-Path $dataRoot 'leases.db') --port $Port 2>&1 | Out-File -LiteralPath (Join-Path $dataRoot 'broker-autostart.log') -Append -Encoding UTF8
} else {
    & $record.python -B (Join-Path $InstallRoot 'broker.py') --config $config --credential-file $credential --db (Join-Path $dataRoot 'leases.db') --port $Port
}
if ($LASTEXITCODE -ne 0) { throw "Broker exited with code $LASTEXITCODE" }
