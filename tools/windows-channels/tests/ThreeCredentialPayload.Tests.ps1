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
param($Builder,$Python,$Output,$Channel,$Broker,$Human)
function global:Get-AuthenticodeSignature { [pscustomobject]@{Status=[Management.Automation.SignatureStatus]::Valid;SignerCertificate=[pscustomobject]@{Subject='CN=Python Software Foundation';Issuer='CN=Test'}} }
& $Builder -EmbeddedPythonDirectory $Python -OutputDirectory $Output -BIOSUUID '11111111-2222-4333-8444-555555555555' -ChannelTokenFile $Channel -BrokerTokenFile $Broker -HumanTokenFile $Human -Compact
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $harness -Encoding ASCII
    $payload=Join-Path $root 'payload'
    $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Builder $builder -Python $python -Output $payload -Channel $paths[0] -Broker $paths[1] -Human $paths[2] 2>&1
    Assert ($LASTEXITCODE -eq 0) "Three-credential build failed: $($output -join ' ')"
    $result=$output|ConvertFrom-Json
    Assert ($result.credentialMode -eq 'channel-broker-human') 'Build result must identify three-credential mode.'
    $manifest=Get-Content (Join-Path $payload 'payload-manifest.json') -Raw|ConvertFrom-Json
    Assert ($manifest.schemaVersion -eq 2) 'Three-credential manifest must be version 2.'
    Assert ((@($manifest.tokenPaths) -join '|') -eq '.local/channel.token|.local/broker.token|.local/human.token') 'Manifest must list three credential paths.'
    foreach($name in @('channel','broker','human')){Assert (Test-Path (Join-Path $payload ".local\$name.token")) 'Credential file is missing.'}
    $start=Get-Content (Join-Path $payload 'Start-Channel.cmd') -Raw
    Assert ($start.Contains('python.exe" -B -m guest.agent')) 'Start command must disable bytecode writes.'
    foreach($flag in @('--token-file','--broker-token-file','--human-token-file')){Assert ($start.Contains($flag)) 'Start command must contain each credential flag.'}
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
    [pscustomobject]@{passed=26;failed=0;guestSessions=0;vmChanges=0}|ConvertTo-Json -Compress
}
finally { if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force} }
