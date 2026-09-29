# AI 客户端接入 Agent Channel

Agent Channel 的 `bridge.py` 是本机 MCP stdio 服务。它让 AI 客户端看到 `channel_state`、`channel_screenshot` 和 `channel_input`，每个进程只连接一个频道。它只访问 `127.0.0.1:18761` 或 `127.0.0.1:18762`，不接管 Windows 宿主桌面。双频道试用包默认直连模式建议每频道分配一个 AI 任务；需要同频道多个任务时，须另行配置并验证 Task Lease。AI 客户端及 Python 3.10+ 需另行安装；本产品不提供模型、订阅或客户端账号。现有 `QichengLite` 安装目录、`qicheng_lite_1/2` MCP 名称和协议保持不变。

## Codex（Windows）

先安装并启动 Agent Channel，再双击安装包中的 `Register-Qicheng-Codex.cmd`。它先显示将添加的服务及 Python、bridge 路径，询问后才写入当前用户的 Codex MCP 配置。已有同名且完全一致的服务会跳过；同名但配置不同或禁用时会拒绝覆盖。选 1 个频道只添加 `qicheng_lite_1`，选 2 个频道添加两个。若从 2 个频道缩到 1 个，脚本会提示已有 `qicheng_lite_2`，不会自动删除。

需要在命令行预览或指定解释器时：

```powershell
.\Register-CodexMcp.ps1
.\Register-CodexMcp.ps1 -PythonPath 'C:\Program Files\Python\python.exe' -Apply
codex mcp list
```

脚本不保存 token，也不在配置中嵌入 token。`bridge.py` 在启动时从本机安装目录的 `.local\channel.token` 读取它。脚本可发现 `python.exe` 或通过 `py.exe` 找到实际 Python，也可发现 `codex.exe` 或 `codex.cmd`；路径含空格时，Codex 分别保存可执行文件与参数，不需要手工拼接命令行。若未安装 Codex CLI、Python 不符合版本要求或安装记录缺失，脚本报错且不写配置。注册后重启客户端，确认它加载服务和工具；注册成功本身不代表实际频道可用。

## 其他支持 stdio MCP 的客户端

在客户端的 MCP 设置中为每个启用频道添加一项：`command` 填 Python 3.10+ 可执行文件的绝对路径，`args` 依次填安装目录下 `bridge.py` 的绝对路径、`--channel`、`1` 或 `2`。不要把这些内容拼成一条带引号的字符串。Windows 默认安装目录是 `%LOCALAPPDATA%\Programs\QichengLite`。例如通用 JSON 形状如下；字段名和授权方式以该客户端文档为准：

```json
{
  "command": "C:\\path to Python\\python.exe",
  "args": ["C:\\Users\\you\\AppData\\Local\\Programs\\QichengLite\\bridge.py", "--channel", "1"]
}
```

先让 AI 读取 `channel_state` 和 `channel_screenshot`，核实确实连接了目标频道，再考虑输入。查看器中的“接管”或“暂停”会拒绝 AI 输入；只能由人在查看器里恢复“交给 AI”。业务登录、发帖、付款等动作仍需相应授权。其他客户端的加载、工具批准和端到端操作尚未逐一实测，这里只给出协议层的配置形状。若客户端支持 Skill，可按 `QUICKSTART.zh-CN.md` 安装 `skills/agent-channel/SKILL.md`；Skill 不会自动连接 MCP 或批准工具权限。

## Task Lease 模式

已有 Broker 安装保持原有配置；不要用 双频道试用包默认直连配置覆盖它。安装目录存在 `.local\broker.token` 时，上面的 Codex 一键脚本会拒绝配置直连输入。Task Lease 需要在每个频道的 stdio 参数中同时追加 `--broker-url http://127.0.0.1:18770 --broker-token-file <broker.token 绝对路径> --broker-channel-id <该频道 ID>`，并先核对 Task Lease 的频道绑定、凭据隔离及真实输入。缺少任一参数不得退回直连模式。操作顺序是 `begin`、具体动作、`finish`；结果不确定时停止并先核对桌面，不能自动重试。这个模式的首次接入不是一键注册的验收范围。
