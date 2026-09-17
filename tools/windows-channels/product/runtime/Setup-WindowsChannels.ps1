[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Interactive','Inspect','Import','Create')][string]$Action = 'Interactive',
    [string]$DataRoot,
    [string]$ImportConfigPath,
    [ValidateRange(1,8)][int]$Count = 2,
    [string]$IsoPath,
    [string]$ExpectedSha256,
    [string]$VMRootPath,
    [string]$SwitchName,
    [string]$NewChannelVMsPath,
    [switch]$Notify,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Product.Common.ps1')
$installRoot = Resolve-QichengLocalPath -Path $PSScriptRoot -Label 'InstallRoot'
$record = Get-QichengInstallRecord -InstallRoot $installRoot
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = if ($record -and $record.dataRoot) { [string]$record.dataRoot } else { Get-QichengDefaultDataRoot } }
$dataRoot = Resolve-QichengLocalPath -Path $DataRoot -Label 'DataRoot'
$configPath = Join-Path $dataRoot 'channels.json'
$setupStatePath = Join-Path $dataRoot 'setup-status.json'
if ([string]::IsNullOrWhiteSpace($NewChannelVMsPath)) { $NewChannelVMsPath = Join-Path $installRoot 'source\New-ChannelVMs.ps1' }
$newChannelVMsPath = Resolve-QichengLocalPath -Path $NewChannelVMsPath -Label 'NewChannelVMsPath'

function Get-WorkspaceSnapshot {
    $configuredProjects = @()
    $configValid = $false
    $configError = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $configuredProjects = @((Read-QichengConfig -ConfigPath $configPath).ProjectNames)
            $configValid = $true
        } catch { $configError = $_.Exception.Message }
    }
    $existingVMs = @()
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        try {
            $existingVMs = @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -match '^qicheng-win-[1-8]$' } | Sort-Object Name | ForEach-Object {
                [pscustomobject][ordered]@{ name=[string]$_.Name; state=[string]$_.State; id=[string]$_.Id }
            })
        } catch { $existingVMs = @() }
    }
    $physicalGiB = $null
    try { $physicalGiB = [math]::Round(([double](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB),1) } catch {}
    [pscustomobject][ordered]@{
        configExists = (Test-Path -LiteralPath $configPath -PathType Leaf)
        configValid = $configValid
        configError = $configError
        configPath = $configPath
        configuredProjects = $configuredProjects
        existingVMs = $existingVMs
        physicalMemoryGiB = $physicalGiB
        pendingSetupExists = (Test-Path -LiteralPath $setupStatePath -PathType Leaf)
        pendingSetupPath = $setupStatePath
    }
}

function Get-ResourceEstimate([int]$WorkspaceCount) {
    [pscustomobject][ordered]@{
        workspaceCount = $WorkspaceCount
        memoryPerWorkspaceGiB = 8
        totalVMMemoryGiB = 8 * $WorkspaceCount
        recommendedHostMemoryGiB = 8 + (8 * $WorkspaceCount)
        dynamicDiskMaximumPerWorkspaceGiB = 80
        totalDynamicDiskMaximumGiB = 80 * $WorkspaceCount
        note = '每台 VM 使用 8 GiB 静态内存；建议另为 Windows 主机保留至少 8 GiB。VHDX 动态增长，不会立即占满上限。'
    }
}

function Write-SetupResult([System.Collections.IDictionary]$Result) { $Result | ConvertTo-Json -Depth 9 }

function Import-ExistingConfiguration([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '请选择已有的 channels.json。' }
    $snapshot = Get-WorkspaceSnapshot
    if ($snapshot.configExists -and $snapshot.configValid) {
        return [ordered]@{ schemaVersion=1; status='configured-reused'; configPath=$configPath; projects=$snapshot.configuredProjects; vmCreationRequested=$false; hostChangesMade=$false }
    }
    $material = Get-QichengConfigImportMaterial -ConfigPath $Path
    $repairing = ($snapshot.configExists -and -not $snapshot.configValid)
    $backupPath = $null
    if ($repairing) {
        $backupPath = Join-Path $dataRoot ('channels.invalid.' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffffffZ') + '.json')
        Copy-Item -LiteralPath $configPath -Destination $backupPath
    }
    $result = Import-QichengConfig -Material $material -DataRoot $dataRoot -Replace:$repairing
    return [ordered]@{ schemaVersion=1; status=if($repairing){'configuration-repaired'}else{'configuration-imported'}; configPath=$result.ConfigPath; invalidConfigBackup=$backupPath; projects=$result.Projects; vmCreationRequested=$false; tokensCopiedPrivately=$true; hostChangesMade=$true }
}

function Invoke-NewWorkspaceProvisioning {
    $snapshot = Get-WorkspaceSnapshot
    if ($snapshot.configExists -and $snapshot.configValid) {
        return [ordered]@{ schemaVersion=1; status='configured-reused'; message='已存在可用频道配置，将直接复用，不会重建 VM。'; configPath=$configPath; projects=$snapshot.configuredProjects; vmCreationRequested=$false; hostChangesMade=$false }
    }
    if ($snapshot.configExists -and -not $snapshot.configValid) { throw "现有频道配置无效：$($snapshot.configError) 请先使用导入已有频道配置修复；不会重建 VM。" }
    foreach ($required in @(@{Value=$IsoPath;Name='ISO'},@{Value=$VMRootPath;Name='VM 目标目录'},@{Value=$SwitchName;Name='Hyper-V 虚拟交换机'})) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) { throw "请选择$($required.Name)。" }
    }
    $resolvedIso = Resolve-QichengLocalPath -Path $IsoPath -Label 'IsoPath'
    $resolvedVMRoot = Resolve-QichengLocalPath -Path $VMRootPath -Label 'VMRootPath'
    if (-not (Test-Path -LiteralPath $resolvedIso -PathType Leaf) -or [IO.Path]::GetExtension($resolvedIso) -ine '.iso') { throw '请选择存在的 Windows ISO 文件。' }
    if (-not (Test-Path -LiteralPath $resolvedVMRoot -PathType Container)) { throw 'VM 目标目录必须已经存在。' }
    if (-not (Test-Path -LiteralPath $newChannelVMsPath -PathType Leaf)) { throw "VM 创建脚本缺失：$newChannelVMsPath。请重新安装完整发布包。" }
    $command = Get-Command -Name $newChannelVMsPath -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('Count')) { throw '当前发布包的 VM 创建脚本不支持 1..8 台工作区，请更新发布包后重试。' }
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { $ExpectedSha256 = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash }
    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'ISO SHA-256 必须是 64 位十六进制。' }
    $estimate = Get-ResourceEstimate -WorkspaceCount $Count
    if ($Apply -and -not $PSCmdlet.ShouldProcess("$Count 台工作区；目标 $resolvedVMRoot", '创建关闭状态的 Hyper-V VM')) {
        return [ordered]@{ schemaVersion=1; status='vm-create-declined'; workspaceCount=$Count; resourceEstimate=$estimate; channelsAvailable=$false; hostChangesMade=$false }
    }
    $arguments = @{ IsoPath=$resolvedIso; ExpectedSha256=$ExpectedSha256; RootPath=$resolvedVMRoot; SwitchName=$SwitchName; Count=$Count; Compact=$true }
    if ($Apply) { $arguments.Apply = $true; $arguments.Confirm = $false }
    $output = @(& $newChannelVMsPath @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    try { $provisioning = $text | ConvertFrom-Json -ErrorAction Stop } catch { throw "VM 创建脚本未返回有效结果：$text" }
    if ($exitCode -ne 0) { throw "VM 创建未完成：$($provisioning.error)" }
    $created = ($Apply -and $provisioning.status -eq 'created-off')
    $result = [ordered]@{
        schemaVersion = 1
        status = if ($created) { 'vm-created-windows-pending' } else { 'vm-plan-ready' }
        workspaceCount = $Count
        resourceEstimate = $estimate
        provisioning = $provisioning
        channelsAvailable = $false
        windowsInstallationRequired = $true
        guestAgentRequired = $true
        configurationImportRequired = $true
        nextStep = '逐台完成 Windows 安装和登录，再安装来宾代理并导入生成的 channels.json。完成前这些工作区不会出现在可用频道中。'
        hostChangesMade = [bool]$created
    }
    if ($created) {
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        Set-QichengPrivateDirectoryAcl -Path $dataRoot
        $state = [ordered]@{ schemaVersion=1; status=$result.status; updatedAt=(Get-Date).ToUniversalTime().ToString('o'); workspaceCount=$Count; resourceEstimate=$estimate; provisioned=$provisioning.provisioned; windowsInstallationRequired=$true; guestAgentRequired=$true; configurationImportRequired=$true; channelsAvailable=$false }
        $temporaryState = $setupStatePath + '.tmp'
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryState -Encoding UTF8
        Move-Item -LiteralPath $temporaryState -Destination $setupStatePath -Force
    }
    return $result
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Request-ElevatedWorkspaceCreation {
    foreach ($required in @(@{Value=$IsoPath;Name='ISO'},@{Value=$VMRootPath;Name='VM 目标目录'},@{Value=$SwitchName;Name='Hyper-V 虚拟交换机'})) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) { throw "请选择$($required.Name)。" }
    }
    $resolvedIso = Resolve-QichengLocalPath -Path $IsoPath -Label 'IsoPath'
    $resolvedVMRoot = Resolve-QichengLocalPath -Path $VMRootPath -Label 'VMRootPath'
    if (-not (Test-Path -LiteralPath $resolvedIso -PathType Leaf) -or [IO.Path]::GetExtension($resolvedIso) -ine '.iso') { throw '请选择存在的 Windows ISO 文件。' }
    if (-not (Test-Path -LiteralPath $resolvedVMRoot -PathType Container)) { throw 'VM 目标目录必须已经存在。' }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    if ($SwitchName.Contains('"')) { throw '虚拟交换机名称不能包含双引号。' }
    $setupScript = Join-Path $installRoot 'Setup-WindowsChannels.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Create -DataRoot "{1}" -Count {2} -IsoPath "{3}" -VMRootPath "{4}" -SwitchName "{5}" -Apply -Notify' -f $setupScript,$dataRoot,$Count,$resolvedIso,$resolvedVMRoot,$SwitchName
    Start-Process -FilePath $powershell -ArgumentList $arguments -WorkingDirectory $installRoot -Verb RunAs -WindowStyle Hidden | Out-Null
    return [ordered]@{ schemaVersion=1; status='elevation-requested'; message='已请求管理员权限。请在 Windows 用户账户控制窗口确认；提升后的向导会报告实际创建结果。'; workspaceCount=$Count; channelsAvailable=$false; hostChangesMade=$false }
}

function Show-SetupWizard {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $snapshot = Get-WorkspaceSnapshot
    if ($snapshot.configExists -and $snapshot.configValid) {
        [void][System.Windows.Forms.MessageBox]::Show("已配置 $($snapshot.configuredProjects.Count) 个频道，将直接复用并打开工作台，不会重建 VM。",'启程 Windows 频道','OK','Information')
        $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
        Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Start-WindowsChannels.ps1') + '" -Show') -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
        return [ordered]@{ schemaVersion=1; status='configured-reused'; configPath=$configPath; projects=$snapshot.configuredProjects; vmCreationRequested=$false; hostChangesMade=$false }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '启程 Windows 频道 · 首次设置'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object Drawing.Size(700,590)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $title = New-Object Windows.Forms.Label
    $title.Text = '先选择如何准备工作区'
    $title.Font = New-Object Drawing.Font('Microsoft YaHei UI',16,[Drawing.FontStyle]::Bold)
    $title.SetBounds(28,22,620,38); $form.Controls.Add($title)
    $summary = New-Object Windows.Forms.Label
    $vmNames = @($snapshot.existingVMs | ForEach-Object { $_.name })
    $summary.Text = if ($snapshot.configExists -and -not $snapshot.configValid) { '现有 channels.json 无效。请选择导入有效配置进行修复；向导不会据此重建 VM。' } elseif ($vmNames.Count) { "发现现有频道 VM：$($vmNames -join '、')。导入对应配置即可复用，不会重建。" } else { '未发现 qicheng-win-1..8。若已有其他安装，请优先导入原 channels.json。' }
    $summary.SetBounds(30,66,630,44); $form.Controls.Add($summary)
    $importRadio = New-Object Windows.Forms.RadioButton
    $importRadio.Text = '导入已有频道配置（推荐用于已有 VM）'; $importRadio.Checked = ($snapshot.configExists -or $vmNames.Count -gt 0); $importRadio.SetBounds(30,116,500,28); $form.Controls.Add($importRadio)
    $importBox = New-Object Windows.Forms.TextBox; $importBox.SetBounds(52,150,510,28); $form.Controls.Add($importBox)
    $importBrowse = New-Object Windows.Forms.Button; $importBrowse.Text='浏览…'; $importBrowse.SetBounds(570,148,80,30); $form.Controls.Add($importBrowse)
    $createRadio = New-Object Windows.Forms.RadioButton
    $createRadio.Text = '创建新的 Hyper-V 工作区'; $createRadio.Checked = -not $importRadio.Checked; $createRadio.SetBounds(30,196,420,28); $form.Controls.Add($createRadio)
    $countLabel = New-Object Windows.Forms.Label; $countLabel.Text='工作区数量（1–8）'; $countLabel.SetBounds(52,234,150,24); $form.Controls.Add($countLabel)
    $countBox = New-Object Windows.Forms.NumericUpDown; $countBox.Minimum=1; $countBox.Maximum=8; $countBox.Value=2; $countBox.SetBounds(210,230,70,28); $form.Controls.Add($countBox)
    $estimateLabel = New-Object Windows.Forms.Label; $estimateLabel.SetBounds(300,230,350,48); $form.Controls.Add($estimateLabel)
    $isoLabel = New-Object Windows.Forms.Label; $isoLabel.Text='Windows ISO'; $isoLabel.SetBounds(52,290,120,24); $form.Controls.Add($isoLabel)
    $isoBox = New-Object Windows.Forms.TextBox; $isoBox.SetBounds(170,286,392,28); $form.Controls.Add($isoBox)
    $isoBrowse = New-Object Windows.Forms.Button; $isoBrowse.Text='浏览…'; $isoBrowse.SetBounds(570,284,80,30); $form.Controls.Add($isoBrowse)
    $rootLabel = New-Object Windows.Forms.Label; $rootLabel.Text='VM 目标目录'; $rootLabel.SetBounds(52,330,120,24); $form.Controls.Add($rootLabel)
    $rootBox = New-Object Windows.Forms.TextBox; $rootBox.SetBounds(170,326,392,28); $form.Controls.Add($rootBox)
    $rootBrowse = New-Object Windows.Forms.Button; $rootBrowse.Text='浏览…'; $rootBrowse.SetBounds(570,324,80,30); $form.Controls.Add($rootBrowse)
    $switchLabel = New-Object Windows.Forms.Label; $switchLabel.Text='虚拟交换机'; $switchLabel.SetBounds(52,370,120,24); $form.Controls.Add($switchLabel)
    $switchBox = New-Object Windows.Forms.ComboBox; $switchBox.DropDownStyle='DropDownList'; $switchBox.SetBounds(170,366,392,28); $form.Controls.Add($switchBox)
    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) { try { @(Get-VMSwitch -ErrorAction Stop | Sort-Object Name) | ForEach-Object { [void]$switchBox.Items.Add([string]$_.Name) } } catch {} }
    if ($switchBox.Items.Count -gt 0) { $switchBox.SelectedIndex=0 }
    $pending = New-Object Windows.Forms.Label
    $pending.Text = '创建只会生成关闭状态的 VM。随后仍须逐台安装 Windows、登录、安装来宾代理并导入配置，完成前不会显示为可用频道。'
    $pending.ForeColor = [Drawing.Color]::FromArgb(145,75,0); $pending.SetBounds(52,410,590,54); $form.Controls.Add($pending)
    $continue = New-Object Windows.Forms.Button; $continue.Text='继续'; $continue.SetBounds(470,490,86,34); $form.Controls.Add($continue)
    $cancel = New-Object Windows.Forms.Button; $cancel.Text='稍后设置'; $cancel.SetBounds(565,490,86,34); $form.Controls.Add($cancel)
    $form.CancelButton=$cancel
    $updateEstimate = {
        $e=Get-ResourceEstimate -WorkspaceCount ([int]$countBox.Value)
        $actual = if ($null -ne $snapshot.physicalMemoryGiB) { "；本机 $($snapshot.physicalMemoryGiB) GiB" } else { '' }
        $estimateLabel.Text="VM 内存 $($e.totalVMMemoryGiB) GiB；建议主机至少 $($e.recommendedHostMemoryGiB) GiB$actual"
        $estimateLabel.ForeColor = if ($null -ne $snapshot.physicalMemoryGiB -and $snapshot.physicalMemoryGiB -lt $e.recommendedHostMemoryGiB) { [Drawing.Color]::Firebrick } else { [Drawing.Color]::FromArgb(35,35,35) }
    }
    $countBox.add_ValueChanged($updateEstimate); & $updateEstimate
    $importBrowse.add_Click({ $d=New-Object Windows.Forms.OpenFileDialog; $d.Title='选择 channels.json'; $d.Filter='频道配置 (channels.json)|channels.json|JSON 文件 (*.json)|*.json'; if($d.ShowDialog() -eq 'OK'){$importBox.Text=$d.FileName;$importRadio.Checked=$true} })
    $isoBrowse.add_Click({ $d=New-Object Windows.Forms.OpenFileDialog; $d.Title='选择 Windows ISO'; $d.Filter='Windows ISO (*.iso)|*.iso'; if($d.ShowDialog() -eq 'OK'){$isoBox.Text=$d.FileName;$createRadio.Checked=$true} })
    $rootBrowse.add_Click({ $d=New-Object Windows.Forms.FolderBrowserDialog; $d.Description='选择已存在的 VM 目标目录'; if($d.ShowDialog() -eq 'OK'){$rootBox.Text=$d.SelectedPath;$createRadio.Checked=$true} })
    $script:wizardResult = $null
    $cancel.add_Click({ $form.DialogResult='Cancel'; $form.Close() })
    $continue.add_Click({
        try {
            if ($importRadio.Checked) {
                $script:wizardResult = Import-ExistingConfiguration -Path $importBox.Text
                [void][Windows.Forms.MessageBox]::Show('配置已安全导入。工作台将显示可用频道。','设置完成','OK','Information')
                $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
                Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Start-WindowsChannels.ps1') + '" -Show') -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
            } else {
                $script:Count=[int]$countBox.Value; $script:IsoPath=$isoBox.Text; $script:VMRootPath=$rootBox.Text; $script:SwitchName=[string]$switchBox.SelectedItem; $script:Apply=$true
                $confirm = [Windows.Forms.MessageBox]::Show("将创建 $script:Count 台关闭状态的 Hyper-V VM。Windows 与来宾代理仍需随后完成。继续吗？",'确认创建','YesNo','Warning')
                if ($confirm -ne 'Yes') { return }
                if (Test-IsAdministrator) {
                    $script:wizardResult = Invoke-NewWorkspaceProvisioning
                    [void][Windows.Forms.MessageBox]::Show("VM 已创建并保持关闭。`r`n`r`n下一步：逐台安装 Windows、登录并安装来宾代理，然后导入 channels.json。完成前频道尚不可用。",'工作区等待后续设置','OK','Information')
                } else {
                    $script:wizardResult = Request-ElevatedWorkspaceCreation
                    [void][Windows.Forms.MessageBox]::Show($script:wizardResult.message,'需要管理员权限','OK','Information')
                }
            }
            $form.DialogResult='OK'; $form.Close()
        } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'无法继续','OK','Error') }
    })
    [void]$form.ShowDialog()
    if ($script:wizardResult) { return $script:wizardResult }
    return [ordered]@{ schemaVersion=1; status='setup-deferred'; configPath=$configPath; hostChangesMade=$false }
}

$snapshot = Get-WorkspaceSnapshot
if ($Action -eq 'Inspect') {
    $inspectStatus = if ($snapshot.configExists -and $snapshot.configValid) { 'configured-reused' } elseif ($snapshot.configExists) { 'invalid-configuration' } else { 'setup-required' }
    Write-SetupResult ([ordered]@{ schemaVersion=1; status=$inspectStatus; snapshot=$snapshot; resourceOptions=@(1..8 | ForEach-Object { Get-ResourceEstimate -WorkspaceCount $_ }); vmCreationRequested=$false; hostChangesMade=$false })
    return
}
if ($Action -eq 'Import') { Write-SetupResult (Import-ExistingConfiguration -Path $ImportConfigPath); return }
if ($Action -eq 'Create') {
    try {
        $createResult = Invoke-NewWorkspaceProvisioning
        if ($Notify) {
            Add-Type -AssemblyName System.Windows.Forms
            $notifyText = if ($createResult.status -eq 'vm-created-windows-pending') { "VM 已创建并保持关闭。`r`n仍需逐台安装 Windows、登录、安装来宾代理并导入 channels.json；完成前频道不可用。" } else { "操作结果：$($createResult.status)" }
            [void][System.Windows.Forms.MessageBox]::Show($notifyText,'启程 Windows 频道设置','OK','Information')
        }
        Write-SetupResult $createResult
    } catch {
        if (-not $Notify) { throw }
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'工作区创建未完成','OK','Error')
        Write-SetupResult ([ordered]@{ schemaVersion=1; status='vm-create-failed'; error=$_.Exception.Message; channelsAvailable=$false; hostChangesMade=$false })
    }
    return
}
Write-SetupResult (Show-SetupWizard)
