# 启程 Windows 频道｜快速说明

这是 Windows 10/11 Pro 或 Enterprise 上的实验性 Hyper-V 频道包装。它把已有的查看器、Host CLI 和 MCP 入口安装到当前用户目录，方便在两台已经准备好的 Windows 虚拟机之间切换。它不会安装 Windows、创建或下载镜像、创建虚拟机、开启 Hyper-V、安装微信开发者工具、登录账号或把 guest agent 自动装进虚拟机。

## 依赖与当前边界

- Windows 10/11 Pro 或 Enterprise；已由管理员启用 Hyper-V，`vmms` 服务可用。
- 宿主安装 Python 3.12 或更高版本。Host 与 MCP 使用 Python 标准库的 `AF_HYPERV`，旧版 Python 不支持。
- 系统自带 .NET Framework 4.x；构建包时还需 `csc.exe`，普通安装只运行已构建的 EXE。
- 两台现有 Hyper-V 虚拟机应已完成 Windows 安装、激活、各自的本地用户登录、guest payload 安装和 Host service 注册。客体内需在目标用户的交互桌面运行 agent。
- 查看器的“AI 可用”状态只表示本地接口可配置，不代表实际客户端已加载 MCP，也不代表 Hyper-V 通信、微信开发者工具或 Computer Use 已通过真机验收。

## 双击安装

解压发布包后，双击 **Install-Qicheng-Windows-Channels.cmd**。它会在当前用户范围安装程序、自动定位并核验支持 `AF_HYPERV` 的 Python 3.12+，创建中文快捷方式，并立即打开首次设置向导（已有有效配置时打开工作台）；默认也会在当前用户下次登录时启动工作台。不要求先输入两条 PowerShell 命令。如果依赖缺失，窗口会保留明确错误，不会偷偷下载或修改系统组件。它不会设置 VM 自动登录，也不会注册系统级自启动服务。

需要先审阅或从命令行导入已有配置时，可运行：

```powershell
.\Install-WindowsChannels.ps1
.\Install-WindowsChannels.ps1 -ImportConfigPath 'D:\Private\channels.json'
.\Install-WindowsChannels.ps1 -ImportConfigPath 'D:\Private\channels.json' -Apply
.\Install-WindowsChannels.ps1 -AutoStart Disabled -Apply
```

前两条只显示计划；带 `-Apply` 才执行。安装位置为 `%LOCALAPPDATA%\Programs\QichengWindowsChannels`，用户数据位于 `%LOCALAPPDATA%\Qicheng\WindowsChannels`。导入会解析原配置的相对 token 路径，将每个 token 复制到受当前 Windows 用户保护的 `DataRoot\tokens` 并写入规范化配置，不会把凭据放入程序包或命令输出。已有目标配置默认拒绝覆盖，只有明确审阅后才能加 `-ReplaceConfig`。

默认自启动只创建当前用户 Startup 目录中的“启程 Windows 频道”快捷方式。要关闭它，用同一发布包重新运行 `Install-WindowsChannels.ps1 -AutoStart Disabled -Apply`；卸载也只删除这个本产品命名的快捷方式。

升级前请关闭频道工作台，以及正在使用本频道 MCP 的 AI/Codex 客户端。安装器检测到本产品 Viewer 或 MCP 启动器仍在运行时，会显示“关闭频道客户端后重试”，保持当前版本不变，也不会自动终止 Python、Codex 或其他进程。

## 首次设置

第一次启动且尚无 `channels.json` 时，程序会自动打开中文设置向导。已有频道配置应优先选择“导入已有频道配置”：向导会显示检测到的 `qicheng-win-1..8` VM，并安全复制配置与 token，不重建 VM。

全新电脑可选择 1–8 台工作区、Windows ISO、已存在的 VM 目标目录和 Hyper-V 虚拟交换机。每台 VM 使用 8 GiB 静态内存和最多 80 GiB 动态磁盘；向导会显示总量，并按“VM 总内存 + 至少 8 GiB 主机余量”给出建议。确认后它实际调用 `source\New-ChannelVMs.ps1 -Count N -Apply`。

VM 创建成功只表示生成了关闭状态的 Hyper-V VM。Windows 安装、许可与登录、来宾代理安装及最终 `channels.json` 导入仍需完成；向导把这一阶段记录为“等待 Windows/来宾代理”，不会把数量保存成可用频道。配置完成后，登录自启动及默认双击入口都在后台托盘运行；需要显示管理窗口时，从开始菜单打开“管理 Windows 频道”。可用 `Alt+1` 至 `Alt+8` 切换。

## 新电脑首次准备 Windows 工作区

发布包不会假设电脑已有 Windows VM，也不会伪装成 Windows 全自动安装器。源码分发目录 `source` 保留了可审阅、可运行的准备脚本。首次准备顺序如下：

1. 以管理员身份确认 Windows 10/11 Pro 或 Enterprise、Hyper-V、固件虚拟化、`vmms` 和目标 VM 名称：`source\Test-Host.ps1`。
2. 自行取得合法、已校验 SHA-256 的 Windows ISO，并选择现有 Hyper-V virtual switch。先运行 `source\Prepare-Channels.ps1` 或不带 `-Apply` 的 `source\New-ChannelVMs.ps1` 查看计划。
3. 审阅计划后，按 `source\README.md` 的参数运行 `New-ChannelVMs.ps1 -Apply`。它只创建两台 Gen2 VM 与 VHDX，不安装 Windows、不接受许可、不登录账号。
4. 用 VMConnect 完成两台客体各自的 Windows 安装、激活、本地用户和应用准备；保持两台客体身份、磁盘和 token 分离。
5. 运行 `source\Register-HostService.ps1` 注册固定 Hyper-V service。使用可信的 Python embeddable 目录与每客体独立 token，通过 `source\Build-GuestPayload.ps1` 构建 payload。
6. 客体登录到目标交互用户后，用 PowerShell `Get-Credential` 获取内存凭据；先运行 `source\Install-GuestPayloadDirect.ps1` 的计划模式，再显式 `-Apply`。它不保存明文密码，也不代替真实 Host↔Guest 验收。
7. 对两台客体分别核对 VM ID、BIOS UUID、token、交互桌面 agent 和实际通道，再创建或导入 `channels.json`。

详细参数和边界见 `source\README.md`、`source\guest\README.md` 与 `source\ARCHITECTURE.md`。这些步骤仍需要 Windows 安装与登录操作；当前包没有镜像下载器、自动装 Windows、自动登录或账号迁移。

## 接入已有 Windows 工作区

已有合格 Windows VM 时不要重新创建。记录每台 VM 的 ID、已核对 BIOS UUID 和准确 VM 名称；每个频道使用不同 token。可直接用安装器的 `-ImportConfigPath`，或安装后从开始菜单选择“导入已有频道配置”。手工创建时，私有文件只放用户数据目录：

```json
{
  "schema_version": 1,
  "projects": {
    "channel-1": {
      "vm_id": "现有虚拟机的 VM ID",
      "bios_uuid": "已核对的客体 BIOS UUID",
      "token_file": "channel-1.token",
      "vm_name": "现有 Hyper-V VM 的准确名称"
    },
    "channel-2": {
      "vm_id": "另一台现有虚拟机的 VM ID",
      "bios_uuid": "另一台客体的 BIOS UUID",
      "token_file": "channel-2.token",
      "vm_name": "另一台 Hyper-V VM 的准确名称"
    }
  }
}
```

保存为 `%LOCALAPPDATA%\Qicheng\WindowsChannels\channels.json`。`token_file` 相对配置文件解析；每个 token 文件只能包含对应 guest payload 使用的 64 位小写十六进制 token。不要复制另一台宿主的 token、账号或虚拟磁盘。确认每台 VM 的 guest agent 与配置中的 VM ID、BIOS UUID、token 一一对应。

## 启动、诊断与 AI 接入

从桌面或开始菜单打开“启程 Windows 频道”。也可以运行：

```powershell
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Start-WindowsChannels.ps1"
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Diagnose-WindowsChannels.ps1"
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Get-AISetup.ps1"
```

启动器只接受绝对的本地 `--config` 和 `--python` 路径。查看器保留 `viewer\dist` 与 `host` 的相对结构；缺配置时会弹出可操作提示并打开本说明。诊断命令只读取依赖、配置结构、token 文件存在性和 Hyper-V/VM 可见性，不显示 token 内容。

`Get-AISetup.ps1` 为每个 project 输出不依赖客户端 `cwd` 的稳定 MCP 启动命令。要显式把某个频道加入本机 Codex CLI，可先查看计划，再执行：

```powershell
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Add-CodexMcp.ps1" -Name 'qicheng-channel-1' -Project 'channel-1'
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Add-CodexMcp.ps1" -Name 'qicheng-channel-1' -Project 'channel-1' -Apply
```

这只修改明确选择的一个 Codex MCP 配置，不自动改其他客户端。`codex mcp add` 成功只表示 CLI 配置已写入；当前任务不会热加载新工具，也不能据此声称原生 MCP 已发现。重启或重新加载客户端后必须实际检查工具，再用合成数据测试 `state`、截图和输入。每个 MCP 进程只绑定一个 project；不要把人工控制切换做成 AI 自动重试。

## 卸载

```powershell
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Uninstall-WindowsChannels.ps1"
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Uninstall-WindowsChannels.ps1" -Apply
```

默认保留 `channels.json` 和 token。只有明确需要清除当前用户数据时才使用 `-RemoveUserData -Apply`。卸载不会删除虚拟机、VHDX、ISO、客体软件或 Hyper-V 配置。
