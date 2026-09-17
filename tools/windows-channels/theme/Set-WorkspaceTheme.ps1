[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1,8)][int]$WorkspaceNumber = 1,
    [string]$WallpaperPath = (Join-Path $PSScriptRoot 'ai-space.png'),
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $WallpaperPath).Path
$machine = Get-CimInstance Win32_ComputerSystem
if ($machine.Manufacturer -ne 'Microsoft Corporation' -or $machine.Model -ne 'Virtual Machine') {
    throw 'Run this theme installer inside the Windows workspace, not on the host PC.'
}
$destination = Join-Path $env:LOCALAPPDATA 'Qicheng\Workspace\ai-space.png'
$result = [ordered]@{
    status = 'planned'
    workspaceNumber = $WorkspaceNumber
    wallpaper = $destination
    scope = 'current-guest-user'
}
if ($Apply -and $PSCmdlet.ShouldProcess('Current Windows guest user', 'Apply Qicheng AI workspace wallpaper')) {
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    if (-not $source.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    # Fill the screen without stretching the artwork. The viewer shows workspace identity.
    Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
    if (-not ('Qicheng.WorkspaceWallpaper' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace Qicheng {
    public static class WorkspaceWallpaper {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SystemParametersInfo(uint action, uint parameter, string value, uint flags);
    }
}
'@
    }
    if (-not [Qicheng.WorkspaceWallpaper]::SystemParametersInfo(20, 0, $destination, 3)) {
        throw "Windows rejected wallpaper update: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $actual = (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name Wallpaper).Wallpaper
    if (-not $actual.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Wallpaper setting could not be verified.'
    }
    $result.status = 'applied'
}
$result | ConvertTo-Json -Compress
