[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [string]$PackageRoot=$PSScriptRoot,
    [string]$InstallRoot,
    [string]$DataRoot,
    [string]$ImportTokenPath,
    [string]$StartMenuRoot,
    [string]$DesktopRoot,
    [string]$StartupRoot,
    [string]$LegacyStartupRoot,
    [switch]$DisableLegacyWindowsChannelsStartup,
    [switch]$LaunchAfterInstall,
    [string]$DockerPath='docker',
    [ValidateRange(1,45)][int]$HealthAttempts=45,
    [ValidateRange(1024,65535)][int]$Port1=18761,
    [ValidateRange(1024,65535)][int]$Port2=18762,
    [switch]$NonInteractive,
    [switch]$Apply
)

$ErrorActionPreference='Stop'
if($NonInteractive){$ConfirmPreference='None'}
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=Get-QichengLiteInstallRoot}
$packageRoot=Resolve-QichengLitePath -Path $PackageRoot -Label 'PackageRoot'
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$existingRecord=Read-QichengLiteInstallRecord -InstallRoot $installRoot
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

$legacyLink=Join-Path $legacyStartupRoot '启程 Windows 频道.lnk'
$legacyBackup=Join-Path $dataRoot 'compatibility-backup\启程 Windows 频道.lnk'
$plan=[ordered]@{schemaVersion=1;status='not-installed';version=[string]$manifest.version;installRoot=$installRoot;dataRoot=$dataRoot;files=$expected.Count;tokenAction=if($ImportTokenPath){'import'}elseif($tokenValue){'preserve'}else{'generate'};composeProject='qicheng-agent-channels';ports=@(18761,18762);defaultViewerMode='background';disableLegacyWindowsChannelsStartup=[bool]$DisableLegacyWindowsChannelsStartup;legacyShortcutPresent=(Test-Path -LiteralPath $legacyLink -PathType Leaf);volumesRemoved=$false;applyRequested=[bool]$Apply;hostChangesMade=$false}
if(-not $Apply){$plan|ConvertTo-Json -Depth 5;return}

$viewerPath=Join-Path $installRoot 'dist\AgentChannels.exe'
$running=@()
try{$running=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{[string]$_.ExecutablePath -and ([string]$_.ExecutablePath).Equals($viewerPath,[StringComparison]::OrdinalIgnoreCase)}|ForEach-Object{[ordered]@{processId=[int]$_.ProcessId;name=[string]$_.Name;role='viewer'}})}catch{}
if($running.Count){[ordered]@{schemaVersion=1;status='blocked-process-in-use';message='启程轻量工作台仍在运行。请从托盘退出后重试；当前版本保持不变。';processes=$running;existingVersionPreserved=$true;hostChangesMade=$false}|ConvertTo-Json -Depth 5;return}
if(-not $PSCmdlet.ShouldProcess($installRoot,'安装或升级启程轻量版')){$plan|ConvertTo-Json -Depth 5;return}

$parent=Split-Path -Parent $installRoot
New-Item -ItemType Directory -Path $parent -Force|Out-Null
$stage=Join-Path $parent ('.QichengLite.stage.'+[guid]::NewGuid().ToString('N'))
$backup=$null
$activated=$false
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
    $record=[ordered]@{schemaVersion=1;product='Qicheng Lite';version=[string]$manifest.version;installedAt=(Get-Date).ToUniversalTime().ToString('o');dataRoot=$dataRoot;composeProject='qicheng-agent-channels';tokenPath='.local/channel.token';startupLink=(Join-Path $startupRoot '启程轻量工作台.lnk');startMenuRoot=$startMenuRoot;desktopLink=(Join-Path $desktopRoot '启程轻量工作台.lnk')}
    $record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $stage '.qicheng-lite-install.json') -Encoding UTF8
    if(Test-Path -LiteralPath $installRoot){$backup=Join-Path $parent ('.QichengLite.backup.'+[guid]::NewGuid().ToString('N'));Move-Item -LiteralPath $installRoot -Destination $backup}
    Move-Item -LiteralPath $stage -Destination $installRoot
    $activated=$true
    New-Item -ItemType Directory -Path $dataRoot -Force|Out-Null
    Set-QichengLitePrivateAcl -Path $dataRoot
    Set-QichengLitePrivateAcl -Path (Join-Path $installRoot '.local')
    Set-QichengLitePrivateAcl -Path (Join-Path $installRoot '.local\channel.token') -File
    New-Item -ItemType Directory -Path $startMenuRoot,$desktopRoot,$startupRoot -Force|Out-Null
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
    New-Link (Join-Path $startupRoot '启程轻量工作台.lnk') $powershell $backgroundArgs
    New-Link (Join-Path $startMenuRoot '管理启程轻量工作台.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$startScript+'"')
    New-Link (Join-Path $startMenuRoot '诊断启程轻量工作台.lnk') $powershell ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Diagnose-Qicheng-Lite.ps1')+'"')
    New-Link (Join-Path $startMenuRoot '取回频道一下载文件.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Export-Downloads.ps1')+'" -Channel 1 -Open')
    New-Link (Join-Path $startMenuRoot '取回频道二下载文件.lnk') $powershell ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Export-Downloads.ps1')+'" -Channel 2 -Open')
    New-Link (Join-Path $startMenuRoot '恢复旧 Windows 频道自启动.lnk') $powershell ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Restore-LegacyWindowsChannelsStartup.ps1')+'" -Apply')
    $legacyDisabled=$false
    if($DisableLegacyWindowsChannelsStartup -and (Test-Path -LiteralPath $legacyLink -PathType Leaf)){
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyBackup) -Force|Out-Null
        if(-not(Test-Path -LiteralPath $legacyBackup -PathType Leaf)){Copy-Item -LiteralPath $legacyLink -Destination $legacyBackup}
        Remove-Item -LiteralPath $legacyLink -Force
        $legacyDisabled=$true
    }
    if($backup){Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue}
}catch{
    if($activated -and (Test-Path -LiteralPath $installRoot)){Remove-Item -LiteralPath $installRoot -Recurse -Force}
    if($backup -and (Test-Path -LiteralPath $backup)){Move-Item -LiteralPath $backup -Destination $installRoot}
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
    throw
}

$startStatus=$null
if($LaunchAfterInstall){
    try{$startStatus=(& (Join-Path $installRoot 'Start-Qicheng-Lite.ps1') -Background -BuildBackend -DockerPath $DockerPath -HealthAttempts $HealthAttempts -Port1 $Port1 -Port2 $Port2|Out-String|ConvertFrom-Json).status}catch{$startStatus='start-failed';$startError=$_.Exception.Message}
}
[ordered]@{schemaVersion=1;status=if($startStatus -eq 'start-failed'){'installed-start-failed'}else{'installed'};version=[string]$manifest.version;installRoot=$installRoot;dataRoot=$dataRoot;tokenImported=[bool]$ImportTokenPath;tokenDisplayed=$false;composeProject='qicheng-agent-channels';ports=@(18761,18762);viewerMode='background';legacyStartupDisabled=$legacyDisabled;legacyBackup=if($legacyDisabled){$legacyBackup}else{$null};startStatus=$startStatus;startError=if($startStatus -eq 'start-failed'){$startError}else{$null};volumesRemoved=$false;hostChangesMade=$true}|ConvertTo-Json -Depth 5
