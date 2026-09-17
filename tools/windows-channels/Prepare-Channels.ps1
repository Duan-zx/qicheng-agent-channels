[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [string]$RootPath = 'D:\Hyper-V\qicheng-channels',
    [string]$VMName1 = 'qicheng-win-1',
    [string]$VMName2 = 'qicheng-win-2',
    [ValidateRange(1, 8)]
    [int]$Count = 2,
    [string]$PlanPath,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Path must be a fully qualified local drive path: $Path"
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-SafeVMName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$') {
        throw "VM name must be 1-40 characters using only letters, digits, underscore, and hyphen: $Name"
    }
    if ($Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        throw "VM name is a reserved Windows device name: $Name"
    }
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $rootPrefix = $Root.TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $Child.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Target path escapes the requested root: $Child"
    }
}

try {
    $vmNames = @(for ($index = 1; $index -le $Count; $index++) {
        if ($index -eq 1) { $VMName1 }
        elseif ($index -eq 2) { $VMName2 }
        else { "qicheng-win-$index" }
    })
    if ($vmNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }) {
        throw 'VM names must not be empty.'
    }
    if (@($vmNames | Sort-Object -Unique).Count -ne $vmNames.Count) {
        throw 'VM names must be distinct.'
    }
    foreach ($name in $vmNames) {
        Assert-SafeVMName -Name $name
    }

    $resolvedIso = Resolve-AbsolutePath -Path $IsoPath
    if (-not (Test-Path -LiteralPath $resolvedIso -PathType Leaf)) {
        throw "ISO file does not exist: $resolvedIso"
    }
    if ([System.IO.Path]::GetExtension($resolvedIso) -ine '.iso') {
        throw "Installation media must have an .iso extension: $resolvedIso"
    }

    $resolvedRoot = Resolve-AbsolutePath -Path $RootPath
    $getVmCommand = Get-Command -Name Get-VM -ErrorAction SilentlyContinue
    if (-not $getVmCommand) {
        throw 'Get-VM is unavailable, so existing VM names cannot be checked safely.'
    }
    try {
        $vmInventory = @(Get-VM -ErrorAction Stop)
    }
    catch {
        throw "Get-VM inventory failed; refusing to plan against an unknown VM inventory: $($_.Exception.Message)"
    }

    $channels = @()
    foreach ($name in $vmNames) {
        if ($vmInventory | Where-Object { $_.Name -ieq $name }) {
            throw "VM name already exists: $name"
        }

        $vmRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $name))
        $configurationPath = [System.IO.Path]::GetFullPath((Join-Path $vmRoot 'Virtual Machines'))
        $diskPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $vmRoot 'Virtual Hard Disks') "$name.vhdx"))
        Assert-ChildPath -Root $resolvedRoot -Child $vmRoot
        Assert-ChildPath -Root $resolvedRoot -Child $configurationPath
        Assert-ChildPath -Root $resolvedRoot -Child $diskPath

        foreach ($candidate in @($diskPath, $configurationPath, $vmRoot)) {
            if (Test-Path -LiteralPath $candidate) {
                throw "Target path already exists: $candidate"
            }
        }

        $channels += [ordered]@{
            channel = $channels.Count + 1
            vmName = $name
            generation = 2
            processorCount = 4
            startupMemoryBytes = 8GB
            dynamicMemory = $false
            disk = [ordered]@{
                path = $diskPath
                type = 'dynamic'
                maximumSizeBytes = 80GB
            }
            configurationPath = $configurationPath
            installationMedia = $resolvedIso
            networkSwitch = $null
            state = 'not-deployed'
        }
    }

    $plan = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        status = 'not-deployed'
        experimental = $true
        action = 'review-only'
        hostChangesMade = $false
        rootPath = $resolvedRoot
        requestedCount = $channels.Count
        channels = $channels
        prerequisitesStillRequired = @(
            'Choose and review a Hyper-V virtual switch before deployment.',
            'Provide valid Windows licensing and complete Windows installation interactively.',
            'Verify guest login, WeChat Developer Tools, and Computer Use inside each guest.'
        )
        deliberatelyNotImplemented = @(
            'VM or virtual disk creation',
            'Windows installation or activation',
            'Guest login or application login',
            'Host virtualization or security setting changes',
            'Firewall, port, virtual switch, or network changes',
            'WeChat Developer Tools or Computer Use installation and verification'
        )
    }

    $json = if ($Compact) { $plan | ConvertTo-Json -Depth 8 -Compress } else { $plan | ConvertTo-Json -Depth 8 }
    if ($PlanPath) {
        $resolvedPlan = Resolve-AbsolutePath -Path $PlanPath
        $parent = Split-Path -Parent $resolvedPlan
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "Plan output directory does not exist: $parent"
        }
        if (Test-Path -LiteralPath $resolvedPlan) {
            throw "Plan output already exists: $resolvedPlan"
        }
        [System.IO.File]::WriteAllText($resolvedPlan, $json, [System.Text.UTF8Encoding]::new($false))
    }
    $json
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
