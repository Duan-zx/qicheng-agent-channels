[CmdletBinding()]
param([string]$ConfigPath, [string]$PythonPath, [switch]$Show, [string]$ChannelHotkeys, [switch]$NoHostHotkey, [switch]$WaitForHotkeys)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')

$installRoot = Resolve-QichengLocalPath -Path $PSScriptRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
$dataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $dataRoot 'channels.json' }
function Start-SetupWizard([string]$Reason) {
    $setup = Join-Path $installRoot 'Setup-WindowsChannels.ps1'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "首次设置向导缺失：$setup。请重新安装完整发布包。" }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $setup + '"') -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
    [pscustomobject]@{ status='setup-start-requested'; reason=$Reason; config=$ConfigPath; setup=$setup; channelsAvailable=$false }
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Start-SetupWizard -Reason 'configuration-missing'
    return
}
try { $config = Read-QichengConfig -ConfigPath $ConfigPath }
catch {
    Start-SetupWizard -Reason 'configuration-invalid'
    return
}
$python = Resolve-QichengPython -PythonPath $(if(-not [string]::IsNullOrWhiteSpace($PythonPath)){$PythonPath}elseif($record -and $record.pythonPath){[string]$record.pythonPath}else{$null})
$viewer = Join-Path $installRoot 'viewer\dist\WindowsChannelsViewer.exe'
if (-not (Test-Path -LiteralPath $viewer -PathType Leaf)) { throw "查看器缺失：$viewer。请重新安装发布包。" }
$disableHostHotkey = [bool]$NoHostHotkey
if ([string]::IsNullOrWhiteSpace($ChannelHotkeys) -and -not $disableHostHotkey -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $liteRecord = Join-Path $env:LOCALAPPDATA 'Programs\QichengLite\.qicheng-lite-install.json'
    if (Test-Path -LiteralPath $liteRecord -PathType Leaf) {
        if ($config.ProjectNames.Count -gt 6) { throw 'Lite 已占用 Alt+1/2/3；Windows 频道数量超过剩余 Alt+4..9 快捷键。请在设置中减少频道数量或指定快捷键。' }
        $ChannelHotkeys = ((4..(3 + $config.ProjectNames.Count)) -join ',')
        $disableHostHotkey = $true
    }
}
$guestStarts = @()
$getVm = Get-Command Get-VM -ErrorAction SilentlyContinue
$startVm = Get-Command Start-VM -ErrorAction SilentlyContinue
foreach ($name in $config.ProjectNames) {
    $binding = $config.Value.projects.$name
    if (-not $getVm -or -not $startVm) {
        $guestStarts += [pscustomobject]@{ project=$name; status='hyperv-unavailable' }
        continue
    }
    try {
        $vm = Get-VM -Id ([guid]([string]$binding.vm_id)) -ErrorAction Stop
        if ([string]$vm.State -eq 'Running') { $status='already-running' }
        elseif ([string]$vm.State -in @('Off','Saved')) {
            Start-VM -VM $vm -ErrorAction Stop | Out-Null
            $status='started'
        } else { $status='not-started:' + [string]$vm.State }
        $guestStarts += [pscustomobject]@{ project=$name; status=$status }
    } catch {
        $guestStarts += [pscustomobject]@{ project=$name; status='start-failed'; reason=$_.Exception.GetType().Name }
    }
}
$workingDirectory = $installRoot
$arguments = '--config "{0}" --python "{1}"' -f $config.Path.Replace('"','\"'), $python.Replace('"','\"')
if ($Show) { $arguments += ' --show' }
if (-not [string]::IsNullOrWhiteSpace($ChannelHotkeys)) { $arguments += ' --channel-hotkeys "' + $ChannelHotkeys.Replace('"','') + '"' }
if ($disableHostHotkey) { $arguments += ' --no-host-hotkey' }
$hotkeyStatusPath=$null
if($WaitForHotkeys){
    $hotkeyStatusPath=Join-Path ([IO.Path]::GetTempPath()) ('qicheng-windows-hotkeys-'+[guid]::NewGuid().ToString('N')+'.json')
    $arguments+=' --hotkey-status "'+$hotkeyStatusPath+'" --quiet-control-error'
}
$viewerProcess=Start-Process -FilePath $viewer -ArgumentList $arguments -WorkingDirectory $workingDirectory -PassThru
if($WaitForHotkeys){
    try{
        foreach($attempt in 1..120){
            if(Test-Path -LiteralPath $hotkeyStatusPath -PathType Leaf){break}
            if($viewerProcess.HasExited){throw 'Windows 查看器未确认快捷键重映射；已有查看器可能是旧版本，需先从托盘正常退出并升级。'}
            Start-Sleep -Milliseconds 100
        }
        if(-not(Test-Path -LiteralPath $hotkeyStatusPath -PathType Leaf)){throw 'Windows 查看器未在 12 秒内确认快捷键重映射。'}
        $hotkeyStatus=Get-Content -LiteralPath $hotkeyStatusPath -Raw|ConvertFrom-Json
        if($hotkeyStatus.PSObject.Properties.Name -contains 'status' -and $hotkeyStatus.status -eq 'control-failed'){throw ('Windows 查看器控制请求失败：'+[string]$hotkeyStatus.error_type+' / '+[string]$hotkeyStatus.error_message)}
        $expectedHotkeys=if([string]::IsNullOrWhiteSpace($ChannelHotkeys)){@(2..(1+$config.ProjectNames.Count))}else{@($ChannelHotkeys.Split(',')|ForEach-Object{[int]$_})}
        if($hotkeyStatus.host_enabled -ne (-not $disableHostHotkey) -or
            (@($hotkeyStatus.channels) -join ',') -ne ($expectedHotkeys -join ',') -or
            @($hotkeyStatus.failed).Count -gt 0 -or
            [int]$hotkeyStatus.registered -ne ($expectedHotkeys.Count + [int](-not $disableHostHotkey))){
            throw 'Windows 查看器快捷键注册结果与请求不一致；Lite 快捷键尚未安全让出。'
        }
    }finally{Remove-Item -LiteralPath $hotkeyStatusPath -Force -ErrorAction SilentlyContinue}
}
[pscustomobject]@{ status = if($WaitForHotkeys){'hotkeys-confirmed'}else{'viewer-start-requested'}; config = $config.Path; python = $python; projects = $config.ProjectNames; guestStarts=$guestStarts; channelHotkeys=$ChannelHotkeys; hostHotkeyEnabled=(-not $disableHostHotkey); showRequested = [bool]$Show }
