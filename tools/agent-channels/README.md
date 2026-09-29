# Agent Channel

## Agent Channel 本地安装

`product/Build-Package.ps1` 生成 `Qicheng-Lite.zip`：它运行在 Windows 宿主上，提供 1 或 2 个 Linux 容器工作区（双任务试用包配置为 2 个）。Windows 客体兼容下载由 `windows-channels` 模块单独构建。轻量包包含显式白名单源码、Apache-2.0 自有代码许可证及第三方依赖说明；不会包含 `.local` token、账号、浏览器资料、Docker volume、缓存或本机历史。

轻量版仍要求用户已有可用的 Docker Linux engine，首次构建镜像需要联网。它不捆绑 Docker Desktop，也不把 Docker Desktop、Debian、Firefox 或容器依赖重新标为 Apache。安装和使用入口见 [轻量版快速说明](product/QUICKSTART.zh-CN.md)，本版发行边界见 [发行说明](docs/RELEASE-0.2.0-alpha.1-local.md)。

在独立 Linux 桌面里让 Agent 操作，在 Windows 无边框查看器里观察与接管。安装包按选择维护 1 或 2 个频道，使用固定 Compose 项目 `qicheng-agent-channels`，并把持久工作区保存在显式命名的 Docker volumes 中。

## MCP 接入

可选 Linux 微信开发者工具镜像及 CLI 见 [构建说明](docs/WECHAT-LINUX-OPTION.md)。

stdio 桥启动命令：`python <当前克隆目录>/tools/agent-channels/bridge.py --channel 1`。频道二用 `--channel 2`。Python 及桥脚本最好使用接手机器的绝对路径；不要依赖另一台机器的盘符。

Codex 片段见 [codex.example.toml](integrations/codex.example.toml)。它是模板，不是已经加载的连接。默认读取本模块 `.local/channel.token`，由 `Start-Backend.ps1` 生成，不应写进配置、聊天或 Git。

工具为 `channel_state`、`channel_screenshot`、`channel_input`。新频道默认交给 AI；先读实际状态并截图观察，再按客体坐标行动。人选择接管或暂停后，agent 输入立即停止，只有人能在查看器里交回 AI；不能回退到宿主 Computer Use。模型或客户端必须能够消费 MCP 图片。

本桥不提供 shell 执行工具，但在桌面终端中键入仍能执行命令；它不是安全授权边界。网页内容与应用数据继续按不可信输入处理，对外动作遵循用户实际授权。

## 调试与验收

`python -m unittest discover -s tests -v` 做单元、HTTP 和 MCP 检查。`Build.ps1` 编译查看器；`--self-test <输出路径>` 验证坐标、布局和隐藏窗口渲染，不等于真实热键、多显示器或业务任务验收。

启动两个本工具容器后，可显式运行 `python tests/live_smoke.py`。它会暂停两频道、在频道一创建测试终端和临时标记、切换测试控制权，再恢复两频道为 paused，输出合成截图和 JSON。**不要在已有业务任务运行时执行此测试。** 此脚本按固定 compose 项目名称寻找容器，导出仓验证没有运行它，避免碰到原开发环境。

`dist/`、`.local/` 与缓存均不入库。构建包内的 `SOURCE-MANIFEST.json` 列出公开源码白名单与哈希。
