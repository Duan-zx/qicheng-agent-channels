[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [string]$PackageRoot,
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$ImportTokenPath,
    [string]$ImportBrokerTokenPath,
    [string]$StartMenuRoot,
    [string]$DesktopRoot,
    [string]$StartupRoot,
    [string]$LegacyStartupRoot,
    [switch]$DisableLegacyWindowsChannelsStartup,
    [switch]$LaunchAfterInstall,
    [switch]$ReuseExistingBackendImage,
    [string]$DockerPath='docker',
    [ValidateRange(1,45)][int]$HealthAttempts=45,
    [int]$Port1=18761,
    [int]$Port2=18762,
    [ValidateSet(1,2)][int]$ChannelCount=0,
    [switch]$NonInteractive,
    [switch]$Apply
)

$ErrorActionPreference='Stop'
if($NonInteractive){$ConfirmPreference='None'}
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if($Port1 -ne 18761 -or $Port2 -ne 18762){throw '端口契约固定为 18761/18762；请移除自定义端口参数。'}
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=Get-QichengLiteInstallRoot}
if([string]::IsNullOrWhiteSpace($PackageRoot)){$PackageRoot=$PSScriptRoot}
$packageRoot=Resolve-QichengLitePath -Path $PackageRoot -Label 'PackageRoot'
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$existingRecord=Read-QichengLiteInstallRecord -InstallRoot $installRoot
if($ChannelCount -eq 0){$ChannelCount=if($existingRecord){Get-QichengLiteChannelCount -Record $existingRecord}else{1}}
if([string]::IsNullOrWhiteSpace($DataRoot)){
    $DataRoot=if($existingRecord -and -not[string]::IsNullOrWhiteSpace([string]$existingRecord.dataRoot)){[string]$existingRecord.dataRoot}else{Get-QichengLiteDataRoot}
}
if([string]::IsNullOrWhiteSpace($StartMenuRoot)){$StartMenuRoot=Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\启程轻量工作台'}
if([string]::IsNullOrWhiteSpace($DesktopRoot)){$DesktopRoot=[Environment]::GetFolderPath('DesktopDirectory')}
if([string]::IsNullOrWhiteSpace($StartupRoot)){$StartupRoot=[Environment]::GetFolderPath('Startup')}
if([string]::IsNullOrWhiteSpace($LegacyStartupRoot)){$LegacyStartupRoot=[Environment]::GetFolderPath('Startup')}
$dataRoot=Resolve-QichengLitePath -Path $DataRoot -Label 'DataRoot'
$startMenuRoot=Resolve-QichengLitePath -Path $StartMenuRoot -Label 'StartMenuRoot'
$desktopRoot=Resolve-QichengLitePath -Path $DesktopRoot -Label 'DesktopRoot'
$startupRoot=Resolve-QichengLitePath -Path $StartupRoot -Label 'StartupRoot'
$legacyStartupRoot=Resolve-QichengLitePath -Path $LegacyStartupRoot -Label 'LegacyStartupRoot'
if($installRoot.TrimEnd('\') -ieq $dataRoot.TrimEnd('\')){throw 'InstallRoot 与 DataRoot 必须分开。'}

$manifestPath=Join-Path $packageRoot 'package-manifest.json'
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'package-manifest.json 缺失。'}
$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if($manifest.schemaVersion -ne 1 -or $manifest.product -ne 'Qicheng Lite' -or -not $manifest.files){throw '安装包 manifest 不受支持。'}
$expected=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($entry in $manifest.files){
    $relative=([string]$entry.path).Replace('/','\')
    $segments=@($relative -split '[\\/]')
    if([IO.Path]::IsPathRooted($relative) -or $relative -match '[:*?"<>|]' -or @($segments|Where-Object{[string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..'}).Count){throw "安装包路径不安全：$relative"}
    [void]$expected.Add($relative)
    $source=Join-Path $packageRoot $relative
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "安装包文件缺失：$relative"}
    if((Get-QichengLiteSha256 -Path $source) -ine [string]$entry.sha256){throw "安装包文件校验失败：$relative"}
}
$actual=@(Get-ChildItem -LiteralPath $packageRoot -File -Recurse|ForEach-Object{$_.FullName.Substring($packageRoot.Length).TrimStart('\')}|Where-Object{$_ -ine 'package-manifest.json'})
foreach($relative in $actual){if(-not $expected.Contains($relative)){throw "安装包白名单外文件：$relative"}}
if($actual.Count -ne $expected.Count){throw '安装包文件数量与白名单不一致。'}

# An older install record has no image provenance. Reuse is therefore an explicit
# upgrade choice, gated by the previous package's build inputs and a local image.
$imageContentVerified=$false
if($ReuseExistingBackendImage){
    if(-not $existingRecord){throw '离线复用只适用于已有 Lite 安装；首次安装必须构建后端。'}
    if(-not[string]::IsNullOrWhiteSpace($env:DOCKER_HOST) -and $env:DOCKER_HOST -notmatch '(?i)^npipe:////\./pipe/(docker_engine|dockerDesktopLinuxEngine)$'){throw '离线复用拒绝远端 Docker endpoint；未进行安装。'}
    $endpoint=@(& $DockerPath context inspect --format '{{.Endpoints.docker.Host}}' 2>$null)
    if($LASTEXITCODE -ne 0 -or $endpoint.Count -ne 1 -or [string]$endpoint[0] -notmatch '(?i)^npipe:////\./pipe/(docker_engine|dockerDesktopLinuxEngine)$'){throw '无法确认本机 Docker endpoint；离线复用未进行安装。'}
    $osType=@(& $DockerPath info --format '{{.OSType}}' 2>$null)
    if($LASTEXITCODE -ne 0 -or $osType.Count -ne 1 -or [string]$osType[0] -cne 'linux'){throw '本机 Docker Linux engine 不可用；离线复用未进行安装。'}
    $oldManifestPath=Join-Path $installRoot 'package-manifest.json'
    if(-not(Test-Path -LiteralPath $oldManifestPath -PathType Leaf)){throw '旧安装缺少 package-manifest.json；无法核验镜像来源。'}
    $oldManifest=Get-Content -LiteralPath $oldManifestPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    if($oldManifest.schemaVersion -ne 1 -or $oldManifest.product -ne 'Qicheng Lite'){throw '旧安装 manifest 无效；拒绝复用镜像。'}
    $buildInputs=@('.dockerignore','Dockerfile')+@(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'backend') -File -Recurse|ForEach-Object{$_.FullName.Substring($packageRoot.Length).TrimStart('\')})
    foreach($relative in $buildInputs){
        $oldPath=Join-Path $installRoot $relative
        $newPath=Join-Path $packageRoot $relative
        if(-not(Test-Path -LiteralPath $oldPath -PathType Leaf)){throw "旧安装缺少后端构建文件 $relative；拒绝复用镜像。"}
        $oldEntry=@($oldManifest.files|Where-Object{[string]$_.path -ieq $relative.Replace('\','/')})
        if($oldEntry.Count -ne 1 -or (Get-QichengLiteSha256 -Path $oldPath) -ine [string]$oldEntry[0].sha256){throw "旧安装后端文件未通过原 manifest 校验：$relative。"}
        if($relative -eq 'Dockerfile'){
            $oldText=[IO.File]::ReadAllText($oldPath).Replace("`r`n","`n")
            $newText=[IO.File]::ReadAllText($newPath).Replace("`r`n","`n")
            # The alpha.14 browser chrome change is supplied by Compose as well.
            $themeLine='ENV DISPLAY=:99 SCREEN_WIDTH=1600 SCREEN_HEIGHT=900 GTK_THEME=Adwaita:dark'
            $baseLine='ENV DISPLAY=:99 SCREEN_WIDTH=1600 SCREEN_HEIGHT=900'
            if($newText -ne $oldText -and -not($newText.Replace($themeLine,$baseLine) -ceq $oldText)){
                throw 'Dockerfile 后端构建内容已变化；拒绝复用旧镜像。'
            }
        }elseif((Get-QichengLiteSha256 -Path $oldPath) -ine (Get-QichengLiteSha256 -Path $newPath)){
            throw "后端构建文件已变化：$relative；拒绝复用旧镜像。"
        }
    }
    $oldBackend=@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'backend') -File -Recurse|ForEach-Object{$_.FullName.Substring($installRoot.Length).TrimStart('\')})
    if(@($oldBackend|Where-Object{$buildInputs -inotcontains $_}).Count){throw '旧安装含有新包未声明的后端文件；拒绝复用旧镜像。'}
    $imageId=@(& $DockerPath image inspect --format '{{.Id}}' 'qicheng-agent-channels:0.1-local' 2>$null)
    if($LASTEXITCODE -ne 0 -or $imageId.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$imageId[0])){
        throw '本地缺少 qicheng-agent-channels:0.1-local 镜像；离线复用未进行安装。'
    }
    $oldCompose=Join-Path $installRoot 'compose.yaml'
    $oldComposeArgs=@('compose','--project-name','qicheng-agent-channels','--project-directory',$installRoot,'-f',$oldCompose)
    if(Test-Path -LiteralPath (Join-Path $installRoot '.local\broker.token') -PathType Leaf){$oldComposeArgs+=@('-f',(Join-Path $installRoot 'compose.broker.yaml'))}
    $oldChannelCount=Get-QichengLiteChannelCount -Record $existingRecord
    foreach($channel in 1..$oldChannelCount){
        $containerIds=@(& $DockerPath @oldComposeArgs --profile second ps -a -q "channel$channel" 2>$null|Where-Object{$_})
        if($LASTEXITCODE -ne 0 -or $containerIds.Count -ne 1){throw "无法核验旧频道 $channel 容器；离线复用未进行安装。"}
        $containerId=[string]$containerIds[0]
        $containerImage=@(& $DockerPath inspect --format '{{.Image}}' $containerId 2>$null)
        $project=@(& $DockerPath inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' $containerId 2>$null)
        $service=@(& $DockerPath inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' $containerId 2>$null)
        $workingDir=@(& $DockerPath inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' $containerId 2>$null)
        $mountsText=@(& $DockerPath inspect --format '{{json .Mounts}}' $containerId 2>$null)
        if($LASTEXITCODE -ne 0 -or $containerImage.Count -ne 1 -or [string]$containerImage[0] -cne [string]$imageId[0] -or $project.Count -ne 1 -or [string]$project[0] -cne 'qicheng-agent-channels' -or $service.Count -ne 1 -or [string]$service[0] -cne "channel$channel" -or $workingDir.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$workingDir[0]) -or -not([IO.Path]::GetFullPath([string]$workingDir[0]).Equals($installRoot,[StringComparison]::OrdinalIgnoreCase)) -or $mountsText.Count -ne 1){throw "旧频道 $channel 的镜像或 Compose 归属不匹配；拒绝复用。"}
        $mounts=@([string]$mountsText[0]|ConvertFrom-Json -ErrorAction Stop)
        $homeMount=@($mounts|Where-Object{$_.Type -eq 'volume' -and $_.Name -ceq "qicheng-lite-home-$channel" -and $_.Destination -ceq '/home/channel'})
        if($homeMount.Count -ne 1){throw "旧频道 $channel 的持久卷归属不匹配；拒绝复用。"}
    }
    function Assert-QichengLiteImageContent {
        $probeContainer=$null
        $probeBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $probeRoot=[IO.Path]::GetFullPath((Join-Path $probeBase ('qicheng-lite-image-check-'+[guid]::NewGuid().ToString('N'))))
        $probeError=$null
        $cleanupErrors=New-Object 'System.Collections.Generic.List[string]'
        try{
            New-Item -ItemType Directory -Path $probeRoot -ErrorAction Stop|Out-Null
            $probeIds=@(& $DockerPath create --network none --read-only --entrypoint /usr/bin/true ([string]$imageId[0]) 2>$null)
            if($LASTEXITCODE -ne 0 -or $probeIds.Count -ne 1 -or [string]$probeIds[0] -notmatch '^[0-9a-f]{12,64}$'){throw '无法创建只读镜像校验容器；离线复用未进行安装。'}
            $probeContainer=[string]$probeIds[0]
            & $DockerPath cp "${probeContainer}:/app/." $probeRoot|Out-Null
            if($LASTEXITCODE -ne 0){throw '无法读取镜像内后端文件；离线复用未进行安装。'}
            $imageFiles=@(Get-ChildItem -LiteralPath $probeRoot -File -Recurse)
            if(@($imageFiles|Where-Object{($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}).Count){throw '镜像内后端包含符号链接；拒绝复用。'}
            $imageBackend=@($imageFiles|ForEach-Object{$_.FullName.Substring($probeRoot.Length).TrimStart('\').Replace('\','/')})
            $expectedBackend=@($buildInputs|Where-Object{$_ -like 'backend\*'}|ForEach-Object{$_.Substring(8).Replace('\','/')})
            if($imageBackend.Count -ne $expectedBackend.Count -or @($imageBackend|Where-Object{$expectedBackend -inotcontains $_}).Count){throw '镜像内后端文件清单不匹配；拒绝复用。'}
            foreach($relative in $expectedBackend){
                $imagePath=Join-Path $probeRoot $relative
                $oldPath=Join-Path (Join-Path $installRoot 'backend') $relative
                if(-not(Test-Path -LiteralPath $imagePath -PathType Leaf) -or (Get-QichengLiteSha256 -Path $imagePath) -ine (Get-QichengLiteSha256 -Path $oldPath)){throw "镜像内后端文件不匹配：$relative；拒绝复用。"}
            }
        }catch{$probeError=$_}
        finally{
            if($probeContainer){
                try{
                    & $DockerPath rm $probeContainer 2>$null|Out-Null
                    if($LASTEXITCODE -ne 0){throw 'Docker 探针容器删除失败。'}
                }catch{[void]$cleanupErrors.Add($_.Exception.Message)}
            }
            if(Test-Path -LiteralPath $probeRoot){
                try{
                    $resolvedProbe=[IO.Path]::GetFullPath($probeRoot)
                    if(-not([IO.Path]::GetDirectoryName($resolvedProbe).Equals($probeBase,[StringComparison]::OrdinalIgnoreCase)) -or [IO.Path]::GetFileName($resolvedProbe) -notmatch '^qicheng-lite-image-check-[0-9a-f]{32}$' -or ((Get-Item -LiteralPath $resolvedProbe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw '探针临时目录超出本次创建的安全路径；拒绝递归清理。'}
                    Remove-Item -LiteralPath $resolvedProbe -Recurse -Force -ErrorAction Stop
                    if(Test-Path -LiteralPath $resolvedProbe){throw '探针临时目录删除后仍存在。'}
                }catch{[void]$cleanupErrors.Add($_.Exception.Message)}
            }
        }
        if($cleanupErrors.Count){throw ('镜像探针清理失败；旧安装保持不变；probeContainerId='+$(if($probeContainer){$probeContainer}else{'unknown'})+'：'+($cleanupErrors -join '; '))}
        if($probeError){throw $probeError}
        return $true
    }
}

if((Test-Path -LiteralPath $installRoot) -and -not $existingRecord){throw '目标目录已存在但不是启程轻量版安装，拒绝覆盖。'}
$tokenValue=$null
if(-not[string]::IsNullOrWhiteSpace($ImportTokenPath)){
    $sourceToken=Resolve-QichengLitePath -Path $ImportTokenPath -Label 'ImportTokenPath'
    if(-not(Test-Path -LiteralPath $sourceToken -PathType Leaf)){throw '导入 token 文件不存在。'}
    $tokenValue=(Get-Content -LiteralPath $sourceToken -Raw).Trim()
} elseif($existingRecord -and (Test-Path -LiteralPath (Join-Path $installRoot '.local\channel.token') -PathType Leaf)){
    $tokenValue=(Get-Content -LiteralPath (Join-Path $installRoot '.local\channel.token') -Raw).Trim()
}
if($tokenValue -and -not(Test-QichengLiteTokenValue -Value $tokenValue)){throw 'token 必须是 64 位小写十六进制；未进行安装。'}
$brokerTokenValue=$null
if(-not[string]::IsNullOrWhiteSpace($ImportBrokerTokenPath)){
    $sourceBrokerToken=Resolve-QichengLitePath -Path $ImportBrokerTokenPath -Label 'ImportBrokerTokenPath'
    if(-not(Test-Path -LiteralPath $sourceBrokerToken -PathType Leaf)){throw 'Broker token 文件不存在。'}
    $brokerTokenValue=(Get-Content -LiteralPath $sourceBrokerToken -Raw).Trim()
} elseif($existingRecord -and (Test-Path -LiteralPath (Join-Path $installRoot '.local\broker.token') -PathType Leaf)){
    $brokerTokenValue=(Get-Content -LiteralPath (Join-Path $installRoot '.local\broker.token') -Raw).Trim()
}
if($brokerTokenValue -and -not(Test-QichengLiteTokenValue -Value $brokerTokenValue)){throw 'Broker token 必须是 64 位小写十六进制；未进行安装。'}
if($brokerTokenValue -and $tokenValue -and $brokerTokenValue -ceq $tokenValue){throw 'Broker token 必须与频道 token 不同。'}
$viewerTokenValue=$null
if($brokerTokenValue -and $existingRecord -and (Test-Path -LiteralPath (Join-Path $installRoot '.local\viewer.token') -PathType Leaf)){
    $viewerTokenValue=(Get-Content -LiteralPath (Join-Path $installRoot '.local\viewer.token') -Raw).Trim()
    if(-not(Test-QichengLiteTokenValue -Value $viewerTokenValue)){throw '查看器 token 格式无效；未进行安装。'}
    if($viewerTokenValue -ceq $brokerTokenValue -or ($tokenValue -and $viewerTokenValue -ceq $tokenValue)){throw '查看器 token 必须与其他凭据不同。'}
}

$legacyLink=Join-Path $legacyStartupRoot '启程 Windows 频道.lnk'
$legacyBackup=Join-Path $dataRoot 'compatibility-backup\启程 Windows 频道.lnk'
$selectedPorts=@(18761);if($ChannelCount -eq 2){$selectedPorts+=18762}
$plan=[ordered]@{schemaVersion=1;status=if($existingRecord){'upgrade-preview'}else{'not-installed'};version=[string]$manifest.version;installRoot=$installRoot;dataRoot=$dataRoot;files=$expected.Count;tokenAction=if($ImportTokenPath){'import'}elseif($tokenValue){'preserve'}else{'generate'};composeProject='qicheng-agent-channels';channelCount=$ChannelCount;ports=$selectedPorts;defaultViewerMode='background';backendImageAction=if($ReuseExistingBackendImage){'reuse-local-image'}else{'build'};imageContentVerified=$imageContentVerified;disableLegacyWindowsChannelsStartup=[bool]$DisableLegacyWindowsChannelsStartup;legacyShortcutPresent=(Test-Path -LiteralPath $legacyLink -PathType Leaf);volumesRemoved=$false;applyRequested=[bool]$Apply;hostChangesMade=$false}
if(-not $Apply){$plan|ConvertTo-Json -Depth 5;return}

$viewerPath=Join-Path $installRoot 'dist\AgentChannels.exe'
$running=@()
try{$running=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{[string]$_.ExecutablePath -and ([string]$_.ExecutablePath).Equals($viewerPath,[StringComparison]::OrdinalIgnoreCase)}|ForEach-Object{[ordered]@{processId=[int]$_.ProcessId;name=[string]$_.Name;role='viewer'}})}catch{}
if($running.Count){[ordered]@{schemaVersion=1;status='blocked-process-in-use';message='启程轻量工作台仍在运行。请从托盘退出后重试；当前版本保持不变。';processes=$running;existingVersionPreserved=$true;hostChangesMade=$false;imageContentVerified=$false}|ConvertTo-Json -Depth 5;return}
if(-not $PSCmdlet.ShouldProcess($installRoot,'安装或升级启程轻量版')){$plan|ConvertTo-Json -Depth 5;return}
if($ReuseExistingBackendImage){$imageContentVerified=Assert-QichengLiteImageContent}

$parent=Split-Path -Parent $installRoot
New-Item -ItemType Directory -Path $parent -Force|Out-Null
$stage=Join-Path $parent ('.QichengLite.stage.'+[guid]::NewGuid().ToString('N'))
$backup=$null
$activated=$false
$legacyRemoved=$false
$shortcutSnapshotRoot=Join-Path $parent ('.QichengLite.shortcuts.'+[guid]::NewGuid().ToString('N'))
$shortcutSnapshot=New-Object 'System.Collections.Generic.List[object]'
try{
    New-Item -ItemType Directory -Path $stage|Out-Null
    foreach($entry in $manifest.files){
        $relative=([string]$entry.path).Replace('/','\')
        $destination=Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
        Copy-Item -LiteralPath (Join-Path $packageRoot $relative) -Destination $destination
    }
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stage 'package-manifest.json')
    $tokenDirectory=Join-Path $stage '.local'
    New-Item -ItemType Directory -Path $tokenDirectory -Force|Out-Null
    if(-not $tokenValue){
        $bytes=New-Object byte[] 32
        $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try{$rng.GetBytes($bytes);$tokenValue=[BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()}finally{$rng.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
    }
    [IO.File]::WriteAllText((Join-Path $tokenDirectory 'channel.token'),$tokenValue,[Text.UTF8Encoding]::new($false))
    if($brokerTokenValue){
        if($brokerTokenValue -ceq $tokenValue){throw 'Broker token 必须与频道 token 不同。'}
        [IO.File]::WriteAllText((Join-Path $tokenDirectory 'broker.token'),$brokerTokenValue,[Text.UTF8Encoding]::new($false))
        if(-not $viewerTokenValue){
            do {
                $bytes=New-Object byte[] 32
                $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
                try{$rng.GetBytes($bytes);$viewerTokenValue=[BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()}finally{$rng.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
            } while($viewerTokenValue -ceq $tokenValue -or $viewerTokenValue -ceq $brokerTokenValue)
        }
        [IO.File]::WriteAllText((Join-Path $tokenDirectory 'viewer.token'),$viewerTokenValue,[Text.UTF8Encoding]::new($false))
    }
    $record=[ordered]@{schemaVersion=1;product='Qicheng Lite';version=[string]$manifest.version;installedAt=(Get-Date).ToUniversalTime().ToString('o');dataRoot=$dataRoot;composeProject='qicheng-agent-channels';channelCount=$ChannelCount;tokenPath='.local/channel.token';startupLink=(Join-Path $startupRoot '启程轻量工作台.lnk');startMenuRoot=$startMenuRoot;desktopLink=(Join-Path $desktopRoot '启程轻量工作台.lnk')}
    $record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $stage '.qicheng-lite-install.json') -Encoding UTF8
    if(Test-Path -LiteralPath $installRoot){$backup=Join-Path $parent ('.QichengLite.backup.'+[guid]::NewGuid().ToString('N'));Move-Item -LiteralPath $installRoot -Destination $backup}
    Move-Item -LiteralPath $stage -Destination $installRoot
    $activated=$true
    New-Item -ItemType Directory -Path $dataRoot -Force|Out-Null
    Set-QichengLitePrivateAcl -Path $dataRoot
    Set-QichengLitePrivateAcl -Path (Join-Path $installRoot '.local')
    Set-QichengLitePrivateAcl -Path (Join-Path $installRoot '.local\channel.token') -File
    if($brokerTokenValue){Set-QichengLitePrivateAcl -Path (Join-Path $installRoot '.local\broker.token') -File}
    if($brokerTokenValue){Set-QichengLitePrivateAcl -Path (Join-Path $installRoot '.local\viewer.token') -File}
    New-Item -ItemType Directory -Path $startMenuRoot,$desktopRoot,$startupRoot -Force|Out-Null
    New-Item -ItemType Directory -Path $shortcutSnapshotRoot -Force|Out-Null
    $managedShortcutPaths=@(
        (Join-Path $startMenuRoot '启程轻量工作台.lnk'),
        (Join-Path $desktopRoot '启程轻量工作台.lnk'),
        (Join-Path $startupRoot '启程轻量工作台.lnk'),
        (Join-Path $startMenuRoot '管理启程轻量工作台.lnk'),
        (Join-Path $startMenuRoot '诊断启程轻量工作台.lnk'),
        (Join-Path $startMenuRoot '取回频道一下载文件.lnk'),
        (Join-Path $startMenuRoot '取回频道二下载文件.lnk'),
        (Join-Path $startMenuRoot '恢复旧 Windows 频道自启动.lnk')
    )
    foreach($shortcutPath in $managedShortcutPaths){
        $shortcutBackup=Join-Path $shortcutSnapshotRoot ([guid]::NewGuid().ToString('N')+'.lnk')
        $shortcutExists=Test-Path -LiteralPath $shortcutPath -PathType Leaf
        if($shortcutExists){Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup}
        [void]$shortcutSnapshot.Add([pscustomobject]@{Path=$shortcutPath;Backup=$shortcutBackup;Exists=$shortcutExists})
    }
    $shell=New-Object -ComObject WScript.Shell
    function New-Link([string]$Path,[string]$Target,[string]$Arguments){
        $temporaryPath=Join-Path (Split-Path -Parent $Path) ('.qicheng-shortcut-'+[guid]::NewGuid().ToString('N')+'.lnk')
        $link=$null
        try{
            # WScript.Shell can ANSI-mangle a non-ASCII link filename on an English locale.
            # Save under an ASCII basename, release the COM object, then let .NET move it.
            $link=$shell.CreateShortcut($temporaryPath)
            $link.TargetPath=$Target
            $link.Arguments=$Arguments
            $link.WorkingDirectory=$installRoot
            $link.Save()
        }finally{
            if($null -ne $link -and [Runtime.InteropServices.Marshal]::IsComObject($link)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}
        }
        try{
            if(-not(Test-Path -LiteralPath $temporaryPath -PathType Leaf)){throw '快捷方式临时文件创建失败。'}
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        }finally{
            if(Test-Path -LiteralPath $temporaryPath){Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue}
        }
    }
    $powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
    $startScript=Join-Path $installRoot 'Start-Qicheng-Lite.ps1'
    $backgroundArgs='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$startScript+'" -Background'
    New-Link (Join-Path $startMenuRoot '启程轻量工作台.lnk') $powershell $backgroundArgs
    New-Link (Join-Path $desktopRoot '启程轻量工作台.lnk') $powershell $backgroundArgs
    New-Link (Join-Path $startupRoot '启程轻量工作台.lnk') $powershell ($backgroundArgs+' -LoginRecovery')
    New-Link (Join-Path $startMenuRoot '管理启程轻量工作台.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$startScript+'"')
    New-Link (Join-Path $startMenuRoot '诊断启程轻量工作台.lnk') $powershell ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Diagnose-Qicheng-Lite.ps1')+'"')
    New-Link (Join-Path $startMenuRoot '取回频道一下载文件.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Export-Downloads.ps1')+'" -Channel 1 -Open')
    if($ChannelCount -eq 2){New-Link (Join-Path $startMenuRoot '取回频道二下载文件.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Export-Downloads.ps1')+'" -Channel 2 -Open')}
    elseif(Test-Path -LiteralPath (Join-Path $startMenuRoot '取回频道二下载文件.lnk')){Remove-Item -LiteralPath (Join-Path $startMenuRoot '取回频道二下载文件.lnk') -Force}
    New-Link (Join-Path $startMenuRoot '恢复旧 Windows 频道自启动.lnk') $powershell ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Restore-LegacyWindowsChannelsStartup.ps1')+'" -Apply')
    $legacyDisabled=$false
    if($DisableLegacyWindowsChannelsStartup -and (Test-Path -LiteralPath $legacyLink -PathType Leaf)){
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyBackup) -Force|Out-Null
        if(-not(Test-Path -LiteralPath $legacyBackup -PathType Leaf)){Copy-Item -LiteralPath $legacyLink -Destination $legacyBackup}
        Remove-Item -LiteralPath $legacyLink -Force
        $legacyRemoved=$true
        $legacyDisabled=$true
    }
    if($backup){Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $shortcutSnapshotRoot){Remove-Item -LiteralPath $shortcutSnapshotRoot -Recurse -Force -ErrorAction SilentlyContinue}
}catch{
    if($activated -and (Test-Path -LiteralPath $installRoot)){Remove-Item -LiteralPath $installRoot -Recurse -Force}
    if($backup -and (Test-Path -LiteralPath $backup)){Move-Item -LiteralPath $backup -Destination $installRoot}
    if($legacyRemoved -and -not(Test-Path -LiteralPath $legacyLink) -and (Test-Path -LiteralPath $legacyBackup -PathType Leaf)){Copy-Item -LiteralPath $legacyBackup -Destination $legacyLink -Force -ErrorAction SilentlyContinue}
    foreach($shortcut in $shortcutSnapshot){
        if($shortcut.Exists){
            if(Test-Path -LiteralPath $shortcut.Path){Remove-Item -LiteralPath $shortcut.Path -Force -ErrorAction SilentlyContinue}
            if(Test-Path -LiteralPath $shortcut.Backup -PathType Leaf){Move-Item -LiteralPath $shortcut.Backup -Destination $shortcut.Path -Force -ErrorAction SilentlyContinue}
        }elseif(Test-Path -LiteralPath $shortcut.Path){Remove-Item -LiteralPath $shortcut.Path -Force -ErrorAction SilentlyContinue}
    }
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
    if(Test-Path -LiteralPath $shortcutSnapshotRoot){Remove-Item -LiteralPath $shortcutSnapshotRoot -Recurse -Force -ErrorAction SilentlyContinue}
    throw
}

$startStatus=$null
if($LaunchAfterInstall){
    try{$startStatus=(& (Join-Path $installRoot 'Start-Qicheng-Lite.ps1') -Background -BuildBackend:(!$ReuseExistingBackendImage) -DockerPath $DockerPath -HealthAttempts $HealthAttempts|Out-String|ConvertFrom-Json).status}catch{$startStatus='start-failed';$startError=$_.Exception.Message}
}
[ordered]@{schemaVersion=1;status=if($startStatus -eq 'start-failed'){'installed-start-failed'}else{'installed'};version=[string]$manifest.version;installRoot=$installRoot;dataRoot=$dataRoot;tokenImported=[bool]$ImportTokenPath;tokenDisplayed=$false;composeProject='qicheng-agent-channels';channelCount=$ChannelCount;ports=$selectedPorts;viewerMode='background';backendImageAction=if($ReuseExistingBackendImage){'reuse-local-image'}else{'build'};imageContentVerified=$imageContentVerified;legacyStartupDisabled=$legacyDisabled;legacyBackup=if($legacyDisabled){$legacyBackup}else{$null};startStatus=$startStatus;startError=if($startStatus -eq 'start-failed'){$startError}else{$null};volumesRemoved=$false;hostChangesMade=$true}|ConvertTo-Json -Depth 5
