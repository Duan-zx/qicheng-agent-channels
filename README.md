# Qicheng Agent Channels

Independent desktop workspaces for AI agents, with clear human takeover.

**Status: pre-release development. No usable Windows release is published yet.**

The first release must run two Windows-native tool workspaces concurrently without competing for the host desktop. Each project will have a separate Windows guest, input path, and workspace. A Linux browser prototype exists, but it does not satisfy the Windows acceptance criteria.

## First-release acceptance criteria

- Two independent Windows guests running native developer tools concurrently.
- Screenshot and input routed to the selected guest only.
- Human takeover and pause take priority over agent input.
- No shared host clipboard, disks, or device redirection by default.
- Documented setup, diagnostics, project binding, and recovery.
- Recorded concurrency and reconnect tests; limitations stated explicitly.

Guest Windows and third-party applications are separate dependencies. Their installers, accounts, licenses, and activation are not included in this repository.

## Repository boundary

This public repository is for the reusable tool, documentation, tests, and reviewed examples. Internal project records, customer data, credentials, desktop profiles, and business repositories are excluded.

## 中文

启程桌面频道让 AI 在独立桌面中工作，人可以随时观察、接管或暂停。

当前处于发布前开发阶段，尚未发布可用的 Windows 版本。首版必须通过两套 Windows 原生工具并行、输入互不干扰的实测。现有 Linux 网页原型不作为此目标的验收结果。

## License

Apache License 2.0. See [LICENSE](LICENSE). This license covers this project's code and documentation, not Windows or third-party applications.
