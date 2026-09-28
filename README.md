# Qicheng · AI Workspaces

[简体中文](README.zh-CN.md) · Apache-2.0 · Alpha

![Concept diagram of Qicheng workspaces; not a product screenshot](docs/images/workspace-concept.svg)

**Give each computer-using AI task its own workspace.** Run two browser jobs in separate Linux desktops while you keep using your Windows PC. Press **Alt+2** or **Alt+3** to look in; press **Alt+1** to return home. Take control of one channel, hand it back to a connected AI client, or pause it without changing the other channel.

Qicheng has two installation paths. Start with Lite for browser work. Add native Windows channels only when a task needs a Windows desktop application, such as WeChat Developer Tools. Qicheng provides the workspace and controls; bring your own AI client. No model subscription or API key is included.

| Package | Use it for | You need |
| --- | --- | --- |
| **Qicheng Lite** | Isolated browser profiles, web workflows and downloads | Windows host, Docker Desktop with a Linux engine; internet for the first image build |
| **Qicheng Windows Channels** | Native desktop tools in separate Windows guests | Hyper-V capable Windows host, Python 3.12+, and your own licensed Windows guest installations |

The optional **Task Lease** broker lets explicitly connected Codex MCP and n8n jobs queue for the same native channel and run on different channels at once. The local alpha.16 source candidate can also give a configured, short fixed action its own Git worktree and build directory. Lite does not require the broker. It does not automatically intercept other Computer Use, CLI or n8n actions.

**Download status:** [public Releases](https://github.com/Duan-zx/qicheng-agent-channels/releases) currently contain earlier Alpha builds. This candidate branch includes newer source, but matching public installers have not been released. Check a Release's version and package hash before installing; do not assume the latest source is already in a download.

## Try Lite

1. Download a matching Lite Release, verify its hash, extract it and run the installer included in the package. Docker's Linux engine must be available.
2. The viewer stays in the tray. Use **Alt+2 / Alt+3** for the two workspaces and **Alt+1** for your own desktop.
3. Choose **Take control** to use a channel yourself. Choose **Give to AI** before a connected client sends input. Each channel keeps its own browser profile and Downloads volume.
4. Run the installed diagnostics if a channel is unavailable. The package quickstart lists data locations and AI connection steps.

When both editions are installed, Lite keeps Alt+1/2/3 and native Windows channels start at Alt+4. The Windows setup wizard limits its count accordingly. Hotkey conflicts are reported by diagnostics; available keys depend on the installed version.

## What is open source

This repository contains product source, package builders, public documentation and sanitized validation records. Windows Channels and Task Lease use explicit source allowlists and SHA-256 manifests. It does not include private product memory, browser data, tokens, Windows images, guest accounts or third-party commercial applications.

Qicheng's own code is offered under Apache-2.0. Included third-party software keeps its own licenses; see the Lite package's `THIRD-PARTY-NOTICES.md`. Docker Desktop and Windows guest licenses are separate. See [validation and known limits](docs/VALIDATION.md) and [asset provenance](docs/ASSET-PROVENANCE.md). This is an Alpha product: automated tests and synthetic input do not prove every site, login flow or Windows app works. DELL independent installation and real WeChat project compilation remain unverified.
