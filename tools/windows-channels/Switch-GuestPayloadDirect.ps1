[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VMName,
    [Parameter(Mandatory=$true)][string]$ExpectedVMId,
    [Parameter(Mandatory=$true)][string]$ExpectedBiosUuid,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
    [string]$HostClientRoot,
    [string]$HostConfigPath,
    [string]$Project,
    [string]$HostPythonPath,
    [switch]$Apply,
    [switch]$Promote,
    [switch]$Rollback,
    [switch]$Compact
)

# Apply runs an untriggered candidate. Promote transfers logon ownership to it.
$ErrorActionPreference = 'Stop'
$session = $null
$transitionAttempted = $false
$promotionAttempted = $false
function Emit-Result([System.Collections.IDictionary]$Value, [int]$Code) {
    if ($Compact) { $Value | ConvertTo-Json -Depth 5 -Compress } else { $Value | ConvertTo-Json -Depth 5 }
    exit $Code
}
function Test-HostStateHandshake([string]$Python,[string]$Client,[string]$Config,[string]$ProjectName) {
    for ($attempt=0;$attempt -lt 3;$attempt++) {
        $process=$null
        try {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=$Python
            $start.Arguments='-B "' + $Client + '" --config "' + $Config + '" --project "' + $ProjectName + '" state'
            $start.UseShellExecute=$false
            $start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true
            $start.RedirectStandardError=$true
            $process=[Diagnostics.Process]::new()
            $process.StartInfo=$start
            if (-not $process.Start()) { continue }
            if (-not $process.WaitForExit(15000)) {
                try { $process.Kill() } catch {}
                [void]$process.WaitForExit(2000)
            } elseif ($process.ExitCode -eq 0) { return $true }
        } catch {} finally { if($process){$process.Dispose()} }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
try {
    if (([int][bool]$Apply + [int][bool]$Promote + [int][bool]$Rollback) -gt 1) { throw 'Apply, Promote, and Rollback are mutually exclusive.' }
    if ($VMName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$' -or $Version -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' -or $Version -in @('.','..')) { throw 'Unsafe VM name or version.' }
    $id = [guid]::Empty; $bios = [guid]::Empty
    if (-not [guid]::TryParse($ExpectedVMId,[ref]$id) -or $id -eq [guid]::Empty -or -not [guid]::TryParse($ExpectedBiosUuid,[ref]$bios) -or $bios -eq [guid]::Empty) { throw 'VM ID and BIOS UUID must be nonzero UUIDs.' }
    if ($Apply -or $Promote) {
        foreach ($path in @($HostClientRoot,$HostConfigPath,$HostPythonPath)) {
            if (-not $path -or $path -notmatch '^[A-Za-z]:[\\/]' -or $path -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Apply requires absolute local host client, config, and Python paths without traversal.' }
        }
        if ($Project -cnotmatch '^[a-z0-9][a-z0-9_-]{0,39}$') { throw 'Apply requires a safe project name.' }
        $hostClient = Join-Path ([IO.Path]::GetFullPath($HostClientRoot)) 'host\client.py'
        $hostConfig = [IO.Path]::GetFullPath($HostConfigPath)
        $hostPython = [IO.Path]::GetFullPath($HostPythonPath)
        foreach ($path in @($hostClient,$hostConfig,$hostPython)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Host handshake dependency is missing or a reparse point.' }
        }
        try {
            $config = Get-Content -LiteralPath $hostConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            $projectProperty = if ($config.projects) { $config.projects.PSObject.Properties[$Project] } else { $null }
            if ($config.schema_version -ne 1 -or -not $projectProperty -or [guid]$projectProperty.Value.vm_id -ne $id -or [guid]$projectProperty.Value.bios_uuid -ne $bios) { throw 'mismatch' }
        } catch { throw 'Host project binding validation failed.' }
    }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ([guid]$vm.Id -ne $id -or $vm.State.ToString() -ne 'Running') { throw 'VM identity or state does not match.' }
    $rows = @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData -Filter "VirtualSystemIdentifier = '$($vm.Id)'" -ErrorAction Stop | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' -and $_.BIOSGUID })
    if ($rows.Count -ne 1 -or [guid]$rows[0].BIOSGUID -ne $bios) { throw 'Host realized BIOS UUID does not match.' }
    $session = New-PSSession -VMId $vm.Id -Credential $Credential -ErrorAction Stop
    $guest = Invoke-Command -Session $session -ArgumentList $Version,$bios.ToString('D') -ScriptBlock {
        param($version,$expectedBios)
        $product = Get-CimInstance Win32_ComputerSystemProduct
        $cs = Get-CimInstance Win32_ComputerSystem
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ([guid]$product.UUID -ne [guid]$expectedBios -or $cs.Model -ne 'Virtual Machine' -or $cs.Manufacturer -notmatch '(?i)Microsoft') { throw 'Guest BIOS or manufacturer mismatch.' }
        if ($env:USERPROFILE -notmatch '^C:\\Users\\[^\\]+$' -or $cs.UserName -ne $identity.Name) { throw 'Guest interactive profile does not match credential.' }
        $root = $env:USERPROFILE + '\AppData\Local\Qicheng\channel'
        $versionRoot = $root + '\versions\' + $version
        $task = Get-ScheduledTask -TaskName 'Qicheng Guest Channel' -ErrorAction SilentlyContinue
        $candidateName = 'Qicheng Guest Channel Candidate ' + $version
        $candidate = Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue
        $otherCandidates = @(Get-ScheduledTask -TaskName 'Qicheng Guest Channel Candidate *' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -ne $candidateName })
        $manifestPath = $versionRoot + '\payload-manifest.json'
        function Test-SafeVersionPath([string]$Path,[string]$VersionRoot,[string[]]$AllowedSids) {
            $cursor = [IO.Path]::GetFullPath($Path)
            $rootFull = [IO.Path]::GetFullPath($VersionRoot)
            if (-not $cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -and -not $cursor.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
            while ($cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                if ($cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -or $cursor.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) {
                    $acl = Get-Acl -LiteralPath $cursor -ErrorAction Stop
                    if ($cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -and -not $acl.AreAccessRulesProtected) { return $false }
                    foreach ($rule in $acl.Access) {
                        if ($rule.AccessControlType -eq 'Deny') { return $false }
                        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $AllowedSids) { return $false }
                    }
                }
                $next = [IO.Path]::GetDirectoryName($cursor)
                if (-not $next -or $next -eq $cursor) { break }
                $cursor = $next
            }
            return $true
        }
        function Test-StagedVersion([string]$Path,[string]$ManifestPath,[string]$Bios,[string]$OwnerSid) {
            try {
                if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
                $allowed = @($OwnerSid,'S-1-5-18','S-1-5-32-544')
                if (-not (Test-SafeVersionPath $ManifestPath $Path $allowed)) { return $false }
                $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
                $tokens = @('.local/channel.token','.local/broker.token','.local/human.token')
                if ($manifest.schemaVersion -ne 2 -or $manifest.payloadType -ne 'qicheng-windows-guest' -or $manifest.credentialMode -ne 'channel-broker-human' -or $manifest.entrypoint -ne 'Start-Channel.cmd' -or $manifest.tokenPath -ne $tokens[0] -or (@($manifest.tokenPaths) -join '|') -cne ($tokens -join '|') -or [guid]$manifest.expectedBiosUuid -ne [guid]$Bios) { return $false }
                $wechatConfigured = [bool]$manifest.PSObject.Properties['wechatConfigPath']
                if ($wechatConfigured -and $manifest.wechatConfigPath -cne '.local/wechat.json') { return $false }
                $entries = @($manifest.files)
                if ($entries.Count -eq 0) { return $false }
                $required = @('Start-Channel.cmd','python/python.exe','python/pythonw.exe','guest/agent.py','guest/protocol.py','guest/windows.py') + $tokens
                $seen = @{}
                foreach ($entry in $entries) {
                    $relative = [string]$entry.path
                    if ($relative -notmatch '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' -or $relative -match '(^|/)\.\.?(\/|$)') { return $false }
                    $key = $relative.ToLowerInvariant()
                    if ($seen.ContainsKey($key)) { return $false }
                    $seen[$key] = $true
                    $file = $Path + '\' + $relative.Replace('/','\')
                    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or -not (Test-SafeVersionPath $file $Path $allowed)) { return $false }
                    if ([uint64](Get-Item -LiteralPath $file).Length -ne [uint64]$entry.sizeBytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne ([string]$entry.sha256).ToUpperInvariant()) { return $false }
                }
                foreach ($relative in $required) { if (-not $seen.ContainsKey($relative.ToLowerInvariant())) { return $false } }
                if ($wechatConfigured -ne $seen.ContainsKey('.local/wechat.json')) { return $false }
                if ($wechatConfigured) {
                    $wechatFile = $Path + '\.local\wechat.json'
                    if ((Get-Item -LiteralPath $wechatFile).Length -gt 4096 -or -not (Get-Acl -LiteralPath $wechatFile).AreAccessRulesProtected) { return $false }
                }
                $actual = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Where-Object { $_.FullName -ne $ManifestPath })
                if ($actual.Count -ne $entries.Count) { return $false }
                $start = Get-Content -LiteralPath ($Path + '\Start-Channel.cmd') -Raw -Encoding ASCII
                foreach ($flag in @('--token-file','--broker-token-file','--human-token-file')) { if (-not $start.Contains($flag)) { return $false } }
                if ($start.Contains('--wechat-config-file') -ne $wechatConfigured) { return $false }
                if ($wechatConfigured -and -not $start.Contains('--wechat-config-file "%~dp0.local\wechat.json"')) { return $false }
                return $true
            } catch { return $false }
        }
        $versionVerified = Test-StagedVersion $versionRoot $manifestPath $expectedBios $identity.User.Value
        $wechatConfigured = $false
        if ($versionVerified) { $wechatConfigured = [bool]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).PSObject.Properties['wechatConfigPath']) }
        $oldAction = if ($task) { @($task.Actions)[0] } else { $null }
        $oldExecutablePresent = [bool]($oldAction -and $oldAction.Execute -and (Test-Path -LiteralPath $oldAction.Execute -PathType Leaf))
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction Stop)
        $principalSid = $null
        if ($task -and $task.Principal.UserId) {
            try { $principalSid = ([Security.Principal.NTAccount]$task.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { try { $principalSid = ([Security.Principal.SecurityIdentifier]::new($task.Principal.UserId)).Value } catch {} }
        }
        [pscustomobject]@{
            taskPresent=[bool]$task
            oldActionExecutablePresent=$oldExecutablePresent
            oldActionDirectoryPresent=[bool]($oldAction -and $oldAction.WorkingDirectory -and (Test-Path -LiteralPath $oldAction.WorkingDirectory -PathType Container))
            taskActionCount=if($task){@($task.Actions).Count}else{0}
            taskState=if($task){$task.State.ToString()}else{$null}
            stagedVersionPresent=(Test-Path -LiteralPath $versionRoot -PathType Container)
            stagedVersionVerified=$versionVerified
            wechatConfigPresent=$wechatConfigured
            guestSid=$identity.User.Value
            guestProfile=$env:USERPROFILE
            oldExecutable=if($oldAction){[string]$oldAction.Execute}else{$null}
            oldTaskPrincipalValid=[bool]($principalSid -eq $identity.User.Value -and $task.Principal.LogonType.ToString() -eq 'Interactive' -and $task.Principal.RunLevel.ToString() -eq 'Limited')
            pythonwCount=$processes.Count
            pythonwPath=if($processes.Count -eq 1){[string]$processes[0].ExecutablePath}else{$null}
            candidateTaskPresent=[bool]$candidate
            candidateTaskState=if($candidate){$candidate.State.ToString()}else{$null}
            oldTaskEnabled=if($task){[bool]$task.Settings.Enabled}else{$false}
            oldLogonTriggerCount=if($task){@($task.Triggers | Where-Object { $_ -and $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count}else{0}
            oldTriggerCount=if($task){@($task.Triggers | Where-Object { $_ }).Count}else{0}
            candidateTriggerCount=if($candidate){@($candidate.Triggers | Where-Object { $_ }).Count}else{0}
            candidateTaskEnabled=if($candidate){[bool]$candidate.Settings.Enabled}else{$false}
            otherCandidateTaskCount=$otherCandidates.Count
            startupShortcutPresent=(Test-Path -LiteralPath ($env:APPDATA + '\Microsoft\Windows\Start Menu\Programs\Startup\Qicheng Channel.lnk') -PathType Leaf)
        }
    }
    $candidateName = 'Qicheng Guest Channel Candidate ' + $Version
    if ($Apply -or $Promote -or $Rollback) {
        $oldPath = [IO.Path]::GetFullPath([string]$guest.oldExecutable)
        $candidatePath = $guest.guestProfile + '\AppData\Local\Qicheng\channel\versions\' + $Version + '\python\pythonw.exe'
        $oldRoot = $guest.guestProfile + '\AppData\Local\Qicheng\channel'
        if (-not $guest.taskPresent -or $guest.taskActionCount -ne 1 -or -not $guest.oldTaskPrincipalValid -or -not $guest.oldActionExecutablePresent -or -not $guest.oldActionDirectoryPresent) { throw 'Old task definition, principal, or installation is not valid for transition.' }
        if (-not $oldPath.StartsWith($oldRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or $oldPath.StartsWith($oldRoot + '\versions\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Old task executable is outside the unchanged legacy installation.' }
        if ($guest.startupShortcutPresent) { throw 'A legacy Startup shortcut could race scheduled tasks at logon.' }
        if ($guest.otherCandidateTaskCount -ne 0) { throw 'Another candidate task could race this transition.' }
        if ($guest.oldTriggerCount -ne 1 -or $guest.oldLogonTriggerCount -ne 1) { throw 'Legacy task must have exactly one logon trigger.' }
        if ($Apply) {
            if (-not $guest.oldTaskEnabled) { throw 'Apply requires the legacy logon task enabled.' }
            if (-not $guest.stagedVersionVerified) { throw 'Staged version failed complete verification.' }
            if ($guest.candidateTaskPresent -or $guest.taskState -ne 'Running' -or $guest.pythonwCount -ne 1 -or -not $guest.pythonwPath.Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Apply requires one running legacy pythonw and no candidate task.' }
        } elseif ($Promote) {
            if (-not $guest.stagedVersionVerified -or -not $guest.oldTaskEnabled -or -not $guest.candidateTaskEnabled -or $guest.candidateTriggerCount -ne 0 -or $guest.taskState -eq 'Running' -or $guest.candidateTaskState -ne 'Running' -or $guest.pythonwCount -ne 1 -or -not $guest.pythonwPath.Equals($candidatePath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Promote requires one verified running candidate, an enabled legacy logon task, and no candidate trigger.' }
            if (-not (Test-HostStateHandshake $hostPython $hostClient $hostConfig $Project)) { throw 'Candidate host client state handshake failed before promotion.' }
        } else {
            if ($guest.pythonwCount -gt 1 -or ($guest.pythonwCount -eq 1 -and -not ($guest.pythonwPath.Equals($candidatePath,[StringComparison]::OrdinalIgnoreCase) -or $guest.pythonwPath.Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)))) { throw 'Rollback found an unexpected pythonw process.' }
            if (-not $guest.candidateTaskPresent -and $guest.oldTaskEnabled -and $guest.pythonwCount -eq 1 -and $guest.pythonwPath.Equals($oldPath,[StringComparison]::OrdinalIgnoreCase) -and $guest.taskState -eq 'Running') {
                Emit-Result ([ordered]@{schemaVersion=1;status='already-rolled-back';vmId=$id.ToString('D');version=$Version;oldTaskDefinitionChanged=$false;stageFilesPreserved=$true;rollbackRestored=$true;credentialReported=$false}) 0
            }
        }
        if ($Promote -or ($Rollback -and (-not $guest.oldTaskEnabled -or $guest.candidateTriggerCount -gt 0))) {
            $promotionAttempted = $true
            $promotionScript = {
                param($mode,$version,$expectedBios,$sid,$profile,$candidateName,$oldPath,$wechatConfigured)
                $ErrorActionPreference = 'Stop'
                $oldName = 'Qicheng Guest Channel'
                $root = $profile + '\AppData\Local\Qicheng\channel\versions\' + $version
                $candidatePath = $root + '\python\pythonw.exe'
                function Get-AgentProcess { @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction Stop) }
                function Wait-Agent([int]$Count,[string]$Path) {
                    for($i=0;$i -lt 30;$i++) {
                        $items=@(Get-AgentProcess)
                        if($items.Count -eq $Count -and ($Count -eq 0 -or ([string]$items[0].ExecutablePath).Equals($Path,[StringComparison]::OrdinalIgnoreCase))) { return $true }
                        Start-Sleep -Milliseconds 200
                    }
                    return $false
                }
                function Get-TriggerCount($Task) { @($Task.Triggers | Where-Object { $_ }).Count }
                function Restore-Legacy {
                    $candidate=Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue
                    if($candidate) {
                        # Disable first: no logon can start the candidate while legacy is re-enabled.
                        if($candidate.Settings.Enabled) { Disable-ScheduledTask -TaskName $candidateName -ErrorAction Stop | Out-Null }
                        if((Get-ScheduledTask -TaskName $candidateName -ErrorAction Stop).Settings.Enabled) { return $false }
                        $running=@(Get-AgentProcess)
                        if($running.Count -eq 1 -and ([string]$running[0].ExecutablePath).Equals($candidatePath,[StringComparison]::OrdinalIgnoreCase)) { Stop-ScheduledTask -TaskName $candidateName -ErrorAction Stop }
                    }
                    $items=@(Get-AgentProcess)
                    if($items.Count -gt 1 -or ($items.Count -eq 1 -and -not (([string]$items[0].ExecutablePath).Equals($candidatePath,[StringComparison]::OrdinalIgnoreCase) -or ([string]$items[0].ExecutablePath).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)))) { return $false }
                    if($items.Count -eq 1 -and ([string]$items[0].ExecutablePath).Equals($candidatePath,[StringComparison]::OrdinalIgnoreCase) -and -not (Wait-Agent 0 '')) { return $false }
                    $old=Get-ScheduledTask -TaskName $oldName -ErrorAction Stop
                    if(-not $old.Settings.Enabled) { Enable-ScheduledTask -TaskName $oldName -ErrorAction Stop | Out-Null }
                    if(-not (Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).Settings.Enabled) { return $false }
                    if(-not (Wait-Agent 1 $oldPath)) {
                        Start-ScheduledTask -TaskName $oldName -ErrorAction Stop
                        if(-not (Wait-Agent 1 $oldPath)) { return $false }
                    }
                    if($candidate) { Unregister-ScheduledTask -TaskName $candidateName -Confirm:$false -ErrorAction Stop }
                    return ((Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).State.ToString() -eq 'Running' -and -not (Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue))
                }
                try {
                    $product=Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
                    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
                    if([guid]$product.UUID -ne [guid]$expectedBios -or $identity.User.Value -ne $sid -or $env:USERPROFILE -ne $profile) { throw 'Guest identity changed before promotion transition.' }
                    $old=Get-ScheduledTask -TaskName $oldName -ErrorAction Stop
                    $candidate=Get-ScheduledTask -TaskName $candidateName -ErrorAction Stop
                    $candidateSid=try{([Security.Principal.NTAccount]$candidate.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value}catch{([Security.Principal.SecurityIdentifier]::new($candidate.Principal.UserId)).Value}
                    $oldSid=try{([Security.Principal.NTAccount]$old.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value}catch{([Security.Principal.SecurityIdentifier]::new($old.Principal.UserId)).Value}
                    $arguments='-B -m guest.agent --expected-bios-uuid "' + $expectedBios + '" --token-file "' + $root + '\.local\channel.token" --broker-token-file "' + $root + '\.local\broker.token" --human-token-file "' + $root + '\.local\human.token"'
                    if($wechatConfigured){$arguments+=' --wechat-config-file "'+$root+'\.local\wechat.json"'}
                    if($oldSid -ne $sid -or $candidateSid -ne $sid -or @($old.Actions).Count -ne 1 -or @($candidate.Actions).Count -ne 1 -or ([string]$old.Actions[0].Execute) -ine $oldPath -or ([string]$candidate.Actions[0].Execute) -ine $candidatePath -or ([string]$candidate.Actions[0].Arguments) -cne $arguments -or ([string]$candidate.Actions[0].WorkingDirectory) -ine $root -or $candidate.Principal.LogonType.ToString() -ne 'Interactive' -or $candidate.Principal.RunLevel.ToString() -ne 'Limited' -or (Get-TriggerCount $old) -ne 1 -or $old.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger') { throw 'Task definition changed before promotion transition.' }
                    $items=@(Get-AgentProcess)
                    if($mode -eq 'promote') {
                        if(-not $old.Settings.Enabled -or -not $candidate.Settings.Enabled -or (Get-TriggerCount $candidate) -ne 0 -or $candidate.State.ToString() -ne 'Running' -or $items.Count -ne 1 -or ([string]$items[0].ExecutablePath) -ine $candidatePath) { throw 'Promotion preconditions changed.' }
                        Disable-ScheduledTask -TaskName $oldName -ErrorAction Stop | Out-Null
                        if((Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).Settings.Enabled) { throw 'Legacy logon task remained enabled.' }
                        $logon=New-ScheduledTaskTrigger -AtLogOn -User $sid
                        Set-ScheduledTask -TaskName $candidateName -Trigger $logon -ErrorAction Stop | Out-Null
                        $candidate=Get-ScheduledTask -TaskName $candidateName -ErrorAction Stop
                        $old=Get-ScheduledTask -TaskName $oldName -ErrorAction Stop
                        $items=@(Get-AgentProcess)
                        $triggerUser=[string]$candidate.Triggers[0].UserId
                        $triggerSid=try{([Security.Principal.NTAccount]$triggerUser).Translate([Security.Principal.SecurityIdentifier]).Value}catch{([Security.Principal.SecurityIdentifier]::new($triggerUser)).Value}
                        if($old.Settings.Enabled -or -not $candidate.Settings.Enabled -or (Get-TriggerCount $candidate) -ne 1 -or $candidate.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' -or $triggerSid -ne $sid -or $items.Count -ne 1 -or ([string]$items[0].ExecutablePath) -ine $candidatePath -or $candidate.State.ToString() -ne 'Running') { throw 'Promotion verification failed.' }
                        return [pscustomobject]@{status='promoted';rollbackRestored=$false;oldTaskState=$old.State.ToString();candidateTaskState=$candidate.State.ToString();pythonwCount=1;candidateHasAutoTrigger=$true}
                    }
                    if($items.Count -gt 1 -or ($items.Count -eq 1 -and -not (([string]$items[0].ExecutablePath).Equals($candidatePath,[StringComparison]::OrdinalIgnoreCase) -or ([string]$items[0].ExecutablePath).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)))) { throw 'Unexpected process before promoted rollback.' }
                    if($old.Settings.Enabled -and $candidate.Settings.Enabled -and (Get-TriggerCount $candidate) -gt 0) { throw 'Both logon tasks are enabled; automatic rollback is unsafe.' }
                    if(-not (Restore-Legacy)) { throw 'Promoted rollback could not prove legacy restoration.' }
                    return [pscustomobject]@{status='rolled-back';rollbackRestored=$true;oldTaskState='Running';candidateTaskState=$null;pythonwCount=1;candidateHasAutoTrigger=$false}
                } catch {
                    $reason=$_.Exception.Message
                    $restored=$false
                    try { $restored=Restore-Legacy } catch {}
                    return [pscustomobject]@{status=if($restored){'failed-rolled-back'}else{'failed-recovery-incomplete'};error=$reason;rollbackRestored=$restored;oldTaskState=try{(Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).State.ToString()}catch{$null};candidateTaskState=try{(Get-ScheduledTask -TaskName $candidateName -ErrorAction Stop).State.ToString()}catch{$null};pythonwCount=try{@(Get-AgentProcess).Count}catch{$null};candidateHasAutoTrigger=$null}
                }
            }
            $mode=if($Promote){'promote'}else{'rollback'}
            $transition=Invoke-Command -Session $session -ArgumentList $mode,$Version,$bios.ToString('D'),$guest.guestSid,$guest.guestProfile,$candidateName,$oldPath,$guest.wechatConfigPresent -ScriptBlock $promotionScript
            Emit-Result ([ordered]@{schemaVersion=1;status=$transition.status;error=$transition.error;vmId=$id.ToString('D');version=$Version;oldTaskState=$transition.oldTaskState;candidateTaskState=$transition.candidateTaskState;pythonwCount=$transition.pythonwCount;rollbackRestored=$transition.rollbackRestored;candidateHasAutoTrigger=$transition.candidateHasAutoTrigger;stateHandshakeVerified=if($Promote){$true}else{$false};rebootBehavior=if($transition.status -eq 'promoted'){'At the next interactive logon, only the v2 candidate task is enabled.'}else{'At the next interactive logon, only the legacy task is enabled.'};modeMayNeedRestorationAfterReboot=$false;oldTaskDefinitionChanged=$false;stageFilesPreserved=$true;credentialReported=$false}) $(if($transition.status -in @('promoted','rolled-back')){0}else{2})
        }
        $mode = if ($Apply) { 'apply' } else { 'rollback' }
        $transitionAttempted = $true
        $transitionScript = {
            param($mode,$version,$expectedBios,$sid,$profile,$candidateName,$oldPath,$wechatConfigured)
            $ErrorActionPreference = 'Stop'
            $oldName = 'Qicheng Guest Channel'
            $root = $profile + '\AppData\Local\Qicheng\channel\versions\' + $version
            $candidatePath = $root + '\python\pythonw.exe'
            function Get-AgentProcess { @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction Stop) }
            function Wait-AgentProcess([int]$ExpectedCount,[string]$ExpectedPath) {
                for ($attempt = 0; $attempt -lt 30; $attempt++) {
                    $items = @(Get-AgentProcess)
                    if ($items.Count -eq $ExpectedCount -and ($ExpectedCount -eq 0 -or ([string]$items[0].ExecutablePath).Equals($ExpectedPath,[StringComparison]::OrdinalIgnoreCase))) { return $true }
                    Start-Sleep -Milliseconds 200
                }
                return $false
            }
            function Restore-OldAgent {
                $candidate = Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue
                if ($candidate) { try { Stop-ScheduledTask -TaskName $candidateName -ErrorAction Stop } catch {} }
                $items = @(Get-AgentProcess)
                $oldAlreadyRunning = $items.Count -eq 1 -and ([string]$items[0].ExecutablePath).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)
                if (-not $oldAlreadyRunning) {
                    if (-not (Wait-AgentProcess 0 '')) { return $false }
                    try { if ((Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).State.ToString() -eq 'Running') { Stop-ScheduledTask -TaskName $oldName -ErrorAction Stop } } catch { return $false }
                    try { Start-ScheduledTask -TaskName $oldName -ErrorAction Stop } catch { return $false }
                    if (-not (Wait-AgentProcess 1 $oldPath)) { return $false }
                }
                if ((Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).State.ToString() -ne 'Running') { return $false }
                if ($candidate) { try { Unregister-ScheduledTask -TaskName $candidateName -Confirm:$false -ErrorAction Stop } catch { return $false } }
                if (Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue) { return $false }
                return $true
            }
            try {
                $product = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                if ([guid]$product.UUID -ne [guid]$expectedBios -or $identity.User.Value -ne $sid -or $env:USERPROFILE -ne $profile) { throw 'Guest identity changed before transition.' }
                $oldTask = Get-ScheduledTask -TaskName $oldName -ErrorAction Stop
                $principalSid = try { ([Security.Principal.NTAccount]$oldTask.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value } catch { ([Security.Principal.SecurityIdentifier]::new($oldTask.Principal.UserId)).Value }
                if (@($oldTask.Actions).Count -ne 1 -or -not ([string]$oldTask.Actions[0].Execute).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase) -or $principalSid -ne $sid -or $oldTask.Principal.LogonType.ToString() -ne 'Interactive' -or $oldTask.Principal.RunLevel.ToString() -ne 'Limited') { throw 'Legacy task definition changed before transition.' }
                $items = @(Get-AgentProcess)
                if ($mode -eq 'apply') {
                    if ($items.Count -ne 1) { throw 'Expected exactly one pythonw before apply.' }
                    if (-not ([string]$items[0].ExecutablePath).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase) -or (Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue)) { throw 'Legacy process or candidate task changed before apply.' }
                    $arguments = '-B -m guest.agent --expected-bios-uuid "' + $expectedBios + '" --token-file "' + $root + '\.local\channel.token" --broker-token-file "' + $root + '\.local\broker.token" --human-token-file "' + $root + '\.local\human.token"'
                    if($wechatConfigured){$arguments+=' --wechat-config-file "'+$root+'\.local\wechat.json"'}
                    $action = New-ScheduledTaskAction -Execute $candidatePath -Argument $arguments -WorkingDirectory $root
                    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
                    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew
                    Register-ScheduledTask -TaskName $candidateName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
                    $registered = Get-ScheduledTask -TaskName $candidateName -ErrorAction Stop
                    $registeredSid = $null
                    try { $registeredSid = ([Security.Principal.NTAccount]([string]$registered.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value }
                    catch { try { $registeredSid = ([Security.Principal.SecurityIdentifier]::new([string]$registered.Principal.UserId)).Value } catch {} }
                    # On Windows PowerShell 5.1 an empty Triggers collection is $null;
                    # wrapping it with @() incorrectly counts one null item.
                    if (@($registered.Triggers | Where-Object { $null -ne $_ }).Count -ne 0 -or @($registered.Actions).Count -ne 1 -or ([string]$registered.Actions[0].Execute) -ine $candidatePath -or $registeredSid -ne $sid -or $registered.Principal.LogonType.ToString() -ne 'Interactive' -or $registered.Principal.RunLevel.ToString() -ne 'Limited') { throw 'Candidate task registration verification failed.' }
                    Stop-ScheduledTask -TaskName $oldName -ErrorAction Stop
                    if (-not (Wait-AgentProcess 0 '')) { throw 'Legacy pythonw did not exit after stop.' }
                    Start-ScheduledTask -TaskName $candidateName -ErrorAction Stop
                    if (-not (Wait-AgentProcess 1 $candidatePath)) { throw 'Candidate pythonw did not become the sole agent.' }
                    if ((Get-ScheduledTask -TaskName $candidateName -ErrorAction Stop).State.ToString() -ne 'Running' -or (Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).State.ToString() -eq 'Running') { throw 'Candidate and legacy task states are inconsistent.' }
                    [pscustomobject]@{status='candidate-running';oldTaskState=(Get-ScheduledTask -TaskName $oldName).State.ToString();candidateTaskState=(Get-ScheduledTask -TaskName $candidateName).State.ToString();pythonwCount=1;rollbackRestored=$false;candidateHasAutoTrigger=$false}
                } else {
                    if ($items.Count -gt 1 -or ($items.Count -eq 1 -and -not (([string]$items[0].ExecutablePath).Equals($candidatePath,[StringComparison]::OrdinalIgnoreCase) -or ([string]$items[0].ExecutablePath).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)))) { throw 'Unexpected process appeared before rollback.' }
                    if (-not (Restore-OldAgent)) { throw 'Rollback could not prove the legacy agent was restored.' }
                    [pscustomobject]@{status='rolled-back';oldTaskState=(Get-ScheduledTask -TaskName $oldName).State.ToString();candidateTaskState=$null;pythonwCount=1;rollbackRestored=$true;candidateHasAutoTrigger=$false}
                }
            } catch {
                $reason = $_.Exception.Message
                $restored = $false
                try { $restored = Restore-OldAgent } catch {}
                [pscustomobject]@{status=if($restored){'failed-rolled-back'}else{'failed-recovery-incomplete'};error=$reason;oldTaskState=try{(Get-ScheduledTask -TaskName $oldName -ErrorAction Stop).State.ToString()}catch{$null};candidateTaskState=try{(Get-ScheduledTask -TaskName $candidateName -ErrorAction Stop).State.ToString()}catch{$null};pythonwCount=try{@(Get-AgentProcess).Count}catch{$null};rollbackRestored=$restored;candidateHasAutoTrigger=$false}
            }
        }
        $transition = Invoke-Command -Session $session -ArgumentList $mode,$Version,$bios.ToString('D'),$guest.guestSid,$guest.guestProfile,$candidateName,$oldPath,$guest.wechatConfigPresent -ScriptBlock $transitionScript
        $handshakeVerified = $false
        if ($Apply -and $transition.status -eq 'candidate-running') {
            $handshakeVerified = Test-HostStateHandshake $hostPython $hostClient $hostConfig $Project
            if (-not $handshakeVerified) {
                $rollback = Invoke-Command -Session $session -ArgumentList 'rollback',$Version,$bios.ToString('D'),$guest.guestSid,$guest.guestProfile,$candidateName,$oldPath,$guest.wechatConfigPresent -ScriptBlock $transitionScript
                $transition = [pscustomobject]@{status=if($rollback.status -eq 'rolled-back'){'failed-rolled-back'}else{'failed-recovery-incomplete'};error='Candidate host client state handshake failed; legacy recovery was attempted.';oldTaskState=$rollback.oldTaskState;candidateTaskState=$rollback.candidateTaskState;pythonwCount=$rollback.pythonwCount;rollbackRestored=($rollback.status -eq 'rolled-back');candidateHasAutoTrigger=$false}
            }
        }
        Emit-Result ([ordered]@{schemaVersion=1;status=$transition.status;error=$transition.error;vmId=$id.ToString('D');version=$Version;oldTaskState=$transition.oldTaskState;candidateTaskState=$transition.candidateTaskState;pythonwCount=$transition.pythonwCount;rollbackRestored=$transition.rollbackRestored;candidateHasAutoTrigger=$transition.candidateHasAutoTrigger;stateHandshakeVerified=$handshakeVerified;rebootBehavior='At the next interactive logon, the unchanged legacy task starts; the temporary candidate has no trigger.';modeMayNeedRestorationAfterReboot=$true;oldTaskDefinitionChanged=$false;stageFilesPreserved=$true;credentialReported=$false}) $(if($transition.status -in @('candidate-running','rolled-back')){0}else{2})
    }
    Emit-Result ([ordered]@{
        schemaVersion=1;status='switch-diagnostic-only';vmId=$id.ToString('D');version=$Version
        oldTaskPresent=$guest.taskPresent;oldActionExecutablePresent=$guest.oldActionExecutablePresent
        oldActionDirectoryPresent=$guest.oldActionDirectoryPresent;oldTaskActionCount=$guest.taskActionCount
        oldTaskState=$guest.taskState;stagedVersionPresent=$guest.stagedVersionPresent
        stagedVersionVerified=$guest.stagedVersionVerified;rollbackProven=$false
        reason='Read-only diagnostic. Apply registers a no-trigger candidate task and stops the legacy task; Rollback restores the legacy task.'
        taskModified=$false;agentStarted=$false;credentialReported=$false
    }) 0
}
catch {
    $failure = $_.Exception.Message
    if ($promotionAttempted) {
        Emit-Result ([ordered]@{schemaVersion=1;status='failed-recovery-incomplete';error=$failure;rollbackRestored=$false;taskStateUnknown=$true;stageFilesPreserved=$true;credentialReported=$false}) 2
    }
    if ($transitionAttempted) {
        $recovered = $false
        try {
            if (-not $session -or $session.State -ne 'Opened') { $session = New-PSSession -VMId $vm.Id -Credential $Credential -ErrorAction Stop }
            $recovered = [bool](Invoke-Command -Session $session -ArgumentList $bios.ToString('D'),$guest.guestSid,$guest.guestProfile,$candidateName,$oldPath -ScriptBlock {
                param($expectedBios,$sid,$profile,$candidateName,$oldPath)
                if ([guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne [guid]$expectedBios -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $sid -or $env:USERPROFILE -ne $profile) { return $false }
                $candidate = Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue
                if ($candidate) { try { Stop-ScheduledTask -TaskName $candidateName -ErrorAction Stop } catch {} }
                $oldAlreadyRunning = $false
                for ($i=0;$i -lt 30;$i++) {
                    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction Stop)
                    if ($processes.Count -eq 0) { break }
                    if ($processes.Count -eq 1 -and ([string]$processes[0].ExecutablePath).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)) { $oldAlreadyRunning = $true; break }
                    Start-Sleep -Milliseconds 200
                }
                if (-not $oldAlreadyRunning) {
                    if (@(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'").Count -ne 0) { return $false }
                    Start-ScheduledTask -TaskName 'Qicheng Guest Channel' -ErrorAction Stop
                }
                for ($i=0;$i -lt 30;$i++) {
                    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction Stop)
                    if ($processes.Count -eq 1 -and ([string]$processes[0].ExecutablePath).Equals($oldPath,[StringComparison]::OrdinalIgnoreCase)) {
                        if ($candidate) { try { Unregister-ScheduledTask -TaskName $candidateName -Confirm:$false -ErrorAction Stop } catch { return $false } }
                        return ((Get-ScheduledTask -TaskName 'Qicheng Guest Channel' -ErrorAction Stop).State.ToString() -eq 'Running' -and -not (Get-ScheduledTask -TaskName $candidateName -ErrorAction SilentlyContinue))
                    }
                    Start-Sleep -Milliseconds 200
                }
                return $false
            })
        } catch { $recovered = $false }
        Emit-Result ([ordered]@{schemaVersion=1;status=if($recovered){'failed-rolled-back'}else{'failed-recovery-incomplete'};error=$failure;rollbackRestored=$recovered;oldTaskDefinitionChanged=$false;stageFilesPreserved=$true;credentialReported=$false}) 2
    }
    Emit-Result ([ordered]@{schemaVersion=1;status='failed';error=$failure;taskModified=$false;agentStarted=$false;credentialReported=$false}) 2
}
finally { if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } }
