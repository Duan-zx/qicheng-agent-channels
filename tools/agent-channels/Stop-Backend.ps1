[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
& docker compose --project-directory $PSScriptRoot -f (Join-Path $PSScriptRoot 'compose.yaml') --profile second stop
if($LASTEXITCODE -ne 0){throw 'Unable to stop this project; check Docker state.'}
