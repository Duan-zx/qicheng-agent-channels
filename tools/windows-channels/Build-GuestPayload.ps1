[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EmbeddedPythonDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$BIOSUUID,

    [Parameter(Mandatory = $true)]
    [string]$TokenFile,

    [switch]$Compact
)

$ErrorActionPreference = 'Stop'

function Resolve-SafeLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Path must be a fully qualified local drive path: $Path"
    }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Traversal segments are not allowed in paths: $Path"
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathContains {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    if ($Parent.Equals($Child, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $Parent.TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
    return $Child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SafeSourceFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)
    $reparse = @($items | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
    if ($reparse.Count -gt 0) {
        throw "Source trees must not contain reparse points: $($reparse[0].FullName)"
    }
    return @($items | Where-Object {
        -not $_.PSIsContainer -and
        $_.FullName -notmatch '([\\/])__pycache__([\\/]|$)' -and
        $_.Extension -ine '.pyc'
    })
}

function Copy-PreparedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][object[]]$Files
    )

    foreach ($file in $Files) {
        $relative = $file.FullName.Substring($SourceRoot.Length).TrimStart([char[]]@([char]92, [char]47))
        $destination = Join-Path $DestinationRoot $relative
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $destination -ErrorAction Stop
    }
}

function Get-AllowedPayloadSids {
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return @($current, 'S-1-5-18', 'S-1-5-32-544')
}

function Assert-PrivateTokenAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $allowed = @(Get-AllowedPayloadSids)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch { throw "Token ACL contains an unresolvable allowed identity: $($rule.IdentityReference)" }
        if ($sid -notin $allowed) { throw "Token ACL grants access to an unapproved identity: $sid" }
    }
}

function Set-ProtectedPayloadAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($sidText in @(Get-AllowedPayloadSids)) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
}

$outputCreated = $false
try {
    $pythonSource = Resolve-SafeLocalPath -Path $EmbeddedPythonDirectory
    $payloadRoot = Resolve-SafeLocalPath -Path $OutputDirectory
    $tokenSource = Resolve-SafeLocalPath -Path $TokenFile
    $guestSource = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'guest'))

    if (-not (Test-Path -LiteralPath $pythonSource -PathType Container)) {
        throw "Embedded Python directory does not exist: $pythonSource"
    }
    if (-not (Test-Path -LiteralPath $guestSource -PathType Container)) {
        throw "Guest source directory does not exist: $guestSource"
    }
    if (-not (Test-Path -LiteralPath $tokenSource -PathType Leaf)) {
        throw "Token file does not exist: $tokenSource"
    }
    Assert-PrivateTokenAcl -Path $tokenSource
    if (Test-Path -LiteralPath $payloadRoot) {
        throw "Output path already exists: $payloadRoot"
    }

    $outputParent = Split-Path -Parent $payloadRoot
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        throw "Output parent directory does not exist: $outputParent"
    }
    foreach ($sourceRoot in @($pythonSource, $guestSource)) {
        if ((Test-PathContains -Parent $sourceRoot -Child $payloadRoot) -or (Test-PathContains -Parent $payloadRoot -Child $sourceRoot)) {
            throw "Output and source paths must not overlap: $sourceRoot ; $payloadRoot"
        }
    }

    $parsedUuid = [guid]::Empty
    if (-not [guid]::TryParse($BIOSUUID, [ref]$parsedUuid) -or $parsedUuid -eq [guid]::Empty) {
        throw 'BIOSUUID must be a specific nonzero UUID.'
    }
    $canonicalUuid = $parsedUuid.ToString('D')

    $token = [System.IO.File]::ReadAllText($tokenSource, [System.Text.Encoding]::ASCII).Trim()
    if ($token -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Token file must contain exactly one 64-character lowercase hexadecimal token.'
    }

    $pythonExe = Join-Path $pythonSource 'python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        throw "Embedded Python must contain python.exe at its root: $pythonExe"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $pythonExe -ErrorAction Stop
    $signerText = @($signature.SignerCertificate.Subject, $signature.SignerCertificate.Issuer) -join ' '
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $signerText -notmatch '(?i)Python Software Foundation') {
        throw 'python.exe must have a valid Python Software Foundation Authenticode signature.'
    }

    $pthFiles = @(Get-ChildItem -LiteralPath $pythonSource -File -Filter 'python*._pth' -ErrorAction Stop)
    if ($pthFiles.Count -ne 1) {
        throw "Embedded Python must contain exactly one python*._pth file; found $($pthFiles.Count)."
    }
    $pthLines = @([System.IO.File]::ReadAllLines($pthFiles[0].FullName))
    $stdlibEntries = @($pthLines | Where-Object {
        $trimmed = $_.Trim()
        $trimmed -and -not $trimmed.StartsWith('#') -and $trimmed -ne '.' -and $trimmed -ne '..' -and $trimmed -ne 'import site'
    })
    if ($stdlibEntries.Count -eq 0) {
        throw 'python*._pth must retain at least one embedded standard-library entry.'
    }
    foreach ($entry in $stdlibEntries) {
        if ([System.IO.Path]::IsPathRooted($entry) -or $entry -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "python*._pth contains an unsafe standard-library entry: $entry"
        }
    }

    $licenseFiles = @(Get-ChildItem -LiteralPath $pythonSource -File -Filter 'LICENSE*' -ErrorAction Stop)
    if ($licenseFiles.Count -eq 0) {
        throw 'Embedded Python source must include its LICENSE file.'
    }

    $pythonFiles = @(Get-SafeSourceFiles -Root $pythonSource)
    $guestFiles = @(Get-SafeSourceFiles -Root $guestSource)
    if (-not ($guestFiles | Where-Object { $_.Name -eq 'agent.py' })) {
        throw 'Guest source is incomplete: agent.py is missing.'
    }

    New-Item -ItemType Directory -Path $payloadRoot -ErrorAction Stop | Out-Null
    $outputCreated = $true
    Set-ProtectedPayloadAcl -Path $payloadRoot
    $pythonDestination = Join-Path $payloadRoot 'python'
    $guestDestination = Join-Path $payloadRoot 'guest'
    $localDestination = Join-Path $payloadRoot '.local'
    New-Item -ItemType Directory -Path $pythonDestination -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $guestDestination -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $localDestination -ErrorAction Stop | Out-Null

    Copy-PreparedFiles -SourceRoot $pythonSource -DestinationRoot $pythonDestination -Files $pythonFiles
    Copy-PreparedFiles -SourceRoot $guestSource -DestinationRoot $guestDestination -Files $guestFiles

    $destinationPth = Join-Path $pythonDestination $pthFiles[0].Name
    $destinationPthLines = @([System.IO.File]::ReadAllLines($destinationPth))
    if (-not ($destinationPthLines | Where-Object { $_.Trim() -eq '..' })) {
        $destinationPthLines += '..'
    }
    [System.IO.File]::WriteAllLines($destinationPth, $destinationPthLines, [System.Text.UTF8Encoding]::new($false))

    $destinationToken = Join-Path $localDestination 'channel.token'
    [System.IO.File]::WriteAllText($destinationToken, $token + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

    $startScript = @"
@echo off
setlocal
echo [qicheng] Starting the experimental guest channel in this interactive Windows guest.
echo [qicheng] Identity and token values are configured and will not be displayed.
"%~dp0python\python.exe" -m guest.agent --expected-bios-uuid "$canonicalUuid" --token-file "%~dp0.local\channel.token" >nul 2>&1
set "CHANNEL_EXIT=%ERRORLEVEL%"
echo [qicheng] Guest channel exited with code %CHANNEL_EXIT%. Sensitive values were not logged.
exit /b %CHANNEL_EXIT%
"@
    [System.IO.File]::WriteAllText((Join-Path $payloadRoot 'Start-Channel.cmd'), $startScript, [System.Text.Encoding]::ASCII)

    $manifestFiles = @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Force | ForEach-Object {
        $relative = $_.FullName.Substring($payloadRoot.Length).TrimStart([char[]]@([char]92, [char]47)).Replace('\', '/')
        [ordered]@{
            path = $relative
            sizeBytes = [uint64]$_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        }
    } | Sort-Object { $_.path })
    $manifest = [ordered]@{
        schemaVersion = 1
        payloadType = 'qicheng-windows-guest'
        expectedBiosUuid = $canonicalUuid
        entrypoint = 'Start-Channel.cmd'
        tokenPath = '.local/channel.token'
        files = $manifestFiles
    }
    [System.IO.File]::WriteAllText((Join-Path $payloadRoot 'payload-manifest.json'), ($manifest | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

    $result = [ordered]@{
        schemaVersion = 1
        status = 'payload-prepared'
        outputDirectory = $payloadRoot
        expectedBiosUuid = $canonicalUuid
        pythonExecutable = 'python\python.exe'
        guestModule = 'guest.agent'
        tokenDestination = '.local\channel.token'
        startCommand = 'Start-Channel.cmd'
        manifest = 'payload-manifest.json'
        automaticLoginConfigured = $false
        startupTaskConfigured = $false
        agentStarted = $false
        vmChangesMade = $false
        tokenReported = $false
    }
    if ($Compact) { $result | ConvertTo-Json -Depth 4 -Compress } else { $result | ConvertTo-Json -Depth 4 }
    exit 0
}
catch {
    $result = [ordered]@{
        schemaVersion = 1
        status = if ($outputCreated) { 'partial-output-preserved' } else { 'validation-failed' }
        outputDirectory = if ($payloadRoot) { $payloadRoot } else { $null }
        error = $_.Exception.Message
        cleanupAttempted = $false
        agentStarted = $false
        vmChangesMade = $false
        tokenReported = $false
    }
    if ($Compact) { $result | ConvertTo-Json -Depth 4 -Compress } else { $result | ConvertTo-Json -Depth 4 }
    exit 2
}
