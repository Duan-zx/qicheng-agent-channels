# Qicheng · AI Workspaces

[简体中文](README.zh-CN.md) · Apache-2.0 · Alpha

![Concept diagram of Qicheng workspaces; not a product screenshot](docs/images/workspace-concept.svg)

**Give each computer-using AI task its own workspace.** Run one or two browser jobs in separate Linux desktops while you keep using your Windows PC. Press **Alt+2** for the first channel, **Alt+3** when a second is enabled, and **Alt+1** to return home. Take control of one channel, hand it back to a connected AI client, or pause it without changing the other channel.

Qicheng has two installation paths. Start with Lite for browser work. Add native Windows channels only when a task needs a Windows desktop application, such as WeChat Developer Tools. Qicheng provides the workspace and controls; bring your own AI client. No model subscription or API key is included.

| Package | Use it for | You need |
| --- | --- | --- |
| **Qicheng Lite** | Isolated browser profiles, web workflows and downloads | Windows host, Docker Desktop with a Linux engine; internet for the first image build |
| **Qicheng Windows Channels** | Native desktop tools in separate Windows guests | Hyper-V capable Windows host, Python 3.12+, and your own licensed Windows guest installations |

The optional **Task Lease** broker lets explicitly connected Codex MCP and n8n jobs coordinate access to a channel. It can give a configured, short fixed action its own Git worktree and build directory; `/v1/run` owns one such action through acquire, execution, and release. n8n can use immediate `409 busy` responses by default, or opt into bounded queueing with a local execution-status check: in isolated n8n 2.39.6 CLI tests, a canceled queued run was withdrawn before the channel became free, while a live run proceeded. The local alpha.24 source candidate adds an offline maintenance gate that blocks new leases and actions during a controlled upgrade; it has passed isolated package tests but is not running on the 01 host. This is an explicit integration for one action, with a remaining stop-versus-start race; it does not automatically intercept other Computer Use, CLI, or n8n actions. Lite can run on its own or join the broker through an explicit connection.

**Download status:** [public Releases](https://github.com/Duan-zx/qicheng-agent-channels/releases) currently contain earlier Alpha builds. This candidate branch includes newer source, but matching public installers have not been released. Check a Release's version and package hash before installing; do not assume the latest source is already in a download.

## Try Lite

1. Download a matching Lite Release, verify its hash, extract it and run the installer included in the package. Docker's Linux engine must be available.
2. In the alpha.14 local source candidate, first installation can choose one or two Lite channels; one is the default. The viewer stays in the tray. Use **Alt+2** for channel one, **Alt+3** when channel two is enabled, and **Alt+1** for your own desktop.
3. Choose **Take control** to use a channel yourself. Choose **Give to AI** before a connected client sends input. Each channel keeps its own browser profile and Downloads volume.
4. Run the installed diagnostics if a channel is unavailable. The package quickstart lists data locations and AI connection steps.

The alpha.14 source sets a dark Firefox chrome by default, both in the image and the two-channel Compose environment. It does not suppress Firefox security or session-recovery notices. The 01 host still runs alpha.13; alpha.14 has no matching public installer or live upgrade acceptance yet.

The alpha.14 local source candidate also adds an explicit offline upgrade option for an existing Lite installation when Docker Hub is unavailable. Its preview checks the local Linux engine, installed backend files, Compose ownership, and persistent volumes; applying the upgrade also checks image content before reuse. The default installer still builds the new image. This path does not cover first installation or prove that the new Dockerfile image was built. See the package quickstart for the preview and apply commands. The offline upgrade has not been installed on the 01 host or published as a Release.

A later local Viewer source candidate adds a visible overflow menu to both the expanded and compact bars, including the existing graceful **Exit and pause input** action. It has compiled and passed non-GUI checks; it is absent from the installed alpha.13 Viewer and the built alpha.14 ZIP. Its menu interaction and DPI rendering still need GUI acceptance.

When both editions are installed, Lite uses Alt+1/2 and optionally Alt+3; native Windows channels start at Alt+4. The Windows setup wizard limits its count accordingly. Hotkey conflicts are reported by diagnostics; available keys depend on the installed version.

## What is open source

This repository contains product source, package builders, public documentation and sanitized validation records. Windows Channels and Task Lease use explicit source allowlists and SHA-256 manifests. It does not include private product memory, browser data, tokens, Windows images, guest accounts or third-party commercial applications.

Qicheng's own code is offered under Apache-2.0. Included third-party software keeps its own licenses; see the Lite package's `THIRD-PARTY-NOTICES.md`. Docker Desktop and Windows guest licenses are separate. See [validation and known limits](docs/VALIDATION.md) and [asset provenance](docs/ASSET-PROVENANCE.md). This is an Alpha product: automated tests and synthetic input do not prove every site, login flow or Windows app works. DELL independent installation and real WeChat project compilation remain unverified.
