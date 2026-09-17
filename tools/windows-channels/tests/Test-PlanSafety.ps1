[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Prepare-Channels.ps1')).Path
$hostScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Test-Host.ps1')).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("qicheng-windows-channels-" + [guid]::NewGuid().ToString('N'))

function Invoke-Plan {
    param([string[]]$Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Invoke-PlanWithEmptyVMInventory {
    param([int]$Count)

    $harness = Join-Path $testRoot ("empty-inventory-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $source = @'
param($TargetScript, $Iso, $Root, $Count)
function global:Get-VM { return @() }
& $TargetScript -IsoPath $Iso -RootPath $Root -Count $Count -Compact
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($harness, $source, [System.Text.UTF8Encoding]::new($false))
    $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -TargetScript $scriptPath -Iso $iso -Root $root -Count $Count 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-WithFailedVMInventory {
    param(
        [string]$TargetScript,
        [string]$Iso,
        [string]$Root,
        [string]$Name1,
        [string]$Name2
    )

    $harness = Join-Path $testRoot ("inventory-failure-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $source = @'
param($TargetScript, $Iso, $Root, $Name1, $Name2)
function Get-VM { throw [System.UnauthorizedAccessException]::new('inventory-denied') }
if ($Iso) {
    & $TargetScript -IsoPath $Iso -RootPath $Root -VMName1 $Name1 -VMName2 $Name2 -Compact
}
else {
    & $TargetScript -VMName @($Name1, $Name2) -Compact
}
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($harness, $source, [System.Text.UTF8Encoding]::new($false))
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Iso) {
            $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -TargetScript $TargetScript -Iso $Iso -Root $Root -Name1 $Name1 -Name2 $Name2 2>&1
        }
        else {
            $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -TargetScript $TargetScript -Name1 $Name1 -Name2 $Name2 2>&1
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $iso = Join-Path $testRoot 'windows.iso'
    [System.IO.File]::WriteAllBytes($iso, [byte[]]@())
    $root = Join-Path $testRoot 'vm-root'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $names = @("qc-test-$suffix-1", "qc-test-$suffix-2")

    $valid = Invoke-Plan -Arguments @('-IsoPath', $iso, '-RootPath', $root, '-VMName1', $names[0], '-VMName2', $names[1], '-Compact')
    Assert-True ($valid.ExitCode -eq 0) "Valid review plan failed: $($valid.Output)"
    $plan = $valid.Output | ConvertFrom-Json
    Assert-True ($plan.status -eq 'not-deployed') 'Plan status must be not-deployed.'
    Assert-True ($plan.action -eq 'review-only') 'Plan action must be review-only.'
    Assert-True ($plan.hostChangesMade -eq $false) 'Plan must report that no host changes were made.'
    Assert-True ($plan.channels.Count -eq 2) 'Plan must contain exactly two channels.'
    Assert-True ($plan.channels[0].generation -eq 2) 'VM generation must be 2.'
    Assert-True ($plan.channels[0].processorCount -eq 4) 'Each VM must recommend 4 vCPU.'
    Assert-True ($plan.channels[0].startupMemoryBytes -eq 8GB) 'Each VM must recommend 8 GiB RAM.'
    Assert-True ($plan.channels[0].disk.maximumSizeBytes -eq 80GB) 'Each VM must recommend an 80 GiB disk.'
    Assert-True ([System.IO.Path]::IsPathRooted($plan.channels[0].disk.path)) 'Disk path must be absolute.'
    Assert-True (-not (Test-Path -LiteralPath $root)) 'Generating a plan must not create the VM root.'

    foreach ($requestedCount in @(1, 3, 8)) {
        $countPlanRun = Invoke-PlanWithEmptyVMInventory -Count $requestedCount
        Assert-True ($countPlanRun.ExitCode -eq 0) "Count $requestedCount plan failed: $($countPlanRun.Output)"
        $countPlan = $countPlanRun.Output | ConvertFrom-Json
        Assert-True ($countPlan.requestedCount -eq $requestedCount) "Count $requestedCount plan summary is incorrect."
        Assert-True ($countPlan.channels.Count -eq $requestedCount) "Count $requestedCount must produce exactly $requestedCount channels."
        for ($index = 0; $index -lt $requestedCount; $index++) {
            Assert-True ($countPlan.channels[$index].channel -eq ($index + 1)) "Count $requestedCount channel ordinal is incorrect."
            Assert-True ($countPlan.channels[$index].vmName -eq "qicheng-win-$($index + 1)") "Count $requestedCount VM name is incorrect."
        }
    }

    $customCountPlanRun = Invoke-Plan -Arguments @('-IsoPath', $iso, '-RootPath', $root, '-Count', 3, '-VMName1', $names[0], '-VMName2', $names[1], '-Compact')
    Assert-True ($customCountPlanRun.ExitCode -eq 0) "Custom names with Count failed: $($customCountPlanRun.Output)"
    $customCountPlan = $customCountPlanRun.Output | ConvertFrom-Json
    Assert-True ($customCountPlan.channels[0].vmName -eq $names[0]) 'VMName1 must remain compatible with Count.'
    Assert-True ($customCountPlan.channels[1].vmName -eq $names[1]) 'VMName2 must remain compatible with Count.'
    Assert-True ($customCountPlan.channels[2].vmName -eq 'qicheng-win-3') 'Count must generate names after the two compatibility parameters.'

    foreach ($invalidCount in @(0, 9)) {
        $invalidCountRun = Invoke-Plan -Arguments @('-IsoPath', $iso, '-RootPath', $root, '-Count', $invalidCount, '-Compact')
        Assert-True ($invalidCountRun.ExitCode -ne 0) "Count $invalidCount must be rejected."
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'Prepare-Channels.ps1 must parse without errors.'
    $commandNames = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    $forbiddenCommands = @('New-VM', 'New-VHD', 'Set-VM', 'Start-VM', 'New-VMSwitch', 'Enable-WindowsOptionalFeature', 'Set-NetFirewallRule')
    Assert-True (-not ($commandNames | Where-Object { $_ -in $forbiddenCommands })) 'Review-only script contains a forbidden mutating command.'
    Assert-True (@($commandNames | Where-Object { $_ -eq 'Get-VM' }).Count -eq 1) 'Prepare script must query the complete VM inventory exactly once.'

    $hostTokens = $null
    $hostParseErrors = $null
    $hostAst = [System.Management.Automation.Language.Parser]::ParseFile($hostScriptPath, [ref]$hostTokens, [ref]$hostParseErrors)
    $hostCommandNames = @($hostAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Assert-True (@($hostCommandNames | Where-Object { $_ -eq 'Get-VM' }).Count -eq 1) 'Host check must query the complete VM inventory exactly once.'

    $failedPlanInventory = Invoke-WithFailedVMInventory -TargetScript $scriptPath -Iso $iso -Root $root -Name1 $names[0] -Name2 $names[1]
    Assert-True ($failedPlanInventory.ExitCode -eq 2) 'Prepare script must fail closed when VM inventory fails.'
    Assert-True ($failedPlanInventory.Output -match 'inventory failed') 'Prepare script must report VM inventory failure.'

    $failedHostInventory = Invoke-WithFailedVMInventory -TargetScript $hostScriptPath -Iso '' -Root '' -Name1 $names[0] -Name2 $names[1]
    Assert-True ($failedHostInventory.ExitCode -eq 0) "Read-only host report must remain machine-readable when VM inventory fails. Exit=$($failedHostInventory.ExitCode) Output=$($failedHostInventory.Output)"
    $failedHostReport = $failedHostInventory.Output | ConvertFrom-Json
    Assert-True ($failedHostReport.requestedVMs[0].exists -eq $null) 'Host report must use exists=null when VM inventory fails.'
    Assert-True ($failedHostReport.requestedVMs[0].queryAvailable -eq $false) 'Host report must mark failed VM inventory unavailable.'

    $missingIso = Invoke-Plan -Arguments @('-IsoPath', (Join-Path $testRoot 'missing.iso'), '-RootPath', $root, '-VMName1', $names[0], '-VMName2', $names[1])
    Assert-True ($missingIso.ExitCode -eq 2) 'Missing ISO must be rejected.'

    $sameName = Invoke-Plan -Arguments @('-IsoPath', $iso, '-RootPath', $root, '-VMName1', $names[0], '-VMName2', $names[0])
    Assert-True ($sameName.ExitCode -eq 2) 'Duplicate VM names must be rejected.'

    $generatedDuplicate = Invoke-Plan -Arguments @('-IsoPath', $iso, '-RootPath', $root, '-Count', 3, '-VMName1', 'qicheng-win-3', '-VMName2', $names[1])
    Assert-True ($generatedDuplicate.ExitCode -eq 2) 'Compatibility names must not duplicate generated VM names.'

    foreach ($unsafeName in @('..\escape', 'bad/name', '*')) {
        $unsafe = Invoke-Plan -Arguments @('-IsoPath', $iso, '-RootPath', $root, '-VMName1', $unsafeName, '-VMName2', $names[1])
        Assert-True ($unsafe.ExitCode -eq 2) "Unsafe VM name must be rejected: $unsafeName"
    }

    $driveRelative = Invoke-Plan -Arguments @('-IsoPath', 'D:relative.iso', '-RootPath', $root, '-VMName1', $names[0], '-VMName2', $names[1])
    Assert-True ($driveRelative.ExitCode -eq 2) 'Drive-relative paths must be rejected.'
    $rootRelative = Invoke-Plan -Arguments @('-IsoPath', '\root-relative.iso', '-RootPath', $root, '-VMName1', $names[0], '-VMName2', $names[1])
    Assert-True ($rootRelative.ExitCode -eq 2) 'Root-relative paths must be rejected.'

    $diskDirectory = Join-Path (Join-Path (Join-Path $root $names[0]) 'Virtual Hard Disks') ''
    New-Item -ItemType Directory -Path $diskDirectory -Force | Out-Null
    $diskPath = Join-Path $diskDirectory "$($names[0]).vhdx"
    [System.IO.File]::WriteAllBytes($diskPath, [byte[]]@())
    $collision = Invoke-Plan -Arguments @('-IsoPath', $iso, '-RootPath', $root, '-VMName1', $names[0], '-VMName2', $names[1])
    Assert-True ($collision.ExitCode -eq 2) 'Existing disk path must be rejected.'

    [pscustomobject]@{ passed = 47; failed = 0; destructiveActions = 0; vmCreated = 0 } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
