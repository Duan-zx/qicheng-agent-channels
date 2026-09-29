[CmdletBinding()]
param([string]$InstallRoot,[string]$DockerPath='docker',[string]$StartupRoot,[string]$LegacyStartupRoot,[int]$Port1=18761,[int]$Port2=18762)
$ErrorActionPreference='Continue'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if($Port1 -ne 18761 -or $Port2 -ne 18762){throw '端口契约固定为 18761/18762；请移除自定义端口参数。'}
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=$PSScriptRoot}
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$checks=New-Object 'System.Collections.Generic.List[object]'
function Add-Check([string]$Name,[bool]$Passed,[string]$Detail){$checks.Add([pscustomobject][ordered]@{name=$Name;passed=$Passed;detail=$Detail})}
function Test-CompatibleWindowsStartup([string]$ShortcutPath,[string]$LiteRoot){
    try{
        # The shortcut is evidence only when it launches this installed package's entrypoint.
        $shell=New-Object -ComObject WScript.Shell
        $link=$shell.CreateShortcut($ShortcutPath)
        $arguments=[string]$link.Arguments
        if($arguments -notmatch '(?i)(?:^|\s)-File\s+"([^"]+Start-WindowsChannels\.ps1)"\s*$'){return $false}
        $script=[IO.Path]::GetFullPath($matches[1])
        $windowsRoot=Split-Path -Parent $script
        if(-not [string]::Equals([IO.Path]::GetFullPath([string]$link.WorkingDirectory).TrimEnd('\'),$windowsRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){return $false}
        if(-not [string]::Equals([IO.Path]::GetFullPath([string]$link.TargetPath),[IO.Path]::GetFullPath((Get-Command powershell.exe -ErrorAction Stop).Source),[StringComparison]::OrdinalIgnoreCase)){return $false}
        if(-not [string]::Equals($LiteRoot.TrimEnd('\'),([IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\QichengLite'))).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){return $false}
        $recordPath=Join-Path $windowsRoot '.qicheng-product-install.json'
        $manifestPath=Join-Path $windowsRoot 'package-manifest.json'
        if(-not(Test-Path -LiteralPath $recordPath -PathType Leaf) -or -not(Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not(Test-Path -LiteralPath $script -PathType Leaf)){return $false}
        $windowsRecord=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
        if($windowsRecord.schemaVersion -ne 1 -or $manifest.schemaVersion -ne 1 -or $manifest.product -ne 'Qicheng Windows Channels' -or $windowsRecord.version -ne $manifest.version -or $windowsRecord.autoStart -ne 'Enabled'){return $false}
        if([string]$windowsRecord.startupLink -ne $ShortcutPath){return $false}
        $version=[string]$windowsRecord.version
        if($version -match '^\d+\.\d+\.\d+-alpha\.(\d+)(?:-local)?$'){
            if([int]$matches[1] -lt 13){return $false}
        }elseif($version -notmatch '^\d+\.\d+\.\d+(?:-local)?$'){return $false}
        if([string]$windowsRecord.packageManifestSha256 -ne (Get-QichengLiteSha256 -Path $manifestPath)){return $false}
        $entry=@($manifest.files|Where-Object{[string]$_.path -eq 'Start-WindowsChannels.ps1'})
        if($entry.Count -ne 1){return $false}
        if([string]$entry[0].sha256 -ne (Get-QichengLiteSha256 -Path $script) -or [uint64]$entry[0].bytes -ne [uint64](Get-Item -LiteralPath $script).Length){return $false}
        $viewerRelative='viewer/dist/WindowsChannelsViewer.exe'
        $viewerEntry=@($manifest.files|Where-Object{[string]$_.path -eq $viewerRelative})
        $viewer=Join-Path $windowsRoot 'viewer\dist\WindowsChannelsViewer.exe'
        if($viewerEntry.Count -ne 1 -or -not(Test-Path -LiteralPath $viewer -PathType Leaf)){return $false}
        if([string]$viewerEntry[0].sha256 -ne (Get-QichengLiteSha256 -Path $viewer) -or [uint64]$viewerEntry[0].bytes -ne [uint64](Get-Item -LiteralPath $viewer).Length){return $false}
        $source=Get-Content -LiteralPath $script -Raw -Encoding UTF8
        if(-not $source.Contains('Programs\QichengLite\.qicheng-lite-install.json') -or -not $source.Contains('4..(3 + $config.ProjectNames.Count)') -or -not $source.Contains('$disableHostHotkey = $true')){return $false}
        $configPath=Join-Path ([string]$windowsRecord.dataRoot) 'channels.json'
        if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){return $false}
        $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
        $count=@($config.projects.PSObject.Properties.Name).Count
        return ($config.schema_version -eq 1 -and $count -ge 1 -and $count -le 6)
    }catch{return $false}
}
$record=Read-QichengLiteInstallRecord -InstallRoot $installRoot
Add-Check 'install-record' ($null -ne $record) $(if($record){"版本 $($record.version)"}else{'安装记录缺失'})
$packageCheck=Test-QichengLiteInstalledPackage -InstallRoot $installRoot
Add-Check 'installed-package-consistency' $packageCheck.valid $(if($packageCheck.valid){"版本 $($packageCheck.version)，文件与包清单一致"}else{($packageCheck.issues -join '；')+'；请使用完整安装包修复，不要继续覆盖单个文件'})
$channelCount=0
if($record){try{$channelCount=Get-QichengLiteChannelCount -Record $record}catch{Add-Check 'channel-selection' $false $_.Exception.Message}}
if($channelCount){Add-Check 'channel-selection' $true "$channelCount 个频道"}
$desktopApp=if($record -and $record.PSObject.Properties['desktopApp']){[string]$record.desktopApp}else{'firefox'}
$desktopAppValid=$desktopApp -cin @('firefox','wechat')
Add-Check 'desktop-app-selection' $desktopAppValid $(if($desktopAppValid){$desktopApp}else{'安装记录中的 desktopApp 无效'})
if($desktopApp -eq 'wechat'){
    foreach($relative in @('Dockerfile.wechat','compose.wechat.yaml','wechat-devtools-cli','wechat-cli-result.py')){
        Add-Check ("wechat-file-$relative") (Test-Path -LiteralPath (Join-Path $installRoot $relative) -PathType Leaf) $relative
    }
}
foreach($item in @(
    @{Name='viewer';Path='dist\AgentChannels.exe'},
    @{Name='compose';Path='compose.yaml'},
    @{Name='dockerfile';Path='Dockerfile'},
    @{Name='license';Path='LICENSE'},
    @{Name='third-party-notices';Path='THIRD-PARTY-NOTICES.md'}
)){$path=Join-Path $installRoot $item.Path;Add-Check $item.Name (Test-Path -LiteralPath $path -PathType Leaf) $path}
$tokenPath=Join-Path $installRoot '.local\channel.token'
$tokenValid=$false
if(Test-Path -LiteralPath $tokenPath -PathType Leaf){try{$tokenValid=Test-QichengLiteTokenValue -Value ((Get-Content -LiteralPath $tokenPath -Raw).Trim())}catch{}}
Add-Check 'private-token' $tokenValid $(if($tokenValid){'存在且格式有效；值未显示'}else{'缺失或格式无效'})
$brokerTokenPath=Join-Path $installRoot '.local\broker.token'
$brokerEnabled=Test-Path -LiteralPath $brokerTokenPath -PathType Leaf
if($brokerEnabled){
    $brokerCredentialsValid=$false
    try{
        $channelTokenValue=(Get-Content -LiteralPath $tokenPath -Raw).Trim()
        $brokerTokenValue=(Get-Content -LiteralPath $brokerTokenPath -Raw).Trim()
        $viewerTokenValue=(Get-Content -LiteralPath (Join-Path $installRoot '.local\viewer.token') -Raw).Trim()
        $brokerCredentialsValid=(Test-QichengLiteTokenValue -Value $brokerTokenValue) -and (Test-QichengLiteTokenValue -Value $viewerTokenValue) -and
            $channelTokenValue -cne $brokerTokenValue -and $channelTokenValue -cne $viewerTokenValue -and $brokerTokenValue -cne $viewerTokenValue -and
            (Test-Path -LiteralPath (Join-Path $installRoot 'compose.broker.yaml') -PathType Leaf)
    }catch{}
    Add-Check 'broker-credentials' $brokerCredentialsValid $(if($brokerCredentialsValid){'三类凭据分离且格式有效；值未显示'}else{'Broker 模式三类凭据不完整或重复'})
}
$dockerAvailable=$false
try{& $DockerPath version --format '{{.Server.Version}}' 2>$null|Out-Null;$dockerAvailable=($LASTEXITCODE -eq 0)}catch{}
Add-Check 'docker-linux-engine' $dockerAvailable $(if($dockerAvailable){'可用'}else{'不可用；本产品不捆绑 Docker Desktop'})
if($dockerAvailable){
    if($desktopApp -eq 'wechat'){
        $imageId=@(& $DockerPath image inspect --format '{{.Id}}' 'qicheng-agent-channels-wechat:2.02.2608070-2-local' 2>$null)
        $imageReady=($LASTEXITCODE -eq 0 -and $imageId.Count -eq 1 -and -not[string]::IsNullOrWhiteSpace([string]$imageId[0]))
        Add-Check 'wechat-image' $imageReady $(if($imageReady){'已找到可选微信镜像'}else{'可选微信镜像缺失；重新构建后再启动'})
    }
    $composeOutput=''
    $composeArgs=@('compose','--project-name','qicheng-agent-channels','--project-directory',$installRoot,'-f',(Join-Path $installRoot 'compose.yaml'))
    if($desktopApp -eq 'wechat'){$composeArgs+=@('-f',(Join-Path $installRoot 'compose.wechat.yaml'))}
    if($brokerEnabled){$composeArgs+=@('-f',(Join-Path $installRoot 'compose.broker.yaml'))}
    try{$composeOutput=(& $DockerPath @composeArgs --profile second ps --format json 2>&1|Out-String);$composeOk=($LASTEXITCODE -eq 0)}catch{$composeOk=$false;$composeOutput=$_.Exception.Message}
    Add-Check 'compose-project' $composeOk $(if($composeOk){'qicheng-agent-channels 可读取'}else{'无法读取项目状态'})
    if($record -and $record.PSObject.Properties['runtimeImageId'] -and $record.runtimeImageId){
        foreach($channel in 1..$channelCount){
            $imageMatches=$false
            try {
                $ids=@(& $DockerPath @composeArgs --profile second ps -q "channel$channel" 2>$null)
                if($LASTEXITCODE -eq 0 -and $ids.Count -eq 1){
                    $runningImage=@(& $DockerPath inspect --format '{{.Image}}' ([string]$ids[0]) 2>$null)
                    $imageMatches=($LASTEXITCODE -eq 0 -and $runningImage.Count -eq 1 -and [string]$runningImage[0] -ceq [string]$record.runtimeImageId)
                }
            } catch {}
            Add-Check "channel-$channel-image-version" $imageMatches $(if($imageMatches){'运行镜像与安装记录一致'}else{'运行镜像缺失或与安装版本不一致；请使用完整安装包修复'})
        }
    }
}
$ports=@(18761);if($channelCount -eq 2){$ports+=18762}
foreach($port in $ports){
    $ready=$false
    if($tokenValid){
        try{
            $state=Invoke-RestMethod -Uri ("http://127.0.0.1:$port/api/state") -Headers @{Authorization=('Bearer '+((Get-Content -LiteralPath $tokenPath -Raw).Trim()))} -TimeoutSec 2
            $ready=($state.input_target -eq 'private-linux-display' -and [int]$state.width -gt 0 -and [int]$state.height -gt 0 -and
                (Test-QichengLiteDesktopState -DesktopApp $desktopApp -State $state) -and
                (-not $brokerEnabled -or ($state.input_auth -eq 'broker-v2' -and [string]$state.channel_id -eq [string]($port-18760))))
        }catch{}
    }
    Add-Check ("channel-$port-authenticated-state") $ready $(if($ready){"私有 Linux 显示已认证，协议与尺寸有效"}elseif($desktopApp -eq 'wechat'){"127.0.0.1:$port 状态、Broker 鉴权或微信 GUI 存活未通过检查"}else{"127.0.0.1:$port 状态、Broker 鉴权协议或频道身份未通过检查"})
}
if([string]::IsNullOrWhiteSpace($StartupRoot)){$StartupRoot=[Environment]::GetFolderPath('Startup')}
if([string]::IsNullOrWhiteSpace($LegacyStartupRoot)){$LegacyStartupRoot=[Environment]::GetFolderPath('Startup')}
$startup=Join-Path (Resolve-QichengLitePath -Path $StartupRoot -Label 'StartupRoot') '启程轻量工作台.lnk'
$legacy=Join-Path (Resolve-QichengLitePath -Path $LegacyStartupRoot -Label 'LegacyStartupRoot') '启程 Windows 频道.lnk'
Add-Check 'lite-autostart' (Test-Path -LiteralPath $startup -PathType Leaf) $startup
$legacyPresent=Test-Path -LiteralPath $legacy -PathType Leaf
$windowsCompatible=$legacyPresent -and (Test-CompatibleWindowsStartup -ShortcutPath $legacy -LiteRoot $installRoot)
Add-Check 'legacy-alt-conflict' (-not $legacyPresent -or $windowsCompatible) $(if($windowsCompatible){'已核对 Windows 频道启动项、安装记录、包校验及 Lite 快捷键重映射：Alt+4..9，无 host 快捷键'}elseif($legacyPresent){'Windows 频道启动项的兼容性未证实，可能争用 Alt 快捷键'}else{'未发现旧启动项'})
$failed=@($checks.ToArray()|Where-Object{-not $_.passed}).Count
[ordered]@{schemaVersion=1;status=if($failed){'attention-required'}else{'healthy'};installRoot=$installRoot;composeProject='qicheng-agent-channels';channelCount=$channelCount;desktopApp=$desktopApp;ports=$ports;checks=$checks.ToArray();failedChecks=$failed;mutationsMade=$false;tokenDisplayed=$false}|ConvertTo-Json -Depth 6
