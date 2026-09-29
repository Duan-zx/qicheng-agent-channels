[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$runtime=Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('qicheng-uninstall-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT: $Message"}}
function Write-Record([string]$Path,[string]$Product='Qicheng Lite'){
    [ordered]@{schemaVersion=1;product=$Product;version='test';dataRoot=$data;composeProject='qicheng-agent-channels';channelCount=1;desktopApp='firefox';startupLink=(Join-Path $startup '启程轻量工作台.lnk');desktopLink=(Join-Path $desktop '启程轻量工作台.lnk');startMenuRoot=$menu}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Path '.qicheng-lite-install.json') -Encoding UTF8
}
try{
    $viewerProcess=$null
    $install=Join-Path $testRoot 'install';$data=Join-Path $testRoot 'data';$recovery=Join-Path $testRoot 'recovery';$menu=Join-Path $testRoot 'menu';$desktop=Join-Path $testRoot 'desktop';$startup=Join-Path $testRoot 'startup'
    New-Item -ItemType Directory -Path $install,$data,$menu,$desktop,$startup,(Join-Path $install '.local'),(Join-Path $install 'dist') -Force|Out-Null
    Write-Record $install
    [ordered]@{schemaVersion=1;product='Qicheng Lite';files=@()}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install 'package-manifest.json') -Encoding UTF8
    foreach($file in @('compose.yaml','Product.Common.ps1','Start-Qicheng-Lite.ps1','dist\AgentChannels.exe')){Set-Content -LiteralPath (Join-Path $install $file) -Value 'fixture'}
    Set-Content -LiteralPath (Join-Path $install '.local\channel.token') -Value ('a'*64)
    Set-Content -LiteralPath (Join-Path $data 'user-data.txt') -Value 'keep'
    $shell=New-Object -ComObject WScript.Shell
    $ownedLink=Join-Path $startup '启程轻量工作台.lnk'
    $otherLink=Join-Path $menu '诊断启程轻量工作台.lnk'
    foreach($item in @(@($ownedLink,(Join-Path $install 'Start-Qicheng-Lite.ps1')),@($otherLink,'C:\other-install\Diagnose-Qicheng-Lite.ps1'))){
        $link=$shell.CreateShortcut($item[0]);$link.TargetPath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';$link.Arguments='-File "'+$item[1]+'"';$link.Save()
    }
    $fakeDocker=Join-Path $testRoot 'fake-docker.ps1';$log=Join-Path $testRoot 'docker.log';$env:QICHENG_UNINSTALL_TEST_LOG=$log;$env:QICHENG_UNINSTALL_TEST_INSTALL=$install
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArgs)
Add-Content -LiteralPath $env:QICHENG_UNINSTALL_TEST_LOG -Value ($DockerArgs -join ' ')
$global:LASTEXITCODE=0
if($DockerArgs[0] -eq 'context'){'npipe:////./pipe/docker_engine';return}
if($DockerArgs[0] -eq 'info'){'linux';return}
if($DockerArgs[0] -eq 'ps'){('a'*64);return}
if($DockerArgs[0] -eq 'inspect'){
    if($DockerArgs[2] -eq '{{json .Config.Labels}}'){
        $working=if($env:QICHENG_UNINSTALL_TEST_FOREIGN){'C:\foreign-lite'}else{$env:QICHENG_UNINSTALL_TEST_INSTALL}
        @{ 'com.docker.compose.project'='qicheng-agent-channels';'com.docker.compose.service'='channel1';'com.docker.compose.project.working_dir'=$working }|ConvertTo-Json -Compress;return
    }
    if($DockerArgs[2] -eq '{{json .Mounts}}'){@(@{Type='volume';Name='qicheng-lite-home-1';Destination='/home/channel'})|ConvertTo-Json -Compress;return}
}
if($DockerArgs[0] -eq 'stop'){$DockerArgs[1];return}
throw ('Unexpected Docker call: '+($DockerArgs -join ' '))
'@|Set-Content -LiteralPath $fakeDocker -Encoding UTF8
    $options=@{InstallRoot=$install;RecoveryRoot=$recovery;DockerPath=$fakeDocker;Confirm=$false}
    $launcher=Get-Content -LiteralPath (Join-Path $runtime 'Uninstall-Qicheng-Lite.cmd') -Raw
    Assert ($launcher -match '(?s):preview.*Uninstall-Qicheng-Lite\.ps1" %ARGS%.*choice /c YN.*:apply.*Uninstall-Qicheng-Lite\.ps1" -Apply -NonInteractive %ARGS%') 'CMD confirmation flow is missing'
    Assert ($launcher -match 'if /I "%~1"=="-Apply"' -and $launcher -match 'Cancelled\. No Apply was requested') 'CMD explicit Apply or cancel handling is missing'
    $preview=(& (Join-Path $runtime 'Uninstall-Qicheng-Lite.ps1') @options|Out-String|ConvertFrom-Json)
    Assert ($preview.status -eq 'uninstall-preview' -and -not $preview.hostChangesMade) 'preview status'
    Assert ((Test-Path -LiteralPath $install) -and (Test-Path -LiteralPath (Join-Path $data 'user-data.txt')) -and (Test-Path -LiteralPath $ownedLink) -and -not(Test-Path -LiteralPath $recovery)) 'preview changed files'
    Assert ((Get-Content -LiteralPath $log -Raw) -notmatch '^stop ') 'preview stopped container'
    Write-Record $install 'Foreign Product'
    $unknown='';try{& (Join-Path $runtime 'Uninstall-Qicheng-Lite.ps1') @options -Apply|Out-Null}catch{$unknown=$_.Exception.Message}
    Assert ($unknown -match '未知安装' -and (Test-Path -LiteralPath $install)) 'unknown install was accepted'
    Write-Record $install
    $env:QICHENG_UNINSTALL_TEST_FOREIGN='1'
    $foreign='';try{& (Join-Path $runtime 'Uninstall-Qicheng-Lite.ps1') @options -Apply|Out-Null}catch{$foreign=$_.Exception.Message}
    Assert ($foreign -match '归属不匹配' -and (Test-Path -LiteralPath $install)) 'foreign container was accepted'
    Remove-Item Env:QICHENG_UNINSTALL_TEST_FOREIGN
    $source=Join-Path $testRoot 'FakeViewer.cs'
    [IO.File]::WriteAllText($source,'public static class FakeViewer { [System.STAThread] public static int Main(string[] args) { System.Threading.Thread.Sleep(30000); return 0; } }',[Text.UTF8Encoding]::new($false))
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /optimize+ "/out:$install\dist\AgentChannels.exe" $source
    Assert ($LASTEXITCODE -eq 0) 'fake Viewer compilation failed'
    $viewerProcess=Start-Process -FilePath (Join-Path $install 'dist\AgentChannels.exe') -WindowStyle Hidden -PassThru
    foreach($attempt in 1..20){if(@(Get-CimInstance Win32_Process -Filter "ProcessId=$($viewerProcess.Id)" -ErrorAction SilentlyContinue|Where-Object{$_.ExecutablePath -eq (Join-Path $install 'dist\AgentChannels.exe')}).Count){break};Start-Sleep -Milliseconds 100}
    Assert (-not $viewerProcess.HasExited) 'fake Viewer did not start'
    $result=(& (Join-Path $runtime 'Uninstall-Qicheng-Lite.ps1') @options -Apply|Out-String|ConvertFrom-Json)
    Assert ($result.status -eq 'uninstalled-data-kept' -and (Test-Path -LiteralPath $result.recoveryPath)) 'install was not archived'
    Assert ($viewerProcess.HasExited) 'Viewer was not stopped before archive'
    Assert ((Test-Path -LiteralPath (Join-Path $result.recoveryPath '.local\channel.token')) -and (Test-Path -LiteralPath (Join-Path $data 'user-data.txt'))) 'private token or data was lost'
    Assert (-not(Test-Path -LiteralPath $ownedLink) -and (Test-Path -LiteralPath $otherLink)) 'shortcut ownership scope'
    Assert (-not(Test-Path -LiteralPath $install)) 'install remained at original path'
    $calls=Get-Content -LiteralPath $log -Raw
    Assert ($calls -match ('stop '+('a'*64)) -and $calls -notmatch 'down|volume rm|image rm') 'Docker operation scope'
    [ordered]@{status='passed';previewUnchanged=$true;dataAndCredentialsKept=$true;unknownAndForeignRejected=$true;viewerExitWaited=$true;launcherConfirmationChecked=$true;realDockerTouched=$false;realInstallTouched=$false}|ConvertTo-Json
}finally{
    if($viewerProcess -and -not $viewerProcess.HasExited){Stop-Process -Id $viewerProcess.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item Env:QICHENG_UNINSTALL_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:QICHENG_UNINSTALL_TEST_INSTALL -ErrorAction SilentlyContinue
    Remove-Item Env:QICHENG_UNINSTALL_TEST_FOREIGN -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^qicheng-uninstall-test-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
