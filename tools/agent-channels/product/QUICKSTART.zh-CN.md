# Agent Channel｜快速开始

版本以安装包内 `package-manifest.json` 为准。

Agent Channel 在 Windows 上提供 1 或 2 个彼此独立的 Linux 桌面频道。每个频道可交给一个 AI 任务，人在查看器里用“接管”“交给 AI”“暂停”三个按钮切换控制权。安装包和本地配置仍使用 `Qicheng-Lite`、`QichengLite` 等原有文件名及路径；这些是兼容接口，不要为改名而移动安装目录、Docker 卷或 MCP 名称。

## 先确认依赖

Agent Channel 需要 Docker Linux engine。安装包不包含 Docker Desktop，也不声称 Docker Desktop 开源或无条件免费。首次构建容器镜像需要联网访问官方 Python 镜像与 Debian HTTPS 软件源；后续启动可复用本机镜像。Windows 查看器是可选入口；AI 客户端仍需另行准备。

轻量版启动器运行在 Windows 宿主，需要系统 .NET Framework 4.x。发布包已经带有编译好的 `dist/AgentChannels.exe`，普通安装不需要重新编译；公开源码可用 `source/Build.ps1` 重建。

## Windows 当前用户安装

解压 `Qicheng-Lite.zip`，进入其中的 `Qicheng-Lite` 目录并双击 `Install-Qicheng-Lite.cmd`。默认安装到：

- 程序：`%LOCALAPPDATA%\Programs\QichengLite`
- 用户数据：`%LOCALAPPDATA%\Qicheng\Lite`
- 私有 token：程序根 `.local\channel.token`（后端和查看器的现有接口要求此位置）

需要多个 AI 任务操作同一频道时，可另外接入 Task Lease。该模式使用独立的 `.local\broker.token`；两个 token 不能相同。仅安装轻量版不会自动创建 Task Lease 租约。

首次双击安装可选择 1 或 2 个频道；命令行无交互时默认 1 个，适合资源较紧的电脑。频道一使用 `127.0.0.1:18761`，选 2 个时另启频道二 `127.0.0.1:18762`；Compose 项目固定为 `qicheng-agent-channels`。安装记录保存选择，升级不传参数时沿用原选择；旧版双频道安装升级按 2 个保留。明确要增减频道时运行 `Install-Qicheng-Lite.ps1 -ChannelCount 1` 或 `-ChannelCount 2`，先查看计划，再加 `-Apply` 执行。切到 1 个频道时，下次启动会核对并停止本安装的旧频道二容器；不会删除它的 volume，重新选 2 可继续使用原数据。它不会执行 `docker compose down -v`，不会删除 volume，也不会停止无关进程。

要复用已有 token，请从 PowerShell 显式运行：

```powershell
.\Install-Qicheng-Lite.ps1 -ImportTokenPath 'D:\private\channel.token'
.\Install-Qicheng-Lite.ps1 -ImportTokenPath 'D:\private\channel.token' -DisableLegacyWindowsChannelsStartup -LaunchAfterInstall -Apply
```

第一条只显示计划；第二条才执行。token 必须是 64 位小写十六进制，复制后只允许当前用户和 SYSTEM 访问，值不会进入输出或 manifest。

已有安装升级时若 Docker Hub 暂不可达，且你已保存频道中的表单与下载、从托盘选择“退出并暂停输入”，可在新版解压目录先预览显式离线复用，再执行：

```powershell
.\Install-Qicheng-Lite.ps1 -ReuseExistingBackendImage
.\Install-Qicheng-Lite.ps1 -ReuseExistingBackendImage -LaunchAfterInstall -Apply
```

离线复用会在替换旧安装前核对本机 Docker Linux engine、旧安装与运行镜像的后端文件、Compose 容器及数据卷归属；若后端变化、镜像不符或首次安装则拒绝。预览只读，实际执行会暂时重建频道容器并沿用原资料卷。默认双击仍构建新版镜像；离线复用只适用于已核实兼容的升级，不表示 Dockerfile 的新版镜像已经构建。

默认从托盘后台启动查看器（`--background`）。桌面、普通开始菜单和登录启动项都使用隐藏 PowerShell；“管理启程轻量工作台”用于打开可见管理界面。登录启动项会在确认本机 Docker 管道后、Linux engine 尚未就绪时启动本机已安装的 Docker Desktop，从首次探测起最多等待 120 秒；若仍不可用，则明确报错且不启动后端和查看器。Docker CLI 缺失或当前 endpoint 无法确认时不会启动 Desktop；远端 Docker context 和 Windows engine 也会被拒绝。它不会修改 Docker Desktop 自启动设置、接受许可或停止其他容器。桌面和开始菜单的手动入口仍要求 engine 已经可用，以便快速发现错误。

为避免两套产品同时注册全局 Alt 快捷键，双击安装会停用**精确名为**“启程 Windows 频道.lnk”的旧当前用户 Startup 快捷方式，并把原文件备份到轻量版 DataRoot。不会改其他启动项，也不会杀进程。开始菜单“恢复旧 Windows 频道自启动”可恢复备份；目标已存在时拒绝覆盖。

诊断遇到该 Startup 快捷方式时会检查它实际指向的 Windows 频道安装、安装记录、发布包文件校验和启动器的 Lite 热键协调能力。经核实的兼容版会自动为 Windows 频道使用 Alt+4..9 并关闭 host 快捷键，此时不报冲突；旧版或证据不完整的启动项仍报告可能冲突。诊断只读，不修改启动项，也不读取 Windows 频道私有 token。

来宾浏览器下载保存在 Docker volume 内。开始菜单只为已选频道提供“取回频道下载文件”入口；导出时会先核对容器确实属于本产品，再把 `/home/channel/Downloads` 手动导出为 `%LOCALAPPDATA%\Qicheng\Lite\Downloads\频道N\时间戳` 快照并打开目录。每次使用新目录，不覆盖以前同名文件；来宾原文件和 volume 保留。

## 开发者 Linux 后端脚本

可选 Linux 微信开发者工具镜像的构建、资源、许可与双频道切换说明见 `docs/WECHAT-LINUX-OPTION.md`。它需要单独构建，普通 Lite 安装不会下载或启动微信开发者工具。

源码白名单保留 `product/runtime/linux/` 下的用户目录安装和后端启动脚本，便于开发者验证 Compose 后端。当前版本不生成 Linux 主机发行资产，也不提供兼容的 Linux 查看器；这些脚本不是普通用户下载入口。

```sh
sh ./product/runtime/linux/install.sh --prefix /absolute/path
```

## 诊断与边界

Windows 开始菜单可运行“诊断启程轻量工作台”。诊断只读，不启动、不停止、不重建容器，并使用本地 token 验证已选频道的私有 Linux 显示、认证状态和尺寸。选 1 个频道时不把未启用的 18762 报为故障。

本版本提供本地安装、1 或 2 个频道容器启动、托盘查看器、诊断和源码重建。它不安装 Docker、不替用户接受第三方许可、不登录业务账号，也不把工程测试等同于真实业务可用性。第三方许可边界见 `THIRD-PARTY-NOTICES.md`。

## AI 客户端接入（Lite）

宿主另需 Python 3.10+。查看器和浏览器本身不依赖宿主 Python；只有 MCP 适配器需要它。启程不附带模型或订阅。

已安装 Codex CLI 和 Python 时，双击 `Register-Qicheng-Codex.cmd`：先看预览，再决定是否写入当前用户的 Codex 配置。它按安装记录注册 1 或 2 个频道，已有同名但不同配置时拒绝覆盖。PowerShell 也可运行 `./Register-CodexMcp.ps1` 预览，确认后加 `-Apply`。其他 MCP 客户端的通用 stdio 配置见 `AI-CLIENTS.zh-CN.md`。

重新加载 AI 客户端，按客户端要求批准工具。双频道试用包 候选默认直连、每频道一个任务；新频道默认由 AI 操作。每个任务固定使用一个频道的 MCP 服务，先读 `channel_state` 和 `channel_screenshot`，确认频道及实际控制状态后再调用 `channel_input`。在查看器点“接管”或“暂停”会立即拒绝 AI 输入，点“交给 AI”可恢复。每个频道的控制选择保存在各自资料卷，重启后沿用；从托盘选“退出并暂停输入”也会保持暂停。不要改用宿主桌面绕过拒绝。

已验证适配器 stdio 协议、部分本机频道输入和暂停边界。已有 Task Lease Broker 安装不能按默认直连步骤覆盖。不同 AI 客户端的加载、权限和端到端执行需要分别验证；注册成功不代表客户端已经可用。两个频道互相独立，工具不会退回宿主桌面。

支持 Skill 的工具可读取安装包 `skills/agent-channel/SKILL.md`；也可由用户把整个 `agent-channel` 文件夹复制到该工具的 Skill 目录（Codex 通常为 `~/.codex/skills/agent-channel`）并重载客户端。Skill 只提供操作指导，不会注册 MCP、开启权限或改变控制模式；MCP 仍按 `AI-CLIENTS.zh-CN.md` 单独配置并实测。

### 多任务接入 Task Lease

先安装并配置启程 Task Lease，再在安装轻量版时传入一份单独生成的 64 位小写十六进制 broker token 文件：

```powershell
.\Install-Qicheng-Lite.ps1 -ImportBrokerTokenPath 'C:\private\lite-broker.token' -Apply
```

升级时若已有 `.local\broker.token`，安装器会保留它，并为查看器生成独立的 `.local\viewer.token`（后续升级保留）。启动器检测到 broker token 后使用 `compose.broker.yaml`，要求频道读取、查看器人工操作和 Broker AI 输入使用三类不同凭据。旧直连 MCP 只能读取，不能更改接管状态或输入；只有查看器中的人能更改控制模式，人工接管或暂停会立即撤销后端短租约。不要只打开后端门禁却继续使用上面的直连 MCP 注册命令。

Task Lease 每个频道需配置固定的 `lite` 绑定，端口分别为 18761/18762，频道编号分别为 1/2；`broker_token_file` 指向安装后的 `.local\broker.token`，`channel_token_file` 指向 `.local\channel.token`。对应的 `endpoint_id` 和 `project_path` 各自独立。完整示例见 Task Lease 随包说明。AI 客户端通过同一 `bridge.py` 增加 `--broker-url http://127.0.0.1:18770 --broker-token-file <Task Lease 的 broker.token> --broker-channel-id <频道 ID>`。三项参数必须同时提供；`channel_input` 先用 `begin`，再执行动作，最后 `finish`。每个动作由 Broker 记录并确认；响应不确定时停止该会话，先核对实际桌面，不能自动重试。

此接法是可选的多任务隔离模式。首次接入需逐项核对真实配置和本机输入。默认直连模式没有任务级互斥；只有两端都启用新模式并完成验收，才能声称同频道多任务不会串台。

## 保留数据卸载

双击安装目录中的 `Uninstall-Qicheng-Lite.cmd`，先查看预览再确认。保持 Docker Desktop 运行以核验并停止本产品容器。卸载会移除本安装的快捷方式，将完整程序和私有凭据移到回执显示的本机恢复目录，保留用户数据、Docker 资料卷和镜像；不删除其他产品。恢复时先查看回执，勿把恢复目录上传到网盘或 Git。

## 修复已有微信频道

先退出查看器，在完整新包目录运行：

```powershell
.\Install-Qicheng-Lite.ps1 -RepairExistingWechatImage
.\Install-Qicheng-Lite.ps1 -RepairExistingWechatImage -LaunchAfterInstall -NonInteractive -Apply
```

第一条只预览，第二条执行。仅适用于本安装已有的固定版本微信频道；脚本核对容器归属、镜像、资料卷和工具版本后，用完整新包替换产品后端并更新安装记录，保留账号资料与凭据。它不下载新的微信工具，不用于首次安装，也不能用于绕过不匹配的镜像或来源检查。报错时保留原文，勿改标签或覆盖单个文件强行通过。