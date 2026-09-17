Set-StrictMode -Version 2.0

function Resolve-QichengLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw "$Label must be a fully qualified local-drive path." }
    if ($Path.Contains('"')) { throw "$Label contains an unsupported quote character." }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-QichengDefaultInstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    Join-Path $env:LOCALAPPDATA 'Programs\QichengWindowsChannels'
}

function Get-QichengDefaultDataRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    Join-Path $env:LOCALAPPDATA 'Qicheng\WindowsChannels'
}

function Get-QichengSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try { return (($algorithm.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $algorithm.Dispose() }
    } finally { $stream.Dispose() }
}

function Resolve-QichengPython {
    param([string]$PythonPath)
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
        $candidates += Resolve-QichengLocalPath -Path $PythonPath -Label 'PythonPath'
    }
    else {
        $py = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($py) {
            try {
                $fromLauncher = (& $py.Source -3.12 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1)
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($fromLauncher)) { $candidates += $fromLauncher.Trim() }
            } catch { }
        }
        $python = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($python) { $candidates += $python.Source }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            $resolved = Resolve-QichengLocalPath -Path $candidate -Label 'PythonPath'
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
            & $resolved -c 'import socket,sys; raise SystemExit(0 if sys.version_info >= (3,12) and hasattr(socket,chr(65)+chr(70)+chr(95)+chr(72)+chr(89)+chr(80)+chr(69)+chr(82)+chr(86)) else 1)' 2>$null
            if ($LASTEXITCODE -eq 0) { return $resolved }
        } catch { }
    }
    throw '未找到支持 AF_HYPERV 的 Python 3.12+。请安装 64 位 Python 3.12 或更高版本，或显式传入 -PythonPath。'
}

function Read-QichengConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $resolved = Resolve-QichengLocalPath -Path $ConfigPath -Label 'ConfigPath'
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "频道配置不存在：$resolved。请先按 QUICKSTART.zh-CN.md 创建 channels.json 和独立 token 文件。"
    }
    $item = Get-Item -LiteralPath $resolved
    if ($item.Length -le 0 -or $item.Length -gt 65536) { throw '频道配置必须为 1..65536 字节。' }
    try { $config = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "频道配置不是有效 JSON：$($_.Exception.Message)" }
    if ($config.schema_version -ne 1 -or $null -eq $config.projects) { throw '频道配置需要 schema_version=1 和 projects 对象。' }
    $names = @($config.projects.PSObject.Properties.Name)
    if ($names.Count -lt 1) { throw '频道配置至少需要一个 project。' }
    $vmIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $biosIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $tokenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) {
        if ($name -notmatch '^[a-z0-9][a-z0-9_-]{0,39}$') { throw "project 名称不安全：$name" }
        $binding = $config.projects.$name
        if ($null -eq $binding -or [string]::IsNullOrWhiteSpace([string]$binding.vm_id) -or [string]::IsNullOrWhiteSpace([string]$binding.bios_uuid) -or [string]::IsNullOrWhiteSpace([string]$binding.token_file)) { throw "project 绑定不完整：$name" }
        try { $vmId = [guid]([string]$binding.vm_id); $biosId = [guid]([string]$binding.bios_uuid) } catch { throw "project VM ID 或 BIOS UUID 无效：$name" }
        if ($vmId -eq [guid]::Empty -or $biosId -eq [guid]::Empty) { throw "project 需要非零 VM ID 和 BIOS UUID：$name" }
        $tokenText = [string]$binding.token_file
        if ([System.IO.Path]::IsPathRooted($tokenText)) { $tokenPath = Resolve-QichengLocalPath -Path $tokenText -Label "token_file:$name" }
        else { $tokenPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $resolved) $tokenText)) }
        if (-not $vmIds.Add($vmId.ToString()) -or -not $biosIds.Add($biosId.ToString()) -or -not $tokenPaths.Add($tokenPath)) { throw '不同 project 不得共享 VM ID、BIOS UUID 或 token 文件。' }
        if ($binding.PSObject.Properties.Name -contains 'vm_name' -and ([string]$binding.vm_name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$')) { throw "vm_name 无效：$name" }
    }
    [pscustomobject]@{ Path = $resolved; Value = $config; ProjectNames = $names }
}

function Get-QichengInstallRecord {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $recordPath = Join-Path $InstallRoot '.qicheng-product-install.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
    Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}

function Get-QichengConfigImportMaterial {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $source = Read-QichengConfig -ConfigPath $ConfigPath
    $projects = [ordered]@{}
    $tokens = [ordered]@{}
    foreach ($name in $source.ProjectNames) {
        $binding = $source.Value.projects.$name
        $tokenText = [string]$binding.token_file
        $tokenSource = if ([System.IO.Path]::IsPathRooted($tokenText)) {
            Resolve-QichengLocalPath -Path $tokenText -Label "token_file:$name"
        } else {
            [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $source.Path) $tokenText))
        }
        if (-not (Test-Path -LiteralPath $tokenSource -PathType Leaf)) { throw "project 的 token 文件不存在：$name" }
        $tokenItem = Get-Item -LiteralPath $tokenSource
        if ($tokenItem.Length -le 0 -or $tokenItem.Length -gt 256) { throw "project 的 token 文件大小无效：$name" }
        $tokenValue = (Get-Content -LiteralPath $tokenSource -Raw -Encoding ASCII).Trim()
        if ($tokenValue -notmatch '^[a-f0-9]{64}$') { throw "project 的 token 格式无效：$name" }
        $normalized = [ordered]@{ vm_id=[guid]([string]$binding.vm_id).ToString(); bios_uuid=[guid]([string]$binding.bios_uuid).ToString(); token_file=('tokens/' + $name + '.token') }
        if ($binding.PSObject.Properties.Name -contains 'vm_name') { $normalized.vm_name = [string]$binding.vm_name }
        $projects[$name] = $normalized
        $tokens[$name] = $tokenValue
    }
    [pscustomobject]@{ SourcePath=$source.Path; Config=[ordered]@{ schema_version=1; projects=$projects }; Tokens=$tokens }
}

function Set-QichengPrivateDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) { throw 'Cannot resolve the current Windows user SID.' }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity.User, 'FullControl', $inheritance, $propagation, $allow)))
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, 'FullControl', $inheritance, $propagation, $allow)))
    $directory = New-Object System.IO.DirectoryInfo($Path)
    if ($directory.PSObject.Methods.Name -contains 'SetAccessControl') {
        # Windows PowerShell 5.1 / .NET Framework instance API.
        $directory.SetAccessControl($acl)
    }
    else {
        # PowerShell 7 / .NET uses the access-control extension assembly.
        [System.IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
    }
}

function Import-QichengConfig {
    param(
        [Parameter(Mandatory = $true)]$Material,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [switch]$Replace
    )
    $root = Resolve-QichengLocalPath -Path $DataRoot -Label 'DataRoot'
    $destinationConfig = Join-Path $root 'channels.json'
    if ((Test-Path -LiteralPath $destinationConfig) -and -not $Replace) { throw 'DataRoot already contains channels.json; use -ReplaceConfig only after reviewing the replacement.' }
    $tokensRoot = Join-Path $root 'tokens'
    New-Item -ItemType Directory -Path $tokensRoot -Force | Out-Null
    Set-QichengPrivateDirectoryAcl -Path $root
    Set-QichengPrivateDirectoryAcl -Path $tokensRoot
    foreach ($name in $Material.Tokens.Keys) {
        $destinationToken = Join-Path $tokensRoot ($name + '.token')
        if ((Test-Path -LiteralPath $destinationToken) -and -not $Replace) { throw "DataRoot already contains a token for project: $name" }
        Set-Content -LiteralPath $destinationToken -Value ([string]$Material.Tokens[$name]) -Encoding ASCII -NoNewline
    }
    $temporaryConfig = Join-Path $root ('.channels.import.' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $Material.Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryConfig -Encoding UTF8
        if (Test-Path -LiteralPath $destinationConfig) { Remove-Item -LiteralPath $destinationConfig -Force }
        Move-Item -LiteralPath $temporaryConfig -Destination $destinationConfig
    } finally {
        if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Force }
    }
    [pscustomobject]@{ ConfigPath=$destinationConfig; Projects=@($Material.Tokens.Keys); ImportedFrom=$Material.SourcePath }
}
