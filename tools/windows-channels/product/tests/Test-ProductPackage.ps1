[CmdletBinding()]
param([switch]$SkipPublicExportRoundTrip,[switch]$RunHotkeyIntegration)

$ErrorActionPreference = 'Stop'
$productRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qicheng-product-test-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $temporaryRoot 'package'
$previousLocalAppData = $env:LOCALAPPDATA
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Protect-ImportToken([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $env:LOCALAPPDATA = Join-Path $temporaryRoot 'isolated-localappdata'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA | Out-Null
    $buildJson = & (Join-Path $productRoot 'Build-Package.ps1') -OutputDirectory $packageRoot -Version '0.1.0-test' | Out-String
    $build = $buildJson | ConvertFrom-Json
    Assert-True ($build.status -eq 'built') 'Build did not report success.'
    Assert-True (Test-Path -LiteralPath $build.archive -PathType Leaf) 'Zip archive is missing.'
    $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Raw | ConvertFrom-Json
    $themeSourceRoot = Join-Path (Split-Path -Parent $productRoot) 'theme'
    $themeSourceCount = @(@('ai-space.png','ai-space-v2.png','Set-WorkspaceTheme.ps1','README.md') | Where-Object { Test-Path -LiteralPath (Join-Path $themeSourceRoot $_) -PathType Leaf }).Count
    $expectedPackageFiles = 83 + (2 * $themeSourceCount)
    Assert-True ($manifest.files.Count -eq $expectedPackageFiles) 'Unexpected package allowlist count.'
    $paths = @($manifest.files.path)
    Assert-True ($paths -contains 'LICENSE' -and $paths -contains 'source/LICENSE') 'Apache LICENSE is missing from the install or source package.'
    $moduleLicense = Join-Path (Split-Path -Parent $productRoot) 'LICENSE'
    $licenseHash = (Get-FileHash -LiteralPath $moduleLicense -Algorithm SHA256).Hash
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Install package LICENSE differs from the module Apache LICENSE.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'source\LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Source package LICENSE differs from the module Apache LICENSE.'
    Assert-True ($paths -contains 'viewer/dist/WindowsChannelsViewer.exe') 'Built viewer is not packaged in its required relative layout.'
    Assert-True ($paths -contains 'host/mcp.py') 'Runtime MCP source is not packaged.'
    Assert-True ($paths -contains 'host/lease_client.py' -and $paths -contains 'source/host/lease_client.py') 'Lease client is missing from runtime or reproducible source.'
    Assert-True ($paths -contains 'host/broker_client.py' -and $paths -contains 'source/host/broker_client.py') 'Broker MCP client is missing from runtime or reproducible source.'
    Assert-True ($paths -contains 'source/guest/agent.py') 'Guest source is not packaged for public reproduction.'
    Assert-True ($paths -contains 'source/guest/wechat_cli.py') 'Guest WeChat CLI source is not packaged.'
    Assert-True ($paths -contains 'source/New-ChannelVMs.ps1') 'VM preparation source is not packaged.'
    Assert-True ($paths -contains 'source/tests/test_host_mcp.py') 'Source tests are not packaged.'
    foreach ($testName in @('test_guest_lease.py','test_host_lease.py','test_wechat_cli.py','test_broker_client.py')) {
        Assert-True ($paths -contains ('source/tests/' + $testName)) "Lease or WeChat CLI source test is not packaged: $testName"
    }
    Assert-True ($paths -contains 'source/Stage-GuestPayloadDirect.ps1' -and $paths -contains 'source/Switch-GuestPayloadDirect.ps1' -and $paths -contains 'source/tests/ThreeCredentialPayload.Tests.ps1') 'Three-credential stage source or tests are missing.'
    Assert-True ($paths -contains 'source/Install-GuestPayloadOffline.ps1' -and $paths -contains 'source/tests/InstallGuestPayloadOffline.Tests.ps1') 'Three-credential offline installer or its simulated test is missing.'
    Assert-True ($paths -contains 'source/tests/HostServiceSafety.Tests.ps1') 'Host service safety tests are not packaged.'
    Assert-True ($paths -contains 'source/product/Build-Package.ps1') 'Product package builder is not included in source distribution.'
    Assert-True ($paths -contains 'source/product/tests/Test-ProductPackage.ps1') 'Product package tests are not included in source distribution.'
    Assert-True ($paths -contains 'Setup-WindowsChannels.ps1' -and $paths -contains 'source/product/runtime/Setup-WindowsChannels.ps1') 'First-run setup wizard is missing from runtime or source distribution.'
    foreach ($themeName in @('ai-space.png','ai-space-v2.png','Set-WorkspaceTheme.ps1','README.md')) {
        if (Test-Path -LiteralPath (Join-Path $themeSourceRoot $themeName) -PathType Leaf) {
            Assert-True ($paths -contains ('theme/' + $themeName) -and $paths -contains ('source/theme/' + $themeName)) "Allowlisted theme asset was not packaged twice: $themeName"
        }
    }
    Assert-True (-not ($paths -match '(?i)token|\.local|\.vhdx|\.iso|project-memory|\.git')) 'Sensitive or machine-local path entered the package.'
    Assert-True (-not ($paths -match '(?i)evidence/|docs/pm/')) 'Unreviewed evidence or project memory entered the package.'
    foreach ($entry in $manifest.files) {
        $file = Join-Path $packageRoot ([string]$entry.path)
        Assert-True (Test-Path -LiteralPath $file -PathType Leaf) "Manifest file missing: $($entry.path)"
        Assert-True ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ieq [string]$entry.sha256) "Hash mismatch: $($entry.path)"
    }
    $offlineTestJson = & (Join-Path $packageRoot 'source\tests\InstallGuestPayloadOffline.Tests.ps1') | Out-String
    $offlineTest = $offlineTestJson | ConvertFrom-Json
    Assert-True ($offlineTest.passed -eq 14 -and $offlineTest.failed -eq 0 -and $offlineTest.vmMounts -eq 0 -and $offlineTest.agentStarts -eq 0) 'Packaged offline installer failed the simulated three-credential plan and rejection tests.'
    $installRoot = Join-Path $temporaryRoot 'install'
    $dataRoot = Join-Path $temporaryRoot 'data'
    $startMenu = Join-Path $temporaryRoot 'start-menu'
    $desktop = Join-Path $temporaryRoot 'desktop'
    $startup = Join-Path $temporaryRoot 'startup'
    $importRoot = Join-Path $temporaryRoot 'private-import'
    New-Item -ItemType Directory -Path $importRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $importRoot 'original-1.token') -Value ('a' * 64) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $importRoot 'original-2.token') -Value ('b' * 64) -Encoding ASCII
    Protect-ImportToken (Join-Path $importRoot 'original-1.token')
    Protect-ImportToken (Join-Path $importRoot 'original-2.token')
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
    Assert-True (-not ($installedConfig.projects.'channel-1'.PSObject.Properties.Name -contains 'human_token_file')) 'Legacy single-token config unexpectedly gained a human token.'
    $humanImportRoot = Join-Path $temporaryRoot 'private-human-import'
    New-Item -ItemType Directory -Path $humanImportRoot | Out-Null
    $humanChannelSource = Join-Path $humanImportRoot 'channel.token'
    $humanSource = Join-Path $humanImportRoot 'human.token'
    Set-Content -LiteralPath $humanChannelSource -Value ('c' * 64) -Encoding ASCII
    Set-Content -LiteralPath $humanSource -Value ('d' * 64) -Encoding ASCII
    Protect-ImportToken $humanChannelSource
    Protect-ImportToken $humanSource
    $humanConfig = Join-Path $humanImportRoot 'channels.json'
    [ordered]@{ schema_version=1; projects=[ordered]@{
        'human-channel'=[ordered]@{ vm_id='51111111-2222-4333-8444-555555555555'; bios_uuid='61111111-2222-4333-8444-555555555555'; token_file='channel.token'; human_token_file='human.token' }
    } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $humanConfig -Encoding UTF8
    $humanDataRoot = Join-Path $temporaryRoot 'human-data'
    $humanOut = Join-Path $temporaryRoot 'winps-human-import.json'
    $humanErr = Join-Path $temporaryRoot 'winps-human-import.err'
    $humanArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -DataRoot "{2}"' -f (Join-Path $installRoot 'Import-WindowsChannelsConfig.ps1'),$humanConfig,$humanDataRoot
    $humanProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $humanArgs -RedirectStandardOutput $humanOut -RedirectStandardError $humanErr -Wait -PassThru
    $humanErrorText = if (Test-Path -LiteralPath $humanErr) { Get-Content -LiteralPath $humanErr -Raw } else { '' }
    Assert-True ($humanProcess.ExitCode -eq 0) ("Windows PowerShell 5.1 three-credential import failed: " + $humanErrorText)
    $humanResultText = Get-Content -LiteralPath $humanOut -Raw
    $humanResult = $humanResultText | ConvertFrom-Json
    Assert-True ($humanResult.status -eq 'imported' -and @($humanResult.projects).Count -eq 1) 'Three-credential import result is invalid.'
    $humanInstalled = Get-Content -LiteralPath (Join-Path $humanDataRoot 'channels.json') -Raw | ConvertFrom-Json
    Assert-True ($humanInstalled.projects.'human-channel'.token_file -eq 'tokens/human-channel.token') 'Three-credential channel path was not normalized.'
    Assert-True ($humanInstalled.projects.'human-channel'.human_token_file -eq 'tokens/human-channel.human.token') 'Human token path was discarded during import.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $humanDataRoot 'tokens\human-channel.human.token') -Raw) -eq ('d' * 64)) 'Human token value was not preserved.'
    Assert-True ($humanResultText -notmatch ('c' * 64) -and $humanResultText -notmatch ('d' * 64)) 'Human import output exposed a token value.'
    foreach ($tokenPath in @((Join-Path $humanDataRoot 'tokens\human-channel.token'),(Join-Path $humanDataRoot 'tokens\human-channel.human.token'))) {
        $tokenAcl = Get-Acl -LiteralPath $tokenPath
        Assert-True $tokenAcl.AreAccessRulesProtected 'Imported token file ACL is not protected.'
        foreach ($rule in $tokenAcl.Access) {
            if ($rule.AccessControlType -eq 'Allow') {
                $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                Assert-True (@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18') -contains $sid) 'Imported token grants access to another identity.'
            }
        }
    }
    . (Join-Path $productRoot 'runtime\Product.Common.ps1')
    Remove-Item -LiteralPath $humanSource
    $missingRejected = $false
    try { Get-QichengConfigImportMaterial -ConfigPath $humanConfig | Out-Null } catch { $missingRejected = $true }
    Assert-True $missingRejected 'Missing human token was accepted.'
    Set-Content -LiteralPath $humanSource -Value ('d' * 64) -Encoding ASCII
    $weakRejected = $false
    try { Get-QichengConfigImportMaterial -ConfigPath $humanConfig | Out-Null } catch { $weakRejected = $true }
    Assert-True $weakRejected 'Human token with inherited ACL was accepted.'
    Protect-ImportToken $humanSource
    Set-Content -LiteralPath $humanSource -Value ('z' * 64) -Encoding ASCII
    $invalidRejected = $false
    try { Get-QichengConfigImportMaterial -ConfigPath $humanConfig | Out-Null } catch { $invalidRejected = $true }
    Assert-True $invalidRejected 'Invalid human token was accepted.'
    Set-Content -LiteralPath $humanSource -Value ('c' * 64) -Encoding ASCII
    $duplicateValueRejected = $false
    try { Get-QichengConfigImportMaterial -ConfigPath $humanConfig | Out-Null } catch { $duplicateValueRejected = $true }
    Assert-True $duplicateValueRejected 'Identical channel and human token values were accepted.'
    $sharedPathConfig = Get-Content -LiteralPath $humanConfig -Raw | ConvertFrom-Json
    $sharedPathConfig.projects.'human-channel'.human_token_file = 'channel.token'
    $sharedPathConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $humanConfig -Encoding UTF8
    $duplicatePathRejected = $false
    try { Get-QichengConfigImportMaterial -ConfigPath $humanConfig | Out-Null } catch { $duplicatePathRejected = $true }
    Assert-True $duplicatePathRejected 'Shared channel and human token path was accepted.'
    $shell = New-Object -ComObject WScript.Shell
    function Read-Link([string]$Path) {
        Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "Shortcut is missing: $Path"
        $temporaryPath = Join-Path $temporaryRoot ('.qicheng-shortcut-read-' + [guid]::NewGuid().ToString('N') + '.lnk')
        $link = $null
        try {
            Copy-Item -LiteralPath $Path -Destination $temporaryPath
            $link = $shell.CreateShortcut($temporaryPath)
            [pscustomobject]@{ Arguments=[string]$link.Arguments; TargetPath=[string]$link.TargetPath; WorkingDirectory=[string]$link.WorkingDirectory }
        } finally {
            if ($null -ne $link -and [Runtime.InteropServices.Marshal]::IsComObject($link)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
    $desktopArguments = (Read-Link (Join-Path $desktop '启程 Windows 频道.lnk')).Arguments
    $startupArguments = (Read-Link (Join-Path $startup '启程 Windows 频道.lnk')).Arguments
    $managementArguments = (Read-Link (Join-Path $startMenu '管理 Windows 频道.lnk')).Arguments
    $setupArguments = (Read-Link (Join-Path $startMenu '设置 Windows 频道.lnk')).Arguments
    Assert-True ($desktopArguments -notmatch '(?i)(^|\s)-Show(\s|$)' -and $desktopArguments -match '(?i)-WindowStyle\s+Hidden') 'Default double-click shortcut is visible or can flash a PowerShell window.'
    Assert-True ($startupArguments -notmatch '(?i)(^|\s)-Show(\s|$)' -and $startupArguments -match '(?i)-WindowStyle\s+Hidden') 'Background Startup shortcut is visible or can flash a PowerShell window.'
    Assert-True ($managementArguments -match '(?i)(^|\s)-Show(\s|$)' -and $managementArguments -match '(?i)-WindowStyle\s+Hidden') 'Explicit management shortcut does not show Viewer cleanly without a PowerShell window.'
    Assert-True ($setupArguments -match '(?i)-WindowStyle\s+Hidden') 'Setup shortcut can flash a PowerShell window behind WinForms.'
    $setupInspectJson = & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Inspect -DataRoot $dataRoot | Out-String
    $setupInspect = $setupInspectJson | ConvertFrom-Json
    Assert-True ($setupInspect.status -eq 'configured-reused' -and $setupInspect.resourceOptions.Count -eq 8 -and $setupInspect.workspaceLimit.maxWorkspaceCount -eq 8 -and -not $setupInspect.workspaceLimit.liteCoexistenceDetected) 'Setup inspection did not reuse existing configuration or expose 1..8 resource options without Lite.'
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
if ($env:QICHENG_TEST_PROVISIONER_MARKER) { Set-Content -LiteralPath $env:QICHENG_TEST_PROVISIONER_MARKER -Value $Count -Encoding ASCII }
[ordered]@{ schemaVersion=1; status=if($Apply){'created-off'}else{'not-deployed'}; applyRequested=[bool]$Apply; hostChangesMade=[bool]$Apply; provisioned=$items } | ConvertTo-Json -Depth 6 -Compress
'@ | Set-Content -LiteralPath $fakeProvisioner -Encoding UTF8
    $fakeIso = Join-Path $temporaryRoot 'windows-fixture.iso'
    Set-Content -LiteralPath $fakeIso -Value 'synthetic ISO fixture; not installation media' -Encoding ASCII
    $fakeIsoHash = (Get-FileHash -LiteralPath $fakeIso -Algorithm SHA256).Hash
    $liteInstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\QichengLite'
    New-Item -ItemType Directory -Path $liteInstallRoot -Force | Out-Null
    $liteRecord = Join-Path $liteInstallRoot '.qicheng-lite-install.json'
    Set-Content -LiteralPath $liteRecord -Value '{}' -Encoding ASCII
    $liteSetupData = Join-Path $temporaryRoot 'setup-lite-data'
    $liteInspect = (& (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Inspect -DataRoot $liteSetupData | Out-String) | ConvertFrom-Json
    Assert-True ($liteInspect.workspaceLimit.liteCoexistenceDetected -and $liteInspect.workspaceLimit.maxWorkspaceCount -eq 6 -and @($liteInspect.resourceOptions).Count -eq 6 -and $liteInspect.workspaceLimit.explanation -match 'Alt\+4\.\.9') 'Lite coexistence inspection did not expose the six-workspace hotkey limit.'
    $provisionerMarker = Join-Path $temporaryRoot 'provisioner-invoked.txt'
    $env:QICHENG_TEST_PROVISIONER_MARKER = $provisionerMarker
    try {
        foreach ($rejectedCount in @(7,8)) {
            $limitRejected = $false
            try { & (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Create -DataRoot $liteSetupData -Count $rejectedCount -IsoPath $fakeIso -ExpectedSha256 $fakeIsoHash -VMRootPath $temporaryRoot -SwitchName 'fixture-switch' -NewChannelVMsPath $fakeProvisioner -Apply -Confirm:$false | Out-Null } catch { $limitRejected = ($_.Exception.Message -match '上限 6' -and $_.Exception.Message -match 'Alt\+4\.\.9') }
            Assert-True $limitRejected "Lite coexistence accepted $rejectedCount workspaces or omitted the hotkey explanation."
            Assert-True (-not (Test-Path -LiteralPath $provisionerMarker) -and -not (Test-Path -LiteralPath $liteSetupData)) "Rejected $rejectedCount-workspace request caused a creation side effect."
        }
        $liteSix = (& (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Create -DataRoot $liteSetupData -Count 6 -IsoPath $fakeIso -ExpectedSha256 $fakeIsoHash -VMRootPath $temporaryRoot -SwitchName 'fixture-switch' -NewChannelVMsPath $fakeProvisioner | Out-String) | ConvertFrom-Json
        Assert-True ($liteSix.status -eq 'vm-plan-ready' -and $liteSix.workspaceCount -eq 6 -and (Get-Content -LiteralPath $provisionerMarker -Raw).Trim() -eq '6') 'Lite coexistence rejected the allowed six-workspace plan.'
        Remove-Item -LiteralPath $provisionerMarker -Force
        Remove-Item -LiteralPath $liteRecord -Force
        $plainInspect = (& (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Inspect -DataRoot $liteSetupData | Out-String) | ConvertFrom-Json
        Assert-True (-not $plainInspect.workspaceLimit.liteCoexistenceDetected -and $plainInspect.workspaceLimit.maxWorkspaceCount -eq 8 -and @($plainInspect.resourceOptions).Count -eq 8) 'Setup did not restore the 1..8 options without Lite.'
        $plainEight = (& (Join-Path $installRoot 'Setup-WindowsChannels.ps1') -Action Create -DataRoot $liteSetupData -Count 8 -IsoPath $fakeIso -ExpectedSha256 $fakeIsoHash -VMRootPath $temporaryRoot -SwitchName 'fixture-switch' -NewChannelVMsPath $fakeProvisioner | Out-String) | ConvertFrom-Json
        Assert-True ($plainEight.status -eq 'vm-plan-ready' -and $plainEight.workspaceCount -eq 8 -and (Get-Content -LiteralPath $provisionerMarker -Raw).Trim() -eq '8') 'Setup rejected eight workspaces without Lite.'
    } finally { Remove-Item Env:QICHENG_TEST_PROVISIONER_MARKER -ErrorAction SilentlyContinue }
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
    Assert-True ($viewerSelfTest.arguments_valid -and $viewerSelfTest.project_count -eq 2 -and $viewerSelfTest.host_return_pipe -and -not $viewerSelfTest.gui_tested) 'Installed viewer self-test or hidden host-return pipe is invalid.'
    if ($RunHotkeyIntegration) {
        $previousScope = [Environment]::GetEnvironmentVariable('QICHENG_WINDOWS_VIEWER_TEST_SCOPE')
        $env:QICHENG_WINDOWS_VIEWER_TEST_SCOPE = [guid]::NewGuid().ToString('N')
        $firstStatusPath = Join-Path $temporaryRoot 'hotkey-integration-first.json'
        $secondStatusPath = Join-Path $temporaryRoot 'hotkey-integration-second.json'
        $firstArguments = '--config "{0}" --python "{1}" --channel-hotkeys 8,9 --no-host-hotkey --hotkey-status "{2}" --quiet-control-error' -f $installedConfigPath,$pythonPath,$firstStatusPath
        $secondArguments = '--config "{0}" --python "{1}" --channel-hotkeys 6,7 --no-host-hotkey --hotkey-status "{2}" --quiet-control-error' -f $installedConfigPath,$pythonPath,$secondStatusPath
        $firstViewer = $null
        try {
            $firstViewer = Start-Process -FilePath $installedViewer -ArgumentList $firstArguments -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru
            foreach ($attempt in 1..60) { if (Test-Path -LiteralPath $firstStatusPath -PathType Leaf) { break }; if ($firstViewer.HasExited) { break }; Start-Sleep -Milliseconds 100 }
            Assert-True (Test-Path -LiteralPath $firstStatusPath -PathType Leaf) 'Isolated viewer did not register its initial hotkeys.'
            $firstStatus = Get-Content -LiteralPath $firstStatusPath -Raw | ConvertFrom-Json
            Assert-True ($firstStatus.registered -eq 2 -and @($firstStatus.failed).Count -eq 0) 'Isolated viewer could not register Alt+8/9.'
            $secondViewer = Start-Process -FilePath $installedViewer -ArgumentList $secondArguments -WorkingDirectory $installRoot -WindowStyle Hidden -Wait -PassThru
            $secondStatus = Get-Content -LiteralPath $secondStatusPath -Raw | ConvertFrom-Json
            Assert-True ($secondViewer.ExitCode -eq 0 -and -not $firstViewer.HasExited -and $secondStatus.process_id -eq $firstViewer.Id -and ($secondStatus.channels -join ',') -eq '6,7' -and $secondStatus.registered -eq 2 -and @($secondStatus.failed).Count -eq 0) 'Running viewer did not reconfigure Alt+8/9 to Alt+6/7 in place.'
            $otherConfig = Join-Path $temporaryRoot 'other-hotkey-config.json'
            Copy-Item -LiteralPath $installedConfigPath -Destination $otherConfig
            $rejectedStatusPath = Join-Path $temporaryRoot 'hotkey-integration-rejected.json'
            $rejectedArguments = '--config "{0}" --python "{1}" --channel-hotkeys 8,9 --no-host-hotkey --hotkey-status "{2}" --quiet-control-error' -f $otherConfig,$pythonPath,$rejectedStatusPath
            $rejectedViewer = Start-Process -FilePath $installedViewer -ArgumentList $rejectedArguments -WorkingDirectory $installRoot -WindowStyle Hidden -Wait -PassThru
            $rejectedStatus = Get-Content -LiteralPath $rejectedStatusPath -Raw | ConvertFrom-Json
            Assert-True ($rejectedViewer.ExitCode -eq 1 -and $rejectedStatus.status -eq 'control-failed' -and $rejectedStatus.error_type -eq 'InvalidOperationException' -and -not $firstViewer.HasExited) 'Quiet control failure did not leave a readable diagnostic or preserve the first viewer.'
        } finally {
            if ($firstViewer -and -not $firstViewer.HasExited) { Stop-Process -Id $firstViewer.Id -Force -ErrorAction SilentlyContinue }
            [Environment]::SetEnvironmentVariable('QICHENG_WINDOWS_VIEWER_TEST_SCOPE',$previousScope)
        }
    }
    $originalViewer = Join-Path $temporaryRoot 'original-WindowsChannelsViewer.exe'
    Copy-Item -LiteralPath $installedViewer -Destination $originalViewer
    $fakeViewerSource = Join-Path $temporaryRoot 'FakeHotkeyViewer.cs'
    @'
using System;
using System.IO;
using System.Text;
class FakeHotkeyViewer {
    static void Main(string[] args) {
        string path = null, channels = "2,3";
        bool host = true;
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "--hotkey-status") path = args[++i];
            else if (args[i] == "--channel-hotkeys") channels = args[++i];
            else if (args[i] == "--no-host-hotkey") host = false;
        }
        if (path == null) return;
        string[] digits = channels.Split(',');
        string failed = Environment.GetEnvironmentVariable("QICHENG_FAKE_HOTKEY_FAILURE") == "1" ? "[\"Alt+4\"]" : "[]";
        string json = "{\"host_enabled\":" + (host ? "true" : "false") + ",\"channels\":[" + channels +
            "],\"registered\":" + (digits.Length + (host ? 1 : 0)) + ",\"failed\":" + failed + "}";
        File.WriteAllText(path, json, new UTF8Encoding(false));
    }
}
'@ | Set-Content -LiteralPath $fakeViewerSource -Encoding UTF8
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /out:$installedViewer $fakeViewerSource
    Assert-True ($LASTEXITCODE -eq 0) 'Fake hotkey viewer did not compile.'
    try {
        $coordinated = & (Join-Path $installRoot 'Start-WindowsChannels.ps1') -ConfigPath $installedConfigPath -PythonPath $pythonPath -ChannelHotkeys '4,5' -NoHostHotkey -WaitForHotkeys
        Assert-True ($coordinated.status -eq 'hotkeys-confirmed' -and -not $coordinated.hostHotkeyEnabled) 'Start script did not wait for confirmed remapping.'
        $ps5Start = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -PythonPath "{2}" -ChannelHotkeys 4,5 -NoHostHotkey -WaitForHotkeys' -f (Join-Path $installRoot 'Start-WindowsChannels.ps1'),$installedConfigPath,$pythonPath) -Wait -PassThru -WindowStyle Hidden
        Assert-True ($ps5Start.ExitCode -eq 0) 'Windows PowerShell 5.1 could not confirm hotkey remapping.'
        $env:QICHENG_FAKE_HOTKEY_FAILURE = '1'
        $registrationFailure = $false
        try { & (Join-Path $installRoot 'Start-WindowsChannels.ps1') -ConfigPath $installedConfigPath -PythonPath $pythonPath -ChannelHotkeys '4,5' -NoHostHotkey -WaitForHotkeys | Out-Null }
        catch { $registrationFailure = $true }
        Assert-True $registrationFailure 'Start script accepted a failed hotkey registration.'
    } finally {
        Remove-Item Env:QICHENG_FAKE_HOTKEY_FAILURE -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $originalViewer -Destination $installedViewer -Force
    }
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
    $brokerTokenFile = Join-Path $temporaryRoot 'synthetic-broker.token'
    [IO.File]::WriteAllText($brokerTokenFile, ('c' * 64), [Text.Encoding]::ASCII)
    $brokerMcpArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Project channel-1 -PythonPath "{1}" -BrokerUrl "http://127.0.0.1:18770" -BrokerTokenFile "{2}" -BrokerChannelId "channel-1"' -f (Join-Path $installRoot 'Invoke-WindowsChannelsMcp.ps1'),$pythonPath,$brokerTokenFile
    $brokerMcpStdout = Join-Path $temporaryRoot 'broker-mcp-stdout.txt'
    $brokerMcpStderr = Join-Path $temporaryRoot 'broker-mcp-stderr.txt'
    $brokerMcp = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $brokerMcpArgs -WorkingDirectory $temporaryRoot -RedirectStandardInput $emptyInput -RedirectStandardOutput $brokerMcpStdout -RedirectStandardError $brokerMcpStderr -Wait -PassThru
    Assert-True ($brokerMcp.ExitCode -eq 0) 'Stable MCP launcher did not accept fixed broker options.'
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
        $brokerCodexPlan = (& (Join-Path $installRoot 'Add-CodexMcp.ps1') -Name 'qicheng-channel-1-broker' -Project 'channel-1' -PythonPath $pythonPath -CodexPath $fakeCodex -BrokerUrl 'http://127.0.0.1:18770' -BrokerTokenFile $brokerTokenFile -BrokerChannelId 'channel-1' | Out-String) | ConvertFrom-Json
        Assert-True ($brokerCodexPlan.status -eq 'not-added' -and $brokerCodexPlan.args -contains '-BrokerUrl' -and $brokerCodexPlan.args -contains '-BrokerChannelId') 'Optional broker Codex plan did not preserve fixed routing.'
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
    Assert-True ($sourceManifest.selectedSourceDirty -eq $build.sourceDirty) 'Build status and source manifest disagree about selected source changes.'
    if (-not $SkipPublicExportRoundTrip) {
        $publicRoot = Join-Path $temporaryRoot 'public-source'
        New-Item -ItemType Directory -Path $publicRoot | Out-Null
        $exportJson = & (Join-Path $productRoot 'Export-PublicSource.ps1') -OutputDirectory $publicRoot | Out-String
        $export = $exportJson | ConvertFrom-Json
        $expectedPublicFiles = 64 + $themeSourceCount
        Assert-True ($export.status -eq 'exported' -and $export.fileCount -eq $expectedPublicFiles) 'Public source export count or status is incorrect.'
        $publicModule = Join-Path $publicRoot 'tools\windows-channels'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicRoot 'LICENSE') -PathType Leaf) 'Public repository LICENSE is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'LICENSE') -PathType Leaf) 'Public module LICENSE is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'product\Build-Package.ps1') -PathType Leaf) 'Exported package builder is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'product\tests\Test-ProductPackage.ps1') -PathType Leaf) 'Exported product tests are missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $publicModule 'tests\HostServiceSafety.Tests.ps1') -PathType Leaf) 'Exported HostService safety tests are missing.'
        foreach ($relative in @('host\lease_client.py','host\broker_client.py','guest\wechat_cli.py','Install-GuestPayloadOffline.ps1','Stage-GuestPayloadDirect.ps1','Switch-GuestPayloadDirect.ps1','tests\test_guest_lease.py','tests\test_host_lease.py','tests\test_broker_client.py','tests\test_wechat_cli.py','tests\ThreeCredentialPayload.Tests.ps1','tests\InstallGuestPayloadOffline.Tests.ps1')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $publicModule $relative) -PathType Leaf) "Exported source is missing: $relative"
        }
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $publicRoot 'LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Public repository LICENSE differs from the module Apache LICENSE.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $publicModule 'LICENSE') -Algorithm SHA256).Hash -eq $licenseHash) 'Public module LICENSE differs from the reviewed Apache LICENSE.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicModule 'evidence'))) 'Untracked evidence entered public source export.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicModule 'docs\pm'))) 'Project memory entered public source export.'
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
    [ordered]@{ status='passed'; packageFiles=$manifest.files.Count; publicSourceRoundTripValidated=(-not $SkipPublicExportRoundTrip); offlinePreflightSimulated=$true; offlineApplyValidated=$false; archive=$build.archive; planValidated=$true; windowsPowerShellInstallerPreflight=$true; windowsPowerShell51ImportValidated=$true; windowsPowerShell51SetupValidated=$true; powerShell7ImportValidated=$true; firstRunSetupValidated=$true; invalidConfigurationRepairValidated=$true; existingConfigurationReuseValidated=$true; workspaceCountOptionsValidated='1..8 without Lite; 1..6 with Lite'; liteCoexistenceLimitValidated=$true; workspaceResourceEstimateValidated=$true; vmCreatedStateRemainsPendingValidated=$true; failedUpgradeRestoreValidated=$true; upgradeProcessBlockValidated=$true; temporaryInstallValidated=$true; configImportValidated=$true; viewerDerivedRoot=$derivedRoot; viewerSelfTestValidated=$true; powerShell7DiagnosisValidated=$true; shortcutsValidated=$true; defaultLaunchHiddenAndManagementShowValidated=$true; autoStartEnabledValidated=$true; autoStartDisabledValidated=$true; uninstallExactStartupLinkValidated=$true; aiConnectorsValidated=2; stableMcpLauncherValidated=$true; codexCliIsolatedFakeValidated=$true; codexEmptyListAddRecorded=$true; codexSameConfigNoOpValidated=$true; codexNameConflictRejected=$true; nativeMcpDiscovered=$false; uninstallPreservesUserData=$true; relativePathRejected=$true; realUserInstallPerformed=$false } | ConvertTo-Json -Depth 4
} finally {
    if ($null -eq $previousLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocalAppData }
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd([char[]]@('\','/'))
    $resolvedTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
    Assert-True ([string]::Equals([IO.Path]::GetDirectoryName($resolvedTemporaryRoot),$resolvedTempParent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTemporaryRoot) -match '^qicheng-product-test-[0-9a-f]{32}$') 'Refusing to remove a test directory outside the expected temporary location.'
    if (Test-Path -LiteralPath $resolvedTemporaryRoot) { Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force }
}
