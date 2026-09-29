[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$VerifiedDebPath)
$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('qicheng-wechat-reuse-'+[guid]::NewGuid().ToString('N'))
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT: $Message"}}
try{
    $expectedDeb='c5246f3f7548905a8e768ed464d9f6400e3a59d0cd539f1fe6a85dde29860457'
    Assert-True ((Get-FileHash -LiteralPath $VerifiedDebPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedDeb) 'verified DEB hash mismatch'
    New-Item -ItemType Directory -Path $testRoot|Out-Null
    $install=Join-Path $testRoot 'installed'
    Copy-Item -LiteralPath $PackageRoot -Destination $install -Recurse
    New-Item -ItemType Directory -Path (Join-Path $install '.local') -Force|Out-Null
    $record=[ordered]@{schemaVersion=1;product='Qicheng Lite';version='0.2.0-alpha.18-local';dataRoot=(Join-Path $testRoot 'data');channelCount=2;desktopApp='wechat'}
    $record|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $install '.local/channel.token'),('a'*64),[Text.UTF8Encoding]::new($false))
    $fakeDocker=Join-Path $testRoot 'fake-docker.ps1'
    $env:QICHENG_REUSE_TEST_INSTALL=$install
    $env:QICHENG_REUSE_TEST_LOG=Join-Path $testRoot 'docker.log'
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArgs,[switch]$show)
if($show){$DockerArgs+='--show'}
Add-Content -LiteralPath $env:QICHENG_REUSE_TEST_LOG -Value ($DockerArgs -join ' ')
$global:LASTEXITCODE=0
if($DockerArgs[0] -eq 'context'){'npipe:////./pipe/docker_engine';return}
if($DockerArgs[0] -eq 'info'){'linux';return}
if($DockerArgs[0] -eq 'image' -and $DockerArgs[1] -eq 'inspect'){
    if($DockerArgs[-1] -eq 'qicheng-agent-channels:0.1-local'){'sha256:base';return}
    if($DockerArgs[-1] -eq 'qicheng-agent-channels-wechat:2.02.2608070-2-local'){'sha256:wechat';return}
    if($DockerArgs[-1] -match '^qicheng-agent-channels-wechat:repair-source-'){'sha256:wechat';return}
    if($DockerArgs[-1] -match '^qicheng-agent-channels-wechat:preflight-'){'sha256:new-wechat';return}
}
if($DockerArgs[0] -eq 'image' -and $DockerArgs[1] -in @('tag','rm')){
    if($env:QICHENG_REUSE_TEST_CASE -eq 'fail-full-build' -and $DockerArgs[1] -eq 'rm'){Write-Error 'No such image';return}
    if($env:QICHENG_REUSE_TEST_CASE -eq 'fail-promote' -and $DockerArgs[1] -eq 'tag' -and $DockerArgs[-1] -eq 'qicheng-agent-channels-wechat:2.02.2608070-2-local' -and $DockerArgs[-2] -match ':preflight-'){exit 13}
    return
}
if($DockerArgs[0] -eq 'run'){
    if($env:QICHENG_REUSE_TEST_CASE -eq 'bad-version'){"io.github.msojocs.wechat-devtools-linux`t2.02.0000000-0";return}
    "io.github.msojocs.wechat-devtools-linux`t2.02.2608070-2";return
}
if($DockerArgs[0] -eq 'compose' -and $DockerArgs -contains 'config'){
    $image=if($env:QICHENG_REUSE_TEST_CASE -eq 'bad-config'){'foreign/image:latest'}else{'qicheng-agent-channels-wechat:2.02.2608070-2-local'}
    @{services=@{channel1=@{image=$image};channel2=@{image=$image}}}|ConvertTo-Json -Depth 4 -Compress
    return
}
if($DockerArgs[0] -eq 'compose' -and $DockerArgs -contains 'ps'){
    if($DockerArgs[-1] -eq 'channel1'){'111111111111';return}
    if($DockerArgs[-1] -eq 'channel2'){'222222222222';return}
}
if($DockerArgs[0] -eq 'inspect'){
    $channel=if($DockerArgs[-1] -eq '111111111111'){1}else{2}
    if($DockerArgs[2] -eq '{{.Image}}'){
        if($env:QICHENG_REUSE_TEST_CASE -eq 'bad-runtime'){'sha256:foreign'}else{'sha256:wechat'}
        return
    }
    if($DockerArgs[2] -eq '{{json .Config.Labels}}'){
        $root=$env:QICHENG_REUSE_TEST_INSTALL
        $files=@((Join-Path $root 'compose.yaml'),(Join-Path $root 'compose.wechat.yaml'))
        if($env:QICHENG_REUSE_TEST_CASE -eq 'bad-owner'){$files[1]=Join-Path $root 'foreign.yaml'}
        @{ 'com.docker.compose.project'='qicheng-agent-channels';'com.docker.compose.service'="channel$channel";'com.docker.compose.project.working_dir'=$root;'com.docker.compose.project.config_files'=($files -join ',') }|ConvertTo-Json -Compress
        return
    }
    if($DockerArgs[2] -eq '{{json .Mounts}}'){
        $name=if($env:QICHENG_REUSE_TEST_CASE -eq 'bad-volume'){'foreign-home'}else{"qicheng-lite-home-$channel"}
        ConvertTo-Json -InputObject @(@{Type='volume';Name=$name;Destination='/home/channel'}) -Compress
        return
    }
}
if($DockerArgs[0] -eq 'create'){'bbbbbbbbbbbb';return}
if($DockerArgs[0] -eq 'cp'){
    Get-ChildItem -LiteralPath (Join-Path $env:QICHENG_REUSE_TEST_INSTALL 'backend') -Force|Copy-Item -Destination $DockerArgs[-1] -Recurse
    return
}
if($DockerArgs[0] -eq 'rm'){return}
if($DockerArgs[0] -eq 'build'){
    if($env:QICHENG_REUSE_TEST_CASE -eq 'fail-full-build'){exit 12}
    return
}
throw ('Unexpected Docker call: '+($DockerArgs -join ' '))
'@|Set-Content -LiteralPath $fakeDocker -Encoding UTF8
    $installer=Join-Path $PackageRoot 'Install-Qicheng-Lite.ps1'
    $options=@{PackageRoot=$PackageRoot;InstallRoot=$install;DataRoot=(Join-Path $testRoot 'data');StartMenuRoot=(Join-Path $testRoot 'menu');DesktopRoot=(Join-Path $testRoot 'desktop');StartupRoot=(Join-Path $testRoot 'startup');LegacyStartupRoot=(Join-Path $testRoot 'legacy');DockerPath=$fakeDocker;ReuseExistingBackendImage=$true;WechatDebPath=$VerifiedDebPath;NonInteractive=$true}
    foreach($case in @('good','bad-config','bad-runtime','bad-owner','bad-volume')){
        $env:QICHENG_REUSE_TEST_CASE=$case
        $errorText=''
        $result=$null
        try{$result=(& $installer @options|Out-String|ConvertFrom-Json)}catch{$errorText=$_.Exception.Message}
        if($case -eq 'good'){Assert-True ($result.status -eq 'upgrade-preview' -and $result.desktopApp -eq 'wechat' -and -not $result.hostChangesMade) "valid WeChat reuse preview failed: $errorText"}
        else{Assert-True ($errorText -match '拒绝复用') "$case was accepted: $errorText"}
    }
    Assert-True ((Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json).version -eq '0.2.0-alpha.18-local') 'preview changed old record'
    $env:QICHENG_REUSE_TEST_CASE='fail-promote'
    $promotionError=''
    try{& $installer @options -Apply|Out-Null}catch{$promotionError=$_.Exception.Message}
    $promotionCalls=Get-Content -LiteralPath $env:QICHENG_REUSE_TEST_LOG -Raw
    Assert-True ($promotionError -match '镜像切换失败' -and $promotionCalls -match 'image tag qicheng-agent-channels-wechat:2\.02\.2608070-2-local qicheng-agent-channels-wechat:backup-' -and $promotionCalls -match 'image tag qicheng-agent-channels-wechat:backup-[0-9a-f]{32} qicheng-agent-channels-wechat:2\.02\.2608070-2-local') 'promotion failure did not restore full WeChat tag'
    Assert-True ((Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json).version -eq '0.2.0-alpha.18-local') 'promotion failure changed old install'
    $repairOptions=$options.Clone();$repairOptions.Remove('ReuseExistingBackendImage');$repairOptions.Remove('WechatDebPath');$repairOptions.RepairExistingWechatImage=$true
    $env:QICHENG_REUSE_TEST_CASE='bad-version'
    $versionError=''
    try{& $installer @repairOptions -Apply|Out-Null}catch{$versionError=$_.Exception.Message}
    Assert-True ($versionError -match 'DevTools 安装版本不匹配' -and (Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json).version -eq '0.2.0-alpha.18-local') "wrong installed DevTools version was accepted: $versionError"
    $fullOptions=$repairOptions.Clone();$fullOptions.Remove('RepairExistingWechatImage')
    $env:QICHENG_REUSE_TEST_CASE='fail-full-build'
    $buildError=''
    try{& $installer @fullOptions -Apply|Out-Null}catch{$buildError=$_.Exception.Message}
    Assert-True ($buildError -match 'Lite 底座预构建失败' -and $buildError -notmatch 'No such image') 'temporary image cleanup masked original build failure'
    $env:QICHENG_REUSE_TEST_CASE='good'
    $repair=(& $installer @repairOptions -Apply|Out-String|ConvertFrom-Json)
    $repairRecord=Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json
    $repairCalls=Get-Content -LiteralPath $env:QICHENG_REUSE_TEST_LOG -Raw
    Assert-True ($repair.status -eq 'installed' -and $repair.wechatPackageVerified -and -not $repair.imageContentVerified -and $repairRecord.backendImageMode -eq 'repair-from-verified-wechat-runtime' -and $repairRecord.sourceRuntimeImageId -eq 'sha256:wechat' -and $repairRecord.runtimeImageId -eq 'sha256:new-wechat') 'offline WeChat repair did not record package and image provenance'
    Assert-True ($repairCalls -match 'run --rm --network none --read-only --entrypoint /usr/bin/dpkg-query sha256:wechat .*io.github.msojocs.wechat-devtools-linux' -and $repairCalls -match 'image tag sha256:wechat qicheng-agent-channels-wechat:repair-source-[0-9a-f]{32}' -and $repairCalls -match 'build --network none --pull=false --build-arg BASE_IMAGE=qicheng-agent-channels-wechat:repair-source-[0-9a-f]{32} .*Dockerfile.wechat.repair' -and $repairCalls -notmatch 'build --network none .*wechat-devtools.deb') 'repair did not use verified runtime image and network none'
    $env:QICHENG_REUSE_TEST_CASE='good'
    $applied=(& $installer @options -Apply|Out-String|ConvertFrom-Json)
    $newRecord=Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json
    Assert-True ($applied.status -eq 'installed' -and $applied.imageContentVerified -and $newRecord.version -eq (Get-Content -LiteralPath (Join-Path $PackageRoot 'package-manifest.json') -Raw|ConvertFrom-Json).version) 'mock upgrade did not commit new version'
    Assert-True ($newRecord.backendImageMode -eq 'reuse-verified-base' -and $newRecord.baseImageId -eq 'sha256:base' -and $newRecord.runtimeImageId -eq 'sha256:new-wechat') 'image provenance missing from install record'
    $calls=Get-Content -LiteralPath $env:QICHENG_REUSE_TEST_LOG -Raw
    Assert-True ($calls -match 'image tag qicheng-agent-channels-wechat:preflight-[0-9a-f]{32} qicheng-agent-channels-wechat:2\.02\.2608070-2-local' -and $calls -notmatch 'image inspect --format \{\{\.Id\}\} q\r?\n') 'successful upgrade did not promote full WeChat tag'
    [ordered]@{status='passed';previewCases=5;mockApply=$true;repairApply=$true;buildFailurePreserved=$true;realDockerTouched=$false;realInstallationTouched=$false}|ConvertTo-Json
}finally{
    Remove-Item Env:QICHENG_REUSE_TEST_INSTALL -ErrorAction SilentlyContinue
    Remove-Item Env:QICHENG_REUSE_TEST_CASE -ErrorAction SilentlyContinue
    Remove-Item Env:QICHENG_REUSE_TEST_LOG -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if((Test-Path -LiteralPath $resolved) -and [IO.Path]::GetDirectoryName($resolved).Equals($base,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^qicheng-wechat-reuse-[0-9a-f]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
