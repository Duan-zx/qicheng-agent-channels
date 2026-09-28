[CmdletBinding()]
param([switch]$TwoChannels)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$state=Join-Path $root '.local'
New-Item -ItemType Directory -Path $state -Force | Out-Null
$token=Join-Path $state 'channel.token'
if(-not(Test-Path -LiteralPath $token)){
    $bytes=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
    [IO.File]::WriteAllText($token,([BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()))
}
$channelToken=(Get-Content -LiteralPath $token -Raw).Trim()
if($channelToken -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid channel token; backend not started.'}
$brokerToken=Join-Path $state 'broker.token'
$brokerEnabled=Test-Path -LiteralPath $brokerToken -PathType Leaf
if($brokerEnabled){
    $brokerCompose=Join-Path $root 'compose.broker.yaml'
    $viewerToken=Join-Path $state 'viewer.token'
    if(-not(Test-Path -LiteralPath $brokerCompose -PathType Leaf)){throw 'Broker compose override missing; backend not started.'}
    if(-not(Test-Path -LiteralPath $viewerToken -PathType Leaf)){throw 'Viewer token missing in broker mode; backend not started.'}
    $brokerTokenValue=(Get-Content -LiteralPath $brokerToken -Raw).Trim()
    $viewerTokenValue=(Get-Content -LiteralPath $viewerToken -Raw).Trim()
    if($brokerTokenValue -cnotmatch '^[a-f0-9]{64}$' -or $brokerTokenValue -ceq $channelToken){throw 'Invalid or duplicate broker token; backend not started.'}
    if($viewerTokenValue -cnotmatch '^[a-f0-9]{64}$' -or $viewerTokenValue -ceq $channelToken -or $viewerTokenValue -ceq $brokerTokenValue){throw 'Invalid or duplicate viewer token; backend not started.'}
}
& docker version --format '{{.Server.Version}}'
if($LASTEXITCODE -ne 0){throw 'Docker Linux engine unavailable. Start your approved Docker environment then rerun; system settings unchanged.'}
$composeArguments=@('compose','--project-directory',$root,'-f',(Join-Path $root 'compose.yaml'))
if($brokerEnabled){$composeArguments+=@('-f',$brokerCompose)}
$arguments=@($composeArguments)
if($TwoChannels){$arguments+=@('--profile','second')}
& docker @arguments up -d --build
if($LASTEXITCODE -ne 0){
    if($brokerEnabled){
        & docker @composeArguments stop channel1 channel2|Out-Null
        if($LASTEXITCODE -ne 0){throw 'Broker backend failed to build/start and channel stop failed; stop both channel containers manually.'}
    }
    throw 'Backend failed to start; no host input fallback.'
}
if($brokerEnabled){
    $ports=if($TwoChannels){@(18761,18762)}else{@(18761)}
    $ready=@{}
    foreach($port in $ports){$ready[$port]=$false}
    $headers=@{Authorization=('Bearer '+$channelToken)}
    foreach($attempt in 1..45){
        foreach($port in $ports){
            if(-not $ready[$port]){
                try{
                    $backendState=Invoke-RestMethod -Uri ("http://127.0.0.1:$port/api/state") -Headers $headers -TimeoutSec 2
                    $ready[$port]=($backendState.input_target -eq 'private-linux-display' -and [int]$backendState.width -gt 0 -and [int]$backendState.height -gt 0 -and $backendState.input_auth -ceq 'broker-v2' -and [string]$backendState.channel_id -eq [string]($port-18760))
                }catch{}
            }
        }
        if(-not @($ports|Where-Object{-not $ready[$_]}).Count){break}
        Start-Sleep -Milliseconds 500
    }
    if(@($ports|Where-Object{-not $ready[$_]}).Count){
        & docker @composeArguments stop channel1 channel2|Out-Null
        if($LASTEXITCODE -ne 0){throw 'Broker state check failed and channel stop failed; stop both channel containers manually.'}
        throw 'Broker state check failed (requires input_auth=broker-v2 on each channel). Both channel containers stopped; no viewer launched.'
    }
}
Write-Host 'Backend requested. Verify actual desktop before enabling AI input; launch dist/AgentChannels.exe.'
