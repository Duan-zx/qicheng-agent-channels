# 安装 Agent Channel

当前提供 **Windows 宿主 + 两个 Linux 频道**的 Alpha 试用包。不用重装 Windows，也不用另买 Windows 客体。AI 客户端、模型订阅不包含在内。

## 准备环境

- Windows x64；Docker Desktop 已启动，使用本机 Linux engine。Docker Desktop 的许可与系统要求由其提供方规定。
- Python 3.10+；一键连接 Codex 还需要可在终端运行的 Codex CLI。
- 首装需要联网下载基础镜像、Linux 依赖及固定版本的社区微信开发者工具。下载源包括 Docker Hub 和 GitHub；本安装包不是完整离线镜像。
- 关闭占用 Alt+1/2/3 的其他热键工具。已有安装先保存任务并正常退出查看器；不要手工覆盖单个 EXE。

## 下载、校验、安装

下载 [alpha.23 r2 ZIP](../downloads/Agent-Channel-Windows-Linux-alpha23-r2.zip) 和 [SHA256SUMS.txt](../downloads/SHA256SUMS.txt)。GitHub 文件页点下载按钮，完整解压到普通文件夹。PowerShell 可用 `Get-FileHash <ZIP路径> -Algorithm SHA256` 核对：

```text
2b40a8ecda27b552755a3abcfdd820316b393b0281d85c5ef71d38c34a1d45fc
```

双击 **Install-Agent-Channel.cmd**。它先校验包与依赖，再构建和安装两个频道；构建输出实时显示，窗口给出本机日志路径。首次下载可能较慢，按实际输出判断进度。失败时保留日志并处理报错，不连续重复安装，也不要关闭 TLS 校验。

包内沿用 `START-DELL.md`、`DELL-RESULTS.md` 等首轮测试文件名，并标注候选状态；它们不是额外安装步骤。此包与开发机已验候选字节相同，尚未完成独立跨机首装验收。

## 使用与连接 AI

安装完成后后台常驻：**Alt+1 本机、Alt+2 频道一、Alt+3 频道二**。托盘可打开管理和诊断。新频道默认 AI 可操作；“接管”交给你操作，“暂停”停止输入，“交给 AI”恢复。你主动选择的状态会保存。

双击 **Connect-Codex.cmd**，确认注册预览后重载 Codex。按 [AI 接入](AI-SETUP.md) 验证状态、截图和一次无业务副作用的输入；给两个任务各绑定一个频道。安装 Skill 不等于安装 MCP。已有 Broker 安装保持原配置，脚本不会降级成直连。

微信为社区 Linux 移植版，不是腾讯官方 Linux 支持。CLI 服务端口由本人在微信工具中开启；登录、合法项目和真实编译需要你自行验证。不要把能打开登录窗口当成已能开发所有项目。

## 数据、卸载和反馈

程序在 `%LOCALAPPDATA%\Programs\QichengLite`，本机配置在 `%LOCALAPPDATA%\Qicheng\Lite`，频道资料在 Docker 卷 `qicheng-lite-home-1/2`。兼容目录和 MCP 名称暂不改名。

停止试用可从托盘退出。卸载请用安装目录的 **Uninstall-Qicheng-Lite.cmd**，先看预览再确认；它保留资料卷、镜像和含配置的恢复目录。[完整卸载说明](UNINSTALL-LITE.md)。不要用 `docker compose down -v` 清理仍需保留的数据。

国内转发包应保持原 ZIP 与上述 SHA 一致。国内网盘镜像尚未提供；收到不同来源的包也应核对哈希，下载 ZIP 成功不代表首装上游依赖可达。

问题请提交 [GitHub Issue](https://github.com/Duan-zx/qicheng-agent-channels/issues)，附版本、Windows 版本/缩放、失败步骤和脱敏日志。不要附 token、二维码、浏览器资料、账号或项目源码。跨机首次安装、重启恢复、不同物理 DPI 和真实微信项目仍是本轮重点反馈项。
