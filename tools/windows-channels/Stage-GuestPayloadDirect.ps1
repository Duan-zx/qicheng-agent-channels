[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VMName,
    [Parameter(Mandatory=$true)][string]$ExpectedVMId,
    [Parameter(Mandatory=$true)][string]$PayloadDirectory,
    [Parameter(Mandatory=$true)][string]$Version,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Apply,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$session = $null
$creationAttempted = $false
$existingVersionRefused = $false
$guestVersionRoot = $null
function Emit-Result([System.Collections.IDictionary]$Value, [int]$Code) {
    if ($Compact) { $Value | ConvertTo-Json -Depth 6 -Compress } else { $Value | ConvertTo-Json -Depth 6 }
    exit $Code
}
function Assert-Acl([string]$Path, [switch]$Protected) {
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $Path
    if ($Protected -and -not $acl.AreAccessRulesProtected) { throw 'Payload root ACL inheritance is enabled.' }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -eq 'Deny') { throw 'Payload contains a deny ACL rule.' }
        if ($rule.AccessControlType -eq 'Allow') {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($sid -notin $allowed) { throw 'Payload ACL grants an unapproved identity.' }
        }
    }
}
function Assert-Descendant([string]$Root, [string]$Path) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char]92)
    $cursor = [IO.Path]::GetFullPath($Path)
    if (-not $cursor.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Payload file escapes its root.' }
    while (-not $cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase)) {
        $item = Get-Item -LiteralPath $cursor -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload contains a reparse point.' }
        Assert-Acl $cursor
        $cursor = [IO.Path]::GetDirectoryName($cursor)
        if (-not $cursor) { throw 'Payload file chain does not reach root.' }
    }
}
try {
    if ($VMName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$') { throw 'Unsafe VM name.' }
    if ($Version -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' -or $Version -eq '.' -or $Version -eq '..') { throw 'Unsafe version.' }
    $vmId = [guid]::Empty
    if (-not [guid]::TryParse($ExpectedVMId, [ref]$vmId) -or $vmId -eq [guid]::Empty) { throw 'ExpectedVMId must be a nonzero UUID.' }
    if ($PayloadDirectory -notmatch '^[A-Za-z]:[\\/]' -or $PayloadDirectory -match '(^|[\\/])\.\.([\\/]|$)') { throw 'PayloadDirectory must be an absolute local drive path without traversal.' }
    $root = [IO.Path]::GetFullPath($PayloadDirectory)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Payload directory is missing.' }
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload root must not be a reparse point.' }
    Assert-Acl $root -Protected
    $manifestPath = Join-Path $root 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Payload manifest is missing.' }
    Assert-Descendant $root $manifestPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2 -or $manifest.payloadType -ne 'qicheng-windows-guest' -or $manifest.credentialMode -ne 'channel-broker-human' -or $manifest.entrypoint -ne 'Start-Channel.cmd') { throw 'Unsupported three-credential manifest.' }
    $required = @('Start-Channel.cmd','python/python.exe','python/pythonw.exe','guest/agent.py','guest/protocol.py','guest/windows.py','.local/channel.token','.local/broker.token','.local/human.token')
    $expectedTokens = @('.local/channel.token','.local/broker.token','.local/human.token')
    if ((@($manifest.tokenPaths) -join '|') -cne ($expectedTokens -join '|') -or $manifest.tokenPath -ne $expectedTokens[0]) { throw 'Manifest credential paths are invalid.' }
    $wechatConfigured = [bool]($manifest.PSObject.Properties['wechatConfigPath'])
    if ($wechatConfigured -and $manifest.wechatConfigPath -cne '.local/wechat.json') { throw 'Manifest WeChat config path is invalid.' }
    $bios = [guid]::Empty
    if (-not [guid]::TryParse($manifest.expectedBiosUuid, [ref]$bios) -or $bios -eq [guid]::Empty) { throw 'Manifest BIOS UUID is invalid.' }
    $entries = @($manifest.files)
    if (-not $entries.Count) { throw 'Manifest file inventory is empty.' }
    $seen = @{}
    foreach ($entry in $entries) {
        $relative = [string]$entry.path
        if ($relative -notmatch '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' -or $relative -match '(^|/)\.\.?(\/|$)') { throw 'Manifest contains an unsafe path.' }
        $key = $relative.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw 'Manifest contains a duplicate path.' }
        $seen[$key] = $true
        $path = Join-Path $root $relative.Replace('/','\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing payload file: $relative" }
        Assert-Descendant $root $path
        if ([uint64](Get-Item -LiteralPath $path).Length -ne [uint64]$entry.sizeBytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne ([string]$entry.sha256).ToUpperInvariant()) { throw "Payload hash or size mismatch: $relative" }
    }
    foreach ($relative in $required) { if (-not $seen.ContainsKey($relative.ToLowerInvariant())) { throw "Missing required payload file: $relative" } }
    if ($wechatConfigured -and -not $seen.ContainsKey('.local/wechat.json')) { throw 'Manifest is missing WeChat config.' }
    if (-not $wechatConfigured -and $seen.ContainsKey('.local/wechat.json')) { throw 'Unconfigured WeChat config is present.' }
    if ($wechatConfigured) {
        $configPath = Join-Path $root '.local\wechat.json'
        if ((Get-Item -LiteralPath $configPath).Length -gt 4096) { throw 'WeChat config is too large.' }
        if (-not (Get-Acl -LiteralPath $configPath).AreAccessRulesProtected) { throw 'WeChat config ACL inheritance is enabled.' }
    }
    $actual = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object { $_.FullName -ne $manifestPath })
    if ($actual.Count -ne $entries.Count) { throw 'Payload includes files outside its manifest.' }
    $startText = Get-Content -LiteralPath (Join-Path $root 'Start-Channel.cmd') -Raw -Encoding ASCII
    foreach ($flag in @('--token-file','--broker-token-file','--human-token-file')) { if (-not $startText.Contains($flag)) { throw 'Start command omits a required credential argument.' } }
    if ($startText.Contains('--wechat-config-file') -ne $wechatConfigured) { throw 'Start command and manifest disagree about WeChat config.' }
    if ($wechatConfigured -and -not $startText.Contains('--wechat-config-file "%~dp0.local\wechat.json"')) { throw 'Start command has an unsafe WeChat config path.' }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.Id -ne $vmId -or $vm.State -ne 'Running') { throw 'Host VM ID or running state does not match.' }
    $settings = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_VirtualSystemSettingData -Filter "VirtualSystemIdentifier='$($vm.Id)'" -ErrorAction Stop | Where-Object VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized')
    if ($settings.Count -ne 1 -or [guid]$settings[0].BIOSGUID -ne $bios) { throw 'Host realized BIOS UUID does not match manifest.' }
    $plan = [ordered]@{schemaVersion=1;status='validated-stage-plan';vmName=$vm.Name;vmId=$vm.Id.ToString();expectedBiosUuid=$bios.ToString('D');version=$Version;fileCount=$entries.Count;existingTaskUnchanged=$true;agentStarted=$false;credentialReported=$false}
    if (-not $Apply) { Emit-Result $plan 0 }
    if (-not $Credential) { throw 'Apply requires an in-memory PSCredential.' }
    $session = New-PSSession -VMId $vm.Id -Credential $Credential -ErrorAction Stop
    $identity = Invoke-Command -Session $session -ScriptBlock {
        $cs = Get-CimInstance Win32_ComputerSystem
        $product = Get-CimInstance Win32_ComputerSystemProduct
        $user = [Security.Principal.WindowsIdentity]::GetCurrent()
        [pscustomobject]@{model=$cs.Model;manufacturer=$cs.Manufacturer;biosUuid=$product.UUID;sid=$user.User.Value;profile=$env:USERPROFILE;identityName=$user.Name;interactiveUser=$cs.UserName}
    }
    if ($identity.model -ne 'Virtual Machine' -or $identity.manufacturer -notmatch '(?i)Microsoft' -or [guid]$identity.biosUuid -ne $bios) { throw 'PowerShell Direct target guest identity does not match.' }
    if ($identity.sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $identity.profile -notmatch '^C:\\Users\\[^\\]+$' -or $identity.interactiveUser -ne $identity.identityName) { throw 'Authenticated guest user is not the interactive profile owner.' }
    $guestVersionRoot = $identity.profile + '\AppData\Local\Qicheng\channel\versions\' + $Version
    $preflight = Invoke-Command -Session $session -ArgumentList $guestVersionRoot -ScriptBlock {
        param($destination)
        $cursor = [IO.Path]::GetDirectoryName($destination)
        while ($cursor) {
            if (Test-Path -LiteralPath $cursor) {
                if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guest destination ancestry contains a reparse point.' }
            }
            $next = [IO.Path]::GetDirectoryName($cursor)
            if (-not $next -or $next -eq $cursor) { break }
            $cursor = $next
        }
        [bool](Test-Path -LiteralPath $destination)
    }
    if ($preflight) { $existingVersionRefused = $true; throw 'Version directory already exists; overwrite refused.' }
    $creationAttempted = $true
    Invoke-Command -Session $session -ArgumentList $guestVersionRoot,$identity.sid -ScriptBlock {
        param($destination,$sidText)
        if (Test-Path -LiteralPath $destination) { throw 'Version directory already exists; overwrite refused.' }
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($sidText))
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in @($sidText,'S-1-5-18','S-1-5-32-544')) {
            [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow'))
        }
        New-Item -ItemType Directory -Path $destination | Out-Null
        Set-Acl -LiteralPath $destination -AclObject $acl
        if (-not (Get-Acl -LiteralPath $destination).AreAccessRulesProtected) { throw 'Version ACL protection failed.' }
    }
    foreach ($entry in $entries) {
        $relative = ([string]$entry.path).Replace('/','\')
        $remote = $guestVersionRoot + '\' + $relative
        Invoke-Command -Session $session -ArgumentList ([IO.Path]::GetDirectoryName($remote)) -ScriptBlock { param($parent) if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null } }
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $remote -ToSession $session -ErrorAction Stop
    }
    Copy-Item -LiteralPath $manifestPath -Destination ($guestVersionRoot + '\payload-manifest.json') -ToSession $session -ErrorAction Stop
    Invoke-Command -Session $session -ArgumentList $guestVersionRoot,$identity.sid,$wechatConfigured -ScriptBlock {
        param($destination,$sidText,$hasWechatConfig)
        if ($hasWechatConfig) {
            $wechatFile = $destination + '\.local\wechat.json'
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.SetAccessRuleProtection($true,$false)
            $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($sidText))
            foreach ($sid in @($sidText,'S-1-5-18','S-1-5-32-544')) {
                [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,'Allow'))
            }
            Set-Acl -LiteralPath $wechatFile -AclObject $acl
            if (-not (Get-Acl -LiteralPath $wechatFile).AreAccessRulesProtected) { throw 'Guest WeChat config ACL protection failed.' }
        }
        $allowed = @($sidText,'S-1-5-18','S-1-5-32-544')
        function Assert-GuestPath([string]$Path,[string]$Root,[string[]]$Approved) {
            $cursor = [IO.Path]::GetFullPath($Path)
            $rootFull = [IO.Path]::GetFullPath($Root)
            if (-not $cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -and -not $cursor.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Guest file escaped version root.' }
            while ($cursor) {
                if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guest version path contains a reparse point.' }
                if ($cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -or $cursor.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) {
                    $acl = Get-Acl -LiteralPath $cursor
                    if ($cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -and -not $acl.AreAccessRulesProtected) { throw 'Guest version ACL inheritance is enabled.' }
                    foreach ($rule in $acl.Access) {
                        if ($rule.AccessControlType -eq 'Deny') { throw 'Guest version ACL contains a deny rule.' }
                        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $Approved) { throw 'Guest version ACL grants an unapproved identity.' }
                    }
                }
                $next = [IO.Path]::GetDirectoryName($cursor)
                if (-not $next -or $next -eq $cursor) { break }
                $cursor = $next
            }
        }
        $m = Get-Content -LiteralPath ($destination + '\payload-manifest.json') -Raw | ConvertFrom-Json
        if ([bool]$m.PSObject.Properties['wechatConfigPath'] -ne $hasWechatConfig) { throw 'Guest WeChat config manifest changed.' }
        Assert-GuestPath -Path ($destination + '\payload-manifest.json') -Root $destination -Approved $allowed
        foreach ($entry in $m.files) {
            $file = $destination + '\' + ([string]$entry.path).Replace('/','\')
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or [uint64](Get-Item -LiteralPath $file).Length -ne [uint64]$entry.sizeBytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne ([string]$entry.sha256).ToUpperInvariant()) { throw 'Guest version file verification failed.' }
            Assert-GuestPath -Path $file -Root $destination -Approved $allowed
        }
    }
    Emit-Result ([ordered]@{schemaVersion=1;status='staged';vmId=$vm.Id.ToString();version=$Version;guestVersionDirectory=$guestVersionRoot;fileCount=$entries.Count;existingTaskUnchanged=$true;agentStarted=$false;credentialReported=$false}) 0
}
catch {
    if ($_.Exception.Message -like '*Version directory already exists; overwrite refused.*') { $existingVersionRefused = $true }
    Emit-Result ([ordered]@{schemaVersion=1;status=if($existingVersionRefused){'refused-existing-version-no-write'}elseif($creationAttempted){'partial-stage-preserved'}else{'failed-no-write'};error=$_.Exception.Message;guestVersionDirectory=$guestVersionRoot;existingTaskUnchanged=$true;agentStarted=$false;credentialReported=$false}) 2
}
finally { if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } }
