Set-StrictMode -Version 2.0

function Resolve-QichengLitePath {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw "$Label 必须是本机绝对路径。" }
    [IO.Path]::GetFullPath($Path)
}

function Get-QichengLiteInstallRoot { Join-Path $env:LOCALAPPDATA 'Programs\QichengLite' }
function Get-QichengLiteDataRoot { Join-Path $env:LOCALAPPDATA 'Qicheng\Lite' }

function Get-QichengLiteSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream=[IO.File]::OpenRead($Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
}

function Set-QichengLitePrivateAcl {
    param([Parameter(Mandatory=$true)][string]$Path,[switch]$File)
    if (-not (Test-Path -LiteralPath $Path)) { throw "ACL 目标不存在：$Path" }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($File) {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true,$false)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','Allow')))
        $item = [IO.FileInfo](Get-Item -LiteralPath $Path)
        if ($PSVersionTable.PSVersion.Major -le 5) { $item.SetAccessControl($acl) } else { [IO.FileSystemAclExtensions]::SetAccessControl($item,$acl) }
    } else {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl',$inherit,'None','Allow')))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl',$inherit,'None','Allow')))
        $item = [IO.DirectoryInfo](Get-Item -LiteralPath $Path)
        if ($PSVersionTable.PSVersion.Major -le 5) { $item.SetAccessControl($acl) } else { [IO.FileSystemAclExtensions]::SetAccessControl($item,$acl) }
    }
}

function Read-QichengLiteInstallRecord {
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $path = Join-Path $InstallRoot '.qicheng-lite-install.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}

function Get-QichengLiteChannelCount {
    param([Parameter(Mandatory=$true)]$Record)
    # Records written before the channel selector always installed both channels.
    if($null -eq $Record.PSObject.Properties['channelCount']){return 2}
    $value=[string]$Record.channelCount
    if($value -cnotmatch '^[12]$'){throw '安装记录中的 channelCount 无效；拒绝猜测频道数。'}
    return [int]$value
}

function Test-QichengLiteTokenValue {
    param([Parameter(Mandatory=$true)][string]$Value)
    $Value -cmatch '^[a-f0-9]{64}$'
}
