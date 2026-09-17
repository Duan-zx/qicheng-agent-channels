[CmdletBinding()]
param([switch]$SkipPublicRoundTrip)

$ErrorActionPreference='Stop'
$productRoot=Split-Path -Parent $PSScriptRoot
$moduleRoot=Split-Path -Parent $productRoot
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('qicheng-lite-product-test-'+[guid]::NewGuid().ToString('N'))
$serverProcess=$null

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT: $Message"}}
function Read-Json([string]$Path){Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}
function Quote-Ps([string]$Value){"'"+$Value.Replace("'","''")+"'"}
function Get-FreePort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();try{([Net.IPEndPoint]$listener.LocalEndpoint).Port}finally{$listener.Stop()}
}
function Get-TestOwnedProcesses([string]$Root){
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    try{
        @(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{
            if(-not[string]::IsNullOrWhiteSpace([string]$_.ExecutablePath)){
                try{[IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)}catch{$false}
            }else{$false}
        })
    }catch{@()}
}
function Test-Manifest([string]$Root){
    $manifest=Read-Json (Join-Path $Root 'package-manifest.json')
    $listed=@($manifest.files)
    $actual=@(Get-ChildItem -LiteralPath $Root -Recurse -File|ForEach-Object{$_.FullName.Substring($Root.Length).TrimStart('\').Replace('\','/')}|Where-Object{$_ -ne 'package-manifest.json'})
    Assert-True ($listed.Count -eq $actual.Count) "package manifest count mismatch: $Root"
    foreach($entry in $listed){
        $path=Join-Path $Root ([string]$entry.path)
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "manifest file missing: $($entry.path)"
        Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq [string]$entry.sha256) "manifest hash mismatch: $($entry.path)"
    }
    Assert-True (-not(@($actual|Where-Object{$_ -match '(^|/)(\.local|channel\.token|\.git)(/|$)'}).Count)) 'private state entered package'
    $sourceManifest=Read-Json (Join-Path $Root 'SOURCE-MANIFEST.json')
    foreach($entry in @($sourceManifest.files)){
        $source=Join-Path $Root ('source/'+[string]$entry.path)
        Assert-True ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -eq [string]$entry.sha256) "source manifest hash mismatch: $($entry.path)"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $Root 'LICENSE')) 'Apache license missing'
    Assert-True (Test-Path -LiteralPath (Join-Path $Root 'THIRD-PARTY-NOTICES.md')) 'third-party notices missing'
    return $manifest
}

try{
    New-Item -ItemType Directory -Path $testRoot|Out-Null
    $output=Join-Path $testRoot 'packages'
    $build=(& (Join-Path $productRoot 'Build-Package.ps1') -OutputDirectory $output|Out-String|ConvertFrom-Json)
    Assert-True ($build.status -eq 'built') 'build did not report built'
    Assert-True ($build.version -eq '0.2.0-alpha.1-local') 'unexpected package version'
    Assert-True (-not $build.dockerBundled) 'package must not claim Docker is bundled'
    Assert-True ([bool]$build.firstBuildRequiresNetwork) 'network boundary missing'
    Assert-True ($build.download -eq 'Qicheng-Lite.zip' -and $build.hostPlatform -eq 'windows-x64' -and $build.guestPlatform -eq 'linux-container') 'download naming or platform contract failed'
    Assert-True (-not $build.linuxHostReleaseBuilt) 'Linux host release must not be emitted'
    foreach($archive in @($build.windows.archive)){Assert-True (Test-Path -LiteralPath $archive -PathType Leaf) "archive missing: $archive"}
    $windowsManifest=Test-Manifest $build.windows.directory
    Assert-True ($windowsManifest.platform -eq 'windows-x64') 'Windows platform mismatch'
    Assert-True ($windowsManifest.guestPlatform -eq 'linux-container') 'guest platform mismatch'
    Assert-True ($windowsManifest.PSObject.Properties.Name -notcontains 'repositoryCommit') 'package manifest leaked Git revision'
    $embeddedSourceManifest=Read-Json (Join-Path $build.windows.directory 'SOURCE-MANIFEST.json')
    Assert-True ($embeddedSourceManifest.PSObject.Properties.Name -notcontains 'repositoryCommit') 'source manifest leaked Git revision'

    $sourcePaths=@((Import-PowerShellDataFile -LiteralPath (Join-Path $productRoot 'Source-Allowlist.psd1')).Files)
    Assert-True (-not(@($sourcePaths|Where-Object{$_ -match 'PILOT|Start-Pilot|test_pilot|channel_cli'}).Count)) 'private pilot files entered source allowlist'
    $moduleReadme=Get-Content -LiteralPath (Join-Path $moduleRoot 'README.md') -Raw
    Assert-True ($moduleReadme -notmatch 'DELL|NODE01|START-HERE|HANDOFF|jjx|hongyan') 'module README retains private-machine or pilot references'

    $selfTest=Join-Path $testRoot 'viewer-self-test.json'
    $selfTestProcess=Start-Process -FilePath (Join-Path $build.windows.directory 'dist\AgentChannels.exe') -ArgumentList @('--self-test',$selfTest) -Wait -PassThru -WindowStyle Hidden
    Assert-True ($selfTestProcess.ExitCode -eq 0) 'viewer self-test failed'
    $viewerResult=Read-Json $selfTest
    Assert-True ($viewerResult.coordinate_mapping -and $viewerResult.jpeg_route -and $viewerResult.default_hidden -and $viewerResult.single_instance) 'viewer contract failed'

    $install=Join-Path $testRoot 'installed'
    $data=Join-Path $testRoot 'data'
    $startMenu=Join-Path $testRoot 'start-menu'
    $desktop=Join-Path $testRoot 'desktop'
    $startup=Join-Path $testRoot 'startup'
    $legacyStartup=Join-Path $testRoot 'legacy-startup'
    New-Item -ItemType Directory -Path $startMenu,$desktop,$startup,$legacyStartup|Out-Null
    Set-Content -LiteralPath (Join-Path $legacyStartup '启程 Windows 频道.lnk') -Value 'legacy-shortcut' -NoNewline
    Set-Content -LiteralPath (Join-Path $legacyStartup 'unrelated.lnk') -Value 'unrelated' -NoNewline
    $tokenPath=Join-Path $testRoot 'import.token';$token=-join ('ab'*32)
    [IO.File]::WriteAllText($tokenPath,$token,[Text.UTF8Encoding]::new($false))
    $installer=Join-Path $build.windows.directory 'Install-Qicheng-Lite.ps1'
    $common=@{PackageRoot=$build.windows.directory;InstallRoot=$install;DataRoot=$data;StartMenuRoot=$startMenu;DesktopRoot=$desktop;StartupRoot=$startup;LegacyStartupRoot=$legacyStartup;ImportTokenPath=$tokenPath;DisableLegacyWindowsChannelsStartup=$true;Confirm=$false}
    $plan=(& $installer @common|Out-String|ConvertFrom-Json)
    Assert-True ($plan.status -eq 'not-installed' -and -not $plan.hostChangesMade) 'installer plan mutated host state'
    Assert-True (Test-Path -LiteralPath (Join-Path $legacyStartup '启程 Windows 频道.lnk')) 'plan removed legacy shortcut'
    $installText=(& $installer @common -Apply|Out-String)
    Assert-True ($installText -notmatch [regex]::Escape($token)) 'installer output exposed token'
    $installedResult=$installText|ConvertFrom-Json
    Assert-True ($installedResult.status -eq 'installed' -and $installedResult.legacyStartupDisabled) 'temporary install failed'
    Assert-True ((Get-Content -LiteralPath (Join-Path $install '.local\channel.token') -Raw) -ceq $token) 'imported token mismatch'
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $legacyStartup '启程 Windows 频道.lnk'))) 'legacy shortcut was not disabled'
    Assert-True (Test-Path -LiteralPath (Join-Path $legacyStartup 'unrelated.lnk')) 'unrelated shortcut changed'
    Assert-True (Test-Path -LiteralPath (Join-Path $data 'compatibility-backup\启程 Windows 频道.lnk')) 'legacy backup missing'
    $shell=New-Object -ComObject WScript.Shell
    foreach($linkPath in @((Join-Path $startup '启程轻量工作台.lnk'),(Join-Path $desktop '启程轻量工作台.lnk'),(Join-Path $startMenu '启程轻量工作台.lnk'))){
        $link=$shell.CreateShortcut($linkPath)
        Assert-True ($link.Arguments -match '-WindowStyle Hidden' -and $link.Arguments -match '-Background') "background shortcut contract failed: $linkPath"
    }
    $manage=$shell.CreateShortcut((Join-Path $startMenu '管理启程轻量工作台.lnk'))
    Assert-True ($manage.Arguments -match '-WindowStyle Hidden' -and $manage.Arguments -notmatch '-Background') 'management shortcut contract failed'
    foreach($channel in 1,2){
        $exportLink=$shell.CreateShortcut((Join-Path $startMenu "取回频道$(@{1='一';2='二'}[$channel])下载文件.lnk"))
        Assert-True ($exportLink.Arguments -match '-WindowStyle Hidden' -and $exportLink.Arguments -match "-Channel $channel" -and $exportLink.Arguments -match '-Open') "download export shortcut failed: $channel"
    }

    $upgradeCommon=$common.Clone();$upgradeCommon.Remove('ImportTokenPath');$upgradeCommon.Remove('DataRoot')
    $upgrade=(& $installer @upgradeCommon -Apply|Out-String|ConvertFrom-Json)
    Assert-True ($upgrade.status -eq 'installed') 'upgrade failed'
    Assert-True ([string]$upgrade.dataRoot -eq [IO.Path]::GetFullPath($data)) 'upgrade did not inherit custom DataRoot'
    Assert-True ([string](Read-Json (Join-Path $install '.qicheng-lite-install.json')).dataRoot -eq [IO.Path]::GetFullPath($data)) 'upgrade record drifted from custom DataRoot'
    Assert-True ((Get-Content -LiteralPath (Join-Path $install '.local\channel.token') -Raw) -ceq $token) 'upgrade did not preserve token'
    $restore=(& (Join-Path $install 'Restore-LegacyWindowsChannelsStartup.ps1') -InstallRoot $install -LegacyStartupRoot $legacyStartup -Apply -Confirm:$false|Out-String|ConvertFrom-Json)
    Assert-True ($restore.status -eq 'restored' -and $restore.backupPreserved) 'legacy shortcut restore failed'
    Assert-True (Test-Path -LiteralPath (Join-Path $legacyStartup 'unrelated.lnk')) 'restore changed unrelated shortcut'

    $fakeDocker=Join-Path $testRoot 'fake-docker.cmd'
    $dockerLog=Join-Path $testRoot 'docker.log';$env:QICHENG_LITE_FAKE_DOCKER_LOG=$dockerLog
    "@echo off`r`n>>`"%QICHENG_LITE_FAKE_DOCKER_LOG%`" echo %*`r`nexit /b 0`r`n"|Set-Content -LiteralPath $fakeDocker -Encoding ASCII
    $port1=Get-FreePort;do{$port2=Get-FreePort}while($port2 -eq $port1)
    $cmdInstall=Join-Path $testRoot 'cmd-installed';$cmdData=Join-Path $testRoot 'cmd-data';$cmdRunner=Join-Path $testRoot 'run-installer.cmd'
    @"
@echo off
set QICHENG_LITE_NO_PAUSE=1
call "$($build.windows.directory)\Install-Qicheng-Lite.cmd" -InstallRoot "$cmdInstall" -DataRoot "$cmdData" -StartMenuRoot "$($testRoot)\cmd-menu" -DesktopRoot "$($testRoot)\cmd-desktop" -StartupRoot "$($testRoot)\cmd-startup" -LegacyStartupRoot "$($testRoot)\cmd-legacy" -ImportTokenPath "$tokenPath" -DockerPath "$fakeDocker" -HealthAttempts 1 -Port1 $port1 -Port2 $port2
exit /b %ERRORLEVEL%
"@|Set-Content -LiteralPath $cmdRunner -Encoding ASCII
    $cmdOutput=(& cmd.exe /d /c $cmdRunner 2>&1|Out-String);$cmdExit=$LASTEXITCODE
    Assert-True ($cmdExit -eq 2) "double-click installer did not return startup-failed exit code (exit=$cmdExit; output=$cmdOutput)"
    Assert-True ($cmdOutput -match 'installed-start-failed' -and $cmdOutput -match 'was installed, but its first backend build or health check failed') 'double-click installer did not explain retained install and startup failure'
    Assert-True ($cmdOutput -notmatch 'installation finished') 'double-click installer printed false success after startup failure'
    Assert-True (Test-Path -LiteralPath (Join-Path $cmdInstall '.qicheng-lite-install.json')) 'startup failure did not retain installation'
    $requestLog=Join-Path $testRoot 'requests.log';$readyFile=Join-Path $testRoot 'server.ready';$serverScript=Join-Path $testRoot 'fake-state-server.py'
    @'
import http.server,json,sys,threading,time
token,ready,log=sys.argv[1:4]; ports=[int(x) for x in sys.argv[4:]]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        if self.path=='/health': body={'service':'agent-channels'}
        elif self.path=='/api/state' and self.headers.get('Authorization')=='Bearer '+token:
            body={'input_target':'private-linux-display','width':1600,'height':900,'mode':'paused'}
            with open(log,'a',encoding='utf-8') as f: f.write('authorized-state\n')
        else: self.send_response(401); self.end_headers(); return
        data=json.dumps(body).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
servers=[http.server.ThreadingHTTPServer(('127.0.0.1',p),Handler) for p in ports]
for server in servers: threading.Thread(target=server.serve_forever,daemon=True).start()
open(ready,'w').write('ready')
while True: time.sleep(1)
'@|Set-Content -LiteralPath $serverScript -Encoding UTF8
    $python=(Get-Command python.exe -ErrorAction Stop).Source
    $serverProcess=Start-Process -FilePath $python -ArgumentList @($serverScript,$token,$readyFile,$requestLog,$port1,$port2) -WindowStyle Hidden -PassThru
    foreach($n in 1..50){if(Test-Path -LiteralPath $readyFile){break};Start-Sleep -Milliseconds 100}
    Assert-True (Test-Path -LiteralPath $readyFile) 'fake state server did not start'
    $fakeViewerSource=Join-Path $testRoot 'FakeViewer.cs'
    [IO.File]::WriteAllText($fakeViewerSource,'public static class FakeViewer { [System.STAThread] public static int Main(string[] args) { return 0; } }',[Text.UTF8Encoding]::new($false))
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /optimize+ "/out:$install\dist\AgentChannels.exe" $fakeViewerSource
    Assert-True ($LASTEXITCODE -eq 0) 'fake viewer compilation failed'
    $started=(& (Join-Path $install 'Start-Qicheng-Lite.ps1') -InstallRoot $install -Background -BuildBackend -DockerPath $fakeDocker -HealthAttempts 3 -Port1 $port1 -Port2 $port2|Out-String|ConvertFrom-Json)
    Assert-True ($started.status -eq 'started' -and $started.viewerMode -eq 'background') 'isolated start failed'
    foreach($n in 1..20){if(-not @(Get-TestOwnedProcesses -Root $testRoot).Count){break};Start-Sleep -Milliseconds 50}
    Assert-True (@(Get-TestOwnedProcesses -Root $testRoot).Count -eq 0) 'fake viewer did not exit after isolated start'
    $requests=@(Get-Content -LiteralPath $requestLog)
    Assert-True ($requests.Count -ge 2) 'authenticated state was not checked for both channels'
    $dockerCalls=Get-Content -LiteralPath $dockerLog -Raw
    Assert-True ($dockerCalls -match '--project-name qicheng-agent-channels' -and $dockerCalls -match '--profile second' -and $dockerCalls -match 'channel1 channel2' -and $dockerCalls -match '--build') 'compose start contract failed'
    Assert-True ($dockerCalls -notmatch '(^|\s)down(\s|$)|(^|\s)-v(\s|$)') 'start attempted destructive Docker action'

    Remove-Item -LiteralPath $dockerLog -Force
    $diagnosisText=(& (Join-Path $install 'Diagnose-Qicheng-Lite.ps1') -InstallRoot $install -DockerPath $fakeDocker -Port1 $port1 -Port2 $port2 -StartupRoot $startup -LegacyStartupRoot $legacyStartup|Out-String)
    Assert-True ($diagnosisText -notmatch [regex]::Escape($token)) 'diagnosis exposed token'
    $diagnosis=$diagnosisText|ConvertFrom-Json
    Assert-True (-not $diagnosis.mutationsMade -and -not $diagnosis.tokenDisplayed) 'diagnosis mutation contract failed'
    $diagnoseCalls=Get-Content -LiteralPath $dockerLog -Raw
    Assert-True ($diagnoseCalls -match 'compose .* ps' -and $diagnoseCalls -notmatch '(^|\s)up(\s|$)|(^|\s)down(\s|$)|(^|\s)-v(\s|$)') 'diagnosis used mutating Docker command'

    $exportDocker=Join-Path $testRoot 'fake-export-docker.ps1';$exportDockerLog=Join-Path $testRoot 'export-docker.log';$env:QICHENG_LITE_EXPORT_DOCKER_LOG=$exportDockerLog
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArgs)
Add-Content -LiteralPath $env:QICHENG_LITE_EXPORT_DOCKER_LOG -Value ($DockerArgs -join ' ')
if($DockerArgs[0] -eq 'version'){'1.0';return}
if($DockerArgs[0] -eq 'compose' -and $DockerArgs -contains '-q'){'qicheng-test-channel1';return}
if($DockerArgs[0] -eq 'inspect'){
    if($DockerArgs[2] -match 'compose.project'){'qicheng-agent-channels'}else{'channel1'}
    return
}
if($DockerArgs[0] -eq 'cp'){
    $destination=$DockerArgs[-1]
    New-Item -ItemType Directory -Path $destination -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $destination 'sample.txt') -Value 'guest-download' -NoNewline
    return
}
throw 'Unexpected fake Docker arguments'
'@|Set-Content -LiteralPath $exportDocker -Encoding UTF8
    $downloadText=(& (Join-Path $install 'Export-Downloads.ps1') -Channel 1 -InstallRoot $install -DataRoot $data -DockerPath $exportDocker|Out-String)
    Assert-True ($downloadText -notmatch [regex]::Escape($token)) 'download export exposed token'
    $download=$downloadText|ConvertFrom-Json
    Assert-True ($download.status -eq 'exported' -and $download.ownContainerVerified -and $download.guestFilesPreserved -and -not $download.volumesRemoved) 'download snapshot contract failed'
    Assert-True ((Get-Content -LiteralPath (Join-Path $download.destination 'sample.txt') -Raw) -eq 'guest-download') 'download snapshot file missing'
    $exportCalls=Get-Content -LiteralPath $exportDockerLog -Raw
    Assert-True ($exportCalls -match 'qicheng-test-channel1:/home/channel/Downloads/\.' -and $exportCalls -notmatch '(^|\s)rm(\s|$)|(^|\s)down(\s|$)|(^|\s)-v(\s|$)') 'download export Docker contract failed'

    $ps5Install=Join-Path $testRoot 'installed-ps5';$ps5Data=Join-Path $testRoot 'data-ps5';$ps5Script=Join-Path $testRoot 'ps5-install.ps1'
    $ps5Command='& '+(Quote-Ps $installer)+' -PackageRoot '+(Quote-Ps $build.windows.directory)+' -InstallRoot '+(Quote-Ps $ps5Install)+' -DataRoot '+(Quote-Ps $ps5Data)+' -StartMenuRoot '+(Quote-Ps (Join-Path $testRoot 'ps5-menu'))+' -DesktopRoot '+(Quote-Ps (Join-Path $testRoot 'ps5-desktop'))+' -StartupRoot '+(Quote-Ps (Join-Path $testRoot 'ps5-startup'))+' -LegacyStartupRoot '+(Quote-Ps (Join-Path $testRoot 'ps5-legacy'))+' -ImportTokenPath '+(Quote-Ps $tokenPath)+' -Apply -Confirm:$false'
    [IO.File]::WriteAllText($ps5Script,$ps5Command,[Text.UTF8Encoding]::new($true))
    $ps5Text=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps5Script|Out-String)
    Assert-True ($LASTEXITCODE -eq 0 -and (($ps5Text|ConvertFrom-Json).status -eq 'installed')) 'Windows PowerShell 5.1 install/ACL branch failed'

    $publicRoot=Join-Path $testRoot 'public';New-Item -ItemType Directory -Path $publicRoot|Out-Null
    $export=(& (Join-Path $productRoot 'Export-PublicSource.ps1') -OutputDirectory $publicRoot|Out-String|ConvertFrom-Json)
    Assert-True ($export.status -eq 'exported' -and $export.fileCount -eq $sourcePaths.Count) 'public source export failed'
    $publicManifest=Read-Json (Join-Path $publicRoot 'QICHENG-LITE-PUBLIC-SOURCE-MANIFEST.json')
    Assert-True ($null -eq $publicManifest.repositoryCommit) 'public export leaked private Git commit'
    foreach($entry in @($publicManifest.files)){Assert-True ((Get-FileHash -LiteralPath (Join-Path $publicRoot ([string]$entry.path)) -Algorithm SHA256).Hash.ToLowerInvariant() -eq [string]$entry.sha256) "public export hash mismatch: $($entry.path)"}
    if(-not $SkipPublicRoundTrip){
        $roundtrip=Join-Path $testRoot 'public-packages'
        $rebuilt=(& (Join-Path $publicRoot 'tools\agent-channels\product\Build-Package.ps1') -OutputDirectory $roundtrip|Out-String|ConvertFrom-Json)
        Assert-True ($rebuilt.status -eq 'built' -and (Test-Path -LiteralPath $rebuilt.windows.archive) -and -not $rebuilt.linuxHostReleaseBuilt) 'public source roundtrip build failed'
    }

    [ordered]@{schemaVersion=1;status='passed';version=$build.version;packageFiles=$build.windows.files;sourceFiles=$sourcePaths.Count;viewerSelfTest=$true;windowsPowerShell51Install=$true;isolatedDockerContract=$true;publicExportRoundTrip=(-not $SkipPublicRoundTrip);realDockerTouched=$false;realStartupTouched=$false;realInstallTouched=$false}|ConvertTo-Json -Depth 5
}finally{
    if($serverProcess -and -not $serverProcess.HasExited){Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue}
    foreach($process in @(Get-TestOwnedProcesses -Root $testRoot)){
        if([int]$process.ProcessId -ne $PID){Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue}
    }
    Remove-Item Env:QICHENG_LITE_FAKE_DOCKER_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:QICHENG_LITE_EXPORT_DOCKER_LOG -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
