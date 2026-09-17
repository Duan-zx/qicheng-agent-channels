[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$Version='0.2.0-alpha.1-local')
$ErrorActionPreference='Stop'
$productRoot=$PSScriptRoot
$moduleRoot=Split-Path -Parent $productRoot
if($OutputDirectory -notmatch '^[A-Za-z]:[\\/]'){throw 'OutputDirectory 必须是本机绝对路径。'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $output){throw 'OutputDirectory 已存在；请选择新目录。'}
if($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$'){throw 'Version 格式不受支持。'}
New-Item -ItemType Directory -Path $output|Out-Null
$privateBuild=Join-Path $output '.build'
New-Item -ItemType Directory -Path $privateBuild|Out-Null
& (Join-Path $moduleRoot 'Build.ps1') -OutputDirectory $privateBuild|Out-Null
$viewer=Join-Path $privateBuild 'AgentChannels.exe'
if(-not(Test-Path -LiteralPath $viewer -PathType Leaf)){throw '查看器构建产物缺失。'}

$sourcePaths=(Import-PowerShellDataFile -LiteralPath (Join-Path $productRoot 'Source-Allowlist.psd1')).Files
foreach($relative in $sourcePaths){if(-not(Test-Path -LiteralPath (Join-Path $moduleRoot $relative) -PathType Leaf)){throw "白名单源码缺失：$relative"}}
$sourceManifestFiles=@($sourcePaths|ForEach-Object{$path=Join-Path $moduleRoot $_;$item=Get-Item -LiteralPath $path;[ordered]@{path=$_.Replace('\','/');bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}})
$sourceManifest=[ordered]@{schemaVersion=1;product='Qicheng Lite';version=$Version;policy='Explicit source allowlist. No tokens, accounts, Docker volumes, browser profiles, caches, private history, or machine-local state.';files=$sourceManifestFiles}

function Copy-File([string]$Source,[string]$Root,[string]$Relative,[string]$Kind,[System.Collections.Generic.List[object]]$List){
    $destination=Join-Path $Root $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination
    if($Kind -ne 'source' -and $destination.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)){
        $text=[IO.File]::ReadAllText($destination,[Text.UTF8Encoding]::new($false,$true))
        [IO.File]::WriteAllText($destination,$text,[Text.UTF8Encoding]::new($true))
    }
    $item=Get-Item -LiteralPath $destination
    $List.Add([ordered]@{path=$Relative.Replace('\','/');kind=$Kind;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()})
}
function Add-CommonRuntime([string]$Root,[System.Collections.Generic.List[object]]$List){
    foreach($relative in @('.dockerignore','Dockerfile','compose.yaml','bridge.py','backend/forward.py','backend/README.md','backend/firefox-policies.json','backend/server.py','backend/start.sh','backend/welcome.html','backend/theme/ai-space.png')){
        Copy-File (Join-Path $moduleRoot $relative) $Root $relative 'runtime' $List
    }
    Copy-File (Join-Path $productRoot 'LICENSE') $Root 'LICENSE' 'license' $List
    Copy-File (Join-Path $productRoot 'THIRD-PARTY-NOTICES.md') $Root 'THIRD-PARTY-NOTICES.md' 'notice' $List
    Copy-File (Join-Path $productRoot 'QUICKSTART.zh-CN.md') $Root 'QUICKSTART.zh-CN.md' 'documentation' $List
    foreach($relative in $sourcePaths){Copy-File (Join-Path $moduleRoot $relative) $Root (Join-Path 'source' $relative) 'source' $List}
    $sourceManifest|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $Root 'SOURCE-MANIFEST.json') -Encoding UTF8
    $item=Get-Item -LiteralPath (Join-Path $Root 'SOURCE-MANIFEST.json')
    $List.Add([ordered]@{path='SOURCE-MANIFEST.json';kind='manifest';bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
}

$windowsName='Qicheng-Lite'
$windowsRoot=Join-Path $output $windowsName
New-Item -ItemType Directory -Path $windowsRoot|Out-Null
$windowsFiles=New-Object 'System.Collections.Generic.List[object]'
Add-CommonRuntime $windowsRoot $windowsFiles
Copy-File $viewer $windowsRoot 'dist\AgentChannels.exe' 'built-executable' $windowsFiles
foreach($relative in @('Product.Common.ps1','Install-Qicheng-Lite.ps1','Start-Qicheng-Lite.ps1','Diagnose-Qicheng-Lite.ps1','Export-Downloads.ps1','Restore-LegacyWindowsChannelsStartup.ps1','Install-Qicheng-Lite.cmd')){
    Copy-File (Join-Path (Join-Path $productRoot 'runtime') $relative) $windowsRoot $relative 'installer-runtime' $windowsFiles
}
$windowsManifest=[ordered]@{schemaVersion=1;product='Qicheng Lite';version=$Version;platform='windows-x64';guestPlatform='linux-container';downloadKind='linux-guest-default';builtAt=(Get-Date).ToUniversalTime().ToString('o');files=$windowsFiles.ToArray()}
$windowsManifest|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $windowsRoot 'package-manifest.json') -Encoding UTF8
$windowsArchive=Join-Path $output 'Qicheng-Lite.zip'
Compress-Archive -LiteralPath $windowsRoot -DestinationPath $windowsArchive -CompressionLevel Optimal
Remove-Item -LiteralPath $privateBuild -Recurse -Force
[ordered]@{schemaVersion=1;status='built';version=$Version;download='Qicheng-Lite.zip';hostPlatform='windows-x64';guestPlatform='linux-container';windows=[ordered]@{directory=$windowsRoot;archive=$windowsArchive;files=$windowsFiles.Count;sha256=(Get-FileHash -LiteralPath $windowsArchive -Algorithm SHA256).Hash.ToLowerInvariant()};sourceFiles=$sourcePaths.Count;dockerBundled=$false;firstBuildRequiresNetwork=$true;linuxHostReleaseBuilt=$false}|ConvertTo-Json -Depth 5
