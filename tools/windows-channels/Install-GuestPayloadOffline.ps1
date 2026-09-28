[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$ExpectedVMId,
    [Parameter(Mandatory = $true)][string]$PayloadDirectory,
    [Parameter(Mandatory = $true)][string]$MountWorkDirectory,
    [string]$GuestProfile,
    [switch]$Apply,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$mounted = $false
$accessPathAdded = $false
$hiveLoaded = $false
$mountPath = $null
$mountedPartition = $null
$hiveKeyName = 'QichengOffline_' + [guid]::NewGuid().ToString('N')
$shortcutTemp = $null
$installedFiles = 0

function Write-ResultAndExit { param([System.Collections.IDictionary]$Result,[int]$Code) if($Compact){$Result|ConvertTo-Json -Depth 8 -Compress}else{$Result|ConvertTo-Json -Depth 8}; exit $Code }
function Resolve-SafeHostPath { param([string]$Path,[string]$Label) if($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '(^|[\\/])\.\.([\\/]|$)'){throw "$Label must be a fully qualified local path without traversal."}; [IO.Path]::GetFullPath($Path) }
function Assert-PrivateAcl {
    param([string]$Path)
    $allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544'); $acl=Get-Acl -LiteralPath $Path
    if(-not $acl.AreAccessRulesProtected){throw "ACL inheritance is not disabled: $Path"}
    $actual=@()
    foreach($r in $acl.Access){
        if($r.AccessControlType -eq 'Deny'){throw "ACL contains a deny rule: $Path"}
        if($r.AccessControlType -eq 'Allow'){
            $sid=$r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if($sid -notin $allowed -or ($r.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl){throw "ACL grants an unapproved or non-FullControl identity: $Path"}
            $actual+=$sid
        }
    }
    if((@($actual|Sort-Object -Unique)-join',') -cne (@($allowed|Sort-Object)-join',')){throw "ACL does not resolve to the approved identities: $Path"}
}
function Set-GuestPrivateAcl {
    param([string]$Path,[string]$GuestSid)
    $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true,$false); $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($GuestSid))
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach($sidText in @($GuestSid,'S-1-5-18','S-1-5-32-544')){$rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidText),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow);[void]$acl.AddAccessRule($rule)}
    Set-Acl -LiteralPath $Path -AclObject $acl
}

try {
    if($VMName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$'){throw 'VMName is unsafe.'}
    $expectedId=[guid]::Empty; if(-not [guid]::TryParse($ExpectedVMId,[ref]$expectedId) -or $expectedId -eq [guid]::Empty){throw 'ExpectedVMId must be a nonzero UUID.'}
    $payloadRoot=Resolve-SafeHostPath $PayloadDirectory 'PayloadDirectory'; $mountWork=Resolve-SafeHostPath $MountWorkDirectory 'MountWorkDirectory'
    if($mountWork.StartsWith('C:\',[StringComparison]::OrdinalIgnoreCase)){throw 'MountWorkDirectory must not be on host C:.'}
    if(-not(Test-Path $payloadRoot -PathType Container)){throw 'PayloadDirectory does not exist.'}; if(-not(Test-Path $mountWork -PathType Container)){throw 'MountWorkDirectory does not exist.'}
    Assert-PrivateAcl $payloadRoot
    $manifestPath=Join-Path $payloadRoot 'payload-manifest.json'; if(-not(Test-Path $manifestPath -PathType Leaf)){throw 'payload-manifest.json is missing.'}
    $manifest=Get-Content $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.schemaVersion -ne 2 -or $manifest.payloadType -ne 'qicheng-windows-guest' -or $manifest.credentialMode -ne 'channel-broker-human' -or $manifest.entrypoint -ne 'Start-Channel.cmd'){throw 'Unsupported three-credential manifest.'}
    $tokenPaths=@('.local/channel.token','.local/broker.token','.local/human.token')
    if($manifest.tokenPath -cne $tokenPaths[0] -or (@($manifest.tokenPaths)-join '|') -cne ($tokenPaths-join '|')){throw 'Manifest credential paths are invalid.'}
    $bios=[guid]::Empty; if(-not[guid]::TryParse($manifest.expectedBiosUuid,[ref]$bios) -or $bios -eq [guid]::Empty){throw 'Manifest BIOS UUID is invalid.'}
    $entries=@($manifest.files); if(-not $entries.Count){throw 'Manifest is empty.'}; $seen=@{}
    foreach($entry in $entries){$rel=[string]$entry.path;if(-not$rel -or $rel -match '(^|/)\.\.(/|$)' -or $rel.StartsWith('/') -or $rel.Contains('\') -or $rel.Contains(':')){throw "Unsafe manifest path: $rel"};$key=$rel.ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate manifest path: $rel"};$seen[$key]=$true;$src=Join-Path $payloadRoot $rel.Replace('/','\');if(-not(Test-Path $src -PathType Leaf)){throw "Missing payload file: $rel"};$item=Get-Item $src;if([uint64]$item.Length-ne[uint64]$entry.sizeBytes){throw "Payload size mismatch: $rel"};if((Get-FileHash $src -Algorithm SHA256).Hash.ToUpperInvariant()-cne([string]$entry.sha256).ToUpperInvariant()){throw "Payload hash mismatch: $rel"}}
    foreach($required in @('Start-Channel.cmd','python/python.exe','python/pythonw.exe','guest/agent.py','guest/protocol.py','guest/windows.py') + $tokenPaths){if(-not $seen.ContainsKey($required.ToLowerInvariant())){throw "Manifest is missing required runtime file: $required"}}
    $seenTokenValues=@{}
    foreach($tokenPath in $tokenPaths){
        $tokenFile=Join-Path $payloadRoot $tokenPath.Replace('/','\')
        Assert-PrivateAcl $tokenFile
        $tokenText=[IO.File]::ReadAllText($tokenFile,[Text.Encoding]::ASCII)
        if($tokenText -cnotmatch '^[0-9a-f]{64}(?:\r?\n)?\z'){throw "Invalid token format: $tokenPath"}
        $tokenValue=$tokenText.Substring(0,64)
        if($seenTokenValues.ContainsKey($tokenValue)){throw 'Payload token values must be distinct.'}
        $seenTokenValues[$tokenValue]=$true
    }

    $vms=@(Get-VM -ErrorAction Stop);$match=@($vms|Where-Object Name -ieq $VMName);if($match.Count-ne1){throw "Expected one VM named $VMName."};$vm=$match[0]
    if([guid]$vm.Id-ne$expectedId){throw 'VM ID mismatch.'};if($vm.State.ToString()-ne'Off'){throw "VM must be Off; current state is $($vm.State)."}
    $biosRows=@(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData -Filter "VirtualSystemIdentifier = '$($vm.Id)'"|Where-Object{$_.VirtualSystemType-eq'Microsoft:Hyper-V:System:Realized'-and$_.BIOSGUID});if($biosRows.Count-ne1-or[guid]$biosRows[0].BIOSGUID-ne$bios){throw 'Host BIOS GUID does not match manifest.'}
    $drives=@(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop|Where-Object{$_.Path-and[IO.Path]::GetExtension($_.Path)-ieq'.vhdx'});if($drives.Count-ne1){throw "Expected exactly one attached VHDX; found $($drives.Count)."};$vhdPath=[IO.Path]::GetFullPath($drives[0].Path)
    $vhd=Get-VHD -Path $vhdPath -ErrorAction Stop;if($vhd.Attached){throw 'VHDX is already mounted on the host.'}
    $plan=[ordered]@{schemaVersion=1;status='not-installed';mode='plan';applyRequested=[bool]$Apply;vmName=$vm.Name;vmId=$vm.Id.ToString();biosGuid=$bios.ToString('D');vmState='Off';vhdPath=$vhdPath;payloadDirectory=$payloadRoot;fileCount=$entries.Count;mountWorkDirectory=$mountWork;guestProfileSelector=if($GuestProfile){$GuestProfile}else{$null};installRoot='per-user AppData\Local\Qicheng\channel';startup='per-user Startup\Qicheng Channel.lnk';agentStarted=$false;vmStartedOrStopped=$false;credentialsUsed=$false;powershellDirect=$false}
    if(-not$Apply){Write-ResultAndExit $plan 0};if(-not$PSCmdlet.ShouldProcess("$($vm.Name) [$($vm.Id)]",'Mount its sole VHDX offline and install the validated payload into one private user profile')){$plan.mode='what-if-or-declined';Write-ResultAndExit $plan 0}

    $mountPath=Join-Path $mountWork ('qicheng-offline-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $mountPath|Out-Null
    $mountedVhd=Mount-VHD -Path $vhdPath -NoDriveLetter -Passthru -ErrorAction Stop;$mounted=$true;$diskNumber=[int]$mountedVhd.DiskNumber
    $windowsPartitions=@()
    foreach($partition in @(Get-Partition -DiskNumber $diskNumber -ErrorAction Stop|Where-Object{$_.Size-gt5GB})){
        Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $mountPath -ErrorAction Stop;$accessPathAdded=$true
        if(Test-Path (Join-Path $mountPath 'Windows\System32\config\SOFTWARE') -PathType Leaf){$windowsPartitions+=$partition}
        Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $mountPath -ErrorAction Stop;$accessPathAdded=$false
    }
    if($windowsPartitions.Count-ne1){throw "Expected exactly one Windows partition; found $($windowsPartitions.Count)."};$mountedPartition=$windowsPartitions[0]
    Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $mountedPartition.PartitionNumber -AccessPath $mountPath -ErrorAction Stop;$accessPathAdded=$true
    $hiveFile=Join-Path $mountPath 'Windows\System32\config\SOFTWARE';$registryPath="Registry::HKEY_LOCAL_MACHINE\$hiveKeyName";if(Test-Path $registryPath){throw 'Temporary offline hive key already exists.'}
    & reg.exe load "HKLM\$hiveKeyName" $hiveFile *> $null;if($LASTEXITCODE-ne0){throw 'Failed to load offline SOFTWARE hive.'};$hiveLoaded=$true
    $profileRoot=Join-Path $registryPath 'Microsoft\Windows NT\CurrentVersion\ProfileList';$profiles=@()
    foreach($key in @(Get-ChildItem $profileRoot)){$sid=$key.PSChildName;if($sid-notmatch'^S-1-5-21-\d+-\d+-\d+-\d+$'){continue};$raw=[string](Get-ItemProperty $key.PSPath).ProfileImagePath;$profile=$raw.Replace('%SystemDrive%','C:');if($profile-match'^C:\\Users\\([^\\]+)$' -and $Matches[1]-notin@('defaultuser0','Default','Public','All Users','Default User')){$profiles+=[ordered]@{sid=$sid;profile=$profile}}}
    if($GuestProfile){$wanted=if($GuestProfile-match'^C:\\Users\\'){$GuestProfile}else{"C:\Users\$GuestProfile"};$profiles=@($profiles|Where-Object{$_.profile-ieq$wanted})}
    if($profiles.Count-ne1){throw "Expected exactly one eligible guest profile; found $($profiles.Count). Supply -GuestProfile after verifying the account."};$selected=$profiles[0]
    $relativeProfile=$selected.profile.Substring(3);$offlineProfile=Join-Path $mountPath $relativeProfile
    if(-not(Test-Path -LiteralPath $offlineProfile -PathType Container) -or -not(Test-Path -LiteralPath (Join-Path $offlineProfile 'NTUSER.DAT') -PathType Leaf)){throw 'Selected guest profile is absent or not initialized on the mounted VHDX.'}
    $installRoot=Join-Path $offlineProfile 'AppData\Local\Qicheng\channel';if(Test-Path $installRoot){throw 'Existing guest installation found; overwrite is refused.'}
    New-Item -ItemType Directory -Path $installRoot|Out-Null;Set-GuestPrivateAcl $installRoot $selected.sid
    foreach($entry in $entries){$src=Join-Path $payloadRoot ([string]$entry.path).Replace('/','\');$dst=Join-Path $installRoot ([string]$entry.path).Replace('/','\');$parent=Split-Path $dst -Parent;if(-not(Test-Path $parent)){New-Item -ItemType Directory -Path $parent|Out-Null};Copy-Item -LiteralPath $src -Destination $dst;$installedFiles++}
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $installRoot 'payload-manifest.json');$installedFiles++
    $startupDir=Join-Path $offlineProfile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup';if(-not(Test-Path $startupDir)){New-Item -ItemType Directory -Path $startupDir|Out-Null}
    $shortcutTemp=Join-Path $mountWork ('qicheng-'+[guid]::NewGuid().ToString('N')+'.lnk');$shell=New-Object -ComObject WScript.Shell;$lnk=$shell.CreateShortcut($shortcutTemp);$guestInstall=$selected.profile+'\AppData\Local\Qicheng\channel';$lnk.TargetPath=$guestInstall+'\python\pythonw.exe';$lnk.Arguments='-B -m guest.agent --expected-bios-uuid "'+$bios.ToString('D')+'" --token-file "'+$guestInstall+'\.local\channel.token" --broker-token-file "'+$guestInstall+'\.local\broker.token" --human-token-file "'+$guestInstall+'\.local\human.token"';$lnk.WorkingDirectory=$guestInstall;$lnk.Save();Copy-Item $shortcutTemp (Join-Path $startupDir 'Qicheng Channel.lnk')
    Write-ResultAndExit ([ordered]@{schemaVersion=1;status='installed-offline';vmName=$vm.Name;vmId=$vm.Id.ToString();guestSid=$selected.sid;guestProfile=$selected.profile;installedFiles=$installedFiles;startupInstalled=$true;agentStarted=$false;vmStartedOrStopped=$false}) 0
}
catch {Write-ResultAndExit ([ordered]@{schemaVersion=1;status=if($installedFiles){'partial-files-preserved'}else{'failed'};error=$_.Exception.Message;installedFiles=$installedFiles;recursiveCleanupAttempted=$false;agentStarted=$false;vmStartedOrStopped=$false}) 2}
finally {
    if($hiveLoaded){& reg.exe unload "HKLM\$hiveKeyName" *> $null;$hiveLoaded=$false}
    if($accessPathAdded -and $mountedPartition){Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $mountedPartition.PartitionNumber -AccessPath $mountPath -ErrorAction SilentlyContinue;$accessPathAdded=$false}
    if($mounted){Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue;$mounted=$false}
    if($shortcutTemp -and(Test-Path $shortcutTemp)){Remove-Item $shortcutTemp -Force}
    if($mountPath -and(Test-Path $mountPath) -and -not(Get-ChildItem $mountPath -Force -ErrorAction SilentlyContinue)){Remove-Item $mountPath -Force}
}
