[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$Apply,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'

$serviceId = '6f3bbd64-8b13-4f20-a1c6-93f77f6ab20e'
$elementName = 'Qicheng Windows Channels'
$serviceRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices'
$servicePath = Join-Path $serviceRoot $serviceId

$exists = Test-Path -LiteralPath $servicePath -PathType Container
$existingElementName = $null

if ($exists) {
    try {
        $existingElementName = (Get-ItemProperty -LiteralPath $servicePath -Name 'ElementName' -ErrorAction Stop).ElementName
    }
    catch {
        throw "The Hyper-V service GUID already exists without the expected ElementName; refusing to modify it."
    }
    if ($existingElementName -cne $elementName) {
        throw "The Hyper-V service GUID is already owned by a different ElementName; refusing to modify it."
    }
}

$status = if ($exists) { 'registered' } else { 'not-registered' }
$action = if ($exists) { 'already-registered' } else { 'review-only' }
$hostChangesMade = $false

if ($Apply -and -not $exists) {
    if ($PSCmdlet.ShouldProcess($servicePath, "Register Hyper-V guest communication service '$elementName'")) {
        # Do not use -Force: if another process claims this GUID after the read,
        # New-Item must fail rather than opening and overwriting that key.
        New-Item -Path $servicePath -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $servicePath -Name 'ElementName' -Value $elementName `
            -PropertyType String -ErrorAction Stop | Out-Null

        $verifiedName = (Get-ItemProperty -LiteralPath $servicePath -Name 'ElementName' -ErrorAction Stop).ElementName
        if ($verifiedName -cne $elementName) {
            throw 'Hyper-V guest communication service registration verification failed.'
        }
        $status = 'registered'
        $action = 'registered'
        $hostChangesMade = $true
    }
    else {
        $action = 'what-if'
    }
}

$result = [ordered]@{
    schemaVersion = 1
    experimental = $true
    serviceId = $serviceId
    elementName = $elementName
    registryPath = $servicePath
    status = $status
    action = $action
    applyRequested = $Apply.IsPresent
    hostChangesMade = $hostChangesMade
    idempotent = $exists
    deliberatelyNotModified = @(
        'Firewall rules'
        'TCP or UDP ports'
        'Virtual machines or switches'
        'Hyper-V security settings'
        'Global host security settings'
    )
}

if ($Compact) {
    $result | ConvertTo-Json -Depth 4 -Compress
}
else {
    $result | ConvertTo-Json -Depth 4
}
