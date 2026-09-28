[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$ExpectedVMId,
    [Parameter(Mandatory = $true)][string]$ExpectedBiosUuid,
    [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
    [switch]$AcceptSysinternalsEula,
    [switch]$Apply,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$session = $null
$hostTemp = $null
$guestTemp = $null
$stage = 'input'

function Write-Result {
    param([System.Collections.IDictionary]$Value, [int]$Code)
    if ($Compact) { $Value | ConvertTo-Json -Depth 6 -Compress }
    else { $Value | ConvertTo-Json -Depth 6 }
    exit $Code
}

try {
    if ($VMName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$') { throw 'invalid VM name' }
    $vmId = [guid]::Empty
    $bios = [guid]::Empty
    if (-not [guid]::TryParse($ExpectedVMId, [ref]$vmId) -or $vmId -eq [guid]::Empty) { throw 'invalid VM ID' }
    if (-not [guid]::TryParse($ExpectedBiosUuid, [ref]$bios) -or $bios -eq [guid]::Empty) { throw 'invalid BIOS UUID' }

    $stage = 'host-identity'
    $matches = @(Get-VM -ErrorAction Stop | Where-Object Name -ieq $VMName)
    if ($matches.Count -ne 1) { throw 'VM name did not resolve uniquely' }
    $vm = $matches[0]
    if ([guid]$vm.Id -ne $vmId -or $vm.State.ToString() -ne 'Running') { throw 'VM ID or state mismatch' }
    $rows = @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData -Filter "VirtualSystemIdentifier = '$($vm.Id)'" -ErrorAction Stop |
        Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' -and $_.BIOSGUID })
    if ($rows.Count -ne 1 -or [guid]$rows[0].BIOSGUID -ne $bios) { throw 'host BIOS UUID mismatch' }

    $plan = [ordered]@{
        schemaVersion = 1; status = 'not-configured-by-this-run'; mode = 'plan'; applyRequested = [bool]$Apply
        vmName = $vm.Name; vmId = $vm.Id.ToString(); biosUuid = $bios.ToString('D')
        transport = 'PowerShell Direct'; source = 'https://download.sysinternals.com/files/AutoLogon.zip'
        credentialStoredByScript = $false; guestConfigurationChanged = $false
        eulaAcceptanceRequiredForApply = $true; eulaAcceptanceRequested = [bool]$AcceptSysinternalsEula
    }
    if (-not $Apply) { Write-Result $plan 0 }
    if (-not $PSCmdlet.ShouldProcess("$($vm.Name) [$($vm.Id)]", 'Configure optional Windows console autologon with signed Microsoft Sysinternals Autologon')) {
        $plan.mode = 'what-if-or-declined'
        Write-Result $plan 0
    }
    $stage = 'eula-authorization'
    if (-not $AcceptSysinternalsEula) { throw 'Sysinternals EULA acceptance is required for apply' }

    $stage = 'guest-identity'
    $session = New-PSSession -VMId $vm.Id -Credential $Credential -ErrorAction Stop
    $identity = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $computer = Get-CimInstance Win32_ComputerSystem
        $product = Get-CimInstance Win32_ComputerSystemProduct
        $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($wid)
        [pscustomobject]@{
            model = $computer.Model; manufacturer = $computer.Manufacturer; biosUuid = $product.UUID
            computerName = $env:COMPUTERNAME; identityName = $wid.Name; sid = $wid.User.Value
            elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
    }
    if ($identity.model -ne 'Virtual Machine' -or $identity.manufacturer -notmatch '(?i)Microsoft' -or [guid]$identity.biosUuid -ne $bios) { throw 'guest VM identity mismatch' }
    if (-not $identity.elevated -or $identity.sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'guest account must be a local administrator' }
    $accountParts = $identity.identityName -split '\\', 2
    if ($accountParts.Count -ne 2 -or $accountParts[0] -ine $identity.computerName -or $accountParts[1] -notmatch '^[A-Za-z0-9_.-]{1,64}$') { throw 'guest identity is not a local account' }

    $alreadyEnabled = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        [string]$key.AutoAdminLogon -eq '1'
    }
    if ($alreadyEnabled) { throw 'guest autologon is already enabled; refusing to replace it' }

    $stage = 'download-and-signature'
    $hostTemp = Join-Path ([IO.Path]::GetTempPath()) ('qicheng-autologon-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($hostTemp) | Out-Null
    $archivePath = Join-Path $hostTemp 'AutoLogon.zip'
    $exePath = Join-Path $hostTemp 'Autologon64.exe'
    Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/AutoLogon.zip' -OutFile $archivePath -UseBasicParsing -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entries = @($archive.Entries | Where-Object FullName -ceq 'Autologon64.exe')
        if ($entries.Count -ne 1 -or $entries[0].Length -lt 10000 -or $entries[0].Length -gt 5000000) { throw 'expected x64 executable missing or oversized' }
        $inputStream = $entries[0].Open()
        $outputStream = [IO.File]::Create($exePath)
        try { $inputStream.CopyTo($outputStream) }
        finally { $outputStream.Dispose(); $inputStream.Dispose() }
    }
    finally { $archive.Dispose() }
    $signature = Get-AuthenticodeSignature -LiteralPath $exePath
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') { throw 'Microsoft Authenticode validation failed' }
    $exeHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash

    $stage = 'guest-execution'
    $guestTemp = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('qicheng-autologon-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($path) | Out-Null
        $path
    }
    Copy-Item -LiteralPath $exePath -Destination (Join-Path $guestTemp 'Autologon64.exe') -ToSession $session -ErrorAction Stop
    $configured = Invoke-Command -Session $session -ArgumentList $guestTemp,$exeHash,$Credential,$accountParts[1],$identity.computerName -ErrorAction Stop -ScriptBlock {
        param($directory,$expectedHash,$guestCredential,$username,$domain)
        $ErrorActionPreference = 'Stop'
        $exe = Join-Path $directory 'Autologon64.exe'
        if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -cne $expectedHash) { throw 'guest executable hash mismatch' }
        $sig = Get-AuthenticodeSignature -LiteralPath $exe
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') { throw 'guest Authenticode validation failed' }
        # Autologon documents three CLI arguments. The password is transiently visible to guest administrators
        # in the process command line; it is never written to a script file or returned to the caller.
        function Quote-Argument([string]$value) {
            $value = $value -replace '(\\*)"', '$1$1\"'
            $value = $value -replace '(\\+)$', '$1$1'
            '"' + $value + '"'
        }
        $ptr = [IntPtr]::Zero
        $password = $null
        try {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($guestCredential.Password)
            $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            $arguments = ((Quote-Argument $username),(Quote-Argument $domain),(Quote-Argument $password)) -join ' '
            $eulaKey = 'HKCU:\Software\Sysinternals\Autologon'
            New-Item -Path $eulaKey -Force | Out-Null
            New-ItemProperty -Path $eulaKey -Name EulaAccepted -PropertyType DWord -Value 1 -Force | Out-Null
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $exe
            $start.Arguments = $arguments
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Autologon timed out' }
                if ($process.ExitCode -ne 0) { throw 'Autologon returned a nonzero exit code' }
            }
            finally { $process.Dispose() }
        }
        finally {
            if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
            $password = $null
            $arguments = $null
        }
        $winlogon = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        if ([string]$winlogon.AutoAdminLogon -ne '1' -or $winlogon.DefaultUserName -ine $username -or $winlogon.DefaultDomainName -ine $domain) { throw 'Winlogon autologon settings could not be verified' }
        if ($winlogon.PSObject.Properties.Name -contains 'DefaultPassword') { throw 'plaintext Winlogon password value detected' }
        $true
    }
    if (-not $configured) { throw 'guest configuration was not verified' }
    Write-Result ([ordered]@{
        schemaVersion = 1; status = 'configured-reboot-unverified'; vmName = $vm.Name
        vmId = $vm.Id.ToString(); biosUuid = $bios.ToString('D'); source = 'Microsoft Sysinternals'
        signatureVerifiedOnHostAndGuest = $true; guestConfigurationChanged = $true
        credentialStoredByScript = $false; rebootPerformed = $false; consoleLogonVerified = $false
    }) 0
}
catch {
    # Do not serialize exception text: native process errors may include its command line.
    Write-Result ([ordered]@{
        schemaVersion = 1; status = 'failed-or-unverified'; failureStage = $stage
        guestConfigurationMayHaveChanged = ($stage -eq 'guest-execution')
        credentialReported = $false; rebootPerformed = $false
    }) 2
}
finally {
    if ($session -and $guestTemp) {
        try { Invoke-Command -Session $session -ArgumentList $guestTemp -ScriptBlock { param($path) Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    if ($hostTemp -and (Test-Path -LiteralPath $hostTemp)) { Remove-Item -LiteralPath $hostTemp -Recurse -Force -ErrorAction SilentlyContinue }
}
