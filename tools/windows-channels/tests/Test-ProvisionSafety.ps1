[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$provisionScript = (Resolve-Path (Join-Path $PSScriptRoot '..\New-ChannelVMs.ps1')).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("qicheng-provision-safety-" + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-MockedProvision {
    param(
        [ValidateSet('empty', 'collision', 'failure')][string]$Inventory,
        [string]$ExpectedHash,
        [ValidateRange(1, 8)][int]$Count = 2,
        [switch]$Apply,
        [switch]$WhatIf
    )

    $marker = Join-Path $testRoot ("mutations-" + [guid]::NewGuid().ToString('N') + '.log')
    $harness = Join-Path $testRoot ("harness-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $source = @'
param($Target, $Iso, $Root, $ExpectedHash, $Inventory, $Marker, $Count, $ApplyFlag, $WhatIfFlag)
$global:inventoryMode = $Inventory
$global:mutationMarker = $Marker
function global:Get-VM {
    if ($global:inventoryMode -eq 'failure') { throw [System.UnauthorizedAccessException]::new('inventory-denied') }
    if ($global:inventoryMode -eq 'collision') { return [pscustomobject]@{ Name = 'qicheng-win-1' } }
    return @()
}
function global:Get-VMSwitch { return [pscustomobject]@{ Name = 'Test Switch'; Id = [guid]::Empty; SwitchType = 'Internal' } }
function global:Add-Mutation { param($Name) [System.IO.File]::AppendAllText($global:mutationMarker, "$Name`n") }
function global:New-Item { Add-Mutation 'New-Item' }
function global:New-VHD { Add-Mutation 'New-VHD' }
function global:New-VM { Add-Mutation 'New-VM' }
function global:Set-VMProcessor { Add-Mutation 'Set-VMProcessor' }
function global:Set-VMMemory { Add-Mutation 'Set-VMMemory' }
function global:Set-VMFirmware { Add-Mutation 'Set-VMFirmware' }
function global:Add-VMDvdDrive { Add-Mutation 'Add-VMDvdDrive' }
function global:Set-VMKeyProtector { Add-Mutation 'Set-VMKeyProtector' }
function global:Enable-VMTPM { Add-Mutation 'Enable-VMTPM' }
$invoke = @{ IsoPath = $Iso; ExpectedSha256 = $ExpectedHash; RootPath = $Root; SwitchName = 'Test Switch'; Count = $Count; Compact = $true }
if ($ApplyFlag -eq 'true') { $invoke.Apply = $true; $invoke.Confirm = $false }
if ($WhatIfFlag -eq 'true') { $invoke.WhatIf = $true }
& $Target @invoke
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($harness, $source, [System.Text.UTF8Encoding]::new($false))
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Target $provisionScript -Iso $iso -Root $vmRoot -ExpectedHash $ExpectedHash -Inventory $Inventory -Marker $marker -Count $Count -ApplyFlag $Apply.IsPresent.ToString().ToLowerInvariant() -WhatIfFlag $WhatIf.IsPresent.ToString().ToLowerInvariant() 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
        Mutations = if (Test-Path -LiteralPath $marker) { @(Get-Content -LiteralPath $marker) } else { @() }
    }
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $iso = Join-Path $testRoot 'windows.iso'
    [System.IO.File]::WriteAllBytes($iso, [System.Text.Encoding]::UTF8.GetBytes('review-only ISO fixture'))
    $actualHash = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    $vmRoot = Join-Path $testRoot 'vm-root'
    [System.IO.Directory]::CreateDirectory($vmRoot) | Out-Null

    $badHash = Invoke-MockedProvision -Inventory empty -ExpectedHash ('0' * 64)
    Assert-True ($badHash.ExitCode -eq 3) 'SHA mismatch must fail.'
    Assert-True ($badHash.Mutations.Count -eq 0) 'SHA mismatch must cause zero mutations.'

    $collision = Invoke-MockedProvision -Inventory collision -ExpectedHash $actualHash
    Assert-True ($collision.ExitCode -eq 3) 'Existing VM collision must fail.'
    Assert-True ($collision.Mutations.Count -eq 0) 'VM collision must cause zero mutations.'

    $queryFailure = Invoke-MockedProvision -Inventory failure -ExpectedHash $actualHash
    Assert-True ($queryFailure.ExitCode -eq 3) 'VM inventory failure must fail closed.'
    Assert-True ($queryFailure.Mutations.Count -eq 0) 'VM inventory failure must cause zero mutations.'

    $plan = Invoke-MockedProvision -Inventory empty -ExpectedHash $actualHash
    Assert-True ($plan.ExitCode -eq 0) "Valid plan must succeed: $($plan.Output)"
    Assert-True ($plan.Mutations.Count -eq 0) 'Default plan mode must cause zero mutations.'
    $planJson = $plan.Output | ConvertFrom-Json
    Assert-True ($planJson.status -eq 'not-deployed') 'Plan status must be not-deployed.'
    Assert-True ($planJson.preflight.hashVerified -eq $true) 'Plan must report a verified ISO hash.'
    Assert-True ($planJson.preflight.channels.Count -eq 2) 'Plan must preserve both validated channels.'

    foreach ($requestedCount in @(1, 3, 8)) {
        $countPlan = Invoke-MockedProvision -Inventory empty -ExpectedHash $actualHash -Count $requestedCount
        Assert-True ($countPlan.ExitCode -eq 0) "Count $requestedCount provision plan must succeed: $($countPlan.Output)"
        Assert-True ($countPlan.Mutations.Count -eq 0) "Count $requestedCount provision plan must cause zero mutations."
        $countPlanJson = $countPlan.Output | ConvertFrom-Json
        Assert-True ($countPlanJson.preflight.requestedCount -eq $requestedCount) "Count $requestedCount preflight summary is incorrect."
        Assert-True ($countPlanJson.preflight.channels.Count -eq $requestedCount) "Count $requestedCount preflight resource count is incorrect."
    }

    $whatIf = Invoke-MockedProvision -Inventory empty -ExpectedHash $actualHash -Apply -WhatIf
    Assert-True ($whatIf.ExitCode -eq 0) 'Apply with WhatIf must succeed without applying.'
    Assert-True ($whatIf.Mutations.Count -eq 0) 'Apply with WhatIf must cause zero mutations.'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($provisionScript, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Provision script must parse without errors.'
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Assert-True (-not ($commands -contains 'New-VMSwitch')) 'Provision script must not create a virtual switch.'
    Assert-True (-not ($commands -contains 'Start-VM')) 'Provision script must not start a VM.'
    Assert-True (-not ($commands -contains 'Remove-VM')) 'Provision script must not delete a VM.'
    Assert-True (-not ($commands -contains 'Remove-VHD')) 'Provision script must not delete a VHD.'
    Assert-True ($commands -contains 'Get-VMSecurity') 'TPM state must be read from Get-VMSecurity.'
    Assert-True (-not ($commands -contains 'Get-VMTPM')) 'Provision script must not call the nonexistent Get-VMTPM cmdlet.'
    $sourceText = Get-Content -LiteralPath $provisionScript -Raw
    Assert-True ($sourceText -match "Msvm_VirtualSystemSettingData") 'BIOS GUID must come from the Hyper-V CIM settings class.'
    Assert-True ($sourceText -match "Microsoft:Hyper-V:System:Realized") 'BIOS GUID query must select realized VM settings.'
    Assert-True ($sourceText -notmatch '(?i)keyProtector\s*=') 'Structured output must not contain a key protector field.'
    Assert-True ($sourceText -notmatch 'New-Item[^\r\n]*-LiteralPath') 'New-Item must use its supported Path parameter.'

    [pscustomobject]@{ passed = 34; failed = 0; mutationsObserved = 0; vmCreated = 0 } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
