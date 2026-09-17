# AI workspace appearance

`ai-space.png` is the Qicheng AI workspace wallpaper. The viewer displays the workspace number and control status separately so they remain readable when an application covers the desktop.

Run inside the signed-in Windows guest to apply the wallpaper for that user:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Set-WorkspaceTheme.ps1 -WorkspaceNumber 1 -Apply
```

Without `-Apply`, the script only reports its plan. It rejects physical host PCs and does not modify login, privacy or security settings. Running through a remote noninteractive session may require signing out and back in before the visible desktop refreshes.

Artwork created for this project using the built-in image generation tool. Prompt: premium calm AI workspace wallpaper; translucent orbital ribbons and sparse connected light points in midnight blue space; cyan and violet intelligence core on the right, quiet left margin for icons; no text, logo or fake UI. This asset is distributed with the project's Apache-2.0 license.
