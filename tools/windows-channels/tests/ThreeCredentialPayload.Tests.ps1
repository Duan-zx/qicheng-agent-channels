[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$builder = (Resolve-Path (Join-Path $PSScriptRoot '..\Build-GuestPayload.ps1')).Path
$stager = (Resolve-Path (Join-Path $PSScriptRoot '..\Stage-GuestPayloadDirect.ps1')).Path
$switcher = (Resolve-Path (Join-Path $PSScriptRoot '..\Switch-GuestPayloadDirect.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('qicheng-three-credential-' + [guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Protect([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    $inherit=[Security.AccessControl.InheritanceFlags]::None
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')) {
        [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $python=Join-Path $root 'python';[IO.Directory]::CreateDirectory($python)|Out-Null
    foreach($name in @('python.exe','pythonw.exe','python312.zip','LICENSE.txt')){[IO.File]::WriteAllText((Join-Path $python $name),'fixture')}
    [IO.File]::WriteAllLines((Join-Path $python 'python312._pth'),@('python312.zip','.'))
    $paths=@();foreach($i in 1..3){$p=Join-Path $root ("credential-$i");[IO.File]::WriteAllText($p,([char](96+$i)).ToString()*64);Protect $p;$paths+=$p}
    $harness=Join-Path $root 'build-harness.ps1'
    @'
param($Builder,$Python,$Output,$Channel,$Broker,$Human,$Wechat)
function global:Get-AuthenticodeSignature { [pscustomobject]@{Status=[Management.Automation.SignatureStatus]::Valid;SignerCertificate=[pscustomobject]@{Subject='CN=Python Software Foundation';Issuer='CN=Test'}} }
$parameters=@{EmbeddedPythonDirectory=$Python;OutputDirectory=$Output;BIOSUUID='11111111-2222-4333-8444-555555555555';ChannelTokenFile=$Channel;BrokerTokenFile=$Broker;HumanTokenFile=$Human;Compact=$true}
if($Wechat){$parameters.WechatConfigFile=$Wechat}
& $Builder @parameters
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $harness -Encoding ASCII
    $payload=Join-Path $root 'payload'
    $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Builder $builder -Python $python -Output $payload -Channel $paths[0] -Broker $paths[1] -Human $paths[2] 2>&1
    Assert ($LASTEXITCODE -eq 0) "Three-credential build failed: $($output -join ' ')"
    $result=$output|ConvertFrom-Json
    Assert ($result.credentialMode -eq 'channel-broker-human') 'Build result must identify three-credential mode.'
    $manifest=Get-Content (Join-Path $payload 'payload-manifest.json') -Raw|ConvertFrom-Json
    Assert ($manifest.schemaVersion -eq 2) 'Three-credential manifest must be version 2.'
    Assert (-not $manifest.PSObject.Properties['wechatConfigPath']) 'Legacy three-credential manifest must not configure WeChat.'
    Assert ((@($manifest.tokenPaths) -join '|') -eq '.local/channel.token|.local/broker.token|.local/human.token') 'Manifest must list three credential paths.'
    foreach($name in @('channel','broker','human')){Assert (Test-Path (Join-Path $payload ".local\$name.token")) 'Credential file is missing.'}
    $start=Get-Content (Join-Path $payload 'Start-Channel.cmd') -Raw
    Assert ($start.Contains('python.exe" -B -m guest.agent')) 'Start command must disable bytecode writes.'
    foreach($flag in @('--token-file','--broker-token-file','--human-token-file')){Assert ($start.Contains($flag)) 'Start command must contain each credential flag.'}
    Assert (-not $start.Contains('--wechat-config-file')) 'Legacy start command must omit WeChat config.'
    foreach($p in $paths){$secret=[IO.File]::ReadAllText($p);Assert (($output -join ' ') -notmatch [regex]::Escape($secret)) 'Credential leaked in builder result.';Assert ($start -notmatch [regex]::Escape($secret)) 'Credential leaked in start command.'}
    $duplicate=Join-Path $root 'duplicate'
    $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Builder $builder -Python $python -Output $duplicate -Channel $paths[0] -Broker $paths[0] -Human $paths[2] 2>&1
    Assert ($LASTEXITCODE -eq 2 -and -not(Test-Path $duplicate)) 'Duplicate credential paths must fail before output.'
    Push-Location $payload
    try { & python.exe -B -c 'import guest.agent' *> $null;Assert ($LASTEXITCODE -eq 0) 'Real Python import of bundled guest module must pass with -B.' }
    finally { Pop-Location }
    $actualFiles=@(Get-ChildItem -LiteralPath $payload -File -Recurse -Force | Where-Object Name -ne 'payload-manifest.json')
    Assert ($actualFiles.Count -eq @($manifest.files).Count) 'Real import must leave the payload inventory unchanged.'
    Assert (-not(Test-Path -LiteralPath (Join-Path $payload 'guest\__pycache__'))) 'Real import must not create guest bytecode cache.'
    $configDir=Join-Path $root 'private-config';[IO.Directory]::CreateDirectory($configDir)|Out-Null;Protect $configDir
    $config=Join-Path $configDir 'wechat.json'
    [IO.File]::WriteAllText($config,'{"project_id":"fixture-project","guest_project_path":"C:\\Users\\fixture\\project","cli_bat_path":"C:\\Program Files\\wechat\\cli.bat","service_port":1234}',[Text.UTF8Encoding]::new($false));Protect $config
    $withWechat=Join-Path $root 'payload-with-wechat'
    $configOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Builder $builder -Python $python -Output $withWechat -Channel $paths[0] -Broker $paths[1] -Human $paths[2] -Wechat $config 2>&1
    Assert ($LASTEXITCODE -eq 0) "WeChat sidecar build failed: $($configOutput -join ' ')"
    $configManifest=Get-Content (Join-Path $withWechat 'payload-manifest.json') -Raw|ConvertFrom-Json
    Assert ($configManifest.wechatConfigPath -ceq '.local/wechat.json') 'Manifest must fix the WeChat path.'
    Assert (@($configManifest.files|Where-Object path -eq '.local/wechat.json').Count -eq 1) 'Manifest must hash the WeChat sidecar.'
    Assert ((Get-Acl -LiteralPath (Join-Path $withWechat '.local\wechat.json')).AreAccessRulesProtected) 'Output sidecar ACL must be protected.'
    $configStart=Get-Content (Join-Path $withWechat 'Start-Channel.cmd') -Raw
    Assert ($configStart.Contains('--wechat-config-file "%~dp0.local\wechat.json"')) 'Start command must use the fixed sidecar path.'
    Assert (($configOutput -join ' ') -notmatch 'fixture-project') 'Builder output must not expose sidecar contents.'
    $tampered=Join-Path $root 'bad-sidecar';[IO.File]::WriteAllText($config,'not-json');Protect $config
    $bad=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Builder $builder -Python $python -Output $tampered -Channel $paths[0] -Broker $paths[1] -Human $paths[2] -Wechat $config 2>&1
    Assert ($LASTEXITCODE -eq 2 -and -not(Test-Path $tampered)) 'Invalid sidecar JSON must fail before output.'
    [IO.File]::Copy((Join-Path $withWechat '.local\wechat.json'),$config,$true);Protect $config
    $unprotected=Get-Acl -LiteralPath $configDir;$unprotected.SetAccessRuleProtection($false,$true);Set-Acl -LiteralPath $configDir -AclObject $unprotected
    $bad=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Builder $builder -Python $python -Output $tampered -Channel $paths[0] -Broker $paths[1] -Human $paths[2] -Wechat $config 2>&1
    Assert ($LASTEXITCODE -eq 2 -and -not(Test-Path $tampered)) 'Unprotected source parent ACL must fail before output.'
    $stageHarness=Join-Path $root 'stage-harness.ps1'
    @'
param($Stager,$Payload)
function global:Get-VM { [pscustomobject]@{Name='qicheng-win-1';Id=[guid]'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';State='Running'} }
function global:Get-CimInstance { [pscustomobject]@{VirtualSystemType='Microsoft:Hyper-V:System:Realized';BIOSGUID='11111111-2222-4333-8444-555555555555'} }
& $Stager -VMName 'qicheng-win-1' -ExpectedVMId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -PayloadDirectory $Payload -Version 'candidate-1' -Compact
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $stageHarness -Encoding ASCII
    $stageOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stageHarness -Stager $stager -Payload $payload 2>&1
    Assert ($LASTEXITCODE -eq 0) "Stage plan failed: $($stageOutput -join ' ')"
    Assert (($stageOutput|ConvertFrom-Json).status -eq 'validated-stage-plan') 'Stage plan must validate without a guest session.'
    $stageOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stageHarness -Stager $stager -Payload $withWechat 2>&1
    Assert ($LASTEXITCODE -eq 0 -and ($stageOutput|ConvertFrom-Json).status -eq 'validated-stage-plan') 'Stage must accept a protected configured sidecar.'
    $wechatPayloadFile=Join-Path $withWechat '.local\wechat.json'
    $wechatSaved=[IO.File]::ReadAllBytes($wechatPayloadFile)
    [IO.File]::AppendAllText($wechatPayloadFile,'tamper')
    $stageOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stageHarness -Stager $stager -Payload $withWechat 2>&1
    Assert ($LASTEXITCODE -eq 2) 'Stage must reject a tampered sidecar.'
    [IO.File]::WriteAllBytes($wechatPayloadFile,$wechatSaved)
    $savedWechatAcl=Get-Acl -LiteralPath $wechatPayloadFile
    $wideAcl=Get-Acl -LiteralPath $wechatPayloadFile;$wideAcl.SetAccessRuleProtection($false,$true);Set-Acl -LiteralPath $wechatPayloadFile -AclObject $wideAcl
    $stageOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stageHarness -Stager $stager -Payload $withWechat 2>&1
    Assert ($LASTEXITCODE -eq 2) 'Stage must reject an unprotected sidecar ACL.'
    Set-Acl -LiteralPath $wechatPayloadFile -AclObject $savedWechatAcl
    Move-Item -LiteralPath $wechatPayloadFile -Destination ($wechatPayloadFile+'.missing')
    $stageOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stageHarness -Stager $stager -Payload $withWechat 2>&1
    Assert ($LASTEXITCODE -eq 2) 'Stage must reject a missing configured sidecar.'
    Move-Item -LiteralPath ($wechatPayloadFile+'.missing') -Destination $wechatPayloadFile
    $stageAst=[Management.Automation.Language.Parser]::ParseFile($stager,[ref]$null,[ref]$null)
    $createBlocks=@($stageAst.FindAll({param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $node.Extent.Text -like '*Version ACL protection failed*'},$true))
    $verifyBlocks=@($stageAst.FindAll({param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $node.Extent.Text -like '*Guest version file verification failed*'},$true))
    Assert ($createBlocks.Count -eq 1 -and $verifyBlocks.Count -eq 1) 'Stage must have one remote creation and one remote verification block.'
    $createRemote=$createBlocks[0].ScriptBlock.GetScriptBlock()
    $verifyRemote=$verifyBlocks[0].ScriptBlock.GetScriptBlock()
    $ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach($variant in @(@{Source=$payload;Wechat=$false;Name='legacy'},@{Source=$withWechat;Wechat=$true;Name='with-wechat'})){
        $remoteRoot=Join-Path $root ('simulated-guest-'+$variant.Name)
        & $createRemote $remoteRoot $ownerSid
        Assert (Test-Path -LiteralPath $remoteRoot -PathType Container) 'Remote creation must create the version root before file copies.'
        $remoteManifest=Get-Content (Join-Path $variant.Source 'payload-manifest.json') -Raw|ConvertFrom-Json
        foreach($entry in $remoteManifest.files){$target=Join-Path $remoteRoot ([string]$entry.path).Replace('/','\');[IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null;Copy-Item -LiteralPath (Join-Path $variant.Source ([string]$entry.path).Replace('/','\')) -Destination $target}
        Copy-Item -LiteralPath (Join-Path $variant.Source 'payload-manifest.json') -Destination (Join-Path $remoteRoot 'payload-manifest.json')
        if($variant.Wechat){$remoteWechat=Join-Path $remoteRoot '.local\wechat.json';$openAcl=Get-Acl -LiteralPath $remoteWechat;$openAcl.SetAccessRuleProtection($false,$true);Set-Acl -LiteralPath $remoteWechat -AclObject $openAcl}
        & $verifyRemote $remoteRoot $ownerSid $variant.Wechat
        if($variant.Wechat){Assert ((Get-Acl -LiteralPath $remoteWechat).AreAccessRulesProtected) 'Remote verification must protect the copied sidecar ACL.'}
    }
    $stageApplyHarness=Join-Path $root 'stage-apply-harness.ps1'
    @'
param($Stager,$Payload,$RemoteRoot)
$global:remoteRoot=$RemoteRoot
$global:guestRoot='C:\Users\fixture\AppData\Local\Qicheng\channel\versions\candidate-1'
$global:remoteCalls=0
function global:Get-VM { [pscustomobject]@{Name='qicheng-win-1';Id=[guid]'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';State='Running'} }
function global:Get-CimInstance { [pscustomobject]@{VirtualSystemType='Microsoft:Hyper-V:System:Realized';BIOSGUID='11111111-2222-4333-8444-555555555555'} }
function global:New-PSSession { [pscustomobject]@{State='Opened'} }
function global:Remove-PSSession {}
function global:Map-GuestPath([string]$Path){
    if(-not $Path.StartsWith($global:guestRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected guest path in simulated Apply.'}
    $suffix=$Path.Substring($global:guestRoot.Length).TrimStart([char]92)
    if($suffix){return Join-Path $global:remoteRoot $suffix}
    return $global:remoteRoot
}
function global:Invoke-Command {
    param($Session,$ArgumentList,$ScriptBlock)
    $global:remoteCalls++
    if($global:remoteCalls -eq 1){return [pscustomobject]@{model='Virtual Machine';manufacturer='Microsoft Corporation';biosUuid='11111111-2222-4333-8444-555555555555';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;profile='C:\Users\fixture';identityName='fixture\user';interactiveUser='fixture\user'}}
    $arguments=@($ArgumentList)
    $arguments[0]=Map-GuestPath ([string]$arguments[0])
    & $ScriptBlock @arguments
}
function global:Copy-Item {
    param($LiteralPath,$Destination,$ToSession,$ErrorAction)
    $mapped=Map-GuestPath ([string]$Destination)
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $mapped -ErrorAction Stop
}
$credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
& $Stager -VMName 'qicheng-win-1' -ExpectedVMId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -PayloadDirectory $Payload -Version 'candidate-1' -Credential $credential -Apply -Compact
exit $LASTEXITCODE
'@|Set-Content -LiteralPath $stageApplyHarness -Encoding UTF8
    foreach($variant in @(@{Source=$payload;Wechat=$false;Name='legacy'},@{Source=$withWechat;Wechat=$true;Name='with-wechat'})){
        $applyRoot=Join-Path $root ('simulated-apply-'+$variant.Name)
        $applyOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stageApplyHarness -Stager $stager -Payload $variant.Source -RemoteRoot $applyRoot 2>&1
        Assert ($LASTEXITCODE -eq 0 -and ($applyOutput|ConvertFrom-Json).status -eq 'staged') "Simulated Stage Apply failed: $($applyOutput -join ' ')"
        if($variant.Wechat){Assert ((Get-Acl -LiteralPath (Join-Path $applyRoot '.local\wechat.json')).AreAccessRulesProtected) 'Simulated Apply must protect the copied sidecar ACL.'}
    }
    $applyHarness=Join-Path $root 'apply-harness.ps1'
    @'
param($Stager,$Payload,$Mode)
function global:Get-VM { [pscustomobject]@{Name='qicheng-win-1';Id=[guid]'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';State='Running'} }
function global:Get-CimInstance { [pscustomobject]@{VirtualSystemType='Microsoft:Hyper-V:System:Realized';BIOSGUID='11111111-2222-4333-8444-555555555555'} }
function global:New-PSSession { [pscustomobject]@{Fake=$true} }
function global:Remove-PSSession {}
$global:remoteCalls=0
function global:Invoke-Command {
    $global:remoteCalls++
    if($global:remoteCalls -eq 1){return [pscustomobject]@{model='Virtual Machine';manufacturer='Microsoft Corporation';biosUuid='11111111-2222-4333-8444-555555555555';sid='S-1-5-21-1-2-3-4';profile='C:\Users\fixture';identityName='fixture\user';interactiveUser='fixture\user'}}
    if($global:remoteCalls -eq 2){return ($Mode -eq 'existing')}
    throw 'Synthetic creation failure after write attempt.'
}
$credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
& $Stager -VMName 'qicheng-win-1' -ExpectedVMId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -PayloadDirectory $Payload -Version 'candidate-1' -Credential $credential -Apply -Compact
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $applyHarness -Encoding ASCII
    $existingOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $applyHarness -Stager $stager -Payload $payload -Mode existing 2>&1
    Assert ($LASTEXITCODE -eq 2 -and ($existingOutput|ConvertFrom-Json).status -eq 'refused-existing-version-no-write') 'Existing staged version must report a no-write refusal.'
    $partialOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $applyHarness -Stager $stager -Payload $payload -Mode partial 2>&1
    Assert ($LASTEXITCODE -eq 2 -and ($partialOutput|ConvertFrom-Json).status -eq 'partial-stage-preserved') 'Failure after the creation attempt must report a partial stage.'
    $ast=[Management.Automation.Language.Parser]::ParseFile($switcher,[ref]$null,[ref]$null)
    foreach($name in @('Test-SafeVersionPath','Test-StagedVersion')){
        $definition=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
        Assert ($definition.Count -eq 1) "Switch validator $name must exist exactly once."
        Invoke-Expression $definition[0].Extent.Text
    }
    $manifestPath=Join-Path $payload 'payload-manifest.json'
    $ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Assert (Test-StagedVersion $payload $manifestPath '11111111-2222-4333-8444-555555555555' $ownerSid) 'Switch diagnostic must accept a valid staged fixture.'
    $wechatManifestPath=Join-Path $withWechat 'payload-manifest.json'
    Assert (Test-StagedVersion $withWechat $wechatManifestPath '11111111-2222-4333-8444-555555555555' $ownerSid) 'Switch diagnostic must accept a configured sidecar.'
    $wechatSaved=[IO.File]::ReadAllBytes($wechatPayloadFile)
    [IO.File]::AppendAllText($wechatPayloadFile,'tamper')
    Assert (-not(Test-StagedVersion $withWechat $wechatManifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch must reject a tampered sidecar.'
    [IO.File]::WriteAllBytes($wechatPayloadFile,$wechatSaved)
    $savedWechatAcl=Get-Acl -LiteralPath $wechatPayloadFile
    $wideAcl=Get-Acl -LiteralPath $wechatPayloadFile;$wideAcl.SetAccessRuleProtection($false,$true);Set-Acl -LiteralPath $wechatPayloadFile -AclObject $wideAcl
    Assert (-not(Test-StagedVersion $withWechat $wechatManifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch must reject an unprotected sidecar ACL.'
    Set-Acl -LiteralPath $wechatPayloadFile -AclObject $savedWechatAcl
    Move-Item -LiteralPath $wechatPayloadFile -Destination ($wechatPayloadFile+'.missing')
    Assert (-not(Test-StagedVersion $withWechat $wechatManifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch must reject a missing configured sidecar.'
    Move-Item -LiteralPath ($wechatPayloadFile+'.missing') -Destination $wechatPayloadFile
    $savedManifest=[IO.File]::ReadAllText($manifestPath)
    $empty=$savedManifest|ConvertFrom-Json;$empty.files=@();[IO.File]::WriteAllText($manifestPath,($empty|ConvertTo-Json -Depth 8))
    Assert (-not(Test-StagedVersion $payload $manifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch diagnostic must reject empty file inventories.'
    [IO.File]::WriteAllText($manifestPath,$savedManifest)
    $extra=Join-Path $payload 'unexpected.bin';[IO.File]::WriteAllText($extra,'extra')
    Assert (-not(Test-StagedVersion $payload $manifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch diagnostic must reject unlisted files.'
    Remove-Item -LiteralPath $extra
    $unsafe=$savedManifest|ConvertFrom-Json;$unsafe.files[0].path='../escape';[IO.File]::WriteAllText($manifestPath,($unsafe|ConvertTo-Json -Depth 8))
    Assert (-not(Test-StagedVersion $payload $manifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch diagnostic must reject unsafe paths.'
    [IO.File]::WriteAllText($manifestPath,$savedManifest)
    $originalAcl=Get-Acl -LiteralPath $payload
    $acl=Get-Acl -LiteralPath $payload
    $acl.SetAccessRuleProtection($false,$true);Set-Acl -LiteralPath $payload -AclObject $acl
    Assert (-not(Test-StagedVersion $payload $manifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch diagnostic must reject unprotected version ACL.'
    Set-Acl -LiteralPath $payload -AclObject $originalAcl
    [IO.File]::AppendAllText((Join-Path $payload 'guest\agent.py'),'tamper')
    $stageOutput=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stageHarness -Stager $stager -Payload $payload 2>&1
    Assert ($LASTEXITCODE -eq 2) 'Stage must reject a tampered payload.'
    $switchSource=Get-Content $switcher -Raw
    Assert ($switchSource -notmatch 'Copy-Item|Remove-Item') 'Switch must preserve staged and legacy files.'
    Assert (-not(Test-StagedVersion $payload $manifestPath '11111111-2222-4333-8444-555555555555' $ownerSid)) 'Switch diagnostic must reject hash tampering.'
    Assert ($switchSource -match 'refused-existing-version-no-write' -eq $false) 'Switch source must not claim staging outcomes.'
    $stageSource=Get-Content $stager -Raw
    Assert ($stageSource.Contains('refused-existing-version-no-write') -and $stageSource.Contains('partial-stage-preserved')) 'Stage must distinguish existing version refusal from partial write.'
    Assert ($switchSource.Contains("'-B -m guest.agent")) 'Candidate task must disable bytecode writes.'
    [pscustomobject]@{passed=50;failed=0;guestSessions=0;vmChanges=0}|ConvertTo-Json -Compress
}
finally { if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force} }
