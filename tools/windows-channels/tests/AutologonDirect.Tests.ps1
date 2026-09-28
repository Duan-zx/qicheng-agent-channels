[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Enable-GuestAutologonDirect.ps1')).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('qicheng-autologon-test-' + [guid]::NewGuid().ToString('N'))
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $harness = Join-Path $temp 'harness.ps1'
    @'
param($Script,$Mode)
function global:Get-VM { [pscustomobject]@{Name='qicheng-win-1';Id=[guid]'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';State='Running'} }
function global:Get-CimInstance { [pscustomobject]@{VirtualSystemType='Microsoft:Hyper-V:System:Realized';BIOSGUID='11111111-2222-4333-8444-555555555555'} }
function global:New-PSSession { throw 'guest session must not be opened in plan or WhatIf' }
function global:Invoke-WebRequest { throw 'download must not occur in plan or WhatIf' }
$credential=[pscredential]::new('qicheng',(ConvertTo-SecureString 'test-only' -AsPlainText -Force))
$arguments=@{VMName='qicheng-win-1';ExpectedVMId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';ExpectedBiosUuid='11111111-2222-4333-8444-555555555555';Credential=$credential;Compact=$true}
if ($Mode -eq 'whatif') { $arguments.Apply=$true; $arguments.WhatIf=$true }
if ($Mode -eq 'no-eula') { $arguments.Apply=$true; $arguments.Confirm=$false }
if ($Mode -eq 'mismatch') { $arguments.ExpectedBiosUuid='99999999-2222-4333-8444-555555555555' }
& $Script @arguments
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $harness -Encoding UTF8
    $shell = (Get-Process -Id $PID).Path
    foreach ($case in @(
        @{ mode='plan'; code=0; status='not-configured-by-this-run'; changed=$false },
        @{ mode='whatif'; code=0; status='not-configured-by-this-run'; changed=$false },
        @{ mode='no-eula'; code=2; status='failed-or-unverified'; changed=$null },
        @{ mode='mismatch'; code=2; status='failed-or-unverified'; changed=$null }
    )) {
        $output = & $shell -NoProfile -File $harness -Script $scriptPath -Mode $case.mode 2>&1
        Assert-True ($LASTEXITCODE -eq $case.code) "$($case.mode) exit code mismatch: $($output -join ' ')"
        $result = ($output | Where-Object { $_ -is [string] -and $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        Assert-True ($result.status -eq $case.status) "$($case.mode) status mismatch"
        Assert-True (($output -join ' ') -notmatch 'test-only') "$($case.mode) leaked a credential"
        if ($case.mode -in @('plan','whatif')) { Assert-True ($result.guestConfigurationChanged -eq $false) "$($case.mode) reported a guest change" }
        if ($case.mode -eq 'no-eula') { Assert-True ($result.failureStage -eq 'eula-authorization') 'Apply without explicit EULA acceptance must stop before guest access' }
    }
    $source = Get-Content -LiteralPath $scriptPath -Raw
    Assert-True ($source -match 'https://download\.sysinternals\.com/files/AutoLogon\.zip') 'Official case-sensitive download URL missing'
    Assert-True ($source -match 'Get-AuthenticodeSignature') 'Authenticode verification missing'
    Assert-True ($source -match 'New-PSSession -VMId') 'PowerShell Direct must bind VM ID'
    Assert-True ($source -match 'Remove-PSSession') 'PowerShell Direct session cleanup missing'
    Assert-True ($source -notmatch 'DefaultPassword\s*=|New-ItemProperty[^\r\n]*DefaultPassword') 'Plaintext Winlogon password write found'
    # The production script exits from Write-Result inside try; verify Windows PowerShell still executes finally.
    $exitProbe = Join-Path $temp 'exit-probe.ps1'
    $marker = Join-Path $temp 'finally-ran.txt'
    @'
param($Marker)
try { exit 0 } finally { [IO.File]::WriteAllText($Marker, 'cleaned') }
'@ | Set-Content -LiteralPath $exitProbe -Encoding UTF8
    & $shell -NoProfile -File $exitProbe -Marker $marker | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($marker) -eq 'cleaned') 'Exit did not execute finally cleanup'
    [pscustomobject]@{ passed = 21; failed = 0; guestSessionsCreated = 0; guestChanges = 0; finallyCleanupVerified = $true } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
