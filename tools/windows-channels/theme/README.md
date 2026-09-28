# AI workspace appearance

`ai-space-v2.png` is the current Qicheng AI workspace wallpaper. The original `ai-space.png` remains for compatibility with earlier packages. The viewer displays the workspace number and control status separately so they remain readable when an application covers the desktop.

Run inside the signed-in Windows guest to apply the wallpaper for that user:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Set-WorkspaceTheme.ps1 -WorkspaceNumber 1 -Apply
```

Without `-Apply`, the script only reports its plan. It rejects physical host PCs and does not modify login, privacy or security settings. Running through a remote noninteractive session may require signing out and back in before the visible desktop refreshes.

Artwork created for this project using the built-in image generation tool. The v2 prompt specifies a restrained midnight-navy architectural space with translucent planes, thin trajectories, mint light and one coral accent; the left quarter stays quiet for desktop icons, with no text, logos, interface controls, planets, or glowing orb. These project assets are distributed under Apache-2.0.
