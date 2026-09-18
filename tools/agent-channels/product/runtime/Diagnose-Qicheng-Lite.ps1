[CmdletBinding()]
param([string]$InstallRoot,[string]$DockerPath='docker',[string]$StartupRoot,[string]$LegacyStartupRoot,[int]$Port1=18761,[int]$Port2=18762)
$ErrorActionPreference='Continue'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
if($Port1 -ne 18761 -or $Port2 -ne 18762){throw '端口契约固定为 18761/18762；请移除自定义端口参数。'}
if([string]::IsNullOrWhiteSpace($InstallRoot)){$InstallRoot=$PSScriptRoot}
$installRoot=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
$checks=New-Object 'System.Collections.Generic.List[object]'
function Add-Check([string]$Name,[bool]$Passed,[string]$Detail){$checks.Add([pscustomobject][ordered]@{name=$Name;passed=$Passed;detail=$Detail})}
$record=Read-QichengLiteInstallRecord -InstallRoot $installRoot
Add-Check 'install-record' ($null -ne $record) $(if($record){"版本 $($record.version)"}else{'安装记录缺失'})
foreach($item in @(
    @{Name='viewer';Path='dist\AgentChannels.exe'},
    @{Name='compose';Path='compose.yaml'},
    @{Name='dockerfile';Path='Dockerfile'},
    @{Name='license';Path='LICENSE'},
    @{Name='third-party-notices';Path='THIRD-PARTY-NOTICES.md'}
)){$path=Join-Path $installRoot $item.Path;Add-Check $item.Name (Test-Path -LiteralPath $path -PathType Leaf) $path}
$tokenPath=Join-Path $installRoot '.local\channel.token'
$tokenValid=$false
if(Test-Path -LiteralPath $tokenPath -PathType Leaf){try{$tokenValid=Test-QichengLiteTokenValue -Value ((Get-Content -LiteralPath $tokenPath -Raw).Trim())}catch{}}
Add-Check 'private-token' $tokenValid $(if($tokenValid){'存在且格式有效；值未显示'}else{'缺失或格式无效'})
$dockerAvailable=$false
try{& $DockerPath version --format '{{.Server.Version}}' 2>$null|Out-Null;$dockerAvailable=($LASTEXITCODE -eq 0)}catch{}
Add-Check 'docker-linux-engine' $dockerAvailable $(if($dockerAvailable){'可用'}else{'不可用；本产品不捆绑 Docker Desktop'})
if($dockerAvailable){
    $composeOutput=''
    try{$composeOutput=(& $DockerPath compose --project-name qicheng-agent-channels --project-directory $installRoot -f (Join-Path $installRoot 'compose.yaml') --profile second ps --format json 2>&1|Out-String);$composeOk=($LASTEXITCODE -eq 0)}catch{$composeOk=$false;$composeOutput=$_.Exception.Message}
    Add-Check 'compose-project' $composeOk $(if($composeOk){'qicheng-agent-channels 可读取'}else{'无法读取项目状态'})
}
$port1=18761
$port2=18762
foreach($port in @($port1,$port2)){
    $ready=$false
    if($tokenValid){
        try{
            $state=Invoke-RestMethod -Uri ("http://127.0.0.1:$port/api/state") -Headers @{Authorization=('Bearer '+((Get-Content -LiteralPath $tokenPath -Raw).Trim()))} -TimeoutSec 2
            $ready=($state.input_target -eq 'private-linux-display' -and [int]$state.width -gt 0 -and [int]$state.height -gt 0)
        }catch{}
    }
    Add-Check ("channel-$port-authenticated-state") $ready $(if($ready){"私有 Linux 显示已认证并报告有效尺寸"}else{"127.0.0.1:$port 未通过认证状态检查"})
}
if([string]::IsNullOrWhiteSpace($StartupRoot)){$StartupRoot=[Environment]::GetFolderPath('Startup')}
if([string]::IsNullOrWhiteSpace($LegacyStartupRoot)){$LegacyStartupRoot=[Environment]::GetFolderPath('Startup')}
$startup=Join-Path (Resolve-QichengLitePath -Path $StartupRoot -Label 'StartupRoot') '启程轻量工作台.lnk'
$legacy=Join-Path (Resolve-QichengLitePath -Path $LegacyStartupRoot -Label 'LegacyStartupRoot') '启程 Windows 频道.lnk'
Add-Check 'lite-autostart' (Test-Path -LiteralPath $startup -PathType Leaf) $startup
Add-Check 'legacy-alt-conflict' (-not(Test-Path -LiteralPath $legacy -PathType Leaf)) $(if(Test-Path -LiteralPath $legacy -PathType Leaf){'旧 Windows 频道仍会登录启动，可能争用 Alt 快捷键'}else{'未发现旧启动项'})
$failed=@($checks.ToArray()|Where-Object{-not $_.passed}).Count
[ordered]@{schemaVersion=1;status=if($failed){'attention-required'}else{'healthy'};installRoot=$installRoot;composeProject='qicheng-agent-channels';ports=@($port1,$port2);checks=$checks.ToArray();failedChecks=$failed;mutationsMade=$false;tokenDisplayed=$false}|ConvertTo-Json -Depth 6
