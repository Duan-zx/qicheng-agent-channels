# 给 AI 一个独立频道

Agent Channel 提供本机 MCP stdio 服务和操作 Skill，不提供 AI 模型、订阅或账号。先完成[安装](INSTALL.zh-CN.md)，确认两个频道在线。

## Codex：推荐入口

1. 双击试用包中的 `Connect-Codex.cmd`，检查 Python、安装路径及两个服务名称，确认后注册。
2. 重载客户端，检查 `qicheng_lite_1` 和 `qicheng_lite_2` 下的 `channel_state`、`channel_screenshot`、`channel_input`。工具审批按客户端正常流程进行。
3. 可将完整 [agent-channel Skill 文件夹](../tools/agent-channels/product/skills/agent-channel) 安装到客户端的 Skill 目录；Codex 的位置见包内快速入门。Skill 提供操作规范，不代替 MCP 注册或批准。
4. 给任务 A 指定频道一、任务 B 指定频道二。默认直连模式每频道只运行一个 AI 任务，不保证同频道多个客户端互斥。

第一次可复制这段提示：

> 只使用 qicheng_lite_1。先读状态和截图，确认频道一允许 AI 操作。在我指定的无业务数据测试输入框输入“Agent Channel 测试”，再截图确认。不要操作宿主，不登录、不发布、不上传；若暂停、接管或工具拒绝，停止并报告。若该服务有 begin/finish，按租约完成操作并释放。

“AI 可操作”只表示输入权限允许，不等于模型正在执行任务。截图只读能力也不等于输入授权。人工接管/暂停时停止；不能另走宿主控制或省略 Broker 参数。

## 其他客户端与平台

[通用 command/args 和排错](../tools/agent-channels/product/AI-CLIENTS.zh-CN.md)适用于支持本机 stdio MCP 的客户端。WorkBuddy、ZCode、MiniMax 等平台尚未逐一实测接入或完成上架，不能把支持 Skill 当作已经兼容。

本服务只连用户本机回环地址。纯云端 Agent 无法直接访问你的 `127.0.0.1`；不要为方便上架把频道端口暴露公网。需要本地运行 MCP 的客户端或另行设计和验证连接方式。

## 已有 Task Lease / Windows 模式

已有 Broker 配置必须保留 URL、凭据文件和频道 ID；使用 `begin → 操作 → finish`。未知或失败响应后停止该进程会话，先核对副作用，再按文档恢复，不能自动重放输入。注册脚本会拒绝覆盖同名不同配置，也不会把 Broker 安装改为直连。

原生 Windows 模式为可选实验能力，使用者自备合法 Windows 客体。见 [Windows 接入](../tools/windows-channels/host/README.md)，它不是默认安装步骤。共享 n8n 接入不在本试用包承诺范围内。


## 接入验收与截图报错

先验“握手 → 三个工具可见 → 状态/截图 → 无业务副作用输入 → 画面读回”，再用于真实任务。两个频道分别绑定两个任务；Skill 是指导，MCP 才是连接。2026-09-29 已有两个独立AI会话的本机broker模式实测，见[验证记录](VALIDATION.md)。n8n 尚未端到端接入验证；本机stdio参数不能直接填成远程MCP URL。

截图503并不总是权限问题。若状态已是agent，先查GUI状态和客体临时空间；测试曾因/tmp写满导致截图失败。保留报错，不反复点击“交给AI”，不重放输入，不盲删资料。向维护者提供脱敏诊断；原始token、登录二维码和用户资料不要上传。
