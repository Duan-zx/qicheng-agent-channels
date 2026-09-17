[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$productRoot=$PSScriptRoot
$moduleRoot=Split-Path -Parent $productRoot
$repoRoot=[IO.Path]::GetFullPath((Join-Path $moduleRoot '..\..'))
if($OutputDirectory -notmatch '^[A-Za-z]:[\\/]'){throw 'OutputDirectory 必须是本机绝对路径。'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
if($output.StartsWith($repoRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw '公开源码导出目录必须在私有仓库外。'}
if(-not(Test-Path -LiteralPath $output -PathType Container)){throw 'OutputDirectory 必须是已存在的空目录。'}
if(@(Get-ChildItem -LiteralPath $output -Force).Count){throw 'OutputDirectory 必须为空。'}
$allowlist=(Import-PowerShellDataFile -LiteralPath (Join-Path $productRoot 'Source-Allowlist.psd1')).Files
$moduleDestination=Join-Path $output 'tools\agent-channels'
$manifestFiles=New-Object 'System.Collections.Generic.List[object]'
foreach($relative in $allowlist){
    $source=Join-Path $moduleRoot $relative
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "白名单源码缺失：$relative"}
    $destination=Join-Path $moduleDestination $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
    $item=Get-Item -LiteralPath $destination
    $manifestFiles.Add([ordered]@{path=('tools/agent-channels/'+$relative.Replace('\','/'));bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()})
}
$manifest=[ordered]@{schemaVersion=1;product='Qicheng Lite';policy='Explicit agent-channels source allowlist. No private Git identity or machine-local data.';excluded=@('.local','dist','tokens','accounts','Docker volumes','browser profiles','caches','logs','private Git metadata');files=$manifestFiles.ToArray()}
$manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'QICHENG-LITE-PUBLIC-SOURCE-MANIFEST.json') -Encoding UTF8
[ordered]@{schemaVersion=1;status='exported';outputDirectory=$output;moduleRoot=$moduleDestination;fileCount=$manifestFiles.Count;manifest=(Join-Path $output 'QICHENG-LITE-PUBLIC-SOURCE-MANIFEST.json')}|ConvertTo-Json -Depth 4
