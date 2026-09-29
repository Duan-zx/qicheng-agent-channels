# Qicheng Lite 0.2.0-alpha.16 — review draft, not a published release

**Release decision: pending DELL first installation.** Do not create a tag, upload an asset, or announce this draft yet. This branch also contains experimental Windows/Task Lease/WeChat source beyond the Lite pilot; those features are not part of the recommended first download.

## Proposed user promise

Give one or two AI browser tasks their own Linux desktop on a Windows PC. Alt+2 opens the first workspace, Alt+3 opens the optional second, and Alt+1 returns to your own desktop. The viewer starts in the tray; you can take control, pause input, or hand a channel to a separately connected AI client. Browser profiles and Downloads persist in separate Docker volumes.

## Proposed first download

- Asset: `Qicheng-Lite-0.2.0-alpha.16.zip` only. Current private pilot asset SHA-256: `137ee3e6d7378bfcfd0763095948c9fbef73ea83edc1421285d34e051da9c728`. Recheck the exact uploaded bytes before citing this hash publicly.
- Download URL: **pending**. Older GitHub Releases do not contain this asset.
- Host: Windows with .NET Framework 4.x and a local Docker Linux engine. The first backend build requires network access. Docker Desktop, AI models, subscriptions and Windows guest licenses are not included.
- Start: extract the ZIP and run `Qicheng-Lite/Install-Qicheng-Lite.cmd`; choose one channel initially. Run “诊断启程轻量工作台” and try Alt+2/Alt+1 before connecting an AI client. The bundled `QUICKSTART.zh-CN.md` covers MCP setup, data locations and downloads; [manual stop/uninstall](UNINSTALL-LITE.md) is in this repository, not the current ZIP.

The source build entry is `tools/agent-channels/product/Build-Package.ps1 -OutputDirectory <new absolute directory> -Version 0.2.0-alpha.16`. On 01, a local rebuild produced a 70-file package and a 45-file source manifest with the same source hashes as the private pilot ZIP. The ZIP hash differs because the newly compiled viewer and generated manifests differ; verify the exact release asset separately.

## Evidence and limits to keep in the public note

- On 01, the private alpha.16 upgrade runs two isolated Lite displays and passes its installed diagnostics. A Checker exercised hotkeys and exit menu in alpha.15 with the same running code; alpha.16 changed build identifiers. This is **not** a DELL first-install result.
- DELL's first Docker build, physical hotkeys, AI client permission flow, resume after host restart, and long-term use remain to be recorded in `docs/PILOT.md` or a sanitized issue. Do not say “works on another machine” until that receipt exists.
- Lite channels isolate browser desktops, but without the optional Task Lease integration, two AI clients writing the **same** channel are not automatically queued. Native Windows applications need separate licensed guest systems; Windows Channels are an experimental advanced path. WeChat project compilation and shared n8n integration are unverified.
- Firefox security and session-recovery notices may be visible. Save unfinished web forms before stopping a channel. Do not hide security notices in promotional screenshots.
- Qicheng's own source is Apache-2.0; third-party components retain their own licenses. No Windows image, VM disk, browser profile, token, account, or third-party desktop application belongs in a release asset.

## Feedback and approval gates

Feedback: [open an issue](https://github.com/Duan-zx/qicheng-agent-channels/issues/new) with the version, OS, installation step, expected/actual result and a redacted screenshot. Do not upload tokens, QR codes, account data, browser profiles or VM disks.

Before publication, complete DELL's independent installation record; verify the final ZIP SHA and install instructions; review generated visual assets and old screenshots still reachable in Git history; confirm the public source snapshot corresponds to the asset; and obtain specific authorization for the GitHub push/tag/Release and announcement.
