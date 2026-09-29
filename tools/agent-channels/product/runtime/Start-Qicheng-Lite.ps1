[CmdletBinding()]
param([string]$InstallRoot,[switch]$Background,[switch]$LoginRecovery,[switch]$BuildBackend,[switch]$NoWindowsChannels,[string]$DockerPath='docker',[string]$DockerDesktopPath,[ValidateRange(1,300)][int]$DockerReadyTimeoutSeconds=120,[ValidateRange(1,45)][int]$HealthAttempts=45,[int]$Port1=18761,[int]$Port2=18762)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if($Port1 -ne 18761 -or $Port2 -ne 18762){throw '端口契约固定为 18761/18762；请移除自定义端口参数。'}
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=$PSScriptRoot}
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$record=Read-QichengLiteInstallRecord -InstallRoot $installRoot
if(-not $record){throw '安装记录缺失；未启动容器或查看器。'}
$channelCount=Get-QichengLiteChannelCount -Record $record
$desktopApp=if($record.PSObject.Properties['desktopApp']){[string]$record.desktopApp}else{'firefox'}
if($desktopApp -cnotin @('firefox','wechat')){throw '安装记录中的 desktopApp 无效；未启动容器或查看器。'}
$token=Join-Path $installRoot '.local\channel.token'
$compose=Join-Path $installRoot 'compose.yaml'
$brokerToken=Join-Path $installRoot '.local\broker.token'
$viewerToken=Join-Path $installRoot '.local\viewer.token'
$brokerCompose=Join-Path $installRoot 'compose.broker.yaml'
$wechatCompose=Join-Path $installRoot 'compose.wechat.yaml'
$viewer=Join-Path $installRoot 'dist\AgentChannels.exe'
foreach($required in @($token,$compose,$viewer)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "运行文件缺失：$required。请重新安装或导入 token。"}}
$tokenValue=(Get-Content -LiteralPath $token -Raw).Trim()
if(-not(Test-QichengLiteTokenValue -Value $tokenValue)){throw '本地 token 格式无效；未启动容器或查看器。'}
$brokerEnabled=Test-Path -LiteralPath $brokerToken -PathType Leaf
if($brokerEnabled){
    if(-not(Test-Path -LiteralPath $brokerCompose -PathType Leaf)){throw 'Broker Compose 配置缺失；未启动容器。'}
    if(-not(Test-Path -LiteralPath $viewerToken -PathType Leaf)){throw 'Broker 模式缺少查看器 token；未启动容器。请重新安装。'}
    $brokerTokenValue=(Get-Content -LiteralPath $brokerToken -Raw).Trim()
    if(-not(Test-QichengLiteTokenValue -Value $brokerTokenValue) -or $brokerTokenValue -ceq $tokenValue){throw 'Broker token 无效或与频道 token 相同；未启动容器。'}
    $viewerTokenValue=(Get-Content -LiteralPath $viewerToken -Raw).Trim()
    if(-not(Test-QichengLiteTokenValue -Value $viewerTokenValue) -or $viewerTokenValue -ceq $tokenValue -or $viewerTokenValue -ceq $brokerTokenValue){throw '查看器 token 无效或与其他凭据相同；未启动容器。'}
}
function Invoke-BoundedDockerProbe([string[]]$Arguments,[Diagnostics.Stopwatch]$Timer,[int]$BudgetMilliseconds){
    $remaining=$BudgetMilliseconds-[int]$Timer.ElapsedMilliseconds
    if($remaining -le 0){return $null}
    $process=$null
    try {
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=$DockerPath
        $startInfo.Arguments=$Arguments -join ' '
        $startInfo.UseShellExecute=$false
        $startInfo.CreateNoWindow=$true
        $startInfo.RedirectStandardOutput=$true
        $startInfo.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($startInfo)
        $remaining=$BudgetMilliseconds-[int]$Timer.ElapsedMilliseconds
        if($remaining -le 0 -or -not $process.WaitForExit([Math]::Min(2000,$remaining))){
            if(-not $process.HasExited){$process.Kill()}
            return $null
        }
        if($process.ExitCode -ne 0){return $null}
        return $process.StandardOutput.ReadToEnd().Trim()
    }catch{return $null}
    finally {if($process){$process.Dispose()}}
}
function Get-DockerLinuxState([Diagnostics.Stopwatch]$Timer,[int]$BudgetMilliseconds){
    if(-not[string]::IsNullOrWhiteSpace($env:DOCKER_HOST) -and $env:DOCKER_HOST -notmatch '(?i)^npipe:////\./pipe/(docker_engine|dockerDesktopLinuxEngine)$'){return 'remote'}
    $endpoint=Invoke-BoundedDockerProbe -Arguments @('context','inspect','--format','{{.Endpoints.docker.Host}}') -Timer $Timer -BudgetMilliseconds $BudgetMilliseconds
    if([string]::IsNullOrWhiteSpace($endpoint)){return 'unknown-endpoint'}
    if($endpoint -notmatch '(?i)^npipe:////\./pipe/(docker_engine|dockerDesktopLinuxEngine)$'){return 'remote'}
    $osType=Invoke-BoundedDockerProbe -Arguments @('info','--format','{{.OSType}}') -Timer $Timer -BudgetMilliseconds $BudgetMilliseconds
    if($osType -eq 'linux'){return 'ready'}
    if($osType -eq 'windows'){return 'windows'}
    return 'unavailable'
}
$readyTimer=[Diagnostics.Stopwatch]::StartNew()
$readyBudgetMilliseconds=if($LoginRecovery){$DockerReadyTimeoutSeconds*1000}else{2000}
$dockerState=Get-DockerLinuxState -Timer $readyTimer -BudgetMilliseconds $readyBudgetMilliseconds
if($dockerState -eq 'remote'){throw '当前 Docker endpoint 不是本机 Docker Desktop 管道；拒绝启动远端容器。'}
if($dockerState -eq 'unknown-endpoint'){throw '无法确认当前 Docker endpoint（Docker CLI 缺失、无响应或 context inspect 失败）；登录恢复未启动 Docker Desktop、后端或查看器。'}
if($dockerState -eq 'windows'){throw '当前 Docker engine 为 Windows 模式；启程轻量版需要本机 Linux engine。'}
$dockerReady=($dockerState -eq 'ready')
if(-not $dockerReady -and $LoginRecovery){
    if($readyTimer.ElapsedMilliseconds -ge $readyBudgetMilliseconds){throw "Docker Linux engine 不可用（登录恢复等待上限 $DockerReadyTimeoutSeconds 秒）。未启动后端或查看器；请检查 Docker Desktop。"}
    if([string]::IsNullOrWhiteSpace($DockerDesktopPath)){
        $desktopCandidates=@()
        foreach($programRoot in @($env:ProgramFiles,${env:ProgramFiles(x86)})){
            if(-not[string]::IsNullOrWhiteSpace($programRoot)){$desktopCandidates+=Join-Path $programRoot 'Docker\Docker\Docker Desktop.exe'}
        }
        $DockerDesktopPath=@($desktopCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1)[0]
    }
    if([string]::IsNullOrWhiteSpace($DockerDesktopPath) -or -not(Test-Path -LiteralPath $DockerDesktopPath -PathType Leaf)){
        throw 'Docker Linux engine 不可用，且未找到已安装的 Docker Desktop。登录恢复未启动后端或查看器。'
    }
    $desktopPath=[IO.Path]::GetFullPath($DockerDesktopPath)
    $desktopName=[IO.Path]::GetFileName($desktopPath)
    $desktopRunning=$false
    try {
        $desktopRunning=@(Get-CimInstance Win32_Process -Filter ("Name='"+$desktopName.Replace("'","''")+"'") -ErrorAction Stop|Where-Object{[string]$_.ExecutablePath -and ([string]$_.ExecutablePath).Equals($desktopPath,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
    }catch {throw '无法确认 Docker Desktop 是否已运行；登录恢复未重复启动进程。请检查 Windows 进程查询权限。'}
    if(-not $desktopRunning){Start-Process -FilePath $desktopPath -WindowStyle Hidden|Out-Null}
    while(-not $dockerReady -and $readyTimer.ElapsedMilliseconds -lt $readyBudgetMilliseconds){
        $sleepMilliseconds=[Math]::Min(500,$readyBudgetMilliseconds-[int]$readyTimer.ElapsedMilliseconds)
        if($sleepMilliseconds -gt 0){Start-Sleep -Milliseconds $sleepMilliseconds}
        $dockerState=Get-DockerLinuxState -Timer $readyTimer -BudgetMilliseconds $readyBudgetMilliseconds
        if($dockerState -eq 'remote'){throw '当前 Docker endpoint 不是本机 Docker Desktop 管道；拒绝启动远端容器。'}
        if($dockerState -eq 'unknown-endpoint'){
            if($readyTimer.ElapsedMilliseconds -ge $readyBudgetMilliseconds){throw "Docker Linux engine 不可用（登录恢复等待上限 $DockerReadyTimeoutSeconds 秒）。未启动后端或查看器；请检查 Docker Desktop。"}
            throw '无法确认当前 Docker endpoint（Docker CLI 缺失、无响应或 context inspect 失败）；登录恢复未启动后端或查看器。'
        }
        if($dockerState -eq 'windows'){throw '当前 Docker engine 为 Windows 模式；启程轻量版需要本机 Linux engine。'}
        $dockerReady=($dockerState -eq 'ready')
    }
}
if(-not $dockerReady){
    if($LoginRecovery){throw "Docker Linux engine 不可用（登录恢复等待上限 $DockerReadyTimeoutSeconds 秒）。未启动后端或查看器；请检查 Docker Desktop。"}
    throw 'Docker Linux engine 不可用。轻量版不捆绑 Docker Desktop；请先启动已获准的 Docker Linux 环境。'
}
$dockerComposeArguments=@('compose','--project-name','qicheng-agent-channels','--project-directory',$installRoot,'-f',$compose)
if($desktopApp -eq 'wechat'){
    foreach($required in @($wechatCompose,(Join-Path $installRoot 'Dockerfile.wechat'),(Join-Path $installRoot 'wechat-devtools-cli'),(Join-Path $installRoot 'wechat-cli-result.py'))){
        if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "微信可选镜像运行文件缺失：$required；未启动容器。"}
    }
    $dockerComposeArguments+=@('-f',$wechatCompose)
}
if($brokerEnabled){$dockerComposeArguments+=@('-f',$brokerCompose)}
$services=@('channel1');$ports=@(18761)
if($channelCount -eq 2){$services+= 'channel2';$ports+=18762}
# Check ownership before any Compose mutation when reducing an existing installation.
if($channelCount -eq 1){
    $oldIds=@(& $DockerPath @dockerComposeArguments --profile second ps -q channel2 2>$null|Where-Object{$_}|ForEach-Object{$_.Trim()})
    if($LASTEXITCODE -ne 0){throw '无法确认旧频道二容器状态；未启动查看器。'}
    foreach($oldId in $oldIds){
        $workingDirOutput=& $DockerPath inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' $oldId 2>$null
        $workingDirExit=$LASTEXITCODE
        $workingDir=([string]($workingDirOutput|Select-Object -First 1)).Trim()
        if($workingDirExit -ne 0 -or -not [string]::Equals(($workingDir -replace '[\\/]+$',''),($installRoot -replace '[\\/]+$',''),[StringComparison]::OrdinalIgnoreCase)){throw '发现频道二项目目录不匹配；拒绝停止其他安装的容器。'}
    }
}
$dockerArguments=@($dockerComposeArguments)+@('--profile','second','up','-d')
if($BuildBackend -and $desktopApp -eq 'wechat'){
    & $DockerPath build --tag 'qicheng-agent-channels:0.1-local' --file (Join-Path $installRoot 'Dockerfile') $installRoot
    if($LASTEXITCODE -ne 0){throw '微信可选镜像的 Lite 底座构建失败；未启动容器或查看器。'}
    & $DockerPath build --tag 'qicheng-agent-channels-wechat:2.02.2608070-2-local' --file (Join-Path $installRoot 'Dockerfile.wechat') $installRoot
    if($LASTEXITCODE -ne 0){throw '微信可选镜像构建失败（检查下载和 SHA-256）；未启动容器或查看器。'}
}
if($BuildBackend -and $desktopApp -eq 'firefox'){$dockerArguments+='--build'}else{$dockerArguments+=@('--no-build','--pull','never')}
$dockerArguments+=$services
& $DockerPath @dockerArguments
if($LASTEXITCODE -ne 0){
    if($brokerEnabled){
        & $DockerPath @dockerComposeArguments stop @services|Out-Null
        if($LASTEXITCODE -ne 0){throw 'Broker 模式启动失败，且无法停止已选频道容器。请立即手动检查；未启动查看器。'}
    }
    throw '后端启动失败。Broker 模式下已停止已选频道；未删除容器或 volume；请运行诊断。'
}
if($channelCount -eq 1){
    foreach($oldId in $oldIds){
        & $DockerPath @dockerComposeArguments stop channel2|Out-Null
        if($LASTEXITCODE -ne 0){throw '无法停止旧频道二容器；未启动查看器。'}
    }
}
$ready=@{}
foreach($port in $ports){$ready[$port]=$false}
$headers=@{Authorization=('Bearer '+$tokenValue)}
foreach($attempt in 1..$HealthAttempts){
    foreach($port in $ports){
        if(-not $ready[$port]){
            try{
                $state=Invoke-RestMethod -Uri ("http://127.0.0.1:$port/api/state") -Headers $headers -TimeoutSec 2
                $ready[$port]=($state.input_target -eq 'private-linux-display' -and [int]$state.width -gt 0 -and [int]$state.height -gt 0 -and
                    (Test-QichengLiteDesktopState -DesktopApp $desktopApp -State $state) -and
                    (-not $brokerEnabled -or ($state.input_auth -ceq 'broker-v2' -and [string]$state.channel_id -eq [string]($port-18760))))
            }catch{}
        }
    }
    if(@($ports|Where-Object{-not $ready[$_]}).Count -eq 0){break}
    Start-Sleep -Milliseconds 500
}
if(@($ports|Where-Object{-not $ready[$_]}).Count -gt 0){
    if($brokerEnabled){
        & $DockerPath @dockerComposeArguments stop @services|Out-Null
        if($LASTEXITCODE -ne 0){throw 'Broker 模式健康检查失败，且无法停止已选频道容器。请立即手动检查；未启动查看器。'}
    }
    throw "容器已请求启动，但已选端口 $($ports -join '/') 健康检查未全部通过（微信模式要求 GUI 可见且存活；Broker 模式要求 input_auth=broker-v2）。Broker 模式下已停止已选频道；未启动查看器，未删除 volume。"
}
$windowsViewerStartRequested=$false
$windowsHotkeysConfirmed=$false
$windowsViewerStatus=if($NoWindowsChannels){'disabled'}else{'not-installed'}
if(-not $NoWindowsChannels -and -not[string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){
    $windowsRoot=Join-Path $env:LOCALAPPDATA 'Programs\QichengWindowsChannels'
    $windowsStart=Join-Path $windowsRoot 'Start-WindowsChannels.ps1'
    $windowsRecord=Join-Path $windowsRoot '.qicheng-product-install.json'
    if((Test-Path -LiteralPath $windowsStart -PathType Leaf) -and (Test-Path -LiteralPath $windowsRecord -PathType Leaf)){
        try{
            $windowsCommand=Get-Command -Name $windowsStart -ErrorAction Stop
            if(-not $windowsCommand.Parameters.ContainsKey('WaitForHotkeys')){
                $windowsViewerStatus='legacy-hotkeys-unconfirmed'
            }else{
                $windowsViewerStartRequested=$true
                $windowsResult=& $windowsStart -WaitForHotkeys
                if($windowsResult.status -eq 'hotkeys-confirmed'){
                    $windowsHotkeysConfirmed=$true
                    $windowsViewerStatus='hotkeys-confirmed'
                }else{
                    $windowsViewerStatus='hotkeys-unconfirmed'
                }
            }
        }catch{
            $windowsViewerStatus='hotkeys-unconfirmed'
        }
    }
}
$viewerArguments=if($Background){@('--background')}else{@('--show')}
Start-Process -FilePath $viewer -ArgumentList $viewerArguments -WorkingDirectory $installRoot -WindowStyle Hidden|Out-Null
[ordered]@{schemaVersion=1;status='started';installRoot=$installRoot;composeProject='qicheng-agent-channels';channelCount=$channelCount;desktopApp=$desktopApp;services=$services;ports=$ports;backendBuilt=[bool]$BuildBackend;viewerMode=if($Background){'background'}else{'visible'};windowsViewerStartRequested=$windowsViewerStartRequested;windowsViewerStatus=$windowsViewerStatus;windowsHotkeysConfirmed=$windowsHotkeysConfirmed;tokenDisplayed=$false;volumesRemoved=$false}|ConvertTo-Json -Depth 4
