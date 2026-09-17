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
& docker version --format '{{.Server.Version}}'
if($LASTEXITCODE -ne 0){throw 'Docker Linux engine unavailable. Start your approved Docker environment then rerun; system settings unchanged.'}
$arguments=@('compose','--project-directory',$root,'-f',(Join-Path $root 'compose.yaml'))
if($TwoChannels){$arguments+=@('--profile','second')}
& docker @arguments up -d --build
if($LASTEXITCODE -ne 0){throw 'Backend failed to start; no host input fallback.'}
Write-Host 'Backend requested. Verify actual desktop before enabling AI input; launch dist/AgentChannels.exe.'
