[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha256,

    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$SwitchName,

    [string]$VMName1 = 'qicheng-win-1',
    [string]$VMName2 = 'qicheng-win-2',
    [ValidateRange(1, 8)]
    [int]$Count = 2,
    [switch]$Apply,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$prepareScript = Join-Path $PSScriptRoot 'Prepare-Channels.ps1'
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$stepLog = [System.Collections.Generic.List[object]]::new()
$createdResources = [System.Collections.Generic.List[object]]::new()

function Write-ResultAndExit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Result,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    $json = if ($Compact) { $Result | ConvertTo-Json -Depth 10 -Compress } else { $Result | ConvertTo-Json -Depth 10 }
    $json
    exit $ExitCode
}

function Add-Step {
    param([string]$VMName, [string]$Step, [string]$Status, [string]$Detail)

    $stepLog.Add([ordered]@{
        at = (Get-Date).ToUniversalTime().ToString('o')
        vmName = $VMName
        step = $Step
        status = $Status
        detail = $Detail
    })
}

try {
    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'ExpectedSha256 must contain exactly 64 hexadecimal characters.'
    }

    $planOutput = & $prepareScript -IsoPath $IsoPath -RootPath $RootPath -VMName1 $VMName1 -VMName2 $VMName2 -Count $Count -Compact 2>&1
    $planExitCode = $LASTEXITCODE
    if ($planExitCode -ne 0) {
        throw "Channel plan validation failed: $($planOutput -join ' ')"
    }
    try {
        $plan = ($planOutput -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Channel plan did not return valid JSON: $($_.Exception.Message)"
    }

    $actualSha256 = (Get-FileHash -LiteralPath $plan.channels[0].installationMedia -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    $expectedNormalized = $ExpectedSha256.ToUpperInvariant()
    if ($actualSha256 -cne $expectedNormalized) {
        throw "ISO SHA256 mismatch. Expected $expectedNormalized but found $actualSha256. No changes were made."
    }

    try {
        $switchInventory = @(Get-VMSwitch -ErrorAction Stop)
    }
    catch {
        throw "Hyper-V switch inventory failed; refusing to continue: $($_.Exception.Message)"
    }
    $switchMatches = @($switchInventory | Where-Object { $_.Name -ieq $SwitchName })
    if ($switchMatches.Count -ne 1) {
        throw "Exactly one existing Hyper-V switch must match '$SwitchName'; found $($switchMatches.Count)."
    }
    $selectedSwitch = $switchMatches[0]

    $preflight = [ordered]@{
        isoPath = $plan.channels[0].installationMedia
        isoSha256 = $actualSha256
        expectedSha256 = $expectedNormalized
        hashVerified = $true
        switch = [ordered]@{ name = $selectedSwitch.Name; id = $selectedSwitch.Id; switchType = $selectedSwitch.SwitchType.ToString() }
        requestedCount = $plan.channels.Count
        channels = $plan.channels
    }

    if (-not $Apply) {
        Write-ResultAndExit -ExitCode 0 -Result ([ordered]@{
            schemaVersion = 1
            startedAt = $startedAt
            completedAt = (Get-Date).ToUniversalTime().ToString('o')
            status = 'not-deployed'
            mode = 'plan'
            applyRequested = $false
            hostChangesMade = $false
            preflight = $preflight
            deliberatelyNotPerformed = @('VM or VHD creation', 'VM start', 'Windows installation or EULA acceptance', 'Guest or application login', 'Enhanced Session sharing', 'Host port, firewall, virtual switch, virtualization, or security changes')
        })
    }

    $resolvedRoot = $plan.rootPath
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "RootPath must already exist before -Apply; only dedicated VM subdirectories may be created: $resolvedRoot"
    }

    $targetSummary = ($plan.channels | ForEach-Object { $_.vmName }) -join ', '
    if (-not $PSCmdlet.ShouldProcess($targetSummary, "Create $($plan.channels.Count) off-state Hyper-V Generation 2 VM(s) and their dynamic VHDX files")) {
        Write-ResultAndExit -ExitCode 0 -Result ([ordered]@{
            schemaVersion = 1
            startedAt = $startedAt
            completedAt = (Get-Date).ToUniversalTime().ToString('o')
            status = 'not-deployed'
            mode = 'what-if-or-declined'
            applyRequested = $true
            hostChangesMade = $false
            preflight = $preflight
        })
    }

    $protectorFingerprints = [System.Collections.Generic.List[string]]::new()
    foreach ($channel in $plan.channels) {
        $vmName = $channel.vmName
        $vmRoot = Split-Path -Parent $channel.configurationPath
        $diskDirectory = Split-Path -Parent $channel.disk.path

        New-Item -ItemType Directory -Path $vmRoot -ErrorAction Stop | Out-Null
        $createdResources.Add([ordered]@{ type = 'directory'; vmName = $vmName; path = $vmRoot })
        Add-Step -VMName $vmName -Step 'create-vm-root' -Status 'succeeded' -Detail $vmRoot

        New-Item -ItemType Directory -Path $diskDirectory -ErrorAction Stop | Out-Null
        Add-Step -VMName $vmName -Step 'create-disk-directory' -Status 'succeeded' -Detail $diskDirectory

        New-VHD -Path $channel.disk.path -Dynamic -SizeBytes ([uint64]$channel.disk.maximumSizeBytes) -ErrorAction Stop | Out-Null
        $createdResources.Add([ordered]@{ type = 'vhdx'; vmName = $vmName; path = $channel.disk.path })
        Add-Step -VMName $vmName -Step 'create-vhdx' -Status 'succeeded' -Detail $channel.disk.path

        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes ([uint64]$channel.startupMemoryBytes) -VHDPath $channel.disk.path -Path $vmRoot -SwitchName $selectedSwitch.Name -ErrorAction Stop | Out-Null
        $createdResources.Add([ordered]@{ type = 'vm'; vmName = $vmName })
        Add-Step -VMName $vmName -Step 'create-vm' -Status 'succeeded' -Detail 'Generation 2; VM remains off.'

        Set-VMProcessor -VMName $vmName -Count ([int]$channel.processorCount) -ErrorAction Stop
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes ([uint64]$channel.startupMemoryBytes) -ErrorAction Stop
        Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
        Add-VMDvdDrive -VMName $vmName -Path $channel.installationMedia -ErrorAction Stop | Out-Null
        Set-VMKeyProtector -VMName $vmName -NewLocalKeyProtector -ErrorAction Stop
        Enable-VMTPM -VMName $vmName -ErrorAction Stop
        $protectorBytes = [byte[]](Get-VMKeyProtector -VMName $vmName -ErrorAction Stop)
        if ($protectorBytes.Count -eq 0) {
            throw "Local key protector verification returned no material for $vmName."
        }
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $protectorFingerprints.Add([Convert]::ToBase64String($sha256.ComputeHash($protectorBytes)))
        }
        finally {
            $sha256.Dispose()
            [Array]::Clear($protectorBytes, 0, $protectorBytes.Length)
        }
        Add-Step -VMName $vmName -Step 'configure-vm' -Status 'succeeded' -Detail '4 vCPU; 8 GiB static RAM; Secure Boot on; local vTPM protector; ISO attached.'
    }

    if (@($protectorFingerprints | Select-Object -Unique).Count -ne $plan.channels.Count) {
        throw 'Local key protectors are not unique across the requested VMs.'
    }
    $protectorFingerprints.Clear()

    $vmInventoryAfter = @(Get-VM -ErrorAction Stop)
    $provisioned = @()
    foreach ($channel in $plan.channels) {
        $vm = @($vmInventoryAfter | Where-Object { $_.Name -ieq $channel.vmName }) | Select-Object -First 1
        if (-not $vm) {
            throw "Created VM could not be found in post-create inventory: $($channel.vmName)"
        }
        if ($vm.State.ToString() -ne 'Off') {
            throw "Created VM is not off as required: $($channel.vmName) ($($vm.State))"
        }
        $firmware = Get-VMFirmware -VMName $channel.vmName -ErrorAction Stop
        $biosSettings = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_VirtualSystemSettingData -Filter "VirtualSystemIdentifier = '$($vm.Id)'" -ErrorAction Stop | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' -and -not [string]::IsNullOrWhiteSpace($_.BIOSGUID) })
        if ($biosSettings.Count -ne 1) {
            throw "Expected one BIOS GUID for $($channel.vmName), found $($biosSettings.Count)."
        }
        $security = Get-VMSecurity -VMName $channel.vmName -ErrorAction Stop
        $provisioned += [ordered]@{
            vmName = $channel.vmName
            vmId = $vm.Id.ToString()
            biosGuid = $biosSettings[0].BIOSGUID
            state = $vm.State.ToString()
            generation = $vm.Generation
            configurationPath = $channel.configurationPath
            diskPath = $channel.disk.path
            isoPath = $channel.installationMedia
            switchName = $selectedSwitch.Name
            secureBoot = $firmware.SecureBoot.ToString()
            tpmEnabled = [bool]$security.TpmEnabled
        }
    }

    Write-ResultAndExit -ExitCode 0 -Result ([ordered]@{
        schemaVersion = 1
        startedAt = $startedAt
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        status = 'created-off'
        mode = 'apply'
        applyRequested = $true
        hostChangesMade = $true
        preflight = $preflight
        provisioned = $provisioned
        steps = $stepLog
        createdResources = $createdResources
        keyProtectorMaterialReported = $false
    })
}
catch {
    Write-ResultAndExit -ExitCode 3 -Result ([ordered]@{
        schemaVersion = 1
        startedAt = $startedAt
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        status = if ($createdResources.Count -gt 0) { 'partial-failure-preserved' } else { 'preflight-failed' }
        mode = if ($Apply) { 'apply' } else { 'plan' }
        applyRequested = [bool]$Apply
        hostChangesMade = ($createdResources.Count -gt 0)
        error = $_.Exception.Message
        cleanupAttempted = $false
        recovery = if ($createdResources.Count -gt 0) { 'Created resources were preserved. Review createdResources and steps; no automatic VM or disk deletion was attempted.' } else { 'No resource creation step completed.' }
        steps = $stepLog
        createdResources = $createdResources
        keyProtectorMaterialReported = $false
    })
}
