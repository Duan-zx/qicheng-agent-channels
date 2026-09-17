[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw '.NET Framework C# compiler missing.'}
$dest=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'dist'}
New-Item -ItemType Directory -Path $dest -Force | Out-Null
& $compiler /nologo /target:winexe /optimize+ /platform:x64 /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Net.Http.dll /r:System.Web.Extensions.dll "/out:$dest\AgentChannels.exe" "$root\windows\Channels.cs" "$root\windows\Skin.cs"
if($LASTEXITCODE -ne 0){throw 'Compilation failed'}
Get-FileHash -LiteralPath (Join-Path $dest 'AgentChannels.exe') -Algorithm SHA256
