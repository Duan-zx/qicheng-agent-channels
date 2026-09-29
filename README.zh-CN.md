# Agent Channel

[English](README.md) · [安装说明](docs/INSTALL.zh-CN.md) · [验证范围](docs/VALIDATION.md) · [Apache-2.0](LICENSE)

![独立 AI 频道示意图，并非产品实机截图](docs/images/workspace-concept.svg)

**一个 AI 任务，一个 Linux 频道；Windows 宿主留给自己用。** Agent Channel 为任务提供独立 Linux 桌面、浏览器资料和持久数据卷。你可以在查看器里观察、接管或暂停 AI 输入。MCP 桥只连接选定的频道，不把操作转到 Windows 宿主桌面。

按 **Alt+2** 看频道一，**Alt+3** 看频道二，**Alt+1** 回宿主。新频道默认允许已接入的 AI 操作；查看器显示“AI 可操作”不代表已有任务正在执行。默认 Lite 接法每个频道分配一个任务。

## 试用 Lite

[Alpha 23 r2 试用 ZIP](downloads/Agent-Channel-Windows-Linux-alpha23-r2.zip) 在 **Windows 宿主与 Docker Desktop 的 Linux engine** 上提供两个 Linux 频道。请按[安装说明](docs/INSTALL.zh-CN.md)操作，并先核对其中的 ZIP SHA-256。首次构建镜像需要联网；MCP 另需 **Python 3.10+** 和你自备的 AI 客户端。产品不附模型、订阅或 API 密钥。

试用包带有精简 Agent Channel Skill、先预览再写入当前用户 MCP 配置的 Codex 注册入口，以及[保留数据卸载路径](docs/UNINSTALL-LITE.md)。Skill 只提供操作指引，不会自动注册 MCP 或批准工具。可选 Linux 微信开发者工具镜像在本机构建，并遵守该软件自己的条款。

当前[公开 Releases](https://github.com/Duan-zx/qicheng-agent-channels/releases)仍是较早的 Alpha；此试用 ZIP 从仓库直接提供，尚不是对应版本的公开 Release。开发者可查看 [Lite 构包脚本](tools/agent-channels/product/Build-Package.ps1)、[快速说明](tools/agent-channels/product/QUICKSTART.zh-CN.md)和 [AI 接入说明](docs/AI-SETUP.md)。

## 其他组件

需要 Windows 客体原生应用时，可另看 [Windows Channels](tools/windows-channels/README.md)；需要显式接入的任务协调时，可另看 [Task Lease](tools/task-lease/README.md)。两者仍属独立实验组件，须分别安装和验收；Lite 不会自动让多个任务经 Task Lease 排队。

开发机已验证两个 Linux 频道各自的 AI 中文输入、点击和保存值读回，以及查看器热键、频道独立暂停/接管、缩放画面的实际点击。一次有限时长的宿主前台采样在采样点未见切走，不能排除更短的瞬间切换。另一台 Windows 实机的首次安装与重启、其他物理 DPI 或多屏、合法微信项目编译仍未验证。详见[验证范围与限制](docs/VALIDATION.md)。

本仓包含产品源码、构包脚本、公开文档和脱敏验证记录，不含用户资料、凭据、Windows 镜像或第三方商业应用。Agent Channel 自有代码使用 Apache-2.0；第三方软件各守其许可证和条款。见[第三方声明](tools/agent-channels/product/THIRD-PARTY-NOTICES.md)和[素材来源](docs/ASSET-PROVENANCE.md)。
