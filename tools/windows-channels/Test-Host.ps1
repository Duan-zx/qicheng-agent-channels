[CmdletBinding()]
param(
    [string[]]$VMName = @('qicheng-win-1', 'qicheng-win-2'),
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'

function Get-SafeValue {
    param([scriptblock]$Operation)

    try {
        return [ordered]@{ available = $true; value = & $Operation; error = $null }
    }
    catch {
        return [ordered]@{ available = $false; value = $null; error = $_.Exception.Message }
    }
}

$computerSystem = Get-SafeValue { Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -First 1 }
$operatingSystem = Get-SafeValue { Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -First 1 }
$processors = Get-SafeValue { @(Get-CimInstance -ClassName Win32_Processor) }
$hyperVFeature = Get-SafeValue {
    (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State.ToString()
}
$vmms = Get-SafeValue { (Get-Service -Name vmms).Status.ToString() }
$getVmCommand = Get-Command -Name Get-VM -ErrorAction SilentlyContinue
$vmInventory = $null
$vmInventoryError = $null
if ($getVmCommand) {
    try {
        $vmInventory = @(Get-VM -ErrorAction Stop)
    }
    catch {
        $vmInventoryError = $_.Exception.Message
    }
}

$vmResults = @()
foreach ($name in $VMName) {
    if (-not $getVmCommand) {
        $vmResults += [ordered]@{
            name = $name
            queryAvailable = $false
            exists = $null
            state = $null
            generation = $null
            configurationLocation = $null
            disks = @()
            error = 'Get-VM is unavailable; VM existence was not inferred.'
        }
        continue
    }

    if ($null -eq $vmInventory) {
        $vmResults += [ordered]@{
            name = $name
            queryAvailable = $false
            exists = $null
            state = $null
            generation = $null
            configurationLocation = $null
            disks = @()
            error = "Get-VM inventory failed: $vmInventoryError"
        }
        continue
    }

    try {
        $vm = @($vmInventory | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
        if (-not $vm) {
            $vmResults += [ordered]@{
                name = $name
                queryAvailable = $true
                exists = $false
                state = $null
                generation = $null
                configurationLocation = $null
                disks = @()
                error = $null
            }
            continue
        }

        $disks = @()
        try {
            $disks = @(Get-VMHardDiskDrive -VMName $name -ErrorAction Stop | ForEach-Object {
                [ordered]@{ controllerType = $_.ControllerType.ToString(); controllerNumber = $_.ControllerNumber; controllerLocation = $_.ControllerLocation; path = $_.Path }
            })
        }
        catch {
            $disks = @([ordered]@{ error = $_.Exception.Message })
        }

        $vmResults += [ordered]@{
            name = $name
            queryAvailable = $true
            exists = $true
            state = $vm.State.ToString()
            generation = $vm.Generation
            configurationLocation = $vm.ConfigurationLocation
            disks = $disks
            error = $null
        }
    }
    catch {
        $vmResults += [ordered]@{
            name = $name
            queryAvailable = $true
            exists = $null
            state = $null
            generation = $null
            configurationLocation = $null
            disks = @()
            error = $_.Exception.Message
        }
    }
}

$virtualizationFirmwareEnabled = $null
if ($processors.available -and $processors.value.Count -gt 0) {
    $virtualizationFirmwareEnabled = -not ($processors.value.VirtualizationFirmwareEnabled -contains $false)
}

$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    readOnly = $true
    host = [ordered]@{
        computerName = $env:COMPUTERNAME
        osCaption = if ($operatingSystem.available) { $operatingSystem.value.Caption } else { $null }
        osVersion = if ($operatingSystem.available) { $operatingSystem.value.Version } else { $null }
        osBuild = if ($operatingSystem.available) { $operatingSystem.value.BuildNumber } else { $null }
        architecture = if ($operatingSystem.available) { $operatingSystem.value.OSArchitecture } else { $null }
        logicalProcessors = if ($computerSystem.available) { $computerSystem.value.NumberOfLogicalProcessors } else { $null }
        totalMemoryBytes = if ($computerSystem.available) { [uint64]$computerSystem.value.TotalPhysicalMemory } else { $null }
        powershellVersion = $PSVersionTable.PSVersion.ToString()
    }
    hyperV = [ordered]@{
        optionalFeature = $hyperVFeature
        getVmAvailable = [bool]$getVmCommand
        vmManagementService = $vmms
        virtualizationFirmwareEnabled = $virtualizationFirmwareEnabled
    }
    requestedVMs = $vmResults
}

$depth = 8
if ($Compact) {
    $report | ConvertTo-Json -Depth $depth -Compress
}
else {
    $report | ConvertTo-Json -Depth $depth
}
