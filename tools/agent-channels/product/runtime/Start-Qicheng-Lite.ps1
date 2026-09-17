[CmdletBinding()]
param([string]$InstallRoot=$PSScriptRoot,[switch]$Background,[switch]$BuildBackend,[string]$DockerPath='docker',[ValidateRange(1,45)][int]$HealthAttempts=45,[ValidateRange(1024,65535)][int]$Port1=18761,[ValidateRange(1024,65535)][int]$Port2=18762)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$token=Join-Path $installRoot '.local\channel.token'
$compose=Join-Path $installRoot 'compose.yaml'
$viewer=Join-Path $installRoot 'dist\AgentChannels.exe'
foreach($required in @($token,$compose,$viewer)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "运行文件缺失：$required。请重新安装或导入 token。"}}
$tokenValue=(Get-Content -LiteralPath $token -Raw).Trim()
if(-not(Test-QichengLiteTokenValue -Value $tokenValue)){throw '本地 token 格式无效；未启动容器或查看器。'}
& $DockerPath version --format '{{.Server.Version}}' 2>$null|Out-Null
if($LASTEXITCODE -ne 0){throw 'Docker Linux engine 不可用。轻量版不捆绑 Docker Desktop；请先启动已获准的 Docker Linux 环境。'}
$dockerArguments=@('compose','--project-name','qicheng-agent-channels','--project-directory',$installRoot,'-f',$compose,'--profile','second','up','-d')
if($BuildBackend){$dockerArguments+='--build'}else{$dockerArguments+='--no-build'}
$dockerArguments+=@('channel1','channel2')
& $DockerPath @dockerArguments
if($LASTEXITCODE -ne 0){throw '两频道后端启动失败。未删除容器或 volume；请运行诊断。'}
$ready=@{}
$ready[$Port1]=$false
$ready[$Port2]=$false
$headers=@{Authorization=('Bearer '+$tokenValue)}
foreach($attempt in 1..$HealthAttempts){
    foreach($port in @($Port1,$Port2)){
        if(-not $ready[$port]){
            try{
                $state=Invoke-RestMethod -Uri ("http://127.0.0.1:$port/api/state") -Headers $headers -TimeoutSec 2
                $ready[$port]=($state.input_target -eq 'private-linux-display' -and [int]$state.width -gt 0 -and [int]$state.height -gt 0)
            }catch{}
        }
    }
    if($ready[$Port1] -and $ready[$Port2]){break}
    Start-Sleep -Milliseconds 500
}
if(-not($ready[$Port1] -and $ready[$Port2])){throw "容器已请求启动，但 $Port1/$Port2 健康检查未全部通过。未删除容器或 volume。"}
$viewerArguments=if($Background){@('--background')}else{@('--show')}
Start-Process -FilePath $viewer -ArgumentList $viewerArguments -WorkingDirectory $installRoot -WindowStyle Hidden|Out-Null
[ordered]@{schemaVersion=1;status='started';installRoot=$installRoot;composeProject='qicheng-agent-channels';services=@('channel1','channel2');ports=@($Port1,$Port2);backendBuilt=[bool]$BuildBackend;viewerMode=if($Background){'background'}else{'visible'};tokenDisplayed=$false;volumesRemoved=$false}|ConvertTo-Json -Depth 4
