$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('TaskLeaseTest-' + [guid]::NewGuid().ToString('N'))))
$tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
if (-not $root.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary test root.' }
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $package=Join-Path $root 'package'
    & (Join-Path $source 'product\Build-Package.ps1') -OutputDirectory $package | Out-Null
    if (-not (Test-Path -LiteralPath "$package.zip" -PathType Leaf)) { throw 'Zip missing.' }
    $extracted=Join-Path $root 'extracted'
    Expand-Archive -LiteralPath "$package.zip" -DestinationPath $extracted
    if (-not (Test-Path -LiteralPath (Join-Path $extracted 'LICENSE') -PathType Leaf)) { throw 'Apache license missing.' }
    $install=Join-Path $root 'installed'
    $data=Join-Path $root 'private-data'
    $installer=Join-Path $extracted 'product\runtime\Install-TaskLease.ps1'
    $plan=(& $installer -PackageRoot $extracted -InstallRoot $install -DataRoot $data | ConvertFrom-Json)
    if ($plan.status -ne 'install' -or (Test-Path -LiteralPath $install)) { throw 'Dry run changed host or gave wrong plan.' }
    $result=(& $installer -PackageRoot $extracted -InstallRoot $install -DataRoot $data -Apply | ConvertFrom-Json)
    if ($result.status -ne 'installed' -or -not (Test-Path -LiteralPath (Join-Path $data 'broker.token'))) { throw 'Install failed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'attempt_workspace.py') -PathType Leaf)) { throw 'Packaged attempt workspace helper is missing.' }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'bounded_action.py') -PathType Leaf)) { throw 'Packaged bounded action runner is missing.' }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'reconcile_action_dirty.py') -PathType Leaf)) { throw 'Packaged action reconciliation tool is missing.' }
    if (Test-Path -LiteralPath (Join-Path $install 'broker.token')) { throw 'Token entered install tree.' }
    $autostart=Join-Path $install 'product\runtime\Install-TaskLeaseAutostart.ps1'
    $autostartRejected=$false
    try { & $autostart -InstallRoot $install | Out-Null } catch { $autostartRejected=($_.Exception.Message -match 'config.json is missing') }
    if (-not $autostartRejected) { throw 'Autostart accepted missing private config.' }
    Set-Content -LiteralPath (Join-Path $data 'config.json') -Value '{"channels":[]}' -Encoding ASCII
    $existingTask=Get-ScheduledTask -TaskPath '\' -TaskName 'QichengTaskLease' -ErrorAction SilentlyContinue
    if ($existingTask) {
        $duplicateRejected=$false
        try { & $autostart -InstallRoot $install -Port 18771 | Out-Null } catch { $duplicateRejected=($_.Exception.Message -match 'already exists') }
        if (-not $duplicateRejected) { throw 'Autostart preview did not protect the existing task.' }
    } else {
        $autostartPlan=(& $autostart -InstallRoot $install -Port 18771 | ConvertFrom-Json)
        if ($autostartPlan.status -ne 'autostart-plan' -or $autostartPlan.startsNow -or $autostartPlan.port -ne 18771 -or
            (Get-ScheduledTask -TaskPath '\' -TaskName 'QichengTaskLease' -ErrorAction SilentlyContinue)) { throw 'Autostart preview changed the host or gave wrong plan.' }
    }
    $wrapperFailed=$false
    try { & (Join-Path $install 'product\runtime\Run-TaskLeaseAutostart.ps1') -InstallRoot $install -Port 18771 | Out-Null }
    catch { $wrapperFailed=$true }
    $autostartLog=Join-Path $data 'broker-autostart.log'
    if (-not $wrapperFailed -or -not (Test-Path -LiteralPath $autostartLog) -or
        (Get-Content -LiteralPath $autostartLog -Raw) -notmatch 'at least one channel is required') { throw ('Autostart wrapper did not record the startup failure privately: ' + (Get-Content -LiteralPath $autostartLog -Raw)) }
    Remove-Item -LiteralPath (Join-Path $data 'config.json')
    $diagnosis=(& (Join-Path $install 'product\runtime\Diagnose-TaskLease.ps1') -InstallRoot $install | ConvertFrom-Json)
    if (-not $diagnosis.installed -or -not $diagnosis.packageOk -or -not $diagnosis.pythonOk -or $diagnosis.ready) { throw "Diagnosis mismatch: $($diagnosis | ConvertTo-Json -Compress)" }
    $pythonTest=@'
import json
import sys
from pathlib import Path

install, data = map(Path, sys.argv[1:3])
sys.path.insert(0, str(install))
from broker import Broker
from guest_bridge import windows_host

read_config, LeaseClient = windows_host()
assert Path(sys.modules[LeaseClient.__module__].__file__).resolve() == (install / 'windows-channels/host/lease_client.py').resolve()
project = data / 'project'
project.mkdir()
channel_token = data / 'channel.token'
guest_token = data / 'guest-broker.token'
channel_token.write_text('1' * 64, encoding='ascii')
guest_token.write_text('2' * 64, encoding='ascii')
host_config = data / 'host.json'
host_config.write_text(json.dumps({'schema_version': 1, 'projects': {'guest-a': {
    'vm_id': '11111111-1111-4111-8111-111111111111',
    'bios_uuid': '22222222-2222-4222-8222-222222222222',
    'token_file': str(channel_token)}}}), encoding='utf-8')
binding = read_config(host_config)['guest-a']
assert isinstance(LeaseClient(binding, guest_token), LeaseClient)
channel = {'channel_id': 'channel-a', 'endpoint_id': 'guest-a',
           'tool_id': 'windows-guest', 'project_id': 'project-a',
           'project_path': str(project)}
config = data / 'test-config.json'
config.write_text(json.dumps({'channels': [dict(channel, guest={
    'host_config_path': str(host_config), 'project': 'guest-a',
    'broker_token_file': str(guest_token)})]}), encoding='utf-8')
broker = Broker(config_path=config, credential_path=data / 'broker.token',
                db_path=data / 'guest-leases.db')
assert broker.guest_client_factory is LeaseClient
assert broker.channels['channel-a'].guest['binding']['vm_id'] == binding['vm_id']
config.write_text(json.dumps({'channels': [channel]}), encoding='utf-8')
legacy = Broker(config_path=config, credential_path=data / 'broker.token',
                db_path=data / 'legacy-leases.db')
assert legacy.guest_client_factory is None
assert legacy.channels['channel-a'].guest is None
print('PASS: installed guest binding, LeaseClient construction, legacy no-guest config')
'@
    & $result.python -B -c $pythonTest $install $data
    if ($LASTEXITCODE -ne 0) { throw 'Installed Python guest bridge test failed.' }
    Copy-Item -LiteralPath (Join-Path $extracted 'windows-channels') -Destination $root -Recurse
    $installedGuestModule=Join-Path $install 'windows-channels\host\lease_client.py'
    Remove-Item -LiteralPath $installedGuestModule
    $noFallback=@'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from guest_bridge import windows_host
try:
    windows_host()
except RuntimeError:
    print('PASS: incomplete installed package refused sibling source fallback')
else:
    raise AssertionError('Installed package fell back to sibling source')
'@
    & $result.python -B -c $noFallback $install
    if ($LASTEXITCODE -ne 0) { throw 'Installed bridge accepted source fallback.' }
    Copy-Item -LiteralPath (Join-Path $extracted 'windows-channels\host\lease_client.py') -Destination $installedGuestModule
    $startRejected=$false
    try { & (Join-Path $install 'product\runtime\Start-TaskLease.ps1') -InstallRoot $install | Out-Null } catch { $startRejected=$true }
    if (-not $startRejected) { throw 'Start accepted missing private config.' }
    Add-Content -LiteralPath $installedGuestModule -Value 'tamper'
    $installedTamperRejected=$false
    try { & (Join-Path $install 'product\runtime\Start-TaskLease.ps1') -InstallRoot $install | Out-Null }
    catch { $installedTamperRejected=($_.Exception.Message -match 'Package hash mismatch') }
    if (-not $installedTamperRejected) { throw 'Start did not reject installed guest module tampering.' }
    Copy-Item -LiteralPath (Join-Path $extracted 'windows-channels\host\lease_client.py') -Destination $installedGuestModule -Force
    $tampered=Join-Path $extracted 'windows-channels\host\lease_client.py'
    Add-Content -LiteralPath $tampered -Value 'tamper'
    $rejected=$false
    try { & $installer -PackageRoot $extracted -InstallRoot (Join-Path $root 'other') -DataRoot $data | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'Tampered package was accepted.' }
    $uninstaller=Join-Path $install 'product\runtime\Uninstall-TaskLease.ps1'
    $uninstallPlan=(& $uninstaller -InstallRoot $install | ConvertFrom-Json)
    if ($uninstallPlan.status -ne 'uninstall-plan' -or -not (Test-Path -LiteralPath $install)) { throw 'Uninstall preview changed host.' }
    $uninstalled=(& $uninstaller -InstallRoot $install -Apply | ConvertFrom-Json)
    if ($uninstalled.status -ne 'uninstalled' -or (Test-Path -LiteralPath $install) -or -not (Test-Path -LiteralPath (Join-Path $data 'broker.token'))) { throw 'Uninstall or data preservation failed.' }
    Write-Output 'PASS: package, zip, install preview/apply, private credential, autostart preview/config gate/private failure log, diagnose, packaged guest bridge, legacy config, no source fallback, missing-config refusal, installed and extracted module tamper rejection, uninstall preview/apply'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
