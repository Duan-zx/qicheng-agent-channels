[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [string]$InstallRoot,
    [string]$RecoveryRoot,
    [string]$DockerPath='docker',
    [switch]$Apply,
    [switch]$NonInteractive
)
$ErrorActionPreference='Stop'
if($NonInteractive){$ConfirmPreference='None'}
. (Join-Path $PSScriptRoot 'Product.Common.ps1')

function Assert-PlainPath([string]$Path,[string]$Label){
    $cursor=$Path
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "$Label 路径含重解析点；拒绝操作。"}
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if(-not $parent -or $parent -eq $cursor){break}
        $cursor=$parent
    }
}
function Same-Path([string]$A,[string]$B){
    [string]::Equals($A.TrimEnd('\'),$B.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
}
function Is-Within([string]$Path,[string]$Root){
    (Same-Path $Path $Root) -or $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Read-OwnedShortcut([string]$Path,[string]$Root){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    Assert-PlainPath $Path '快捷方式'
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('qicheng-lite-link-'+[guid]::NewGuid().ToString('N')+'.lnk')
    $link=$null
    try{
        Copy-Item -LiteralPath $Path -Destination $temporary -ErrorAction Stop
        $shell=New-Object -ComObject WScript.Shell
        $link=$shell.CreateShortcut($temporary)
        $target=[string]$link.TargetPath
        $args=[string]$link.Arguments
        $script=Join-Path $Root 'Start-Qicheng-Lite.ps1'
        if($Path -like '*管理启程轻量工作台.lnk'){$script=Join-Path $Root 'Start-Qicheng-Lite.ps1'}
        elseif($Path -like '*诊断启程轻量工作台.lnk'){$script=Join-Path $Root 'Diagnose-Qicheng-Lite.ps1'}
        elseif($Path -like '*取回频道*下载文件.lnk'){$script=Join-Path $Root 'Export-Downloads.ps1'}
        elseif($Path -like '*恢复旧 Windows 频道自启动.lnk'){$script=Join-Path $Root 'Restore-LegacyWindowsChannelsStartup.ps1'}
        return ($target -match '(?i)[\\/]powershell\.exe$' -and $args.Contains('"'+$script+'"'))
    }finally{
        if($link -and [Runtime.InteropServices.Marshal]::IsComObject($link)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
    }
}
function Invoke-Docker([string[]]$Arguments){
    $lines=@(& $DockerPath @Arguments 2>$null)
    if($LASTEXITCODE -ne 0){throw "Docker 命令失败：$($Arguments[0]) $($Arguments[1])。请核对当前容器状态。"}
    return $lines
}

if(-not $InstallRoot){$InstallRoot=Get-QichengLiteInstallRoot}
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
Assert-PlainPath $installRoot 'InstallRoot'
if(-not(Test-Path -LiteralPath $installRoot -PathType Container)){throw '未知安装：安装目录不存在。'}
$record=Read-QichengLiteInstallRecord -InstallRoot $installRoot
if(-not $record -or $record.schemaVersion -ne 1 -or [string]$record.product -cne 'Qicheng Lite' -or [string]$record.composeProject -cne 'qicheng-agent-channels'){
    throw '未知安装：安装记录或产品归属无效。'
}
$channelCount=Get-QichengLiteChannelCount -Record $record
$dataRoot=Resolve-QichengLitePath -Path ([string]$record.dataRoot) -Label 'DataRoot'
Assert-PlainPath $dataRoot 'DataRoot'
if((Is-Within $dataRoot $installRoot) -or (Is-Within $installRoot $dataRoot)){throw '安装与数据目录重叠；拒绝操作。'}
foreach($required in @('compose.yaml','Product.Common.ps1','Start-Qicheng-Lite.ps1','dist\AgentChannels.exe','.local\channel.token','package-manifest.json')){
    if(-not(Test-Path -LiteralPath (Join-Path $installRoot $required) -PathType Leaf)){throw "未知安装：缺少 $required。"}
}
$manifest=Get-Content -LiteralPath (Join-Path $installRoot 'package-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
if($manifest.schemaVersion -ne 1 -or [string]$manifest.product -cne 'Qicheng Lite'){throw '未知安装：包清单无效。'}
if(-not $RecoveryRoot){$RecoveryRoot=Join-Path (Split-Path -Parent $installRoot) 'QichengLite-Recovery'}
$recoveryRoot=Resolve-QichengLitePath -Path $RecoveryRoot -Label 'RecoveryRoot'
Assert-PlainPath $recoveryRoot 'RecoveryRoot'
if((Is-Within $recoveryRoot $installRoot) -or (Is-Within $installRoot $recoveryRoot) -or (Is-Within $recoveryRoot $dataRoot) -or (Is-Within $dataRoot $recoveryRoot)){
    throw '恢复目录与安装或数据目录重叠；拒绝操作。'
}
$recoveryPath=Join-Path $recoveryRoot ('QichengLite-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
$startupLink=Resolve-QichengLitePath -Path ([string]$record.startupLink) -Label 'startupLink'
$desktopLink=Resolve-QichengLitePath -Path ([string]$record.desktopLink) -Label 'desktopLink'
$startMenuRoot=Resolve-QichengLitePath -Path ([string]$record.startMenuRoot) -Label 'startMenuRoot'
foreach($path in @($startupLink,$desktopLink,$startMenuRoot)){
    Assert-PlainPath $path '快捷方式目录'
    if((Is-Within $path $installRoot) -or (Is-Within $path $dataRoot) -or (Is-Within $path $recoveryRoot)){throw '快捷方式目录与安装、数据或恢复目录重叠；拒绝操作。'}
}
$shortcutPaths=@($startupLink,$desktopLink)+@(
    '启程轻量工作台.lnk','管理启程轻量工作台.lnk','诊断启程轻量工作台.lnk',
    '取回频道一下载文件.lnk','取回频道二下载文件.lnk','恢复旧 Windows 频道自启动.lnk'
)|ForEach-Object{if($_ -match '^[A-Za-z]:[\\/]'){$_}else{Join-Path $startMenuRoot $_}}
$ownedShortcuts=@($shortcutPaths|Where-Object{Read-OwnedShortcut $_ $installRoot})

if($env:DOCKER_HOST -and $env:DOCKER_HOST -notmatch '(?i)^npipe:////\./pipe/(docker_engine|dockerDesktopLinuxEngine)$'){
    throw 'Docker endpoint 非本机管道；拒绝操作。'
}
$endpoint=@(Invoke-Docker -Arguments @('context','inspect','--format','{{.Endpoints.docker.Host}}'))
$osType=@(Invoke-Docker -Arguments @('info','--format','{{.OSType}}'))
if($endpoint.Count -ne 1 -or [string]$endpoint[0] -notmatch '(?i)^npipe:////\./pipe/(docker_engine|dockerDesktopLinuxEngine)$' -or $osType.Count -ne 1 -or [string]$osType[0] -cne 'linux'){
    throw '无法确认本机 Docker Linux engine；拒绝操作。'
}
$containerIds=@(Invoke-Docker -Arguments @('ps','-a','--filter','label=com.docker.compose.project=qicheng-agent-channels','--format','{{.ID}}')|Where-Object{$_})
$ownedContainers=@()
foreach($id in $containerIds){
    if([string]$id -notmatch '^[0-9a-f]{12,64}$'){throw '容器 ID 无效；拒绝操作。'}
    $labelsText=@(Invoke-Docker -Arguments @('inspect','--format','{{json .Config.Labels}}',[string]$id))
    $mountsText=@(Invoke-Docker -Arguments @('inspect','--format','{{json .Mounts}}',[string]$id))
    if($labelsText.Count -ne 1 -or $mountsText.Count -ne 1){throw '容器归属无法核验；拒绝操作。'}
    $labels=$labelsText[0]|ConvertFrom-Json -ErrorAction Stop
    $service=[string]$labels.PSObject.Properties['com.docker.compose.service'].Value
    $workingDir=[string]$labels.PSObject.Properties['com.docker.compose.project.working_dir'].Value
    if([string]$labels.PSObject.Properties['com.docker.compose.project'].Value -cne 'qicheng-agent-channels' -or
       $service -cnotin @('channel1','channel2') -or
       -not $workingDir -or -not(Same-Path ([IO.Path]::GetFullPath($workingDir)) $installRoot)){
        throw '容器 Compose 归属不匹配；拒绝操作。'
    }
    $mounts=$mountsText[0]|ConvertFrom-Json -ErrorAction Stop
    $number=$service.Substring(7)
    $homeMount=@($mounts|Where-Object{$_.Type -eq 'volume' -and $_.Name -ceq "qicheng-lite-home-$number" -and $_.Destination -ceq '/home/channel'})
    if($homeMount.Count -ne 1){throw '容器持久卷归属不匹配；拒绝操作。'}
    $ownedContainers+=@{id=[string]$id;service=$service}
}
$preview=[ordered]@{schemaVersion=1;status='uninstall-preview';installRoot=$installRoot;dataRoot=$dataRoot;recoveryPath=$recoveryPath;composeProject='qicheng-agent-channels';containerIds=@($ownedContainers|ForEach-Object{$_.id});shortcuts=@($ownedShortcuts);volumesRemoved=$false;imagesRemoved=$false;dataPreserved=$true;applyRequested=[bool]$Apply;hostChangesMade=$false}
if(-not $Apply -or -not $PSCmdlet.ShouldProcess($installRoot,'停止本安装频道并保留数据卸载')){$preview|ConvertTo-Json -Depth 5;return}

$viewerPath=Join-Path $installRoot 'dist\AgentChannels.exe'
$viewerProcesses=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{[string]$_.ExecutablePath -and (Same-Path ([string]$_.ExecutablePath) $viewerPath)})
foreach($process in $viewerProcesses){
    $current=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$process.ProcessId)" -ErrorAction Stop
    if($current -and [string]$current.ExecutablePath -and (Same-Path ([string]$current.ExecutablePath) $viewerPath)){
        Stop-Process -Id ([int]$process.ProcessId) -ErrorAction Stop
        $stopped=Get-Process -Id ([int]$process.ProcessId) -ErrorAction SilentlyContinue
        if($stopped -and -not $stopped.WaitForExit(10000)){
            throw '后台 Viewer 未在 10 秒内退出；安装与数据保持原位，请关闭查看器后重试。'
        }
    }
}
foreach($container in $ownedContainers){
    # Stop by the already inspected container ID; do not issue project-wide down.
    Invoke-Docker -Arguments @('stop',$container.id)|Out-Null
}
New-Item -ItemType Directory -Path $recoveryRoot -Force|Out-Null
Move-Item -LiteralPath $installRoot -Destination $recoveryPath -ErrorAction Stop
try{Set-QichengLitePrivateAcl -Path $recoveryPath}catch{throw "安装已移至恢复目录 $recoveryPath，但私有 ACL 设置失败；请先限制访问。原错误：$($_.Exception.Message)"}
try{
    foreach($path in $ownedShortcuts){if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}}
}catch{throw "安装已移至恢复目录 $recoveryPath，但快捷方式清理未完成；请核对残留。原错误：$($_.Exception.Message)"}
[ordered]@{schemaVersion=1;status='uninstalled-data-kept';installRoot=$installRoot;dataRoot=$dataRoot;recoveryPath=$recoveryPath;stoppedContainers=@($ownedContainers|ForEach-Object{$_.id});shortcutsRemoved=@($ownedShortcuts);volumesRemoved=$false;imagesRemoved=$false;dataPreserved=$true;hostChangesMade=$true}|ConvertTo-Json -Depth 5
