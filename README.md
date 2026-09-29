# Qicheng · AI Workspaces

[简体中文](README.zh-CN.md) · Apache-2.0 · Alpha

![Concept diagram of Qicheng workspaces; not a product screenshot](docs/images/workspace-concept.svg)

**Give each computer-using AI task its own workspace.** Run one or two browser or Linux WeChat Developer Tools jobs in separate Linux desktops while you keep using your Windows PC. Press **Alt+2** for the first channel, **Alt+3** when a second is enabled, and **Alt+1** to return home. New channels start ready for a connected AI client; take control or pause either channel at any time.

Qicheng has two installation paths. Start with Lite for browser work or the community Linux port of WeChat Developer Tools. Add native Windows channels when a task requires an application that works only on Windows. Qicheng provides the workspace and controls; bring your own AI client. No model subscription or API key is included.

| Package | Use it for | You need |
| --- | --- | --- |
| **Qicheng Lite** | Isolated browser profiles or the optional community Linux WeChat Developer Tools, with separate downloads | Windows host, Docker Desktop with a Linux engine; internet for the first image build |
| **Qicheng Windows Channels** | Native desktop tools in separate Windows guests | Hyper-V capable Windows host, Python 3.12+, and your own licensed Windows guest installations |

The optional **Task Lease** broker lets explicitly connected Codex MCP and n8n jobs coordinate access to a channel. It can give a configured, short fixed action its own Git worktree and build directory; `/v1/run` owns one such action through acquire, execution, and release. n8n can use immediate `409 busy` responses by default, or opt into bounded queueing with a local execution-status check: in isolated n8n 2.39.6 CLI tests, a canceled queued run was withdrawn before the channel became free, while a live run proceeded. The local alpha.24 source candidate adds an offline maintenance gate that blocks new leases and actions during a controlled upgrade; it has passed isolated package tests but is not running on the 01 host. This is an explicit integration for one action, with a remaining stop-versus-start race; it does not automatically intercept other Computer Use, CLI, or n8n actions. Lite can run on its own or join the broker through an explicit connection.

**Download status:** [public Releases](https://github.com/Duan-zx/qicheng-agent-channels/releases) currently contain earlier Alpha builds. This candidate branch includes newer source, but matching public installers have not been released. Check a Release's version and package hash before installing; do not assume the latest source is already in a download.

## Try Lite

1. Download a matching Lite Release, verify its hash, extract it and run the installer included in the package. Docker's Linux engine must be available.
2. The private alpha.20 candidate lets first installation choose one or two Lite channels; one is the default. The viewer stays in the tray. Use **Alt+2** for channel one, **Alt+3** when channel two is enabled, and **Alt+1** for your own desktop. DELL first installation remains untested.
3. A new channel starts in AI mode. Choose **Take control** or **Pause** to stop AI input immediately; **Give to AI** restores it. The chosen mode survives a container restart in that channel's own data volume.
4. Run the installed diagnostics if a channel is unavailable. The package quickstart lists data locations and AI connection steps.

To stop the pilot and keep your channel data, follow the [manual uninstall and data guide](docs/UNINSTALL-LITE.md). The current candidate has no one-click uninstaller.

The 01 host runs two private Linux WeChat channels. Two independent Codex/MCP sessions each completed four clicks under a separate broker lease; the WeChat CLI reached each channel's enabled local service port and returned `login:false`. After a reversible alpha.20 backend image patch, both channels restarted in AI mode without another handoff and retained their CLI settings. The installed package record is still alpha.18, so this does not prove a standard alpha.20 upgrade. No matching public alpha.20 installer has been released.

The explicit offline upgrade option checks the local Linux engine, installed backend files, Compose ownership, persistent volumes and image content before reusing an existing image. The default installer still builds a new image. The 01 host completed a PowerShell 5.1 in-place upgrade using the verified local image; this does not cover first installation or prove a fresh Dockerfile build on DELL. See the package quickstart for the preview and apply commands. This version has not been published as a Release.

The Viewer has a visible overflow menu on both the expanded and compact bars, including **Exit and pause input**. Earlier real-window checks covered the menu and hotkeys; high-DPI and keyboard-only use still need separate acceptance.

When both editions are installed, Lite uses Alt+1/2 and optionally Alt+3; native Windows channels start at Alt+4. The Windows setup wizard limits its count accordingly. Hotkey conflicts are reported by diagnostics; available keys depend on the installed version.

## What is open source

This repository contains product source, package builders, public documentation and sanitized validation records. Windows Channels and Task Lease use explicit source allowlists and SHA-256 manifests. It does not include private product memory, browser data, tokens, Windows images, guest accounts or third-party commercial applications.

Qicheng's own code is offered under Apache-2.0. Included third-party software keeps its own licenses; see the Lite package's `THIRD-PARTY-NOTICES.md`. Docker Desktop and Windows guest licenses are separate. See [validation and known limits](docs/VALIDATION.md) and [asset provenance](docs/ASSET-PROVENANCE.md). This is an Alpha product: automated tests and synthetic input do not prove every site, login flow or Windows app works. DELL independent installation and real WeChat project compilation remain unverified.
