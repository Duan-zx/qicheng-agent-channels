[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$scriptPath=(Resolve-Path (Join-Path $PSScriptRoot '..\Install-GuestPayloadOffline.ps1')).Path
$testRoot=Join-Path $PSScriptRoot ('offline-test-'+[guid]::NewGuid().ToString('N'))
$payload=Join-Path $testRoot 'payload'
$mountWork='D:\fixture-mount-work'
$bios=[guid]'11111111-2222-4333-8444-555555555555'
$guestInstall='C:\Users\channel1\AppData\Local\Qicheng\channel'
$tokenPaths=@('.local/channel.token','.local/broker.token','.local/human.token')
$required=@('Start-Channel.cmd','python/python.exe','python/pythonw.exe','guest/agent.py','guest/protocol.py','guest/windows.py')+$tokenPaths

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Set-PrivateAcl([string]$Path){
    $item=Get-Item -LiteralPath $Path
    $acl=if($item.PSIsContainer){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
    $acl.SetAccessRuleProtection($true,$false)
    $inherit=if($item.PSIsContainer){[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
    foreach($sidText in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidText),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-Manifest([string[]]$Files,[string[]]$Tokens=$tokenPaths,[int]$Schema=2,[bool]$Wechat=$false){
    $entries=@(foreach($relative in $Files){$file=Join-Path $payload $relative.Replace('/','\');$item=Get-Item -LiteralPath $file;[ordered]@{path=$relative;sizeBytes=[uint64]$item.Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}})
    $manifest=[ordered]@{schemaVersion=$Schema;payloadType='qicheng-windows-guest';credentialMode='channel-broker-human';expectedBiosUuid=$bios.ToString('D');entrypoint='Start-Channel.cmd';tokenPath=$tokenPaths[0];tokenPaths=$Tokens;files=$entries}
    if($Wechat){$manifest.wechatConfigPath='.local/wechat.json'}
    [IO.File]::WriteAllText((Join-Path $payload 'payload-manifest.json'),($manifest|ConvertTo-Json -Depth 6))
}
function Set-TokenValue([string]$Name,[string]$Value){[IO.File]::WriteAllText((Join-Path $payload ('.local\'+$Name+'.token')),$Value+[Environment]::NewLine,[Text.Encoding]::ASCII)}
function Invoke-Plan {
    $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Script $scriptPath -Payload $payload -MountWork $mountWork 2>&1
    [pscustomobject]@{Code=$LASTEXITCODE;Output=($output-join "`n")}
}

try {
    [IO.Directory]::CreateDirectory($payload)|Out-Null
    foreach($relative in $required){$path=Join-Path $payload $relative.Replace('/','\');[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;$content=if($relative -like '*.token'){'a'*64}else{'fixture'};[IO.File]::WriteAllText($path,$content)}
    Set-TokenValue 'channel' ('a'*64)
    Set-TokenValue 'broker' ('b'*64)
    Set-TokenValue 'human' ('c'*64)
    Write-Manifest $required
    Set-PrivateAcl $payload
    foreach($tokenPath in $tokenPaths){Set-PrivateAcl (Join-Path $payload $tokenPath.Replace('/','\'))}

    $harness=Join-Path $testRoot 'harness.ps1'
$harnessSource=@'
param($Script,$Payload,$MountWork)
function global:Test-Path {
    param([string]$Path,[string]$LiteralPath,[string]$PathType)
    $target=if($LiteralPath){$LiteralPath}else{$Path}
    if($target -eq 'D:\fixture-mount-work'){return $true}
    if($LiteralPath){if($PathType){return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType};return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}
    if($PathType){return Microsoft.PowerShell.Management\Test-Path -Path $Path -PathType $PathType}
    Microsoft.PowerShell.Management\Test-Path -Path $Path
}
function global:Get-VM { [pscustomobject]@{Name='qicheng-win-1';Id=[guid]'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';State='Off'} }
function global:Get-CimInstance { [pscustomobject]@{VirtualSystemType='Microsoft:Hyper-V:System:Realized';BIOSGUID='11111111-2222-4333-8444-555555555555'} }
function global:Get-VMHardDiskDrive { [pscustomobject]@{Path='D:\fixture.vhdx'} }
function global:Get-VHD { [pscustomobject]@{Attached=$false} }
& $Script -VMName 'qicheng-win-1' -ExpectedVMId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -PayloadDirectory $Payload -MountWorkDirectory $MountWork -Compact
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($harness,$harnessSource)

    $result=Invoke-Plan
    Assert-True ($result.Code -eq 0) "Valid three-credential plan failed: $($result.Output)"
    Assert-True (($result.Output|ConvertFrom-Json).status -eq 'not-installed') 'Valid plan must remain not-installed.'
    $wechatFile=Join-Path $payload '.local\wechat.json'
    [IO.File]::WriteAllText($wechatFile,'{"project_id":"fixture","guest_project_path":"C:\\Users\\fixture\\project","cli_bat_path":"C:\\wechat\\cli.bat","service_port":1234}')
    Set-PrivateAcl $wechatFile
    $startFile=Join-Path $payload 'Start-Channel.cmd'
    [IO.File]::WriteAllText($startFile,'fixture --wechat-config-file "%~dp0.local\wechat.json"')
    Write-Manifest (@($required)+'.local/wechat.json') $tokenPaths 2 $true
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 0) "Configured offline plan must validate: $($result.Output)"
    [IO.File]::AppendAllText($wechatFile,'tamper')
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2) 'Offline plan must reject sidecar tampering.'
    [IO.File]::WriteAllText($wechatFile,'{"project_id":"fixture","guest_project_path":"C:\\Users\\fixture\\project","cli_bat_path":"C:\\wechat\\cli.bat","service_port":1234}')
    $savedAcl=Get-Acl -LiteralPath $wechatFile
    $wideAcl=Get-Acl -LiteralPath $wechatFile;$wideAcl.SetAccessRuleProtection($false,$true);Set-Acl -LiteralPath $wechatFile -AclObject $wideAcl
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2) 'Offline plan must reject unprotected sidecar ACL.'
    Set-Acl -LiteralPath $wechatFile -AclObject $savedAcl
    Move-Item -LiteralPath $wechatFile -Destination ($wechatFile+'.missing')
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2) 'Offline plan must reject a missing configured sidecar.'
    Move-Item -LiteralPath ($wechatFile+'.missing') -Destination $wechatFile
    Remove-Item -LiteralPath $wechatFile
    [IO.File]::WriteAllText($startFile,'fixture')
    Write-Manifest $required

    Write-Manifest $required @('.local/channel.token')
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'credential paths') 'Missing tokenPaths must fail.'

    Write-Manifest $required $tokenPaths 1
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'three-credential manifest') 'Legacy schema must fail.'

    Write-Manifest (@($required|Where-Object {$_ -ne 'python/python.exe'}))
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'required runtime file') 'Missing required runtime must fail.'

    Set-TokenValue 'human' ''
    Write-Manifest $required
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'Invalid token format') 'Empty human token must fail.'
    Assert-True ($result.Output -notmatch ('a'*32)) 'Token values must not appear in failure output.'

    Set-TokenValue 'human' ('c'*64)
    Set-TokenValue 'broker' ('a'*64)
    Write-Manifest $required
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'must be distinct') 'Duplicate token values must fail.'

    Set-TokenValue 'broker' ('b'*64)
    Set-TokenValue 'human' ('C'*64)
    Write-Manifest $required
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'Invalid token format') 'Uppercase token must fail.'

    Set-TokenValue 'human' ('c'*63)
    Write-Manifest $required
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'Invalid token format') 'Short token must fail.'

    Set-TokenValue 'human' ('c'*64)
    Write-Manifest $required
    $broker=Join-Path $payload '.local\broker.token'
    $acl=Get-Acl -LiteralPath $broker
    $acl.SetAccessRuleProtection($false,$true)
    Set-Acl -LiteralPath $broker -AclObject $acl
    $result=Invoke-Plan
    Assert-True ($result.Code -eq 2 -and ($result.Output|ConvertFrom-Json).error -match 'ACL inheritance') 'Nonprivate broker token must fail.'
    Assert-True ($result.Output -notmatch ('a'*32)) 'Failure output must not contain token material.'

    $source=Get-Content -LiteralPath $scriptPath -Raw
    $match=[regex]::Match($source,'\$lnk\.Arguments=(?<expression>.*?);\$lnk\.WorkingDirectory',[Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True $match.Success 'Startup argument expression must be present.'
    $arguments=Invoke-Expression $match.Groups['expression'].Value
    $expected='-B -m guest.agent --expected-bios-uuid "11111111-2222-4333-8444-555555555555" --token-file "'+$guestInstall+'\.local\channel.token" --broker-token-file "'+$guestInstall+'\.local\broker.token" --human-token-file "'+$guestInstall+'\.local\human.token"'
    Assert-True ($arguments -ceq $expected) "Startup must pass all three credential paths: $arguments"
    [pscustomobject]@{passed=18;failed=0;vmMounts=0;agentStarts=0}|ConvertTo-Json -Compress
}
finally {if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
