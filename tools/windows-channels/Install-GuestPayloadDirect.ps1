[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$ExpectedVMId,
    [Parameter(Mandatory = $true)][string]$PayloadDirectory,
    [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
    [switch]$Apply,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$session = $null
$copiedFiles = 0
$installRootCreated = $false
$taskRegistered = $false
$startRequested = $false
$taskName = 'Qicheng Guest Channel'

function Write-ResultAndExit { param([System.Collections.IDictionary]$Result,[int]$Code) if($Compact){$Result|ConvertTo-Json -Depth 8 -Compress}else{$Result|ConvertTo-Json -Depth 8}; exit $Code }
function Resolve-SafePath { param([string]$Path) if($Path-notmatch'^[A-Za-z]:[\\/]'-or$Path-match'(^|[\\/])\.\.([\\/]|$)'){throw 'PayloadDirectory must be a fully qualified local path without traversal.'};[IO.Path]::GetFullPath($Path) }
function Get-ApprovedHostSids { @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544') }
function Assert-ExactEffectiveAcl {
    param([string]$Path,[switch]$RequireProtected)
    $approved=@(Get-ApprovedHostSids);$acl=Get-Acl -LiteralPath $Path
    if($RequireProtected-and-not$acl.AreAccessRulesProtected){throw "Payload root ACL inheritance is not disabled: $Path"}
    if(@($acl.Access|Where-Object AccessControlType -eq Deny).Count){throw "Payload ACL contains a deny rule: $Path"}
    $actual=@()
    foreach($rule in @($acl.Access|Where-Object AccessControlType -eq Allow)){
        $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if($sid-notin$approved-or($rule.FileSystemRights-band[Security.AccessControl.FileSystemRights]::FullControl)-ne[Security.AccessControl.FileSystemRights]::FullControl){throw "Payload ACL contains an unapproved or non-FullControl rule: $Path ; $sid"}
        $actual+=$sid
    }
    if((@($actual|Sort-Object -Unique)-join',')-cne(@($approved|Sort-Object)-join',')){throw "Payload ACL does not resolve to the approved identities: $Path"}
}
function Assert-SafeDescendant {
    param([string]$Root,[string]$Path)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([char]92);$pathFull=[IO.Path]::GetFullPath($Path);$prefix=$rootFull+[IO.Path]::DirectorySeparatorChar
    if(-not$pathFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Payload path escapes the validated root: $Path"}
    $cursor=Get-Item -LiteralPath $pathFull
    while($true){if($cursor.Attributes-band[IO.FileAttributes]::ReparsePoint){throw "Payload path chain contains a reparse point: $($cursor.FullName)"};if($cursor.FullName.TrimEnd([char]92).Equals($rootFull,[StringComparison]::OrdinalIgnoreCase)){break};$cursor=if($cursor-is[IO.DirectoryInfo]){$cursor.Parent}else{$cursor.Directory};if(-not$cursor){throw "Payload path chain did not reach root: $Path"}}
    Assert-ExactEffectiveAcl -Path $pathFull
}

try {
    if($VMName-notmatch'^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$'){throw 'VMName is unsafe.'};$expectedId=[guid]::Empty;if(-not[guid]::TryParse($ExpectedVMId,[ref]$expectedId)-or$expectedId-eq[guid]::Empty){throw 'ExpectedVMId must be a nonzero UUID.'}
    $payloadRoot=Resolve-SafePath $PayloadDirectory;if(-not(Test-Path $payloadRoot -PathType Container)){throw 'PayloadDirectory does not exist.'};Assert-ExactEffectiveAcl -Path $payloadRoot -RequireProtected
    $manifestPath=Join-Path $payloadRoot 'payload-manifest.json';if(-not(Test-Path $manifestPath -PathType Leaf)){throw 'payload-manifest.json is missing.'};Assert-SafeDescendant -Root $payloadRoot -Path $manifestPath;$manifest=Get-Content $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.schemaVersion-ne1-or$manifest.payloadType-ne'qicheng-windows-guest'){throw 'Unsupported payload manifest.'};if($manifest.entrypoint-ne'Start-Channel.cmd'-or$manifest.tokenPath-ne'.local/channel.token'){throw 'Manifest entrypoint or tokenPath is invalid.'};$bios=[guid]::Empty;if(-not[guid]::TryParse($manifest.expectedBiosUuid,[ref]$bios)-or$bios-eq[guid]::Empty){throw 'Manifest BIOS UUID is invalid.'}
    $entries=@($manifest.files);if(-not$entries.Count){throw 'Manifest is empty.'};$seen=@{}
    foreach($e in $entries){$rel=[string]$e.path;if(-not$rel-or$rel-match'(^|/)\.\.(/|$)'-or$rel.StartsWith('/')-or$rel.Contains('\')-or$rel.Contains(':')){throw "Unsafe manifest path: $rel"};$key=$rel.ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate manifest path: $rel"};$seen[$key]=$true;$src=Join-Path $payloadRoot $rel.Replace('/','\');if(-not(Test-Path $src -PathType Leaf)){throw "Missing payload file: $rel"};Assert-SafeDescendant -Root $payloadRoot -Path $src;$f=Get-Item $src;if([uint64]$f.Length-ne[uint64]$e.sizeBytes){throw "Payload size mismatch: $rel"};if((Get-FileHash $src -Algorithm SHA256).Hash.ToUpperInvariant()-cne([string]$e.sha256).ToUpperInvariant()){throw "Payload hash mismatch: $rel"}}
    foreach($required in @('Start-Channel.cmd','python/pythonw.exe','guest/agent.py','guest/protocol.py','guest/windows.py','.local/channel.token')){if(-not$seen.ContainsKey($required.ToLowerInvariant())){throw "Manifest is missing required runtime file: $required"}}
    $actual=@(Get-ChildItem $payloadRoot -Recurse -File -Force|Where-Object Name -ne 'payload-manifest.json'|ForEach-Object{$_.FullName.Substring($payloadRoot.Length).TrimStart('\','/').Replace('\','/').ToLowerInvariant()}|Sort-Object);if(($actual-join"`n")-cne(@($seen.Keys|Sort-Object)-join"`n")){throw 'Payload file set does not exactly match manifest.'}

    $inventory=@(Get-VM -ErrorAction Stop);$matches=@($inventory|Where-Object Name -ieq $VMName);if($matches.Count-ne1){throw "Expected exactly one VM named $VMName."};$vm=$matches[0];if([guid]$vm.Id-ne$expectedId){throw 'VM ID mismatch.'};if($vm.State.ToString()-ne'Running'){throw "VM must be Running; current state is $($vm.State)."}
    $rows=@(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData -Filter "VirtualSystemIdentifier = '$($vm.Id)'"|Where-Object{$_.VirtualSystemType-eq'Microsoft:Hyper-V:System:Realized'-and$_.BIOSGUID});if($rows.Count-ne1-or[guid]$rows[0].BIOSGUID-ne$bios){throw 'Host BIOS GUID does not match manifest.'}
    $plan=[ordered]@{schemaVersion=1;status='not-installed';mode='plan';applyRequested=[bool]$Apply;vmName=$vm.Name;vmId=$vm.Id.ToString();biosGuid=$bios.ToString('D');vmState='Running';payloadDirectory=$payloadRoot;fileCount=$entries.Count;transport='PowerShell Direct';credentialStored=$false;passwordStoredInTask=$false;automaticLoginConfigured=$false;existingInstallWillBeOverwritten=$false;agentStarted=$false}
    if(-not$Apply){Write-ResultAndExit $plan 0};if(-not$PSCmdlet.ShouldProcess("$($vm.Name) [$($vm.Id)]",'Install validated payload with PowerShell Direct into the authenticated user profile and register its interactive logon task')){$plan.mode='what-if-or-declined';Write-ResultAndExit $plan 0}

    $session=New-PSSession -VMId $vm.Id -Credential $Credential -ErrorAction Stop
    $identity=Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $cs=Get-CimInstance Win32_ComputerSystem;$product=Get-CimInstance Win32_ComputerSystemProduct;$wid=[Security.Principal.WindowsIdentity]::GetCurrent()
        [pscustomobject]@{model=$cs.Model;manufacturer=$cs.Manufacturer;biosUuid=$product.UUID;sid=$wid.User.Value;profile=$env:USERPROFILE;identityName=$wid.Name;interactiveUser=$cs.UserName}
    }
    if($identity.model-ne'Virtual Machine'-or$identity.manufacturer-notmatch'(?i)Microsoft'){throw 'PowerShell Direct target is not the expected Microsoft Hyper-V guest.'};if([guid]$identity.biosUuid-ne$bios){throw 'Guest BIOS UUID does not match manifest.'};if($identity.sid-notmatch'^S-1-5-21-\d+-\d+-\d+-\d+$'){throw 'Authenticated guest identity is not an explicit user SID.'};if($identity.profile-notmatch'^C:\\Users\\[^\\]+$'){throw 'Authenticated guest profile is outside C:\Users.'};if($identity.interactiveUser-ne$identity.identityName){throw 'Authenticated guest user is not the current interactive console user.'}
    $guestRoot=$identity.profile+'\AppData\Local\Qicheng\channel'
    $preflight=Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName -ScriptBlock {param($root,$task) [pscustomobject]@{rootExists=Test-Path -LiteralPath $root;taskExists=[bool](Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)}}
    if($preflight.rootExists){throw 'Existing guest installation root found; overwrite is refused.'};if($preflight.taskExists){throw 'Existing guest scheduled task found; overwrite is refused.'}
    Invoke-Command -Session $session -ArgumentList $guestRoot,$identity.sid -ScriptBlock {param($root,$sidText) New-Item -ItemType Directory -Path $root|Out-Null;$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$sid=[Security.Principal.SecurityIdentifier]::new($sidText);$acl.SetOwner($sid);$inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit';$expected=@($sidText,'S-1-5-18','S-1-5-32-544');foreach($s in $expected){$rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($s),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow');[void]$acl.AddAccessRule($rule)};Set-Acl $root $acl;$check=Get-Acl $root;$ownerSid=([Security.Principal.NTAccount]$check.Owner).Translate([Security.Principal.SecurityIdentifier]).Value;if(-not$check.AreAccessRulesProtected-or$ownerSid-ne$sidText){throw 'Guest install ACL owner or inheritance verification failed.'};$actual=@($check.Access|Where-Object AccessControlType -eq Allow|ForEach-Object{$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value}|Sort-Object -Unique);if(($actual-join',')-cne(@($expected|Sort-Object)-join',')){throw 'Guest install ACL allow-list verification failed.'}};$installRootCreated=$true
    foreach($e in $entries){$rel=([string]$e.path).Replace('/','\');$parent=[IO.Path]::GetDirectoryName($guestRoot+'\'+$rel);Invoke-Command -Session $session -ArgumentList $parent -ScriptBlock{param($p)if(-not(Test-Path $p)){New-Item -ItemType Directory -Path $p|Out-Null}};Copy-Item -LiteralPath (Join-Path $payloadRoot $rel) -Destination ($guestRoot+'\'+$rel) -ToSession $session;$copiedFiles++}
    Copy-Item -LiteralPath $manifestPath -Destination ($guestRoot+'\payload-manifest.json') -ToSession $session;$copiedFiles++
    Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {param($root)$m=Get-Content ($root+'\payload-manifest.json')-Raw|ConvertFrom-Json;foreach($e in $m.files){$p=$root+'\'+([string]$e.path).Replace('/','\');if(-not(Test-Path $p)-or(Get-FileHash $p -Algorithm SHA256).Hash.ToUpperInvariant()-cne([string]$e.sha256).ToUpperInvariant()){throw "Guest payload verification failed: $($e.path)"}}}
    Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName,$identity.sid,$bios.ToString('D') -ScriptBlock {param($root,$task,$sid,$uuid)$arguments='-m guest.agent --expected-bios-uuid "'+$uuid+'" --token-file "'+$root+'\.local\channel.token"';$action=New-ScheduledTaskAction -Execute ($root+'\python\pythonw.exe') -Argument $arguments -WorkingDirectory $root;$trigger=New-ScheduledTaskTrigger -AtLogOn -User $sid;$principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited;$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew;Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings|Out-Null}
    $registered=Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {param($task)[bool](Get-ScheduledTask -TaskName $task -ErrorAction Stop)}
    if(-not$registered){throw 'Scheduled task registration could not be verified.'};$taskRegistered=$true
    Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {param($task)Start-ScheduledTask -TaskName $task -ErrorAction Stop};$startRequested=$true
    Write-ResultAndExit ([ordered]@{schemaVersion=1;status='installed-and-start-requested';vmName=$vm.Name;vmId=$vm.Id.ToString();guestSid=$identity.sid;guestProfile=$identity.profile;installedFiles=$copiedFiles;taskName=$taskName;taskRegistered=$taskRegistered;startRequested=$startRequested;agentStarted=$false;passwordStoredInTask=$false;automaticLoginConfigured=$false;credentialReported=$false}) 0
}
catch {Write-ResultAndExit ([ordered]@{schemaVersion=1;status=if($installRootCreated){'partial-install-preserved'}else{'failed'};error=$_.Exception.Message;copiedFiles=$copiedFiles;taskRegistered=$taskRegistered;startRequested=$startRequested;agentStarted=$false;cleanupGuestFilesAttempted=$false;credentialReported=$false;passwordStoredInTask=$false;automaticLoginConfigured=$false}) 2}
finally {if($session){Remove-PSSession -Session $session -ErrorAction SilentlyContinue;$session=$null}}
