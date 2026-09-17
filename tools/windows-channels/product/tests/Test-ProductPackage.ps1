[CmdletBinding()]
param([switch]$SkipPublicExportRoundTrip)

$ErrorActionPreference = 'Stop'
$productRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qicheng-product-test-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $temporaryRoot 'package'
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $buildJson = & (Join-Path $productRoot 'Build-Package.ps1') -OutputDirectory $packageRoot -Version '0.1.0-test' | Out-String
    $build = $buildJson | ConvertFrom-Json
    Assert-True ($build.status -eq 'built') 'Build did not report success.'
    Assert-True (Test-Path -LiteralPath $build.archive -PathType Leaf) 'Zip archive is missing.'
    $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Raw | ConvertFrom-Json
    $themeSourceRoot = Join-Path (Split-Path -Parent $productRoot) 'theme'
    $themeSourceCount = @(@('ai-space.png','Set-WorkspaceTheme.ps1','README.md') | Where-Object { Test-Path -LiteralPath (Join-Path $themeSourceRoot $_) -PathType Leaf }).Count
    $expectedPackageFiles = 67 + (2 * $themeSourceCount)
    Assert-True ($manifest.files.Count -eq $expectedPackageFiles) 'Unexpected package allowlist count.'
    $paths = @($manifest.files.path)
    Assert-True ($paths -contains 'LICENSE' -and $paths -contains 'source/LICENSE') 'Apache LICENSE is missing from the install or source package.'
    $moduleLicense = Join-Path (Split-Path -Parent $productRoot) 'LICENSE'
    $licenseHash = (Get-FileHash -LiteralPath $moduleLicense -Algorithm SHA256).Hash
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Install package LICENSE differs from the module Apache LICENSE.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'source\LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Source package LICENSE differs from the module Apache LICENSE.'
    Assert-True ($paths -contains 'viewer/dist/WindowsChannelsViewer.exe') 'Built viewer is not packaged in its required relative layout.'
    Assert-True ($paths -contains 'host/mcp.py') 'Runtime MCP source is not packaged.'
    Assert-True ($paths -contains 'source/guest/agent.py') 'Guest source is not packaged for public reproduction.'
    Assert-True ($paths -contains 'source/New-ChannelVMs.ps1') 'VM preparation source is not packaged.'
    Assert-True ($paths -contains 'source/tests/test_host_mcp.py') 'Source tests are not packaged.'
    Assert-True ($paths -contains 'source/tests/HostServiceSafety.Tests.ps1') 'Host service safety tests are not packaged.'
    Assert-True ($paths -contains 'source/product/Build-Package.ps1') 'Product package builder is not included in source distribution.'
    Assert-True ($paths -contains 'source/product/tests/Test-ProductPackage.ps1') 'Product package tests are not included in source distribution.'
    Assert-True ($paths -contains 'Setup-WindowsChannels.ps1' -and $paths -contains 'source/product/runtime/Setup-WindowsChannels.ps1') 'First-run setup wizard is missing from runtime or source distribution.'
    foreach ($themeName in @('ai-space.png','Set-WorkspaceTheme.ps1','README.md')) {
        if (Test-Path -LiteralPath (Join-Path $themeSourceRoot $themeName) -PathType Leaf) {
            Assert-True ($paths -contains ('theme/' + $themeName) -and $paths -contains ('source/theme/' + $themeName)) "Allowlisted theme asset was not packaged twice: $themeName"
        }
    }
    Assert-True (-not ($paths -match '(?i)token|\.local|\.vhdx|\.iso|project-memory|\.git')) 'Sensitive or machine-local path entered the package.'
    foreach ($entry in $manifest.files) {
        $file = Join-Path $packageRoot ([string]$entry.path)
        Assert-True (Test-Path -LiteralPath $file -PathType Leaf) "Manifest file missing: $($entry.path)"
        Assert-True ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ieq [string]$entry.sha256) "Hash mismatch: $($entry.path)"
    }
    $installRoot = Join-Path $temporaryRoot 'install'
    $dataRoot = Join-Path $temporaryRoot 'data'
    $startMenu = Join-Path $temporaryRoot 'start-menu'
    $desktop = Join-Path $temporaryRoot 'desktop'
    $startup = Join-Path $temporaryRoot 'startup'
    $importRoot = Join-Path $temporaryRoot 'private-import'
    New-Item -ItemType Directory -Path $importRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $importRoot 'original-1.token') -Value ('a' * 64) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $importRoot 'original-2.token') -Value ('b' * 64) -Encoding ASCII
    $fixtureConfig = [ordered]@{ schema_version=1; projects=[ordered]@{
        'channel-1'=[ordered]@{ vm_id='11111111-2222-4333-8444-555555555555'; bios_uuid='21111111-2222-4333-8444-555555555555'; token_file='original-1.token'; vm_name='qicheng-win-1' }
        'channel-2'=[ordered]@{ vm_id='31111111-2222-4333-8444-555555555555'; bios_uuid='41111111-2222-4333-8444-555555555555'; token_file='original-2.token'; vm_name='qicheng-win-2' }
    } }
    $importConfig = Join-Path $importRoot 'channels.json'
    $fixtureConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $importConfig -Encoding UTF8
    $pythonPath = (& py.exe -3.12 -c 'import sys; print(sys.executable)' | Select-Object -First 1).Trim()
    $planJson = & (Join-Path $packageRoot 'Install-WindowsChannels.ps1') -PackageRoot $packageRoot -InstallRoot $installRoot -DataRoot $dataRoot -StartMenuRoot $startMenu -DesktopRoot $desktop -StartupRoot $startup -PythonPath $pythonPath -ImportConfigPath $importConfig | Out-String
    $plan = $planJson | ConvertFrom-Json
    Assert-True ($plan.status -eq 'not-installed') 'Install plan status is incorrect.'
    Assert-True (-not $plan.hostChangesMade) 'Install plan claimed a mutation.'
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'Install plan created InstallRoot.'
    Assert-True (-not (Test-Path -LiteralPath $dataRoot)) 'Install plan created DataRoot.'
    $winPsOut = Join-Path $temporaryRoot 'winps-install-plan.json'
    $winPsErr = Join-Path $temporaryRoot 'winps-install-plan.err'
    $winPsArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PackageRoot "{1}" -InstallRoot "{2}" -DataRoot "{3}" -StartMenuRoot "{4}" -DesktopRoot "{5}" -StartupRoot "{6}" -PythonPath "{7}" -ImportConfigPath "{8}"' -f (Join-Path $packageRoot 'Install-WindowsChannels.ps1'),$packageRoot,$installRoot,$dataRoot,$startMenu,$desktop,$startup,$pythonPath,$importConfig
    $winPsProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $winPsArgs -RedirectStandardOutput $winPsOut -RedirectStandardError $winPsErr -Wait -PassThru
    $winPsErrorText = if (Test-Path -LiteralPath $winPsErr) { Get-Content -LiteralPath $winPsErr -Raw } else { '' }
    Assert-True ($winPsProcess.ExitCode -eq 0) ("Windows PowerShell double-click installer preflight failed: " + $winPsErrorText)
    $winPsPlan = Get-Content -LiteralPath $winPsOut -Raw | ConvertFrom-Json
    Assert-True ($winPsPlan.status -eq 'not-installed' -and $winPsPlan.python -ieq $pythonPath) 'Windows PowerShell installer preflight output is invalid.'
    $badPathRejected = $false
    try { & (Join-Path $packageRoot 'Install-WindowsChannels.ps1') -PackageRoot $packageRoot -InstallRoot 'relative\install' -DataRoot $dataRoot -StartMenuRoot $startMenu -DesktopRoot $desktop -StartupRoot $startup | Out-Null } catch { $badPathRejected = $true }
    Assert-True $badPathRejected 'Relative installation path was accepted.'
    $winPsApplyOut = Join-Path $temporaryRoot 'winps-install-apply.json'
    $winPsApplyErr = Join-Path $temporaryRoot 'winps-install-apply.err'
    $winPsApplyArgs = $winPsArgs + ' -Apply'
    $winPsApplyProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $winPsApplyArgs -RedirectStandardOutput $winPsApplyOut -RedirectStandardError $winPsApplyErr -Wait -PassThru
    $winPsApplyErrorText = if (Test-Path -LiteralPath $winPsApplyErr) { Get-Content -LiteralPath $winPsApplyErr -Raw } else { '' }
    Assert-True ($winPsApplyProcess.ExitCode -eq 0) ("Windows PowerShell double-click installation failed: " + $winPsApplyErrorText)
    $applyJson = Get-Content -LiteralPath $winPsApplyOut -Raw
    $applied = $applyJson | ConvertFrom-Json
    Assert-True ($applied.status -eq 'installed') 'Temporary installation did not report success.'
    $installedViewer = Join-Path $installRoot 'viewer\dist\WindowsChannelsViewer.exe'
    Assert-True (Test-Path -LiteralPath $installedViewer -PathType Leaf) 'Installed viewer is missing.'
    $derivedRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $installedViewer) '..\..'))
    Assert-True ($derivedRoot -ieq $installRoot) 'Installed viewer does not derive the installation root.'
    Assert-True (Test-Path -LiteralPath (Join-Path $derivedRoot 'host\client.py') -PathType Leaf) 'Viewer-derived root does not contain host.client.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot '.qicheng-product-install.json') -PathType Leaf) 'Install record is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $desktop '启程 Windows 频道.lnk') -PathType Leaf) 'Desktop shortcut is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $startup '启程 Windows 频道.lnk') -PathType Leaf) 'Default current-user startup shortcut is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $startMenu '启程 Windows 频道诊断.lnk') -PathType Leaf) 'Diagnostic shortcut is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $startMenu '导入已有频道配置.lnk') -PathType Leaf) 'Config-import shortcut is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $startMenu '设置 Windows 频道.lnk') -PathType Leaf) 'First-run setup shortcut is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $startMenu '管理 Windows 频道.lnk') -PathType Leaf) 'Explicit visible-management shortcut is missing.'
    Assert-True (-not @(Get-ChildItem -LiteralPath $startMenu,$desktop,$startup -Filter '.qicheng-shortcut-*.lnk' -File -ErrorAction SilentlyContinue).Count) 'ASCII temporary shortcut was not cleaned up.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Install-Qicheng-Windows-Channels.cmd') -PathType Leaf) 'Double-click installer entry is missing.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'Install-Qicheng-Windows-Channels.cmd') -Raw) -match '(?i)-LaunchAfterInstall') 'Double-click installer does not launch first-run setup or the configured viewer.'
    Assert-True (Test-Path -LiteralPath $dataRoot -PathType Container) 'Separated user-data directory is missing.'
    $installedConfigPath = Join-Path $dataRoot 'channels.json'
    $installedConfig = Get-Content -LiteralPath $installedConfigPath -Raw | ConvertFrom-Json
    Assert-True ($installedConfig.projects.'channel-1'.token_file -eq 'tokens/channel-1.token') 'Imported token path was not normalized beneath DataRoot.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $dataRoot 'tokens\channel-1.token') -Raw).Trim() -eq ('a' * 64)) 'Imported token value was not preserved.'
    Assert-True ($applyJson -notmatch ('a' * 64) -and $applyJson -notmatch ('b' * 64)) 'Installer output exposed a token value.'
    $shell = New-Object -ComObject WScript.Shell
    $desktopArguments = $shell.CreateShortcut((Join-Path $desktop '启程 Windows 频道.lnk')).Arguments
    $startupArguments = $shell.CreateShortcut((Join-Path $startup '启程 Windows 频道.lnk')).Arguments
    $managementArguments = $shell.CreateShortcut((Join-Path $startMenu '管理 Windows 频道.lnk')).Arguments
    $setupArguments = $shell.CreateShortcut((Join-Path $startMenu '设置 Windows 频道.lnk')).Arguments
    Assert-True ($desktopArguments -notmatch '(?i)(^|\s)-Show(\s|$)' -and $desktopArguments -match '(?i)-WindowStyle\s+Hidden') 'Default double-click shortcut is visible or can flash a PowerShell window.'
    Assert-True ($startupArguments -notmatch '(?i)(^|\s)-Show(\s|$)' -and $startupArguments -match '(?i)-WindowStyle\s+Hidden') 'Background Startup shortcut is visible or can flash a PowerShell window.'
    Assert-True ($managementArguments -match '(?i)(^|\s)-Show(\s|$)' -and $managementArguments -match '(?i)-WindowStyle\s+Hidden') 'Explicit management shortcut does not show Viewer cleanly without a PowerShell window.'
    Assert-True ($setupArguments -match '(?i)-WindowStyle\s+Hidden') 'Setup shortcut can flash a PowerShell window behind WinForms.'
    $setupInspectJson = & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Inspect -DataRoot $dataRoot | Out-String
    $setupInspect = $setupInspectJson | ConvertFrom-Json
    Assert-True ($setupInspect.status -eq 'configured-reused' -and $setupInspect.resourceOptions.Count -eq 8) 'Setup inspection did not reuse existing configuration or expose 1..8 resource options.'
    $setupWinOut = Join-Path $temporaryRoot 'setup-winps.json'
    $setupWinErr = Join-Path $temporaryRoot 'setup-winps.err'
    $setupWinArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Inspect -DataRoot "{1}"' -f (Join-Path $installRoot 'Setup-WindowsChannels.ps1'),$dataRoot
    $setupWinProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $setupWinArgs -RedirectStandardOutput $setupWinOut -RedirectStandardError $setupWinErr -Wait -PassThru
    Assert-True ($setupWinProcess.ExitCode -eq 0 -and (Get-Content -LiteralPath $setupWinOut -Raw | ConvertFrom-Json).status -eq 'configured-reused') 'Windows PowerShell 5.1 could not inspect first-run setup.'
    $setupReuseJson = & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Create -DataRoot $dataRoot -Count 8 | Out-String
    $setupReuse = $setupReuseJson | ConvertFrom-Json
    Assert-True ($setupReuse.status -eq 'configured-reused' -and -not $setupReuse.vmCreationRequested -and -not $setupReuse.hostChangesMade) 'Setup attempted to rebuild VMs despite an existing configuration.'
    $setupImportData = Join-Path $temporaryRoot 'setup-import-data'
    New-Item -ItemType Directory -Path $setupImportData | Out-Null
    Set-Content -LiteralPath (Join-Path $setupImportData 'channels.json') -Value '{ invalid json' -Encoding UTF8
    $invalidInspectJson = & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Inspect -DataRoot $setupImportData | Out-String
    $invalidInspect = $invalidInspectJson | ConvertFrom-Json
    Assert-True ($invalidInspect.status -eq 'invalid-configuration' -and -not $invalidInspect.snapshot.configValid) 'Invalid existing configuration was presented as reusable.'
    $invalidCreateRejected = $false
    try { & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Create -DataRoot $setupImportData -Count 2 | Out-Null } catch { $invalidCreateRejected = ($_.Exception.Message -match '配置无效') }
    Assert-True $invalidCreateRejected 'Invalid existing configuration did not block VM creation and direct the user to repair import.'
    $setupImportJson = & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Import -DataRoot $setupImportData -ImportConfigPath $importConfig | Out-String
    $setupImport = $setupImportJson | ConvertFrom-Json
    Assert-True ($setupImport.status -eq 'configuration-repaired' -and $setupImport.projects.Count -eq 2 -and (Test-Path -LiteralPath $setupImport.invalidConfigBackup) -and (Test-Path -LiteralPath (Join-Path $setupImportData 'channels.json'))) 'Setup invalid-configuration repair import failed.'
    $fakeProvisioner = Join-Path $temporaryRoot 'New-ChannelVMs.fake.ps1'
    @'
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$IsoPath,[string]$ExpectedSha256,[string]$RootPath,[string]$SwitchName,[ValidateRange(1,8)][int]$Count=2,[switch]$Compact,[switch]$Apply)
$items = @(1..$Count | ForEach-Object { [ordered]@{ vmName=('qicheng-win-' + $_); state='Off' } })
[ordered]@{ schemaVersion=1; status=if($Apply){'created-off'}else{'not-deployed'}; applyRequested=[bool]$Apply; hostChangesMade=[bool]$Apply; provisioned=$items } | ConvertTo-Json -Depth 6 -Compress
'@ | Set-Content -LiteralPath $fakeProvisioner -Encoding UTF8
    $fakeIso = Join-Path $temporaryRoot 'windows-fixture.iso'
    Set-Content -LiteralPath $fakeIso -Value 'synthetic ISO fixture; not installation media' -Encoding ASCII
    $fakeIsoHash = (Get-FileHash -LiteralPath $fakeIso -Algorithm SHA256).Hash
    $newSetupData = Join-Path $temporaryRoot 'setup-new-data'
    $setupPlanJson = & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Create -DataRoot $newSetupData -Count 3 -IsoPath $fakeIso -ExpectedSha256 $fakeIsoHash -VMRootPath $temporaryRoot -SwitchName 'fixture-switch' -NewChannelVMsPath $fakeProvisioner | Out-String
    $setupPlan = $setupPlanJson | ConvertFrom-Json
    Assert-True ($setupPlan.status -eq 'vm-plan-ready' -and $setupPlan.workspaceCount -eq 3 -and $setupPlan.provisioning.provisioned.Count -eq 3 -and $setupPlan.resourceEstimate.totalVMMemoryGiB -eq 24 -and -not $setupPlan.channelsAvailable -and -not $setupPlan.hostChangesMade) 'Setup VM plan overclaimed readiness, dropped Count, or calculated resources incorrectly.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $newSetupData 'setup-status.json'))) 'Setup plan wrote pending state without Apply.'
    $setupApplyJson = & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Create -DataRoot $newSetupData -Count 3 -IsoPath $fakeIso -ExpectedSha256 $fakeIsoHash -VMRootPath $temporaryRoot -SwitchName 'fixture-switch' -NewChannelVMsPath $fakeProvisioner -Apply -Confirm:$false | Out-String
    $setupApply = $setupApplyJson | ConvertFrom-Json
    $setupPending = Get-Content -LiteralPath (Join-Path $newSetupData 'setup-status.json') -Raw | ConvertFrom-Json
    Assert-True ($setupApply.status -eq 'vm-created-windows-pending' -and -not $setupApply.channelsAvailable -and $setupApply.windowsInstallationRequired -and $setupApply.guestAgentRequired) 'Setup treated newly created VMs as ready channels.'
    Assert-True ($setupPending.workspaceCount -eq 3 -and -not $setupPending.channelsAvailable -and $setupPending.configurationImportRequired) 'Setup pending-state record is incomplete.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $newSetupData 'channels.json'))) 'VM creation wrote a channels.json before Windows and guest-agent setup completed.'
    $installedRecordPath = Join-Path $installRoot '.qicheng-product-install.json'
    $recordHashBeforeBlockedUpgrade = (Get-FileHash -LiteralPath $installedRecordPath -Algorithm SHA256).Hash
    $installedLauncher = Join-Path $installRoot 'Invoke-WindowsChannelsMcp.ps1'
    $escapedLauncher = $installedLauncher.Replace("'","''")
    $escapedInstallRoot = $installRoot.Replace("'","''")
    $holdArguments = '-NoProfile -Command "$marker = ''{0}''; Set-Location -LiteralPath ''{1}''; Start-Sleep -Seconds 4"' -f $escapedLauncher,$escapedInstallRoot
    $holdProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $holdArguments -WindowStyle Hidden -PassThru
    try {
        $holdVisible = $false
        foreach ($attempt in 1..20) {
            $holdDetails = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $holdProcess.Id) -ErrorAction SilentlyContinue
            if ($holdDetails -and ([string]$holdDetails.CommandLine).IndexOf($installedLauncher,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $holdVisible = $true; break }
            Start-Sleep -Milliseconds 100
        }
        Assert-True $holdVisible 'Upgrade-lock fixture process did not expose the installed MCP launcher in its command line.'
        $blockedJson = & (Join-Path $packageRoot 'Install-WindowsChannels.ps1') -PackageRoot $packageRoot -InstallRoot $installRoot -DataRoot $dataRoot -StartMenuRoot $startMenu -DesktopRoot $desktop -StartupRoot $startup -PythonPath $pythonPath -ImportConfigPath $importConfig -Apply -Confirm:$false | Out-String
        $blocked = $blockedJson | ConvertFrom-Json
        Assert-True ($blocked.status -eq 'blocked-process-in-use' -and $blocked.reason -eq 'installed-product-running' -and $blocked.existingVersionPreserved -and -not $blocked.hostChangesMade) 'Running installed MCP launcher did not produce the structured upgrade blocker.'
        Assert-True (@($blocked.processes | Where-Object { $_.processId -eq $holdProcess.Id -and $_.role -eq 'mcp-launcher' }).Count -eq 1) 'Structured upgrade blocker did not identify the MCP launcher process.'
        Assert-True ($blocked.message -match '关闭频道.*重试' -and $blocked.message -match '保持不变') 'Structured upgrade blocker did not provide a clear retry/preservation message.'
        Assert-True ((Get-FileHash -LiteralPath $installedRecordPath -Algorithm SHA256).Hash -eq $recordHashBeforeBlockedUpgrade) 'Blocked upgrade changed the installed version record.'
        Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $installRoot) -Directory -Filter '.QichengWindowsChannels.*').Count -eq 0) 'Blocked upgrade created a staging or backup directory.'
    } finally {
        [void]$holdProcess.WaitForExit(10000)
    }
    $pwshInstallRoot = Join-Path $temporaryRoot 'install-pwsh7'
    $pwshDataRoot = Join-Path $temporaryRoot 'data-pwsh7'
    $pwshStartMenu = Join-Path $temporaryRoot 'start-menu-pwsh7'
    $pwshDesktop = Join-Path $temporaryRoot 'desktop-pwsh7'
    $pwshStartup = Join-Path $temporaryRoot 'startup-pwsh7'
    $pwshApplyJson = & (Join-Path $packageRoot 'Install-WindowsChannels.ps1') -PackageRoot $packageRoot -InstallRoot $pwshInstallRoot -DataRoot $pwshDataRoot -StartMenuRoot $pwshStartMenu -DesktopRoot $pwshDesktop -StartupRoot $pwshStartup -AutoStart Disabled -PythonPath $pythonPath -ImportConfigPath $importConfig -Apply -Confirm:$false | Out-String
    $pwshApply = $pwshApplyJson | ConvertFrom-Json
    Assert-True ($pwshApply.status -eq 'installed' -and $pwshApply.configImported) 'PowerShell 7 config-import installation failed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $pwshDataRoot 'tokens\channel-2.token') -PathType Leaf) 'PowerShell 7 config import did not copy a token.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $pwshStartup '启程 Windows 频道.lnk'))) 'AutoStart Disabled still created a startup shortcut.'
    $recoveryMarker = Join-Path $installRoot 'pre-upgrade.marker'
    Set-Content -LiteralPath $recoveryMarker -Value 'preserve-original-install' -Encoding ASCII
    $upgradeFailureObserved = $false
    try {
        & (Join-Path $packageRoot 'Install-WindowsChannels.ps1') -PackageRoot $packageRoot -InstallRoot $installRoot -DataRoot $dataRoot -StartMenuRoot $startMenu -DesktopRoot $desktop -StartupRoot $startup -PythonPath $pythonPath -ImportConfigPath $importConfig -Apply -Confirm:$false | Out-Null
    } catch { $upgradeFailureObserved = $true }
    Assert-True $upgradeFailureObserved 'Recovery test did not trigger the expected post-activation import failure.'
    Assert-True ((Get-Content -LiteralPath $recoveryMarker -Raw).Trim() -eq 'preserve-original-install') 'Failed upgrade did not restore the prior installation.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $dataRoot 'tokens\channel-1.token') -Raw).Trim() -eq ('a' * 64)) 'Failed upgrade changed existing user data.'
    $selfTestPath = Join-Path $temporaryRoot 'installed-viewer-self-test.json'
    $selfArgs = '--config "{0}" --python "{1}" --self-test "{2}"' -f $installedConfigPath,$pythonPath,$selfTestPath
    $viewerProcess = Start-Process -FilePath $installedViewer -ArgumentList $selfArgs -WorkingDirectory $installRoot -Wait -PassThru
    Assert-True ($viewerProcess.ExitCode -eq 0) 'Installed viewer self-test failed.'
    $viewerSelfTest = Get-Content -LiteralPath $selfTestPath -Raw | ConvertFrom-Json
    Assert-True ($viewerSelfTest.arguments_valid -and $viewerSelfTest.project_count -eq 2 -and -not $viewerSelfTest.gui_tested) 'Installed viewer self-test output is invalid.'
    $diagnoseOut = Join-Path $temporaryRoot 'diagnose.json'
    $diagnoseErr = Join-Path $temporaryRoot 'diagnose.err'
    $diagnoseArgs = '-NoProfile -File "{0}" -InstallRoot "{1}" -ConfigPath "{2}" -PythonPath "{3}"' -f (Join-Path $installRoot 'Diagnose-WindowsChannels.ps1'),$installRoot,$installedConfigPath,$pythonPath
    $diagnoseProcess = Start-Process -FilePath (Get-Command pwsh.exe -ErrorAction Stop).Source -ArgumentList $diagnoseArgs -RedirectStandardOutput $diagnoseOut -RedirectStandardError $diagnoseErr -Wait -PassThru
    $diagnoseJson = Get-Content -LiteralPath $diagnoseOut -Raw | ConvertFrom-Json
    Assert-True ($null -ne $diagnoseJson.checks -and $diagnoseJson.checks.Count -ge 6) 'PowerShell 7 diagnosis did not emit its check array.'
    $diagnoseErrorText = [string]::Join('', @(Get-Content -LiteralPath $diagnoseErr))
    Assert-True ([bool]($diagnoseErrorText -notmatch 'Argument types do not match')) 'PowerShell 7 diagnosis retained the generic-list conversion failure.'
    $aiJson = & (Join-Path $installRoot 'Get-AISetup.ps1') -PythonPath $pythonPath | Out-String
    $ai = $aiJson | ConvertFrom-Json
    Assert-True ($ai.connectors.Count -eq 2) 'AI setup did not emit one connector per project.'
    Assert-True (-not $ai.connectors[0].cwdRequired) 'AI setup still requires the client to supply cwd.'
    Assert-True ($ai.connectors[0].command -match '(?i)powershell\.exe$') 'AI setup did not emit the stable PowerShell launcher.'
    Assert-True ($ai.connectors[0].args -contains (Join-Path $installRoot 'Invoke-WindowsChannelsMcp.ps1')) 'AI setup did not bind the installed stable launcher.'
    Assert-True ($aiJson -notmatch ('a' * 64) -and $aiJson -notmatch ('b' * 64)) 'AI setup exposed a token value.'
    $emptyInput = Join-Path $temporaryRoot 'empty-stdin.txt'
    Set-Content -LiteralPath $emptyInput -Value '' -NoNewline
    $mcpStdout = Join-Path $temporaryRoot 'mcp-stdout.txt'
    $mcpStderr = Join-Path $temporaryRoot 'mcp-stderr.txt'
    $mcpArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Project channel-1 -PythonPath "{1}"' -f (Join-Path $installRoot 'Invoke-WindowsChannelsMcp.ps1'),$pythonPath
    $mcpProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $mcpArguments -WorkingDirectory $temporaryRoot -RedirectStandardInput $emptyInput -RedirectStandardOutput $mcpStdout -RedirectStandardError $mcpStderr -Wait -PassThru
    $mcpErrorText = if (Test-Path -LiteralPath $mcpStderr) { Get-Content -LiteralPath $mcpStderr -Raw } else { '' }
    Assert-True ($mcpProcess.ExitCode -eq 0) ("Stable MCP launcher failed when invoked without a client cwd: " + $mcpErrorText)
    $fakeCodex = Join-Path $temporaryRoot 'fake-codex.cmd'
    $fakeList = Join-Path $temporaryRoot 'fake-codex-list.json'
    $fakeAddLog = Join-Path $temporaryRoot 'fake-codex-add.log'
    @(
        '@echo off',
        'if /I "%~1"=="mcp" if /I "%~2"=="list" (',
        '  type "%QICHENG_FAKE_CODEX_LIST_FILE%"',
        '  exit /b 0',
        ')',
        'if /I "%~1"=="mcp" if /I "%~2"=="add" (',
        '  >"%QICHENG_FAKE_CODEX_ADD_LOG%" echo %*',
        '  exit /b 0',
        ')',
        'exit /b 3'
    ) | Set-Content -LiteralPath $fakeCodex -Encoding ASCII
    $previousFakeList = $env:QICHENG_FAKE_CODEX_LIST_FILE
    $previousFakeLog = $env:QICHENG_FAKE_CODEX_ADD_LOG
    $env:QICHENG_FAKE_CODEX_LIST_FILE = $fakeList
    $env:QICHENG_FAKE_CODEX_ADD_LOG = $fakeAddLog
    try {
        '[]' | Set-Content -LiteralPath $fakeList -Encoding ASCII
        $codexPlanJson = & (Join-Path $installRoot 'Add-CodexMcp.ps1') -Name 'qicheng-channel-1' -Project 'channel-1' -PythonPath $pythonPath -CodexPath $fakeCodex | Out-String
        $codexPlan = $codexPlanJson | ConvertFrom-Json
        Assert-True ($codexPlan.status -eq 'not-added' -and -not $codexPlan.nativeToolsDiscovered -and $codexPlan.requiresClientReload) 'Empty fake Codex list did not produce a non-mutating add plan.'
        $codexApplyJson = & (Join-Path $installRoot 'Add-CodexMcp.ps1') -Name 'qicheng-channel-1' -Project 'channel-1' -PythonPath $pythonPath -CodexPath $fakeCodex -Apply -Confirm:$false | Out-String
        $codexApply = $codexApplyJson | ConvertFrom-Json
        Assert-True ($codexApply.status -eq 'codex-cli-config-added') 'Fake Codex add path did not report success.'
        $addLogBefore = (Get-Content -LiteralPath $fakeAddLog -Raw).Trim()
        Assert-True ($addLogBefore -match '^mcp add qicheng-channel-1 -- ') 'Fake Codex did not receive the expected mcp add command.'

        @([ordered]@{ name='qicheng-channel-1'; enabled=$true; transport=[ordered]@{ type='stdio'; command=[string]$ai.connectors[0].command; args=@($ai.connectors[0].args) } }) | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $fakeList -Encoding ASCII
        $samePlanJson = & (Join-Path $installRoot 'Add-CodexMcp.ps1') -Name 'qicheng-channel-1' -Project 'channel-1' -PythonPath $pythonPath -CodexPath $fakeCodex | Out-String
        $samePlan = $samePlanJson | ConvertFrom-Json
        Assert-True ($samePlan.status -eq 'already-configured' -and $samePlan.existingMatches) 'Same-name same-command fake Codex entry was not treated as already configured.'

        @([ordered]@{ name='qicheng-channel-1'; enabled=$true; transport=[ordered]@{ type='stdio'; command='cmd.exe'; args=@('/d','/c','different-server.cmd') } }) | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $fakeList -Encoding ASCII
        $conflictPlanJson = & (Join-Path $installRoot 'Add-CodexMcp.ps1') -Name 'qicheng-channel-1' -Project 'channel-1' -PythonPath $pythonPath -CodexPath $fakeCodex | Out-String
        $conflictPlan = $conflictPlanJson | ConvertFrom-Json
        Assert-True ($conflictPlan.status -eq 'conflict' -and $conflictPlan.existingNameFound -and -not $conflictPlan.existingMatches) 'Existing different fake Codex entry was not reported as a conflict.'
        $conflictApplyRejected = $false
        try { & (Join-Path $installRoot 'Add-CodexMcp.ps1') -Name 'qicheng-channel-1' -Project 'channel-1' -PythonPath $pythonPath -CodexPath $fakeCodex -Apply -Confirm:$false | Out-Null } catch { $conflictApplyRejected = $true }
        Assert-True $conflictApplyRejected 'Fake Codex conflict apply was not rejected before add.'
        Assert-True ((Get-Content -LiteralPath $fakeAddLog -Raw).Trim() -eq $addLogBefore) 'Conflict path invoked fake codex mcp add.'
    } finally {
        if ($null -eq $previousFakeList) { Remove-Item Env:QICHENG_FAKE_CODEX_LIST_FILE -ErrorAction SilentlyContinue } else { $env:QICHENG_FAKE_CODEX_LIST_FILE = $previousFakeList }
        if ($null -eq $previousFakeLog) { Remove-Item Env:QICHENG_FAKE_CODEX_ADD_LOG -ErrorAction SilentlyContinue } else { $env:QICHENG_FAKE_CODEX_ADD_LOG = $previousFakeLog }
    }
    $uninstallPlanJson = & (Join-Path $installRoot 'Uninstall-WindowsChannels.ps1') -InstallRoot $installRoot | Out-String
    $uninstallPlan = $uninstallPlanJson | ConvertFrom-Json
    Assert-True ($uninstallPlan.status -eq 'not-uninstalled' -and -not $uninstallPlan.removeUserData) 'Uninstall default does not preserve user data.'
    $sourceManifest = Get-Content -LiteralPath (Join-Path $packageRoot 'SOURCE-MANIFEST.json') -Raw | ConvertFrom-Json
    Assert-True ($sourceManifest.exclusions -contains 'tokens') 'Source manifest does not state token exclusion.'
    if (-not $SkipPublicExportRoundTrip) {
        $publicRoot = Join-Path $temporaryRoot 'public-source'
        New-Item -ItemType Directory -Path $publicRoot | Out-Null
        $exportJson = & (Join-Path $productRoot 'Export-PublicSource.ps1') -OutputDirectory $publicRoot | Out-String
        $export = $exportJson | ConvertFrom-Json
        $expectedPublicFiles = 50 + $themeSourceCount
        Assert-True ($export.status -eq 'exported' -and $export.fileCount -eq $expectedPublicFiles) 'Public source export count or status is incorrect.'
        $publicModule = Join-Path $publicRoot 'tools\windows-channels'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicRoot 'LICENSE') -PathType Leaf) 'Public repository LICENSE is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'LICENSE') -PathType Leaf) 'Public module LICENSE is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'product\Build-Package.ps1') -PathType Leaf) 'Exported package builder is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'product\tests\Test-ProductPackage.ps1') -PathType Leaf) 'Exported product tests are missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'tests\HostServiceSafety.Tests.ps1') -PathType Leaf) 'Exported HostService safety tests are missing.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $publicRoot 'LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Public repository LICENSE differs from the module Apache LICENSE.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $publicModule 'LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Public module LICENSE differs from the reviewed Apache LICENSE.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicModule 'Install-GuestPayloadOffline.ps1'))) 'Offline candidate entered public source export.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicModule '.local'))) 'Private .local data entered public source export.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicModule 'viewer\dist'))) 'Built viewer output entered public source export.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicRoot 'SOURCE-MANIFEST.json'))) 'Internal package source manifest entered public source export.'
        $publicManifestText = Get-Content -LiteralPath (Join-Path $publicRoot 'PUBLIC-SOURCE-MANIFEST.json') -Raw
        $publicManifest = $publicManifestText | ConvertFrom-Json
        Assert-True (-not ($publicManifest.PSObject.Properties.Name -contains 'repositoryCommit')) 'Public source manifest exposed a private Git commit.'
        $roundTripJson = & (Join-Path $publicModule 'product\tests\Test-ProductPackage.ps1') -SkipPublicExportRoundTrip | Out-String
        $roundTrip = $roundTripJson | ConvertFrom-Json
        Assert-True ($roundTrip.status -eq 'passed' -and $roundTrip.packageFiles -eq $expectedPackageFiles) 'Exported source could not reproduce the package and tests.'
    }
    $unrelatedStartupLink = Join-Path $startup '其他产品.lnk'
    Set-Content -LiteralPath $unrelatedStartupLink -Value 'unrelated shortcut sentinel' -Encoding UTF8
    $uninstallJson = & (Join-Path $installRoot 'Uninstall-WindowsChannels.ps1') -InstallRoot $installRoot -Apply -Confirm:$false | Out-String
    $uninstall = $uninstallJson | ConvertFrom-Json
    Assert-True ($uninstall.status -eq 'uninstall-requested' -and $uninstall.userDataPreserved -and -not $uninstall.dataRemoved) 'Applied uninstall did not preserve user data by default.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $startup '启程 Windows 频道.lnk'))) 'Applied uninstall left the product startup shortcut.'
    Assert-True (Test-Path -LiteralPath $unrelatedStartupLink -PathType Leaf) 'Applied uninstall removed an unrelated startup shortcut.'
    Assert-True (Test-Path -LiteralPath $dataRoot -PathType Container) 'Applied uninstall removed user data without RemoveUserData.'
    [ordered]@{ status='passed'; packageFiles=$manifest.files.Count; publicSourceRoundTripValidated=(-not $SkipPublicExportRoundTrip); archive=$build.archive; planValidated=$true; windowsPowerShellInstallerPreflight=$true; windowsPowerShell51ImportValidated=$true; windowsPowerShell51SetupValidated=$true; powerShell7ImportValidated=$true; firstRunSetupValidated=$true; invalidConfigurationRepairValidated=$true; existingConfigurationReuseValidated=$true; workspaceCountOptionsValidated='1..8'; workspaceResourceEstimateValidated=$true; vmCreatedStateRemainsPendingValidated=$true; failedUpgradeRestoreValidated=$true; upgradeProcessBlockValidated=$true; temporaryInstallValidated=$true; configImportValidated=$true; viewerDerivedRoot=$derivedRoot; viewerSelfTestValidated=$true; powerShell7DiagnosisValidated=$true; shortcutsValidated=$true; defaultLaunchHiddenAndManagementShowValidated=$true; autoStartEnabledValidated=$true; autoStartDisabledValidated=$true; uninstallExactStartupLinkValidated=$true; aiConnectorsValidated=2; stableMcpLauncherValidated=$true; codexCliIsolatedFakeValidated=$true; codexEmptyListAddRecorded=$true; codexSameConfigNoOpValidated=$true; codexNameConflictRejected=$true; nativeMcpDiscovered=$false; uninstallPreservesUserData=$true; relativePathRejected=$true; realUserInstallPerformed=$false } | ConvertTo-Json -Depth 4
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
