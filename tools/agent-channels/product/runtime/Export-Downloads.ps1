[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet(1,2)][int]$Channel,
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$DockerPath='docker',
    [switch]$Open
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=$PSScriptRoot}
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$record=Read-QichengLiteInstallRecord -InstallRoot $installRoot
if(-not $record){throw '启程轻量版安装记录缺失。'}
if([string]::IsNullOrWhiteSpace($DataRoot)){$DataRoot=[string]$record.dataRoot}
$dataRoot=Resolve-QichengLitePath -Path $DataRoot -Label 'DataRoot'
$compose=Join-Path $installRoot 'compose.yaml'
if(-not(Test-Path -LiteralPath $compose -PathType Leaf)){throw 'compose.yaml 缺失，请重新安装。'}
$service='channel'+$Channel
& $DockerPath version --format '{{.Server.Version}}' 2>$null|Out-Null
if($LASTEXITCODE -ne 0){throw 'Docker Linux engine 不可用，无法取回下载文件。'}
$ids=@(& $DockerPath compose --project-name qicheng-agent-channels --project-directory $installRoot -f $compose --profile second ps -q $service 2>$null|Where-Object{$_}|ForEach-Object{$_.Trim()})
if($LASTEXITCODE -ne 0 -or $ids.Count -ne 1){throw "未找到唯一的频道 $Channel 容器；请先启动轻量工作台。"}
$containerId=$ids[0]
$projectOutput=& $DockerPath inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' $containerId 2>$null
$projectExit=$LASTEXITCODE
$project=([string]($projectOutput|Select-Object -First 1)).Trim()
$serviceOutput=& $DockerPath inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' $containerId 2>$null
$serviceExit=$LASTEXITCODE
$containerService=([string]($serviceOutput|Select-Object -First 1)).Trim()
if($projectExit -ne 0 -or $serviceExit -ne 0 -or $project -cne 'qicheng-agent-channels' -or $containerService -cne $service){throw '容器归属验证失败，未导出任何文件。'}
$channelName=if($Channel -eq 1){'频道一'}else{'频道二'}
$destinationParent=Join-Path $dataRoot ('Downloads\'+$channelName)
New-Item -ItemType Directory -Path $destinationParent -Force|Out-Null
$stamp=(Get-Date).ToString('yyyyMMdd-HHmmss-fff')
$destination=Join-Path $destinationParent $stamp
$stage=Join-Path $destinationParent ('.export-stage-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage|Out-Null
try{
    & $DockerPath cp ($containerId+':/home/channel/Downloads/.') $stage
    if($LASTEXITCODE -ne 0){throw '从来宾下载目录复制失败；来宾原文件保持不变。'}
    Move-Item -LiteralPath $stage -Destination $destination
}catch{
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
    throw
}
$files=@(Get-ChildItem -LiteralPath $destination -File -Recurse)
if($Open){Start-Process -FilePath explorer.exe -ArgumentList @('"'+$destination+'"')|Out-Null}
[ordered]@{schemaVersion=1;status='exported';channel=$Channel;source='/home/channel/Downloads';destination=$destination;files=$files.Count;bytes=($files|Measure-Object -Property Length -Sum).Sum;ownContainerVerified=$true;guestFilesPreserved=$true;volumesRemoved=$false;opened=[bool]$Open}|ConvertTo-Json -Depth 4
