[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Install-GuestPayloadDirect.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('qicheng-direct-' + [guid]::NewGuid().ToString('N'))
function Assert-True { param($Condition,$Message) if(-not $Condition){throw $Message} }
try {
    $payload = Join-Path $root 'payload'
    foreach($directory in @('.local','python','guest')){[IO.Directory]::CreateDirectory((Join-Path $payload $directory))|Out-Null}
    foreach($relative in @('Start-Channel.cmd','python\pythonw.exe','guest\agent.py','guest\protocol.py','guest\windows.py')){[IO.File]::WriteAllText((Join-Path $payload $relative),'x')}
    [IO.File]::WriteAllText((Join-Path $payload '.local\channel.token'),('a'*64))
    $files=@()
    foreach($relative in @('Start-Channel.cmd','python/pythonw.exe','guest/agent.py','guest/protocol.py','guest/windows.py','.local/channel.token')){
        $file=Join-Path $payload $relative.Replace('/','\');$item=Get-Item $file
        $files += [ordered]@{path=$relative;sizeBytes=$item.Length;sha256=(Get-FileHash $file -Algorithm SHA256).Hash}
    }
    $manifest=[ordered]@{schemaVersion=1;payloadType='qicheng-windows-guest';expectedBiosUuid='11111111-2222-4333-8444-555555555555';entrypoint='Start-Channel.cmd';tokenPath='.local/channel.token';files=$files}
    [IO.File]::WriteAllText((Join-Path $payload 'payload-manifest.json'),($manifest|ConvertTo-Json -Depth 5))
    foreach($path in @($payload)){
        $acl=Get-Acl $path;$acl.SetAccessRuleProtection($true,$false);foreach($rule in @($acl.Access)){[void]$acl.RemoveAccessRuleAll($rule)}
        $inheritance=[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')){[void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}
        Set-Acl $path $acl
    }
    Assert-True (-not(Get-Acl (Join-Path $payload '.local\channel.token')).AreAccessRulesProtected) 'Token fixture must exercise safe inherited ACL.'
    $harness=Join-Path $root 'harness.ps1'
    $harnessSource=@'
param($Script,$Payload,$WhatIfMode)
function global:Get-VM { [pscustomobject]@{Name='qicheng-win-1';Id=[guid]'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';State='Running'} }
function global:Get-CimInstance { [pscustomobject]@{VirtualSystemType='Microsoft:Hyper-V:System:Realized';BIOSGUID='11111111-2222-4333-8444-555555555555'} }
$credential=[pscredential]::new('qicheng',(ConvertTo-SecureString 'test-only' -AsPlainText -Force))
$invoke=@{VMName='qicheng-win-1';ExpectedVMId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';PayloadDirectory=$Payload;Credential=$credential;Compact=$true}
if($WhatIfMode -eq 'true'){$invoke.Apply=$true;$invoke.WhatIf=$true}
& $Script @invoke
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($harness,$harnessSource)
    $output=& powershell.exe -NoProfile -File $harness -Script $scriptPath -Payload $payload -WhatIfMode false 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "Plan must succeed: $($output -join ' ')"
    Assert-True (($output|ConvertFrom-Json).status -eq 'not-installed') 'Plan status must remain not-installed.'
    $output=& powershell.exe -NoProfile -File $harness -Script $scriptPath -Payload $payload -WhatIfMode true 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'WhatIf must succeed without a session.'
    $manifestPath=Join-Path $payload 'payload-manifest.json';$savedManifest=[IO.File]::ReadAllText($manifestPath);$missingRuntime=$savedManifest|ConvertFrom-Json
    $missingRuntime.files=@($missingRuntime.files|Where-Object path -ne 'python/pythonw.exe');[IO.File]::WriteAllText($manifestPath,($missingRuntime|ConvertTo-Json -Depth 6))
    $output=& powershell.exe -NoProfile -File $harness -Script $scriptPath -Payload $payload -WhatIfMode false 2>&1
    Assert-True ($LASTEXITCODE -eq 2) 'Missing required runtime file must fail before a session.'
    Assert-True (($output|ConvertFrom-Json).error -match 'missing required runtime file') 'Missing runtime failure must be explicit.'
    [IO.File]::WriteAllText($manifestPath,$savedManifest)
    $source=Get-Content $scriptPath -Raw
    Assert-True ($source -notmatch 'Copy-VMFile') 'Direct installer must not use Guest Service copy.'
    Assert-True ($source -notmatch 'Start-VM|Stop-VM') 'Direct installer must not change VM lifecycle.'
    Assert-True ($source -match 'New-PSSession -VMId') 'Direct installer must bind the exact VM ID.'
    Assert-True ($source -match 'Remove-PSSession') 'Direct installer must remove its session.'
    foreach($required in @('python/pythonw.exe','guest/agent.py','guest/protocol.py','guest/windows.py','.local/channel.token')){Assert-True ($source -match [regex]::Escape($required)) "Installer must require $required"}
    $registerAt=$source.IndexOf('Register-ScheduledTask');$verifiedAt=$source.IndexOf('$taskRegistered=$true');$startAt=$source.IndexOf('Start-ScheduledTask')
    Assert-True ($registerAt -ge 0 -and $verifiedAt -gt $registerAt -and $startAt -gt $verifiedAt) 'Task registration, verification state, and start request must be ordered separately.'
    [pscustomobject]@{passed=16;failed=0;sessionsCreated=0;vmChanges=0}|ConvertTo-Json -Compress
}
finally { if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force} }
exit 0
