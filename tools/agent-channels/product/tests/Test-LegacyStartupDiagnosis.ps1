[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('qicheng-lite-startup-test-'+[guid]::NewGuid().ToString('N'))
$previousLocalAppData=$env:LOCALAPPDATA
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
try{
    $env:LOCALAPPDATA=Join-Path $root 'local'
    $lite=Join-Path $env:LOCALAPPDATA 'Programs\QichengLite'
    $windows=Join-Path $root 'windows'
    $startup=Join-Path $root 'startup'
    $data=Join-Path $root 'windows-data'
    New-Item -ItemType Directory -Path $lite,$windows,$startup,$data -Force|Out-Null
    $runtime=Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'
    Copy-Item (Join-Path $runtime 'Diagnose-Qicheng-Lite.ps1') $lite
    Copy-Item (Join-Path $runtime 'Product.Common.ps1') $lite
    $liteRecord='{"version":"0.2.0-alpha.1"}'
    Set-Content (Join-Path $lite '.qicheng-lite-install.json') $liteRecord
    $source=Join-Path (Split-Path -Parent (Split-Path -Parent $runtime)) '..\windows-channels\product\runtime\Start-WindowsChannels.ps1'
    # The fixture uses the actual launcher source; its package manifest pins its bytes.
    Assert (Test-Path $source) 'Windows launcher source missing'
    $launcher=Join-Path $windows 'Start-WindowsChannels.ps1'
    Copy-Item $source $launcher
    $viewer=Join-Path $windows 'viewer\dist\WindowsChannelsViewer.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $viewer) -Force|Out-Null
    Set-Content $viewer 'viewer fixture'
    $scriptHash=(Get-FileHash $launcher -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest=[ordered]@{schemaVersion=1;product='Qicheng Windows Channels';version='0.1.0-alpha.13-local';files=@([ordered]@{path='Start-WindowsChannels.ps1';bytes=(Get-Item $launcher).Length;sha256=$scriptHash},[ordered]@{path='viewer/dist/WindowsChannelsViewer.exe';bytes=(Get-Item $viewer).Length;sha256=(Get-FileHash $viewer -Algorithm SHA256).Hash.ToLowerInvariant()})}
    $manifestPath=Join-Path $windows 'package-manifest.json'
    $manifest|ConvertTo-Json -Depth 5|Set-Content $manifestPath -Encoding UTF8
    $linkPath=Join-Path $startup '启程 Windows 频道.lnk'
    $record=[ordered]@{schemaVersion=1;version='0.1.0-alpha.13-local';autoStart='Enabled';startupLink=$linkPath;dataRoot=$data;packageManifestSha256=(Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    $record|ConvertTo-Json|Set-Content (Join-Path $windows '.qicheng-product-install.json') -Encoding UTF8
    '{"schema_version":1,"projects":{"one":{},"two":{}}}'|Set-Content (Join-Path $data 'channels.json')
    $shell=New-Object -ComObject WScript.Shell
    $temporary=Join-Path $startup 'test.lnk'
    $link=$shell.CreateShortcut($temporary)
    $link.TargetPath=(Get-Command powershell.exe).Source
    $link.Arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$launcher+'"'
    $link.WorkingDirectory=$windows
    $link.Save()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
    Move-Item $temporary $linkPath
    function ConflictCheck {
        $json=& (Join-Path $lite 'Diagnose-Qicheng-Lite.ps1') -InstallRoot $lite -DockerPath (Join-Path $root 'missing-docker.exe') -StartupRoot $startup -LegacyStartupRoot $startup|Out-String|ConvertFrom-Json
        @($json.checks|Where-Object name -eq 'legacy-alt-conflict')[0]
    }
    Assert ((ConflictCheck).passed) ('verified alpha.13 should be compatible: '+[string](ConflictCheck).detail)
    $record.version='0.1.0-alpha.12-local';$record|ConvertTo-Json|Set-Content (Join-Path $windows '.qicheng-product-install.json') -Encoding UTF8
    Assert (-not ((ConflictCheck).passed)) ("legacy version accepted: "+(Get-Content (Join-Path $windows '.qicheng-product-install.json') -Raw))
    $record.version='0.1.0-alpha.13-local';$record|ConvertTo-Json|Set-Content (Join-Path $windows '.qicheng-product-install.json') -Encoding UTF8
    Add-Content $launcher '# tampered'
    Assert (-not ((ConflictCheck).passed)) 'tampered launcher accepted'
    Copy-Item $source $launcher -Force
    '{"schema_version":1,"projects":{"one":{},"two":{},"three":{},"four":{},"five":{},"six":{},"seven":{}}}'|Set-Content (Join-Path $data 'channels.json')
    Assert (-not ((ConflictCheck).passed)) 'seven channels accepted'
    '{"schema_version":1,"projects":{"one":{},"two":{}}}'|Set-Content (Join-Path $data 'channels.json')
    Remove-Item $linkPath
    Assert ((ConflictCheck).passed) 'absent shortcut reported as conflict'
    [ordered]@{status='passed';compatibleAlpha13=$true;legacyRejected=$true;tamperingRejected=$true;excessChannelsRejected=$true;absentShortcutAccepted=$true;liveInstallTouched=$false}|ConvertTo-Json
}finally{
    $env:LOCALAPPDATA=$previousLocalAppData
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $fixtureRoot=[IO.Path]::GetFullPath($root).TrimEnd('\')
    $expectedPrefix=$tempRoot+'\qicheng-lite-startup-test-'
    if(-not $fixtureRoot.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase)){throw "Refusing fixture cleanup outside $tempRoot"}
    if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
}
