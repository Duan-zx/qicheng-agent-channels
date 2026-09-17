[CmdletBinding()]
param([switch]$Show,[switch]$Background)
$ErrorActionPreference='Stop'
$exe=Join-Path $PSScriptRoot 'dist\AgentChannels.exe'
if(-not(Test-Path -LiteralPath $exe)){ & (Join-Path $PSScriptRoot 'Build.ps1') }
if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot '.local\channel.token'))){throw 'Run Start-Backend.ps1 first.'}
# The product default is a real tray-only process. The Form is never shown
# until Alt+2/Alt+3, a tray action, or an explicit -Show request.
if($Show){Start-Process -FilePath $exe -ArgumentList '--show' -WorkingDirectory $PSScriptRoot -WindowStyle Hidden}
else{Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot -WindowStyle Hidden}
