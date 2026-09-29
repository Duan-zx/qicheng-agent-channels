# Agent Channel

[简体中文](README.zh-CN.md) · [Install guide](docs/INSTALL.zh-CN.md) · [Validation](docs/VALIDATION.md) · [Apache-2.0](LICENSE)

![Concept diagram of separate AI channels; not a product screenshot](docs/images/workspace-concept.svg)

**One AI task, one Linux channel. Keep your Windows desktop for yourself.** Agent Channel gives each task a separate Linux desktop, browser profile, and persistent data volume. Its viewer lets you watch a channel, take control, or pause AI input. The MCP bridge addresses the selected channel rather than the Windows host desktop.

Use **Alt+2** for channel one, **Alt+3** for channel two, and **Alt+1** to return to the host. A new channel is ready for a connected AI client; the viewer shows whether AI input is allowed, not whether a task is actually running. The default Lite connection assigns one task to each channel.

## Try Lite

The [Alpha 23 r2 trial ZIP](downloads/Agent-Channel-Windows-Linux-alpha23-r2.zip) provides two Linux channels on a **Windows host with Docker Desktop's Linux engine**. Follow the [installation guide](docs/INSTALL.zh-CN.md) and verify the ZIP's SHA-256 there before installing. The first image build needs network access. MCP needs **Python 3.10+** and your own AI client; Agent Channel includes no model, subscription, or API key.

The trial package contains a compact Agent Channel Skill, a Codex registration command that previews its changes before writing the current user's MCP configuration, and a [keep-data uninstall path](docs/UNINSTALL-LITE.md). The Skill is guidance; it does not register MCP or grant tool permissions. The optional Linux WeChat Developer Tools image is built locally and is subject to that software's own terms.

The [public Releases](https://github.com/Duan-zx/qicheng-agent-channels/releases) contain earlier Alpha builds. This trial ZIP is linked from the repository, not yet a matching public Release. Developers can use the [Lite package builder](tools/agent-channels/product/Build-Package.ps1), [quickstart](tools/agent-channels/product/QUICKSTART.zh-CN.md), and [AI setup guide](docs/AI-SETUP.md).

## Other components

[Windows Channels](tools/windows-channels/README.md) for native Windows guest applications and [Task Lease](tools/task-lease/README.md) for explicitly connected task coordination are separate experimental components. They require their own setup and validation. Lite does not automatically route multiple tasks through Task Lease.

Development-machine checks covered two independent Linux channels, AI text input and clicks, separate saved values, viewer hotkeys and per-channel pause/takeover, and a scaled-screen click. A bounded host-focus sample saw no switch at its sampling points; it cannot rule out shorter switches. Independent first installation and reboot on another Windows PC, other physical DPI or multi-monitor setups, and compilation of a legitimate WeChat project remain unverified. See [validation and limits](docs/VALIDATION.md).

This repository contains Agent Channel source, builders, documentation, and sanitized validation notes. It does not contain user data, credentials, Windows images, or third-party commercial applications. Agent Channel's own code is Apache-2.0; third-party software keeps its own licenses and terms. See [third-party notices](tools/agent-channels/product/THIRD-PARTY-NOTICES.md) and [asset provenance](docs/ASSET-PROVENANCE.md).
