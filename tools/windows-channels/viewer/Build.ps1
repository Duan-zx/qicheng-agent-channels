[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw '.NET Framework C# compiler missing.'
}
$destination = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$output = Join-Path $destination 'WindowsChannelsViewer.exe'

& $compiler /nologo /target:winexe /optimize+ /platform:x64 `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    "/win32manifest:$(Join-Path $root 'app.manifest')" `
    "/out:$output" (Join-Path $root 'Viewer.cs')
if ($LASTEXITCODE -ne 0) {
    throw 'Compilation failed.'
}
Get-FileHash -LiteralPath $output -Algorithm SHA256
