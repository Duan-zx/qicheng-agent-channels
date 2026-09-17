[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$builder = (Resolve-Path (Join-Path $PSScriptRoot '..\Build-GuestPayload.ps1')).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("qicheng-payload-" + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Set-TestPrivateAcl {
    param([string]$Path)
    $security = Get-Acl -LiteralPath $Path
    $security.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($security.Access)) { [void]$security.RemoveAccessRuleAll($rule) }
    foreach ($sidText in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new($sidText), [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Invoke-Builder {
    param(
        [string]$PythonSource,
        [string]$Output,
        [string]$Uuid,
        [string]$Token,
        [ValidateSet('valid', 'invalid')][string]$Signature = 'valid'
    )

    $harness = Join-Path $testRoot ("harness-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $source = @'
param($Builder, $PythonSource, $Output, $Uuid, $Token, $Signature)
$global:signatureMode = $Signature
function global:Get-AuthenticodeSignature {
    if ($global:signatureMode -eq 'valid') {
        return [pscustomobject]@{
            Status = [System.Management.Automation.SignatureStatus]::Valid
            SignerCertificate = [pscustomobject]@{ Subject = 'CN=Python Software Foundation'; Issuer = 'CN=Trusted Test CA' }
        }
    }
    return [pscustomobject]@{
        Status = [System.Management.Automation.SignatureStatus]::NotSigned
        SignerCertificate = $null
    }
}
& $Builder -EmbeddedPythonDirectory $PythonSource -OutputDirectory $Output -BIOSUUID $Uuid -TokenFile $Token -Compact
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($harness, $source, [System.Text.UTF8Encoding]::new($false))
    $outputText = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness -Builder $builder -PythonSource $PythonSource -Output $Output -Uuid $Uuid -Token $Token -Signature $Signature 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($outputText -join "`n") }
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $pythonSource = Join-Path $testRoot 'python-source'
    [System.IO.Directory]::CreateDirectory($pythonSource) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $pythonSource 'python.exe'), [byte[]]@(77, 90))
    [System.IO.File]::WriteAllText((Join-Path $pythonSource 'python312.zip'), 'stdlib fixture')
    [System.IO.File]::WriteAllText((Join-Path $pythonSource 'LICENSE.txt'), 'Python fixture license')
    [System.IO.File]::WriteAllLines((Join-Path $pythonSource 'python312._pth'), @('python312.zip', '.', '#import site'))
    $tokenFile = Join-Path $testRoot 'pm-generated.token'
    $tokenValue = 'a' * 64
    [System.IO.File]::WriteAllText($tokenFile, $tokenValue)
    Set-TestPrivateAcl $tokenFile
    $uuid = '11111111-2222-4333-8444-555555555555'

    $payload = Join-Path $testRoot 'payload'
    $success = Invoke-Builder -PythonSource $pythonSource -Output $payload -Uuid $uuid -Token $tokenFile
    Assert-True ($success.ExitCode -eq 0) "Valid payload build failed: $($success.Output)"
    Assert-True ($success.Output -notmatch $tokenValue) 'Token value must never appear on stdout.'
    $result = $success.Output | ConvertFrom-Json
    Assert-True ($result.status -eq 'payload-prepared') 'Successful result must report payload-prepared.'
    Assert-True (Test-Path -LiteralPath (Join-Path $payload 'python\python.exe') -PathType Leaf) 'python.exe must be copied.'
    Assert-True (Test-Path -LiteralPath (Join-Path $payload 'python\LICENSE.txt') -PathType Leaf) 'Embedded Python license must be preserved.'
    Assert-True (Test-Path -LiteralPath (Join-Path $payload 'guest\agent.py') -PathType Leaf) 'Guest source must be bundled.'
    Assert-True (Test-Path -LiteralPath (Join-Path $payload 'Start-Channel.cmd') -PathType Leaf) 'Start-Channel.cmd must be generated.'
    Assert-True (Test-Path -LiteralPath (Join-Path $payload 'payload-manifest.json') -PathType Leaf) 'Payload manifest must be generated.'
    Assert-True (([System.IO.File]::ReadAllText((Join-Path $payload '.local\channel.token'))).Trim() -ceq $tokenValue) 'Token must be copied only to the payload .local path.'
    $pth = [System.IO.File]::ReadAllLines((Join-Path $payload 'python\python312._pth'))
    Assert-True ($pth -contains 'python312.zip') 'Existing stdlib entry must be preserved.'
    Assert-True ($pth -contains '.') 'Existing local entry must be preserved.'
    Assert-True ($pth -contains '..') 'Payload root entry must be added.'
    $start = [System.IO.File]::ReadAllText((Join-Path $payload 'Start-Channel.cmd'))
    Assert-True ($start -match '-m guest\.agent') 'Start command must launch guest.agent.'
    Assert-True ($start -match [regex]::Escape($uuid)) 'Start command must bind the supplied BIOS UUID.'
    Assert-True ($start -match '%~dp0\.local\\channel\.token') 'Start command must use the bundled token path.'
    Assert-True ($start -notmatch $tokenValue) 'Start command must not contain the token value.'
    Assert-True ($start -match '>nul 2>&1') 'Start command must suppress raw agent output before printing its fixed exit status.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $payload 'guest\__pycache__'))) 'Cache directories must not be bundled.'
    $manifest = Get-Content -LiteralPath (Join-Path $payload 'payload-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.expectedBiosUuid -eq $uuid) 'Manifest must bind the expected BIOS UUID.'
    Assert-True (@($manifest.files).Count -gt 0) 'Manifest must inventory payload files.'
    Assert-True (@($manifest.files | Where-Object path -eq '.local/channel.token').Count -eq 1) 'Manifest must inventory the token without printing it.'
    $payloadAcl = Get-Acl -LiteralPath $payload
    Assert-True ($payloadAcl.AreAccessRulesProtected) 'Payload root ACL inheritance must be disabled.'
    $allowedSids = @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    $unexpected = @($payloadAcl.Access | Where-Object AccessControlType -eq Allow | Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -notin $allowedSids })
    Assert-True ($unexpected.Count -eq 0) 'Payload ACL must not grant access to broad identities.'

    $zeroOutput = Join-Path $testRoot 'zero-output'
    $zeroUuid = Invoke-Builder -PythonSource $pythonSource -Output $zeroOutput -Uuid ([guid]::Empty.ToString()) -Token $tokenFile
    Assert-True ($zeroUuid.ExitCode -eq 2) 'Zero BIOS UUID must be rejected.'
    Assert-True (-not (Test-Path -LiteralPath $zeroOutput)) 'Zero UUID rejection must occur before output mutation.'

    $badSignatureOutput = Join-Path $testRoot 'bad-signature-output'
    $badSignature = Invoke-Builder -PythonSource $pythonSource -Output $badSignatureOutput -Uuid $uuid -Token $tokenFile -Signature invalid
    Assert-True ($badSignature.ExitCode -eq 2) 'Invalid Python signature must be rejected.'
    Assert-True (-not (Test-Path -LiteralPath $badSignatureOutput)) 'Signature rejection must occur before output mutation.'

    $uppercaseToken = Join-Path $testRoot 'uppercase.token'
    [System.IO.File]::WriteAllText($uppercaseToken, ('A' * 64))
    Set-TestPrivateAcl $uppercaseToken
    $uppercaseOutput = Join-Path $testRoot 'uppercase-output'
    $uppercase = Invoke-Builder -PythonSource $pythonSource -Output $uppercaseOutput -Uuid $uuid -Token $uppercaseToken
    Assert-True ($uppercase.ExitCode -eq 2) 'Uppercase token must be rejected.'
    Assert-True (-not (Test-Path -LiteralPath $uppercaseOutput)) 'Invalid token rejection must occur before output mutation.'

    $overlap = Join-Path $pythonSource 'payload-inside-source'
    $overlapResult = Invoke-Builder -PythonSource $pythonSource -Output $overlap -Uuid $uuid -Token $tokenFile
    Assert-True ($overlapResult.ExitCode -eq 2) 'Source/output overlap must be rejected.'
    Assert-True (-not (Test-Path -LiteralPath $overlap)) 'Overlap rejection must occur before output mutation.'

    $existingOutput = Join-Path $testRoot 'existing-output'
    [System.IO.Directory]::CreateDirectory($existingOutput) | Out-Null
    $sentinel = Join-Path $existingOutput 'sentinel.txt'
    [System.IO.File]::WriteAllText($sentinel, 'keep')
    $existing = Invoke-Builder -PythonSource $pythonSource -Output $existingOutput -Uuid $uuid -Token $tokenFile
    Assert-True ($existing.ExitCode -eq 2) 'Existing output must be rejected.'
    Assert-True (([System.IO.File]::ReadAllText($sentinel)) -eq 'keep') 'Existing output must remain unchanged.'

    $relative = Invoke-Builder -PythonSource $pythonSource -Output 'D:relative-payload' -Uuid $uuid -Token $tokenFile
    Assert-True ($relative.ExitCode -eq 2) 'Drive-relative output must be rejected.'
    $traversalPath = Join-Path $testRoot 'parent\..\traversal-output'
    $traversal = Invoke-Builder -PythonSource $pythonSource -Output $traversalPath -Uuid $uuid -Token $tokenFile
    Assert-True ($traversal.ExitCode -eq 2) 'Traversal output must be rejected.'

    [pscustomobject]@{ passed = 33; failed = 0; guestAgentRuns = 0; vmChanges = 0 } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
