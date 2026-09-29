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

function Resolve-QichengLiteRegularFile {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Label)
    $resolved=Resolve-QichengLitePath -Path $Path -Label $Label
    if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label 文件不存在。"}
    $cursor=$resolved
    while($cursor){
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "$Label 路径含重解析点；拒绝使用。"}
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor){break}
        $cursor=$parent
    }
    return $resolved
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

function Test-QichengLiteDesktopState {
    param([Parameter(Mandatory=$true)][ValidateSet('firefox','wechat')][string]$DesktopApp,[Parameter(Mandatory=$true)]$State)
    if($DesktopApp -eq 'firefox'){return $true}
    if(-not $State.PSObject.Properties['desktop_app'] -or -not $State.PSObject.Properties['gui_alive']){return $false}
    return ([string]$State.desktop_app -ceq 'wechat' -and $State.gui_alive -eq $true)
}

function Test-QichengLiteInstalledPackage {
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $issues=New-Object 'System.Collections.Generic.List[string]'
    $version=$null
    try {
        $root=Resolve-QichengLitePath -Path $InstallRoot -Label 'InstallRoot'
        $manifest=Get-Content -LiteralPath (Join-Path $root 'package-manifest.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        $record=Read-QichengLiteInstallRecord -InstallRoot $root
        if($manifest.schemaVersion -ne 1 -or $manifest.product -cne 'Qicheng Lite' -or -not $record -or $record.product -cne 'Qicheng Lite'){throw '安装身份或清单无效'}
        $version=[string]$manifest.version
        if([string]::IsNullOrWhiteSpace($version) -or [string]$record.version -cne $version){$issues.Add('安装记录与包版本不一致')}
        $seen=@{}
        $files=@($manifest.files)
        if($files.Count -eq 0){throw '包文件清单为空'}
        foreach($file in $files){
            $relative=[string]$file.path
            if($relative -cnotmatch '^[A-Za-z0-9._/-]+$' -or $relative -match '(^|/)\.\.(/|$)' -or $relative.StartsWith('/') -or $relative.Contains('//') -or $seen.ContainsKey($relative)){throw '包文件路径或重复项无效'}
            $seen[$relative]=$true
            $path=Join-Path $root $relative
            if(-not(Test-Path -LiteralPath $path -PathType Leaf)){$issues.Add("文件缺失：$relative");continue}
            if([string]$file.sha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-QichengLiteSha256 -Path $path) -cne [string]$file.sha256){$issues.Add("文件与版本清单不符：$relative")}
        }
    } catch { $issues.Add($_.Exception.Message) }
    [pscustomobject]@{valid=($issues.Count -eq 0);version=$version;issues=$issues.ToArray()}
}
