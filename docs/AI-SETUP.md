# AI 接入

启程提供控制通道，不附带模型订阅、API 密钥或第三方账号。你使用现有 AI 客户端，并明确选择对应项目频道。

## Windows 兼容版：Codex MCP

安装后，对每个项目分别运行（项目名以自己的配置为准）：

```powershell
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Add-CodexMcp.ps1" -Name qicheng_windows_a -Project project-a -Apply
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Add-CodexMcp.ps1" -Name qicheng_windows_b -Project project-b -Apply
```

脚本不覆盖已有同名不同配置，也不自动扩大客户端工具权限。重新加载客户端后，检查是否出现 `windows_channel_state`、`windows_channel_screenshot`、`windows_channel_input`。若客户端要求批准，须按客户端支持的权限流程授权；`approval policy never` 下的批准拒绝不表示客体故障，不要用其他通道绕过拒绝。

操作前在工作台选择“交给 AI”。MCP 不提供自行解除暂停或接管的接口。先读取状态和截图，确认目标，再执行一次操作并回读截图；用户暂停/接管后停止。

建议首个合成任务：

> 在绑定的启程频道中，先检查状态及截图。在已打开的测试应用搜索框输入“启程验证A”，再截图确认文本。不要登录、发布或上传内容。若暂停、人工接管或客户端拒绝，停止并报告。

## 其他客户端

`Get-AISetup.ps1` 输出每项目的 stdio 启动 command/args。当前进程能发现工具、能连接客体、输入生效是三个独立检查；不要只凭配置已保存判断接入成功。

## CLI

允许本地命令与图片查看的 AI 客户端也可以使用 `host.client`，具体参数见 [Host 接口](../tools/windows-channels/host/README.md)。这是一种单独的集成方式，不能用于规避客户端已经拒绝的操作。

## 默认轻量版：Codex MCP

Lite 的宿主 Python 3.10+ 依赖、两频道注册命令及权限说明见 [轻量版快速说明](../tools/agent-channels/product/QUICKSTART.zh-CN.md#ai-客户端接入lite)。工具名为 `channel_state`、`channel_screenshot`、`channel_input`，与 Windows 兼容版独立。当前已测真实后端和 stdio 适配器；不要把注册配置当作任意 AI 客户端端到端验收。
