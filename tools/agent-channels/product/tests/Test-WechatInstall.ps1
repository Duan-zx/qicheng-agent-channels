[CmdletBinding()]
param([string]$VerifiedDebPath)
$ErrorActionPreference='Stop'
$moduleRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('qicheng-wechat-install-test-'+[guid]::NewGuid().ToString('N'))
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT: $Message"}}
try{
    New-Item -ItemType Directory -Path $testRoot|Out-Null
    $packageOutput=Join-Path $testRoot 'package-output'
    $built=(& (Join-Path $moduleRoot 'product\Build-Package.ps1') -OutputDirectory $packageOutput|Out-String|ConvertFrom-Json)
    $package=$built.windows.directory
    . (Join-Path $package 'Product.Common.ps1')
    Assert-True (Test-QichengLiteDesktopState -DesktopApp wechat -State ([pscustomobject]@{desktop_app='wechat';gui_alive=$true})) 'live WeChat state was rejected'
    Assert-True (-not(Test-QichengLiteDesktopState -DesktopApp wechat -State ([pscustomobject]@{desktop_app='wechat';gui_alive=$false}))) 'dead WeChat GUI was accepted'
    Assert-True (-not(Test-QichengLiteDesktopState -DesktopApp wechat -State ([pscustomobject]@{input_target='private-linux-display'}))) 'legacy private display was accepted as WeChat GUI'
    $install=Join-Path $testRoot 'installed'
    $data=Join-Path $testRoot 'data'
    $menu=Join-Path $testRoot 'menu'
    $desktop=Join-Path $testRoot 'desktop'
    $startup=Join-Path $testRoot 'startup'
    $legacy=Join-Path $testRoot 'legacy'
    New-Item -ItemType Directory -Path $install,(Join-Path $install '.local'),$menu,$desktop,$startup,$legacy|Out-Null
    $oldRecord=[ordered]@{schemaVersion=1;product='Qicheng Lite';version='old';dataRoot=$data;channelCount=1;desktopApp='firefox'}
    $oldRecord|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $install '.local\channel.token'),('a'*64),[Text.UTF8Encoding]::new($false))
    Set-Content -LiteralPath (Join-Path $install 'old-sentinel.txt') -Value 'preserve' -NoNewline
    $fakeDocker=Join-Path $testRoot 'fake-docker.ps1'
    $log=Join-Path $testRoot 'docker.log'
    $env:QICHENG_WECHAT_TEST_DOCKER_LOG=$log
    $env:QICHENG_WECHAT_TEST_INSTALL=$install
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArgs)
Add-Content -LiteralPath $env:QICHENG_WECHAT_TEST_DOCKER_LOG -Value ($DockerArgs -join ' ')
if($DockerArgs[0] -eq 'context'){$global:LASTEXITCODE=0;'npipe:////./pipe/docker_engine';return}
if($DockerArgs[0] -eq 'info'){$global:LASTEXITCODE=0;'linux';return}
if($DockerArgs[0] -eq 'build'){
    if($env:QICHENG_WECHAT_TEST_FAIL -eq 'wechat' -and ($DockerArgs -join ' ') -match 'Dockerfile.wechat'){exit 12}
    $global:LASTEXITCODE=0
    return
}
if($DockerArgs[0] -eq 'image'){
    if($env:QICHENG_WECHAT_TEST_FAIL -eq 'promote' -and $DockerArgs[1] -eq 'tag' -and $DockerArgs[-1] -eq 'qicheng-agent-channels-wechat:2.02.2608070-2-local' -and $DockerArgs[-2] -match ':preflight-'){exit 13}
    $global:LASTEXITCODE=0
    if($DockerArgs[1] -eq 'inspect'){'sha256:mock-image';return}
    if($DockerArgs[1] -in @('tag','rm')){return}
}
if($DockerArgs[0] -eq 'compose'){
    $global:LASTEXITCODE=0
    if($DockerArgs -contains 'config'){@{services=@{channel1=@{image='qicheng-agent-channels:0.1-local'}}}|ConvertTo-Json -Depth 4 -Compress;return}
    ('a'*64);return
}
if($DockerArgs[0] -eq 'inspect'){
    $global:LASTEXITCODE=0
    if($DockerArgs[2] -eq '{{.Image}}'){'sha256:mock-image';return}
    if($DockerArgs[2] -eq '{{json .Config.Labels}}'){
        @{ 'com.docker.compose.project'='qicheng-agent-channels';'com.docker.compose.service'='channel1';'com.docker.compose.project.working_dir'=$env:QICHENG_WECHAT_TEST_INSTALL;'com.docker.compose.project.config_files'=(Join-Path $env:QICHENG_WECHAT_TEST_INSTALL 'compose.yaml') }|ConvertTo-Json -Compress
        return
    }
    if($DockerArgs[2] -eq '{{json .Mounts}}'){@(@{Type='volume';Name='qicheng-lite-home-1';Destination='/home/channel'})|ConvertTo-Json -Compress;return}
}
if($DockerArgs[0] -eq 'create'){$global:LASTEXITCODE=0;('b'*64);return}
if($DockerArgs[0] -eq 'cp'){
    $global:LASTEXITCODE=0
    $destination=$DockerArgs[-1]
    Get-ChildItem -LiteralPath (Join-Path $env:QICHENG_WECHAT_TEST_INSTALL 'backend') -Force | Copy-Item -Destination $destination -Recurse
    return
}
if($DockerArgs[0] -eq 'rm'){$global:LASTEXITCODE=0;return}
throw ('Unexpected Docker call: '+($DockerArgs -join ' '))
'@|Set-Content -LiteralPath $fakeDocker -Encoding UTF8
    $options=@{PackageRoot=$package;InstallRoot=$install;DataRoot=$data;StartMenuRoot=$menu;DesktopRoot=$desktop;StartupRoot=$startup;LegacyStartupRoot=$legacy;DockerPath=$fakeDocker;DesktopApp='wechat';Confirm=$false}
    $badDeb=Join-Path $testRoot 'bad.deb';[IO.File]::WriteAllText($badDeb,'not the verified package')
    $badOptions=$options.Clone();$badOptions.ReuseExistingBackendImage=$true;$badOptions.WechatDebPath=$badDeb
    $badError=''
    try{& (Join-Path $package 'Install-Qicheng-Lite.ps1') @badOptions|Out-Null}catch{$badError=$_.Exception.Message}
    Assert-True ($badError -match 'SHA-256 不匹配') 'wrong local DEB hash was accepted'
    Assert-True (-not(Test-Path -LiteralPath $log)) 'wrong hash invoked Docker before rejection'
    $relativeOptions=$options.Clone();$relativeOptions.ReuseExistingBackendImage=$true;$relativeOptions.WechatDebPath='bad.deb'
    $relativeError=''
    try{& (Join-Path $package 'Install-Qicheng-Lite.ps1') @relativeOptions|Out-Null}catch{$relativeError=$_.Exception.Message}
    Assert-True ($relativeError -match '本机绝对路径') 'relative DEB path was accepted'
    $env:QICHENG_WECHAT_TEST_FAIL='wechat'
    $failure=''
    try{& (Join-Path $package 'Install-Qicheng-Lite.ps1') @options -Apply -ErrorAction Stop|Out-Null}catch{$failure=$_.Exception.Message}
    Assert-True ($failure -match '预构建失败' -or $failure -match 'SHA-256') 'mocked download/build failure was not reported'
    Assert-True ((Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json).desktopApp -eq 'firefox') 'failed build changed installed desktop choice'
    Assert-True (Test-Path -LiteralPath (Join-Path $install 'old-sentinel.txt')) 'failed build removed old installation'
    Assert-True ((Get-Content -LiteralPath $log -Raw) -notmatch 'image tag .*0\.1-local|image tag .*2\.02\.2608070-2-local') 'failed prebuild changed final image tags'
    $env:QICHENG_WECHAT_TEST_FAIL='promote'
    $promotionFailure=''
    try{& (Join-Path $package 'Install-Qicheng-Lite.ps1') @options -Apply -ErrorAction Stop|Out-Null}catch{$promotionFailure=$_.Exception.Message}
    Assert-True ($promotionFailure -match '镜像切换失败') 'mocked image promotion failure was not reported'
    Assert-True ((Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json).desktopApp -eq 'firefox') 'promotion failure changed installed choice'
    Assert-True (Test-Path -LiteralPath (Join-Path $install 'old-sentinel.txt')) 'promotion failure removed old installation'
    Assert-True ((Get-Content -LiteralPath $log -Raw) -match 'image tag qicheng-agent-channels:backup-.*qicheng-agent-channels:0\.1-local') 'promotion failure did not restore old base image tag'
    $env:QICHENG_WECHAT_TEST_FAIL=''
    $installed=(& (Join-Path $package 'Install-Qicheng-Lite.ps1') @options -Apply|Out-String|ConvertFrom-Json)
    Assert-True ($installed.status -eq 'installed' -and $installed.desktopApp -eq 'wechat') 'apply without launch did not commit prepared image and choice'
    Assert-True ((Get-Content -LiteralPath (Join-Path $install '.qicheng-lite-install.json') -Raw|ConvertFrom-Json).desktopApp -eq 'wechat') 'wechat choice missing from installation record'
    $inheritOptions=$options.Clone();$inheritOptions.Remove('DesktopApp')
    $preview=(& (Join-Path $package 'Install-Qicheng-Lite.ps1') @inheritOptions|Out-String|ConvertFrom-Json)
    Assert-True ($preview.desktopApp -eq 'wechat' -and -not $preview.hostChangesMade) 'upgrade preview did not inherit wechat choice'
    $calls=Get-Content -LiteralPath $log -Raw
    Assert-True ($calls -match 'BASE_IMAGE=qicheng-agent-channels:preflight-' -and $calls -match 'image tag qicheng-agent-channels-wechat:preflight-.*qicheng-agent-channels-wechat:2\.02\.2608070-2-local') 'candidate image was not promoted'
    $offlineVerified=$false
    if($VerifiedDebPath){
        Assert-True ((Get-FileHash -LiteralPath $VerifiedDebPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq 'c5246f3f7548905a8e768ed464d9f6400e3a59d0cd539f1fe6a85dde29860457') 'provided DEB hash mismatch'
        $recordPath=Join-Path $install '.qicheng-lite-install.json'
        $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
        $record.desktopApp='firefox'
        $record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $recordPath -Encoding UTF8
        $beforeBaseTags=@(Get-Content -LiteralPath $log | Where-Object{$_ -match '^image tag .*qicheng-agent-channels:0\.1-local$'}).Count
        $offlineOptions=$options.Clone();$offlineOptions.ReuseExistingBackendImage=$true;$offlineOptions.WechatDebPath=$VerifiedDebPath
        $offline=(& (Join-Path $package 'Install-Qicheng-Lite.ps1') @offlineOptions -Apply|Out-String|ConvertFrom-Json)
        Assert-True ($offline.status -eq 'installed' -and $offline.desktopApp -eq 'wechat' -and $offline.imageContentVerified) 'local DEB upgrade did not complete'
        $offlineCalls=Get-Content -LiteralPath $log -Raw
        Assert-True ($offlineCalls -match 'build --pull=false .*Dockerfile.wechat.offline' -and $offlineCalls -notmatch 'build --pull=false .*Dockerfile.wechat.offline.*qicheng-agent-channels:preflight-') 'offline build did not use local base tag'
        $afterBaseTags=@(Get-Content -LiteralPath $log | Where-Object{$_ -match '^image tag .*qicheng-agent-channels:0\.1-local$'}).Count
        Assert-True ($beforeBaseTags -eq $afterBaseTags) 'offline upgrade mutated Lite base image tag'
        Assert-True (-not @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'qicheng-wechat-offline-*' | Where-Object{$_.CreationTime -gt (Get-Date).AddMinutes(-2) -and $_.Name -match '^qicheng-wechat-offline-[0-9a-f]{32}$'}).Count) 'offline DEB staging directory remains'
        $offlineVerified=$true
    }
    [ordered]@{status='passed';failurePreservedOldInstall=$true;promotionFailureRestoredTag=$true;applyWithoutLaunchPreparedImage=$true;upgradeInheritedChoice=$true;localDebMockUpgrade=$offlineVerified;realDockerTouched=$false;realDesktopTouched=$false}|ConvertTo-Json
}finally{
    Remove-Item Env:QICHENG_WECHAT_TEST_DOCKER_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:QICHENG_WECHAT_TEST_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:QICHENG_WECHAT_TEST_INSTALL -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^qicheng-wechat-install-test-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $resolved)){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
