$ErrorActionPreference = 'Stop'
$target = (Resolve-Path (Join-Path $PSScriptRoot '..\Register-HostService.ps1')).Path
$expectedId = '6f3bbd64-8b13-4f20-a1c6-93f77f6ab20e'
$expectedName = 'Qicheng Windows Channels'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("qicheng-host-service-" + [guid]::NewGuid().ToString('N'))

function Invoke-HostServiceHarness {
    param(
        [ValidateSet('absent', 'expected', 'conflict', 'missing-name')]
        [string]$Scenario,
        [switch]$Apply,
        [switch]$WhatIf
    )

    $marker = Join-Path $testRoot ("mutations-" + [guid]::NewGuid().ToString('N') + '.log')
    $harness = Join-Path $testRoot ("harness-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $source = @'
param($Target, $Scenario, $Marker, $ApplyFlag, $WhatIfFlag)
$global:hostServiceScenario = $Scenario
$global:hostServiceMarker = $Marker

function global:Test-Path {
    param($LiteralPath, $PathType)
    return $global:hostServiceScenario -ne 'absent'
}
function global:Get-ItemProperty {
    param($LiteralPath, $Name, $ErrorAction)
    if ($global:hostServiceScenario -eq 'missing-name') { throw 'missing ElementName' }
    if ($global:hostServiceScenario -eq 'conflict') {
        return [pscustomobject]@{ ElementName = 'Another Product' }
    }
    return [pscustomobject]@{ ElementName = 'Qicheng Windows Channels' }
}
function global:Add-Mutation {
    param($Value)
    [System.IO.File]::AppendAllText($global:hostServiceMarker, "$Value`n")
}
function global:New-Item {
    param($Path, $ErrorAction)
    Add-Mutation "New-Item|$Path"
    return [pscustomobject]@{}
}
function global:New-ItemProperty {
    param($LiteralPath, $Name, $Value, $PropertyType, $ErrorAction)
    Add-Mutation "New-ItemProperty|$LiteralPath|$Name|$Value|$PropertyType"
    return [pscustomobject]@{}
}

$invoke = @{ Compact = $true }
if ($ApplyFlag -eq 'true') { $invoke.Apply = $true; $invoke.Confirm = $false }
if ($WhatIfFlag -eq 'true') { $invoke.WhatIf = $true }
try {
    & $Target @invoke
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 7
}
'@
    [System.IO.File]::WriteAllText($harness, $source, [System.Text.UTF8Encoding]::new($false))
    $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness `
        -Target $target -Scenario $Scenario -Marker $marker `
        -ApplyFlag $Apply.IsPresent.ToString().ToLowerInvariant() `
        -WhatIfFlag $WhatIf.IsPresent.ToString().ToLowerInvariant() 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($output | ForEach-Object { $_.ToString() })
    $jsonLine = @($lines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($lines -join "`n")
        Json = if ($jsonLine.Count -eq 1) { $jsonLine[0] | ConvertFrom-Json } else { $null }
        Mutations = if ([System.IO.File]::Exists($marker)) { @([System.IO.File]::ReadAllLines($marker)) } else { @() }
    }
}

Describe 'Register-HostService safety' {
    BeforeAll {
        [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    }

    It 'defaults to a read-only registration plan' {
        $run = Invoke-HostServiceHarness -Scenario absent
        $run.ExitCode | Should Be 0
        $run.Json.serviceId | Should Be $expectedId
        $run.Json.elementName | Should Be $expectedName
        $run.Json.status | Should Be 'not-registered'
        $run.Json.action | Should Be 'review-only'
        $run.Json.applyRequested | Should Be $false
        $run.Json.hostChangesMade | Should Be $false
        $run.Mutations.Count | Should Be 0
    }

    It 'honors Apply WhatIf without registry writes' {
        $run = Invoke-HostServiceHarness -Scenario absent -Apply -WhatIf
        $run.ExitCode | Should Be 0
        $run.Json.action | Should Be 'what-if'
        $run.Json.applyRequested | Should Be $true
        $run.Json.hostChangesMade | Should Be $false
        $run.Mutations.Count | Should Be 0
    }

    It 'applies only the fixed GUID and ElementName when explicitly requested' {
        $run = Invoke-HostServiceHarness -Scenario absent -Apply
        $run.ExitCode | Should Be 0
        $run.Json.status | Should Be 'registered'
        $run.Json.action | Should Be 'registered'
        $run.Json.hostChangesMade | Should Be $true
        $run.Mutations.Count | Should Be 2
        $run.Mutations[0] | Should Be "New-Item|HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\$expectedId"
        $run.Mutations[1] | Should Be "New-ItemProperty|HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\$expectedId|ElementName|$expectedName|String"
    }

    It 'is idempotent for the exact existing registration' {
        $run = Invoke-HostServiceHarness -Scenario expected -Apply
        $run.ExitCode | Should Be 0
        $run.Json.status | Should Be 'registered'
        $run.Json.action | Should Be 'already-registered'
        $run.Json.idempotent | Should Be $true
        $run.Json.hostChangesMade | Should Be $false
        $run.Mutations.Count | Should Be 0
    }

    It 'refuses an existing GUID owned by another ElementName' {
        $run = Invoke-HostServiceHarness -Scenario conflict -Apply
        $run.ExitCode | Should Be 7
        $run.Output | Should Match 'different ElementName'
        $run.Mutations.Count | Should Be 0
    }

    It 'refuses an existing GUID with no readable ElementName' {
        $run = Invoke-HostServiceHarness -Scenario missing-name -Apply
        $run.ExitCode | Should Be 7
        $run.Output | Should Match 'without the expected ElementName'
        $run.Mutations.Count | Should Be 0
    }

    It 'contains no commands for network VM or global security changes' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() })
        $forbidden = @(
            'New-NetFirewallRule', 'Set-NetFirewallRule', 'Remove-NetFirewallRule',
            'New-NetIPAddress', 'Set-NetIPInterface', 'New-VMSwitch', 'Set-VMSwitch',
            'New-VM', 'Set-VM', 'Start-VM', 'Stop-VM', 'Remove-VM',
            'Enable-WindowsOptionalFeature', 'Set-ExecutionPolicy', 'Set-MpPreference'
        )
        @($commands | Where-Object { $_ -in $forbidden }).Count | Should Be 0
        @($commands | Where-Object { $_ -eq 'New-Item' }).Count | Should Be 1
        @($commands | Where-Object { $_ -eq 'New-ItemProperty' }).Count | Should Be 1
    }

    AfterAll {
        if ([System.IO.Directory]::Exists($testRoot)) {
            [System.IO.Directory]::Delete($testRoot, $true)
        }
    }
}
