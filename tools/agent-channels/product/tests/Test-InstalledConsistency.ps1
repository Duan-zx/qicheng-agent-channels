$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\runtime\Product.Common.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agent-channel-consistency-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root|Out-Null
    $file=Join-Path $root 'viewer.exe'
    [IO.File]::WriteAllText($file,'original')
    $record=@{product='Qicheng Lite';version='test-1'}
    $manifest=@{schemaVersion=1;product='Qicheng Lite';version='test-1';files=@(@{path='viewer.exe';sha256=(Get-QichengLiteSha256 $file)})}
    $record|ConvertTo-Json|Set-Content (Join-Path $root '.qicheng-lite-install.json') -Encoding UTF8
    $manifest|ConvertTo-Json -Depth 4|Set-Content (Join-Path $root 'package-manifest.json') -Encoding UTF8
    if(-not (Test-QichengLiteInstalledPackage $root).valid){throw 'Matching installation rejected'}
    [IO.File]::WriteAllText($file,'hotfix')
    if((Test-QichengLiteInstalledPackage $root).valid){throw 'Unrecorded binary replacement accepted'}
    [IO.File]::WriteAllText($file,'original')
    $record.version='test-2'
    $record|ConvertTo-Json|Set-Content (Join-Path $root '.qicheng-lite-install.json') -Encoding UTF8
    if((Test-QichengLiteInstalledPackage $root).valid){throw 'Version mismatch accepted'}
    $manifest.files[0].path='../outside'
    $manifest|ConvertTo-Json -Depth 4|Set-Content (Join-Path $root 'package-manifest.json') -Encoding UTF8
    if((Test-QichengLiteInstalledPackage $root).valid){throw 'Escaping manifest path accepted'}
    'Installed package consistency: passed (clean, overlay, version mismatch, invalid path)'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^agent-channel-consistency-[a-f0-9]{32}$'){throw 'Unsafe cleanup path'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
